#!/usr/bin/env python3
"""Dispatcher for /.well-known/lightning/v1/accounts/* (FEAT-212 PR-2;
moved + versioned by FEAT-224 / FEAT-232).

Apache maps the whole `/.well-known/lightning/v1/accounts` URL tree to
this single script; the prefix is consumed by the ScriptAlias, so
PATH_INFO still arrives as the `<id>/<verb>` tail (the dispatcher is
unchanged by the move).  The script parses PATH_INFO + REQUEST_METHOD
and routes:

  POST .../v1/accounts                     -> create (anonymous)
  GET  .../v1/accounts/<id>/balance        -> balance
  GET  .../v1/accounts/<id>/topup[?sat=N]  -> topup
  POST .../v1/accounts/<id>/withdraw       -> withdraw
  POST .../v1/accounts/<id>/pay            -> pay
  POST .../v1/accounts/<id>/recv           -> recv
  POST .../v1/accounts/<id>/recv-reusable  -> recv-reusable (BOLT-12)
  POST .../v1/accounts/<id>/transfer       -> transfer (FEAT-223)
  GET  .../v1/accounts/<id>/referrals      -> referrals (FEAT-218)
  GET  .../v1/accounts/<id>/invite-codes   -> invite codes (FEAT-220)
  POST .../v1/accounts/<id>/invoice        -> commercial invoice (FEAT-225)
  GET  .../v1/accounts/<id>/invoice/<hash> -> invoice lookup    (FEAT-225)
  GET  .../v1/accounts/<id>/standing-orders          -> list    (FEAT-226)
  POST .../v1/accounts/<id>/standing-orders          -> create  (FEAT-226)
  POST .../v1/accounts/<id>/standing-orders/<so_id>  -> pause/resume
  DEL  .../v1/accounts/<id>/standing-orders/<so_id>  -> cancel
  GET/POST .../v1/accounts/<id>/mandates             -> list/create (FEAT-227)
  PATCH/DEL .../v1/accounts/<id>/mandates/<mid>      -> update/revoke
  POST .../v1/accounts/<id>/mandates/<mid>/charge    -> charge (secret-authed)
  POST .../v1/accounts/<id>/mandates/<mid>/pulls/<pid>/approve|deny
  GET/POST .../v1/accounts/<id>/charges              -> list/create (FEAT-228)
  GET  .../v1/accounts/<id>/charges/<cid>            -> show
  POST .../v1/accounts/<id>/charges/<cid>/<action>   -> lifecycle transition
  GET  .../v1/accounts/<id>/export/tax-data          -> tax-data export (FEAT-230)
  GET  .../v1/accounts/<id>/api-key         -> api-key (FEAT-249)
  POST .../v1/accounts/<id>/close          -> close

All authenticated endpoints require Authorization: Bearer <key>.
Create is anonymous + rate-limited at the verb layer.
"""

import json
import os
import re
import subprocess
import sys
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lightning"))
import _lib  # noqa: E402


def _method():
    return os.environ.get("REQUEST_METHOD", "GET").upper()


def _query():
    return urllib.parse.parse_qs(os.environ.get("QUERY_STRING", ""))


def _create():
    if _method() != "POST":
        _lib.respond("405 Method Not Allowed", {"error": "use_post"})
    body = _lib.read_body()
    hint = str(body.get("hint", ""))[:64] if isinstance(body, dict) else ""
    invite = str(body.get("invite_code", ""))[:32] if isinstance(body, dict) else ""
    args = ["api-accounts-create"]
    if hint:
        args += ["--hint", hint]
    if invite:
        args += ["--invite-code", invite]
    result = _lib.call_verb(*args)
    _lib.respond("201 Created", result)


def _balance(account_id):
    if _method() != "GET":
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})
    _lib.auth_account(account_id)
    result = _lib.call_verb("api-account-balance", account_id)
    _lib.respond("200 OK", result)


def _topup(account_id):
    if _method() != "GET":
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})
    _lib.auth_account(account_id)
    args = ["api-account-topup", account_id]
    sat = _query().get("sat", [""])[0]
    if sat and sat.isdigit():
        args += [sat]
    result = _lib.call_verb(*args)
    _lib.respond("200 OK", result)


