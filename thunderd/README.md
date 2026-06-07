# thunderd

A small Rust **companion daemon to `lightningd`** that offers both
custodial and non-custodial accounts for Lightning — one engine, two
tiers, one API namespace (`/.well-known/thunder/v1`). It runs *parallel*
to `lightningd` and reaches it purely over the `lightning-rpc` Unix
socket; it is **not** an in-process CLN plugin.

See the design docs:
`../share/doc/lightning/standards/roadmap-overview.md` and
`../share/doc/lightning/standards/thunderd/`.

## Status — Phase I custodial (1.4.0 → 1.9.0, in progress)

Implemented and tested:

| Feature | What landed |
|---|---|
| FEAT-300/301/302 | Cargo workspace, `thunderd`+`thunderd-cli`, config, logging, `cln-rpc` probe; make targets + systemd unit; carve-out guard |
| FEAT-303/304/305 | axum server (health, `versions.json`, body limit, **CORS**); `Bearer`/`X-Mandate-Secret` auth + typed status contract (6→402/7→401/→502); Apache proxy fragment + deprecated aliases |
| FEAT-306/307 | owned SQLite schema + migrations (WAL); **double-entry msat ledger** (atomic transfers, overdraft guard, system accounts, fee-aware `charge`) |
| FEAT-309/310 | `cln-rpc` invoice/pay/decode/waitanyinvoice; **settlement reconciler** |
| FEAT-313/314 | accounts + API-key mint; pay (internal), send (external BOLT-11), invoice recv |
| FEAT-315/316/317/318 | invoices; **standing orders** + runner; **mandates** (direct debit); **auth/capture charges** (escrow) |
| FEAT-319/321/323/324 | history + CSV export; **operator fee skim**; capability profiles; **rate limiting** |
| FEAT-222 | **WebAuthn passkey** register/login + sessions (auth fully in the daemon) |

Remaining Phase I: FEAT-308 (importer), 320 (referrals), 322 (compliance
hooks), 325 (MCP), 326-328 (cutover), 329 (extract). Then Phase II
(non-custodial: LDK + remote signer + on-chain) and the 2.0.0 cutover.

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
