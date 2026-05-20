#!/usr/bin/env python3
"""GET /.well-known/lightning/<user>/balance  (FEAT-196).

Returns: {"balance_sat": <int>, "limit_sat": <int|null>,
          "overdraft": "deny"|"warn"|"allow"}
"""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import _lib

user = _lib.read_user()
_lib.auth(user, "read")
result = _lib.call_verb("api-balance", user)
_lib.respond("200 OK", result)
