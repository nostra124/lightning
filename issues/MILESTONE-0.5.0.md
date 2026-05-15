# Milestone 0.5.0 — addresses & liquidity

```
milestone: 0.5.0
title: addresses & liquidity
status: open
depends_on: 0.4.0
```

## Summary

Ecosystem features that sit on top of the core verbs:

1. **FEAT-175 — liquidity layer** — Loop / Boltz / generic LSP
   wrappers (`lightning loop {out,in}`, `lightning lsp …`).
   Routes through whichever backend is active.
2. **FEAT-176 — Lightning Addresses** —
   `alice@example.com`-style addresses: pay them, create your
   own, and host them (the host flow needs a public HTTP
   endpoint; covered as an optional sub-feature with a
   walkthrough deferred to 1.0.0 / FEAT-181).

## Dependency Order

FEAT-175 and FEAT-176 are independent and can land in either
order. Both depend on the pay / invoice verbs from 0.3.0 and
the wallet ledger from 0.4.0 (for recording loop fees and
address-pay history).

## Exit Criteria

- `lightning loop {out,in}` works against at least one
  liquidity provider (Boltz is the simplest because it
  requires no account).
- `lightning lsp …` provides a minimal generic-LSP surface.
- `lightning address pay <addr>` resolves and pays a
  Lightning Address.
- `lightning address create` issues an address bound to the
  active wallet.
- Unit test contract extended.
- `.rpk/version` bumped 0.4.0 → 0.5.0; ledger updated.
- FEAT-175, FEAT-176 move to `issues/feature/done/`.

## Dependencies

Hard: 0.4.0. Soft: external services (Boltz, Loop server) —
mocked at unit-test level, real in SIT (FEAT-182).
