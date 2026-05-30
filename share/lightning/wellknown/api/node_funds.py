#!/usr/bin/env python3
"""GET /.well-known/lightning/v1/node-funds  (FEAT-265).

Bearer-required (any valid account key).  Returns node on-chain +
channel funds from api-node-funds → node-funds verb.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lightning"))
import _lib  # noqa: E402


def main():
    if os.environ.get("REQUEST_METHOD", "GET").upper() != "GET":
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})
    _lib.read_bearer()
    result = _lib.call_verb("node-funds")
    _lib.respond("200 OK", result)


main()
