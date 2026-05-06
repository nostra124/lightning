---
id: FEAT-182
type: feature
priority: medium
status: open
---

# SIT: lightning end-to-end against per-backend regtest containers

## Description

**As a** maintainer changing lightning code
**I want** end-to-end tests against real clightning / lnd /
phoenixd nodes on regtest
**So that** the multi-backend abstraction's translators
are exercised against the actual daemons, and the
properties (channel open / pay / receive / offer / address)
are proven on each backend.

Mirrors FEAT-130 (dht), FEAT-016 (bitcoin), FEAT-118
(check), FEAT-098 (services).

## Implementation

Under `tests/sit/`:

    tests/sit/
    ├── podman/
    │   ├── Dockerfile.regtest        (bitcoind regtest base)
    │   ├── Dockerfile.clightning     (regtest + clightning)
    │   ├── Dockerfile.lnd            (regtest + lnd)
    │   └── Dockerfile.phoenixd       (regtest + phoenixd)
    ├── helpers.bash                  (multi-node fixture: spin
    │                                  up two backend instances
    │                                  + a bitcoind regtest +
    │                                  fund + connect)
    └── suites/
        ├── 01_backend_detect.bats
        ├── 02_channel_open_close.bats
        ├── 03_invoice_pay_bolt11.bats
        ├── 04_offer_pay_bolt12.bats          (clightning + lnd;
        │                                      phoenixd skipped
        │                                      with a clear msg)
        ├── 05_lnurl_flow.bats                (mock LNURL service
        │                                      in the container)
        ├── 06_address_create_pay.bats        (standalone-mode
        │                                      address daemon;
        │                                      cluster mode in
        │                                      a separate suite
        │                                      that bundles cluster
        │                                      apache)
        ├── 07_wallet_account_history.bats    (multi-account
        │                                      tagging + history
        │                                      query)
        ├── 08_wallet_push_pull.bats          (two-machine wallet
        │                                      sync)
        ├── 09_liquidity_loop.bats            (mock Loop endpoint)
        ├── 10_walkthrough.bats               (FEAT-181 lockstep)
        └── 11_softdep_probe.bats             (missing backend
                                               binary fails clearly)

`make check-sit` runs the matrix; soft-skips if `podman`
isn't available.

## Acceptance Criteria

1. `make check-sit` against all three backend dockerfiles
   runs the relevant suites to green (BOLT-12 suite skips
   phoenixd cleanly).
2. Channel open / close + invoice pay end-to-end on each
   backend.
3. LNURL + Lightning Address flows end-to-end.
4. Wallet push/pull two-machine round-trip preserves
   history.
5. Walkthrough suite verifies every step of FEAT-181.
6. Suites are deterministic over 5 runs.
