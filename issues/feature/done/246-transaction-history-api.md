---
id: FEAT-246
type: feature
priority: medium
status: research
---

# Transaction history — HTTP endpoint + PWA screen

## Description

The ledger table tracks every credit and debit for each account, but
there is no HTTP endpoint to query it. LLM agents and the PWA have no
way to show a user their payment history. This feature exposes the
ledger via a paginated `GET /accounts/<id>/history` endpoint and adds
a **History** screen to the PWA.

## Scope

* `libexec/lightning/api-account-history` — shell verb that queries
  the ledger for one account; returns `{"entries":[…],"has_more":bool}`.
  Fields per entry: `id, ts, direction, amount_msat, peer,
  payment_hash, message, note`. Default limit 50, max 200; paginate
  backwards via `--before <id>`.
* `accounts.py` — `GET /accounts/<id>/history[?limit=N&before=ID]`
  route; session/key authed.
* `app.js` — `screenHistory` renders entries as cards (amount in sat,
  direction coloured green/red, timestamp, message/peer label);
  "Older" button pages backwards. "History" button added to the
  account overview.
* `llms.txt` updated.

## Acceptance criteria

1. `GET /.well-known/lightning/v1/accounts/<id>/history` returns 200
   + JSON with `entries` array and `has_more` boolean.
2. Each entry has `direction`, `amount_msat`, `ts`, `message`.
3. `?before=<id>` paginates backwards correctly.
4. The PWA account screen has a History button.
5. `screenHistory` renders entries and a load-more button.

## Milestone

alpha polish (FEAT-209 PR-3 item).
