# thunderd — implementation status & the road to 2.0.0

This tracks what is **code-complete and tested** vs. what remains, so the
roadmap claims stay honest. Source of truth for the plan:
`../share/doc/lightning/standards/roadmap-overview.md`.

## Done — custodial Phase I (compiles, `clippy -D warnings`, 40 tests, CI green)

- **Foundations** (FEAT-300/301/302): workspace, `thunderd`+`thunderd-cli`,
  config, logging, `cln-rpc` probe, make targets, systemd unit, carve-out guard.
- **HTTP/auth/discovery** (303/304/305): axum (health, versions, CORS, body
  limit), Bearer + mandate-secret auth, typed status contract, Apache fragment.
- **Ledger** (306/307): owned SQLite + migrations; double-entry msat engine
  (atomic transfers, overdraft guard, system accounts, fee-aware charge).
- **Node integration** (309/310): cln-rpc invoice/pay/decode/waitanyinvoice;
  settlement reconciler.
- **Accounts/payments/commerce** (313/314/315/316/317/318): accounts + API
  keys; internal pay + external send + invoice recv; standing orders + runner;
  mandates; auth/capture/void/refund charges.
- **Policy/ops** (319/321/322/323/324): history + CSV; fee skim; compliance
  veto + audit; capability profiles; rate limiting.
- **Identity** (222): WebAuthn passkey register/login + sessions.
- **Migration** (308): `thunderd migrate` legacy importer.
- **Referrals** (320): fee split to referrer.

## Done — Phase II transport + on-chain construction (FEAT-400/41x)

- Tenant + **watch-only xpub** registration (custody bar A2 — no spendable
  key on the server).
- **Remote-signer transport**: enqueue signing request → device fetches
  pending → signs locally → returns signature. Session-gated, tested.
- **On-chain (rust-bitcoin)**: real xpub→p2wpkh **address derivation** and
  unsigned **PSBT construction** from supplied UTXOs (fee computed), then
  enqueued to the signer. Pure + unit-tested (`GET /tenants/{id}/onchain/
  address`, `POST /tenants/{id}/onchain/psbt`).

## NOT implemented — needs a live engine / environment (documented, not faked)

These cannot be built *and verified* in CI without real Lightning/on-chain
infrastructure, so they are intentionally **not** shipped as code:

1. **Per-tenant LDK node engine** (FEAT-407+): spin per-tenant LDK nodes,
   open/manage channels via the companion `lightningd` as LSP/counterparty.
   HTTP `/tenants/{id}/node` returns 501 until this lands.
2. **On-chain UTXO discovery + broadcast** (FEAT-41x): PSBT *construction*
   and address derivation are done (above); what still needs a live node is
   chain-scan to discover UTXOs (callers supply inputs for now) and
   broadcasting the finalized tx.
3. **Validating remote signer (VLS-style)** — **done** as the `signer-core`
   crate (validate PSBT against a device policy + sign controlled p2wpkh
   inputs; unit-tested). Closes the A2 loop with the daemon's PSBT builder.
   (LDK commitment-tx signing is part of the LDK engine, item 1.)
4. **thunder-pay PWA** (FEAT-340-349): the browser frontend. `signer-core`
   is structured to compile to WASM for it; the PWA itself is a separate
   codebase.

## The 2.0.0 cutover runbook (operational — needs the production node)

`2.0.0` is the breaking release; it is a *sequence of operational steps*,
not a code patch, and must follow a validated shadow-run:

1. **Shadow-run** (FEAT-326): deploy `thunderd` beside the live CGI; mirror
   a copy of traffic to `/.well-known/thunder/v1`; diff responses against the
   legacy `/.well-known/lightning/v1/accounts/*` until parity holds.
2. **Import** (FEAT-308, shipped): `thunderd migrate --from <wallet>/state.db`
   (dry-run first), reconcile balances against the ledger invariant.
3. **Flip the proxy** (FEAT-327): point Apache at `thunderd`
   (`dist/thunderd-apache.conf`); 301 the legacy URLs.
4. **Retire the old layer** (FEAT-328): delete `api-account-*` verbs, the
   commerce CGI + `_lib.py` paths, trim the wallet `state.db` commerce
   schema, update man pages. **This is the breaking change** that returns
   `lightning` to simple administration — do it only after cutover holds.
5. **Extract** (FEAT-329/431): `git filter-repo` the `thunderd/` workspace
   into its own repo (the one-way carve-out boundary, enforced since day one,
   makes this mechanical) and bump that repo to its own 1.0.

Until steps 1 and 4 are executed against the real node, bumping the repo to
`2.0.0` would be a false claim — so the version stays sub-2.0 here.
