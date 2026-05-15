# Milestone 0.3.0 — channels & payments

```
milestone: 0.3.0
title: channels & payments
status: open
depends_on: 0.2.0
```

## Summary

The operational core of a Lightning wallet: opening / closing
channels and paying / receiving over them. Both verbs are
implemented per backend, citing the relevant BOLT(s) inline.

Two tickets:

1. **FEAT-172 — channel management verbs** — `open`, `close`,
   `list`, `balance` across clightning / lnd / phoenixd. The
   on-chain funding leg is handled by the backend daemon's
   built-in bitcoind connection; `lightning` does not call
   the `bitcoin` package directly.
2. **FEAT-173 — payments, invoices, BOLT-12, LNURL** — `pay`,
   `invoice`, `decode`, plus BOLT-12 offers and LNURL-pay /
   LNURL-withdraw flows.

## Dependency Order

FEAT-172 → FEAT-173. The payment verbs need an active channel
to be useful end-to-end; the test fixtures from 172 (regtest
channel) are reused by 173.

## Exit Criteria

- `lightning {open,close,list,balance}` work against all three
  backends (at least mocked in unit tests; real backends in
  FEAT-182).
- `lightning {pay,invoice,decode}` work across backends and
  decode BOLT-11, BOLT-12, and LNURL strings.
- Each verb's source cites the BOLT it implements.
- Unit test contract extended; bats suite green.
- `.rpk/version` bumped 0.2.0 → 0.3.0; ledger updated.
- FEAT-172, FEAT-173 move to `issues/feature/done/`.

## Dependencies

Hard: 0.2.0 (backend dispatch). On-chain funding is the
backend daemon's responsibility (its built-in bitcoind
connection); no direct `bitcoin` package dep.
