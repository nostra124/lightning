---
name: lightning-wallet
description: |
  Operate the `lightning` Lightning Network frontend on
  clightning (Core Lightning). Send + receive Lightning
  payments (BOLT-11 / BOLT-12 / LNURL / Lightning
  Address), manage channels and inbound liquidity, drive
  a multi-account wallet repo with SQLite + git, set up
  the .well-known/lightning/ JSON API. Trigger when the
  user wants any Lightning operation, set up a Lightning
  Address, run a small bank-mode node, or learn the BOLT
  abstractions.
---

# `lightning-wallet` skill

## 1. Design principles

- **Educational.** Each verb cites the BOLT / LUD / BLIP
  it implements. Reading any verb script teaches the
  matching `lightning-cli` RPC.
- **Functional.** Each verb is a thin wrapper over
  `lightning-cli`. No shared cli-helper library.
- **Decentralized.** No custodial layer; the operator's
  node is the trust boundary.
- **Simple.** `lightning` calls only `account` at
  runtime; on-chain channel funding is handled by
  clightning's built-in wallet.

## 2. The model

A **lightning node** is a `lightningd` instance plus
its on-chain backing wallet. `lightning` is a verb layer
on top of `lightning-cli`. The libexec dispatch shape
(`libexec/lightning/<verb>`) leaves the door open for
additional backends as future plugin directories, but
only clightning ships today.

A **wallet** (in the `lightning` sense) is a git repo
with a SQLite `state.db` inside — accounts, ledger
rows, invoices, channel notes, hosted-user bindings.
The wallet repo is what `lightning wallet push` mirrors
to a remote; the binary DB is rebuilt from a
`state.sql` dump on `wallet pull`.

An **account** is a label applied to ledger rows. It
isn't a separate set of keys — funds remain pooled in
the node. Accounts gain limits (`--limit`) and an
overdraft policy (`deny`/`warn`/`allow`) so the operator
can run a small bank without per-holder authentication.

A **hosted user** is `<name>@<domain>` published via
the Apache CGI handler. Auto-issued by
`account create --host <domain>`. Each user maps to
exactly one account.

## 3. Workflow recipes

### Set up a node end-to-end

    lightning daemon install --system          # FEAT-183
    lightning daemon start
    lightning unlock                            # interactive once
    lightning info

### Open a channel and receive a payment

    lightning channel open <peer-uri> 1000000
    # wait for confirmations
    lightning invoice 5000 "coffee" --qr
    # → BOLT-11 + QR

### Pay a Lightning Address with a message

    lightning address pay alice@example.com 1000 \
        --comment "thanks for the article"

The comment rides LUD-12 to the recipient and ends up
in their ledger row's `message` column.

### Run a small bank

    lightning wallet new myorg
    lightning account create treasury --description "ops"
    lightning account create rent --limit 200000 --overdraft deny
    lightning account create alice --host myorg.example --limit 50000
    # alice@myorg.example now resolves via Apache + LUD-16

    # Issue alice an API key for her phone:
    lightning account apikey create alice --scope write

    # End of month:
    lightning ledger statement --account alice --period 2026-03

### Get inbound liquidity

    lightning liquidity status                  # zero inbound -> can't receive
    lightning liquidity provider default lsp
    lightning liquidity in 100000               # LSPS1 channel purchase

### Backup + restore

    # On the live node:
    lightning backup --remote origin

    # On a fresh machine:
    lightning restore git@example.com:myorg-wallet.git myorg

## 4. Guardrails

1. **Channel state is at-rest in clightning's data dir**
   (`/var/lib/clightning/` in system-mode). The wallet
   repo holds SCB snapshots (FEAT-185); a force-close
   recovery is possible from those alone, but loses
   in-flight HTLCs.
2. **`force-close` is destructive.** It costs the
   `to_self_delay` (typically ~1 day of blocks) and
   reveals channel state on-chain. `--confirm` is
   mandatory.
3. **Liquidity ops cost fees.** Read
   `liquidity status` first; the LSP / Loop / Boltz
   round-trip fee is non-trivial.
4. **The bank-mode overdraft policy is the operator's
   discipline, not authentication.** Single-user
   assumption: shell access = full control. API keys
   exist for HTTP-facing callers, not per-holder auth.
5. **Never log payment preimages or BOLT-11 invoices
   outside the wallet repo.** The wallet repo's git
   history is the audit trail; ad-hoc copies are a leak
   surface.
6. **Invoices expire.** BOLT-11 default is 1h; mint
   fresh.
7. **Tor is the default on system-mode installs.**
   `lightning tor status` to verify; clearnet leakage
   is caught here.

## 5. Where to read more

- `man lightning` — full CLI reference
- `share/doc/lightning/standards/cln-overview.md` —
  10-minute clightning tour
- `share/doc/lightning/standards/api/spec.md` —
  Lightning Well-Known JSON API spec
- `share/doc/lightning/standards/` — vendored BOLT /
  LUD / BIP / BLIP texts
- This package's `CLAUDE.md`

## 6. Anti-patterns to avoid

- **Don't bypass `lightning unlock`** by setting
  password env vars in shell history — the secret store
  (`secret put lightning.<wallet>.unlock`) is the path.
- **Don't push the binary `state.db` to the wallet
  remote** — only `state.sql` is tracked; the pre-commit
  hook handles the dump.
- **Don't pay `lightning pay <bolt11>` from a script
  without `--max-fee-sat`** — uncapped routing fees can
  surprise.
- **Don't expose the JSON API without TLS** — `X-API-Key`
  is a shared secret; without TLS it's printed to every
  hop. Use certbot or a real reverse-proxy.
