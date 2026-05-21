---
id: FEAT-198
type: feature
priority: medium
status: in-progress
---

# Real LSPS1 inbound liquidity — wrap the cln-lsps plugin

## Description

**As a** user who needs to receive Lightning payments
**I want** `lightning liquidity lsp <name> buy <amount>` to actually
open an inbound channel from any LSPS1-compliant LSP
**So that** I don't have to use a CEX or run a payment
processor's hosted node to receive sats reliably.

Implementation: wrap the **cln-lsps** Core Lightning plugin
(community-maintained Rust plugin that speaks LSPS0 transport over
BOLT-1 custom messages and exposes LSPS1 RPCs).  Our verbs are thin
wrappers — the plugin handles the wire protocol, message framing,
and order-state machine.  First test target: **Boltz's LSPS1
endpoint**, but the plugin is LSP-agnostic so Voltage / Olympus /
Megalith / Blocktank work too with just a config-file change.

## Background

The current `libexec/lightning/liquidity` script has the right CLI
surface (`liquidity in`, `liquidity lsp <name> buy`, etc.) but the
LSPS1 implementations print "ok" and exit without opening any
channels.  They were placeholders shipped in 0.5.0.

LSPS1 (BLIP-51) is the standardised way for clients to ask LSPs
for inbound liquidity.  The protocol exchanges three messages over
BOLT-1 custom messages (LSPS0 transport):

   lsps1.get_info         # quote: sizes, fees, expiry
   lsps1.create_order     # commit to buy, get payment request
   lsps1.get_order        # poll status until channel opens

The challenge was that clightning didn't ship an LSPS1 client.
That's resolved by **cln-lsps** — a Rust plugin that implements
LSPS0 transport + LSPS1 RPCs as `lightning-cli` commands.

## Approach: wrap cln-lsps

```
liquidity lsp <name> buy <sat>
  │
  ├─ cli connect $LSP_PEER                       # pubkey@host:port from config
  ├─ cli lsps1-get-info <pubkey>                 # quote
  ├─ display price, prompt confirm (or --yes)
  ├─ cli lsps1-create-order <pubkey> <sat> ...   # pay-to invoice
  ├─ cli pay <bolt11>                            # send sats
  └─ poll cli lsps1-get-order <id> until done    # channel-state machine
```

The plugin handles the wire framing, retries, and order-state
machine; we orchestrate the operator-facing flow (display, confirm,
pay, poll, report).

### Why this beats Option B (hand-roll over `sendcustommsg`)

- ~200 lines of bash + jq instead of ~1000+ lines re-implementing
  BOLT-1 custom-message framing and an async-notification poller.
- Tracks the LSPS1 spec via someone else's maintenance.
- Same plugin will unlock LSPS2 in a follow-up (FEAT-198b) without
  rewiring our verb surface.

### Why this beats Option C (bespoke REST per LSP)

- Works against any LSPS1-compliant LSP from day 1 — no per-LSP
  REST integration to maintain.
- One source of truth for the protocol; LSP changes ride upstream.
- Boltz's LSPS1 wire endpoint is what we'll test against first, but
  Voltage / Olympus / Megalith / Blocktank work too.

## Plugin installation

Modelled on the existing `daemon install --trustedcoin` pattern.
New flag:

   lightning daemon install --lsps

Downloads the cln-lsps prebuilt binary into `$LIGHTNING_DIR/plugins/`
and adds `plugin=...` to `$LIGHTNING_CONF` so lightningd loads it on
next start.  Plugin source + pin live in two constants near
`TRUSTEDCOIN_REPO` / `TRUSTEDCOIN_VERSION`.

There's a small architectural debt to call out: we now have two
one-off plugin installers (trustedcoin + cln-lsps).  A future
generic `lightning plugin install <name>` verb will unify them, but
that's deferred — duplicating the pattern once is cheaper than
designing the generic shape before we know what third plugin will
arrive.

## Configuration

Each LSP is configured under the active wallet's repo:

   $wallet/liquidity/lsp/<name>/peer    # pubkey@host:port

Example for Boltz mainnet (operator runs once):

   mkdir -p $wallet/liquidity/lsp/boltz
   echo '02d96eadea3d780104449aca5c93461ce67c1564e2e1d73225fa67dd3b997a6018@45.86.229.190:9735' \
     > $wallet/liquidity/lsp/boltz/peer

The old `endpoint` file (HTTP URL for the REST path that was never
finished) is left as-is; new installs use `peer` instead.

## Surface (no changes from 0.5.0)

```
lightning liquidity in <amount> [--provider lsp|loop|boltz]
lightning liquidity lsp <name> buy <amount> [--yes]
lightning liquidity provider default <name>
```

Adds `--yes` to skip the cost-confirmation prompt for unattended
scripts.  No other surface changes.

## Acceptance Criteria

1. With cln-lsps loaded and a configured LSP, `lightning liquidity
   lsp boltz buy <sat>` runs the full sequence:
   connect → get-info → confirm → create-order → pay → poll → done.
2. The flow handles the order-state machine: pending → waiting-for-
   payment → channel-opening → channel-open (or refunded on error).
3. Cost transparency: before paying, print the quoted price in
   sats + a clear "type Y to confirm" or `--yes` flag.
4. Failure modes are clearly reported (plugin not loaded, LSP
   unreachable, quote expired, payment failed, order refunded,
   channel never opened).
5. Bats coverage with a stubbed lightning-cli that returns canned
   lsps1-get-info / lsps1-create-order / lsps1-get-order responses.
6. The personal-node and routing-node guides update their tier-4
   sections from "stub today" to "ships real".

## Out of scope

- **LSPS2 (JIT channels)** — same plugin supports it, separate
  ticket (**FEAT-198b**) to expose `liquidity jit on/off` and the
  invoice-wrapping logic.
- **Magma marketplace** — different protocol model; separate
  ticket (**FEAT-198a**).
- **Wyrd P2P clan / marketplace** — FEAT-208.
- **Generic `lightning plugin install` verb** — future refactor;
  trustedcoin + cln-lsps duplicate the install pattern for now.

## Milestone

1.4.0.

## See also

- BLIP-51 / LSPS1 spec: https://github.com/BitcoinAndLightningLayerSpecs/lsp/blob/main/LSPS1/README.md
- LSPS0 (transport): https://github.com/BitcoinAndLightningLayerSpecs/lsp/blob/main/LSPS0/common-schemas.md
- cln-lsps plugin: see the `LSPS_PLUGIN_REPO` constant in
  `libexec/lightning/daemon` for the current pinned source.
- `libexec/lightning/liquidity` (the verb to wire up)
- FEAT-202 (personal-node guide — tier 4 references this)
- FEAT-203 (routing-node guide — same)
- FEAT-208 (Wyrd P2P alternative)

