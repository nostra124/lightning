---
id: FEAT-184
type: feature
priority: high
status: done
---

# Lightning wallet unlock

## Description

**As a** user of `lightning`
**I want** a `lightning unlock` verb that releases
clightning's wallet (the HSM encryption-password flow) and
stores the secret via the `secret` package
**So that** daemon restart is automatic and key material never
has to live in shell history.

Non-custodial-by-default: the secret never leaves the user's
machine. Hardware-signer support via clightning's
`--remote-hsmd` is a forward-looking sub-feature.

## Implementation

1. **`lightning unlock`** — interactive: prompts for
   password, feeds it to clightning's `hsmtool` /
   HSM-encryption flow, stores the password via
   `secret put lightning.<wallet>.unlock`.
2. **`lightning unlock --stored`** — non-interactive: pulls
   the stored secret and unlocks. Called by FEAT-183's
   `daemon-start` after restart.
3. **`lightning unlock rotate`** — change password; updates
   both clightning's HSM and the `secret` store atomically.
4. **`lightning unlock forget`** — drops the stored secret so
   future restarts prompt the user.
5. **Hardware-signer hook** — `lightning unlock --signer=<id>`
   delegates to a configured external HSM via clightning's
   `--remote-hsmd`. Scope-limited: only the contract is
   defined here; full integration deferred to a follow-on.

## Acceptance Criteria

1. `lightning unlock` succeeds against a fresh encrypted
   `hsm_secret`.
2. Stored unlock survives `daemon restart` via FEAT-183.
3. `lightning unlock rotate` succeeds end-to-end.
4. Forgotten secrets are not recoverable from disk after
   `unlock forget`.
5. Help text cites the clightning HSM encryption mechanism
   (`lightningd-hsmtool`).
