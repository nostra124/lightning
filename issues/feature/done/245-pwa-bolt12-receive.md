---
id: FEAT-245
type: feature
priority: medium
status: research
---

# PWA — BOLT-12 reusable offer on the Receive screen

## Description

The Receive screen today only mints single-use BOLT-11 invoices.
The backend already exposes `POST /accounts/<id>/recv-reusable`
(FEAT-212 PR-2) which creates a BOLT-12 offer — reusable by any
number of payers and suitable for sharing in a bio, QR code, or
profile.

Add a two-tab layout to `screenRecv`: the existing BOLT-11 flow
stays on the first tab; a new "Reusable offer (BOLT-12)" tab calls
`/recv-reusable`.  The amount field accepts a positive integer or
is left blank for any-amount offers.

## Scope

* `screenRecv` grows two tabs: **Invoice (BOLT-11)** (default)
  and **Reusable offer (BOLT-12)**.
* BOLT-12 tab: amount field (blank = any), description field,
  "Get reusable offer" button.
* On success the offer string (`lno1…`) is displayed with a note
  that it is reusable.
* No other changes — backend, CLI, man pages, llms.txt are
  unaffected.

## Acceptance criteria

1. `screenRecv` renders two tab buttons.
2. Clicking "Reusable offer (BOLT-12)" calls `/recv-reusable`.
3. Leaving the amount blank sends `sat: "any"` to the API.
4. The response `bolt12` string is displayed.

## Milestone

alpha polish (FEAT-209 PR-3 item).
