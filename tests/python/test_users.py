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


# --- FEAT-222 PR-4: user CRUD + owned-account HTTP API -------------------


def test_pr4_anon_register_begin_200(api_dir, bin_shim, lightning_stub, cgi, parse):
    """POST /register/begin returns challenge + user_id."""
    lightning_stub({
        "_webauthn-verify": (0, '{"challenge":"ch1","options":{}}'),
    })
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO="/register/begin",
                       REQUEST_METHOD="POST"))
    status, _, body = parse(proc)
    assert "200" in status
    data = json.loads(body)
    assert "user_id" in data
    assert data["user_id"].startswith("usr_")
    assert len(data["user_id"]) == 20  # usr_ + 16
    assert "challenge" in data


def test_pr4_anon_register_begin_no_rp_503(api_dir, bin_shim, cgi, parse):
    """POST /register/begin without RP config returns 503."""
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, with_rp=False,
                       PATH_INFO="/register/begin",
                       REQUEST_METHOD="POST"))
    status, _, body = parse(proc)
    assert "503" in status
    assert "rp_not_configured" in body


def test_pr4_register_finish_happy(api_dir, bin_shim, cgi, parse):
    """POST / (finish) happy path returns session."""
    target = bin_shim / "lightning"
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        '  api-user-create) printf \'{"user_id":"' + UID + '","referrer_user":null}\'; exit 0 ;;\n'
        '  _webauthn-verify) printf \'{"credential_id":"cred1"}\'; exit 0 ;;\n'
        '  _session-token) printf "sess_BODY.SIG"; exit 0 ;;\n'
        '  *) echo "unhandled: $1" >&2; exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    payload = json.dumps({
        "user_id": UID,
        "invite_code": "INV123",
        "passkey_attestation": {"challenge": "ch1", "attestation": {}},
        "label": "my device",
    }).encode()
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO="/",
                       REQUEST_METHOD="POST",
                       CONTENT_LENGTH=str(len(payload))),
               body=payload)
    status, _, body = parse(proc)
    assert "200" in status
    data = json.loads(body)
    assert "session" in data
    assert data["user_id"] == UID


def test_pr4_register_finish_bad_invite_401(api_dir, bin_shim, cgi, parse):
    """POST / with bad invite code returns 401."""
    target = bin_shim / "lightning"
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        '  api-user-create) printf \'{"error":"invite_not_found"}\'; exit 4 ;;\n'
        '  *) exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    payload = json.dumps({
        "user_id": UID,
        "invite_code": "BAD",
        "passkey_attestation": {"challenge": "ch1", "attestation": {}},
    }).encode()
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO="/",
                       REQUEST_METHOD="POST",
                       CONTENT_LENGTH=str(len(payload))),
               body=payload)
    status, _, body = parse(proc)
    assert "401" in status
    assert "invite_not_found" in body


def test_pr4_register_finish_bad_attestation_401(api_dir, bin_shim, cgi, parse):
    """POST / with bad attestation returns 401."""
    target = bin_shim / "lightning"
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        '  api-user-create) printf \'{"user_id":"' + UID + '","referrer_user":null}\'; exit 0 ;;\n'
        '  _webauthn-verify) printf \'{"error":"verification_failed"}\'; exit 6 ;;\n'
        '  *) exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    payload = json.dumps({
        "user_id": UID,
        "passkey_attestation": {"challenge": "bad", "attestation": {}},
    }).encode()
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO="/",
                       REQUEST_METHOD="POST",
                       CONTENT_LENGTH=str(len(payload))),
               body=payload)
    status, _, body = parse(proc)
    assert "400" in status


def test_pr4_get_profile_no_bearer_401(api_dir, bin_shim, cgi, parse):
    """GET /<id> without bearer returns 401."""
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO=f"/{UID}",
                       REQUEST_METHOD="GET"))
    status, _, _ = parse(proc)
    assert "401" in status


