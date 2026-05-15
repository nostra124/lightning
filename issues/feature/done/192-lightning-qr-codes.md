---
id: FEAT-192
type: feature
priority: high
status: done
---

# Lightning QR codes — invoices, addresses, offers

## Description

**As a** Lightning user receiving a payment
**I want** `lightning qr <text>`, plus `--qr` on every verb
that emits a string a payer would scan (invoice, address,
offer, LNURL)
**So that** receiving on Lightning doesn't require a separate
QR tool, and demos / posters / shop displays work straight
out of the box.

Receiving over Lightning is overwhelmingly QR-driven (phone
camera scanning a screen). Today nothing in the planned verb
set emits a QR — this ticket closes that gap.

## Implementation

1. **Generic verb**:

       lightning qr <text>          # detect type, render to terminal
       lightning qr <text> --png <file>
       lightning qr <text> --svg <file>
       lightning qr <text> --ansi   # default; utf-8 half-block

2. **Auto `--qr` on string-emitting verbs** — the verb prints
   the string as before, then a blank line, then the QR
   (terminal-friendly). Verbs:
   - `lightning invoice ... --qr`
   - `lightning address show <addr> --qr`
   - `lightning offer ... --qr` (BOLT-12)
3. **Soft dep on `qrencode`**. If missing, fall back to a
   small awk QR renderer (rough but readable) and print a
   `# install qrencode for crisp QR` hint.
4. **HTTP `/qr` endpoint** on the standalone address daemon
   (FEAT-176) and `lightning serve` (FEAT-190): returns a PNG
   for in-browser display.

## Acceptance Criteria

1. `lightning qr lnbc1...` prints a scannable QR in a
   standard 80-column terminal.
2. `lightning invoice 1000 'coffee' --qr` produces both the
   BOLT-11 string and a scannable QR.
3. `lightning qr lightning:alice@example.com --png alice.png`
   writes a valid PNG.
4. Without `qrencode` installed, the fallback renderer still
   produces a scannable QR for short BOLT-11 strings.
5. Help text cites the BIP-21 `lightning:` URI prefix used by
   most wallets.
