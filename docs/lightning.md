# `lightning` — CLI contract reference

> Per FEAT-177. Authoritative reference for every verb,
> argument, env var, file path, and exit code. The bats
> suite in `tests/unit/lightning.bats` is the executable
> contract; this file is its prose form.

`lightning(1)` is the man-page rendering of the same
contract (`share/man/man1/lightning.1`).

## Synopsis

    lightning [-d] [-q] <command> [args]

Options:

- `-d` — debug mode (`set -x` everywhere the dispatcher sees)
- `-q` — quiet mode (suppress info-level chatter)

## Environment

| Var                       | Default                       | Used by                          |
|---------------------------|-------------------------------|----------------------------------|
| `LIGHTNING_DIR`           | `$HOME/.lightning`            | every verb that calls `lightning-cli` |
| `LIGHTNING_NETWORK`       | `bitcoin`                     | same                              |
| `LIGHTNING_WALLETS_ROOT`  | `$HOME/.lightning/wallet`     | wallet / account / ledger / address |
| `SELF_LIBEXEC`            | auto-detected                 | sub-verb dispatch                  |
| `SELF_QUIET`              | unset                         | `lightning -q` sets this           |
| `SELF_DEBUG`              | unset                         | `lightning -d` sets this           |

## Verb surface

### Node introspection

| Verb             | Args               | Output         | Notes                             |
|------------------|--------------------|----------------|-----------------------------------|
| `info`           | —                  | plaintext      | summary of `lightning-cli getinfo`|
| `node-id`        | —                  | `<pubkey>`     | `getinfo .id`                     |
| `peers`          | —                  | TSV (4 cols)   | `pubkey/connected/features/addr`  |
| `channels`       | —                  | TSV (6 cols)   | `id/peer/capacity/local/remote/state` |
| `balance`        | `[--on-chain]`     | TSV row or addr| `--on-chain` -> receive address   |

### Channels — `channel <subcommand>`

| Sub      | Args                                       | Output          |
|----------|--------------------------------------------|-----------------|
| `list`   | —                                          | TSV (alias for `channels`) |
| `open`   | `<node-uri> <sats> [--push <sats>]`        | `ok` + IDs      |
| `close`  | `<channel-id>`                             | `ok` + txid     |
| `force-close` | `<channel-id> --confirm`              | warning + close |
| `balance`| `[<channel-id>]`                           | TSV             |
| `info`   | `<channel-id>`                             | JSON            |
| `pending`| —                                          | TSV             |

### Payments / invoices / decode

| Verb       | Args                                                 | Output                |
|------------|------------------------------------------------------|-----------------------|
| `invoice`  | `<sat> <label> [--description T] [--expiry S] [--qr]`| BOLT-11 (+ QR)        |
| `pay`      | `<bolt11> [--max-fee-sat N] [--timeout S]`           | `ok` + hash + fee     |
| `send`     | `<node-id> <sat> [--message T]`                      | keysend; hash         |
| `decode`   | `<string>`                                           | `type:` + decoded JSON|
| `offer`    | `<sat>\|any <desc> [--qr]`                           | BOLT-12               |
| `offer-pay`| `<bolt12> [<sat>] [--message T]`                     | hash                  |
| `lnurl`    | `decode <url>` / `pay <addr> <sat> [--comment T]`    | metadata or hash      |
| `qr`       | `<text> [--png F\|--svg F\|--ansi]`                  | QR (terminal or file) |

### Wallet + accounts + ledger

| Verb                     | Args                                                                 |
|--------------------------|----------------------------------------------------------------------|
| `wallet new`             | `<name>`                                                             |
| `wallet use`             | `<name>`                                                             |
| `wallet list`            | —                                                                    |
| `wallet active / path`   | —                                                                    |
| `wallet push/pull/sync`  | `[<remote>]` (default `origin`)                                      |
| `account list`           | `[--balances]`                                                       |
| `account create`         | `<name> [<desc>] [--limit S] [--overdraft P] [--host D]`             |
| `account delete / show`  | `<name>`                                                             |
| `account apikey`         | `{create,list,revoke} <name> --scope read\|write`                    |
| `ledger list`            | `[--account N] [--since D] [--limit N]`                              |
| `ledger sum`             | `[--by account\|day\|month\|year] [--account N]`                     |
| `ledger balance`         | `[<account>]`                                                        |
| `ledger annotate`        | `<payment_hash> <note>`                                              |
| `ledger statement`       | `--account N --period <YYYY-MM\|YYYY-Q[1-4]\|YYYY> [--tsv]`          |
| `ledger export`          | `tsv\|csv\|jsonl`                                                    |
| `history`                | alias for `ledger list`                                              |

### Seed + backups

| Verb                | Args                                          |
|---------------------|-----------------------------------------------|
| `seed`              | `export / import / verify`                    |
| `scb`               | `emit [--out F]` / `restore <file>`           |
| `backup`            | `[--seed] [--remote N]`                       |
| `restore`           | `<wallet-remote-url> [<wallet-name>]`         |

