---
id: FEAT-222
type: feature
priority: high
status: research
---

# User layer above accounts — passkey auth, invite-gated registration

## Description

Introduces a **user** entity that sits above accounts and acts as
the human-facing identity on the hosted PWA + on a self-hosted
install.  Users authenticate via passkey, register only with an
invite code, and own one or more accounts.

The existing **account API stays exactly as it is** — same
endpoints, same per-account API key bearer.  LLM agents and
scripts continue to use account-level bearers without any
awareness of users.  Users are an additive layer above
accounts, not a refactor of them.

## Why

* **Invite-gated registration** prevents spam on the public
  bawee.site instance.  And the same gate is *useful*, not
  burdensome, on a self-hosted install — operators can hand
  out invite codes as a soft access-control primitive instead
  of inventing their own.  No bypass knob.
* **One identity, many accounts**.  Users naturally want
  separate accounts for separate purposes (personal / kids /
  business / a one-shot pseudonymous spend) without re-doing
  Face ID + losing their place.  This was awkward under FEAT-
  212's account-as-identity model.
* **Passkey at the user level** = one set of credentials
  syncs across all the user's devices (iCloud Keychain /
  Google Password Manager / 1Password sync passkeys
  natively), and gates access to every account they own.
* **Hierarchical referrals**.  Today FEAT-218 invite codes
  point at one specific account; that account gets the
  FEAT-219 referral skim.  Under the user layer, invites are
  minted by users + name a credit account; the new user
  inherits the relationship for *every* account they create
  later.  Real affiliate-tree semantics for free.
* **Anonymous accounts still allowed**.  Anyone can `POST
  /api/accounts` with no auth + get an account; it just has
  no user owner.  The FEAT-212 PR-5 GC eventually reaps idle
  ones; the future per-account monthly fee will reap the
  rest.

## Scope

* New `users` table + `user_passkeys` + `auth_challenges_user`
  tables (passkey-credential plumbing, parallel to FEAT-209's
  per-account account_passkeys design — but user-scoped).
* `accounts.owner_user TEXT` column, nullable.  Anonymous
  accounts have `owner_user = NULL`.
* `invite_codes` grows `owner_user` + `credit_account` columns
  (additive).  The legacy `account` column becomes the
  fallback "credit_account when owner_user is NULL" — pre-
  FEAT-222 wallets still work; new code prefers `owner_user`.
* New HTTP endpoints under `/api/users/*` (see Surface below).
* User registration enforced via invite — anonymous `POST
  /api/users` always requires an `invite_code` field.  No
  way to register without one, on either hosted or self-
  hosted installs.  The first user (bootstrap) is minted by
  the operator via a CLI verb that bypasses the HTTP gate.
* User → owned-account creation goes through `POST
  /api/users/<id>/accounts` (passkey session required).
  Mirror of the anonymous `POST /api/accounts` but stamps
  `owner_user`.
* New CLI verbs: `lightning user create/list/show/delete`,
  `lightning user passkey list/revoke`, `lightning user
  invite-code create/list/revoke` (the user-layer
  counterpart of FEAT-218's account-layer codes; the latter
  stays as a fallback for code-on-account use cases).

Out of scope (for THIS ticket — listed so the file shape stays
predictable; each its own follow-up):

* PWA UX changes that surface the user concept.  Lives in a
  FEAT-209-style follow-up PR that updates the wallet UI.
* Monthly recurring per-account fee — meaningful new ticket
  on its own (FEAT-223 placeholder).
* Multi-user-owned accounts ("teams").  One account → one
  owner_user, full stop.  No shared accounts in v1.
* Account-transfer between users.  Operator can do it
  manually via `UPDATE accounts SET owner_user = …`; no
  user-facing primitive.
* OAuth / OIDC / federation.  Passkey only.

## The model

```
user                ── owns ──>  N accounts
  ├ passkey 1                      ├ API key (FEAT-212 PR-1)
  ├ passkey 2                      ├ ledger entries
  └ invite code(s)                 └ referrer (account-level)
```

`accounts.referrer` (FEAT-218) keeps pointing at an account.
The invitation flow is:

