---
id: FEAT-207
type: feature
priority: medium
status: open
---

# Install Core Lightning itself — `lightning daemon install-core`

## Description

**As a** new operator setting up a Lightning node
**I want** `lightning daemon install-core` to put a working
`lightningd` on my PATH using whichever package source fits
my platform best
**So that** I don't have to leave the `lightning` UX to
chase a tarball, hunt build dependencies, or learn brew /
apk / podman commands the first time I bring a node up.

Filed after the FEAT-183 daemon overhaul shipped: that work
covered the *service unit* (systemd / launchd) but assumed
`lightningd` was already on PATH. New operators on a clean
machine hit a wall the moment they run `lightning daemon
start` without a backend. This ticket closes that gap.

## Background

Today the `lightning daemon` verb manages an already-
installed `lightningd`:

   start / run / stop / restart / status / logs
   install [--system] [--migrate]   # service unit only
   install --trustedcoin             # plugin only

Nothing in our tree installs the binary. The
`personal-node.md` and `routing-node.md` guides each open
with "first, install Core Lightning by …" — the steps differ
per platform and rot quickly.

We want one verb that hides the platform difference: pick
the right source, run it, verify `lightningd --version`
succeeds, hand off to `daemon install` for the service unit.

## Surface (proposed)

```
lightning daemon install-core [--rpk|--brew|--apk|--source|--podman]
                              [--version <tag>] [--system] [--yes]
                              [--dry-run]
```

With no `--<backend>` flag, the verb auto-detects (see
"Detection precedence" below).

`--version` pins to a Core Lightning release tag (default:
latest stable). `--system` writes to a system-wide prefix
and chains into `daemon install --system` afterwards.
`--yes` skips the confirm-the-source prompt for use in
unattended scripts. `--dry-run` prints the plan without
running anything.

After `install-core` exits 0, `lightningd --version`
succeeds and `lightning daemon install` can wire up the
service unit. The two verbs compose cleanly; either can be
run standalone.

## Install backends

| Source | Trigger | What it gives you |
|--------|---------|-------------------|
| `rpk install lightningd` *(preferred — assumes sister package)* | `--rpk` or default when `rpk` is on PATH | `lightningd`, `lightning-cli`, `lightning-hsmtool` installed to the same `bin/`-`libexec/`-`share/` layout `lightning` itself uses. rpk owns version pinning, upgrade, and uninstall. Cross-platform — the rpk package internally picks brew / apk / source. |
| `brew install core-lightning` | `--brew` (macOS) | Homebrew-managed `lightningd` under `/opt/homebrew/bin/` (Apple Silicon) or `/usr/local/bin/` (Intel). |
| `apk add lightningd` | `--apk` (Alpine) | Alpine community-repo build, system-wide. |
| Source build (`git clone ElementsProject/lightning && ./configure && make && sudo make install`) | `--source` (Ubuntu and fallback) | Universal path. Ubuntu defaults to source because no upstream apt package exists today. Apt build-deps are installed first; the operator sees the list before they go in. |
| `podman pull elementsproject/lightningd && podman run …` | `--podman` (any platform) | Rootless containerized `lightningd`; `lightning-cli` shimmed via `podman exec`; state mounted from `$LIGHTNING_DIR`. Useful when the operator can't or won't install build deps on the host. |

### Why podman, not docker

- Rootless by default — matches the user-mode install
  pattern (no docker-group sudo escalation).
- Daemonless — no `dockerd` to babysit; fewer moving parts
  under `lightning daemon status`.
- systemd-native via `podman generate systemd` — slots
  cleanly into the FEAT-183 service-install code path on
  Ubuntu. `podman generate kube` works for Alpine/OpenRC.
- On macOS: `podman machine init` creates the qemu VM;
  behaviour from `lightning daemon`'s POV is identical to
  native.

