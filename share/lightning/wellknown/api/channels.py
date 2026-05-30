#!/usr/bin/env python3
"""GET /.well-known/lightning/v1/channels  (FEAT-257).

Bearer-required (any valid account key proves the caller is a wallet
user on this node).  Returns channel list from api-channel-list.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lightning"))
import _lib  # noqa: E402


def main():
    if os.environ.get("REQUEST_METHOD", "GET").upper() != "GET":
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})
    _lib.read_bearer()  # aborts with 401 if missing
    result = _lib.call_verb("api-channel-list")
    _lib.respond("200 OK", result)


main()
