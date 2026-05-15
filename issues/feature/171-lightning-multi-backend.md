---
id: FEAT-171
type: feature
priority: high
status: open
---

# Lightning: clightning backend wiring

## Description

**As a** Lightning user
**I want** the `lightning` verb layer to talk to clightning
(Core Lightning) via `lightning-cli`
**So that** `lightning channel open …`, `lightning pay …`,
`lightning invoice …` etc. work against a local lightningd
daemon.

Scope: **clightning only**. lnd and phoenixd are out of
scope. The libexec verb-dispatch layout
(`libexec/lightning/<verb>`) leaves the door open for
future backends as additional plugin directories, but only
clightning ships today. No `lightning backend <name>` verb,
no auto-detection across implementations.

## Implementation

### Verb scripts

Each verb is a script under `libexec/lightning/<verb>` that
shells out to `lightning-cli` and reshapes the JSON output
into the project's TSV / plaintext contract. No shared
"backend helper" library — repetition is intentional per
the no-shared-lib policy.

Verbs that land in this ticket (the minimum to prove the
wiring):

    lightning node-id                       # getinfo .id
    lightning info                          # getinfo summary
    lightning peers                         # listpeers
    lightning channels                      # listchannels
    lightning balance                       # listfunds reshape

The verbs in FEAT-172 / 173 (channel open/close/pay/invoice)
follow the same pattern.

### RPC reach

`lightning-cli` defaults to talking to the unix socket at
`~/.lightning/<network>/lightning-rpc`. We honour:

    LIGHTNING_DIR        # overrides ~/.lightning
    LIGHTNING_NETWORK    # bitcoin | testnet | regtest | signet
                          # (default: bitcoin)

### Auth

Authentication is the unix-socket permission bit
(file-owner only). Rune / commando paths aren't needed for
local use; if a user wants remote `lightning-cli`, they wire
that into `lightning-cli`'s own config and we just inherit.

### Soft dep

`lightning-cli` (binary `lightning-cli`) probed at help-time
via the standard rpk pattern. Missing binary fails with a
clear "install Core Lightning (lightningd) and ensure
`lightning-cli` is on PATH" message.

## Acceptance Criteria

1. `lightning node-id` returns the same pubkey as
   `lightning-cli getinfo | jq -r .id`.
2. `lightning info` summarises getinfo in <10 lines of
   plain text.
3. `lightning channels` produces a stable TSV (header +
   one row per channel:
   `id<TAB>peer<TAB>capacity<TAB>local<TAB>remote<TAB>state`).
4. Missing `lightning-cli` produces the install hint and
   exits non-zero.
5. Verbs respect `LIGHTNING_DIR` and `LIGHTNING_NETWORK`.
6. SIT (FEAT-182) drives these verbs against a clightning
   regtest container.
