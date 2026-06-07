# Roadmap overview — one engine + one frontend

**Status:** Planning. No code yet; this is the feature/milestone plan.

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

## Roadmap (folded into the two deliverables)

| Deliverable | Phase / milestones | Features | Doc |
|---|---|---|---|
| `thunderd` — **Phase I: custodial** | (was Track A) M0–M6 | FEAT-300 … 328 | `accounts-plugin/roadmap.md` |
| `thunderd` — **Phase II: non-custodial** | TH0–TH8 | FEAT-400 … 432 | `thunderd/design.md` |
| `thunderd` — extraction | — | FEAT-329 / 431 | both |
| `thunder-pay` — PWA | PW0–PW3 | FEAT-340 … 349 | `thunder-pay.md` |

Feature numbers are **proposed placeholders**. The custodial milestones
(M0–M6) are now `thunderd`'s **Phase I** and ship first (simpler, reuse
existing logic); the non-custodial `TH` milestones are **Phase II**.

## Sequencing

1. **`thunderd` Phase I (custodial)** first — the daemon skeleton +
   `lightningd` RPC + owned state/ledger + commerce + policy + API.
   Custodial MVP. (Establishes the CORS `thunder-pay` needs.)
2. **`thunder-pay`** in parallel — the PWA frontend + the device-signing
   primitives (seed on device, `@noble/curves`, WebAuthn-PRF storage,
   `signer-core` WASM) that Phase II reuses.
3. **`thunderd` Phase II (non-custodial)** — per-tenant LDK + the
   validating remote signer + cloud sync. Reuses Phase I's fee engine and
   `thunder-pay`'s `signer-core`.

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
