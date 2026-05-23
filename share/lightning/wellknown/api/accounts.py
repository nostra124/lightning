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
  POST .../v1/accounts/<id>/invoice        -> commercial invoice (FEAT-225)
  GET  .../v1/accounts/<id>/invoice/<hash> -> invoice lookup    (FEAT-225)
  POST .../v1/accounts/<id>/close          -> close

All authenticated endpoints require Authorization: Bearer <key>.
Create is anonymous + rate-limited at the verb layer.
"""

import json
import os
import re
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
    args = ["api-account-pay", account_id, target]
    if isinstance(sat, int) and sat > 0:
        args += ["--sat", str(sat)]
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


def _close(account_id):
    if _method() != "POST":
        _lib.respond("405 Method Not Allowed", {"error": "use_post"})
    _lib.auth_account(account_id)
    result = _lib.call_verb("api-account-close", account_id)
    _lib.respond("200 OK", result)


def _referrals(account_id):
    if _method() != "GET":
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})
    _lib.auth_account(account_id)
    result = _lib.call_verb("api-account-referrals", account_id)
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
    if verb == "invoice":
        # POST .../invoice (create) or GET .../invoice/<payment_hash>.
        _invoice(account_id, tail[1] if len(tail) > 1 else None)
        return
    routes = {
        "balance": lambda: _balance(account_id),
        "topup": lambda: _topup(account_id),
        "withdraw": lambda: _withdraw(account_id),
        "pay": lambda: _pay(account_id),
        "recv": lambda: _recv(account_id, reusable=False),
        "recv-reusable": lambda: _recv(account_id, reusable=True),
        "transfer": lambda: _transfer(account_id),
        "referrals": lambda: _referrals(account_id),
        "close": lambda: _close(account_id),
    }
    handler = routes.get(verb)
    if handler is None:
        _lib.respond("404 Not Found")
    handler()


main()
