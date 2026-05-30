#!/usr/bin/env python3
"""GET /.well-known/lightning/v1/node  (FEAT-252).

Public — no auth.  Returns a subset of lightning-cli getinfo:
  {pubkey, alias, num_channels, local_msat}
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lightning"))
import _lib  # noqa: E402


def main():
    if os.environ.get("REQUEST_METHOD", "GET").upper() != "GET":
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})
    result = _lib.call_verb("api-node-info")
    _lib.respond("200 OK", result)


main()