Docker is intentionally not auto-selected and not exposed
as a flag. If a user has docker installed but not podman,
`install-core` exits with a hint and the one-line podman-
install command for their platform.

### Detection precedence (no `--<backend>` flag)

1. `command -v rpk` → `--rpk`
2. macOS + `command -v brew` → `--brew`
3. Alpine (`ID=alpine` in `/etc/os-release`) + `command -v apk` → `--apk`
4. `command -v podman` → `--podman`
5. Ubuntu / Debian (`ID_LIKE` contains `debian`) → `--source`
6. otherwise → exit with platform-detection error + manual instructions

## Contract for the `lightningd` rpk package

`lightning` will pick up an `lightningd` rpk package if and
when one exists. This ticket does NOT implement that
package — it documents what `lightning` will assume so the
sister-package work has a target to hit.

- **Binaries on PATH**: `lightningd`, `lightning-cli`,
  `lightning-hsmtool`, `lightning-keysend`.
- **Version file**: `share/lightningd/version` containing
  the Core Lightning release tag (e.g. `v26.04.1`). Lets
  `lightning daemon status` cross-check.
- **No BOLT-spec duplication**: the `lightningd` package
  MUST NOT vendor BOLT specs — `lightning` owns those
  under `share/doc/lightning/standards/` (FEAT-178). Two
  packages share specs by reference, not duplication.
- **Plugin directory**: respects `LIGHTNING_DIR/plugins/`
  for user plugins; no opinion on bundled plugins.
- **Install hook**: `rpk install lightningd` exits 0 and
  leaves `lightningd --version` working without further
  steps. If it cannot (e.g. missing build deps on a from-
  source internal path), it exits non-zero with a message
  — no half-installed state.
- **System-mode awareness**: when the `lightningd` package
  installs system-wide (rpk-system mode), it MAY create
  the `clightning` user. If not, `lightning daemon install
  --system` does so. We do not double-create.

## Service-install + Alpine OpenRC

`lightning daemon install` today supports systemd (user &
system) and launchd (user & system). Alpine uses **OpenRC**,
not systemd, so it needs a third branch:

| Init system | User mode | System mode |
|-------------|-----------|-------------|
| systemd (Ubuntu) | `~/.config/systemd/user/lightning.service` ✓ exists | `/etc/systemd/system/clightningd.service` ✓ exists |
| launchd (macOS) | `~/Library/LaunchAgents/network.lightning.lightningd.plist` ✓ exists | `/Library/LaunchDaemons/…` ✓ exists |
| **OpenRC (Alpine)** | n/a — OpenRC has no per-user mode | **`/etc/init.d/clightningd` + `rc-update add clightningd default`** ← new |

The OpenRC init script needs:
- `command=/usr/bin/lightningd`
- `command_args="--daemon --pid-file=…"` (or `--bcli`,
  `--trustedcoin-frontend` flags from the existing
  backend block)
- `supervisor=supervise-daemon` for restart-on-failure
- runs as user `clightning`, group `clightning`

Three-user separation (FEAT-183 §3) works identically: on
Alpine the web frontend is typically `nginx` rather than
`www-data`, but the sudo-to-operator bridge is the same.

## Detection helpers (lib code)

Need a small detection module to keep the logic DRY across
`install-core` and `install`:

```bash
# libexec/lightning/daemon — internal helpers
platform_id()        # darwin / ubuntu / alpine / unknown
init_system()        # systemd / launchd / openrc / none
preferred_backend()  # rpk / brew / apk / source / podman / none
```

`init_system` is what the existing `cmd_install` already
implicitly computes via `uname -s` + presence checks; this
just names it.

## Acceptance criteria

1. `lightning daemon install-core --dry-run` on each of
   {macOS+brew, Ubuntu+source, Alpine+apk, any+podman,
   any+rpk} prints the exact command sequence it would
   run, exits 0, makes no filesystem changes.
