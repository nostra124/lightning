# `lightning` — developer notes

> Mirrors `CLAUDE.md.foundation`, specialised for
> `lightning`.

## 1. Scope

`lightning` is the Lightning Network frontend
targeting **clightning (Core Lightning)** as the single
backend, plus vendored BOLT and LNURL specs. lnd and
phoenixd support are explicitly out of scope; the libexec
plugin layout leaves the door open for future backends
but ships only the clightning plugin.

Out of scope: on-chain operations (handled by the backend
daemon's built-in bitcoind connection); custodial
wallets (we're non-custodial-by-default); lnd / phoenixd
support.

## 2. Repo conventions

Standard rpk per-package: `bin/lightning` dispatcher
plus libexec lookup for verbs (`libexec/lightning/<verb>`).
The clightning calls live directly under those verb
scripts — no extra "backend plugin" layer.

Educational package: vendors BOLT 1..11 + LNURL LUDs
+ Lightning Address spec under
`share/doc/lightning/standards/` (FEAT-178, partial).

## 3. Issue authoring

Same as `CLAUDE.md.foundation`. **Bugs come before
features at the same priority level.**

## 4. The no-shared-lib policy

`lightning` calls only `account` at runtime. The
on-chain leg of channel opens is handled by clightning
itself (its built-in bitcoind connection); we never
shell out to the `bitcoin` package directly. Verb
scripts call only `lightning-cli`.

## 5. What is intentionally duplicated

- **Verb-level command construction** — each verb
  script shells out to `lightning-cli` inline; no shared
  cli-helper library.
- **Invoice / payment-hash parsing** — implemented in
  each verb that needs it.

## 6. Consumers

End users (personal Lightning wallets); cluster
integrations exposing payment endpoints (FEAT-079
cluster apache + lightning).

## 7. Build / install

`./configure && make install`. Stow-based.

## 8. Versioning

Semver. `tests/unit/lightning.bats` is the contract.
