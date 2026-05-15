---
id: FEAT-178
type: feature
priority: medium
status: open
---

# Vendor BOLT specs + LNURL LUDs + Lightning Address spec under `share/doc/lightning/standards/`

## Description

**As a** user of the educational `lightning` toolkit
**I want** the canonical Lightning specs vendored locally
— BOLTs, LNURL LUDs, Lightning Address, BIP-353 — so any
operation is one step away from the spec text
**So that** the educational mission lands: `lightning help
pay` cites BOLT-11; `lightning help offer` cites BOLT-12;
`lightning help address` cites the LN Address spec + BIP-353.

Mirrors FEAT-017 (bitcoin BIPs), FEAT-094 (services),
FEAT-126 (dht).

## Implementation

1. **Vendor documents** under
   `share/doc/lightning/standards/`:

       bolts/                            (lightning/bolts repo, MIT)
         00-introduction.md
         01-messaging.md
         02-peer-protocol.md             channel mgmt
         03-transactions.md
         04-onion-routing.md
         05-onchain.md                   channel close
         07-routing-gossip.md
         08-transport.md                 encrypted, authed wire
         09-features.md
         11-payment-encoding.md          BOLT-11 invoices
         12-offer-encoding.md            BOLT-12 offers
         README-drafts.md                pointers to draft specs
                                          (watchtowers, onion messages)
                                          we vendor once they stabilise

       lnurl-rfc/                        (fiatjaf/lnurl-rfc repo, CC0)
         lud-01.md  base
         lud-04.md  auth
         lud-06.md  pay
         lud-09.md  comments
         lud-12.md  metadata
         lud-16.md  paymentRequest in description
         lud-17.md  protocol scheme

       lightning-address/                (lightning.address)
         spec.md                         the LN Address spec
                                          (Markdown render of upstream)

       bips/
         bip-353.md                      DNS-based payment instructions
                                          (cross-link to bitcoin's
                                           vendored copy if present)

       blips/                            (Bitcoin Lightning Improvement
                                          Proposals)
         blip-50.md                      LSPS general
         blip-51.md                      LSPS1 channel purchase

       comparison.md                     contrasts the three LN
                                          implementations (clightning /
                                          lnd / phoenixd) — model,
                                          auth, RPC dialect, mobile
                                          friendliness, BOLT-12 support.
                                          Educational centrepiece.

2. **`UPSTREAM.txt`** records canonical URL + retrieved-on
   date per vendored document. Refresh script re-fetches.

3. **`.rpk/package`** installs `share/doc/lightning/standards/*`.

## Acceptance Criteria

1. `share/doc/lightning/standards/` contains every
   document above plus `UPSTREAM.txt`.
2. Licence boundaries respected (BOLTs MIT, LUDs CC0, etc.).
3. After `make install`, every cited file is reachable.
4. The refresh script re-fetches reproducibly.
5. `comparison.md` contrasts the three implementations —
   readable in 10 minutes, leaves a reader with a model
   of why each exists.