def test_pr4_get_profile_happy(api_dir, bin_shim, cgi, parse):
    """GET /<id> with valid session returns JSON profile."""
    profile = {"user_id": UID, "label": "Alice", "created_at": 1000000,
               "referrer_user": None, "account_count": 0}
    target = bin_shim / "lightning"
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        f'  _session-token) printf %s {json.dumps(json.dumps({"user_id": UID, "exp": 9999999999}))}; exit 0 ;;\n'
        f'  api-user-show) printf %s {json.dumps(json.dumps(profile))}; exit 0 ;;\n'
        '  *) exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{UID}",
                                   REQUEST_METHOD="GET")))
    status, _, body = parse(proc)
    assert "200" in status
    data = json.loads(body)
    assert data["user_id"] == UID
    assert data["label"] == "Alice"


def test_pr4_accounts_list_happy(api_dir, bin_shim, cgi, parse):
    """GET /<id>/accounts returns 200 JSON array."""
    target = bin_shim / "lightning"
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        f'  _session-token) printf %s {json.dumps(json.dumps({"user_id": UID, "exp": 9999999999}))}; exit 0 ;;\n'
        '  api-user-accounts) printf \'[]\'; exit 0 ;;\n'
        '  *) exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{UID}/accounts",
                                   REQUEST_METHOD="GET")))
    status, _, body = parse(proc)
    assert "200" in status
    data = json.loads(body)
    assert data["accounts"] == []


def test_pr4_accounts_create_happy(api_dir, bin_shim, cgi, parse):
    """POST /<id>/accounts returns 201 with account JSON."""
    acct = {"account_id": "bc1qtest", "api_key": "lt_key", "topup_uri": "bitcoin:bc1qtest",
            "referrer": "house", "limit_sat": 100000, "overdraft": "deny", "endpoints": {}}
    target = bin_shim / "lightning"
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        f'  _session-token) printf %s {json.dumps(json.dumps({"user_id": UID, "exp": 9999999999}))}; exit 0 ;;\n'
        f'  api-accounts-create) printf %s {json.dumps(json.dumps(acct))}; exit 0 ;;\n'
        '  *) exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    payload = json.dumps({"hint": "my account"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{UID}/accounts",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body = parse(proc)
    assert "201" in status
    data = json.loads(body)
    assert data["account_id"] == "bc1qtest"


def test_pr4_account_apikey_happy(api_dir, bin_shim, cgi, parse):
    """GET /<id>/accounts/<acct>/api-key returns 200 with api_key."""
    acct_addr = "bc1qtest"
    target = bin_shim / "lightning"
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        f'  _session-token) printf %s {json.dumps(json.dumps({"user_id": UID, "exp": 9999999999}))}; exit 0 ;;\n'
        f'  api-user-apikey) printf \'{{"account_id":"{acct_addr}","api_key":"lt_testkey123"}}\'; exit 0 ;;\n'
        '  *) exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/accounts/{acct_addr}/api-key",
                                   REQUEST_METHOD="GET")))
    status, _, body = parse(proc)
    assert "200" in status
    data = json.loads(body)
    assert data["api_key"] == "lt_testkey123"


def test_pr4_session_refresh_happy(api_dir, bin_shim, cgi, parse):
    """POST /<id>/session/refresh returns 200 with new session token."""
    # _session-token verify returns a valid session payload; refresh returns new token.
    # The stub branches on $2 (subcommand): "verify" vs "refresh".
    target = bin_shim / "lightning"
    sess_payload = json.dumps({"user_id": UID, "exp": 9999999999})
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        f'  _session-token)\n'
        '    case "$2" in\n'
        f'      verify) printf %s {json.dumps(sess_payload)}; exit 0 ;;\n'
        '      refresh) printf "sess_NEW.SIG2"; exit 0 ;;\n'
        '      *) exit 99 ;;\n'
        '    esac ;;\n'
        '  *) exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/session/refresh",
                                   REQUEST_METHOD="POST")))
    status, _, body = parse(proc)
    assert "200" in status
    data = json.loads(body)
    assert "session" in data
    assert data["session"] == "sess_NEW.SIG2"


# --- FEAT-222 PR-5: invite codes + hierarchical governance ---

SUB_UID = "usr_cccccccccccccccc"


def _sess_stub(bin_shim, extra_cases=""):
    """Write a lightning stub with session-token verify + extra verb cases."""
    target = bin_shim / "lightning"
    sess_payload = json.dumps({"user_id": UID, "exp": 9999999999})
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        f'  _session-token) printf %s {json.dumps(sess_payload)}; exit 0 ;;\n'
        + extra_cases +
        '  *) exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    return target


