# Milestone 0.5.0 — addresses & liquidity

```
milestone: 0.5.0
title: addresses & liquidity
status: open
depends_on: 0.4.0
```

## Summary

Ecosystem features that sit on top of the core verbs:

1. **FEAT-175 — liquidity layer** — inbound liquidity is the
   primary user story (a fresh node has zero inbound capacity
   and can't receive). `lightning liquidity in <amount>`
   acquires inbound via the default provider; LSPS1 channel
   purchase, Loop, and Boltz are all wired. Outbound is the
   symmetric secondary case.
2. **FEAT-176 — Lightning Addresses** —
   `alice@example.com`-style addresses: pay them, create your
   own, and host them via cluster Apache, local Apache, or
   the standalone bash daemon.
3. **FEAT-195 — bank mode** — single-user multi-account
   discipline: overdraft policy, auto-address-on-account-
   create, per-period statements. Sits on top of FEAT-174 +
   FEAT-193 + FEAT-176, so it lands here once addresses are
   in.

## Dependency Order

FEAT-175 and FEAT-176 are independent. FEAT-195 depends on
FEAT-176 (auto-address) and FEAT-174 / FEAT-193 from 0.4.0.
All three depend on the pay / invoice verbs from 0.3.0 and
the wallet ledger from 0.4.0.

## Exit Criteria

- `lightning liquidity in <amount>` on a fresh zero-inbound
  node acquires inbound capacity (LSPS1 against a test LSP
  is the must-pass path; Loop / Boltz are also wired).
- `lightning liquidity status` reflects the new capacity.
- `lightning address pay <addr>` resolves and pays a
  Lightning Address.
- `lightning address create` issues an address bound to the
  active wallet; `apache-snippet` emits a working vhost
  fragment.
- `lightning account create alice --limit 50000 --host
  host.com` creates the account, issues `alice@host.com`,
  and enforces the ceiling on subsequent pays.
- `lightning ledger statement --account alice --period
  2026-03` produces a parseable plaintext statement.
- Unit test contract extended.
- `.rpk/version` bumped 0.4.0 → 0.5.0; ledger updated.
- FEAT-175, FEAT-176, FEAT-195 move to `issues/feature/done/`.

## Dependencies

Hard: 0.4.0. Soft: external services (Boltz, Loop server) —
mocked at unit-test level, real in SIT (FEAT-182).
