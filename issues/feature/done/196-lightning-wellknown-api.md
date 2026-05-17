---
id: FEAT-196
type: feature
priority: medium
status: done
---

# Lightning `.well-known/lightning/` JSON API

## Description

**As a** Lightning user who already publishes
`alice@example.com` via FEAT-176
**I want** a tiny JSON API at
`https://example.com/.well-known/lightning/<user>/{send,recv,balance}`
that lets external clients (a phone, a script, another
node's webhook) receive payments to alice's account and
send to other `user@domain` addresses
**So that** Lightning becomes scriptable over HTTP from any
language, not just shell-on-the-node.

Extends the Apache-CGI + Python pattern from FEAT-176 into
a `lightning` namespace. Each endpoint is one small Python
file (< 100 lines, stdlib only). The shell verbs
(FEAT-172 / 173 / 176 / 193) remain the source of truth;
the Python files are thin HTTP frontends.

**Scope boundary.** The JSON API is purely LN-to-LN.
On-chain ops — depositing to the LN node's chain wallet,
withdrawing via channel close or `lightning-cli withdraw` —
are operator-only via the shell. No HTTP endpoint moves
on-chain funds.

## Implementation

### Endpoints (three, symmetric)

    POST /.well-known/lightning/<user>/send
        body: {"to": "user2@domain2.com",
               "sat": 500,
               "message": "thanks for the coffee",
               "note":    "march coffee budget"}
        auth: X-API-Key (write scope)
        returns: {"payment_hash": "...",
                  "fee_sat": 1,
                  "preimage": "..."}

    POST /.well-known/lightning/<user>/recv
        body: {"sat": 1000,
               "message": "invoice for consulting"}
        auth: X-API-Key (write scope)
        returns: {"bolt11": "lnbc...",
                  "payment_hash": "..."}

    GET  /.well-known/lightning/<user>/balance
        auth: X-API-Key (read scope OR write scope)
        returns: {"balance_sat": 12400,
                  "limit_sat":   50000,
                  "overdraft":   "deny"}

All `<user>` values must exist in FEAT-176's `users.tsv`.

### Files

One script per endpoint, mirroring the URL shape:

    share/lightning/wellknown/lightning/
      send.py
      recv.py
      balance.py
      _lib.py          # shared 30-line helper: parse PATH_INFO,
                       #   validate API key, run() wrapper

`_lib.py` is the single allowed shared module. Endpoint
scripts call into it; they don't reach across each other.

### Message and note plumbing

Two metadata fields on `send`, one on `recv`. The plumbing
relies on LUD-12 (LNURL-pay `comment`), which Lightning
Address handlers honour today.

**On `send`:**

1. `send.py` resolves `to` via the standard Lightning Address
   flow (FEAT-176): fetches the LNURL-pay metadata, reads
   `commentAllowed` (max comment length the remote will
   accept).
2. Truncates `message` to that length (or rejects with
   HTTP 400 if zero / missing and remote demands one — we
   don't ship `message` if remote can't carry it).
3. Hits the remote's callback with
   `?amount=<msat>&comment=<message>`. The remote mints a
   BOLT-11 with `message` in the description.
4. We pay the BOLT-11.
5. On success, append one ledger row (FEAT-193) with:
   - `direction = out`
   - `peer = user2@domain2.com`
   - `message = <message>`  (what travelled)
   - `note    = <note>`     (local-only)

**On `recv`:**

1. `recv.py` calls `lightning invoice <sat> <message>` via
   the privileged hop (see below). The message goes into
   the BOLT-11 description.
2. Returns the BOLT-11 to the caller.
3. When the invoice settles, the matching ledger row carries
   `message = <message>` and `note = -` (annotate later via
   `lightning ledger annotate`).

**Inbound from LUD-12 comment** (FEAT-176 handler.py path):
when an external payer hits `/.well-known/lnurlp/alice` with
`?amount=X&comment=Y`, the handler stores the comment so
that the settling ledger row gets `message = Y`. This is
the symmetric inbound case to our outbound `send` above —
external Lightning Address wallets carry messages exactly
the same way.

**Why this works on both BOLT-11 and BOLT-12:**

- BOLT-11 invoice descriptions are set by the receiver. The
  LNURL-pay round-trip is what turns sender-side text into
  receiver-set invoice text — the LUD-12 comment is echoed
  into the description hash.
- BOLT-12 offers have `payer_note` natively; `send.py`
  prefers the offer path when the target presents one
  (deferred to a follow-on; v1 only does LNURL-pay).

### Privileged hop: three users, two boundaries

Recommended layout for any node that hosts addresses or the
web API (FEAT-183 system-mode):

| User         | What it does                                               |
|--------------|------------------------------------------------------------|
| `clightning` | runs `lightningd`; owns `/var/lib/clightning/`             |
| `alice`      | operator; runs `lightning` CLI; owns the wallet repo +     |
|              | `secret` store; member of group `clightning`               |
| `www-data`   | runs Apache + the CGI scripts                              |

Apache executes the CGI scripts as `www-data`. They cannot
directly read:

- `/var/lib/clightning/<network>/lightning-rpc` (mode 0660,
  group `clightning`; `www-data` is **not** in that group)
- `~alice/.password-store/` (mode 0700; alice-only)
- `~alice/.lightning/wallet/<name>/ledger.tsv` (alice-owned)

The CGI scripts also can't run `lightning-cli` directly —
they're not in the `clightning` group. The bridge is
sudo-to-alice, not sudo-to-clightning: this gives the API a
single funnel through `lightning` (which already has the
right group membership and the right secret-store access),
rather than scattering capabilities across two boundary
crossings.

**Solution: a narrow sudoers fragment** shipped at
`share/lightning/sudoers.d/lightning`:

    # /etc/sudoers.d/lightning  (installed by `make install`
    # only if the operator runs `make install-apache-bridge`
    # — we don't drop sudoers files silently)
    www-data ALL=(alice) NOPASSWD: \
        /usr/local/bin/lightning api-recv [a-z][a-z0-9_-]* [0-9]* *, \
        /usr/local/bin/lightning api-send [a-z][a-z0-9_-]* * [0-9]* *, \
        /usr/local/bin/lightning api-balance [a-z][a-z0-9_-]*, \
        /usr/local/bin/lightning api-verify [a-z][a-z0-9_-]* read|write *

Each CGI script does exactly one `sudo -u alice lightning
api-<verb> <user> <args>`. The `api-*` verbs are a
sudo-friendly facade with strict argument validation
(numeric `sat`, lowercase `user` matching FEAT-176's
`users.tsv` regex, etc.); the sudoers globs enforce shape
once more. No free-form arguments cross the privilege
boundary.

`lightning api-verify <account> <scope> <key>` checks the
key against `secret get lightning.<account>.apikey.<scope>`
and exits 0/1. The CGI scripts gate every request through
it; key material never reaches www-data's memory.

**Alternative: mod_suexec.** For operators who prefer not to
use sudo, `share/lightning/apache/suexec.conf` documents the
mod_suexec setup (per-vhost SuexecUserGroup). It works but
requires Apache to be built with suEXEC enabled and the
script + parent dir owned by alice. The sudoers path is the
default; suEXEC is a documented opt-in.

### API keys

Per-account, stored via `secret` under:

    lightning.<account>.apikey.<scope>

Two scopes:
- `read`     — balance only
- `write`    — send + recv + balance

Issued by `lightning account apikey create <account> --scope
<read|write>` (FEAT-195). Constant-time comparison via
`hmac.compare_digest`. Wrong / missing key → HTTP 401, no
body details.

### Spending guardrails

`send.py` consults FEAT-195's overdraft policy via
`lightning api-balance <account>` (returns
balance + limit + policy) before hitting the remote:

- `deny`  — rejects with HTTP 402 if the send would
            overdraw.
- `warn`  — proceeds (no warning surface in JSON; logged
            server-side).
- `allow` — proceeds silently.

`--limit` from FEAT-195 is a hard ceiling.

### Apache wiring

The same vhost snippet from FEAT-176 gains a second
`ScriptAlias` block + a `RewriteRule` so the URL shape stays
clean:

    ScriptAliasMatch "^/.well-known/lightning/([^/]+)/(send|recv|balance)$" \
        "/usr/share/lightning/wellknown/lightning/$2.py"
    SetEnv LIGHTNING_API_USER $1   # captured via mod_setenvif

`<user>` is read by `_lib.py` from `LIGHTNING_API_USER`.

### Logging

Each invocation appends one row to
`/var/log/lightning/api.log` (TSV: ts, endpoint, user,
remote-ip, status). Rotated by logrotate; sample logrotate
config shipped under `share/lightning/logrotate/`.

### What this explicitly does NOT do

- No on-chain ops. Withdrawals / topups via clightning's
  `withdraw` / channel close happen at the shell only.
- No web UI. Just JSON in / JSON out.
- No streaming endpoints. Polling for status.
- No long-running connections. CGI = request/response.
- No account management endpoints. Account lifecycle is
  shell-only (FEAT-174 / 195).
- No multi-user authentication. API keys per account, not
  per holder.

### Specification document

A formal BIP-style specification of the wire format and
endpoint semantics lives at
`share/doc/lightning/standards/api/spec.md`. Vendored under
FEAT-178 so it sits alongside the BOLTs and LUDs the
implementation cites. The document covers:

- URL space, request / response shapes for the three
  endpoints
- Authentication semantics (X-API-Key, scopes, 401
  oracle-resistance)
- Spending guardrails (overdraft + limit)
- Logging requirements
- Rationale (why CGI, why three endpoints, why LUD-12 for
  the message)

Implementation MUST match the spec; the spec is the
contract any external client codes to.

## Acceptance Criteria

1. `POST /.well-known/lightning/alice/recv` with a valid
   write-scope API key and `{"sat": 1000, "message": "test"}`
   returns a parseable JSON object containing a valid BOLT-11
   string whose description equals `"test"`.
2. `POST .../alice/send` with `{"to": "bob@example.com",
   "sat": 500, "message": "thanks", "note": "march budget"}`:
   - resolves bob's address (FEAT-176),
   - sends `"thanks"` as the LUD-12 comment,
   - pays the resulting BOLT-11,
   - returns the payment hash + fee,
   - appends a ledger row with `message="thanks"`,
     `note="march budget"`.
3. On the receiving side (`alice@example.com` minting an
   invoice in response to an external LUD-12 comment), the
   settling `ledger` row in SQLite carries `message` equal
   to the payer-supplied comment.
4. `GET .../alice/balance` returns the current balance +
   limit + overdraft policy from FEAT-195.
5. Wrong API key → HTTP 401 with no body details
   (resistant to oracle attacks).
6. `send.py` with overdraft=`deny` and insufficient balance
   → HTTP 402, no payment made.
7. `share/lightning/sudoers.d/lightning` installs cleanly
   via `make install-apache-bridge`; the bridge works
   end-to-end from www-data Apache to alice's clightning.
8. SIT (FEAT-182) covers all three endpoints round-trip
   inside an Apache-equipped clightning regtest container,
   including the message-arrives-on-both-sides assertion.
9. `share/doc/lightning/standards/api/spec.md` exists and
   matches the implementation.
10. Each endpoint script is < 100 lines of Python 3 (stdlib
    only) excluding `_lib.py`.