def _withdraw(account_id):
    if _method() != "POST":
        _lib.respond("405 Method Not Allowed", {"error": "use_post"})
    _lib.auth_account(account_id)
    body = _lib.read_body()
    sat = body.get("sat")
    addr = body.get("address", "")
    if not isinstance(sat, int) or sat <= 0:
        _lib.respond("400 Bad Request", {"error": "sat_required"})
    if not isinstance(addr, str) or len(addr) < 26:
        _lib.respond("400 Bad Request", {"error": "address_required"})
    result = _lib.call_verb("api-account-withdraw", account_id, str(sat), addr)
    _lib.respond("200 OK", result)


def _pay(account_id):
    if _method() != "POST":
        _lib.respond("405 Method Not Allowed", {"error": "use_post"})
    _lib.auth_account(account_id)
    body = _lib.read_body()
    target = body.get("target", "")
    sat = body.get("sat")
    if not isinstance(target, str) or not target:
        _lib.respond("400 Bad Request", {"error": "target_required"})
    note = body.get("note", "")
    args = ["api-account-pay", account_id, target]
    if isinstance(sat, int) and sat > 0:
        args += ["--sat", str(sat)]
    if isinstance(note, str) and note:
        args += ["--note", note[:200]]
    result = _lib.call_verb(*args)
    _lib.respond("200 OK", result)


def _transfer(account_id):
    if _method() != "POST":
        _lib.respond("405 Method Not Allowed", {"error": "use_post"})
    _lib.auth_account(account_id)
    body = _lib.read_body()
    to = body.get("to", "")
    sat = body.get("sat")
    note = str(body.get("note", ""))[:256]
    if not isinstance(to, str) or not to:
        _lib.respond("400 Bad Request", {"error": "to_required"})
    if not isinstance(sat, int) or sat <= 0:
        _lib.respond("400 Bad Request", {"error": "sat_required"})
    args = ["api-account-transfer", account_id, to, str(sat)]
    if note:
        args += ["--note", note]
    result = _lib.call_verb(*args)
    _lib.respond("200 OK", result)


def _recv(account_id, reusable=False):
    if _method() != "POST":
        _lib.respond("405 Method Not Allowed", {"error": "use_post"})
    _lib.auth_account(account_id)
    body = _lib.read_body()
    sat = body.get("sat")
    desc = str(body.get("description", ""))[:256]
    if reusable:
        # BOLT-12 supports "any" as a placeholder for unspecified.
        if sat == "any":
            sat_arg = "any"
        elif isinstance(sat, int) and sat > 0:
            sat_arg = str(sat)
        else:
            _lib.respond("400 Bad Request", {"error": "sat_or_any_required"})
        verb = "api-account-recv-reusable"
    else:
        if not isinstance(sat, int) or sat <= 0:
            _lib.respond("400 Bad Request", {"error": "sat_required"})
        sat_arg = str(sat)
        verb = "api-account-recv"
    args = [verb, account_id, sat_arg]
    if desc:
        args += ["--desc", desc]
    result = _lib.call_verb(*args)
    _lib.respond("200 OK", result)


