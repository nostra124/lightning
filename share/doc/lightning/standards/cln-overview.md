# clightning (Core Lightning): a 10-minute tour

> Vendored per FEAT-178 §cln-overview as the educational
> centrepiece for the single-backend release. After
> reading, you should have a mental model of every binary
> `lightning` shells into.

## The pieces

clightning ships four executables:

| Binary             | Role                                                     |
|--------------------|----------------------------------------------------------|
| `lightningd`       | The long-running daemon. Owns the channel state, RPC.    |
| `lightning-cli`    | JSON-RPC client over the unix socket at                  |
|                    | `<data-dir>/<network>/lightning-rpc`.                    |
| `lightning-hsmtool`| Offline tool for the HSM seed file (`hsm_secret`):       |
|                    | encrypt / decrypt / generate / dump mnemonic.            |
| `lightningd-plugin`| Loaded dynamically; plugins extend the RPC surface.      |

Plus a bunch of stock plugins ship inside the `lightningd`
binary: `pay`, `keysend`, `bookkeeper`, `funder`,
`offers`, `topology`, `commando`, etc. `lightning-cli help`
lists everything currently loaded.

## Data layout

Default data dir is `~/.lightning/` for user-mode and
`/var/lib/clightning/` for system-mode (FEAT-183
`daemon install --system`). Inside:

    <data-dir>/
        hsm_secret         # the seed. 32 bytes (raw) or 73 (encrypted).
        config             # main config; we edit this for Tor (FEAT-189).
        bitcoin/           # one subdir per network
            lightningd.sqlite3   # channel state + payments + invoices
            lightning-rpc        # unix socket (mode 0660 in system-mode)
            log                  # the daemon log
            <plugin-state>/      # per-plugin storage
        regtest/           # same shape for regtest
        testnet/           # same shape for testnet

`lightning` never writes inside `<data-dir>`; we only read
the RPC socket and `config`.

## The wire surface in three layers

### Layer 1 — bitcoind

`lightningd` keeps a persistent connection to a bitcoind
RPC. It uses this for:

- watching channel-funding txs confirm
- broadcasting force-close commitment txs
- watching for breaches (other side publishing a stale
  commitment)
- on-chain funds in the LN wallet (the "internal" wallet)

This is *clightning's* bitcoind, not `lightning`'s — we
never shell out to `bitcoind` or the `bitcoin` rpk package.

### Layer 2 — peer connections (BOLT-1, BOLT-8)

`lightningd` opens TCP connections (clearnet, Tor, or
both) to other Lightning nodes. BOLT-1 defines the
message-typed protocol; BOLT-8 wraps it in an encrypted +
authenticated transport (Noise XK with Curve25519 +
ChaCha20-Poly1305). After handshake, every message is
framed and authenticated.

### Layer 3 — channel state (BOLT-2, BOLT-3, BOLT-5)

A channel is a 2-of-2 multisig output funded on-chain. The
state is a commitment transaction that either party can
broadcast to claim their balance. Updates happen by
co-signing a new commitment + revoking the old one
(BOLT-2). BOLT-3 specifies the exact transaction format;
BOLT-5 governs what to do when something hits chain.

## How `lightning` talks to it

Every verb in `libexec/lightning/<verb>` shells out via:

    lightning-cli --lightning-dir=$LIGHTNING_DIR \
                  --network=$LIGHTNING_NETWORK \
                  <rpc-method> [args]

The output is JSON; `jq` reshapes it. There is no shared
helper library — each verb script is self-contained.

## BOLT-12 (offers) — what's specific to clightning

clightning is the BOLT-12 reference implementation. The
`offer` plugin ships in the daemon; the relevant RPCs are:

| RPC                      | Verb in `lightning`                            |
|--------------------------|------------------------------------------------|
| `offer`                  | `lightning offer <sat> <description>`          |
| `fetchinvoice`           | called from `lightning offer-pay`              |
| `disableoffer`           | (TODO: `lightning offer-revoke`)               |
| `listoffers`             | (TODO: `lightning offers`)                     |

BOLT-12 invoices commit to a `payer_note` field — the
sender-side message — natively. Our FEAT-196 send.py uses
LUD-12 over LUD-16 for the same purpose because Lightning
Address handlers are universal; BOLT-12 offers would be a
fallback when the target presents one.

## LSPS — the LSP plugin family

LSPS (Lightning Service Provider Specifications) are a
BLIP series for "buy inbound capacity from a service".
clightning loads the `lsps-client` plugin to participate
as a client; FEAT-175 calls it via:

    lightning-cli lsps1-create-order <endpoint> <sat>

LSPs are how a fresh node with zero inbound capacity
becomes able to *receive*.

## Tor

`lightning tor on` (FEAT-189) edits the daemon's `config`
to add:

    proxy=127.0.0.1:9050
    addr=statictor:127.0.0.1:9051
    always-use-proxy=true

then restarts. clightning auto-creates a v3 hidden service
on first start and advertises it. The static-tor mode
means the onion address is derived from `hsm_secret` and
stays stable across restarts.

## Reading further

- The BOLTs themselves: this directory.
- The clightning docs: <https://docs.corelightning.org/>
- The `lightning-cli` RPC reference:
  `man 7 lightning-rpc` after installing core-lightning.
