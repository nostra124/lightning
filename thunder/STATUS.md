# thunderd — implementation status & the road to 2.0.0

This tracks what is **code-complete and tested** vs. what remains, so the
roadmap claims stay honest. Source of truth for the plan:
`../share/doc/lightning/standards/roadmap-overview.md`.

## Done — custodial Phase I (compiles, `clippy -D warnings`, 51 unit tests + live-node SIT, CI green)

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

## Validated against a live node (FEAT-309/310 — was mock-only)

The custodial cln-rpc integration is no longer only unit-tested with
mocks: `tests/sit/thunderd-live.sh` (`make check-thunderd-sit`) stands up
a regtest stack with podman — `bitcoind` + two Core Lightning nodes — and
drives the real `thunderd` daemon end-to-end against it. Proven green
(11/11) from a clean slate:

- **health/getinfo** — daemon connects to the live `lightningd`; the
  reported node id matches.
- **BOLT-11 receive** — a minted invoice decodes as valid *on-node* and
  appears in `listinvoices` (real RPC, not faked).
- **BOLT-12 offer** — minted offer decodes as a valid offer on-node.
- **auth contract** — invoice without a bearer is rejected `401`.
- **send** — pays a real BOLT-11 from a counterparty node over an open
  channel (`status: complete`), the custodial ledger debits correctly,
  and the counterparty confirms the invoice `paid`.
- **settlement reconciliation (FEAT-310)** — when the counterparty pays a
  thunderd-issued invoice, the `waitanyinvoice` reconciler credits the
  owning account's ledger.

This closes the "needs a live node to verify" gap for the custodial tier
and is the concrete foundation for the `2.0.0` shadow-run (FEAT-326). The
container image is `tests/sit/podman/Dockerfile.thunderd` (multi-stage
Rust build, runs as uid 1000 to reach the `lightning-rpc` socket shared
in over a volume).

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

## The 2.0.0 cutover runbook

The repo is now at **`2.0.0`**: the account/commerce **HTTP API is served
by `thunderd`**. The breaking step that defines the major bump — retiring
the bash CGI dispatcher and repointing the served API — has landed in
code. Status of each runbook step:

1. **Shadow-run** (FEAT-326): the live-node harness (`make
   check-thunderd-sit`) proves `thunderd` drives a real `lightningd`
   end-to-end (11/11). A production traffic-mirroring diff against the
   legacy CGI is the one step that still needs the **production node**.
2. **Import** (FEAT-308, shipped): `thunderd migrate --from <wallet>/state.db`
   (dry-run first), reconcile balances against the ledger invariant. Run
   once before flipping production traffic.
3. **Flip the proxy** (FEAT-327, **done**): `share/lightning/apache/lnurlp.conf`
   reverse-proxies `/.well-known/lightning/v1/accounts` → thunderd's
   `/.well-known/thunder/v1/accounts` (deprecated transitional alias).
4. **Retire the old layer** (FEAT-328, **partially done**): the CGI
   dispatcher `wellknown/api/accounts.py` is deleted; its dispatcher tests
   were removed and the apache-mapping tests now assert the proxy. The
   `api-account-*` shell verbs are **kept as operator-local helpers** —
   they cannot yet be removed because the FEAT-196 Lightning-Address flow
   and the operator wallet (`wallet ledger`/`history`, `address`) share the
   same `accounts`/`ledger` tables and the `account` verb delegates to
   `api-account-transfer`. Fully shedding the operator-side commerce state
   is the **post-2.0 cleanup** (it needs the state-ownership migration:
   repoint those kept consumers at thunderd first).
5. **Extract** (FEAT-329/431): `git filter-repo` the `thunderd/` workspace
   into its own repo (the one-way carve-out boundary makes this mechanical)
   and bump that repo to its own 1.0. Post-2.0.
