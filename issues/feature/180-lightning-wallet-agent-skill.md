---
id: FEAT-180
type: feature
priority: medium
status: open
---

# `lightning-wallet` agent skill

## Description

**As a** user delegating Lightning tasks to an AI agent
**I want** a packaged skill that teaches the agent the
multi-backend model, the wallet/account abstraction, the
liquidity layer, and the Lightning Address flow
**So that** an agent can manage channels, send/receive
payments, set up an address, and rebalance liquidity
without the model re-explained per session.

Mirrors FEAT-128 (dht), FEAT-019 (bitcoin-wallet), FEAT-116
(check), FEAT-096 (services-user).

## Implementation

Layout:

    skills/
    └── lightning-wallet/
        ├── SKILL.md
        └── opencode.md

`SKILL.md` frontmatter:

    ---
    name: lightning-wallet
    description: Operate a Lightning Network wallet via
      the `lightning` toolkit — open / close / rebalance
      channels, pay / receive via BOLT-11 / BOLT-12 /
      LNURL / Lightning Address, manage labelled accounts
      in the git-backed wallet repo, configure liquidity
      providers (Loop / Boltz / LSP). Trigger when the
      user wants to move sats over Lightning, set up an
      address, or learn how the design (educational,
      functional, decentralized, simple) maps onto a
      specific BOLT / LUD / BLIP.
    ---

`SKILL.md` body covers:

1. Design principles.
2. Multi-backend (clightning / lnd / phoenixd) — when each
   is chosen.
3. The git-backed wallet + labelled accounts model
   (parallel to bitcoin-wallet).
4. Workflow recipes:
   - open a channel; check capacity
   - create + pay an invoice; pay an offer
   - resolve + pay a Lightning Address
   - set up your own Lightning Address
   - rebalance via Loop / Boltz
   - tag payments to an account; query history
5. Guardrails:
   - Never log payment preimages or invoices outside the
     wallet repo.
   - `force-close` is destructive — require confirmation.
   - Liquidity ops cost fees; show the budget before
     executing.
   - Multi-backend means verb behaviour can differ subtly;
     check `lightning backend` before debugging.
6. Where to read more: `man lightning`, walkthrough
   (FEAT-181), `share/doc/lightning/standards/comparison.md`.

Installation per the established pattern.

## Acceptance Criteria

1. `skills/lightning-wallet/SKILL.md` and `opencode.md`
   exist with the sections above.
2. `make install` places the skill under standard agent
   directories.
3. `make install-skills-user` symlinks idempotently.
4. Every recipe cites the relevant BOLT / LUD / BIP /
   BLIP and links to the vendored copy.
5. The "never log preimages" guardrail is called out
   explicitly.
