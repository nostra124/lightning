---
id: FEAT-176
type: feature
priority: medium
status: done
---

# Lightning addresses (`alice@example.com`) — create, pay, host via Apache

## Description

**As a** Lightning user with Apache already running on my
host
**I want** to publish `alice@example.com` Lightning Addresses
and pay any address in the same format
**So that** receiving doesn't require sharing a fresh
invoice every time, and the user-facing payment surface
matches email's familiar shape.

Hosting is Apache-only. On `lightning address create` we
detect a running Apache, drop a small Python CGI script
under `.well-known/lnurlp/`, and wire the LNURL-pay flow
through it. No cluster integration, no standalone bash
daemon, no `lightning serve` — Apache is the single supported
front end. If Apache isn't installed, `address create` prints
a clear "install apache2 and rerun" message and exits non-
zero.

## Implementation

### Verbs

    lightning address resolve <addr>                # get LNURL-pay endpoint
    lightning address pay <addr> <sat> [--comment <text>]
                                                    # resolve + pay
    lightning address create <addr> [--account <name>]
                                                    # detect Apache, install
                                                    # the LNURL-pay handler
    lightning address list                          # owned addresses
    lightning address remove <addr>                 # remove handler + record

### Apache wiring (the one hosting mode)

**Detection.** `lightning address create` shells out
`command -v apache2` (or `httpd` on RPM-based systems) and
checks that the service is enabled. If absent, abort with a
clear message.

**The Python handler.** A single CGI script lives at:

    share/lightning/wellknown/lnurlp/handler.py

It is invoked by Apache for `/.well-known/lnurlp/<user>`.
On request, the script:

1. Reads `<user>` from `PATH_INFO`.
2. Shells out `sudo -u alice lightning api-lnurlp <user>
   [<msat> <comment>]` — the verb queries the per-wallet
   SQLite `users` table (FEAT-193) for the
   `<user> → <account>` binding and `min_sat / max_sat /
   comment_max` parameters.
3. If query string contains `amount=<msat>`, the verb mints
   a fresh BOLT-11 via `lightning invoice --account
   <account> --message <comment>` and returns the callback
   JSON (LUD-06 + LUD-12 metadata).
4. Otherwise returns the LUD-06 discovery JSON (callback
   URL, min/max amounts, metadata).

The script is < 100 lines of Python 3, no dependencies
beyond the stdlib. Soft deps on `python3` and `sqlite3`
declared at `.rpk/depends/`.

**Apache config snippet.** Shipped at
`share/lightning/apache/lnurlp.conf`. Drop-in for stock
Debian apache2:

    ScriptAlias /.well-known/lnurlp/ \
        /usr/share/lightning/wellknown/lnurlp/handler.py/
    <Directory /usr/share/lightning/wellknown/lnurlp>
        Options +ExecCGI
        SetHandler cgi-script
        Require all granted
    </Directory>

`lightning address create` writes/updates the snippet
idempotently (or hints the operator to drop it in if their
Apache config is unusual). TLS and DNS remain the operator's
job; the snippet's header comment points at certbot.

### BIP-353 DNS-based payment instructions

`lightning address create` prints the
`_bitcoin-payment.<user>` TXT record it would like the
operator to publish (per BIP-353). DNS provisioning is
manual in this scope; we don't shell out to any DNS tool.

### Account binding

`--account <name>` (FEAT-174) ties received payments at the
address to a specific account — `alice@example.com` →
`donations` account, etc. Auto-binding on
`account create --host <domain>` is FEAT-195's job.

## Acceptance Criteria

1. `lightning address resolve alice@coincorner.com` returns
   the LNURL-pay JSON with callback URL, min/max amounts.
2. `lightning address pay alice@coincorner.com 1000` resolves
   + pays end-to-end against a real testnet/mainnet address.
3. `lightning address create me@my-domain.com` with Apache
   installed:
   - drops `handler.py` and the vhost snippet
   - inserts a row into the `users` table (FEAT-193)
   - prints the BIP-353 TXT record to publish
   - results in a working
     `https://my-domain.com/.well-known/lnurlp/me` endpoint
     (assuming TLS / DNS is configured)
4. `lightning address create` without Apache prints "install
   apache2 first" and exits non-zero.
5. `lightning address remove` deletes the `users` row;
   handler.py and the vhost snippet stay (they handle every
   user from the table).
6. SIT (FEAT-182) covers address create + pay round-trip
   inside an Apache-equipped clightning regtest container.
