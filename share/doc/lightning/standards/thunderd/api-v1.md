# `thunder/v1` — HTTP JSON API specification (draft)

**Version:** 0.1.0 (draft) · **Status:** Planning
**Base URL:** `/.well-known/thunder/v1`
**Served by:** `thunderd` (companion to `lightningd`) — see
`design.md`. Consumed by the `thunder` CLI and the `thunder-pay` PWA.

> This is the contract three things build against (the daemon and two
> clients), so it is pinned early. It is a **draft** — endpoint shapes
> firm up as each release lands (`1.4.0` custodial → `1.20.0`
> non-custodial). Each endpoint is tagged **[C]** custodial (Phase I,
> `1.4.0`–`1.9.0`) or **[N]** non-custodial (Phase II, `1.13.0`–`1.20.0`).

## 1. Conventions

- JSON in/out; `Content-Type: application/json` unless noted (tax export
  may be `text/csv`).
- All routes under `/.well-known/thunder/v1`. A reverse proxy (Apache)
  terminates TLS and strips the prefix; `thunderd` binds localhost.
- Legacy custodial paths `/.well-known/lightning/accounts/v1` and
  `/.well-known/lightning/v1/accounts` are **deprecated aliases** to the
  custodial endpoints here, removed at `2.0.0`.
- Amounts are integer **sats** in request/response bodies; the ledger is
  msat-precise internally.

## 2. Account tiers

An account carries a `kind`:

| kind | custody | id | keys |
|---|---|---|---|
| `custodial` | node holds keys; account = ledger row | bech32 address (FEAT-212) | server-side (`lightningd`) |
| `noncustodial` | seed on device, signs remotely (A2) | `tnd_<base32>` | user device (validating signer) |

Custodial mirrors today's commerce/neobank surface. Non-custodial adds
per-tenant LDK channels + on-chain, all device-signed.

## 3. Authentication

- **[C] Bearer (account key):** `Authorization: Bearer lt_…` — per-account
  long-lived key (custodial).
- **[C] Mandate secret:** body `secret` or `X-Mandate-Secret` — merchant
  charge against a direct-debit mandate.
- **[N] Device session:** `Authorization: Bearer tsess_…` — minted when a
  device registers/authenticates (see §8); scopes calls to one tenant.
- **Public:** discovery, price, node info, invoice decode.

Wrong/missing auth → `401` (oracle-resistant: never reveals existence).

## 4. Error model

Typed `Result` → HTTP status (preserving the verb exit-code contract):

| Internal | HTTP | Body `error` |
|---|---|---|
| ok | `200`/`201` | — |
| rule violation (overdraft/limit/capability/compliance) | `402` | `rule_violation` / `compliance_denied` |
| auth mismatch | `401` | `invalid_bearer` / `invalid_mandate_secret` |
| bad request | `400` | `<field>_required` / `bad_json` |
| not found | `404` | — |
| backend failure | `502` | `backend_failed` |

## 5. Discovery (public)

| Method | Path | Notes |
|---|---|---|
| GET | `/versions.json` | advertised versions, surfaces |
| GET | `/mcp.json` | MCP descriptor (if MCP kept) |
| GET | `/price?base=EUR` | sat/fiat tick |
| GET | `/node` | pubkey, alias, channel count |
| GET | `/decode?invoice=…` | BOLT-11/12 decode |

## 6. Accounts & money (both tiers unless tagged)

