---
id: FEAT-188
type: feature
priority: medium
status: done
---

# Lightning fee policy & forwarding (routing-node features)

## Description

**As a** user running `lightning` as a small routing node
**I want** `lightning fee {get,set,policy}` and
`lightning forward {list,stats}`
**So that** I can earn routing fees with a transparent policy
and inspect the resulting traffic.

Routing-node features are explicitly post-1.0: the 1.0 scope is
a personal wallet. This ticket exists so the scope boundary is
visible.

## Implementation

1. **Fee policy**:
   - `lightning fee get [<channel-id>]` — show base+ppm per
     channel.
   - `lightning fee set <channel-id> <base-msat> <ppm>` —
     update.
   - `lightning fee policy <name>` — apply a named policy
     (default policies: `flat`, `lsp-style`, `match-peer`).
2. **Forwarding**:
   - `lightning forward list [--since <date>]` — TSV of
     forwarded HTLCs.
   - `lightning forward stats` — totals: forwarded msats,
     fees earned, success rate.
3. **Privacy note**: forwarding stats reveal channel
   utilisation. Help text warns.

## Acceptance Criteria

1. `lightning fee set` updates clightning's per-channel
   policy (`setchannel`) and `fee get` reflects it via
   `listchannels`.
2. `lightning forward list` returns a stable TSV
   (forwarded HTLCs from `listforwards`).
3. SIT (FEAT-182) routes a payment through the test node and
   `forward stats` reports it.

## Milestone

Post-1.0. Add to a future 1.x routing-node milestone.
