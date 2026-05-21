---
id: FEAT-208
type: feature
priority: low
status: research
---

# Wyrd integration — peer-to-peer Lightning liquidity marketplace / clan

## Description

**As a** node operator who doesn't want to lease inbound from a
single LSP
**I want** to buy and sell Lightning liquidity peer-to-peer with
other operators inside a Wyrd "clan" (a trust-graph community)
**So that** liquidity flows decentrally — better pricing, no single
LSP holding the routing key to my receive flow.

Placeholder ticket — filed for future discussion.  The integration
target (Wyrd) needs documentation review and a design conversation
before any code work starts.

## Background

FEAT-198 ships a centralised LSP integration (Boltz LSPS1).  That
covers the cold-start case for new nodes, but it leaves operators
buying inbound from a single counterparty with the usual
trade-offs:

- one LSP knows every channel you open
- single point of pricing — no real market discipline
- centralised availability (if the LSP goes down, you can't lease)

A peer-to-peer market for Lightning liquidity gives a decentralised
alternative, and one that matches the spirit of Lightning itself.

## What Wyrd is (sister project)

Wyrd is a sister project — a **peer-to-peer Platform-as-a-Service**
under independent development by the same author.  It provides:

- container / VM procurement payable in Lightning sats, on Wyrd's
  hosting network OR on the operator's own hardware
- a P2P trust / clan layer for peering between operators
- the substrate **bawee.site** (the operator-facing rental platform
  — see FEAT-209) builds upon

For Lightning liquidity specifically, Wyrd's clan + settlement
primitives are a natural fit: the same operators renting capacity
to each other can also broker inbound channels to each other inside
the same trust graph.

The "clan" angle is interesting on its own: a group of operators
who trust each other (mutual peers, a routing collective, a
geographic node-runner meetup) could share inbound liquidity within
the clan at preferential terms — different from a fully-open
marketplace.  Both modes are worth scoping.

## Open questions (the things this ticket exists to discuss)

1. **What is Wyrd's actual protocol surface?**  REST?  Lightning
   custom-message?  Nostr events?  Read the docs and write it down
   here before designing verbs.
2. **What does a "clan" look like in their model?**  Is it a
   first-class concept or something we layer on top via a
   membership list?
3. **Trust model.**  P2P liquidity sales involve trust — the seller
   has to actually open the channel after being paid.  Wyrd's
   reputation / scoring / escrow story matters.  Is there an HTLC-
   based atomic-swap path or is it trust-based?
4. **Settlement.**  How does payment for inbound happen — on-chain,
   Lightning, signed receipts?  Does Wyrd handle the LSPS1 wire or
   are they a discovery/matching layer on top?
5. **How does this compose with FEAT-198?**  Best case: same verb
   surface (`liquidity lsp <name> buy`) with a "Wyrd as the LSP"
   shim that auto-discovers offers from peers inside the clan.
6. **How does this compose with Amboss Magma (FEAT-198a, also
   future)?**  Magma is a centralised marketplace; Wyrd would be
   the decentralised alternative.  They can probably coexist as two
   `--provider` options.

## Proposed surface (sketch — finalize in design phase)

```
lightning liquidity clan list                   show clans we're in
lightning liquidity clan join <invite>          accept a clan invite
lightning liquidity clan leave <name>
lightning liquidity clan members <name>         who else is in
lightning liquidity clan offers <name>          inbound offers from the clan
lightning liquidity wyrd buy <sat> [--from <peer>]
lightning liquidity wyrd sell <sat> [--to <peer>] [--price <ppm>]
```

This is a strawman.  Pick from / modify after reading Wyrd's docs.

## Out of scope (initial)

- **Full decentralised orderbook** — Wyrd presumably handles
  discovery / matching; we don't reinvent that layer.
- **Trust scoring** — leverage whatever reputation system Wyrd
  ships with.
- **Custodial fallback** — if a clan member fails to open the
  channel after being paid, that's a Wyrd-level dispute, not
  something we resolve in our verbs.
- **LSPS2 JIT channels** via the clan — first prove the LSPS1-style
  one-shot flow works, then think about JIT.

## Acceptance criteria (placeholder — finalize after design)

1. `lightning liquidity clan join <invite>` joins a clan and
   persists membership under the wallet repo.
2. `lightning liquidity clan offers <name>` lists current inbound
   offers from clan peers (TSV: peer / size / price / expiry).
3. `lightning liquidity wyrd buy <sat>` matches an offer, runs the
   handshake, results in an actual inbound channel.
4. Failure modes are reported clearly (no offers, counterparty
   reneges, channel never opens).
5. Bats coverage with a stubbed Wyrd that returns canned
   match/offer responses.
6. The personal-node and routing-node guides gain a "P2P liquidity
   via Wyrd" tier under "advanced inbound" once it ships.

## Milestone

None — research / future-discussion ticket.  Not assigned to a
milestone; implementation work is gated on the Wyrd protocol shape
being finalised + the design conversations called out under "Open
questions" above.

## See also

- FEAT-198 — Boltz LSPS1 integration (the centralised LSP path).
- FEAT-198a — Amboss Magma marketplace (the centralised
  marketplace path, not yet filed).
- FEAT-209 — Self-hosted CLN wallet companion (BaweePay).
  Same sister-project ecosystem; both rely on Wyrd's hosting layer.
- FEAT-210 — Nostr discovery layer for liquidity.  May fold into
  this ticket if Wyrd's transport turns out to be Nostr-based.
- `libexec/lightning/liquidity` — the verb whose surface this
  extends.
