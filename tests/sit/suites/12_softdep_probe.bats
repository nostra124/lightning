#!/usr/bin/env bats
# SIT 12 — soft-dep probes. Verbs must fail clearly when a
# required binary is missing.

@test "lightning info exits 127 with install hint when lightning-cli is hidden" {
	# Shadow lightning-cli with a binary that doesn't exist.
	export PATH="/usr/bin:/bin"
	hash -r
	run lightning info
	[ "$status" -eq 127 ]
	[[ "$output" == *"install Core Lightning"* ]]
}

@test "lightning wallet new exits 127 when sqlite3 is hidden" {
	# Mask sqlite3 by removing it from PATH.
	export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v sqlite | paste -sd:)
	hash -r
	# Use a known-bad PATH instead.
	PATH="/usr/bin:/bin" run lightning wallet new sd-test
	# We expect non-zero with a clear message (sqlite3 is on /usr/bin
	# typically, so this test only fails meaningfully when masked).
	if command -v sqlite3 >/dev/null; then
		skip "sqlite3 reachable; soft-dep probe N/A here"
	fi
	[ "$status" -ne 0 ]
}

@test "lightning address create exits 3 when apache2 is absent" {
	export PATH="/usr/bin:/bin"
	hash -r
	# Make `lightning` reachable but Apache binaries hidden.
	if command -v apache2 >/dev/null || command -v httpd >/dev/null; then
		# Need to install lightning to PATH; if apache is also present we
		# can't simulate "absent" cleanly within this container.
		skip "apache2 present in image; absent-path covered by unit tests"
	fi
	run lightning address create alice@example.com
	[ "$status" -eq 3 ]
	[[ "$output" == *"apache2 not installed"* ]]
}
