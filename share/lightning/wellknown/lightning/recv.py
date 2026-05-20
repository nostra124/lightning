#!/usr/bin/env python3
"""POST /.well-known/lightning/<user>/recv  (FEAT-196).

Body: {"sat": <int>, "message": "<text>"}
Returns: {"bolt11": "...", "payment_hash": "...", "amount_sat": <int>}
"""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import _lib

user = _lib.read_user()
_lib.auth(user, "write")
body = _lib.read_body()

sat = body.get("sat")
if not isinstance(sat, int) or sat <= 0:
    _lib.respond("400 Bad Request", {"error": "sat: positive integer required"})
message = body.get("message", "") or ""
if not isinstance(message, str) or len(message) > 256:
    _lib.respond("400 Bad Request", {"error": "message: string ≤ 256 bytes"})

result = _lib.call_verb("api-recv", user, str(sat), message)
_lib.respond("200 OK", result)
