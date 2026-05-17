"""Tests for share/lightning/wellknown/lightning/balance.py.

Covers the read-scope auth path + happy-path JSON shape +
upstream failure → 502.
"""

import os
import pytest


def env(bin_shim, **extra):
    e = {
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "/alice",
        "HTTP_X_API_KEY": "rk",
    }
    e.update(extra)
    return e


def test_no_user_returns_404(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-verify": (0, ""), "api-balance": (0, "{}")})
    proc = cgi(cgi_dir / "balance.py", env={"PATH": f"{bin_shim}:{os.environ['PATH']}"})
    status, _, _ = parse(proc)
    assert "404" in status


def test_missing_apikey_returns_401(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-verify": (0, ""), "api-balance": (0, "{}")})
    proc = cgi(cgi_dir / "balance.py", env={
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "/alice",
    })
    status, _, _ = parse(proc)
    assert "401" in status


def test_wrong_apikey_returns_401(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    # Both read and write verifies fail.
    lightning_stub({"api-verify": (1, ""), "api-balance": (0, '{"balance_sat":42}')})
    proc = cgi(cgi_dir / "balance.py", env=env(bin_shim))
    status, _, _ = parse(proc)
    assert "401" in status


def test_happy_path_returns_200_with_balance(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    body_json = '{"balance_sat":1234,"limit_sat":50000,"overdraft":"deny"}'
    lightning_stub({"api-verify": (0, ""), "api-balance": (0, body_json)})
    proc = cgi(cgi_dir / "balance.py", env=env(bin_shim))
    status, headers, body = parse(proc)
    assert "200" in status
    assert "application/json" in headers.get("content-type", "")
    assert "1234" in body
    assert "deny" in body


def test_backend_failure_returns_502(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-verify": (0, ""), "api-balance": (1, "")})
    proc = cgi(cgi_dir / "balance.py", env=env(bin_shim))
    status, _, _ = parse(proc)
    assert "502" in status


def test_backend_bad_json_returns_502(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-verify": (0, ""), "api-balance": (0, "not-json")})
    proc = cgi(cgi_dir / "balance.py", env=env(bin_shim))
    status, _, _ = parse(proc)
    assert "502" in status


def test_invalid_user_in_path_returns_404(cgi_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-verify": (0, ""), "api-balance": (0, "{}")})
    # Uppercase user — fails the [a-z][a-z0-9_-]* regex.
    proc = cgi(cgi_dir / "balance.py", env={
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "/Alice",
        "HTTP_X_API_KEY": "rk",
    })
    status, _, _ = parse(proc)
    assert "404" in status
