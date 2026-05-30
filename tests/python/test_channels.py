"""Tests for share/lightning/wellknown/api/channels.py (FEAT-257)."""

import json
import os


SCRIPT = "channels.py"


def env(bin_shim, **extra):
    e = {
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "REQUEST_METHOD": "GET",
    }
    e.update(extra)
    return e


def test_channels_happy_path(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '[{"peer_id":"02abc","alias":"bob","channel_id":"x","capacity_sat":1000000,"local_sat":600000,"remote_sat":400000,"state":"CHANNELD_NORMAL"}]'
    lightning_stub({"api-channel-list": (0, body)})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, HTTP_AUTHORIZATION="Bearer lt_x"))
    status, _, body_out = parse(proc)
    assert "200" in status
    j = json.loads(body_out)
    assert j[0]["alias"] == "bob"


def test_channels_requires_bearer(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    proc = cgi(api_dir / SCRIPT, env=env(bin_shim))
    status, _, _ = parse(proc)
    assert "401" in status


def test_channels_post_is_405(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, REQUEST_METHOD="POST",
                       HTTP_AUTHORIZATION="Bearer lt_x"))
    status, _, _ = parse(proc)
    assert "405" in status
