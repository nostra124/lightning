---
id: FEAT-212
type: feature
priority: high
status: in-progress
---

# Account-centric HTTP API with self-service creation

## Description

**As a** third-party app talking to a system-mode `lightning` install
**I want** to create an account self-service, get an API key back,
and use it to receive / send / top up / withdraw on that account
**So that** the operator doesn't have to manually provision every
account, and accounts are addressable via a stable, opaque identifier
that doubles as their on-chain top-up address.

System-mode only (FEAT-183 three-user layout: `clightning`,
operator, `www-data`).  User-mode operators stay on the CLI;
nothing in this ticket affects them.

## The model in one sentence

**An account's ID is a Bitcoin address derived from lightningd's
seed.  That address doubles as the account's on-chain top-up
destination.  The HTTP API keys off the address; the operator-side
CLI lets the operator attach human nicknames locally.**

## What changes vs the existing HTTP API (FEAT-196)

Today (FEAT-176 + FEAT-196):

- Accounts are operator-created (`lightning account create rent`).
- HTTP paths use `<user>` as a stand-in for the account name —
  `.well-known/lightning/<user>/balance`.
- The Lightning address Apache vhost is wired up via `address
  create user@host`.
- API keys are issued out-of-band (`account apikey create`).
- Endpoints cover: `balance`, `recv` (BOLT-11), `send` (LN-address
  only), `verify`.

After FEAT-212:

- Accounts are caller-created via `POST /api/accounts`.  Anonymous
  (no auth needed for creation itself).
- The account's **ID is a Bitcoin address** (`bc1q...`) returned by
  `lightning-cli newaddr` at creation time.  Persists for the
  lifetime of the account.
- The HTTP API returns the ID + an API key in the create response;
  the key is the ONLY time it's shown.
- All mutating + read endpoints require `Authorization: Bearer
  <api_key>` (same key for read and write — kept simple).
- `POST /api/accounts/<id>/close` revokes the key and marks the
  account inactive.  Closed accounts with zero balance are
  garbage-collected by a cleanup cron after a grace period.
- New endpoints: `topup`, `withdraw`, `pay` (broader shapes than
  the current `send`), `recv-reusable` (BOLT-12 offer).

## Why account-ID = Bitcoin address

Two wins for free:

1. **The ID is the top-up address.**  `POST /api/accounts/<id>/topup`
   isn't really needed — the caller already has the address from
   the create response.  We still expose a `GET /api/accounts/<id>/topup`
   for convenience (returns the address + BIP-21 URI + QR text).
2. **Self-attribution of on-chain deposits.**  Each account has a
   unique address; an on-chain deposit lands in lightningd's UTXO
   set against a known address.  A watcher cron matches new UTXOs
   to known account-addresses and credits the ledger accordingly.
3. **CLI parity** — operators on the CLI can also use Bitcoin-
   address account IDs as a stable handle (`lightning account show
   bc1q...`), with a separate nickname store (operator-local) that
   maps `rent` → `bc1q...` for readability.

The address is derived from clightning's HSM seed via BIP-32
(whatever derivation `newaddr` uses).  No new derivation logic on
our side; we just remember which address belongs to which account.

## Surface

### HTTP endpoints

```
POST /api/accounts                  open / anonymous
    body:    {"hint": "optional human label, not stored server-side"}
    return:  { "account_id": "bc1q...",
               "api_key": "lt_<48-base64url-chars>",
               "topup_uri": "bitcoin:bc1q...",
               "endpoints": { ... links to relative paths ... } }

GET  /api/accounts/<id>/balance     Authorization: Bearer <key>
    return:  { "balance_sat": <int>, "limit_sat": <int|null>,
               "overdraft": "deny|warn|allow" }

GET  /api/accounts/<id>/topup       Authorization: Bearer <key>
    return:  { "address": "bc1q...", "uri": "bitcoin:...?amount=...",
               "qr_text": "..." }
    optional ?sat=<int> to set amount in the BIP-21 URI

POST /api/accounts/<id>/withdraw    Authorization: Bearer <key>
    body:    {"sat": <int>, "address": "bc1q..."}
    return:  { "swap_id": "...", "status": "created" }

POST /api/accounts/<id>/pay         Authorization: Bearer <key>
    body:    {"target": "<bolt11|bolt12|lnurl|addr|node-pubkey>",
              "sat": <int>}     (sat optional except for keysend)
    return:  { "payment_hash": "...", "amount_sat": <int>,
               "fee_sat": <int> }

POST /api/accounts/<id>/recv        Authorization: Bearer <key>
    body:    {"sat": <int>, "description": "<text>"}
    return:  { "bolt11": "lnbc...", "payment_hash": "...",
               "amount_sat": <int> }

POST /api/accounts/<id>/recv-reusable    Authorization: Bearer <key>
    body:    {"sat": <int>|"any", "description": "<text>"}
    return:  { "bolt12": "lno1...", "offer_id": "..." }

POST /api/accounts/<id>/close       Authorization: Bearer <key>
    return:  { "status": "closed" }     (200)
                — revokes the key; account row marked inactive
```

