```
Title: Lightning Well-Known JSON API
Author: nostra124 <nostra124@users.noreply.github.com>
Status: Draft
Type: Standards Track
Created: 2026-05-15
Version: 0.1
License: MIT
```

## Abstract

This document specifies a minimal JSON HTTP API for Lightning
Network nodes published at `.well-known/lightning/<user>/`
alongside the LUD-16 Lightning Address endpoint
(`.well-known/lnurlp/<user>`). The API exposes three
operations — **send**, **recv**, **balance** — per local
user, each authenticated by a per-user API key. The design
target is a single-operator node with one or more virtual
accounts; the API replaces "I have shell access to the
node" with "I have an HTTP endpoint and a key", without
introducing a new authentication system, a new persistence
layer, or a new on-chain pathway.

## Motivation

Lightning Address (LUD-16) already gives an externally-
hostable receive endpoint at `.well-known/lnurlp/<user>`.
What's missing is a symmetric sender endpoint, and a way for
the owner of the node to drive their wallet over HTTP from a
phone, a JS frontend, or another service's webhook — without
exposing shell access, without hosting a custodial layer.

The simplest possible shape is:

- One Python CGI script per endpoint.
- API keys per user, per scope.
- The shell verbs of the underlying node are the source of
  truth; the HTTP layer is a thin frontend.
- LN-to-LN only — on-chain ops stay at the shell.

## Specification

### URL space

Three endpoints per local user `<user>`:

    POST  /.well-known/lightning/<user>/send
    POST  /.well-known/lightning/<user>/recv
    GET   /.well-known/lightning/<user>/balance

`<user>` MUST match the regex `[a-z][a-z0-9_-]*` (LUD-16
compatibility). Servers MUST 404 if `<user>` is not bound
to an account.

### Authentication

Every request MUST include an `X-API-Key` header. Servers
MUST validate it against the per-user key store using a
constant-time comparison.

Two scopes exist:

- `read`  — `GET balance` only.
- `write` — `POST send`, `POST recv`, `GET balance`.

A wrong, missing, or wrong-scope key MUST return
`401 Unauthorized` with an empty body. Servers MUST NOT
leak whether the user exists, whether the key was missing
vs. wrong, or whether the scope was insufficient.

### `POST send`

Request:

    Content-Type: application/json
    X-API-Key: <write-scope key>

    {
      "to":      "user@domain.tld",         // required
      "sat":     <integer, > 0>,            // required
      "message": "<string, ≤ comment_max>", // optional
      "note":    "<string, ≤ 256 bytes>"    // optional
    }

`to` is a LUD-16 Lightning Address (this version). Future
versions MAY accept a raw BOLT-11 invoice or a BOLT-12 offer.

Server flow:

1. Resolve `to` via LUD-16: GET
   `https://<domain.tld>/.well-known/lnurlp/<user>`. Read
   `commentAllowed` from the response.