1. User X mints invite code `C` via `POST
   /api/users/<X>/invite-codes` — supplies `credit_account =
   A` (one of X's owned accounts).  Server stores `(code=C,
   owner_user=X, credit_account=A)`.
2. New user Y registers via `POST /api/users` with body
   `{invite_code: C, passkey_attestation: ...}`.  Server
   creates the user + stamps `Y.referrer_user = X` (group-
   level relationship; informational).
3. When Y creates any account `A_Y` via `POST
   /api/users/<Y>/accounts`, server stamps `A_Y.referrer = A`
   (account-level relationship; this drives the FEAT-219
   credit split).
4. Anonymous accounts (created via `POST /api/accounts`
   without auth) still accept `invite_code` in the body —
   the legacy account-linked path from FEAT-218 — for back-
   compat.  Resolution: if `invite_code.owner_user IS NOT
   NULL`, use `credit_account`; else use the legacy
   `account` column.

## Surface

### Schema (additive)

```sql
CREATE TABLE IF NOT EXISTS users (
    id              TEXT PRIMARY KEY,           -- usr_<22 base58 chars>
    created_at      INTEGER NOT NULL,
    referrer_user   TEXT REFERENCES users(id) ON DELETE SET NULL,
    label           TEXT NOT NULL DEFAULT ''    -- optional human label
);

CREATE TABLE IF NOT EXISTS user_passkeys (
    id            INTEGER PRIMARY KEY,
    user          TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    credential_id TEXT NOT NULL UNIQUE,
    public_key    BLOB NOT NULL,
    sign_count    INTEGER NOT NULL DEFAULT 0,
    label         TEXT NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL,
    last_used_at  INTEGER
);

CREATE TABLE IF NOT EXISTS auth_challenges_user (
    challenge   TEXT PRIMARY KEY,
    user        TEXT,
    purpose     TEXT NOT NULL,   -- 'register' | 'login'
    created_at  INTEGER NOT NULL,
    expires_at  INTEGER NOT NULL
);

ALTER TABLE accounts ADD COLUMN owner_user TEXT
    REFERENCES users(id) ON DELETE SET NULL;

-- FEAT-218 invite_codes grows two columns; the legacy `account`
-- column remains for back-compat with pre-FEAT-222 wallets.
-- New code prefers credit_account when owner_user is set.
ALTER TABLE invite_codes ADD COLUMN owner_user TEXT
    REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE invite_codes ADD COLUMN credit_account TEXT
    REFERENCES accounts(name) ON DELETE SET NULL;
```

### HTTP endpoints

Anonymous:

```
POST /api/users
    Body:  { "invite_code": "...",
             "passkey_attestation": <PublicKeyCredentialJSON>,
             "label": "optional human label" }
    Return: { "user_id": "usr_...",
              "session":  "sess_...",
              "expires_at": <epoch> }
    401 if no/bad invite; 409 if passkey already registered.

POST /api/users/<id>/passkeys/login/begin
    No auth.
    Return: { "challenge", "options" }

POST /api/users/<id>/passkeys/login/finish
    No auth.
    Body:   { "challenge", "assertion" }
    Return: { "session", "expires_at" }
```

Passkey-session-authed (bearer = `sess_<...>` issued by the
user-level login):

```
GET    /api/users/<id>                          profile + counts
GET    /api/users/<id>/accounts                 list owned accounts
POST   /api/users/<id>/accounts                 create owned account
                                                 (same body shape as
                                                  POST /api/accounts)

GET    /api/users/<id>/accounts/<acct>/api-key  retrieve the account's
                                                 API key — for handing
                                                 to an LLM agent.

GET    /api/users/<id>/passkeys                 list registered passkeys
POST   /api/users/<id>/passkeys/register/begin  enroll another device
POST   /api/users/<id>/passkeys/register/finish
DELETE /api/users/<id>/passkeys/<cred_id>

GET    /api/users/<id>/invite-codes
POST   /api/users/<id>/invite-codes             { credit_account, code? }
DELETE /api/users/<id>/invite-codes/<code>

