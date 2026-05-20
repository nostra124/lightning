"""pytest fixtures for the FEAT-196 CGI scripts.

The CGI scripts shell out via `sudo -u <op> lightning api-...`.
We stage a temp PATH dir with stub `sudo` (passthrough) and
stub `lightning` (canned responses) so the scripts run end-
to-end without needing real sudo or a real node.
"""

import os
import shlex
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
CGI_DIR = REPO_ROOT / "share/lightning/wellknown/lightning"
LNURLP_DIR = REPO_ROOT / "share/lightning/wellknown/lnurlp"


@pytest.fixture
def bin_shim(tmp_path):
    """A PATH dir with stub `sudo` (passthrough) and stub `lightning`.

    Test modules override `lightning` per-test with their own canned
    responses by writing to `bin_shim / "lightning"`.
    """
    shim = tmp_path / "bin"
    shim.mkdir()

    sudo = shim / "sudo"
    sudo.write_text(
        "#!/bin/bash\n"
        "# Strip sudo flags + user, exec the rest.\n"
        "while [ $# -gt 0 ]; do\n"
        '  case "$1" in\n'
        "    -n|-A|-K|-k|-S|-b|-E|-H|-P) shift ;;\n"
        "    -u|-g|-r|-t|-T|-h) shift 2 ;;\n"
        '    -*) shift ;;\n'
        '    *) break ;;\n'
        "  esac\n"
        "done\n"
        'exec "$@"\n'
    )
    sudo.chmod(0o755)
    return shim


@pytest.fixture
def lightning_stub(bin_shim):
    """Returns a writer that installs a fake `lightning` into bin_shim.

    Each call replaces the binary; tests use this to set up per-verb
    canned responses.
    """
    target = bin_shim / "lightning"

    def install(verb_responses: dict[str, tuple[int, str]]):
        # verb_responses: {verb_name: (rc, stdout)}
        cases = []
        for verb, (rc, out) in verb_responses.items():
            cases.append(
                f'{shlex.quote(verb)}) printf %s {shlex.quote(out)}; exit {rc} ;;'
            )
        script = (
            "#!/bin/bash\n"
            'case "$1" in\n'
            + "\n".join(cases) + "\n"
            '  *) echo "stub: unhandled $1" >&2; exit 99 ;;\n'
            "esac\n"
        )
        target.write_text(script)
        target.chmod(0o755)
        return target

    return install


def run_cgi(script: Path, *, env: dict | None = None, body: bytes = b"") -> subprocess.CompletedProcess:
    """Invoke a CGI script the way Apache would.

    Returns the CompletedProcess; the caller inspects stdout/stderr/returncode
    and parses the Status header out of stdout.
    """
    full_env = dict(os.environ)
    full_env.setdefault("LIGHTNING_OPERATOR_USER", "test")
    if env:
        full_env.update(env)
    return subprocess.run(
        [sys.executable, str(script)],
        capture_output=True,
        input=body,
        env=full_env,
    )


def parse_response(proc: subprocess.CompletedProcess) -> tuple[str, dict, str]:
    """Split a CGI response into (status_line, headers, body_text)."""
    out = proc.stdout.decode()
    head, _, body = out.partition("\r\n\r\n")
    if "\r\n\r\n" not in out:
        head, _, body = out.partition("\n\n")
    headers = {}
    status = ""
    for line in head.splitlines():
        if line.lower().startswith("status:"):
            status = line.split(":", 1)[1].strip()
        elif ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    return status, headers, body


@pytest.fixture
def cgi():
    """Convenience: returns the `run_cgi` helper."""
    return run_cgi


@pytest.fixture
def parse():
    """Convenience: returns the `parse_response` helper."""
    return parse_response


# Expose the CGI dirs to tests.
@pytest.fixture
def cgi_dir():
    return CGI_DIR


@pytest.fixture
def lnurlp_dir():
    return LNURLP_DIR
