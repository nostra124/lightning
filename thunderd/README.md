# thunderd

A small Rust **companion daemon to `lightningd`** that offers both
custodial and non-custodial accounts for Lightning — one engine, two
tiers, one API namespace (`/.well-known/thunder/v1`). It runs *parallel*
to `lightningd` and reaches it purely over the `lightning-rpc` Unix
socket; it is **not** an in-process CLN plugin.

See the design docs:
`../share/doc/lightning/standards/roadmap-overview.md` and
`../share/doc/lightning/standards/thunderd/`.

## Status — Phase I skeleton (1.4.0, in progress)

This is the **foundations** slice of Phase I (custodial):

| Feature | What landed |
|---|---|
| FEAT-300 | Cargo workspace, `thunderd` (tokio) + `thunderd-cli` binaries, config, structured logging, `cln-rpc` startup probe |
| FEAT-301 | `thunderd-build` / `thunderd-check` make targets, systemd unit template (`dist/thunderd.service`); standalone-buildable for the 2.0.0 extraction |
| FEAT-302 | carve-out guardrail (`scripts/carve-out-guard.sh`) — no coupling to the `lightning` bash package |
| FEAT-303 | embedded axum HTTP server: health, `versions.json` discovery, body limit, **CORS scaffold**, 404/405 |
| FEAT-304 | auth scaffold: `Bearer` API-key + `X-Mandate-Secret` (hashed at rest, constant-time), 401 contract |
| FEAT-306 | owned SQLite schema + embedded migrations (sqlx, WAL) |

Stub business routes return `501` until their feature ports (Phase 4).

## Key decisions

- **DB crate: `sqlx` (sqlite backend).** Async-native fit for the
  tokio/axum server; runtime-checked queries (no compile-time
  `DATABASE_URL`/offline cache) keep CI and the carve-out guard simple.
  Isolated to `src/db.rs`.
- **Auth/identity lives in `thunderd`** (not deferred to a separate
  plugin): bearer + mandate-secret today; the passkey/WebAuthn
  wallet-user layer has its schema + routes scaffolded here.

## Build & run

```sh
cd thunderd
cargo build --release
cargo test
./scripts/carve-out-guard.sh

# run against a local lightningd
./target/release/thunderd \
    --cln-socket ~/.lightning/bitcoin/lightning-rpc \
    --db ./thunderd.sqlite3

# in another shell
./target/release/thunderd-cli health
```

Or via the package Makefile (from the repo root): `make thunderd`,
`make thunderd-check`, `make thunderd-guard`.

## Layout

```
thunderd/
├── Cargo.toml                 workspace
├── crates/
│   ├── thunderd/              the daemon
│   │   ├── src/{main,config,logging,clnrpc,db,error,auth,state}.rs
│   │   ├── src/http/          axum server, routes, CORS, handlers
│   │   └── migrations/        sqlx SQLite migrations
│   └── thunderd-cli/          operator admin CLI (`health`)
├── dist/thunderd.service      systemd unit template
└── scripts/carve-out-guard.sh FEAT-302 boundary check
```
