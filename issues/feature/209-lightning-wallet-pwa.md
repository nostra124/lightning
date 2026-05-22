---
id: FEAT-209
type: feature
priority: medium
status: in-progress
---

# Lightning wallet PWA + `lightning ui` installer

## Description

**As a** `lightning` operator running the FEAT-212 HTTP API
**I want** to drop a small static PWA into my Apache docroot so
end-users can open it on phone or laptop, create / receive /
send against an account on my node
**So that** the API has a usable face without me having to ship
a native mobile app, and self-hosters can install the same
PWA on their own bawee.example clone (or behind Tailscale at
home) and point it at whichever node they trust.

This supersedes the original FEAT-209 sketch (BaweePay-as-LSP).
After FEAT-212 landed, the simpler model is "PWA on top of the
account API" — no per-user fly.io / Akash orchestration, no
LSP plumbing, no new server runtime.

## Scope

In:

* Static **PWA** under `share/lightning/ui/` — HTML + ES
  modules + plain CSS, no build step.  Works offline via a
  service worker, installable to home screen on iOS / Android,
  installable as desktop app on macOS / Linux / Windows.
* New top-level verb **`lightning ui`** with `install`,
  `uninstall`, `upgrade` subcommands.  Drops the static files
  into a configurable docroot + writes an Apache vhost
  fragment.
* **Two credential types**, each suited to its caller:
    * **API key** (`lt_...`) — the existing FEAT-212 PR-1
      long-lived bearer.  Stays the credential for **LLM
      agents** (MCP clients), CLI scripts, native mobile
      apps, server-to-server callers.
    * **Passkey** (WebAuthn) — the primary credential for the
      PWA.  Backed by iCloud Keychain / Google Password
      Manager / 1Password / Bitwarden, syncs natively across
      a user's devices, no plaintext bearer sitting in
      `localStorage`.
* **Server-side recovery blob** (opt-in 12-word phrase) for
  the case where all passkeys are lost and the user isn't
  using a manager that backs them up.

Out (deferred):

* **Form-fill / iCloud Keychain trick** as a wallet credential
  store — superseded by passkeys, which sync natively without
  the autocomplete hack.
* **PIN-encrypted localStorage** of the bearer — superseded
  by passkeys, which don't put a long-lived bearer on the
  device at all.
* **Native iOS / Android apps** — the PWA covers both
  platforms via "Add to Home Screen."  No App Store friction,
  no per-platform codebase.  If demand justifies it later,
  Capacitor or Tauri can wrap the same code.
* **Multi-tenant SaaS billing** — the hosted instance at
  bawee.site (or whatever the operator names their public
  install) charges in sats via FEAT-212's regular receive
  endpoint.  No subscription primitive needed inside the PWA.

## The PWA itself

Pure static — HTML + ES modules + plain CSS.  No npm, no
build step, no node_modules.  Aligns with the rest of the
codebase (bash + jq + small Python).  Total payload ~50KB
gzipped target.

### Screens

```
/                   account picker (existing accounts on this device)
/login              paste API key (or scan QR), select backend URL
/create             create a new anon account (calls POST /api/accounts)
/account/<id>       balance + last 10 ledger entries
/account/<id>/send  paste invoice or scan QR; confirm; pay
/account/<id>/recv  amount + description → BOLT-11 QR (auto-poll for paid)
/account/<id>/offer BOLT-12 reusable invoice + QR
/account/<id>/topup BIP-21 URI + QR (the address IS the account ID)
/settings           backend URL, PIN, export, recovery setup
```

Wallet logic is straightforward — HTTP calls + DOM + QR
rendering.  Doesn't need a framework.  Lit is the fallback if
some component (e.g. the ledger list) gets unwieldy.

### Backend selection — runtime, not install-time

The PWA defaults to `window.location.origin + "/api"` on
first load.  If that responds, the PWA uses it — covers the
common case where one operator runs PWA + node behind the
same vhost.

If same-origin doesn't respond (PWA on a public host but the
node lives behind Tailscale; multi-backend power user), the
PWA's first-run screen prompts for `backend URL + bearer`.
Settings → "Change backend" lets the user swap later without
reinstalling.

One PWA build serves every topology — hosted, self-hosted at
home, hosted-PWA-against-tailnet-node.  No build-time flag
to forget.

Branding overrides (operator wants their own name / colour)
live in a static `config.json` next to `index.html` that the
operator can edit by hand after install:

```json
{
  "branding": {
    "name": "Bawee",
    "primary_color": "#7b3fe4"
  }
}
```

Empty / missing `config.json` = default branding.

### Service worker + offline

Standard PWA pattern.  `sw.js` caches the static shell on
first load; new versions roll out via a cache-bust hash in
the asset URLs.  The wallet's *data* (balance, ledger) is
fetched live each time — only the shell is cached.

