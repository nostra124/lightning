---
id: FEAT-172
type: feature
priority: high
status: open
---

# Lightning: channel management verbs

## Description

**As a** Lightning user
**I want** consistent commands to open, list, close, and
adjust channels via clightning
**So that** I can manage routing capacity without learning
each daemon's CLI dialect.

## Implementation

Subcommands at top level of `lightning`, implemented as verb
scripts under `libexec/lightning/channel-*` (FEAT-171 idiom):

    lightning channel list                       # all channels
    lightning channel open <node-uri> <sats> [--push <sats>]
    lightning channel close <channel-id>          # cooperative
    lightning channel force-close <channel-id>    # unilateral; warn
    lightning channel balance [<channel-id>]      # local / remote
    lightning channel fee-update <channel-id> <base-msat> <ppm>
    lightning channel info <channel-id>
    lightning channel pending                     # opening / closing
    lightning channel rebalance <out-id> <in-id> <amount>
                                                  # circular self-payment

### `<node-uri>` format

`<pubkey>@<host>:<port>` — standard Lightning peer URI.

### Funding source

`channel open` requires on-chain funds. clightning handles
the on-chain transaction via its built-in wallet; if the
wallet is empty, the command fails clearly with a "fund the
LN node's on-chain wallet first" message and a hint to send
to `lightning balance --on-chain` (which prints the on-chain
receive address from clightning's `newaddr`).

For multi-wallet setups using `bitcoin wallet` (FEAT-010),
a future ticket can wire `bitcoin wallet send-to lightning`
as a one-shot. Out of scope here.

### Force-close warnings

`force-close` requires `--confirm` since it costs the timeout
fee and locks funds for the CSV delay. A loud warning on
invocation lists the cost.

## Acceptance Criteria

1. `lightning channel open <node-uri> 100000` opens a 100k
   sat channel; `lightning channel list` shows it pending,
   then active after confirmations.
2. `lightning channel close <id>` cooperatively closes a
   channel; `lightning channel pending` shows it during
   the close period.
3. `lightning channel rebalance` succeeds for valid input
   against a clightning regtest.
4. Verb output shape is stable across releases.
5. SIT (FEAT-182) covers open / close / list / balance on
   the clightning regtest container.
