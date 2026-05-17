"""Tests for share/lightning/wellknown/lnurlp/handler.py — the
LUD-06 metadata + invoice endpoint."""

import json
import os


def test_no_amount_returns_lud06_metadata(lnurlp_dir, bin_shim, lightning_stub, cgi, parse):
    # First-hop fetch: no `amount=` in query string → discovery JSON.
    lightning_stub({"api-recv": (0, "")})
    proc = cgi(lnurlp_dir / "handler.py", env={
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "/alice",
        "QUERY_STRING": "",
        "HTTP_HOST": "example.com",
    })
    status, headers, body = parse(proc)
    assert "200" in status
    parsed = json.loads(body)
    assert parsed["tag"] == "payRequest"
    assert parsed["callback"] == "https://example.com/.well-known/lnurlp/alice"
    assert parsed["commentAllowed"] == 256
    # LUD-06 metadata is a JSON-encoded list of [type, value] pairs.
    md = json.loads(parsed["metadata"])
    assert any(t == "text/identifier" and v == "alice@example.com" for t, v in md)


def test_amount_callback_returns_pr(lnurlp_dir, bin_shim, lightning_stub, cgi, parse):
    backend_json = '{"bolt11":"lnbcrt10n1pxxx","payment_hash":"deadbeef","amount_sat":1}'
    lightning_stub({"api-recv": (0, backend_json)})
    proc = cgi(lnurlp_dir / "handler.py", env={
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "/alice",
        "QUERY_STRING": "amount=1000&comment=hi",
        "HTTP_HOST": "example.com",
    })
    status, _, body = parse(proc)
    assert "200" in status
    parsed = json.loads(body)
    assert parsed["pr"] == "lnbcrt10n1pxxx"
    assert parsed["routes"] == []


def test_invalid_user_returns_404(lnurlp_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-recv": (0, "")})
    proc = cgi(lnurlp_dir / "handler.py", env={
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "/Alice",          # uppercase
        "QUERY_STRING": "",
        "HTTP_HOST": "example.com",
    })
    status, _, _ = parse(proc)
    assert "404" in status


def test_empty_path_info_returns_404(lnurlp_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-recv": (0, "")})
    proc = cgi(lnurlp_dir / "handler.py", env={
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "",
        "QUERY_STRING": "",
    })
    status, _, _ = parse(proc)
    assert "404" in status


def test_non_numeric_amount_returns_400(lnurlp_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-recv": (0, "")})
    proc = cgi(lnurlp_dir / "handler.py", env={
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "/alice",
        "QUERY_STRING": "amount=not-a-number",
        "HTTP_HOST": "example.com",
    })
    status, _, _ = parse(proc)
    assert "400" in status


def test_zero_amount_returns_400(lnurlp_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-recv": (0, "")})
    proc = cgi(lnurlp_dir / "handler.py", env={
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "/alice",
        "QUERY_STRING": "amount=0",
        "HTTP_HOST": "example.com",
    })
    status, _, _ = parse(proc)
    assert "400" in status


def test_backend_failure_returns_502(lnurlp_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-recv": (1, "")})
    proc = cgi(lnurlp_dir / "handler.py", env={
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "/alice",
        "QUERY_STRING": "amount=1000",
        "HTTP_HOST": "example.com",
    })
    status, _, _ = parse(proc)
    assert "502" in status
