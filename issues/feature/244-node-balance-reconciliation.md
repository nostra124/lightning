---
id: FEAT-244
type: feature
priority: high
status: research
---

# Node-balance reconciliation — book externally-initiated flows into an `others` account

## Description

The wallet's books only know about money **our verbs** moved: `pay`,
`invoice`, `send`, the `api-account-*` verbs, and the on-chain
`account topup-watcher` each write a ledger row when they act.  But the
same `lightningd` can be driven by **other clients** — a second wallet
app, a raw `lightning-cli pay`, a phone paying one of our BOLT-11
invoices — and those movements shift real channel liquidity while
leaving **no ledger row**.  As a result `SUM(ledger)` silently drifts
from the node's actual balance.

Two concrete gaps today:

1. **No off-chain settle-watcher.** Incoming Lightning payments (someone
   pays an invoice we minted) are *never* credited to the ledger — only
   on-chain deposits are (via topup-watcher).
2. **External sends are invisible.** A pay made outside our verbs leaves
   the node but is never debited.

This ticket adds a reconciliation pass — the off-chain analog of
topup-watcher — that scans clightning's settled history, skips anything
already booked, and books the residue so the books reconcile.

## Scope (this ticket)

* A seeded, reserved **`others`** account (alongside `house` / `escrow`
  / `-`), `overdraft=allow`, `fund_class` left NULL so it inherits the
  node's `access.recfile` `default_profile` (FEAT-243).
* **`lightning ledger reconcile [run|dry-run|status]`** (lives on the
  `ledger` verb — the ledger source-of-truth):
  * `run` — scan `listpays` (completed) + `listinvoices` (paid); for
    each payment_hash **not already in the ledger**, book:
    * a completed **pay** → `others`, as an `out` of the destination
      amount + a `fee` row for the routing fee when known;
    * a paid **invoice** → the owning account from the `invoices` table
      when known (a receive we minted but never had booked), else
      `others`, as an `in`.  Mark the invoice `state='paid'`.
  * `dry-run` — print the would-book rows; write nothing.
  * `status` — reconcile counts, `others` balance, last reconcile row.
* Dedupe is by **payment_hash** regardless of which verb booked it, so
  reconcile is idempotent and never double-counts our own payments.
* On-chain stays with topup-watcher: its synthetic `txid:vout`
  payment_hash space is disjoint from the off-chain payment hash, so the
  two passes never collide.

## Design decisions

* **Off-chain only; routing forwards out of scope.** `listforwards`
  earnings are routing-node territory (FEAT-188) and net to ~0 liquidity
  change; folding fee income in would mix operator revenue into a
  residual account.  A later ticket can route settled-forward fees to
  `house`.
* **Placement on `ledger`, not a new top-level verb** — colocated with
  the source-of-truth; no new man page, just an extended
  `lightning-ledger.1`.
* **`others` is `fund_class`-neutral.** For a personal node the residual
  is usually the operator on another app (own funds); for a custodial /
  system install it may be third-party money.  Leaving it NULL lets each
  deployment classify it via the node default rather than baking a
  guess into the schema.

## Out of scope (follow-ups)

* Routing-forward fee booking (→ `house` or a dedicated `routing`
  account).
* A timer/cron to run reconcile automatically (compose from the same
  one-shot pattern as `daemon install --topup-watcher`).
* A true balance-audit (`SUM(ledger)` vs live channel+on-chain funds)
  surfaced as a drift figure — blocked on the sign-convention cleanup
  below.
* **Sign-convention bug (separate):** `invoice pay` and `send` book
  `out` rows with a **positive** amount, whereas `api-account-pay` /
  `topup-watcher` (and the `ledger balance` SUM) expect `out` negative.
  CLI-paid accounts therefore mis-total.  Reconcile uses the correct
  (negative-for-out) convention; fixing the two offenders is a small,
  separate bug.

## Acceptance criteria

1. A fresh wallet has a seeded `others` account; an existing wallet
   gets it lazily on the first `reconcile run`.
2. `reconcile run` with a completed pay not in the ledger books an `out`
   (negative) on `others`; a second run is a no-op (deduped).
3. A paid invoice whose payment_hash matches an `invoices` row is
   credited (`in`) to **that** account, not `others`, and the invoice is
   marked `paid`; an unknown paid invoice credits `others`.
4. A payment already booked by one of our verbs is left untouched.
5. `reconcile dry-run` writes nothing; `reconcile status` reports the
   counts + `others` balance.

## Dependencies

* FEAT-193 (the ledger + `ledger` verb), FEAT-212 (the `invoices` table
  + topup-watcher pattern), FEAT-243 (`fund_class` / `default_profile`
  the `others` account inherits).

## Milestone

alpha — the books should reconcile before the feature-complete alpha cut.
