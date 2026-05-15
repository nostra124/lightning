---
id: FEAT-175
type: feature
priority: medium
status: open
---

# Lightning: liquidity layer (Loop / Boltz / generic LSP)

## Description

**As a** Lightning user who wants to **receive** payments
**I want** common verbs for acquiring inbound liquidity
through the major providers (Lightning Loop, Boltz, LSPS1
channel-purchase against any LSP) — plus the symmetric
outbound case
**So that** "I can receive up to N sat" stops being a
mystery and "rebalancing" is a one-liner without fighting
each provider's REST API by hand.

Inbound liquidity is the limiting factor for any node that
wants to receive: a fresh node opened by you has zero
inbound capacity. This ticket's primary user story is "buy
inbound from an LSP"; outbound is the symmetric secondary
case.

## Implementation

### Verbs

    lightning liquidity status              # inbound / outbound capacity
                                             # per channel + total
    lightning liquidity in <amount>         # acquire INBOUND (any provider)
    lightning liquidity out <amount>        # acquire OUTBOUND

    lightning liquidity loop in|out <amount>     # Lightning Loop
    lightning liquidity boltz in|out <amount>    # Boltz
    lightning liquidity lsp <name> buy <amount>  # LSPS1 channel purchase
    lightning liquidity lsp <name> <verb>        # LSPS-specific verbs

`liquidity in / out` (no provider named) chooses the
configured default provider; `lightning liquidity provider
default <name>` sets it.

### A note on direction (educational)

The terms get inverted depending on whose perspective. From
`lightning`'s user-facing view:

- `liquidity in`  = I want to be able to **receive** more
                    (more inbound capacity).
- `liquidity out` = I want to be able to **send** more
                    (more outbound capacity).

This maps to provider verbs as follows:

| User wants    | Loop verb | Boltz verb | LSP             |
|---------------|-----------|------------|-----------------|
| more inbound  | loop out  | reverse    | LSPS1 buy       |
| more outbound | loop in   | submarine  | (open + topup)  |

The flipped naming is a Loop-isms relic — Loop names its
verbs from the swap-service's perspective, not the user's.
Our verb names are the user's perspective; the help text
spells out the mapping.

### Provider configuration

Provider-specific config lives in the wallet repo under
`liquidity/<provider>/`:

    api-endpoint
    api-key-ref       # → secret namespace
    fee-budget-sat
    timeout-sec

Default endpoints baked in for the well-known providers
(loop.lightning.engineering, boltz.exchange, etc.); user
can override.

### LSP protocol

For "generic LSP" the tool follows BLIP-51 (LSPS1 — channel
purchase) where the provider implements it. Otherwise
fallback to provider-specific REST.

### Accounting

Every liquidity operation writes to the wallet history
(FEAT-174) with provider, fee paid, on-chain tx (if any),
new capacity.

### Soft deps

Each provider integration has its own runtime probe
(typically just `curl` for REST). Backend-required for
on-chain fallback (e.g. Loop sometimes does on-chain HTLCs).

## Acceptance Criteria

1. `lightning liquidity status` reports per-channel inbound
   + outbound capacity in sat.
2. `lightning liquidity in 100000` on a fresh node with zero
   inbound capacity acquires 100k sat of inbound via the
   default provider — `status` reflects it after the swap
   confirms.
3. `lightning liquidity lsp <name> buy 100000` against an
   LSPS1-compliant test LSP opens a channel from the LSP
   that gives 100k sat inbound (verifies the BLIP-51 path).
4. `lightning liquidity loop out 50000` initiates a loop-out
   on Lightning Loop's testnet endpoint and reports the
   resulting on-chain swap address.
5. Same for Boltz on its testnet endpoint.
6. Every liquidity operation appears in the wallet ledger
   (FEAT-193) with provider + fee + outcome.
7. SIT (FEAT-182) covers the inbound-via-LSPS1 path and
   loop + boltz against testnet endpoints (with mocking
   where the test endpoints don't support automation).
