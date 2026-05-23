---
id: FEAT-227
type: feature
priority: medium
status: research
---

# Direct debit (Lastschrift) + mandates

## Description

**As a** merchant
**I want** to pull a payment from a customer's account under a
prior authorization (a mandate)
**So that** recurring/variable billing works without the
customer re-approving each charge — while still giving the
customer more control than SEPA does.

Lightning is push-only, so a "pull" only works cleanly when
both accounts live on the *same node* (it's a gated intra-node
ledger op — FEAT-223).  Cross-node pull is explicitly deferred.

## The two modes

Per the design decision, both ship; the customer chooses:

* **(a) Mandate (default, SEPA-style)** — customer authorizes
  merchant M to pull up to `max_per_period` every `period`.
  M's pulls execute immediately (intra-node ledger op) without
  per-charge approval.  Convenient.
* **(b) Per-pull approval (customer-switchable)** — every pull
  creates a *pending* authorization the customer must approve
  (push notification / PWA prompt / API poll).  Fills the SEPA
  gap (where you can't approve individual debits).  The
  customer flips a mandate to this mode at will.

## Scope

* New `mandates` table:
    ```sql
    CREATE TABLE mandates (
        id              TEXT PRIMARY KEY,    -- mdt_<...>
        merchant        TEXT NOT NULL REFERENCES accounts(name) ON DELETE CASCADE,
        customer        TEXT NOT NULL REFERENCES accounts(name) ON DELETE CASCADE,
        max_per_period  INTEGER NOT NULL,
        period          TEXT NOT NULL,       -- 'daily'|'weekly'|'monthly'
        mode            TEXT NOT NULL DEFAULT 'auto',  -- 'auto'|'approval'
        status          TEXT NOT NULL DEFAULT 'active',
        created_at      INTEGER NOT NULL
    );
    CREATE TABLE mandate_pulls (
        id          TEXT PRIMARY KEY,
        mandate     TEXT NOT NULL REFERENCES mandates(id) ON DELETE CASCADE,
        sat         INTEGER NOT NULL,
        reference   TEXT,                    -- FEAT-225 order/shipment ref
        state       TEXT NOT NULL,           -- 'pending'|'approved'|'executed'|'denied'
        created_at  INTEGER NOT NULL
    );
    ```
* Customer-side: `POST .../mandates` to authorize a merchant;
  `PATCH .../mandates/<id>` to switch mode / pause / revoke;
  `POST .../mandates/<id>/pulls/<pull_id>/approve|deny` for
  mode (b).
* Merchant-side: `POST .../mandates/<id>/pull {sat, reference}`
  — in mode (a) executes immediately (intra-node transfer via
  FEAT-223), in mode (b) creates a pending pull + notifies the
  customer.
* Per-period cap enforced: a pull that would exceed
  `max_per_period` within the current window is rejected
  (mode a) or held (mode b).
* Operator fee: each executed pull pays the `transfer` fee
  tier (FEAT-213/219).

## Out of scope

* **Cross-node direct debit** — needs a customer-side
  responder / LNURL-withdraw-style mechanism; not in this
  ticket.  Intra-node only for v1.
* Dispute / chargeback flow.
* Mandate transfer between merchants.

## Acceptance criteria

1. Customer creates a mode-(a) mandate; merchant pulls within
   the cap → executes immediately as an intra-node transfer.
2. A pull exceeding `max_per_period` in the window is
   rejected.
3. Switching the mandate to mode (b): the next merchant pull
   lands `pending`; customer `approve` executes it, `deny`
   cancels it.
4. Revoking a mandate blocks further pulls.
5. Cross-node pull attempts return a clear
   `cross_node_not_supported` error.

## Dependencies

* FEAT-223 (intra-node transfer is the execution primitive).
* FEAT-224 (endpoint prefix).
* FEAT-225 (the `reference` on a pull reuses the commercial-
  invoice reference convention).

## Milestone

1.6.0 (commerce epic).
