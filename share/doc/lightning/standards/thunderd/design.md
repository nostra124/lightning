# Track C — `thunderd`: a remote-signer Lightning companion daemon

**Working title:** `thunderd` (was `pwalight`)
**Status:** Planning / design. No code yet.
**Lives:** in this repo for now; extracted to its own repo later
(FEAT-431). Design everything one-way so extraction is mechanical.

> See `../roadmap-overview.md` for how this relates to Track A (the
> `accounts` plugin) and Track B (the PWA carve-out).

## 1. What it is

`thunderd` is a **small Lightning daemon, companion to `lightningd`, that
offers both custodial and non-custodial accounts for Lightning** — one
engine, two tiers (§1.3). For the **non-custodial** tier it is an API for
**remote signers to manage their own channels**: the seed lives on the
user's device and signs remotely (**A2**); our servers never hold a
usable key. The **custodial** tier is the former *accounts plugin* — the
commerce/neobank surface — now folded in as a module of the same daemon.

**Why "thunder".** One **lightning**, many **thunders**: a node runs a
single `lightningd`, and many `thunderd` accounts and clients hang off
it. The name encodes both the **one-to-many** fan-out *and* the
**dependency** — thunder follows lightning; `thunderd` only works with a
`lightningd` companion.

It is a **companion to `lightningd`** — it does not replace a full node,
it runs **parallel to a `lightningd` on the same machine and interacts
with it through the Unix (RPC) socket**, for *both* tiers (so there is
**no in-process CLN plugin**). `lightningd` is the shared backend: it
holds the node funds for the custodial tier, and is the channel
**counterparty / LSP / trampoline** + chain/network gateway for the
non-custodial tier. `thunderd` adds the account model, per-user keying,
the remote-signing protocol, multi-tenancy, and the public JSON API.

It is *not* a reused phoenixd, *not* Greenlight, *not* Ark.

### 1.1 Components & names (mirror `lightningd`/`lightning-cli`)

| Name | Side | Role |
|---|---|---|
| **`thunderd`** | server | The daemon. Companion to `lightningd` (Unix socket). Serves custodial + non-custodial accounts via the JSON API. |
| **`thunderd-cli`** | server | Operator admin CLI for `thunderd` (tenants, accounts, channels, liquidity, health). |
| **`thunder`** | client | The user's command-line **remote-signer client**: holds the seed, signs, manages their own channels/accounts over the JSON API. |
| **`thunder-pay`** | client | The **PWA web frontend** for `thunderd` (Apache-hosted; later its own app). Renders both account tiers; reuses `signer-core` (WASM) for the non-custodial signer. |

### 1.2 API namespace

`thunderd` serves **`/.well-known/thunder/v1`** for **both** tiers
(custodial and non-custodial) — this is the canonical home for the
custodial API too. The legacy custodial paths
(`/.well-known/lightning/accounts/v1` and the original CGI
`/.well-known/lightning/v1/accounts`) survive only as **deprecated
transitional aliases**, removed after cutover. `thunder` and
`thunder-pay` speak the `thunder` namespace; a reverse proxy (Apache)
does TLS + forwards it. The endpoint contract (routes, auth, error
model, the remote-signer sub-protocol) is specified in `api-v1.md`.

### 1.3 Two account tiers, one daemon

`thunderd` absorbs the former *accounts plugin* (custodial) and the
former *pwalight* (non-custodial), so both are one engine sharing the
account model, fee engine, API and clients:

- **Custodial** — node holds the keys; an account is a ledger row.
  `thunderd` drives the companion `lightningd` over the Unix RPC socket
  (+ `waitanyinvoice` for settlement) — exactly the "fat plugin" design,
  but as a module of this daemon rather than an in-process CLN plugin.
  This is the commerce/neobank surface (invoices, mandates, charges,
  standing orders, tax export). Feature detail: `../accounts-plugin/roadmap.md`
  (now **Phase I** of `thunderd`).
- **Non-custodial** — seed on the device, signs remotely (A2);
  per-tenant LDK nodes; this document (**Phase II**, §3 onward).

### 1.4 Design principle: fat daemon, thin clients

`thunderd` does **all** the heavy work — for **Lightning *and*
on-chain**. The two clients (`thunder` CLI, `thunder-pay` PWA) stay as
small as possible: they **hold keys and sign, render UI, and sync** —
nothing more. Everything else lives in the daemon:

- **On-chain (Bitcoin) wallet** is first-class, not just Lightning.
  `thunderd` derives/watches addresses, tracks UTXOs, does coin
  selection, builds PSBTs, estimates fees, broadcasts, and monitors
  confirmations — using the companion `lightningd` (its `bitcoind`) as
  the chain backend over the Unix socket.
