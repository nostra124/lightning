#!/usr/bin/env bats
# SIT 03 — BOLT-11 mint + pay round-trip (FEAT-173).

load ../helpers

setup()    { sit_setup_alice_bob; }
teardown() { sit_teardown; }

@test "alice pays a BOLT-11 invoice minted by bob" {
	sit_open_channel
	# Bob mints. Use the explicit RPC because `lightning invoice`
	# routes via alice's environment.
	local bolt11
	bolt11=$(lightning-cli --lightning-dir="$BOB_DIR" --network="$LIGHTNING_NETWORK" \
	         invoice 5000000 sit-03 "beer" | jq -r .bolt11)
	[ -n "$bolt11" ]

	run lightning pay "$bolt11"
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}
