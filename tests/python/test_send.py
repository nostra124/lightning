"""Tests for share/lightning/wellknown/lightning/send.py."""

import json
import os


def env(bin_shim):
    return {
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "/alice",
        "HTTP_X_API_KEY": "wk",
        "REQUEST_METHOD": "POST",
    }


def post(cgi_dir, bin_shim, lightning_stub, cgi, parse, payload, verb_responses=None):
    verb_responses = verb_responses or {"api-verify": (0, ""), "api-send": (0, "{}")}
    lightning_stub(verb_responses)
    body = json.dumps(payload).encode()
    proc = cgi(cgi_dir / "send.py", env={
        **env(bin_shim),
        "CONTENT_LENGTH": str(len(body)),
    }, body=body)
    return parse(proc)


def test_missing_to_field_returns_400(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    status, _, _ = post(cgi_dir, bin_shim, lightning_stub, cgi, parse,
                        {"sat": 100})
    assert "400" in status


def test_malformed_address_returns_400(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    status, _, _ = post(cgi_dir, bin_shim, lightning_stub, cgi, parse,
                        {"to": "not-an-address", "sat": 100})
    assert "400" in status


def test_zero_sat_returns_400(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    status, _, _ = post(cgi_dir, bin_shim, lightning_stub, cgi, parse,
                        {"to": "bob@example.com", "sat": 0})
    assert "400" in status


def test_note_too_long_returns_400(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    status, _, _ = post(cgi_dir, bin_shim, lightning_stub, cgi, parse,
                        {"to": "bob@example.com", "sat": 100,
                         "note": "x" * 1024})
    assert "400" in status


def test_overdraft_402(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    # api-send exits 6 on overdraft; balance.py-style mapping in _lib
    # turns that into 402.
    err = '{"error":"would_overdraw","balance_sat":50,"requested_sat":1000}'
    status, _, body = post(cgi_dir, bin_shim, lightning_stub, cgi, parse,
                           {"to": "bob@example.com", "sat": 1000},
                           {"api-verify": (0, ""), "api-send": (6, err)})
    assert "402" in status
    assert "would_overdraw" in body


def test_happy_path_returns_payment_hash(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    ok = '{"payment_hash":"deadbeef","fee_sat":1,"amount_sat":100}'
    status, _, body = post(cgi_dir, bin_shim, lightning_stub, cgi, parse,
                           {"to": "bob@example.com", "sat": 100,
                            "message": "thanks", "note": "march"},
                           {"api-verify": (0, ""), "api-send": (0, ok)})
    assert "200" in status
    assert "deadbeef" in body


def test_backend_502_on_unknown_error(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    status, _, _ = post(cgi_dir, bin_shim, lightning_stub, cgi, parse,
                        {"to": "bob@example.com", "sat": 100},
                        {"api-verify": (0, ""), "api-send": (5, "")})
    assert "502" in status
