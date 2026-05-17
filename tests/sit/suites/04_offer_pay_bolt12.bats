#!/usr/bin/env bats
# SIT 04 — BOLT-12 offer + fetchinvoice + pay (FEAT-173).

load ../helpers

setup()    { sit_setup_alice_bob; }
teardown() { sit_teardown; }

@test "alice pays a BOLT-12 offer from bob" {
	sit_open_channel
	local offer
	offer=$(lightning-cli --lightning-dir="$BOB_DIR" --network="$LIGHTNING_NETWORK" \
	        offer 1000msat "tip jar" | jq -r .bolt12)
	[ -n "$offer" ]

	run lightning offer-pay "$offer"
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}
