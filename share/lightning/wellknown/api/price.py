#!/usr/bin/env python3
"""GET /.well-known/lightning/v1/price?base=EUR  (FEAT-229).

Public — no auth.  Thin wrapper over `lightning price now --base
<CUR>`; returns the latest stored tick as JSON.  "No price yet" is
a 200 with an error field (not a 5xx) so a polling client can
distinguish "feed not configured / no data" from a server fault.
"""

import os
import sys
import json
import subprocess
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lightning"))
import _lib  # noqa: E402


def main():
    if os.environ.get("REQUEST_METHOD", "GET").upper() != "GET":
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})
    q = urllib.parse.parse_qs(os.environ.get("QUERY_STRING", ""))
    base = q.get("base", ["EUR"])[0]
    if not base.isalpha() or not (2 <= len(base) <= 5):
        _lib.respond("400 Bad Request", {"error": "bad_base"})
    base = base.upper()

    r = subprocess.run(
        ["sudo", "-n", "-u", _lib.OPERATOR_USER, "lightning",
         "price", "now", "--base", base],
        capture_output=True, text=True,
    )
    # `price now` prints a JSON tick on stdout (or a no_price_data
    # error object + exit 4).  Either way the stdout is the JSON we
    # want; only a totally-empty/garbage stdout is a real fault.
    out = (r.stdout or "").strip()
    try:
        payload = json.loads(out) if out else {"error": "no_price_data", "base": base}
    except json.JSONDecodeError:
        _lib.respond("502 Bad Gateway", {"error": "bad_json"})
        return
    _lib.respond("200 OK", payload)


main()
