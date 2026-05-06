---
id: FEAT-175
type: feature
priority: medium
status: open
---

# Lightning: liquidity layer (Loop / Boltz / generic LSP)

## Description

**As a** Lightning user
**I want** common verbs for managing channel liquidity
through the major providers (Lightning Loop, Boltz,
generic LSPs like Phoenix / Voltage / etc.)
**So that** rebalancing inbound / outbound is a one-liner
without fighting each provider's REST API by hand.

## Implementation

### Verbs

    lightning liquidity status              # inbound / outbound capacity
                                             # per channel + total
    lightning liquidity in <amount>         # acquire inbound (any provider)
    lightning liquidity out <amount>        # acquire outbound

    lightning liquidity loop in|out <amount>     # Lightning Loop
    lightning liquidity boltz in|out <amount>    # Boltz
    lightning liquidity lsp <name> <verb>        # generic LSP
                                                  # (Phoenix / Voltage / ...)

`liquidity in / out` (no provider named) chooses the
configured default provider; `lightning liquidity provider
default <name>` sets it.

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
2. `lightning liquidity loop out 50000` initiates a loop-out
   on Lightning Loop's testnet endpoint and reports the
   resulting on-chain swap address.
3. Same for Boltz on its testnet endpoint.
4. `lightning liquidity lsp <name> <verb>` works against an
   LSPS1-compliant test LSP.
5. Every liquidity operation appears in `lightning history`
   with provider + fee + outcome.
6. SIT (FEAT-182) covers loop + boltz against testnet
   endpoints (with mocking where the test endpoints don't
   support automation).
