"""Tests for share/lightning/wellknown/lightning/recv.py."""

import json
import os


def env(bin_shim):
    return {
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "/alice",
        "HTTP_X_API_KEY": "wk",
        "REQUEST_METHOD": "POST",
    }


def test_missing_apikey_returns_401(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-verify": (0, ""), "api-recv": (0, "{}")})
    proc = cgi(cgi_dir / "recv.py", env={
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "/alice",
        "REQUEST_METHOD": "POST",
    }, body=b'{"sat":1000,"message":"hi"}')
    status, _, _ = parse(proc)
    assert "401" in status


def test_read_scope_key_cannot_recv(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    # read-scope verify succeeds for `read` only; recv expects `write`.
    # We model that by failing the write-scope verify.
    lightning_stub({"api-verify": (1, ""), "api-recv": (0, "{}")})
    e = env(bin_shim)
    e["HTTP_X_API_KEY"] = "rk"
    body = json.dumps({"sat": 1000, "message": "hi"}).encode()
    proc = cgi(cgi_dir / "recv.py", env={**e, "CONTENT_LENGTH": str(len(body))},
               body=body)
    status, _, _ = parse(proc)
    assert "401" in status


def test_bad_json_body_returns_400(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-verify": (0, ""), "api-recv": (0, "{}")})
    body = b"not json at all"
    proc = cgi(cgi_dir / "recv.py", env={
        **env(bin_shim),
        "CONTENT_LENGTH": str(len(body)),
    }, body=body)
    status, _, _ = parse(proc)
    assert "400" in status


def test_missing_sat_field_returns_400(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-verify": (0, ""), "api-recv": (0, "{}")})
    body = json.dumps({"message": "no amount"}).encode()
    proc = cgi(cgi_dir / "recv.py", env={
        **env(bin_shim),
        "CONTENT_LENGTH": str(len(body)),
    }, body=body)
    status, _, _ = parse(proc)
    assert "400" in status


def test_negative_sat_returns_400(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-verify": (0, ""), "api-recv": (0, "{}")})
    body = json.dumps({"sat": -1, "message": "negative"}).encode()
    proc = cgi(cgi_dir / "recv.py", env={
        **env(bin_shim),
        "CONTENT_LENGTH": str(len(body)),
    }, body=body)
    status, _, _ = parse(proc)
    assert "400" in status


def test_message_too_long_returns_400(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-verify": (0, ""), "api-recv": (0, "{}")})
    body = json.dumps({"sat": 100, "message": "x" * 1024}).encode()
    proc = cgi(cgi_dir / "recv.py", env={
        **env(bin_shim),
        "CONTENT_LENGTH": str(len(body)),
    }, body=body)
    status, _, _ = parse(proc)
    assert "400" in status


def test_happy_path_returns_bolt11(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    backend_json = '{"bolt11":"lnbcrt10n1pxxx","payment_hash":"deadbeef","amount_sat":100}'
    lightning_stub({"api-verify": (0, ""), "api-recv": (0, backend_json)})
    body = json.dumps({"sat": 100, "message": "ok"}).encode()
    proc = cgi(cgi_dir / "recv.py", env={
        **env(bin_shim),
        "CONTENT_LENGTH": str(len(body)),
    }, body=body)
    status, _, body_text = parse(proc)
    assert "200" in status
    assert "lnbcrt10n1pxxx" in body_text
