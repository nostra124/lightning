---
name: lightning-wallet
description: |
  Operate the `lightning` Lightning Network frontend
  on clightning (Core Lightning) — open channels, pay
  invoices, generate invoices, query node info.
  Trigger when the user wants to send a Lightning
  payment, receive one, manage channels, or learn the
  BOLT abstractions.
---

# `lightning-wallet` skill

## 1. Design principles

- **Educational.** Each verb cites the BOLT it
  implements (BOLT 1..12) plus LNURL/Lightning
  Address standards. Reading any verb script teaches
  the matching `lightning-cli` surface.
- **Functional.** Each verb is a thin wrapper over
  `lightning-cli` (clightning's CLI).
- **Decentralized.** No custodial layer; the user's
  node is the trust boundary.
- **Simple.** `lightning` calls only `account` at
  runtime; on-chain channel funding is handled by
  clightning's built-in wallet.

## 2. The model

A **lightning node** is a `lightningd` instance plus
its on-chain backing wallet. `lightning` is a verb
layer on top of `lightning-cli`. The libexec dispatch
shape (`libexec/lightning/<verb>`) leaves the door
open for additional backends as future plugin
directories, but only clightning ships today.

## 3. Workflow recipes

(All under construction — FEAT-170..182 file the
implementation. Today's `bin/lightning` is a stub.)

1. **Inspect node info.**

       lightning info
       lightning peers
       lightning channels

2. **Pay an invoice (BOLT 11).**

       lightning pay lnbc1...

3. **Receive via Lightning Address (LUD-16).**

       lightning invoice 100sat "coffee"
       # → lnbc1...

4. **Send to a Lightning Address.**

       lightning sendto user@domain.tld 100sat

5. **Open a channel (BOLT 2).**

       lightning open-channel <peer-pubkey> 1000000sat

## 4. Guardrails (when implementation lands)

1. **Channel state is at-rest in clightning's data
   dir** (`~/.lightning/`). Back it up — losing it
   loses funds. SCB snapshots (FEAT-185) live in the
   wallet repo and let you force-close to recover.
2. **Invoices expire.** BOLT 11 has a default 1h
   expiry; pay or generate a new one.
3. **Channel close ≠ instant funds.** On-chain
   confirmation (≥ 6 blocks) is required for
   force-closes.
4. **The seed phrase / wallet keys live in
   `secret` (FEAT-041 pass-init).** Never copy them
   into shell history.

## 5. Where to read more

- `man lightning`
- `share/doc/lightning/standards/README.md` —
  BOLT / LNURL / Lightning Address citations
- `man bitcoin` — the on-chain layer
- This package's `CLAUDE.md`
