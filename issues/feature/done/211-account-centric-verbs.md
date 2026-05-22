---
id: FEAT-211
type: feature
priority: medium
status: shipped
---

# Account-centric user-facing verb surface

## Description

**As a** user who thinks in terms of "I have an account, what can
I do with it"
**I want** all the common Lightning workflows to be exposed under
`lightning account ...`
**So that** I don't have to learn three other verbs (`invoice`,
`offer`, `liquidity`) just to receive, pay, top up and withdraw.

The existing power-user verbs (`invoice`, `offer`, `wallet`,
`liquidity`, `channel`, `rebalance`, `lnurl`, ...) stay exactly as
they are.  This ticket adds a **thin, account-centric facade** on
top of them — `account` becomes the user's entry point; everything
else is the mechanism a power user can drill into.

## Background

After FEAT-198 (LSPS1 via cln-lsps) shipped, we reviewed the seven
high-level use cases an operator should be able to do trivially:

| # | Use case |
|---|---|
| 1 | Create a new Lightning account |
| 2 | Top up account with X sats (QR on console) |
| 3 | Withdraw X sats on-chain |
| 4 | Pay someone in Lightning |
| 5 | Receive a one-time payment (QR) |
| 6 | Receive recurring payments (QR) |
| 7 | Automatic liquidity management with cost attribution |

Use cases 1-6 are all user-facing — they should live under one
verb (`account`).  Use case 7 stays in the power-user verbs
(`autopilot.conf`, `ledger`) because the policy decisions are
operator-level, not account-level.

Today (pre-FEAT-211):

- #1 (create) is covered: `lightning account create <name>` exists.
- #4 (pay) is covered by three verbs (`invoice pay`, `offer pay`,
  `send`), but the operator has to know which to use.
- #5 (receive one-time) is covered: `lightning invoice create
  <sat> <label> --account <n> --qr`.
- #2, #3, #6 have gaps (no top-up verb, no withdraw verb, `offer
  create` is missing the `--account` flag).

This ticket closes the gaps and surfaces all six under `account`.

## Surface

```
lightning account create <name>                         existing (FEAT-174)
lightning account topup <name> <sat>                    NEW — QR for on-chain top-up
        [--via lightning]                                   alt: BOLT-11 invoice
lightning account withdraw <name> <sat> <addr>          NEW — submarine swap out
lightning account pay <name> <payment-string>           NEW — auto-dispatch by shape
                                                        (bolt11, bolt12, lnurl,
                                                        lightning-address, node-id)
        [--sat <sat>]                                       (keysend needs amount)
lightning account receive <name> <sat> [--desc <text>]  NEW — BOLT-11 + QR
        [--reusable]                                        flips to BOLT-12 + QR
```

All six user-facing flows reachable with `lightning account
<verb>`.  Each new wrapper is ~30 lines of bash that composes
existing verbs with `--account <name>` already plumbed.

## Implementation

### `account topup`

Default path (on-chain top-up):
- `lightning-cli newaddr` returns a fresh receive address
- Print address + render `bitcoin:<addr>?amount=<sat>` via `qr`
- (Future: a watcher credits the account's ledger when the deposit
  confirms — out of scope for the first cut)

`--via lightning` alternate:
- Same as `invoice create <sat> <label> --account <name> --qr`
- Slightly cheaper UX framing for "I have LN sats elsewhere"

### `account withdraw`

- Validate `<addr>` looks like a Bitcoin address (bech32, P2PKH, P2SH, taproot)
- Delegate to `boltzcli createreverseswap --amount <sat> --address <addr>`
- If `boltzcli` isn't installed: clear error + install hint
- On success: `ledger add debit ... --account <name> --note "withdraw to <addr>"`

This is the reverse submarine swap path — same mechanism the
existing `liquidity boltz in` uses, just with an explicit
destination address rather than the operator's own wallet.

### `account pay`

Auto-dispatch on the payment-string shape:

| Prefix / shape | Dispatched to |
|----------------|---------------|
| `lnbc*` / `lnbcrt*` / `lntb*` | `invoice pay <bolt11> --account <n>` |
| `lno*` | `offer pay <bolt12> --account <n>` |
| `lnurl*` | `lnurl pay <string> --account <n>` |
| `<user>@<host>` (Lightning address) | `lnurl pay <user@host> --account <n>` |
| `02*` / `03*` (66-char hex pubkey) | `send <node-id> <sat> --account <n>`  (keysend; needs `--sat`) |

Unknown shape → error with "couldn't identify payment type" hint.

### `account receive`

- Default (`--reusable` not passed): `invoice create <sat>
  receive-<name>-<ts> --description "<desc>" --account <name>
  --qr` (BOLT-11, single-use).
- `--reusable`: `offer create <sat> "<desc>" --account <name>
  --qr` (BOLT-12, multi-use).

Needs `offer create` to learn `--account` — small addition.

## Acceptance criteria

1. `lightning account topup alice 100000` prints an on-chain
   address + ANSI QR + a `bitcoin:<addr>?amount=100000` URI.
2. `lightning account withdraw alice 50000 bc1q...` runs a Boltz
   reverse swap to that address; ledger gets a debit row.
3. `lightning account pay alice lnbc1...` dispatches to the
   BOLT-11 path; `lightning account pay alice lno1...` to the
   BOLT-12 path; both with `--account alice` propagated.
4. `lightning account receive alice 10000 --desc "tip jar"`
   produces a BOLT-11 invoice + QR; with `--reusable` produces a
   BOLT-12 offer + QR.
5. `offer create` accepts `--account <n>` (gap-filler, no surface
   change beyond the new flag).
6. Each wrapper exits with a clear error when the account doesn't
   exist or the payment string can't be identified.
7. Bats coverage for each new subcommand + the dispatch table for
   `account pay`.

## Out of scope

- **Watcher daemon to auto-credit account on confirm** — write
  the address now, manual `ledger add` later.  A `daemon install
  --topup-watcher` sidecar can land in a follow-up.
- **Withdrawal fallback to channel-close** — if no swap operator
  is available, we currently error out.  Adding a fallback that
  closes a channel + spends the resulting UTXO is conceptually
  bigger than this ticket.
- **Use case #7** (automatic cost distribution) — power-user
  territory; lives in autopilot config and ledger policy.

## Milestone

1.4.0.

## See also

- FEAT-174 (account + ledger primitives — what this verb extends)
- FEAT-188 / FEAT-201 / FEAT-205 (power-user fee + rebalance +
  autopilot stack the operator drops into for #7)
- FEAT-192 (`qr` verb — used for QR rendering in topup / receive)
- FEAT-198 (LSPS1 — orthogonal but mentioned in the topup flow
  for "buy inbound first if needed")
