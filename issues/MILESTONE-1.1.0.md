# Milestone 1.1.0 — foundation & multi-backend abstraction

```
milestone: 1.1.0
title: foundation & multi-backend abstraction
status: open
depends_on: ~
```

## Summary

The 1.0.0 import landed a stub `bin/lightning` (help + version
only) and a contract `tests/unit/lightning.bats`. 1.1.0 turns
that stub into a real foundation and lays down the
multi-backend dispatch layer that every subsequent verb relies
on.

Two tickets:

1. **FEAT-170 — foundation prep** — sourceable lib
   (`bin/lightning.sh` symlink + source-mode guard), declare
   runtime deps (`account` / `config` / `secret`; `bitcoin`
   for on-chain channel opens), soft probes for `lightningd`
   / `lnd` / `phoenixd`, and the `CLAUDE.md.lightning`
   template.
2. **FEAT-171 — multi-backend abstraction** — auto-detect the
   active daemon and route verbs to
   `libexec/lightning/{clightning,lnd,phoenixd}/<verb>`.

## Dependency Order

FEAT-170 → FEAT-171. 171 needs the libexec lookup and source
guard from 170 in place before backend plugins can be wired.

## Exit Criteria

- `bin/lightning.sh` symlink resolves; sourcing it defines
  functions without executing the dispatcher.
- Runtime deps declared in `.rpk/depends/`.
- At least one backend plugin directory under
  `libexec/lightning/` with a working `info` (or equivalent)
  verb proving auto-detect dispatch.
- `docs/templates/CLAUDE.md.lightning` exists.
- `tests/unit/lightning.bats` still green; new tests cover
  source-mode and backend dispatch.
- `.rpk/version` bumped 1.0.0 → 1.1.0; `.rpk/versions` ledger
  updated.
- FEAT-170 and FEAT-171 move to `issues/feature/done/`.

## Dependencies

External: `account`, `config`, `secret` (declared runtime);
`bitcoin` (declared, used only by FEAT-172 once channel opens
land). At least one of `lightningd` / `lnd` / `phoenixd`
available at runtime for any non-trivial verb.
