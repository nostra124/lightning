"""Shared helpers for the .well-known/lightning/ CGI endpoints (FEAT-196).

Usage:
    from _lib import get_user, require_auth, run_lightning, json_response, error_response

Each endpoint script calls get_user() then require_auth() then its own
business logic. All < 100 lines per endpoint.
"""

import json
import os
import subprocess
import sys

LIGHTNING_BIN = os.environ.get("LIGHTNING_BIN", "/usr/local/bin/lightning")
ALICE_USER = os.environ.get("ALICE_USER", "alice")
SUDO_CMD = os.environ.get("SUDO_CMD", "sudo")


def get_user() -> str:
    """Extract <user> from PATH_INFO. Exit with 400 if missing/invalid."""
    path_info = os.environ.get("PATH_INFO", "").strip("/")
    user = path_info.split("/")[0] if path_info else ""
    if not user or not user.isascii() or not user.islower():
        error_response(400, "invalid user")
    return user


def require_auth(user: str, required_scope: str = "write") -> str:
    """Validate X-API-Key from HTTP headers.

    Returns the API key on success. Exits with 401 on failure.
    Oracle-resistant: no body details on wrong/missing key.
    """
    key = os.environ.get("HTTP_X_API_KEY", "")
    if not key:
        key = os.environ.get("X_API_KEY", "")

    if not key:
        error_response(401, "")

    out = run_lightning("api-verify", user, required_scope, key)
    if out != "ok":
        error_response(401, "")
    return key


def run_lightning(*args: str) -> str:
    """Shell out to `lightning` via sudo-to-alice. Returns stdout on success."""
    cmd = [SUDO_CMD, "-u", ALICE_USER, LIGHTNING_BIN] + list(args)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        error_response(502, "backend timeout")
    if r.returncode != 0:
        sys.stderr.write(f"lightning error (code {r.returncode}): {r.stderr}\n")
        error_response(502, "")
    return r.stdout.strip()


def json_response(data: dict, status: int = 200):
    """Print an HTTP JSON response and exit."""
    print(f"Status: {status}")
    print("Content-Type: application/json")
    print()
    print(json.dumps(data, indent=2))
    sys.exit(0)


def error_response(status: int, msg: str):
    """Print an HTTP error response and exit."""
    body = json.dumps({"error": msg}) if msg else ""
    print(f"Status: {status}")
    print("Content-Type: application/json")
    print()
    if body:
        print(body)
    sys.exit(0)
