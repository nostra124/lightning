---
id: FEAT-195
type: feature
priority: medium
status: done
---

# Lightning bank mode — single-user, multi-account financial discipline

## Description

**As a** single operator running a Lightning node with
several virtual accounts (`treasury`, `donations`, `alice`,
`bob`)
**I want** account-level overdraft policy, an address per
account, and printable per-period statements
**So that** I can treat the node like a small bank — accounts
don't quietly go negative, each account has a place where
funds can be sent, and end-of-period bookkeeping is one
command.

Single-user assumption: there is no per-account-holder
authentication. The operator is the only person with shell
access; the discipline is for the operator's own bookkeeping,
not for protecting one account-holder from another.

Sits on top of FEAT-174 (accounts), FEAT-193 (TSV ledger),
and FEAT-176 (Lightning Addresses). FEAT-190 (`lightning
serve`) is unaffected — no HTTP-facing surface here.

## Implementation

### Overdraft policy

`lightning account create` gains two flags:

    --limit <sat>         # spendable ceiling for this account
    --overdraft deny|warn|allow
                           # default: deny

Stored as two extra TSV columns in the `accounts` file
(FEAT-174):

    <name><TAB><description><TAB><limit_sat><TAB><overdraft>

Before any `lightning pay --account <n>` or
`lightning loop out --account <n>`, the verb computes the
running balance from `ledger.tsv` (FEAT-193), and:

- `deny`  — refuses if `balance - send_amt < 0`, exit 3
- `warn`  — proceeds, prints a banner on stderr
- `allow` — proceeds silently

If `--limit` is set, the same check applies to receipts that
would breach the ceiling (refuses an inbound HTLC if
configured to enforce; default for now is to just warn — a
hard refusal needs deeper backend integration).

### Auto-address on account create

`lightning account create` gains:

    --host <domain>       # auto-issue <name>@<domain>

When set, account-create chains into FEAT-176's
`lightning address create <name>@<domain> --account <name>`
and prints both the account confirmation and the address.

### Per-period statements

New verb under FEAT-193's `ledger` family:

    lightning ledger statement \
        --account <n> \
        --period <YYYY-MM | YYYY-Q1..Q4 | YYYY>

Output is a plaintext block:

    Statement for alice — 2026-03
    --------------------------------
    Opening balance:        12,400 sat
      2026-03-02  +1,000   coffee shop tip
      2026-03-11    -250   lnurl pay nostr@…
      ...
    --------------------------------
    Closing balance:        13,150 sat
    Fees paid:                  17 sat
    Net for period:           +750 sat

A `--tsv` flag emits the same data as TSV for spreadsheet
import. PDF is explicitly out of scope.

### Aggregated view

`lightning account list` gains a `--balances` flag that
prints account / limit / current-balance / utilisation as a
single TSV, suitable for a daily cron summary.

### API keys (per account, for FEAT-196)

    lightning account apikey create <name> --scope read|write
        # generates a random key, stores it via
        # secret put lightning.<name>.apikey.<scope>,
        # prints it once (operator copies it out)
    lightning account apikey list <name>
        # which scopes are issued
    lightning account apikey revoke <name> --scope read|write

Used by FEAT-196's `.well-known/lightning/` CGI scripts.
Single-user assumption still holds: the operator manages
keys; there's no holder-side workflow. The keys exist so
external HTTP callers (the operator's phone, a JS frontend,
a webhook) can authenticate without putting shell access on
the internet.

## Acceptance Criteria

1. `lightning account create alice --limit 50000
   --overdraft deny --host my-host.com` creates the
   account, issues `alice@my-host.com`, and stores the
   ceiling.
2. With alice at 100 sat balance, `lightning pay --account
   alice <2000-sat-invoice>` refuses with exit 3 and a
   clear "would overdraw alice (-1900 sat)" message.
3. `lightning ledger statement --account alice --period
   2026-03` produces a parseable plaintext statement.
4. `lightning account list --balances` prints one TSV row
   per account.
5. `lightning account apikey create alice --scope write`
   prints a one-shot key and stores it under
   `secret get lightning.alice.apikey.write`.
6. Help text states the single-user assumption explicitly
   ("no per-account holder auth — API keys exist so HTTP
   callers can authenticate, not so account holders can").
