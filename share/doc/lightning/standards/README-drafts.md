# Draft Lightning standards (not yet vendored)

Per FEAT-178 §drafts. The following specs are in active
discussion upstream; we'll vendor them once they stabilise
and reach a working-group consensus.

## Watchtowers — BOLT-13 (draft)

Penalty-transaction outsourcing protocol. lnd ships a
production implementation; clightning has the
`altruistwatchtower` plugin.

- Upstream draft: <https://github.com/lightning/bolts/pull/471>
- BLIP-equivalent: not yet assigned
- Tracking ticket: FEAT-186 (post-1.0)

## Onion messages — BLIP (draft)

Sender-anonymous messaging over the Lightning routing graph.
Used by BOLT-12 `fetchinvoice` for the invoice-request
round.

- Upstream: <https://github.com/lightning/bolts/blob/master/04-onion-routing.md#onion-messages>
- The BOLT-04 §onion-messages section *is* vendored locally;
  this entry just flags that the standalone draft hasn't
  landed yet.

## LSPS2 / LSPS3 / LSPS4

Newer BLIPs in the LSP series — JIT channels, channel-buy
extensions. We vendor BLIP-50 (general framework) and
BLIP-51 (LSPS1) today; the newer ones land as needed.

- Upstream: <https://github.com/lightning/blips>

## When something here moves out of draft

1. Add a row to `UPSTREAM.txt`.
2. Run `./refresh.sh`.
3. Move the row out of this file into `README.md`.
4. Bump the citing FEAT (e.g. FEAT-186 for watchtowers) to
   reflect the new stable path.