def _standing_orders(account_id, so_id=None):
    # FEAT-226 — standing orders.  GET/POST on the collection; POST
    # (pause/resume) + DELETE (cancel) on a single order.  Account-only.
    _lib.auth_account(account_id)
    m = _method()
    if so_id is None:
        if m == "GET":
            result = _lib.call_verb("api-account-standing-order", account_id, "list")
            _lib.respond("200 OK", result)
        if m != "POST":
            _lib.respond("405 Method Not Allowed", {"error": "use_get_or_post"})
        body = _lib.read_body()
        target = body.get("target", "")
        sat = body.get("sat")
        cadence = str(body.get("cadence", ""))
        if not isinstance(target, str) or not target:
            _lib.respond("400 Bad Request", {"error": "target_required"})
        if not isinstance(sat, int) or sat <= 0:
            _lib.respond("400 Bad Request", {"error": "sat_required"})
        if cadence not in ("daily", "weekly", "monthly"):
            _lib.respond("400 Bad Request", {"error": "bad_cadence"})
        result = _lib.call_verb("api-account-standing-order", account_id,
                                "create", target, str(sat), cadence)
        _lib.respond("201 Created", result)
    # Single-order operations.
    if not re.fullmatch(r"so_[0-9a-z]{1,32}", so_id):
        _lib.respond("400 Bad Request", {"error": "bad_order_id"})
    if m == "DELETE":
        result = _lib.call_verb("api-account-standing-order", account_id, "cancel", so_id)
        _lib.respond("200 OK", result)
    if m == "POST":
        body = _lib.read_body()
        action = str(body.get("action", ""))
        if action not in ("pause", "resume"):
            _lib.respond("400 Bad Request", {"error": "bad_action"})
        result = _lib.call_verb("api-account-standing-order", account_id, action, so_id)
        _lib.respond("200 OK", result)
    _lib.respond("405 Method Not Allowed", {"error": "use_post_or_delete"})


def _mandate_charge(account_id, mid):
    # FEAT-227 — merchant-triggered charge.  Authenticated by the
    # per-mandate secret (body `secret` or X-Mandate-Secret header), NOT
    # a customer bearer — this is the endpoint a cross-node merchant
    # POSTs to.  Maps the verb's auth/rule exit codes to 401/402.
    if _method() != "POST":
        _lib.respond("405 Method Not Allowed", {"error": "use_post"})
    body = _lib.read_body()
    secret = body.get("secret") or os.environ.get("HTTP_X_MANDATE_SECRET", "")
    sat = body.get("sat")
    ref = body.get("reference")
    if not isinstance(secret, str) or not secret:
        _lib.respond("401 Unauthorized", {"error": "missing_mandate_secret"})
    if not isinstance(sat, int) or sat <= 0:
        _lib.respond("400 Bad Request", {"error": "sat_required"})
    args = ["api-account-mandate-pull", account_id, "charge", mid, secret, str(sat)]
    if ref is not None:
        args += ["--ref", json.dumps(ref)]
    r = subprocess.run(
        ["sudo", "-n", "-u", _lib.OPERATOR_USER, "lightning", *args],
        capture_output=True, text=True,
    )
    if r.returncode == 7:
        _lib.respond("401 Unauthorized", {"error": "invalid_mandate_secret"})
    if r.returncode == 6:
        try:
            _lib.respond("402 Payment Required", json.loads(r.stdout or "{}"))
        except json.JSONDecodeError:
            _lib.respond("402 Payment Required", {"error": "rule_violation"})
    if r.returncode != 0:
        _lib.respond("502 Bad Gateway", {"error": "backend_failed"})
    try:
        _lib.respond("200 OK", json.loads(r.stdout))
    except json.JSONDecodeError:
        _lib.respond("502 Bad Gateway", {"error": "bad_json"})


