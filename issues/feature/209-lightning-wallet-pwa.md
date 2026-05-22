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
* **Key storage + backup design** — three orthogonal layers
  (browser/OS password manager via form-fill, manual QR
  export, opt-in server-side recovery blob).  At-rest
  encryption via a user-set PIN.
* Two server-side endpoints for the opt-in recovery layer:
  `POST /api/accounts/<id>/recovery` (store an encrypted
  blob) and `POST /api/accounts/recovery/restore` (look up by
  phrase hash).

Out (deferred):

* **Passkeys / WebAuthn** as the bearer credential — the
  right v2 answer, but PWA enrollment UX is still wonky in
  Safari.  Filed as PR-4 for future work.
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

### Same-origin by default

The PWA reads `window.location.origin + "/api"` for the
backend.  No config file needed in the common case — install
the PWA under the same Apache vhost that hosts FEAT-212 and
everything wires up.

Override via a `config.json` next to `index.html`:

```json
{
  "backend": "https://node.tailnet.example",
  "branding": {
    "name": "Bawee",
    "primary_color": "#7b3fe4"
  }
}
```

`config.json` is written by the install verb based on its
`--backend` flag.  Empty / missing config = same-origin.

### Service worker + offline

Standard PWA pattern.  `sw.js` caches the static shell on
first load; new versions roll out via a cache-bust hash in
the asset URLs.  The wallet's *data* (balance, ledger) is
fetched live each time — only the shell is cached.

## The verb

```
lightning ui install [<docroot>]
                     [--backend <url>]
                     [--apache-vhost <name>]
                     [--no-vhost]
    Copy the PWA files from $PREFIX/share/lightning/ui/ to
    <docroot> (default /var/www/html/lightning).  Write a
    vhost fragment to $PREFIX/share/lightning/apache/ui.conf
    that the operator includes from their main vhost.  If
    --backend is set, write a config.json baking in that URL.

lightning ui uninstall [<docroot>]
    Remove the docroot tree + the vhost fragment.

lightning ui upgrade [<docroot>]
    Equivalent to uninstall + install — picks up new files
    from $PREFIX/share/lightning/ui/.  Preserves config.json.
```

The verb is intentionally thin — most of the work is `cp -r`.
Defence in depth: the vhost fragment locks the docroot to
`Options -ExecCGI -Indexes` (the PWA is purely static; no
server-side scripts).

## Key storage on the device

The user's "key" is the FEAT-212 bearer token (`lt_...`).
Lost bearer = lost account.

### Three orthogonal backup layers

1. **Browser / OS password manager** — *default-on, no
   server involvement*.  On first login, render a hidden
   form:

   ```html
   <form id="save-creds" autocomplete="on">
     <input type="text"     name="username" autocomplete="username"
            value="<account-id>" />
     <input type="password" name="password" autocomplete="current-password"
            value="<bearer>" />
   </form>
   ```

   Submit it once → iOS / Android / desktop browser prompts
   "Save password?" → on accept, the bearer lands in iCloud
   Keychain / Google Password Manager / 1Password / Bitwarden.

   On reinstall or new device, the same form is autofilled,
   JS reads the field value back, and the user is logged in.
   This is the de facto pattern custodial Lightning PWAs use
   today and is the most ergonomic for typical users.

2. **Manual QR export** — *always works, no infra*.  The
   Settings screen has a "Show recovery QR" button.  The QR
   payload is a JSON blob `{backend, account_id, api_key}`.
   User scans it from a password manager, saves to a paper
   wallet, ships to a buddy as a delegation — operator's
   choice.

