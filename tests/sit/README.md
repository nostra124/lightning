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