def _mandates(account_id, tail):
    # tail[0] == "mandates".  Sub-shapes:
    #   mandates                      GET list / POST create   (customer bearer)
    #   mandates/<mid>                PATCH update / DELETE revoke (bearer)
    #   mandates/<mid>/charge         POST charge (mandate-secret authed)
    #   mandates/<mid>/pulls/<pid>/approve|deny  POST (bearer)
    if len(tail) == 1:
        _lib.auth_account(account_id)
        if _method() == "GET":
            _lib.respond("200 OK", _lib.call_verb("api-account-mandate", account_id, "list"))
        if _method() != "POST":
            _lib.respond("405 Method Not Allowed", {"error": "use_get_or_post"})
        body = _lib.read_body()
        merchant = body.get("merchant", "")
        maxp = body.get("max_per_period")
        period = str(body.get("period", ""))
        mode = str(body.get("mode", "auto"))
        if not isinstance(merchant, str) or not merchant:
            _lib.respond("400 Bad Request", {"error": "merchant_required"})
        if not isinstance(maxp, int) or maxp <= 0:
            _lib.respond("400 Bad Request", {"error": "max_per_period_required"})
        if period not in ("daily", "weekly", "monthly"):
            _lib.respond("400 Bad Request", {"error": "bad_period"})
        if mode not in ("auto", "approval"):
            _lib.respond("400 Bad Request", {"error": "bad_mode"})
        result = _lib.call_verb("api-account-mandate", account_id, "create",
                                merchant, str(maxp), period, "--mode", mode)
        _lib.respond("201 Created", result)

    mid = tail[1]
    if not re.fullmatch(r"mdt_[0-9a-z]{1,32}", mid):
        _lib.respond("400 Bad Request", {"error": "bad_mandate_id"})

    if len(tail) == 2:
        _lib.auth_account(account_id)
        if _method() == "DELETE":
            result = _lib.call_verb("api-account-mandate", account_id, "patch",
                                    mid, "--status", "revoked")
            _lib.respond("200 OK", result)
        if _method() != "PATCH":
            _lib.respond("405 Method Not Allowed", {"error": "use_patch_or_delete"})
        body = _lib.read_body()
        args = ["api-account-mandate", account_id, "patch", mid]
        mode = body.get("mode")
        status = body.get("status")
        if isinstance(mode, str) and mode:
            args += ["--mode", mode]
        if isinstance(status, str) and status:
            args += ["--status", status]
        _lib.respond("200 OK", _lib.call_verb(*args))

    if len(tail) == 3 and tail[2] == "charge":
        _mandate_charge(account_id, mid)

    if len(tail) == 3 and tail[2] == "pulls":
        # FEAT-231 — the customer's approval inbox: pending pulls.
        _lib.auth_account(account_id)
        if _method() != "GET":
            _lib.respond("405 Method Not Allowed", {"error": "use_get"})
        _lib.respond("200 OK", _lib.call_verb("api-account-mandate", account_id, "pulls", mid))

    if len(tail) == 5 and tail[2] == "pulls" and tail[4] in ("approve", "deny"):
        _lib.auth_account(account_id)
        if _method() != "POST":
            _lib.respond("405 Method Not Allowed", {"error": "use_post"})
        pid = tail[3]
        if not re.fullmatch(r"mpl_[0-9a-z]{1,32}", pid):
            _lib.respond("400 Bad Request", {"error": "bad_pull_id"})
        result = _lib.call_verb("api-account-mandate-pull", account_id, tail[4], mid, pid)
        _lib.respond("200 OK", result)

    _lib.respond("404 Not Found")


_CHARGE_ACTIONS = {
    "hold", "release", "authorize", "void", "dun", "pay-installment",
    "refund", "capture", "installments",
}


def _charges(account_id, tail):
    # FEAT-228 — commerce charge lifecycle.  Merchant-driven (the path
    # account is the merchant).  tail[0] == "charges".
    _lib.auth_account(account_id)
    m = _method()
    if len(tail) == 1:
        if m == "GET":
            _lib.respond("200 OK", _lib.call_verb("api-account-charge", account_id, "list"))
        if m != "POST":
            _lib.respond("405 Method Not Allowed", {"error": "use_get_or_post"})
        body = _lib.read_body()
        customer = body.get("customer", "")
        amount = body.get("amount_sat")
        if not isinstance(customer, str) or not customer:
            _lib.respond("400 Bad Request", {"error": "customer_required"})
        if not isinstance(amount, int) or amount <= 0:
            _lib.respond("400 Bad Request", {"error": "amount_required"})
        args = ["api-account-charge", account_id, "create", customer, str(amount)]
        if body.get("reference") is not None:
            args += ["--ref", json.dumps(body["reference"])]
        if body.get("terms") is not None:
            args += ["--terms", json.dumps(body["terms"])]
        due = body.get("due_days")
        if isinstance(due, int) and due >= 0:
            args += ["--due-days", str(due)]
        _lib.respond("201 Created", _lib.call_verb(*args))

    chg_id = tail[1]
    if not re.fullmatch(r"chg_[0-9a-z]{1,32}", chg_id):
        _lib.respond("400 Bad Request", {"error": "bad_charge_id"})

    if len(tail) == 2:
        if m != "GET":
            _lib.respond("405 Method Not Allowed", {"error": "use_get"})
        _lib.respond("200 OK", _lib.call_verb("api-account-charge", account_id, "show", chg_id))

    if len(tail) == 3:
        action = tail[2]
        if action not in _CHARGE_ACTIONS:
            _lib.respond("404 Not Found")
        if m != "POST":
            _lib.respond("405 Method Not Allowed", {"error": "use_post"})
        body = _lib.read_body()
        args = ["api-account-charge", account_id, action, chg_id]
        if action == "capture":
            sat = body.get("sat")
            if not isinstance(sat, int) or sat <= 0:
                _lib.respond("400 Bad Request", {"error": "sat_required"})
            args.append(str(sat))
        elif action == "installments":
            n = body.get("n")
            if not isinstance(n, int) or n < 2:
                _lib.respond("400 Bad Request", {"error": "n_required"})
            args.append(str(n))
        elif action == "refund":
            sat = body.get("sat")
            if isinstance(sat, int) and sat > 0:
                args += ["--sat", str(sat)]
        _lib.respond("200 OK", _lib.call_verb(*args))

    _lib.respond("404 Not Found")