### CLI changes

```
lightning account create [<nickname>]
    Existing nickname-as-primary-key model stays for OS operators;
    additionally generates a Bitcoin address + API key under the
    hood and prints them out.  Caller can save either as the
    handle they use.

lightning account nickname add <bc1q...> <name>
    Local-only alias for operator readability.  Persisted under
    $wallet/accounts/nicknames.recfile.  Never sent over the wire.

lightning account show <bc1q...|nickname>
    Looks up by ID or by nickname.  Already-existing show verb
    learns the address lookup.

lightning account close <bc1q...|nickname>
    Mirrors POST /api/accounts/<id>/close.  Revokes API key,
    marks inactive.

lightning account list [--inactive]
    Shows the address as the canonical column; nickname column
    is operator-local.
```

### Cleanup sidecar (cron job)

```
lightning account gc [--dry-run]
    Iterates accounts, removes API keys + marks inactive (or
    deletes) accounts that meet the criteria:
      - balance_sat == 0
      - no API call in the last LIGHTNING_ACCOUNT_GC_DAYS days
        (default 90)
      - no pending in-flight payment or open invoice

    Closed accounts are kept for a shorter grace window
    (LIGHTNING_ACCOUNT_GC_CLOSED_DAYS, default 7) before deletion.

lightning daemon install --account-gc
    Opt-in sidecar timer (daily) that runs the GC.  Same pattern
    as --autopilot.
```

## Rate-limiting

Account creation is the only anonymous endpoint, so it's the
primary spam vector.  Three layers:

1. **Apache-level**: the operator configures `mod_ratelimit` or
   `mod_qos` to cap creates per IP per minute.  Our install verb
   writes a sane default into the vhost.
2. **Application-level**: `api-accounts-create` shell verb checks
   the last N seconds of create-events for the source IP via
   `$LIGHTNING_DIR/account-creates.log` (rolling tail).  Tunable
   via `LIGHTNING_ACCOUNT_CREATE_RATE` (creates/minute, default 6).
3. **GC + low default limit**: anonymous accounts ship with
   `limit_sat=100000` and `overdraft=deny`.  Operator can promote
   an account via CLI to raise.

## MCP endpoint (for LLM agents)

LLM agents (Claude Code, IDE assistants, autonomous workflows)
don't know how to read a human-prose REST API.  They consume
**MCP (Model Context Protocol)** — Anthropic's open protocol where
a server exposes typed tools + resources + prompts, and the agent
discovers and invokes them natively.

We expose the same account-centric surface as MCP alongside the
REST endpoints, so an LLM agent can do "use my Lightning account
to pay this invoice" without bespoke per-app integration.

### Mapping REST endpoints → MCP tools

Each REST endpoint becomes one MCP tool with a JSON Schema input
descriptor.  Same auth model — bearer token in the connection's
init message.

| MCP tool name          | Backed by REST endpoint               | Inputs |
|------------------------|---------------------------------------|--------|
| `account_create`       | `POST /api/accounts`                  | none (anonymous) |
| `account_balance`      | `GET /api/accounts/<id>/balance`      | account_id |
| `account_topup`        | `GET /api/accounts/<id>/topup`        | account_id, sat? |
| `account_withdraw`     | `POST /api/accounts/<id>/withdraw`    | account_id, sat, address |
| `account_pay`          | `POST /api/accounts/<id>/pay`         | account_id, target, sat? |
| `account_recv`         | `POST /api/accounts/<id>/recv`        | account_id, sat, description? |
| `account_recv_reusable`| `POST /api/accounts/<id>/recv-reusable` | account_id, sat\|"any", description? |
| `account_close`        | `POST /api/accounts/<id>/close`       | account_id |