def test_pr5_invite_codes_list_happy(api_dir, bin_shim, cgi, parse):
    """GET /<id>/invite-codes returns 200 JSON array."""
    tsv = f"abc1234567890abc\tbc1qtest\t2\t1700000000"
    _sess_stub(bin_shim, extra_cases=f'  wallet-user) printf "{tsv}"; exit 0 ;;\n')
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/invite-codes",
                                   REQUEST_METHOD="GET")))
    status, _, body = parse(proc)
    assert "200" in status
    data = json.loads(body)
    assert isinstance(data, list)
    assert data[0]["code"] == "abc1234567890abc"


def test_pr5_invite_codes_create_happy(api_dir, bin_shim, cgi, parse):
    """POST /<id>/invite-codes returns 201 with code + credit_account."""
    _sess_stub(bin_shim,
               extra_cases='  wallet-user) printf "code: mycode1234567890\\ncredit_account: bc1qtest\\n"; exit 0 ;;\n')
    payload = json.dumps({"credit_account": "bc1qtest"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/invite-codes",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body = parse(proc)
    assert "201" in status
    data = json.loads(body)
    assert "code" in data
    assert data["credit_account"] == "bc1qtest"


def test_pr5_invite_codes_create_cap_exceeded(api_dir, bin_shim, cgi, parse):
    """POST /<id>/invite-codes when cap exceeded → 403."""
    target = bin_shim / "lightning"
    sess_payload = json.dumps({"user_id": UID, "exp": 9999999999})
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        f'  _session-token) printf %s {json.dumps(sess_payload)}; exit 0 ;;\n'
        '  wallet-user)\n'
        '    case "$2" in\n'
        '      invite-code)\n'
        '        if [ "$3" = "create" ]; then\n'
        '          printf \'{"error":"cap_exceeded","ancestor":"usr_root"}\' >&2; exit 6\n'
        '        fi ;;\n'
        '    esac ;;\n'
        '  *) exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    payload = json.dumps({"credit_account": "bc1qtest"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/invite-codes",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body = parse(proc)
    assert "403" in status


def test_pr5_invite_codes_revoke_happy(api_dir, bin_shim, cgi, parse):
    """DELETE /<id>/invite-codes/<code> returns 200 {revoked}."""
    code = "mycode1234567890"
    tsv = f"{code}\tbc1qtest\t0\t1700000000"
    target = bin_shim / "lightning"
    sess_payload = json.dumps({"user_id": UID, "exp": 9999999999})
    target.write_text(
        "#!/bin/bash\n"
        'case "$1" in\n'
        f'  _session-token) printf %s {json.dumps(sess_payload)}; exit 0 ;;\n'
        '  wallet-user)\n'
        '    case "$3" in\n'
        f'      list) printf "{tsv}"; exit 0 ;;\n'
        '      revoke) exit 0 ;;\n'
        '    esac ;;\n'
        '  *) exit 99 ;;\n'
        "esac\n"
    )
    target.chmod(0o755)
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/invite-codes/{code}",
                                   REQUEST_METHOD="DELETE")))
    status, _, body = parse(proc)
    assert "200" in status
    data = json.loads(body)
    assert data["revoked"] == code


def test_pr5_downstream_tree_happy(api_dir, bin_shim, cgi, parse):
    """GET /<id>/downstream returns 200 with tree text."""
    _sess_stub(bin_shim,
               extra_cases=f'  wallet-user) printf "usr_aaaa (root) [cap: none, size: 0]"; exit 0 ;;\n')
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/downstream",
                                   REQUEST_METHOD="GET")))
    status, _, body = parse(proc)
    assert "200" in status
    data = json.loads(body)
    assert "tree" in data
    assert data["user_id"] == UID


def test_pr5_downstream_cap_happy(api_dir, bin_shim, cgi, parse):
    """POST /<id>/downstream/<sub>/cap returns 200."""
    _sess_stub(bin_shim,
               extra_cases='  wallet-user) exit 0 ;;\n')
    payload = json.dumps({"max": 5}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{UID}/downstream/{SUB_UID}/cap",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body = parse(proc)
    assert "200" in status
    data = json.loads(body)
    assert data["user_id"] == SUB_UID
    assert data["max_downline"] == 5
