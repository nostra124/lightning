---
id: FEAT-173
type: feature
priority: high
status: open
---

# Lightning: payment / invoice / BOLT-12 / LNURL verbs

## Description

**As a** Lightning user
**I want** consistent commands to create invoices, pay
invoices (BOLT-11), receive offers (BOLT-12), and
interact with LNURL services
**So that** every common Lightning flow is one verb away
via clightning.

## Implementation

### Payment + invoice (BOLT-11)

    lightning invoice <sat> <label> [--expiry <sec>] [--description <text>]
                                                  # returns BOLT-11 invoice
    lightning pay <bolt11>                        # pay a BOLT-11 invoice
    lightning send <node-id> <sat> [--message <text>]
                                                  # keysend
    lightning decode <bolt11>                     # parse + display

### BOLT-12 offers (newer, async-payments-friendly)

    lightning offer <sat> <description>           # create a reusable offer
    lightning offers                               # list this node's offers
    lightning offer-pay <bolt12-offer>            # pay an offer
                                                  # (fetches invoice
                                                  #  via the offer's RGS)
    lightning offer-revoke <offer-id>

(clightning has first-class BOLT-12 support via
`fetchinvoice` / `offer`.)

### LNURL (LUDs)

    lightning lnurl decode <lnurl>                # decode + display
    lightning lnurl pay <lnurl-or-address> <sat> [--comment <text>]
                                                  # LNURL-pay flow
    lightning lnurl withdraw <lnurl> <sat>        # LNURL-withdraw
    lightning lnurl auth <lnurl>                  # LNURL-auth (LUD-04)

### Decode helpers

`lightning decode <whatever>` is a smart wrapper that
detects BOLT-11 / BOLT-12 / LNURL / lightning-address and
dispatches.

### Wallet-side accounting

Every successful pay / receive writes a row into the wallet
ledger (FEAT-193's `ledger.tsv`) with timestamp, amount,
account label, counterparty (if known), and the invoice /
offer / lnurl source. Available for query via
`lightning ledger list` (FEAT-193).

### Help / man-page citations

Each verb cites its BOLT or LUD reference (FEAT-178 /
FEAT-179).

## Acceptance Criteria

1. `lightning invoice 1000 'beer'` produces a BOLT-11
   invoice; `lightning pay <bolt11>` from a peer pays it
   on regtest.
2. `lightning offer 500 'donations'` creates a BOLT-12
   offer; `lightning offer-pay <offer>` from a peer pays
   against it.
3. `lightning lnurl pay <test-lnurl> 100` resolves and
   pays.
4. `lightning decode` correctly identifies + dispatches
   each format.
5. SIT (FEAT-182) covers happy paths for BOLT-11, BOLT-12,
   and LNURL on the clightning regtest container.
