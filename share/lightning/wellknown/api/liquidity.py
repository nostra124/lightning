#!/usr/bin/env python3
"""GET /v1/liquidity  — public Nostr Kind 39735 liquidity offer index (FEAT-210).

Queries the configured Nostr relay for active LSP offers and returns
them as a JSON array.  No authentication required (offers are public).

Query parameters:
  relay=<wss://...>   override relay (default: LIGHTNING_NOSTR_RELAY env)
  max_ppm=<n>         filter: variable fee ≤ n ppm
  min_sat=<n>         filter: min_channel_balance_sat ≥ n
  limit=<n>           cap results (default 50, max 200)
  featured=1          return only featured/boosted offers first

Featured offers: a Kind 39735 event tagged with a verified zap receipt
(Kind 9735) from our node is ranked first.  Operators pay via
`lightning liquidity nostr sell --featured` which sends a zap to our
node and includes the receipt event id in a `featured_zap` tag.
"""

import json
import os
import sys
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lightning"))
import _lib  # noqa: E402

DEFAULT_RELAY = os.environ.get(
    "LIGHTNING_NOSTR_RELAY", "wss://lightning.bawee.site"
)
FETCH_TIMEOUT = 8  # seconds
MAX_LIMIT = 200
DEFAULT_LIMIT = 50


def _parse_qs_safe(qs: str) -> dict:
    return {k: v[0] for k, v in parse_qs(qs).items() if v}


def _fetch_offers(relay: str, timeout: int = FETCH_TIMEOUT) -> list:
    """Open a websocket to *relay*, subscribe to kind:39735, collect events."""
    try:
        import websocket  # type: ignore
    except ImportError:
        _lib.respond(
            "503 Service Unavailable",
            {"error": "relay_client_unavailable",
             "detail": "pip install websocket-client on the server"},
        )

    import uuid

    sub_id = str(uuid.uuid4())[:8]
    results = []
    deadline = time.time() + timeout

    try:
        ws = websocket.create_connection(relay, timeout=timeout)
    except Exception as exc:
        _lib.respond(
            "502 Bad Gateway",
            {"error": "relay_unreachable", "relay": relay, "detail": str(exc)},
        )

    try:
        ws.send(json.dumps(["REQ", sub_id, {"kinds": [39735], "limit": 500}]))
        while time.time() < deadline:
            ws.settimeout(max(0.3, deadline - time.time()))
            try:
                msg = json.loads(ws.recv())
            except Exception:
                break
            if msg[0] == "EOSE":
                break
            if msg[0] != "EVENT" or msg[1] != sub_id:
                continue
            ev = msg[2]
            tags = {t[0]: t[1] for t in ev.get("tags", []) if len(t) >= 2}
            if tags.get("status", "active") != "active":
                continue
            created = ev.get("created_at", 0)
            expiry_blocks = int(tags.get("channel_expiry_blocks", 6480))
            # Approximate: 10 min/block
            expires_at = created + expiry_blocks * 600
            if expires_at < time.time():
                continue
            results.append({
                "event_id":       ev.get("id", ""),
                "pubkey":         ev.get("pubkey", ""),
                "lsp_node_id":    tags.get("node_id", tags.get("lsp_pubkey", "")),
                "alias":          tags.get("alias", ""),
                "min_sat":        int(tags.get("min_channel_balance_sat",
                                               tags.get("min_sat", 0))),
                "max_sat":        int(tags.get("max_channel_balance_sat",
                                               tags.get("max_sat", 0))),
                "fixed_cost_sat": int(tags.get("fixed_cost_sats", 0)),
                "variable_ppm":   int(tags.get("variable_cost_ppm", 0)),
                "max_promised_base_fee": int(tags.get("max_promised_base_fee", 0)),
                "supports_zero_reserve": tags.get("supports_zero_channel_reserve", "false") == "true",
                "supports_private":      tags.get("supports_private_channels", "false") == "true",
                "channel_expiry_blocks": expiry_blocks,
                "expires_at":     expires_at,
                "relay":          relay,
                "featured":       bool(tags.get("featured_zap")),
            })
    finally:
        try:
            ws.close()
        except Exception:
            pass

    return results


def main():
    if os.environ.get("REQUEST_METHOD", "GET").upper() not in ("GET", "HEAD"):
        _lib.respond("405 Method Not Allowed", {"error": "use_get"})

    params = _parse_qs_safe(os.environ.get("QUERY_STRING", ""))
    relay = params.get("relay", DEFAULT_RELAY)
    max_ppm = int(params.get("max_ppm", 0)) or None
    min_sat = int(params.get("min_sat", 0)) or None
    limit = min(int(params.get("limit", DEFAULT_LIMIT)), MAX_LIMIT)
    featured_first = params.get("featured") == "1"

    offers = _fetch_offers(relay)

    if max_ppm is not None:
        offers = [o for o in offers if o["variable_ppm"] <= max_ppm]
    if min_sat is not None:
        offers = [o for o in offers if o["min_sat"] >= min_sat]

    # Sort: featured first, then by effective cost (fixed + ppm*1M sat as proxy).
    def sort_key(o):
        return (
            0 if (featured_first and o["featured"]) else 1,
            o["fixed_cost_sat"] + o["variable_ppm"],
        )

    offers.sort(key=sort_key)
    offers = offers[:limit]

    _lib.respond("200 OK", {"offers": offers, "relay": relay, "count": len(offers)})


main()
