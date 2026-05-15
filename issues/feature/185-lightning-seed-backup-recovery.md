---
id: FEAT-185
type: feature
priority: high
status: open
---

# Lightning seed backup & recovery

## Description

**As a** non-custodial Lightning user
**I want** `lightning seed {export,import,verify}` and
`lightning scb {emit,restore}` (static channel backups)
**So that** I can recover my funds from a clean machine using
only my seed phrase + the latest SCB.

Two distinct artefacts:

- **Seed** — clightning's `hsm_secret`, optionally
  represented as a BIP-39 mnemonic via `hsmtool generatehsm
  / dumponchaindescriptors`. Encrypted with the HSM
  password.
- **SCB** — static channel backup blob. Encrypted with the
  seed-derived key. Updated on every channel open / close.
  Restoring an SCB triggers force-closes by peers to release
  on-chain funds; it does **not** restore channel state.

The wallet (FEAT-174) stores SCB snapshots in its git history;
`scb emit` is wired to FEAT-172's channel-change hook so every
open/close auto-commits a fresh SCB.

## Implementation

1. **`lightning seed export`** — writes the mnemonic to stdout
   (read once, scary banner). Optionally `--out <file>` writes
   to a path readable only by the user.
2. **`lightning seed import`** — interactive: prompts for
   mnemonic, initialises a fresh `hsm_secret` via `hsmtool
   generatehsm`.
3. **`lightning seed verify`** — checksum + asks the user to
   re-type 2 random words.
4. **`lightning scb emit [--out <file>]`** — writes a fresh
   SCB. Default destination: the wallet's `scb/` directory
   (auto-commits if FEAT-174 is in play).
5. **`lightning scb restore <file>`** — initiates SCB recovery
   against an unlocked daemon. Prints expected force-close
   timeline.

## Acceptance Criteria

1. `lightning seed export` round-trips through
   `lightning seed import` on a fresh daemon — same node id.
2. `lightning scb emit` after every channel state change is
   automatic (hook fires from FEAT-172 verbs).
3. `lightning scb restore` triggers visible force-closes
   against a regtest peer.
4. Seed export refuses to run if the daemon is locked.
5. Help text cites the BOLT-relevant background (BOLT 02 §
   channel state, clightning's `emergency.recover`
   documentation).
