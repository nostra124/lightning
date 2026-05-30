---
name: lightning-wallet
description: Operate the lightning(1) Lightning Network wallet
long_description: Operate the lightning(1) Lightning Network frontend on clightning (Core Lightning). Trigger when the user wants to send or receive a Lightning payment (BOLT-11 / BOLT-12 / LNURL / Lightning Address), open or close channels, manage inbound liquidity, run a multi-account wallet in bank mode, set up a Lightning Address via Apache CGI, back up or restore the wallet repo, or learn how a BOLT / LUD maps onto the wallet's design.
role: [user]
references: secret/secret-user
---

# lightning-wallet

Operate the `lightning(1)` Lightning Network frontend — a bash
package that wraps `lightning-cli` (Core Lightning) to send and
receive payments, manage channels, and host Lightning Addresses.
Every verb cites the BOLT or LUD it implements; reading any verb
script teaches the matching `lightning-cli` RPC.

## When to use

Trigger when the user says any of:

- "Send a Lightning payment", "pay this invoice / BOLT-11 / BOLT-12".
- "Pay a Lightning Address", "send to alice@example.com".
- "Create an invoice", "generate a QR code for a payment".
- "Open / close a channel", "connect to a peer".
- "Check my balance", "list my channels".
- "Get inbound liquidity", "I can't receive".
- "Set up a Lightning Address", "run a small bank".
- "Create an account", "issue an API key".
- "Back up / restore my wallet".
- "What is BOLT-11 / BOLT-12 / LNURL / LUD-16?".
- "Unlock my node", "start the daemon".

## Design principles

| Principle | What it rules in | What it rules out |
|---|---|---|
| **Educational** | Every verb cites the BOLT / LUD / BLIP it implements. | Magic primitives the documentation doesn't point at. |
| **Functional** | Real payments over a real clightning node. | Demo-only features that don't survive a real HTLC. |
| **Decentralized** | No custodial layer; the operator's node is the trust boundary. | Re-using a central server as the wallet store. |
| **Simple** | `lightning` calls only `account` at runtime; on-chain channel funding is handled by clightning's built-in wallet. | A shared cli-helper library. Each verb is self-contained. |

## The model

A **lightning node** is a `lightningd` instance plus its on-chain
backing wallet. `lightning` is a verb layer on top of
`lightning-cli`. The libexec dispatch shape
(`libexec/lightning/<verb>`) leaves the door open for additional
backends as future plugin directories, but only clightning ships
today.

A **wallet** (in the `lightning` sense) is a git repo with a SQLite
`state.db` inside — accounts, ledger rows, invoices, channel notes,
hosted-user bindings. The wallet repo is what `lightning wallet push`
mirrors to a remote; the binary DB is rebuilt from a `state.sql`
dump on `wallet pull`.

An **account** is a label applied to ledger rows. It isn't a
separate set of keys — funds remain pooled in the node. Accounts
gain limits (`--limit`) and an overdraft policy
(`deny`/`warn`/`allow`) so the operator can run a small bank without
per-holder authentication.

A **hosted user** is `<name>@<domain>` published via the Apache CGI
handler. Auto-issued by `account create --host <domain>`. Each user
maps to exactly one account.

## Workflow recipes

### Set up a node end-to-end

```sh
lightning daemon install --system     # FEAT-183: three-user separation
lightning daemon start
lightning unlock                       # interactive once; reads from secret store
lightning info                         # verify node ID + block height
```

### Open a channel and receive a payment

```sh
lightning peer connect <peer-uri>
lightning channel open <peer-id> 1000000
# wait for on-chain confirmations
lightning invoice 5000 "coffee" --qr   # BOLT-11 + QR
```

### Pay an invoice

```sh
lightning pay <bolt11>                 # cap fees with --max-fee-sat
lightning pay <bolt12-offer>           # BOLT-12 offer
lightning offer pay <offer-id>
```

### Pay a Lightning Address with a message

```sh
lightning address pay alice@example.com 1000 \
    --comment "thanks for the article"
```

The comment rides LUD-12 to the recipient and ends up in their
ledger row's `message` column.

### Run a small bank

```sh
lightning wallet new myorg
lightning account create treasury --description "ops"
lightning account create rent --limit 200000 --overdraft deny
lightning account create alice --host myorg.example --limit 50000
# alice@myorg.example now resolves via Apache + LUD-16

# Issue alice an API key for her phone:
lightning account apikey create alice --scope write

# End of month:
lightning ledger statement --account alice --period 2026-03
```

### Get inbound liquidity

```sh
lightning liquidity status               # check current inbound
lightning liquidity provider default lsp
lightning liquidity in 100000            # LSPS1 channel purchase
```

### Backup + restore

```sh
# On the live node:
lightning backup --remote origin

# On a fresh machine:
lightning restore git@example.com:myorg-wallet.git myorg
```

## Guardrails

1. **Channel state is at-rest in clightning's data dir**
   (`/var/lib/clightning/` in system-mode). The wallet repo holds
   SCB snapshots (FEAT-185); a force-close recovery is possible
   from those alone, but loses in-flight HTLCs.
2. **`force-close` is destructive.** It costs the `to_self_delay`
   (typically ~144 blocks) and reveals channel state on-chain.
   `--confirm` is mandatory; never add it silently.
3. **Liquidity ops cost fees.** Read `liquidity status` first; the
   LSP / Loop / Boltz round-trip fee is non-trivial.
4. **The bank-mode overdraft policy is the operator's discipline,
   not authentication.** Shell access = full control. API keys
   exist for HTTP-facing callers, not per-holder auth.
5. **Never log payment preimages or BOLT-11 invoices outside the
   wallet repo.** The wallet repo's git history is the audit trail.
6. **Invoices expire.** BOLT-11 default is 1 hour; mint fresh.
7. **Tor is the default on system-mode installs.** `lightning tor
   status` to verify; clearnet leakage is caught here.
8. **Never pass `--max-fee-sat` silently from a script.** Surface
   the fee estimate to the user; let them decide the cap.

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `lightning-cli: connection refused` | lightningd not running | `lightning daemon start` |
| `lightning pay` fails with "no route" | No outbound channel with enough balance | Open a channel or rebalance |
| `lightning invoice` won't be paid | Zero inbound capacity | `lightning liquidity in <sats>` |
| `wallet push` fails | No remote configured | `lightning wallet remote add origin <url>` |
| `unlock` asks for password every time | Secret not stored | `secret put lightning.<wallet>.unlock` |

## Related skills

- **rpk/bugs** — file and fix bugs the rpk way.
- **rpk/features** — design and ship new features.
- **secret/secret-user** — where the unlock passphrase lives.
- **lightning-operator** — daemon install, fee policy, routing.

## Where to read more

- `man lightning` — full CLI reference.
- `share/doc/lightning/standards/cln-overview.md` — 10-minute
  clightning tour.
- `share/doc/lightning/standards/api/spec.md` — Lightning
  Well-Known JSON API spec.
- `share/doc/lightning/standards/` — vendored BOLT / LUD / BIP /
  BLIP texts.
- `CLAUDE.md` — package-level notes including the no-shared-lib
  policy and wallet model.
