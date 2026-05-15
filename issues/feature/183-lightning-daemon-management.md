---
id: FEAT-183
type: feature
priority: high
status: open
---

# Lightning daemon lifecycle management

## Description

**As a** user of `lightning`
**I want** `lightning daemon {start,stop,restart,status,logs,install}`
verbs that drive lightningd, **running under a dedicated
`clightning` system user**
**So that** running a Lightning node doesn't require knowing
the right `lightningd` flags, the right systemd unit shape,
or where the logs go — and so the daemon's keys aren't
sitting in the operator's home dir.

Wraps `lightningd`. Help text cites the upstream command
being wrapped.

## Two run modes

### User-mode (default for the casual user)

Run lightningd from the operator's own account
(`alice`). State lives under `~alice/.lightning/`. Suitable
for "I just want a node on my laptop" — nothing to set up,
no system-level config.

### System-mode (recommended for any node that hosts
addresses or the web API)

`lightning daemon install --system` provisions a dedicated
`clightning` system user (uid/gid auto-allocated, login
shell `/usr/sbin/nologin`), creates `/var/lib/clightning/`
owned by `clightning:clightning`, and installs a
**system-level** systemd unit (`/etc/systemd/system/
clightningd.service`) that runs `lightningd` as that user.

The RPC socket lives at
`/var/lib/clightning/<network>/lightning-rpc`, group-owned
by `clightning` with mode `0660`. The operator (`alice`) is
added to the `clightning` group on install so her
`lightning-cli` can reach the socket. Apache's user
(`www-data`) is **not** added — it talks through the
sudo-to-alice hop documented in FEAT-196, never directly to
the RPC socket.

The three users that result on a system-mode install:

| User         | Role                                                       |
|--------------|------------------------------------------------------------|
| `clightning` | runs `lightningd`; owns `/var/lib/clightning/`             |
| `alice`      | operator; runs `lightning` CLI; in group `clightning`      |
| `www-data`   | runs Apache + the CGI scripts; bridges to alice via sudo   |

This three-user split is the security boundary: a CGI
compromise gets you alice's privileges (which means alice's
wallet repo + secret store), not direct daemon access. A
daemon compromise gets you `clightning`'s very thin
filesystem footprint.

## Implementation

1. Verbs under `libexec/lightning/`:
   - `daemon-start` — `lightningd --daemon`; user-mode uses
     `LIGHTNING_DIR` (default `~/.lightning`); system-mode
     does `sudo systemctl start clightningd`.
   - `daemon-stop` — `lightning-cli stop` (graceful).
   - `daemon-restart` — stop + start.
   - `daemon-status` — process alive? RPC reachable? chain
     synced? wallet unlocked?
   - `daemon-logs` — user-mode tails `<lightning-dir>/log`;
     system-mode tails `journalctl -u clightningd`.
2. **`lightning daemon install`** — user-mode by default.
   `--system` switches to the three-user layout above:
   - creates the `clightning` system user if absent
     (idempotent; no-op if already created)
   - creates `/var/lib/clightning/` owned by
     `clightning:clightning`
   - drops `/etc/systemd/system/clightningd.service`
   - adds the calling user to the `clightning` group
   - configures lightningd with `rpc-file-mode=0660`
   - prints a one-line "log out and back in for group
     membership to take effect" reminder
   Both modes are idempotent. The system-mode install does
   not silently take over an existing user-mode setup; it
   refuses unless `--migrate` is passed.
3. **Health checks** in `status`: process alive + RPC
   reachable + chain synced + wallet unlocked.
4. **Auto-unlock hook** — if a stored unlock secret exists
   (FEAT-184), `daemon-start` invokes it after lightningd
   reports the HSM wants a password.

## Acceptance Criteria

1. `lightning daemon start` (user-mode) brings up
   lightningd in the background under the calling user.
2. `lightning daemon install --system` creates the
   `clightning` user, the systemd unit, and the group
   membership; subsequent `daemon start` runs the daemon
   under `clightning` and the operator's `lightning-cli`
   still works.
3. `lightning daemon status` returns a one-line summary +
   non-zero exit if not healthy. Works against both modes.
4. `lightning daemon logs -f` tails the live log in both
   modes.
5. The system-mode RPC socket is mode `0660`, group
   `clightning`; `www-data` cannot read it.
6. Tests cover both modes against a mocked `lightning-cli`.
