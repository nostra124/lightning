---
id: FEAT-209
type: feature
priority: low
status: research
---

# BaweePay — self-hosted Lightning wallet companion

## Description

**As a** Lightning user who runs their own node (or rents one from
bawee.site)
**I want** an iOS / Android / desktop wallet that talks directly to
my node — not a custodial wallet, not an LSP-fronted wallet
**So that** every receive and pay flows through my infrastructure,
on my hardware, with signing under my control.

Filed for future discussion / integration with the sister-project
ecosystem.  No milestone — implementation is gated on the bawee +
Wyrd platform shape being finalised.

## Sister-project context

**Wyrd** (see FEAT-208) is a peer-to-peer Platform-as-a-Service
under independent development by the same author.  **bawee.site**
builds upon Wyrd and provides operator-facing container / VM
procurement payable in Lightning sats — either on Wyrd's hosting
network OR on the operator's own hardware.

BaweePay is the **wallet-side companion** to bawee:

      bawee.site            ← operator dashboard, rents Wyrd capacity
        │
        ├── provisions a CLN node container          ← FEAT-207
        │     (lightning daemon install-core --podman)
        ├── ships clnrest + tailscale on the host
        └── emits a pairing QR
                                                     ← BaweePay
                                                       (this ticket)
                                                       scans the QR,
                                                       reaches the node
                                                       over tailscale

## What already exists

To set expectations: **multiple wallets already do what BaweePay
needs to do at the protocol level.**  The friction isn't building a
new wallet — it's collapsing the operator's manual provisioning
workflow into one click.

| Wallet | Platform | Connects to CLN how |
|--------|----------|---------------------|
| Zeus   | iOS, Android | clnrest (REST), commando, or Tor |
| Spark  | desktop web  | Sparko plugin (CLN-specific HTTP) |
| RTL    | desktop web  | clnrest |
| Thunderhub | desktop web | clnrest (CLN supported alongside LND) |

All four would work today if the operator manually:

1. Rents a VPS / container
2. Installs CLN + clnrest + bitcoind (or `daemon install --trustedcoin`)
3. Sets up tailscale on the host
4. Generates a clnrest rune / TLS cert
5. Scans the cert + URL into the wallet

That's a long path — and the gap BaweePay closes.

## What BaweePay actually adds

The novel piece is **automation between bawee's provisioning and
the wallet pairing**, not a new wallet from scratch.  Three possible
implementation paths to discuss:

### Option 1 — Zeus fork / brand

Fork Zeus (open source), white-label as BaweePay, ship through the
relevant app stores or as a tauri / Capacitor build.  Pre-configure
the bawee provisioning flow so the QR scan is the only operator
step.

* pros: most code already exists upstream; battle-tested protocol
  handling; CLN + LND support out of the box
* cons: fork maintenance overhead; need to track upstream

### Option 2 — Recommend Zeus + ship the bawee glue

Don't fork.  Ship a bawee-side QR generator that produces Zeus-
compatible pairing strings.  Operators install stock Zeus from the
app store, scan the QR, done.

* pros: zero wallet-side code; rides upstream; faster to ship
* cons: any UX problem in Zeus is upstream's to fix, not ours

### Option 3 — Thin native app

Build a minimal native wallet (iOS / Android / desktop via tauri or
Electron) that does only the clnrest happy-path: get balance, scan
invoice, pay, generate invoice.  Skip the full Zeus feature set.

* pros: smallest UX surface; fastest onboarding
* cons: new app to maintain; loses features power users want
  (channel management, route hints, etc.)

Recommended starting point: **Option 2** as MVP (ship the glue,
recommend Zeus), then upgrade to Option 1 if the friction with
upstream becomes the bottleneck.

## What the integration with bawee + Wyrd looks like

Operator path (the happy case):

1. Visit bawee.site, sign in
2. Click "Lightning node"
3. Choose: rent from Wyrd / use my own hardware (bring-your-own-VPS)
4. bawee provisions a podman container running CLN
   (= `lightning daemon install-core --podman` from FEAT-207)
5. bawee's dashboard shows a pairing QR
6. Operator scans QR with BaweePay (Zeus / fork / thin)
7. Wallet pairs via tailscale → clnrest, ready to receive and pay

bawee handles steps 3-5 server-side; FEAT-207's `install-core`
provides the CLN-side install primitive.

## Open questions (the things this ticket exists to discuss)

1. **Which path** (Option 1 / 2 / 3) — depends on how invested in
   wallet-side UX bawee wants to be.
2. **Pairing-string format** — Zeus's existing format, or a bawee-
   specific one that wraps it?
3. **Tailscale or alternative?**  Tailscale is the easy default;
   wireguard / Tor / direct-clearnet are alternatives.
4. **Signing model** — clnrest exposes raw RPCs; we could expose
   only a curated subset for the wallet to use (a "rune" with
   restricted permissions), preventing the wallet from doing
   destructive operations.
5. **How does this interact with FEAT-198 (LSPS1 via Boltz) and
   FEAT-208 (Wyrd P2P liquidity)?**  Best case: BaweePay surfaces
   "buy inbound" as a one-tap action that calls the operator-side
   `lightning liquidity lsp <name> buy <sat>` (or, post-FEAT-208, a
   Wyrd clan peer).
6. **How does bawee charge** for the rented container?  Lightning
   invoice settled via the node itself?  Pre-paid sats from a
   different wallet?  Worth nailing down before scoping.

## Out of scope (initial)

- **Building a wallet from scratch** when Zeus / Spark / RTL exist.
- **Custodial fallback** — BaweePay is non-custodial by design;
  the whole point is the node runs on hardware the operator
  controls.
- **Multi-node management** — one node per BaweePay pair for the
  first cut; multi-node comes later.
- **Backup / SCB sync to bawee.site** — separate ticket; coupling
  state to the rental platform is its own design question.

## Acceptance criteria (placeholder — finalize after design)

1. Operator can rent a CLN-running container on bawee.site, scan
   the resulting QR with BaweePay, and pay / receive Lightning
   payments via their own node.
2. Tailscale (or chosen transport) is the only network path between
   wallet and node; no third-party servers in the middle.
3. Bawee-side rune limits the wallet's RPC permissions to a curated
   safe subset.
4. Pairing tested against Zeus's existing CLN-pair flow.
5. Documentation under `share/doc/lightning/guides/` covers the
   end-to-end flow from "I just signed up at bawee" to "I just
   paid an invoice from my phone."

## Milestone

None — research / future-discussion ticket.  Not assigned to a
milestone; tied to bawee + Wyrd's release schedule, not this repo's.

## See also

- FEAT-207 — `install-core` (the CLN-side install primitive bawee
  invokes when provisioning a node).
- FEAT-208 — Wyrd P2P platform (the substrate bawee runs on).
- FEAT-210 — Nostr discovery layer for liquidity (orthogonal but
  adjacent decentralised-ecosystem ticket).
- Zeus mobile wallet: https://zeusln.com (existing wallet to fork /
  recommend / glue-pair with).
- clnrest plugin docs: https://docs.corelightning.org/docs/rest
