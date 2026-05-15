---
id: FEAT-186
type: feature
priority: medium
status: open
---

# Lightning watchtowers

## Description

**As a** Lightning user whose node goes offline regularly
**I want** `lightning tower {client-add,client-list,server-on}`
verbs that wire my node to a watchtower (or run one)
**So that** an offline node can't be cheated by a peer
publishing a stale commitment.

Watchtowers are the BOLT-13 proposal (draft). lnd has a
production implementation (`wtclient` / `watchtower`);
clightning ships `lightningd-altruistwatchtower` as a plugin.
phoenixd is online-only (no watchtower client / server).

Educational angle: this verb teaches penalty transactions —
help text walks through the justice scenario.

## Implementation

1. **Client side**:
   - `lightning tower client-add <pubkey@host>` — register a
     remote tower.
   - `lightning tower client-list` — show registered towers
     and session counts.
   - `lightning tower client-stats` — sessions, towers,
     backup state.
2. **Server side (opt-in)**:
   - `lightning tower server-on` — enable watchtower role on
     the active backend (lnd config flip; clightning plugin
     load).
   - `lightning tower server-off` — disable.
   - `lightning tower server-status` — peers + breaches
     witnessed.
3. **phoenixd**: prints a clear "not supported — this is an
   always-online wallet" message.

## Acceptance Criteria

1. `lightning tower client-add` works against lnd and
   clightning.
2. SIT (FEAT-182) demonstrates penalty-tx broadcast by a
   running tower when a peer publishes a stale commitment.
3. phoenixd prints the not-supported message and exits 0.
4. Help text walks through the justice scenario citing BOLT 03
   and the watchtower BLIP/BOLT-13 draft URL.

## Milestone

Post-1.0 — not required for graduation; an educational
wallet doesn't strictly need watchtower auto-wiring on day
one. Reconsider at 1.1.0 planning.
