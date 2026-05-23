---
id: FEAT-209
type: feature
priority: medium
status: in-progress
---

# Lightning wallet PWA + `lightning ui` installer

## The whole pitch in one paragraph

You open the URL.  The PWA loads.  First visit, it asks you to
create a passkey and creates your first account.  After that you
can create more accounts, see their top-up addresses, pay BOLT-11
invoices, mint receive invoices.  Everything else — crediting
on-chain deposits, garbage-collecting stale accounts, rebalancing
channels, watchtower — is handled by the server-side cron jobs
already shipped in FEAT-205 and FEAT-212.  The PWA is a thin
client; the operator's node does the work.

## Two install patterns

* **Provider-hosted** — operator runs `lightning daemon install
  --system --topup-watcher --account-gc` + `lightning ui install`
  on a public host.  User opens `https://bawee.site`, taps "Get
  started", lands on a passkey prompt, then they're using
  Lightning.  Custodial-by-default.  Mitigations: transparent
  ledger, withdraw-anytime, BOLT-12 receive directly to the
  node's pubkey.
* **Self-hosted** — power user runs the same two install
  commands on a Tailscale-reachable machine at home.  Same PWA,
  same flow, but now they hold their own keys + run their own
  routing.

Both modes are same-origin (PWA + API under one vhost).  There's
no runtime backend switcher and no `--backend` flag — if the user
trusts the operator enough to load the PWA, they trust the API
behind it too.  One install = one identity = one backend.

## User journey

```
1. Open https://bawee.site (or your-tailnet-node.example)
2. PWA loads.  "Welcome — create your first account?"
3. Tap "Create".  PWA calls POST /api/accounts (anonymous).
   Server returns {account_id, api_key}.
4. PWA shows "Set up sign-in for this device" + Face ID / Touch
   ID prompt.  Passkey registers against this account_id.
5. PWA stores: { account_id, label } in localStorage.  api_key
   is shown once on a "save this for backup" screen (copy /
   download), then discarded from the PWA.
6. Land on /account/<id> — balance 0, top-up address visible.
7. User scans the BIP-21 QR with another wallet, sends sats on-
   chain.  FEAT-212 PR-4's deposit watcher cron credits the
   ledger within ~1 min.  PWA's balance polling picks it up.
8. User pays a BOLT-11 invoice (paste + confirm + Face ID
   re-prompt + receipt).  User mints a receive invoice (amount +
   description + QR).  Done.
9. On next launch the picker shows their account.  Tap →
   passkey assertion → session → /account/<id>.
```

That's the wallet.  Anything beyond this — recovery flows,
LLM-agent delegation, BOLT-12 receive, QR scanning, lightning-
address autocomplete — is a follow-up PR, not blocking the
initial ship.

## Scope

In scope for the initial ship (PR-2):

* Static **PWA** under `share/lightning/ui/` — HTML + ES
  modules + plain CSS, no build step.  ~50KB target.  Hard-wired
  to same-origin `/api`.
* **`lightning ui install/uninstall/upgrade`** verb — drops
  files into a docroot + writes an Apache vhost fragment.
  Defence-in-depth `Options -ExecCGI -Indexes`.
* **Inline documentation** shipped alongside the PWA under
  `share/lightning/ui/docs/`.  Two complementary forms (see
  the "Inline docs" section below for the full design):
    * `docs/index.html` — human-readable HTML, linked from the
      PWA Settings → Help and navigable from the docroot URL.
    * `docs/llms.txt` — single-file plain-text dump an LLM
      agent can fetch in one HTTP call and understand the
      whole API + MCP surface from.
  Scope: PWA usage + the FEAT-212 REST + MCP surfaces only.
  Nothing about clightning install or channel management —
  that's elsewhere in `share/doc/lightning/`.
* **Passkey backend** — `account_passkeys` table, one-shot
  `auth_challenges` table, Python `_webauthn-verify` helper
  (single new dep: the `webauthn` PyPI package), 7 new
  endpoints: passkeys list/register-begin/finish, login-begin/
  finish, revoke, session refresh.
* **Session tokens** — `sess_…` prefix, 30-min HMAC-signed,
  verified by the existing `api-account-verify` (learns the
  new prefix).  No DB round-trip per request.
* **Screens**: account picker, login (passkey assertion),
  create, account view (balance + recent ledger + top-up
  address), send (BOLT-11 paste), recv (BOLT-11 mint),
  settings (passkeys list, "show API key" for LLM-export,
  revoke this device).

Out of scope for PR-2; listed here so the file shape stays
predictable:

* Service worker / offline shell — Lightning needs the network
  to do anything useful; the offline-cached shell is chrome.
  Add when the PWA is otherwise feature-complete.
