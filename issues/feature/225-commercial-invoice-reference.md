---
id: FEAT-225
type: feature
priority: medium
status: research
---

# Commercial invoice with structured order / shipment reference

## Description

Enable real e-commerce: a merchant issues a Lightning invoice
that carries a structured reference (order id, delivery-note
number, shipment id) so that when the customer pays, the
merchant reconciles the settled payment back to the order by
`payment_hash`.  This is the "classical delivery → pay-invoice
with reference to the delivery note" flow.

No Lightning protocol extension needed — the reference rides
in the BOLT-11 `description` (or BOLT-12 offer/invoice
metadata).  This ticket defines the *standard convention* so
webshops parse it predictably.

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

## Out of scope

* Standing order (FEAT-226) + direct debit (FEAT-227).
* A full webshop plugin — we define the API + convention;
  plugins are downstream.
* Refund flows.

## Acceptance criteria

1. Creating a commercial invoice with a reference embeds it
   recoverably in the BOLT-11 description.
2. After (mock) settlement, `GET .../invoice/<hash>` returns
   the original reference + `paid: true`.
3. The reference convention is documented + has a parse
   example a webshop can copy.

## Dependencies

* FEAT-224 (so the endpoint lands at the `.well-known` prefix).
* Builds on FEAT-212 PR-2's `recv` plumbing.

## Milestone

1.6.0 (commerce epic — post the core 1.5 train).
