---
id: FEAT-250
type: feature
priority: medium
status: research
---

# PWA — import account from backup blob

## Description

FEAT-249 adds a "Download backup" button.  This feature closes the loop
by letting users restore an account from that backup file.  On the
account picker screen add an "Import from backup file" button that reads
a `lightning-backup-*.json` file and adds the account to the local store.

## Scope

* `app.js` — add "Import backup" button to `screenPicker`; file-input
  handler reads JSON, validates `{account_id, api_key}`, calls
  `addAccount(account_id, api_key, label?)`, and navigates to the
  account view.  Show toast on success or error.

No backend changes needed — the backup file contains everything.

## Acceptance criteria

1. Picker screen has an "Import backup" button / file input.
2. Uploading a valid backup JSON adds the account and navigates to it.
3. Uploading an invalid file shows an error toast.

## Milestone

alpha polish (follows FEAT-249).
