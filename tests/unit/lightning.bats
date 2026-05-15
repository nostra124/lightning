#!/usr/bin/env bats
#
# Unit tests for bin/lightning — the educational Lightning Network
# frontend on clightning (FEAT-170..195). bin/lightning is a stub
# today; the real verb surface (clightning wiring, BOLT 1..12,
# LNURL, LSPS1) lands per FEAT-170..195.

setup() {
	BATS_TMPDIR=${BATS_TMPDIR:-$(mktemp -d)}
	HOME="$(mktemp -d "$BATS_TMPDIR/home.XXXXXX")"
	unset XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_SHARE_HOME
	unset XDG_SOURCE_HOME XDG_BACKUP_HOME XDG_RUNTIME_DIR
	export HOME
	export SELF_QUIET=1
	export LIGHTNING_BIN="$BATS_TEST_DIRNAME/../../bin/lightning"
}

teardown() {
	rm -rf "$HOME"
}

# ---------------------------------------------------------------------------
# Smoke + semver contract (FEAT-005)
# ---------------------------------------------------------------------------

@test "lightning binary exists and is executable" {
	[ -x "$LIGHTNING_BIN" ]
}

@test "lightning version returns 0.1.0" {
	run "$LIGHTNING_BIN" version
	[ "$status" -eq 0 ]
	[ "$output" = "0.1.0" ]
}

@test "lightning help prints usage" {
	run "$LIGHTNING_BIN" help
	[ -n "$output" ]
}

@test "lightning with no args prints help" {
	run "$LIGHTNING_BIN"
	[ -n "$output" ]
}

@test "lightning unknown subcommand exits non-zero (BUG-005 regression)" {
	run "$LIGHTNING_BIN" definitely-not-a-real-subcommand
	[ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Help surface — every spec hook documented today should be discoverable
# ---------------------------------------------------------------------------

@test "help mentions the four design principles" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"educational"* ]]
	[[ "$output" == *"functional"* ]]
	[[ "$output" == *"decentralized"* ]]
	[[ "$output" == *"simple"* ]]
}

@test "help mentions BOLT specs" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"BOLT"* ]]
}

@test "help mentions clightning (Core Lightning)" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"clightning"* || "$output" == *"Core Lightning"* ]]
}

@test "help mentions LNURL / Lightning Address vendored standards" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"LNURL"* || "$output" == *"Lightning Address"* ]]
}
