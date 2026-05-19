---
id: FEAT-199
type: feature
priority: medium
status: open
---

# `peer keepalive` — survive network outages without losing the gossip graph

## Description

**As an** operator running `lightning` on a laptop / desktop that
sleeps / has wifi blips
**I want** my node to automatically re-seed its peer set after a
network outage
**So that** routing and BOLT-12 / LSPS1 keep working without me
having to remember to run `lightning peer reconnect` after every
disconnect.

Background: clightning's reconnect policy is asymmetric — it
retries forever for peers with whom you share at least one
channel, but gives up on bare peers after the first TCP error.
After a laptop sleep / wifi drop, `lightning peer list` empties
out and gossip / routing silently break until the operator
notices and re-runs `peer bootstrap`.

The shipped manual workaround is `lightning peer reconnect` (a
named alias for `peer bootstrap`, added alongside this issue's
diagnostic). This ticket is the automation that removes the need
to run it.

## Implementation

### Surface

```
lightning peer keepalive [--threshold N] [--target N]
```

- Idempotent. Designed to be invoked from a scheduler / launchd /
  systemd timer.
- Calls `cli listpeers`, counts connected peers.
- If count < `--threshold` (default 3), runs `peer bootstrap -n
  $((target - count))` (default target 5) so we top up to a
  healthy floor without spamming connects.
- Exits 0 in all "nothing to do / OK" cases. Non-zero only on
  bootstrap-file errors.
- Honors `LIGHTNING_NO_BOOTSTRAP=1` (same skip semantics as
  `peer bootstrap`).

### Scheduling (the actual reconnect mechanism)

Wire into `daemon install` as a sidecar so users get this for
free after install. Platform-specific:

**macOS — second LaunchAgent (sibling to `network.lightning.lightningd`)**

```
~/Library/LaunchAgents/network.lightning.keepalive.plist
   Label              network.lightning.keepalive
   ProgramArguments   [lightning, peer, keepalive]
   StartInterval      600        # every 10min
   RunAtLoad          true       # on first install + every login
   KeepAlive
       NetworkState   true       # waits for network up; restarts on network change
```

`KeepAlive { NetworkState: true }` is the key: launchd re-runs
the agent whenever the network reachability state changes, which
is exactly what we want for "wifi just came back".

**Linux — systemd `.timer` + `.service` pair (user-mode mirror of the daemon unit)**

```
~/.config/systemd/user/lightning-keepalive.timer
   OnUnitActiveSec    10min
   OnBootSec          1min
~/.config/systemd/user/lightning-keepalive.service
   ExecStart          $(command -v lightning) peer keepalive
```

For network-event triggering on Linux, add a NetworkManager
dispatcher snippet (best-effort — not all distros use NM):

```
/etc/NetworkManager/dispatcher.d/99-lightning-keepalive
   case "$2" in up|connectivity-change)
       sudo -u $LIGHTNING_USER lightning peer keepalive
   esac
```

The dispatcher hook is best-effort and Linux-only; the timer is
the floor that always works.

### Install flow

`daemon install` (and `--system` variants) writes the sidecar.
`daemon install --no-keepalive` opts out for users who already
have their own monitoring.

## Acceptance Criteria

1. `lightning peer keepalive` with no flags exits 0 and runs
   bootstrap iff connected-peer count is < 3.
2. `lightning peer keepalive --threshold 0 --target 0` is a no-op
   that always exits 0 (for users who want the verb registered
   but no automation).
3. On macOS, `daemon install` writes BOTH the lightningd plist
   AND the keepalive plist. `launchctl unload` of the lightningd
   plist alone leaves the keepalive untouched (and vice versa).
4. On Linux, `daemon install` writes lightning-keepalive.timer +
   lightning-keepalive.service alongside lightning.service.
5. Bats coverage:
   - keepalive runs bootstrap when peers below threshold (stub
     listpeers to return N peers, assert bootstrap was called)
   - keepalive is a no-op when peers >= threshold
   - `daemon install` on macOS writes both plists
   - LIGHTNING_NO_BOOTSTRAP=1 short-circuits keepalive

## Out of scope

- Channel-pinning approaches (open a tiny channel to a bootstrap
  node so clightning treats it as a retryable peer). Real
  on-chain commitment + dust risk.
- Generic event-bus / clightning-plugin approach. A simple timer
  + network-event hook is enough for the laptop use case.

## Milestone

0.7.0 (operational hardening — alongside FEAT-186 watchtowers and
FEAT-189 Tor privacy if/when they land).

## See also

- `lightning peer reconnect` (the manual command this automates)
- `lightning daemon install` (where the sidecar gets wired in)
- clightning's `--important-peer` config flag — partial workaround
  but requires lightningd restart to take effect
