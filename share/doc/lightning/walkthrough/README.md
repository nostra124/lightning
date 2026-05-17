# `lightning` end-to-end walkthrough (regtest)

> Per FEAT-181. Run on a fresh machine, follow the prompts,
> end up with a working node + Lightning Address + paid
> invoice + JSON API + inbound liquidity. Every step cites
> the BOLT / LUD / BLIP that governs the behaviour.

Target: **clightning on bitcoind regtest, all in one box.**
For multi-machine / per-network testing, see the SIT suite
at `tests/sit/`.

## Prerequisites

- Linux (Debian/Ubuntu tested; RPM distros work with `httpd`
  in place of `apache2`)
- bitcoind 27+
- clightning (Core Lightning) 24.05+
- The `lightning` package installed: `./configure && make
  install`
- `apache2`, `python3`, `sqlite3`, `git`, `jq`, `qrencode`

Time budget: 30 minutes for the happy path.

## 1. Setup (bitcoind + clightning + lightning)

Cite: BOLT-1 §protocol-model.

    # bitcoind on regtest. Mine 101 blocks to mature the
    # coinbase reward into a spendable UTXO.
    bitcoind -regtest -daemon
    sleep 2
    bitcoin-cli -regtest createwallet test
    addr=$(bitcoin-cli -regtest getnewaddress)
    bitcoin-cli -regtest generatetoaddress 101 "$addr"

    # clightning, driven by `lightning`.
    export LIGHTNING_DIR=$HOME/.lightning
    export LIGHTNING_NETWORK=regtest
    lightning daemon start
    lightning info       # confirm node is up

> Reading: `share/doc/lightning/standards/cln-overview.md`
> if you want the 10-minute tour.

## 2. Create a wallet

Cite: FEAT-174 / FEAT-193 — git-backed SQLite store.

    lightning wallet new alice
    lightning account create personal --description "everyday"
    lightning account create donations --description "tip jar"
    lightning account list

## 3. Open a channel

Cite: BOLT-2 §peer-protocol-for-channel-management.

Spin up a second clightning node as a peer:

    bob_dir=$(mktemp -d)
    lightningd --lightning-dir="$bob_dir" --network=regtest \
               --bitcoin-rpcuser=$(grep rpcuser  ~/.bitcoin/regtest.conf | cut -d= -f2) \
               --bitcoin-rpcpassword=$(grep rpcpassword ~/.bitcoin/regtest.conf | cut -d= -f2) \
               --daemon

    bob_id=$(lightning-cli --lightning-dir="$bob_dir" --network=regtest getinfo | jq -r .id)
    bob_port=$(lightning-cli --lightning-dir="$bob_dir" --network=regtest getinfo | jq -r '.binding[0].port')

    # Fund alice's on-chain wallet.
    alice_addr=$(lightning balance --on-chain)
    bitcoin-cli -regtest sendtoaddress "$alice_addr" 1
    bitcoin-cli -regtest generatetoaddress 6 "$addr"

    # Open the channel.
    lightning channel open "${bob_id}@127.0.0.1:${bob_port}" 100000
    bitcoin-cli -regtest generatetoaddress 6 "$addr"
    lightning channel list

## 4. Pay an invoice (BOLT-11)

Cite: BOLT-11 §invoice-protocol-for-lightning-payments.

    # From bob, mint an invoice for 5000 sat.
    bob_bolt11=$(lightning-cli --lightning-dir="$bob_dir" \
                                --network=regtest invoice 5000000 beer "test" \
                  | jq -r .bolt11)

    # From alice, pay it. --qr would also render a QR.
    lightning pay "$bob_bolt11"
    lightning ledger list --account personal

## 5. BOLT-12 offer

Cite: BOLT-12 §offer-encoding.

    # From bob, create a reusable offer.
    bob_offer=$(lightning-cli --lightning-dir="$bob_dir" \
                                --network=regtest offer 1000msat "tip jar" \
                  | jq -r .bolt12)

    # From alice, fetch + pay.
    lightning offer-pay "$bob_offer"

## 6. LNURL

Cite: LUD-06 §payRequest.

    # Mock a LUD-06 endpoint locally for the demo.
    # In a real run you'd use a public address like
    # alice@coincorner.com — see step 7 for hosting.
    lightning lnurl pay alice@example.com 100 --comment "thanks"

