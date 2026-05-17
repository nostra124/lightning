# Shared SIT helpers (FEAT-182).
#
# Sourced from every tests/sit/suites/*.bats file. Provides:
#   - sit_setup_alice_bob: spin up two lightningd instances
#     on the same regtest bitcoind, fund alice, connect them.
#   - sit_teardown: stop everything; remove temp dirs.
#   - sit_mine N: mine N blocks; returns once they're seen.

set -euo pipefail

: "${LIGHTNING_DIR:=/home/alice/.lightning}"
: "${LIGHTNING_NETWORK:=regtest}"

BTCCLI() {
	bitcoin-cli -regtest -rpcuser=test -rpcpassword=test "$@"
}

cli_alice() { lightning-cli --lightning-dir="$LIGHTNING_DIR" --network="$LIGHTNING_NETWORK" "$@"; }

sit_mine() {
	local n="${1:-1}"
	local addr
	addr=$(BTCCLI getnewaddress)
	BTCCLI generatetoaddress "$n" "$addr" >/dev/null
}

# A second lightningd for the peer side of every test.
BOB_DIR=""
BOB_PORT=9836

sit_setup_alice_bob() {
	# alice is the operator's lightningd (already running via
	# the container CMD); bob is a fresh second instance.
	BOB_DIR=$(mktemp -d /tmp/bob.XXXXXX)
	lightningd --lightning-dir="$BOB_DIR" --network="$LIGHTNING_NETWORK" \
	           --bitcoin-rpcuser=test --bitcoin-rpcpassword=test \
	           --addr="127.0.0.1:$BOB_PORT" --daemon
	# Wait for both nodes to reach getinfo.
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		cli_alice getinfo >/dev/null 2>&1 \
			&& lightning-cli --lightning-dir="$BOB_DIR" --network="$LIGHTNING_NETWORK" getinfo >/dev/null 2>&1 \
			&& break
		sleep 1
	done

	# Fund alice on-chain.
	local alice_addr
	alice_addr=$(cli_alice newaddr | jq -r '.bech32 // .p2tr // .p2wkh')
	BTCCLI sendtoaddress "$alice_addr" 1 >/dev/null
	sit_mine 6
}

sit_bob_id() {
	lightning-cli --lightning-dir="$BOB_DIR" --network="$LIGHTNING_NETWORK" getinfo | jq -r .id
}

sit_open_channel() {
	# Open a 100k sat channel alice -> bob.
	local bob_id; bob_id=$(sit_bob_id)
	lightning channel open "${bob_id}@127.0.0.1:${BOB_PORT}" 100000 >/dev/null
	sit_mine 6
	# Wait for the channel to be ACTIVE.
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		cli_alice listpeerchannels | jq -e '.channels[] | select(.state == "CHANNELD_NORMAL")' >/dev/null 2>&1 && return 0
		sit_mine 1
		sleep 1
	done
	return 1
}

sit_teardown() {
	if [ -n "$BOB_DIR" ] && [ -d "$BOB_DIR" ]; then
		lightning-cli --lightning-dir="$BOB_DIR" --network="$LIGHTNING_NETWORK" stop 2>/dev/null || true
		rm -rf "$BOB_DIR"
		BOB_DIR=""
	fi
}
