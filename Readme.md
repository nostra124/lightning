# `lightning`

> Educational Lightning wallet on clightning (Core Lightning): accounts, liquidity, Lightning Addresses

## Install

    git clone https://github.com/nostra124/lightning
    cd lightning
    ./install --prefix=$HOME/.local

Or in two steps:

    ./configure --prefix=$HOME/.local
    make install

## Quick start

    lightning help
    lightning version

## Layout

| Path | Purpose |
|---|---|
| `bin/lightning` | the entry point |
| `libexec/lightning/` | sub-commands (where applicable) |
| `docs/lightning.md` | CLI contract reference |
| `share/man/man1/lightning.1` | man page |
| `share/doc/lightning/standards/` | vendored references (educational) |
| `skills/lightning-wallet/` | agent skill |
| `tests/unit/lightning.bats` | unit tests |
| `tests/sit/` | system integration (when present) |
| `.cpk/` | container packaging overlay |
| `.rpk/` | rpk metadata (version, versions ledger, depends/) |

## Documentation

- `man lightning`
- `docs/lightning.md` — CLI contract reference
- `share/doc/lightning/walkthrough/README.md` — end-to-end regtest walkthrough
- `share/doc/lightning/standards/README.md` — vendored standards
- `share/doc/lightning/standards/cln-overview.md` — 10-minute clightning tour
- `share/doc/lightning/standards/api/spec.md` — Well-Known JSON API spec
- `CLAUDE.md` — agent guide
- `skills/lightning-wallet/SKILL.md` — agent skill

## Tests

- `make check` — bats unit suite (no daemon required)
- `make check-sit` — full SIT against a regtest+apache podman container
  (see `tests/sit/README.md`)

## Conventions

This package follows the rpk per-script repo convention:

- Per-script repo: this repo contains only `lightning`'s artefacts.
- No shared library: helper boilerplate is duplicated, not factored out (see `CLAUDE.md` §4–5).
- Stow-based install via `make install`.
- Versioning: semver, with `.rpk/version` as the source of truth and `.rpk/versions` as the per-release SHA ledger.

## License

GPL-3 (per the cross-cutting policy in the parent `scripts` collection).
