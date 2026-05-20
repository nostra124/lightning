#!/usr/bin/env bats
# SIT 13 — watchtower client (FEAT-186).
#
# Requires the altruistwatchtower plugin in the lightningd
# image; soft-skips when absent.

setup() {
	if ! lightning-cli --network=regtest help 2>/dev/null \
	     | grep -q -E 'addtower|altruistwatchtower'; then
		skip "altruistwatchtower plugin not loaded"
	fi
}

@test "tower client-list returns the TSV header even when empty" {
	run lightning tower client-list
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "pubkey	host	port	sessions" ]]
}

@test "tower client-stats returns JSON with sessions field" {
	run lightning tower client-stats
	[ "$status" -eq 0 ]
	[[ "$output" == *"sessions"* ]]
	[[ "$output" == *"towers"* ]]
}