2. With no `--<backend>` flag, `install-core --dry-run`
   picks per the detection precedence above. A bats test
   per platform stubs `command -v` / `/etc/os-release` /
   `uname` and asserts the chosen backend.
3. `install-core --podman` produces a rootless container,
   a `lightning-cli` shim that exec's into it, and state
   mounted from `$LIGHTNING_DIR`. The shim is on `PATH`
   ahead of any host `lightning-cli`.
4. `install-core --brew` on macOS exits with a clear
   "brew not found" error if Homebrew isn't installed
   (does not auto-install brew).
5. `install-core --source` on Ubuntu prints the build-dep
   list, prompts for confirmation (or accepts `--yes`),
   runs `apt-get install` via sudo, then the source build.
6. Alpine OpenRC service unit installs and starts; `rc-service
   clightningd status` reports started.
7. Docker is detected but never auto-selected; user sees
   the podman-install hint.
8. After `install-core` exits 0, `lightningd --version`
   succeeds. `install-core` does NOT chain into `daemon
   install` automatically — that's a separate call. They
   compose; neither is required to call the other.
9. `install-core --rpk` no-ops (or exits 2 with a "rpk
   package not yet published" message) until the
   `lightningd` rpk package exists. The flag is recognised
   so the contract is wired in advance.
10. Bats coverage: one test per backend's flag-parsing,
    one per detection branch, one per dry-run plan
    output. Real-execution tests run inside rootless
    podman containers (Ubuntu + Alpine images) under
    `tests/sit/`.

## Test strategy

- **Unit tests (`tests/unit/lightning.bats`)** — stub
  `command -v`, `/etc/os-release`, `uname -s`, and the
  package managers (`brew`, `apk`, `apt-get`, `podman`,
  `rpk`) via the `BIN_SHIM` pattern already used for
  systemctl. Assert the planned command sequence, not
  side effects.

- **System-integration tests (`tests/sit/podman/`)** — one
  rootless podman container per target platform (Ubuntu
  24.04, Alpine 3.20). Build images on first run, cache by
  hash. Run `install-core` for real inside each container.
  No DinD nesting — podman runs on the CI host, not inside
  a container.

- **macOS** — shims only; CI has no macOS runners. The
  launchd paths and brew detection logic stay unit-
  testable via fixture.

## Out of scope (non-goals)

- **lnd, eclair, LDK, sensei, phoenixd, any non-Core-
  Lightning backend.** `lightning` ships exactly one
  Lightning backend (CLAUDE.md §1). lnd has its own
  installer story; we don't compete.
- **Auto-installing Homebrew, podman, or sudo.** If the
  prerequisite isn't present, `install-core` exits with a
  one-line install command and the URL of the official
  install docs. We don't curl-pipe-bash anything.
- **Auto-updating an existing install.** Upgrades are a
  separate ticket. `install-core` refuses to overwrite an
  existing `lightningd` without `--force`.
- **The `lightningd` rpk package itself.** This ticket
  documents the contract; the package work happens
  elsewhere.
- **Docker support.** Podman is the chosen container
  runtime. See "Why podman, not docker" above.
- **Snap, flatpak, AppImage, nix, guix.** Not on the
  matrix today. If a maintainer wants to add one, the
  surface is open (`--<backend>` is just a switch case),
  but no commitment from this ticket.

## Milestone

1.4.0 (new — covers FEAT-207 and related operator-UX work).

## See also

- FEAT-183 — daemon lifecycle / service-unit install
  (what `install-core` composes with).
- FEAT-202 — personal-node guide (will update its
  "install Core Lightning" section once this ships).
- FEAT-203 — routing-node guide (same).
- FEAT-178 — vendored BOLT specs (the rpk package must
  not duplicate these).
- Core Lightning install docs:
  https://docs.corelightning.org/docs/installation
- Podman rootless docs:
  https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md
- Alpine OpenRC docs:
  https://wiki.alpinelinux.org/wiki/OpenRC
