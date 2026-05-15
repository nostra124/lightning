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

Wraps clightning's `--proxy` + `--addr=statictor:` flags;
relies on a running `tor` daemon and its control socket.

## Implementation

1. **`lightning tor on`** — edits `<lightning-dir>/config`
   in-place to add `proxy=127.0.0.1:9050` and
   `addr=statictor:127.0.0.1:9051`, restarts lightningd
   (FEAT-183), verifies a v3 onion address is advertised
   via `lightning-cli getinfo`.
2. **`lightning tor off`** — reverses.
3. **`lightning tor status`** — reports: tor running locally?
   onion address advertised by lightningd? clearnet leak
   detected (i.e., is `getinfo.address` ipv4/ipv6 visible)?
4. **`lightning daemon install`** (FEAT-183) defaults Tor on;
   user can opt out with `--no-tor`.
5. **Walkthrough (FEAT-181)** adds a "verify your node isn't
   leaking" step that runs `lightning tor status` plus a
   manual `dig` check.

## Acceptance Criteria

1. `lightning tor on` against a fresh regtest lightningd
   advertises a v3 onion address within 30s.
2. `lightning tor status` reports `leak: none` after `tor on`.
3. Default-on Tor is documented in the man page (FEAT-179).
