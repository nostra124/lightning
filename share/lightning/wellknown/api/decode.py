#!/usr/bin/env python3
"""GET /.well-known/lightning/v1/decode?invoice=<bolt11>  (FEAT-262).

Public — no auth.  Decodes a BOLT-11 invoice via invoice-decode verb.
"""

import os
import sys
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lightning"))
import _lib  # noqa: E402


def main():
    if os.environ.get("REQUEST_METHOD", "GET").upper() != "GET":
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})
    q = urllib.parse.parse_qs(os.environ.get("QUERY_STRING", ""))
    invoice = q.get("invoice", [""])[0].strip()
    if not invoice:
        _lib.respond("400 Bad Request", {"error": "invoice_required"})
    result = _lib.call_verb("invoice-decode", invoice)
    _lib.respond("200 OK", result)


main()
