#!/usr/bin/env bats
#
# thunderd skeleton — structural + carve-out checks (FEAT-300/301/302/306).
# These need no Rust toolchain so they run in the standard bats CI job;
# the cargo build / clippy / test run in the dedicated `thunderd` CI job.

ROOT="$BATS_TEST_DIRNAME/../.."

@test "FEAT-300: thunderd Cargo workspace + both binaries exist" {
	[ -f "$ROOT/thunder/Cargo.toml" ]
	grep -q 'members' "$ROOT/thunder/Cargo.toml"
	[ -f "$ROOT/thunder/crates/thunderd/Cargo.toml" ]
	[ -f "$ROOT/thunder/crates/thunderd/src/main.rs" ]
	[ -f "$ROOT/thunder/crates/thunderd-cli/Cargo.toml" ]
	[ -f "$ROOT/thunder/crates/thunderd-cli/src/main.rs" ]
}

@test "FEAT-303: HTTP server module + CORS scaffold present" {
	[ -f "$ROOT/thunder/crates/thunderd/src/http/mod.rs" ]
	grep -q 'CorsLayer' "$ROOT/thunder/crates/thunderd/src/http/mod.rs"
	grep -q '/health' "$ROOT/thunder/crates/thunderd/src/http/mod.rs"
}

@test "FEAT-306: initial SQLite migration present" {
	[ -f "$ROOT/thunder/crates/thunderd/migrations/0001_init.sql" ]
	grep -q 'CREATE TABLE' "$ROOT/thunder/crates/thunderd/migrations/0001_init.sql"
}

@test "FEAT-301: systemd unit template present" {
	[ -f "$ROOT/thunder/dist/thunderd.service" ]
}

@test "FEAT-302: carve-out guard passes on the workspace" {
	run "$ROOT/thunder/scripts/carve-out-guard.sh"
	[ "$status" -eq 0 ]
}

@test "FEAT-302: carve-out guard catches introduced coupling" {
	probe="$ROOT/thunder/crates/thunderd/src/_guardprobe.rs"
	# shellcheck disable=SC2064
	printf 'fn p() { let _ = "lightning-cli getinfo"; }\n' > "$probe"
	run "$ROOT/thunder/scripts/carve-out-guard.sh"
	rm -f "$probe"
	[ "$status" -ne 0 ]
}

@test "FEAT-302: guard does NOT trip on the allowed lightning-rpc socket" {
	# lightning-rpc / lightningd are the standard CLN surface thunderd
	# is allowed to use; only the bash package is forbidden.
	grep -q 'lightning-rpc' "$ROOT/thunder/crates/thunderd/src/clnrpc.rs"
	run "$ROOT/thunder/scripts/carve-out-guard.sh"
	[ "$status" -eq 0 ]
}
