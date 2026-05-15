---
id: FEAT-182
type: feature
priority: medium
status: open
---

# SIT: lightning end-to-end against a clightning regtest container

## Description

**As a** maintainer changing lightning code
**I want** end-to-end tests against a real clightning node
on regtest
**So that** the verbs are exercised against the actual
daemon, and the properties (channel open / pay / receive /
offer / address / inbound-liquidity) are proven against
`lightning-cli` rather than mocks.

Mirrors FEAT-130 (dht), FEAT-016 (bitcoin), FEAT-118
(check), FEAT-098 (services).

## Implementation

Under `tests/sit/`:

    tests/sit/
    ├── podman/
    │   ├── Dockerfile.regtest        (bitcoind regtest base)
    │   └── Dockerfile.clightning     (regtest + lightningd
    │                                  + lightning-cli)
    ├── helpers.bash                  (multi-node fixture:
    │                                  spin up two lightningd
    │                                  instances + a bitcoind
    │                                  regtest + fund + connect)
    └── suites/
        ├── 01_daemon_lifecycle.bats          (start/stop/status)
        ├── 02_channel_open_close.bats
        ├── 03_invoice_pay_bolt11.bats
        ├── 04_offer_pay_bolt12.bats
        ├── 05_lnurl_flow.bats                (mock LNURL service
        │                                      in the container)
        ├── 06_address_create_pay.bats        (standalone +
        │                                      local-Apache
        │                                      modes; cluster
        │                                      mode in a
        │                                      separate suite
        │                                      that bundles
        │                                      cluster apache)
        ├── 07_wallet_account_ledger.bats     (multi-account
        │                                      tagging + TSV
        │                                      ledger queries)
        ├── 08_wallet_push_pull.bats          (two-machine wallet
        │                                      sync)
        ├── 09_inbound_liquidity_lsps1.bats   (mock LSP)
        ├── 10_walkthrough.bats               (FEAT-181 lockstep)
        └── 11_softdep_probe.bats             (missing
                                               lightning-cli
                                               fails clearly)

`make check-sit` runs the suite; soft-skips if `podman`
isn't available.

## Acceptance Criteria

1. `make check-sit` against the clightning dockerfile runs
   every suite to green.
2. Channel open / close + invoice pay end-to-end.
3. BOLT-12 offer + LNURL + Lightning Address flows
   end-to-end.
4. Inbound-liquidity via mock LSPS1 LSP succeeds and
   `liquidity status` reflects the new capacity.
5. Wallet push/pull two-machine round-trip preserves the
   TSV ledger byte-for-byte.
6. Walkthrough suite verifies every step of FEAT-181.
7. Suites are deterministic over 5 runs.
