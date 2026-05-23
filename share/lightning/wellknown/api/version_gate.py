#!/usr/bin/env python3
"""Catch-all for unknown API versions (FEAT-232).

Apache routes `/.well-known/lightning/v1/accounts` + `.../v1/mcp` to
the real dispatchers (longer ScriptAlias prefixes win).  Any other
version segment — `/.well-known/lightning/v2/...`, `/v9/...` — falls
through to this gate, which returns a clean 404 with a JSON body so
callers learn the version is unsupported rather than getting Apache's
generic page.

PATH_INFO here is the tail after `/.well-known/lightning/v`, e.g.
`2/accounts/...` for a `/v2/...` request.
"""

import os
import sys
import re
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lightning"))
import _lib  # noqa: E402

KNOWN = {"v1"}


def main():
    # Reconstruct the requested version from PATH_INFO.  The ScriptAlias
    # mount is `/.well-known/lightning/v`, so PATH_INFO begins with the
    # rest of the version token: e.g. request `/v2/accounts/x` →
    # PATH_INFO `2/accounts/x`.  Prepend the stripped `v`.
    path_info = os.environ.get("PATH_INFO", "")
    m = re.match(r"^/?(v?[0-9A-Za-z._-]*)", "v" + path_info.lstrip("/"))
    requested = m.group(1) if m else "v?"
    _lib.respond("404 Not Found", {
        "error": "unknown_api_version",
        "requested": requested,
        "supported": sorted(KNOWN),
        "versions_url": "/.well-known/lightning/versions.json",
    })


main()
