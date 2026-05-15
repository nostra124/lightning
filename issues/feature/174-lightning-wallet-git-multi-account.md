---
id: FEAT-174
type: feature
priority: high
status: open
---

# Lightning wallet as git repo with multi-account, accounting, and push/pull

## Description

**As a** Lightning user
**I want** my Lightning state — labelled accounts, payment
history, channel notes — kept as an encrypted git
repository, parallel to bitcoin's wallet model
(FEAT-010..011)
**So that** my Lightning context travels with me (push/pull
between accounts), is auditable (git log of every change),
and is searchable (recsel-style queries via the data
toolkit).

The LN node's funds are the wallet's funds (one wallet
per node, per the design call). Accounts are *labels*
applied to incoming/outgoing payments and channels — they
don't sub-key the node's funds, they're a bookkeeping layer.

## Implementation

### Layout

`~/.lightning/wallet/<name>/`:

    .git/
    backend                  # active backend name
    backend-config           # backend connection config
                              # (rune-id / macaroon-id / phoenixd-host)
    accounts                 # one per line:
                              #   <name><TAB><description>
    ledger.tsv               # append-only TSV ledger (FEAT-193)
    invoices.tsv             # outstanding invoices, TSV
    notes/<channel-id>       # free-text channel notes
    .gitignore               # excludes runtime caches

The seed / credentials live in `secret` (under
`lightning/<wallet>/<backend>/`), not in the repo. Pushing
the repo is safe (no credentials).

### Accounts

    lightning account list
    lightning account create <name> [<description>]
    lightning account delete <name>
    lightning account show <name>            # balance + history filter

Each `lightning invoice` / `pay` / `send` accepts
`--account <name>` to tag the event with that account.
`lightning account show alice` filters history to
alice-tagged events; computes alice's notional balance
(sum of receives minus sum of pays for that account).

### History

`lightning history` is a thin alias for `lightning ledger
list` (FEAT-193). Same TSV file, same flags
(`--account <n>` / `--since <date>` / `--limit N`). No soft
dep on `data` / recutils — plain `awk` over the TSV.

### Push/pull

Mirrors bitcoin FEAT-011:

    lightning wallet push <account>
    lightning wallet pull <account>
    lightning wallet sync <account>

Endpoint resolution via `account remote-url <account>
lightning` (FEAT-044 pattern). Conflict policy: union for
history (dedup by event-id); accounts merge by name;
notes are last-writer-wins per file.

### Multi-wallet

Multiple wallets per machine via `lightning wallet new
<name>`; switch active via `lightning wallet use <name>`.
Each wallet binds to one LN backend instance. A common
pattern: `personal` wallet on a phoenixd backend, `node`
wallet on a clightning backend.

## Acceptance Criteria

1. `lightning wallet new alice` creates an encrypted git
   repo at `~/.lightning/wallet/alice/`; credentials live
   in `secret`.
2. `lightning account create rent` creates an account;
   `lightning invoice 1000 'march' --account rent`
   produces an invoice tagged `rent`.
3. After a pay, `lightning account show rent` shows the
   notional balance + the tagged history.
4. `lightning wallet push laptop` mirrors the wallet to
   another machine; subsequent `pull` is a no-op (idempotent).
5. The wallet repo never contains credentials — only
   identifiers pointing into `secret`.
6. SIT (FEAT-182) covers wallet new + accounts + pay + push/pull
   round-trip.
