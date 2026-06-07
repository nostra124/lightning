# Track C — `pwalight`: multi-tenant self-custodial Lightning

**Working title:** `pwalight`
**Status:** Planning / design. No code yet.
**Lives:** in this repo for now; extracted to its own repo later
(FEAT-431). Design everything one-way so extraction is mechanical.

> See `../roadmap-overview.md` for how this relates to Track A (the
> `accounts` plugin) and Track B (the PWA carve-out).

## 1. Goal

Offer **as banking-like a product as possible without entering the
custodial-compliance trap**, by being genuinely **self-custodial**: the
heavy lifting (running Lightning nodes, watching the chain, liquidity)
happens on our infrastructure, but **the seed lives on the user's
device and signs remotely** — our servers never hold a usable key.

It is *not* a reused phoenixd, *not* Greenlight, *not* Ark. It is a
fresh Rust implementation of phoenixd-style behaviour with two
non-negotiables:

1. **A2 — true remote signing.** The seed never reaches our servers in
   plaintext. Every signature is produced on the device by a
   **validating** signer.
2. **One efficient multi-tenant process.** One service hosts *many*
   users' nodes — not one daemon per user.

## 2. Topology

```
 user devices (PWA / Tauri) — hold the seed, sign remotely, sync E2E-encrypted
        │  persistent connection + push-to-sign
        ▼
 ┌──────────────────────────────────────────────┐
 │  pwalight server  (server A, ONE Rust process)│
 │   • multi-tenant LDK host (many tenants)      │
 │   • shared chain backend + persistence        │
 │   • remote-signer client (RPCs to device)     │
 │   • E2E-encrypted cloud-sync store (ciphertext)│
 └───────────────┬──────────────────────────────┘
                 │  real BOLT-2/3 channels over a multiplexed internal link
                 ▼
 ┌──────────────────────────────────────────────┐
 │  server B: our Core Lightning node            │
 │   • LSP: pay-to-open / splice fill-up (LSPS)  │
 │   • trampoline node (send without routing)    │
 │   • channel counterparty for every tenant     │
 │   • Track A `accounts` plugin (custodial side)│
 └──────────────────────────────────────────────┘
```

Every tenant's **only peer is B**. We control both A and B, so peer
trust between them is a non-issue — but the channels are still **real
BOLT-2/3** so the user keeps a trustless, on-chain-enforceable
**unilateral exit**.

## 3. Phoenix-style simplifications

- **Send without routing = trampoline.** B is the trampoline node; the
  tenant just says "pay this, max fee X" and B does pathfinding. (LDK
  trampoline support, maturing.)
- **Receive + channel fill-up = pay-to-open / JIT channels / splicing**
  via the **LSP spec (LSPS)** — LDK's `lightning-liquidity` crate on the
  client, the matching server role on B.
- **One or two channels, all to B.** No gossip, no routing table.

## 4. Efficiency: one process, many tenants

The whole point of not reusing phoenixd (one JVM/user). Because every
tenant peers only with B, almost everything is shared:

- **One tokio runtime.**
- **One chain backend** (bitcoind/esplora) feeding *all* tenants via
  LDK's `Filter` — one block download fans out to every tenant's
  `ChannelMonitor`. Not N chain syncs.
- **One persistence backend** (KV/SQL) implementing LDK's
  `KVStore`/`Persist`, partitioned by tenant.
- **Per tenant:** a `ChannelManager` + monitors + a **remote
  `ChannelSigner`**. Idle tenants **hibernate** (state on disk, zero
  RAM/CPU) and **wake on activity** — a nudge from B (incoming HTLC) or a
  user action. Idle users cost ~storage only.
- **Transport:** since we own A and B, all tenant↔B channel messages run
  over **one multiplexed internal link** instead of N BOLT-8/TCP sockets.
  Commitments stay real (exit stays trustless); we just drop the
  per-node networking overhead.

Target: thousands of tenants per box, each still owning a real channel.

## 5. The remote validating signer (A2 — the security core)

In A2 the *entire* guarantee is "the device refuses to sign a bad
state." So:

- **Never blind-sign.** Build the device signer on **VLS (Validating
  Lightning Signer)** — Rust, purpose-built to validate LDK/CLN signing
  requests against tracked channel state so a compromised host cannot
  extract funds. (Spike: VLS's usual deployment is one signer per node;
  using it as a per-user device signer for a *hosted* LDK node is a
  slightly novel topology — confirm the integration surface early.)
- **`signer-core` crate** — the validating signer + key derivation,
  compiled **native** (Tauri) and to **WASM** (browser fallback). One
  codebase, two targets.
