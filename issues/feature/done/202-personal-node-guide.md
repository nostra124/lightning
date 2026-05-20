---
id: FEAT-202
type: feature
priority: medium
status: open
---

# Operational guide: running `lightning` as a personal node

## Description

**As a** new user of `lightning` running a personal Lightning
wallet on a laptop or small server
**I want** a single document that walks me through channel
selection, fee policy, rebalancing, and inbound-liquidity
acquisition in concrete terms
**So that** I don't have to assemble the strategy from BOLT
specs, plugin READMEs, and forum threads.

Lives at `share/doc/lightning/guides/personal-node.md`. Pairs
with the `lightning(1)` man page (FEAT-179) which is
verb-reference; this is strategy and operational practice.

## Content (four tiers, concrete numbers)

### Tier 1 — Channel selection

- Recommend 3-5 channels, no more.
- Mix:
  - 1-2 to a major routing hub (ACINQ, Bitrefill, LNBIG)
  - 1-2 to services you actually use (your CEX, BTCPay, LNbits)
  - 1-2 from an LSP (Voltage, Olympus, OpenSats) for inbound
- Size: ~10× your typical payment. Concrete examples for
  "pays $50/month online" vs. "runs a small shop".
- Channel cost math: funding tx + eventual close ≈ 1k sat at
  low fee rates; budget for it.

### Tier 2 — Passive fee tuning

- `lightning plugin install feeadjuster` (continuous)
- `lightning fee policy balanced --apply` (initial seed; FEAT-200)
- Why this earns money instead of costing it: when fees
  discourage spend on a depleted channel and encourage spend on
  a full one, organic traffic rebalances you AND pays you for it.
- 80% of the rebalancing problem solved here.

### Tier 3 — Active rebalancing (sparingly)

- `lightning rebalance <amount>` (FEAT-201) when a channel is
  stuck and `feeadjuster` can't reach it.
- LN circular preferred (cheap); swap fallback when no route.
- Cost math: circular ≈ 5-50 sat per 100k rebalanced; swap ≈
  0.1-0.5% of amount + on-chain fees.
- When to give up and close + reopen.

### Tier 4 — Liquidity acquisition

- `lightning liquidity lsp <name> buy <amount>` for inbound
  (FEAT-198 once real).
- Magma / liquidity-ads marketplaces for shopping around.
- When NOT to buy inbound: if you only send, don't waste sats
  on inbound capacity you won't fill.

## Realistic economics section

A frank one-page subsection: typical personal node returns
0-2% APY in fees on locked capital, vs. ~5-8% lending the same
BTC. The "make money routing" framing is a trap for personal
nodes. The right framing: channels are infrastructure for your
own payments; routing fees are a side-effect, not the product.

For the "I really want to earn from routing" case: point to
FEAT-203 (routing-node guide) and Plebnet / BOSScore communities.

## Format

Markdown, ~5-8 pages. Lives at
`share/doc/lightning/guides/personal-node.md`. Linked from:
- `lightning(1)` man page see-also section
- README.md
- `lightning help` (mention in the top-level help, single line)

Sections:
1. Goals & framing (one page)
2. Tier 1: channel selection
3. Tier 2: passive fees
4. Tier 3: active rebalancing
5. Tier 4: liquidity acquisition
6. Realistic economics
7. When to consider a routing node (-> FEAT-203)
8. Operational checklist (one screen, copy-pasteable)

## Acceptance Criteria

1. File exists at `share/doc/lightning/guides/personal-node.md`.
2. Every command in the guide either exists today or has a
   filed FEAT- ticket (no vapor commands).
3. Numbers in the economics section are sourced (Plebnet
   surveys, BOSScore quartiles) with dates attached so they're
   refreshable.
4. The operational checklist fits one terminal screen and can
   be copy-pasted as actual `lightning` commands.
5. Linked from man page, README, and top-level help.

## Milestone

0.7.0 — same milestone as FEAT-200/201 since the doc cites them.

## See also

- FEAT-200, FEAT-201 (the verbs the guide depends on)
- FEAT-203 (routing-node guide)
- FEAT-181 (walkthrough — getting-started, different audience)
