"""Tests for share/lightning/wellknown/api/node.py (FEAT-252).

Public node-info endpoint — no auth.
"""

import json
import os


SCRIPT = "node.py"


def env(bin_shim, **extra):
    e = {
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "REQUEST_METHOD": "GET",
    }
    e.update(extra)
    return e


def test_node_happy_path(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"pubkey":"0266e4598d1d3c415f572a8488830b60f7e744ed9235eb0b1ba93283b315c03518","alias":"alice","num_channels":3,"local_msat":600000}'
    lightning_stub({"api-node-info": (0, body)})
    proc = cgi(api_dir / SCRIPT, env=env(bin_shim))
    status, _, body_out = parse(proc)
    assert "200" in status
    j = json.loads(body_out)
    assert j["pubkey"].startswith("02")
    assert j["num_channels"] == 3


def test_node_post_is_405(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    proc = cgi(api_dir / SCRIPT, env=env(bin_shim, REQUEST_METHOD="POST"))
    status, _, _ = parse(proc)
    assert "405" in status
