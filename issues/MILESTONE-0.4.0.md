# Milestone 0.4.0 — wallet, seed backup, and backup/restore

```
milestone: 0.4.0
title: wallet, seed backup, and backup/restore
status: done
depends_on: 0.3.0
```

## Summary

The wallet milestone — non-custodial-by-default posture comes
to life. Four tickets land together because they form a
single user story (init wallet → record activity → back it
up → recover it on a new machine):

1. **FEAT-174 — wallet as git repo** — `lightning wallet`
   storage layer with multi-account support, append-only
   TSV ledger per wallet, and `push` / `pull` to a bare-repo
   remote.
2. **FEAT-193 — TSV accounting** — `ledger.tsv` format spec
   plus `lightning ledger {list,sum,balance,export}` verbs.
   Plain awkable TSV, no recutils or SQLite.
3. **FEAT-185 — seed backup & recovery** —
   `lightning seed {export,import,verify}` and
   `lightning scb {emit,restore}` (static channel backups,
   auto-committed to the wallet repo on every channel state
   change).
4. **FEAT-187 — backup / restore verbs** — `lightning backup`
   and `lightning restore` umbrella verbs that compose
   FEAT-174 + FEAT-185 + FEAT-184 (unlock) into a single
   one-shot.

## Dependency Order

FEAT-174 + FEAT-193 land together (the wallet repo's
`ledger.tsv` *is* the FEAT-193 file; the wallet writes,
FEAT-193 reads). Then FEAT-185 (seed/SCB), then FEAT-187
(umbrella). The seed/SCB layer needs a wallet repo to write
into; the umbrella verbs sit on top of both.

## Exit Criteria

- `lightning wallet init` creates a fresh git-backed wallet.
- `lightning wallet account add/list/select` works.
- Every pay / invoice from FEAT-173 appends one row to
  `ledger.tsv`.
- `lightning ledger sum --by month` returns per-month TSV;
  `ledger balance <account>` matches `account show`.
- The append-only pre-commit hook rejects rewrites of
  existing rows in `ledger.tsv`.
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
- FEAT-174, FEAT-193, FEAT-185, FEAT-187 move to
  `issues/feature/done/`.

## Dependencies

Hard: 0.3.0 (pay / invoice verbs to feed the ledger; channel
state for the SCB) and 0.2.0 / FEAT-184 (unlock for the
restore flow).
