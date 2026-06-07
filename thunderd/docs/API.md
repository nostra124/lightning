# thunderd HTTP API reference

Base namespace: **`/.well-known/thunder/v1`** (proxy-stripped prefix,
configurable with `--base-path`). The listener is loopback-bound; TLS is
terminated by the reverse proxy (`dist/thunderd-apache.conf`).

## Auth

- **Account API key** — `Authorization: Bearer lt_…` (returned once at
  account/key creation; stored only as a SHA-256 hash).
- **Mandate secret** — `X-Mandate-Secret: ms_…` (direct-debit pulls).
- **Wallet-user session** — `Authorization: Bearer st_…` (minted by a
  passkey login; used for `/auth/me` and the non-custodial `/tenants` API).

Status contract: insufficient funds / over-limit → **402**, auth failure
→ **401**, cross-account / policy denial → **403**, backend (lightningd)
error → **502**, unimplemented → **501**, rate-limited → **429**.

## Discovery

| Method | Path | Notes |
|---|---|---|
| GET | `/health` | `{status, version, uptime_s, db, cln{connected,id,…}}`; 200 (or 503 if DB down) |
| GET | `/versions.json` | namespace + supported versions + tiers |
| GET | `/mcp.json` | MCP tool manifest for AI-agent consumers |

## Accounts (custodial)

| Method | Path | Body / notes |
|---|---|---|
| POST | `/accounts` | `{label?, capability?, referrer?}` → `{id, …, api_key}` (key shown once). Rate-limited. capability ∈ custodial\|treasury\|family\|prepaid |
| GET | `/accounts/{id}` | bearer owns it → `{account, balance_msat}` |
| POST | `/accounts/{id}/topup` | `{amount_msat}` — dev settlement hook (replaced by invoice settlement) |
| GET | `/accounts/{id}/history` | `?limit` → recent ledger entries |
| GET | `/accounts/{id}/history.csv` | RFC-4180 CSV (tax export) |

## Payments

| Method | Path | Body / notes |
|---|---|---|
| POST | `/pay` | `{to, amount_msat, memo?}` — internal account→account transfer; operator fee + referral applied |
| POST | `/accounts/{id}/invoice` | `{amount_msat, description?}` → BOLT-11 (recv); settled by the reconciler |
| POST | `/accounts/{id}/offer` | `{amount_msat, description?}` → reusable BOLT-12 offer |
| POST | `/accounts/{id}/send` | `{bolt11}` — pay an external invoice; compliance-gated; fee applied |
| POST | `/accounts/{id}/withdraw` | `{address, amount_sat}` — on-chain via the node's wallet; compliance-gated |
| GET | `/invoices/{id}` | invoice record (owner only) |

## Commerce

| Method | Path | Body / notes |
|---|---|---|
| POST | `/accounts/{id}/mandates` | `{label?, max_amount_msat?}` → `{mandate_id, secret}` (secret once) |
| POST | `/mandates/charge` | `X-Mandate-Secret`; `{to, amount_msat}` — pull within cap; fee applied |
| POST | `/mandates/{id}/revoke` | owner bearer; revokes (secret stops authenticating) |
| POST | `/accounts/{id}/charges` | payer authorizes a hold → escrow; `{merchant, amount_msat}` |
| POST | `/charges/{id}/capture` | merchant; `{amount_msat?}` (partial captures, voids remainder) |
| POST | `/charges/{id}/void` | merchant or payer; releases the hold |
| POST | `/charges/{id}/refund` | merchant; `{amount_msat?}` (partial/full) |
| GET | `/charges/{id}` | charge state (payer or merchant) |
| POST | `/accounts/{id}/standing-orders` | `{to, amount_msat, interval_secs}` — recurring; runner executes due |
| GET | `/accounts/{id}/standing-orders` | list |
| POST | `/standing-orders/{id}/cancel` | owner |

## Identity (passkey / WebAuthn)

| Method | Path | Notes |
|---|---|---|
| POST | `/auth/passkey/register/begin` | `{name}` → `{session, user_id, challenge}` |
| POST | `/auth/passkey/register/finish` | `{session, credential}` → persists the credential |
| POST | `/auth/passkey/login/begin` | `{user_id}` → `{session, challenge}` |
| POST | `/auth/passkey/login/finish` | `{session, credential}` → `{user_id, session_token}` (`st_…`) |
| GET | `/auth/me` | `Bearer st_…` → `{user_id}` |

## Non-custodial (Phase II — session-gated by tenant owner)

| Method | Path | Notes |
|---|---|---|
| POST | `/tenants` | `{label?, xpub}` — register a tenant + watch-only xpub |
| GET | `/tenants/{id}` | tenant info |
| GET | `/tenants/{id}/signing-requests` | device fetches pending requests |
| POST | `/tenants/{id}/signing-requests` | enqueue `{kind?, payload}` to sign |
| POST | `/signing-requests/{id}/sign` | device returns `{signature}` |
| GET | `/tenants/{id}/onchain/address` | `?index` → derived watch-only p2wpkh address |
| POST | `/tenants/{id}/onchain/psbt` | `{inputs[], outputs[]}` → unsigned PSBT + enqueues it to the signer |
| GET | `/tenants/{id}/node` | **501** — per-tenant LDK channel engine not implemented |

## Configuration (flags / env)

`--http-bind/-port`, `--db`, `--base-path`, `--cln-socket`,
`--cors-origin`, `--body-limit`, `--fee-base-msat`, `--fee-ppm`,
`--referral-share-ppm`, `--compliance-max-msat`, `--create-rate-per-min`,
`--network`, `--rp-id`, `--rp-origin`. Each has a `THUNDERD_*` env
equivalent. Subcommand: `thunderd migrate --from <path> [--dry-run]`.