- **Remote `ChannelSigner`** on the engine RPCs each request to the
  device and blocks on the reply.

### 5.1 Stateful signer + multi-device = signer-state sync

A validating signer is **stateful** (must refuse to sign two different
commitments at the same index, track revocations, …). A user has
multiple devices (see §6), so there must be **one logical signer
state**, or the host could play two devices against each other.

Fix that preserves non-custody: keep the signer's security state as an
**encrypted, monotonically-versioned blob synced through A** — A stores
only ciphertext + a version counter it **enforces** (so it cannot roll
the signer back to replay); the signing device loads it, verifies, bumps,
re-uploads. All devices stay consistent; A never sees plaintext. This is
the most-missed subtlety of multi-device remote signers — design it in
from PL2.

## 6. Liveness: the online problem

A2 means **device offline ⇒ the channel cannot advance.** The mitigation
is a **per-tenant signer pool**: the seed lives on *every* device, so
signing is tied to *"any* of the user's devices is online," not one.

- Each device registers presence (persistent WS / push token). A routes a
  sign request to whichever device is live, **preferring desktop**, then
  **push-wakes** a phone, then asks **B to hold** the inbound HTLC.
- **Desktop browser (open)** and **mobile foreground** are fine. **Mobile
  background** is the only gap — covered by an always-on desktop in the
  pool, or by push-to-sign, or by B holding the HTLC.
- **B's hold has a hard clock:** an inbound HTLC can only be held within
  its CLTV budget (~hours up to ~a day), then it fails back. So "user
  online sometime today" works; "offline for a week" does not — that is
  the accepted price of the strict A2 bar.
- **Tauri-desktop is the first-class always-on client** (autostart, tray,
  persistent connection); the browser PWA is the light/foreground client.

## 7. Cloud sync (E2E-encrypted)

All of a user's clients sync through pwalight, **always ciphertext on our
servers** — we cannot read it:

- Encrypted **client-side** with a key derived from the user password via
  a memory-hard KDF (**Argon2id**). We store only ciphertext + version.
- **Datasets:** encrypted **seed backup** (so users can't lose it and can
  use the same seed on multiple devices), the **signer-state blob**
  (§5.1), and **metadata** (labels, contacts, notes, device registry).
- **Multi-device:** enter the password on device 2 → pull ciphertext →
  decrypt locally → same seed + state everywhere.
- **Password loss = fund loss** (be loud). Later: optional social
  recovery / Shamir / passkey-PRF second factor so it isn't password-only.

## 8. Fees

Channel opens, splice-ins (fill-up) and first-receive pay-to-open cost
on-chain + liquidity. Charge them as a **liquidity fee schedule**
(mining-fee passthrough + a liquidity service fee), plus optionally a
spread or hosting fee. **Reuse Track A's operator-fee engine** (FEAT-213
skim concept) so both the custodial and self-custodial tiers bill through
one mechanism.

## 9. Recovery & resilience

- **SCB (static channel backup) on the device**, synced (§7).
- If A loses node state: recover from **seed + SCB** → force-close →
  funds on-chain.
- **Watchtower:** someone must catch a revoked-state broadcast and
  publish the penalty. Decide between our own watchtower, a third-party
  one, and/or device-side watching. (Because we own B, the relevant
  threat is mostly host/A compromise, not B cheating — but design the
  exit so the user is safe even then.)

## 10. Compliance posture (not legal advice)

Non-custody is the standard argument for staying out of
money-transmitter / MiCA-CASP / travel-rule territory, but the test is
**control**, not "we encrypted it." A2 (we hold no usable key) plus a
validating signer plus a user-exit path is what backs the claim. We run
nodes, are the LSP, and store (encrypted) seeds — a lot of control
surface — so **get a regulatory read before betting on it**; the A2
design choices materially strengthen the position.

## 11. Milestones & features

Feature numbers are proposed placeholders.

### PL0 — Foundations & carve-out
- **FEAT-400 — Workspace.** `pwalight/` Rust workspace in-tree (crates:
  `signer-core`, `node-host`, `sync`, `protocol`); carve-out CI guard
  (no coupling to `lightning`).
- **FEAT-401 — Service skeleton.** Single-process tokio service; config;
  health + admin RPC; structured logging.
- **FEAT-402 — Tenant model + storage.** Tenant identity; storage schema
  for node state (partitioned) + E2E-encrypted blobs.

### PL1 — Multi-tenant engine (§4)
- **FEAT-403 — LDK host.** Many tenants, one runtime.
- **FEAT-404 — Shared chain backend.** One block source + `Filter`
  fan-out to all monitors.
