# Running `lightning` as a small/medium routing node

Companion to the [personal-node guide](personal-node.md).
Aimed at operators committing 5+ BTC, opening 10-50 channels,
and treating the node as a small business or a focused hobby.
Up to ~20 BTC of capacity, this tool is comfortable. Beyond
that, you probably want `lnd` + `balance-of-satoshis`.

The first section is required reading even if you're sure
you want to do this.

## Why run a routing node?

Honest numbers first. A 5 BTC node, actively managed, typical
2026 conditions:

| Capacity | Fees earned (low/high) | Annualised |
|---|---|---|
| 5 BTC | 5-50k sat/day | 0.5-3.5% APY |
| 10 BTC | 10-100k sat/day | 0.5-3.5% APY |
| 20 BTC | 30-200k sat/day | 0.5-3.5% APY |

Yield doesn't scale linearly with capacity. ETF dividends
and CeFi lending both beat this in most years. The cases
where running a routing node makes economic sense:

1. **You're going to be in the ecosystem anyway** — running
   a payment processor, exchange, custodian, or LSP. The
   routing node is infrastructure; fees are bonus.
2. **You care about decentralisation** as a public good and
   are willing to subsidise it.
3. **You enjoy it as a hobby** — Plebnet community, BOSScore
   leaderboards, learning Lightning at depth.
4. **You're at scale enough to justify it** (10+ BTC,
   multi-region, dedicated operational hours).

If none of those, run a personal node instead. The yield
math just doesn't work for "I want to earn money routing
Lightning payments" alone.

## Channel strategy at scale

### Channel count

20-50 channels is typical. Beyond 50 the operational burden
grows faster than the marginal fee revenue — diminishing
returns set in around 30 for most node profiles.

### Mix

- 5-10 **anchor channels** of 5-20M sat (0.05-0.2 BTC each)
  to high-volume hubs. ACINQ, LNBIG, Bitrefill, Wallet of
  Satoshi, Olympus by Zeus.
- 10-30 **smaller channels** of 1-5M sat to mid-tier nodes.
  These build graph density and catch the long tail of
  routing requests.
- 2-5 **service channels** to your CEX / merchant network /
  LSP partners. These have predictable flows.

### Geographic diversification

Don't peer with only one region. A US-east-coast outage that
takes out half your peer set kills your node's routing
ability for the duration. Aim for at least three regions
across your top-10 channels.

### Channel acceptance

Use `clnrod` (channel-rules-of-business plugin) to filter
inbound channel-open requests:

- Reject channels smaller than your minimum useful size
  (typically 500k-1M sat).
- Reject peers with no track record (no channels, very low
  node-age).
- Reject peers from sanctioned jurisdictions if your
  regulatory posture requires it.

```sh
lightning plugin install clnrod
# Configuration lives in $LIGHTNING_DIR/clnrod/rules.toml
```

### Bootstrap + persistence

```sh
lightning peer bootstrap -n 10   # bigger seed than the personal default
```

The persisted `important-peer=` block (FEAT-199) keeps these
nodes always-connected across daemon restarts. The
keepalive sidecar handles the wifi/sleep case.

## Fee strategy

### Continuous mode

`feeadjuster` is the baseline — install it and let it
react to every forward event:

```sh
lightning plugin install feeadjuster
lightning fee policy balanced --apply
```

### Per-channel overrides

Routing nodes benefit from per-channel-class fee tuning. Use
`lightning fee set` to override the balanced policy on
specific channels:

| Channel class | Base (msat) | ppm | Rationale |
|---|---|---|---|
| **Anchor channels** | 5000+ | 10-50 | Tight ppm catches volume; high base recovers cost of being a "regular" route |
| **Smaller / experimental** | 0-1000 | 100-500 | Looser ppm encourages probing; base low so small payments aren't rejected |
| **One-directional flow** (e.g. a CEX you only send to) | 0 | 1 | Drain freely; cost recovery happens elsewhere |

### Quarterly review

Look at forwarding stats (FEAT-188 once landed — until then,
parse `lightning-cli listforwards` directly) every quarter and
adjust:

- Channels with zero forwards in N weeks → consider closing
  (or moving to a different peer).
- Channels with very high forward count + low fee revenue →
  raise ppm to match the value you're providing.
- Channels with frequent failed forwards → check
  `htlc_maximum_msat` (you may be capping too low).

## Active rebalancing at scale

### Schedule it

Don't run rebalance manually for every channel. Use cron /
launchd / systemd timer:

```sh
# Every 6 hours, rebalance the most asymmetric pair if needed.
*/6 * * * lightning rebalance 1000000 --max-fee-ppm 300
```

### Budget discipline

Spend at most 1-5% of weekly fee revenue on rebalancing. If
the rebalance plugin reports more than this in fees-spent
over a week, dial back:

- Tighten `--max-fee-ppm` cap (e.g. 300 → 200).
- Reduce rebalance frequency.
- Live with mildly asymmetric channels; let `feeadjuster`
  catch up over weeks rather than hours.

### Source for big rebalances

When you need to move >500k sat at once, `lightning rebalance
--fallback swap` is often cheaper than circular routing. Loop
and Boltz are price-competitive for amounts in the 1-50M sat
range. Circular is best for the 10-500k sat range.

## Monitoring and alerts

