---
id: FEAT-197
type: feature
priority: medium
status: open
---

# `lightning plugin <list|install|remove|search>` verb

## Description

**As a** user of `lightning` who wants to extend clightning with
community plugins (trustedcoin, rebalance, summary, prometheus, …)
**I want** a `lightning plugin` object with a sub-command surface
matching the rest of the CLI
**So that** I don't have to remember the underlying tooling
(`reckless`, manual curl + chmod, Python venvs, etc.) for each
plugin and platform.

CLN ships its own plugin manager — `reckless` — but it requires
existing config files, prompts interactively on first run, and
doesn't surface a clean error model. Our verb wraps it where it
helps, falls back to file-system inspection when it doesn't, and
mirrors the look-and-feel of every other `lightning` object.

## Implementation

### Sub-commands

```
lightning plugin list                       — list installed plugins
lightning plugin install <name> [<source>]  — install a plugin
lightning plugin remove <name>              — uninstall a plugin
lightning plugin search <query>             — search source repos
lightning plugin enable <name>              — activate without re-install
lightning plugin disable <name>             — deactivate without remove
```

- `list` reads `$LIGHTNING_DIR/plugins/` directly (file presence
  + executable bit). Falls back to `reckless --json list` when
  available for source-repo metadata.
- `install` prefers `reckless install <name>` when reckless is on
  PATH. For plugins that aren't in reckless's source repos (e.g.
  `trustedcoin` lives at `nbd-wtf/trustedcoin`), accepts an
  optional `<source>` URL which is either:
  - A GitHub `owner/repo` shorthand, or
  - A full URL (added via `reckless source add` then installed).
- `remove` prefers `reckless uninstall <name>`; falls back to
  `rm $LIGHTNING_DIR/plugins/<name>*`.
- `search` requires reckless; errors clearly if missing.
- `enable` / `disable` wrap `reckless enable|disable`.

### reckless quirks to absorb

1. Reckless requires `$LIGHTNING_DIR/<network>/config` to exist.
   Pre-create an empty file on first use so reckless doesn't
   prompt.
2. Reckless prompts `press [Y] to create one now.` on missing
   config. Pre-create plus `yes` pipe handles this.
3. `lightning -v plugin install` forwards `-v` to reckless.

### Special-case: the daemon backend plugin

`daemon install --trustedcoin` already installs the trustedcoin
plugin directly (it manages the `disable-plugin=bcli` config
block). The new `plugin install trustedcoin` verb is a more
general alternative — same end state, but doesn't touch the
backend config. Doc both paths in the help.

## Acceptance Criteria

1. `lightning plugin list` lists every executable file in
   `$LIGHTNING_DIR/plugins/`, one per line, exit 0 even when the
   directory is empty.
2. `lightning plugin install rebalance` installs the plugin via
   reckless and verifies it's present under
   `$LIGHTNING_DIR/plugins/` after the call.
3. `lightning plugin install trustedcoin nbd-wtf/trustedcoin`
   adds the source repo via reckless and installs trustedcoin.
4. `lightning plugin remove rebalance` uninstalls cleanly; a
   following `plugin list` no longer shows it.
5. With reckless absent: `install` and `search` exit 127 with a
   clear "install reckless / use core-lightning bundle" message;
   `list` and `remove` still work via the filesystem fallback.
6. `lightning plugin --help` and `lightning plugin <sub> --help`
   render the rpk-style help.
7. Bats coverage with a reckless stub.

## Milestone

0.6.0 (alongside FEAT-177 packaging / FEAT-178 standards).

## See also

- `daemon install --trustedcoin` (the backend-specific shortcut)
- reckless docs (shipped with CLN): `reckless --help`
- Plugin index: <https://github.com/lightningd/plugins>