3. **Opt-in server-side recovery blob** — *for users who
   will lose their phone and their password manager*.  At
   account creation, optionally generate a 12-word recovery
   phrase (BIP-39 wordlist).  Local side:

   * Derive `key = PBKDF2(phrase, salt=account_id, iters=100k)`
   * `blob = AES-GCM(key, bearer)`
   * Send `POST /api/accounts/<id>/recovery` with `blob` +
     `sha256(phrase)`.

   Server stores `(account_id, sha256(phrase), blob)` keyed
   by the phrase hash.  Restore flow: user types the phrase
   on a new device → JS hashes it → `POST /api/accounts/
   recovery/restore` with just the hash → server returns the
   encrypted blob → local PBKDF2 + AES-GCM decrypt.

   The server learns nothing about the bearer.  Trade-off:
   we add a recovery surface (someone with the phrase can
   recover the bearer; someone with read access to the
   recovery table sees only `sha256(phrase) → encrypted blob`).
   The phrase hash isn't account-id-bound on the wire — i.e.
   restore-by-hash works without naming the account first;
   that's deliberate so a user with only the phrase can
   recover.

### At-rest protection (a 4th layer)

Before persisting the bearer to localStorage, wrap it with
an AES-GCM key derived from a 6-digit PIN the user sets at
login.  The PIN is short (typing on a phone), but it raises
the bar for cross-app reads (XSS, shared device).  Lock-out
after N wrong PINs falls back to "log in again from the
password manager."

Skip the PIN if the user opts out (default-on but skippable).

## Server-side recovery endpoints (PR-3)

```
POST /api/accounts/<id>/recovery
    Authorization: Bearer <key>
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

Rate-limit `restore` aggressively at the Apache layer — it's
the only anonymous endpoint that returns potentially-
recoverable secrets (even encrypted).  Same rolling-log
approach as PR-2's `accounts-create`, lower threshold
(LIGHTNING_ACCOUNT_RECOVERY_RATE, default 3/min).

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
Tailscale tailnet, installs the PWA either on the same machine
(default same-origin) or on a public host with `--backend
https://node.tailnet.example`.  Settings screen accepts the
URL + paste-bearer flow for users who want to point the same
phone-installed PWA at multiple backends.

Both modes share one PWA codebase.

## Phasing (PR plan)

1. **PR-1 (this — spec only)** — file the design.  No code.
2. **PR-2 (PWA + verb)** — static PWA under
   `share/lightning/ui/` + `lightning ui install/uninstall/
   upgrade` verb + Apache vhost fragment.  Default backend =
   same-origin.  Covers account create, send (BOLT-11), recv
   (BOLT-11), topup display, balance, settings, manual QR
   export.  No service worker, no recovery yet.
3. **PR-3 (service worker + offline shell)** — PWA installable
   via "Add to Home Screen", offline shell cached, asset
   hashing for cache bust.  Also adds the form-fill trick for
   browser/OS password manager save.
4. **PR-4 (server-side recovery)** — new HTTP endpoints +
   schema column + PWA UI for "generate recovery phrase" and
   "restore from phrase."  Rate-limited `restore`.
5. **PR-5 (BOLT-12 + nicer UX)** — reusable offers in the
   PWA (the verb already supports them via FEAT-212), QR
   scanner using `BarcodeDetector` API (Chrome) with a JS
   fallback for Safari, lightning-address autocomplete.
6. **PR-6 (passkey support, follow-up)** — generate a passkey
   at account creation, store its public key server-side, use
   the passkey as the credential (no bearer at all).  Skippable
   for users on platforms where passkey enrollment is rough.

PR-2 + PR-3 are the minimum-shippable wallet.  PR-4 closes
the recovery story.  PR-5 is UX polish.  PR-6 is the v2
credential.

## Test plan

* **bats** — install verb writes files under docroot, vhost
  fragment is well-formed, uninstall removes them, upgrade
  preserves config.json, --backend writes correct config.json.
* **pytest** — the two new HTTP endpoints (PR-4) for recovery
  store + restore + rate-limit + unknown-hash 404.
* **manual** — install on a regtest node, open the PWA on a
  phone, create an account, receive on-chain regtest sats,
  the PR-4 deposit watcher credits the ledger, the PWA sees
  the new balance.

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