```sh
lightning alert create peer-down \
    --on peer_offline \
    --cooldown 30m \
    --webhook https://hooks.slack.com/services/...

lightning alert create channel-stuck \
    --on channel_ratio_outside --threshold 5,95 \
    --cooldown 4h \
    --webhook https://hooks.slack.com/services/...

lightning alert create low-inbound \
    --on low_inbound_capacity --threshold 5000000 \
    --webhook https://hooks.slack.com/services/...

lightning alert create daemon-died \
    --on daemon_down \
    --cooldown 5m \
    --webhook https://hooks.slack.com/services/...
```

The alert sidecar runs every 60s; webhooks fire when
conditions trip (subject to per-rule cooldown).

For richer dashboards: `lightning plugin install prometheus`
and point Grafana at the resulting metrics endpoint.

## Backup at scale

The wallet repo + SCB pattern that ships with this tool
(`lightning wallet backup`, FEAT-187) handles the core case.
At routing-node scale, additional considerations:

- **Off-host seed backup**: print the BIP-39 seed on a steel
  plate, or split with SLIP-39. Not in `lightning`'s scope.
- **Wallet repo to multiple remotes**: configure git push to
  origin + backup remotes:
  ```sh
  git -C ~/.lightning/wallet/default remote add backup git@server2:wallet.git
  lightning wallet push backup
  ```
- **SCB snapshot after every channel event**: write a hook
  that calls `lightning channel scb emit` on `channel_open`
  / `channel_close` notifications. Until that's wrapped as
  a plugin, run hourly via cron.
- **Quarterly disaster-recovery drill**: on a test machine,
  `lightning wallet restore <remote>` from your backup, then
  `lightning wallet seed import` from the off-host backup,
  then `lightning channel scb restore`. Verify the node
  comes back up and reconnects.

## Tax + accounting

`lightning ledger export csv` (FEAT-193) gives you a ledger
you can feed to your accountant or upload to Koinly /
CoinTracking / Bittytax.

Jurisdiction-specific:

- **US**: routing fees are ordinary income at FMV when
  received. Each forward is a taxable event.
- **EU**: VAT treatment varies. Most jurisdictions don't tax
  routing fees because they're a financial service, but
  check locally.
- **DE specifically**: routing fees are likely "private
  Veräußerungsgewinne" under §23 EStG if held >1 year, or
  "sonstige Einkünfte" otherwise. Get advice.

This is not legal advice. Talk to a Bitcoin-literate
accountant in your jurisdiction.

## Privacy

For a routing node, Tor isn't optional — your node's IP
becomes a public liability the moment you announce a
channel. See FEAT-189 (Tor / network privacy) when it lands.

Until then:

- Run lightningd with `bind-addr=/var/run/lightningd-tor.sock`
  and `addr=statictor:...` to advertise only the Tor v3
  onion.
- Don't publicly associate your node's pubkey or alias with
  personal identities (Twitter accounts, GitHub profile,
  etc.). Once linked, every payment you make over Lightning
  becomes potentially deanonymisable.
- Channel opens are public on the blockchain forever. Be
  thoughtful about who you peer with.

## Operational checklist

```sh
# Initial install (one-time)
lightning daemon enable --trustedcoin       # or run bitcoind yourself
lightning daemon start
lightning peer bootstrap -n 10
lightning wallet init

# Open channels (manual — pick wisely per the strategy above)
lightning wallet balance --on-chain
# fund the on-chain address printed; wait for confirmations
# open 5-10 anchor channels of 5-20M sat each
# open 10-30 smaller channels of 1-5M sat each

# Fees (one-time setup)
lightning plugin install feeadjuster
lightning fee policy balanced --apply
# Then per-channel overrides for anchor + one-directional channels.

# Plugins (one-time)
lightning plugin install rebalance
lightning plugin install clnrod
lightning plugin install prometheus      # for Grafana dashboards

# Monitoring (one-time)
lightning alert create peer-down       --on peer_offline       --webhook <url>
lightning alert create channel-stuck   --on channel_ratio_outside --threshold 5,95 --webhook <url>
lightning alert create low-inbound     --on low_inbound_capacity  --threshold 5000000 --webhook <url>
lightning alert create daemon-died     --on daemon_down --cooldown 5m --webhook <url>

# Backup configuration (one-time)
git -C ~/.lightning/wallet/default remote add backup git@server2:wallet.git
# crontab: hourly `lightning channel scb emit` + `lightning wallet push backup`

# Day-to-day (rare — alerts surface what needs attention)
lightning daemon status
lightning liquidity                    # totals
lightning fee get | recsel              # filter to channels of interest
lightning channel pending
lightning ledger statement --account routing --period 2026-05

# Quarterly review (calendar item)
lightning-cli listforwards | jq '...'   # which channels actually moved sats
# close stale channels, open replacements
# adjust per-channel fee overrides
# audit alert rules — kill noisy ones, add new conditions
```

## See also

- [Personal-node guide](personal-node.md) — start here if
  you haven't already run a small node.
- `lightning(1)` man page.
- BOLT 7 (routing gossip): `share/doc/lightning/standards/
  bolts/07-routing-gossip.md`.
- Plebnet Discord, BOSScore, Amboss — operator-community
  references.
- balanceofsatoshis (BOS), CLBOSS, charge-lnd — sister
  tooling in the lnd ecosystem you might also use.
