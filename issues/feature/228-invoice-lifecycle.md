---
id: FEAT-228
type: feature
priority: medium
status: research
---

# Invoice lifecycle states — escrow, refund, installments, auth/capture, dunning

## Description

The use cases beyond simple pay-now / pay-later share a common
spine: an invoice (or charge) that moves through *states* over
time.  Rather than scatter these across one-off endpoints, model
them as a small state machine on a `commerce_invoices` table.

This is the umbrella for the timing-rich commerce patterns the
design conversation surfaced that don't fit FEAT-225 (simple
commercial invoice), FEAT-226 (standing order), or FEAT-227
(direct debit).

## Patterns covered

* **Escrow / hold-and-release** — customer pays into a held
  state; funds release to the merchant on delivery
  confirmation (or auto-refund on timeout).  Intra-node: the
  sats sit in an escrow sub-balance; release is a transfer
  (FEAT-223).
* **Refund / return** — reverse a settled invoice fully or
  partially; a transfer merchant→customer tagged against the
  original.
* **Installments** — one invoice amortised into N scheduled
  partial payments (distinct from a standing order, which is N
  independent obligations).
* **Auth-and-capture** — reserve an amount now (hold), capture
  ≤ that amount later, release the remainder (deposit / hotel
  pattern).
* **Dunning** — overdue handling for pay-later invoices:
  reminder schedule → late fee (FEAT-225 terms) → suspension /
  write-off.

## State machine (sketch)

```
draft → issued → (paid | partially_paid | overdue | cancelled)
issued → held (escrow) → released | refunded | expired
issued → authorized (hold) → captured | voided
paid → refunded | partially_refunded
overdue → (dunning_1 → dunning_2 → ... ) → paid | written_off
```

## Scope (high level — detailed design when promoted)

* `commerce_invoices` table: id, merchant, customer?, amount,
  state, terms (FEAT-225), created_at, due_at, references.
* `commerce_events` append-only log of state transitions (the
  audit trail + the basis for the tax export, FEAT-230).
* Endpoints under `/.well-known/lightning/v1/accounts/<id>/
  invoices/*` for issue / pay / hold / release / capture /
  void / refund / list.
* The escrow + auth-hold sub-balances are intra-node ledger
  constructs (a reserved bucket on the customer's account).

## Out of scope

* Cross-node escrow (needs a third-party arbiter / HTLC-style
  construct — far future).
* Dispute arbitration UI.

## Dependencies

* FEAT-223 (transfer) — the settlement primitive.
* FEAT-225 (terms) — due dates / Skonto / late fees feed
  dunning + capture math.
* FEAT-224 (versioned `.well-known` prefix).

## Milestone

1.7.0 (commerce epic, second wave — after the 1.6 basics).