### Liquidity + addresses

| Verb                 | Args                                                         |
|----------------------|--------------------------------------------------------------|
| `liquidity status`   | —                                                            |
| `liquidity in`       | `<sat> [--provider N]`                                       |
| `liquidity out`      | `<sat> [--provider N]`                                       |
| `liquidity loop`     | `in\|out <sat>`                                              |
| `liquidity boltz`    | `in\|out <sat>`                                              |
| `liquidity lsp`      | `<name> buy <sat>`                                           |
| `liquidity provider` | `default <name>`                                             |
| `address create`     | `<user@domain> [--account N]` (requires apache2)             |
| `address pay`        | `<addr> <sat> [--comment T]`                                 |
| `address resolve`    | `<addr>`                                                     |
| `address list / remove / apache-snippet` | various                                  |

### Daemon control + unlock + tor

| Verb       | Args                                                                |
|------------|---------------------------------------------------------------------|
| `daemon`   | `start / stop / restart / status / logs / install [--system] [--migrate]` |
| `unlock`   | `[--stored \| rotate \| forget] [--wallet N]`                       |
| `tor`      | `on / off / status`                                                 |

### Sudo-bridge (internal — used by the FEAT-196 CGI)

`api-verify`, `api-recv`, `api-send`, `api-balance` are
narrow-shape verbs called from
`share/lightning/wellknown/lightning/*.py`. They're not
intended for direct shell use; the sudoers fragment at
`share/lightning/sudoers.d/lightning` restricts `www-data`
to exactly these verb names with argument-shape globs.

## Filesystem layout (installed)

    $PREFIX/bin/lightning
    $PREFIX/bin/lightning.sh          # symlink for sourceable mode
    $PREFIX/libexec/lightning/<verb>
    $PREFIX/share/lightning/version
    $PREFIX/share/lightning/schema.sql
    $PREFIX/share/lightning/hooks/{pre-commit,post-merge}
    $PREFIX/share/lightning/apache/lnurlp.conf
    $PREFIX/share/lightning/sudoers.d/lightning
    $PREFIX/share/lightning/logrotate/lightning
    $PREFIX/share/lightning/wellknown/lnurlp/handler.py
    $PREFIX/share/lightning/wellknown/lightning/{send,recv,balance,_lib}.py
    $PREFIX/share/doc/lightning/standards/...
    $PREFIX/share/man/man1/lightning.1
    $PREFIX/etc/bash_completion.d/lightning

## Filesystem layout (per user)

    $LIGHTNING_DIR/                       # clightning data dir
        config
        hsm_secret
        <network>/lightning-rpc
        <network>/log
    $LIGHTNING_WALLETS_ROOT/<name>/       # one wallet repo per <name>
        .git/
        lightning-dir
        state.db                          # SQLite (gitignored)
        state.sql                         # readable dump (tracked)
        scb/scb-<utc>.hex                 # FEAT-185
        liquidity/<provider>/             # FEAT-175
    $LIGHTNING_WALLETS_ROOT/../active     # active-wallet pointer

## Exit codes

| Code | Meaning                                                                  |
|------|--------------------------------------------------------------------------|
| 0    | success                                                                  |
| 1    | generic error (unknown verb, bad args, malformed input)                  |
| 2    | business-rule failure (force-close without `--confirm`, no active wallet)|
| 3    | configuration failure (apache not installed, hsm_secret already exists)  |
| 4    | payment / unlock failure                                                 |
| 5    | rotate / restore failure                                                 |
| 6    | overdraft / limit violation (used by `api-send`)                         |
| 127  | soft dependency absent (`lightning-cli`, `sqlite3`, `qrencode`, …)       |

## Soft dependencies

| Tool          | Used by                          | Absent behaviour                       |
|---------------|----------------------------------|-----------------------------------------|
| `lightning-cli` | every node-touching verb       | exit 127 with install hint              |
| `sqlite3`     | wallet / account / ledger        | exit 127                                |
| `jq`          | every JSON-reshaping verb        | exit 127                                |
| `git`         | wallet (init / push / pull)      | exit 127                                |
| `qrencode`    | `qr`, `invoice --qr`             | fallback to raw text + hint             |
| `python3`     | FEAT-176 / 196 CGI scripts       | only matters at HTTP-request time       |
| `apache2`     | FEAT-176 / 196                   | `address create` exits 3                |
| `tor`         | FEAT-189                         | `tor status` reports `tor: NOT running` |
| `secret`      | unlock + account apikey          | exit 127                                |
| `account`     | wallet push/pull (remote-url)    | exit 127                                |

## See also

- `man lightning`
- `share/doc/lightning/standards/cln-overview.md` — 10-minute clightning tour
- `share/doc/lightning/standards/api/spec.md` — Lightning Well-Known JSON API spec
- `CLAUDE.md` — agent guide
- `skills/lightning-wallet/SKILL.md` — agent skill
