# Roadmap overview — three tracks

**Status:** Planning. No code yet; this is the feature/milestone plan.

The account/commerce stack has outgrown the `lightning` admin CLI. The
plan splits it into three independently-shippable, separately-extractable
tracks. All three are designed as **one-way carve-outs** (no runtime
dependency back into `lightning`) so each can later move to its own repo.

| Track | Working name | What | Custody | Lang | Doc |
|---|---|---|---|---|---|
| **A** | `accounts` plugin | The commerce/neobank HTTP API, carved out of the CLI into a fat Core Lightning plugin (direct lightningd RPC, plugin-owned state), served at `/.well-known/lightning/accounts/v1`. | Custodial | Rust (`cln-plugin`) | `accounts-plugin/roadmap.md` |
| **B** | `lightning-pwa` | The existing PWA (`share/lightning/ui/`), separated so it can deploy on its own host as a pure client of the API (config-driven base URL, CORS, real service worker). | — (client) | JS/PWA (+Tauri) | `pwa-carveout.md` |
| **C** | **`thunderd`** | A small **remote-signer Lightning daemon** offering **non-custodial accounts**: it runs **parallel to a `lightningd` companion** (Unix socket) and lets users manage their own channels while **the seed stays on the device and signs remotely (A2)**. One efficient Rust process, many tenants; Phoenix-style simplifications (trampoline send, pay-to-open / splice fill-up); E2E-encrypted cloud sync. Components: `thunderd` (daemon), `thunderd-cli` (server admin), `thunder` (client CLI). API at `/.well-known/thunder/v1`. | Self-custodial | Rust (LDK + VLS) | `thunderd/design.md` |

## How they relate

```
                 ┌─────────────────────────────────────────┐
   Clients       │  hold keys, sign remotely:               │
   (devices) ───►│   • `thunder` CLI — remote signer (C)    │
                 │   • PWA / Tauri — custodial UI (A) +      │
                 │     self-custodial UI + signer (C)        │
                 └──────┬───────────────────────┬───────────┘
            HTTPS /.well-known/lightning/…(A)    │ HTTPS /.well-known/thunder/v1 (C)
                        ▼                        ▼
 ┌──────────────────────────────┐      ┌───────────────────────┐
 │ Track A: accounts plugin      │      │ Track C: thunderd     │
 │ (custodial; in lightningd)    │      │ multi-tenant LDK host │
 │                               │      │ remote signer on device│
 └──────────────┬───────────────┘      └───────────┬───────────┘
                │ (in-process)            Unix RPC  │ socket (same machine)
                ▼                                    ▼
 ┌─────────────────────────────────────────────────────────────┐
 │ companion lightningd  (server B: the operator's node)         │
 │  • Track A plugin host   • LSP / trampoline / chain gateway   │
 │  • channel counterparty for every thunderd tenant            │
 └─────────────────────────────────────────────────────────────┘
                         ▲  channels (real BOLT2/3, user-keyed, device-signed)
                         └── thunderd tenants
```

- **One `lightningd` is the hub.** The operator's Core Lightning node
  (server B) hosts the `accounts` plugin (Track A) *and* is `thunderd`'s
  **companion over the Unix RPC socket** (Track C) — acting as LSP /
  trampoline / chain gateway / channel counterparty for every tenant.
- **The device is the trust anchor for Track C.** Heavy lifting (the
  node) runs on our infra; signing happens on the user's device(s). See
  `thunderd/design.md` for why this stays non-custodial (validating
  signer) and the liveness model (multi-device signer pool + push-wake).
- **Shared clients.** The `thunder` CLI is Track C's first client; the
  PWA/Tauri (Track B) render both custodial accounts (A) and the
  self-custodial wallet (C) and reuse the same `signer-core`.

## Milestone summary

| Track | Milestones | Features |
|---|---|---|
| A — accounts plugin | M0–M7 | FEAT-300 … 329 |
| B — PWA carve-out | PW0–PW3 | FEAT-340 … 349 |
| C — thunderd | TH0–TH8 | FEAT-400 … 431 |

Feature numbers are **proposed placeholders** — continue the repo's
`FEAT-###` sequence when the issues are filed.

## Sequencing across tracks

1. **Track A first** (custodial MVP + the carve-out discipline). It also
   establishes the CORS the PWA will need.
2. **Track B next / in parallel** — separate the PWA and land the
   device-signing *primitives* (seed on device, `@noble/curves`,
   WebAuthn-PRF-wrapped storage). This is the **bridge** to Track C.
3. **Track C (`thunderd`) after** — reuses Track B's client signer and
   Track A's fee engine; the new build is the multi-tenant Rust node host
   + the validating remote signer. Lives in this repo for now; extracted
   later (FEAT-431).

## Cross-cutting decisions already taken

- Track A: **fat** plugin (direct lightningd RPC, owns its state), Rust.
- Track C custody bar: **A2 — true remote signing** (seed never reaches
  our servers in plaintext). Engine: **LDK** (pluggable signer), signer:
  **VLS-based validation**. *Not* Greenlight, *not* Ark, *not* a reused
  phoenixd — a fresh, **single multi-tenant** Rust process.
- Track C shape: **`thunderd`** daemon runs **parallel to a `lightningd`
  companion** (Unix socket) and serves **`/.well-known/thunder/v1`**;
  **`thunderd-cli`** is the server admin tool and **`thunder`** the client
  CLI. Offers **non-custodial accounts** (user-keyed, device-signed
  channels to the companion).
- Clients: **`thunder` CLI first**, then PWA + **Tauri** (desktop autostart/tray persistent signer;
  Android via TWA; iOS as a signer-capable native host, not a bare
  web wrapper).
</content>
