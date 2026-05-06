# Vendored Lightning Network standards

> Per FEAT-178. The Lightning Network protocol specs and
> related standards `lightning` and its plugins
> implement.

## BOLT — Basis of Lightning Technology

The base protocol specification (11 documents).

| BOLT  | Title                                       |
|-------|---------------------------------------------|
| BOLT 1| Base Protocol                               |
| BOLT 2| Peer Protocol for Channel Management        |
| BOLT 3| Bitcoin Transaction and Script Formats      |
| BOLT 4| Onion Routing Protocol                      |
| BOLT 5| Recommendations for On-chain Transactions   |
| BOLT 6| Reserved                                    |
| BOLT 7| P2P Node and Channel Discovery              |
| BOLT 8| Encrypted and Authenticated Transport       |
| BOLT 9| Assigned Feature Flags                      |
| BOLT 10| DNS Bootstrap and Assisted Node Location   |
| BOLT 11| Invoice Protocol for Lightning Payments    |

Upstream: <https://github.com/lightning/bolts>.

## LNURL LUDs

Lightning Network URL specifications (LUD-01 through
LUD-21+).

Upstream: <https://github.com/lnurl/luds>.

Notable:
- LUD-01: base-bech32-encoded URLs
- LUD-06: payRequest endpoint
- LUD-16: Lightning Address (`user@domain.tld`)

## Lightning Address

The Lightning Address spec uses LUD-16 to make Lightning
payments addressable as `user@domain.tld`.

Upstream: <https://lightningaddress.com/>.

## Backends

Each daemon implements the full BOLT set with
implementation-specific extensions:

- **clightning** (Core Lightning, Blockstream):
  <https://docs.corelightning.org/>
- **lnd** (Lightning Labs):
  <https://github.com/lightningnetwork/lnd>
- **phoenixd** (ACINQ, lightweight):
  <https://phoenix.acinq.co/server>

`lightning <verb>` dispatches to whichever backend is
configured locally; the verb surface is uniform across
them.

## Citation policy

    BOLT NN §X.Y (paragraph title) — <one-line behaviour>
    LUD-NN §X (paragraph title) — <one-line behaviour>
