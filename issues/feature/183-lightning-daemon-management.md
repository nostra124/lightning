---
id: FEAT-183
type: feature
priority: high
status: open
---

# Lightning daemon lifecycle management

## Description

**As a** user of `lightning`
**I want** `lightning daemon {start,stop,restart,status,logs}`
verbs that drive lightningd
**So that** running a Lightning node doesn't require knowing
the right `lightningd` flags, the right systemd unit shape,
or where the logs go.

Wraps `lightningd --daemon`. Help text cites the upstream
command being wrapped.

## Implementation

1. Verbs under `libexec/lightning/`:
   - `daemon-start` — `lightningd --daemon` with config from
     `LIGHTNING_DIR` (or default `~/.lightning`)
   - `daemon-stop` — `lightning-cli stop` (graceful)
   - `daemon-restart` — stop + start
   - `daemon-status` — process alive? RPC reachable? chain
     synced? wallet unlocked?
   - `daemon-logs` — tail `<lightning-dir>/log`
2. **`lightning daemon install`** generates a systemd user
   unit at `~/.config/systemd/user/lightning.service` for
   opt-in supervised running. Idempotent.
3. **Health checks** in `status`: process alive + RPC
   reachable + chain synced + wallet unlocked.
4. **Auto-unlock hook** — if a stored unlock secret exists
   (FEAT-184), `daemon-start` invokes it after lightningd
   reports the HSM wants a password.

## Acceptance Criteria

1. `lightning daemon start` brings up lightningd in the
   background.
2. `lightning daemon status` returns a one-line summary +
   non-zero exit if not healthy.
3. `lightning daemon logs -f` tails the live log.
4. `lightning daemon install` generates a systemd user unit
   that survives `loginctl enable-linger`.
5. Tests cover the verbs against a mocked `lightning-cli`.
