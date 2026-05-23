---
id: FEAT-219
type: feature
priority: medium
status: done
---

# Referral fee distribution

## Description

Splits each FEAT-213 fee skim between the house account and the
fee-payer's direct referrer.  Configurable percentages in
`fees.recfile`.  Single-level only — we don't walk the referrer
chain.

## Scope

* `fees.recfile` gains a new record:

  ```
  referral_split: direct=20
  referral_split: house=80
  ```

  Sum must be 100.  Default: `direct=0 house=100` (no split —
  back-compat with FEAT-213 standalone).

* At fee-skim time in the modified verbs (api-account-pay /
  withdraw / topup-onchain):
    1. Compute total fee F (same as FEAT-213).
    2. Look up the user's `referrer` (defaults to `house`).
    3. Compute `F_direct = F * direct_pct / 100`,
       `F_house = F - F_direct`.
    4. Book separate ledger entries — `house` and the direct
       referrer each get their share, with `message='referral
       credit from <user>'` on the referrer's row for
       traceability.

* Sybil defences (all read from `fees.recfile`):
    * `referral_min_referee_activity_sat` — referee must have
      transacted at least N sats of non-fee volume before
      their fees start crediting their referrer (default
      10 000 sat).
    * `referral_max_credit_per_referrer_per_day_sat` — cap on
      daily credits a single referrer can accrue (default
      10 000 sat).
    * Operator can override either by setting `referrer =
      'house'` on an account manually (administrative escape
      hatch for abuse).

## Out of scope

* Multi-level cascade.
* PWA UX (FEAT-220).
* Cross-account credit transfers other than the automatic skim
  split.

## Dependencies

* FEAT-213 (skim primitives must exist).
* FEAT-218 (referrer column must exist).

## Acceptance criteria

1. With `referral_split: direct=20 house=80` and a user whose
   referrer is `alice`, a 100-sat fee credits 20 sat to alice +
   80 sat to house.
2. A user with `referrer = 'house'` (the default) has the full
   fee credited to house (no double-counting).
3. A referee under the min-activity threshold is treated as
   `referrer = 'house'` for skim purposes until they cross the
   threshold.
4. Once a referrer hits the daily cap, additional credits
   route to house instead.
5. Setting both splits to zero or one-side-100 is accepted;
   sums other than 100 are rejected with a clear error.

## Milestone

alpha — **implemented**; on master, pre-release.  Part of the feature-complete alpha set.

## See also

* FEAT-213 — fee skim primitives.
* FEAT-218 — referral schema (provides `referrer`).
* FEAT-220 — PWA UX.
