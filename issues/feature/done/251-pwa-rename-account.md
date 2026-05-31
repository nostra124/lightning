---
id: FEAT-251
type: feature
priority: low
status: research
---

# PWA Settings — rename account label

## Description

Account labels are device-local (stored in localStorage with the account).
There is currently no way to change the label after account creation.
Add a simple rename field to the Settings screen.

## Scope

* `app.js` — add label input + "Save label" button to `screenSettings`;
  on save call `upsertAccount` with the new label and show a toast.

No backend changes needed.

## Acceptance criteria

1. Settings screen shows the current label in an editable input.
2. Saving updates `localStorage` and shows a success toast.

## Milestone

alpha polish (follows FEAT-250).
