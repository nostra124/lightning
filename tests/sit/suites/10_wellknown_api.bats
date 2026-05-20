#!/usr/bin/env bats
# SIT 10 — .well-known/lightning/<user>/{send,recv,balance}
# end-to-end (FEAT-196).

setup() {
	lightning wallet new api-test >/dev/null
	lightning wallet use api-test >/dev/null
	lightning account create alice --limit 1000000 --overdraft deny >/dev/null
	lightning address create alice@example.com --account alice >/dev/null
	echo "127.0.0.1 example.com" | sudo tee -a /etc/hosts >/dev/null

	API_KEY=$(lightning account apikey create alice --scope write | tail -1)
	export API_KEY

	# Pre-credit alice so /send has something to spend.
	lightning ledger add in 500000 --account alice
}

@test "recv mints a BOLT-11 with the message in the description" {
	run curl -fsSL \
		-H "X-API-Key: $API_KEY" \
		-d '{"sat":1000,"message":"api-recv-test"}' \
		http://example.com/.well-known/lightning/alice/recv
	[ "$status" -eq 0 ]
	[[ "$output" == *"bolt11"* ]]
	[[ "$output" == *"payment_hash"* ]]
}

@test "balance returns the current SQLite-computed value" {
	run curl -fsSL \
		-H "X-API-Key: $API_KEY" \
		http://example.com/.well-known/lightning/alice/balance
	[ "$status" -eq 0 ]
	[[ "$output" == *'"balance_sat":500'* ]]
	[[ "$output" == *'"overdraft":"deny"'* ]]
}

@test "wrong API key returns 401 with no body" {
	run curl -sS -o /dev/null -w '%{http_code}' \
		-H "X-API-Key: not-a-real-key" \
		http://example.com/.well-known/lightning/alice/balance
	[ "$status" -eq 0 ]
	[ "$output" = "401" ]
}

@test "overdraft=deny + insufficient balance returns 402" {
	# alice has 500 sat; ask to send 1_000_000 sat.
	run curl -sS -o /dev/null -w '%{http_code}' \
		-H "X-API-Key: $API_KEY" \
		-d '{"to":"bob@example.com","sat":1000000,"message":"too much"}' \
		http://example.com/.well-known/lightning/alice/send
	[ "$status" -eq 0 ]
	[ "$output" = "402" ]
}
