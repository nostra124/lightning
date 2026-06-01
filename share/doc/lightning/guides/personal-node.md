# Running `lightning` as a personal Lightning node

This is the operational guide that pairs with the
`lightning(1)` man page (which is verb-reference) and the
walkthrough (FEAT-181, which is the first-time hands-on
getting started). This guide is **strategy** — what channels
to open, how to set fees, when to rebalance, how to acquire
inbound liquidity. Four tiers, concrete numbers.

The honest framing up front: **channels are infrastructure
for your own payments. Routing fees are a side-effect, not
the product.** Treat anything you earn as a happy accident,
not a return on investment. See "Realistic economics" at the
end for why.

## Goals

- Receive payments reliably (LSP-backed inbound).
- Send payments to merchants, friends, and services without
  on-chain fees on every transaction.
- Keep the node useful with minimal operator attention.

Not goals:

- Maximise routing revenue.
- Run 20+ channels.
- Manage liquidity by hand every day.

## Tier 1 — Channel selection

**Three to five channels. No more.** Each additional channel
multiplies the rebalancing burden and the operational
attention you'll spend.

Recommended mix:

| Channel | Purpose | Notes |
|---|---|---|
| 1-2 to a major routing hub | General-purpose reachability | ACINQ, Bitrefill Thor, LNBIG, Wallet of Satoshi |
| 1-2 to services you use | Direct path, lowest cost | Your CEX, your favourite merchant, BTCPay, LNbits |
| 1-2 from an LSP | Guaranteed inbound when you receive | Voltage, Olympus, OpenSats, Megalith |

### Sizing

A common rule of thumb: scale to **~10× your typical
payment**. If you pay around $50/month, open ~500k sat
channels (~0.005 BTC, ~$375 at $75k BTC). Less burns through
in fees; more locks up money you won't use.

For a "running a small online shop" use case, scale up:
50k sat typical pay → 500k sat per typical channel; 200k sat
typical pay → 2M sat (0.02 BTC) per channel.

### On-chain cost budget

Funding tx + cooperative close: ~1,000 sat each side at low
fee rates, more in fee-spike periods. Budget ~$1 per channel
lifecycle now, plan for $5+ during fee spikes. Don't open a
channel that won't earn back this cost over its life.

### Bootstrap

```sh
lightning peer bootstrap
```

This connects to 5 well-known nodes AND persists them as
`important-peer=` in `~/.lightning/config` (FEAT-199) so
clightning auto-reconnects them after a restart. The
`peer keepalive` sidecar that `daemon enable` wires up keeps
the gossip graph reseeded after laptop sleep and wifi blips.

Then open your first channel:

```sh
lightning channel open <node-uri> 500000
```

## Tier 2 — Passive fee tuning

This is the cheapest and most effective rebalancing
mechanism. When local liquidity is low, fees rise; that
discourages spend, encourages inbound. When local is high,
fees drop; that encourages spend, evens things out. Organic
traffic does the rebalancing, AND pays you while doing it.

### Setup

```sh
# Continuous mode: feeadjuster reacts to every forward.
lightning plugin install feeadjuster

# One-shot seed: apply the balanced policy now.
lightning fee policy balanced --apply

# Inspect at any time:
lightning fee get             # all channels, recfile
lightning fee get <chan-id>   # one channel
```

### The "balanced" policy curve

`lightning fee policy balanced` uses a piecewise-linear
sigmoid on `local_sat / capacity_sat`:

| local ratio | base (msat) | ppm |
|---|---|---|
| 100% (full outbound) | 100 | 50 |
| 50% (balanced) | 1000 | 200 |
| 0% (depleted) | 5000 | 1000 |

Linear interpolation between. Live channels rarely sit
exactly at the endpoints; most settle around 30-70% and pick
up reasonable fees from the curve.

### Manual overrides

For specific channels (a large inbound from an LSP you
NEVER want to drain, a private channel you only use to
receive), override by hand:

```sh
lightning fee set 876543x12x0 0 1   # near-zero — favour drain
lightning fee set 123456x7x1 5000 0  # high base — discourage all use
```

### Why this is 80% of the rebalancing problem

Most channels never go fully one-sided in practice — they
oscillate in the 20-80% band. The `balanced` policy keeps
that natural oscillation rewarded with fee revenue rather
than punished by active rebalancing costs. You'll only need
tier 3 for the chronic cases.

## Tier 3 — Active rebalancing (sparingly)

When a channel goes fully one-sided and `feeadjuster` can't
budge it (because there's no traffic in the needed
direction), reach for `lightning rebalance`.

### LN circular (cheap when a route exists)

```sh
# Install the plugin first (one-time).
lightning plugin install rebalance

# Auto-pick most-asymmetric pair, 100k sat, fee cap 500 ppm.
lightning rebalance 100000 --dry-run
lightning rebalance 100000

# Explicit pair.
lightning rebalance 50000 --from 876543x12x0 --to 123456x7x1
```

Cost: 5-50 sat per 100k rebalanced (~0.005-0.05%). A circular
rebalance that succeeds is by far the cheapest option.

### Swap fallback (when LN can't reach)

```sh
lightning rebalance 100000 --fallback swap
```

