---
id: FEAT-193
type: feature
priority: high
status: open
---

# Lightning accounting — tiny TSV ledger

## Description

**As a** Lightning user
**I want** a dead-simple TSV ledger of every payment, with a
few view / aggregate verbs
**So that** I can answer "how much did I spend on coffee in
March?" with `awk`, `cut`, or a spreadsheet — no recutils,
no SQLite, no daemon, no daemon-specific export format.

Replaces the rec-format `history` file in FEAT-174 with a
plain TSV (`ledger.tsv`) under the wallet repo. Append-only;
never rewritten. Stays small on disk, stays simple to read.

## Implementation

### File

`~/.lightning/wallet/<name>/ledger.tsv` — append-only, with
a single header row:

    ts<TAB>account<TAB>direction<TAB>amount_msat<TAB>peer<TAB>payment_hash<TAB>memo

- `ts` — RFC-3339 UTC (`2026-03-15T11:22:33Z`)
- `account` — account label or `-` for unassigned
- `direction` — `in` / `out` / `fee` / `forward`
- `amount_msat` — signed integer (negative = outgoing)
- `peer` — counterparty pubkey or Lightning Address, `-` if
  unknown
- `payment_hash` — hex hash, `-` if not a payment row
- `memo` — free text; tabs and newlines stripped at write
  time

Every `lightning {pay,invoice settled,forward}` appends one
row. The append-only invariant is enforced by a pre-commit
git hook in the wallet repo.

### Verbs

    lightning ledger list [--account <n>] [--since <date>] [--limit N]
    lightning ledger sum [--by account|day|month|year]
    lightning ledger balance [<account>]      # net per account
    lightning ledger export csv > out.csv
    lightning ledger export jsonl > out.jsonl

`ledger list` and `ledger sum` are thin `awk` over the TSV.
No soft dep on `data` / recutils.

## Acceptance Criteria

1. Every `lightning pay` and `lightning invoice settled`
   appends exactly one row.
2. `lightning ledger balance alice` matches
   `lightning account show alice` to the msat.
3. `lightning ledger sum --by month` returns per-month totals
   in TSV.
4. `lightning ledger export csv` produces a spreadsheet-ready
   CSV (comma-separated, quoted memos).
5. `awk -F'\t' '$2 == "coffee" { s += $4 } END { print s }'
   ledger.tsv` works without any `lightning` tool installed
   — the file is plain TSV.
6. Pre-commit hook rejects any commit that rewrites existing
   rows (append-only).
