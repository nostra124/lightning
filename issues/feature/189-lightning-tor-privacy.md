---
id: FEAT-189
type: feature
priority: medium
status: open
---

# Lightning Tor / network privacy

## Description

**As a** non-custodial Lightning user
**I want** `lightning tor {on,off,status}` and an opinionated
default that turns Tor on at daemon configure time
**So that** my node's IP isn't trivially linkable to its
pubkey, and the gossip graph doesn't doxx my home network.

Each backend has its own Tor story:

- **lnd**: `tor.active=true` + `tor.v3=true` in `lnd.conf`,
  hidden-service auto-created.
- **clightning**: `--proxy` + `--addr=statictor:` flags.
- **phoenixd**: routes through the Phoenix relay anyway;
  surface a `--tor=external` advisory.

## Implementation

1. **`lightning tor on`** — edits the active backend's config
   file in-place, restarts the daemon (FEAT-183), verifies a
   v3 onion address is advertised.
2. **`lightning tor off`** — reverses.
3. **`lightning tor status`** — reports: tor running locally?
   onion address advertised? clearnet leak detected?
4. **`lightning daemon install`** (FEAT-183) defaults Tor on
   for lnd / clightning; user can opt out with `--no-tor`.
5. **Walkthrough (FEAT-181)** adds a "verify your node isn't
   leaking" step that runs `lightning tor status` plus a
   manual `dig` check.

## Acceptance Criteria

1. `lightning tor on` against a fresh regtest daemon
   advertises a v3 onion address within 30s.
2. `lightning tor status` reports `leak: none` after `tor on`.
3. Default-on Tor is documented in the man page (FEAT-179).
4. phoenixd path prints the relay advisory and exits 0.
