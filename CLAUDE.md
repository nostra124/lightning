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

Externally we depend on `python3` for the Apache CGI
scripts that host Lightning Addresses (FEAT-176) and
the `.well-known/lightning/` JSON API (FEAT-196). The
shell verbs remain the source of truth — Python
scripts are thin HTTP frontends that shell out.

## 5. What is intentionally duplicated

- **Verb-level command construction** — each verb
  script shells out to `lightning-cli` inline; no shared
  cli-helper library.
- **Invoice / payment-hash parsing** — implemented in
  each verb that needs it.
- **CGI endpoint scripts** — one Python file per
  endpoint (FEAT-196), only `_lib.py` shared. Endpoint
  scripts don't reach across each other.

## 6. Consumers

End users (personal Lightning wallets); external HTTP
callers (phone / JS frontend / webhooks) via the
`.well-known/lightning/` API (FEAT-196). Cluster
integration is not on the critical path — see FEAT-190
(obsolete).

## 7. Build / install

`./configure && make install`. Stow-based.

## 8. Versioning

Semver. `tests/unit/lightning.bats` is the contract.
