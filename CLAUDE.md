# `lightning` — developer notes

> Mirrors `CLAUDE.md.foundation`, specialised for
> `lightning`.

## 1. Scope

`lightning` is the multi-backend Lightning Network
frontend. Its scope is the verb surface uniform
across clightning / lnd / phoenixd, plus vendored
BOLT and LNURL specs.

Out of scope: on-chain operations (that's `bitcoin`);
custodial wallets (we're non-custodial-by-default).

## 2. Repo conventions

Standard rpk per-package: `bin/lightning` dispatcher
plus libexec lookup for backend plugins
(`libexec/lightning/{clightning,lnd,phoenixd}`).

Educational package: vendors BOLT 1..11 + LNURL LUDs
+ Lightning Address spec under
`share/doc/lightning/standards/` (FEAT-178, partial).

## 3. Issue authoring

Same as `CLAUDE.md.foundation`. **Bugs come before
features at the same priority level.**

## 4. The no-shared-lib policy

`lightning` calls only `account` at runtime. The
on-chain leg of channel opens is handled by the
backend daemon itself (each backend ships with its
own bitcoind connection); we never shell out to the
`bitcoin` package directly. Backend plugins call only
their daemon CLI.

## 5. What is intentionally duplicated

- **Per-backend command construction** — each
  backend plugin's verbs are inline; no shared
  backend-helpers.
- **Invoice / payment-hash parsing** — implemented
  per backend.

## 6. Consumers

End users (personal Lightning wallets); cluster
integrations exposing payment endpoints (FEAT-079
cluster apache + lightning).

## 7. Build / install

`./configure && make install`. Stow-based.

## 8. Versioning

Semver. `tests/unit/lightning.bats` is the contract.
