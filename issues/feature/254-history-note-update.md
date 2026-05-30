---
id: FEAT-254
type: feature
priority: low
status: research
---

# PATCH /accounts/<id>/history/<entry_id> — update ledger note

## Description

FEAT-253 lets users set a note at pay time.  This feature lets users
annotate any historical ledger entry after the fact: `PATCH
/accounts/<id>/history/<entry_id>` with `{"note":"…"}` updates the
`note` column for that row.

## Scope

* `api-account-history-note` (new verb) — takes `<address> <entry_id>
  <note>`; validates entry belongs to account; UPDATE ledger.
* `accounts.py` — route `PATCH .../history/<entry_id>`.
* `app.js` — in `screenHistory`, each entry row gets an "edit note"
  inline input that PATCHes on blur.
* `sudoers.d/lightning` — allow verb.
* bats tests.

## Acceptance criteria

1. `PATCH /accounts/<id>/history/<entry_id>` with `{"note":"…"}`
   updates the ledger row and returns `{ok:true}`.
2. PWA history rows have an editable note field.

## Milestone

alpha polish (follows FEAT-253).
