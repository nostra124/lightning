---
id: FEAT-253
type: feature
priority: low
status: done
---

# Payment note / memo on outbound pays

## Description

Let users attach a short memo to outbound payments. The `note` column
already exists in the `ledger` table; this feature threads it through
`api-account-pay` (`--note`), the REST API (`note` body field), and the
PWA Send screen (optional note input).

## Scope

* `api-account-pay` — add `--note <text>` arg; write to ledger row.
* `accounts.py` — pass `note` body field to the verb.
* `app.js` — add note input to `screenSend`.

## Acceptance criteria

1. `api-account-pay <id> <target> --note "text"` stores the note.
2. `POST /accounts/<id>/pay` with `{"note":"…"}` stores the note.
3. PWA Send screen has a Note field.

## Milestone

alpha polish (follows FEAT-252).
