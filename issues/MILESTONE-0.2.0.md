# Milestone 0.2.0 — foundation & multi-backend abstraction

```
milestone: 0.2.0
title: foundation & multi-backend abstraction
status: open
depends_on: ~
```

## Summary

The 0.1.0 import landed a stub `bin/lightning` (help + version
only) and a contract `tests/unit/lightning.bats`. 0.2.0 turns
that stub into a real foundation and lays down the
multi-backend dispatch layer that every subsequent verb relies
on.

Five tickets — foundation, dispatch, daemon control, unlock,
and CI all need to be working before any verb is useful:

1. **FEAT-170 — foundation prep** — sourceable lib
   (`bin/lightning.sh` symlink + source-mode guard), declare
   runtime deps (`account` / `config` / `secret`; no direct
   `bitcoin` dep — on-chain funding goes through the backend
   daemon), soft probes for `lightningd` / `lnd` /
   `phoenixd`, and the `CLAUDE.md.lightning` template.
2. **FEAT-171 — multi-backend abstraction** — auto-detect the
   active daemon and route verbs to
   `libexec/lightning/{clightning,lnd,phoenixd}/<verb>`.
3. **FEAT-183 — daemon lifecycle management** —
   `lightning daemon {start,stop,restart,status,logs,install}`
   so users don't have to learn per-daemon CLI quirks.
4. **FEAT-184 — secrets & wallet unlock** — uniform
   `lightning unlock` that drives the backend's wallet-unlock
   RPC and stores the password via `secret`. FEAT-183's
   `daemon-start` calls it on restart.
5. **FEAT-191 — CI workflow** — GitHub Actions runs the bats
   suite on every push / PR. Closes the "no CI" gap visible
   on PR #1.

## Dependency Order

FEAT-170 → FEAT-171 → (FEAT-183 ∥ FEAT-184 ∥ FEAT-191).
FEAT-183 and FEAT-184 are mutually dependent at the contract
level (daemon-start auto-calls unlock --stored), so they land
together. FEAT-191 is independent and can land any time.

## Exit Criteria

- `bin/lightning.sh` symlink resolves; sourcing it defines
  functions without executing the dispatcher.
- Runtime deps declared in `.rpk/depends/`.
- At least one backend plugin directory under
  `libexec/lightning/` with a working `info` (or equivalent)
  verb proving auto-detect dispatch.
- `docs/templates/CLAUDE.md.lightning` exists.
- `tests/unit/lightning.bats` still green; new tests cover
  source-mode, backend dispatch, daemon verbs, and unlock.
- `.github/workflows/test.yml` runs the bats suite green.
- `lightning daemon status` reports healthy after
  `lightning daemon start` + `lightning unlock --stored`.
- `.rpk/version` bumped 0.1.0 → 0.2.0; `.rpk/versions` ledger
  updated.
- FEAT-170, FEAT-171, FEAT-183, FEAT-184, FEAT-191 move to
  `issues/feature/done/`.

## Dependencies

External: `account`, `config`, `secret` (declared runtime).
At least one of `lightningd` / `lnd` / `phoenixd` available
at runtime for any non-trivial verb.
