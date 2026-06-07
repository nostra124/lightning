# `thunder-pay` — the PWA web frontend for `thunderd`

**Status:** Planning. See `roadmap-overview.md` for context.

**`thunder-pay`** is the **web frontend for `thunderd`** — the nice PWA
over both account tiers (custodial + non-custodial). It starts as the
existing PWA (`share/lightning/ui/`) separated so it can be deployed on
its own host (Apache) as a pure client of `thunderd`'s
`/.well-known/thunder/v1` API, and later becomes its own installable app.
It also grows the device-signing primitives the non-custodial tier
(`thunderd` Phase II) depends on, sharing the `signer-core` (WASM) crate.

## 1. What exists today

- `share/lightning/ui/`: zero-build single-file SPA — `app.js` (~1077
  lines), `style.css`, `index.html`, `manifest.webmanifest`,
  `config.json`, `icon.svg`, `docs/`.
- Hash router, 21 screens, a clean `api(path,{method,key,body})` fetch
  wrapper hitting `CONFIG.api_base`.
- State in `localStorage` (accounts + their `lt_` keys) and
  `sessionStorage` (passkey session token).
- **WebAuthn passkey helpers already present** (`passkeyCreate` /
  `passkeyGet`, FEAT-222) — the crypto-on-device foundation is here.
- Installed by `libexec/lightning/ui` which generates
  `share/lightning/apache/ui.conf` (Alias `/lightning` + SPA fallback).
- **No service worker** (installable by manifest, but not offline).
- Manifest tagline already claims *"self-custodial-by-default"* — only
  becomes true once the device-signing ladder (below) lands.

## 2. The one real consequence: same-origin → cross-origin

Today a bats test deliberately asserts `app.js` is **hardwired
same-origin**: a security stance — "if you loaded the PWA you trust the
API behind it; the bearer never leaves that origin." Factoring the PWA
onto its own host breaks that, so:

- The `accounts` plugin (Track A) must support an explicit **CORS
  origin-allowlist + preflight** (tracked in Track A M0/M1).
- **Default deploy stays same-origin** (the plugin may bundle + serve the
  PWA for the single-box case); **cross-origin/CDN is opt-in.**

## 3. The device-signing ladder (the bridge to Track C)

The PWA is on rung 1 today; rung 2 is cheap because passkeys already
exist, and it produces the primitives Track C reuses.

1. **Custodial + device authorizes** (today): node holds keys; device
   holds a bearer token.
2. **Device holds a key; every spend is device-signed.** Use the
   **WebAuthn PRF extension** on the existing passkey to derive a
   wrapping key → encrypt a real **secp256k1** key (`@noble/curves`),
   ciphertext in IndexedDB. That key signs payment intents and doubles as
   LNURL-auth / message-signing / identity. Server verifies before
   acting. *Still custodial economically, but every action is
   device-authorized.*
3. **Full self-custody** = Track C (`thunderd`): the device key controls
   the *channel*, not just an intent.

## 4. Milestones & features

Feature numbers are proposed placeholders.

### PW0 — Decouple
- **FEAT-340 — Configurable API base, hardened.** `config.json` already
  exposes `api_base`; make cross-origin a first-class (opt-in) mode,
  multi-node aware, with a clear trust prompt.
- **FEAT-341 — CORS handshake.** Client side of the CORS contract;
  cross-origin bearer storage; pairs with the plugin's allowlist.
- **FEAT-342 — Carve-out CI guard.** Assert no path/coupling back into
  `lightning` (mirror Track A's guard).

### PW1 — Own its scaffolding
- **FEAT-343 — Installer + vhost extraction.** Move `libexec/lightning/ui`
  + `ui.conf` generation into the PWA repo (or ship as plain static
  assets deployable to any host/CDN).
- **FEAT-344 — Test extraction.** Port the grep-based bats UI assertions
  (FEAT-209/222/231/245/246/253/257/258/262/265 …) to a JS runner
  (vitest + Playwright) inside the PWA repo.
- **FEAT-345 — Docs travel with the PWA.** `docs/` + `llms.txt` move with
  the app.

### PW2 — Real PWA
- **FEAT-346 — Service worker + offline app shell.** Cache the shell,
  offline-first read screens, background-sync hooks.
- **FEAT-347 — Web Push plumbing.** Notification permission + push
  subscription, groundwork for Track C's push-to-sign wake.
- **FEAT-348 — Device-signing rung 2.** PRF-wrapped secp256k1 key;
  sign-intent flow; reused wholesale by Track C.

### PW3 — Extract
- **FEAT-349 — `git filter-repo` → `thunder-pay`.** Own versioning;
  the `accounts` plugin can still optionally bundle + serve it for the
  single-box deploy.

## 5. Open decisions
1. **Default deployment:** same-origin bundled (recommended) vs.
   cross-origin/CDN-primary.
2. **Test stack:** vitest + Playwright vs. another runner.
3. **Rung-2 scope in Track B** vs. deferring all signing to Track C.
</content>
