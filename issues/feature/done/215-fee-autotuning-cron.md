---
id: FEAT-215
type: feature
priority: medium
status: done
---

# Fee auto-tuning cron

## Description

Daily sidecar that nudges the rates in `fees.recfile` based on
observed economics: routing income from clightning's
`listforwards`, operator-fee revenue from the house account
ledger, and an operator-set target monthly net income.

## Scope

* New verb: `lightning fee-policy autotune {run|dry-run|status}`
    * `run` — read 30-day routing income + 30-day skim
      revenue, estimate forward run-rate, nudge rates up/down
      to hit the target.
    * `dry-run` — print the proposed nudge without writing.
    * `status` — show last run + current rate vs. target.

* Safety bounds (read from `fees.recfile`):
    * `target_msat_per_day` — operator's monthly target
      divided by 30.
    * `max_step_per_day_ppm` — clip per-day adjustments to
      avoid oscillation (default 500 ppm = 0.05%).
    * `rate_floor_ppm` / `rate_ceiling_ppm` per operation —
      hard bounds the tuner can't cross.

* Hysteresis: only nudge if observed revenue is more than
  20 % away from target in either direction.

* Sidecar: `lightning daemon install --fee-autotune` writes
  a daily systemd-user timer (same pattern as
  `--account-gc` from FEAT-212 PR-5).

## Out of scope

* Negative-rate / interest mode (FEAT-216).
* Per-account custom rates.
* Live A/B-testing of rate changes.

## Dependencies

* FEAT-213 (rates must exist to nudge).
* FEAT-214 (revenue must be queryable for the tuner to read).

## Acceptance criteria

1. Synthetic data with revenue 50 % below target nudges all
   non-zero rates up by `max_step_per_day_ppm`.
2. Synthetic data with revenue 50 % above target nudges them
   down by the same step.
3. Rates that hit `rate_floor_ppm` / `rate_ceiling_ppm` stop
   moving.
4. `dry-run` writes nothing.
5. Sidecar install writes the timer + service files.

## Milestone

alpha — **implemented**; on master, pre-release.  Part of the feature-complete alpha set.
