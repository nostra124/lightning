---
id: FEAT-186
type: feature
priority: medium
status: done
---

# Lightning watchtowers

## Description

**As a** Lightning user whose node goes offline regularly
**I want** `lightning tower {client-add,client-list,server-on}`
verbs that wire my node to a watchtower (or run one)
**So that** an offline node can't be cheated by a peer
publishing a stale commitment.

Watchtowers are the BOLT-13 proposal (draft). clightning
ships `lightningd-altruistwatchtower` as a plugin (client
side) and the `watchtower` plugin (server side).

Educational angle: this verb teaches penalty transactions —
help text walks through the justice scenario.

## Implementation

1. **Client side** — wraps the `altruistwatchtower` plugin:
   - `lightning tower client-add <pubkey@host>` — register a
     remote tower.
   - `lightning tower client-list` — show registered towers
     and session counts.
   - `lightning tower client-stats` — sessions, towers,
     backup state.
2. **Server side (opt-in)** — wraps the `watchtower` plugin:
   - `lightning tower server-on` — load the plugin into
     lightningd.
   - `lightning tower server-off` — unload.
   - `lightning tower server-status` — peers + breaches
     witnessed.

## Acceptance Criteria

1. `lightning tower client-add <pubkey@host>` registers a
   tower with the altruistwatchtower plugin.
2. SIT (FEAT-182) demonstrates penalty-tx broadcast by a
   running tower when a peer publishes a stale commitment.
3. Help text walks through the justice scenario citing
   BOLT 03 and the watchtower BLIP / BOLT-13 draft URL.

## Milestone

Post-1.0 — not required for graduation; an educational
wallet doesn't strictly need watchtower auto-wiring on day
one. Reconsider at 1.1.0 planning.