Plus MCP resources for read-only data the agent might want to
poll or stream:

| Resource URI            | What it returns |
|-------------------------|-----------------|
| `account://<id>`        | full account record (balance + recent ledger) |
| `account://<id>/ledger` | ledger entries (paged) |
| `account://<id>/topup`  | live BIP-21 URI + QR text |

### Transport

MCP over **plain HTTP + JSON-RPC 2.0**.  POST `/api/mcp`, body
is a JSON-RPC envelope, response is the JSON-RPC result.  No SSE
on this server — the tool surface is request/response only, so
the streaming side of the MCP "Streamable HTTP" transport
(server-initiated messages back over GET+SSE) isn't needed.

Implementation: **CGI script** at
`share/lightning/wellknown/api/mcp.py`, stdlib-only (no FastAPI,
no `mcp` SDK).  The protocol pieces we need — initialize,
tools/{list,call}, resources/{list,read}, prompts/list, ping —
are a few hundred lines of straightforward JSON-RPC handling.
Earlier plans for an ASGI long-runner were dropped: every call
on our surface terminates synchronously, so the per-request
fork-and-die of CGI is fine, and we keep the no-new-deps
posture of the rest of `wellknown/`.

If a future tool needs real streaming (e.g. wait for an invoice
to settle), it lands as a separate SSE endpoint without
disturbing existing callers — the MCP spec allows the two
transports to coexist on the same server.

### Discovery

Two ways an agent learns the server exists:

1. **Standard MCP transport**: agent connects to
   `/.well-known/lightning/mcp/sse` and lists tools via the
   protocol's `tools/list` method.  Self-describing.
2. **Static manifest** at `/.well-known/lightning/mcp.json` — a
   one-shot JSON file describing the server (URL, transport,
   tool list, auth hint).  Lets non-MCP-aware tools at least know
   the server is there.

### Authentication

Same bearer token as the REST API.  Two-phase:

- **Anonymous MCP connection** can only call `account_create` (and
  read public resources like server info).  Same anonymous bucket
  as `POST /api/accounts` over REST.
- **Authenticated connection** (Bearer header sent during the SSE
  HTTP upgrade) unlocks tools scoped to that account_id.  The
  server validates the token against the address derived from the
  init headers' `X-Account-Id` (or equivalent).

### Why CGI is enough

The MCP "Streamable HTTP" transport spec mandates SSE only for
servers that push server-initiated messages back to the client
(progress updates, sampling requests, log records).  Our tool
surface doesn't — every call returns a complete result
synchronously.  Under that constraint plain POST / JSON-out is
within the protocol, and CGI is fine.

This also removes the systemd-sidecar moving part the spec
originally envisaged.  No `daemon install --mcp` needed; the
endpoint is live the moment Apache restarts with the new
vhost stanza.

### Out of scope (for the MCP layer)

- **Tool-call streaming** beyond what SSE naturally provides.
  Long-running tool calls (e.g., waiting for an invoice to settle)
  return synchronously with the final result; no progress events.
  Can be added in a follow-up.
- **MCP prompts** — the spec calls out prompts as a separate
  primitive; we don't expose any until a user-facing template
  makes sense.
- **Multi-account auth** — one connection ↔ one account.  An agent
  managing multiple accounts opens multiple connections (cheap on
  SSE) or rotates `account_create` calls.

## Auth flow

API key format: `lt_` + 32 bytes of `/dev/urandom` base64url-
encoded (43 chars after stripping padding).  Total 46 chars.
Stored server-side under `secret put lightning.account.<id>.apikey`.

`Authorization: Bearer <key>` on every authenticated request.
The CGI script extracts, calls `api-verify <id> write <key>` (the
existing verify verb learns the new ID-keyed lookup).  Reject with
401 on mismatch; 404 on unknown ID.

## Schema

Two new columns on `accounts`:

```sql
ALTER TABLE accounts ADD COLUMN address TEXT;          -- bc1q... (the ID)
ALTER TABLE accounts ADD COLUMN created_at INTEGER;    -- unix epoch
ALTER TABLE accounts ADD COLUMN closed_at  INTEGER;    -- nullable; set on close
ALTER TABLE accounts ADD COLUMN last_api_call_at INTEGER;  -- for GC
```