## The verb

```
lightning ui install [<docroot>] [--apache-vhost <name>] [--no-vhost]
    Copy the PWA files from $PREFIX/share/lightning/ui/ to
    <docroot> (default /var/www/html/lightning).  Write a
    vhost fragment to $PREFIX/share/lightning/apache/ui.conf
    that the operator includes from their main vhost.

lightning ui uninstall [<docroot>]
    Remove the docroot tree + the vhost fragment.

lightning ui upgrade [<docroot>]
    Equivalent to uninstall + install — picks up new files
    from $PREFIX/share/lightning/ui/.  Preserves config.json.
```

The verb is intentionally thin — most of the work is `cp -r`.
Backend URL selection is the PWA's runtime concern (default
same-origin, prompt on first-run if unreachable, settings
screen to change later), not a build-time argument.

Defence in depth: the vhost fragment locks the docroot to
`Options -ExecCGI -Indexes` (the PWA is purely static; no
server-side scripts).

## Credentials — two parallel paths

The account has **two** credential types, each suited to its
caller.  Both authenticate against the same FEAT-212 account.

### 1. API key (long-lived bearer) — for non-browser callers

The existing `lt_...` bearer minted by FEAT-212 PR-1 stays.
It's the credential used by:

* **LLM agents** (MCP clients calling the FEAT-212 PR-3
  tools).  Agents hold the bearer in their own keychain
  (Claude memory, 1Password CLI, etc.) and present it on
  every JSON-RPC call.
* **CLI scripts** — operator automation, monitoring probes,
  pen-test harnesses.
* **Native mobile apps** (when someone writes one outside
  the PWA path) — long-lived bearer paired with the OS
  keychain.
* **Server-to-server integrations** — webhooks, payment
  processors, CI bots.

The PWA can also accept the API key as a fallback login
path (paste-bearer in Settings) — useful for self-hosters
who already have an API key in hand from `account create`
on their own node, and for debugging.

### 2. Passkey (WebAuthn) — for the PWA

The PWA's primary credential.  At account creation (or first
login), the PWA enrolls a passkey:

* The server returns a WebAuthn `PublicKeyCredentialCreation
  Options` blob.
* The PWA calls `navigator.credentials.create({publicKey: ...})`.
  On iOS Safari this triggers Face ID / Touch ID + saves the
  passkey to iCloud Keychain.  On Chrome / Edge, into Google
  Password Manager or the OS keychain.  1Password / Bitwarden
  / Dashlane hook in too.
* The PWA posts the attestation to
  `/api/accounts/<id>/passkeys/register/finish`.  Server
  parses the COSE public key + stores it in a new table.
* For every subsequent session, the PWA calls
  `navigator.credentials.get({publicKey: ...})` with a server-
  issued challenge.  Server verifies the assertion, issues a
  short-lived **session token** (`sess_<random>`, 30-min TTL,
  HMAC-signed).
* The session token is what the PWA actually sends on each
  HTTP call — `Authorization: Bearer sess_…`.  No long-lived
  bearer ever sits on the device.

Trade-offs vs. the API-key path:

* ✅ No plaintext bearer in `localStorage`.  No PIN dance, no
  XSS exposure of long-lived creds.
* ✅ iCloud Keychain / Google Password Manager / 1Password
  sync the passkey natively — multi-device + backup for free.
* ✅ Biometric gate on every passkey assertion (face / touch).
* ⚠️ Each new browser session needs a fresh passkey assertion
  (one prompt to log in, then a session token covers the
  next 30 min).
* ⚠️ Lost all passkeys = lost account, unless the user
  enrolled the opt-in recovery blob below or kept a copy of
  the API key.

### Session tokens

A session token is server-issued after a successful passkey
assertion or an API-key paste-login.  Format:

```
sess_<base64url(account_id || expiry || hmac(secret, account_id||expiry))>
```

* TTL: 30 min.  Refresh via `POST /api/accounts/<id>/session/
  refresh` while still valid; expired sessions force a re-
  auth.
* HMAC-signed with a per-wallet secret in the secret store
  (`secret put lightning.session.hmac-key`).
* Verified by `api-account-verify` — same verb as for `lt_…`
  bearers, just learns the new prefix.  No DB round-trip per
  request (the token is self-contained).

### Server-side recovery blob (opt-in)

For users who will lose all their passkeys *and* their copy
of the API key.  At account creation, optionally generate a
12-word recovery phrase (BIP-39 wordlist).  Local side:

* Derive `key = PBKDF2(phrase, salt=account_id, iters=100k)`
* `blob = AES-GCM(key, api_key)`
* Send `POST /api/accounts/<id>/recovery` with `blob` +
  `sha256(phrase)`.

