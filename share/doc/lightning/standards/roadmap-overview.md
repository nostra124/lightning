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
| **C** | **`pwalight`** | A multi-tenant, **self-custodial** ("cooperative custodial") Lightning service: one efficient Rust process runs many users' lightweight nodes, but **the seed lives on the user's device and signs remotely (A2)**. Phoenix-style simplifications (trampoline send, pay-to-open / splice fill-up), all channels to our own node, plus E2E-encrypted cloud sync. | Self-custodial | Rust (LDK + VLS) | `pwalight/design.md` |

## How they relate

```
                 ┌─────────────────────────────────────────┐
   Device(s)     │  Track B: PWA / Tauri (UI + signer)      │
   hold keys ───►│   • custodial accounts UI (Track A)      │
                 │   • self-custodial UI + remote signer (C)│
                 └───────────────┬─────────────────────────┘
                                 │ HTTPS (config-driven base + CORS)
        ┌────────────────────────┼───────────────────────────┐
        ▼                                                     ▼
 ┌──────────────┐                                   ┌───────────────────────┐
 │ Track A:     │   channels (real BOLT2/3)         │ Track C: pwalight     │
 │ accounts     │◄──────────────────────────────────│ multi-tenant LDK host │
 │ plugin on B  │   B = LSP / trampoline / counter- │ (one process, many    │
 │ (custodial)  │   party for every tenant          │ tenants, remote signer│
 │              │                                    │ on device)            │
 └──────┬───────┘                                   └───────────────────────┘
        ▼
   lightningd  (server B: the operator's node)
```

- **B is the hub.** The operator's Core Lightning node (server B) carries
  the `accounts` plugin (Track A) *and* acts as LSP / trampoline /
  channel counterparty for every `pwalight` tenant (Track C).
- **The device is the trust anchor for Track C.** Heavy lifting (the
  node) runs on our infra; signing happens on the user's device(s). See
  `pwalight/design.md` for why this stays self-custodial (validating
  signer) and the liveness model (multi-device signer pool + push-wake).
- **Track B is the shared client.** One PWA renders both custodial
  accounts (A) and self-custodial wallets (C); the Tauri build adds the
  always-on native signer Track C needs.

## Milestone summary

| Track | Milestones | Features |
|---|---|---|
| A — accounts plugin | M0–M7 | FEAT-300 … 329 |
| B — PWA carve-out | PW0–PW3 | FEAT-340 … 349 |
| C — pwalight | PL0–PL8 | FEAT-400 … 431 |

Feature numbers are **proposed placeholders** — continue the repo's
`FEAT-###` sequence when the issues are filed.

## Sequencing across tracks

1. **Track A first** (custodial MVP + the carve-out discipline). It also
   establishes the CORS the PWA will need.
2. **Track B next / in parallel** — separate the PWA and land the
   device-signing *primitives* (seed on device, `@noble/curves`,
   WebAuthn-PRF-wrapped storage). This is the **bridge** to Track C.
3. **Track C (`pwalight`) after** — reuses Track B's client signer and
   Track A's fee engine; the new build is the multi-tenant Rust node host
   + the validating remote signer. Lives in this repo for now; extracted
   later (FEAT-431).

## Cross-cutting decisions already taken

- Track A: **fat** plugin (direct lightningd RPC, owns its state), Rust.
- Track C custody bar: **A2 — true remote signing** (seed never reaches
  our servers in plaintext). Engine: **LDK** (pluggable signer), signer:
  **VLS-based validation**. *Not* Greenlight, *not* Ark, *not* a reused
  phoenixd — a fresh, **single multi-tenant** Rust process.
- Clients: PWA + **Tauri** (desktop autostart/tray persistent signer;
  Android via TWA; iOS as a signer-capable native host, not a bare
  web wrapper).
</content>
