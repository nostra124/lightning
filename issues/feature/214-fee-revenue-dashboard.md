---
id: FEAT-214
type: feature
priority: medium
status: research
---

# Fee revenue dashboard

## Description

Once FEAT-213 starts skimming, the operator needs visibility into
how much the node is earning, broken down by operation and over
time, so they can tune rates (manually now, automatically once
FEAT-215 lands) and know the node is sustainable.

## Scope

* New verb: `lightning fee-policy status [--since <date>]`
    * Reads `house` account's ledger
    * Reports: revenue per operation (pay / withdraw / topup),
      daily / weekly / monthly aggregates, top contributing
      accounts (anonymised — first 8 chars of address).
* New HTTP endpoint: `GET /api/admin/fees/summary`
    * Operator-bearer-only (uses a separate API key from a
      reserved `admin` account, or simply requires the bearer
      tied to the operator's account that owns the house).
    * Returns the same data as the verb, JSON-shaped.
* PWA admin view (operator-only) renders the dashboard.  Hidden
  behind a settings toggle and only visible if the bearer maps
  to the operator-account.

## Out of scope

* Auto-tuning logic (FEAT-215).
* Forecasting / what-if simulations.

## Dependencies

* FEAT-213 (skim must be in place before there's revenue to
  display).

## Acceptance criteria

1. `lightning fee-policy status` against a node with no skim
   activity prints a clear "no revenue yet" state.
2. After a synthetic flurry of skims, the dashboard reports
   accurate totals broken down by operation.
3. `/api/admin/fees/summary` is gated by an operator bearer;
   regular account bearers get 403.

## Milestone

1.5.0.