* **Server-side recovery blob** (BIP-39 phrase + encrypted
  API-key blob keyed by `sha256(phrase)`).  Useful but optional.
* BOLT-12 receive in the PWA.  The verb already supports it
  (FEAT-212 PR-2 ships `api-account-recv-reusable`).  Add a
  button.
* QR scanner using `BarcodeDetector` (Chrome) with a JS
  fallback for Safari.
* Lightning-address autocomplete in the send screen.
* LLM-agent delegation UI (multiple keys per account).  The
  FEAT-212 PR-1 schema is one key per account; multi-key is a
  separate small ticket.
* Native iOS / Android apps — the PWA covers both via "Add to
  Home Screen."
* Branding overrides via `config.json`.  Operators editing
  `share/lightning/ui/index.html` directly is the v1 escape
  hatch.

## Credentials

The account has two credential types — both authenticate against
the same FEAT-212 account, just via different paths:

### Passkey (the PWA's credential)

At account creation the PWA enrolls a passkey via WebAuthn.
The passkey lives in iCloud Keychain / Google Password Manager /
1Password / Bitwarden — synced + backed up natively, no
plaintext bearer on the device.  Subsequent logins:

* PWA calls `POST /api/accounts/<id>/passkeys/login/begin` → gets
  a challenge.
* `navigator.credentials.get({publicKey: ...})` → user does
  Face ID / Touch ID → assertion.
* PWA posts to `/passkeys/login/finish` → server verifies +
  issues `sess_<…>`.
* PWA holds the session in memory (NOT localStorage) for ~30
  min; refresh while valid via `POST /api/accounts/<id>/session
  /refresh`.

### API key (for everyone else)

The original `lt_…` bearer minted by FEAT-212 PR-1.  Used by:

* LLM agents (MCP calls), CLI scripts, native apps, server-to-
  server callers.  Long-lived, presented on every request.
* PWA fallback for self-hosters who already have an API key
  in hand.  Paste-bearer login is a hidden settings entry, not
  the main path.

The api_key is shown **once** in the PWA at account creation —
on the "save this for backup" screen, with copy / download
buttons.  If the user loses both their passkeys and their
api-key backup, they're locked out unless the future recovery-
blob (PR-4) is enabled.

## Server-side endpoints (new in PR-2)

```
GET  /api/accounts/<id>/passkeys
    Authorization: Bearer <key|sess>
    Return: { "passkeys": [ { credential_id, label,
                              created_at, last_used_at }, ... ] }

POST /api/accounts/<id>/passkeys/register/begin
    Authorization: Bearer <key|sess>
    Body:   { "label": "iPhone 15" }
    Return: { "challenge", "options": <PublicKeyCredentialCreationOptions> }

POST /api/accounts/<id>/passkeys/register/finish
    Authorization: Bearer <key|sess>
    Body:   { "challenge", "attestation": <PublicKeyCredentialJSON> }
    Return: { "credential_id" }

POST /api/accounts/<id>/passkeys/login/begin
    No auth.
    Return: { "challenge", "options": <PublicKeyCredentialRequestOptions> }

POST /api/accounts/<id>/passkeys/login/finish
    No auth.
    Body:   { "challenge", "assertion": <PublicKeyCredentialJSON> }
    Return: { "session", "expires_at" }

DELETE /api/accounts/<id>/passkeys/<credential_id>
    Authorization: Bearer <key|sess>
    Return: { "status": "revoked" }

POST /api/accounts/<id>/session/refresh
    Authorization: Bearer sess_<still-valid>
    Return: { "session", "expires_at" }
```

The existing `/api/accounts`, `/api/accounts/<id>/balance`,
`/topup`, `/withdraw`, `/pay`, `/recv`, `/recv-reusable`,
`/close` endpoints (FEAT-212 PR-2) already accept the bearer.
The session token follows the same path; `api-account-verify`
learns the `sess_` prefix and short-circuits the secret-store
lookup with an HMAC check.

## Schema (additive)

```sql
CREATE TABLE IF NOT EXISTS account_passkeys (
    id            INTEGER PRIMARY KEY,
    account       TEXT    NOT NULL REFERENCES accounts(name) ON DELETE CASCADE,
    credential_id TEXT    NOT NULL UNIQUE,
    public_key    BLOB    NOT NULL,
    sign_count    INTEGER NOT NULL DEFAULT 0,
    label         TEXT    NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL,
    last_used_at  INTEGER
);

-- Challenges are one-shot, ~60-second TTL.  PR-2 garbage-collects
-- them inline in `login/finish` and `register/finish`; the
-- FEAT-212 PR-5 GC sidecar sweeps any leaks on its daily run.
CREATE TABLE IF NOT EXISTS auth_challenges (
    challenge   TEXT    PRIMARY KEY,
    account     TEXT,   -- nullable; login/begin doesn't bind yet
    purpose     TEXT    NOT NULL,
    created_at  INTEGER NOT NULL,
    expires_at  INTEGER NOT NULL
);
```

