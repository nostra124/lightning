#!/usr/bin/env bats
# SIT 14 — fee + forward (FEAT-188).

load ../helpers

setup()    { sit_setup_alice_bob; }
teardown() { sit_teardown; }

@test "fee get on a fresh node returns at least the header" {
	sit_open_channel
	run lightning fee get
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "channel_id	base_msat	ppm" ]]
}

@test "fee set + get round-trips a new base/ppm" {
	sit_open_channel
	local cid
	cid=$(lightning channels | awk 'NR==2{print $1}')
	[ -n "$cid" ]
	run lightning fee set "$cid" 1234 7
	[ "$status" -eq 0 ]

	# Wait for the gossip + listpeerchannels to reflect the new fee.
	for _ in 1 2 3 4 5; do
		lightning fee get "$cid" | grep -qE '\t1234\t7$' && return 0
		sleep 1
	done
	return 1
}

@test "forward stats returns success_rate as 0 when no forwards happened" {
	run lightning forward stats
	[ "$status" -eq 0 ]
	[[ "$output" == *"success_rate"* ]]
	[[ "$output" == *"forwarded_msat"* ]]
}

@test "forward list returns just the TSV header on a fresh node" {
	run lightning forward list
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "received_time	in_channel	out_channel	in_msat	out_msat	fee_msat	status" ]]
}
