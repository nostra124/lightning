# Milestone 0.2.0 — foundation & clightning wiring

```
milestone: 0.2.0
title: foundation & clightning wiring
status: open
depends_on: ~
```

## Summary

The 0.1.0 import landed a stub `bin/lightning` (help + version
only) and a contract `tests/unit/lightning.bats`. 0.2.0 turns
that stub into a real foundation and wires up the clightning
backend that every subsequent verb relies on.

Five tickets — foundation, dispatch, daemon control, unlock,
and CI all need to be working before any verb is useful:

1. **FEAT-170 — foundation prep** — sourceable lib
   (`bin/lightning.sh` symlink + source-mode guard), declare
   runtime deps (`account` / `config` / `secret`; no direct
   `bitcoin` dep — on-chain funding goes through clightning),
   soft probe for `lightning-cli`, and the
   `CLAUDE.md.lightning` template.
2. **FEAT-171 — clightning backend wiring** — verb scripts
   under `libexec/lightning/<verb>` that shell out to
   `lightning-cli` and reshape JSON into TSV / plaintext.
   First verbs: `info`, `node-id`, `peers`, `channels`,
   `balance`.
3. **FEAT-183 — daemon lifecycle management** —
   `lightning daemon {start,stop,restart,status,logs,install}`
   wraps lightningd's lifecycle.
4. **FEAT-184 — wallet unlock** — `lightning unlock` drives
   clightning's `hsmtool` / runes flow and stores the
   password via `secret`. FEAT-183's `daemon-start` calls it
   on restart.
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
- `libexec/lightning/{info,node-id,peers,channels,balance}`
  all work against a regtest lightningd.
- `docs/templates/CLAUDE.md.lightning` exists.
- `tests/unit/lightning.bats` still green; new tests cover
  source-mode, verb dispatch, daemon verbs, and unlock.
- `.github/workflows/test.yml` runs the bats suite green.
- `lightning daemon status` reports healthy after
  `lightning daemon start` + `lightning unlock --stored`.
- `.rpk/version` bumped 0.1.0 → 0.2.0; `.rpk/versions` ledger
  updated.
- FEAT-170, FEAT-171, FEAT-183, FEAT-184, FEAT-191 move to
  `issues/feature/done/`.

## Dependencies

External: `account`, `config`, `secret` (declared runtime);
`lightning-cli` (Core Lightning) on PATH at runtime for any
non-trivial verb.
