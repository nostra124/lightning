"""Tests for share/lightning/wellknown/api/health.py (FEAT-284).

Public health endpoint — no auth.  Returns 200 when ok=true, 503 otherwise.
"""

import json
import os


SCRIPT = "health.py"


def env(bin_shim, **extra):
    e = {
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "REQUEST_METHOD": "GET",
    }
    e.update(extra)
    return e


def test_health_ok(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"ok":true,"daemon":true,"block_height":900000,"num_channels":2,"balanced":true,"pending_htlcs":0,"warnings":[]}'
    lightning_stub({"api-node-health": (0, body)})
    proc = cgi(api_dir / SCRIPT, env=env(bin_shim))
    status, _, body_out = parse(proc)
    assert "200" in status
    j = json.loads(body_out)
    assert j["ok"] is True
    assert j["block_height"] == 900000


def test_health_degraded_returns_503(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"ok":false,"daemon":false,"block_height":null,"num_channels":0,"balanced":true,"pending_htlcs":0,"warnings":["daemon unreachable"]}'
    lightning_stub({"api-node-health": (0, body)})
    proc = cgi(api_dir / SCRIPT, env=env(bin_shim))
    status, _, body_out = parse(proc)
    assert "503" in status
    j = json.loads(body_out)
    assert j["ok"] is False


def test_health_post_is_405(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    proc = cgi(api_dir / SCRIPT, env=env(bin_shim, REQUEST_METHOD="POST"))
    status, _, _ = parse(proc)
    assert "405" in status