POST   /api/users/<id>/session/refresh
```

The existing `/api/accounts/*` family (FEAT-212 PR-2) stays
entirely unchanged.  An LLM agent given an account's API key
operates exactly as before — no awareness of users.

### CLI

```
lightning user create [--label <text>]            bootstrap-only: mint
                                                   a user without an
                                                   invite (operator path
                                                   for the FIRST user)
lightning user list                               TSV of users + their
                                                   account counts
lightning user show <id>
lightning user delete <id>                        ON DELETE SET NULL
                                                   on accounts (orphans
                                                   them; GC reaps idle
                                                   ones).
lightning user passkey list <id>
lightning user passkey revoke <id> <cred_id>
lightning user invite-code create <id>
                       --credit-account <handle>
                       [--code <vanity>]
lightning user invite-code list <id>
lightning user invite-code revoke <code>
```

## Auth flow (PWA)

1. Open the URL.  PWA finds no local user → "Register" screen.
2. User pastes invite code + clicks "Create passkey."  PWA
   calls `POST /api/users` with the WebAuthn attestation.
3. Server validates the invite, creates the user, returns
   session + user_id.  PWA stores `{user_id, label}` locally
   (NOT the session — that lives in memory only).
4. Subsequent launches: PWA recognises the local user_id,
   prompts passkey assertion via `POST /api/users/<id>/
   passkeys/login/begin` → `/finish` → session.
5. Account picker shows the user's accounts.  "+ New account"
   creates an owned account.  Each account's API key is
   visible in its settings (for LLM-agent delegation).

## Bootstrap problem

The first user on a fresh install has no inviter.  Solution:
the operator runs `lightning user create --label "operator"`
(CLI-only, no HTTP gate).  That user can then mint invite
codes to onboard everyone else.  Hosted instance bootstraps
the same way — the operator (`alice` per FEAT-183) registers
once, then opens the gates.

## Migration

Additive — no breaking changes:

* Pre-FEAT-222 wallets pick up the new columns + tables on
  next account-verb call (via `migrate_accounts_schema`).
* Existing `invite_codes(code, account, ...)` rows continue
  to work via the legacy resolution path.
* Existing accounts have `owner_user = NULL` — they remain
  anonymous accounts forever (or until the operator manually
  assigns them: `UPDATE accounts SET owner_user = … WHERE
  ...`).
* FEAT-218's `account invite-code` CLI verbs continue to
  work for the legacy path; new `user invite-code` verbs are
  the recommended path going forward.

## WebAuthn verification

Same Python helper as FEAT-209 PR-2 planned to ship —
`libexec/lightning/_webauthn-verify`.  Single new PyPI dep
(`webauthn`).  Whichever PR lands first (FEAT-209 PR-2 or
this one) introduces it; the other reuses it.

## Phasing (PR plan)

1. **PR-1 (this — spec only)** — file the design.
2. **PR-2 (schema + CLI bootstrap)** — `users` /
   `user_passkeys` / `auth_challenges_user` tables, `accounts.
   owner_user` column, `invite_codes.owner_user` +
   `credit_account` columns.  CLI verbs `lightning user
   create/list/show/delete`.  No HTTP, no passkey verification
   yet — the CLI verbs cover the operator bootstrap path so
   downstream PRs can rely on a working users table.
3. **PR-3 (passkey backend)** — Python `_webauthn-verify`
   helper + the seven endpoints under
   `/api/users/<id>/passkeys/*` + session-token issuance
   (`sess_<...>` HMAC, same shape as FEAT-209's planned token).
4. **PR-4 (user CRUD + owned-account endpoints)** —
   `POST /api/users`, `GET /api/users/<id>`, `GET/POST
   /api/users/<id>/accounts`, `GET /api/users/<id>/accounts/
   <acct>/api-key`, `POST /api/users/<id>/session/refresh`.
   Invite-gated registration enforced here.
5. **PR-5 (user-level invite codes + referral routing)** —
   `lightning user invite-code create/list/revoke` + the
   matching HTTP endpoints + the resolution change in
   `api-accounts-create` (prefer `owner_user.credit_account`
   over the legacy `account` column).  FEAT-219's referrer
   stamping inherits naturally.
6. **PR-6 (PWA changes)** — wallet UI grows the user
   registration / login flow.  Lives in FEAT-209's PWA PR
   sequence; tracked there with a back-reference to this
   ticket.

## Test plan

Each PR carries its own bats + pytest coverage; outline only
here:

* bats: user CRUD + passkey list/revoke + invite-code mint
  + bootstrap path on fresh wallet + the additive migration
  is idempotent.
* pytest: dispatcher routing for `/api/users/*`; invite-
  gated registration rejects no/bad invite; passkey
  attestation verified via the helper; session-token
  issuance + refresh + expiry; owned-account create stamps
  `owner_user`; api-key retrieval requires the right
  passkey session.

## Out of scope (deferred)

* PWA UI surfacing the user concept — owned by FEAT-209's
  next PR.
* Monthly recurring per-account fee — its own ticket.
* Team accounts (N users own one account) — explicit no.
* Account transfer between users — operator-only via SQL,
  no user-facing primitive.

## See also

* FEAT-212 — account API + the account-as-bearer model this
  layers above.
* FEAT-213 — operator fee skim that referral credits split.
* FEAT-218 — account-linked invite codes (FEAT-222 layers on
  top with user-linked codes).
* FEAT-219 — referral fee distribution (consumes the
  inherited `referrer` from this ticket's flow).
* FEAT-209 — Lightning wallet PWA + the per-account passkey
  design that this ticket pivots to the user level.

## Milestone

1.5.0 — same train as FEAT-212/213/etc.
