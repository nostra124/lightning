# Milestone 0.6.0 — self-contained packaging, standards & docs

```
milestone: 0.6.0
title: self-contained packaging, standards & docs
status: open
depends_on: 0.5.0
```

## Summary

Once the verb surface is complete (0.2.0 → 0.5.0), this
milestone makes the package self-describing: vendored
standards, a man page that cites them, an agent skill, and the
operational packaging glue that documents and tests the whole
surface.

Four tickets:

1. **FEAT-177 — self-contained packaging** — `docs/lightning.md`
   CLI contract reference, completion scripts, the
   `CLAUDE.md` agent guide pass to cover the full surface.
2. **FEAT-178 — vendor Lightning standards** — BOLT 1..11 +
   LNURL LUDs + Lightning Address spec under
   `share/doc/lightning/standards/` (README is already there
   from the 0.1.0 import; this finishes the vendoring).
3. **FEAT-179 — `lightning(1)` man page** — full man page
   citing the vendored standards by section.
4. **FEAT-180 — `lightning-wallet` agent skill** — flesh out
   `skills/lightning-wallet/SKILL.md` so an agent can drive
   the wallet end-to-end.

## Dependency Order

FEAT-178 first (the standards are referenced by 177 and 179).
FEAT-177 and FEAT-179 in parallel after that. FEAT-180 last
(the skill documents the full verb surface and references the
man page).

## Exit Criteria

- `share/doc/lightning/standards/` contains all BOLT 1..11
  texts, the LNURL LUDs, and the Lightning Address spec, each
  with a stable filename and a top-level `README.md` index.
- `docs/lightning.md` covers every verb shipped through 0.5.0.
- `share/man/man1/lightning.1` renders cleanly and references
  the standards directory.
- `skills/lightning-wallet/SKILL.md` describes the full wallet
  workflow.
- Unit test contract extended (help / man / standards
  presence).
- `.rpk/version` bumped 0.5.0 → 0.6.0; ledger updated.
- FEAT-177, FEAT-178, FEAT-179, FEAT-180 move to
  `issues/feature/done/`.

## Dependencies

Hard: 0.5.0 (the surface that gets documented).
