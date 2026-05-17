---
id: FEAT-177
type: feature
priority: high
status: done
---

# Lightning self-contained packaging: docs, tests, completion, CLAUDE.md

## Description

**As a** maintainer about to extract `lightning` to its own
educational rpk repo
**I want** the standard packaging artefacts in place
**So that** the extraction (FEAT-183) is mechanical.

Mirrors FEAT-125 (dht), FEAT-093 (services), FEAT-113
(check). The man page is **not** part of this ticket — it
depends on FEAT-178's vendored standards and lands as
FEAT-179.

## Implementation

Depends on FEAT-170..176.

For `bin/lightning`:

1. **Dispatcher.** `bin/lightning` is small: builtins +
   libexec lookup for verb scripts and the address daemon.
2. **`docs/lightning.md`** per FEAT-004: synopsis,
   description (the four design principles + the
   clightning focus + the wallet/account model +
   lightning addresses), every subcommand with args / env
   / exit codes, environment (`LIGHTNING_DIR`,
   `LIGHTNING_NETWORK`), files (wallet repo layout, secret
   namespacing, address daemon socket), exit codes,
   cross-script dependencies.
3. **`tests/unit/lightning.bats`** per FEAT-003: covers
   the verb surface with a mocked `lightning-cli`.
   Per-feature bats: `lightning-channel.bats`,
   `lightning-pay.bats`, `lightning-wallet.bats`,
   `lightning-address.bats`. SIT (FEAT-182) covers the
   real thing.
4. **`etc/bash_completion.d/lightning`** — context-aware
   completion at three levels: `lightning <TAB>`, `lightning
   <category> <TAB>`, `lightning <category> <verb> <TAB>`.
5. **`docs/templates/CLAUDE.md.lightning`** — already
   drafted in FEAT-170; finalise here.

## Acceptance Criteria

1. `bin/lightning`'s dispatcher is small; verb scripts
   live under `libexec/lightning/<verb>`; address daemon
   under `libexec/lightning/address-daemon`.
2. `docs/lightning.md` covers every subcommand.
3. `bats tests/unit/lightning*.bats` passes.
4. Tab completion works at three levels.
5. `docs/templates/CLAUDE.md.lightning` is finalised.