Triggers `lightning liquidity loop out` then `loop in`. Cost:
0.1-0.5% of amount + on-chain fees (300-3000 sat). Use only
when circular rebalance fails or no LN route exists at all.

### When to give up

If a channel has been stuck one-sided for weeks and neither
circular nor swap can fix it economically, close it and open
the replacement from the other side. Force-close only if the
peer is unreachable — cooperative close is much cheaper.

### Cost discipline

Budget rebalancing spend at ~5% of your weekly fee revenue.
If a rebalance costs more than the channel will earn back in
its remaining useful life, don't do it.

## Tier 4 — Liquidity acquisition

When you regularly receive payments and the natural channel
flow runs your inbound low, buy more from an LSP.

### LSPS1 channel purchase

```sh
# Discover offers + buy from a known LSP.
lightning liquidity lsp <name> buy 1000000   # 1M sat inbound
```

Set a default provider so plain `liquidity in <amount>` works:

```sh
lightning liquidity provider default <name>
lightning liquidity in 500000
```

(FEAT-198 is the open implementation ticket — until it lands,
`lightning liquidity lsp buy` is a stub. The "buy" verb still
shows you the LSP discovery and lets you reason about your
liquidity needs.)

### When NOT to buy inbound

- You only send (no receive use case) — inbound capacity
  doesn't help you. Save the channel-open cost.
- You already have inbound capacity. Check first:
  ```sh
  lightning liquidity            # totals (recfile)
  lightning liquidity status     # per-channel TSV
  ```

### Marketplace alternative

For routing nodes Magma is a liquidity marketplace where
sellers post inbound offers and buyers pick the best price.
Outside the personal-node scope; mentioned here for
completeness.

## Monitoring

Set up a Slack/Discord/Telegram webhook for the things you
actually want to know about:

```sh
# Most-useful starter set.
lightning alert create channel-down \
    --on channel_offline \
    --webhook https://hooks.slack.com/services/...
lightning alert create low-balance \
    --on balance_below --threshold 100000 \
    --webhook https://hooks.slack.com/services/...
lightning alert create off-balance \
    --on channel_ratio_outside --threshold 5,95 \
    --webhook https://hooks.slack.com/services/...
```

`daemon enable` writes a sidecar that runs `alert run` every
60s. Verify with:

```sh
lightning alert list
lightning alert test channel-down   # dry-fire to verify webhook
```

## Realistic economics

A typical 0.1 BTC personal node (~10M sat across 3-5
channels) earns **100-1,000 sat/day in routing fees** before
costs. After active rebalancing spend, net is 0-500 sat/day.

Annualised: **$5-150 in fees against $7,500 in locked
capital** at $75k BTC. That's 0.07-2% APY. Compare:

| Strategy | Yield | Risk |
|---|---|---|
| Personal Lightning node | 0.5-2% APY (good case) | Operational + on-chain fee spikes + channel close costs |
| BTC HODL | 0% APY | Zero |
| BTC ETF | 0% APY | Counterparty + IRS reporting |
| BTC lending (CeFi) | 5-8% APY | Counterparty (high; Celsius, BlockFi precedent) |
| Pleb savings (USD) | 4-5% APY | Inflation + currency risk |

Lightning routing fees do NOT make a personal node profitable
compared to alternatives. If you want yield, lend or HODL. If
you want to use Lightning for your own payments without
on-chain fees on every transaction, run a node — the fee
revenue is a happy accident.

For a node committed to routing as a business (5+ BTC, active
management, several months of fee tuning), see the
[routing-node guide](routing-node.md). That use case has
different economics and different operational patterns; this
guide doesn't apply.

## Operational checklist

```sh
# Initial install (one-time)
lightning daemon enable --trustedcoin
lightning daemon start
lightning peer bootstrap
lightning wallet init

# Open the first channels (manual; pick wisely — see Tier 1)
lightning wallet balance --on-chain
# fund the on-chain address printed
# wait for confirmations
lightning channel open <hub-uri> 500000
lightning channel open <service-uri> 500000
lightning liquidity lsp <lsp-name> buy 1000000

# Initial fee policy
lightning plugin install feeadjuster
lightning fee policy balanced --apply

# Plugins (one-time)
lightning plugin install rebalance

# Monitoring
lightning alert create channel-down --on channel_offline --webhook <url>
lightning alert create low-inbound --on low_inbound_capacity --threshold 200000 --webhook <url>

# Day-to-day (rare — feeadjuster + alerts run on their own)
lightning daemon status
lightning fee get | less
lightning liquidity
lightning channel pending
lightning rebalance <amount>   # only when a specific channel is stuck
```

## See also

- `lightning(1)` man page — verb-by-verb reference.
- [Walkthrough](../walkthrough/README.md) — FEAT-181, the
  hands-on first-time setup (lives at FEAT-181 release).
- [Routing-node guide](routing-node.md) — the 5+ BTC
  companion to this guide (FEAT-203).
- BOLT 7 (channel announcements, gossip):
  `share/doc/lightning/standards/bolts/07-routing-gossip.md`.
- BLIP 51 (LSPS1, channel-request flow):
  `share/doc/lightning/standards/lsp-rfc/`.
