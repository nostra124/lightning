#!/usr/bin/env bats
# SIT 01 — daemon lifecycle (FEAT-183 against real lightningd).

load ../helpers

@test "daemon status reports healthy when the operator's lightningd is up" {
	run lightning daemon status
	[ "$status" -eq 0 ]
	[[ "$output" == *"healthy"* ]]
}

@test "daemon stop then start round-trips" {
	lightning daemon stop
	# Wait for shutdown.
	for _ in 1 2 3 4 5; do
		lightning daemon status >/dev/null 2>&1 || break
		sleep 1
	done
	run lightning daemon status
	[ "$status" -ne 0 ]

	lightning daemon start
	for _ in 1 2 3 4 5; do
		lightning daemon status >/dev/null 2>&1 && break
		sleep 1
	done
	run lightning daemon status
	[ "$status" -eq 0 ]
}
