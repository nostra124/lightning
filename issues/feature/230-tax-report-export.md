---
id: FEAT-230
type: feature
priority: medium
status: research
---

# Tax report export — operator + user (German law as reference)

## Description

Export all data needed to file a tax declaration, for both the
**operator** (fee revenue = business income) and a **user**
(account gains/losses + private-sale treatment).  German tax
law is the reference because it's among the most intricate for
crypto — if we model it, simpler regimes fall out.

This is data export, not tax advice — we produce the numbers +
the auditable trail; the filer (or their Steuerberater) does
the declaration.

## German specifics to model

* **§23 EStG private sales (Privatveräußerungsgeschäfte)** —
  for a user, disposing of sats (spend / withdraw / transfer
  out) is a private sale.  Gain = fiat-value-at-disposal −
  fiat-value-at-acquisition.
* **1-year holding period** — sats held > 1 year before
  disposal are tax-free; ≤ 1 year are taxable.  Requires
  per-lot acquisition timestamps.
* **FIFO cost basis** — the Finanzamt accepts FIFO; match each
  disposal against the oldest acquisition lots.
* **Freigrenze** — annual exemption (€1000 from 2024; was
  €600).  Report total gains so the filer knows if they cross
  it (it's a Freigrenze, not a Freibetrag — cross it and the
  *whole* amount is taxable).
* **Operator income** — house-account fee revenue is ordinary
  business income (gewerblich / freiberuflich), valued in fiat
  at receipt time.  Separate report.

## Scope

* Verb `lightning tax-report <account|--operator> --year YYYY
  [--base EUR] [--format csv|json]`.
* For a **user account**: walk the ledger, classify each entry
  as acquisition (in) or disposal (out), value each at the
  FEAT-229 price for its timestamp, run FIFO lot-matching,
  compute per-disposal gain + holding period + taxable flag,
  sum by year.  Emit a line-itemised report + a summary
  (total gains, taxable gains, tax-free gains, whether the
  Freigrenze is crossed).
* For the **operator** (`--operator`): the house account's
  fee-revenue entries valued in fiat at receipt, summed by
  period — straight business-income report.
* HTTP: `GET /.well-known/lightning/v1/accounts/<id>/tax-report
  ?year=YYYY&base=EUR&format=csv` (account-bearer); operator
  variant behind the operator credential.
* PWA: Settings → "Download tax report" (FEAT-231).

## Out of scope

* Filing / submission to ELSTER or any tax authority.
* Non-FIFO methods (LIFO, HIFO) — FIFO only for v1.
* Jurisdictions other than DE as the *reference* — the export
  is data-complete enough that other regimes can be derived,
  but we don't ship per-country templates in v1.
* Tax *advice* — we export numbers + the audit trail, nothing
  more.

## Acceptance criteria

1. A user account with acquisitions + disposals across a year
   produces a FIFO-matched report: each disposal shows
   matched-lot acquisition date, holding days, gain, and
   taxable/tax-free per the 1-year rule.
2. The summary flags whether total taxable gains cross the
   Freigrenze.
3. `--operator` produces a fee-revenue report valued in fiat
   at receipt time.
4. CSV + JSON formats both validate.
5. Missing price data for a timestamp → clear gap report
   (don't silently value at 0).

## Dependencies

* FEAT-229 (price history — every line needs a fiat value at
  its timestamp).
* FEAT-228 (commerce events feed disposal/acquisition
  classification for invoice-driven flows).
* FEAT-224 (versioned `.well-known` prefix).

## Milestone

1.7.0.
