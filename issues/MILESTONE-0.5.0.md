# Milestone 0.5.0 — addresses, liquidity, bank mode, web API

```
milestone: 0.5.0
title: addresses, liquidity, bank mode, web API
status: open
depends_on: 0.4.0
```

## Summary

Ecosystem features that sit on top of the core verbs:

1. **FEAT-175 — liquidity layer** — inbound liquidity is the
   primary user story (a fresh node has zero inbound capacity
   and can't receive). `lightning liquidity in <amount>`
   acquires inbound via the default provider; LSPS1 channel
   purchase, Loop, and Boltz are all wired. Outbound is the
   symmetric secondary case.
2. **FEAT-176 — Lightning Addresses** —
   `alice@example.com`-style addresses: pay them, create your
   own, and host them via Apache + a small Python CGI script
   at `/.well-known/lnurlp/<user>`. Apache is the single
   supported front end.
3. **FEAT-195 — bank mode** — single-user multi-account
   discipline: overdraft policy, auto-address-on-account-
   create, per-period statements, per-account API key
   issuance for FEAT-196.
4. **FEAT-196 — `.well-known/lightning/` JSON API** — three
   small Python CGI endpoints (`send`, `recv`, `balance`)
   under `/.well-known/lightning/<user>/`. Per-account API
   keys; lets a phone / JS frontend / webhook drive the node
   without shell access. Sender messages plumb through
   LUD-12 to the remote ledger; local-only notes stay on
   this side. Three-user privilege layout
   (`clightning` / operator / `www-data`); bridge is
   sudo-to-operator. Formal BIP-style spec lives at
   `share/doc/lightning/standards/api/spec.md`.

## Dependency Order

FEAT-175 and FEAT-176 are independent. FEAT-195 depends on
FEAT-176 (auto-address binding) and FEAT-174 / FEAT-193 from
0.4.0. FEAT-196 depends on FEAT-176 (the same Apache vhost
snippet gains a second ScriptAlias) and FEAT-195 (per-account
API keys). All depend on the pay / invoice verbs from 0.3.0
and the wallet ledger from 0.4.0.

## Exit Criteria

- `lightning liquidity in <amount>` on a fresh zero-inbound
  node acquires inbound capacity (LSPS1 against a test LSP
  is the must-pass path; Loop / Boltz are also wired).
- `lightning liquidity status` reflects the new capacity.
- `lightning address pay <addr>` resolves and pays a
  Lightning Address.
- `lightning address create me@my-domain.com` detects Apache
  and installs the LNURL-pay handler at
  `/.well-known/lnurlp/me`; without Apache it exits non-zero
  with a clear message.
- `lightning account create alice --limit 50000 --host
  host.com` creates the account, issues `alice@host.com`,
  and enforces the ceiling on subsequent pays.
- `lightning account apikey create alice --scope write`
  prints a one-shot key.
- `lightning ledger statement --account alice --period
  2026-03` produces a parseable plaintext statement.
- `POST /.well-known/lightning/alice/recv` with the
  write-scope key returns a BOLT-11.
- `POST /.well-known/lightning/alice/send` with a message
  to a remote Lightning Address completes a payment
  end-to-end; the remote's ledger row carries the message;
  alice's ledger row carries both the message and the
  local note.
- `GET /.well-known/lightning/alice/balance` returns the
  current account balance + limit + overdraft policy.
- `share/doc/lightning/standards/api/spec.md` is in place
  and matches the implementation.
- `lightning daemon install --system` provisions the
  three-user layout; the sudoers bridge survives a
  reboot.
- Unit test contract extended.
- `.rpk/version` bumped 0.4.0 → 0.5.0; ledger updated.
- FEAT-175, FEAT-176, FEAT-195, FEAT-196 move to
  `issues/feature/done/`.

## Dependencies

Hard: 0.4.0. Soft: external services (Boltz, Loop server,
test LSP) — mocked at unit-test level, real in SIT
(FEAT-182). New runtime deps: `python3` (CGI scripts) and
`sqlite3` (per-wallet store). `apache2` is the operator's
choice; absent → addresses + API gracefully degrade with a
clear install hint.
