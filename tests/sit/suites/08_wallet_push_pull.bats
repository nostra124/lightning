#!/usr/bin/env bats
# SIT 08 — wallet push/pull round-trip preserves state.sql.

BARE=""
CLONE=""

setup() {
	lightning wallet new push-test >/dev/null
	lightning wallet use push-test >/dev/null
	lightning account create rent >/dev/null
	lightning ledger add in 100000 --account rent --message "ping"

	BARE=$(mktemp -d /tmp/bare.XXXXXX)
	git init --bare --quiet "$BARE"
	(cd "$HOME/.lightning/wallet/push-test" && git remote add origin "$BARE")
}

teardown() {
	[ -n "$BARE"  ] && rm -rf "$BARE"
	[ -n "$CLONE" ] && rm -rf "$CLONE"
}

@test "push -> pull on a fresh machine preserves the ledger byte-for-byte" {
	lightning backup --remote origin

	# Clone-side: rebuild state.db from state.sql, dump, compare.
	CLONE=$(mktemp -d /tmp/clone.XXXXXX)
	git clone --quiet "$BARE" "$CLONE"
	sqlite3 "$CLONE/state.db" < "$CLONE/state.sql"

	local local_dump remote_dump
	local_dump=$(sqlite3 "$HOME/.lightning/wallet/push-test/state.db" \
	             "SELECT * FROM ledger ORDER BY id;")
	remote_dump=$(sqlite3 "$CLONE/state.db" \
	             "SELECT * FROM ledger ORDER BY id;")
	[ "$local_dump" = "$remote_dump" ]
}
