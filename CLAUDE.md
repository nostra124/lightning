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

**Use cases (FEAT-203 scope decision, 2026-05-20):**

- **Primary**: personal Lightning wallet on a laptop or
  small server. Defaults are tuned for this case — small
  channel count (3-5), passive fee policy, infrequent
  rebalancing. See
  `share/doc/lightning/guides/personal-node.md` (FEAT-202).
- **Secondary**: small-to-medium routing node (up to ~20
  BTC capacity). Same verbs, used at higher cardinality
  + with the routing-specific verbs (`fee`, `rebalance`,
  `alert`, `peer score`). Routing-specific operational
  defaults are documented, not enforced — operators tune
  individual settings. See
  `share/doc/lightning/guides/routing-node.md` (FEAT-203).
- **Out of scope**: large-scale commercial routing (50+
  BTC, multi-region, dedicated NOC). Those operators want
  lnd + balance-of-satoshis; we don't try to compete.

Other out-of-scope items: on-chain operations (handled by
the backend daemon's built-in bitcoind connection);
custodial wallets (we're non-custodial-by-default);
lnd / phoenixd support.

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
the `.well-known/lightning/` JSON API (FEAT-196), and on
`sqlite3` for the per-wallet store (FEAT-193). The shell
verbs remain the source of truth — Python scripts are
thin HTTP frontends that shell out.

Three-user separation on system-mode installs
(FEAT-183): `clightning` runs the daemon, the operator
(`alice`) runs `lightning` from her shell and owns the
wallet repo + secret store, `www-data` runs Apache and
the CGI. The bridge is sudo-to-alice; `www-data` never
talks to lightningd directly.

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

- **Personal wallet operators** — `lightning daemon
  install`, `wallet info`, `pay`, `invoice`, etc.
- **Small / medium routing-node operators** — same verbs
  plus `fee`, `rebalance`, `alert`, `peer score`. Up to
  ~20 BTC capacity.
- **External HTTP callers** — phone / JS frontend /
  webhooks via the `.well-known/lightning/` API
  (FEAT-196).

Cluster integration is not on the critical path — see
FEAT-190 (obsolete).

## 7. Build / install

`./configure && make install`. Stow-based.

## 8. Versioning

Semver. `tests/unit/lightning.bats` is the contract.

## 9. Man pages (FEAT-221)

One man page per top-level verb under `share/man/man1/lightning-<verb>.1`;
`lightning.1` stays a high-level overview that cross-references them.
When a verb's CLI surface changes, update the matching
`share/man/man1/lightning-<verb>.1` page **in the same PR**. A bats test
asserts every dispatchable verb (excluding `_*` helpers and the `api-*`
HTTP-bridge verbs, which are documented via the FEAT-209 inline docs) has
a page whose `.SH NAME` carries the verb.
