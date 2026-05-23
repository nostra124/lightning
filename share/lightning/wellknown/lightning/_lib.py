"""Shared helpers for the .well-known/lightning/ CGI endpoints (FEAT-196).

Endpoint scripts call into this module for: PATH_INFO parsing,
X-API-Key validation, sudo-bridge invocation. They don't reach
across each other.
"""

import json
import os
import re
import subprocess
import sys

OPERATOR_USER = os.environ.get("LIGHTNING_OPERATOR_USER", "alice")
USER_RE = re.compile(r"^[a-z][a-z0-9_-]*$")
# FEAT-212 — bitcoin address shapes used as account IDs.  Bech32 only;
# we don't accept legacy base58 (the wallet always mints bech32 via
# `newaddr`).  Length: bech32 mainnet/testnet/regtest addresses run
# 14–90 chars per BIP-173; we cap at 90 to avoid pathological inputs.
ACCOUNT_ID_RE = re.compile(r"^(bc1|tb1|bcrt1)[0-9a-z]{10,87}$")


def respond(status, body=None):
    """Write a complete CGI response and exit."""
    sys.stdout.write(f"Status: {status}\r\n")
    sys.stdout.write("Content-Type: application/json\r\n")
    sys.stdout.write("\r\n")
    if body is not None:
        sys.stdout.write(json.dumps(body))
    sys.stdout.flush()
    sys.exit(0)


def read_user():
    """<user> arrives via LIGHTNING_API_USER (set by Apache mod_setenvif)
    or as the basename of PATH_INFO. We accept both."""
    u = os.environ.get("LIGHTNING_API_USER")
    if not u:
        # PATH_INFO: /alice/send -> "alice"
        path = os.environ.get("PATH_INFO", "")
        parts = [p for p in path.split("/") if p]
        if parts:
            u = parts[0]
    if not u or not USER_RE.match(u):
        respond("404 Not Found")
    return u


def read_apikey():
    """Apache passes headers as HTTP_X_API_KEY."""
    key = os.environ.get("HTTP_X_API_KEY", "")
    if not key:
        respond("401 Unauthorized")
    return key


def auth(user, scope):
    """Verify the X-API-Key via sudo-to-operator. The scope is the role
    expected; for `balance` we accept either `read` or `write`."""
    key = read_apikey()
    if scope == "read":
        if _verify(user, "read", key) or _verify(user, "write", key):
            return
    else:
        if _verify(user, scope, key):
            return
    respond("401 Unauthorized")


def _verify(account, scope, key):
    """Returns True on match. Wraps `lightning api-verify`."""
    rc = subprocess.run(
        ["sudo", "-n", "-u", OPERATOR_USER, "lightning", "api-verify",
         account, scope, key],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode
    return rc == 0


def call_verb(verb, *args):
    """Shell out to `sudo -u <operator> lightning api-<verb> <args>`.
    Returns the parsed JSON output or raises with a 5xx body."""
    r = subprocess.run(
        ["sudo", "-n", "-u", OPERATOR_USER, "lightning", verb, *args],
        capture_output=True, text=True,
    )
    if r.returncode == 6:
        # Soft business-rule failure (overdraft, limit) — body is JSON.
        try:
            respond("402 Payment Required", json.loads(r.stdout or "{}"))
        except json.JSONDecodeError:
            respond("402 Payment Required", {"error": "rule_violation"})
    if r.returncode != 0:
        respond("502 Bad Gateway", {"error": "backend_failed",
                                    "verb": verb,
                                    "detail": r.stderr.strip()[:200]})
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        respond("502 Bad Gateway", {"error": "bad_json"})


def read_body():
    """Parse the JSON request body (POST). Returns {} for empty bodies."""
    try:
        n = int(os.environ.get("CONTENT_LENGTH", "0") or "0")
    except ValueError:
        n = 0
    if n <= 0:
        return {}
    try:
        return json.loads(sys.stdin.read(n))
    except json.JSONDecodeError:
        respond("400 Bad Request", {"error": "bad_json"})


# --- FEAT-212 helpers ------------------------------------------------------

def read_account_id_from_path(path_info):
    """Pull the account-ID (bech32 bitcoin address) out of a PATH_INFO.

    Apache routes /.well-known/lightning/v1/accounts/<id>/<verb> here
    with PATH_INFO set to "/<id>/<verb>" (or "/<id>" / "" for the bare
    create case).  The versioned prefix is consumed by the ScriptAlias.
    """
    parts = [p for p in path_info.split("/") if p]
    if not parts:
        return None, []
    head, tail = parts[0], parts[1:]
    if not ACCOUNT_ID_RE.match(head):
        return None, []
    return head, tail


def read_bearer():
    """FEAT-212 — bearer-token auth.

    Apache passes the Authorization header as HTTP_AUTHORIZATION (the
    canonical CGI mapping; mod_setenvif strips the scheme on some
    setups, so we cope with both `Bearer xxx` and a raw token).
    Returns the token or aborts with 401.
    """
    raw = os.environ.get("HTTP_AUTHORIZATION", "").strip()
    if not raw:
        respond("401 Unauthorized", {"error": "missing_bearer"})
    if raw.lower().startswith("bearer "):
        token = raw[7:].strip()
    else:
        token = raw
    if not token:
        respond("401 Unauthorized", {"error": "missing_bearer"})
    return token


def auth_account(account_id):
    """Verify the request's bearer token against the API key stored
    server-side for `account_id`. Aborts with 401 on mismatch."""
    token = read_bearer()
    rc = subprocess.run(
        ["sudo", "-n", "-u", OPERATOR_USER, "lightning", "api-account-verify",
         account_id, token],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode
    if rc != 0:
        respond("401 Unauthorized", {"error": "invalid_bearer"})