## 7. Lightning Address (LUD-16)

Cite: LUD-16 + BIP-353. See `share/doc/lightning/standards/`.

    # Apache vhost + LUD-16 CGI handler.
    sudo a2enmod cgi headers rewrite
    sudo cat /usr/share/lightning/apache/lnurlp.conf >> \
        /etc/apache2/sites-available/000-default.conf
    sudo systemctl reload apache2

    # Register alice's address.
    lightning address create alice@example.com --account personal

    # From bob (or any LUD-16 wallet):
    lightning address pay alice@example.com 100 --comment "hi"

If you don't have a real domain, point `/etc/hosts`
`example.com` at `127.0.0.1` for the walkthrough.

## 8. JSON API (FEAT-196)

Cite: `share/doc/lightning/standards/api/spec.md`.

    # Issue alice a write-scope API key.
    key=$(lightning account apikey create alice --scope write | tail -1)

    # `recv`: mint an invoice over HTTP.
    curl -fsSL -H "X-API-Key: $key" \
         -d '{"sat":1000,"message":"api test"}' \
         http://example.com/.well-known/lightning/alice/recv

    # `send`: pay another address over HTTP.
    curl -fsSL -H "X-API-Key: $key" \
         -d '{"to":"bob@example.com","sat":500,"message":"thx","note":"march"}' \
         http://example.com/.well-known/lightning/alice/send

    # `balance`: read-scope key works too.
    curl -fsSL -H "X-API-Key: $key" \
         http://example.com/.well-known/lightning/alice/balance

The `note` field stays on this side (`ledger.note`). The
`message` field rides LUD-12 to the recipient.

## 9. Inbound liquidity (LSPS1)

Cite: BLIP-51.

    lightning liquidity status      # currently zero inbound
    lightning liquidity provider default lsp

    # Configure an LSP endpoint (URL of an LSPS1-compliant
    # service). For regtest, use the lsps-server stub from
    # the SIT container.
    mkdir -p $LIGHTNING_WALLETS_ROOT/alice/liquidity/lsp/regtest
    echo "http://127.0.0.1:9737" > \
        $LIGHTNING_WALLETS_ROOT/alice/liquidity/lsp/regtest/endpoint

    lightning liquidity in 100000
    bitcoin-cli -regtest generatetoaddress 6 "$addr"
    lightning liquidity status      # 100_000 sat inbound

## 10. Wallet sync

Cite: FEAT-174 §push/pull.

    # Set up a bare-repo remote (in real life, a remote host).
    git init --bare /tmp/alice-bare.git
    (cd $LIGHTNING_WALLETS_ROOT/alice && \
        git remote add origin /tmp/alice-bare.git)

    lightning backup --remote origin

    # On a fresh machine:
    lightning restore /tmp/alice-bare.git alice
    lightning info     # alice's pubkey is back

If you've stored the seed via `lightning seed export`, the
backup `--seed` flag encrypts it into the wallet repo.
Otherwise it's in your head, where it belongs.

## What just happened

| Step | Cited spec                                         | Local path                                   |
|------|----------------------------------------------------|----------------------------------------------|
| 1    | BOLT-1                                             | `bolts/01-messaging.md`                      |
| 2    | FEAT-174 / 193                                     | `issues/feature/done/174-*.md`               |
| 3    | BOLT-2                                             | `bolts/02-peer-protocol.md`                  |
| 4    | BOLT-11                                            | `bolts/11-payment-encoding.md`               |
| 5    | BOLT-12                                            | `bolts/12-offer-encoding.md`                 |
| 6    | LUD-06                                             | `lnurl-rfc/lud-06.md`                        |
| 7    | LUD-16 + BIP-353                                   | `lightning-address/spec.md` + `bips/bip-353.md` |
| 8    | FEAT-196 spec                                      | `api/spec.md`                                |
| 9    | BLIP-51                                            | `blips/blip-51.md`                           |
| 10   | FEAT-174                                           | `issues/feature/done/174-*.md`               |

All paths are relative to `share/doc/lightning/standards/`.

## Teardown

    lightning daemon stop
    rm -rf "$LIGHTNING_DIR" "$LIGHTNING_WALLETS_ROOT/alice"
    bitcoin-cli -regtest stop
