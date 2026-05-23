---
id: FEAT-216
type: feature
priority: low
status: research
---

# Interest mode — pay users when routing is flush

## Description

When FEAT-215's auto-tuner finds the operator's revenue is
significantly over target, allow the configured fee rates to go
**negative** — the operator pays users for parking sats.  The
subsidy comes from accumulated routing income in the house
account.

Marketing angle: "earn yield on your Lightning balance."
Operational angle: idle balances are providing the liquidity
the operator's channels need; sharing some of the proceeds is
fair *and* differentiating.

## Scope

* `fees.recfile` gains an optional `interest_mode: on|off` flag
  per operation.  When on, the auto-tuner may drive that rate
  negative (down to `rate_floor_ppm`, which becomes a *negative*
  bound).
* At skim time, a negative rate means a credit: user gets
  `amount + |fee|` instead of `amount - fee`.  The subsidy is
  booked as a debit on the house account.
* PWA displays the active rate as a positive APR
  ("+1.2 % effective annual yield this month") when in
  interest mode for at least one operation the user is using.
* Operator-side: `lightning fee-policy status` flags interest
  mode + the cumulative subsidy paid.

## Out of scope

* Per-account custom yields.
* Compound interest on idle balances (this is per-transaction
  yield, not interest on stored balance).
* Legal disclaimers or compliance plumbing — operator's
  responsibility to know their jurisdiction.

## Honest caveat

In many jurisdictions, paying yield on customer-deposited funds
is regulated as deposit-taking.  Spec ships with `interest_mode:
off` as the default and a prominent comment in
`fees.recfile` pointing the operator at their legal advisor.
This is **opt-in only**.

## Dependencies

* FEAT-215 (the auto-tuner needs to know about negative rates).

## Acceptance criteria

1. With `interest_mode: on` for `topup-onchain` and a rate of
   `-2000` ppm, a 100 000-sat deposit credits the user 100 200.
2. House account ledger shows a -200-sat debit with the matching
   `payment_hash`.
3. With `interest_mode: off` (default), negative rates are
   rejected with a clear error from the auto-tuner.
4. PWA's yield indicator appears only when interest mode is
   active for at least one operation.

## Milestone

alpha — must ship before the feature-complete **alpha** cut (alpha = everything implemented; then beta hardening; then 1.0.0 is a formal version bump).
