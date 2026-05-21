---
id: FEAT-206
type: feature
priority: low
status: shipped
---

# `lightning peer score <node-id>` — pre-channel-open intelligence

## Description

**As a** node operator considering opening a channel to a node
I haven't peered with before
**I want** `lightning peer score <node-id>` to pull rank /
reachability / centrality from public Lightning network analytics
(Amboss / 1ML / mempool.space lightning index) and report a
single recfile summary
**So that** I make informed channel-open decisions instead of
guessing from a node alias.

Pre-flight for the `channel open` decision. Useful at any scale
(a personal node opening their first channel benefits from the
same data) but more frequently consulted by routing operators
who open dozens of channels.

## Implementation

### Surface

```
lightning peer score <node-id>
                     [--source amboss|1ml|mempool|auto]
                     [--json]
```

Default source: `auto` — try mempool.space first (no auth, free
API), fall back to 1ML, then Amboss (last because some endpoints
need an API key).

### Output (recfile, single record)

```
node_id:           03864ef025fde8fb587d989186ce6a4a186895ee44a926bfc370e2c366597a3f8f
alias:             ACINQ
color:             49daaa
capacity_btc:      82.5
capacity_rank:     #14 of 8421 nodes
channel_count:     412
channel_rank:      #21
first_seen:        2018-01-17
last_seen:         2026-05-20T08:14:00Z
addresses:         3.33.236.230:9735, [redacted]:9735
features_summary:  basic_mpp, anchor, route_blinding, splice
betweenness_rank:  #8     # higher = more central in routes
closeness_rank:    #14
amboss_score:      9.4 / 10  # or "-" if source doesn't expose
warning:           none      # or e.g. "high force-close rate"
source:            mempool   # which API answered
fetched_at:        2026-05-20T13:42:18Z
```

Network ranks are out of "total nodes the source knows about" —
varies slightly between sources.

### Sources

Each source is a small bash helper that does one `curl` and
maps the response to the unified recfile schema. Add a new
source by dropping `share/lightning/score-source-<name>.sh`
with `fetch <node-id> -> recfile` semantics.

Initial three:

- **mempool.space** — `https://mempool.space/api/v1/lightning/
  nodes/<node-id>`. No auth, well-documented, includes capacity
  and channel rank.
- **1ML** — `https://1ml.com/node/<node-id>/json`. No auth.
  Older format, may degrade over time.
- **Amboss** — `https://api.amboss.space/...`. Requires API
  key (`AMBOSS_API_KEY` env var). Best data including
  reputation scores; only used when key is set.

### Caching

Results cached for 1h under `$LIGHTNING_DIR/score-cache/
<node-id>.json` (raw source response). `--no-cache` flag for
operators who want fresh data on demand.

## Acceptance Criteria

1. `peer score <node-id>` returns a recfile single record on
   success, exits 0.
2. Unknown node-id returns a clear error and exit 4 (not
   silently empty).
3. All three sources implemented and selectable via `--source`.
4. `--source auto` tries mempool → 1ml → amboss in order,
   stopping at first success.
5. `--json` flag returns the raw source JSON instead of recfile
   (escape hatch for scripts wanting full data).
6. Results cached under `$LIGHTNING_DIR/score-cache/`,
   1h TTL, `--no-cache` bypasses.
7. Help mentions the AMBOSS_API_KEY env var.
8. Bats coverage with stubbed `curl`.

## Out of scope

- Recommending nodes to open channels to (autopilot's job —
  FEAT-205).
- Historical time-series of rank changes — pull-once verb.
- API key management beyond env-var lookup. Power users can
  put it in a shell rc.

## Milestone

0.8.0 — useful but not on the critical path; depends on
external APIs which is a maintenance cost we want to land
after the core verbs (FEAT-200/201/204) are stable.

## See also

- `peer connect`, `channel open` (the verbs whose decisions
  this informs)
- FEAT-205 (autopilot — could consume this verb's data later)
- Amboss API docs: https://amboss.space/docs
- mempool.space Lightning API:
  https://mempool.space/docs/api/lightning
