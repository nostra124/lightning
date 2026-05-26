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


# --- FEAT-223 transfer ----------------------------------------------------


def test_transfer_happy_path(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"transfer_id":"xfer:abc","from":"alpha","to":"beta","amount_sat":1000,"status":"complete"}'
    lightning_stub({
        "api-account-verify":   (0, ""),
        "api-account-transfer": (0, body),
    })
    payload = json.dumps({"to": "beta", "sat": 1000, "note": "x"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/transfer",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "xfer:abc" in body_out


def test_transfer_missing_to_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-transfer": (0, "{}")})
    payload = json.dumps({"sat": 1000}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/transfer",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "to_required" in body_out


def test_transfer_insufficient_balance_maps_to_402(api_dir, bin_shim, lightning_stub, cgi, parse):
    # The verb exits 6 on balance_insufficient; _lib.call_verb maps rc 6 → 402.
    lightning_stub({
        "api-account-verify":   (0, ""),
        "api-account-transfer": (6, '{"error":"balance_insufficient"}'),
    })
    payload = json.dumps({"to": "beta", "sat": 999999}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/transfer",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "402" in status
    assert "balance_insufficient" in body_out


def test_transfer_get_is_405(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-transfer": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/transfer")))
    status, _, _ = parse(proc)
    assert "405" in status


# --- FEAT-225 commercial invoice ------------------------------------------


HASH = "a" * 64


def test_invoice_create_returns_201(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = ('{"bolt11":"lnbcrt1","payment_hash":"' + HASH +
            '","face_sat":100000,"effective_sat":98000,'
            '"reference":{"order_id":"A-42"},"terms":{"due_days":14}}')
    lightning_stub({
        "api-account-verify":  (0, ""),
        "api-account-invoice": (0, body),
    })
    payload = json.dumps({
        "sat": 100000,
        "reference": {"order_id": "A-42"},
        "terms": {"due_days": 14, "skonto": {"within_days": 7, "discount_pct": 2}},
    }).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/invoice",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "201" in status
    assert "A-42" in body_out


def test_invoice_create_missing_sat_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-invoice": (0, "{}")})
    payload = json.dumps({"reference": {"order_id": "X"}}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/invoice",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "sat_required" in body_out


def test_invoice_create_requires_bearer(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-invoice": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO=f"/{ID}/invoice", REQUEST_METHOD="POST"))
    status, _, _ = parse(proc)
    assert "401" in status


def test_invoice_get_returns_200(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = ('{"bolt11":"lnbcrt1","payment_hash":"' + HASH +
            '","face_sat":100000,"effective_sat":98000,'
            '"reference":{"order_id":"A-42"},"paid":false,"state":"issued"}')
    lightning_stub({
        "api-account-verify":      (0, ""),
        "api-account-invoice-get": (0, body),
    })
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/invoice/{HASH}")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "A-42" in body_out


def test_invoice_get_bad_hash_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-invoice-get": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/invoice/not-hex!")))
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "bad_payment_hash" in body_out


def test_invoice_create_get_is_405(api_dir, bin_shim, lightning_stub, cgi, parse):
    # GET on the bare .../invoice (no hash) is the create slot — POST only.
    lightning_stub({"api-account-verify": (0, ""), "api-account-invoice": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/invoice")))
    status, _, _ = parse(proc)
    assert "405" in status


# --- FEAT-226 standing orders ---------------------------------------------


SO_ID = "so_abcdef0123456789"


def test_standing_order_list_returns_200(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"standing_orders":[{"id":"' + SO_ID + '","target":"landlord","sat":10000}]}'
    lightning_stub({
        "api-account-verify":         (0, ""),
        "api-account-standing-order": (0, body),
    })
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/standing-orders")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "landlord" in body_out


def test_standing_order_create_returns_201(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"id":"' + SO_ID + '","target":"landlord","sat":10000,"cadence":"monthly","status":"active"}'
    lightning_stub({
        "api-account-verify":         (0, ""),
        "api-account-standing-order": (0, body),
    })
    payload = json.dumps({"target": "landlord", "sat": 10000, "cadence": "monthly"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/standing-orders",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "201" in status
    assert SO_ID in body_out


def test_standing_order_create_bad_cadence_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-standing-order": (0, "{}")})
    payload = json.dumps({"target": "landlord", "sat": 10000, "cadence": "hourly"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/standing-orders",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "bad_cadence" in body_out


def test_standing_order_create_missing_target_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-standing-order": (0, "{}")})
    payload = json.dumps({"sat": 10000, "cadence": "daily"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/standing-orders",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "target_required" in body_out


def test_standing_order_pause_via_post(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"id":"' + SO_ID + '","status":"paused"}'
    lightning_stub({
        "api-account-verify":         (0, ""),
        "api-account-standing-order": (0, body),
    })
    payload = json.dumps({"action": "pause"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/standing-orders/{SO_ID}",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "paused" in body_out


def test_standing_order_bad_action_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-standing-order": (0, "{}")})
    payload = json.dumps({"action": "explode"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/standing-orders/{SO_ID}",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "bad_action" in body_out


def test_standing_order_cancel_via_delete(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"id":"' + SO_ID + '","status":"cancelled"}'
    lightning_stub({
        "api-account-verify":         (0, ""),
        "api-account-standing-order": (0, body),
    })
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/standing-orders/{SO_ID}",
                                   REQUEST_METHOD="DELETE")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "cancelled" in body_out


def test_standing_order_bad_id_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-standing-order": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/standing-orders/NOT-an-id",
                                   REQUEST_METHOD="DELETE")))
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "bad_order_id" in body_out


def test_standing_order_requires_bearer(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-standing-order": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO=f"/{ID}/standing-orders"))
    status, _, _ = parse(proc)
    assert "401" in status


# --- FEAT-227 direct-debit mandates ---------------------------------------


MDT = "mdt_abcdef0123456789"
MPL = "mpl_abcdef0123456789"


def test_mandate_create_returns_201(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"id":"' + MDT + '","merchant":"shop","customer":"cust","mode":"auto","status":"active","secret":"s3cr3t"}'
    lightning_stub({"api-account-verify": (0, ""), "api-account-mandate": (0, body)})
    payload = json.dumps({"merchant": "shop", "max_per_period": 50000, "period": "monthly"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/mandates",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "201" in status
    assert "s3cr3t" in body_out


def test_mandate_create_bad_period_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-mandate": (0, "{}")})
    payload = json.dumps({"merchant": "shop", "max_per_period": 50000, "period": "hourly"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/mandates",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "bad_period" in body_out


def test_mandate_list_returns_200(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"mandates":[{"id":"' + MDT + '","merchant":"shop","status":"active"}]}'
    lightning_stub({"api-account-verify": (0, ""), "api-account-mandate": (0, body)})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/mandates")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "shop" in body_out


def test_mandate_patch_returns_200(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"id":"' + MDT + '","mode":"approval","status":"active"}'
    lightning_stub({"api-account-verify": (0, ""), "api-account-mandate": (0, body)})
    payload = json.dumps({"mode": "approval"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/mandates/{MDT}",
                                   REQUEST_METHOD="PATCH",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "approval" in body_out


def test_mandate_revoke_via_delete(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"id":"' + MDT + '","mode":"auto","status":"revoked"}'
    lightning_stub({"api-account-verify": (0, ""), "api-account-mandate": (0, body)})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/mandates/{MDT}",
                                   REQUEST_METHOD="DELETE")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "revoked" in body_out


def test_mandate_charge_happy_path(api_dir, bin_shim, lightning_stub, cgi, parse):
    # Secret-authed (no bearer). The verb echoes an executed pull.
    body = '{"pull_id":"' + MPL + '","state":"executed","sat":10000}'
    lightning_stub({"api-account-mandate-pull": (0, body)})
    payload = json.dumps({"secret": "s3cr3t", "sat": 10000}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim,
                       PATH_INFO=f"/{ID}/mandates/{MDT}/charge",
                       REQUEST_METHOD="POST",
                       CONTENT_LENGTH=str(len(payload))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "executed" in body_out


def test_mandate_charge_missing_secret_returns_401(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-mandate-pull": (0, "{}")})
    payload = json.dumps({"sat": 10000}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim,
                       PATH_INFO=f"/{ID}/mandates/{MDT}/charge",
                       REQUEST_METHOD="POST",
                       CONTENT_LENGTH=str(len(payload))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "401" in status
    assert "missing_mandate_secret" in body_out


def test_mandate_charge_bad_secret_maps_to_401(api_dir, bin_shim, lightning_stub, cgi, parse):
    # Verb exits 7 on auth failure; dispatcher maps 7 -> 401.
    lightning_stub({"api-account-mandate-pull": (7, '{"error":"unauthorized"}')})
    payload = json.dumps({"secret": "wrong", "sat": 10000}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim,
                       PATH_INFO=f"/{ID}/mandates/{MDT}/charge",
                       REQUEST_METHOD="POST",
                       CONTENT_LENGTH=str(len(payload))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "401" in status
    assert "invalid_mandate_secret" in body_out


def test_mandate_charge_cap_exceeded_maps_to_402(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-mandate-pull": (6, '{"error":"cap_exceeded"}')})
    payload = json.dumps({"secret": "s3cr3t", "sat": 999999}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim,
                       PATH_INFO=f"/{ID}/mandates/{MDT}/charge",
                       REQUEST_METHOD="POST",
                       CONTENT_LENGTH=str(len(payload))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "402" in status
    assert "cap_exceeded" in body_out


def test_mandate_pull_approve(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"pull_id":"' + MPL + '","state":"executed"}'
    lightning_stub({"api-account-verify": (0, ""), "api-account-mandate-pull": (0, body)})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/mandates/{MDT}/pulls/{MPL}/approve",
                                   REQUEST_METHOD="POST")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "executed" in body_out


def test_mandate_charge_requires_no_bearer_but_pulls_do(api_dir, bin_shim, lightning_stub, cgi, parse):
    # approve without a bearer -> 401.
    lightning_stub({"api-account-verify": (0, ""), "api-account-mandate-pull": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim,
                       PATH_INFO=f"/{ID}/mandates/{MDT}/pulls/{MPL}/deny",
                       REQUEST_METHOD="POST"))
    status, _, _ = parse(proc)
    assert "401" in status


# --- FEAT-228 commerce charge lifecycle -----------------------------------


CHG = "chg_abcdef0123456789"


def test_charge_create_returns_201(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"id":"' + CHG + '","merchant":"shop","customer":"buyer","amount_sat":20000,"state":"issued"}'
    lightning_stub({"api-account-verify": (0, ""), "api-account-charge": (0, body)})
    payload = json.dumps({"customer": "buyer", "amount_sat": 20000,
                          "reference": {"order_id": "O1"}, "due_days": 14}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/charges",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "201" in status
    assert "issued" in body_out


def test_charge_create_missing_amount_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-charge": (0, "{}")})
    payload = json.dumps({"customer": "buyer"}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/charges",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "amount_required" in body_out


def test_charge_list_returns_200(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"charges":[{"id":"' + CHG + '","customer":"buyer","state":"issued"}]}'
    lightning_stub({"api-account-verify": (0, ""), "api-account-charge": (0, body)})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/charges")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "buyer" in body_out


def test_charge_show_returns_200(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"id":"' + CHG + '","state":"released","events":[]}'
    lightning_stub({"api-account-verify": (0, ""), "api-account-charge": (0, body)})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/charges/{CHG}")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "released" in body_out


def test_charge_hold_action(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"id":"' + CHG + '","state":"held"}'
    lightning_stub({"api-account-verify": (0, ""), "api-account-charge": (0, body)})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/charges/{CHG}/hold",
                                   REQUEST_METHOD="POST")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "held" in body_out


def test_charge_capture_requires_sat(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-charge": (0, "{}")})
    payload = json.dumps({}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/charges/{CHG}/capture",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "sat_required" in body_out


def test_charge_installments_requires_n(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-charge": (0, "{}")})
    payload = json.dumps({"n": 1}).encode()
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/charges/{CHG}/installments",
                                   REQUEST_METHOD="POST",
                                   CONTENT_LENGTH=str(len(payload)))),
               body=payload)
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "n_required" in body_out


def test_charge_bad_state_maps_to_402(api_dir, bin_shim, lightning_stub, cgi, parse):
    # Verb exits 6 on a bad-state transition; call_verb maps 6 -> 402.
    lightning_stub({"api-account-verify": (0, ""),
                    "api-account-charge": (6, '{"error":"bad_state"}')})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/charges/{CHG}/release",
                                   REQUEST_METHOD="POST")))
    status, _, body_out = parse(proc)
    assert "402" in status
    assert "bad_state" in body_out


def test_charge_unknown_action_returns_404(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-charge": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/charges/{CHG}/explode",
                                   REQUEST_METHOD="POST")))
    status, _, _ = parse(proc)
    assert "404" in status


def test_charge_bad_id_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-charge": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/charges/NOT-an-id")))
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "bad_charge_id" in body_out


def test_charge_requires_bearer(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-charge": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO=f"/{ID}/charges"))
    status, _, _ = parse(proc)
    assert "401" in status


# --- FEAT-230 tax-data export ---------------------------------------------


def test_export_json_streams_verb_output(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"kind":"transaction_data_for_tax_preparation","disposals":[],"summary":{}}'
    lightning_stub({"api-account-verify": (0, ""), "export": (0, body)})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/export/tax-data",
                                   QUERY_STRING="year=2024&base=EUR&format=json")))
    status, headers, body_out = parse(proc)
    assert "200" in status
    assert "application/json" in headers.get("content-type", "")
    assert "transaction_data_for_tax_preparation" in body_out


def test_export_csv_sets_text_csv_content_type(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = "disposal_date,disposal_sat,acquisition_date,holding_days,fiat_in,fiat_out,gain,price_gap\n"
    lightning_stub({"api-account-verify": (0, ""), "export": (0, body)})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/export/tax-data",
                                   QUERY_STRING="year=2024&format=csv")))
    status, headers, body_out = parse(proc)
    assert "200" in status
    assert "text/csv" in headers.get("content-type", "")
    assert "disposal_date" in body_out


def test_export_missing_year_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "export": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/export/tax-data",
                                   QUERY_STRING="base=EUR")))
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "year_required" in body_out


def test_export_bad_format_returns_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "export": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/export/tax-data",
                                   QUERY_STRING="year=2024&format=xml")))
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "bad_format" in body_out


def test_export_requires_bearer(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "export": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO=f"/{ID}/export/tax-data",
                       QUERY_STRING="year=2024"))
    status, _, _ = parse(proc)
    assert "401" in status


def test_export_unknown_subpath_returns_404(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "export": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/export/everything")))
    status, _, _ = parse(proc)
    assert "404" in status


# --- FEAT-220 invite codes ------------------------------------------------


def test_invite_codes_returns_200(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"invite_codes":[{"code":"abc1234","uses":0,"created_at":1}]}'
    lightning_stub({
        "api-account-verify":          (0, ""),
        "api-account-invite-codes":    (0, body),
    })
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim, PATH_INFO=f"/{ID}/invite-codes")))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "abc1234" in body_out


def test_invite_codes_post_is_405(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-invite-codes": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=with_bearer(env(bin_shim,
                                   PATH_INFO=f"/{ID}/invite-codes",
                                   REQUEST_METHOD="POST")))
    status, _, _ = parse(proc)
    assert "405" in status


def test_invite_codes_requires_bearer(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""), "api-account-invite-codes": (0, "{}")})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO=f"/{ID}/invite-codes"))
    status, _, _ = parse(proc)
    assert "401" in status
