---
id: FEAT-196
type: feature
priority: medium
status: open
---

# Lightning `.well-known/lightning/` JSON API

## Description

**As a** Lightning user who already publishes
`alice@example.com` via FEAT-176
**I want** a tiny JSON API at
`https://example.com/.well-known/lightning/<user>/{invoice,send,balance}`
that lets external clients (a phone, a script, another
node's webhook) receive payments to alice's account and
send to other `user@domain` addresses
**So that** Lightning becomes scriptable over HTTP from any
language, not just shell-on-the-node — and so my own little
JS frontend can drive the wallet without ever logging into
the box.

Extends the Apache-CGI + Python pattern from FEAT-176 into
a `lightning` namespace. Each endpoint is one small Python
file (< 100 lines, stdlib only) that:

1. Reads `<user>` from `PATH_INFO`.
2. Validates `X-API-Key` against the per-account key stored
   in `secret` (FEAT-184).
3. Shells out to the appropriate `lightning ...` verb.
4. Returns JSON.

The shell verbs (FEAT-172 / 173 / 176 / 193) remain the
source of truth; the Python files are thin HTTP frontends.

## Implementation

### Endpoints

Three to start:

    POST /.well-known/lightning/<user>/invoice
        body: {"sat": 1000, "memo": "coffee"}
        auth: X-API-Key (read+write key)
        returns: {"bolt11": "lnbc...", "payment_hash": "..."}

    POST /.well-known/lightning/<user>/send
        body: {"to": "user2@domain2.com", "sat": 500,
               "comment": "thanks"}
        auth: X-API-Key (read+write key)
        returns: {"payment_hash": "...", "fee_sat": 1,
                  "preimage": "..."}

    GET  /.well-known/lightning/<user>/balance
        auth: X-API-Key (read-only OR read+write)
        returns: {"balance_sat": 12400,
                  "limit_sat": 50000,
                  "overdraft": "deny"}

All `<user>` values must exist in FEAT-176's `users.tsv`.

### Files

One script per endpoint, mirroring the URL shape:

    share/lightning/wellknown/lightning/
      invoice.py
      send.py
      balance.py
      _lib.py          # shared 30-line helper: parse PATH_INFO,
                       #   validate API key, run() wrapper

`_lib.py` is the single allowed shared module. Endpoint
scripts call into it; they don't reach across each other.

### API keys

Per-account, stored via `secret` under:

    lightning.<account>.apikey.<scope>

Two scopes:
- `read`     — balance only
- `write`    — invoice + send + balance

Two issued by `lightning account apikey create <account>
--scope <read|write>` (lands with FEAT-195 — see
cross-reference there).

Each script does constant-time comparison via
`hmac.compare_digest`. Wrong / missing key → HTTP 401, no
body details.

### Spending guardrails

`send.py` consults FEAT-195's overdraft policy before
calling `lightning address pay`:

- `deny`  — rejects with HTTP 402 if the send would
            overdraw.
- `warn`  — proceeds (no warning surface in JSON; logged
            server-side).
- `allow` — proceeds silently.

`--limit` from FEAT-195 is a hard ceiling for `send.py`.

### Apache wiring

The same vhost snippet from FEAT-176 gains a second
`ScriptAlias` block:

    ScriptAlias /.well-known/lightning/ \
        /usr/share/lightning/wellknown/lightning/

URL rewriting (mod_rewrite) routes
`/<user>/{invoice,send,balance}` to the right endpoint
script while preserving `<user>` in PATH_INFO.

### Logging

Each invocation appends one row to
`/var/log/lightning/api.log` (TSV: ts, endpoint, user,
remote-ip, status). Rotated by logrotate; sample logrotate
config shipped under `share/lightning/logrotate/`.

### What this explicitly does NOT do

- No web UI. Just JSON in / JSON out.
- No streaming endpoints. Polling for status.
- No long-running connections. CGI = request/response.
- No account management endpoints. Account lifecycle is
  shell-only (FEAT-174 / 195).
- No multi-user authentication. API keys per account, not
  per holder.

## Acceptance Criteria

1. `POST /.well-known/lightning/alice/invoice` with a valid
   write-scope API key and `{"sat": 1000}` returns a
   parseable JSON object containing a valid BOLT-11 string.
2. `POST .../alice/send` with `{"to": "bob@example.com",
   "sat": 500}` resolves bob's Lightning Address (FEAT-176)
   and pays it, returning the payment hash + fee.
3. `GET .../alice/balance` returns the current balance + the
   limit + overdraft policy from FEAT-195.
4. Wrong API key → HTTP 401 with no body details
   (resistant to oracle attacks).
5. `send.py` with overdraft=`deny` and insufficient balance
   → HTTP 402, no payment made.
6. SIT (FEAT-182) covers all three endpoints round-trip
   inside an Apache-equipped clightning regtest container.
7. Each endpoint script is < 100 lines of Python 3 (stdlib
   only) excluding `_lib.py`.
