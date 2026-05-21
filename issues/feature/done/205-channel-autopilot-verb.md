---
id: FEAT-205
type: feature
priority: low
status: shipped
---

# `lightning channel autopilot` — combined fee + rebalance + suggest daemon

## Description

**As an** experienced node operator who has run the manual
fee/rebalance loop for months and wants to stop thinking about it
**I want** `lightning channel autopilot` — a daemonised verb that
combines `feeadjuster` (passive fees), scheduled `rebalance`
(active when needed), and channel-open suggestions
**So that** my node stays well-balanced and well-connected with
minimal operator attention.

CLBOSS for CLN, scoped to channels (NOT including
auto-funding-new-channels — that decision stays a human's, the
verb only *suggests* opens, doesn't execute them).

**Explicitly post-1.0.** This requires the manual stack
(FEAT-200 fee, FEAT-201 rebalance, FEAT-206 peer score) to be
stable and well-tuned first, otherwise the autopilot just
codifies bad defaults. Run the manual loop for 3-6 months,
*then* decide what the policy should be.

## Implementation

### Surface

```
lightning channel autopilot run [--dry-run]
                                [--config <path>]
lightning channel autopilot status
lightning channel autopilot suggest      # one-shot suggestions
```

`run` is the daemon — invoked from a sidecar timer (every 15min).
`status` reports current state (last fee adjustment, last
rebalance, current suggestions). `suggest` runs only the
channel-open-suggestion phase, useful interactively.

### Cycle

Each `run` iteration:

1. **Read state**: `listpeerchannels`, `listpeers`,
   `wallet balance`, `liquidity totals`.
2. **Passive fees** (delegated to `feeadjuster` plugin if
   present; otherwise apply `fee policy balanced --apply`).
3. **Active rebalance** (only if needed):
   - Identify channels outside the configured ratio band
     (default [10%, 90%]).
   - For each, attempt `lightning rebalance` with a fee cap
     proportional to expected fee recovery (don't rebalance
     for $0.50 if the channel earns $0.05/day).
   - Cap total rebalance spend per day (default 5% of weekly
     fee revenue).
4. **Channel suggestions** (informational only):
   - Identify "missing" connectivity: nodes ranked highly by
     `peer score` (FEAT-206) that we have no path to.
   - Identify "stale" channels: low forwarding activity over
     N weeks, suggest closure.
   - Write suggestions to `$LIGHTNING_DIR/autopilot/
     suggestions-<timestamp>.recfile` for operator review.
   - Never auto-opens or auto-closes.

### Config

`$LIGHTNING_DIR/autopilot.conf` (recfile):

```
enabled:             true
fee_policy:          balanced
rebalance_band_low:  10
rebalance_band_high: 90
rebalance_max_fee_ppm: 500
rebalance_daily_cap_sat: 5000   # max spend per day
suggest_min_score:   8.0        # min Amboss score for suggestions
suggest_stale_weeks: 6          # close-suggest after N stale weeks
```

## Acceptance Criteria

1. `autopilot run --dry-run` performs all reads + computes all
   actions, prints what would happen, doesn't execute.
2. `autopilot run` executes fee adjustments + rebalances within
   configured caps, writes suggestions, exits 0.
3. `autopilot status` reports last-run timestamp, actions taken
   in the last N runs, current rebalance budget remaining.
4. Channel opens / closes are never executed automatically.
5. Sidecar timer wired via `daemon install` (off by default;
   `daemon install --autopilot` opts in).
6. Bats coverage with stubbed everything.

## Out of scope

- Auto-opening new channels — too consequential for autopilot;
  human decision.
- Auto-closing channels — same reason.
- Pricing-graph optimisations (BOSScore-style multi-objective
  fee tuning) — out of our depth, defer to specialised tools.

## Milestone

Post-1.0 — needs FEAT-200/201/204/206 stable, plus 3-6 months
of operator experience with the manual stack to inform what
the policy should actually be.

## See also

- FEAT-200, FEAT-201, FEAT-204, FEAT-206 (the manual verbs
  this combines)
- CLBOSS (lnd): https://github.com/ZmnSCPxj/clboss — the
  reference implementation we'd take inspiration from
- Charge-LND, BOS (balanceofsatoshis) — operator-community
  tools we'd compete-with / learn-from
