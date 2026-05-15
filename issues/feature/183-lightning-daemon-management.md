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
verbs that drive the active backend daemon (lightningd / lnd /
phoenixd)
**So that** running a Lightning node doesn't require dropping
into per-daemon CLI quirks. The educational mission applies:
each verb names what the underlying daemon does and why.

The dispatcher routes per backend (FEAT-171). Each backend
plugin implements its own daemon lifecycle: lightningd is
`lightningd --daemon`; lnd is `lnd` (manual) or `systemctl`;
phoenixd has `phoenixd --background`. Help text cites the
upstream command being wrapped.

## Implementation

1. Verbs under `libexec/lightning/{clightning,lnd,phoenixd}/`:
   - `daemon-start` — start in the configured mode
     (foreground, background, systemd unit if installed)
   - `daemon-stop` — graceful shutdown
   - `daemon-restart` — stop + start
   - `daemon-status` — running? listening? unlocked?
   - `daemon-logs` — tail the daemon log file
2. **`lightning daemon install`** generates a systemd user
   unit at `~/.config/systemd/user/lightning-<backend>.service`
   for opt-in supervised running. Idempotent.
3. **Health checks** in `status`: process alive + RPC
   reachable + chain synced + (if applicable) wallet
   unlocked.
4. **Auto-unlock hook** — if a stored unlock secret exists
   (FEAT-184), `daemon-start` invokes it after the daemon
   reports "waiting for password".

## Acceptance Criteria

1. `lightning daemon start` brings up the active backend
   without backend-specific user knowledge.
2. `lightning daemon status` returns a one-line summary +
   non-zero exit if not healthy.
3. `lightning daemon logs -f` tails the live log.
4. `lightning daemon install` generates a systemd user unit
   that survives `loginctl enable-linger`.
5. Tests cover the dispatcher contract with mocked daemons.
