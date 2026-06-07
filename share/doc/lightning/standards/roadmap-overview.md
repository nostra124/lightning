# Roadmap overview — one engine + one frontend

**Status:** In progress, under `thunderd/`. The **custodial tier (Phase I)
is implemented** end-to-end (accounts, ledger, payments, commerce, policy,
passkey auth, importer) and the **non-custodial component set** —
`thunderd`, `thunderd-cli`, `signer-core`, `thunder` — exists with the A2
remote-signer loop (build PSBT → validate → sign) proven across crates
(51 tests, CI green). **Not yet done:** the per-tenant LDK channel engine,
the `thunder-pay` PWA, and the breaking `2.0.0` cutover (gated behind a
shadow-run against the live node). See `../../../../thunderd/STATUS.md`
for the exact status + cutover runbook. The rest of this document is the
original feature/milestone plan.

The account/commerce stack outgrew the `lightning` admin CLI. After
several rounds the plan has **collapsed from three tracks into two
deliverables**:

1. **`thunderd`** — one Rust engine (a companion daemon to `lightningd`)
   offering **both custodial and non-custodial accounts for Lightning**.
   It absorbs the former *accounts plugin* (custodial) and the former
   *pwalight* (non-custodial). Ships with **`thunderd-cli`** (server
   admin) and **`thunder`** (client remote-signer CLI).
2. **`thunder-pay`** — the **PWA web frontend** for `thunderd`, hosted on
   Apache; later its own installable app.

So the build surface is now just **one Rust codebase + one PWA**.

## Why "thunder"

One **lightning**, many **thunders**. A node runs a single `lightningd`;
many `thunderd`-served accounts and clients hang off it. The name encodes
both the **one-to-many** fan-out *and* the **dependency** — thunder
follows lightning: `thunderd` only works with a `lightningd` companion.

## One engine, two account tiers

| Tier | Custody | How `thunderd` does it |
|---|---|---|
| **Custodial** | node holds keys; an account is a ledger row | Drives the companion `lightningd` over the Unix RPC socket (+ `waitanyinvoice` for settlement). This is the old commerce/neobank surface (invoices, mandates, charges, standing orders, tax export, …). |
| **Non-custodial** | seed on the device, signs remotely (**A2**) | Runs per-tenant LDK nodes keyed by the user; the companion `lightningd` is LSP / trampoline / counterparty / chain gateway. Includes an **on-chain wallet** (watch-only xpub in the daemon, PSBT signed on device). |

Both tiers are one daemon, one state model, one fee engine, one API,
under one namespace: **`/.well-known/thunder/v1`** — custodial *and*
non-custodial. The legacy custodial paths (`/.well-known/lightning/accounts/v1`
and the original CGI `/.well-known/lightning/v1/accounts`) survive only as
**deprecated transitional aliases**, removed after cutover. **No
in-process CLN plugin is needed** — `thunderd` is a companion daemon that
reaches `lightningd` purely through its Unix RPC socket, for both tiers.

## Components

`thunderd` (daemon) · `thunderd-cli` (server admin) · `thunder` (client
remote-signer CLI) · `thunder-pay` (PWA frontend) · `signer-core`
(shared Rust signer crate, native + WASM).

## Topology

```
 clients (hold keys for the non-custodial tier; sign remotely):
   • thunder CLI        • thunder-pay PWA / Tauri
        │  HTTPS  /.well-known/thunder/v1   (+ push-to-sign)
        ▼
 ┌──────────────────────────────────────────────┐
 │  thunderd   (ONE Rust daemon)                  │
 │   • custodial accounts  (ledger; was Track A)  │
 │   • non-custodial accounts (per-tenant LDK,    │
 │     remote signer; was pwalight)               │
 │   • JSON API + E2E-encrypted cloud sync        │
 │   • admin via thunderd-cli                      │
 └───────────────┬──────────────────────────────┘
                 │  Unix (RPC) socket — same machine
                 ▼
 ┌──────────────────────────────────────────────┐
 │  companion lightningd                          │
 │   • holds node funds (custodial tier)          │
 │   • LSP / trampoline / counterparty / gateway  │
 │     (non-custodial tier)                       │
 └──────────────────────────────────────────────┘
        ▲ Apache: TLS + serves thunder-pay + proxies /.well-known/thunder/v1
```

