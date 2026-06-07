# `accounts` — custodial accounts: feature plan & roadmap

**Status:** In progress — Phase 0/1 foundations skeleton landed (1.4.0);
see `../../../../../thunder/`. Phases 2+ still planning.
**Owner:** rene
**Target:** lift the account / commerce ("neobank") surface out of the
`lightning` package into Rust.

> **MERGED INTO `thunderd`.** This is now the **custodial-accounts tier
> (Phase I)** of the `thunderd` engine — see `../thunderd/design.md` and
> `../roadmap-overview.md`. The change vs. the original plan: the
> custodial logic ships as a **module of the `thunderd` companion
> daemon** (driving `lightningd` over the Unix RPC socket + `waitanyinvoice`
> for settlement), **not** as a separate in-process CLN plugin. It still
> owns its state and uses direct `lightningd` RPC exactly as the "fat
> plugin" would have, so the feature breakdown below stands; the
> milestones 1.4.0–1.9.0 are `thunderd` **Phase I**. Where this doc says
> "plugin", read "thunderd custodial module".

---

## 1. Why

`lightning` started as a thin CLI in front of Core Lightning. It has
since grown a full account-and-commerce stack — anonymous accounts keyed
by a bech32 address, a double-entry msat ledger, commercial invoices
(Skonto / late-fee terms), standing orders (Dauerauftrag), direct-debit
mandates (Lastschrift), an escrow/auth-capture charge lifecycle,
tax export, referrals, an operator fee model, and a compliance hook
layer. That surface is reached over HTTP at
`/.well-known/lightning/v1/accounts/*` via four layers: Apache → Python
CGI → `sudo`-to-operator → `api-account-*` bash verbs → `sqlite3` +
`lightning-cli`.

This is no longer "simple lightning administration." It is a product of
its own, and it bloats the wallet CLI it lives inside. **We want to carve
it out** into a single Core Lightning plugin you install on the node —
named **`accounts`**, because that is what it offers — with a generic
URL scheme:

```
/.well-known/thunder/v1                       ← canonical (custodial + non-custodial)
/.well-known/lightning/accounts/v1            ← deprecated alias (removed after cutover)
```

> **Note (post-consolidation):** the custodial API now lives under
> `thunderd`'s **`/.well-known/thunder/v1`** namespace alongside the
> non-custodial tier; the `/.well-known/lightning/accounts/v1` path
> above is kept only as a deprecated transitional alias.

Apache (or any reverse proxy) does TLS + a one-line `ProxyPass`; the
daemon owns everything behind it.

> **Build model (post-consolidation):** this tier is a **module of the
> `thunderd` companion daemon**, *not* an in-process CLN plugin. It talks
> to `lightningd` over the **Unix RPC socket** (`cln-rpc`), the same way
> the non-custodial tier does, and uses `waitanyinvoice` for settlement
> notifications. Read "plugin" below as "thunderd custodial module"; the
> binary is `thunderd`, the workspace is `thunderd/`.

## 2. Goals / non-goals

**Goals**
- A custodial accounts/commerce JSON API served by the **`thunderd`
  daemon** (Rust), running parallel to `lightningd`.
- **Fat architecture:** `thunderd` talks to `lightningd` directly over
  JSON-RPC (`cln-rpc`, Unix socket) and **owns its own state DB** — no
  `lightning-cli`, no `sudo`-bridge, no `api-account-*` bash verbs at
  runtime. Settlement via `waitanyinvoice`.
- **Factor-out-ready:** zero runtime coupling to the `lightning`
  package. `thunderd` depends only on *standard* CLN RPC, so the
  `thunderd/` workspace can later be `git filter-repo`'d into its own
  repo at **2.0.0** (FEAT-431).
- Behaviour parity with today's `/.well-known/lightning/v1/accounts/*`
  surface (same routes, same auth, same status-code contract).

**Non-goals (for this initiative)**
- The other `/.well-known/lightning/` surfaces — `price`, `node`,
  `decode`, `channels`, `node-funds`, `health`, `lnurlp`, the `users`
  passkey layer, `liquidity`. They stay where they are (CGI) and keep
  their own URLs. The passkey/user layer (FEAT-222) is a *candidate* for
  a separate future plugin, not part of this carve-out.
