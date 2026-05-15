#!/usr/bin/env python3
"""POST /.well-known/lightning/<user>/recv

Body: {"sat": 1000, "message": "invoice for consulting"}
Auth: X-API-Key (write scope)
Returns: {"bolt11": "lnbc...", "payment_hash": "..."}
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

    sat = payload.get("sat", 0)
    message = payload.get("message", f"invoice for {user}")

    if not sat:
        error_response(400, "missing 'sat'")

    label = f"api-{user}-{os.urandom(4).hex()}"
    inv_args = [str(sat), label, "--description", message, "--account", user]

    out = run_lightning("invoice", *inv_args)
    if not out:
        error_response(502, "failed to create invoice")

    bolt11 = out.split("\n")[0]
    payment_hash = ""
    for line in out.split("\n"):
        if "payment_hash:" in line:
            payment_hash = line.split(None, 1)[1]

    result = {
        "bolt11": bolt11,
        "payment_hash": payment_hash or "unknown",
    }
    json_response(result)


if __name__ == "__main__":
    main()
