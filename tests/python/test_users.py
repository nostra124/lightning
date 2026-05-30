"""Tests for share/lightning/wellknown/api/users.py (FEAT-222 PR-3b).

Covers the user-layer passkey dispatcher: routing, session auth via
_session-token verify, and JSON response wiring.  All backend verb
invocations (`lightning _webauthn-verify ...`, `lightning _session-token
...`) are stubbed via the shared `lightning_stub` fixture.
"""

import json
import os

import pytest


UID = "usr_aaaaaaaaaaaaaaaa"
OTHER_UID = "usr_bbbbbbbbbbbbbbbb"
SCRIPT = "users.py"
RP_ENV = {
    "LIGHTNING_RP_ID": "example.com",
    "LIGHTNING_RP_ORIGIN": "https://example.com",
    "LIGHTNING_RP_NAME": "Lightning Wallet",
}


def env(bin_shim, *, with_rp=True, **extra):
    e = {
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "",
        "REQUEST_METHOD": "GET",
    }
    if with_rp:
        e.update(RP_ENV)
    e.update(extra)
    return e


def with_bearer(d, token="sess_BODY.SIG"):
    d["HTTP_AUTHORIZATION"] = f"Bearer {token}"
    return d


# --- routing / id validation ---------------------------------------------

def test_no_path_is_404(api_dir, bin_shim, cgi, parse):
    proc = cgi(api_dir / SCRIPT, env=env(bin_shim))
    status, _, body = parse(proc)
    assert "404" in status
    assert "no_user_id" in body


def test_bad_user_id_is_404(api_dir, bin_shim, cgi, parse):
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO="/not-a-usr/passkeys"))
    status, _, body = parse(proc)
    assert "404" in status
    assert "bad_user_id" in body


def test_unknown_subpath_is_404(api_dir, bin_shim, cgi, parse):
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO=f"/{UID}/wat",
                       REQUEST_METHOD="GET"))
    status, _, _ = parse(proc)
    assert "404" in status


def test_wrong_method_on_passkeys_is_405(api_dir, bin_shim, cgi, parse):
    # PATCH /<uid>/passkeys is not a route.
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO=f"/{UID}/passkeys",
                       REQUEST_METHOD="PATCH"))
    # The GET branch will only fire for GET; everything else falls
    # through to the 405 at the bottom of the passkeys branch.
    status, _, _ = parse(proc)
    assert "405" in status


# --- RP config gate -------------------------------------------------------

def test_no_rp_config_is_503(api_dir, bin_shim, cgi, parse):
    # Login-begin doesn't need auth but DOES need the RP config.
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, with_rp=False,
                       PATH_INFO=f"/{UID}/passkeys/login/begin",
                       REQUEST_METHOD="POST"))
    status, _, body = parse(proc)
    assert "503" in status
    assert "rp_not_configured" in body


# --- login (no auth) ------------------------------------------------------

def test_login_begin_happy(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({
        "_webauthn-verify": (
            0,
            '{"challenge":"abc","rpId":"example.com","allowCredentials":[]}',
        ),
    })
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim,
                       PATH_INFO=f"/{UID}/passkeys/login/begin",
                       REQUEST_METHOD="POST"))
    status, _, body = parse(proc)
    assert "200" in status
    assert "challenge" in body


def test_login_finish_mints_session(api_dir, bin_shim, lightning_stub, cgi, parse):
    # login-finish calls _webauthn-verify THEN _session-token mint.
    lightning_stub({
        "_webauthn-verify": (0, '{"credential_id":"cred","user_id":"' + UID + '"}'),
        "_session-token":   (0, "sess_NEW.SIG"),
    })
    payload = json.dumps({"challenge": "abc", "assertion": {"id": "cred"}}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim,
                       PATH_INFO=f"/{UID}/passkeys/login/finish",
                       REQUEST_METHOD="POST",
                       CONTENT_LENGTH=str(len(payload))),
               body=payload)
    status, _, body = parse(proc)
    assert "200" in status
    resp = json.loads(body)
    assert resp["credential_id"] == "cred"
    assert resp["session"] == "sess_NEW.SIG"


def test_login_finish_bad_challenge_is_401(api_dir, bin_shim, lightning_stub, cgi, parse):
    # _webauthn-verify exits 7 on challenge_invalid -> mapped to 401.
    lightning_stub({
        "_webauthn-verify": (7, ""),
        "_session-token":   (0, "sess_x"),
    })
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim,
                       PATH_INFO=f"/{UID}/passkeys/login/finish",
                       REQUEST_METHOD="POST"))
    status, _, _ = parse(proc)
    assert "401" in status


# --- session auth gate ----------------------------------------------------

def test_passkey_list_without_bearer_is_401(api_dir, bin_shim, cgi, parse):
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim,
                       PATH_INFO=f"/{UID}/passkeys",
                       REQUEST_METHOD="GET"))
    status, _, body = parse(proc)
    assert "401" in status
    assert "missing_bearer" in body


