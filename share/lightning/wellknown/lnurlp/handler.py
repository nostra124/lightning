#!/usr/bin/env python3
"""GET /.well-known/lnurlp/<user>  (FEAT-176).

Two modes per LUD-06:
  - no `amount` query param  → return discovery metadata
  - `amount=<msat>` (+ optional `comment=<text>`) → return the
    callback JSON containing a freshly-minted BOLT-11.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.parse

OPERATOR_USER = os.environ.get("LIGHTNING_OPERATOR_USER", "alice")
USER_RE = re.compile(r"^[a-z][a-z0-9_-]*$")


def respond(status, body=None):
    sys.stdout.write(f"Status: {status}\r\n")
    sys.stdout.write("Content-Type: application/json\r\n")
    sys.stdout.write("\r\n")
    if body is not None:
        sys.stdout.write(json.dumps(body))
    sys.exit(0)


def domain():
    return os.environ.get("HTTP_HOST", "example.com").split(":")[0]


def user_from_path():
    path = os.environ.get("PATH_INFO", "")
    parts = [p for p in path.split("/") if p]
    if not parts or not USER_RE.match(parts[0]):
        respond("404 Not Found")
    return parts[0]


def call(*args):
    """Shell into `sudo -u <operator> lightning api-<verb> <args>`."""
    r = subprocess.run(
        ["sudo", "-n", "-u", OPERATOR_USER, "lightning", *args],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        respond("502 Bad Gateway", {"error": "backend_failed",
                                    "detail": r.stderr.strip()[:200]})
    return r.stdout.strip()


user = user_from_path()
qs = urllib.parse.parse_qs(os.environ.get("QUERY_STRING", ""))
amount = qs.get("amount", [None])[0]
comment = qs.get("comment", [""])[0]

# LUD-06 metadata is a JSON-encoded list of [type, value] pairs that the
# receiver commits to in the invoice's description hash.
metadata = json.dumps([
    ["text/identifier", f"{user}@{domain()}"],
    ["text/plain",      f"Pay to {user}@{domain()}"],
])
callback = f"https://{domain()}/.well-known/lnurlp/{user}"

if amount is None:
    respond("200 OK", {
        "callback":       callback,
        "maxSendable":    100_000_000_000,
        "minSendable":    1_000,
        "metadata":       metadata,
        "commentAllowed": 256,
        "tag":            "payRequest",
    })

try:
    msat = int(amount)
except (TypeError, ValueError):
    respond("400 Bad Request", {"status": "ERROR", "reason": "bad amount"})

sat = msat // 1000
if sat <= 0:
    respond("400 Bad Request", {"status": "ERROR", "reason": "amount must be > 0"})

# Mint via the sudo bridge. The bridge handles the SQLite insert.
out = call("api-recv", user, str(sat), comment)
try:
    data = json.loads(out)
except json.JSONDecodeError:
    respond("502 Bad Gateway", {"status": "ERROR", "reason": "bad_json"})

respond("200 OK", {
    "pr":       data["bolt11"],
    "routes":   [],
    "disposable": False,
    "successAction": {"tag": "message", "message": "thanks"},
})