- On-chain ops, lnd/phoenixd — out of scope per `CLAUDE.md`.
- Re-implementing the operator's *wallet* CLI. `lightning` stays the
  operator's admin tool; it just sheds the commerce stack.

## 3. Target architecture

```
HTTP client (PWA / merchant POS / webhook / MCP agent)
   │  Authorization: Bearer lt_…  (or X-Mandate-Secret)
   ▼
Apache / nginx  —  TLS + ProxyPass /.well-known/thunder/v1/ → 127.0.0.1:<port>/
   ▼
thunderd  (Rust daemon, companion to lightningd — NOT an in-process plugin)
   ├─ HTTP listener        (axum/hyper, localhost-bound)
   ├─ router + authz       (bearer / mandate-secret, rate-limit)
   ├─ business logic       (accounts, ledger, invoices, mandates, charges, …)
   ├─ owned state          (SQLite: accounts/commerce schema + migrations)
   └─ node integration     (cln-rpc over the Unix socket: invoice, pay,
        │                    newaddr, offer, listfunds, waitanyinvoice, …)
        │  JSON-RPC over the lightning-rpc unix socket
        ▼
   lightningd
```

`thunderd` runs as its own daemon (systemd / supervised), not loaded by
`lightningd`. It reaches the node purely through the `lightning-rpc`
Unix socket (`cln-rpc`) and an embedded async HTTP server. (Contrast
`clnrest`, which *is* an in-process plugin — we deliberately stay an
external companion so one daemon serves both account tiers.)

### 3.1 Daemon options (config)
- `accounts-http-bind` (default `127.0.0.1`) — listener address.
- `accounts-http-port` (default e.g. `9737`) — listener port.
- `accounts-db` — path to the plugin's SQLite file (default under the
  node's lightning-dir, e.g. `accounts.sqlite3`).
- `accounts-base-path` (default `/.well-known/thunder/v1`) —
  the path prefix the proxy strips, used for self-links.
- Policy config (fees, referral split, compliance, capability defaults,
  create rate-limit) — see §6.

### 3.2 URL scheme & discovery
- All routes under **`/.well-known/thunder/v1/…`** (the unified namespace),
  preserving today's `…/accounts/…` tail shape.
- Serves its own discovery docs under `…/thunder/v1/` (`versions.json`,
  and `mcp.json` if MCP is kept).
- **Back-compat:** during transition, Apache also points the legacy
  `/.well-known/lightning/accounts/v1` and original CGI
  `/.well-known/lightning/v1/accounts` prefixes at `thunderd` (or 301s to
  the new path) so existing clients don't break; removed after cutover.

## 4. The carve-out boundary (most important design call)

The plugin must be self-contained. The hard part is **state ownership**:
today the `accounts` and `ledger` tables are *shared* between the bash
verbs (operator CLI) and the HTTP API.

Decision for the fat plugin: **the plugin owns the commerce/account
state** (`accounts`, `ledger`, `commerce_invoices`, `standing_orders`,
`mandates`, `mandate_pulls`, `commerce_charges`, `commerce_events`,
`invite_codes`, `prices`, plus its own `apikeys`). The operator CLI's
relationship to that data becomes one of:

- **(a) Read-only via the plugin** — `lightning account …` admin verbs
  call the plugin's RPC/HTTP instead of touching the DB. Cleanest
  boundary; preferred end-state.
- **(b) Frozen** — operator account-admin moves into the plugin (e.g.
  `lightning-cli accounts-admin …` registered RPC methods), and the old
  `account` verb is deprecated.

Either way the runtime dependency arrow points **one way** (CLI →
plugin), never plugin → `lightning`. That is what makes the later repo
extraction a mechanical move.

**Migration:** a one-shot importer reads the existing wallet
`state.db` and copies the commerce/account rows into the plugin DB
(idempotent, re-runnable, with a dry-run). Ships as `accounts-migrate`.

## 5. Security model change (must be designed in, not bolted on)

