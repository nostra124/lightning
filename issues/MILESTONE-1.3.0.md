# Milestone 1.3.0 — wallet as git repo with multi-account

```
milestone: 1.3.0
title: wallet as git repo with multi-account
status: open
depends_on: 1.2.0
```

## Summary

One ticket: **FEAT-174** — `lightning wallet` storage layer.
The wallet is a git repo with multi-account support, plain-text
accounting (one append-only ledger per account), and
`push` / `pull` for backup to a remote.

This is what gives the package its non-custodial-by-default
posture: keys, channel state, and payment history all live in
a user-owned git repo rather than in the backend daemon's
opaque database.

## Dependency Order

Single ticket; depends on the payment / invoice verbs from
1.2.0 so the ledger has something to record.

## Exit Criteria

- `lightning wallet init` creates a fresh git-backed wallet.
- `lightning wallet account add/list/select` works.
- Every pay / invoice from FEAT-173 appends a ledger entry.
- `lightning wallet push` / `pull` round-trip through a
  bare-repo remote in test fixtures.
- Unit test contract extended.
- `.rpk/version` bumped 1.2.0 → 1.3.0; ledger updated.
- FEAT-174 moves to `issues/feature/done/`.

## Dependencies

Hard: 1.2.0 (pay / invoice verbs to feed the ledger).
