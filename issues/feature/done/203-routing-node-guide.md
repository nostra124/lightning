---
id: FEAT-203
type: feature
priority: low
status: open
---

# Operational guide + scope expansion: 5+ BTC routing node

## Description

**As an** operator who wants to commit serious capital (5+ BTC)
to a Lightning routing node
**I want** `lightning` to be usable as the operational tool —
not just a personal wallet — and a documented strategy that
goes beyond the personal-node guide (FEAT-202)
**So that** I'm not forced to switch to lnd + balance-of-satoshis
just because I want more channels and active fee management.

This ticket has two halves:
1. The strategy document (operational guide for routing nodes).
2. The scope question — what additional `lightning` verbs /
   behaviours does the routing-node use case need?

## Part 1 — Strategy document

Lives at `share/doc/lightning/guides/routing-node.md`. Sections:

### Why run a routing node?

- Honest economics: typical 5 BTC node earns 5k-50k sat/day
  in fees ≈ 0.5-3.5% APY on capital. Worse than ETF dividends
  in most years; better than HODL during fee spikes. Treat as
  a hobby / public-good contribution unless you're at the
  10+ BTC tier with active management.
- The actual reasons people do it: community / Plebnet
  involvement, learning Lightning at depth, supporting
  decentralisation, having infrastructure for a related
  service (LSP, payment processor, exchange).

### Channel strategy at scale

- 20-50 channels typical (vs. 3-5 for personal).
- Geographic diversification (don't peer with only one
  region — outage correlation).
- Size distribution: a few "anchors" of 5-20M sat, many of
  1-5M sat for graph density.
- Outbound vs. inbound balance: aim for net ~50/50; bias
  slightly toward inbound if you're a destination for popular
  services.
- Channel acceptance policy: `clnrod` or similar to filter
  inbound channel opens (refuse junk peers).

### Fee strategy

- `feeadjuster` daemon, but with custom curves per channel
  class.
- Anchor channels: tight ppm (10-50), high base (5000+ msat).
  These are your "always-on" workhorses.
- Smaller / experimental channels: looser ppm (100-500), low
  base.
- Per-peer overrides via `lightning fee set` (FEAT-200) for
  channels that observed flows show to be one-directional.
- Quarterly review using forward stats (FEAT-188).

### Active rebalancing at scale

- Schedule `lightning rebalance` (FEAT-201) via cron / launchd
  for chronically imbalanced channels.
- Budget: 1-5% of weekly fee revenue spent on rebalancing.
- Cheaper sources: `loop` and `boltz` for big rebalances
  (>500k sat); circular for small (<100k sat).

### Monitoring and alerts

- `lightning daemon status` is the floor.
- Prometheus plugin → Grafana dashboards (peers, fees,
  forwards, balance ratios).
- Alerts: peer offline > 1h, channel ratio outside
  [10%, 90%], failed forwards > threshold, sync lag > 6h.
- See FEAT-204 (proposed) — `lightning alert` verb.

### Backup at scale

- `lightning wallet push` to a remote (existing FEAT-187).
- SCB snapshots after every channel open / close (existing
  `channel scb emit` hook).
- Off-host seed backup (printed steel plate, hardware wallet
  recovery — not in our scope).
- Quarterly disaster-recovery drill on a test node.

### Tax / accounting

- `lightning ledger export csv` (existing FEAT-193) feeds into
  Koinly / CoinTracking / your accountant.
- US: routing fees are ordinary income; FMV at receipt.
- EU: VAT treatment varies by jurisdiction; consult locally.
- Pointer to community resources, not legal advice.

### Privacy

- Tor-only or hybrid (FEAT-189 once landed).
- Don't publish your node identity alongside personal social
  media accounts.
- Channel opens are public — careful peer selection.

## Part 2 — Scope expansion: what does the tool need?

The good news: 80% of routing-node verbs are already in
`lightning`. The remaining 20%:

### Already covered

- `channel open/close/list/balance/scb` — yes
- `wallet seed/backup/restore/info/balance/peers` — yes
- `liquidity status/loop/boltz/lsp` — yes (stubs need real
  impls via FEAT-198)
- `ledger list/sum/balance/annotate/export/statement` — yes
- `daemon start/stop/install/logs` — yes (including
  trustedcoin / launchd / systemd)
- `peer list/connect/bootstrap` — yes (this PR)
- `plugin list/install/remove` — yes (this PR)

### Filed, not yet implemented

- `fee get/set/policy` — FEAT-200
- `rebalance` — FEAT-201
- `forward list/stats` — FEAT-188 (post-1.0)

### Genuinely new for routing nodes (filed in this ticket
or follow-ups)

- **`lightning alert <create|list|remove>`** — config file +
  background runner that fires webhooks (Slack / Discord /
  email / Telegram) on thresholds. Sub-ticket: FEAT-204.
- **`lightning channel autopilot`** — daemonised verb that
  combines feeadjuster + scheduled rebalance + suggested new
  channels (CLBOSS-style, scoped). Sub-ticket: FEAT-205. Belongs
  post-1.0 — needs the manual stack to be stable first.
- **`lightning peer score <node-id>`** — pull node metrics
  from Amboss / 1ML / mempool.space lightning index and report
  a one-record recfile: capacity rank, age, reachability,
  centrality. For "should I open to this node?" decisions.
  Sub-ticket: FEAT-206.

### Scope expansion question

The current README / CLAUDE.md positions `lightning` as a
"personal Lightning wallet" with routing features explicitly
out of scope. This ticket proposes:

**Option A: Same package, expanded scope.** Keep all verbs
general-purpose. Personal vs. routing is a documentation
distinction (FEAT-202 vs. FEAT-203 guides), not a code split.
Defaults stay personal-friendly; routing operators tune via
config + the verbs they actually need.

**Option B: Spin off `lightning-routing` as a sibling package.**
Wrap `lightning` with routing-specific defaults + extra verbs.
Adds package overhead, breaks the rpk "one package, one job"
principle.

**Option C: Profile flag.** `lightning --profile=routing <verb>`
or env var that flips defaults (e.g. peer bootstrap target,
fee policy default, alert thresholds). Lighter than B, more
runtime cost than A.

I recommend **A** — most routing-node-specific behaviour is
already enabled by the verbs we have. Documentation does the
heavy lifting. New verbs (alert, autopilot, score) get filed
as their own tickets and built incrementally; they're useful
to personal nodes too (just less often).

## Acceptance Criteria

For Part 1 (the doc):
1. File exists at `share/doc/lightning/guides/routing-node.md`.
2. Cross-links to FEAT-202 personal-node guide ("step up
   from a personal node").
3. Every command in the guide either exists or has a filed
   FEAT- ticket.
4. Economics section cites Plebnet / BOSScore / Amboss
   surveys with dates.
5. Linked from man page and README.

For Part 2 (the scope decision):
1. Decide A / B / C and record the decision in CLAUDE.md
   ("Scope" section needs an update).
2. File the follow-up FEAT- tickets (alert, autopilot, score).
3. Update FEAT-188 if it's superseded by the new tickets.

## Milestone

- Strategy doc: 0.7.0 (alongside the verbs it cites)
- Scope decision: now, before more code lands
- New verbs (alert / autopilot / score): post-1.0 or 0.8.0

## See also

- FEAT-202 (personal-node guide)
- FEAT-200, FEAT-201 (verbs the routing guide depends on)
- FEAT-188 (forward analytics, may be absorbed here)
- Plebnet Discord, BOSScore, Amboss, balanceofsatoshis (BOS)
  — operator community references
