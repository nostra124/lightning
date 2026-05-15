# Milestone 0.4.0 — wallet, seed backup, and backup/restore

```
milestone: 0.4.0
title: wallet, seed backup, and backup/restore
status: open
depends_on: 0.3.0
```

## Summary

The wallet milestone — non-custodial-by-default posture comes
to life. Three tickets land together because they form a
single user story (init wallet → record activity → back it
up → recover it on a new machine):

1. **FEAT-174 — wallet as git repo** — `lightning wallet`
   storage layer with multi-account support, plain-text
   append-only ledger per account, and `push` / `pull` to a
   bare-repo remote.
2. **FEAT-185 — seed backup & recovery** —
   `lightning seed {export,import,verify}` and
   `lightning scb {emit,restore}` (static channel backups,
   auto-committed to the wallet repo on every channel state
   change).
3. **FEAT-187 — backup / restore verbs** — `lightning backup`
   and `lightning restore` umbrella verbs that compose
   FEAT-174 + FEAT-185 + FEAT-184 (unlock) into a single
   one-shot.

## Dependency Order

FEAT-174 → FEAT-185 → FEAT-187. The seed/SCB layer needs a
wallet repo to write into; the umbrella verbs sit on top of
both.

## Exit Criteria

- `lightning wallet init` creates a fresh git-backed wallet.
- `lightning wallet account add/list/select` works.
- Every pay / invoice from FEAT-173 appends a ledger entry.
- `lightning wallet push` / `pull` round-trip through a
  bare-repo remote in test fixtures.
- `lightning seed export` / `import` round-trips against a
  fresh regtest daemon — same node id.
- `lightning scb emit` fires automatically on every channel
  state change (hook from FEAT-172).
- `lightning backup && lightning restore` round-trips
  end-to-end against a fresh regtest daemon.
- Unit test contract extended.
- `.rpk/version` bumped 0.3.0 → 0.4.0; ledger updated.
- FEAT-174, FEAT-185, FEAT-187 move to
  `issues/feature/done/`.

## Dependencies

Hard: 0.3.0 (pay / invoice verbs to feed the ledger; channel
state for the SCB) and 0.2.0 / FEAT-184 (unlock for the
restore flow).