Server stores `(account_id, sha256(phrase), blob)` keyed by
the phrase hash.  Restore flow: user types the phrase on a
new device → JS hashes it → `POST /api/accounts/recovery/
restore` with just the hash → server returns the encrypted
blob → local PBKDF2 + AES-GCM decrypt → user pastes-login
with the recovered API key, then enrolls a fresh passkey
from the new device.

The server learns nothing about the API key.  Rate-limited
aggressively at the Apache layer (it's the only anonymous
endpoint that returns potentially-recoverable secrets, even
encrypted).

### Manual QR export

Settings → "Show API key QR" — payload `{backend,
account_id, api_key}`.  Paste into a password manager,
delegate to an LLM agent, ship as a paper wallet.  Always
works, no infra.

## Server-side endpoints

### Passkey (PR-3)

```
GET  /api/accounts/<id>/passkeys
    Authorization: Bearer <key|sess>
    Return: { "passkeys": [ { "credential_id": "...",
                              "label": "iPhone 15",
                              "created_at": <epoch>,
                              "last_used_at": <epoch|null> }, ... ] }

POST /api/accounts/<id>/passkeys/register/begin
    Authorization: Bearer <key|sess>
    Body:   { "label": "iPhone 15" }
    Return: { "challenge": "<base64url>",
              "options": <PublicKeyCredentialCreationOptions> }

POST /api/accounts/<id>/passkeys/register/finish
    Authorization: Bearer <key|sess>
    Body:   { "challenge": "...",
              "attestation": <PublicKeyCredentialJSON> }
    Return: { "credential_id": "..." }

POST /api/accounts/<id>/passkeys/login/begin
    No auth (browser kicks off the assertion before holding a session).
    Body:   { }
    Return: { "challenge": "<base64url>",
              "options": <PublicKeyCredentialRequestOptions> }

POST /api/accounts/<id>/passkeys/login/finish
    No auth.
    Body:   { "challenge": "...",
              "assertion": <PublicKeyCredentialJSON> }
    Return: { "session": "sess_...", "expires_at": <epoch> }

DELETE /api/accounts/<id>/passkeys/<credential_id>
    Authorization: Bearer <key|sess>
    Return: { "status": "revoked" }

POST /api/accounts/<id>/session/refresh
    Authorization: Bearer sess_<still-valid>
    Return: { "session": "sess_...", "expires_at": <epoch> }
```

Schema:

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

-- Challenges are one-shot — stored just long enough to round-trip
-- the begin/finish call.  Expired rows are cleaned by the GC sidecar.
CREATE TABLE IF NOT EXISTS auth_challenges (
    challenge   TEXT    PRIMARY KEY,
    account     TEXT,   -- nullable: login/begin doesn't bind to one yet
    purpose     TEXT    NOT NULL,  -- 'register' | 'login'
    created_at  INTEGER NOT NULL,
    expires_at  INTEGER NOT NULL
);
```

### WebAuthn verification — Python helper

COSE parsing + ES256 / EdDSA / RS256 signature verification
in bash + jq is unworkable.  We add a small Python script
under `libexec/lightning/_webauthn-verify` that the verbs
call to validate attestations and assertions.  Single
PyPI dep — the `webauthn` package — added to the
`install-core --source` Python requirements.

The verb-Python split keeps the rest of the codebase shell-
first: only the cryptography lives in Python.

### Recovery blob (PR-4)

```
POST /api/accounts/<id>/recovery
    Authorization: Bearer <key|sess>
    Body: { "phrase_sha256": "hex", "blob": "base64" }
    Return: { "status": "stored" }

POST /api/accounts/recovery/restore
    No auth.
    Body: { "phrase_sha256": "hex" }
    Return: { "account_id": "bc1q...",
              "blob": "base64",
              "backend": "<this server's URL>" }
    404 if no record.
```

Schema:

```sql
CREATE TABLE IF NOT EXISTS account_recovery (
    phrase_sha256 TEXT PRIMARY KEY,
    account       TEXT NOT NULL REFERENCES accounts(name) ON DELETE CASCADE,
    blob          BLOB NOT NULL,
    created_at    INTEGER NOT NULL
);
```

Rate-limit `restore` aggressively at the Apache layer + a
rolling-log limiter in the verb (same shape as PR-2's
`accounts-create`).  Threshold: `LIGHTNING_ACCOUNT_RECOVERY
_RATE`, default 3/min.

## Apache wiring

`share/lightning/apache/ui.conf` — vhost fragment the verb
drops:

```apache
Alias /wallet /var/www/html/lightning
<Directory /var/www/html/lightning>
    Options -ExecCGI -Indexes
    Require all granted
    # Cache the shell aggressively; index.html short-cache
    # so service-worker updates are timely.
    <FilesMatch "\.(js|css|svg|png|ico|webmanifest)$">
        Header set Cache-Control "public, max-age=31536000, immutable"
    </FilesMatch>
    <FilesMatch "\.(html|json)$">
        Header set Cache-Control "no-cache"
    </FilesMatch>