- **FEAT-405 — Shared persistence.** `KVStore`/`Persist`, per-tenant.
- **FEAT-406 — Tenant lifecycle.** Create / hibernate / wake-on-activity.
- **FEAT-407 — B-only multiplexed transport.** Real BOLT-2/3 over one
  internal link.

### PL2 — Remote validating signer (§5)
- **FEAT-408 — `signer-core`.** VLS-based validating signer; native +
  WASM targets; key derivation (BIP-39/32).
- **FEAT-409 — Remote `ChannelSigner`.** Engine-side RPC to device.
- **FEAT-410 — Sign transport + presence.** Device connection, request
  routing, timeouts.
- **FEAT-411 — Signer-state sync.** Encrypted monotonic blob;
  rollback-resistant version enforcement.

### PL3 — LSP / liquidity on B (§3)
- **FEAT-412 — Trampoline serving** (send without routing).
- **FEAT-413 — LSPS / `lightning-liquidity`** (pay-to-open / JIT).
- **FEAT-414 — Splice-based fill-up.**
- **FEAT-415 — Liquidity fee schedule + billing** (reuse FEAT-213).

### PL4 — Wallet operations
- **FEAT-416 — Send** (trampoline; BOLT-11/BOLT-12).
- **FEAT-417 — Receive** (BOLT-11/BOLT-12 + pay-to-open).
- **FEAT-418 — Channel open / fill-up flows.**
- **FEAT-419 — On-chain wallet** (PSBT constructed on A, signed on device).
- **FEAT-420 — Account model.** Channel(s) ↔ self-custodial account(s);
  balance + history. (Decision: account = channel vs. logical sub-balance
  over one user node — see §12.)

### PL5 — Multi-device & cloud sync (§6, §7)
- **FEAT-421 — Device registry + signer-pool routing** (presence-aware).
- **FEAT-422 — E2E-encrypted cloud-sync service** (ciphertext-only,
  Argon2id, monotonic versioning).
- **FEAT-423 — Synced datasets** (seed backup, signer-state, metadata).
- **FEAT-424 — Push-to-sign wake** (mobile background).

### PL6 — Clients
- **FEAT-425 — PWA self-custodial UI** (extends Track B; reuses rung-2
  signing primitives).
- **FEAT-426 — Tauri desktop** (autostart, tray, persistent signer,
  OS-keychain storage).
- **FEAT-427 — Native mobile** (Android TWA; iOS signer-capable host with
  native keystore + push — not a bare web wrapper, per App Store §12).

### PL7 — Recovery & resilience (§9)
- **FEAT-428 — SCB on device + seed+SCB recovery flow.**
- **FEAT-429 — Watchtower strategy** / justice-tx defence.
- **FEAT-430 — Force-close / unilateral exit + key-loss UX.**

### PL8 — Extraction
- **FEAT-431 — `git filter-repo` `pwalight/` → its own repo;** independent
  versioning + CI.

## 12. Open spikes & decisions
1. **VLS-in-a-pool** — confirm VLS works as a per-user device signer for a
   hosted LDK node, with the shared signer-state model (§5.1).
2. **A↔B multiplexed transport** — design the internal link that carries
   real BOLT-2/3 for many tenants without per-node TCP.
3. **Signer-state sync blob** — exact format, monotonicity enforcement,
   conflict handling across devices.
4. **Account semantics** (FEAT-420) — account = channel (simple, on-chain
   cost per account) vs. logical sub-balance over one user-owned node
   (cheaper, more code).
5. **iOS distribution** — verify current App Store guidelines for a
   signer-capable host loading a remote web UI (4.2 minimum
   functionality; 2.5.2 no native-code download; crypto-wallet rules).
6. **Watchtower** (FEAT-429) — own vs. third-party vs. device-side.

## 13. App Store note (PL6 / FEAT-427)
- **Android:** a **TWA** (Trusted Web Activity) is Google's blessed way to
  ship a PWA as an app — "download the PWA and show it" is fine.
- **iOS:** a *pure* web wrapper risks rejection (Guideline 4.2 minimum
  functionality), and crypto wallets get extra scrutiny. Make it a
  **signer-capable native host** — Secure-Enclave/biometric key storage,
  push-to-sign, background connection — that renders the web UI. Loading
  remote *web* content is acceptable; downloading native *code* (2.5.2)
  is not. The PWA can also be installed directly from Safari with no App
  Store for casual users. (Guidelines drift + review is discretionary —
  recheck before submission.)
</content>
