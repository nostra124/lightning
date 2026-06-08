#!/bin/bash
# SIT container entrypoint (FEAT-182): bring up the full regtest stack —
# bitcoind + lightningd (both as the `alice` operator so lightningd's bcli
# plugin, which shells `bitcoin-cli` with alice's ~/.bitcoin, reaches the
# same node) + apache for the CGI account API — then idle.
#
# Runs as the `bitcoin` user (image USER); uses passwordless sudo to drop
# into alice and to start apache. Regtest only; never for production.
set -e

sudo -u alice -i bash -s <<'ALICE'
set -e
export LIGHTNING_NETWORK=regtest  # match the bitcoind backend (default is mainnet)
export LIGHTNING_NO_BOOTSTRAP=1   # no mainnet peer bootstrap in regtest

mkdir -p ~/.bitcoin
cat > ~/.bitcoin/bitcoin.conf <<EOF
regtest=1
server=1
txindex=1
rpcuser=test
rpcpassword=test
fallbackfee=0.0001
EOF

bitcoind -regtest -daemon
for _ in $(seq 1 30); do
	bitcoin-cli -regtest getblockchaininfo >/dev/null 2>&1 && break
	sleep 1
done
bitcoin-cli -regtest createwallet test 2>/dev/null \
	|| bitcoin-cli -regtest loadwallet test 2>/dev/null || true
# Mature some coins so the node is actually usable.
bitcoin-cli -regtest generatetoaddress 101 "$(bitcoin-cli -regtest getnewaddress)" >/dev/null

lightning daemon start
lightning version
echo "alice: lightningd up — $(lightning daemon status 2>/dev/null | head -1)"
ALICE

sudo apache2ctl start
echo "SIT stack up: bitcoind + lightningd (alice) + apache (CGI)"
exec tail -F /dev/null