Old name-keyed accounts continue to work — `address` stays NULL
for them, identifying them as "operator-created legacy" accounts.
The HTTP API rejects requests for accounts without an address.

The nickname mapping lives in a separate recfile (not the SQLite
schema):

```
# $wallet/accounts/nicknames.recfile
nickname: rent
address: bc1q...
%
nickname: club
address: bc1q...
```

## Acceptance criteria

1. `POST /api/accounts` on a fresh system returns a 201 with a
   `bc1q...` ID, an `lt_...` API key, and a BIP-21 URI.
2. The same address is what `lightning-cli newaddr` yielded
   internally; sending sats to it credits the account when the
   deposit watcher (next ticket — see "Phasing" below) runs.
3. Any authed endpoint (`/balance`, `/recv`, ...) returns 401 if
   the bearer key doesn't match the address.
4. `POST /api/accounts/<id>/close` revokes the key.  Subsequent
   calls return 401.
5. `lightning account gc --dry-run` lists accounts that would be
   GC'd (balance=0, last_api_call > 90 days ago).
6. `lightning account gc` (no flag) revokes keys + marks closed
   the accounts the dry-run identified.
7. Rate limit: a 7th account create within 60 seconds from the
   same IP returns 429.
8. Bats coverage for each new CLI verb; pytest coverage for each
   new HTTP endpoint with mocked verb output.

## Phasing (PR plan)

Single ticket, multiple PRs:

1. **PR-1 (CLI foundation)** — extend `account create` to mint
   the address + API key; add `account close`, `account
   nickname`.  Schema migration.  No HTTP yet.
2. **PR-2 (HTTP endpoints)** — wire up the 8 new endpoints over
   the existing CGI pattern; new `api-accounts-create`,
   `api-account-close`, `api-account-topup`, `api-account-withdraw`,
   `api-account-pay`, `api-account-recv-reusable` shell verbs.
   Rate limiting at the apache + verb layer.
3. **PR-3 (MCP endpoint)** — Python ASGI process + the official
   `mcp` SDK; reverse-proxied by Apache.  Exposes the 8 REST
   endpoints as MCP tools + the three resources.  Sidecar service
   (long-running, not cron) via `daemon install --mcp`.  Static
   manifest at `/.well-known/lightning/mcp.json`.
4. **PR-4 (Deposit watcher)** — `account topup-watcher` cron that
   matches new UTXOs to known account addresses and credits the
   ledger.  Sidecar timer via `daemon install --topup-watcher`.
5. **PR-5 (GC sidecar)** — `account gc` verb + `daemon install
   --account-gc` sidecar.

PR-1 + PR-2 land first since they're the minimum for an external
caller (or human via curl) to do anything useful.  PR-3 (MCP)
follows once REST is stable so the MCP tools have something to
wrap.  PR-4 and PR-5 don't block each other.

## Out of scope (separate tickets / future)

- **Custodial pooling** — every account stays funded by its own
  on-chain deposits.  No "operator can move sats between accounts"
  primitive in this ticket; would need separate audit / regulation
  thought.
- **OAuth / OIDC** — bearer token only.  Identity-federated auth
  is a separate concern (FEAT-209's BaweePay direction).
- **REST-level WebSocket push** — REST endpoints stay
  request/response.  MCP-over-SSE (PR-3) covers the streaming /
  agent-driven use case; a separate REST-side push channel can
  land later if there's demand.
- **Refresh tokens** — the API key is the only credential.  Lost
  key = closed account (operator can re-issue manually via the
  CLI if needed).
- **MCP prompts** — the protocol allows servers to expose
  parameterised prompts; we don't ship any until a user-facing
  template earns its place.

## Milestone

1.5.0.

## See also

- FEAT-174 — account + ledger primitives (this extends the
  account schema).
- FEAT-176 — Lightning Address Apache vhost (the CGI hosting
  pattern this builds on).
- FEAT-183 — system-mode three-user layout (the install context
  these endpoints assume).
- FEAT-195 — bank-mode overdraft + API key model (this picks up
  the key-issuance plumbing).
- FEAT-196 — existing .well-known/lightning/ JSON API (this
  augments and partially supersedes it).
- FEAT-205 — channel autopilot (the existing cron sidecar
  pattern the GC + topup-watcher follow).
- FEAT-211 — account-centric CLI surface (the CLI verb shapes
  this HTTP API mirrors).
