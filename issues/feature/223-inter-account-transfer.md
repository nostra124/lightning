---
id: FEAT-223
type: feature
priority: high
status: research
---

# Inter-account transfer — the core-banking primitive

## Description

**As an** account holder on a `lightning` node
**I want** to move sats to another account on the *same* node
**So that** family/friends and merchant/customer pairs can settle
instantly + for free without touching the Lightning network.

This is the foundation the commerce epic builds on: a direct
debit is "merchant pulls from customer (both local)", a
standing order can target a local account, etc.  All of them
reduce to an atomic intra-node ledger debit+credit.

## Scope

* New verb `api-account-transfer <from-addr> <to> <sat>` +
  HTTP `POST /api/accounts/<id>/transfer {to, sat, note?}`.
  `to` resolves by address, nickname, or legacy name.
* Atomic: a single SQLite transaction writes the debit
  (`from`, out) + credit (`to`, in), same `payment_hash`-
  style correlation id (`xfer:<uuid>`).
* Balance check on the sender honouring the existing
  overdraft policy (deny / warn / allow from FEAT-195).
* Optional operator fee on transfers — a new `transfer`
  operation in `fees.recfile` (default 0; intra-node moves
  are cheap so the operator may keep them free).
* `note` is free text stored on both ledger rows for the
  human statement.
* CLI mirror: `lightning account transfer <from> <to> <sat>
  [--note <text>]`.

## Out of scope

* Cross-node transfers (that's just `pay` — FEAT-212 PR-2).
* Scheduling (standing order — FEAT-226).
* Authorization mandates (direct debit — FEAT-227).

## Acceptance criteria

1. Transfer 1000 sat A→B: A's balance −1000, B's +1000,
   both ledger rows share the correlation id.
2. Transfer that would overdraw A (overdraft=deny) returns
   402 + `balance_insufficient`; no rows written
   (transaction rolls back).
3. Transfer to an unknown `to` returns 404.
4. With a non-zero `transfer` fee configured, the operator
   fee is skimmed to house + referral-split per FEAT-219.

## Dependencies

None — extends the FEAT-212 account API + FEAT-213/219 fee
machinery in place.

## Milestone

1.5.0.
