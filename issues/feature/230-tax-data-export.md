---
id: FEAT-230
type: feature
priority: medium
status: research
---

# Tax-relevant transaction data export — operator + user

## Description

Export a complete, fiat-valued transaction record so the user
(or their Steuerberater) can **later prepare a tax
declaration** from it.  This is explicitly **not a tax report**
and not a filled-in declaration — it's the *source data*:
every movement, valued in a base fiat at the time it happened,
with acquisition/disposal classification + holding periods
worked out.  Producing the actual report (and any advice) is
the filer's job; we just make the inputs complete + auditable.

German tax law is the reference for *what fields to include*
(it's among the most intricate for crypto), so the export
carries enough to satisfy it; simpler regimes need a subset.

## What "tax-relevant" means here (German reference)

The export includes the data points German private-sale
taxation needs, so nothing has to be reconstructed later:

* **§23 EStG private-sale framing** — each disposal (spend /
  withdraw / transfer out) carries its fiat value at disposal
  *and* the fiat value at acquisition of the matched lot, so
  the gain is computable.  We surface the numbers; we don't
  assert a tax liability.
* **Holding period** — per-lot acquisition timestamps + the
  holding days at disposal, so the >1-year (tax-free) vs
  ≤1-year line can be drawn by the filer.
* **FIFO lot matching** — disposals matched against oldest
  acquisitions (the method the Finanzamt accepts), with the
  matching shown so it's auditable / overridable.
* **Annual totals** — gains summed by year + a note of the
  Freigrenze threshold (informational — we report the number,
  the filer decides the treatment).
* **Operator income rows** — the house account's fee-revenue
  entries, fiat-valued at receipt, exported separately (the
  operator's business-income inputs).

## Scope

* Verb `lightning export tax-data <account|--operator>
  --year YYYY [--base EUR] [--format csv|json]`.
  (Named *export* / *tax-data*, never "report" — the output
  is source data, not a report.)
* For a **user account**: walk the ledger, classify each entry
  as acquisition (in) or disposal (out), value each at the
  FEAT-229 price for its timestamp, run FIFO lot-matching,
  emit per-disposal rows (matched-lot acquisition date,
  holding days, fiat-in, fiat-out, gain) + an annual summary.
  Clearly labelled "transaction data for tax preparation".
* For the **operator** (`--operator`): the house account's
  fee-revenue entries valued in fiat at receipt, line-itemised
  + summed by period.
* HTTP: `GET /.well-known/lightning/v1/accounts/<id>/export
  /tax-data?year=YYYY&base=EUR&format=csv` (account-bearer);
  operator variant behind the operator credential.
* PWA: Settings → "Export transaction data (for tax)"
  (FEAT-231) — wording makes clear it's data, not a report.

## Out of scope

* **Producing a tax report / declaration** — out by design.
  We export inputs; the report is the filer's (or their
  advisor's) deliverable.
* Filing / submission to ELSTER or any tax authority.
* Tax *advice* of any kind.
* Non-FIFO methods (LIFO, HIFO) — FIFO matching shown for v1
  (the raw rows are method-agnostic, so a preparer can
  re-match if they want).
* Jurisdictions other than DE as the *reference* — the export
  is data-complete enough that other regimes can be derived;
  no per-country templates in v1.

## Acceptance criteria

1. A user account with acquisitions + disposals across a year
   produces a FIFO-matched **data export**: each disposal row
   shows matched-lot acquisition date, holding days, fiat-in,
   fiat-out, and gain.  Output is labelled as transaction data
   for tax preparation, not a report.
2. The annual summary reports total gains + notes the
   Freigrenze threshold value (informational only).
3. `--operator` exports fee-revenue rows valued in fiat at
   receipt.
4. CSV + JSON formats both validate.
5. Missing price data for a timestamp → an explicit gap marker
   in the row (never silently valued at 0).

## Dependencies

* FEAT-229 (price history — every row needs a fiat value at
  its timestamp).
* FEAT-228 (commerce events feed disposal/acquisition
  classification for invoice-driven flows).
* FEAT-224 (versioned `.well-known` prefix).

## Milestone

1.7.0.