</Directory>
```

If the operator already has the FEAT-212 `/api/accounts` and
`/api/mcp` blocks in their vhost, the PWA at `/wallet/` reads
same-origin and everything Just Works.

## Hosted vs self-hosted

**Hosted (default)** — the operator (we, or whoever stands
up a public instance) runs the PWA + the API under the same
vhost.  End user opens `https://bawee.site` (or the operator's
chosen domain), taps "create account", and gets going in 5
seconds.  Custodial-by-default — the operator's node holds
custody of every account's sats.  Mitigations: transparent
ledger, BOLT-11/12 receive directly to the node's pubkey,
withdraw-anytime via the existing PR-2 `withdraw` endpoint.

**Self-hosted** — user runs `lightning daemon install --system`
on a small machine at home, exposes the API on their
Tailscale tailnet, installs the PWA on the same machine
(default same-origin works) — or installs the PWA on a
different host and lets the first-run prompt point it at
`https://node.tailnet.example`.  Settings → "Change backend"
swaps URLs later without a reinstall.

Both modes share one PWA codebase.

## Phasing (PR plan)

1. **PR-1 (this — spec only)** — file the design.  No code.
2. **PR-2 (PWA + `ui install` verb)** — static PWA under
   `share/lightning/ui/` + `lightning ui install/uninstall/
   upgrade` verb + Apache vhost fragment.  Default backend =
   same-origin.  Login = paste API key (the FEAT-212 PR-1
   bearer).  Covers account create, send (BOLT-11), recv
   (BOLT-11), topup display, balance, settings, manual QR
   export.  No service worker, no passkey, no recovery yet.
3. **PR-3 (passkey + session tokens)** — `account_passkeys`
   table + `auth_challenges` table + Python `_webauthn-
   verify` helper + 7 new endpoints (passkeys list, register
   begin/finish, login begin/finish, revoke, session refresh)
   + PWA flow that enrolls a passkey on first login and uses
   session tokens thereafter.  The PWA's "paste API key"
   path stays as a fallback for self-hosters / debugging /
   LLM delegation.
4. **PR-4 (service worker + offline shell)** — PWA installable
   via "Add to Home Screen", offline shell cached, asset
   hashing for cache bust.
5. **PR-5 (server-side recovery blob)** — opt-in 12-word
   phrase + new endpoints + PWA UI for "generate recovery
   phrase" and "restore from phrase."  Rate-limited `restore`.
6. **PR-6 (BOLT-12 + nicer UX)** — reusable offers in the
   PWA (the verb already supports them via FEAT-212), QR
   scanner using `BarcodeDetector` API (Chrome) with a JS
   fallback for Safari, lightning-address autocomplete.

PR-2 ships a working wallet (paste-bearer login).  PR-3 is
the consumer UX (passkey-first).  PR-4 makes it a real PWA.
PR-5 closes the recovery story.  PR-6 is UX polish.

## Test plan

* **bats** — install verb writes files under docroot, vhost
  fragment is well-formed, uninstall removes them, upgrade
  preserves a hand-edited config.json.
* **pytest** — passkey endpoints (PR-3): challenge/begin
  shape, finish validates attestation via the Python helper,
  duplicate-credential rejection, session-token issuance +
  expiry + refresh, revoke-by-cred-id; recovery endpoints
  (PR-5) for store + restore + rate-limit + unknown-hash 404.
* **manual** — install on a regtest node, open the PWA on a
  phone, create an account, enroll a passkey via Face ID,
  receive on-chain regtest sats, the FEAT-212 deposit watcher
  credits the ledger, the PWA sees the new balance.  Cross-
  device: log in to the same account on a laptop via the
  iCloud-Keychain-synced passkey.

## Naming

The name "BaweePay" goes away.  The feature is "Lightning
wallet PWA" — descriptive, no marketing.  Operators picking
their own hostname can brand the install via
`config.branding.name` / `config.branding.primary_color`.
The hosted public instance is still free to call itself
"Bawee" (or anything else) but that's a deployment choice,
not the feature.

## See also

* FEAT-176 — Lightning Address Apache vhost (the file-drop
  pattern this builds on).
* FEAT-196 — original .well-known/lightning/ JSON API.
* FEAT-207 — `daemon install-core` (the package-install
  pattern this borrows from).
* FEAT-212 — account-centric HTTP API + MCP server (the
  backend this PWA is a client for).

## Milestone

1.5.0 — same as FEAT-212.