Today's safety comes from Unix-user isolation (`www-data` can't move
money; only `sudo`-to-`alice` can). A fat plugin runs **in lightningd's
trust domain** and can move real funds. So every guardrail the OS gave
us for free now lives *inside* the plugin and must be airtight:

- Bearer tokens + mandate secrets hashed at rest; constant-time compare.
- HTTP listener bound to localhost only; TLS terminated by the proxy.
- In-plugin rate-limiting (account-create, auth attempts).
- Overdraft / limit / capability checks enforced before any RPC `pay`.
- Compliance pre-hook can veto a money-move before it reaches the node.
- The exit-code contract (`6`→402, `7`→401, backend→502) becomes a typed
  `Result` → HTTP status mapping; keep the same external behaviour.

## 6. Cross-cutting policy that MUST be preserved (port, don't drop)

These live in the bash verbs today and are easy to lose in a rewrite:
- **Operator fee skim** (FEAT-213) — base_sat + rate_ppm to `house`.
- **Referral split** (FEAT-219) — % to the referrer chain.
- **Compliance hooks + audit** (FEAT-233) — `compliance_events`.
- **Capability profiles / gates** (FEAT-243) — `treasury|family|
  prepaid|custodial`, own/foreign fund class.
- **System accounts** — `house`, `escrow`, `others`, `-` and their
  overdraft=allow semantics.
- **Double-entry, msat-precision** atomic ledger moves.

Each becomes a Rust module with its own tests and a golden-output test
against the current verb behaviour.

---

## 7. Roadmap (phases & feature epics)

