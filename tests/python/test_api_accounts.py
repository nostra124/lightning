"""Tests for share/lightning/wellknown/api/accounts.py (FEAT-212 PR-2).

Covers the dispatcher's routing, method enforcement, bearer-auth
hand-off, and JSON response wiring.  Backend verbs are stubbed via
the shared `lightning_stub` fixture.
"""

import json
import os

import pytest


ID = "bcrt1qtestaddress000000000000000000000000000099xxxx"
SCRIPT = "accounts.py"


def env(bin_shim, **extra):
    e = {
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "",
        "REQUEST_METHOD": "GET",
    }
    e.update(extra)
    return e


def with_bearer(d, token="lt_some-bearer-token"):
    d["HTTP_AUTHORIZATION"] = f"Bearer {token}"
    return d


# --- create (anonymous) ---------------------------------------------------


def test_create_post_returns_201(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"account_id":"' + ID + '","api_key":"lt_x"}'
    lightning_stub({"api-accounts-create": (0, body)})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, REQUEST_METHOD="POST"))
    status, _, body_out = parse(proc)
    assert "201" in status
    assert ID in body_out


def test_create_get_is_405(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-accounts-create": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, REQUEST_METHOD="GET"))
    status, _, _ = parse(proc)
    assert "405" in status


def test_create_with_hint_passes_it_through(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"account_id":"' + ID + '"}'
    lightning_stub({"api-accounts-create": (0, body)})
    payload = json.dumps({"hint": "pocket"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, REQUEST_METHOD="POST",
                       CONTENT_LENGTH=str(len(payload))),
               body=payload)
    status, _, _ = parse(proc)
    assert "201" in status


def test_create_rate_limited_returns_402(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-accounts-create": (6, '{"error":"rate_limited"}')})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, REQUEST_METHOD="POST"))
    status, _, body_out = parse(proc)
    assert "402" in status
    assert "rate_limited" in body_out


# --- balance --------------------------------------------------------------


def test_balance_happy_path(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"balance_sat":1234,"limit_sat":50000,"overdraft":"deny"}'
    lightning_stub({
        "api-account-verify": (0, ""),
        "api-account-balance": (0, body),
    })
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/balance")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "1234" in body_out


def test_balance_missing_bearer_returns_401(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({
        "api-account-verify": (0, ""),
        "api-account-balance": (0, "{}"),
    })
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO=f"/{ID}/balance"))
    status, _, body_out = parse(proc)
    assert "401" in status
    assert "missing_bearer" in body_out


def test_balance_bad_bearer_returns_401(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({
        "api-account-verify": (1, ""),
        "api-account-balance": (0, "{}"),
    })
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/balance")))
    status, _, body_out = parse(proc)
    assert "401" in status
    assert "invalid_bearer" in body_out


def test_balance_post_is_405(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({
        "api-account-verify": (0, ""),
        "api-account-balance": (0, "{}"),
    })
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/balance",
                                   REQUEST_METHOD="POST")))
    status, _, _ = parse(proc)
    assert "405" in status


# --- topup ----------------------------------------------------------------


def test_topup_happy_path(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"address":"' + ID + '","uri":"bitcoin:' + ID + '","qr_text":"..."}'
    lightning_stub({
        "api-account-verify": (0, ""),
        "api-account-topup": (0, body),
    })
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/topup")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert ID in body_out


def test_topup_with_sat_query_passes_through(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"uri":"bitcoin:' + ID + '?amount=0.0005"}'
    lightning_stub({
        "api-account-verify": (0, ""),
        "api-account-topup": (0, body),
    })
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/topup",
                                   QUERY_STRING="sat=50000")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "amount=0.0005" in body_out


# --- withdraw -------------------------------------------------------------


