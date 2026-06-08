# Lightning Wallet PWA — usage

A thin, same-origin client for one node's account API. The node does the
work (crediting deposits, GC, rebalancing); the PWA just talks to it.

## First run

1. Open the wallet URL (e.g. `https://your-host/lightning`).
2. Tap **Create my first account**. The PWA calls `POST /accounts`
   (anonymous) and the node returns an `account_id` and a one-time
   `api_key`.
3. **Save the API key.** It is shown once. It is your backup credential —
   anyone holding it controls the account. Copy or download it.
4. You land on the account view: balance, and a **Top up** button that
   shows your on-chain address. Send BTC there; the node's deposit
   watcher credits your ledger within ~1 minute.

## Everyday use

- **Send**: paste a BOLT-11 invoice, tap Pay.
- **Receive**: enter an amount + description, mint a BOLT-11 invoice to
  share.
- **Settings**: reveal the API key (for LLM agents / CLI), or forget the
  account on this device (funds stay on the node).

## Credentials

- **API key** (`lt_…`): the bearer this PWA uses today, and what LLM
  agents / CLI / server-to-server callers use. Long-lived; store safely.
- **Passkey** (WebAuthn): no plaintext bearer on the device — a
  follow-up backend (FEAT-209 PR-2b).

## Commerce (FEAT-231)

The **Commerce** button on the account view opens:

- **Point of sale** — enter an amount (with a live fiat estimate), mint a
  commercial invoice, show it to the payer, and watch it flip to **PAID**
  (the PWA polls the invoice until settled).
- **Transfer** — send to another local account by name or address.
- **Standing orders** — create / pause / resume / cancel recurring pushes.
- **Direct-debit mandates** — authorize a merchant (the secret is shown
  once to hand over), switch auto / approval mode, and approve or deny
  pending charges in the approval inbox.

Balances and amounts show a fiat estimate alongside sats (from the public
price tick). Settings → **Export transaction data (for tax)** downloads a
FIFO-matched CSV — source data, not a report.

## Offline & notifications (FEAT-346/347)

A service worker (`sw.js`) caches the app shell so the PWA opens and
renders offline; cached read screens stay usable without a connection.
The account API (anything under `/.well-known/…`) is **never** cached —
balances and bearer-authed calls always hit the network so nothing
money-sensitive lingers on disk. The worker stays same-origin (no
absolute URLs), preserving the "trust the origin you loaded" stance.

Settings → **Enable notifications** is opt-in web push: it asks
permission and subscribes via the worker's `pushManager`. Today it is
groundwork — the wake path the node uses to nudge a device when something
needs it (e.g. a pending signature in the non-custodial tier). The push
payload is advisory only; the app re-authenticates and fetches the real
request when opened.

## Self-custody notes

Custodial-by-default when provider-hosted; mitigations are a transparent
ledger, withdraw-anytime, and BOLT-12 receive directly to the node. Run
the same install on your own Tailscale-reachable machine to hold your own
keys.
