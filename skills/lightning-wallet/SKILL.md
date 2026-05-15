---
name: lightning-wallet
description: |
  Operate the `lightning` multi-backend Lightning
  Network frontend — open channels, pay invoices,
  generate invoices, query node info across
  clightning / lnd / phoenixd backends. Trigger when
  the user wants to send a Lightning payment, receive
  one, manage channels, or learn the BOLT
  abstractions.
---

# `lightning-wallet` skill

## 1. Design principles

- **Educational.** Each verb cites the BOLT it
  implements (BOLT 1..11) plus LNURL/Lightning
  Address standards. Reading any backend plugin
  teaches the corresponding daemon's surface.
- **Functional.** Each verb is a thin wrapper over
  the backend daemon's CLI.
- **Decentralized.** No custodial layer; the user's
  node is the trust boundary.
- **Simple.** `lightning` calls only `account` at
  runtime; on-chain channel funding is handled by the
  backend daemon's built-in wallet.

## 2. The model

A **lightning node** is identified by a backend +
node ID + on-chain backing wallet:

| Backend     | Daemon              | Use case                  |
|-------------|---------------------|---------------------------|
| clightning  | lightningd          | full-featured             |
| lnd         | lnd                 | broad ecosystem support   |
| phoenixd    | phoenixd            | lightweight, mobile-style |

`lightning` exposes a uniform verb surface across
all three; behind the scenes it dispatches to the
matching plugin under `libexec/lightning/<backend>/`.

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

1. **Channel state is at-rest in the daemon's
   data dir.** Back up `~/.lightning/`,
   `~/.lnd/`, etc. — losing it loses funds.
2. **`phoenixd` is custodial-leaning** — it relies
   on ACINQ as a routing peer. clightning / lnd
   are non-custodial.
3. **Invoices expire.** BOLT 11 has a default 1h
   expiry; pay or generate a new one.
4. **Channel close ≠ instant funds.** On-chain
   confirmation (≥ 6 blocks) is required for
   force-closes.
5. **The seed phrase / wallet keys live in
   `secret` (FEAT-041 pass-init).** Never copy them
   into shell history.

## 5. Where to read more

- `man lightning`
- `share/doc/lightning/standards/README.md` —
  BOLT / LNURL / Lightning Address citations
- `man bitcoin` — the on-chain layer
- This package's `CLAUDE.md`