2. Truncate `message` to `commentAllowed` bytes. If the
   payer-supplied `message` is non-empty and the remote's
   `commentAllowed` is `0`, the server MUST return
   `400 Bad Request` (don't silently drop the message).
3. Hit the callback URL with
   `?amount=<sat * 1000>&comment=<message-url-encoded>`.
4. Receive a BOLT-11 invoice whose description contains
   (or commits to) the comment via LUD-12.
5. Apply the local spending policy (see §Spending
   guardrails).
6. Pay the BOLT-11. Append one row to the local ledger with
   `direction=out`, `peer=<to>`, `message=<message>`,
   `note=<note>`.

Success response:

    200 OK
    Content-Type: application/json

    {
      "payment_hash": "<hex, 64 chars>",
      "fee_sat":      <integer ≥ 0>,
      "preimage":     "<hex, 64 chars>"
    }

Error responses:

| Code | Condition                                                |
|------|----------------------------------------------------------|
| 400  | Missing required field; message > remote `commentAllowed`|
| 401  | Auth failure (see §Authentication)                       |
| 402  | Overdraft policy `deny` would be violated                |
| 404  | `<user>` not bound                                       |
| 502  | Resolving `to` failed at the remote                      |
| 503  | Local node not reachable / not synced                    |

### `POST recv`

Request:

    Content-Type: application/json
    X-API-Key: <write-scope key>

    {
      "sat":     <integer, > 0>,            // required
      "message": "<string, ≤ 256 bytes>"    // optional
    }

Server flow:

1. Mint a BOLT-11 via the local node, setting the invoice
   description to `message` (or empty if absent).
2. Insert into the local `invoices` table with state
   `pending`.

Success response:

    200 OK
    Content-Type: application/json

    {
      "bolt11":       "<lower-case bech32 string>",
      "payment_hash": "<hex, 64 chars>",
      "expiry":       "<RFC-3339 UTC>"
    }

When the invoice eventually settles, the server appends a
ledger row with `direction=in`, `message` carried from the
invoice description, `note=""` (the operator may fill it
later via `lightning ledger annotate`).

### `GET balance`

Request:

    X-API-Key: <read- or write-scope key>

Success response:

    200 OK
    Content-Type: application/json

    {
      "balance_sat": <integer; signed; in sat>,
      "limit_sat":   <integer or null>,        // null = no limit
      "overdraft":   "deny" | "warn" | "allow"
    }

`balance_sat` is the net of the account's ledger rows in
sat (msat / 1000, rounded toward zero). Clients that need
msat precision SHOULD use a different transport — the API
is deliberately sat-grained for simplicity.

### Spending guardrails

Each account has a `limit_sat` (optional ceiling) and an
`overdraft` policy. Before paying, the server computes:

    candidate_balance = balance_sat - sat - fee_estimate_sat

and acts per policy:

| `overdraft` | Behaviour                                        |
|-------------|--------------------------------------------------|
| `deny`      | If `candidate_balance < 0`, return `402`.        |
| `warn`      | Proceed; log a warning server-side.              |
| `allow`     | Proceed silently.                                |

`limit_sat`, when set, is a hard ceiling: if
`balance_sat - sat > limit_sat` (i.e. the account's spend in
the current period would exceed the limit), return `402`.

### Logging

Every request MUST be logged with timestamp, endpoint,
user, remote IP, HTTP status. The log SHOULD NOT include
the API key, the payment preimage, or the BOLT-11 / BOLT-12
string.

### What this specification does NOT define

- Account creation, deletion, or naming. These are
  implementation-specific.
- On-chain operations. The API never moves on-chain funds.
- Streaming endpoints or webhooks. The model is
  request/response.
- Multi-user authentication. API keys are per-account, not
  per-account-holder.
- Schema or storage. The reference implementation uses
  SQLite; other implementations are free to choose.

## Rationale

### Why CGI?

CGI keeps every endpoint a single file that can be read end
to end. There is no framework, no long-running process, no
session state. Each request is a fresh subprocess; failures
are isolated. This makes the security audit surface a
function of "what does each .py file shell out to" — easy
to grep, easy to lock down via the operating system's
existing tools (sudo, mod_suexec).

### Why three endpoints?

A wallet has three observable operations to an external
caller: spend, accrue, query. `send`, `recv`, and `balance`
map one-to-one. Adding more endpoints (list invoices,
recent transactions, channel ops) was considered and
rejected for v0.1 — the operator can always reach for the
shell.

### Why not bearer tokens?

Bearer tokens are equivalent to `X-API-Key` here; both are
shared secrets in a header. We use the API-Key naming
because the semantic is per-account-per-scope, not
per-session-per-user. Servers MAY also accept
`Authorization: Bearer <key>` for client convenience but
MUST treat the value identically.

### Why LUD-12 for the message?

LUD-12 is what Lightning Address wallets implement today. A
sender setting the `comment` parameter on an LNURL-pay
callback is exactly the right shape for "attach a message
that the recipient will see". Reusing it means no new
protocol, no new BOLT, no new field — just a JSON binding
on top of an existing standard.

### Why a local-only `note`?

Receipts, expense categories, "what was this for again" —
this metadata wants to stay private to the operator. There
is no place in the LN payment flow to attach a payload that
the sender sees but the recipient doesn't (the directions
are reversed). Storing it locally is the only honest
answer.

## Backwards Compatibility

This is the first version of the specification. There is
nothing to be backwards-compatible with. Future versions
will increment `Version:` and document the diff.

## Reference Implementation

`nostra124/lightning`, in particular:

- `share/lightning/wellknown/lightning/{send,recv,balance}.py`
- `share/lightning/wellknown/lnurlp/handler.py` (for the
  LUD-12 inbound side)
- `share/lightning/apache/lnurlp.conf` (the vhost
  ScriptAlias snippet)
- `libexec/lightning/api-{send,recv,balance,lnurlp,verify}`
  (the shell verbs the CGI scripts shell into)

See FEAT-176, FEAT-193, FEAT-195, FEAT-196 in
`issues/feature/` for the design history.

## Acknowledgments

The shape of LUD-12 (`commentAllowed`) made the message
plumbing trivial. The three-user privilege layout
(`clightning` / operator / `www-data`) is the
postfix / dovecot pattern adapted to Lightning.

## Copyright

This document is released under the MIT license.