| Method | Path | Auth | Tier | Purpose |
|---|---|---|---|---|
| POST | `/accounts` | none (rate-limited) / device | C/N | create account (`kind` selects tier) |
| GET | `/accounts` | bearer (operator) | C | list/search accounts |
| GET | `/accounts/<id>/balance` | bearer | C/N | balance (LN + on-chain), limit, overdraft |
| GET | `/accounts/<id>/topup` | bearer | C | on-chain deposit (BIP-21) |
| POST | `/accounts/<id>/pay` | bearer | C/N | pay BOLT-11/12 (trampoline for N) |
| POST | `/accounts/<id>/recv` | bearer | C/N | mint BOLT-11 (pay-to-open for N) |
| POST | `/accounts/<id>/recv-reusable` | bearer | C/N | BOLT-12 offer |
| POST | `/accounts/<id>/transfer` | bearer | C | intra-node transfer |
| POST | `/accounts/<id>/withdraw` | bearer | C/N | on-chain send (C: node wallet; N: device-signed PSBT, see §7) |
| GET | `/accounts/<id>/history` | bearer | C/N | unified LN + on-chain ledger |
| PATCH | `/accounts/<id>/history/<n>` | bearer | C/N | edit note |
| GET | `/accounts/<id>/export/tax-data?year=&base=&format=` | bearer | C/N | CSV/JSON tax export |
| GET | `/accounts/<id>/api-key` | bearer | C | reveal key |
| POST | `/accounts/<id>/close` | bearer | C/N | close |

### 6.1 On-chain [N] (daemon builds, device signs)

| Method | Path | Purpose |
|---|---|---|
| GET | `/accounts/<id>/onchain/address` | derive next receive address (from watched xpub) |
| GET | `/accounts/<id>/onchain/utxos` | tracked UTXOs |
| POST | `/accounts/<id>/onchain/send` | build PSBT (coin-select, fee-est) → returns PSBT for signing (§8) |
| POST | `/accounts/<id>/onchain/bump` | RBF/CPFP fee-bump → PSBT |

### 6.2 Channels [N]

| Method | Path | Purpose |
|---|---|---|
| GET | `/accounts/<id>/channels` | tenant channels to the companion |
| POST | `/accounts/<id>/channels` | open / fill-up (LSP pay-to-open / splice) → may need a signing round |

## 7. Commerce [C]

Mirror of the existing surface (FEAT-225/226/227/228):
`/accounts/<id>/invoice[/<hash>]`, `/standing-orders[/<so_id>]`,
`/mandates[/<mid>[/charge|/pulls/<pid>/approve|deny]]`,
`/charges[/<cid>[/<action>]]`. Methods/semantics carry over from
`api/spec.md` + the dispatcher; unchanged except the namespace.

## 8. Remote-signer sub-protocol [N] (the novel part)

Non-custodial money-moves and on-chain spends produce a **signing
request** the device must satisfy. The daemon never holds the key.

| Method | Path | Purpose |
|---|---|---|
| POST | `/devices/register/begin` · `/finish` | enroll a device (passkey/PRF-wrapped key); mints `tsess_…` |
| GET | `/sign/next` (long-poll / WS) | device pulls the next pending signing request for its tenant |
| POST | `/sign/<req_id>` | device returns the signature(s) for a request |
| GET | `/sign/state` | fetch the encrypted, monotonically-versioned signer-state blob |
| PUT | `/sign/state` | store a bumped signer-state blob (server enforces monotonicity) |

A signing request carries everything the **validating** signer needs to
check before signing (channel state / PSBT / sighashes); the signer
validates, signs, returns. See `design.md` §6.

## 9. Cloud sync [N] (E2E-encrypted)

Ciphertext only; the server cannot read it. Argon2id-derived keys,
monotonic versioning (see `design.md` §8).

| Method | Path | Purpose |
|---|---|---|
| GET/PUT | `/sync/seed` | encrypted seed backup (for multi-device) |
| GET/PUT | `/sync/meta` | labels, contacts, device registry |
| GET | `/sync/log?since=` | change feed for incremental sync |

## 10. Out of scope (here)

The `lightning`-side `price`/`node`/`decode` are mirrored read-only above
for client convenience; the `users`/passkey identity layer (FEAT-222)
mapping into `thunderd` is an **open decision** (see `roadmap-overview.md`).
</content>
