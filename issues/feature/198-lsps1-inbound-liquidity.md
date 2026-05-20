---
id: FEAT-198
type: feature
priority: medium
status: open
---

# Real LSPS1 inbound liquidity — replace the `liquidity in / lsp` stubs

## Description

**As a** user who needs to receive Lightning payments
**I want** `lightning liquidity in <amount>` and
`lightning liquidity lsp <name> buy <amount>` to actually
open an inbound channel from an LSP using the LSPS1 protocol
**So that** I don't have to use a CEX or run a payment
processor's hosted node to receive sats reliably.

Filed retroactively from MILESTONE-0.7.0 / MILESTONE-0.8.0
references. Deferred from 0.7.0 because the spec discussion
revealed it's research-heavy: needs decisions on which LSP
to target first and whether to wrap an existing LSPS1 client
plugin or hand-roll over `sendcustommsg`.

## Background

The current `libexec/lightning/liquidity` script has the
right CLI surface (`liquidity in`, `liquidity lsp <name>
buy`, etc.) but the implementations print "ok" and exit
without opening any channels. They were placeholders
shipped in 0.5.0.

LSPS1 (BLIP-51) is the standardised way for clients to ask
LSPs for inbound liquidity. The protocol uses Lightning's
custom-message wire (BOLT-1 type-65535 + LSP-specific
sub-types) for:

   LSPS0: lsps0.list_protocols     # discovery
   LSPS1: lsps1.get_info           # quote (sizes, fees, expiry)
   LSPS1: lsps1.create_order       # commit to buy, get payment req
   (pay the invoice or on-chain order via existing verbs)
   LSPS1: lsps1.get_order          # poll status until channel opens

The challenge: clightning doesn't ship an LSPS1 client. We
either build one or wrap a third-party plugin.

## Implementation paths

### Option A — Wrap an existing LSPS1 client plugin

Pros: protocol details handled by someone else; fewer lines
of code in our tree.
Cons: as of 2026, the canonical CLN-side LSPS1 client doesn't
exist in `lightningd/plugins`. Candidates would be project-
specific (Voltage's, Megalith's, Olympus by Zeus's).
Vendor lock-in risk.

### Option B — Hand-roll over `sendcustommsg`

Pros: stays in this repo; no external runtime dependencies;
educational value matches our design principles.
Cons: ~500-1000 lines of bash + json. We'd need:

- LSPS message framing (BOLT-1 type 37913 / 37925 for LSPS0/1)
- async response handling (custom-message notifications arrive
  via `notification` plugin hook, but we're a shell wrapper —
  may need a small plugin or a polling loop)
- handling LSPS1's order-state machine
- pay-the-invoice integration with our existing `invoice pay`

### Option C — Tactical: bespoke per-LSP REST integration

Pros: shortest path to a working flow against one specific
LSP. Most LSPs expose a REST API for orders alongside the
LSPS1 wire protocol.
Cons: not portable; each LSP needs its own implementation;
not the standardised LSPS1 path.

### Recommended sequence

1. Survey current LSPs and their LSPS1 support (Voltage,
   Olympus by Zeus, Megalith, Boltz, etc.).
2. Pick one to target as a first integration.
3. If they have a clean REST API, do Option C as MVP (gets
   users a working flow fast).
4. Refactor to Option B once the second LSP is on the
   roadmap (the bespoke REST integration becomes
   maintenance burden the moment we add a second).
5. If a canonical LSPS1 client plugin emerges upstream
   before we're done, switch to Option A.

## Surface (already in place)

```
lightning liquidity in <amount> [--provider lsp|loop|boltz]
lightning liquidity lsp <name> buy <amount>
lightning liquidity provider default <name>
```

Implementation work fills in the bodies. No CLI surface
changes expected.

## Acceptance Criteria

1. `lightning liquidity lsp <name> buy <sat>` against at
   least one configured LSP actually opens an inbound
   channel of <sat> sat to our node (verifiable via
   `lightning channel list` after order completes).
2. The flow handles the order-state machine: pending →
   waiting-for-tx → channel-open. Operator sees status
   updates (recfile) without polling manually.
3. Cost transparency: before paying, print the quoted price
   in sats + a clear "type Y to confirm" or `--yes` flag.
4. Failure modes are clearly reported (LSP unreachable,
   quote expired, payment failed, channel never opened).
5. Bats coverage with a stubbed LSP that returns canned
   LSPS1 responses.
6. The personal-node and routing-node guides update their
   tier-4 sections from "stub today" to "ships real".

## Out of scope

- LSPS2 (channel sales the other direction — operator
  selling inbound to other peers).
- Magma marketplace integration (different protocol /
  layer; can land separately as FEAT-198a).

## Milestone

0.8.0.

## See also

- BLIP-51 / LSPS1 spec: https://github.com/BitcoinAndLightningLayerSpecs/lsp/blob/main/LSPS1/README.md
- LSPS0 (transport): https://github.com/BitcoinAndLightningLayerSpecs/lsp/blob/main/LSPS0/common-schemas.md
- `libexec/lightning/liquidity` (the verbs to implement)
- FEAT-202 (personal-node guide — tier 4 references this)
- FEAT-203 (routing-node guide — same)
