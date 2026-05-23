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
* **Referrals are an access-control + pricing primitive, not
  an MLM.**  The headline use is *gating*: who's allowed to
  create accounts/users, and at what fee tier.  The affiliate
  payout (a referral account earning a slice of fees) is a
  secondary incentive layered on top, single-level only.
  Two knobs make this an admin mechanism:
    * a `require_referral` flag that forbids unreferred
      account/user creation entirely; and
    * an optional whitelist of which users/accounts may mint
      invites at all.
* **Anonymous accounts still allowed (by default)**.  Anyone
  can `POST /api/accounts` with no auth + get an account; it
  just has no user owner and pays the *unreferred* (higher)
  fee tier.  The FEAT-212 PR-5 GC eventually reaps idle ones;
  the future per-account monthly fee reaps the rest.  Flip
  `require_referral` on and even this is closed.

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
* User registration accepts an *optional* `invite_code`.
  With one → the referral relationship is recorded + the
  discounted fee tier applies to the user's accounts.
  Without one → registration still succeeds (unless
  `require_referral` is on), accounts pay the higher
  unreferred tier.  The first user (bootstrap) is minted by
  the operator via a CLI verb that bypasses the HTTP path.
* `require_referral` config flag (default off): when on,
  `POST /api/users` and `POST /api/accounts` both reject
  requests without a valid invite.  Hard gate for operators
  who want a fully-closed instance.
* Optional invite **whitelist**: a config list of
  users/accounts permitted to mint invite codes.  Empty
  list (default) = anyone with an account/user may invite.
  Non-empty = only the listed identities.
* User → owned-account creation goes through `POST
  /api/users/<id>/accounts` (passkey session required).
  Mirror of the anonymous `POST /api/accounts` but stamps
  `owner_user` + passes the user's referral through to the
  new account's `referrer`.
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

## Access control + fee tiers (the real focus)

This is framed as a security/admin mechanism, not affiliate
marketing.  Three layers, each independently toggleable:

### 1. Two fee tiers — referred vs unreferred

Account creation takes an optional referral account `R`:

* **With `R`** — the account's operations get the *discounted*
  fee tier, and `R` earns a slice of the (discounted) skim
  per FEAT-219.  Both the new account AND the referrer come
  out ahead; the house trades per-tx margin for growth.
* **Without `R`** — the account pays the *full* (higher) fee
  tier; the whole skim goes to house.  Creation is still
  allowed by default.

Implemented as a `referral_discount_pct` knob in
`fees.recfile` (extends FEAT-213's per-op rates).  The
operator-fee math becomes:

```
F_full      = base_sat*1000 + amount_msat*rate_ppm/1e6   (FEAT-213)
if referred:
    F        = F_full * (100 - referral_discount_pct) / 100
    to_R     = F * referral_direct_pct / 100              (FEAT-219)
    to_house = F - to_R
else:
    F        = F_full
    to_house = F        (no referrer share)
```

So a referred user literally pays less than an unreferred
one — the discount is the carrot, the higher unreferred tier
is the (soft) stick.

### 2. `require_referral` — the hard gate

A config flag (default **off**).  When **on**:

* `POST /api/users` rejects registration without a valid
  invite (`401 invite_required`).
* `POST /api/accounts` (anonymous) + `POST /api/users/<id>/
  accounts` reject creation without a referral.

This turns the soft fee-tier nudge into a closed instance —
no account exists without a sponsor.  Useful for invite-only
deployments.

### 3. Invite whitelist — who may sponsor

A config list (default **empty** = anyone may invite).  When
non-empty, only the listed users/accounts may mint invite
codes; everyone else's `POST .../invite-codes` returns
`403 not_authorised_to_invite`.

Combined with `require_referral`, this gives the operator a
two-level admission control: a small set of trusted sponsors,
and nobody gets in without one of them vouching.

Config lives in `fees.recfile` (rates + discount) +
a sibling `access.recfile` (require_referral flag + invite
whitelist) under the wallet repo — both git-tracked, plain
text, operator-edited.

### Referral pass-through for users

A user's referral relationship is set once at registration
(from the invite's `credit_account`).  Every account the
user subsequently creates inherits that as its `referrer`,
so the whole portfolio sits on the discounted tier and the
sponsor keeps earning.  A user who registered *without* an
invite creates *unreferred* accounts (higher tier) — unless
the operator later assigns them a sponsor.

The API key for each owned account is retrievable in the PWA
GUI (Settings → the account → "Show API key") so the user
can paste it to an LLM agent.

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
6. **PR-6 (access control + fee tiers)** — the admin/security
   layer: `referral_discount_pct` in fees.recfile (referred
   accounts pay less; extends FEAT-213/219 skim math),
   `access.recfile` with the `require_referral` flag + invite
   whitelist, and the enforcement points in
   `api-accounts-create` / the user-registration endpoint.
   This is the part the operator actually cares about.
7. **PR-7 (PWA changes)** — wallet UI grows the user
   registration / login flow + the per-account "Show API
   key" affordance.  Lives in FEAT-209's PWA PR sequence;
   tracked there with a back-reference to this ticket.

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

alpha — must ship before the feature-complete **alpha** cut (alpha = everything implemented; then beta hardening; then 1.0.0 is a formal version bump).
