# Milestone 1.0.0 — walkthrough & SIT validation

```
milestone: 1.0.0
title: walkthrough & SIT validation
status: open
depends_on: 0.6.0
```

## Summary

The 1.0.0 graduation milestone: the package is feature-complete
through 0.6.0, and this milestone validates the full surface
end-to-end. A reproducible walkthrough exercises the happy path
on regtest, and a SIT suite runs the same path against
per-backend containers in CI.

Two tickets:

1. **FEAT-181 — walkthrough** — clightning on regtest →
   channel open → pay → Lightning Address → Loop. Lives under
   `share/doc/lightning/walkthrough/` and is reproducible by
   a reader following the man page.
2. **FEAT-182 — SIT tests** — `tests/sit/` runs the same
   walkthrough against `clightning`, `lnd`, and `phoenixd`
   regtest containers, gated by env so it's opt-in locally
   and mandatory in CI.

## Dependency Order

FEAT-181 → FEAT-182. The walkthrough script becomes the
backbone of the SIT runner.

## Exit Criteria

- `share/doc/lightning/walkthrough/` runs to completion on a
  clean regtest.
- `tests/sit/` green against all three backends in CI.
- README links to the walkthrough.
- `.rpk/version` bumped 0.6.0 → 1.0.0; ledger updated.
- FEAT-181, FEAT-182 move to `issues/feature/done/`.

## Dependencies

Hard: 0.6.0. External: docker / podman for backend containers
in SIT.
