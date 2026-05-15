---
id: FEAT-176
type: feature
priority: medium
status: open
---

# Lightning addresses (`alice@example.com`) — create, pay, host

## Description

**As a** Lightning user
**I want** to publish my own `alice@example.com` Lightning
Address and to pay any address in the same format
**So that** receiving doesn't require sharing a fresh
invoice every time, and the user-facing payment surface
matches email's familiar shape.

## Implementation

### Verbs

    lightning address resolve <addr>                # get LNURL-pay endpoint
    lightning address pay <addr> <sat> [--comment <text>]
                                                    # resolve + pay
    lightning address create <addr> [--account <name>]
                                                    # set up own address
    lightning address list                          # owned addresses
    lightning address remove <addr>

### Hosting (three modes)

**Cluster mode** (preferred for cluster operators):

`cluster apache enable` (FEAT-079) or `cluster caddy enable`
(per FEAT-168) gains an LNURL-pay handler at
`https://<host>/.well-known/lnurlp/<user>` that returns the
right LNURL-pay JSON. The handler queries the local
`lightning` to mint an invoice on demand. DNS A record auto-
managed by `cluster dns`.

**Local-Apache mode** (single-user with an existing Apache):

For users who already run Apache locally but don't want the
whole `cluster` stack, we ship a drop-in vhost snippet under
`share/doc/lightning/apache/lnurlp.conf` that ProxyPasses
`/.well-known/lnurlp/<user>` to `lightning serve` (FEAT-190)
or the standalone daemon (below) on `127.0.0.1`. Installs via
`lightning address apache-snippet > /etc/apache2/sites-
available/lnurlp.conf`. TLS and DNS are the user's job;
hints in the snippet comments point at certbot.

**Standalone mode** (no web server at all):

`lightning address daemon start` runs a small bash HTTP
server (using `socat` / `nc` + a lightning-side handler)
listening on a configurable port, suitable for users
without any web server in front. They configure their own
DNS + TLS termination (e.g. via cloudflare tunnels).

### BIP-353 DNS-based payment instructions

`lightning address create` also registers a `_bitcoin-payment.<user>`
TXT record (per BIP-353) with the LNURL-pay URI, so
BIP-353-aware wallets can resolve directly via DNS. The TXT
record auto-managed by `cluster dns` in cluster mode.

### Account binding

`--account <name>` (FEAT-174) ties received payments at the
address to a specific account — so `alice@example.com`
funds go to the `donations` account by default, etc.

## Acceptance Criteria

1. `lightning address resolve alice@coincorner.com` returns
   the LNURL-pay JSON with callback URL, min/max amounts.
2. `lightning address pay alice@coincorner.com 1000` resolves
   + pays end-to-end against a real testnet/mainnet address.
3. `lightning address create me@my-domain.com` in cluster
   mode produces a working `https://my-domain.com/.well-known/
   lnurlp/me` endpoint that mints invoices via the local
   lightning node; another wallet can pay it.
4. `lightning address apache-snippet` emits a vhost
   fragment that works when dropped into a stock Debian
   `apache2` config (local-Apache mode).
5. Standalone-mode daemon serves the same endpoint when the
   user manages their own DNS + TLS.
6. BIP-353 TXT record gets created when `cluster dns` is
   available; falls back to a manual instruction message
   otherwise.
7. SIT (FEAT-182) covers address create + pay round-trip
   between two regtest nodes.
