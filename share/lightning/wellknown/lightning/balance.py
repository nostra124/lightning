#!/usr/bin/env python3
"""GET /.well-known/lightning/<user>/balance

Auth: X-API-Key (read or write scope)
Returns: {"balance_sat": N, "limit_sat": N, "overdraft": "deny"}
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import get_user, require_auth, run_lightning, json_response


def main():
    user = get_user()
    # Accept read OR write scope.
    key = os.environ.get("HTTP_X_API_KEY", "") or os.environ.get("X_API_KEY", "")
    if key:
        # Try read first, then write.
        out = run_lightning("api-verify", user, "read", key)
        if out != "ok":
            out = run_lightning("api-verify", user, "write", key)
        if out != "ok":
            json_response({"error": ""}, 401)
    else:
        json_response({"error": ""}, 401)

    # Get balance via api-balance facade.
    out = run_lightning("api-balance", user)
    balance_sat = 0
    limit_sat = None
    overdraft = "deny"

    for line in out.split("\n"):
        if "balance_sat:" in line:
            balance_sat = int(line.split(None, 1)[1])
        elif "limit_sat:" in line:
            limit_str = line.split(None, 1)[1]
            limit_sat = int(limit_str) if limit_str != "NULL" else None
        elif "overdraft:" in line:
            overdraft = line.split(None, 1)[1]

    result = {
        "balance_sat": balance_sat,
        "limit_sat": limit_sat,
        "overdraft": overdraft,
    }
    json_response(result)


if __name__ == "__main__":
    main()
