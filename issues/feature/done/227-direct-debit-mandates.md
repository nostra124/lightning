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

Lightning is push-only, but a "pull" works in **both**
topologies:

* **Intra-node** (both accounts local) — a gated intra-node
  ledger op (FEAT-223 transfer).  The operator moves the sats
  on the merchant's behalf, bounded by the mandate.
* **Cross-node** — because every node exposes the well-known
  API publicly, the merchant POSTs to the *customer's*
  `/.well-known/lightning/v1/accounts/<id>/mandates/<id>/
  charge` endpoint; the customer's node validates the mandate
  and **pushes** a one-time payment to the merchant.  The
  pull is really "merchant-triggered, customer-side-executed
  push, gated by a pre-authorized mandate" — Lightning's
  push-only nature is respected.  (Earlier draft deferred
  cross-node; the well-known-API insight makes it tractable.)

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
  — the charge trigger.  Resolution:
    * **Intra-node** (customer is local) — mode (a) executes
      immediately as a ledger transfer (FEAT-223); mode (b)
      creates a pending pull + notifies the customer.
    * **Cross-node** (customer is on another node) — the
      merchant calls the *customer node's*
      `.../mandates/<id>/charge` endpoint; the customer node
      validates the mandate + (mode a) pushes a one-time
      payment to the merchant, or (mode b) holds for
      approval then pushes.  The push reuses the existing
      `pay` path.
* Per-period cap enforced: a pull that would exceed
  `max_per_period` within the current window is rejected
  (mode a) or held (mode b).
* Operator fee: each executed pull pays the `transfer` fee
  tier intra-node, or the `pay` fee tier cross-node
  (FEAT-213/219).
* Mandate authentication: the charge request must prove it
  comes from the mandated merchant (a per-mandate shared
  secret issued at authorization time, presented as a bearer
  on the charge call).

## Out of scope

* Dispute / chargeback flow.
* Mandate transfer between merchants.
* Cross-node *liveness* guarantees — if the customer node is
  offline at charge time, the merchant retries; we don't
  queue on the customer side beyond the mandate record.

## Acceptance criteria

1. Customer creates a mode-(a) mandate; merchant pulls within
   the cap → executes immediately (intra-node ledger transfer
   OR cross-node customer-push).
2. A pull exceeding `max_per_period` in the window is
   rejected.
3. Switching the mandate to mode (b): the next merchant pull
   lands `pending`; customer `approve` executes it, `deny`
   cancels it.
4. Revoking a mandate blocks further pulls.
5. A charge call without the mandate's shared secret is
   rejected `401`.

## Dependencies

* FEAT-223 (intra-node transfer is the intra-node execution
  primitive).
* FEAT-212 PR-2 `pay` (the cross-node push primitive).
* FEAT-224 (versioned endpoint prefix).
* FEAT-225 (the `reference` on a pull reuses the commercial-
  invoice reference convention).

## Milestone

alpha — must ship before the feature-complete **alpha** cut (alpha = everything implemented; then beta hardening; then 1.0.0 is a formal version bump).