def _export(account_id):
    # FEAT-230 — tax-data export.  GET .../export/tax-data?year=&base=&format=
    # Account-bearer authed.  Returns CSV or JSON (so it can't go through
    # _lib.call_verb, which assumes JSON) — we stream the verb's stdout
    # with the right Content-Type.
    if _method() != "GET":
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})
    _lib.auth_account(account_id)
    q = _query()
    year = q.get("year", [""])[0]
    if not year.isdigit() or len(year) != 4:
        _lib.respond("400 Bad Request", {"error": "year_required"})
    base = q.get("base", ["EUR"])[0]
    if not base.isalpha() or not (2 <= len(base) <= 5):
        _lib.respond("400 Bad Request", {"error": "bad_base"})
    fmt = q.get("format", ["json"])[0]
    if fmt not in ("csv", "json"):
        _lib.respond("400 Bad Request", {"error": "bad_format"})
    r = subprocess.run(
        ["sudo", "-n", "-u", _lib.OPERATOR_USER, "lightning", "export", "tax-data",
         account_id, "--year", year, "--base", base.upper(), "--format", fmt],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        _lib.respond("502 Bad Gateway", {"error": "backend_failed",
                                         "detail": r.stderr.strip()[:200]})
    ctype = "text/csv" if fmt == "csv" else "application/json"
    sys.stdout.write("Status: 200 OK\r\n")
    sys.stdout.write(f"Content-Type: {ctype}\r\n\r\n")
    sys.stdout.write(r.stdout)
    sys.stdout.flush()
    sys.exit(0)


def _apikey(account_id):
    # FEAT-249 — return the account's API key so the owner can copy it.
    if _method() != "GET":
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})
    _lib.auth_account(account_id)
    result = _lib.call_verb("api-account-apikey", account_id)
    _lib.respond("200 OK", result)


def _close(account_id):
    if _method() != "POST":
        _lib.respond("405 Method Not Allowed", {"error": "use_post"})
    _lib.auth_account(account_id)
    result = _lib.call_verb("api-account-close", account_id)
    _lib.respond("200 OK", result)


def _history(account_id, entry_id=None):
    # FEAT-246 — transaction history (ledger entries for the account).
    # FEAT-254 — PATCH .../history/<entry_id> updates the note.
    _lib.auth_account(account_id)
    if entry_id is not None:
        if not re.fullmatch(r"[0-9]+", entry_id):
            _lib.respond("400 Bad Request", {"error": "bad_entry_id"})
        if _method() != "PATCH":
            _lib.respond("405 Method Not Allowed", {"error": "use_patch"})
        body = _lib.read_body()
        note = body.get("note", "") if isinstance(body, dict) else ""
        result = _lib.call_verb("api-account-history-note", account_id, entry_id,
                                str(note)[:200])
        _lib.respond("200 OK", result)
    if _method() != "GET":
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})
    qs = _query()
    args = ["api-account-history", account_id]
    if "limit" in qs:
        args += ["--limit", qs["limit"][0]]
    if "before" in qs:
        args += ["--before", qs["before"][0]]
    result = _lib.call_verb(*args)
    _lib.respond("200 OK", result)