def test_withdraw_happy_path(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"swap_id":"abc","status":"created","amount_sat":5000}'
    lightning_stub({
        "api-account-verify": (0, ""),
        "api-account-withdraw": (0, body),
    })
    payload = json.dumps({"sat": 5000,
                          "address": "bc1qdestxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/withdraw",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "abc" in body_out


def test_withdraw_missing_sat_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""),
                    "api-account-withdraw": (0, "{}")})
    payload = json.dumps({"address": "bc1qdestxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/withdraw",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "sat_required" in body_out


# --- pay ------------------------------------------------------------------


def test_pay_happy_path(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"payment_hash":"deadbeef","amount_sat":42,"fee_sat":1,"status":"complete"}'
    lightning_stub({
        "api-account-verify": (0, ""),
        "api-account-pay": (0, body),
    })
    payload = json.dumps({"target": "lnbc42p1xxx"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/pay",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "deadbeef" in body_out


def test_pay_unsupported_target_returns_402(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({
        "api-account-verify": (0, ""),
        "api-account-pay": (6, '{"error":"target_shape_not_implemented"}'),
    })
    payload = json.dumps({"target": "lnurl1abc"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/pay",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "402" in status
    assert "target_shape_not_implemented" in body_out


def test_pay_missing_target_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-pay": (0, "{}")})
    payload = b"{}"
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/pay",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "target_required" in body_out


# --- recv ---------------------------------------------------------------


def test_recv_happy_path(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"bolt11":"lnbc...","payment_hash":"hash","amount_sat":1000}'
    lightning_stub({
        "api-account-verify": (0, ""),
        "api-account-recv": (0, body),
    })
    payload = json.dumps({"sat": 1000, "description": "hi"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/recv",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "lnbc" in body_out


def test_recv_reusable_with_any_routes_to_offer_verb(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"bolt12":"lno1...","offer_id":"oid","amount_sat":null}'
    lightning_stub({
        "api-account-verify": (0, ""),
        "api-account-recv-reusable": (0, body),
    })
    payload = json.dumps({"sat": "any", "description": "tip jar"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/recv-reusable",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "lno1" in body_out


def test_recv_reusable_with_bad_sat_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({
        "api-account-verify": (0, ""),
        "api-account-recv-reusable": (0, "{}"),
    })
    payload = b"{}"
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/recv-reusable",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "sat_or_any_required" in body_out


# --- close ---------------------------------------------------------------


def test_close_happy_path(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"status":"closed","closed_at":1234567890}'
    lightning_stub({
        "api-account-verify": (0, ""),
        "api-account-close": (0, body),
    })
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/close",
                                   REQUEST_METHOD="POST")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "closed" in body_out


# --- routing ---------------------------------------------------------------


def test_unknown_verb_returns_404(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, "")})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/explode")))
    status, _, _ = parse(proc)
    assert "404" in status


def test_bad_account_id_returns_404(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO="/NotAnAddress/balance"))
    status, _, _ = parse(proc)
    assert "404" in status


def test_empty_path_routes_to_create(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-accounts-create": (0, '{"account_id":"' + ID + '"}')})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO="", REQUEST_METHOD="POST"))
    status, _, _ = parse(proc)
    assert "201" in status


def test_id_without_verb_is_404(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, "")})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}")))
    status, _, _ = parse(proc)
    assert "404" in status


def test_raw_token_without_bearer_prefix_works(api_dir, bin_shim, lightning_stub, cgi, parse):
    """Some proxies strip the scheme — _lib should still accept the token."""
    lightning_stub({
        "api-account-verify": (0, ""),
        "api-account-balance": (0, '{"balance_sat":0}'),
    })
    e = env(bin_shim, PATH_INFO=f"/{ID}/balance")
    e["HTTP_AUTHORIZATION"] = "lt_token-without-scheme"
    proc = cgi(api_dir / SCRIPT, env=e)
    status, _, body_out = parse(proc)
    assert "200" in status


# --- FEAT-218 referrals ---------------------------------------------------


def test_referrals_happy_path(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"referrals":[{"account_id":"' + ID + '","joined_at":1,"accrued_credits_sat":0}]}'
    lightning_stub({
        "api-account-verify":    (0, ""),
        "api-account-referrals": (0, body),
    })
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/referrals")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "referrals" in body_out


def test_referrals_post_is_405(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""),
                    "api-account-referrals": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/referrals",
                                   REQUEST_METHOD="POST")))
    status, _, _ = parse(proc)
    assert "405" in status


def test_referrals_requires_bearer(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""),
                    "api-account-referrals": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO=f"/{ID}/referrals"))
    status, _, _ = parse(proc)
    assert "401" in status


def test_create_with_invite_code_passes_through(api_dir, bin_shim, lightning_stub, cgi, parse):
    """The dispatcher should pass invite_code from the JSON body
    down to api-accounts-create as --invite-code."""
    body = '{"account_id":"' + ID + '","referrer":"alice"}'
    lightning_stub({"api-accounts-create": (0, body)})
    payload = json.dumps({"invite_code": "abcd"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim,
                       REQUEST_METHOD="POST",
                       CONTENT_LENGTH=str(len(payload))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "201" in status
    assert "alice" in body_out