- **Custody follows the tier.** Non-custodial: `thunderd` holds only the
  tenant's **xpub (watch-only)** for on-chain and the channel pubkeys for
  Lightning; it builds the PSBT / commitment and the **device signs**
  (same A2 guarantee — a watch-only xpub can't spend). Custodial:
  on-chain rides the companion `lightningd`'s own wallet.
- **Clients never touch the chain or build transactions.** A client
  receives a ready-to-sign PSBT / sighash from `thunderd`, validates it
  (the signer is a *validating* signer, §6), signs, returns it. This
  keeps `thunder` and `thunder-pay` tiny and lets a new client (mobile,
  hardware, a third party) be little more than a validating signer + UI.

## 2. Topology

```
 user device(s): `thunder` CLI (+ later PWA/Tauri) — hold seed, sign remotely
        │  /.well-known/thunder/v1   (persistent conn + push-to-sign)
        ▼
 ┌──────────────────────────────────────────────┐
 │  thunderd  (ONE Rust process, many tenants)   │
 │   • multi-tenant node engine (LDK)            │
 │   • remote-signer protocol (RPC to device)    │
 │   • JSON API  /.well-known/thunder/v1         │
 │   • E2E-encrypted cloud-sync store (ciphertext)│
 │   • admin via thunderd-cli                     │
 └───────────────┬──────────────────────────────┘
                 │  Unix (RPC) socket — same machine
                 ▼
 ┌──────────────────────────────────────────────┐
 │  companion lightningd                          │
 │   • channel counterparty for every tenant     │
 │   • LSP: pay-to-open / splice fill-up          │
 │   • trampoline (send without routing)          │
 │   • chain + Lightning-network gateway          │
 └──────────────────────────────────────────────┘
```

Every tenant's channel is to the **companion `lightningd`**; the user's
side of that channel is keyed by the user and **signed on their device**,
so the channel is the user's own — real BOLT-2/3, trustless unilateral
exit. We control `lightningd`, so peer trust is a non-issue; the channel
being real is what makes it non-custodial.

## 3. The companion-`lightningd` relationship (key design call)

CLN is **single-seed** (one `lightningd` = one node identity), so
`thunderd` cannot host many users' distinct keys *inside* `lightningd`.
Hence `thunderd` runs its **own per-tenant lightweight nodes (LDK)**,
each keyed by its user, and uses the companion `lightningd` as the
**shared backend** over the Unix socket:

- **Counterparty / LSP:** every tenant opens its channel(s) to the
  companion `lightningd`; `thunderd` drives accept/fund/splice/pay-to-open
  via RPC.
- **Network + chain gateway:** tenants ride the one `lightningd` for
  reaching the wider network (trampoline send) and chain access, instead
  of each running its own peer/chain stack.

**Open spike (FEAT-407):** the precise `thunderd`↔`lightningd` plumbing —
how LDK per-tenant nodes peer with the co-located `lightningd` and how
much rides RPC vs. a local transport. (Alternative read — `thunderd`
drives channels *on* `lightningd` directly — is blocked by the
single-seed constraint for true per-user non-custody, so it's out unless
we add a remote-signer/multi-seed layer to CLN itself.)

## 4. Phoenix-style simplifications

- **Send without routing = trampoline** via the companion `lightningd`.
- **Receive + channel fill-up = pay-to-open / JIT channels / splicing**
  via the LSP spec (LSPS); `thunderd` requests them on `lightningd`.
- **One or two channels per tenant, all to the companion.** No gossip,
  no routing table on the tenant side.

## 5. Efficiency: one process, many tenants

The point of a fresh daemon (not one node per user):

- **One Rust process / one tokio runtime** hosts all tenants.
- **One companion `lightningd`** is the shared LSP + chain + network
  gateway for everyone — tenants don't each run a node.
- **Shared chain feed + persistence** across tenants (LDK `Filter`
  fan-out; one `KVStore` partitioned by tenant).
- **Idle tenants hibernate** (state on disk; wake on a nudge from
  `lightningd` about inbound activity, or a user action).

Target: thousands of tenants per box, each owning a real channel.

## 6. The remote validating signer (A2 — the security core)

In A2 the entire guarantee is "the device refuses to sign a bad state":

- **Never blind-sign.** Build the device signer on **VLS (Validating
  Lightning Signer)** — Rust, validates LDK signing requests against
  tracked channel state so a compromised host can't extract funds.
  (Spike: VLS as a per-user device signer for a hosted node is a slightly
  novel topology — confirm the integration surface early.)
- **`signer-core` crate** — validating signer + key derivation, compiled
  **native** (the `thunder` CLI; later Tauri) and to **WASM** (browser).
- **Remote `ChannelSigner`** on the engine RPCs each request to the
  device and blocks on the reply.

### 6.1 Stateful signer + multi-device → signer-state sync

A validating signer is **stateful** (must never sign two commitments at
the same index, etc.). A user has multiple devices (§7), so there must be
**one logical signer state**. Keep it as an **encrypted,
monotonically-versioned blob synced through `thunderd`** — it stores only
ciphertext + a version counter it **enforces** (no rollback/replay); the
signing device loads, verifies, bumps, re-uploads. `thunderd` never sees
plaintext.

## 7. Liveness: the online problem

A2 means **device offline ⇒ the channel can't advance.** Mitigation is a
per-tenant **signer pool**: the seed is on every device, so signing is
tied to *"any* of the user's devices is online."

- Each device registers presence; `thunderd` routes a sign request to a
  live device (desktop preferred), else **push-wakes** a phone, else asks
  the companion `lightningd` to **hold** the inbound HTLC within its CLTV
  budget (~hours–a day) before it fails back.
- A `thunder` CLI on an always-on box (or a Tauri desktop later) makes
  the pool near-100% available; mobile background is push-to-sign only.

## 8. Cloud sync (E2E-encrypted)

All of a user's clients sync through `thunderd`, **always ciphertext** on
our servers:

- Encrypted client-side with a key derived from the user password via
  **Argon2id**; we store only ciphertext + version.
- Datasets: encrypted **seed backup** (don't-lose-it + multi-device),
  the **signer-state blob** (§6.1), and **metadata** (labels, contacts,
  device registry).
- Multi-device = enter password on device 2 → pull ciphertext → decrypt
  locally. **Password loss = fund loss** (be loud); later optional
  social/Shamir/passkey-PRF second factor.

## 9. Fees

Channel opens, splice-ins (fill-up) and first-receive pay-to-open cost
on-chain + liquidity. Charge a **liquidity fee schedule** (mining-fee
passthrough + service fee). Reuse Track A's operator-fee engine
(FEAT-213) so custodial and non-custodial tiers bill through one
mechanism.

## 10. Recovery & resilience

- **SCB (static channel backup) on the device**, synced (§8).
- `thunderd` data loss → recover from **seed + SCB** → force-close →
  funds on-chain.
- **Watchtower:** decide own vs. third-party vs. device-side. Design the
  exit so the user is safe even against host/`thunderd` compromise.

## 11. Compliance posture (not legal advice)

Non-custody is the standard argument for staying out of
money-transmitter / MiCA-CASP / travel-rule territory, but the test is
**control**, not "we encrypted it." A2 (no usable key) + a validating
signer + a user-exit path is what backs the claim. We run `thunderd`, the
companion `lightningd` is the counterparty/LSP, and we store (encrypted)
seeds — a lot of surface — so **get a regulatory read**; the A2 choices
materially strengthen the position.

## 12. Milestones & features

These milestones are `thunderd` **Phase II (non-custodial)**, shipping as
repo semver releases **`1.13.0` → `1.20.0`** — after Phase I (custodial,
`1.4.0`–`1.9.0`) and `thunder-pay` (`1.10.0`–`1.12.0`). The final
**separation of `thunder` into its own repo, together with stripping
`lightning` down, is the `2.0.0` target** (below). Phase I is tracked in
`../accounts-plugin/roadmap.md` (FEAT-300…328). Feature numbers are
proposed placeholders.

### 1.13.0 — Foundations & carve-out
- **FEAT-400 — Workspace.** `thunderd/` Rust workspace in-tree (crates:
  `signer-core`, `node-engine`, `sync`, `protocol`, `thunderd-cli`,
  `thunder`); carve-out CI guard (no coupling to `lightning`).
- **FEAT-401 — Daemon skeleton.** Single-process tokio service; config;
  health; **`thunderd-cli`** admin transport; structured logging.
- **FEAT-402 — Tenant model + storage.** Tenant identity; storage schema
  for node state (partitioned) + E2E-encrypted blobs.

### 1.14.0 — Companion engine (§3, §5)
- **FEAT-403 — LDK host.** Many tenants, one runtime.
- **FEAT-404 — Shared chain backend** (one feed + `Filter` fan-out).
- **FEAT-405 — Shared persistence** (`KVStore`/`Persist`, per-tenant).
- **FEAT-406 — Tenant lifecycle** (create / hibernate / wake).
- **FEAT-407 — Companion-`lightningd` integration.** Drive counterparty /
  LSP / chain-gateway ops over the Unix RPC socket; per-tenant peering.

### 1.15.0 — Remote validating signer (A2 core, §6)
- **FEAT-408 — `signer-core`** (VLS-based; native + WASM).
- **FEAT-409 — Remote `ChannelSigner`** (engine → device RPC).
- **FEAT-410 — Sign transport + device presence.**
- **FEAT-411 — Signer-state sync** (encrypted monotonic blob).

### 1.16.0 — LSP / liquidity on the companion (§4)
- **FEAT-412 — Trampoline serving** (send without routing).
- **FEAT-413 — LSPS / `lightning-liquidity`** (pay-to-open / JIT).
- **FEAT-414 — Splice-based fill-up.**
- **FEAT-415 — Liquidity fee schedule + billing** (reuse FEAT-213).

### 1.17.0 — Wallet operations & the JSON API
- **FEAT-416 — Send** (trampoline; BOLT-11/12).
- **FEAT-417 — Receive** (BOLT-11/12 + pay-to-open).
- **FEAT-418 — Channel open / fill-up flows.**
- **FEAT-419 — On-chain wallet (daemon-side, device-signed).** First-class
  Bitcoin wallet in `thunderd`: watch-only **xpub/descriptor** import,
  address derivation + gap-limit watching, UTXO tracking, coin selection,
  **PSBT construction**, fee estimation, broadcast, and confirmation
  monitoring — all via the companion `lightningd`'s `bitcoind`. On-chain
  **send** (build PSBT → device signs → broadcast) and **receive**
  (derive + watch). Custodial on-chain rides `lightningd`'s own wallet.
- **FEAT-432 — On-chain fee management & recovery.** RBF / CPFP fee-bump,
  sweep / consolidate, dust handling, and **descriptor/xpub backup**
  (synced E2E-encrypted, §8) so the wallet is recoverable from seed +
  descriptor. Channel↔chain interplay (funding, force-close sweep) ties
  into FEAT-430.
- **FEAT-420 — Account model + `/.well-known/thunder/v1`.** Channel(s)
  *and on-chain balance* ↔ non-custodial account(s); unified balance +
  history (Lightning + on-chain); the public JSON API surface + discovery
  doc. (Decision: account = channel vs. logical sub-balance over one user
  node.)

### 1.18.0 — Multi-device & cloud sync (§7, §8)
- **FEAT-421 — Device registry + signer-pool routing.**
- **FEAT-422 — E2E-encrypted cloud-sync service** (Argon2id, monotonic).
- **FEAT-423 — Synced datasets** (seed backup, signer-state, metadata).
- **FEAT-424 — Push-to-sign wake.**

### 1.19.0 — Clients
- **FEAT-425 — `thunder` CLI client.** The first client: remote-signer
  over `/.well-known/thunder/v1` (key gen/storage, sign loop, account +
  channel management). **Build this before the GUI clients.**
- **FEAT-426 — Tauri desktop** (always-on persistent signer; reuses
  `signer-core`).
- **FEAT-427 — PWA / native mobile** (Android TWA; iOS signer-capable
  host) — reuses the WASM `signer-core` and Track B's UI.

### 1.20.0 — Recovery & resilience (§10)
- **FEAT-428 — SCB on device + seed+SCB recovery.**
- **FEAT-429 — Watchtower strategy.**
- **FEAT-430 — Force-close / unilateral exit + key-loss UX.**

### 2.0.0 — Separation & strip-down (the target)
- **FEAT-431 — Separate `thunder` into its own repo** (`git filter-repo`
  `thunderd/` + `thunder-pay`), with independent versioning + CI, **and
  strip `lightning` down** to simple administration (the custodial
  cutover, FEAT-326–328). This breaking change is the `2.0.0` graduation:
  `lightning` no longer carries the commerce/accounts surface, and
  `thunder` lives on its own.

## 13. Open spikes & decisions
1. **Companion-`lightningd` plumbing** (FEAT-407) — exact LDK↔`lightningd`
   integration over the Unix socket; counterparty + chain/network gateway.
2. **VLS-in-a-pool** — VLS as a per-user device signer for a hosted node,
   with the shared signer-state model (§6.1).
3. **Signer-state sync blob** — format, monotonicity, cross-device
   conflicts.
4. **Account semantics** (FEAT-420) — account = channel vs. logical
   sub-balance over one user node.
5. **Watchtower** (FEAT-429) — own vs. third-party vs. device-side.
6. **`thunder` plugin shape** — standalone CLI vs. an rpk/libexec-style
   plugin vs. a CLN plugin on the client box.
7. **On-chain chain source** (FEAT-419) — drive UTXO/descriptor watching
   through the companion `lightningd`'s `bitcoind` over the Unix socket,
   vs. a dedicated Esplora/Electrum backend for scale.