def _referrals(account_id):
    if _method() != "GET":
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})
    _lib.auth_account(account_id)
    result = _lib.call_verb("api-account-referrals", account_id)
    _lib.respond("200 OK", result)


def _invite_codes(account_id):
    # FEAT-220 — the account's invite codes for the PWA "Invite a friend"
    # screen (lazy-mints one if none exist).
    if _method() != "GET":
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})
    _lib.auth_account(account_id)
    result = _lib.call_verb("api-account-invite-codes", account_id)
    _lib.respond("200 OK", result)


def _invoice(account_id, payment_hash=None):
    # FEAT-225 — commercial invoice.  POST .../invoice mints a new one;
    # GET .../invoice/<payment_hash> looks one up + recomputes the
    # effective (Skonto/late-fee) amount.  Both are merchant-only.
    _lib.auth_account(account_id)
    if payment_hash is not None:
        if _method() != "GET":
            _lib.respond("405 Method Not Allowed", {"error": "use_get"})
        if not re.fullmatch(r"[0-9a-fA-F]{1,64}", payment_hash):
            _lib.respond("400 Bad Request", {"error": "bad_payment_hash"})
        result = _lib.call_verb("api-account-invoice-get", account_id, payment_hash)
        _lib.respond("200 OK", result)
    if _method() != "POST":
        _lib.respond("405 Method Not Allowed", {"error": "use_post"})
    body = _lib.read_body()
    sat = body.get("sat")
    if not isinstance(sat, int) or sat <= 0:
        _lib.respond("400 Bad Request", {"error": "sat_required"})
    args = ["api-account-invoice", account_id, str(sat)]
    ref = body.get("reference")
    terms = body.get("terms")
    if ref is not None:
        args += ["--ref", json.dumps(ref)]
    if terms is not None:
        args += ["--terms", json.dumps(terms)]
    result = _lib.call_verb(*args)
    _lib.respond("201 Created", result)


def main():
    path_info = os.environ.get("PATH_INFO", "")
    account_id, tail = _lib.read_account_id_from_path(path_info)

    if account_id is None:
        # No ID present — only the create endpoint is valid here.
        if not tail and not [p for p in path_info.split("/") if p]:
            _create()
        elif [p for p in path_info.split("/") if p] and not account_id:
            # Bad-shape ID (e.g. /Alice/balance) — 404 rather than 400
            # so we don't leak which account-ids exist.
            _lib.respond("404 Not Found")
        else:
            _create()
        return

    if not tail:
        _lib.respond("404 Not Found")

    verb = tail[0]
    if verb == "history" and len(tail) > 1:
        # PATCH .../history/<entry_id> updates the note.
        _history(account_id, tail[1])
        return
    if verb == "invoice":
        # POST .../invoice (create) or GET .../invoice/<payment_hash>.
        _invoice(account_id, tail[1] if len(tail) > 1 else None)
        return
    if verb == "standing-orders":
        _standing_orders(account_id, tail[1] if len(tail) > 1 else None)
        return
    if verb == "mandates":
        _mandates(account_id, tail)
        return
    if verb == "charges":
        _charges(account_id, tail)
        return
    if verb == "export":
        if len(tail) == 2 and tail[1] == "tax-data":
            _export(account_id)
        _lib.respond("404 Not Found")
        return
    routes = {
        "balance": lambda: _balance(account_id),
        "topup": lambda: _topup(account_id),
        "withdraw": lambda: _withdraw(account_id),
        "pay": lambda: _pay(account_id),
        "recv": lambda: _recv(account_id, reusable=False),
        "recv-reusable": lambda: _recv(account_id, reusable=True),
        "transfer": lambda: _transfer(account_id),
        "history": lambda: _history(account_id),
        "referrals": lambda: _referrals(account_id),
        "invite-codes": lambda: _invite_codes(account_id),
        "api-key": lambda: _apikey(account_id),
        "close": lambda: _close(account_id),
    }
    handler = routes.get(verb)
    if handler is None:
        _lib.respond("404 Not Found")
    handler()


main()
