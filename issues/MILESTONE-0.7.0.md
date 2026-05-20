# Milestone 0.7.0 — operational hardening

```
milestone: 0.7.0
title: operational hardening
status: shipped (2026-05-20, .rpk/version 0.7.0)
depends_on: 0.6.0
```

> **Shipped state**: 6 of 7 tickets landed (FEAT-199, 200, 201,
> 202, 203, 204). FEAT-198 (real LSPS1 inbound) deferred to
> MILESTONE-0.8.0 — needs research on current LSPS1 client
> tooling + a target LSP to integrate against. The `liquidity in`
> / `liquidity lsp buy` stubs remain in place; the personal-node
> guide flags this as a known gap until the implementation lands.
>
> Strictly, the milestone graph said 0.7.0 `depends_on: 0.6.0`,
> but 0.6.0 (packaging / standards / man-page) didn't ship first
> — the operational verbs were higher-leverage given the
> discussion that prompted this milestone. 0.6.0 remains a
> tracked target.

## Summary

0.5.0 closed the verb surface. 0.6.0 makes the package
self-describing (docs, man page, standards). 0.7.0 turns it
from "the verbs exist" into "the node actually stays useful
without the operator babysitting it" — passive fee tuning,
active rebalancing on demand, threshold-driven alerts, peer
persistence across network outages, real LSP-driven inbound
liquidity acquisition, and the operational guide that ties
the four-tier strategy together.

Filed in the wake of the `lightning peer list` empty-output
discussion (PR #11): if the tool is going to cover both
personal-wallet and small-to-medium routing-node use cases
(FEAT-203 scope decision, CLAUDE.md §1), the missing piece is
day-to-day operational ergonomics.

Seven tickets:

1. **FEAT-198 — real LSPS1 inbound liquidity** — replace the
   `liquidity in / lsp buy` stubs with the full LSPS0 →
   LSPS1 protocol flow (discover, quote, order, pay,
   await-channel). Either hand-rolled over `sendcustommsg`
   or wrapped around a third-party LSPS1 client plugin.
2. **FEAT-199 — peer keepalive + `--important-peer`** —
   primary: `peer bootstrap` + `daemon install` append a
   managed `important-peer=<uri>` block to
   $LIGHTNING_DIR/config. Fallback: `peer keepalive` timer
   + launchd `NetworkState` hook for the laptop-sleep case.
3. **FEAT-200 — `lightning fee <get|set|policy>`** —
   per-channel base+ppm management, named policies (flat,
   balanced, lsp, match-peer). The "balanced" policy is the
   one-shot equivalent of the `feeadjuster` plugin's
   continuous mode.
4. **FEAT-201 — `lightning rebalance <amount>`** — circular
   self-payment with submarine-swap fallback. Wraps the
   upstream `rebalance` plugin's RPC when present;
   hand-rolled `getroute`+`sendpay` when not.
5. **FEAT-202 — personal-node operational guide** —
   `share/doc/lightning/guides/personal-node.md`. Four
   tiers (channel selection → passive fees → active
   rebalance → liquidity acquisition) with concrete numbers
   and an honest economics section.
6. **FEAT-203 — routing-node guide** —
   `share/doc/lightning/guides/routing-node.md`. The 5+ BTC
   companion to the personal-node guide. Cross-links to
   FEAT-204 alert + FEAT-200/201.
7. **FEAT-204 — `lightning alert <create|list|remove>`** —
   threshold-driven webhooks (Slack / Discord / Telegram /
   email / generic POST). Same sidecar scheduling pattern
   as the FEAT-199 keepalive.

## Dependency Order

FEAT-199 first (small, unblocks the laptop-sleep frustration
that prompted this milestone). FEAT-200 + FEAT-201 in
parallel (independent verbs, both wrap upstream plugins).
FEAT-198 alongside (LSPS1 work is largely orthogonal).
FEAT-204 after FEAT-199 (shares the sidecar scheduler
implementation). FEAT-202 + FEAT-203 last — written against
verbs that exist + work, with tested examples.

## Exit Criteria

- `lightning peer bootstrap` writes a managed
  `important-peer=` block to $LIGHTNING_DIR/config;
  re-runs are idempotent; lightningd restart picks them up.
- `lightning peer keepalive` runs from launchd / systemd
  sidecar; tops up peer count when below threshold.
- `lightning fee get / set / policy [balanced|flat|lsp|
  match-peer]` work and reflect via `lightning-cli
  setchannel` / `listpeerchannels`.
- `lightning rebalance <sat>` moves liquidity via LN
  circular when a route exists; falls back to
  `liquidity loop / boltz` swap on `--fallback swap`.
- `lightning liquidity in <amount>` and `liquidity lsp
  <name> buy <amount>` actually open a real inbound channel
  via the LSPS1 protocol against at least one tested LSP.
- `lightning alert create <name> --on <condition> --webhook
  <url>` writes a recfile rule; `alert run` evaluates rules
  and fires webhooks; sidecar wired in `daemon install`.
- `share/doc/lightning/guides/personal-node.md` and
  `routing-node.md` ship, linked from `lightning(1)` and
  README; every command in them either exists or has a
  filed FEAT- ticket.
- Unit test contract extended (fee/rebalance/alert/keepalive
  verbs; LSPS1 path with stubbed LSP).
- `.rpk/version` bumped 0.6.0 → 0.7.0; ledger updated.
- FEAT-198, 199, 200, 201, 202, 203, 204 move to
  `issues/feature/done/`.

## Dependencies

Hard: 0.6.0 (man page + standards + Tor referenced by guides).
Soft: 0.5.0 surface assumed stable.

## Out of scope (deferred to 0.8.0 or later)

- **FEAT-198 — real LSPS1 inbound liquidity** — DEFERRED
  to 0.8.0. Research-heavy: needs decisions on which LSP to
  target first and whether to wrap an existing LSPS1 client
  plugin or hand-roll over `sendcustommsg`.
- **FEAT-205 — channel autopilot** — daemonised
  fee+rebalance+suggest loop. Explicitly post-1.0: needs
  3-6 months of operator experience with the manual stack
  first to know what the policy should be.
- **FEAT-206 — `peer score <node-id>`** — pre-channel-open
  intelligence via Amboss / 1ML / mempool.space. 0.8.0.
- **FEAT-188 — forward analytics** (`forward list / stats`)
  — useful but routing-node-only. Post-1.0.
