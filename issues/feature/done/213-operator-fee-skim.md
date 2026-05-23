---
id: FEAT-213
type: feature
priority: high
status: done
---

# Operator-fee skim primitives

## Description

The operator's node has real costs (server, electricity, channel
liquidity, on-chain fees) and the existing FEAT-212 endpoints
move value without billing for it.  This ticket makes the
account API self-funding by skimming a configurable fee on every
value-moving operation and crediting it to a special `house`
account.

## Scope

* New `fees.recfile` under the wallet repo (git-tracked, plain
  text, operator-edited).  One record per operation kind:

  ```
  operation: pay
  base_sat:  1
  rate_ppm:  5000    # 0.5%
  ```

* Recognised operations for v1: `pay`, `withdraw`,
  `topup-onchain`.  `topup-ln` and `recv` ship with zero default
  fee (no skim) but are recognised so the operator can opt in.
* Default `fees.recfile` seeded on first install with modest
  rates the operator can tune.

* `house` account auto-created the first time a skim is
  attempted (lazy bootstrap, no schema migration step needed
  beyond `INSERT OR IGNORE`).  Uses a reserved name `house`
  that the GC (FEAT-212 PR-5) excludes from cleanup, same
  treatment as `-`.

* Modified shell verbs:
    * `api-account-pay`  — skims, books the operator fee + the
      network fee as separate ledger entries; rejects if the
      user's balance can't cover `amount + network_fee +
      operator_fee`.
    * `api-account-withdraw` — same skim pattern, fee atop the
      submarine-swap cost.
    * `api-account-topup` watcher (FEAT-212 PR-4) — skims at
      credit time; user gets `deposited - fee`.

* **Itemised ledger entries**.  A single `api-account-pay` call
  now writes multiple rows:
    1. user account, `out`, `-amount_msat`,         `message='api pay'`
    2. user account, `out`, `-network_fee_msat`,    `message='network fee'`
    3. user account, `out`, `-operator_fee_msat`,   `message='operator fee'`
    4. house account, `in`,  `+operator_fee_msat`,  `message='fee from <user>'`

  All four rows share the same `payment_hash` for traceability.
  Ledger sum across all accounts stays at zero (modulo external
  inflow/outflow), making double-entry-style audits trivial.

* HTTP response envelopes grow `network_fee_sat` + `operator_fee_sat`
  fields so the PWA can show the breakdown to the user.

## Out of scope (deferred to sibling tickets)

* Auto-tuning of the rates (FEAT-215).
* Operator-side revenue dashboard (FEAT-214).
* Negative rates / interest mode (FEAT-216).
* Referral split of the skim (FEAT-219).

## Dependencies

None — extends FEAT-212 PR-2 verbs in place.

## Acceptance criteria

1. With default `fees.recfile`, paying a 10 000-sat invoice
   debits 10 000 (payment) + the routing fee + 51 sat (1 +
   10 000 × 5000 / 1_000_000) operator fee; house balance goes
   up by 51 sat.
2. Topping up 100 000 sat on-chain credits 99 800 sat to the
   user (200-sat skim at the 2000 ppm default for
   `topup-onchain`).
3. Pay request that would over-draw (user has 100, invoice is
   100, fees add 5) returns 402 + `balance_insufficient`.
4. Setting `rate_ppm: 0` for an operation disables the skim
   for that op (back-compat path for operators who don't want
   to charge yet).
5. `house` account is auto-created on first skim; GC sidecar
   doesn't touch it.

## Phasing

Single PR.  Schema additive (just the `INSERT OR IGNORE` for
`house`); fees.recfile is plain text; verb changes are local.

## Milestone

alpha — **implemented**; on master, pre-release.  Part of the feature-complete alpha set.

## See also

* FEAT-212 — account API + cron sidecars this extends.
* FEAT-214 — fee revenue dashboard (depends on this).
* FEAT-215 — auto-tuning cron (depends on this + 214).
* FEAT-216 — interest mode (depends on 215).
* FEAT-219 — referral-fee distribution (depends on this + 218).
