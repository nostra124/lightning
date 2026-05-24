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

## Self-custody notes

Custodial-by-default when provider-hosted; mitigations are a transparent
ledger, withdraw-anytime, and BOLT-12 receive directly to the node. Run
the same install on your own Tailscale-reachable machine to hold your own
keys.