def test_passkey_list_with_invalid_session_is_401(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"_session-token": (6, '{"error":"bad signature"}')})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/passkeys",
                                   REQUEST_METHOD="GET")))
    status, _, _ = parse(proc)
    assert "401" in status


def test_passkey_list_session_user_mismatch_is_403(api_dir, bin_shim, lightning_stub, cgi, parse):
    # Session belongs to OTHER_UID, request is for UID.
    lightning_stub({"_session-token": (0, json.dumps({"user_id": OTHER_UID, "exp": 9_999_999_999}))})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/passkeys",
                                   REQUEST_METHOD="GET")))
    status, _, body = parse(proc)
    assert "403" in status
    assert "session_user_mismatch" in body


# --- session-authed happy paths ------------------------------------------

def _good_session_stub(lightning_stub, extra):
    """Helper: install a stub where _session-token verify succeeds for UID
    and the other listed verbs return their canned responses."""
    table = {"_session-token": (0, json.dumps({"user_id": UID, "exp": 9_999_999_999}))}
    table.update(extra)
    # The dispatch script is a `case` on $1, so a single key per verb.
    # When the script needs BOTH session-token (verify) and another verb,
    # the helper's collision is avoided because the test only exercises
    # one auth path at a time — for tests that ALSO mint/refresh tokens,
    # callers provide their own combined stub.
    lightning_stub(table)


def test_passkey_list_happy(api_dir, bin_shim, lightning_stub, cgi, parse):
    # Tricky: list() shells out to both _session-token (verify) AND
    # _webauthn-verify (list).  The stub dispatcher matches on $1 — so
    # the same key can't serve two different responses.  Solution: use
    # a stub script that branches on $1 across both verbs.
    bin_shim_path = bin_shim
    target = bin_shim_path / "lightning"
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        f'  _session-token) printf %s {json.dumps(json.dumps({"user_id": UID, "exp": 9999999999}))}; exit 0 ;;\n'
        '  _webauthn-verify) printf "credential_id\\tlabel\\tcreated_at\\tlast_used_at\\tsign_count\\ncred1\\tphone\\t1\\t\\t0\\n"; exit 0 ;;\n'
        '  *) echo "stub: $1" >&2; exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/passkeys",
                                   REQUEST_METHOD="GET")))
    status, _, body = parse(proc)
    assert "200" in status
    data = json.loads(body)
    assert data["passkeys"] == [{
        "credential_id": "cred1",
        "label": "phone",
        "created_at": "1",
        "last_used_at": "",
        "sign_count": "0",
    }]


def test_passkey_list_empty(api_dir, bin_shim, cgi, parse):
    target = bin_shim / "lightning"
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        f'  _session-token) printf %s {json.dumps(json.dumps({"user_id": UID, "exp": 9999999999}))}; exit 0 ;;\n'
        '  _webauthn-verify) printf "credential_id\\tlabel\\tcreated_at\\tlast_used_at\\tsign_count\\n"; exit 0 ;;\n'
        '  *) exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/passkeys",
                                   REQUEST_METHOD="GET")))
    status, _, body = parse(proc)
    assert "200" in status
    assert json.loads(body) == {"passkeys": []}


def test_passkey_delete_happy(api_dir, bin_shim, cgi, parse):
    cred = "validBase64UrlCredentialId"
    target = bin_shim / "lightning"
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        f'  _session-token) printf %s {json.dumps(json.dumps({"user_id": UID, "exp": 9999999999}))}; exit 0 ;;\n'
        f'  _webauthn-verify) printf %s {json.dumps(json.dumps({"revoked": cred}))}; exit 0 ;;\n'
        '  *) exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/passkeys/{cred}",
                                   REQUEST_METHOD="DELETE")))
    status, _, body = parse(proc)
    assert "200" in status
    assert cred in body


def test_passkey_delete_bad_cred_format_is_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    # Auth verifies (so we don't reach the credential check until after).
    lightning_stub({"_session-token": (0, json.dumps({"user_id": UID, "exp": 9_999_999_999}))})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/passkeys/!!!bad!!!",
                                   REQUEST_METHOD="DELETE")))
    status, _, body = parse(proc)
    assert "400" in status
    assert "bad_credential_id" in body


def test_register_begin_needs_session(api_dir, bin_shim, cgi, parse):
    # No bearer -> 401, before we ever hit _webauthn-verify.
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim,
                       PATH_INFO=f"/{UID}/passkeys/register/begin",
                       REQUEST_METHOD="POST"))
    status, _, _ = parse(proc)
    assert "401" in status


def test_register_begin_happy(api_dir, bin_shim, cgi, parse):
    target = bin_shim / "lightning"
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        f'  _session-token) printf %s {json.dumps(json.dumps({"user_id": UID, "exp": 9999999999}))}; exit 0 ;;\n'
        '  _webauthn-verify) printf %s \'{"challenge":"xyz","rp":{"id":"example.com","name":"Lightning Wallet"}}\'; exit 0 ;;\n'
        '  *) exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/passkeys/register/begin",
                                   REQUEST_METHOD="POST")))
    status, _, body = parse(proc)
    assert "200" in status
    assert "challenge" in body
