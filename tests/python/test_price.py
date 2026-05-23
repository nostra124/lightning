"""Tests for share/lightning/wellknown/api/price.py (FEAT-229).

Public price endpoint — no auth.  Thin wrapper over `lightning
price now --base <CUR>`; verifies method enforcement, base
validation, pass-through, and the no-data → 200-with-error path.
"""

import json
import os


SCRIPT = "price.py"


def env(bin_shim, **extra):
    e = {
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "REQUEST_METHOD": "GET",
        "QUERY_STRING": "base=EUR",
    }
    e.update(extra)
    return e


def test_price_happy_path(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"ts":123,"base":"EUR","btc_fiat":60000.0,"source":"mempool"}'
    lightning_stub({"price": (0, body)})
    proc = cgi(api_dir / SCRIPT, env=env(bin_shim))
    status, _, body_out = parse(proc)
    assert "200" in status
    j = json.loads(body_out)
    assert j["base"] == "EUR"
    assert j["btc_fiat"] == 60000.0


def test_price_post_is_405(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"price": (0, "{}")})
    proc = cgi(api_dir / SCRIPT, env=env(bin_shim, REQUEST_METHOD="POST"))
    status, _, _ = parse(proc)
    assert "405" in status


def test_price_bad_base_is_400(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"price": (0, "{}")})
    proc = cgi(api_dir / SCRIPT, env=env(bin_shim, QUERY_STRING="base=12345678"))
    status, _, body_out = parse(proc)
    assert "400" in status
    assert "bad_base" in body_out


def test_price_no_data_is_200_with_error(api_dir, bin_shim, lightning_stub, cgi, parse):
    # `price now` exits 4 + prints the no_price_data object; the CGI
    # passes the JSON through as 200 (a polling client checks .error).
    lightning_stub({"price": (4, '{"error":"no_price_data","base":"EUR"}')})
    proc = cgi(api_dir / SCRIPT, env=env(bin_shim))
    status, _, body_out = parse(proc)
    assert "200" in status
    assert "no_price_data" in body_out


def test_price_default_base_when_absent(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"ts":1,"base":"EUR","btc_fiat":1.0,"source":"x"}'
    lightning_stub({"price": (0, body)})
    proc = cgi(api_dir / SCRIPT, env=env(bin_shim, QUERY_STRING=""))
    status, _, _ = parse(proc)
    assert "200" in status
