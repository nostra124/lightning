#!/usr/bin/env bats
# SIT 06 — Lightning Address create + pay (FEAT-176).

load ../helpers

setup() {
	lightning wallet new alice 2>/dev/null || true
	lightning account create alice >/dev/null || true
}

teardown() {
	lightning address remove alice@example.com 2>/dev/null || true
}

@test "address create registers a row in the users table" {
	run lightning address create alice@example.com --account alice
	[ "$status" -eq 0 ]
	[[ "$output" == *"registered"* ]]

	run lightning address list
	[ "$status" -eq 0 ]
	[[ "$output" == *"alice"* ]]
}

@test "the .well-known/lnurlp/alice endpoint serves LUD-06 metadata" {
	lightning address create alice@example.com --account alice >/dev/null
	# Apache must be running and the snippet loaded.
	echo "127.0.0.1 example.com" | sudo tee -a /etc/hosts >/dev/null
	run curl -fsSL http://example.com/.well-known/lnurlp/alice
	[ "$status" -eq 0 ]
	[[ "$output" == *"payRequest"* ]]
	[[ "$output" == *"commentAllowed"* ]]
}
