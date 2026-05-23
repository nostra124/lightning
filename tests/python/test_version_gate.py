"""Tests for share/lightning/wellknown/api/version_gate.py (FEAT-232).

The gate catches unknown API-version segments (anything other than the
v1 ScriptAlias) and returns a clean 404 + JSON body.
"""

import json
import os


SCRIPT = "version_gate.py"


def env(bin_shim, **extra):
    e = {
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "PATH_INFO": "",
        "REQUEST_METHOD": "GET",
    }
    e.update(extra)
    return e


def test_unknown_version_returns_404_json(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    # Apache mounts the gate at /.well-known/lightning/v ; a request to
    # /v2/accounts/x arrives with PATH_INFO "2/accounts/x".
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, PATH_INFO="2/accounts/x/balance"))
    status, _, body_out = parse(proc)
    assert "404" in status
    j = json.loads(body_out)
    assert j["error"] == "unknown_api_version"
    assert j["requested"] == "v2"
    assert j["supported"] == ["v1"]


def test_gate_points_at_versions_manifest(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    proc = cgi(api_dir / SCRIPT, env=env(bin_shim, PATH_INFO="9/mcp"))
    status, _, body_out = parse(proc)
    assert "404" in status
    j = json.loads(body_out)
    assert j["versions_url"] == "/.well-known/lightning/versions.json"
    assert j["requested"] == "v9"