Migration: idempotent `CREATE TABLE IF NOT EXISTS` from the same
helper that does FEAT-212's account-schema migration.

## WebAuthn verification — Python helper

COSE key parsing + ES256 / EdDSA / RS256 signature verification
in bash + jq is unworkable.  We add a small Python helper at
`libexec/lightning/_webauthn-verify` that the shell verbs call
to validate attestations + assertions.  Single new PyPI dep —
`webauthn` — added to the `install-core --source` Python
requirements.  Same Python-for-the-cryptography pattern the
existing CGI scripts already use.

## The verb

```
lightning ui install [<docroot>] [--apache-vhost <name>] [--no-vhost]
    Copy share/lightning/ui/ → docroot.  Default docroot:
    /var/www/html/lightning.  Write share/lightning/apache/ui.conf
    that the operator includes from their main vhost.

lightning ui uninstall [<docroot>]
    Remove docroot tree + vhost fragment.

lightning ui upgrade [<docroot>]
    Reinstall.  Preserves any operator-edited config.json.
```

That's it.  The verb is thin on purpose.

## Inline docs (shipped with the PWA install)

`lightning ui install` copies a small documentation tree
alongside the PWA static files.  Two complementary forms,
same content, different consumers:

* `docs/index.html` — human-readable HTML, navigable from
  the docroot URL.  Linked from the PWA's Settings → Help.
  Plain HTML + CSS, no JS.  Covers PWA usage (how to create
  an account, top up, send/receive, recovery), the FEAT-212
  REST surface (endpoint by endpoint, with `curl` examples),
  and the MCP surface (tool list + JSON-RPC envelope
  examples + how to point an agent at `/api/mcp`).
* `docs/llms.txt` — single-file plain-text dump that an LLM
  agent can fetch in one HTTP call and learn the whole API +
  MCP surface from.  Follows the emerging `llms.txt`
  convention (a single concatenated markdown / plain-text
  document at a well-known path).  Schema-rich: every
  endpoint has its inputs, outputs, error codes, and a
  worked example.

Scope of these docs is *deliberately narrow*: PWA usage +
REST API + MCP.  Nothing about clightning install, channel
management, autopilot, watchtower, etc. — that's the
**man-pages** territory below (operator-facing) and the
`share/doc/lightning/` guides (educational long-form).

Authoring approach: hand-written markdown source under
`share/lightning/ui/docs/src/*.md`, converted to HTML at
*package-build* time (not install time — keeps the install
verb a pure copy).  llms.txt is just the concatenation of
the markdown sources with a fixed ordering.

Update cadence: any FEAT-212 endpoint change MUST update
the inline docs in the same PR; same gate as the existing
"man pages must reflect verb behaviour" convention.

## CLI / operator-facing documentation — man pages

Reminder: documentation for the `lightning` CLI itself is
**man pages**, the standard unix convention.  One page already
exists (`share/man/man1/lightning.1` — top-level overview);
expanding it to cover every verb is tracked in **FEAT-221**.

The man pages and the PWA-shipped inline docs cover different
surfaces — operator-facing CLI vs. user-facing HTTP — and don't
overlap, so no duplication / drift risk.

* **PR-1 (this — spec)**
* **PR-2 (the whole thing)** — PWA + verb + passkey backend +
  all 7 endpoints + schema migration + inline docs
  (`docs/index.html` + `docs/llms.txt`) shipped under the
  install verb's tree.  Ships a working wallet on first
  commit.  Tests: bats for the verb + the new shell verbs
  (passkey-register/login/etc.) + a "docs install correctly"
  smoke check; pytest for the dispatcher routing + WebAuthn
  helper exercised against canned vectors.
* **PR-3 onward (optional polish, one ticket each)** —
  recovery blob, BOLT-12 receive in the PWA, QR scanner,
  lightning-address autocomplete, service worker / offline
  shell, LLM-agent delegation (multi-key per account), passkey
  re-enrollment flow.

PR-2 is a chunky single PR (~3 weeks of work).  It can be split
along schema → backend → frontend lines if reviewer load is a
concern, but the dependencies are tight enough that the
combined diff is easier to review than three separate ones.

## See also

* FEAT-176 — Lightning Address Apache vhost.
* FEAT-196 — original `.well-known/lightning/` JSON API.
* FEAT-207 — `daemon install-core`.
* FEAT-212 — account-centric HTTP API + MCP server + cron-
  job sidecars (this PWA is a client for that backend).

## Milestone

alpha — must ship before the feature-complete **alpha** cut (alpha = everything implemented; then beta hardening; then 1.0.0 is a formal version bump).
