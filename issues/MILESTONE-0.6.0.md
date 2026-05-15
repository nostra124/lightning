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

Five tickets:

1. **FEAT-177 — self-contained packaging** — `docs/lightning.md`
   CLI contract reference, completion scripts, the
   `CLAUDE.md` agent guide pass to cover the full surface.
2. **FEAT-178 — vendor Lightning standards** — BOLT 1..12 +
   LNURL LUDs + Lightning Address spec + draft pointers
   (watchtowers, onion messages) under
   `share/doc/lightning/standards/` (README is already there
   from the 0.1.0 import; this finishes the vendoring).
3. **FEAT-179 — `lightning(1)` man page** — full man page
   citing the vendored standards by section.
4. **FEAT-180 — `lightning-wallet` agent skill** — flesh out
   `skills/lightning-wallet/SKILL.md` so an agent can drive
   the wallet end-to-end.
5. **FEAT-189 — Tor / network privacy** —
   `lightning tor {on,off,status}` plus default-on Tor at
   `daemon install` time. Sits in this milestone because the
   man page and walkthrough document it.

## Dependency Order

FEAT-178 first (the standards are referenced by 177 and 179).
FEAT-189 lands in parallel with 178 (independent verb work).
FEAT-177 and FEAT-179 after that. FEAT-180 last (the skill
documents the full verb surface including Tor, and references
the man page).

## Exit Criteria

- `share/doc/lightning/standards/` contains BOLT 01..12 (incl.
  08 transport), the LNURL LUDs, the Lightning Address spec,
  and a `README-drafts.md` pointing at watchtowers (BOLT-13
  draft) and onion-messages drafts.
- `docs/lightning.md` covers every verb shipped through 0.5.0
  plus the Tor verbs from FEAT-189.
- `share/man/man1/lightning.1` renders cleanly and references
  the standards directory.
- `skills/lightning-wallet/SKILL.md` describes the full wallet
  workflow including the Tor default.
- `lightning tor on` advertises a v3 onion within 30s on
  regtest; `lightning tor status` reports `leak: none`.
- Unit test contract extended (help / man / standards
  presence; Tor verbs).
- `.rpk/version` bumped 0.5.0 → 0.6.0; ledger updated.
- FEAT-177, FEAT-178, FEAT-179, FEAT-180, FEAT-189 move to
  `issues/feature/done/`.

## Dependencies

Hard: 0.5.0 (the surface that gets documented).
