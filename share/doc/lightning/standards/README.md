# Vendored Lightning Network standards

> Per FEAT-178. Every spec `lightning` cites is vendored
> locally so a reader is always one path away from the
> authority. Refresh via `./refresh.sh`; provenance is
> tracked in `UPSTREAM.txt`.

## BOLT — Basis of Lightning Technology

The base protocol specification.

| BOLT   | Title                                        | File                              |
|--------|----------------------------------------------|-----------------------------------|
| BOLT 1 | Base Protocol                                | `bolts/01-messaging.md`           |
| BOLT 2 | Peer Protocol for Channel Management         | `bolts/02-peer-protocol.md`       |
| BOLT 3 | Bitcoin Transaction and Script Formats       | `bolts/03-transactions.md`        |
| BOLT 4 | Onion Routing Protocol                       | `bolts/04-onion-routing.md`       |
| BOLT 5 | Recommendations for On-chain Transactions    | `bolts/05-onchain.md`             |
| BOLT 7 | P2P Node and Channel Discovery               | `bolts/07-routing-gossip.md`      |
| BOLT 8 | Encrypted and Authenticated Transport        | `bolts/08-transport.md`           |
| BOLT 9 | Assigned Feature Flags                       | `bolts/09-features.md`            |
| BOLT 11| Invoice Protocol for Lightning Payments      | `bolts/11-payment-encoding.md`    |
| BOLT 12| Flexible Protocol for Lightning Payments     | `bolts/12-offer-encoding.md`      |

Upstream: <https://github.com/lightning/bolts>.

Drafts not yet vendored (watchtowers BLIP, onion-messages
drafts) — `README-drafts.md`.

## LNURL LUDs

Lightning Network URL specifications.

| LUD    | Topic                                        |
|--------|----------------------------------------------|
| LUD-01 | Base bech32-encoded URLs                     |
| LUD-04 | LNURL-auth                                   |
| LUD-06 | payRequest endpoint                          |
| LUD-09 | Comments in payRequest metadata              |
| LUD-12 | Comments allowed on payRequest               |
| LUD-16 | Lightning Address (`user@domain.tld`)        |
| LUD-17 | Protocol scheme prefixes                     |

Upstream: <https://github.com/lnurl/luds>.

## Lightning Address

The Lightning Address spec layers atop LUD-16:
`lightning-address/spec.md`. Upstream:
<https://lightningaddress.com/>.

## BIPs

| BIP     | Topic                                        |
|---------|----------------------------------------------|
| BIP-353 | DNS-based payment instructions               |

## BLIPs — Bitcoin Lightning Improvement Proposals

| BLIP    | Topic                                        |
|---------|----------------------------------------------|
| BLIP-50 | LSPS general framework                       |
| BLIP-51 | LSPS1 — channel purchase                     |

Upstream: <https://github.com/lightning/blips>.

## Project-specific specs

| File                      | Topic                              |
|---------------------------|------------------------------------|
| `api/spec.md`             | Lightning Well-Known JSON API      |
|                           | (FEAT-196: send / recv / balance)  |
| `cln-overview.md`         | clightning architectural tour      |
|                           | (FEAT-178 §cln-overview)           |

## Citation policy

    BOLT NN §X.Y (paragraph title) — <one-line behaviour>
    LUD-NN §X (paragraph title) — <one-line behaviour>

Each verb's `--help` cites the relevant section.

## Refresh

    cd share/doc/lightning/standards
    ./refresh.sh

Updates `UPSTREAM.txt` retrieved-on column. Commit the diff
to keep the vendored copies in sync with upstream.
