#!/usr/bin/env bats
# SIT 02 — channel open + cooperative close (FEAT-172).

load ../helpers

setup()    { sit_setup_alice_bob; }
teardown() { sit_teardown; }

@test "channel open + list shows the channel funded" {
	sit_open_channel
	run lightning channel list
	[ "$status" -eq 0 ]
	[[ "$output" == *"CHANNELD_NORMAL"* ]]
}

@test "channel close + pending shows it closing" {
	sit_open_channel
	local cid; cid=$(lightning channels | awk 'NR==2{print $1}')
	run lightning channel close "$cid"
	[ "$status" -eq 0 ]
	sit_mine 1
	run lightning channel pending
	[ "$status" -eq 0 ]
	[[ "$output" == *"CLOSINGD"* || "$output" == *"ONCHAIN"* ]]
}
