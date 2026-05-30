---
id: FEAT-248
type: feature
priority: medium
status: done
---

# PWA Send UX — label, fee display, copy buttons

## Description

Polish the Send screen label ("Invoice / Lightning address / offer"),
show `fee_sat` in payment receipt toast, and add Copy buttons to the
BOLT-11 invoice and BOLT-12 offer receive displays.

## Scope

* `app.js` — updated Send label + placeholder; fee_sat in receipt;
  Copy buttons on `screenRecv` invoice and offer tabs.

## Acceptance criteria

1. Send input placeholder shows `lnbc… · lno… · user@domain.com`.
2. Payment receipt toast includes fee.
3. Copy buttons on invoice/offer call `navigator.clipboard.writeText`.

## Milestone

alpha polish (follows FEAT-247).