## Roadmap (semver releases)

Milestones are repo semver releases. **Current version: `1.3.1`.** The
whole build runs in the `1.x` line *alongside* the existing `lightning`
CGI; **`2.0.0` is the target** — the breaking release where `lightning`
is **stripped down** to simple administration and **`thunder` is
separated** into its own repo.

| Deliverable | Releases | Features | Doc |
|---|---|---|---|
| `thunderd` — **Phase I: custodial** | **1.4.0 → 1.9.0** | FEAT-300 … 328 | `accounts-plugin/roadmap.md` |
| `thunder-pay` — PWA (parallel) | **1.10.0 → 1.12.0** | FEAT-340 … 349 | `thunder-pay.md` |
| `thunderd` — **Phase II: non-custodial** | **1.13.0 → 1.20.0** | FEAT-400 … 432 | `thunderd/design.md` |
| **`2.0.0` — strip-down & separation** | **2.0.0** | FEAT-326–328 (strip `lightning`) + 329/349/431 (separate `thunder`) | all three |

Feature numbers are **proposed placeholders**.

### 🎯 The 2.0.0 target

Everything before `2.0.0` is built in-repo, running next to today's CGI.
**`2.0.0`** flips the switch: retire the CGI + `api-account-*` verbs +
commerce schema from `lightning` (it returns to *simple administration*),
point the proxy at `thunderd`, drop the deprecated aliases, and move
`thunderd` + `thunder-pay` + clients into their **own repo**. After
`2.0.0`: `lightning` is a lean Core-Lightning admin CLI again, and
`thunder` is a standalone product.

## Sequencing

1. **`thunderd` Phase I (custodial), `1.4.0`–`1.9.0`** — daemon skeleton
   + `lightningd` RPC + owned state/ledger + commerce + policy + API.
   Custodial MVP, alongside the old CGI. (Establishes the CORS
   `thunder-pay` needs.)
2. **`thunder-pay`, `1.10.0`–`1.12.0`** (parallel) — the PWA frontend +
   device-signing primitives (seed on device, `@noble/curves`,
   WebAuthn-PRF storage, `signer-core` WASM) that Phase II reuses.
3. **`thunderd` Phase II (non-custodial), `1.13.0`–`1.20.0`** — per-tenant
   LDK + the validating remote signer + on-chain + cloud sync. Reuses
   Phase I's fee engine and `thunder-pay`'s `signer-core`.
4. **`2.0.0`** — strip `lightning` down + separate `thunder`.

## Cross-cutting decisions taken

- **One engine, companion daemon.** `thunderd` drives `lightningd` over
  the Unix RPC socket for *both* tiers — no separate in-process CLN
  plugin. Custodial still owns its state and uses direct RPC (+
  `waitanyinvoice` for settlement) exactly as the "fat plugin" would
  have.
- **Non-custodial custody bar: A2** — true remote signing (seed never
  reaches our servers in plaintext). Engine **LDK** (pluggable signer);
  signer **VLS-based validation**. Not Greenlight, not Ark, not a reused
  phoenixd — a fresh single multi-tenant process.
- **Fat daemon, thin clients.** `thunderd` does all heavy work for
  **Lightning *and* on-chain** (UTXO tracking, coin selection, PSBT
  construction, fee estimation, broadcast, chain watching). The clients
  only **hold keys + sign + render** — `thunderd` hands them a
  ready-to-sign PSBT/sighash; they validate, sign, return. A new client
  is little more than a validating signer + UI.
- **Clients:** `thunder` CLI first, then `thunder-pay` (PWA) + **Tauri**
  (desktop persistent signer; Android TWA; iOS signer-capable host).
- Working titles **`thunderd` / `thunderd-cli` / `thunder` /
  `thunder-pay`**; in-repo for now, extracted later.

## Open spikes

Companion-`lightningd` plumbing (FEAT-407) · VLS-in-a-pool · signer-state
sync blob · account=channel vs sub-balance · watchtower · `thunder`
client shape.
</content>
