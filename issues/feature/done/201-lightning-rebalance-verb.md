---
id: FEAT-201
type: feature
priority: medium
status: open
---

# `lightning rebalance` — circular self-payment + swap fallback

## Description

**As a** node operator with a channel stuck on one side
**I want** `lightning rebalance <amount> [flags]` to redistribute
liquidity via a circular self-payment, falling back to a
submarine swap when no LN route exists
**So that** I can fix a stuck channel without learning the
mechanics of `sendpay` / `getroute` / Boltz / Loop by hand.

Active rebalancing is tier-3 in the operational guide
(FEAT-202): when `feeadjuster` + organic forwarding can't
balance a channel, this verb is the manual escape hatch.
Expensive enough that we don't run it from cron — operator's
explicit decision.

## Implementation

### Surface

```
lightning rebalance <amount-sat> [--from <chan>] [--to <chan>]
                                 [--max-fee-ppm N] [--max-fee-sat N]
                                 [--dry-run]
                                 [--fallback swap|none]
```

- `<amount-sat>` — sats to move out of `--from`, in via `--to`.
- Channel selection:
  - With both `--from` and `--to`: that exact pair.
  - With just `--from`: pick the most-incoming-capacity counter-
    party as `--to`.
  - With neither: pick the most-asymmetric pair (highest
    outbound vs. lowest outbound) — the rebalance with the most
    leverage.
- Fee caps: `--max-fee-ppm` (default 500, i.e. 0.05%), OR
  `--max-fee-sat` (absolute). Whichever is lower wins.
- `--dry-run`: print the chosen route + estimated cost, don't pay.
- `--fallback`:
  - `swap` (default) — if LN circular fails, try `liquidity loop`
    or `liquidity boltz` for the same amount. Reports both LN
    and swap costs so the operator can decide.
  - `none` — LN-only; exit non-zero if no LN route.

### Mechanics

Under the hood, two paths:

**LN circular** (preferred when a route exists):
1. `getroute` from our node id, exclude/include the right channels
   to force `from`→…→`to`.
2. `invoice` for `<amount>` to ourselves (or use the
   `rebalance` plugin's `keysend`-self primitive).
3. `sendpay` with the constructed route + payment_hash.
4. On success, log the route, the fees paid, and the resulting
   balance shift.

**Swap fallback** (when no LN route):
1. `lightning liquidity loop out <amount>` (or `boltz out`) to
   drain `--from`.
2. `lightning liquidity loop in <amount>` (or `boltz in`) to
   fill `--to`.
3. Net cost = swap fees + on-chain fees.

### Relation to the `rebalance` plugin

The lightningd/plugins `rebalance` plugin is the upstream
reference impl of the LN-circular path. Our verb is a wrapper —
prefer the plugin's `rebalance` RPC when installed, fall back to
hand-rolled `getroute`+`sendpay` otherwise.

Detection: `lightning-cli plugin list | grep rebalance`.

### Output

Recfile-style summary, always:

```
from:          876543x12x0  (peer ACINQ)
to:            123456x7x1   (peer LNBIG)
amount_sat:    100000
route_hops:    4
fee_msat:      234
fee_ppm:       2.34
status:        complete
```

## Acceptance Criteria

1. `lightning rebalance 100000 --from <a> --to <b> --dry-run`
   computes a route, prints the recfile summary, doesn't pay.
2. `lightning rebalance 100000` (no flags) picks the most
   asymmetric channel pair automatically.
3. `--max-fee-ppm 500` aborts if the cheapest route costs more,
   reports the cheapest route found in the summary.
4. `--fallback swap` falls back to `liquidity loop|boltz` when LN
   has no route; reports both attempted costs.
5. Output is identical recfile shape whether LN or swap succeeds.
6. Uses the `rebalance` plugin's RPC when present, falls back to
   hand-rolled `getroute`+`sendpay` when not.
7. Bats coverage with stubbed cli responses.

## Out of scope

- Periodic / scheduled rebalancing (cron-driven autopilot) —
  belongs in a future `channel autopilot` verb, not here.
- JIT rebalancing during forward events — was the deprecated
  `jitrebalance` plugin's job, not worth resurrecting given how
  rarely a small node can actually profit from it.

## Milestone

0.7.0 (operational hardening, alongside FEAT-200).

## See also

- `rebalance` plugin (the upstream RPC)
- FEAT-200 (`fee` verb — passive layer, runs first)
- FEAT-175 / FEAT-198 (`liquidity loop|boltz|lsp` — swap fallback)
- FEAT-202 (personal-node operational guide)
