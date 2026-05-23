---
id: FEAT-210
type: feature
priority: low
status: research
---

# Nostr-based discovery layer for Lightning liquidity

## Description

**As a** node operator looking for inbound liquidity (or selling it)
**I want** to discover counterparties via Nostr rather than via a
centralised LSP or marketplace
**So that** matching is censorship-resistant and survives any
single LSP / marketplace going offline.

Filed for future discussion.  This is the protocol-level companion
to FEAT-208 (Wyrd P2P clan / marketplace).  If Wyrd's transport
turns out to be Nostr-based, this ticket folds into FEAT-208.  If
Wyrd uses something else (custom protocol, REST, etc.) then this
remains a separate path — Nostr as a generic decentralised
discovery layer for any LSPS1-compliant settlement.

## Sister-project context

**Wyrd** (FEAT-208) is a peer-to-peer Platform-as-a-Service under
independent development by the same author — providing container /
VM procurement payable in Lightning sats on Wyrd's hosting network
or the operator's own hardware, plus a P2P trust / clan layer.

**bawee.site** (FEAT-209) is the operator-facing dashboard that
builds on Wyrd.

This ticket exists to scope the Nostr-side of the liquidity story:
how operators **discover each other's offers** in a decentralised
way.  Settlement is LSPS1 (FEAT-198); discovery is the open
question.

## What exists in the Nostr ecosystem today

Honest framing: my visibility into the Nostr ecosystem has a
knowledge cutoff (early 2026).  Things may have evolved.  What I
can confirm:

| Project / NIP | What | Adjacent to LSPs? |
|---------------|------|---------|
| **NIP-15 (Marketplace)** | Generic marketplace events.  Product-agnostic. | yes — could be extended for liquidity offers |
| **NIP-47 (Nostr Wallet Connect)** | Wallet-to-node remote-control over Nostr DMs. | infrastructure (relays, encrypted DMs) overlaps |
| **NIP-57 (Zaps)** | Micropayments via Lightning + Nostr. | settlement, not discovery |
| **Mostro** | P2P fiat ⇄ BTC marketplace on Nostr, HODL-invoice escrow. | adjacent — same protocol shape |
| **Robosats** | P2P fiat ⇄ BTC, originally Tor-only, adding Nostr. | adjacent — same protocol shape |
| **LN Markets** | Derivatives + channel-leasing.  Not Nostr-native. | adjacent — different transport |

**What I don't think exists yet as a dominant project:** a widely-
adopted Nostr-native LSPS-style channel-lease marketplace where
operators broadcast inbound-offer events, peers match via DMs, and
settlement happens over LSPS1 wire.  The concept fits Nostr
beautifully — it's a small NIP away from being formalised.

If something like this DOES exist by the time we resume this
ticket, it slots in cleanly — we wrap it like FEAT-198 wraps
cln-lsps.

## Open questions

1. **Survey actively.**  Re-do the ecosystem survey when work
   starts.  Specifically check for:
   * Any NIP draft for liquidity events
   * Bitkit / Synonym / Blocktank's Nostr work (they were exploring
     it for inbound-only)
   * Whether Mostro / Robosats has extended to channel sales
2. **Settlement.**  Once a peer accepts an offer over Nostr, the
   settlement layer is most likely LSPS1 — same primitive FEAT-198
   uses.  Confirm.
3. **Relay strategy.**  Which relays do we trust to carry liquidity
   events?  Operator-curated list, hard-coded defaults, or both?
4. **Identity model.**  Operator Nostr pubkey ↔ Lightning node
   pubkey binding.  How is the link asserted (signed event with
   both keys) and verified?
5. **Privacy.**  Liquidity offers are public by default on Nostr.
   Acceptable for routing-node operators with public capacity
   anyway; problematic for personal-wallet operators.  Encrypted
   offer events / paid-relay relays / Whatnot?
6. **Interaction with FEAT-208 (Wyrd) and FEAT-198 (LSPS1 / cln-
   lsps).**  Best case: this is a `--provider nostr` flag on the
   existing `liquidity in / lsp` verbs, with Nostr as the discovery
   transport and cln-lsps as the settlement transport.

## Proposed surface (sketch — finalize in design phase)

```
lightning liquidity nostr offers [--relay <url>] [--max-price <ppm>]
                                                show currently-broadcast offers
lightning liquidity nostr buy <sat> [--from <npub>]
                                                accept an offer + settle via LSPS1
lightning liquidity nostr sell <sat> [--price <ppm>] [--expiry <h>]
                                                broadcast our own offer
```

`buy` reuses FEAT-198's settlement code path.  `sell` is the new
direction (operator becomes an LSP for the duration of the offer).

## Out of scope (initial)

- **Designing a new NIP for liquidity events** if one already
  exists.  Use what's there; only propose a NIP if the ecosystem
  has nothing.
- **Acting as a Nostr relay** ourselves — we're a client.
- **Trust scoring of counterparties** beyond what their Nostr
  profile + repeat trades tell us.  No reputation database we
  maintain.
- **Custodial escrow** — settlement is direct LSPS1 channel-open;
  no third party holds funds in the loop.

## Acceptance criteria (placeholder — finalize after design)

1. `lightning liquidity nostr offers` queries the configured relay
   set and prints a TSV of current offers (counterparty / size /
   price / expiry).
2. `lightning liquidity nostr buy` accepts an offer, runs the
   LSPS1 handshake with the counterparty's node, and results in an
   inbound channel.
3. Failure modes are clearly reported (no relays reachable,
   counterparty offline, offer expired, settlement failed).
4. Bats coverage with a stubbed Nostr relay returning canned events.

## Milestone

backlog — research, unscheduled.  Revisit post-1.0; not required for the alpha feature-complete cut.

## See also

- FEAT-198 — LSPS1 channel-purchase via cln-lsps plugin (the
  settlement layer this would discover over).
- FEAT-208 — Wyrd P2P liquidity clan (if Wyrd's transport IS
  Nostr, this ticket folds into FEAT-208).
- FEAT-209 — BaweePay (wallet-side companion; same ecosystem).
- NIP-15 (Marketplace): https://github.com/nostr-protocol/nips/blob/master/15.md
- NIP-47 (Nostr Wallet Connect): https://github.com/nostr-protocol/nips/blob/master/47.md
- Mostro: https://mostro.network
- Robosats: https://learn.robosats.com
