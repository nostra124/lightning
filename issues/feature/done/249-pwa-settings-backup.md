---
id: FEAT-249
type: feature
priority: medium
status: research
---

# PWA Settings — API key display + account backup blob

## Description

The Settings section on the account view currently has "Show API key"
(button) and "Forget account" (button).  This feature wires up:

1. **Show API key** — the button already exists in the PWA skeleton;
   calling `GET /accounts/<id>/api-key` returns `{api_key}` so the
   user can copy the `lt_…` key to give to an LLM agent or CLI.
2. **Download backup** — a "Download backup" button that packages
   `{account_id, api_key}` as a JSON blob and triggers a browser
   download so the user can keep a recovery file.

## Scope

* `api-account-apikey` (new verb) — `GET /accounts/<id>/api-key`,
  auth-required, returns `{api_key}`.
* `accounts.py` — route `GET /accounts/<id>/api-key`.
* `app.js` — wire "Show API key" button; add "Download backup" button
  that downloads `lightning-backup-<short_id>.json`.
* `sudoers.d/lightning` — allow `www-data` to run the new verb.
* `llms.txt` — document the endpoint.
* bats tests.

## Acceptance criteria

1. `GET /accounts/<id>/api-key` with valid bearer returns `{api_key}`.
2. PWA Settings → "Show API key" reveals the key.
3. PWA Settings → "Download backup" downloads a JSON file.

## Milestone

alpha polish (follows FEAT-248).
