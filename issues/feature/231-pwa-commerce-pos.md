---
id: FEAT-231
type: feature
priority: medium
status: research
---

# PWA commerce + point-of-sale interface

## Description

Surface the core-banking + commerce features (FEAT-223/225/226/
227) in the wallet PWA (FEAT-209), including a **point-of-sale
(POS)** mode so a merchant can take payments face-to-face.

## Scope

* **POS screen** — merchant enters an amount (with a fiat
  keypad backed by FEAT-229 price), optionally an order /
  reference; the PWA mints a commercial invoice (FEAT-225) +
  shows a big QR; polls until paid; shows a "paid" confirmation
  + prints/share a receipt.  The everyday market-stall / café
  flow.
* **Transfers** — send to another local account (FEAT-223) by
  picking a contact / pasting a handle.
* **Standing orders** — create / list / pause / cancel
  (FEAT-226) from Settings.
* **Direct-debit mandates** — authorize a merchant, switch a
  mandate between auto (a) and per-pull-approval (b), approve/
  deny pending pulls (FEAT-227).  The approval inbox is the
  customer-facing half of mode (b).
* **Fiat display** — amounts shown in the user's base currency
  alongside sats, everywhere (FEAT-229).
* **Tax-data export** — Settings → "Export transaction data
  (for tax)" (FEAT-230).  It's a data download, not a report.

## Out of scope

* Hardware-terminal integrations (NFC card readers, etc.).
* Inventory / catalog management — POS is amount-entry only;
  catalogs are a downstream webshop concern.
* Multi-operator marketplace UI.

## Dependencies

* FEAT-209 PR-2 (the PWA must exist first).
* FEAT-223 (transfer), FEAT-225 (commercial invoice),
  FEAT-226 (standing order), FEAT-227 (mandates),
  FEAT-229 (fiat price), FEAT-230 (tax-data export) — surfaces all
  of them.

## Milestone

1.7.0 (lands as the commerce features stabilise; pieces can
ship incrementally as each backend feature lands).
