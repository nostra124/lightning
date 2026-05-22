#!/usr/bin/env python3
"""Dispatcher for /api/accounts/* (FEAT-212 PR-2).

Apache CGI maps the entire /api/accounts/* URL tree to this single
script.  The script parses PATH_INFO + REQUEST_METHOD and routes:

  POST /api/accounts                     -> create (anonymous)
  GET  /api/accounts/<id>/balance        -> balance
  GET  /api/accounts/<id>/topup[?sat=N]  -> topup
  POST /api/accounts/<id>/withdraw       -> withdraw
  POST /api/accounts/<id>/pay            -> pay
  POST /api/accounts/<id>/recv           -> recv
  POST /api/accounts/<id>/recv-reusable  -> recv-reusable (BOLT-12)
  POST /api/accounts/<id>/close          -> close

All authenticated endpoints require Authorization: Bearer <key>.
Create is anonymous + rate-limited at the verb layer.
"""

import os
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
    args = ["api-accounts-create"]
    if hint:
        args += ["--hint", hint]
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
    routes = {
        "balance": lambda: _balance(account_id),
        "topup": lambda: _topup(account_id),
        "withdraw": lambda: _withdraw(account_id),
        "pay": lambda: _pay(account_id),
        "recv": lambda: _recv(account_id, reusable=False),
        "recv-reusable": lambda: _recv(account_id, reusable=True),
        "close": lambda: _close(account_id),
    }
    handler = routes.get(verb)
    if handler is None:
        _lib.respond("404 Not Found")
    handler()


main()
