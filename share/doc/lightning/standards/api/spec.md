# `.well-known/lightning/` JSON API — specification

**Version:** 0.1.0 (FEAT-196)
**Status:** Draft

## 1. URL Space

All endpoints live under `/.well-known/lightning/<user>/`.
`<user>` matches `[a-z][a-z0-9_-]*` and must exist in the
wallet's `users` table (FEAT-176).

| Method | Path                          | Scope | Description          |
|--------|-------------------------------|-------|----------------------|
| POST   | `/.well-known/lightning/<user>/recv`    | write | Mint a BOLT-11 invoice |
| POST   | `/.well-known/lightning/<user>/send`    | write | Send to a Lightning Address |
| GET    | `/.well-known/lightning/<user>/balance` | read  | Get account balance + limit |

## 2. Authentication

Header: `X-API-Key: <key>`.

Keys are issued by `lightning account apikey create <name> --scope read|write`
and stored via the `secret` package under `lightning.<name>.apikey.<scope>`.

Wrong or missing key → HTTP 401 with empty body (oracle-resistant).

## 3. Endpoints

### 3.1 POST /recv

**Request:**
```json
{"sat": 1000, "message": "invoice for consulting"}
```

**Response (200):**
```json
{"bolt11": "lnbcrt10n1...", "payment_hash": "abc..."}
```

**Errors:** 400 (missing/invalid body), 401 (auth), 502 (backend).

The invoice is minted with `--account <user>` so it tags the
ledger with the correct account. The `message` becomes the
BOLT-11 description.

### 3.2 POST /send

**Request:**
```json
{"to": "bob@example.com", "sat": 500, "message": "thanks", "note": "march coffee"}
```

`message` travels to the remote via LUD-12 comment (truncated
to remote's `commentAllowed`). `note` is local-only and written
to the ledger's `note` column.

**Response (200):**
```json
{"payment_hash": "abc...", "fee_sat": 1}
```

**Errors:** 400, 401, 402 (overdraft policy), 502 (backend).

Spending guardrails: before paying, the endpoint consults
the account's overdraft policy and limit (FEAT-195). If
`overdraft=deny` and the send would exceed the balance,
HTTP 402 is returned with no payment made.

### 3.3 GET /balance

**Request:** No body.

**Response (200):**
```json
{"balance_sat": 12400, "limit_sat": 50000, "overdraft": "deny"}
```

`limit_sat` is null when no limit is set.

**Errors:** 401 (auth).

## 4. Privilege Model

Three Unix users (FEAT-183):

| User         | Role                          |
|--------------|-------------------------------|
| `clightning` | Runs `lightningd`             |
| `alice`      | Operator, runs `lightning` CLI |
| `www-data`   | Runs Apache + CGI scripts     |

The CGI scripts never talk to `lightningd` directly. They
`sudo -u alice lightning api-<verb> <user> <args>`. The
`api-*` verbs validate their arguments strictly before
acting.

## 5. Logging

Each invocation appends to `/var/log/lightning/api.log` (TSV):

    <ts>	<endpoint>	<user>	<remote-ip>	<status>

## 6. Out of Scope

- No on-chain operations (deposits / withdrawals).
- No web UI — JSON in/out only.
- No streaming or long-lived connections.
- No account management endpoints.
- No multi-user authentication.
