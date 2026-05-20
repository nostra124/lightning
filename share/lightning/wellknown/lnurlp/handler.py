#!/usr/bin/env python3
"""LNURL-pay CGI handler for Lightning Addresses (FEAT-176).

Invoked by Apache at /.well-known/lnurlp/<user>.
Returns LUD-06 / LUD-12 JSON.
"""

import json
import os
import subprocess
import sys
import urllib.parse
from pathlib import Path

LIGHTNING_BIN = os.environ.get("LIGHTNING_BIN", "/usr/local/bin/lightning")
ALICE_USER = os.environ.get("ALICE_USER", "alice")
SUDO = os.environ.get("SUDO_CMD", "sudo")


def run_lightning(*args):
    """Shell out to `lightning` via the privileged hop."""
    cmd = [SUDO, "-u", ALICE_USER, LIGHTNING_BIN] + list(args)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        sys.stderr.write(f"lightning error: {r.stderr}\n")
        return None
    return r.stdout.strip()


def get_user_info(user: str) -> dict | None:
    """Query the users table via `lightning api-lnurlp`."""
    out = run_lightning("api-lnurlp", user)
    if not out:
        return None
    # api-lnurlp returns TSV: user, account, min_sat, max_sat, comment_max
    parts = out.split("\t")
    if len(parts) < 5:
        return None
    return {
        "user": parts[0],
        "account": parts[1],
        "min_sat": int(parts[2]),
        "max_sat": int(parts[3]),
        "comment_max": int(parts[4]),
    }


def main():
    path_info = os.environ.get("PATH_INFO", "").strip("/")
    query_string = os.environ.get("QUERY_STRING", "")
    user = path_info.split("/")[0] if path_info else ""

    if not user:
        print("Status: 400 Bad Request")
        print("Content-Type: text/plain")
        print()
        print("missing user in PATH_INFO")
        return

    info = get_user_info(user)
    if not info:
        print("Status: 404 Not Found")
        print("Content-Type: text/plain")
        print()
        print(f"user '{user}' not found")
        return

    # Parse query string.
    params = urllib.parse.parse_qs(query_string)
    amount_msat = params.get("amount", [None])[0]

    metadata = json.dumps([
        ["text/plain", f"Payment to {user}"],
        ["text/identifier", f"{user}@{os.environ.get('SERVER_NAME', 'localhost')}"],
    ])

    if amount_msat is None:
        # LUD-06 discovery response.
        cb_url = f"https://{os.environ.get('SERVER_NAME', 'localhost')}/.well-known/lnurlp/{user}"
        resp = {
            "callback": cb_url,
            "minSendable": info["min_sat"] * 1000,
            "maxSendable": info["max_sat"] * 1000,
            "metadata": metadata,
            "tag": "payRequest",
            "commentAllowed": info["comment_max"],
        }
        print("Content-Type: application/json")
        print()
        print(json.dumps(resp, indent=2))
        return

    # LUD-12: amount provided → mint invoice.
    try:
        msat_val = int(amount_msat)
    except ValueError:
        print("Status: 400 Bad Request")
        print("Content-Type: text/plain")
        print()
        print("invalid amount")
        return

    sat_val = msat_val // 1000
    comment = params.get("comment", [None])[0]
    label = f"lnurlp-{user}-{os.urandom(4).hex()}"

    invoice_args = [str(sat_val), label, "--account", info["account"]]
    if comment:
        invoice_args += ["--description", comment[:info["comment_max"]]]

    bolt11 = run_lightning("invoice", *invoice_args)
    if not bolt11:
        print("Status: 502 Bad Gateway")
        print("Content-Type: text/plain")
        print()
        print("failed to mint invoice")
        return

    resp = {
        "pr": bolt11.split("\n")[0],
        "routes": [],
    }
    print("Content-Type: application/json")
    print()
    print(json.dumps(resp))


if __name__ == "__main__":
    main()
