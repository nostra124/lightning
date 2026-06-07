# thunderd

A Rust **companion daemon to `lightningd`** offering both custodial and
non-custodial accounts for Lightning — one engine, two tiers, one API
namespace (`/.well-known/thunder/v1`). It runs *parallel* to `lightningd`
and reaches it purely over the `lightning-rpc` Unix socket; it is **not**
an in-process CLN plugin. The workspace is standalone (no build/runtime
coupling to the `lightning` bash package, enforced by the carve-out
guard) so it can be extracted to its own repo at 2.0.0.

Design docs: `../share/doc/lightning/standards/roadmap-overview.md` and
`../share/doc/lightning/standards/thunderd/`. Implementation status and
the road to 2.0.0: [`STATUS.md`](STATUS.md).

## Components (per roadmap-overview.md)

| Crate | Role |
|---|---|
| **`thunderd`** | the daemon: HTTP API, ledger, commerce, node integration, auth |
| **`thunderd-cli`** | operator admin CLI (`health`) |
| **`signer-core`** | validating remote-signer core (validate + sign PSBTs); native now, WASM-ready for the PWA |
| **`thunder`** | the user's device-side remote-signer client CLI (`sign-psbt`, `inspect`) |

## What's implemented (custodial tier — complete; non-custodial — transport + on-chain + signer)

| Area | Features |
|---|---|
| Foundations | FEAT-300/301/302 — workspace, binaries, config, tracing, `cln-rpc` probe, make targets, systemd unit, **carve-out guard** (CI + bats) |
| HTTP / auth | FEAT-303/304/305 — axum (health, `versions.json`, `mcp.json`, body limit, **CORS**); `Bearer` + `X-Mandate-Secret` auth; typed status contract (insufficient→402, auth→401, backend→502); Apache proxy fragment + deprecated aliases |
| State / ledger | FEAT-306/307 — owned SQLite + migrations (WAL); **double-entry msat ledger** (atomic transfers, in-tx overdraft guard, system accounts, fee-aware `charge`); sum-to-zero invariant tests |
| Node integration | FEAT-309/310/311/314 — `cln-rpc` invoice/pay/decode/waitanyinvoice/offer/withdraw; **settlement reconciler** |
| Accounts / payments | FEAT-313/314 — accounts + API-key mint; internal pay; external BOLT-11 send; on-chain withdraw; invoice + BOLT-12 offer recv |
| Commerce | FEAT-315/316/317/318 — invoices; **standing orders** + runner; **mandates** (direct debit); **auth/capture/void/refund charges** (escrow) |
| Policy / ops | FEAT-319/320/321/322/323/324/325 — history + CSV; **fee skim**; **referrals**; **compliance** veto + audit; capability profiles; **rate limiting**; **MCP manifest** |
| Identity | FEAT-222 — **WebAuthn passkey** register/login + sessions (auth fully in the daemon) |
| Migration | FEAT-308 — `thunderd migrate` legacy importer (idempotent, `--dry-run`) |
| Non-custodial | FEAT-400/41x — tenant + watch-only-xpub registration; **remote-signer transport** (request→sign→return); **on-chain** xpub→address derivation + unsigned-PSBT construction; **`signer-core`** validating signer; **A2 loop proven end-to-end** across crates |

**Not yet implemented** (need live infra / separate codebase — see `STATUS.md`):
per-tenant **LDK channel engine**, **thunder-pay PWA**, and the breaking
**2.0.0 cutover** (gated behind a shadow-run against the live node).

## HTTP API (`/.well-known/thunder/v1`)

Full reference: [`docs/API.md`](docs/API.md). Summary:

- **Discovery**: `GET /health`, `GET /versions.json`, `GET /mcp.json`
- **Accounts**: `POST /accounts`, `GET /accounts/{id}`, `POST /accounts/{id}/topup`
- **Pay/recv**: `POST /pay`, `POST /accounts/{id}/invoice`, `/offer`, `/send`, `/withdraw`, `GET /invoices/{id}`
- **Commerce**: `POST /accounts/{id}/mandates`, `POST /mandates/charge`, `POST /mandates/{id}/revoke`; `POST /accounts/{id}/charges`, `/charges/{id}/{capture,void,refund}`; `GET/POST /accounts/{id}/standing-orders`, `POST /standing-orders/{id}/cancel`
- **History**: `GET /accounts/{id}/history[.csv]`
- **Identity**: `POST /auth/passkey/{register,login}/{begin,finish}`, `GET /auth/me`
- **Non-custodial**: `POST /tenants`, `GET /tenants/{id}`, `GET/POST /tenants/{id}/signing-requests`, `POST /signing-requests/{id}/sign`, `GET /tenants/{id}/onchain/address`, `POST /tenants/{id}/onchain/psbt`, `GET /tenants/{id}/node` (501 until LDK)

## Key decisions

- **DB: `sqlx`/SQLite** (runtime-checked queries; isolated to `db.rs`).
- **Auth/identity lives in `thunderd`** (bearer + mandate + passkey/WebAuthn).
- **Toolchain pinned** via `rust-toolchain.toml` (1.94.1) so `fmt`/`clippy`
  are deterministic across CI and local.
- **Custody bar A2** for non-custodial: server holds only watch-only
  xpubs; the device signs (validated) via `signer-core`.

## Build, run, test

```sh
cd thunder
cargo build --release
cargo test                 # 51 tests
cargo fmt --check && cargo clippy --all-targets -- -D warnings
./scripts/carve-out-guard.sh

# run the daemon against a local lightningd
./target/release/thunderd \
    --cln-socket ~/.lightning/bitcoin/lightning-rpc \
    --db ./thunderd.sqlite3

./target/release/thunderd-cli health            # operator admin
./target/release/thunderd migrate --from <wallet>/state.db --dry-run  # importer
./target/release/thunder sign-psbt --xpriv <…> --psbt <…> --path m/0/0 # device signer
```

From the repo root: `make thunderd`, `make thunderd-check`, `make thunderd-guard`.

## Layout

```
thunder/
├── Cargo.toml                 workspace (4 crates)
├── rust-toolchain.toml        pinned toolchain
├── crates/
│   ├── thunderd/              the daemon
│   │   ├── src/               main,config,logging,clnrpc,db,error,auth,state,util
│   │   │   ├── *.rs           ledger,accounts,invoices,mandates,charges,standing_orders,
│   │   │   │                  policy,compliance,referrals,ratelimit,reconcile,scheduler,
│   │   │   │                  passkey,noncustodial,onchain,migrate
│   │   │   └── http/          axum server, routes, CORS, handlers
│   │   └── migrations/        sqlx SQLite migrations (0001..0010)
│   ├── thunderd-cli/          operator admin CLI
│   ├── signer-core/           validating remote-signer core
│   └── thunder/               device-side signer client CLI
├── dist/                      thunderd.service (systemd), thunderd-apache.conf
├── scripts/carve-out-guard.sh FEAT-302 boundary check
├── STATUS.md                  implementation status + 2.0.0 runbook
└── docs/API.md                HTTP API reference
```
