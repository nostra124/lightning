# Milestone 0.8.0 — network intelligence

```
milestone: 0.8.0
title: network intelligence
status: open
depends_on: 0.7.0
```

## Summary

0.7.0 made the node manageable from the local CLI. 0.8.0
adds the next-of-network awareness — pre-channel-open
intelligence, the analytics that operators consult when
deciding *where* to open channels, and the polish that comes
from having operated the manual stack for a while.

Light milestone by design: most of the heavy work happened in
0.7.0, and we want a quick stabilisation cycle before the
1.0.0 walkthrough lands.

Two tickets:

1. **FEAT-206 — `lightning peer score <node-id>`** —
   pull node metrics from mempool.space / 1ML / Amboss,
   return a single recfile record (capacity rank, channel
   count, centrality, age, features summary).
   Pre-flight for the `channel open` decision.
2. **Cycle-end polish** — anything operational learned
   running the 0.7.0 verbs in practice (fee curves, alert
   conditions, rebalance heuristics).

## Dependency Order

FEAT-206 self-contained. Cycle-end polish lives on top of
6-12 weeks of real-world 0.7.0 usage feedback — the milestone
shouldn't ship until at least one operator has run the
0.7.0 stack continuously for a month.

## Exit Criteria

- `lightning peer score <node-id>` returns recfile from at
  least mempool.space + 1ML sources, with Amboss as an
  opt-in third when `AMBOSS_API_KEY` is set.
- Polish items captured as FEAT- tickets and resolved (or
  consciously deferred to 1.0+).
- `.rpk/version` bumped 0.7.0 → 0.8.0; ledger updated.
- FEAT-206 moves to `issues/feature/done/`.

## Dependencies

Hard: 0.7.0 (fee/rebalance/alert/keepalive must be live for
the score data to inform real decisions).

## Out of scope (deferred to 1.0.0 or post-1.0)

- **FEAT-181 — walkthrough** — moves to 1.0.0 (already there).
- **FEAT-188 — forward analytics** — post-1.0
  (routing-node-only, low priority for personal-wallet 1.0).
- **FEAT-205 — channel autopilot** — post-1.0
  (depends on having run 0.7.0 manually for 3-6 months to
  inform what the policy should be).
- **FEAT-186 — watchtowers** — post-1.0 (separate scope).
