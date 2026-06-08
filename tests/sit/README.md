# SIT — system integration tests for `lightning`

> Per FEAT-182. End-to-end coverage against a real clightning
> + bitcoind + Apache stack running in a podman container.
> The unit suite at `tests/unit/lightning.bats` covers the
> shell verbs in isolation; SIT covers the seams between
> them.

## Layout

    tests/sit/
    ├── podman/
    │   ├── Dockerfile.regtest        # bitcoind regtest base
    │   └── Dockerfile.clightning     # adds lightningd + apache + python3
    │                                  # + the lightning package itself
    ├── helpers.bash                  # shared spin-up: bring up two
    │                                  # lightningd instances, fund them,
    │                                  # connect them, mine some blocks.
    └── suites/
        ├── 01_daemon_lifecycle.bats
        ├── 02_channel_open_close.bats
        ├── 03_invoice_pay_bolt11.bats
        ├── 04_offer_pay_bolt12.bats
        ├── 05_lnurl_flow.bats
        ├── 06_address_create_pay.bats
        ├── 07_wallet_account_ledger.bats
        ├── 08_wallet_push_pull.bats
        ├── 09_inbound_liquidity_lsps1.bats
        ├── 10_wellknown_api.bats
        ├── 11_walkthrough.bats           # locked to FEAT-181
        └── 12_softdep_probe.bats         # missing lightning-cli /
                                           # python3 / apache2 fail clearly

## Running

    # From the repo root:
    make check-sit

The make target soft-skips when `podman` isn't installed,
so CI without container support reports a clean
"skipping" rather than a failure.

Internally it does:

    podman build -t lightning-regtest    -f tests/sit/podman/Dockerfile.regtest    tests/sit
    podman build -t lightning-clightning -f tests/sit/podman/Dockerfile.clightning .
    podman run --rm \
        -v $PWD/tests/sit/suites:/suites:ro \
        lightning-clightning \
        /bin/bash -c "bats /suites/*.bats"

The clightning Dockerfile copies the whole repo into the
image, so `lightning` inside the container is whatever
your working tree is — no need to install before running.

> **Status of the legacy `make check-sit` images (rebuilt 2026-06-08):**
> - `Dockerfile.regtest` — **fixed + builds**: Debian dropped
>   the `bitcoind` apt package, so it installs the official
>   multi-arch Bitcoin Core release binaries.
> - `Dockerfile.clightning` — **builds, installs, and the
>   stack comes up**: `lightningd` (also absent from apt) is
>   copied from the upstream `polarlightning/clightning`
>   image; the bogus `libapache2-mod-cgi` package was dropped
>   (mod_cgi ships in `apache2` on bookworm) and `sudo` added.
>   The Makefile `stow`/double-prefix packaging bug it used to
>   hit is fixed (`make install` installs directly into
>   `$PREFIX`), so the `lightning` CLI installs world-executably.
>   A `clightning-entrypoint.sh` now brings the whole regtest
>   stack up under one user — **bitcoind + lightningd (regtest,
>   synced) + apache** — verified live (`getinfo` returns a
>   regtest node). Run it: `podman run --rm lightning-clightning`.
> - **CGI account API — mostly wired, one residual:** the
>   container threads `LIGHTNING_NETWORK=regtest` to the
>   sudo-bridged verbs (apache `SetEnv` + sudoers `env_keep`),
>   and two **real apache-conf bugs were fixed in the source
>   `lnurlp.conf`**: `CGIPassAuth On` (Apache 2.4.13+ strips
>   `Authorization`, so every bearer endpoint 401'd) and
>   `AcceptPathInfo On`. Verified working: `GET /v1/health`
>   returns `{"ok":true,"daemon":true,…}` (full chain
>   apache→CGI→sudo→verb→lightningd), and bare `/v1/accounts`
>   now returns a proper `401` instead of an empty body.
>   **Residual:** sub-path routes (`/v1/accounts/<id>/balance`)
>   still 404 — a further Apache PATH_INFO nuance, undiagnosed.
> - **Remaining:** finish the sub-path routing, then validate
>   the 12 SIT suites (their `helpers.bash` needs
>   `LIGHTNING_NETWORK=regtest`). These are prerequisites for
>   the `2.0.0` shadow-run parity diff (FEAT-326).
>
> The bash-verb **unit** suite is the primary gate today;
> the **thunderd live-node** harness below is fully working.

## thunderd live-node integration (`make check-thunderd-sit`)

`tests/sit/thunderd-live.sh` exercises the **Rust `thunderd`
daemon** against a *real* regtest Core Lightning node — the
integration the unit suite can only mock. It stands up, via
podman:

    bitcoind (regtest)
       ├── cln   (Core Lightning)   ← thunderd drives THIS over
       │                              its lightning-rpc socket
       └── cln2  (counterparty for a real channel payment)

using the `polarlightning/bitcoind` + `polarlightning/clightning`
images and `tests/sit/podman/Dockerfile.thunderd` (a multi-stage
Rust build that runs as uid 1000 so it can open the `0600`
`lightning-rpc` socket shared in over a volume).

It asserts, end-to-end and green from a clean slate:
health/getinfo against the live node, BOLT-11 receive
(decoded + listed on-node), BOLT-12 offer, the bearer-auth
`401` contract, and a `send` that pays a counterparty invoice
over an open channel with the custodial ledger debiting
correctly. This is the **shadow-run prerequisite** for the
`2.0.0` cutover (FEAT-326). Soft-skips when podman is absent;
pass `--keep` to leave the stack running for poking at.

## What's NOT covered here

- Real LSP / Loop / Boltz endpoints. The
  `09_inbound_liquidity_lsps1.bats` suite uses a stub
  LSPS1 server inside the container; it proves the wire
  shape, not the third-party behaviour.
- Real DNS publishing for BIP-353. The suite uses
  `/etc/hosts` to point `example.com` at `127.0.0.1`.
- TLS. The Apache vhost in the container serves over
  plaintext HTTP because `127.0.0.1` doesn't need it; do
  not deploy this way in production.

## Determinism

Each suite uses fresh state: a clean wallet repo, fresh
bitcoind blocks mined into a known address, fresh
clightning data dirs. Helpers tear down between tests so
runs are independent.

## When a suite fails

The container logs are written to
`tests/sit/out/<suite>.log`. Reproduce locally:

    podman run -it --rm \
        -v $PWD/tests/sit/suites:/suites:ro \
        lightning-clightning \
        bats /suites/<suite>.bats
