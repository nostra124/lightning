#!/usr/bin/env bats
# SIT 11 — the FEAT-181 walkthrough, in lockstep.
#
# Each section of share/doc/lightning/walkthrough/README.md
# corresponds to one @test here. Keep them in sync: if you
# change a command in the walkthrough, change the matching
# test, and vice versa.

load ../helpers

setup()    { sit_setup_alice_bob; }
teardown() { sit_teardown; }

# §1 Setup — covered by the container CMD. Smoke: getinfo works.
@test "§1 setup: alice's node is reachable" {
	run lightning info
	[ "$status" -eq 0 ]
}

# §2 Create a wallet.
@test "§2 wallet new + account list" {
	lightning wallet new walkthrough >/dev/null
	lightning wallet use walkthrough >/dev/null
	lightning account create personal --description "everyday" >/dev/null
	run lightning account list
	[ "$status" -eq 0 ]
	[[ "$output" == *"personal"* ]]
}

# §3 Open a channel.
@test "§3 channel open" { sit_open_channel; }

# §4 BOLT-11 pay.
@test "§4 BOLT-11 pay" {
	sit_open_channel
	local bolt11
	bolt11=$(lightning-cli --lightning-dir="$BOB_DIR" --network="$LIGHTNING_NETWORK" \
	         invoice 5000000 walk-§4 "beer" | jq -r .bolt11)
	run lightning pay "$bolt11"
	[ "$status" -eq 0 ]
}

# §5 BOLT-12 offer-pay.
@test "§5 BOLT-12 offer-pay" {
	sit_open_channel
	local offer
	offer=$(lightning-cli --lightning-dir="$BOB_DIR" --network="$LIGHTNING_NETWORK" \
	        offer 1000msat walk-§5 | jq -r .bolt12)
	run lightning offer-pay "$offer"
	[ "$status" -eq 0 ]
}

# §7 Lightning Address create.
@test "§7 address create" {
	lightning wallet new walkthrough-§7 >/dev/null
	lightning account create alice >/dev/null
	run lightning address create alice@example.com --account alice
	[ "$status" -eq 0 ]
}
