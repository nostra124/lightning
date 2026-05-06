---
id: FEAT-181
type: feature
priority: medium
status: open
---

# Lightning walkthrough: clightning on regtest, channel, pay, address, Loop

## Description

**As a** new user of `lightning`
**I want** a walkthrough that takes me from a fresh
clightning install to a working Lightning Address with a
paid invoice, channel opened, and a Loop-out demonstrating
liquidity management
**So that** the educational value is concrete in 30
minutes.

Mirrors FEAT-129 (dht), FEAT-015 (bitcoin), FEAT-117
(check), FEAT-097 (services).

## Implementation

`docs/lightning-walkthrough.md` walks through:

1. **Setup.** Spin up bitcoind on regtest, then clightning
   (or lnd) connected to it. Confirm `lightning backend
   auto` picks clightning. Mine some regtest blocks +
   fund the LN node's on-chain wallet. Cite BOLT-1 for the
   protocol model.

2. **Create a wallet.** `lightning wallet new alice`,
   create accounts (`personal`, `donations`).

3. **Open a channel.** Spin up a second clightning node
   (peer); `lightning channel open <peer-uri> 1000000`.
   Mine confirmations. `lightning channel list` shows it
   active. Cite BOLT-2.

4. **Pay an invoice.** From peer, `lightning invoice 5000
   'beer'`. From alice, `lightning pay <bolt11>`. Cite
   BOLT-11.

5. **BOLT-12 offer.** From peer, `lightning offer 1000
   'tip jar'`. From alice, `lightning offer-pay <offer>`.
   Cite BOLT-12.

6. **LNURL.** Pay against a public testnet LNURL (or a
   mocked endpoint). Cite LUD-06.

7. **Lightning Address.** Set up `alice@<test-domain>` —
   either via `cluster apache` (if running) or the
   standalone `lightning address daemon`. From peer,
   `lightning address pay alice@<test-domain> 100`.
   Cite the Lightning Address spec + BIP-353.

8. **Liquidity (Loop).** `lightning liquidity status`;
   `lightning liquidity loop out 50000` to a regtest-
   compatible Loop endpoint (or mock). Cite the Loop
   protocol summary.

9. **Wallet sync.** Set up alice on a second machine via
   `lightning wallet pull` — show the history travels.

Each section ends with "what just happened" + the cited
spec + the local path under
`share/doc/lightning/standards/`.

## Acceptance Criteria

1. `docs/lightning-walkthrough.md` exists and covers all
   nine sections.
2. A new user with regtest bitcoind + clightning follows
   it end to end and reaches a working Lightning Address
   + paid invoice + Loop swap without consulting other
   docs.
3. Each step cites the relevant vendored standard.
4. Every command exercised by `tests/sit/` (FEAT-182).
