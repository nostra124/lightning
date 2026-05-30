---
id: FEAT-225
type: feature
priority: medium
status: research
---

# Commercial invoice with structured reference + payment terms

## Description

Enable real e-commerce: a merchant issues a Lightning invoice
that carries a structured reference (order id, delivery-note
number, shipment id) so that when the customer pays, the
merchant reconciles the settled payment back to the order by
`payment_hash`.  This is the "classical delivery → pay-invoice
with reference to the delivery note" flow.

The invoice also carries **payment terms** — a due date, an
early-payment discount (Skonto), and a late fee — so the
amount actually due is computed *at pay time* based on *when*
the customer pays.  This is the time-dimension of commerce
that cuts across pay-before / pay-after / direct-debit.

No Lightning protocol extension needed — the reference + terms
ride in the BOLT-11 `description` (or BOLT-12 metadata).  This
ticket defines the *standard convention* so webshops parse it
predictably.

## Scope

* New verb + endpoint `POST /.well-known/lightning/accounts/
  <id>/invoice` (commercial variant of `recv`):
    body: `{ "sat": <int>, "reference": { "order_id": "...",
            "delivery_note": "...", "shipment_id": "...",
            "memo": "..." } }`
    The `reference` object is serialised into the invoice
    `description` under a documented convention (a `ref:`
    JSON tail) so it round-trips on settle.
* On settle (detected via the existing invoice state tracking
  / a `listinvoices` poll), the merchant can query
  `GET .../invoice/<payment_hash>` to get the reference back
  + the paid status.
* The structured-reference convention is documented in the
  inline docs (FEAT-209) + as a short "standard" note so
  third-party webshop plugins can implement against it.
* BOLT-12 variant: same reference object goes into the
  offer's metadata for reusable merchant offers.

## Payment terms (Skonto / due date / late fee)

The invoice body accepts an optional `terms` object:

```json
{
  "sat": 100000,
  "reference": { "order_id": "..." },
  "terms": {
    "due_days": 14,
    "skonto": { "within_days": 7, "discount_pct": 2 },
    "late_fee": { "after_days": 14, "pct": 5 }
  }
}
```

* The invoice records `issued_at`.  At pay time the verb
  computes the **effective amount**:
    * paid within `skonto.within_days` → `sat × (1 −
      discount_pct/100)` (early-payment discount);
    * paid after `due_days + late_fee.after_days` → `sat ×
      (1 + late_fee.pct/100)`;
    * otherwise the face amount.
* Because the amount is time-dependent, a terms-bearing
  invoice is issued as an *amount-flexible* request (the
  customer's pay call states the amount they're paying; the
  merchant side validates it matches the effective amount for
  the pay timestamp).  Fixed-amount BOLT-11 still works for
  the no-terms case.
* `GET .../invoice/<hash>` reports the face amount, the
  current effective amount (for "if you pay now"), and the
  terms — so a POS / webshop can show "pay €X now (2% Skonto)
  / €Y after <date>".

## Out of scope

* Standing order (FEAT-226) + direct debit (FEAT-227).
* The full overdue → dunning state machine (FEAT-228) — this
  ticket computes the late-fee *amount*; the dunning
  *workflow* (reminders, suspension) is FEAT-228.
* A full webshop plugin — we define the API + convention;
  plugins are downstream.
* Refund flows (FEAT-228).

## Acceptance criteria

1. Creating a commercial invoice with a reference embeds it
   recoverably in the BOLT-11 description.
2. After (mock) settlement, `GET .../invoice/<hash>` returns
   the original reference + `paid: true`.
3. The reference convention is documented + has a parse
   example a webshop can copy.
4. A terms-bearing invoice computes the effective amount
   correctly across the three windows (Skonto / face / late).
5. `GET .../invoice/<hash>` reports face + effective + terms.

## Dependencies

* FEAT-224 (so the endpoint lands at the versioned
  `.well-known` prefix).
* Builds on FEAT-212 PR-2's `recv` plumbing.
* Feeds FEAT-228 (the late-fee amount feeds the dunning
  workflow) + FEAT-230 (terms-derived amounts feed the tax
  export).

## Milestone

alpha — must ship before the feature-complete **alpha** cut (alpha = everything implemented; then beta hardening; then 1.0.0 is a formal version bump).