Phases are sequenced so the plugin is **shippable and shadow-testable
early**, with cutover late. Feature numbers `FEAT-3xx` are *proposed*
placeholders (continue the repo's FEAT-### sequence when filed); the
`from:` notes the existing feature/verb being ported.

### Phase 0 — Foundations (`1.4.0`)
- **FEAT-300 — Daemon skeleton.** The `thunderd/` Rust workspace (one
  Cargo workspace shared with the non-custodial tier), a `thunderd`
  daemon binary (tokio), config options (§3.1), a `cln-rpc` client that
  connects to the `lightning-rpc` Unix socket on startup, a `thunderd-cli
  health` admin command, structured logging. **Not** a `cln-plugin` /
  `getmanifest` handshake — `thunderd` is an external companion daemon.
- **FEAT-301 — Build & install wiring.** `cargo build --release` hooked
  into `make install`; install the `thunderd` + `thunderd-cli` binaries
  and a **systemd unit / service** (run alongside `lightningd`, pointed
  at its `lightning-rpc` socket). The workspace stays standalone-buildable
  for the 2.0.0 extraction.
- **FEAT-302 — Carve-out guardrail.** CI check that the `thunderd/`
  workspace has no build/runtime dependency on `lightning` bash verbs or
  the wallet DB path — enforces the one-way boundary from day one.

### Phase 1 — HTTP server + routing parity (`1.4.0`)
- **FEAT-303 — Embedded HTTP listener.** axum/hyper server bound per
  §3.1; health + 404/405 behaviour; request-body limits; **CORS scaffold**.
- **FEAT-304 — Router & auth.** Port `accounts.py`'s dispatch
  (PATH_INFO → handler), `_lib.py` bearer + mandate-secret auth, the
  status-code contract. Stub handlers return `501` until Phase 4.
- **FEAT-305 — Discovery.** Serve `versions.json` under
  `/.well-known/thunder/v1`; reverse-proxy fragment for Apache/nginx
  (`ProxyPass`), replacing the CGI `ScriptAlias` block. Deprecated
  aliases for the legacy custodial URLs.

### Phase 2 — State layer (carve-out core)
- **FEAT-306 — Owned schema + migrations.** Embed the commerce/account
  schema; versioned, idempotent migrations (sqlx/rusqlite + refinery or
  hand-rolled). WAL mode.
- **FEAT-307 — Ledger engine.** Double-entry, msat, atomic transfers;
  system accounts; balance/overdraft/limit primitives. Property tests
  (sum invariants) + golden tests vs. the bash ledger.
- **FEAT-308 — Importer (`accounts-migrate`).** One-shot, idempotent,
  dry-run import from the existing wallet `state.db`.

### Phase 3 — Node integration (direct RPC)
- **FEAT-309 — cln-rpc wiring.** `invoice` (recv), `pay` (pay), `newaddr`
  (account-id mint + topup target), `listfunds`/`bkpr-*` (balances),
  `decode`. Replace every `lightning-cli` shell-out.
- **FEAT-310 — Settlement reconciliation.** Subscribe to
  `invoice_payment` / `waitanyinvoice`; book settlements to the ledger;
  FEAT-244-style `others` reconciliation for external flows.
- **FEAT-311 — BOLT-12.** `offer` (recv-reusable), `fetchinvoice`+`pay`
  (pay to offer).
- **FEAT-312 — Withdraw / submarine swap.** Decision: native Boltz HTTP
  client in Rust vs. the single sanctioned shell-out to `boltzcli`.
  (Flagged as an open decision — see §8.)

### Phase 4 — Business features (port each verb family)
Each ports a verb family into a Rust module + handler, behind the
already-wired routes:
- **FEAT-313 — Accounts CRUD** (create/list/balance/topup/close/api-key/
  describe). *from FEAT-212, 286, 287, 249.*
- **FEAT-314 — Payments** (pay/recv/recv-reusable/transfer/withdraw).
  *from FEAT-212, 223.*
- **FEAT-315 — Commercial invoices** (terms: Skonto/late-fee; references;
  effective-amount recompute). *from FEAT-225.*
- **FEAT-316 — Standing orders + in-plugin runner.** The cron/sidecar
  becomes a plugin timer task. *from FEAT-226.*
- **FEAT-317 — Mandates / direct debit** (create/patch/revoke, charge by
  secret, pulls + approve/deny). *from FEAT-227, 231.*
- **FEAT-318 — Commerce charges** (hold/release, authorize/capture/void,
  refund, installments, dunning) + `commerce_events`. *from FEAT-228.*
- **FEAT-319 — History, notes, tax export** (CSV/JSON, fiat valuation per
  ts). *from FEAT-230, 246, 254.*
- **FEAT-320 — Referrals & invite codes.** *from FEAT-218, 219, 220.*

### Phase 5 — Cross-cutting policy
- **FEAT-321 — Fee skim + referral split** (§6).
- **FEAT-322 — Compliance hooks + audit** (§6).
- **FEAT-323 — Capability profiles / fund class** (§6).
- **FEAT-324 — Rate-limiting** (account-create + auth).

### Phase 6 — Surface extras (optional)
- **FEAT-325 — MCP server** re-exposed from the plugin (`mcp.json` +
  JSON-RPC tools), if we keep it on this surface. *from FEAT-212 MCP.*

### Phase 7 — Cutover
- **FEAT-326 — Shadow run.** Plugin live alongside the CGI; compare
  responses on a mirrored path; fix drift.
- **FEAT-327 — Flip the proxy.** Apache `ProxyPass` to the plugin; old
  URL 301s to the new one.
- **FEAT-328 — Retire the old layer.** Delete `api-account-*` verbs, the
  `wellknown/api/accounts.py` dispatcher + commerce `_lib.py` paths, the
  CGI Apache block; trim the shared `state.db` schema; update man pages
  (`CLAUDE.md` §9) and `share/doc/.../api/spec.md`. **This is the step
  that shrinks `lightning` back toward "simple administration."**

### Phase 8 — Factor out
- **FEAT-329 — Extract repo.** `git filter-repo` `plugin/accounts/` into
  `cln-accounts` with its own `.rpk`, CI, semver. `lightning` either
  bundles it as a build dep or it installs independently. The boundary
  built in Phase 0–2 makes this mechanical.

---

## 8. Open decisions (need your call before/within Phase 0–3)
1. **Operator-CLI ↔ plugin coupling** (§4): admin via plugin RPC
   *(a, preferred)* vs. freeze admin into the plugin *(b)*.
2. **Withdraw** (FEAT-312): native Rust Boltz client vs. one sanctioned
   `boltzcli` shell-out.
3. **MCP** (FEAT-325): port to the plugin now, later, or drop from this
   surface.
4. **DB engine/crate**: `rusqlite` (sync, simple) vs. `sqlx` (async,
   compile-time-checked) for the async axum server.
5. **In-tree path & workspace**: confirm `plugin/accounts/` as the crate
   home and a workspace root that survives extraction.

## 9. What stays the same
- clightning-only backend (`CLAUDE.md` §1).
- The external contract: routes, bearer auth, the `6→402 / 7→401 /
  →502` status mapping, JSON in/out.
- Reverse proxy does TLS only; no business logic in Apache.

---

## 10. Milestones & sequencing corrections (planning round 2)

This is **Track A** in the wider plan — see `../roadmap-overview.md` for
how it relates to the PWA carve-out (Track B) and `thunderd` (Track C).

### 10.1 Milestone map

Milestones are repo semver releases (`1.x.0`). Current repo version is
`1.3.1`. Phase I (custodial) builds over **`1.4.0` → `1.9.0`**, running
*alongside* the existing CGI. The cutover + extraction is the **`2.0.0`
target** — see below.

| Release | Theme | Features | Exit criteria |
|---|---|---|---|
| **1.4.0 — Skeleton** | Daemon loads & serves | 300, 301, 302, 303, 304, 305 | `thunderd` up, routed + bearer/mandate auth (handlers 501-stub), carve-out CI guard green, proxy fragment, **CORS scaffold** |
| **1.5.0 — Core engine** | State + node + policy *hooks* | 306, 307, 308, 309, 310 **+ policy middleware seam** | Owned DB & migrations, double-entry ledger, importer, `cln-rpc` wired, settlement; `balance` real; fee/compliance/capability hook points exist |
| **1.6.0 — Wallet parity** | Move money | 313, 314, 311, 312 | accounts CRUD + pay/recv/recv-reusable/transfer/withdraw end-to-end, **each routed through the policy hooks** |
| **1.7.0 — Commerce** | Neobank surface | 315, 316, 317, 318, 319, 320 | invoices, standing orders, mandates, charges, history/tax, referrals |
| **1.8.0 — Policy hardening** | Finish guardrails | 321, 322, 323, 324 | fee skim, compliance audit, capability profiles, rate-limit fully enforced |
| **1.9.0 — Extras** | optional/parallel | 325 | MCP surface re-exposed |

**`2.0.0` — strip-down & separation (the target).** The cutover (326,
327, 328): retire the CGI + `api-account-*` verbs + commerce schema from
`lightning` so it returns to *simple administration*, flip the proxy to
`thunderd`, drop the deprecated aliases — **and separate `thunder` into
its own repo** (329, unified with FEAT-431). This is the breaking change
that bumps the major version.

**Critical path:** 1.4.0 → 1.5.0 → 1.6.0 → 1.7.0 → 2.0.0. 1.8.0
hardens what 1.6.0/1.7.0 establish; 1.9.0 is parallel/optional.

### 10.2 Corrections to §7

- **Policy is a foundational seam, not a late phase.** §7 lists the
  cross-cutting policy (fees/compliance/capabilities, 321–323) *after*
  the money features. That is wrong for a real node — every money-moving
  verb today already enforces overdraft, capability gates and the
  compliance-deny hook, so shipping 1.6.0 without them would bypass the
  operator's loss-prevention and revenue. **Land the policy hook points
  (middleware) in 1.5.0, plug each feature into them in 1.6.0/1.7.0, and
  use 1.8.0 only to flesh out the full rule set + audit.**
- **CORS is a new requirement** introduced by the PWA carve-out
  (`thunder-pay`). Once the PWA can be served from a different origin, the
  daemon must support an explicit **CORS origin-allowlist + preflight**,
  and the bearer token travels cross-origin. Land the scaffold in 1.4.0
  and the allowlist in 1.5.0. The default/recommended deploy stays
  **same-origin** (may bundle + serve the PWA); cross-origin is opt-in.
