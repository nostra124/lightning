#!/usr/bin/env python3
"""FEAT-222 PR-3b + PR-4 — user-layer passkey + session HTTP API.

Apache mounts this at /.well-known/lightning/v1/users/ via ScriptAlias;
PATH_INFO arrives as /<user_id>/<rest>.

Routes (PR-3b passkey endpoints + PR-4 user CRUD / owned-account API):

  POST   /register/begin                  anonymous — mint provisional user_id + challenge
  POST   /                                anonymous — finish registration (passkey + invite)
  GET    /<id>                            session auth — user profile
  GET    /<id>/accounts                   session auth — list owned accounts
  POST   /<id>/accounts                   session auth — create owned account
  GET    /<id>/accounts/<acct>/api-key    session auth — retrieve account API key
  POST   /<id>/session/refresh            session auth — refresh session token

  POST   /<id>/passkeys/register/begin    session auth (enroll ANOTHER
                                          device; the first passkey
                                          arrives via POST /api/users).
  POST   /<id>/passkeys/register/finish   session auth.
  POST   /<id>/passkeys/login/begin       no auth.
  POST   /<id>/passkeys/login/finish      no auth -> mints + returns a
                                          session token.
  GET    /<id>/passkeys                   session auth (list).
  DELETE /<id>/passkeys/<cred_id>         session auth (revoke).

All crypto is in the `_webauthn-verify` helper (PR-3a); session tokens
are minted + verified by `_session-token`.  This script does CGI
plumbing + routing + auth gating only.

The Relying-Party config (RP-ID, RP-name, expected origin) comes from
operator-set env vars on the vhost.  WebAuthn requires a stable RP-ID
and a strict origin check, so these can't be guessed — surface them
explicitly.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lightning"))
import _lib  # noqa: E402

# usr_<16 base32-lowercase chars> (FEAT-222 PR-2; alphabet matches FEAT-218).
USER_ID_RE = re.compile(r"^usr_[a-z0-9]{16}$")
# base64url credential id; cap length to avoid pathological inputs.
CRED_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,512}$")

OPERATOR = _lib.OPERATOR_USER
RP_ID = os.environ.get("LIGHTNING_RP_ID", "")
RP_NAME = os.environ.get("LIGHTNING_RP_NAME", "Lightning Wallet")
EXPECTED_ORIGIN = os.environ.get("LIGHTNING_RP_ORIGIN", "")


def _safe_json(s):
    if not s:
        return None
    try:
        return json.loads(s)
    except Exception:
        return None


def _run(args, stdin=None, parse_json=True):
    """Run `sudo -n -u <op> lightning <args>`; map exit codes to HTTP."""
    r = subprocess.run(
        ["sudo", "-n", "-u", OPERATOR, "lightning", *args],
        input=stdin, capture_output=True, text=True,
    )
    # Map helper exits (see _webauthn-verify / _session-token docstrings)
    # to the appropriate HTTP status.
    rc = r.returncode
    if rc == 4:
        _lib.respond("404 Not Found",
                     _safe_json(r.stderr) or {"error": "not_found"})
    if rc == 6:
        _lib.respond("400 Bad Request",
                     _safe_json(r.stderr) or {"error": "verification_failed"})
    if rc == 7:
        _lib.respond("401 Unauthorized",
                     _safe_json(r.stderr) or {"error": "challenge_invalid_or_expired"})
    if rc == 127:
        _lib.respond("503 Service Unavailable",
                     _safe_json(r.stderr) or {"error": "missing_dependency"})
    if rc != 0:
        _lib.respond("502 Bad Gateway",
                     {"error": "backend_failed",
                      "detail": (r.stderr or "").strip()[:200]})
    if not parse_json:
        return r.stdout
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        _lib.respond("502 Bad Gateway", {"error": "bad_json"})


def auth_user(user_id):
    """Verify the bearer is a valid `_session-token` for `user_id`."""
    token = _lib.read_bearer()
    r = subprocess.run(
        ["sudo", "-n", "-u", OPERATOR, "lightning",
         "_session-token", "verify", "--token", token],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        _lib.respond("401 Unauthorized",
                     {"error": "invalid_or_expired_session"})
    payload = _safe_json(r.stdout)
    if not payload:
        _lib.respond("401 Unauthorized", {"error": "invalid_session"})
    if payload.get("user_id") != user_id:
        _lib.respond("403 Forbidden", {"error": "session_user_mismatch"})


def _require_rp_config():
    """RP-ID + origin must be set on the vhost — refuse politely otherwise."""
    if not RP_ID or not EXPECTED_ORIGIN:
        _lib.respond("503 Service Unavailable",
                     {"error": "rp_not_configured",
                      "detail": "LIGHTNING_RP_ID + LIGHTNING_RP_ORIGIN "
                                "must be set in the Apache vhost"})


# --- endpoint handlers ---

def passkey_register_begin(uid):
    auth_user(uid)
    _require_rp_config()
    out = _run(["_webauthn-verify", "register-begin",
                "--user-id", uid,
                "--rp-id", RP_ID,
                "--rp-name", RP_NAME])
    _lib.respond("200 OK", out)


def passkey_register_finish(uid):
    auth_user(uid)
    _require_rp_config()
    body = _lib.read_body()
    out = _run(["_webauthn-verify", "register-finish",
                "--user-id", uid,
                "--rp-id", RP_ID,
                "--expected-origin", EXPECTED_ORIGIN],
               stdin=json.dumps(body))
    _lib.respond("201 Created", out)


def passkey_login_begin(uid):
    _require_rp_config()
    out = _run(["_webauthn-verify", "login-begin",
                "--user-id", uid,
                "--rp-id", RP_ID])
    _lib.respond("200 OK", out)


def passkey_login_finish(uid):
    _require_rp_config()
    body = _lib.read_body()
    out = _run(["_webauthn-verify", "login-finish",
                "--user-id", uid,
                "--rp-id", RP_ID,
                "--expected-origin", EXPECTED_ORIGIN],
               stdin=json.dumps(body))
    # Mint a session on successful login — the PWA needs it for
    # subsequent session-authed calls.
    sess = _run(["_session-token", "mint", "--user-id", uid],
                parse_json=False).strip()
    out["session"] = sess
    _lib.respond("200 OK", out)


def passkey_list(uid):
    auth_user(uid)
    tsv = _run(["_webauthn-verify", "list", "--user-id", uid],
               parse_json=False)
    lines = [ln for ln in tsv.strip().split("\n") if ln]
    if not lines:
        _lib.respond("200 OK", {"passkeys": []})
    header = lines[0].split("\t")
    items = [dict(zip(header, ln.split("\t"))) for ln in lines[1:]]
    _lib.respond("200 OK", {"passkeys": items})


def passkey_delete(uid, cred_id):
    auth_user(uid)
    if not CRED_ID_RE.match(cred_id):
        _lib.respond("400 Bad Request", {"error": "bad_credential_id"})
    out = _run(["_webauthn-verify", "revoke",
                "--credential-id", cred_id,
                "--user-id", uid])
    _lib.respond("200 OK", out)


# --- PR-4 endpoint handlers ---

def register_begin():
    """Anonymous — mint a provisional user_id + issue a WebAuthn challenge."""
    _require_rp_config()
    import secrets as _secrets
    import base64 as _b64
    # Generate a provisional user_id (usr_<16 lowercase alnum>).
    alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    suffix = "".join(_secrets.choice(alphabet) for _ in range(16))
    user_id = f"usr_{suffix}"
    out = _run(["_webauthn-verify", "register-begin",
                "--user-id", user_id,
                "--rp-id", RP_ID,
                "--rp-name", RP_NAME])
    out["user_id"] = user_id
    _lib.respond("200 OK", out)


def user_register_finish():
    """Anonymous — finish registration: validate invite, create user, register passkey, mint session."""
    body = _lib.read_body()
    user_id = body.get("user_id", "")
    invite_code = body.get("invite_code", "")
    passkey_attestation = body.get("passkey_attestation")
    label = body.get("label", "")

    if not USER_ID_RE.match(user_id):
        _lib.respond("400 Bad Request", {"error": "bad_user_id"})

    if not isinstance(passkey_attestation, dict):
        _lib.respond("400 Bad Request", {"error": "missing_passkey_attestation"})

    # a. + b. Create user (validates invite code).
    create_args = ["api-user-create", "--user-id", user_id]
    if label:
        create_args += ["--label", label]
    if invite_code:
        create_args += ["--invite-code", invite_code]

    r = subprocess.run(
        ["sudo", "-n", "-u", OPERATOR, "lightning", *create_args],
        capture_output=True, text=True,
    )
    if r.returncode == 6:
        _lib.respond("401 Unauthorized", {"error": "invite_required"})
    if r.returncode == 4:
        _lib.respond("401 Unauthorized", {"error": "invite_not_found"})
    if r.returncode != 0:
        _lib.respond("502 Bad Gateway",
                     {"error": "create_failed", "detail": (r.stderr or "").strip()[:200]})

    # c. Finish WebAuthn registration.
    _require_rp_config()
    webauthn_out = _run(["_webauthn-verify", "register-finish",
                         "--user-id", user_id,
                         "--rp-id", RP_ID,
                         "--expected-origin", EXPECTED_ORIGIN],
                        stdin=json.dumps(passkey_attestation))

    # d. Mint session.
    sess = _run(["_session-token", "mint", "--user-id", user_id],
                parse_json=False).strip()

    # e. Return user_id + session.
    import re as _re
    sess_parts = sess.split(".")
    # expires_at: parse from token payload if possible, else opaque
    try:
        import base64 as _b64
        padded = sess_parts[1] + "==="
        payload = json.loads(_b64.urlsafe_b64decode(padded))
        expires_at = payload.get("exp")
    except Exception:
        expires_at = None

    _lib.respond("200 OK", {
        "user_id": user_id,
        "session": sess,
        "expires_at": expires_at,
    })


def user_show(uid):
    """Session-authed — return JSON user profile."""
    auth_user(uid)
    out = _run(["api-user-show", uid])
    _lib.respond("200 OK", out)


def user_accounts_list(uid):
    """Session-authed — list accounts owned by this user."""
    auth_user(uid)
    tsv_out = _run(["api-user-accounts", "list", uid], parse_json=False)
    try:
        data = json.loads(tsv_out)
    except json.JSONDecodeError:
        _lib.respond("502 Bad Gateway", {"error": "bad_json"})
    _lib.respond("200 OK", {"accounts": data})


def user_accounts_create(uid):
    """Session-authed — create an account owned by this user."""
    auth_user(uid)
    body = _lib.read_body()
    hint = body.get("hint", "")
    invite_code = body.get("invite_code", "")
    args = ["api-accounts-create", "--owner-user", uid]
    if hint:
        args += ["--hint", hint]
    if invite_code:
        args += ["--invite-code", invite_code]
    out = _run(args)
    _lib.respond("201 Created", out)


def user_account_apikey(uid, acct):
    """Session-authed — retrieve API key for an account owned by this user."""
    auth_user(uid)
    out = _run(["api-user-apikey", uid, acct])
    _lib.respond("200 OK", out)


def user_session_refresh(uid):
    """Session-authed — refresh the session token."""
    token = _lib.read_bearer()
    # verify first (auth_user will fail early if invalid)
    auth_user(uid)
    out = _run(["_session-token", "refresh", "--token", token],
               parse_json=False).strip()
    _lib.respond("200 OK", {"session": out})


# --- dispatcher ---

def dispatch():
    method = os.environ.get("REQUEST_METHOD", "").upper()
    path = os.environ.get("PATH_INFO", "")
    parts = [p for p in path.split("/") if p]

    # POST /register/begin — anonymous, no user_id segment
    if method == "POST" and parts == ["register", "begin"]:
        return register_begin()

    # POST / — anonymous finish registration
    if method == "POST" and not parts:
        return user_register_finish()

    if not parts:
        _lib.respond("404 Not Found", {"error": "no_user_id"})
    uid, tail = parts[0], parts[1:]
    if not USER_ID_RE.match(uid):
        _lib.respond("404 Not Found", {"error": "bad_user_id"})

    # GET /<id> — user profile
    if not tail:
        if method == "GET":
            return user_show(uid)
        _lib.respond("405 Method Not Allowed", {"error": "method_not_allowed"})

    # /<id>/passkeys/...
    if tail[0] == "passkeys":
        rest = tail[1:]
        # POST /passkeys/register/{begin,finish}
        if method == "POST" and len(rest) == 2 and rest[0] == "register":
            if rest[1] == "begin":
                return passkey_register_begin(uid)
            if rest[1] == "finish":
                return passkey_register_finish(uid)
        # POST /passkeys/login/{begin,finish}
        if method == "POST" and len(rest) == 2 and rest[0] == "login":
            if rest[1] == "begin":
                return passkey_login_begin(uid)
            if rest[1] == "finish":
                return passkey_login_finish(uid)
        # GET /passkeys
        if method == "GET" and not rest:
            return passkey_list(uid)
        # DELETE /passkeys/<cred_id>
        if method == "DELETE" and len(rest) == 1:
            return passkey_delete(uid, rest[0])
        _lib.respond("405 Method Not Allowed", {"error": "no_route"})

    # /<id>/accounts/...
    if tail[0] == "accounts":
        rest = tail[1:]
        # GET/POST /<id>/accounts
        if not rest:
            if method == "GET":
                return user_accounts_list(uid)
            if method == "POST":
                return user_accounts_create(uid)
            _lib.respond("405 Method Not Allowed", {"error": "method_not_allowed"})
        # GET /<id>/accounts/<acct>/api-key
        if len(rest) == 2 and rest[1] == "api-key":
            if method == "GET":
                return user_account_apikey(uid, rest[0])
            _lib.respond("405 Method Not Allowed", {"error": "method_not_allowed"})
        _lib.respond("404 Not Found", {"error": "no_route"})

    # /<id>/session/refresh
    if tail[0] == "session" and len(tail) == 2 and tail[1] == "refresh":
        if method == "POST":
            return user_session_refresh(uid)
        _lib.respond("405 Method Not Allowed", {"error": "method_not_allowed"})

    _lib.respond("404 Not Found", {"error": "no_route"})


if __name__ == "__main__":
    dispatch()
