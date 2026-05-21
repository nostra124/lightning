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

> **Update:** FEAT-206 shipped (`libexec/lightning/peer score`).
> FEAT-198 remains the open work item.

Remaining tickets:

1. **FEAT-198 — real LSPS1 inbound liquidity** — deferred
   from 0.7.0. Replace the `liquidity in` / `liquidity lsp
   buy` stubs with the full LSPS0 -> LSPS1 protocol flow
   (discover, quote, order, pay, await-channel). Either
   hand-rolled over `sendcustommsg` or wrapped around a
   third-party LSPS1 client plugin. Research-heavy: pick a
   target LSP first.
2. **Cycle-end polish** — anything operational learned
   running the 0.7.0 verbs in practice (fee curves, alert
   conditions, rebalance heuristics).

## Dependency Order

Cycle-end polish lives on top of 6-12 weeks of real-world
0.7.0 usage feedback — the milestone shouldn't ship until
at least one operator has run the 0.7.0 stack continuously
for a month.

## Exit Criteria

- `lightning liquidity in <amount>` and
  `liquidity lsp <name> buy <amount>` open a real inbound
  channel via LSPS1 against at least one tested LSP.
- Polish items captured as FEAT- tickets and resolved (or
  consciously deferred to 1.0+).
- `.rpk/version` bumped 0.7.0 → 0.8.0; ledger updated.
- FEAT-198 moves to `issues/feature/done/`.

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
