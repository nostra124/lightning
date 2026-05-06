---
id: FEAT-171
type: feature
priority: high
status: open
---

# Lightning: multi-backend abstraction (clightning, lnd, phoenixd)

## Description

**As a** Lightning user
**I want** one CLI surface that drives whichever Lightning
implementation I run — Core Lightning / lnd / phoenixd —
with auto-detection picking the right one
**So that** the same `lightning channel open …` /
`lightning pay …` / etc. work without me caring which
daemon's RPC dialect I'm speaking.

## Implementation

### Backends

Each backend is an executable file under
`libexec/lightning/backends/<name>` exposing a fixed
internal API:

    backend_node_id                          # public key
    backend_unlock                            # if needed
    backend_channel_list
    backend_channel_open <node-uri> <sats>
    backend_channel_close <channel-id>
    backend_balance                           # confirmed / unconfirmed
                                              #  / pending / channel
    backend_invoice <amount-sat> <label> [<expiry>]
    backend_pay <bolt11>
    backend_send_keysend <node-id> <amount>
    backend_pending_forwards
    backend_history [<since>]

Backends:

- `clightning` — talks to `lightning-cli` (or directly to
  the unix socket). Default. Simpler RPC, well-suited to
  bash. Auth via rune / commando.
- `lnd` — talks to `lncli` (gRPC under the hood). Auth via
  macaroon + TLS cert.
- `phoenixd` — talks to phoenixd's HTTP API. Designed for
  mobile / lightweight setups; LSP-backed. Auth via
  api password.

### Selection

    lightning backend                  # show active
    lightning backend auto             # default — detect
    lightning backend clightning|lnd|phoenixd

`auto` priority: clightning if `lightning-cli` reachable;
else lnd if `lncli` reachable; else phoenixd if its API is
reachable.

### Auth handling

Each backend's auth credentials (rune / macaroon /
phoenixd-password) live in `secret` under
`lightning/<backend>/<role>` namespacing. `lightning unlock`
and friends pull from `secret` automatically.

### Soft deps

Each backend's binary is probed; auto only chooses a
backend whose binary is reachable. Missing all three fails
with a clear "install lightningd, lnd, or phoenixd" message.

## Acceptance Criteria

1. `lightning backend auto` correctly picks clightning when
   `lightning-cli getinfo` succeeds, lnd when `lncli getinfo`
   does, phoenixd as fallback.
2. `lightning node-id` returns the same pubkey via any
   backend (against the same node).
3. `lightning channel list` shape is identical across
   backends (TSV: `id<TAB>peer<TAB>capacity<TAB>local<TAB>remote<TAB>state`).
4. Backend translators live under
   `libexec/lightning/backends/`; adding a fourth (e.g.
   eclair) is a single-file addition.
5. SIT (FEAT-182) covers each backend in its container.
