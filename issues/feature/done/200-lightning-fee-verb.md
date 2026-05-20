---
id: FEAT-200
type: feature
priority: medium
status: open
---

# `lightning fee <get|set|policy>` — per-channel fee management

## Description

**As a** node operator (personal or routing)
**I want** a `lightning fee` verb to inspect and set per-channel
base+ppm fees, and to apply named policies like "balanced" that
auto-tune fees from liquidity
**So that** my channels self-balance through passive fee tuning
without me having to remember `setchannel` + the right ppm math
on every channel change.

Promoted from FEAT-188 (which was post-1.0 routing-node-only) —
passive fee tuning is the cheapest and most effective rebalancing
mechanism for personal nodes too, so it belongs in 0.7.0
alongside the other operational improvements.

## Implementation

### Surface

```
lightning fee get [<channel-id>]                     # recfile per channel
lightning fee set <channel-id> <base-msat> <ppm>     # one channel
lightning fee policy [<name>] [--apply]              # show / apply policy
```

#### `fee get`

Without args: one record per channel (recfile), separated by
blank lines. With `<channel-id>`: just that channel.

```
channel_id:    876543x12x0
peer:          ACINQ
local_sat:     500000
remote_sat:    500000
base_msat:     1000
ppm:           150
htlc_min_msat: 1
htlc_max_msat: 990000000
```

Pulls from `lightning-cli listpeerchannels`.

#### `fee set`

Direct wrapper over `lightning-cli setchannel <id> <base> <ppm>`.
Re-broadcasts the channel_update with the new fee. Effective
immediately for new HTLCs.

#### `fee policy`

Named fee policies. Each is a function `(local_sat, capacity_sat)
-> (base, ppm)`:

- **flat** — fixed `base=1000 ppm=100` on every channel (CLN default)
- **balanced** — sigmoid curve on liquidity ratio:
  - 100% local (full outbound) → low fees (encourage spend)
  - 50/50 → medium fees
  - 0% local (depleted) → high fees (discourage spend, attract inbound)
- **lsp** — high base, low ppm; biased for small-payment LSP routing
- **match-peer** — read the peer's outgoing fee on the channel
  (via `listchannels`) and match it. Useful when one side is
  setting the policy and you just want to be neutral.

Without `--apply`: print the policy's per-channel outcome as a
recfile (dry run). With `--apply`: actually call `setchannel`
for each channel where the new value differs from the current.

### Relation to the `feeadjuster` plugin

`feeadjuster` (in lightningd/plugins) is the event-driven version
of the `balanced` policy: it recomputes fees on every forward
event. Our `lightning fee policy balanced --apply` is the
"one-shot recompute now" verb; `feeadjuster` is the daemon.

Recommended setup, documented in the personal-node guide
(FEAT-202):

1. `lightning plugin install feeadjuster` (continuous)
2. `lightning fee policy balanced --apply` (initial sync;
   feeadjuster takes over from there)
3. `lightning fee get` to inspect, `lightning fee set` for
   manual overrides on specific channels.

## Acceptance Criteria

1. `lightning fee get` returns one recfile record per channel,
   pulled from `listpeerchannels`.
2. `lightning fee get <channel-id>` returns just that channel
   (single record, no trailing blank line).
3. `lightning fee set <id> <base> <ppm>` calls `setchannel` and
   exits 0 on success; clear error on bad channel-id.
4. `lightning fee policy balanced` (no --apply) prints the
   policy's intended values for every channel, recfile format,
   doesn't change anything.
5. `lightning fee policy balanced --apply` calls `setchannel`
   for each channel where the new value differs.
6. `lightning fee policy match-peer --apply <channel-id>` only
   updates the specified channel.
7. `lightning fee --help` and per-subcommand help (rpk style).
8. Bats coverage with stubbed `setchannel` calls.

## Out of scope

- Forwarding analytics (`lightning forward list / stats`) —
  stays in FEAT-188, post-1.0 routing-node scope.
- Auto-detection of which policy to use — operator chooses.

## Milestone

0.7.0 (operational hardening).

## See also

- `feeadjuster` plugin (the continuous-mode complement to the
  policy verb)
- FEAT-188 (forwarding analytics, post-1.0)
- FEAT-201 (`rebalance` verb)
- FEAT-202 (personal-node operational guide)
