#!/usr/bin/env python3
"""GET /.well-known/lightning/v1/health  (FEAT-284).

Public — no auth.  Returns the node health snapshot.
HTTP 200 when ok=true, HTTP 503 when ok=false or daemon unreachable.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lightning"))
import _lib  # noqa: E402


def main():
    if os.environ.get("REQUEST_METHOD", "GET").upper() != "GET":
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})

    r = subprocess.run(
        ["sudo", "-n", "-u", _lib.OPERATOR_USER, "lightning", "api-node-health"],
        capture_output=True, text=True,
    )
    try:
        payload = json.loads(r.stdout) if r.stdout else {}
    except json.JSONDecodeError:
        payload = {"ok": False, "error": "bad_json"}

    ok = isinstance(payload, dict) and payload.get("ok", False)
    _lib.respond("200 OK" if ok else "503 Service Unavailable", payload)


main()
