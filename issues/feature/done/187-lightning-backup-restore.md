---
id: FEAT-187
type: feature
priority: high
status: done
---

# Lightning backup / restore verbs

## Description

**As a** Lightning user
**I want** `lightning backup` and `lightning restore` as
one-shot wrappers that bundle seed export (FEAT-185) + SCB
snapshot + wallet git push
**So that** "back up my node" is a single command and
"recover my node" is a documented playbook.

This is the user-facing umbrella; it composes FEAT-174 (wallet
git), FEAT-185 (seed/SCB), and FEAT-184 (unlock) into a single
verb.

## Implementation

1. **`lightning backup`** — composes:
   - `lightning scb emit` (writes the SCB into the wallet
     repo, auto-commits)
   - optional `--seed` flag: ALSO writes an encrypted seed
     export into the wallet repo (default off; seed lives in
     the user's head normally)
   - `lightning wallet push` to the configured remote
2. **`lightning restore <wallet-remote>`** — clones the wallet
   repo, prompts for seed (FEAT-185 `seed import`), unlocks
   the daemon, runs `lightning scb restore` against the
   latest SCB.
3. **`lightning backup verify`** — sanity check: SCB present
   and parseable, wallet remote reachable, seed prompt does
   not match the previous export.

## Acceptance Criteria

1. `lightning backup && lightning restore` round-trips against
   a fresh regtest daemon — same node id, same on-chain
   balance after force-closes settle.
2. `--seed` is opt-in and prints a banner explaining the
   tradeoff.
3. Help text references FEAT-174 / 185 / 184 so users can
   reach the lower-level verbs.
