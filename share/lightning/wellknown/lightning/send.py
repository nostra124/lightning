#!/usr/bin/env python3
"""POST /.well-known/lightning/<user>/send

Body: {"to": "user@domain", "sat": 500, "message": "...", "note": "..."}
Auth: X-API-Key (write scope)
Returns: {"payment_hash": "...", "fee_sat": N, "preimage": "..."}
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import get_user, require_auth, run_lightning, json_response, error_response


def main():
    user = get_user()
    require_auth(user, "write")

    content_length = int(os.environ.get("CONTENT_LENGTH", 0))
    body = sys.stdin.read(content_length) if content_length > 0 else ""
    if not body:
        error_response(400, "empty request body")

    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        error_response(400, "invalid JSON")

    to_addr = payload.get("to", "")
    sat = payload.get("sat", 0)
    message = payload.get("message", "")
    note = payload.get("note", "")

    if not to_addr or not sat:
        error_response(400, "missing 'to' or 'sat'")

    # Use lightning address pay.
    addr_args = ["address", "pay", to_addr, str(sat)]
    if message:
        addr_args += ["--comment", message]
    addr_args += ["--account", user]

    out = run_lightning(*addr_args)
    if not out:
        error_response(502, "payment failed")

    # Parse output for payment_hash and fee.
    ph = ""
    fee = 0
    for line in out.split("\n"):
        if line.startswith("payment_hash:"):
            ph = line.split(None, 1)[1]
        elif line.startswith("fee_sat:"):
            fee = int(line.split(None, 1)[1])

    result = {
        "payment_hash": ph or "unknown",
        "fee_sat": fee,
    }
    json_response(result)


if __name__ == "__main__":
    main()
