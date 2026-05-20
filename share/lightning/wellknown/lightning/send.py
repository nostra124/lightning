#!/usr/bin/env python3
"""POST /.well-known/lightning/<user>/send  (FEAT-196).

Body: {"to": "<addr>", "sat": <int>, "message": "<text>", "note": "<text>"}
Returns: {"payment_hash": "...", "fee_sat": <int>, "amount_sat": <int>}
"""

import re
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import _lib

ADDR_RE = re.compile(r"^[a-z0-9._-]+@[a-z0-9.-]+\.[a-z]{2,}$")

user = _lib.read_user()
_lib.auth(user, "write")
body = _lib.read_body()

to = body.get("to", "")
if not isinstance(to, str) or not ADDR_RE.match(to):
    _lib.respond("400 Bad Request", {"error": "to: Lightning Address required"})
sat = body.get("sat")
if not isinstance(sat, int) or sat <= 0:
    _lib.respond("400 Bad Request", {"error": "sat: positive integer required"})
message = body.get("message", "") or ""
note    = body.get("note", "")    or ""
for k, v in (("message", message), ("note", note)):
    if not isinstance(v, str) or len(v) > 256:
        _lib.respond("400 Bad Request", {"error": f"{k}: string ≤ 256 bytes"})

result = _lib.call_verb("api-send", user, to, str(sat), message, note)
_lib.respond("200 OK", result)
