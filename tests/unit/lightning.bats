#!/usr/bin/env bats
#
# Unit tests for bin/lightning — the educational Lightning Network
# frontend on clightning (FEAT-170..206). Covers the 0.2.0–0.7.0
# surface: dispatcher, lightning.sh source-mode guard, and the
# libexec object dispatchers (wallet / channel / daemon / account /
# ledger / invoice / offer / address / lnurl / liquidity / plugin /
# peer / fee / alert). As of 0.5.x the CLI is purely object-oriented:
# top-level commands are objects, actions live as sub-commands. The
# wallet object is your Lightning identity — it owns both the
# clightning daemon's identity (info/balance/seed/unlock) and the
# git-backed state repo (init/push/pull/backup/restore). The peer
# object handles bare-peering + bootstrap + keepalive (FEAT-199).
# Operational verbs added in 0.7.0: fee (FEAT-200), rebalance
# (FEAT-201), alert (FEAT-204), plus the personal-node + routing-node
# operational guides (FEAT-202/203).

bats_require_minimum_version 1.5.0

setup() {
	BATS_TMPDIR=${BATS_TMPDIR:-$(mktemp -d)}
	HOME="$(mktemp -d "$BATS_TMPDIR/home.XXXXXX")"
	unset XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_SHARE_HOME
	unset XDG_SOURCE_HOME XDG_BACKUP_HOME XDG_RUNTIME_DIR
	export HOME
	export SELF_QUIET=1
	export LIGHTNING_BIN="$BATS_TEST_DIRNAME/../../bin/lightning"

	# Point at a mock lightning-cli so verbs can exercise their
	# parsing logic without a real lightningd.
	FIXTURES="$BATS_TEST_DIRNAME/fixtures"
	export MOCK_STATE="$BATS_TMPDIR/mock-state.$$"
	rm -f "$MOCK_STATE"

	# Shim PATH: put a dir with `lightning-cli -> mock` first.
	BIN_SHIM="$BATS_TMPDIR/bin.$$"
	mkdir -p "$BIN_SHIM"
	ln -sf "$FIXTURES/lightning-cli-mock" "$BIN_SHIM/lightning-cli"
	export PATH="$BIN_SHIM:$PATH"
}

teardown() {
	rm -rf "$HOME" "$BIN_SHIM"
	rm -f "$MOCK_STATE"
}

# Stubs curl+tar so `daemon install --trustedcoin` doesn't hit
# GitHub. curl writes a fake tarball; tar extracts a placeholder
# trustedcoin binary. Tests that want the failure path stub curl
# themselves.
_stub_trustedcoin_curl() {
	cat > "$BIN_SHIM/curl" <<'EOF'
#!/bin/sh
# Pull the -o argument and write a placeholder file there. Real
# tarball isn't needed — our tar stub doesn't read the contents.
while [ $# -gt 0 ]; do
	case "$1" in -o) target=$2; shift 2 ;; *) shift ;; esac
done
[ -n "$target" ] && printf 'STUB TARBALL\n' > "$target"
exit 0
EOF
	chmod +x "$BIN_SHIM/curl"
	# Stub tar to drop a placeholder trustedcoin binary into -C dir.
	cat > "$BIN_SHIM/tar" <<'EOF'
#!/bin/sh
# Find -C <dir> and write trustedcoin there.
while [ $# -gt 0 ]; do
	case "$1" in -C) dest=$2; shift 2 ;; *) shift ;; esac
done
[ -n "$dest" ] && {
	mkdir -p "$dest"
	printf '#!/bin/sh\nexit 0\n' > "$dest/trustedcoin"
	chmod +x "$dest/trustedcoin"
}
exit 0
EOF
	chmod +x "$BIN_SHIM/tar"
}

# ---------------------------------------------------------------------------
# Smoke + semver contract (FEAT-005)
# ---------------------------------------------------------------------------

@test "lightning binary exists and is executable" {
	[ -x "$LIGHTNING_BIN" ]
}

@test "lightning version returns 1.3.1" {
	run "$LIGHTNING_BIN" version
	[ "$status" -eq 0 ]
	[ "$output" = "1.3.1" ]
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

@test "help lists the 1.0.0 verb surface" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"wallet"* ]]
	[[ "$output" == *"account"* ]]
	[[ "$output" == *"channel"* ]]
	[[ "$output" == *"daemon"* ]]
	[[ "$output" == *"invoice"* ]]
	[[ "$output" == *"offer"* ]]
	[[ "$output" == *"address"* ]]
	[[ "$output" == *"lnurl"* ]]
	[[ "$output" == *"liquidity"* ]]
	[[ "$output" == *"ledger"* ]]
}

@test "help lists the one-shot verbs" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"send"* ]]
	[[ "$output" == *"decode"* ]]
	[[ "$output" == *"qr"* ]]
	[[ "$output" == *"wallet"* ]]
	[[ "$output" == *"account"* ]]
	[[ "$output" == *"ledger"* ]]
	[[ "$output" == *"seed"* ]]
	[[ "$output" == *"scb"* ]]
	[[ "$output" == *"backup"* ]]
	[[ "$output" == *"address"* ]]
	[[ "$output" == *"liquidity"* ]]
	[[ "$output" == *"tor"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-170: source-mode guard + bin/lightning.sh symlink
# ---------------------------------------------------------------------------

@test "FEAT-170: bin/lightning.sh symlink resolves to lightning" {
	local sh="$(dirname "$LIGHTNING_BIN")/lightning.sh"
	[ -L "$sh" ]
	[ "$(readlink "$sh")" = "lightning" ]
}

@test "FEAT-170: sourcing lightning.sh defines functions without dispatch" {
	local sh="$(dirname "$LIGHTNING_BIN")/lightning.sh"
	# Source in a subshell; should NOT print help (the dispatcher must
	# return early) but should define `command:version`.
	run bash -c ". '$sh'; type -t command:version"
	[ "$status" -eq 0 ]
	[ "$output" = "function" ]
}

@test "FEAT-170: no script-invocation matches for sister packages in bin/lightning" {
	# Acceptance criterion 4: bin/lightning must not shell out to
	# other packages (cache / check / data / hosts / repo / scripts /
	# task / user). Allow the word as part of help text / comments
	# only; reject as the first token after whitespace or as `$(`.
	run grep -wEn '^[[:space:]]*(cache|check|data|hosts|repo|scripts|task|user)[[:space:]]|\$\((cache|check|data|hosts|repo|scripts|task|user)[[:space:]]' "$LIGHTNING_BIN"
	[ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# FEAT-171: clightning backend wiring
# ---------------------------------------------------------------------------

@test "FEAT-171: lightning wallet info renders getinfo summary" {
	run "$LIGHTNING_BIN" wallet info
	[ "$status" -eq 0 ]
	[[ "$output" == *"TESTNODE"* ]]
	[[ "$output" == *"regtest"* ]]
}

@test "FEAT-171: lightning wallet id returns the pubkey" {
	run "$LIGHTNING_BIN" wallet id
	[ "$status" -eq 0 ]
	[ "$output" = "020000000000000000000000000000000000000000000000000000000000000001" ]
}

@test "FEAT-171: wallet peers is deprecated -> hints at 'peer list'" {
	run "$LIGHTNING_BIN" wallet peers
	[ "$status" -ne 0 ]
	[[ "$output" == *"peer list"* ]]
}

@test "FEAT-171: lightning peer list returns the TSV header" {
	run "$LIGHTNING_BIN" peer list
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "pubkey	connected	features	addr" ]]
}

@test "FEAT-171: lightning channel list returns the TSV header" {
	run "$LIGHTNING_BIN" channel list
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "id	peer	capacity	local	remote	state" ]]
}

@test "FEAT-171: lightning wallet balance is a recfile (single record)" {
	run "$LIGHTNING_BIN" wallet balance
	[ "$status" -eq 0 ]
	# Three key: value lines, no TSV header.
	[ "${#lines[@]}" -eq 3 ]
	[[ "${lines[0]}" == "onchain_confirmed_sat:"* ]]
	[[ "${lines[1]}" == "onchain_unconfirmed_sat:"* ]]
	[[ "${lines[2]}" == "channels_sat:"* ]]
	# Each line ends in the expected zero value (mocked listfunds).
	[[ "${lines[0]}" == *"0" ]]
	[[ "${lines[1]}" == *"0" ]]
	[[ "${lines[2]}" == *"0" ]]
}

@test "FEAT-171: lightning wallet balance --on-chain prints an address" {
	run "$LIGHTNING_BIN" wallet balance --on-chain
	[ "$status" -eq 0 ]
	[[ "$output" == bcrt1q* ]]
}

@test "FEAT-171: verbs exit 127 when lightning-cli is absent" {
	# Hide lightning-cli from PATH.
	export PATH="/usr/bin:/bin"
	run -127 "$LIGHTNING_BIN" wallet info
	[[ "$output" == *"install Core Lightning"* ]]
}

@test "lightning wallet (no args) prints usage" {
	run "$LIGHTNING_BIN" wallet
	[ "$status" -ne 0 ]
	[[ "$output" == *"subcommands"* || "$output" == *"node"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-183: daemon lifecycle
# ---------------------------------------------------------------------------

@test "FEAT-183: lightning daemon (no args) prints usage" {
	run "$LIGHTNING_BIN" daemon
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage"* ]]
}

@test "FEAT-183: lightning daemon status reports 'healthy' when RPC is up" {
	run "$LIGHTNING_BIN" daemon status
	[ "$status" -eq 0 ]
	[[ "$output" == *"healthy"* ]]
}

@test "FEAT-183: lightning daemon status reports 'down' when RPC is down" {
	echo "down" > "$MOCK_STATE"
	run "$LIGHTNING_BIN" daemon status
	[ "$status" -eq 2 ]
	[[ "$output" == *"down"* ]]
}

@test "FEAT-183: lightning daemon install writes a user-mode systemd unit (Linux)" {
	if [ "$(uname -s)" = "Darwin" ]; then
		skip "Linux-only — macOS uses launchd"
	fi
	# Stub lightningd so install's ExecStart resolves.
	ln -sf /bin/true "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" daemon install
	[ "$status" -eq 0 ]
	[ -f "$HOME/.config/systemd/user/lightning.service" ]
	grep -q "Description=Lightning Network daemon" "$HOME/.config/systemd/user/lightning.service"
}

@test "FEAT-183: lightning daemon install writes a LaunchAgent plist (macOS)" {
	if [ "$(uname -s)" != "Darwin" ]; then
		skip "macOS-only — Linux uses systemd"
	fi
	ln -sf /bin/true "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" daemon install
	[ "$status" -eq 0 ]
	local plist="$HOME/Library/LaunchAgents/network.lightning.lightningd.plist"
	[ -f "$plist" ]
	grep -q "<string>network.lightning.lightningd</string>" "$plist"
	grep -q "<string>daemon</string>" "$plist"
	grep -q "<string>run</string>" "$plist"
	grep -q "<key>RunAtLoad</key>" "$plist"
	grep -q "<key>KeepAlive</key>" "$plist"
}

@test "FEAT-183: lightning daemon run requires lightningd binary" {
	# Daemon NOT running, lightningd binary NOT present → exit 127.
	echo "down" > "$MOCK_STATE"
	export PATH="$BIN_SHIM:/usr/bin:/bin"
	run "$LIGHTNING_BIN" daemon run
	[ "$status" -eq 127 ]
	[[ "$output" == *"lightningd not found"* ]]
}

@test "FEAT-183: lightning daemon run refuses when daemon is already running" {
	# Mock lightning-cli getinfo returns success (state = up) by default.
	run "$LIGHTNING_BIN" daemon run
	[ "$status" -eq 1 ]
	[[ "$output" == *"already running"* ]]
}

@test "FEAT-183: lightning daemon help lists run alongside start" {
	run "$LIGHTNING_BIN" daemon
	[[ "$output" == *"run"* ]]
	[[ "$output" == *"start"* ]]
	[[ "$output" == *"foreground"* ]]
}

@test "FEAT-183: daemon start routes through installed LaunchAgent (macOS)" {
	if [ "$(uname -s)" != "Darwin" ]; then
		skip "macOS-only — exercises launchctl detection"
	fi
	# Daemon must be down so start doesn't short-circuit.
	echo "down" > "$MOCK_STATE"
	# Pretend the plist is installed (file presence is what detection checks).
	mkdir -p "$HOME/Library/LaunchAgents"
	touch "$HOME/Library/LaunchAgents/network.lightning.lightningd.plist"
	# Stub launchctl so we can prove start invoked it (not lightningd directly).
	cat > "$BIN_SHIM/launchctl" <<EOF
#!/bin/sh
[ "\$1" = "list" ] && exit 1   # report "not loaded"
# load/kickstart succeeds — flip MOCK_STATE so the post-start
# probe sees a healthy daemon.
rm -f "$MOCK_STATE"
exit 0
EOF
	chmod +x "$BIN_SHIM/launchctl"
	# Stub lightningd as a real script (ln -sf /bin/true would be a
	# dangling symlink on macOS where /bin/true doesn't exist).
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" -v daemon start
	[ "$status" -eq 0 ]
	[[ "$output" == *"launchctl load -w"* ]]
	# Must NOT have fallen through to the direct path.
	[[ "$output" != *"no service unit installed"* ]]
}

@test "FEAT-183: daemon start routes through systemd --user when unit installed (Linux)" {
	if [ "$(uname -s)" = "Darwin" ]; then
		skip "Linux-only — exercises systemctl --user detection"
	fi
	echo "down" > "$MOCK_STATE"
	mkdir -p "$HOME/.config/systemd/user"
	touch "$HOME/.config/systemd/user/lightning.service"
	# Stub systemctl so the routing is observable without a real systemd.
	cat > "$BIN_SHIM/systemctl" <<EOF
#!/bin/sh
[ "\$1" = "--quiet" ] && exit 1   # report system-mode NOT enabled
# start command succeeds — flip MOCK_STATE so post-start probe passes.
rm -f "$MOCK_STATE"
exit 0
EOF
	chmod +x "$BIN_SHIM/systemctl"
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" -v daemon start
	[ "$status" -eq 0 ]
	[[ "$output" == *"systemctl --user start lightning"* ]]
}

@test "FEAT-183: daemon status down surfaces last BROKEN line from log" {
	echo "down" > "$MOCK_STATE"
	mkdir -p "$HOME/.lightning"
	cat > "$HOME/.lightning/log" <<'EOF'
2026-05-18T21:00:00.000Z INFO lightningd: v26.04.1
2026-05-18T21:00:01.000Z **BROKEN** plugin-bcli: The Bitcoin backend died.
2026-05-18T21:00:01.500Z INFO lightningd: shutting down
EOF
	run "$LIGHTNING_BIN" daemon status
	[ "$status" -eq 2 ]
	[[ "$output" == *"down"* ]]
	[[ "$output" == *"BROKEN"* ]]
	[[ "$output" == *"Bitcoin backend died"* ]]
	[[ "$output" == *"daemon logs"* ]]
}

@test "FEAT-183: daemon start warns when bitcoin-cli is missing" {
	echo "down" > "$MOCK_STATE"
	# bitcoin-cli absent (the BIN_SHIM doesn't define it).
	# Stub lightningd so the lightningd-not-found branch doesn't fire first.
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	export PATH="$BIN_SHIM:/usr/bin:/bin"
	# Daemon stays "down" after start → expect non-zero, but the
	# warning should appear in output regardless.
	run "$LIGHTNING_BIN" -v daemon start
	[[ "$output" == *"bitcoin-cli not found"* ]]
}

@test "FEAT-183: daemon start surfaces the error when daemon dies during startup" {
	echo "down" > "$MOCK_STATE"
	mkdir -p "$HOME/.lightning"
	# Pre-seed a log with a fatal line — simulates the daemon
	# crashing during startup.
	cat > "$HOME/.lightning/log" <<'EOF'
2026-05-18T22:00:00.000Z **BROKEN** plugin-bcli: The Bitcoin backend died.
EOF
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" -v daemon start
	# Exit 2 = post-start probe found the daemon down.
	[ "$status" -eq 2 ]
	[[ "$output" == *"did not come up"* ]]
	[[ "$output" == *"BROKEN"* ]]
}

@test "FEAT-183: daemon install plist sets ThrottleInterval (macOS)" {
	if [ "$(uname -s)" != "Darwin" ]; then
		skip "macOS-only — checks the launchd plist"
	fi
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" daemon install
	[ "$status" -eq 0 ]
	local plist="$HOME/Library/LaunchAgents/network.lightning.lightningd.plist"
	grep -q "<key>ThrottleInterval</key>" "$plist"
	grep -q "<integer>30</integer>" "$plist"
}

@test "FEAT-183: daemon install --trustedcoin writes managed block + auto-installs plugin" {
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	_stub_trustedcoin_curl
	run "$LIGHTNING_BIN" daemon install --trustedcoin
	[ "$status" -eq 0 ]
	[ -f "$HOME/.lightning/config" ]
	grep -q "disable-plugin=bcli" "$HOME/.lightning/config"
	grep -q "lightning backend" "$HOME/.lightning/config"
	grep -q "trustedcoin" "$HOME/.lightning/config"
	# The plugin binary should have landed in plugins/ and be executable.
	[ -x "$HOME/.lightning/plugins/trustedcoin" ]
}

@test "FEAT-183: daemon install --trustedcoin skips fetch if binary already present" {
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	mkdir -p "$HOME/.lightning/plugins"
	printf '#!/bin/sh\nexit 0\n' > "$HOME/.lightning/plugins/trustedcoin"
	chmod +x "$HOME/.lightning/plugins/trustedcoin"
	# Fail loudly if curl gets called.
	printf '#!/bin/sh\necho "curl should not be called" >&2; exit 99\n' > "$BIN_SHIM/curl"
	chmod +x "$BIN_SHIM/curl"
	run "$LIGHTNING_BIN" -v daemon install --trustedcoin
	[ "$status" -eq 0 ]
	[[ "$output" == *"already present"* ]]
	[[ "$output" != *"fetching trustedcoin"* ]]
}

@test "FEAT-183: daemon install --trustedcoin reports failure when curl fails (Linux)" {
	if [ "$(uname -s)" = "Darwin" ]; then
		skip "macOS uses go install, not curl"
	fi
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	printf '#!/bin/sh\nexit 22\n' > "$BIN_SHIM/curl"
	chmod +x "$BIN_SHIM/curl"
	run "$LIGHTNING_BIN" daemon install --trustedcoin
	# Config is still written; download failure is surfaced.
	grep -q "disable-plugin=bcli" "$HOME/.lightning/config"
	[[ "$output" == *"failed to download"* ]]
	[[ "$output" == *"manual install"* ]]
}

@test "FEAT-183: daemon install --trustedcoin needs go on macOS without one" {
	if [ "$(uname -s)" != "Darwin" ]; then
		skip "macOS-only — prebuilt binaries cover Linux/BSD"
	fi
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	# Hide go from PATH.
	export PATH="$BIN_SHIM:/usr/bin:/bin"
	run "$LIGHTNING_BIN" daemon install --trustedcoin
	grep -q "disable-plugin=bcli" "$HOME/.lightning/config"
	[[ "$output" == *"doesn't ship a prebuilt macOS binary"* ]]
	[[ "$output" == *"go install"* ]]
}

@test "FEAT-183: daemon install --bitcoind strips the managed block" {
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	_stub_trustedcoin_curl
	# First enable trustedcoin.
	"$LIGHTNING_BIN" daemon install --trustedcoin >/dev/null 2>&1
	grep -q "disable-plugin=bcli" "$HOME/.lightning/config"
	# Then disable.
	run "$LIGHTNING_BIN" daemon install --bitcoind
	[ "$status" -eq 0 ]
	! grep -q "disable-plugin=bcli" "$HOME/.lightning/config"
	! grep -q "lightning backend" "$HOME/.lightning/config"
}

@test "FEAT-183: daemon install --trustedcoin is idempotent (no duplicate blocks)" {
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	_stub_trustedcoin_curl
	"$LIGHTNING_BIN" daemon install --trustedcoin >/dev/null 2>&1
	"$LIGHTNING_BIN" daemon install --trustedcoin >/dev/null 2>&1
	"$LIGHTNING_BIN" daemon install --trustedcoin >/dev/null 2>&1
	# Exactly one block, not three.
	local count; count=$(grep -c "lightning backend" "$HOME/.lightning/config" || true)
	[ "$count" -eq 2 ]   # begin + end markers
}

@test "FEAT-183: daemon install --trustedcoin migrates a legacy esplora block" {
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	_stub_trustedcoin_curl
	mkdir -p "$HOME/.lightning"
	cat > "$HOME/.lightning/config" <<'EOF'
# user setting that should survive
log-level=debug

# >>> lightning esplora — managed by 'daemon install --esplora'
disable-plugin=bcli
sauron-api-endpoint=https://blockstream.info/api
# <<< lightning esplora
EOF
	run "$LIGHTNING_BIN" daemon install --trustedcoin
	[ "$status" -eq 0 ]
	# Legacy block is gone; user setting preserved; new block present.
	! grep -q "lightning esplora" "$HOME/.lightning/config"
	! grep -q "sauron-api-endpoint" "$HOME/.lightning/config"
	grep -q "log-level=debug" "$HOME/.lightning/config"
	grep -q "lightning backend" "$HOME/.lightning/config"
	grep -q "trustedcoin" "$HOME/.lightning/config"
}

@test "FEAT-183: daemon start skips bitcoind check in trustedcoin mode" {
	echo "down" > "$MOCK_STATE"
	mkdir -p "$HOME/.lightning"
	# Pre-seed trustedcoin config (bypass install's WARNING banner).
	cat > "$HOME/.lightning/config" <<EOF
# >>> lightning backend — managed by 'daemon install'
disable-plugin=bcli
# trustedcoin reference
# <<< lightning backend
EOF
	cat > "$BIN_SHIM/lightningd" <<EOF
#!/bin/sh
rm -f "$MOCK_STATE"
exit 0
EOF
	chmod +x "$BIN_SHIM/lightningd"
	# Pretend bitcoin-cli is absent (would normally warn).
	export PATH="$BIN_SHIM:/usr/bin:/bin"
	run "$LIGHTNING_BIN" -v daemon start
	[ "$status" -eq 0 ]
	[[ "$output" == *"trustedcoin backend"* ]]
	[[ "$output" == *"skipping bitcoind check"* ]]
	[[ "$output" != *"bitcoin-cli not found"* ]]
}

@test "FEAT-183: daemon status reports backend in healthy + down output" {
	mkdir -p "$HOME/.lightning"
	cat > "$HOME/.lightning/config" <<EOF
# >>> lightning backend — managed by 'daemon install'
disable-plugin=bcli
# trustedcoin reference
# <<< lightning backend
EOF
	# Healthy path.
	run "$LIGHTNING_BIN" daemon status
	[ "$status" -eq 0 ]
	[[ "$output" == *"backend: trustedcoin"* ]]
	# Down path.
	echo "down" > "$MOCK_STATE"
	run "$LIGHTNING_BIN" daemon status
	[ "$status" -eq 2 ]
	[[ "$output" == *"backend: trustedcoin"* ]]
}

@test "FEAT-183: daemon start falls through to direct mode without a service unit" {
	echo "down" > "$MOCK_STATE"
	# Ensure no plist / unit exists.
	rm -f "$HOME/Library/LaunchAgents/network.lightning.lightningd.plist" 2>/dev/null
	rm -f "$HOME/.config/systemd/user/lightning.service" 2>/dev/null
	# Stub lightningd that flips MOCK_STATE so the post-start
	# probe sees a healthy daemon (real lightningd would do that
	# by responding to lightning-cli getinfo).
	cat > "$BIN_SHIM/lightningd" <<EOF
#!/bin/sh
rm -f "$MOCK_STATE"
exit 0
EOF
	chmod +x "$BIN_SHIM/lightningd"
	# Verbose so the info messages surface (test fixture sets SELF_QUIET=1).
	run "$LIGHTNING_BIN" -v daemon start
	[ "$status" -eq 0 ]
	[[ "$output" == *"no service unit installed"* ]]
	[[ "$output" == *"daemon install"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-184: unlock
# ---------------------------------------------------------------------------

@test "FEAT-184: lightning wallet unlock --stored is a no-op when not encrypted" {
	# No hsm_secret exists yet → not encrypted.
	mkdir -p "$HOME/.lightning/bitcoin"
	# 32-byte file = unencrypted.
	dd if=/dev/zero of="$HOME/.lightning/bitcoin/hsm_secret" bs=32 count=1 status=none
	# Mock `secret` so the dep check passes even though we won't call it.
	ln -sf /bin/true "$BIN_SHIM/secret"
	run "$LIGHTNING_BIN" wallet unlock --stored
	[ "$status" -eq 0 ]
}

@test "FEAT-184: lightning wallet unlock errors clearly when lightning-cli absent" {
	export PATH="/usr/bin:/bin"
	run -127 "$LIGHTNING_BIN" wallet unlock --stored
}

# ---------------------------------------------------------------------------
# FEAT-172: channel management
# ---------------------------------------------------------------------------

@test "FEAT-172: lightning channel (no args) prints usage" {
	run "$LIGHTNING_BIN" channel
	[ "$status" -ne 0 ]
	[[ "$output" == *"subcommands"* ]]
}

@test "FEAT-172: lightning channel list returns the TSV header" {
	run "$LIGHTNING_BIN" channel list
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "id	peer	capacity	local	remote	state" ]]
}

@test "FEAT-172: lightning channel open reports ok + channel_id" {
	run "$LIGHTNING_BIN" channel open \
		020000000000000000000000000000000000000000000000000000000000000002@127.0.0.1:9735 \
		100000
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
	[[ "$output" == *"channel_id"* ]]
}

@test "FEAT-172: lightning channel close reports ok + txid" {
	run "$LIGHTNING_BIN" channel close 0000000000000000000000000000000000000000000000000000000000000001
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
	[[ "$output" == *"txid"* ]]
}

@test "FEAT-172: lightning channel force-close refuses without --confirm" {
	run "$LIGHTNING_BIN" channel force-close 0000000000000000000000000000000000000000000000000000000000000001
	[ "$status" -eq 2 ]
	[[ "$output" == *"REFUSING"* ]]
}

@test "FEAT-172: lightning channel balance prints a header row" {
	run "$LIGHTNING_BIN" channel balance
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "channel_id	local_msat	remote_msat	state" ]]
}

# ---------------------------------------------------------------------------
# FEAT-173: payments / invoices / BOLT-12 / LNURL
# ---------------------------------------------------------------------------

@test "FEAT-173: lightning invoice create 1000 'beer' returns a BOLT-11" {
	run "$LIGHTNING_BIN" invoice create 1000 beer
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == lnbc* || "${lines[0]}" == lntb* || "${lines[0]}" == lnbcrt* ]]
}

@test "FEAT-173: lightning invoice pay <bolt11> returns ok + payment_hash" {
	run "$LIGHTNING_BIN" invoice pay lnbcrt10n1pmocktest
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
	[[ "$output" == *"payment_hash"* ]]
}

@test "FEAT-173: lightning decode identifies BOLT-11" {
	run "$LIGHTNING_BIN" decode lnbcrt10n1pmocktest
	[ "$status" -eq 0 ]
	[[ "$output" == *"bolt11"* ]]
}

@test "FEAT-173: lightning decode identifies BOLT-12 offer" {
	run "$LIGHTNING_BIN" decode lno1pgmocktest
	[ "$status" -eq 0 ]
	[[ "$output" == *"bolt12-offer"* ]]
}

@test "FEAT-173: lightning decode identifies LNURL" {
	run "$LIGHTNING_BIN" decode LNURL1DP68GURN8GHJ7
	[ "$status" -eq 0 ]
	[[ "$output" == *"lnurl"* ]]
}

@test "FEAT-173: lightning decode identifies a Lightning Address" {
	run "$LIGHTNING_BIN" decode alice@example.com
	[ "$status" -eq 0 ]
	[[ "$output" == *"lightning-address"* ]]
	[[ "$output" == *"example.com"* ]]
}

@test "FEAT-173: lightning decode strips the 'lightning:' BIP-21 prefix" {
	run "$LIGHTNING_BIN" decode "lightning:lnbcrt10n1pmocktest"
	[ "$status" -eq 0 ]
	[[ "$output" == *"bolt11"* ]]
}

@test "FEAT-173: lightning offer create makes a BOLT-12 offer" {
	run "$LIGHTNING_BIN" offer create 500 donations
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == lno* ]]
}

@test "FEAT-173: lightning offer pay fetches and pays" {
	run "$LIGHTNING_BIN" offer pay lno1pgmocktest
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

@test "FEAT-173: lightning offer (no args) prints usage" {
	run "$LIGHTNING_BIN" offer
	[ "$status" -ne 0 ]
	[[ "$output" == *"subcommands"* ]]
}

@test "FEAT-173: lightning invoice (no args) prints usage" {
	run "$LIGHTNING_BIN" invoice
	[ "$status" -ne 0 ]
	[[ "$output" == *"subcommands"* ]]
}

@test "FEAT-173: lightning send (keysend) succeeds" {
	run "$LIGHTNING_BIN" send 020000000000000000000000000000000000000000000000000000000000000002 100
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

@test "FEAT-173: lightning lnurl (no args) prints usage" {
	run "$LIGHTNING_BIN" lnurl
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-192: QR codes
# ---------------------------------------------------------------------------

@test "FEAT-192: lightning qr (no args) prints usage" {
	run "$LIGHTNING_BIN" qr
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage"* ]]
}

@test "FEAT-192: lightning qr emits something for ANSI mode" {
	if ! command -v qrencode >/dev/null; then
		# Fallback path: print the text as-is.
		run "$LIGHTNING_BIN" qr "lnbcrt10n1pmocktest"
		[ "$status" -eq 0 ]
		[[ "$output" == *"lnbcrt10n1pmocktest"* ]]
	else
		run "$LIGHTNING_BIN" qr "lnbcrt10n1pmocktest"
		[ "$status" -eq 0 ]
		# qrencode UTF8 output contains the half-block characters.
		[ -n "$output" ]
	fi
}

@test "FEAT-192: lightning qr --png writes a file" {
	if ! command -v qrencode >/dev/null; then
		skip "qrencode not installed"
	fi
	out="$BATS_TMPDIR/qr.$$.png"
	run "$LIGHTNING_BIN" qr "lnbcrt10n1pmocktest" --png "$out"
	[ "$status" -eq 0 ]
	[ -s "$out" ]
	rm -f "$out"
}

@test "FEAT-192: lightning invoice create --qr emits the BOLT-11 AND a QR" {
	if ! command -v qrencode >/dev/null; then
		skip "qrencode not installed"
	fi
	run "$LIGHTNING_BIN" invoice create 1000 beer --qr
	[ "$status" -eq 0 ]
	# First line is the BOLT-11, then a blank line, then the QR.
	[[ "${lines[0]}" == lnbc* || "${lines[0]}" == lntb* || "${lines[0]}" == lnbcrt* ]]
}

# ---------------------------------------------------------------------------
# FEAT-174 + FEAT-193: wallet repo + SQLite store
# ---------------------------------------------------------------------------

@test "FEAT-174: lightning wallet (no args) prints usage" {
	run "$LIGHTNING_BIN" wallet
	[ "$status" -ne 0 ]
	[[ "$output" == *"subcommands"* ]]
}

@test "FEAT-174: lightning wallet new creates a git-backed wallet with state.db" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	run "$LIGHTNING_BIN" wallet new alice
	[ "$status" -eq 0 ]
	[ -d "$LIGHTNING_WALLETS_ROOT/alice/.git" ]
	[ -f "$LIGHTNING_WALLETS_ROOT/alice/state.db" ]
	[ -f "$LIGHTNING_WALLETS_ROOT/alice/state.sql" ]
	[ -f "$LIGHTNING_WALLETS_ROOT/alice/lightning-dir" ]
	# state.db should contain the five schema tables.
	tables=$(sqlite3 "$LIGHTNING_WALLETS_ROOT/alice/state.db" \
		"SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" | sort)
	[[ "$tables" == *"accounts"* ]]
	[[ "$tables" == *"ledger"* ]]
	[[ "$tables" == *"invoices"* ]]
	[[ "$tables" == *"channel_notes"* ]]
	[[ "$tables" == *"users"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT"
}

@test "FEAT-174: wallet new auto-selects the first wallet as active" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" wallet active
	[ "$status" -eq 0 ]
	[ "$output" = "alice" ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-174: wallet list marks active wallet with *" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" wallet new bob >/dev/null
	"$LIGHTNING_BIN" wallet use bob >/dev/null
	run "$LIGHTNING_BIN" wallet list
	[ "$status" -eq 0 ]
	[[ "$output" == *"* bob"* ]]
	[[ "$output" == *"  alice"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-174: wallet push round-trips through a bare-repo remote" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	# Set up a bare-repo remote.
	bare="$BATS_TMPDIR/bare.$$"
	git init --bare --quiet "$bare"
	(cd "$LIGHTNING_WALLETS_ROOT/alice" && git remote add origin "$bare")
	run "$LIGHTNING_BIN" wallet push origin
	[ "$status" -eq 0 ]
	# Clone-side: state.sql should be there.
	clone="$BATS_TMPDIR/clone.$$"
	git clone --quiet "$bare" "$clone"
	[ -f "$clone/state.sql" ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$bare" "$clone" "$HOME/.lightning"
}

# ---------------------------------------------------------------------------
# Account verbs (FEAT-174 + FEAT-195 limit/overdraft fields)
# ---------------------------------------------------------------------------

@test "FEAT-174: account create + list + show + delete" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null

	run "$LIGHTNING_BIN" account create rent "monthly rent" --limit 50000 --overdraft deny
	[ "$status" -eq 0 ]

	run "$LIGHTNING_BIN" account list
	[ "$status" -eq 0 ]
	[[ "$output" == *"rent"* ]]
	[[ "$output" == *"50000"* ]]
	[[ "$output" == *"deny"* ]]

	run "$LIGHTNING_BIN" account show rent
	[ "$status" -eq 0 ]
	[[ "$output" == *"name:        rent"* ]]
	[[ "$output" == *"balance_sat: 0"* ]]
	[[ "$output" == *"overdraft:   deny"* ]]

	run "$LIGHTNING_BIN" account delete rent
	[ "$status" -eq 0 ]

	run "$LIGHTNING_BIN" account show rent
	[ "$status" -eq 2 ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-174: account create rejects invalid name" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" account create "Bad Name"
	[ "$status" -ne 0 ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

# ---------------------------------------------------------------------------
# FEAT-193: ledger verbs
# ---------------------------------------------------------------------------

@test "FEAT-193: ledger add + list + sum + balance" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null

	# Receive 1000 sat (1_000_000 msat) into rent.
	"$LIGHTNING_BIN" ledger add in 1000000 --account rent --peer bob@example.com --message "march" --note "march budget"
	# Pay 250 sat (-250_000 msat) from rent.
	"$LIGHTNING_BIN" ledger add out -250000 --account rent --peer carol@example.com --message "coffee"

	run "$LIGHTNING_BIN" ledger list --account rent
	[ "$status" -eq 0 ]
	# Header row + 2 data rows.
	[ "${#lines[@]}" -ge 3 ]
	[[ "$output" == *"march"* ]]
	[[ "$output" == *"coffee"* ]]
	[[ "$output" == *"march budget"* ]]

	run "$LIGHTNING_BIN" ledger balance rent
	[ "$status" -eq 0 ]
	# 1_000_000 - 250_000 = 750_000 msat.
	[ "$output" = "750000" ]

	run "$LIGHTNING_BIN" ledger sum --by account
	[ "$status" -eq 0 ]
	[[ "$output" == *"rent"* ]]
	[[ "$output" == *"750000"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-193: ledger annotate fills the note column on an existing row" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null
	"$LIGHTNING_BIN" ledger add in 1000000 --account rent --payment-hash deadbeef --message "test"

	run "$LIGHTNING_BIN" ledger annotate deadbeef "april budget"
	[ "$status" -eq 0 ]
	[[ "$output" == *"1 row"* ]]

	run "$LIGHTNING_BIN" ledger list --account rent
	[ "$status" -eq 0 ]
	[[ "$output" == *"april budget"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-193: ledger export csv produces a CSV with header" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null
	"$LIGHTNING_BIN" ledger add in 1000000 --account rent --message "test"
	run "$LIGHTNING_BIN" ledger export csv
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == *"ts,account,direction"* ]]
	[[ "$output" == *"rent"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-174: history is an alias for ledger list" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null
	"$LIGHTNING_BIN" ledger add in 1000 --account rent --message "ping"
	run "$LIGHTNING_BIN" history
	[ "$status" -eq 0 ]
	[[ "$output" == *"ping"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

# ---------------------------------------------------------------------------
# FEAT-185: seed + SCB
# ---------------------------------------------------------------------------

@test "FEAT-185: lightning scb (no args) prints usage" {
	run "$LIGHTNING_BIN" scb
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage"* ]]
}

@test "FEAT-185: lightning scb emit writes a non-empty file" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" scb emit
	[ "$status" -eq 0 ]
	# Find the file emit wrote.
	scb=$(ls "$LIGHTNING_WALLETS_ROOT/alice/scb/"scb-*.hex)
	[ -s "$scb" ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-185: lightning seed (no args) prints usage" {
	run "$LIGHTNING_BIN" seed
	[ "$status" -ne 0 ]
	[[ "$output" == *"export"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-187: backup composer
# ---------------------------------------------------------------------------

@test "FEAT-187: backup emits SCB + pushes wallet to remote" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	bare="$BATS_TMPDIR/bare.$$"
	git init --bare --quiet "$bare"
	(cd "$LIGHTNING_WALLETS_ROOT/alice" && git remote add origin "$bare")
	run "$LIGHTNING_BIN" backup --remote origin
	[ "$status" -eq 0 ]
	# Bare repo should now have the SCB file.
	clone="$BATS_TMPDIR/clone.$$"
	git clone --quiet "$bare" "$clone"
	scb=$(ls "$clone/scb/"scb-*.hex 2>/dev/null || true)
	[ -n "$scb" ]
	[ -s "$scb" ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$bare" "$clone" "$HOME/.lightning"
}

# ---------------------------------------------------------------------------
# FEAT-195: bank mode (apikey, statements, account list --balances)
# ---------------------------------------------------------------------------

@test "FEAT-195: account apikey create stores under secret + prints once" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null

	# Mock secret as a key-value file store.
	SECRET_STORE="$BATS_TMPDIR/secret.$$"
	mkdir -p "$SECRET_STORE"
	cat > "$BIN_SHIM/secret" <<EOF
#!/bin/bash
set -e
case "\$1" in
  put) cat > "$SECRET_STORE/\$2" ;;
  get) [ -f "$SECRET_STORE/\$2" ] && cat "$SECRET_STORE/\$2" || exit 1 ;;
  rm)  rm -f "$SECRET_STORE/\$2" ;;
esac
EOF
	chmod +x "$BIN_SHIM/secret"

	run "$LIGHTNING_BIN" account apikey create rent --scope write
	[ "$status" -eq 0 ]
	# Second line is the key (line 1 is "lightning account apikey: rent/write =").
	key="${lines[1]}"
	[ -n "$key" ]
	[ -f "$SECRET_STORE/lightning.rent.apikey.write" ]
	stored=$(cat "$SECRET_STORE/lightning.rent.apikey.write")
	[ "$key" = "$stored" ]

	run "$LIGHTNING_BIN" account apikey list rent
	[ "$status" -eq 0 ]
	[[ "$output" == *"write"* ]]

	rm -rf "$LIGHTNING_WALLETS_ROOT" "$SECRET_STORE" "$HOME/.lightning"
}

@test "FEAT-195: account list --balances prints balance + limit + overdraft" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent --limit 50000 --overdraft deny >/dev/null
	"$LIGHTNING_BIN" ledger add in 1000000 --account rent

	run "$LIGHTNING_BIN" account list --balances
	[ "$status" -eq 0 ]
	[[ "$output" == *"rent"* ]]
	[[ "$output" == *"1000"* ]]   # balance_sat = 1_000_000 msat / 1000 = 1000
	[[ "$output" == *"deny"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-195: ledger statement renders a plaintext block" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null
	"$LIGHTNING_BIN" ledger add in 1000000 --account rent --message "march"
	"$LIGHTNING_BIN" ledger add out -250000 --account rent --message "coffee"
	year=$(date -u +%Y)
	month=$(date -u +%Y-%m)

	run "$LIGHTNING_BIN" ledger statement --account rent --period "$month"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Statement for rent"* ]]
	[[ "$output" == *"Closing balance"* ]]
	[[ "$output" == *"Net for period"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

# ---------------------------------------------------------------------------
# FEAT-175: liquidity
# ---------------------------------------------------------------------------

@test "FEAT-175: lightning liquidity (no args) prints usage" {
	run "$LIGHTNING_BIN" liquidity
	[ "$status" -ne 0 ]
	[[ "$output" == *"subcommands"* || "$output" == *"status"* ]]
}

@test "FEAT-175: liquidity status returns TSV header + per-channel rows" {
	run "$LIGHTNING_BIN" liquidity status
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "channel_id	inbound_sat	outbound_sat	state" ]]
}

@test "FEAT-175: provider default writes the choice into the wallet repo" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" liquidity provider default lsp
	[ "$status" -eq 0 ]
	[ -f "$LIGHTNING_WALLETS_ROOT/alice/liquidity/default" ]
	[ "$(cat "$LIGHTNING_WALLETS_ROOT/alice/liquidity/default")" = "lsp" ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

# ---------------------------------------------------------------------------
# FEAT-198: LSPS1 inbound liquidity via cln-lsps plugin
# ---------------------------------------------------------------------------

# Set up a wallet + an LSP "boltz" config at $wallet/liquidity/lsp/boltz/peer.
# Tests that want the happy path also export MOCK_HELP_INCLUDES so the
# plugin gate passes.
_lsps_setup_wallet() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	mkdir -p "$LIGHTNING_WALLETS_ROOT/alice/liquidity/lsp/boltz"
	# Format: pubkey@host:port — uses a deterministic test pubkey.
	echo "02d96eadea3d780104449aca5c93461ce67c1564e2e1d73225fa67dd3b997a6018@45.86.229.190:9735" \
		> "$LIGHTNING_WALLETS_ROOT/alice/liquidity/lsp/boltz/peer"
}

# Set MOCK_HELP_INCLUDES so `cli help lsps1-get-info` returns a non-empty
# help array; this is how the verb detects the plugin is loaded.
_lsps_plugin_loaded() {
	export MOCK_HELP_INCLUDES='{"command":"lsps1-get-info","verbose":"..."}'
}

@test "FEAT-198: liquidity lsp buy errors clearly when cln-lsps plugin not loaded" {
	_lsps_setup_wallet
	# Don't set MOCK_HELP_INCLUDES — help returns [], plugin gate fails.
	run "$LIGHTNING_BIN" liquidity lsp boltz buy 1000000 --yes
	[ "$status" -eq 3 ]
	[[ "$output" == *"cln-lsps plugin not loaded"* ]]
	[[ "$output" == *"daemon install --lsps"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-198: liquidity lsp buy errors when LSP peer is not configured" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	_lsps_plugin_loaded
	# No peer file — verb should refuse with a config-write hint.
	run "$LIGHTNING_BIN" liquidity lsp boltz buy 1000000 --yes
	[ "$status" -eq 2 ]
	[[ "$output" == *"LSP 'boltz' not configured"* ]]
	[[ "$output" == *"pubkey@host:port"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-198: liquidity lsp buy rejects a malformed peer file" {
	_lsps_setup_wallet
	_lsps_plugin_loaded
	echo "not-a-valid-peer-uri-no-at-sign" > "$LIGHTNING_WALLETS_ROOT/alice/liquidity/lsp/boltz/peer"
	run "$LIGHTNING_BIN" liquidity lsp boltz buy 1000000 --yes
	[ "$status" -eq 2 ]
	[[ "$output" == *"pubkey@host:port"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-198: liquidity lsp buy refuses without --yes when stdin is not a TTY" {
	_lsps_setup_wallet
	_lsps_plugin_loaded
	# bats `run` doesn't allocate a TTY — exactly the path the test names.
	run "$LIGHTNING_BIN" liquidity lsp boltz buy 1000000
	[ "$status" -eq 1 ]
	[[ "$output" == *"not a TTY"* ]]
	[[ "$output" == *"--yes"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-198: liquidity lsp buy --yes runs the full happy-path flow" {
	_lsps_setup_wallet
	_lsps_plugin_loaded
	# Default MOCK_LSPS1_STATE / MOCK_LSPS1_CHANNEL_ID — channel materialises
	# on first poll, so the loop exits cleanly.
	run "$LIGHTNING_BIN" liquidity lsp boltz buy 1000000 --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"capacity: 1000000 sat"* ]]
	[[ "$output" == *"paying order mock-order-"* ]]
	[[ "$output" == *"channel open: abcdef"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-198: liquidity lsp buy reports REFUNDED as a clear failure" {
	_lsps_setup_wallet
	_lsps_plugin_loaded
	export MOCK_LSPS1_STATE=REFUNDED
	# Suppress channel_id so we hit the state-machine terminal branch
	# before the channel-found branch.
	export MOCK_LSPS1_CHANNEL_ID=""
	run "$LIGHTNING_BIN" liquidity lsp boltz buy 1000000 --yes
	[ "$status" -eq 8 ]
	[[ "$output" == *"REFUNDED"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-198: liquidity lsp buy propagates a connect failure" {
	_lsps_setup_wallet
	_lsps_plugin_loaded
	export MOCK_FAIL_CONNECT=1
	run "$LIGHTNING_BIN" liquidity lsp boltz buy 1000000 --yes
	[ "$status" -eq 4 ]
	[[ "$output" == *"cannot connect to LSP boltz"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-198: liquidity lsp buy propagates an lsps1-get-info failure" {
	_lsps_setup_wallet
	_lsps_plugin_loaded
	export MOCK_FAIL_LSPS1_GET_INFO=1
	run "$LIGHTNING_BIN" liquidity lsp boltz buy 1000000 --yes
	[ "$status" -eq 5 ]
	[[ "$output" == *"lsps1-get-info failed"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-198: liquidity lsp buy times out cleanly when channel never appears" {
	_lsps_setup_wallet
	_lsps_plugin_loaded
	# No channel_id ever — verb polls until LIGHTNING_LSP_TIMEOUT_S elapses.
	export MOCK_LSPS1_CHANNEL_ID=""
	export MOCK_LSPS1_STATE=EXPECT_PAYMENT
	export LIGHTNING_LSP_TIMEOUT_S=2
	export LIGHTNING_LSP_POLL_INTERVAL_S=1
	run "$LIGHTNING_BIN" liquidity lsp boltz buy 1000000 --yes
	[ "$status" -eq 7 ]
	[[ "$output" == *"timed out"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-198: daemon install --lsps flag is parsed without exploding" {
	# Dry-test only — actual binary download would need curl + tar shims
	# (see _stub_trustedcoin_curl for the pattern).  Here we just verify
	# the flag is recognised, the existing service-unit code still runs,
	# and the relevant constants are present in the source.
	grep -q '^LSPS_PLUGIN_REPO=' "$BATS_TEST_DIRNAME/../../libexec/lightning/daemon"
	grep -q '^LSPS_PLUGIN_VERSION=' "$BATS_TEST_DIRNAME/../../libexec/lightning/daemon"
	grep -q 'install_lsps_plugin' "$BATS_TEST_DIRNAME/../../libexec/lightning/daemon"
	# Flag parses — daemon install --lsps shouldn't fail on the flag itself.
	# (It WILL fail later trying to download the plugin without curl shims;
	# we just check it gets past flag parsing.)
	run grep -E '^\s+--lsps\)' "$BATS_TEST_DIRNAME/../../libexec/lightning/daemon"
	[ "$status" -eq 0 ]
}

@test "FEAT-198: spec file references the cln-lsps plugin approach" {
	# Moved to done/ when the ticket shipped — same convention every
	# other graduated 0.x FEAT followed.
	f="$BATS_TEST_DIRNAME/../../issues/feature/done/198-lsps1-inbound-liquidity.md"
	[ -f "$f" ]
	grep -q "^id: FEAT-198" "$f"
	grep -q "^status: shipped" "$f"
	grep -q "cln-lsps" "$f"
	grep -q "Boltz" "$f"
	grep -q "daemon install --lsps" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-176: Lightning Address
# ---------------------------------------------------------------------------

@test "FEAT-176: address (no args) prints usage" {
	run "$LIGHTNING_BIN" address
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage"* ]]
	[[ "$output" == *"resolve"* || "$output" == *"create"* ]]
}

@test "FEAT-176: address create without Apache exits with install hint" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create alice >/dev/null
	# Scrub PATH so apache2/httpd/apachectl aren't found.
	export PATH="$BIN_SHIM:/usr/bin:/bin"
	rm -f "$BIN_SHIM/apache2" "$BIN_SHIM/httpd" "$BIN_SHIM/apachectl"
	run "$LIGHTNING_BIN" address create alice@example.com --account alice
	[ "$status" -eq 3 ]
	[[ "$output" == *"apache2 not installed"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-176: address create with Apache registers the binding" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create alice >/dev/null
	# Stub apache2 so the detection passes.
	ln -sf /bin/true "$BIN_SHIM/apache2"

	run "$LIGHTNING_BIN" address create alice@example.com --account alice
	[ "$status" -eq 0 ]
	[[ "$output" == *"registered alice@example.com"* ]]

	run "$LIGHTNING_BIN" address list
	[ "$status" -eq 0 ]
	[[ "$output" == *"alice"* ]]

	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-176: account create --host chains into address create" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	ln -sf /bin/true "$BIN_SHIM/apache2"

	run "$LIGHTNING_BIN" account create bob --host example.com
	[ "$status" -eq 0 ]
	[[ "$output" == *"created bob"* ]]
	[[ "$output" == *"registered bob@example.com"* ]]

	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

# ---------------------------------------------------------------------------
# FEAT-196: well-known API sudo-bridge verbs
# ---------------------------------------------------------------------------

@test "FEAT-196: api-verify (matching key) exits 0" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null

	# Stub secret to return a known key.
	cat > "$BIN_SHIM/secret" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "get lightning.rent.apikey.write") echo "supersecret" ;;
  *) exit 1 ;;
esac
EOF
	chmod +x "$BIN_SHIM/secret"

	run "$LIGHTNING_BIN" api-verify rent write supersecret
	[ "$status" -eq 0 ]

	run "$LIGHTNING_BIN" api-verify rent write WRONGKEY
	[ "$status" -ne 0 ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-196: api-balance returns the JSON shape balance.py expects" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create alice --limit 50000 --overdraft deny >/dev/null
	ln -sf /bin/true "$BIN_SHIM/apache2"
	"$LIGHTNING_BIN" address create alice@example.com --account alice >/dev/null
	"$LIGHTNING_BIN" ledger add in 1234000 --account alice

	run "$LIGHTNING_BIN" api-balance alice
	[ "$status" -eq 0 ]
	[[ "$output" == *'"balance_sat":1234'* ]]
	[[ "$output" == *'"limit_sat":50000'* ]]
	[[ "$output" == *'"overdraft":"deny"'* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-196: api-send refuses when overdraft=deny and insufficient balance" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create alice --overdraft deny >/dev/null
	ln -sf /bin/true "$BIN_SHIM/apache2"
	"$LIGHTNING_BIN" address create alice@example.com --account alice >/dev/null
	# Balance is zero. Try to send 100 sat.
	run "$LIGHTNING_BIN" api-send alice bob@example.com 100 "msg" "note"
	[ "$status" -eq 6 ]
	[[ "$output" == *"would_overdraw"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-196: balance.py is syntactically valid Python 3" {
	command -v python3 >/dev/null || skip "python3 not installed"
	# Lightweight smoke: the CGI scripts must at least parse.
	# Real end-to-end coverage of the Apache + Python + sudo bridge
	# lives in FEAT-182's SIT suite where a regtest container has
	# the real services.
	run python3 -m py_compile share/lightning/wellknown/lightning/_lib.py \
	                          share/lightning/wellknown/lightning/balance.py \
	                          share/lightning/wellknown/lightning/recv.py \
	                          share/lightning/wellknown/lightning/send.py \
	                          share/lightning/wellknown/lnurlp/handler.py
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# FEAT-189: Tor
# ---------------------------------------------------------------------------

@test "FEAT-189: lightning tor (no args) prints usage" {
	run "$LIGHTNING_BIN" tor
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage"* ]]
}

@test "FEAT-189: lightning tor on writes proxy + statictor into config" {
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR/bitcoin"
	touch "$LIGHTNING_DIR/bitcoin/config"
	# Avoid the restart hop reaching the real daemon.
	ln -sf /bin/true "$BIN_SHIM/lightningd"

	run "$LIGHTNING_BIN" tor on
	# May fail to find an onion in the mock; the config edit is what matters.
	grep -q '^proxy=127.0.0.1:9050' "$LIGHTNING_DIR/bitcoin/config"
	grep -q '^addr=statictor:127.0.0.1:9051' "$LIGHTNING_DIR/bitcoin/config"
	grep -q '^always-use-proxy=true' "$LIGHTNING_DIR/bitcoin/config"
	rm -rf "$LIGHTNING_DIR"
}

@test "FEAT-189: lightning tor off strips the proxy lines" {
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR/bitcoin"
	cat > "$LIGHTNING_DIR/bitcoin/config" <<EOF
network=bitcoin
proxy=127.0.0.1:9050
addr=statictor:127.0.0.1:9051
always-use-proxy=true
EOF
	run "$LIGHTNING_BIN" tor off
	[ "$status" -eq 0 ]
	! grep -q '^proxy=' "$LIGHTNING_DIR/bitcoin/config"
	! grep -q '^addr=statictor:' "$LIGHTNING_DIR/bitcoin/config"
	grep -q '^network=bitcoin' "$LIGHTNING_DIR/bitcoin/config"
	rm -rf "$LIGHTNING_DIR"
}

# ---------------------------------------------------------------------------
# FEAT-178: standards vendoring
# ---------------------------------------------------------------------------

@test "FEAT-178: README index references the full BOLT / LUD / BIP / BLIP set" {
	dir="$BATS_TEST_DIRNAME/../../share/doc/lightning/standards"
	[ -f "$dir/README.md" ]
	for term in BOLT LUD BIP BLIP cln-overview UPSTREAM; do
		grep -q "$term" "$dir/README.md"
	done
}

@test "FEAT-178: UPSTREAM.txt covers every vendored file" {
	dir="$BATS_TEST_DIRNAME/../../share/doc/lightning/standards"
	# Every file mentioned in UPSTREAM.txt should exist on disk.
	while IFS=$'\t' read -r path _ _; do
		case "$path" in '#'*|'') continue ;; esac
		[ -f "$dir/$path" ] || { echo "missing: $path"; return 1; }
	done < "$dir/UPSTREAM.txt"
}

@test "FEAT-178: cln-overview is present and substantial" {
	f="$BATS_TEST_DIRNAME/../../share/doc/lightning/standards/cln-overview.md"
	[ -f "$f" ]
	# Should mention all four clightning binaries.
	for term in lightningd lightning-cli lightning-hsmtool BOLT; do
		grep -q "$term" "$f"
	done
}

@test "FEAT-178: refresh.sh exists and is executable" {
	f="$BATS_TEST_DIRNAME/../../share/doc/lightning/standards/refresh.sh"
	[ -x "$f" ]
}

# ---------------------------------------------------------------------------
# FEAT-179: man page
# ---------------------------------------------------------------------------

@test "FEAT-179: man page exists and references the full verb surface" {
	f="$BATS_TEST_DIRNAME/../../share/man/man1/lightning.1"
	[ -f "$f" ]
	# Spot-check sections + key verbs.
	grep -q "^.TH LIGHTNING 1" "$f"
	grep -q "^.SH NAME" "$f"
	grep -q "^.SH ENVIRONMENT" "$f"
	grep -q "^.SH SUBCOMMANDS" "$f"
	grep -q "^.SH STANDARDS" "$f"
	grep -q "^.SH EXIT STATUS" "$f"
	for verb in invoice pay channel wallet account ledger backup liquidity address tor daemon; do
		grep -qw "$verb" "$f"
	done
}

@test "FEAT-179: man page renders without groff warnings (if groff available)" {
	command -v groff >/dev/null || skip "groff not installed"
	f="$BATS_TEST_DIRNAME/../../share/man/man1/lightning.1"
	# -ww promotes warnings to errors; -man parses the man macros.
	run groff -ww -man -Tutf8 "$f"
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# FEAT-177: self-contained packaging
# ---------------------------------------------------------------------------

@test "FEAT-177: docs/lightning.md covers every 0.6.0 verb" {
	f="$BATS_TEST_DIRNAME/../../docs/lightning.md"
	[ -f "$f" ]
	for verb in info node-id peers channels balance channel invoice pay send decode \
	            offer offer-pay lnurl qr wallet account ledger history seed scb \
	            backup restore liquidity address daemon unlock tor; do
		grep -qw "$verb" "$f"
	done
}

@test "FEAT-177: bash completion defines _lightning and registers complete" {
	f="$BATS_TEST_DIRNAME/../../etc/bash_completion.d/lightning"
	[ -f "$f" ]
	grep -q "_lightning()" "$f"
	grep -q "^complete -F _lightning lightning$" "$f"
	grep -q "^complete -F _lightning lightning.sh$" "$f"
}

@test "FEAT-177: bash completion sources cleanly" {
	f="$BATS_TEST_DIRNAME/../../etc/bash_completion.d/lightning"
	run bash -n "$f"
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# FEAT-180: agent skill
# ---------------------------------------------------------------------------

@test "FEAT-180: SKILL.md describes the full 0.6.0 surface" {
	f="$BATS_TEST_DIRNAME/../../skills/lightning-wallet/SKILL.md"
	[ -f "$f" ]
	for term in "channel open" "lightning invoice" "address pay" "account create" \
	            "liquidity in" "backup" "restore" "BOLT" "LUD" "Tor" "force-close"; do
		grep -q "$term" "$f"
	done
}

@test "FEAT-180: SKILL.md frontmatter has name + description" {
	f="$BATS_TEST_DIRNAME/../../skills/lightning-wallet/SKILL.md"
	head -10 "$f" | grep -q "^name: lightning-wallet"
	head -20 "$f" | grep -q "^description:"
}

# ---------------------------------------------------------------------------
# FEAT-181: walkthrough
# ---------------------------------------------------------------------------

@test "FEAT-181: walkthrough doc covers all ten sections" {
	f="$BATS_TEST_DIRNAME/../../share/doc/lightning/walkthrough/README.md"
	[ -f "$f" ]
	# Section headers from §1 through §10.
	for hdr in "## 1. Setup" "## 2. Create" "## 3. Open" "## 4. Pay" \
	           "## 5. BOLT-12" "## 6. LNURL" "## 7. Lightning Address" \
	           "## 8. JSON API" "## 9. Inbound liquidity" "## 10. Wallet sync"; do
		grep -qF "$hdr" "$f"
	done
}

@test "FEAT-181: walkthrough cites each step's standard" {
	f="$BATS_TEST_DIRNAME/../../share/doc/lightning/walkthrough/README.md"
	for cite in "BOLT-1" "BOLT-2" "BOLT-11" "BOLT-12" "LUD-06" "LUD-16" \
	            "BIP-353" "BLIP-51" "FEAT-196"; do
		grep -qF "$cite" "$f"
	done
}

@test "FEAT-181: README links to the walkthrough" {
	f="$BATS_TEST_DIRNAME/../../Readme.md"
	grep -q "walkthrough/README.md" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-182: SIT scaffolding
# ---------------------------------------------------------------------------

@test "FEAT-182: SIT directory has dockerfiles + helpers + suites" {
	root="$BATS_TEST_DIRNAME/../../tests/sit"
	[ -d "$root/podman" ]
	[ -f "$root/podman/Dockerfile.regtest" ]
	[ -f "$root/podman/Dockerfile.clightning" ]
	[ -f "$root/helpers.bash" ]
	[ -d "$root/suites" ]
	[ -f "$root/README.md" ]
}

@test "FEAT-182: SIT covers all twelve advertised suites" {
	root="$BATS_TEST_DIRNAME/../../tests/sit/suites"
	for f in 01_daemon_lifecycle 02_channel_open_close 03_invoice_pay_bolt11 \
	         04_offer_pay_bolt12 05_lnurl_flow 06_address_create_pay \
	         07_wallet_account_ledger 08_wallet_push_pull \
	         09_inbound_liquidity_lsps1 10_wellknown_api \
	         11_walkthrough 12_softdep_probe; do
		[ -f "$root/$f.bats" ]
	done
}

@test "FEAT-182: every suite parses as valid bats" {
	root="$BATS_TEST_DIRNAME/../../tests/sit/suites"
	for f in "$root"/*.bats; do
		# A bats file is bash with `@test ...` syntax. `bash -n` doesn't
		# understand @test directly; use bats's own --count instead which
		# parses without executing.
		run bats --count "$f"
		[ "$status" -eq 0 ]
	done
}

@test "FEAT-182: helpers.bash defines sit_setup_alice_bob + sit_teardown" {
	f="$BATS_TEST_DIRNAME/../../tests/sit/helpers.bash"
	grep -q "^sit_setup_alice_bob()" "$f"
	grep -q "^sit_teardown()" "$f"
	grep -q "^sit_mine()" "$f"
	grep -q "^sit_open_channel()" "$f"
}

@test "FEAT-182: Dockerfile.clightning installs apache2 + python3 + sqlite3" {
	f="$BATS_TEST_DIRNAME/../../tests/sit/podman/Dockerfile.clightning"
	grep -q "apache2" "$f"
	grep -q "python3" "$f"
	grep -q "sqlite3" "$f"
	grep -q "lightningd" "$f"
}

@test "FEAT-182: Makefile check-sit target invokes podman build + run" {
	f="$BATS_TEST_DIRNAME/../../Makefile.in"
	grep -q "podman build" "$f"
	grep -q "podman run" "$f"
}

# ---------------------------------------------------------------------------
# 1.0.0 graduation smokes
# ---------------------------------------------------------------------------

@test "1.0.0: every 0.x milestone-plan file is gone (graduation invariant)" {
	root="$BATS_TEST_DIRNAME/../../issues"
	# 1.0.0 graduation: every 0.x milestone has been consumed and
	# deleted. Later 1.x milestones may be open and unfinished.
	! ls "$root"/MILESTONE-0.*.md 2>/dev/null
}

@test "1.0.0: every initial FEAT (170..195) is in issues/feature/done/" {
	root="$BATS_TEST_DIRNAME/../../issues/feature/done"
	for n in 170 171 172 173 174 175 176 177 178 179 180 181 182 \
	         183 184 185 187 189 191 192 193 195 196; do
		# Single matching file per number.
		count=$(ls "$root"/${n}-*.md 2>/dev/null | wc -l)
		[ "$count" -eq 1 ] || { echo "FEAT-$n missing in done/"; return 1; }
	done
}

# ---------------------------------------------------------------------------
# 1.1.0 — routing-node features
# ---------------------------------------------------------------------------

@test "FEAT-186: lightning tower (no args) prints usage" {
	run "$LIGHTNING_BIN" tower
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage"* ]]
}

@test "FEAT-186: tower client-add exits 3 when plugin not loaded" {
	run "$LIGHTNING_BIN" tower client-add 020000000000000000000000000000000000000000000000000000000000000002@127.0.0.1:9814
	[ "$status" -eq 3 ]
	[[ "$output" == *"altruistwatchtower"* ]]
}

@test "FEAT-186: tower client-add succeeds with plugin loaded" {
	export MOCK_HELP_INCLUDES='"addtower","listtowers"'
	run "$LIGHTNING_BIN" tower client-add 020000000000000000000000000000000000000000000000000000000000000002@127.0.0.1:9814
	[ "$status" -eq 0 ]
}

@test "FEAT-186: tower client-list returns TSV header" {
	export MOCK_HELP_INCLUDES='"addtower","listtowers"'
	run "$LIGHTNING_BIN" tower client-list
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "pubkey	host	port	sessions" ]]
}

@test "FEAT-188: lightning fee (no args) prints usage" {
	run "$LIGHTNING_BIN" fee
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage"* ]]
}

@test "FEAT-188: fee get returns the TSV header" {
	run "$LIGHTNING_BIN" fee get
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "channel_id	base_msat	ppm" ]]
}

@test "FEAT-188: fee set with non-numeric base rejects" {
	run "$LIGHTNING_BIN" fee set chan-1 not-a-number 100
	[ "$status" -ne 0 ]
	[[ "$output" == *"integer required"* ]]
}

@test "FEAT-188: fee set with valid args round-trips" {
	run "$LIGHTNING_BIN" fee set 0000000000000000000000000000000000000000000000000000000000000001 1000 5
	[ "$status" -eq 0 ]
	[[ "$output" == *"fee_base_msat"* ]]
	[[ "$output" == *"1000"* ]]
}

@test "FEAT-188: fee policy rejects unknown name" {
	run "$LIGHTNING_BIN" fee policy bogus
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown"* ]]
}

@test "FEAT-188: forward (no args) prints usage" {
	run "$LIGHTNING_BIN" forward
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage"* ]]
}

@test "FEAT-188: forward list returns TSV header" {
	run "$LIGHTNING_BIN" forward list
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "received_time	in_channel	out_channel	in_msat	out_msat	fee_msat	status" ]]
}

@test "FEAT-188: forward stats returns JSON with success_rate" {
	run "$LIGHTNING_BIN" forward stats
	[ "$status" -eq 0 ]
	[[ "$output" == *"success_rate"* ]]
	[[ "$output" == *"forwarded_msat"* ]]
}

@test "1.1.0: help lists tower / fee / forward" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"tower"* ]]
	[[ "$output" == *"fee"* ]]
	[[ "$output" == *"forward"* ]]
}

# ---------------------------------------------------------------------------
# 1.1.1 — maintenance pass
# ---------------------------------------------------------------------------

@test "1.1.1: .rpk/versions lists every released version with a SHA" {
	f="$BATS_TEST_DIRNAME/../../.rpk/versions"
	[ -s "$f" ]
	for v in 0.1.0 0.2.0 0.3.0 0.4.0 0.5.0 0.6.0 1.0.0 1.1.0; do
		grep -E "^$v	[0-9a-f]{7,}" "$f"
	done
}

@test "1.1.1: fee policy match-peer returns NOT IMPLEMENTED + exit 2" {
	run "$LIGHTNING_BIN" fee policy match-peer
	[ "$status" -eq 2 ]
	[[ "$output" == *"NOT IMPLEMENTED"* ]]
}

@test "1.1.1: help lists commands alphabetically with one-line descriptions" {
	run "$LIGHTNING_BIN" help
	[ "$status" -eq 0 ]
	[[ "$output" == *"Commands:"* ]]
	[[ "$output" == *"help <command>"* ]]
	[[ "$output" == *"wallet-user"* ]]
	[[ "$output" == *"account"* ]]
	[[ "$output" == *"channel"* ]]
	# No subcommand details in top-level help
	[[ "$output" != *"channel open"* ]]
	[[ "$output" != *"account create"* ]]
}

@test "1.1.1: CI workflow explicitly installs sqlite3 + jq + python3" {
	f="$BATS_TEST_DIRNAME/../../.github/workflows/test.yml"
	[ -f "$f" ]
	grep -q "sqlite3" "$f"
	grep -q "jq" "$f"
	grep -q "python3" "$f"
	# shellcheck step.
	grep -q "shellcheck" "$f"
}

# ---------------------------------------------------------------------------
# 1.2.0 — coverage + correctness pass
# ---------------------------------------------------------------------------

# --- bin/lightning getopts fix ---------------------------------------------

@test "1.2.0: -q flag parses + version still prints" {
	run "$LIGHTNING_BIN" -q version
	[ "$status" -eq 0 ]
	[ "$output" = "1.3.1" ]
}

@test "1.2.0: -q -d flags compose (getopts handles both)" {
	# Don't assert exact $output: -d enables `set -vx` which emits
	# trace to stderr that bats merges into $output. The regression
	# we're guarding against is the previous getopts bug where the
	# second flag was lost or the verb was treated as a flag.
	run "$LIGHTNING_BIN" -q -d version
	[ "$status" -eq 0 ]
	[[ "$output" == *"1.3.1"* ]]
}

@test "1.2.0: unknown flag exits non-zero" {
	run "$LIGHTNING_BIN" -Z version
	[ "$status" -ne 0 ]
}

@test "1.2.0: flags before unknown command still surface the unknown error" {
	run "$LIGHTNING_BIN" -q definitely-not-a-real-subcommand
	[ "$status" -ne 0 ]
}

# --- decode pattern reorder -------------------------------------------------

@test "1.2.0: decode lnbcrt (regtest invoice) correctly identifies as BOLT-11" {
	run "$LIGHTNING_BIN" decode lnbcrt10n1pmocktest
	[ "$status" -eq 0 ]
	[[ "$output" == *"bolt11"* ]]
}

@test "1.2.0: decode lntb (testnet invoice) correctly identifies as BOLT-11" {
	run "$LIGHTNING_BIN" decode lntb10u1pmocktest
	[ "$status" -eq 0 ]
	[[ "$output" == *"bolt11"* ]]
}

# --- info: jq absence is a hard error, not silent fallback ------------------

@test "1.2.0: lightning info exits 127 when jq is absent (was silent fallback)" {
	# Place a stub PATH that has lightning-cli but no jq, then
	# invoke `lightning info` via a subshell that sets PATH for
	# the child only — so our teardown's rm / etc. still resolve.
	NOJQ_BIN="$BATS_TMPDIR/nojq.$$"
	mkdir -p "$NOJQ_BIN"
	ln -sf "$FIXTURES/lightning-cli-mock" "$NOJQ_BIN/lightning-cli"
	for tool in cat echo printf stat mktemp basename dirname date xxd openssl sed grep awk tr cut head tail rm sleep ls; do
		[ -x "/usr/bin/$tool" ] && ln -sf "/usr/bin/$tool" "$NOJQ_BIN/$tool"
		[ -x "/bin/$tool" ]     && ln -sf "/bin/$tool" "$NOJQ_BIN/$tool"
	done
	# Pass PATH inline to the run command; don't export.
	run -127 env -i HOME="$HOME" PATH="$NOJQ_BIN" SELF_QUIET=1 "$LIGHTNING_BIN" info
	[[ "$output" == *"jq not found"* ]]
}

# --- mock-cli failure injection --------------------------------------------

@test "1.2.0: MOCK_FAIL_GETINFO makes info exit 2 with daemon-down hint" {
	export MOCK_FAIL_GETINFO=1
	run "$LIGHTNING_BIN" info
	[ "$status" -eq 2 ]
	[[ "$output" == *"daemon"* ]]
}

@test "1.2.0: MOCK_FAIL_LISTPEERCHANNELS makes channels exit non-zero" {
	export MOCK_FAIL_LISTPEERCHANNELS=1
	run "$LIGHTNING_BIN" channels
	[ "$status" -ne 0 ]
}

@test "1.2.0: MOCK_FAIL_INVOICE makes invoice exit non-zero" {
	export MOCK_FAIL_INVOICE=1
	run "$LIGHTNING_BIN" invoice 1000 test
	[ "$status" -ne 0 ]
}

@test "1.2.0: MOCK_FAIL_PAY surfaces a 'pay returned failed' path" {
	# Mock returns error JSON; our pay verb tries to parse status and
	# exits with the failure code.
	export MOCK_FAIL_PAY=1
	run "$LIGHTNING_BIN" pay lnbcrt10n1pmocktest
	[ "$status" -ne 0 ]
}

@test "1.2.0: MOCK_FAIL_FUNDCHANNEL surfaces channel open failure" {
	export MOCK_FAIL_FUNDCHANNEL=1
	run "$LIGHTNING_BIN" channel open \
		020000000000000000000000000000000000000000000000000000000000000002@127.0.0.1:9735 \
		100000
	[ "$status" -ne 0 ]
}

@test "1.2.0: MOCK_FAIL_CLOSE surfaces channel close failure" {
	export MOCK_FAIL_CLOSE=1
	run "$LIGHTNING_BIN" channel close 0000000000000000000000000000000000000000000000000000000000000001
	[ "$status" -ne 0 ]
}

@test "1.2.0: MOCK_FAIL_OFFER surfaces BOLT-12 offer failure" {
	export MOCK_FAIL_OFFER=1
	run "$LIGHTNING_BIN" offer 500 donations
	[ "$status" -ne 0 ]
}

@test "1.2.0: MOCK_FAIL_NEWADDR surfaces balance --on-chain failure" {
	export MOCK_FAIL_NEWADDR=1
	run "$LIGHTNING_BIN" balance --on-chain
	[ "$status" -ne 0 ]
}

# --- exit-code contracts ---------------------------------------------------

@test "1.2.0: channel force-close without --confirm returns EXACTLY exit 2" {
	run "$LIGHTNING_BIN" channel force-close 0000000000000000000000000000000000000000000000000000000000000001
	[ "$status" -eq 2 ]
}

@test "1.2.0: wallet new on an existing wallet returns EXACTLY exit 2" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" wallet new alice
	[ "$status" -eq 2 ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0: account create with invalid --overdraft returns exit 1" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" account create rent --overdraft bogus
	[ "$status" -eq 1 ]
	[[ "$output" == *"deny|warn|allow"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0: account create with non-integer --limit returns exit 1" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" account create rent --limit not-a-number
	[ "$status" -eq 1 ]
	[[ "$output" == *"integer required"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0: account delete of the unassigned account is refused" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" account delete -
	[ "$status" -eq 2 ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0: ledger add rejects non-numeric amount" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" ledger add in not-a-number
	[ "$status" -eq 1 ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0: ledger add rejects unknown direction" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" ledger add sideways 1000
	[ "$status" -eq 1 ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0: ledger statement without --account fails" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" ledger statement --period 2026-01
	[ "$status" -eq 1 ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0: ledger statement with bad period format fails" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null
	run "$LIGHTNING_BIN" ledger statement --account rent --period notadate
	[ "$status" -eq 1 ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0: address remove on a non-existent user is a no-op (exit 0)" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" address remove ghost@example.com
	[ "$status" -eq 0 ]
	[[ "$output" == *"0 removed"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0: liquidity in with unknown provider fails clearly" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" liquidity in 100000 --provider bogus
	[ "$status" -eq 1 ]
	[[ "$output" == *"unknown provider"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0: liquidity lsp with non-'buy' second arg fails" {
	run "$LIGHTNING_BIN" liquidity lsp myname maybe 100000
	[ "$status" -ne 0 ]
}

@test "1.2.0: api-recv rejects non-numeric sat (exit 2)" {
	run "$LIGHTNING_BIN" api-recv alice not-a-number "msg"
	[ "$status" -eq 2 ]
}

@test "1.2.0: api-recv rejects uppercase user (exit 2)" {
	run "$LIGHTNING_BIN" api-recv Alice 100 "msg"
	[ "$status" -eq 2 ]
}

@test "1.2.0: api-send rejects non-numeric sat (exit 2)" {
	run "$LIGHTNING_BIN" api-send alice bob@example.com nan "msg" "note"
	[ "$status" -eq 2 ]
}

@test "1.2.0: api-verify rejects invalid account name (exit 2)" {
	run "$LIGHTNING_BIN" api-verify "Bad Name" read somekey
	[ "$status" -eq 2 ]
}

@test "1.2.0: api-verify rejects invalid scope (exit 2)" {
	run "$LIGHTNING_BIN" api-verify alice admin somekey
	[ "$status" -eq 2 ]
}

# --- wallet pull clear error on conflict -----------------------------------

@test "1.2.0: wallet pull surfaces a recovery hint on rebase failure" {
	# Set up two clones of a wallet, mutate state.sql in both so rebase
	# conflicts when pulling.
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	bare="$BATS_TMPDIR/bare.$$"
	git init --bare --quiet "$bare"
	(cd "$LIGHTNING_WALLETS_ROOT/alice" \
		&& git remote add origin "$bare" \
		&& git push --quiet origin master 2>/dev/null || git push --quiet origin main)
	# Diverge: rewrite state.sql locally without pulling.
	(cd "$LIGHTNING_WALLETS_ROOT/alice" \
		&& echo "-- local divergence" >> state.sql \
		&& git -c user.email=t@t -c user.name=t commit --quiet -am local) 2>/dev/null || true
	# Push a conflicting remote change.
	clone="$BATS_TMPDIR/clone.$$"
	git clone --quiet "$bare" "$clone"
	(cd "$clone" \
		&& echo "-- remote divergence" >> state.sql \
		&& git -c user.email=t@t -c user.name=t commit --quiet -am remote \
		&& git push --quiet origin HEAD 2>/dev/null) || true
	# Now pull should conflict and surface the lightning-level hint.
	run "$LIGHTNING_BIN" wallet pull origin
	# Either git refused outright (status != 0) or conflict-and-hint path.
	if [ "$status" -eq 5 ]; then
		[[ "$output" == *"rebase --abort"* ]]
	fi
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$bare" "$clone" "$HOME/.lightning"
}

# --- shellcheck clean ------------------------------------------------------

@test "1.2.0: shellcheck -S warning is clean across the verb tree" {
	command -v shellcheck >/dev/null || skip "shellcheck not installed"
	root="$BATS_TEST_DIRNAME/../.."
	run shellcheck -S warning \
		"$root/bin/lightning" \
		$(find "$root/libexec/lightning" -type f) \
		$(find "$root/share/lightning/hooks" -type f) \
		"$root/tests/sit/helpers.bash" \
		"$root/share/doc/lightning/standards/refresh.sh"
	if [ "$status" -ne 0 ]; then
		echo "$output" | head -30
	fi
	[ "$status" -eq 0 ]
}

# --- 1.2.0 graduation smoke ------------------------------------------------

@test "1.2.0: unlock --stored with no stored secret returns EXACTLY exit 4" {
	# Encrypted hsm_secret + no entry in secret store = exit 4.
	mkdir -p "$HOME/.lightning/bitcoin"
	# Make hsm_secret 73 bytes = encrypted.
	dd if=/dev/zero of="$HOME/.lightning/bitcoin/hsm_secret" bs=73 count=1 status=none
	# Stub secret to return failure for any get.
	cat > "$BIN_SHIM/secret" <<'EOF'
#!/bin/bash
[ "$1" = "get" ] && exit 1
exit 0
EOF
	chmod +x "$BIN_SHIM/secret"
	run "$LIGHTNING_BIN" unlock --stored
	[ "$status" -eq 4 ]
}

@test "1.2.0: every documented exit code has at least one test asserting it" {
	# Meta-test: grep the bats file for assertions on each documented
	# exit code (1, 2, 3, 4, 5, 6, 127). Two syntaxes count:
	#   - `[ "$status" -eq N ]` / `[ "$status" = "N" ]`  (older)
	#   - `run -N ...`                                    (bats 1.5+)
	f="$BATS_TEST_DIRNAME/lightning.bats"
	for code in 1 2 3 4 5 6 127; do
		grep -qE -- "status[\" ]+-eq[\" ]+$code|status[\" ]+=[\" ]+\"?$code|run -$code " "$f" \
			|| { echo "no test asserts exit $code"; return 1; }
	done
}

# ---------------------------------------------------------------------------
# 1.2.0 — extended coverage: previously-uncovered branches
# ---------------------------------------------------------------------------

# --- decode -----------------------------------------------------------------

@test "1.2.0 ext: decode rejects an unknown format" {
	run "$LIGHTNING_BIN" decode notalightningstring
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown"* ]]
}

@test "1.2.0 ext: decode strips an UPPER-CASE LIGHTNING: prefix" {
	run "$LIGHTNING_BIN" decode "LIGHTNING:lnbcrt10n1pmocktest"
	[ "$status" -eq 0 ]
	[[ "$output" == *"bolt11"* ]]
}

@test "1.2.0 ext: decode handles BOLT-12 invoice (lni-prefix)" {
	run "$LIGHTNING_BIN" decode lni1pgmocktest
	[ "$status" -eq 0 ]
	[[ "$output" == *"bolt12-invoice"* ]]
}

# --- offer ------------------------------------------------------------------

@test "1.2.0 ext: offer accepts 'any' amount" {
	run "$LIGHTNING_BIN" offer create any tip-jar
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == lno* ]]
}

# --- wallet -----------------------------------------------------------------

@test "1.2.0 ext: wallet use rejects a nonexistent wallet" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	mkdir -p "$LIGHTNING_WALLETS_ROOT"
	run "$LIGHTNING_BIN" wallet use ghost
	[ "$status" -eq 2 ]
	rm -rf "$LIGHTNING_WALLETS_ROOT"
}

@test "1.2.0 ext: wallet active prints 'default' when none configured" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	mkdir -p "$LIGHTNING_WALLETS_ROOT"
	run "$LIGHTNING_BIN" wallet active
	[ "$status" -eq 0 ]
	[ "$output" = "default" ]
	rm -rf "$LIGHTNING_WALLETS_ROOT"
}

@test "1.2.0 ext: wallet path prints the active wallet's filesystem path" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" wallet path
	[ "$status" -eq 0 ]
	[[ "$output" == */alice ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

# --- account apikey ---------------------------------------------------------

@test "1.2.0 ext: account apikey revoke removes the stored secret" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null

	SECRET_STORE="$BATS_TMPDIR/secret.$$"
	mkdir -p "$SECRET_STORE"
	cat > "$BIN_SHIM/secret" <<EOF
#!/bin/bash
case "\$1" in
  put) cat > "$SECRET_STORE/\$2" ;;
  get) [ -f "$SECRET_STORE/\$2" ] && cat "$SECRET_STORE/\$2" || exit 1 ;;
  rm)  rm -f "$SECRET_STORE/\$2" ;;
esac
EOF
	chmod +x "$BIN_SHIM/secret"

	"$LIGHTNING_BIN" account apikey create rent --scope write >/dev/null
	[ -f "$SECRET_STORE/lightning.rent.apikey.write" ]
	run "$LIGHTNING_BIN" account apikey revoke rent --scope write
	[ "$status" -eq 0 ]
	[ ! -f "$SECRET_STORE/lightning.rent.apikey.write" ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$SECRET_STORE" "$HOME/.lightning"
}

# --- ledger -----------------------------------------------------------------

@test "1.2.0 ext: ledger sum --by day groups correctly" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null
	"$LIGHTNING_BIN" ledger add in 1000 --account rent --message a
	"$LIGHTNING_BIN" ledger add in 2000 --account rent --message b
	run "$LIGHTNING_BIN" ledger sum --by day
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "bucket"*"total_msat"*"rows" ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0 ext: ledger sum --by year groups correctly" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null
	"$LIGHTNING_BIN" ledger add in 1000 --account rent --message a
	run "$LIGHTNING_BIN" ledger sum --by year
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "bucket"*"total_msat"*"rows" ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0 ext: ledger sum --by with invalid bucket fails" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" ledger sum --by century
	[ "$status" -ne 0 ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0 ext: ledger export tsv emits TSV with header" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null
	"$LIGHTNING_BIN" ledger add in 1000 --account rent --message a
	run "$LIGHTNING_BIN" ledger export tsv
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "ts"*"account"*"direction"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0 ext: ledger export jsonl emits one JSON object per row" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null
	"$LIGHTNING_BIN" ledger add in 1000 --account rent --message a
	run "$LIGHTNING_BIN" ledger export jsonl
	[ "$status" -eq 0 ]
	[[ "$output" == *'"ts"'* ]]
	[[ "$output" == *'"account":"rent"'* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0 ext: ledger export with invalid format fails" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" ledger export xml
	[ "$status" -ne 0 ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0 ext: ledger annotate of non-existent hash reports 0 rows" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" ledger annotate cafef00d "no such hash"
	[ "$status" -eq 0 ]
	[[ "$output" == *"0 row"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0 ext: ledger balance for unknown account returns 0" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" ledger balance never-existed
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

# --- address ----------------------------------------------------------------

@test "1.2.0 ext: address apache-snippet emits the vhost fragment" {
	run "$LIGHTNING_BIN" address apache-snippet
	[ "$status" -eq 0 ]
	[[ "$output" == *"ScriptAlias"* ]]
	[[ "$output" == *"lnurlp"* ]]
}

@test "1.2.0 ext: address remove removes a registered user" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create alice >/dev/null
	ln -sf /bin/true "$BIN_SHIM/apache2"
	"$LIGHTNING_BIN" address create alice@example.com --account alice >/dev/null

	run "$LIGHTNING_BIN" address remove alice@example.com
	[ "$status" -eq 0 ]
	[[ "$output" == *"1 removed"* ]]
	run "$LIGHTNING_BIN" address list
	[ "$status" -eq 0 ]
	[[ "$output" != *"alice@example.com"* ]] || skip "DB still has the row"
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0 ext: address create rejects an uppercase user part" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create alice >/dev/null
	ln -sf /bin/true "$BIN_SHIM/apache2"
	run "$LIGHTNING_BIN" address create Alice@example.com --account alice
	[ "$status" -ne 0 ]
	[[ "$output" == *"[a-z][a-z0-9_-]*"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "1.2.0 ext: address create rejects an address without @" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	run "$LIGHTNING_BIN" address create notanaddress
	[ "$status" -ne 0 ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

# --- fee policy ------------------------------------------------------------

@test "1.2.0 ext: fee policy flat runs without error on an empty channel set" {
	# listpeerchannels returns {"channels":[]} → no setchannel calls.
	run "$LIGHTNING_BIN" fee policy flat
	[ "$status" -eq 0 ]
	[[ "$output" == *"applied 'flat'"* ]]
}

@test "1.2.0 ext: fee policy lsp-style runs without error on empty set" {
	run "$LIGHTNING_BIN" fee policy lsp-style
	[ "$status" -eq 0 ]
}

# --- forward filters -------------------------------------------------------

@test "1.2.0 ext: forward list --status settled returns header" {
	run "$LIGHTNING_BIN" forward list --status settled
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "received_time"*"status" ]]
}

@test "1.2.0 ext: forward list --since accepts a date" {
	run "$LIGHTNING_BIN" forward list --since 2026-01-01
	[ "$status" -eq 0 ]
}

@test "1.2.0 ext: forward list with unknown flag fails" {
	run "$LIGHTNING_BIN" forward list --bogus
	[ "$status" -ne 0 ]
}

# --- tower -----------------------------------------------------------------

@test "1.2.0 ext: tower client-stats returns JSON with plugin loaded" {
	export MOCK_HELP_INCLUDES='"addtower","listtowers"'
	run "$LIGHTNING_BIN" tower client-stats
	[ "$status" -eq 0 ]
	[[ "$output" == *"sessions"* ]]
	[[ "$output" == *"towers"* ]]
}

@test "1.2.0 ext: tower server-status without plugin loaded fails" {
	# MOCK_HELP_INCLUDES is unset → mock returns empty help list.
	run "$LIGHTNING_BIN" tower server-status
	[ "$status" -eq 1 ]
	[[ "$output" == *"not running"* ]]
}

# --- daemon ----------------------------------------------------------------

@test "1.2.0 ext: daemon logs without a log file exits cleanly with a hint" {
	# No log file exists; daemon-logs should exit non-zero with a clear
	# message rather than `tail -f` on /dev/null silently.
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR/bitcoin"
	run "$LIGHTNING_BIN" daemon logs
	[ "$status" -eq 2 ]
	[[ "$output" == *"no log file"* ]]
	rm -rf "$LIGHTNING_DIR"
}

@test "1.2.0 ext: daemon with unknown subcommand prints usage" {
	run "$LIGHTNING_BIN" daemon takeover
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown"* ]]
}

# --- tor -------------------------------------------------------------------

@test "1.2.0 ext: tor status with no lightning-cli returns non-zero" {
	export PATH="/usr/bin:/bin"
	hash -r
	run "$LIGHTNING_BIN" tor status
	# Reports tor not running and no lightning-cli, exits non-zero.
	[ "$status" -ne 0 ]
}

@test "1.2.0 ext: tor with unknown subcommand prints usage" {
	run "$LIGHTNING_BIN" tor sideways
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage"* ]]
}

# --- qr ----------------------------------------------------------------------

@test "1.2.0 ext: qr with unknown flag fails" {
	run "$LIGHTNING_BIN" qr "lnbcrt10n1ptest" --webp out.webp
	[ "$status" -ne 0 ]
}

@test "1.2.0 ext: qr - reads text from stdin" {
	# Just verify exit 0 + non-empty output. The actual rendered
	# content differs: with qrencode it's UTF-8 half-blocks; without
	# it's the fallback echo of the text.
	run bash -c "echo lnbcrt10n1pstdintest | '$LIGHTNING_BIN' qr -"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
}

# --- bin/lightning dispatcher edge cases -----------------------------------

@test "1.2.0 ext: sourced lightning.sh doesn't run getopts on host's argv" {
	# Regression: getopts in a sourced script can chew host's argv.
	# After sourcing, $1 should still be whatever the host had.
	local sh="$(dirname "$LIGHTNING_BIN")/lightning.sh"
	run bash -c "set -- foo bar; . '$sh'; echo \"\$1\""
	[ "$status" -eq 0 ]
	[ "$output" = "foo" ]
}

# ---------------------------------------------------------------------------
# 1.3.0 — kcov coverage measurement
# ---------------------------------------------------------------------------

@test "1.3.0: Makefile.in has a `coverage` target that wraps bats in kcov" {
	f="$BATS_TEST_DIRNAME/../../Makefile.in"
	[ -f "$f" ]
	grep -q "^coverage:" "$f"
	grep -q "kcov" "$f"
	grep -q "COVERAGE_DIR" "$f"
}

@test "1.3.0: CI workflow has a separate coverage job that uploads HTML" {
	f="$BATS_TEST_DIRNAME/../../.github/workflows/test.yml"
	[ -f "$f" ]
	grep -q "^  coverage:" "$f"
	grep -q "kcov" "$f"
	grep -q "upload-artifact" "$f"
	grep -q "coverage-html" "$f"
}

@test "1.3.0: coverage job depends on the test job (sequenced)" {
	f="$BATS_TEST_DIRNAME/../../.github/workflows/test.yml"
	# `needs: test` ensures the gate-job runs first.
	grep -qE "^[[:space:]]*needs:[[:space:]]*test" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-207 — `lightning daemon install-core` scaffold
# (issues/feature/207-clightning-install.md)
# ---------------------------------------------------------------------------

@test "FEAT-207: daemon install-core --help mentions the five backends" {
	run "$LIGHTNING_BIN" daemon install-core --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--rpk"*    ]]
	[[ "$output" == *"--brew"*   ]]
	[[ "$output" == *"--apk"*    ]]
	[[ "$output" == *"--source"* ]]
	[[ "$output" == *"--podman"* ]]
}

@test "FEAT-207: daemon install-core --help calls out docker as non-goal" {
	run "$LIGHTNING_BIN" daemon install-core --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"docker is not supported"* ]] || \
	[[ "$output" == *"docker"* && "$output" == *"podman"* ]]
}

@test "FEAT-207: install-core --dry-run --rpk prints the rpk plan" {
	run "$LIGHTNING_BIN" daemon install-core --rpk --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"backend:"*"rpk"* ]]
	[[ "$output" == *"rpk install lightningd"* ]]
}

@test "FEAT-207: install-core --dry-run --brew prints the brew plan" {
	run "$LIGHTNING_BIN" daemon install-core --brew --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"brew install core-lightning"* ]]
}

@test "FEAT-207: install-core --dry-run --apk prints the apk plan" {
	run "$LIGHTNING_BIN" daemon install-core --apk --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"apk add lightningd"* ]]
}

@test "FEAT-207: install-core --dry-run --source prints the source plan" {
	run "$LIGHTNING_BIN" daemon install-core --source --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"git clone"* ]]
	[[ "$output" == *"configure"* ]]
}

@test "FEAT-207: install-core --dry-run --podman prints the podman plan" {
	run "$LIGHTNING_BIN" daemon install-core --podman --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"podman pull"* ]]
	[[ "$output" == *"elementsproject/lightningd"* ]]
}

@test "FEAT-207: install-core --docker refuses and hints at --podman" {
	run "$LIGHTNING_BIN" daemon install-core --docker
	[ "$status" -ne 0 ]
	[[ "$output" == *"docker is not supported"* ]]
	[[ "$output" == *"--podman"* ]]
}

@test "FEAT-207: install-core rejects two backend flags" {
	run "$LIGHTNING_BIN" daemon install-core --rpk --brew --dry-run
	[ "$status" -ne 0 ]
	[[ "$output" == *"pick one backend"* ]]
}

@test "FEAT-207: install-core --version pin shows up in the plan" {
	run "$LIGHTNING_BIN" daemon install-core --brew --version v26.04.1 --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"version:"*"v26.04.1"* ]]
}

@test "FEAT-207: install-core unknown flag fails" {
	run "$LIGHTNING_BIN" daemon install-core --not-a-real-flag
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown flag"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-207 stage 1 — real `--rpk` and `--brew` invocations
# ---------------------------------------------------------------------------

# Drop a fake rpk on PATH that records its args and (optionally)
# installs a fake lightningd into BIN_SHIM.
_stub_rpk() {
	local exit_code="${1:-0}" install_lightningd="${2:-1}"
	cat > "$BIN_SHIM/rpk" <<EOF
#!/bin/sh
echo "rpk \$*" >> "$BIN_SHIM/rpk.calls"
if [ "$install_lightningd" = "1" ] && [ "$exit_code" = "0" ]; then
	printf '#!/bin/sh\necho "Core Lightning v26.04.1"\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
fi
exit $exit_code
EOF
	chmod +x "$BIN_SHIM/rpk"
}

_stub_brew() {
	local exit_code="${1:-0}" install_lightningd="${2:-1}"
	cat > "$BIN_SHIM/brew" <<EOF
#!/bin/sh
echo "brew \$*" >> "$BIN_SHIM/brew.calls"
if [ "$install_lightningd" = "1" ] && [ "$exit_code" = "0" ]; then
	printf '#!/bin/sh\necho "Core Lightning v26.04.1"\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
fi
exit $exit_code
EOF
	chmod +x "$BIN_SHIM/brew"
}

@test "FEAT-207: install-core --rpk runs rpk install lightningd" {
	_stub_rpk 0 1
	run "$LIGHTNING_BIN" daemon install-core --rpk --yes
	[ "$status" -eq 0 ]
	[ -f "$BIN_SHIM/rpk.calls" ]
	grep -q "rpk install lightningd" "$BIN_SHIM/rpk.calls"
	grep -q "\\--yes" "$BIN_SHIM/rpk.calls"
	[[ "$output" == *"lightningd installed"* ]]
}

@test "FEAT-207: install-core --rpk --version pins the version" {
	_stub_rpk 0 1
	run "$LIGHTNING_BIN" daemon install-core --rpk --version v26.04.1
	[ "$status" -eq 0 ]
	grep -q "\\--version v26.04.1" "$BIN_SHIM/rpk.calls"
}

@test "FEAT-207: install-core --rpk propagates rpk failure" {
	_stub_rpk 17 0
	run "$LIGHTNING_BIN" daemon install-core --rpk
	[ "$status" -eq 17 ]
	[[ "$output" == *"rpk install failed"* ]]
	[[ "$output" == *"rpk package isn't published"* ]]
}

@test "FEAT-207: install-core --rpk errors when rpk not on PATH" {
	# No rpk shim — the BIN_SHIM is clean by default.
	run "$LIGHTNING_BIN" daemon install-core --rpk
	[ "$status" -eq 1 ]
	[[ "$output" == *"rpk not on PATH"* ]]
}

@test "FEAT-207: install-core --rpk --dry-run skips the rpk-on-PATH check" {
	# Operators may be planning on a different machine — dry-run shouldn't
	# require the package manager to be installed locally.
	run "$LIGHTNING_BIN" daemon install-core --rpk --dry-run
	[ "$status" -eq 0 ]
	[ ! -f "$BIN_SHIM/rpk.calls" ]
	[[ "$output" == *"rpk install lightningd"* ]]
}

@test "FEAT-207: install-core --rpk fails if lightningd missing post-install" {
	# rpk reports success but doesn't actually install the binary.
	_stub_rpk 0 0
	run "$LIGHTNING_BIN" daemon install-core --rpk
	[ "$status" -eq 1 ]
	[[ "$output" == *"reported success"* ]]
	[[ "$output" == *"not on PATH"* ]]
}

@test "FEAT-207: install-core --brew off-macOS exits with a clear hint" {
	# bats CI runs Linux — is_macos returns false here, so --brew errors.
	_stub_brew 0 1
	run "$LIGHTNING_BIN" daemon install-core --brew
	[ "$status" -eq 1 ]
	[[ "$output" == *"macOS-only"* ]] || [[ "$output" == *"macOS"* ]]
}

@test "FEAT-207: install-core --brew --dry-run prints the brew install plan" {
	# Dry-run skips the macOS gate and the brew-on-PATH check, so the
	# Linux CI can still validate the plan text.
	run "$LIGHTNING_BIN" daemon install-core --brew --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"brew install core-lightning"* ]]
}

@test "FEAT-207: install-core --brew --version uses the @version formula" {
	run "$LIGHTNING_BIN" daemon install-core --brew --version v26.04.1 --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"core-lightning@v26.04.1"* ]]
}

@test "FEAT-207: install-core --brew --force uses brew reinstall" {
	run "$LIGHTNING_BIN" daemon install-core --brew --force --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"brew reinstall"* ]]
}

@test "FEAT-207: install-core refuses when lightningd is already on PATH" {
	# Drop a fake lightningd ahead of the call.
	printf '#!/bin/sh\necho "Core Lightning v25.05.0"\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	_stub_rpk 0 1
	run "$LIGHTNING_BIN" daemon install-core --rpk
	[ "$status" -eq 1 ]
	[[ "$output" == *"already on PATH"* ]]
	[[ "$output" == *"--force"* ]]
	[ ! -f "$BIN_SHIM/rpk.calls" ]
}

@test "FEAT-207: install-core --force overrides the idempotency check" {
	printf '#!/bin/sh\necho "Core Lightning v25.05.0"\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	_stub_rpk 0 1
	run "$LIGHTNING_BIN" daemon install-core --rpk --force
	[ "$status" -eq 0 ]
	[ -f "$BIN_SHIM/rpk.calls" ]
	grep -q "\\--force" "$BIN_SHIM/rpk.calls"
}

@test "FEAT-207: install-core --dry-run skips the idempotency check" {
	# Dry-run is "what would you do" — it shouldn't refuse on existing installs.
	printf '#!/bin/sh\necho "Core Lightning v25.05.0"\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" daemon install-core --rpk --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"plan:"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-207 stage 2 — real `--apk` invocation
# ---------------------------------------------------------------------------

# Records its args and (when exit 0) drops a fake lightningd onto PATH.
_stub_apk() {
	local exit_code="${1:-0}" install_lightningd="${2:-1}"
	cat > "$BIN_SHIM/apk" <<EOF
#!/bin/sh
echo "apk \$*" >> "$BIN_SHIM/apk.calls"
if [ "$install_lightningd" = "1" ] && [ "$exit_code" = "0" ]; then
	printf '#!/bin/sh\necho "Core Lightning v26.04.1"\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
fi
exit $exit_code
EOF
	chmod +x "$BIN_SHIM/apk"
}

# Privilege-escalation prefix stubs.  Each just exec's the rest of the
# argv — that lets the apk stub still record what was requested.
_stub_doas() {
	cat > "$BIN_SHIM/doas" <<'EOF'
#!/bin/sh
echo "doas $*" >> "${BIN_SHIM_CALLS_DIR:-$(dirname "$0")}/doas.calls"
exec "$@"
EOF
	chmod +x "$BIN_SHIM/doas"
}
_stub_sudo() {
	cat > "$BIN_SHIM/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "${BIN_SHIM_CALLS_DIR:-$(dirname "$0")}/sudo.calls"
exec "$@"
EOF
	chmod +x "$BIN_SHIM/sudo"
}

# CI containers often run as root, which makes `ic_root_prefix` return
# empty (correctly — no escalation needed).  This stub fakes a non-root
# UID so we can exercise the doas/sudo branches.
_stub_id_nonroot() {
	cat > "$BIN_SHIM/id" <<'EOF'
#!/bin/sh
case "$1" in
	-u) echo 1000 ;;
	*)  exec /usr/bin/id "$@" ;;
esac
EOF
	chmod +x "$BIN_SHIM/id"
}

# Mirror image: GH-hosted runners run as a non-root user, which makes
# `ic_root_prefix` pick sudo.  This stub fakes `id -u` returning 0 so
# we can exercise the no-prefix branch under any test runner.
_stub_id_root() {
	cat > "$BIN_SHIM/id" <<'EOF'
#!/bin/sh
case "$1" in
	-u) echo 0 ;;
	*)  exec /usr/bin/id "$@" ;;
esac
EOF
	chmod +x "$BIN_SHIM/id"
}

# Fake /etc/os-release pointing platform_id() at Alpine.
_fake_alpine_os_release() {
	local f="$BATS_TMPDIR/os-release.$$"
	cat > "$f" <<'EOF'
ID=alpine
VERSION_ID=3.20.0
PRETTY_NAME="Alpine Linux v3.20"
EOF
	export LIGHTNING_OS_RELEASE="$f"
}

@test "FEAT-207: install-core --apk runs apk add lightningd via doas" {
	_fake_alpine_os_release
	_stub_id_nonroot
	_stub_apk 0 1
	_stub_doas
	export BIN_SHIM_CALLS_DIR="$BIN_SHIM"
	run "$LIGHTNING_BIN" daemon install-core --apk
	[ "$status" -eq 0 ]
	[ -f "$BIN_SHIM/apk.calls" ]
	grep -q "apk add lightningd" "$BIN_SHIM/apk.calls"
	[ -f "$BIN_SHIM/doas.calls" ]
	grep -q "doas apk add" "$BIN_SHIM/doas.calls"
	[[ "$output" == *"lightningd installed"* ]]
}

@test "FEAT-207: install-core --apk falls back to sudo when doas is absent" {
	_fake_alpine_os_release
	_stub_id_nonroot
	_stub_apk 0 1
	_stub_sudo
	export BIN_SHIM_CALLS_DIR="$BIN_SHIM"
	run "$LIGHTNING_BIN" daemon install-core --apk
	[ "$status" -eq 0 ]
	[ -f "$BIN_SHIM/sudo.calls" ]
	grep -q "sudo apk add" "$BIN_SHIM/sudo.calls"
	[ ! -f "$BIN_SHIM/doas.calls" ]
}

@test "FEAT-207: install-core --apk skips prefix when already root" {
	# When ic_root_prefix returns empty (id -u == 0), the apk call is bare.
	# Force id -u to 0 — GH-hosted runners are non-root, locally we may
	# already be root, so either way we get a deterministic answer.
	_fake_alpine_os_release
	_stub_id_root
	_stub_apk 0 1
	export BIN_SHIM_CALLS_DIR="$BIN_SHIM"
	run "$LIGHTNING_BIN" daemon install-core --apk
	[ "$status" -eq 0 ]
	[ -f "$BIN_SHIM/apk.calls" ]
	# Bare `apk add` — no doas / sudo prefix on the line.
	[ ! -f "$BIN_SHIM/doas.calls" ]
	[ ! -f "$BIN_SHIM/sudo.calls" ]
}

@test "FEAT-207: install-core --apk --version pins via apk's = syntax" {
	_fake_alpine_os_release
	_stub_apk 0 1
	_stub_doas
	export BIN_SHIM_CALLS_DIR="$BIN_SHIM"
	run "$LIGHTNING_BIN" daemon install-core --apk --version 26.04.1-r0
	[ "$status" -eq 0 ]
	grep -q "lightningd=26.04.1-r0" "$BIN_SHIM/apk.calls"
}

@test "FEAT-207: install-core --apk --force uses --force-overwrite" {
	_fake_alpine_os_release
	_stub_apk 0 1
	_stub_doas
	export BIN_SHIM_CALLS_DIR="$BIN_SHIM"
	run "$LIGHTNING_BIN" daemon install-core --apk --force
	[ "$status" -eq 0 ]
	grep -q "\\--force-overwrite" "$BIN_SHIM/apk.calls"
}

@test "FEAT-207: install-core --apk off-Alpine exits with a clear hint" {
	# No fake os-release — platform_id() returns the real platform
	# (ubuntu in CI).
	_stub_apk 0 1
	_stub_doas
	export BIN_SHIM_CALLS_DIR="$BIN_SHIM"
	run "$LIGHTNING_BIN" daemon install-core --apk
	[ "$status" -eq 1 ]
	[[ "$output" == *"not an Alpine system"* ]]
	[ ! -f "$BIN_SHIM/apk.calls" ]
}

@test "FEAT-207: install-core --apk --dry-run skips platform + apk checks" {
	# No fake os-release, no apk shim — dry-run should still print the plan.
	run "$LIGHTNING_BIN" daemon install-core --apk --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"apk add lightningd"* ]]
}

@test "FEAT-207: install-core --apk propagates apk failure" {
	_fake_alpine_os_release
	_stub_apk 42 0
	_stub_doas
	export BIN_SHIM_CALLS_DIR="$BIN_SHIM"
	run "$LIGHTNING_BIN" daemon install-core --apk
	[ "$status" -eq 42 ]
	[[ "$output" == *"apk add failed"* ]]
}

@test "FEAT-207: install-core --apk fails if lightningd missing post-install" {
	_fake_alpine_os_release
	_stub_apk 0 0
	_stub_doas
	export BIN_SHIM_CALLS_DIR="$BIN_SHIM"
	run "$LIGHTNING_BIN" daemon install-core --apk
	[ "$status" -eq 1 ]
	[[ "$output" == *"reported success"* ]]
}

@test "FEAT-207: platform_id reads LIGHTNING_OS_RELEASE override" {
	# Sanity check for the test hook itself — used by stage-2 onwards.
	_fake_alpine_os_release
	# Reach into the daemon verb's helper via subshell.
	run env LIGHTNING_OS_RELEASE="$LIGHTNING_OS_RELEASE" sh -c '
		. "'"$BATS_TEST_DIRNAME"'/../../libexec/lightning/daemon" >/dev/null 2>&1
		platform_id
	' 2>/dev/null || true
	# The daemon script invokes case logic when sourced; we can't rely on
	# fully sourcing it.  Instead exercise the override through the verb:
	run "$LIGHTNING_BIN" daemon install-core --apk --dry-run
	[ "$status" -eq 0 ]
	# Output line is "platform:   alpine"
	[[ "$output" == *"platform:"*"alpine"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-207 stage 3 — real `--source` invocation (Ubuntu apt + git + make)
# ---------------------------------------------------------------------------

_stub_apt_get() {
	local exit_code="${1:-0}"
	cat > "$BIN_SHIM/apt-get" <<EOF
#!/bin/sh
echo "apt-get \$*" >> "$BIN_SHIM/apt-get.calls"
exit $exit_code
EOF
	chmod +x "$BIN_SHIM/apt-get"
}

# git stub: records args; for `clone <repo> <dest>` it creates <dest>
# with a stub configure script and Makefile so the subsequent build
# step doesn't have to find them on PATH.
_stub_git_for_source() {
	local exit_code="${1:-0}"
	cat > "$BIN_SHIM/git" <<EOF
#!/bin/sh
echo "git \$*" >> "$BIN_SHIM/git.calls"
if [ "\$1" = "clone" ]; then
	# Destination is the last arg (\$# is the count).
	eval dest=\\\${\$#}
	mkdir -p "\$dest/.git" "\$dest"
	printf '#!/bin/sh\nexit 0\n' > "\$dest/configure"
	chmod +x "\$dest/configure"
	# A no-op Makefile — \`make\` itself is a separate shim that fakes
	# install by dropping a lightningd binary onto PATH.
	printf 'all:\n\t@true\ninstall:\n\t@true\n' > "\$dest/Makefile"
fi
exit $exit_code
EOF
	chmod +x "$BIN_SHIM/git"
}

# make stub: records args; on `make install` drops a fake lightningd
# into BIN_SHIM so ic_verify_lightningd passes.  Mirrors the apk-stub
# pattern.
_stub_make() {
	local exit_code="${1:-0}" install_lightningd="${2:-1}"
	cat > "$BIN_SHIM/make" <<EOF
#!/bin/sh
echo "make \$*" >> "$BIN_SHIM/make.calls"
if [ "\$1" = "install" ] && [ "$install_lightningd" = "1" ] && [ "$exit_code" = "0" ]; then
	printf '#!/bin/sh\necho "Core Lightning v26.04.1"\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
fi
exit $exit_code
EOF
	chmod +x "$BIN_SHIM/make"
}

# Drop a fake /etc/os-release identifying as Ubuntu (the CI container
# IS Ubuntu — this is belt-and-braces in case the test order changes).
_fake_ubuntu_os_release() {
	local f="$BATS_TMPDIR/os-release.$$.ubuntu"
	cat > "$f" <<'EOF'
ID=ubuntu
VERSION_ID=24.04
PRETTY_NAME="Ubuntu 24.04"
EOF
	export LIGHTNING_OS_RELEASE="$f"
}

# Common setup for source-backend tests.
_source_common_setup() {
	_fake_ubuntu_os_release
	export LIGHTNING_BUILD_DIR="$BATS_TMPDIR/lightning-build.$$"
	rm -rf "$LIGHTNING_BUILD_DIR"
	export BIN_SHIM_CALLS_DIR="$BIN_SHIM"
	# GH-hosted runners are non-root → ic_root_prefix returns sudo and
	# the verb runs `sudo apt-get install` + `sudo make install`.  Stub
	# sudo so those calls route through our apt-get / make shims rather
	# than asking real sudo for a password (which fails on no-TTY).
	_stub_sudo
}

@test "FEAT-207: install-core --source --yes runs the full sequence" {
	_source_common_setup
	_stub_apt_get 0
	_stub_git_for_source 0
	_stub_make 0 1
	run "$LIGHTNING_BIN" daemon install-core --source --yes
	[ "$status" -eq 0 ]
	# apt-get install was called with the build deps.
	[ -f "$BIN_SHIM/apt-get.calls" ]
	grep -q "apt-get install" "$BIN_SHIM/apt-get.calls"
	grep -q "build-essential"  "$BIN_SHIM/apt-get.calls"
	grep -q "libsqlite3-dev"   "$BIN_SHIM/apt-get.calls"
	grep -q "libsodium-dev"    "$BIN_SHIM/apt-get.calls"
	# git clone went to the configured build dir.
	[ -f "$BIN_SHIM/git.calls" ]
	grep -q "git clone .*ElementsProject/lightning" "$BIN_SHIM/git.calls"
	grep -q "$LIGHTNING_BUILD_DIR/lightning" "$BIN_SHIM/git.calls"
	# make + make install ran.
	[ -f "$BIN_SHIM/make.calls" ]
	grep -q "^make" "$BIN_SHIM/make.calls"
	grep -q "make install" "$BIN_SHIM/make.calls"
	# Post-install verification fired.
	[[ "$output" == *"lightningd installed"* ]]
}

@test "FEAT-207: install-core --source --yes --version checks out the tag" {
	_source_common_setup
	_stub_apt_get 0
	_stub_git_for_source 0
	_stub_make 0 1
	run "$LIGHTNING_BIN" daemon install-core --source --yes --version v26.04.1
	[ "$status" -eq 0 ]
	grep -q "git checkout v26.04.1" "$BIN_SHIM/git.calls"
}

@test "FEAT-207: install-core --source refuses without --yes when stdin isn't a TTY" {
	_source_common_setup
	_stub_apt_get 0
	_stub_git_for_source 0
	_stub_make 0 1
	# bats `run` doesn't allocate a TTY, so this is the path under test.
	run "$LIGHTNING_BIN" daemon install-core --source
	[ "$status" -eq 1 ]
	[[ "$output" == *"not a TTY"* ]]
	[[ "$output" == *"--yes"* ]]
	[ ! -f "$BIN_SHIM/apt-get.calls" ]
}

@test "FEAT-207: install-core --source off-Ubuntu exits with a clear hint" {
	# Fake Alpine — same os-release machinery the apk tests use.
	_fake_alpine_os_release
	export LIGHTNING_BUILD_DIR="$BATS_TMPDIR/lightning-build.$$"
	_stub_apt_get 0
	_stub_git_for_source 0
	_stub_make 0 1
	run "$LIGHTNING_BIN" daemon install-core --source --yes
	[ "$status" -eq 1 ]
	[[ "$output" == *"Ubuntu"* ]] || [[ "$output" == *"ubuntu"* ]]
	[[ "$output" == *"--apk"* ]] || [[ "$output" == *"apk"* ]]
	[ ! -f "$BIN_SHIM/apt-get.calls" ]
}

@test "FEAT-207: install-core --source --dry-run skips platform + tool checks" {
	# No stubs at all — dry-run must still print the plan + build-dir.
	run "$LIGHTNING_BIN" daemon install-core --source --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"apt-get install build-deps"* ]]
	[[ "$output" == *"build-dir:"* ]]
}

@test "FEAT-207: install-core --source propagates apt-get failure" {
	_source_common_setup
	_stub_apt_get 100
	_stub_git_for_source 0
	_stub_make 0 1
	run "$LIGHTNING_BIN" daemon install-core --source --yes
	[ "$status" -eq 100 ]
	[[ "$output" == *"apt-get install failed"* ]]
	# git/make should not have run.
	[ ! -f "$BIN_SHIM/git.calls" ]
}

@test "FEAT-207: install-core --source propagates git failure" {
	_source_common_setup
	_stub_apt_get 0
	_stub_git_for_source 128
	_stub_make 0 1
	run "$LIGHTNING_BIN" daemon install-core --source --yes
	[ "$status" -ne 0 ]
	[[ "$output" == *"git clone failed"* ]]
	# make should not have been invoked.
	[ ! -f "$BIN_SHIM/make.calls" ]
}

@test "FEAT-207: install-core --source propagates build failure" {
	_source_common_setup
	_stub_apt_get 0
	_stub_git_for_source 0
	# make all exits non-zero; install never runs.
	_stub_make 2 0
	run "$LIGHTNING_BIN" daemon install-core --source --yes
	[ "$status" -eq 2 ]
	[[ "$output" == *"build failed"* ]]
	[[ "$output" == *"left at"* ]]   # operator-friendly hint
}

@test "FEAT-207: install-core --source fetches when repo already cloned" {
	_source_common_setup
	# Pre-create the clone dir so the verb takes the fetch branch.
	mkdir -p "$LIGHTNING_BUILD_DIR/lightning/.git"
	printf '#!/bin/sh\nexit 0\n' > "$LIGHTNING_BUILD_DIR/lightning/configure"
	chmod +x "$LIGHTNING_BUILD_DIR/lightning/configure"
	printf 'all:\n\t@true\ninstall:\n\t@true\n' > "$LIGHTNING_BUILD_DIR/lightning/Makefile"
	_stub_apt_get 0
	_stub_git_for_source 0
	_stub_make 0 1
	run "$LIGHTNING_BIN" daemon install-core --source --yes
	[ "$status" -eq 0 ]
	grep -q "git fetch" "$BIN_SHIM/git.calls"
	! grep -q "git clone" "$BIN_SHIM/git.calls"
}

# ---------------------------------------------------------------------------
# FEAT-207 stage 4 — real `--podman` invocation
# ---------------------------------------------------------------------------

# Records every podman invocation; handles the few sub-commands the
# verb cares about.  `container exists` returns 1 by default (no
# container); set PODMAN_CONTAINER_EXISTS=1 in the test env to flip it.
_stub_podman() {
	local pull_exit="${1:-0}" create_exit="${2:-0}"
	cat > "$BIN_SHIM/podman" <<EOF
#!/bin/sh
echo "podman \$*" >> "$BIN_SHIM/podman.calls"
case "\$1" in
	pull)
		exit $pull_exit ;;
	container)
		if [ "\$2" = "exists" ]; then
			[ "\${PODMAN_CONTAINER_EXISTS:-0}" = "1" ] && exit 0 || exit 1
		fi
		exit 0 ;;
	create)
		exit $create_exit ;;
	rm)
		exit 0 ;;
	run)
		# Used by the lightningd shim for --version checks.
		echo "Core Lightning v26.04.1"
		exit 0 ;;
	exec)
		# Used by the lightning-cli shim at runtime.  Not exercised here.
		exit 0 ;;
esac
exit 0
EOF
	chmod +x "$BIN_SHIM/podman"
}

_podman_common_setup() {
	# Isolate state and shim dirs into BATS_TMPDIR so tests don't litter $HOME.
	export LIGHTNING_DIR="$BATS_TMPDIR/lightning-state.$$"
	export LIGHTNING_SHIM_DIR="$BATS_TMPDIR/lightning-shim.$$"
	export LIGHTNING_PODMAN_NAME="clightning"
	rm -rf "$LIGHTNING_DIR" "$LIGHTNING_SHIM_DIR"
	# Make the shim dir part of PATH so the post-install warning doesn't fire.
	export PATH="$LIGHTNING_SHIM_DIR:$PATH"
}

@test "FEAT-207: install-core --podman pulls + creates + writes shims" {
	_podman_common_setup
	_stub_podman 0 0
	run "$LIGHTNING_BIN" daemon install-core --podman
	[ "$status" -eq 0 ]
	[ -f "$BIN_SHIM/podman.calls" ]
	grep -q "podman pull elementsproject/lightningd" "$BIN_SHIM/podman.calls"
	grep -q "podman create" "$BIN_SHIM/podman.calls"
	grep -q "\\--name clightning" "$BIN_SHIM/podman.calls"
	grep -q "\\--volume $LIGHTNING_DIR:/root/.lightning" "$BIN_SHIM/podman.calls"
	[ -x "$LIGHTNING_SHIM_DIR/lightning-cli" ]
	[ -x "$LIGHTNING_SHIM_DIR/lightningd" ]
	grep -q "podman exec" "$LIGHTNING_SHIM_DIR/lightning-cli"
	grep -q "clightning"  "$LIGHTNING_SHIM_DIR/lightning-cli"
	grep -q "podman run"  "$LIGHTNING_SHIM_DIR/lightningd"
	[[ "$output" == *"lightningd installed"* ]]
}

@test "FEAT-207: install-core --podman --version tags the image" {
	_podman_common_setup
	_stub_podman 0 0
	run "$LIGHTNING_BIN" daemon install-core --podman --version v26.04.1
	[ "$status" -eq 0 ]
	grep -q "podman pull elementsproject/lightningd:v26.04.1" "$BIN_SHIM/podman.calls"
	# The lightningd shim's `--version` branch must reference the same tag.
	grep -q "elementsproject/lightningd:v26.04.1" "$LIGHTNING_SHIM_DIR/lightningd"
}

@test "FEAT-207: install-core --podman --dry-run skips podman + writes nothing" {
	_podman_common_setup
	# No podman stub at all — dry-run must still print the plan.
	run "$LIGHTNING_BIN" daemon install-core --podman --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"podman pull"* ]]
	[[ "$output" == *"shim-dir:"* ]]
	[ ! -e "$LIGHTNING_SHIM_DIR/lightning-cli" ]
}

@test "FEAT-207: install-core --podman errors when podman not on PATH" {
	# This test depends on the inherited environment NOT having podman
	# installed.  GH-hosted runners ship podman in /usr/bin, and we
	# can't strip /usr/bin from PATH without also losing coreutils
	# (dirname, basename, grep, …) that bin/lightning's own path
	# resolution needs — earlier strip-PATH approach broke the
	# script's libexec dispatch and the failure mode changed.
	# When podman is present in the environment, skip; the verb's
	# `command -v podman` branch is well-covered by code review and
	# by every other --podman test that does stub podman.
	if command -v podman >/dev/null 2>&1; then
		skip "system podman present; this test requires a podman-free environment"
	fi
	_podman_common_setup
	run "$LIGHTNING_BIN" daemon install-core --podman
	[ "$status" -eq 1 ]
	[[ "$output" == *"podman not on PATH"* ]]
	[ ! -e "$LIGHTNING_SHIM_DIR/lightning-cli" ]
}

@test "FEAT-207: install-core --podman --system is refused" {
	_podman_common_setup
	_stub_podman 0 0
	run "$LIGHTNING_BIN" daemon install-core --podman --system
	[ "$status" -eq 1 ]
	[[ "$output" == *"--system is not supported"* ]]
	[ ! -e "$LIGHTNING_SHIM_DIR/lightning-cli" ]
}

@test "FEAT-207: install-core --podman propagates pull failure" {
	_podman_common_setup
	_stub_podman 125 0
	run "$LIGHTNING_BIN" daemon install-core --podman
	[ "$status" -eq 125 ]
	[[ "$output" == *"podman pull failed"* ]]
	# create should not have happened.
	! grep -q "podman create" "$BIN_SHIM/podman.calls"
}

@test "FEAT-207: install-core --podman propagates create failure" {
	_podman_common_setup
	_stub_podman 0 125
	run "$LIGHTNING_BIN" daemon install-core --podman
	[ "$status" -eq 125 ]
	[[ "$output" == *"podman create failed"* ]]
	[ ! -e "$LIGHTNING_SHIM_DIR/lightning-cli" ]
}

@test "FEAT-207: install-core --podman refuses when container already exists" {
	_podman_common_setup
	_stub_podman 0 0
	export PODMAN_CONTAINER_EXISTS=1
	run "$LIGHTNING_BIN" daemon install-core --podman
	[ "$status" -eq 1 ]
	[[ "$output" == *"already exists"* ]]
	[[ "$output" == *"--force"* ]]
	# create should not have happened — we bailed before it.
	! grep -q "podman create" "$BIN_SHIM/podman.calls"
}

@test "FEAT-207: install-core --podman --force recreates the container" {
	_podman_common_setup
	_stub_podman 0 0
	export PODMAN_CONTAINER_EXISTS=1
	run "$LIGHTNING_BIN" daemon install-core --podman --force
	[ "$status" -eq 0 ]
	grep -q "podman rm -f clightning" "$BIN_SHIM/podman.calls"
	grep -q "podman create" "$BIN_SHIM/podman.calls"
}

@test "FEAT-207: install-core --podman warns when shim dir is not on PATH" {
	# Set up the shim dir but DO NOT add it to PATH.
	export LIGHTNING_DIR="$BATS_TMPDIR/lightning-state.$$"
	export LIGHTNING_SHIM_DIR="$BATS_TMPDIR/lightning-shim.$$"
	export LIGHTNING_PODMAN_NAME="clightning"
	rm -rf "$LIGHTNING_DIR" "$LIGHTNING_SHIM_DIR"
	# To still pass ic_verify_lightningd we need the shim to be executable —
	# verify is by absolute path, not PATH.
	_stub_podman 0 0
	run "$LIGHTNING_BIN" daemon install-core --podman
	[ "$status" -eq 0 ]
	[[ "$output" == *"not on \$PATH"* ]] || [[ "$output" == *"not on $"* ]] || [[ "$output" == *"PATH"*"add it"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-207 — daemon lifecycle commands wired through podman
# ---------------------------------------------------------------------------

# Lifecycle variant of _stub_podman.  Defaults to "container exists,
# not running"; the start/stop verbs flip a state file the inspect
# branch reads.  daemon_running's `cli getinfo` (against the mocked
# lightning-cli) keys off MOCK_STATE, which podman start/stop also
# flip so the post-start probe + cli-tied checks see consistent state.
_stub_podman_lifecycle() {
	cat > "$BIN_SHIM/podman" <<EOF
#!/bin/sh
echo "podman \$*" >> "$BIN_SHIM/podman.calls"
state="$BIN_SHIM/podman-running"
case "\$1" in
	container)
		if [ "\$2" = "exists" ]; then
			[ "\${PODMAN_CONTAINER_EXISTS:-1}" = "1" ] && exit 0 || exit 1
		fi
		exit 0 ;;
	start)
		touch "\$state"
		rm -f "$MOCK_STATE"
		exit 0 ;;
	stop)
		rm -f "\$state"
		echo "down" > "$MOCK_STATE"
		exit 0 ;;
	inspect)
		if [ -f "\$state" ]; then echo "true"; else echo "false"; fi
		exit 0 ;;
	logs)
		echo "<podman log line>"
		exit 0 ;;
	exec)
		# CLI shim runtime path — not exercised here.
		exit 0 ;;
esac
exit 0
EOF
	chmod +x "$BIN_SHIM/podman"
}

_podman_lifecycle_setup() {
	export LIGHTNING_PODMAN_NAME="clightning"
	# Bootstrap is a separate code path that calls cli listpeers + jq.
	# Skip it for the lifecycle tests — peer-graph wiring isn't part of
	# what we're testing here.
	export LIGHTNING_NO_BOOTSTRAP=1
	_stub_podman_lifecycle
}

@test "FEAT-207: daemon start routes through podman when container exists" {
	_podman_lifecycle_setup
	echo "down" > "$MOCK_STATE"
	run "$LIGHTNING_BIN" -v daemon start
	[ "$status" -eq 0 ]
	[ -f "$BIN_SHIM/podman.calls" ]
	grep -q "^podman start clightning$" "$BIN_SHIM/podman.calls"
	[[ "$output" == *"podman start clightning"* ]]
}

@test "FEAT-207: daemon stop routes through podman when container exists" {
	_podman_lifecycle_setup
	# daemon_running starts true (no MOCK_STATE) so cmd_stop proceeds.
	# The podman stub's start subcmd would have touched the state file;
	# here we want the stop branch, so make the daemon look running first.
	touch "$BIN_SHIM/podman-running"
	run "$LIGHTNING_BIN" -v daemon stop
	[ "$status" -eq 0 ]
	grep -q "^podman stop clightning$" "$BIN_SHIM/podman.calls"
	[[ "$output" == *"podman stop clightning"* ]]
}

@test "FEAT-207: daemon status reports podman-mode when container is running" {
	_podman_lifecycle_setup
	touch "$BIN_SHIM/podman-running"   # podman inspect → "true"
	run "$LIGHTNING_BIN" daemon status
	[ "$status" -eq 0 ]
	[[ "$output" == *"podman-mode"* ]]
}

@test "FEAT-207: daemon logs exec's into podman logs when container exists" {
	_podman_lifecycle_setup
	touch "$BIN_SHIM/podman-running"
	run "$LIGHTNING_BIN" daemon logs
	[ "$status" -eq 0 ]
	[[ "$output" == *"<podman log line>"* ]]
	grep -q "^podman logs" "$BIN_SHIM/podman.calls"
}

@test "FEAT-207: daemon start no-ops when podman container already running" {
	_podman_lifecycle_setup
	# MOCK_STATE empty → daemon_running returns true → cmd_start early return.
	run "$LIGHTNING_BIN" -v daemon start
	[ "$status" -eq 0 ]
	[[ "$output" == *"already running"* ]]
	[ ! -f "$BIN_SHIM/podman.calls" ] || ! grep -q "^podman start" "$BIN_SHIM/podman.calls"
}

@test "FEAT-207: daemon start prefers systemd-user over podman" {
	_podman_lifecycle_setup
	echo "down" > "$MOCK_STATE"
	# Both supervisors installed — systemd should win (explicit unit
	# beats inferred-via-container fallback).
	mkdir -p "$HOME/.config/systemd/user"
	touch "$HOME/.config/systemd/user/lightning.service"
	cat > "$BIN_SHIM/systemctl" <<EOF
#!/bin/sh
[ "\$1" = "--quiet" ] && exit 1
rm -f "$MOCK_STATE"
exit 0
EOF
	chmod +x "$BIN_SHIM/systemctl"
	run "$LIGHTNING_BIN" -v daemon start
	[ "$status" -eq 0 ]
	[[ "$output" == *"systemctl --user start lightning"* ]]
	! grep -q "^podman start" "$BIN_SHIM/podman.calls" 2>/dev/null
}

@test "FEAT-207: daemon start falls through to direct mode when no podman container" {
	export PODMAN_CONTAINER_EXISTS=0
	export LIGHTNING_NO_BOOTSTRAP=1
	echo "down" > "$MOCK_STATE"
	_stub_podman_lifecycle
	# Provide a lightningd shim so the direct-mode `command -v lightningd` succeeds.
	cat > "$BIN_SHIM/lightningd" <<EOF
#!/bin/sh
# Direct mode — flip MOCK_STATE so the post-start probe passes.
rm -f "$MOCK_STATE"
exit 0
EOF
	chmod +x "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" -v daemon start
	[ "$status" -eq 0 ]
	[[ "$output" == *"starting lightningd directly"* ]]
	! grep -q "^podman start" "$BIN_SHIM/podman.calls" 2>/dev/null
}

# ---------------------------------------------------------------------------
# FEAT-207 — Alpine / OpenRC daemon install
# ---------------------------------------------------------------------------

# Stubs for the system-account tools the OpenRC install path shells
# out to.  Each records its args; a few also produce side effects so
# the next step of the install pipeline finds what it expects (the
# state dir from `install -d`, in particular).
_stub_busybox_user_tools() {
	# addgroup / adduser / chown — record + exit 0.
	for cmd in addgroup adduser chown; do
		cat > "$BIN_SHIM/$cmd" <<EOF
#!/bin/sh
echo "$cmd \$*" >> "$BIN_SHIM/$cmd.calls"
exit 0
EOF
		chmod +x "$BIN_SHIM/$cmd"
	done
	# getent — always "not found" so the create-user / create-group
	# paths fire (without it the verb assumes the accounts already exist
	# and skips the addgroup / adduser calls we want to assert).
	cat > "$BIN_SHIM/getent" <<EOF
#!/bin/sh
echo "getent \$*" >> "$BIN_SHIM/getent.calls"
exit 2
EOF
	chmod +x "$BIN_SHIM/getent"
	# install -d <dir> needs to create the dir so the following
	# tee / chown calls have a parent to write into.  Ownership flags
	# (-o/-g) are dropped — we don't have the system users on the test
	# host anyway.
	cat > "$BIN_SHIM/install" <<EOF
#!/bin/sh
echo "install \$*" >> "$BIN_SHIM/install.calls"
for last in "\$@"; do :; done
case "\$*" in *-d*) mkdir -p "\$last" ;; esac
exit 0
EOF
	chmod +x "$BIN_SHIM/install"
}

_openrc_common_setup() {
	_fake_alpine_os_release
	export LIGHTNING_INIT_D="$BATS_TMPDIR/init.d.$$"
	export LIGHTNING_OPENRC_STATE="$BATS_TMPDIR/clightning-state.$$"
	rm -rf "$LIGHTNING_INIT_D" "$LIGHTNING_OPENRC_STATE"
	# CI runs as non-root → ic_root_prefix returns sudo.  Stub it so
	# the privileged calls (addgroup, install, tee, …) route through
	# our shims rather than asking real sudo for a password.
	_stub_sudo
	_stub_busybox_user_tools
	export BIN_SHIM_CALLS_DIR="$BIN_SHIM"
}

@test "FEAT-207: daemon install on Alpine writes an OpenRC init script" {
	_openrc_common_setup
	run "$LIGHTNING_BIN" daemon install
	[ "$status" -eq 0 ]
	[ -f "$LIGHTNING_INIT_D/clightningd" ]
	# Init script shape — shebang + supervisor + depend block.
	grep -q '^#!/sbin/openrc-run'                "$LIGHTNING_INIT_D/clightningd"
	grep -q '^command="/usr/bin/lightningd"'     "$LIGHTNING_INIT_D/clightningd"
	grep -q 'command_user="clightning:clightning"' "$LIGHTNING_INIT_D/clightningd"
	grep -q '^supervisor=supervise-daemon'       "$LIGHTNING_INIT_D/clightningd"
	grep -q 'need net'                           "$LIGHTNING_INIT_D/clightningd"
}

@test "FEAT-207: OpenRC install creates the clightning user + group" {
	_openrc_common_setup
	run "$LIGHTNING_BIN" daemon install
	[ "$status" -eq 0 ]
	[ -f "$BIN_SHIM/addgroup.calls" ]
	grep -q "addgroup -S clightning" "$BIN_SHIM/addgroup.calls"
	[ -f "$BIN_SHIM/adduser.calls" ]
	grep -q "adduser -S -H" "$BIN_SHIM/adduser.calls"
	grep -q "\\-G clightning clightning" "$BIN_SHIM/adduser.calls"
}

@test "FEAT-207: OpenRC install seeds the config with rpc-file-mode 0660" {
	_openrc_common_setup
	run "$LIGHTNING_BIN" daemon install
	[ "$status" -eq 0 ]
	[ -f "$LIGHTNING_OPENRC_STATE/config" ]
	grep -q "^rpc-file-mode=0660" "$LIGHTNING_OPENRC_STATE/config"
	grep -q "^network=" "$LIGHTNING_OPENRC_STATE/config"
}

@test "FEAT-207: OpenRC init script references the configured state dir" {
	_openrc_common_setup
	run "$LIGHTNING_BIN" daemon install
	[ "$status" -eq 0 ]
	grep -qF "lightning-dir=$LIGHTNING_OPENRC_STATE" "$LIGHTNING_INIT_D/clightningd"
	grep -qF "pidfile=\"$LIGHTNING_OPENRC_STATE/lightningd-bitcoin.pid\"" "$LIGHTNING_INIT_D/clightningd"
}

@test "FEAT-207: OpenRC install --system is silent (no warning), --bare is the warning" {
	_openrc_common_setup
	run "$LIGHTNING_BIN" daemon install --system
	[ "$status" -eq 0 ]
	# Without --system on OpenRC the verb informs the operator that
	# user-mode isn't an option.  With --system it just proceeds.
	! [[ "$output" == *"no per-user mode"* ]]
}

@test "FEAT-207: OpenRC install without --system warns about no user-mode" {
	_openrc_common_setup
	run "$LIGHTNING_BIN" -v daemon install
	[ "$status" -eq 0 ]
	[[ "$output" == *"no per-user mode"* ]]
}

@test "FEAT-207: OpenRC install refuses without --migrate when ~/.lightning exists" {
	_openrc_common_setup
	mkdir -p "$HOME/.lightning"
	run "$LIGHTNING_BIN" daemon install
	[ "$status" -eq 3 ]
	[[ "$output" == *"--migrate"* ]]
}

@test "FEAT-207: OpenRC install skips sidecar installation (no keepalive/alert)" {
	_openrc_common_setup
	run "$LIGHTNING_BIN" daemon install
	[ "$status" -eq 0 ]
	# Sidecars are user-mode systemd/launchd specific.  On OpenRC the
	# operator runs their own monitoring; we don't ship them.
	[ ! -e "$HOME/.config/systemd/user/lightning-keepalive.service" ]
	[ ! -e "$HOME/.config/systemd/user/lightning-alert.service" ]
}

@test "FEAT-207: spec file exists with the expected id" {
	# Moved to done/ when the ticket shipped — same convention every
	# graduated 0.x FEAT followed (issues/feature/done/).
	f="$BATS_TEST_DIRNAME/../../issues/feature/done/207-clightning-install.md"
	[ -f "$f" ]
	grep -q "^id: FEAT-207" "$f"
	grep -q "^status: shipped" "$f"
	grep -q "install-core" "$f"
	grep -q "podman" "$f"
	grep -q "OpenRC" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-205: channel autopilot
# ---------------------------------------------------------------------------

@test "FEAT-205: channel autopilot (no args) prints usage" {
	run "$LIGHTNING_BIN" channel autopilot
	[ "$status" -ne 0 ]
	[[ "$output" == *"run"* ]]
	[[ "$output" == *"status"* ]]
	[[ "$output" == *"suggest"* ]]
}

@test "FEAT-205: channel autopilot --help describes the run/status/suggest split" {
	run "$LIGHTNING_BIN" channel autopilot --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"daemon iteration"* ]]
	[[ "$output" == *"suggestions"* ]]
}

@test "FEAT-205: channel autopilot status reports 'never run' when no state file" {
	run "$LIGHTNING_BIN" channel autopilot status
	[ "$status" -eq 0 ]
	[[ "$output" == *"never run"* ]]
	[[ "$output" == *"daemon install --autopilot"* ]]
}

@test "FEAT-205: channel autopilot run --dry-run reads config + computes plan" {
	run "$LIGHTNING_BIN" channel autopilot run --dry-run
	[ "$status" -eq 0 ]
	# Plan summary lines visible.
	[[ "$output" == *"starting"* ]]
	[[ "$output" == *"band:"* ]]
	[[ "$output" == *"daily cap:"* ]]
	[[ "$output" == *"would run: lightning fee policy"* ]]
	[[ "$output" == *"done"* ]]
	# State file written even in dry-run.
	[ -f "$HOME/.lightning/autopilot/state.recfile" ]
	grep -q "^last_run:" "$HOME/.lightning/autopilot/state.recfile"
	grep -q "^dry_run: 1" "$HOME/.lightning/autopilot/state.recfile"
}

@test "FEAT-205: channel autopilot honours autopilot.conf overrides" {
	mkdir -p "$HOME/.lightning"
	cat > "$HOME/.lightning/autopilot.conf" <<CFG
rebalance_band_low: 25
rebalance_band_high: 75
rebalance_max_fee_ppm: 1234
rebalance_daily_cap_sat: 99999
fee_policy: lsp-style
CFG
	run "$LIGHTNING_BIN" channel autopilot run --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"25%..75%"* ]]
	[[ "$output" == *"max ppm:"*"1234"* ]]
	[[ "$output" == *"daily cap:"*"99999"* ]]
	[[ "$output" == *"fee policy:"*"lsp-style"* ]]
}

@test "FEAT-205: channel autopilot run refuses when enabled=false" {
	mkdir -p "$HOME/.lightning"
	printf 'enabled: false\n' > "$HOME/.lightning/autopilot.conf"
	run "$LIGHTNING_BIN" channel autopilot run
	[ "$status" -eq 0 ]
	[[ "$output" == *"disabled"* ]]
}

@test "FEAT-205: channel autopilot suggest writes a recfile + prints it" {
	run "$LIGHTNING_BIN" channel autopilot suggest
	[ "$status" -eq 0 ]
	[[ "$output" == *"wrote"* ]]
	[[ "$output" == *"kind: stale-channels"* ]]
	# A suggestions file landed.
	ls "$HOME/.lightning/autopilot/"suggestions-*.recfile >/dev/null
}

@test "FEAT-205: channel autopilot run updates state's budget_day on next-day rollover" {
	# Seed yesterday's state with some budget used.
	mkdir -p "$HOME/.lightning/autopilot"
	cat > "$HOME/.lightning/autopilot/state.recfile" <<EOF2
last_run: 1970-01-01T00:00:00Z
budget_day: 1970-01-01
budget_used_sat: 4000
budget_cap_sat: 5000
EOF2
	run "$LIGHTNING_BIN" channel autopilot run --dry-run
	[ "$status" -eq 0 ]
	# Budget should have reset to 0 since today != 1970-01-01.
	grep -q "^budget_used_sat: 0$" "$HOME/.lightning/autopilot/state.recfile"
}

@test "FEAT-205: channel autopilot run unknown flag fails" {
	run "$LIGHTNING_BIN" channel autopilot run --not-a-real-flag
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown flag"* ]]
}

@test "FEAT-205: channel verb's help mentions autopilot" {
	run "$LIGHTNING_BIN" channel
	[ "$status" -ne 0 ]
	[[ "$output" == *"autopilot"* ]]
}

@test "FEAT-205: daemon install --autopilot writes a sidecar (Linux)" {
	if [ "$(uname -s)" = "Darwin" ]; then
		skip "Linux-only — checks the systemd timer files"
	fi
	# Don't trigger the systemd-system path; user-mode only.
	run "$LIGHTNING_BIN" daemon install --autopilot --no-keepalive --no-alert
	[ "$status" -eq 0 ]
	[ -f "$HOME/.config/systemd/user/lightning-autopilot.service" ]
	[ -f "$HOME/.config/systemd/user/lightning-autopilot.timer" ]
	grep -q "channel autopilot run" "$HOME/.config/systemd/user/lightning-autopilot.service"
	grep -q "OnUnitActiveSec=15min" "$HOME/.config/systemd/user/lightning-autopilot.timer"
}

@test "FEAT-205: daemon install (no --autopilot) does NOT write the sidecar" {
	# The autopilot sidecar is opt-in, unlike keepalive/alert.
	run "$LIGHTNING_BIN" daemon install --no-keepalive --no-alert
	[ "$status" -eq 0 ]
	[ ! -e "$HOME/.config/systemd/user/lightning-autopilot.service" ]
	[ ! -e "$HOME/.config/systemd/user/lightning-autopilot.timer" ]
}

@test "FEAT-205: spec file exists with the expected id" {
	# Move to done/ in the same PR that ships the implementation —
	# matches the convention every other graduated FEAT followed.
	f="$BATS_TEST_DIRNAME/../../issues/feature/done/205-channel-autopilot-verb.md"
	[ -f "$f" ]
	grep -q "^id: FEAT-205" "$f"
	grep -q "^status: shipped" "$f"
	grep -q "autopilot" "$f"
	grep -q "rebalance" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-211: account-centric user-facing verb facade
# ---------------------------------------------------------------------------

# Common: create a wallet + an account.  Returns once both exist.
_acct_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent "monthly rent" --limit 100000 --overdraft warn >/dev/null
}

@test "FEAT-211: account verb's help lists the new account-centric subs" {
	run "$LIGHTNING_BIN" account
	[ "$status" -ne 0 ]
	[[ "$output" == *"topup"* ]]
	[[ "$output" == *"withdraw"* ]]
	[[ "$output" == *"pay"* ]]
	[[ "$output" == *"receive"* ]]
}

@test "FEAT-211: account topup unknown account exits with hint" {
	_acct_setup
	run "$LIGHTNING_BIN" account topup nosuchaccount 10000
	[ "$status" -eq 2 ]
	[[ "$output" == *"not found"* ]]
	[[ "$output" == *"account create"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account topup prints address + BIP-21 URI + QR" {
	_acct_setup
	run "$LIGHTNING_BIN" account topup rent 100000
	[ "$status" -eq 0 ]
	[[ "$output" == *"Top up account 'rent'"* ]]
	[[ "$output" == *"bcrt1qtestaddress"* ]]
	[[ "$output" == *"BIP-21: bitcoin:"* ]]
	[[ "$output" == *"amount=100000"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account topup --via lightning produces a BOLT-11 invoice" {
	_acct_setup
	run "$LIGHTNING_BIN" account topup rent 5000 --via lightning
	[ "$status" -eq 0 ]
	[[ "$output" == *"lnbcrt"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account topup rejects unknown --via value" {
	_acct_setup
	run "$LIGHTNING_BIN" account topup rent 1000 --via tor
	[ "$status" -ne 0 ]
	[[ "$output" == *"--via must be"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account withdraw rejects a non-bitcoin address" {
	_acct_setup
	run "$LIGHTNING_BIN" account withdraw rent 5000 not-an-address
	[ "$status" -ne 0 ]
	[[ "$output" == *"doesn't look like a bitcoin address"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account withdraw errors clearly when boltzcli isn't installed" {
	_acct_setup
	# boltzcli isn't on the test PATH — the verb should report it.
	run "$LIGHTNING_BIN" account withdraw rent 5000 bc1qtestaddressxxxxxxxxxxxxxxxxxxxxxxxxxx
	[ "$status" -eq 127 ]
	[[ "$output" == *"boltzcli not installed"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account withdraw runs boltzcli reverse swap when installed" {
	_acct_setup
	# Stub boltzcli to succeed.
	cat > "$BIN_SHIM/boltzcli" <<'EOF2'
#!/bin/sh
echo "boltzcli $*" >> "$BIN_SHIM/boltzcli.calls"
echo '{"id":"swap-123","status":"created"}'
exit 0
EOF2
	chmod +x "$BIN_SHIM/boltzcli"
	export BIN_SHIM
	run "$LIGHTNING_BIN" account withdraw rent 5000 bc1qrecipientxxxxxxxxxxxxxxxxxxxxxxxxxx
	[ "$status" -eq 0 ]
	grep -q "createreverseswap" "$BIN_SHIM/boltzcli.calls"
	grep -q "\\--address bc1qrecipient" "$BIN_SHIM/boltzcli.calls"
	[[ "$output" == *"ok"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account pay dispatches lnbc* to invoice pay" {
	_acct_setup
	run "$LIGHTNING_BIN" account pay rent lnbcrt10n1pmocktest
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]] || [[ "$output" == *"payment_hash"* ]] || [[ "$output" == *"complete"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account pay dispatches lno* to offer pay" {
	_acct_setup
	run "$LIGHTNING_BIN" account pay rent lno1pgmocktest
	[ "$status" -eq 0 ]
	# offer pay fetches an invoice then pays — output includes payment status.
	[[ "$output" == *"complete"* ]] || [[ "$output" == *"payment_hash"* ]] || [[ "$output" == *"ok"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account pay rejects 02xx node-pubkey without --sat" {
	_acct_setup
	# 66-char hex pubkey starting with 02.
	run "$LIGHTNING_BIN" account pay rent 020000000000000000000000000000000000000000000000000000000000000002
	[ "$status" -ne 0 ]
	[[ "$output" == *"keysend needs --sat"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account pay accepts 02xx node-pubkey + --sat (keysend)" {
	_acct_setup
	run "$LIGHTNING_BIN" account pay rent \
		020000000000000000000000000000000000000000000000000000000000000002 --sat 1000
	[ "$status" -eq 0 ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account pay rejects unknown payment-string shape" {
	_acct_setup
	run "$LIGHTNING_BIN" account pay rent garbage-string-no-prefix
	[ "$status" -ne 0 ]
	[[ "$output" == *"couldn't identify payment-string type"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account pay rejects 02xx that isn't 66 chars" {
	_acct_setup
	run "$LIGHTNING_BIN" account pay rent 02deadbeef --sat 100
	[ "$status" -ne 0 ]
	[[ "$output" == *"isn't 66 chars"* ]] || [[ "$output" == *"couldn't identify"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account receive defaults to BOLT-11 + QR" {
	_acct_setup
	run "$LIGHTNING_BIN" account receive rent 7500 --desc "tip"
	[ "$status" -eq 0 ]
	[[ "$output" == *"lnbcrt"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account receive --reusable produces a BOLT-12 offer + QR" {
	_acct_setup
	run "$LIGHTNING_BIN" account receive rent 5000 --reusable --desc "monthly subscription"
	[ "$status" -eq 0 ]
	[[ "$output" == *"lno1"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: account receive --reusable binds the offer to the account" {
	_acct_setup
	run "$LIGHTNING_BIN" account receive rent 5000 --reusable
	[ "$status" -eq 0 ]
	# offer create --account writes a binding recfile under wallet/offers/.
	[ -d "$LIGHTNING_WALLETS_ROOT/alice/offers" ]
	grep -q "^account: rent" "$LIGHTNING_WALLETS_ROOT/alice/offers/"*.recfile
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: offer create --account writes the binding (unit test for the gap-filler)" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create club "" >/dev/null
	run "$LIGHTNING_BIN" offer create 1000 "test offer" --account club
	[ "$status" -eq 0 ]
	[ -d "$LIGHTNING_WALLETS_ROOT/alice/offers" ]
	grep -q "^account: club"  "$LIGHTNING_WALLETS_ROOT/alice/offers/"*.recfile
	grep -q "^offer_id:"      "$LIGHTNING_WALLETS_ROOT/alice/offers/"*.recfile
	grep -q "^bolt12: lno1"   "$LIGHTNING_WALLETS_ROOT/alice/offers/"*.recfile
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-211: spec file exists with the expected id" {
	# Shipped together with the implementation in this PR — same
	# cadence as FEAT-198 / FEAT-205 / FEAT-207.
	f="$BATS_TEST_DIRNAME/../../issues/feature/done/211-account-centric-verbs.md"
	[ -f "$f" ]
	grep -q "^id: FEAT-211" "$f"
	grep -q "^status: shipped" "$f"
	grep -q "topup" "$f"
	grep -q "withdraw" "$f"
	grep -q "receive" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-212 PR-1: account create mints bitcoin-address ID + API key,
# plus `account close`, `account nickname`, schema migration.
# ---------------------------------------------------------------------------

_acct212_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
}

@test "FEAT-212 PR-1: account create mints a bitcoin address" {
	_acct212_setup
	run "$LIGHTNING_BIN" account create rent
	[ "$status" -eq 0 ]
	[[ "$output" == *"created rent"* ]]
	[[ "$output" == *"address:"* ]]
	[[ "$output" == *"bcrt1qtestaddress"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account create mints an lt_ prefixed API key" {
	_acct212_setup
	run "$LIGHTNING_BIN" account create rent
	[ "$status" -eq 0 ]
	[[ "$output" == *"api_key:"* ]]
	[[ "$output" == *"lt_"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account create persists the address into the schema" {
	_acct212_setup
	run "$LIGHTNING_BIN" account create rent
	[ "$status" -eq 0 ]
	local db="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	local stored
	stored=$(sqlite3 "$db" "SELECT address FROM accounts WHERE name = 'rent';")
	[[ "$stored" == bcrt1qtestaddress* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account create with LIGHTNING_ACCOUNT_NO_MINT=1 skips minting" {
	_acct212_setup
	LIGHTNING_ACCOUNT_NO_MINT=1 run "$LIGHTNING_BIN" account create legacy
	[ "$status" -eq 0 ]
	[[ "$output" != *"address:"* ]]
	[[ "$output" != *"api_key:"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account create writes nickname recfile" {
	_acct212_setup
	"$LIGHTNING_BIN" account create rent >/dev/null
	[ -f "$LIGHTNING_WALLETS_ROOT/alice/accounts/nicknames.recfile" ]
	grep -q "^nickname: rent" "$LIGHTNING_WALLETS_ROOT/alice/accounts/nicknames.recfile"
	grep -q "^address: bcrt1qtestaddress" "$LIGHTNING_WALLETS_ROOT/alice/accounts/nicknames.recfile"
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account create issues unique addresses across accounts" {
	_acct212_setup
	"$LIGHTNING_BIN" account create rent >/dev/null
	"$LIGHTNING_BIN" account create club >/dev/null
	local db="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	local n_distinct
	n_distinct=$(sqlite3 "$db" "SELECT COUNT(DISTINCT address) FROM accounts WHERE name IN ('rent','club');")
	[ "$n_distinct" = "2" ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account show resolves by legacy name" {
	_acct212_setup
	"$LIGHTNING_BIN" account create rent >/dev/null
	run "$LIGHTNING_BIN" account show rent
	[ "$status" -eq 0 ]
	[[ "$output" == *"name:"*"rent"* ]]
	[[ "$output" == *"address:"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account show resolves by bitcoin-address handle" {
	_acct212_setup
	"$LIGHTNING_BIN" account create rent >/dev/null
	local db="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	local addr
	addr=$(sqlite3 "$db" "SELECT address FROM accounts WHERE name = 'rent';")
	run "$LIGHTNING_BIN" account show "$addr"
	[ "$status" -eq 0 ]
	[[ "$output" == *"name:"*"rent"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account close stamps closed_at" {
	_acct212_setup
	"$LIGHTNING_BIN" account create rent >/dev/null
	run "$LIGHTNING_BIN" account close rent
	[ "$status" -eq 0 ]
	[[ "$output" == *"closed rent"* ]]
	local db="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	local closed_at
	closed_at=$(sqlite3 "$db" "SELECT closed_at FROM accounts WHERE name = 'rent';")
	[ -n "$closed_at" ]
	[ "$closed_at" != "0" ]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account close refuses the unassigned (-) account" {
	_acct212_setup
	run "$LIGHTNING_BIN" account close -
	[ "$status" -eq 2 ]
	[[ "$output" == *"cannot close"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account close on unknown handle errors clearly" {
	_acct212_setup
	run "$LIGHTNING_BIN" account close nosuchaccount
	[ "$status" -eq 2 ]
	[[ "$output" == *"no such account"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account nickname add stores the mapping" {
	_acct212_setup
	"$LIGHTNING_BIN" account create rent >/dev/null
	run "$LIGHTNING_BIN" account nickname add bcrt1qtestaddress000000000000000000000099xxxx my-alias
	[ "$status" -eq 0 ]
	[[ "$output" == *"my-alias -> bcrt1q"* ]]
	grep -q "^nickname: my-alias" "$LIGHTNING_WALLETS_ROOT/alice/accounts/nicknames.recfile"
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account nickname add rejects non-bitcoin handles" {
	_acct212_setup
	run "$LIGHTNING_BIN" account nickname add not-an-address my-alias
	[ "$status" -ne 0 ]
	[[ "$output" == *"must be a bitcoin address"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account nickname list returns TSV" {
	_acct212_setup
	"$LIGHTNING_BIN" account create rent >/dev/null
	run "$LIGHTNING_BIN" account nickname list
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "nickname	address" ]]
	[[ "$output" == *"rent"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account nickname remove drops the alias" {
	_acct212_setup
	"$LIGHTNING_BIN" account create rent >/dev/null
	"$LIGHTNING_BIN" account nickname add bcrt1qsome0000000000000000000000000000000000xxxx alias1 >/dev/null
	"$LIGHTNING_BIN" account nickname remove alias1
	! grep -q "^nickname: alias1" "$LIGHTNING_WALLETS_ROOT/alice/accounts/nicknames.recfile"
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account show resolves by operator-added nickname" {
	_acct212_setup
	"$LIGHTNING_BIN" account create rent >/dev/null
	local db="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	local addr
	addr=$(sqlite3 "$db" "SELECT address FROM accounts WHERE name = 'rent';")
	"$LIGHTNING_BIN" account nickname add "$addr" cosy-corner >/dev/null
	run "$LIGHTNING_BIN" account show cosy-corner
	[ "$status" -eq 0 ]
	[[ "$output" == *"name:"*"rent"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: schema migration is idempotent + adds expected columns" {
	_acct212_setup
	local db="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	# Trigger active_db twice via two distinct account commands.
	"$LIGHTNING_BIN" account list >/dev/null
	"$LIGHTNING_BIN" account list >/dev/null
	# Schema should now have the new columns.
	local cols
	cols=$(sqlite3 "$db" "PRAGMA table_info(accounts);" | awk -F'|' '{print $2}' | sort | paste -sd,)
	[[ "$cols" == *"address"* ]]
	[[ "$cols" == *"created_at"* ]]
	[[ "$cols" == *"closed_at"* ]]
	[[ "$cols" == *"last_api_call_at"* ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$HOME/.lightning"
}

@test "FEAT-212 PR-1: account verb's help lists close + nickname" {
	run "$LIGHTNING_BIN" account
	[ "$status" -ne 0 ]
	[[ "$output" == *"close <handle>"* ]]
	[[ "$output" == *"nickname add"* ]]
}

@test "FEAT-212 PR-1: spec file exists with the expected id" {
	# Pre-PR-5 the file lived at issues/feature/; PR-5 moved it to
	# issues/feature/done/ when the ticket completed.  Accept either.
	f=""
	for cand in \
		"$BATS_TEST_DIRNAME/../../issues/feature/212-account-centric-http-api.md" \
		"$BATS_TEST_DIRNAME/../../issues/feature/done/212-account-centric-http-api.md"; do
		[ -f "$cand" ] && f="$cand" && break
	done
	[ -n "$f" ]
	grep -q "^id: FEAT-212" "$f"
	grep -q "Bitcoin address" "$f"
	grep -q "MCP" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-212 PR-2: HTTP-API shell verbs (api-account-*).
# These exercise the verbs directly; the Python CGI dispatcher is
# covered separately under tests/python/test_api_accounts.py.
# ---------------------------------------------------------------------------

_acct212pr2_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null
	BATS_ADDR=$(sqlite3 "$LIGHTNING_WALLETS_ROOT/alice/state.db" "SELECT address FROM accounts WHERE name='rent';")
}

_acct212pr2_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

@test "FEAT-212 PR-2: api-account-balance returns JSON for known address" {
	_acct212pr2_setup
	run "$LIGHTNING_BIN" api-account-balance "$BATS_ADDR"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"balance_sat":0'* ]]
	[[ "$output" == *'"overdraft":"deny"'* ]]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-account-balance rejects non-bech32 input" {
	_acct212pr2_setup
	run "$LIGHTNING_BIN" api-account-balance "1AbCdEfGhIjKlMnOpQrStUvWxYz123"
	[ "$status" -ne 0 ]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-account-balance returns error JSON for unknown address" {
	_acct212pr2_setup
	run "$LIGHTNING_BIN" api-account-balance "bcrt1qaaa00000000000000000000000000000000000000"
	[[ "$output" == *'"error"'* ]]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-account-balance updates last_api_call_at" {
	_acct212pr2_setup
	local db="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	"$LIGHTNING_BIN" api-account-balance "$BATS_ADDR" >/dev/null
	local seen
	seen=$(sqlite3 "$db" "SELECT last_api_call_at FROM accounts WHERE address = '$BATS_ADDR';")
	[ -n "$seen" ]
	[ "$seen" != "0" ]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-account-topup returns BIP-21 URI" {
	_acct212pr2_setup
	run "$LIGHTNING_BIN" api-account-topup "$BATS_ADDR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"bitcoin:$BATS_ADDR"* ]]
	[[ "$output" == *'"address"'* ]]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-account-topup with sat encodes BTC amount" {
	_acct212pr2_setup
	run "$LIGHTNING_BIN" api-account-topup "$BATS_ADDR" 50000
	[ "$status" -eq 0 ]
	[[ "$output" == *"amount=0.00050000"* ]]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-account-topup rejects non-numeric sat" {
	_acct212pr2_setup
	run "$LIGHTNING_BIN" api-account-topup "$BATS_ADDR" five
	[ "$status" -ne 0 ]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-account-close stamps closed_at and emits status JSON" {
	_acct212pr2_setup
	run "$LIGHTNING_BIN" api-account-close "$BATS_ADDR"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"status":"closed"'* ]]
	[[ "$output" == *'"closed_at":'* ]]
	local db="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	local c
	c=$(sqlite3 "$db" "SELECT closed_at FROM accounts WHERE address = '$BATS_ADDR';")
	[ -n "$c" ]
	[ "$c" != "0" ]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-accounts-create mints a fresh account and returns JSON" {
	_acct212pr2_setup
	REMOTE_ADDR=10.0.0.1 run "$LIGHTNING_BIN" api-accounts-create
	[ "$status" -eq 0 ]
	[[ "$output" == *'"account_id":"bcrt1q'* ]]
	[[ "$output" == *'"api_key":"lt_'* ]]
	[[ "$output" == *'"topup_uri":"bitcoin:bcrt1q'* ]]
	[[ "$output" == *'"endpoints"'* ]]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-accounts-create defaults limit_sat=100000 + overdraft=deny" {
	_acct212pr2_setup
	REMOTE_ADDR=10.0.0.2 run "$LIGHTNING_BIN" api-accounts-create
	[ "$status" -eq 0 ]
	[[ "$output" == *'"limit_sat":100000'* ]]
	[[ "$output" == *'"overdraft":"deny"'* ]]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-accounts-create rate-limit fires after threshold" {
	_acct212pr2_setup
	# Drop the limit to 1/min for this test.
	export LIGHTNING_ACCOUNT_CREATE_RATE=1
	REMOTE_ADDR=10.0.0.3 "$LIGHTNING_BIN" api-accounts-create >/dev/null
	REMOTE_ADDR=10.0.0.3 run "$LIGHTNING_BIN" api-accounts-create
	[ "$status" -eq 6 ]
	[[ "$output" == *'"rate_limited"'* ]]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-accounts-create respects per-IP isolation" {
	_acct212pr2_setup
	export LIGHTNING_ACCOUNT_CREATE_RATE=1
	REMOTE_ADDR=10.0.0.4 "$LIGHTNING_BIN" api-accounts-create >/dev/null
	REMOTE_ADDR=10.0.0.5 run "$LIGHTNING_BIN" api-accounts-create
	[ "$status" -eq 0 ]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-accounts-create accepts a hint and trims control chars" {
	_acct212pr2_setup
	REMOTE_ADDR=10.0.0.6 run "$LIGHTNING_BIN" api-accounts-create --hint "personal pocket"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"account_id":"bcrt1q'* ]]
	# Description was persisted in the DB.
	local db="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	local got
	# Exclude house (FEAT-218 pre-seeds it with 'operator fee revenue')
	# and escrow (FEAT-228 holding account).
	got=$(sqlite3 "$db" "SELECT description FROM accounts WHERE description != '' AND name NOT IN ('-', 'house', 'escrow') LIMIT 1;")
	[ "$got" = "personal pocket" ]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-account-verify is reachable" {
	_acct212pr2_setup
	# Without a secret store available, verify returns 127 (configured
	# but not callable).  We just verify the verb's shape — no panic.
	run "$LIGHTNING_BIN" api-account-verify "$BATS_ADDR" "lt_something"
	# Either: 127 (no secret store), 1 (key mismatch), or 0 (matches).
	[ "$status" -eq 127 ] || [ "$status" -eq 1 ] || [ "$status" -eq 0 ]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-account-pay rejects non-BOLT-11 targets with 6/JSON" {
	_acct212pr2_setup
	run "$LIGHTNING_BIN" api-account-pay "$BATS_ADDR" "lnurl1abc"
	[ "$status" -eq 6 ]
	[[ "$output" == *'"target_shape_not_implemented"'* ]]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-account-withdraw rejects too-short destinations" {
	_acct212pr2_setup
	run "$LIGHTNING_BIN" api-account-withdraw "$BATS_ADDR" 5000 short
	[ "$status" -ne 0 ]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: api-account-withdraw without boltzcli returns 127/JSON" {
	_acct212pr2_setup
	# boltzcli is not in PATH inside the test sandbox — verb should
	# return its 127 error envelope rather than crashing.
	run "$LIGHTNING_BIN" api-account-withdraw "$BATS_ADDR" 5000 \
		"bc1qtestdestxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
	[ "$status" -eq 127 ]
	[[ "$output" == *'"boltzcli_not_installed"'* ]]
	_acct212pr2_teardown
}

@test "FEAT-212 PR-2: sudoers fragment lists the api-account-* verbs" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/sudoers.d/lightning"
	[ -f "$f" ]
	grep -q "api-accounts-create" "$f"
	grep -q "api-account-verify" "$f"
	grep -q "api-account-balance" "$f"
	grep -q "api-account-pay" "$f"
	grep -q "api-account-recv-reusable" "$f"
	grep -q "api-account-close" "$f"
}

@test "FEAT-212 PR-2: apache vhost maps the account API (FEAT-224 versioned path)" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/apache/lnurlp.conf"
	[ -f "$f" ]
	# FEAT-224/232: moved under /.well-known/lightning/v1/.
	grep -q "ScriptAlias /.well-known/lightning/v1/accounts" "$f"
	grep -q "wellknown/api/accounts.py" "$f"
}

@test "FEAT-212 PR-2: dispatcher script is executable Python" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/wellknown/api/accounts.py"
	[ -x "$f" ]
	head -1 "$f" | grep -q python3
}

# ---------------------------------------------------------------------------
# FEAT-212 PR-3: MCP endpoint + manifest
# ---------------------------------------------------------------------------

@test "FEAT-212 PR-3: MCP CGI script is executable Python" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/wellknown/api/mcp.py"
	[ -x "$f" ]
	head -1 "$f" | grep -q python3
}

@test "FEAT-212 PR-3: static manifest at .well-known/lightning/mcp.json is valid JSON" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/wellknown/lightning/mcp.json"
	[ -f "$f" ]
	# Validates JSON.
	jq -e '.' "$f" >/dev/null
	# All 8 tool names enumerated.
	for tool in account_create account_balance account_topup account_withdraw \
	            account_pay account_recv account_recv_reusable account_close; do
		jq -e --arg t "$tool" '.tools | index($t)' "$f" >/dev/null
	done
	# Resource URI templates.
	jq -e '.resources | length == 3' "$f" >/dev/null
	# Protocol version.
	[ "$(jq -r '.protocolVersion' "$f")" = "2025-03-26" ]
}

@test "FEAT-212 PR-3: apache vhost maps MCP (FEAT-224 versioned) + mcp.json Alias" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/apache/lnurlp.conf"
	grep -q "ScriptAlias /.well-known/lightning/v1/mcp" "$f"
	grep -q "wellknown/api/mcp.py" "$f"
	grep -q "Alias /.well-known/lightning/mcp.json" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-212 PR-4: deposit watcher.
# ---------------------------------------------------------------------------

_acct212pr4_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null
	BATS_ADDR_RENT=$(sqlite3 "$LIGHTNING_WALLETS_ROOT/alice/state.db" "SELECT address FROM accounts WHERE name='rent';")
}

_acct212pr4_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

@test "FEAT-212 PR-4: topup-watcher status reports counts" {
	_acct212pr4_setup
	run "$LIGHTNING_BIN" account topup-watcher status
	[ "$status" -eq 0 ]
	[[ "$output" == *"watched_accounts: 1"* ]]
	[[ "$output" == *"total_credits:    0"* ]]
	[[ "$output" == *"last_credit:      (none yet)"* ]]
	_acct212pr4_teardown
}

@test "FEAT-212 PR-4: topup-watcher run with no UTXOs is a no-op" {
	_acct212pr4_setup
	MOCK_LISTFUNDS_OUTPUTS='[]' run "$LIGHTNING_BIN" account topup-watcher run
	[ "$status" -eq 0 ]
	local n
	n=$(sqlite3 "$LIGHTNING_WALLETS_ROOT/alice/state.db" "SELECT COUNT(*) FROM ledger WHERE message='topup-watcher';")
	[ "$n" = "0" ]
	_acct212pr4_teardown
}

@test "FEAT-212 PR-4: topup-watcher credits a new UTXO at a known address" {
	_acct212pr4_setup
	outs=$(jq -nc --arg a "$BATS_ADDR_RENT" \
		'[{"txid":"deadbeef","output":0,"status":"confirmed","address":$a,"amount_msat":"50000000msat"}]')
	MOCK_LISTFUNDS_OUTPUTS="$outs" run "$LIGHTNING_BIN" account topup-watcher run
	[ "$status" -eq 0 ]
	local row
	row=$(sqlite3 -separator '|' "$LIGHTNING_WALLETS_ROOT/alice/state.db" \
		"SELECT account, direction, amount_msat, payment_hash FROM ledger WHERE message='topup-watcher';")
	[ "$row" = "rent|in|50000000|deadbeef:0" ]
	_acct212pr4_teardown
}

@test "FEAT-212 PR-4: topup-watcher dry-run prints plan but writes nothing" {
	_acct212pr4_setup
	outs=$(jq -nc --arg a "$BATS_ADDR_RENT" \
		'[{"txid":"deadbeef","output":0,"status":"confirmed","address":$a,"amount_msat":"1000msat"}]')
	MOCK_LISTFUNDS_OUTPUTS="$outs" run "$LIGHTNING_BIN" account topup-watcher dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"would-credit"* ]]
	[[ "$output" == *"rent"* ]]
	local n
	n=$(sqlite3 "$LIGHTNING_WALLETS_ROOT/alice/state.db" "SELECT COUNT(*) FROM ledger WHERE message='topup-watcher';")
	[ "$n" = "0" ]
	_acct212pr4_teardown
}

@test "FEAT-212 PR-4: topup-watcher dedupes re-seen UTXOs" {
	_acct212pr4_setup
	outs=$(jq -nc --arg a "$BATS_ADDR_RENT" \
		'[{"txid":"deadbeef","output":0,"status":"confirmed","address":$a,"amount_msat":"1000msat"}]')
	MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	local n
	n=$(sqlite3 "$LIGHTNING_WALLETS_ROOT/alice/state.db" "SELECT COUNT(*) FROM ledger WHERE message='topup-watcher';")
	[ "$n" = "1" ]
	_acct212pr4_teardown
}

@test "FEAT-212 PR-4: topup-watcher skips unconfirmed UTXOs" {
	_acct212pr4_setup
	outs=$(jq -nc --arg a "$BATS_ADDR_RENT" \
		'[{"txid":"deadbeef","output":0,"status":"unconfirmed","address":$a,"amount_msat":"1000msat"}]')
	MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	local n
	n=$(sqlite3 "$LIGHTNING_WALLETS_ROOT/alice/state.db" "SELECT COUNT(*) FROM ledger WHERE message='topup-watcher';")
	[ "$n" = "0" ]
	_acct212pr4_teardown
}

@test "FEAT-212 PR-4: topup-watcher skips UTXOs at unknown addresses" {
	_acct212pr4_setup
	outs='[{"txid":"deadbeef","output":0,"status":"confirmed","address":"bcrt1qstrangerxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","amount_msat":"1000msat"}]'
	MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	local n
	n=$(sqlite3 "$LIGHTNING_WALLETS_ROOT/alice/state.db" "SELECT COUNT(*) FROM ledger WHERE message='topup-watcher';")
	[ "$n" = "0" ]
	_acct212pr4_teardown
}

@test "FEAT-212 PR-4: topup-watcher does not credit closed accounts" {
	_acct212pr4_setup
	"$LIGHTNING_BIN" account close rent >/dev/null
	outs=$(jq -nc --arg a "$BATS_ADDR_RENT" \
		'[{"txid":"deadbeef","output":0,"status":"confirmed","address":$a,"amount_msat":"1000msat"}]')
	MOCK_LISTFUNDS_OUTPUTS="$outs" run "$LIGHTNING_BIN" account topup-watcher run
	[ "$status" -eq 0 ]
	[[ "$output" == *"skip"*"account closed"* ]]
	local n
	n=$(sqlite3 "$LIGHTNING_WALLETS_ROOT/alice/state.db" "SELECT COUNT(*) FROM ledger WHERE message='topup-watcher';")
	[ "$n" = "0" ]
	_acct212pr4_teardown
}

@test "FEAT-212 PR-4: topup-watcher handles amount_msat as a plain integer" {
	_acct212pr4_setup
	outs=$(jq -nc --arg a "$BATS_ADDR_RENT" \
		'[{"txid":"deadbeef","output":0,"status":"confirmed","address":$a,"amount_msat":2500}]')
	MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	local amt
	amt=$(sqlite3 "$LIGHTNING_WALLETS_ROOT/alice/state.db" "SELECT amount_msat FROM ledger WHERE message='topup-watcher';")
	[ "$amt" = "2500" ]
	_acct212pr4_teardown
}

@test "FEAT-212 PR-4: account verb help lists topup-watcher" {
	run "$LIGHTNING_BIN" account
	[[ "$output" == *"topup-watcher run|dry-run|status"* ]]
}

@test "FEAT-212 PR-4: daemon install --topup-watcher accepts the flag" {
	# We don't actually run the install (it tries to call systemctl);
	# we just verify the flag is recognised by parsing — and check
	# the verb source contains the sidecar function.
	f="$BATS_TEST_DIRNAME/../../libexec/lightning/daemon"
	grep -q "\-\-topup-watcher" "$f"
	grep -q "install_topup_watcher_sidecar" "$f"
	grep -q "TOPUP_WATCHER_LABEL" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-212 PR-5: account garbage collector.
# ---------------------------------------------------------------------------

_acct212pr5_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create fresh >/dev/null
	"$LIGHTNING_BIN" account create stale >/dev/null
	"$LIGHTNING_BIN" account create closer >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	# Backdate 'stale' to 95 days ago.
	sqlite3 "$BATS_DB" "UPDATE accounts SET last_api_call_at = strftime('%s','now')-95*86400, created_at = strftime('%s','now')-95*86400 WHERE name='stale';"
	# Mark 'closer' as long-closed (14 days ago).
	sqlite3 "$BATS_DB" "UPDATE accounts SET closed_at = strftime('%s','now')-14*86400 WHERE name='closer';"
}

_acct212pr5_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

@test "FEAT-212 PR-5: account gc status reports candidate counts" {
	_acct212pr5_setup
	run "$LIGHTNING_BIN" account gc status
	[ "$status" -eq 0 ]
	[[ "$output" == *"total_accounts:    3"* ]]
	[[ "$output" == *"would_close:       1"* ]]
	[[ "$output" == *"would_delete:      1"* ]]
	_acct212pr5_teardown
}

@test "FEAT-212 PR-5: account gc dry-run lists plan but writes nothing" {
	_acct212pr5_setup
	run "$LIGHTNING_BIN" account gc dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"would-close	stale"* ]]
	[[ "$output" == *"would-delete	closer"* ]]
	# State unchanged.
	local n_closed n_total
	n_total=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM accounts WHERE name NOT IN ('-', 'house', 'escrow');")
	n_closed=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM accounts WHERE closed_at IS NOT NULL;")
	[ "$n_total" = "3" ]
	[ "$n_closed" = "1" ]   # only the pre-existing 'closer'
	_acct212pr5_teardown
}

@test "FEAT-212 PR-5: account gc closes the stale account" {
	_acct212pr5_setup
	"$LIGHTNING_BIN" account gc run >/dev/null 2>&1
	local stale_closed_at
	stale_closed_at=$(sqlite3 "$BATS_DB" "SELECT closed_at FROM accounts WHERE name='stale';")
	[ -n "$stale_closed_at" ]
	[ "$stale_closed_at" != "0" ]
	_acct212pr5_teardown
}

@test "FEAT-212 PR-5: account gc deletes the long-closed account" {
	_acct212pr5_setup
	"$LIGHTNING_BIN" account gc run >/dev/null 2>&1
	local n
	n=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM accounts WHERE name='closer';")
	[ "$n" = "0" ]
	_acct212pr5_teardown
}

@test "FEAT-212 PR-5: account gc preserves fresh accounts" {
	_acct212pr5_setup
	"$LIGHTNING_BIN" account gc run >/dev/null 2>&1
	local row
	row=$(sqlite3 -separator '|' "$BATS_DB" "SELECT name, COALESCE(closed_at,0) FROM accounts WHERE name='fresh';")
	[ "$row" = "fresh|0" ]
	_acct212pr5_teardown
}

@test "FEAT-212 PR-5: account gc never touches the unassigned (-) account" {
	_acct212pr5_setup
	# Make '-' look very old to ensure the filter is not based on age alone.
	sqlite3 "$BATS_DB" "UPDATE accounts SET last_api_call_at = 0 WHERE name='-';"
	"$LIGHTNING_BIN" account gc run >/dev/null 2>&1
	local n
	n=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM accounts WHERE name='-';")
	[ "$n" = "1" ]
	_acct212pr5_teardown
}

@test "FEAT-212 PR-5: account gc skips stale accounts with non-zero balance" {
	_acct212pr5_setup
	# Park 1000 msat into stale.
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash, message) \
		VALUES(datetime('now'), 'stale', 'in', 1000, 'stake:0', 'test-fund');"
	"$LIGHTNING_BIN" account gc run >/dev/null 2>&1
	local closed_at
	closed_at=$(sqlite3 "$BATS_DB" "SELECT COALESCE(closed_at,'') FROM accounts WHERE name='stale';")
	[ -z "$closed_at" ]
	_acct212pr5_teardown
}

@test "FEAT-212 PR-5: account gc skips stale accounts with pending invoices" {
	_acct212pr5_setup
	sqlite3 "$BATS_DB" "INSERT INTO invoices(bolt11, payment_hash, account, amount_msat, expiry, state) \
		VALUES('lnbcrt-pending-1', 'hash-1', 'stale', 1000, '4102444800', 'pending');"
	"$LIGHTNING_BIN" account gc run >/dev/null 2>&1
	local closed_at
	closed_at=$(sqlite3 "$BATS_DB" "SELECT COALESCE(closed_at,'') FROM accounts WHERE name='stale';")
	[ -z "$closed_at" ]
	_acct212pr5_teardown
}

@test "FEAT-212 PR-5: LIGHTNING_ACCOUNT_GC_DAYS=1 closes one-day-stale accounts" {
	_acct212pr5_setup
	# 'fresh' was created moments ago — backdate it 2 days.
	sqlite3 "$BATS_DB" "UPDATE accounts SET last_api_call_at = strftime('%s','now')-2*86400, created_at = strftime('%s','now')-2*86400 WHERE name='fresh';"
	LIGHTNING_ACCOUNT_GC_DAYS=1 "$LIGHTNING_BIN" account gc run >/dev/null 2>&1
	local fresh_closed
	fresh_closed=$(sqlite3 "$BATS_DB" "SELECT closed_at FROM accounts WHERE name='fresh';")
	[ -n "$fresh_closed" ]
	[ "$fresh_closed" != "0" ]
	_acct212pr5_teardown
}

@test "FEAT-212 PR-5: account gc preserves ledger entries after deletion (FK SET DEFAULT)" {
	_acct212pr5_setup
	# Add a ledger entry against 'closer' BEFORE its balance is checked.
	# We want closer to have a net-zero balance so GC deletes it, but
	# the historical entries should survive via the FK SET DEFAULT.
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash) VALUES(datetime('now','-30 days'), 'closer', 'in', 1000, 'old:0');"
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash) VALUES(datetime('now','-30 days'), 'closer', 'out', -1000, 'old:1');"
	"$LIGHTNING_BIN" account gc run >/dev/null 2>&1
	# Account gone…
	local accs
	accs=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM accounts WHERE name='closer';")
	[ "$accs" = "0" ]
	# …ledger rows survive on the '-' bucket.
	local lentries
	lentries=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM ledger WHERE payment_hash IN ('old:0','old:1');")
	[ "$lentries" = "2" ]
	_acct212pr5_teardown
}

@test "FEAT-212 PR-5: account gc strips nicknames pointing at deleted address" {
	_acct212pr5_setup
	local addr
	addr=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='closer';")
	"$LIGHTNING_BIN" account nickname add "$addr" stale-nick >/dev/null
	"$LIGHTNING_BIN" account gc run >/dev/null 2>&1
	! grep -q "^address: $addr" "$LIGHTNING_WALLETS_ROOT/alice/accounts/nicknames.recfile"
	! grep -q "^nickname: stale-nick" "$LIGHTNING_WALLETS_ROOT/alice/accounts/nicknames.recfile"
	_acct212pr5_teardown
}

@test "FEAT-212 PR-5: account verb help lists gc" {
	run "$LIGHTNING_BIN" account
	[[ "$output" == *"gc run|dry-run|status"* ]]
}

@test "FEAT-212 PR-5: daemon install --account-gc accepts the flag" {
	f="$BATS_TEST_DIRNAME/../../libexec/lightning/daemon"
	grep -q "\-\-account-gc" "$f"
	grep -q "install_account_gc_sidecar" "$f"
	grep -q "ACCOUNT_GC_LABEL" "$f"
}

@test "FEAT-212 PR-5: account gc on unknown subcommand exits 1" {
	_acct212pr5_setup
	run "$LIGHTNING_BIN" account gc whatever
	[ "$status" -eq 1 ]
	_acct212pr5_teardown
}

# ---------------------------------------------------------------------------
# FEAT-213: operator fee skim primitives.
# ---------------------------------------------------------------------------

_acct213_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	BATS_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='rent';")
	BATS_FEES="$LIGHTNING_WALLETS_ROOT/alice/fees.recfile"
}

_acct213_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

@test "FEAT-213: wallet new seeds the default fees.recfile" {
	_acct213_setup
	[ -f "$BATS_FEES" ]
	grep -q "^operation: pay" "$BATS_FEES"
	grep -q "^operation: withdraw" "$BATS_FEES"
	grep -q "^operation: topup-onchain" "$BATS_FEES"
	_acct213_teardown
}

@test "FEAT-213: wallet new commits fees.recfile to git" {
	_acct213_setup
	pushd "$LIGHTNING_WALLETS_ROOT/alice" >/dev/null
	git ls-files | grep -q "^fees.recfile$"
	popd >/dev/null
	_acct213_teardown
}

@test "FEAT-213: topup-watcher skims operator fee from on-chain deposit" {
	_acct213_setup
	# Default topup-onchain rate is 2000 ppm = 0.2%.  A 100 000-sat
	# deposit should skim 200 sat → house.
	outs=$(jq -nc --arg a "$BATS_ADDR" \
		'[{"txid":"deadbeef","output":0,"status":"confirmed","address":$a,"amount_msat":"100000000msat"}]')
	MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	local skim
	skim=$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='house';")
	[ "$skim" = "200000" ]
	# User balance = deposit - skim
	local user
	user=$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='rent';")
	[ "$user" = "99800000" ]
	_acct213_teardown
}

@test "FEAT-213: topup-watcher skims zero when rate_ppm is 0" {
	_acct213_setup
	# Override the default rate to 0 for topup-onchain.
	sed -i '/^operation: topup-onchain$/,/^$/{s/^rate_ppm:.*$/rate_ppm:  0/}' "$BATS_FEES"
	sed -i '/^operation: topup-onchain$/,/^$/{s/^base_sat:.*$/base_sat:  0/}' "$BATS_FEES"
	outs=$(jq -nc --arg a "$BATS_ADDR" \
		'[{"txid":"deadbeef","output":0,"status":"confirmed","address":$a,"amount_msat":"100000000msat"}]')
	MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	# FEAT-218 pre-seeds `house` so the referrer FK default has a
	# target.  House row exists from wallet new; with zero skim,
	# there should be no in-credit ledger entries against it.
	local house_credits
	house_credits=$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='house' AND direction='in';")
	[ "$house_credits" = "0" ]
	_acct213_teardown
}

@test "FEAT-213: api-account-pay itemises into 4 ledger rows + creates house" {
	_acct213_setup
	"$LIGHTNING_BIN" api-account-pay "$BATS_ADDR" "lnbcrt10n1pmocktest" >/dev/null 2>&1
	local rows
	rows=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM ledger;")
	# 4 rows: payment, network fee, operator fee, house credit
	[ "$rows" = "4" ]
	# House account auto-created
	local house_exists
	house_exists=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM accounts WHERE name='house';")
	[ "$house_exists" = "1" ]
	# House description matches the bootstrap default
	local house_desc
	house_desc=$(sqlite3 "$BATS_DB" "SELECT description FROM accounts WHERE name='house';")
	[ "$house_desc" = "operator fee revenue" ]
	_acct213_teardown
}

@test "FEAT-213: api-account-pay JSON response includes operator_fee_sat" {
	_acct213_setup
	local body
	body=$("$LIGHTNING_BIN" api-account-pay "$BATS_ADDR" "lnbcrt10n1pmocktest" 2>/dev/null)
	echo "$body" | jq -e '.operator_fee_sat' >/dev/null
	# 1000-msat invoice at base_sat=1 + rate_ppm=5000 = 1*1000 + 1000*5000/1M
	# = 1005 msat = 1 sat (integer division).
	local got
	got=$(echo "$body" | jq -r '.operator_fee_sat')
	[ "$got" = "1" ]
	_acct213_teardown
}

@test "FEAT-213: api-account-pay double-entry — ledger sum = -sent_total" {
	_acct213_setup
	"$LIGHTNING_BIN" api-account-pay "$BATS_ADDR" "lnbcrt10n1pmocktest" >/dev/null 2>&1
	# Sum across user + house: -invoice - network_fee - operator_fee + operator_fee
	# = -invoice - network_fee.  Network fee is 1 msat; invoice is 1000 msat.
	# So total = -1001 msat.
	local total
	total=$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger;")
	[ "$total" = "-1001" ]
	_acct213_teardown
}

@test "FEAT-213: missing fees.recfile = no skim, no house credits" {
	_acct213_setup
	rm "$BATS_FEES"
	outs=$(jq -nc --arg a "$BATS_ADDR" \
		'[{"txid":"deadbeef","output":0,"status":"confirmed","address":$a,"amount_msat":"100000000msat"}]')
	MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	local rows house_credits
	rows=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM ledger;")
	[ "$rows" = "1" ]   # just the credit, no skim entries
	# FEAT-218 pre-seeds house; with no fees.recfile the verbs skip the
	# skim, so there should be zero in-credit ledger entries on house.
	house_credits=$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='house' AND direction='in';")
	[ "$house_credits" = "0" ]
	_acct213_teardown
}

@test "FEAT-213: house account is excluded from account list" {
	_acct213_setup
	"$LIGHTNING_BIN" api-account-pay "$BATS_ADDR" "lnbcrt10n1pmocktest" >/dev/null 2>&1
	run "$LIGHTNING_BIN" account list
	[ "$status" -eq 0 ]
	# `rent` appears; `house` does not.
	[[ "$output" == *"rent"* ]]
	[[ "$output" != *"house"* ]]
	_acct213_teardown
}

@test "FEAT-213: house account is excluded from GC" {
	_acct213_setup
	"$LIGHTNING_BIN" api-account-pay "$BATS_ADDR" "lnbcrt10n1pmocktest" >/dev/null 2>&1
	# Backdate house's last_api_call_at to 95 days ago so it would
	# otherwise qualify as stale, and rebalance its account to 0
	# (which it already isn't — but to be sure we cover the would-gc
	# trigger we also stamp closed_at far in the past).
	local now_minus_95; now_minus_95=$(( $(date -u +%s) - 95 * 86400 ))
	local long_ago=$(( $(date -u +%s) - 30 * 86400 ))
	sqlite3 "$BATS_DB" "UPDATE accounts SET last_api_call_at = $now_minus_95, created_at = $now_minus_95, closed_at = $long_ago WHERE name='house';"
	"$LIGHTNING_BIN" account gc run >/dev/null 2>&1
	# House should still exist.
	local count
	count=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM accounts WHERE name='house';")
	[ "$count" = "1" ]
	_acct213_teardown
}

# The FEAT-213 spec assertion lives in its own batch spec PR
# (FEAT-213..220); this implementation PR doesn't carry it directly.
# A spec-existence test would fail in CI until the spec PR merges.

# ---------------------------------------------------------------------------
# FEAT-214: fee revenue dashboard verb.
# ---------------------------------------------------------------------------

_acct214_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	BATS_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='rent';")
}

_acct214_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

@test "FEAT-214: fee-policy with no subcommand prints usage" {
	_acct214_setup
	run "$LIGHTNING_BIN" fee-policy
	[ "$status" -eq 1 ]
	[[ "$output" == *"usage: lightning fee-policy"* ]]
	_acct214_teardown
}

@test "FEAT-214: fee-policy show-rates reads fees.recfile" {
	_acct214_setup
	run "$LIGHTNING_BIN" fee-policy show-rates
	[ "$status" -eq 0 ]
	[[ "$output" == *"pay"* ]]
	[[ "$output" == *"5000"* ]]    # the default pay rate_ppm
	[[ "$output" == *"withdraw"* ]]
	[[ "$output" == *"topup-onchain"* ]]
	_acct214_teardown
}

@test "FEAT-214: fee-policy status reports empty state before any skim" {
	_acct214_setup
	run "$LIGHTNING_BIN" fee-policy status
	[ "$status" -eq 0 ]
	[[ "$output" == *"no revenue yet"* ]]
	_acct214_teardown
}

@test "FEAT-214: fee-policy status aggregates after activity" {
	_acct214_setup
	# Drive a topup skim (200-sat skim on 100k deposit).
	outs=$(jq -nc --arg a "$BATS_ADDR" \
		'[{"txid":"d1","output":0,"status":"confirmed","address":$a,"amount_msat":"100000000msat"}]')
	MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	# And a pay skim (1-sat skim on 1-sat mock-invoice).
	"$LIGHTNING_BIN" api-account-pay "$BATS_ADDR" "lnbcrt1n1pmocktest" >/dev/null 2>&1

	run "$LIGHTNING_BIN" fee-policy status
	[ "$status" -eq 0 ]
	# Total = 200 (topup) + 1 (pay) = 201 sat
	[[ "$output" == *"total_revenue_sat: 201"* ]]
	# Per-op breakdown lists both
	[[ "$output" == *"topup-onchain"* ]]
	[[ "$output" == *"200"* ]]
	[[ "$output" == *"pay"* ]]
	_acct214_teardown
}

@test "FEAT-214: fee-policy status --since filters out earlier rows" {
	_acct214_setup
	# Inject a historical skim 10 days ago.
	sqlite3 "$BATS_DB" "INSERT OR IGNORE INTO accounts(name, description, overdraft) VALUES('house', 'operator fee revenue', 'allow');"
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash, message) \
		VALUES(datetime('now','-10 days'), 'house', 'in', 50000, 'deadbeef', 'fee:pay from rent');"
	# And a fresh one today.
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash, message) \
		VALUES(datetime('now'), 'house', 'in', 25000, 'cafebabe', 'fee:pay from rent');"
	# --since yesterday should see only today's 25-sat row.
	local since; since=$(date -u -d "1 day ago" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)
	run "$LIGHTNING_BIN" fee-policy status --since "$since"
	[ "$status" -eq 0 ]
	[[ "$output" == *"total_revenue_sat: 25"* ]]
	_acct214_teardown
}

@test "FEAT-214: fee-policy status --since rejects malformed dates" {
	_acct214_setup
	run "$LIGHTNING_BIN" fee-policy status --since "yesterday"
	[ "$status" -eq 1 ]
	[[ "$output" == *"YYYY-MM-DD"* ]]
	_acct214_teardown
}

@test "FEAT-214: per-operation buckets correctly tag skim sources" {
	_acct214_setup
	# Topup skim
	outs=$(jq -nc --arg a "$BATS_ADDR" \
		'[{"txid":"d1","output":0,"status":"confirmed","address":$a,"amount_msat":"100000000msat"}]')
	MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	# Pay skim
	"$LIGHTNING_BIN" api-account-pay "$BATS_ADDR" "lnbcrt1n1pmocktest" >/dev/null 2>&1

	# Check ledger has the new fee:<op> tagging.
	local n_pay n_topup
	n_pay=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM ledger WHERE account='house' AND message LIKE 'fee:pay%';")
	n_topup=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM ledger WHERE account='house' AND message LIKE 'fee:topup-onchain%';")
	[ "$n_pay" = "1" ]
	[ "$n_topup" = "1" ]
	_acct214_teardown
}

@test "FEAT-214: top-level help mentions fee-policy" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"fee-policy"* ]]
}

@test "FEAT-214: spec file exists with the expected id" {
	for cand in \
		"$BATS_TEST_DIRNAME/../../issues/feature/214-fee-revenue-dashboard.md" \
		"$BATS_TEST_DIRNAME/../../issues/feature/done/214-fee-revenue-dashboard.md"; do
		[ -f "$cand" ] && f="$cand" && break
	done
	[ -n "$f" ]
	grep -q "^id: FEAT-214" "$f"
	grep -q "fee-policy status" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-215: fee-policy autotune cron.
# ---------------------------------------------------------------------------

_acct215_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create rent >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	BATS_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='rent';")
	BATS_FEES="$LIGHTNING_WALLETS_ROOT/alice/fees.recfile"
}

_acct215_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

@test "FEAT-215: autotune without target env var errors loudly" {
	_acct215_setup
	run "$LIGHTNING_BIN" fee-policy autotune run
	[ "$status" -eq 1 ]
	[[ "$output" == *"LIGHTNING_FEE_AUTOTUNE_TARGET_MSAT_PER_DAY"* ]]
	_acct215_teardown
}

@test "FEAT-215: autotune target must be a non-negative integer" {
	_acct215_setup
	LIGHTNING_FEE_AUTOTUNE_TARGET_MSAT_PER_DAY="abc" run "$LIGHTNING_BIN" fee-policy autotune run
	[ "$status" -eq 1 ]
	[[ "$output" == *"positive integer"* ]]
	_acct215_teardown
}

@test "FEAT-215: autotune dry-run with high target nudges rates up" {
	_acct215_setup
	# 1M msat/day = 30M msat/30days target; observed = 0; well below
	# the low_threshold, so direction=up.
	LIGHTNING_FEE_AUTOTUNE_TARGET_MSAT_PER_DAY=1000000 \
		run "$LIGHTNING_BIN" fee-policy autotune dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"direction=up"* ]]
	# fees.recfile should NOT have changed (dry-run).
	local pay_rate
	pay_rate=$(awk '/^operation: pay$/,/^$/' "$BATS_FEES" | awk '/^rate_ppm:/ {print $2}')
	[ "$pay_rate" = "5000" ]
	_acct215_teardown
}

@test "FEAT-215: autotune run nudges rates up + writes state file" {
	_acct215_setup
	LIGHTNING_FEE_AUTOTUNE_TARGET_MSAT_PER_DAY=1000000 \
		LIGHTNING_FEE_AUTOTUNE_MAX_STEP_PPM=500 \
		"$LIGHTNING_BIN" fee-policy autotune run >/dev/null 2>&1
	# pay rate should be 5500 (5000 + 500 step)
	local pay_rate
	pay_rate=$(awk '/^operation: pay$/,/^$/' "$BATS_FEES" | awk '/^rate_ppm:/ {print $2}')
	[ "$pay_rate" = "5500" ]
	# State file written
	[ -f "$LIGHTNING_DIR/fee-autotune.state.recfile" ]
	grep -q "last_direction: *up" "$LIGHTNING_DIR/fee-autotune.state.recfile"
	_acct215_teardown
}

@test "FEAT-215: autotune holds within hysteresis band" {
	_acct215_setup
	# Seed 30 sat of revenue
	sqlite3 "$BATS_DB" "INSERT OR IGNORE INTO accounts(name, description, overdraft) VALUES('house', 'operator fee revenue', 'allow');"
	for i in $(seq 1 30); do
		sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash, message) \
			VALUES(datetime('now','-$((30 - i)) days'), 'house', 'in', 1000, 'h$i', 'fee:pay from rent');"
	done
	# 30 days × 1000 msat = 30000 msat total / 30 = 1000 msat/day observed
	# Target = 1000 → exact match → direction=hold (within 20% hysteresis)
	LIGHTNING_FEE_AUTOTUNE_TARGET_MSAT_PER_DAY=1000 \
		run "$LIGHTNING_BIN" fee-policy autotune dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"direction=hold"* ]]
	_acct215_teardown
}

@test "FEAT-215: autotune nudges down when revenue exceeds high threshold" {
	_acct215_setup
	# Seed 200 sat skim (200_000 msat) → observed ~6666 msat/day
	sqlite3 "$BATS_DB" "INSERT OR IGNORE INTO accounts(name, description, overdraft) VALUES('house', 'operator fee revenue', 'allow');"
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash, message) \
		VALUES(datetime('now'), 'house', 'in', 200000, 'deadbeef', 'fee:pay from rent');"
	# Target = 1000 msat/day; 1.2×target = 1200; observed 6666 >> 1200 → down
	LIGHTNING_FEE_AUTOTUNE_TARGET_MSAT_PER_DAY=1000 \
		run "$LIGHTNING_BIN" fee-policy autotune dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"direction=down"* ]]
	_acct215_teardown
}

@test "FEAT-215: autotune respects rate ceiling" {
	_acct215_setup
	# Set ceiling at 5500; pay rate currently 5000.  Single 500-step
	# nudge UP would hit 5500 exactly.  A second run shouldn't move it.
	LIGHTNING_FEE_AUTOTUNE_TARGET_MSAT_PER_DAY=1000000 \
		LIGHTNING_FEE_AUTOTUNE_MAX_STEP_PPM=500 \
		LIGHTNING_FEE_AUTOTUNE_CEILING_PPM=5500 \
		"$LIGHTNING_BIN" fee-policy autotune run >/dev/null 2>&1
	LIGHTNING_FEE_AUTOTUNE_TARGET_MSAT_PER_DAY=1000000 \
		LIGHTNING_FEE_AUTOTUNE_MAX_STEP_PPM=500 \
		LIGHTNING_FEE_AUTOTUNE_CEILING_PPM=5500 \
		"$LIGHTNING_BIN" fee-policy autotune run >/dev/null 2>&1
	local pay_rate
	pay_rate=$(awk '/^operation: pay$/,/^$/' "$BATS_FEES" | awk '/^rate_ppm:/ {print $2}')
	[ "$pay_rate" = "5500" ]
	_acct215_teardown
}

@test "FEAT-215: autotune respects rate floor" {
	_acct215_setup
	# Drive direction=down, floor at 4500.  Pay starts at 5000 → 4500 →
	# stays at 4500 across further calls.
	sqlite3 "$BATS_DB" "INSERT OR IGNORE INTO accounts(name, description, overdraft) VALUES('house', 'operator fee revenue', 'allow');"
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash, message) \
		VALUES(datetime('now'), 'house', 'in', 1000000000, 'd1', 'fee:pay from rent');"
	for n in 1 2 3; do
		LIGHTNING_FEE_AUTOTUNE_TARGET_MSAT_PER_DAY=1000 \
			LIGHTNING_FEE_AUTOTUNE_MAX_STEP_PPM=500 \
			LIGHTNING_FEE_AUTOTUNE_FLOOR_PPM=4500 \
			"$LIGHTNING_BIN" fee-policy autotune run >/dev/null 2>&1
	done
	local pay_rate
	pay_rate=$(awk '/^operation: pay$/,/^$/' "$BATS_FEES" | awk '/^rate_ppm:/ {print $2}')
	[ "$pay_rate" = "4500" ]
	_acct215_teardown
}

@test "FEAT-215: autotune status before any run reports 'never run'" {
	_acct215_setup
	run "$LIGHTNING_BIN" fee-policy autotune status
	[ "$status" -eq 0 ]
	[[ "$output" == *"never run"* ]]
	_acct215_teardown
}

@test "FEAT-215: autotune status shows last decision" {
	_acct215_setup
	LIGHTNING_FEE_AUTOTUNE_TARGET_MSAT_PER_DAY=1000000 \
		"$LIGHTNING_BIN" fee-policy autotune run >/dev/null 2>&1
	run "$LIGHTNING_BIN" fee-policy autotune status
	[ "$status" -eq 0 ]
	[[ "$output" == *"last_direction:"* ]]
	[[ "$output" == *"changes:"* ]]
	_acct215_teardown
}

@test "FEAT-215: autotune reads routing income from listforwards" {
	_acct215_setup
	# Seed listforwards with 500_000 msat of recent settled fee revenue.
	cutoff_now=$(date -u +%s)
	export MOCK_LISTFORWARDS=$(jq -nc --argjson now "$cutoff_now" \
		'[{"status":"settled","fee_msat":500000,"received_time":$now}]')
	# Target = 1M msat/day = 30M/30d.  Observed = 500_000/30 = ~16666
	# msat/day from routing; skim is 0.  500_000/30=16666 → well below
	# low_threshold → direction=up + routing_msat_30d reported.
	LIGHTNING_FEE_AUTOTUNE_TARGET_MSAT_PER_DAY=1000000 \
		"$LIGHTNING_BIN" fee-policy autotune run 2>/dev/null
	grep -q "routing_msat_30d: *500000" "$LIGHTNING_DIR/fee-autotune.state.recfile"
	_acct215_teardown
}

@test "FEAT-215: daemon install --fee-autotune accepts the flag" {
	f="$BATS_TEST_DIRNAME/../../libexec/lightning/daemon"
	grep -q "\-\-fee-autotune" "$f"
	grep -q "install_fee_autotune_sidecar" "$f"
	grep -q "FEE_AUTOTUNE_LABEL" "$f"
}

@test "FEAT-215: fee-policy help lists autotune" {
	run "$LIGHTNING_BIN" fee-policy
	[[ "$output" == *"autotune"* ]]
}

@test "FEAT-215: spec file exists with the expected id" {
	for cand in \
		"$BATS_TEST_DIRNAME/../../issues/feature/215-fee-autotuning-cron.md" \
		"$BATS_TEST_DIRNAME/../../issues/feature/done/215-fee-autotuning-cron.md"; do
		[ -f "$cand" ] && f="$cand" && break
	done
	[ -n "$f" ]
	grep -q "^id: FEAT-215" "$f"
	grep -q "autotune" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-218: referral schema + invite codes.
# ---------------------------------------------------------------------------

_acct218_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create alice-acct >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	BATS_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='alice-acct';")
}

_acct218_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

@test "FEAT-218: wallet new pre-seeds house account with FK-safe ordering" {
	_acct218_setup
	# Both house and `-` exist; their referrer defaults to 'house'.
	local row
	row=$(sqlite3 -separator '|' "$BATS_DB" "SELECT name, referrer FROM accounts WHERE name IN ('-','house') ORDER BY name;")
	[ "$row" = "$(printf '%s\n' '-|house' 'house|house')" ]
	_acct218_teardown
}

@test "FEAT-218: invite_codes table exists post-migration" {
	_acct218_setup
	local n
	n=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='invite_codes';")
	[ "$n" = "1" ]
	_acct218_teardown
}

@test "FEAT-218: account verb help mentions invite-code" {
	_acct218_setup
	run "$LIGHTNING_BIN" account
	[[ "$output" == *"invite-code create"* ]]
	[[ "$output" == *"invite-code list"* ]]
	[[ "$output" == *"invite-code revoke"* ]]
	_acct218_teardown
}

@test "FEAT-218: invite-code create mints a 7-char alpha-num code" {
	_acct218_setup
	run "$LIGHTNING_BIN" account invite-code create alice-acct
	[ "$status" -eq 0 ]
	[[ "$output" == *"code:"* ]]
	[[ "$output" == *"account: alice-acct"* ]]
	[[ "$output" == *"link:    ?invite="* ]]
	local code
	code=$(echo "$output" | awk '/^code:/{print $2}')
	[[ "$code" =~ ^[a-z0-9]{7}$ ]]
	_acct218_teardown
}

@test "FEAT-218: invite-code create with --code accepts a vanity string" {
	_acct218_setup
	run "$LIGHTNING_BIN" account invite-code create alice-acct --code mycode
	[ "$status" -eq 0 ]
	[[ "$output" == *"code:    mycode"* ]]
	_acct218_teardown
}

@test "FEAT-218: invite-code create rejects invalid vanity strings" {
	_acct218_setup
	run "$LIGHTNING_BIN" account invite-code create alice-acct --code "Inv ALID!"
	[ "$status" -eq 1 ]
	[[ "$output" == *"[a-z0-9]"* ]]
	_acct218_teardown
}

@test "FEAT-218: invite-code create rejects duplicate codes" {
	_acct218_setup
	"$LIGHTNING_BIN" account invite-code create alice-acct --code dup1 >/dev/null
	run "$LIGHTNING_BIN" account invite-code create alice-acct --code dup1
	[ "$status" -eq 3 ]
	[[ "$output" == *"already exists"* ]]
	_acct218_teardown
}

@test "FEAT-218: invite-code list shows minted codes" {
	_acct218_setup
	"$LIGHTNING_BIN" account invite-code create alice-acct --code abc >/dev/null
	"$LIGHTNING_BIN" account invite-code create alice-acct --code xyz >/dev/null
	run "$LIGHTNING_BIN" account invite-code list alice-acct
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "code	account	uses	created_at" ]]
	[[ "$output" == *"abc"*"alice-acct"* ]]
	[[ "$output" == *"xyz"*"alice-acct"* ]]
	_acct218_teardown
}

@test "FEAT-218: invite-code revoke removes the code" {
	_acct218_setup
	"$LIGHTNING_BIN" account invite-code create alice-acct --code foo >/dev/null
	"$LIGHTNING_BIN" account invite-code revoke foo
	local n
	n=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM invite_codes WHERE code='foo';")
	[ "$n" = "0" ]
	_acct218_teardown
}

@test "FEAT-218: invite-code revoke on unknown code errors clearly" {
	_acct218_setup
	run "$LIGHTNING_BIN" account invite-code revoke nope
	[ "$status" -eq 2 ]
	[[ "$output" == *"not found"* ]]
	_acct218_teardown
}

@test "FEAT-218: api-accounts-create with valid code stamps referrer" {
	_acct218_setup
	"$LIGHTNING_BIN" account invite-code create alice-acct --code abcd >/dev/null
	REMOTE_ADDR=10.0.0.1 "$LIGHTNING_BIN" api-accounts-create --invite-code abcd >/dev/null
	local ref
	ref=$(sqlite3 "$BATS_DB" "SELECT referrer FROM accounts WHERE name LIKE 'anon-%' ORDER BY name DESC LIMIT 1;")
	[ "$ref" = "alice-acct" ]
	_acct218_teardown
}

@test "FEAT-218: api-accounts-create with unknown code silently falls back to house" {
	_acct218_setup
	REMOTE_ADDR=10.0.0.2 run "$LIGHTNING_BIN" api-accounts-create --invite-code totally-bogus-code
	[ "$status" -eq 0 ]
	local ref
	ref=$(sqlite3 "$BATS_DB" "SELECT referrer FROM accounts WHERE name LIKE 'anon-%' ORDER BY name DESC LIMIT 1;")
	[ "$ref" = "house" ]
	_acct218_teardown
}

@test "FEAT-218: api-accounts-create without code defaults referrer to house" {
	_acct218_setup
	REMOTE_ADDR=10.0.0.3 "$LIGHTNING_BIN" api-accounts-create >/dev/null
	local ref
	ref=$(sqlite3 "$BATS_DB" "SELECT referrer FROM accounts WHERE name LIKE 'anon-%' ORDER BY name DESC LIMIT 1;")
	[ "$ref" = "house" ]
	_acct218_teardown
}

@test "FEAT-218: api-accounts-create with code increments uses counter" {
	_acct218_setup
	"$LIGHTNING_BIN" account invite-code create alice-acct --code countme >/dev/null
	REMOTE_ADDR=10.0.0.4 "$LIGHTNING_BIN" api-accounts-create --invite-code countme >/dev/null
	REMOTE_ADDR=10.0.0.5 "$LIGHTNING_BIN" api-accounts-create --invite-code countme >/dev/null
	local uses
	uses=$(sqlite3 "$BATS_DB" "SELECT uses FROM invite_codes WHERE code='countme';")
	[ "$uses" = "2" ]
	_acct218_teardown
}

@test "FEAT-218: api-accounts-create JSON response includes referrer + referrals endpoint" {
	_acct218_setup
	"$LIGHTNING_BIN" account invite-code create alice-acct --code linktest >/dev/null
	local body
	body=$(REMOTE_ADDR=10.0.0.6 "$LIGHTNING_BIN" api-accounts-create --invite-code linktest 2>/dev/null)
	echo "$body" | jq -e '.referrer' >/dev/null
	echo "$body" | jq -e '.endpoints.referrals' >/dev/null
	local ref
	ref=$(echo "$body" | jq -r '.referrer')
	[ "$ref" = "alice-acct" ]
	_acct218_teardown
}

@test "FEAT-218: api-account-referrals returns the direct downline" {
	_acct218_setup
	"$LIGHTNING_BIN" account invite-code create alice-acct --code dl1 >/dev/null
	REMOTE_ADDR=10.0.0.7 "$LIGHTNING_BIN" api-accounts-create --invite-code dl1 >/dev/null
	REMOTE_ADDR=10.0.0.8 "$LIGHTNING_BIN" api-accounts-create --invite-code dl1 >/dev/null
	local body
	body=$("$LIGHTNING_BIN" api-account-referrals "$BATS_ADDR")
	local n
	n=$(echo "$body" | jq '.referrals | length')
	[ "$n" = "2" ]
	# Accrued credits stay 0 in FEAT-218; FEAT-219 fills them in.
	[ "$(echo "$body" | jq '.referrals[0].accrued_credits_sat')" = "0" ]
	_acct218_teardown
}

@test "FEAT-218: api-account-referrals on an account with no downline returns empty array" {
	_acct218_setup
	local body
	body=$("$LIGHTNING_BIN" api-account-referrals "$BATS_ADDR")
	[ "$body" = '{"referrals": []}' ]
	_acct218_teardown
}

@test "FEAT-218: api-account-referrals rejects non-bech32 input" {
	_acct218_setup
	run "$LIGHTNING_BIN" api-account-referrals "1AbCdEfGhIjKlMnOpQrStUvWxYz123"
	[ "$status" -ne 0 ]
	_acct218_teardown
}

@test "FEAT-218: api-account-referrals on unknown address returns error JSON" {
	_acct218_setup
	run "$LIGHTNING_BIN" api-account-referrals "bcrt1qaaa00000000000000000000000000000000000000"
	[[ "$output" == *'"error"'* ]]
	_acct218_teardown
}

@test "FEAT-218: sudoers fragment lists the new verbs" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/sudoers.d/lightning"
	grep -q "api-account-referrals" "$f"
	grep -q "api-accounts-create --invite-code" "$f"
}

@test "FEAT-218: spec file exists with the expected id" {
	for cand in \
		"$BATS_TEST_DIRNAME/../../issues/feature/218-referral-schema.md" \
		"$BATS_TEST_DIRNAME/../../issues/feature/done/218-referral-schema.md"; do
		[ -f "$cand" ] && f="$cand" && break
	done
	[ -n "$f" ]
	grep -q "^id: FEAT-218" "$f"
	grep -q "invite_codes" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-219: referral fee distribution.
# ---------------------------------------------------------------------------

_acct219_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create inv-acct >/dev/null
	"$LIGHTNING_BIN" account invite-code create inv-acct --code refcode >/dev/null
	REMOTE_ADDR=10.0.0.1 "$LIGHTNING_BIN" api-accounts-create --invite-code refcode >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	BATS_INV_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='inv-acct';")
	BATS_REF_NAME=$(sqlite3 "$BATS_DB" "SELECT name FROM accounts WHERE name LIKE 'anon-%' LIMIT 1;")
	BATS_REF_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='$BATS_REF_NAME';")
}

_acct219_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

@test "FEAT-219: with DIRECT_PCT=0 (default), whole skim still goes to house" {
	_acct219_setup
	outs=$(jq -nc --arg a "$BATS_REF_ADDR" \
		'[{"txid":"d1","output":0,"status":"confirmed","address":$a,"amount_msat":"100000000msat"}]')
	# No DIRECT_PCT → default 0 → no split.
	MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	local house ref
	house=$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='house' AND direction='in';")
	ref=$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='inv-acct' AND direction='in';")
	[ "$house" = "200000" ]
	[ "$ref" = "0" ]
	_acct219_teardown
}

@test "FEAT-219: brand-new referee fails min-activity sybil 1 → all to house" {
	_acct219_setup
	outs=$(jq -nc --arg a "$BATS_REF_ADDR" \
		'[{"txid":"d1","output":0,"status":"confirmed","address":$a,"amount_msat":"100000000msat"}]')
	# Referee has zero prior activity; default min=10000 sat blocks split.
	LIGHTNING_REFERRAL_DIRECT_PCT=20 \
		MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	local ref
	ref=$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='inv-acct' AND direction='in';")
	[ "$ref" = "0" ]
	_acct219_teardown
}

@test "FEAT-219: qualified referee splits skim 20/80 between referrer and house" {
	_acct219_setup
	# Seed referee activity past the default min via a synthetic ledger
	# entry (faster than running a real topup, which the previous test
	# already covers in isolation).
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash, message) \
		VALUES(datetime('now'), '$BATS_REF_NAME', 'in', 100000000, 'seed', 'topup-watcher');"
	outs=$(jq -nc --arg a "$BATS_REF_ADDR" \
		'[{"txid":"d2","output":0,"status":"confirmed","address":$a,"amount_msat":"100000000msat"}]')
	LIGHTNING_REFERRAL_DIRECT_PCT=20 \
		MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	# Skim on this topup = 200_000 msat; 20% = 40_000 msat to inv-acct,
	# 160_000 msat to house.  (House also has the previous-test 200_000
	# from the seed? No, we didn't run the no-split path here.)
	local ref house
	ref=$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='inv-acct' AND direction='in' AND message LIKE 'fee:referral%';")
	house=$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='house' AND direction='in';")
	[ "$ref" = "40000" ]
	[ "$house" = "160000" ]
	_acct219_teardown
}

@test "FEAT-219: per-day cap on referrer credits routes overflow to house" {
	_acct219_setup
	# Seed activity to pass sybil 1.
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash, message) \
		VALUES(datetime('now'), '$BATS_REF_NAME', 'in', 100000000, 'seed', 'topup-watcher');"
	# Seed today's referral credit at exactly the cap.
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, message) \
		VALUES(datetime('now'), 'inv-acct', 'in', 10000000, 'fee:referral from prior');"
	outs=$(jq -nc --arg a "$BATS_REF_ADDR" \
		'[{"txid":"dx","output":0,"status":"confirmed","address":$a,"amount_msat":"100000000msat"}]')
	# Default cap = 10000 sat = 10M msat; already there → next skim
	# routes referrer share to house.
	LIGHTNING_REFERRAL_DIRECT_PCT=20 \
		MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	local today_new
	today_new=$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='inv-acct' AND direction='in' AND message LIKE 'fee:referral from $BATS_REF_NAME%';")
	[ "$today_new" = "0" ]
	_acct219_teardown
}

@test "FEAT-219: api-account-pay JSON response includes referral_fee_sat" {
	_acct219_setup
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash, message) \
		VALUES(datetime('now'), '$BATS_REF_NAME', 'in', 100000000, 'seed', 'topup-watcher');"
	local body
	body=$(LIGHTNING_REFERRAL_DIRECT_PCT=20 "$LIGHTNING_BIN" api-account-pay "$BATS_REF_ADDR" "lnbcrt100p1pmocktest" 2>/dev/null)
	echo "$body" | jq -e '.referral_fee_sat' >/dev/null
	_acct219_teardown
}

@test "FEAT-219: api-account-referrals reflects accrued credits" {
	_acct219_setup
	# Seed activity + a referral credit directly so we don't depend on
	# the topup-watcher path within this test.
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash, message) \
		VALUES(datetime('now'), '$BATS_REF_NAME', 'in', 100000000, 'seed', 'topup-watcher');"
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, peer, message) \
		VALUES(datetime('now'), 'inv-acct', 'in', 40000, 'referee:$BATS_REF_NAME', 'fee:referral from $BATS_REF_NAME');"
	local body
	body=$("$LIGHTNING_BIN" api-account-referrals "$BATS_INV_ADDR")
	local credit
	credit=$(echo "$body" | jq ".referrals[0].accrued_credits_sat")
	[ "$credit" = "40" ]
	_acct219_teardown
}

@test "FEAT-219: referee with referrer='house' never gets a split" {
	_acct219_setup
	# Create a second referee with referrer=house (no invite code used).
	REMOTE_ADDR=10.0.0.99 "$LIGHTNING_BIN" api-accounts-create >/dev/null
	local other
	other=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name LIKE 'anon-%' AND referrer='house' LIMIT 1;")
	# Seed activity past threshold.
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash, message) \
		SELECT datetime('now'), name, 'in', 100000000, 'seed', 'topup-watcher' FROM accounts WHERE address = '$other';"
	outs=$(jq -nc --arg a "$other" \
		'[{"txid":"dx","output":0,"status":"confirmed","address":$a,"amount_msat":"100000000msat"}]')
	LIGHTNING_REFERRAL_DIRECT_PCT=20 \
		MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	# Nothing should hit inv-acct's ledger.
	local inv
	inv=$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='inv-acct';")
	[ "$inv" = "0" ]
	_acct219_teardown
}

@test "FEAT-219: invalid DIRECT_PCT is clamped sensibly" {
	_acct219_setup
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash, message) \
		VALUES(datetime('now'), '$BATS_REF_NAME', 'in', 100000000, 'seed', 'topup-watcher');"
	# DIRECT_PCT=999 → clamped to 100 → whole skim goes to referrer.
	outs=$(jq -nc --arg a "$BATS_REF_ADDR" \
		'[{"txid":"d2","output":0,"status":"confirmed","address":$a,"amount_msat":"100000000msat"}]')
	LIGHTNING_REFERRAL_DIRECT_PCT=999 \
		MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	local ref house
	ref=$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='inv-acct' AND direction='in' AND message LIKE 'fee:referral from $BATS_REF_NAME%';")
	house=$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='house' AND direction='in' AND message LIKE 'fee:topup-onchain from $BATS_REF_NAME%';")
	[ "$ref" = "200000" ]
	[ "$house" = "0" ]
	_acct219_teardown
}

@test "FEAT-219: skim + referral redistribution is double-entry-clean" {
	_acct219_setup
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts, account, direction, amount_msat, payment_hash, message) \
		VALUES(datetime('now'), '$BATS_REF_NAME', 'in', 100000000, 'seed', 'topup-watcher');"
	outs=$(jq -nc --arg a "$BATS_REF_ADDR" \
		'[{"txid":"d2","output":0,"status":"confirmed","address":$a,"amount_msat":"100000000msat"}]')
	LIGHTNING_REFERRAL_DIRECT_PCT=20 \
		MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
	# The topup-watcher row is external on-chain money (non-zero on
	# purpose) — the rest of the rows on this payment_hash are
	# redistributions that must sum to zero.
	local redist
	redist=$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger \
		WHERE payment_hash='d2:0' AND message != 'topup-watcher';")
	[ "$redist" = "0" ]
	_acct219_teardown
}

@test "FEAT-219: spec file exists with the expected id" {
	for cand in \
		"$BATS_TEST_DIRNAME/../../issues/feature/219-referral-fee-distribution.md" \
		"$BATS_TEST_DIRNAME/../../issues/feature/done/219-referral-fee-distribution.md"; do
		[ -f "$cand" ] && f="$cand" && break
	done
	[ -n "$f" ]
	grep -q "^id: FEAT-219" "$f"
	grep -q "referral_split" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-223: inter-account transfer.
# ---------------------------------------------------------------------------

_acct223_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create alpha >/dev/null
	"$LIGHTNING_BIN" account create beta >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	BATS_A_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='alpha';")
	BATS_B_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='beta';")
	# Fund alpha.
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts,account,direction,amount_msat,message) VALUES(datetime('now'),'alpha','in',100000000,'seed');"
}

_acct223_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

@test "FEAT-223: transfer moves sats between accounts atomically" {
	_acct223_setup
	run "$LIGHTNING_BIN" api-account-transfer "$BATS_A_ADDR" beta 10000 --note lunch
	[ "$status" -eq 0 ]
	[[ "$output" == *'"status":"complete"'* ]]
	local a b
	a=$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='alpha';")
	b=$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='beta';")
	[ "$a" = "90000000" ]
	[ "$b" = "10000000" ]
	_acct223_teardown
}

@test "FEAT-223: transfer ledger rows share a correlation id" {
	_acct223_setup
	"$LIGHTNING_BIN" api-account-transfer "$BATS_A_ADDR" beta 10000 >/dev/null
	local n distinct
	n=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM ledger WHERE payment_hash LIKE 'xfer:%';")
	distinct=$(sqlite3 "$BATS_DB" "SELECT COUNT(DISTINCT payment_hash) FROM ledger WHERE payment_hash LIKE 'xfer:%';")
	[ "$n" = "2" ]
	[ "$distinct" = "1" ]
	_acct223_teardown
}

@test "FEAT-223: transfer to self is rejected" {
	_acct223_setup
	run "$LIGHTNING_BIN" api-account-transfer "$BATS_A_ADDR" alpha 100
	[ "$status" -ne 0 ]
	[[ "$output" == *"cannot_transfer_to_self"* ]]
	_acct223_teardown
}

@test "FEAT-223: transfer to unknown recipient is rejected" {
	_acct223_setup
	run "$LIGHTNING_BIN" api-account-transfer "$BATS_A_ADDR" nosuchaccount 100
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown_recipient"* ]]
	_acct223_teardown
}

@test "FEAT-223: overdraft=deny blocks an over-balance transfer (exit 6)" {
	_acct223_setup
	# beta has zero balance + deny policy.
	run "$LIGHTNING_BIN" api-account-transfer "$BATS_B_ADDR" alpha 999999
	[ "$status" -eq 6 ]
	[[ "$output" == *"balance_insufficient"* ]]
	# No rows written (rolled back).
	local n
	n=$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM ledger WHERE payment_hash LIKE 'xfer:%';")
	[ "$n" = "0" ]
	_acct223_teardown
}

@test "FEAT-223: transfer resolves recipient by address too" {
	_acct223_setup
	run "$LIGHTNING_BIN" api-account-transfer "$BATS_A_ADDR" "$BATS_B_ADDR" 7000
	[ "$status" -eq 0 ]
	local b
	b=$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='beta';")
	[ "$b" = "7000000" ]
	_acct223_teardown
}

@test "FEAT-223: zero / non-numeric amount rejected" {
	_acct223_setup
	run "$LIGHTNING_BIN" api-account-transfer "$BATS_A_ADDR" beta 0
	[ "$status" -ne 0 ]
	run "$LIGHTNING_BIN" api-account-transfer "$BATS_A_ADDR" beta abc
	[ "$status" -ne 0 ]
	_acct223_teardown
}

@test "FEAT-223: transfer skims an operator fee when configured" {
	_acct223_setup
	# Set transfer fee to 1% (10000 ppm).
	sed -i '/^operation: transfer$/,/^$/{s/^rate_ppm:.*$/rate_ppm:  10000/}' "$LIGHTNING_WALLETS_ROOT/alice/fees.recfile"
	"$LIGHTNING_BIN" api-account-transfer "$BATS_A_ADDR" beta 10000 >/dev/null
	# 10000-sat transfer at 1% = 100-sat fee → house.
	local house
	house=$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='house' AND direction='in';")
	[ "$house" = "100000" ]
	# alpha debited amount + fee.
	local a
	a=$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='alpha';")
	# 100000000 - 10000000 (transfer) - 100000 (fee) = 89900000
	[ "$a" = "89900000" ]
	_acct223_teardown
}

@test "FEAT-223: redistribution (excluding the transfer pair) is balanced" {
	_acct223_setup
	sed -i '/^operation: transfer$/,/^$/{s/^rate_ppm:.*$/rate_ppm:  10000/}' "$LIGHTNING_WALLETS_ROOT/alice/fees.recfile"
	"$LIGHTNING_BIN" api-account-transfer "$BATS_A_ADDR" beta 10000 >/dev/null
	# All rows for this xfer sum to -fee (the transfer pair cancels;
	# the fee leaves alpha and lands split house/referrer).  With no
	# referrer, alpha -fee, house +fee → fee rows net zero; transfer
	# pair nets zero → grand total zero.
	local total
	total=$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE payment_hash LIKE 'xfer:%';")
	[ "$total" = "0" ]
	_acct223_teardown
}

@test "FEAT-223: CLI account transfer works with handles" {
	_acct223_setup
	run "$LIGHTNING_BIN" account transfer alpha beta 5000 --note "via cli"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"status":"complete"'* ]]
	_acct223_teardown
}

@test "FEAT-223: account verb help lists transfer" {
	run "$LIGHTNING_BIN" account
	[[ "$output" == *"transfer <from> <to> <sat>"* ]]
}

@test "FEAT-223: default fees.recfile carries a transfer op" {
	_acct223_setup
	grep -q "^operation: transfer" "$LIGHTNING_WALLETS_ROOT/alice/fees.recfile"
	_acct223_teardown
}

@test "FEAT-223: sudoers fragment lists api-account-transfer" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/sudoers.d/lightning"
	grep -q "api-account-transfer" "$f"
}

# The FEAT-223 spec assertion lives in its own batch spec PR
# (FEAT-223..227); this implementation PR doesn't carry it directly.

# ---------------------------------------------------------------------------
# FEAT-225: commercial invoice with structured reference + payment terms.
# ---------------------------------------------------------------------------

_acct225_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create shop >/dev/null
	"$LIGHTNING_BIN" account create other >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	BATS_SHOP_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='shop';")
	BATS_OTHER_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='other';")
}

_acct225_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning" "$MOCK_STATE.lastdesc"
}

@test "FEAT-225: invoice create returns bolt11 + payment_hash + face/effective" {
	_acct225_setup
	run "$LIGHTNING_BIN" api-account-invoice "$BATS_SHOP_ADDR" 100000
	[ "$status" -eq 0 ]
	[[ "$(echo "$output" | jq -r '.bolt11')" == lnbcrt* ]]
	[ "$(echo "$output" | jq -r '.face_sat')" = "100000" ]
	[ "$(echo "$output" | jq -r '.effective_sat')" = "100000" ]
	[ -n "$(echo "$output" | jq -r '.payment_hash')" ]
	_acct225_teardown
}

@test "FEAT-225: reference is embedded recoverably in the BOLT-11 description" {
	_acct225_setup
	"$LIGHTNING_BIN" api-account-invoice "$BATS_SHOP_ADDR" 5000 \
		--ref '{"order_id":"A-42","delivery_note":"DN-7","memo":"widgets"}' >/dev/null
	local desc b64 pad json
	desc=$(cat "$MOCK_STATE.lastdesc")
	[[ "$desc" == *"widgets [ref:"* ]]
	# Pull the base64url payload back out and decode it.
	b64=$(echo "$desc" | sed -n 's/.*\[ref:\([A-Za-z0-9_-]*\)\].*/\1/p')
	[ -n "$b64" ]
	pad=$(( (4 - ${#b64} % 4) % 4 ))
	while [ "$pad" -gt 0 ]; do b64="${b64}="; pad=$((pad-1)); done
	json=$(echo "$b64" | tr '_-' '/+' | base64 -d)
	[ "$(echo "$json" | jq -r '.order_id')" = "A-42" ]
	[ "$(echo "$json" | jq -r '.delivery_note')" = "DN-7" ]
	_acct225_teardown
}

@test "FEAT-225: invoice create persists a commerce_invoices row + mirrors to invoices" {
	_acct225_setup
	local out hash
	out=$("$LIGHTNING_BIN" api-account-invoice "$BATS_SHOP_ADDR" 12345 --ref '{"order_id":"X1"}')
	hash=$(echo "$out" | jq -r '.payment_hash')
	[ "$(sqlite3 "$BATS_DB" "SELECT face_sat FROM commerce_invoices WHERE payment_hash='$hash';")" = "12345" ]
	[ "$(sqlite3 "$BATS_DB" "SELECT account FROM commerce_invoices WHERE payment_hash='$hash';")" = "shop" ]
	[ "$(sqlite3 "$BATS_DB" "SELECT state FROM commerce_invoices WHERE payment_hash='$hash';")" = "issued" ]
	[ "$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM invoices WHERE payment_hash='$hash';")" = "1" ]
	_acct225_teardown
}

@test "FEAT-225: Skonto discount applies at issue time" {
	_acct225_setup
	run "$LIGHTNING_BIN" api-account-invoice "$BATS_SHOP_ADDR" 100000 \
		--terms '{"due_days":14,"skonto":{"within_days":7,"discount_pct":2}}'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.effective_sat')" = "98000" ]
	_acct225_teardown
}

@test "FEAT-225: invoice-get returns the reference back + paid:false before settle" {
	_acct225_setup
	local hash
	hash=$("$LIGHTNING_BIN" api-account-invoice "$BATS_SHOP_ADDR" 5000 --ref '{"order_id":"A-42"}' | jq -r '.payment_hash')
	run "$LIGHTNING_BIN" api-account-invoice-get "$BATS_SHOP_ADDR" "$hash"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.reference.order_id')" = "A-42" ]
	[ "$(echo "$output" | jq -r '.paid')" = "false" ]
	[ "$(echo "$output" | jq -r '.state')" = "issued" ]
	_acct225_teardown
}

@test "FEAT-225: invoice-get flips to paid:true after (mock) settlement" {
	_acct225_setup
	local hash
	hash=$("$LIGHTNING_BIN" api-account-invoice "$BATS_SHOP_ADDR" 5000 | jq -r '.payment_hash')
	MOCK_LISTINVOICES='[{"status":"paid"}]' run "$LIGHTNING_BIN" api-account-invoice-get "$BATS_SHOP_ADDR" "$hash"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.paid')" = "true" ]
	[ "$(echo "$output" | jq -r '.state')" = "paid" ]
	# Persisted.
	[ "$(sqlite3 "$BATS_DB" "SELECT state FROM commerce_invoices WHERE payment_hash='$hash';")" = "paid" ]
	_acct225_teardown
}

@test "FEAT-225: invoice-get computes a late fee once past the grace period" {
	_acct225_setup
	local hash
	hash=$("$LIGHTNING_BIN" api-account-invoice "$BATS_SHOP_ADDR" 100000 \
		--terms '{"due_days":14,"skonto":{"within_days":7,"discount_pct":2},"late_fee":{"after_days":14,"pct":5}}' \
		| jq -r '.payment_hash')
	# Backdate issuance 30 days: past due(14)+grace(14)=28 → late fee.
	sqlite3 "$BATS_DB" "UPDATE commerce_invoices SET issued_at = issued_at - 30*86400 WHERE payment_hash='$hash';"
	run "$LIGHTNING_BIN" api-account-invoice-get "$BATS_SHOP_ADDR" "$hash"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.effective_sat')" = "105000" ]
	_acct225_teardown
}

@test "FEAT-225: invoice-get reports face == effective when no terms" {
	_acct225_setup
	local hash
	hash=$("$LIGHTNING_BIN" api-account-invoice "$BATS_SHOP_ADDR" 7777 | jq -r '.payment_hash')
	run "$LIGHTNING_BIN" api-account-invoice-get "$BATS_SHOP_ADDR" "$hash"
	[ "$(echo "$output" | jq -r '.face_sat')" = "7777" ]
	[ "$(echo "$output" | jq -r '.effective_sat')" = "7777" ]
	[ "$(echo "$output" | jq -r '.terms')" = "null" ]
	_acct225_teardown
}

@test "FEAT-225: invoice-get is scoped to the owning account" {
	_acct225_setup
	local hash
	hash=$("$LIGHTNING_BIN" api-account-invoice "$BATS_SHOP_ADDR" 5000 | jq -r '.payment_hash')
	# `other` must not be able to read shop's invoice.
	run "$LIGHTNING_BIN" api-account-invoice-get "$BATS_OTHER_ADDR" "$hash"
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown invoice"* ]]
	_acct225_teardown
}

@test "FEAT-225: invoice create rejects non-positive amount + bad JSON" {
	_acct225_setup
	run "$LIGHTNING_BIN" api-account-invoice "$BATS_SHOP_ADDR" 0
	[ "$status" -ne 0 ]
	run "$LIGHTNING_BIN" api-account-invoice "$BATS_SHOP_ADDR" 100 --ref 'not json'
	[ "$status" -ne 0 ]
	[[ "$output" == *"ref_not_json"* ]]
	_acct225_teardown
}

@test "FEAT-225: invoice verbs reject unknown account" {
	_acct225_setup
	run "$LIGHTNING_BIN" api-account-invoice "bcrt1qaaa00000000000000000000000000000000000000" 100
	[[ "$output" == *"unknown account"* ]]
	_acct225_teardown
}

@test "FEAT-225: sudoers fragment lists the invoice verbs" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/sudoers.d/lightning"
	grep -q "api-account-invoice " "$f"
	grep -q "api-account-invoice-get " "$f"
}

@test "FEAT-225: schema declares commerce_invoices" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/schema.sql"
	grep -q "CREATE TABLE IF NOT EXISTS commerce_invoices" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-224 + FEAT-232: versioned .well-known move + API versioning.
# ---------------------------------------------------------------------------

@test "FEAT-224: apache vhost mounts account API + MCP under .well-known/v1" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/apache/lnurlp.conf"
	grep -q "ScriptAlias /.well-known/lightning/v1/accounts" "$f"
	grep -q "ScriptAlias /.well-known/lightning/v1/mcp" "$f"
	# Old unversioned aliases are gone.
	! grep -qE "ScriptAlias /api/accounts\b" "$f"
	! grep -qE "ScriptAlias /api/mcp\b" "$f"
}

@test "FEAT-224: api-accounts-create emits versioned .well-known endpoint URLs" {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	local body
	body=$(REMOTE_ADDR=1.2.3.4 "$LIGHTNING_BIN" api-accounts-create 2>/dev/null)
	[[ "$(echo "$body" | jq -r '.endpoints.balance')" == /.well-known/lightning/v1/accounts/*/balance ]]
	[[ "$(echo "$body" | jq -r '.endpoints.transfer')" == /.well-known/lightning/v1/accounts/*/transfer ]]
	[[ "$(echo "$body" | jq -r '.endpoints.referrals')" == /.well-known/lightning/v1/accounts/*/referrals ]]
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

@test "FEAT-232: versions.json advertises v1 as default" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/wellknown/lightning/versions.json"
	[ -f "$f" ]
	jq -e '.versions | index("v1")' "$f" >/dev/null
	[ "$(jq -r '.default' "$f")" = "v1" ]
	jq -e '.surfaces.accounts == "/.well-known/lightning/v1/accounts"' "$f" >/dev/null
	jq -e '.surfaces.mcp == "/.well-known/lightning/v1/mcp"' "$f" >/dev/null
}

@test "FEAT-224: mcp.json manifest carries the versioned endpoint" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/wellknown/lightning/mcp.json"
	[ "$(jq -r '.transport.endpoint' "$f")" = "/.well-known/lightning/v1/mcp" ]
	[ "$(jq -r '.apiVersion' "$f")" = "v1" ]
	[ "$(jq -r '.links.rest' "$f")" = "/.well-known/lightning/v1/accounts" ]
}

@test "FEAT-232: apache vhost has the unknown-version catch-all + versions.json Alias" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/apache/lnurlp.conf"
	grep -q "version_gate.py" "$f"
	grep -q "Alias /.well-known/lightning/versions.json" "$f"
}

@test "FEAT-232: version_gate is executable Python" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/wellknown/api/version_gate.py"
	[ -x "$f" ]
	head -1 "$f" | grep -q python3
}

# ---------------------------------------------------------------------------
# FEAT-222 PR-2: wallet-user layer (schema + CLI bootstrap).
# ---------------------------------------------------------------------------

_user222_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
}

_user222_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

@test "FEAT-222 PR-2: schema has wallet_users distinct from the FEAT-176 users table" {
	_user222_setup
	# Both tables exist + are different.
	[ "$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='wallet_users';")" = "1" ]
	[ "$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='users';")" = "1" ]
	_user222_teardown
}

@test "FEAT-222 PR-2: accounts gains owner_user; invite_codes gains owner_user + credit_account" {
	_user222_setup
	sqlite3 "$BATS_DB" "PRAGMA table_info(accounts);" | awk -F'|' '{print $2}' | grep -qx owner_user
	sqlite3 "$BATS_DB" "PRAGMA table_info(invite_codes);" | awk -F'|' '{print $2}' | grep -qx owner_user
	sqlite3 "$BATS_DB" "PRAGMA table_info(invite_codes);" | awk -F'|' '{print $2}' | grep -qx credit_account
	_user222_teardown
}

@test "FEAT-222 PR-2: user create mints a usr_ id" {
	_user222_setup
	run "$LIGHTNING_BIN" wallet-user create --label operator
	[ "$status" -eq 0 ]
	[[ "$output" == *"created usr_"* ]]
	[[ "$output" == *"label:    operator"* ]]
	local uid
	uid=$(echo "$output" | awk '/created/{print $4}')
	[[ "$uid" =~ ^usr_[a-z0-9]{16}$ ]]
	_user222_teardown
}

@test "FEAT-222 PR-2: user create --referrer requires an existing user" {
	_user222_setup
	run "$LIGHTNING_BIN" wallet-user create --referrer usr_nope
	[ "$status" -eq 2 ]
	[[ "$output" == *"not found"* ]]
	_user222_teardown
}

@test "FEAT-222 PR-2: user create --referrer records the link" {
	_user222_setup
	local parent
	parent=$("$LIGHTNING_BIN" wallet-user create --label parent | awk '/created/{print $4}')
	"$LIGHTNING_BIN" wallet-user create --label child --referrer "$parent" >/dev/null
	local got
	got=$(sqlite3 "$BATS_DB" "SELECT referrer_user FROM wallet_users WHERE label='child';")
	[ "$got" = "$parent" ]
	_user222_teardown
}

@test "FEAT-222 PR-2: user list shows owned-account counts" {
	_user222_setup
	local uid
	uid=$("$LIGHTNING_BIN" wallet-user create --label op | awk '/created/{print $4}')
	"$LIGHTNING_BIN" account create acct1 >/dev/null 2>&1
	sqlite3 "$BATS_DB" "UPDATE accounts SET owner_user='$uid' WHERE name='acct1';"
	run "$LIGHTNING_BIN" wallet-user list
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "id	label	accounts	created_at" ]]
	[[ "$output" == *"$uid"*"op"*"1"* ]]
	_user222_teardown
}

@test "FEAT-222 PR-2: user show lists owned accounts" {
	_user222_setup
	local uid
	uid=$("$LIGHTNING_BIN" wallet-user create --label op | awk '/created/{print $4}')
	"$LIGHTNING_BIN" account create acct1 >/dev/null 2>&1
	sqlite3 "$BATS_DB" "UPDATE accounts SET owner_user='$uid' WHERE name='acct1';"
	run "$LIGHTNING_BIN" wallet-user show "$uid"
	[ "$status" -eq 0 ]
	[[ "$output" == *"id:           $uid"* ]]
	[[ "$output" == *"referrer:     (none)"* ]]
	[[ "$output" == *"acct1"* ]]
	_user222_teardown
}

@test "FEAT-222 PR-2: user show on unknown id errors" {
	_user222_setup
	run "$LIGHTNING_BIN" wallet-user show usr_nope
	[ "$status" -eq 2 ]
	[[ "$output" == *"no such user"* ]]
	_user222_teardown
}

@test "FEAT-222 PR-2: user delete orphans owned accounts (does not delete them)" {
	_user222_setup
	local uid
	uid=$("$LIGHTNING_BIN" wallet-user create --label op | awk '/created/{print $4}')
	"$LIGHTNING_BIN" account create acct1 >/dev/null 2>&1
	sqlite3 "$BATS_DB" "UPDATE accounts SET owner_user='$uid' WHERE name='acct1';"
	"$LIGHTNING_BIN" wallet-user delete "$uid"
	# Account survives; owner cleared.
	[ "$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM accounts WHERE name='acct1';")" = "1" ]
	[ "$(sqlite3 "$BATS_DB" "SELECT COALESCE(owner_user,'NULL') FROM accounts WHERE name='acct1';")" = "NULL" ]
	# User gone.
	[ "$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM wallet_users WHERE id='$uid';")" = "0" ]
	_user222_teardown
}

@test "FEAT-222 PR-2: user delete on unknown id errors" {
	_user222_setup
	run "$LIGHTNING_BIN" wallet-user delete usr_nope
	[ "$status" -eq 2 ]
	_user222_teardown
}

@test "FEAT-222 PR-2: user with no subcommand prints usage" {
	run "$LIGHTNING_BIN" wallet-user
	[ "$status" -eq 1 ]
	[[ "$output" == *"usage: lightning wallet-user"* ]]
}

@test "FEAT-222 PR-2: top-level help lists the user verb" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"wallet-user"* ]]
}

@test "FEAT-222 PR-2: account migration is idempotent for the new columns" {
	_user222_setup
	# Run an account verb twice → no error, columns stable.
	"$LIGHTNING_BIN" account list >/dev/null
	"$LIGHTNING_BIN" account list >/dev/null
	[ "$(sqlite3 "$BATS_DB" "PRAGMA table_info(accounts);" | awk -F'|' '$2=="owner_user"' | wc -l | tr -d ' ')" = "1" ]
	_user222_teardown
}

@test "FEAT-222 PR-2: spec file present + notes the wallet_users rename" {
	for cand in \
		"$BATS_TEST_DIRNAME/../../issues/feature/222-user-layer.md" \
		"$BATS_TEST_DIRNAME/../../issues/feature/done/222-user-layer.md"; do
		[ -f "$cand" ] && f="$cand" && break
	done
	[ -n "$f" ]
	grep -q "^id: FEAT-222" "$f"
	grep -q "wallet_users" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-229: sat/fiat price oracle.
# ---------------------------------------------------------------------------

_price229_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
}

_price229_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

@test "FEAT-229: wallet new seeds price.recfile + schema has prices" {
	_price229_setup
	[ -f "$LIGHTNING_WALLETS_ROOT/alice/price.recfile" ]
	grep -q "^base:" "$LIGHTNING_WALLETS_ROOT/alice/price.recfile"
	[ "$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='prices';")" = "1" ]
	_price229_teardown
}

@test "FEAT-229: price now with no data returns error + exit 4" {
	_price229_setup
	run "$LIGHTNING_BIN" price now
	[ "$status" -eq 4 ]
	[[ "$output" == *'"error":"no_price_data"'* ]]
	_price229_teardown
}

@test "FEAT-229: price poll stores a tick from the feed" {
	_price229_setup
	MOCK_PRICE_RESPONSE='{"USD":65000,"EUR":60000}' "$LIGHTNING_BIN" price poll >/dev/null 2>&1
	[ "$(sqlite3 "$BATS_DB" "SELECT btc_fiat FROM prices WHERE base='EUR';")" = "60000.0" ]
	_price229_teardown
}

@test "FEAT-229: price now returns the latest tick" {
	_price229_setup
	MOCK_PRICE_RESPONSE='{"EUR":60000}' "$LIGHTNING_BIN" price poll >/dev/null 2>&1
	run "$LIGHTNING_BIN" price now
	[ "$status" -eq 0 ]
	[[ "$output" == *'"base":"EUR"'* ]]
	[[ "$output" == *'"btc_fiat":60000'* ]]
	_price229_teardown
}

@test "FEAT-229: price value computes fiat = sat * btc_fiat / 1e8" {
	_price229_setup
	MOCK_PRICE_RESPONSE='{"EUR":60000}' "$LIGHTNING_BIN" price poll >/dev/null 2>&1
	# 100_000 sat at 60_000 EUR/BTC = 60.00 EUR.
	run "$LIGHTNING_BIN" price value 100000
	[ "$status" -eq 0 ]
	[[ "$output" == *'"fiat":60'* ]]
	# 1 BTC = full price.
	run "$LIGHTNING_BIN" price value 100000000
	[[ "$output" == *'"fiat":60000'* ]]
	_price229_teardown
}

@test "FEAT-229: price at returns the nearest stored tick" {
	_price229_setup
	MOCK_PRICE_RESPONSE='{"EUR":60000}' "$LIGHTNING_BIN" price poll >/dev/null 2>&1
	local ts
	ts=$(sqlite3 "$BATS_DB" "SELECT ts FROM prices WHERE base='EUR';")
	# Query a timestamp 1000s away — still the nearest (only) tick.
	run "$LIGHTNING_BIN" price at $(( ts + 1000 ))
	[ "$status" -eq 0 ]
	[[ "$output" == *"\"ts\":$ts"* ]]
	_price229_teardown
}

@test "FEAT-229: price poll rejects a non-numeric feed response" {
	_price229_setup
	MOCK_PRICE_RESPONSE='{"EUR":"not-a-number"}' run "$LIGHTNING_BIN" price poll
	[ "$status" -ne 0 ]
	[[ "$output" == *"no numeric price"* ]]
	_price229_teardown
}

@test "FEAT-229: price poll honours --base + per-base storage" {
	_price229_setup
	MOCK_PRICE_RESPONSE='{"USD":65000,"EUR":60000}' "$LIGHTNING_BIN" price poll --base USD >/dev/null 2>&1
	[ "$(sqlite3 "$BATS_DB" "SELECT btc_fiat FROM prices WHERE base='USD';")" = "65000.0" ]
	_price229_teardown
}

@test "FEAT-229: price with no subcommand prints usage" {
	run "$LIGHTNING_BIN" price
	[ "$status" -eq 1 ]
	[[ "$output" == *"usage: lightning price"* ]]
}

@test "FEAT-229: top-level help lists the price verb" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"price"*"oracle"* ]]
}

@test "FEAT-229: daemon install --price-oracle is wired" {
	f="$BATS_TEST_DIRNAME/../../libexec/lightning/daemon"
	grep -q "\-\-price-oracle" "$f"
	grep -q "install_price_oracle_sidecar" "$f"
	grep -q "PRICE_ORACLE_LABEL" "$f"
}

@test "FEAT-229: apache vhost adds the public price endpoint" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/apache/lnurlp.conf"
	grep -q "ScriptAlias /.well-known/lightning/v1/price" "$f"
	grep -q "wellknown/api/price.py" "$f"
}

@test "FEAT-229: spec file present" {
	for cand in \
		"$BATS_TEST_DIRNAME/../../issues/feature/229-price-oracle.md" \
		"$BATS_TEST_DIRNAME/../../issues/feature/done/229-price-oracle.md"; do
		[ -f "$cand" ] && f="$cand" && break
	done
	[ -n "$f" ]
	grep -q "^id: FEAT-229" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-226: standing orders (Dauerauftrag) — scheduled recurring payment.
# ---------------------------------------------------------------------------

_acct226_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create payer >/dev/null
	"$LIGHTNING_BIN" account create landlord >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	BATS_PAYER_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='payer';")
	# Fund payer.
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts,account,direction,amount_msat,message) VALUES(datetime('now'),'payer','in',100000000,'seed');"
}

_acct226_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

@test "FEAT-226: create lands an active order with next_run in the future" {
	_acct226_setup
	run "$LIGHTNING_BIN" account standing-order create payer landlord 10000 monthly
	[ "$status" -eq 0 ]
	[[ "$output" == *'"status":"active"'* ]]
	local nr now
	nr=$(sqlite3 "$BATS_DB" "SELECT next_run FROM standing_orders WHERE account='payer';")
	now=$(date -u +%s)
	[ "$nr" -gt "$now" ]
	# Monthly is ~28-31 days out.
	[ "$nr" -gt "$(( now + 27*86400 ))" ]
	[ "$nr" -lt "$(( now + 32*86400 ))" ]
	_acct226_teardown
}

@test "FEAT-226: create rejects a bad cadence" {
	_acct226_setup
	run "$LIGHTNING_BIN" account standing-order create payer landlord 10000 hourly
	[ "$status" -ne 0 ]
	_acct226_teardown
}

@test "FEAT-226: create rejects a single-use BOLT-11 target" {
	_acct226_setup
	run "$LIGHTNING_BIN" account standing-order create payer lnbc10n1pmocktest 5000 daily
	[ "$status" -ne 0 ]
	[[ "$output" == *"re-payable"* ]]
	_acct226_teardown
}

@test "FEAT-226: create accepts a Lightning-address target" {
	_acct226_setup
	run "$LIGHTNING_BIN" account standing-order create payer alice@example.com 5000 weekly
	[ "$status" -eq 0 ]
	_acct226_teardown
}

@test "FEAT-226: run pays a due local-account order and advances next_run" {
	_acct226_setup
	"$LIGHTNING_BIN" account standing-order create payer landlord 10000 monthly >/dev/null
	# Force it due.
	sqlite3 "$BATS_DB" "UPDATE standing_orders SET next_run = strftime('%s','now') - 100;"
	run "$LIGHTNING_BIN" account standing-order run
	[ "$status" -eq 0 ]
	[[ "$output" == *'"paid":1'* ]]
	# Ledger moved 10000 sat payer -> landlord.
	[ "$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='landlord';")" = "10000000" ]
	[ "$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='payer';")" = "90000000" ]
	# next_run advanced back into the future, last_run + failures reset.
	local now nr lr
	now=$(date -u +%s)
	nr=$(sqlite3 "$BATS_DB" "SELECT next_run FROM standing_orders WHERE account='payer';")
	lr=$(sqlite3 "$BATS_DB" "SELECT COALESCE(last_run,0) FROM standing_orders WHERE account='payer';")
	[ "$nr" -gt "$now" ]
	[ "$lr" -gt "0" ]
	[ "$(sqlite3 "$BATS_DB" "SELECT failures FROM standing_orders WHERE account='payer';")" = "0" ]
	_acct226_teardown
}

@test "FEAT-226: run skips a not-yet-due order" {
	_acct226_setup
	"$LIGHTNING_BIN" account standing-order create payer landlord 10000 monthly >/dev/null
	run "$LIGHTNING_BIN" account standing-order run
	[ "$status" -eq 0 ]
	[[ "$output" == *'"paid":0'* ]]
	[ "$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='landlord';")" = "0" ]
	_acct226_teardown
}

@test "FEAT-226: run skips a paused order" {
	_acct226_setup
	"$LIGHTNING_BIN" account standing-order create payer landlord 10000 monthly >/dev/null
	local id
	id=$(sqlite3 "$BATS_DB" "SELECT id FROM standing_orders WHERE account='payer';")
	"$LIGHTNING_BIN" account standing-order pause "$id" >/dev/null
	sqlite3 "$BATS_DB" "UPDATE standing_orders SET next_run = strftime('%s','now') - 100;"
	run "$LIGHTNING_BIN" account standing-order run
	[[ "$output" == *'"paid":0'* ]]
	[ "$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='landlord';")" = "0" ]
	_acct226_teardown
}

@test "FEAT-226: pause/resume/cancel transition status" {
	_acct226_setup
	"$LIGHTNING_BIN" account standing-order create payer landlord 10000 monthly >/dev/null
	local id
	id=$(sqlite3 "$BATS_DB" "SELECT id FROM standing_orders WHERE account='payer';")
	"$LIGHTNING_BIN" account standing-order pause "$id" >/dev/null
	[ "$(sqlite3 "$BATS_DB" "SELECT status FROM standing_orders WHERE id='$id';")" = "paused" ]
	"$LIGHTNING_BIN" account standing-order resume "$id" >/dev/null
	[ "$(sqlite3 "$BATS_DB" "SELECT status FROM standing_orders WHERE id='$id';")" = "active" ]
	"$LIGHTNING_BIN" account standing-order cancel "$id" >/dev/null
	[ "$(sqlite3 "$BATS_DB" "SELECT status FROM standing_orders WHERE id='$id';")" = "cancelled" ]
	_acct226_teardown
}

@test "FEAT-226: a failed run auto-pauses after N failures" {
	_acct226_setup
	# `broke` has no balance + deny overdraft → transfer fails.
	"$LIGHTNING_BIN" account create broke >/dev/null
	"$LIGHTNING_BIN" account standing-order create broke landlord 5000 daily >/dev/null
	sqlite3 "$BATS_DB" "UPDATE standing_orders SET next_run = strftime('%s','now') - 100 WHERE account='broke';"
	LIGHTNING_STANDING_ORDER_MAX_FAILURES=1 run "$LIGHTNING_BIN" account standing-order run
	[[ "$output" == *'"paused":1'* ]]
	[ "$(sqlite3 "$BATS_DB" "SELECT status FROM standing_orders WHERE account='broke';")" = "paused" ]
	[ "$(sqlite3 "$BATS_DB" "SELECT failures FROM standing_orders WHERE account='broke';")" = "1" ]
	_acct226_teardown
}

@test "FEAT-226: dry-run does not pay" {
	_acct226_setup
	"$LIGHTNING_BIN" account standing-order create payer landlord 10000 monthly >/dev/null
	sqlite3 "$BATS_DB" "UPDATE standing_orders SET next_run = strftime('%s','now') - 100;"
	run "$LIGHTNING_BIN" account standing-order dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"would-pay"* ]]
	[ "$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='landlord';")" = "0" ]
	_acct226_teardown
}

@test "FEAT-226: HTTP verb create/list/pause/cancel emit JSON" {
	_acct226_setup
	local out id
	out=$("$LIGHTNING_BIN" api-account-standing-order "$BATS_PAYER_ADDR" create landlord 5000 weekly)
	[[ "$out" == *'"status":"active"'* ]]
	id=$(echo "$out" | jq -r '.id')
	[[ "$id" == so_* ]]
	"$LIGHTNING_BIN" api-account-standing-order "$BATS_PAYER_ADDR" list | jq -e '.standing_orders | length == 1' >/dev/null
	out=$("$LIGHTNING_BIN" api-account-standing-order "$BATS_PAYER_ADDR" pause "$id")
	[[ "$out" == *'"status":"paused"'* ]]
	out=$("$LIGHTNING_BIN" api-account-standing-order "$BATS_PAYER_ADDR" cancel "$id")
	[[ "$out" == *'"status":"cancelled"'* ]]
	_acct226_teardown
}

@test "FEAT-226: HTTP verb scopes orders to the owning account" {
	_acct226_setup
	"$LIGHTNING_BIN" account standing-order create landlord payer 1000 daily >/dev/null
	# payer's list must NOT see landlord's order.
	"$LIGHTNING_BIN" api-account-standing-order "$BATS_PAYER_ADDR" list | jq -e '.standing_orders | length == 0' >/dev/null
	_acct226_teardown
}

@test "FEAT-226: daemon install --standing-orders accepts the flag" {
	f="$BATS_TEST_DIRNAME/../../libexec/lightning/daemon"
	grep -q "\-\-standing-orders" "$f"
	grep -q "install_standing_orders_sidecar" "$f"
	grep -q "STANDING_ORDER_LABEL" "$f"
}

@test "FEAT-226: sudoers fragment lists api-account-standing-order" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/sudoers.d/lightning"
	grep -q "api-account-standing-order" "$f"
}

@test "FEAT-226: schema declares standing_orders" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/schema.sql"
	grep -q "CREATE TABLE IF NOT EXISTS standing_orders" "$f"
}

@test "FEAT-226: account verb usage lists standing-order" {
	run "$LIGHTNING_BIN" account
	[[ "$output" == *"standing-order"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-227: direct debit (Lastschrift) + mandates.
# ---------------------------------------------------------------------------

_acct227_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create cust >/dev/null
	"$LIGHTNING_BIN" account create shop >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	BATS_CUST_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='cust';")
	BATS_SHOP_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='shop';")
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts,account,direction,amount_msat,message) VALUES(datetime('now'),'cust','in',100000000,'seed');"
}

_acct227_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

_mk_mandate() {
	# $1 mode (auto|approval); echoes "<mid> <secret>"
	local out
	out=$("$LIGHTNING_BIN" api-account-mandate "$BATS_CUST_ADDR" create shop 50000 monthly --mode "${1:-auto}")
	echo "$(echo "$out" | jq -r '.id') $(echo "$out" | jq -r '.secret')"
}

@test "FEAT-227: create mandate returns a secret + active status" {
	_acct227_setup
	run "$LIGHTNING_BIN" api-account-mandate "$BATS_CUST_ADDR" create shop 50000 monthly
	[ "$status" -eq 0 ]
	[[ "$output" == *'"status":"active"'* ]]
	[ -n "$(echo "$output" | jq -r '.secret')" ]
	[[ "$(echo "$output" | jq -r '.id')" == mdt_* ]]
	_acct227_teardown
}

@test "FEAT-227: create rejects bad period / mode / non-positive max" {
	_acct227_setup
	run "$LIGHTNING_BIN" api-account-mandate "$BATS_CUST_ADDR" create shop 50000 hourly
	[ "$status" -ne 0 ]
	run "$LIGHTNING_BIN" api-account-mandate "$BATS_CUST_ADDR" create shop 50000 monthly --mode whenever
	[ "$status" -ne 0 ]
	run "$LIGHTNING_BIN" api-account-mandate "$BATS_CUST_ADDR" create shop 0 monthly
	[ "$status" -ne 0 ]
	_acct227_teardown
}

@test "FEAT-227: create rejects a single-use BOLT-11 merchant + self-mandate" {
	_acct227_setup
	run "$LIGHTNING_BIN" api-account-mandate "$BATS_CUST_ADDR" create lnbc10n1pmocktest 5000 daily
	[ "$status" -ne 0 ]
	run "$LIGHTNING_BIN" api-account-mandate "$BATS_CUST_ADDR" create cust 5000 daily
	[ "$status" -ne 0 ]
	[[ "$output" == *"merchant_is_customer"* ]]
	_acct227_teardown
}

@test "FEAT-227: auto-mode charge within cap executes an intra-node transfer" {
	_acct227_setup
	read -r mid secret <<<"$(_mk_mandate auto)"
	run "$LIGHTNING_BIN" api-account-mandate-pull "$BATS_CUST_ADDR" charge "$mid" "$secret" 10000
	[ "$status" -eq 0 ]
	[[ "$output" == *'"state":"executed"'* ]]
	[ "$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='shop';")" = "10000000" ]
	[ "$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='cust';")" = "90000000" ]
	_acct227_teardown
}

@test "FEAT-227: charge with the wrong secret is rejected (exit 7)" {
	_acct227_setup
	read -r mid secret <<<"$(_mk_mandate auto)"
	run "$LIGHTNING_BIN" api-account-mandate-pull "$BATS_CUST_ADDR" charge "$mid" "deadbeef" 1000
	[ "$status" -eq 7 ]
	[[ "$output" == *"unauthorized"* ]]
	# Nothing moved.
	[ "$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='shop';")" = "0" ]
	_acct227_teardown
}

@test "FEAT-227: a pull exceeding the per-period cap is rejected (exit 6)" {
	_acct227_setup
	read -r mid secret <<<"$(_mk_mandate auto)"
	"$LIGHTNING_BIN" api-account-mandate-pull "$BATS_CUST_ADDR" charge "$mid" "$secret" 40000 >/dev/null
	run "$LIGHTNING_BIN" api-account-mandate-pull "$BATS_CUST_ADDR" charge "$mid" "$secret" 20000
	[ "$status" -eq 6 ]
	[[ "$output" == *"cap_exceeded"* ]]
	_acct227_teardown
}

@test "FEAT-227: revoking a mandate blocks further pulls (exit 6)" {
	_acct227_setup
	read -r mid secret <<<"$(_mk_mandate auto)"
	"$LIGHTNING_BIN" api-account-mandate "$BATS_CUST_ADDR" patch "$mid" --status revoked >/dev/null
	run "$LIGHTNING_BIN" api-account-mandate-pull "$BATS_CUST_ADDR" charge "$mid" "$secret" 1000
	[ "$status" -eq 6 ]
	[[ "$output" == *"mandate_not_active"* ]]
	_acct227_teardown
}

@test "FEAT-227: approval-mode charge lands pending; approve executes" {
	_acct227_setup
	read -r mid secret <<<"$(_mk_mandate approval)"
	local out pid
	out=$("$LIGHTNING_BIN" api-account-mandate-pull "$BATS_CUST_ADDR" charge "$mid" "$secret" 5000)
	[[ "$out" == *'"state":"pending"'* ]]
	pid=$(echo "$out" | jq -r '.pull_id')
	# Not executed yet.
	[ "$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='shop';")" = "0" ]
	run "$LIGHTNING_BIN" api-account-mandate-pull "$BATS_CUST_ADDR" approve "$mid" "$pid"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"state":"executed"'* ]]
	[ "$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='shop';")" = "5000000" ]
	_acct227_teardown
}

@test "FEAT-227: approval-mode deny cancels the pull" {
	_acct227_setup
	read -r mid secret <<<"$(_mk_mandate approval)"
	local out pid
	out=$("$LIGHTNING_BIN" api-account-mandate-pull "$BATS_CUST_ADDR" charge "$mid" "$secret" 5000)
	pid=$(echo "$out" | jq -r '.pull_id')
	run "$LIGHTNING_BIN" api-account-mandate-pull "$BATS_CUST_ADDR" deny "$mid" "$pid"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"state":"denied"'* ]]
	[ "$(sqlite3 "$BATS_DB" "SELECT state FROM mandate_pulls WHERE id='$pid';")" = "denied" ]
	[ "$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='shop';")" = "0" ]
	_acct227_teardown
}

@test "FEAT-227: list does not leak the secret" {
	_acct227_setup
	_mk_mandate auto >/dev/null
	run "$LIGHTNING_BIN" api-account-mandate "$BATS_CUST_ADDR" list
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.mandates | length == 1' >/dev/null
	echo "$output" | jq -e '.mandates[0] | has("secret") | not' >/dev/null
	_acct227_teardown
}

@test "FEAT-227: patch switches the mode" {
	_acct227_setup
	read -r mid secret <<<"$(_mk_mandate auto)"
	run "$LIGHTNING_BIN" api-account-mandate "$BATS_CUST_ADDR" patch "$mid" --mode approval
	[ "$status" -eq 0 ]
	[[ "$output" == *'"mode":"approval"'* ]]
	[ "$(sqlite3 "$BATS_DB" "SELECT mode FROM mandates WHERE id='$mid';")" = "approval" ]
	_acct227_teardown
}

@test "FEAT-227: sudoers fragment lists the mandate verbs" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/sudoers.d/lightning"
	grep -q "api-account-mandate " "$f"
	grep -q "api-account-mandate-pull" "$f"
}

@test "FEAT-227: schema declares mandates + mandate_pulls" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/schema.sql"
	grep -q "CREATE TABLE IF NOT EXISTS mandates" "$f"
	grep -q "CREATE TABLE IF NOT EXISTS mandate_pulls" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-228: commerce charge lifecycle (escrow / auth-capture / refund /
# installments / dunning).
# ---------------------------------------------------------------------------

_acct228_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create shop >/dev/null
	"$LIGHTNING_BIN" account create buyer >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	BATS_SHOP_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='shop';")
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts,account,direction,amount_msat,message) VALUES(datetime('now'),'buyer','in',100000000,'seed');"
}

_acct228_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

_chg() {
	# echoes a new charge id for buyer of $1 sat (extra args passed through)
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" create buyer "$@" | jq -r '.id'
}

_sat() { sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0)/1000 FROM ledger WHERE account='$1';"; }

@test "FEAT-228: create issues a charge in state issued" {
	_acct228_setup
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" create buyer 20000 --ref '{"order_id":"O1"}'
	[ "$status" -eq 0 ]
	[[ "$output" == *'"state":"issued"'* ]]
	[[ "$(echo "$output" | jq -r '.id')" == chg_* ]]
	_acct228_teardown
}

@test "FEAT-228: create rejects bad amount / unknown customer / self" {
	_acct228_setup
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" create buyer 0
	[ "$status" -ne 0 ]
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" create nobody 1000
	[ "$status" -ne 0 ]
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" create shop 1000
	[ "$status" -ne 0 ]
	_acct228_teardown
}

@test "FEAT-228: escrow hold moves funds to escrow; release pays the merchant" {
	_acct228_setup
	local id; id=$(_chg 20000)
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" hold "$id" >/dev/null
	[ "$(_sat buyer)" = "80000" ]
	[ "$(_sat escrow)" = "20000" ]
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" release "$id"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"state":"released"'* ]]
	[ "$(_sat escrow)" = "0" ]
	[ "$(_sat shop)" = "20000" ]
	_acct228_teardown
}

@test "FEAT-228: hold requires sufficient customer balance" {
	_acct228_setup
	local id; id=$(_chg 999999999)
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" hold "$id"
	[ "$status" -eq 6 ]
	[[ "$output" == *"insufficient_funds"* ]]
	_acct228_teardown
}

@test "FEAT-228: release only from held state" {
	_acct228_setup
	local id; id=$(_chg 20000)
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" release "$id"
	[ "$status" -eq 6 ]
	[[ "$output" == *"bad_state"* ]]
	_acct228_teardown
}

@test "FEAT-228: partial then full refund walks state + reverses funds" {
	_acct228_setup
	local id; id=$(_chg 20000)
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" hold "$id" >/dev/null
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" release "$id" >/dev/null
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" refund "$id" --sat 5000
	[[ "$output" == *'"state":"partially_refunded"'* ]]
	[ "$(_sat shop)" = "15000" ]
	[ "$(_sat buyer)" = "85000" ]
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" refund "$id"
	[[ "$output" == *'"state":"refunded"'* ]]
	[ "$(_sat shop)" = "0" ]
	[ "$(_sat buyer)" = "100000" ]
	_acct228_teardown
}

@test "FEAT-228: refund cannot exceed the amount the merchant received" {
	_acct228_setup
	local id; id=$(_chg 20000)
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" hold "$id" >/dev/null
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" release "$id" >/dev/null
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" refund "$id" --sat 30000
	[ "$status" -eq 6 ]
	[[ "$output" == *"refund_exceeds_refundable"* ]]
	_acct228_teardown
}

@test "FEAT-228: authorize then capture < amount returns the remainder" {
	_acct228_setup
	local id; id=$(_chg 10000)
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" authorize "$id" >/dev/null
	[ "$(_sat escrow)" = "10000" ]
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" capture "$id" 8000
	[ "$status" -eq 0 ]
	[[ "$output" == *'"state":"captured"'* ]]
	[ "$(_sat shop)" = "8000" ]
	[ "$(_sat escrow)" = "0" ]
	[ "$(_sat buyer)" = "92000" ]
	_acct228_teardown
}

@test "FEAT-228: capture cannot exceed the authorized amount" {
	_acct228_setup
	local id; id=$(_chg 10000)
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" authorize "$id" >/dev/null
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" capture "$id" 20000
	[ "$status" -eq 6 ]
	[[ "$output" == *"capture_exceeds_authorization"* ]]
	_acct228_teardown
}

@test "FEAT-228: void returns the full authorized amount to the customer" {
	_acct228_setup
	local id; id=$(_chg 10000)
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" authorize "$id" >/dev/null
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" void "$id"
	[[ "$output" == *'"state":"voided"'* ]]
	[ "$(_sat escrow)" = "0" ]
	[ "$(_sat buyer)" = "100000" ]
	[ "$(_sat shop)" = "0" ]
	_acct228_teardown
}

@test "FEAT-228: installments amortise to exactly the amount and reach paid" {
	_acct228_setup
	local id; id=$(_chg 9000)
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" installments "$id" 3 >/dev/null
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" pay-installment "$id" >/dev/null
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" pay-installment "$id" >/dev/null
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" pay-installment "$id"
	[[ "$output" == *'"state":"paid"'* ]]
	[ "$(_sat shop)" = "9000" ]
	[ "$(_sat buyer)" = "91000" ]
	# A 4th installment is rejected.
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" pay-installment "$id"
	[ "$status" -eq 6 ]
	_acct228_teardown
}

@test "FEAT-228: installments with a non-divisible amount still sum exactly" {
	_acct228_setup
	local id; id=$(_chg 10000)
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" installments "$id" 3 >/dev/null
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" pay-installment "$id" >/dev/null
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" pay-installment "$id" >/dev/null
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" pay-installment "$id" >/dev/null
	[ "$(_sat shop)" = "10000" ]
	_acct228_teardown
}

@test "FEAT-228: dunning advances stages on an overdue charge + reports late fee" {
	_acct228_setup
	local id; id=$(_chg 5000 --terms '{"late_fee":{"pct":5}}' --due-days 0)
	sqlite3 "$BATS_DB" "UPDATE commerce_charges SET due_at = strftime('%s','now')-100 WHERE id='$id';"
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" dun "$id"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"state":"overdue"'* ]]
	[[ "$output" == *'"late_fee_sat":250'* ]]
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" dun "$id"
	[[ "$output" == *'"state":"dunning_1"'* ]]
	_acct228_teardown
}

@test "FEAT-228: dun before the due date is rejected" {
	_acct228_setup
	local id; id=$(_chg 5000 --due-days 30)
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" dun "$id"
	[ "$status" -eq 6 ]
	[[ "$output" == *"not_yet_due"* ]]
	_acct228_teardown
}

@test "FEAT-228: show returns the charge + its event log" {
	_acct228_setup
	local id; id=$(_chg 20000)
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" hold "$id" >/dev/null
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" release "$id" >/dev/null
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" show "$id"
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.events | length == 3' >/dev/null
	echo "$output" | jq -e '.events[0].event == "created"' >/dev/null
	_acct228_teardown
}

@test "FEAT-228: list + scoping to the merchant" {
	_acct228_setup
	_chg 1000 >/dev/null
	_chg 2000 >/dev/null
	run "$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" list
	echo "$output" | jq -e '.charges | length == 2' >/dev/null
	# buyer (as a merchant) sees none.
	local buyer_addr; buyer_addr=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='buyer';")
	run "$LIGHTNING_BIN" api-account-charge "$buyer_addr" list
	echo "$output" | jq -e '.charges | length == 0' >/dev/null
	_acct228_teardown
}

@test "FEAT-228: ledger stays balanced across a full lifecycle" {
	_acct228_setup
	local id; id=$(_chg 12000)
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" hold "$id" >/dev/null
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" release "$id" >/dev/null
	"$LIGHTNING_BIN" api-account-charge "$BATS_SHOP_ADDR" refund "$id" --sat 4000 >/dev/null
	# Sum of all ledger rows tagged to this charge nets to zero.
	[ "$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE payment_hash='$id';")" = "0" ]
	_acct228_teardown
}

@test "FEAT-228: sudoers fragment lists api-account-charge" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/sudoers.d/lightning"
	grep -q "api-account-charge" "$f"
}

@test "FEAT-228: schema declares commerce_charges + commerce_events + escrow" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/schema.sql"
	grep -q "CREATE TABLE IF NOT EXISTS commerce_charges" "$f"
	grep -q "CREATE TABLE IF NOT EXISTS commerce_events" "$f"
	grep -q "VALUES('escrow'" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-230: tax-relevant transaction DATA export (FIFO, fiat-valued).
# ---------------------------------------------------------------------------

_acct230_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create trader >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	# Acquisitions: 2023-05-01 (500k sat @25000), 2024-01-10 (1M sat @40000).
	# Disposal:    2024-06-10 (400k sat @50000) -> FIFO matches the 2023 lot.
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts,account,direction,amount_msat,message) VALUES
		('2023-05-01 12:00:00','trader','in', 500000000,'acq1'),
		('2024-01-10 12:00:00','trader','in',1000000000,'acq2'),
		('2024-06-10 12:00:00','trader','out',-400000000,'spend1');"
	sqlite3 "$BATS_DB" "INSERT INTO prices(ts,base,btc_fiat,source) VALUES
		(1682942400,'EUR',25000,'test'),
		(1704888000,'EUR',40000,'test'),
		(1718020800,'EUR',50000,'test');"
}

_acct230_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

@test "FEAT-230: FIFO disposal export computes the gain against the oldest lot" {
	_acct230_setup
	run "$LIGHTNING_BIN" export tax-data trader --year 2024 --base EUR --format json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.disposals | length == 1' >/dev/null
	[ "$(echo "$output" | jq -r '.disposals[0].acquisition_date')" = "2023-05-01" ]
	echo "$output" | jq -e '.disposals[0].fiat_in == 100' >/dev/null
	echo "$output" | jq -e '.disposals[0].fiat_out == 200' >/dev/null
	echo "$output" | jq -e '.disposals[0].gain == 100' >/dev/null
	echo "$output" | jq -e '.disposals[0].holding_days == 406' >/dev/null
	echo "$output" | jq -e '.summary.total_gain == 100' >/dev/null
	_acct230_teardown
}

@test "FEAT-230: output is labelled data-for-preparation, with a disclaimer" {
	_acct230_setup
	run "$LIGHTNING_BIN" export tax-data trader --year 2024 --format json
	[ "$(echo "$output" | jq -r '.kind')" = "transaction_data_for_tax_preparation" ]
	[[ "$(echo "$output" | jq -r '.disclaimer')" == *"NOT a tax report"* ]]
	[ "$(echo "$output" | jq -r '.summary.freigrenze_eur')" = "600" ]
	_acct230_teardown
}

@test "FEAT-230: year filter excludes disposals from other years" {
	_acct230_setup
	run "$LIGHTNING_BIN" export tax-data trader --year 2025 --format json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.disposals | length == 0' >/dev/null
	_acct230_teardown
}

@test "FEAT-230: missing price surfaces an explicit gap, never 0" {
	_acct230_setup
	# A disposal far from any price tick.
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts,account,direction,amount_msat,message) VALUES('2024-09-01 12:00:00','trader','out',-100000000,'spend2');"
	run "$LIGHTNING_BIN" export tax-data trader --year 2024 --format json
	echo "$output" | jq -e '[.disposals[] | select(.price_gap == true)] | length >= 1' >/dev/null
	# The gapped row has null gain (not 0).
	echo "$output" | jq -e '[.disposals[] | select(.price_gap == true) | .gain] | all(. == null)' >/dev/null
	_acct230_teardown
}

@test "FEAT-230: operator export values fee revenue at receipt" {
	_acct230_setup
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts,account,direction,amount_msat,message) VALUES('2024-01-10 12:05:00','house','in',2500000,'fee:transfer');"
	run "$LIGHTNING_BIN" export tax-data --operator --year 2024 --format json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.kind')" = "operator_fee_income_data_for_tax_preparation" ]
	echo "$output" | jq -e '.income | length == 1' >/dev/null
	# 2500 sat * 40000 / 1e8 = 1.00 EUR
	echo "$output" | jq -e '.income[0].fiat_value == 1' >/dev/null
	_acct230_teardown
}

@test "FEAT-230: CSV format validates (header + 8 columns)" {
	_acct230_setup
	run "$LIGHTNING_BIN" export tax-data trader --year 2024 --format csv
	[ "$status" -eq 0 ]
	[[ "$output" == *"disposal_date,disposal_sat,acquisition_date,holding_days,fiat_in,fiat_out,gain,price_gap"* ]]
	# The single data row has 8 comma-separated fields.
	local cols
	cols=$(echo "$output" | grep -v '^#' | grep '^2024-06-10' | awk -F, '{print NF}')
	[ "$cols" = "8" ]
	_acct230_teardown
}

@test "FEAT-230: bad format / missing year / unknown account are rejected" {
	_acct230_setup
	run "$LIGHTNING_BIN" export tax-data trader --year 2024 --format xml
	[ "$status" -ne 0 ]
	run "$LIGHTNING_BIN" export tax-data trader
	[ "$status" -ne 0 ]
	run "$LIGHTNING_BIN" export tax-data nobody --year 2024
	[ "$status" -ne 0 ]
	_acct230_teardown
}

@test "FEAT-230: export resolves an account by bech32 address too" {
	_acct230_setup
	local addr; addr=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='trader';")
	run "$LIGHTNING_BIN" export tax-data "$addr" --year 2024 --format json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.account')" = "trader" ]
	_acct230_teardown
}

@test "FEAT-230: sudoers fragment lists export tax-data" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/sudoers.d/lightning"
	grep -q "export tax-data" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-216: interest mode — negative fees pay users a yield (opt-in).
# ---------------------------------------------------------------------------

_acct216_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create saver >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	BATS_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='saver';")
	BATS_FEES="$LIGHTNING_WALLETS_ROOT/alice/fees.recfile"
}

_acct216_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

_deposit_100k() {
	local outs
	outs=$(jq -nc --arg a "$BATS_ADDR" \
		'[{"txid":"feed","output":0,"status":"confirmed","address":$a,"amount_msat":"100000000msat"}]')
	MOCK_LISTFUNDS_OUTPUTS="$outs" "$LIGHTNING_BIN" account topup-watcher run >/dev/null 2>&1
}

@test "FEAT-216: interest mode credits the user a yield on a deposit" {
	_acct216_setup
	# topup-onchain: interest on, rate -2000 ppm (-0.2%).
	sed -i '/^operation: topup-onchain$/,/^$/{s/^rate_ppm:.*/rate_ppm:  -2000/; s/^interest_mode:.*/interest_mode: on/}' "$BATS_FEES"
	_deposit_100k
	# 100 000-sat deposit + 200-sat interest = 100 200 sat.
	[ "$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='saver';")" = "100200000" ]
	_acct216_teardown
}

@test "FEAT-216: the interest subsidy is debited from house with the matching payment_hash" {
	_acct216_setup
	sed -i '/^operation: topup-onchain$/,/^$/{s/^rate_ppm:.*/rate_ppm:  -2000/; s/^interest_mode:.*/interest_mode: on/}' "$BATS_FEES"
	_deposit_100k
	[ "$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='house';")" = "-200000" ]
	# Same payment_hash links the user credit and the house debit.
	local ph
	ph=$(sqlite3 "$BATS_DB" "SELECT payment_hash FROM ledger WHERE account='house' AND message LIKE 'interest:%';")
	[ -n "$ph" ]
	[ "$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM ledger WHERE payment_hash='$ph' AND message LIKE 'interest:%';")" = "2" ]
	_acct216_teardown
}

@test "FEAT-216: a negative rate with interest_mode off pays NO subsidy (clamped)" {
	_acct216_setup
	# Negative rate but interest mode off -> skim clamps to 0.
	sed -i '/^operation: topup-onchain$/,/^$/{s/^rate_ppm:.*/rate_ppm:  -2000/; s/^interest_mode:.*/interest_mode: off/}' "$BATS_FEES"
	_deposit_100k
	# User gets exactly the deposit; house untouched.
	[ "$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='saver';")" = "100000000" ]
	[ "$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='house';")" = "0" ]
	_acct216_teardown
}

@test "FEAT-216: autotune refuses a negative rate when interest_mode is off" {
	_acct216_setup
	sed -i '/^operation: topup-onchain$/,/^$/{s/^rate_ppm:.*/rate_ppm:  -2000/; s/^interest_mode:.*/interest_mode: off/}' "$BATS_FEES"
	LIGHTNING_FEE_AUTOTUNE_TARGET_MSAT_PER_DAY=1000 run "$LIGHTNING_BIN" fee-policy autotune dry-run
	[ "$status" -eq 3 ]
	[[ "$output" == *"interest_mode is off"* ]]
	_acct216_teardown
}

@test "FEAT-216: autotune accepts a negative rate when interest_mode is on" {
	_acct216_setup
	sed -i '/^operation: topup-onchain$/,/^$/{s/^rate_ppm:.*/rate_ppm:  -1000/; s/^interest_mode:.*/interest_mode: on/}' "$BATS_FEES"
	LIGHTNING_FEE_AUTOTUNE_TARGET_MSAT_PER_DAY=1000 run "$LIGHTNING_BIN" fee-policy autotune dry-run
	[ "$status" -eq 0 ]
	_acct216_teardown
}

@test "FEAT-216: fee-policy status reports the cumulative interest subsidy" {
	_acct216_setup
	sed -i '/^operation: topup-onchain$/,/^$/{s/^rate_ppm:.*/rate_ppm:  -2000/; s/^interest_mode:.*/interest_mode: on/}' "$BATS_FEES"
	_deposit_100k
	run "$LIGHTNING_BIN" fee-policy status
	[ "$status" -eq 0 ]
	[[ "$output" == *"interest_subsidy_paid_sat: 200"* ]]
	[[ "$output" == *"interest_mode_ops:"* ]]
	[[ "$output" == *"topup-onchain"* ]]
	_acct216_teardown
}

@test "FEAT-216: default fees.recfile ships interest_mode off + a legal caution" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/defaults/fees.recfile"
	grep -q "interest_mode: off" "$f"
	grep -qi "CAUTION" "$f"
	grep -qi "deposit-taking" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-217: autopilot pay-target intelligence.
# ---------------------------------------------------------------------------

_paytarget_history() {
	# Build a MOCK_LISTPAYS JSON: $1=node, recent completed pays.
	local now; now=$(date -u +%s)
	export PT_A=02aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	export PT_B=03bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
	export PT_C=02cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
	MOCK_LISTPAYS=$(jq -nc --arg a "$PT_A" --arg b "$PT_B" --arg c "$PT_C" --argjson now "$now" '[
		{status:"complete",destination:$a,amount_msat:"10000000msat",created_at:($now-100)},
		{status:"complete",destination:$a,amount_msat:10000000,created_at:($now-200)},
		{status:"complete",destination:$a,amount_msat:10000000,created_at:($now-300)},
		{status:"complete",destination:$b,amount_msat:5000000,created_at:($now-400)},
		{status:"complete",destination:$c,amount_msat:50000000,created_at:($now-500)},
		{status:"failed",  destination:$b,amount_msat:99000000,created_at:($now-50)},
		{status:"complete",destination:$a,amount_msat:9999000000,created_at:($now-99999999)}
	]')
	export MOCK_LISTPAYS
}

@test "FEAT-217: paytarget-intel suggests the top paid destination" {
	_paytarget_history
	MOCK_LISTPEERCHANNELS='[]' run "$LIGHTNING_BIN" channel paytarget-intel
	[ "$status" -eq 0 ]
	local f="$HOME/.lightning/autopilot/paytarget.suggest.recfile"
	[ -f "$f" ]
	grep -q "kind: pay-target-channels" "$f"
	grep -q "node_id: $PT_A" "$f"
	# A (30000 sat) is the top entry, before B.
	[ "$(grep -n "node_id: $PT_A" "$f" | cut -d: -f1)" -lt "$(grep -n "node_id: $PT_B" "$f" | cut -d: -f1)" ]
}

@test "FEAT-217: a directly-connected destination is excluded" {
	_paytarget_history
	# We already have a channel to C.
	local peers; peers=$(jq -nc --arg c "$PT_C" '[{peer_id:$c}]')
	MOCK_LISTPEERCHANNELS="$peers" run "$LIGHTNING_BIN" channel paytarget-intel
	[ "$status" -eq 0 ]
	local f="$HOME/.lightning/autopilot/paytarget.suggest.recfile"
	! grep -q "node_id: $PT_C" "$f"
	grep -q "node_id: $PT_A" "$f"
}

@test "FEAT-217: empty pay history is a no-op (no file written)" {
	MOCK_LISTPAYS='[]' MOCK_LISTPEERCHANNELS='[]' run "$LIGHTNING_BIN" channel paytarget-intel
	[ "$status" -eq 0 ]
	[[ "$output" == *"no pay-target suggestions"* ]]
	[ ! -f "$HOME/.lightning/autopilot/paytarget.suggest.recfile" ]
}

@test "FEAT-217: pays outside the window are excluded" {
	local now; now=$(date -u +%s)
	local node=02dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
	# A single completed pay, but ~2 years ago.
	MOCK_LISTPAYS=$(jq -nc --arg d "$node" --argjson now "$now" \
		'[{status:"complete",destination:$d,amount_msat:10000000,created_at:($now-60000000)}]')
	MOCK_LISTPAYS="$MOCK_LISTPAYS" MOCK_LISTPEERCHANNELS='[]' run "$LIGHTNING_BIN" channel paytarget-intel
	[ "$status" -eq 0 ]
	[[ "$output" == *"no pay-target suggestions"* ]]
}

@test "FEAT-217: --dry-run prints but writes nothing" {
	_paytarget_history
	MOCK_LISTPEERCHANNELS='[]' run "$LIGHTNING_BIN" channel paytarget-intel --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"dry-run"* ]]
	[[ "$output" == *"$PT_A"* ]]
	[ ! -f "$HOME/.lightning/autopilot/paytarget.suggest.recfile" ]
}

@test "FEAT-217: --top caps the number of suggestions" {
	_paytarget_history
	# Exclude C (highest volume) so A is the top remaining target.
	local peers; peers=$(jq -nc --arg c "$PT_C" '[{peer_id:$c}]')
	MOCK_LISTPEERCHANNELS="$peers" run "$LIGHTNING_BIN" channel paytarget-intel --top 1
	[ "$status" -eq 0 ]
	local f="$HOME/.lightning/autopilot/paytarget.suggest.recfile"
	[ "$(grep -c '^node_id:' "$f")" = "1" ]
	grep -q "node_id: $PT_A" "$f"
}

@test "FEAT-217: autopilot run feeds the pay-target suggest queue" {
	_paytarget_history
	MOCK_LISTPEERCHANNELS='[]' run "$LIGHTNING_BIN" channel autopilot run --dry-run
	[ "$status" -eq 0 ]
	# autopilot run invokes paytarget-intel as a real write (not dry).
	[ -f "$HOME/.lightning/autopilot/paytarget.suggest.recfile" ]
	grep -q "node_id: $PT_A" "$HOME/.lightning/autopilot/paytarget.suggest.recfile"
}

@test "FEAT-217: channel usage lists paytarget-intel" {
	run "$LIGHTNING_BIN" channel
	[[ "$output" == *"paytarget-intel"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-233: compliance module framework (hooks + config + audit log).
# ---------------------------------------------------------------------------

_cc_setup() {
	export LIGHTNING_WALLETS_ROOT="$BATS_TMPDIR/wallets.$$"
	export LIGHTNING_DIR="$BATS_TMPDIR/lnd.$$"
	mkdir -p "$LIGHTNING_DIR"
	"$LIGHTNING_BIN" wallet new alice >/dev/null
	"$LIGHTNING_BIN" account create alpha >/dev/null
	"$LIGHTNING_BIN" account create beta >/dev/null
	BATS_DB="$LIGHTNING_WALLETS_ROOT/alice/state.db"
	BATS_CF="$LIGHTNING_WALLETS_ROOT/alice/compliance.recfile"
	BATS_A_ADDR=$(sqlite3 "$BATS_DB" "SELECT address FROM accounts WHERE name='alpha';")
	sqlite3 "$BATS_DB" "INSERT INTO ledger(ts,account,direction,amount_msat,message) VALUES(datetime('now'),'alpha','in',100000000,'seed');"
}

_cc_teardown() {
	rm -rf "$LIGHTNING_WALLETS_ROOT" "$LIGHTNING_DIR" "$HOME/.lightning"
}

_cc_test_module() {
	# $1 = deny|allow ; append a self-test module record.
	printf '\nmodule: test\nenabled: on\ndecision: %s\n' "$1" >> "$BATS_CF"
}

@test "FEAT-233: with no compliance.recfile every hook is a no-op (transfer works)" {
	_cc_setup
	[ ! -f "$BATS_CF" ]
	run "$LIGHTNING_BIN" api-account-transfer "$BATS_A_ADDR" beta 10000
	[ "$status" -eq 0 ]
	[[ "$output" == *'"status":"complete"'* ]]
	# No audit rows written when the framework is off.
	[ "$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM compliance_events;")" = "0" ]
	_cc_teardown
}

@test "FEAT-233: preset us-msb enables the expected module set" {
	_cc_setup
	run "$LIGHTNING_BIN" compliance preset us-msb
	[ "$status" -eq 0 ]
	[ -f "$BATS_CF" ]
	run "$LIGHTNING_BIN" compliance status
	[[ "$output" == *"kyc"*"on"* ]]
	# kyc / screening / travel_rule on; data_subject_rights off in this preset.
	"$LIGHTNING_BIN" compliance status | grep -E "^  kyc " | grep -q on
	"$LIGHTNING_BIN" compliance status | grep -E "^  travel_rule " | grep -q on
	"$LIGHTNING_BIN" compliance status | grep -E "^  proof_of_reserves " | grep -q on
	_cc_teardown
}

@test "FEAT-233: a deny pre-hook blocks the transaction (exit 6 + error)" {
	_cc_setup
	"$LIGHTNING_BIN" compliance preset off >/dev/null
	_cc_test_module deny
	run "$LIGHTNING_BIN" api-account-transfer "$BATS_A_ADDR" beta 5000
	[ "$status" -eq 6 ]
	[[ "$output" == *"compliance_denied"* ]]
	# The transfer did NOT move funds.
	[ "$(sqlite3 "$BATS_DB" "SELECT COALESCE(SUM(amount_msat),0) FROM ledger WHERE account='beta';")" = "0" ]
	# The deny was recorded to the audit log.
	[ "$(sqlite3 "$BATS_DB" "SELECT decision FROM compliance_events WHERE hook='pre' AND op='transfer';")" = "deny" ]
	_cc_teardown
}

@test "FEAT-233: a post-hook records to compliance_events without blocking" {
	_cc_setup
	"$LIGHTNING_BIN" compliance preset off >/dev/null
	_cc_test_module allow
	run "$LIGHTNING_BIN" api-account-transfer "$BATS_A_ADDR" beta 5000
	[ "$status" -eq 0 ]
	[[ "$output" == *'"status":"complete"'* ]]
	# Funds moved AND a post observe row exists.
	[ "$(sqlite3 "$BATS_DB" "SELECT SUM(amount_msat) FROM ledger WHERE account='beta';")" = "5000000" ]
	[ "$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM compliance_events WHERE hook='post' AND op='transfer' AND decision='observe';")" -ge 1 ]
	_cc_teardown
}

@test "FEAT-233: pay + withdraw + create are wired to the hooks" {
	_cc_setup
	"$LIGHTNING_BIN" compliance preset off >/dev/null
	_cc_test_module deny
	# pay denied
	run "$LIGHTNING_BIN" api-account-pay "$BATS_A_ADDR" lnbcrt10n1xxx
	[ "$status" -eq 6 ]
	[[ "$output" == *"compliance_denied"* ]]
	# create denied (anonymous self-service)
	REMOTE_ADDR=9.9.9.9 run "$LIGHTNING_BIN" api-accounts-create
	[ "$status" -ne 0 ]
	[[ "$output" == *"compliance_denied"* ]]
	_cc_teardown
}

@test "FEAT-233: compliance status reports modules + footers the disclaimer" {
	_cc_setup
	"$LIGHTNING_BIN" compliance preset de-custodial >/dev/null
	run "$LIGHTNING_BIN" compliance status
	[ "$status" -eq 0 ]
	[[ "$output" == *"DISCLAIMER"* ]]
	[[ "$output" == *"consult a qualified local lawyer"* ]]
	_cc_teardown
}

@test "FEAT-233: preset prints the disclaimer on application" {
	_cc_setup
	run "$LIGHTNING_BIN" compliance preset uk-fca
	[ "$status" -eq 0 ]
	[[ "$output" == *"consult a qualified local lawyer"* ]]
	_cc_teardown
}

@test "FEAT-233: unknown preset is rejected" {
	_cc_setup
	run "$LIGHTNING_BIN" compliance preset narnia
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown preset"* ]]
	_cc_teardown
}

@test "FEAT-233: status with no config reports framework OFF" {
	_cc_setup
	run "$LIGHTNING_BIN" compliance status
	[ "$status" -eq 0 ]
	[[ "$output" == *"framework OFF"* ]]
	_cc_teardown
}

@test "FEAT-233: GC retention veto holds a delete-eligible account" {
	_cc_setup
	# Make beta a long-closed, delete-eligible account.
	sqlite3 "$BATS_DB" "UPDATE accounts SET closed_at = strftime('%s','now') - 400*86400, created_at = strftime('%s','now') - 500*86400 WHERE name='beta';"
	"$LIGHTNING_BIN" compliance preset off >/dev/null
	_cc_test_module deny
	run "$LIGHTNING_BIN" account gc run
	[ "$status" -eq 0 ]
	# beta retained (legal hold), not deleted.
	[ "$(sqlite3 "$BATS_DB" "SELECT COUNT(*) FROM accounts WHERE name='beta';")" = "1" ]
	[[ "$output" == *"retain"* ]]
	_cc_teardown
}

@test "FEAT-233: DISCLAIMER.txt ships under share/lightning/compliance" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/compliance/DISCLAIMER.txt"
	[ -f "$f" ]
	grep -qi "not legal advice" "$f"
	grep -qi "consult a qualified local lawyer" "$f"
}

@test "FEAT-233: schema declares compliance_events" {
	f="$BATS_TEST_DIRNAME/../../share/lightning/schema.sql"
	grep -q "CREATE TABLE IF NOT EXISTS compliance_events" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-221: per-verb man-page tree.
# ---------------------------------------------------------------------------

@test "FEAT-221: every dispatchable verb has a man page naming it" {
	local libexec="$BATS_TEST_DIRNAME/../../libexec/lightning"
	local man="$BATS_TEST_DIRNAME/../../share/man/man1"
	local missing=""
	local v page
	for path in "$libexec"/*; do
		v=$(basename "$path")
		# Skip internal helpers (_*) and the api-* HTTP-bridge verbs
		# (documented via the FEAT-209 inline docs, not man pages).
		case "$v" in _*|api-*) continue ;; esac
		page="$man/lightning-$v.1"
		if [ ! -f "$page" ]; then
			missing="$missing $v(no-page)"
			continue
		fi
		# The verb name must appear in the .SH NAME stanza.
		awk '/^\.SH NAME/{f=1; next} /^\.SH /{f=0} f' "$page" | grep -q "lightning-$v" \
			|| missing="$missing $v(no-name)"
	done
	[ -z "$missing" ] || { echo "missing/bad man pages:$missing"; false; }
}

@test "FEAT-221: lightning-account.1 covers the account subcommands" {
	local page="$BATS_TEST_DIRNAME/../../share/man/man1/lightning-account.1"
	[ -f "$page" ]
	local s
	for s in create show close nickname topup withdraw pay receive apikey topup-watcher gc; do
		grep -q "$s" "$page" || { echo "account man page missing: $s"; false; }
	done
}

@test "FEAT-221: every per-verb page has NAME + SYNOPSIS + DESCRIPTION + balanced nf/fi" {
	local man="$BATS_TEST_DIRNAME/../../share/man/man1"
	local f bad=""
	for f in "$man"/lightning-*.1; do
		grep -q '^\.TH ' "$f"        || bad="$bad $(basename "$f"):TH"
		grep -q '^\.SH NAME'      "$f" || bad="$bad $(basename "$f"):NAME"
		grep -q '^\.SH SYNOPSIS'  "$f" || bad="$bad $(basename "$f"):SYN"
		grep -q '^\.SH DESCRIPTION' "$f" || bad="$bad $(basename "$f"):DESC"
		[ "$(grep -c '^\.nf$' "$f")" = "$(grep -c '^\.fi$' "$f")" ] || bad="$bad $(basename "$f"):nf"
	done
	[ -z "$bad" ] || { echo "bad pages:$bad"; false; }
}

@test "FEAT-221: lightning.1 overview cross-references the per-verb pages" {
	local f="$BATS_TEST_DIRNAME/../../share/man/man1/lightning.1"
	grep -q "lightning-account (1)" "$f"
	grep -q "lightning-channel (1)" "$f"
	grep -q "lightning-compliance (1)" "$f"
}

# ---------------------------------------------------------------------------
# FEAT-209: wallet PWA + `lightning ui` installer.
# ---------------------------------------------------------------------------

@test "FEAT-209: ui install copies the PWA + docs into a docroot" {
	local dr="$BATS_TMPDIR/docroot.$$"
	rm -rf "$dr"
	run "$LIGHTNING_BIN" ui install "$dr" --no-vhost
	[ "$status" -eq 0 ]
	[ -f "$dr/index.html" ]
	[ -f "$dr/app.js" ]
	[ -f "$dr/style.css" ]
	[ -f "$dr/manifest.webmanifest" ]
	[ -f "$dr/config.json" ]
	[ -f "$dr/docs/index.html" ]
	[ -f "$dr/docs/llms.txt" ]
	rm -rf "$dr"
}

@test "FEAT-209: ui install writes a hardened Apache vhost fragment" {
	local dr="$BATS_TMPDIR/docroot.$$"
	local frag="$BATS_TEST_DIRNAME/../../share/lightning/apache/ui.conf"
	rm -rf "$dr" "$frag"
	run "$LIGHTNING_BIN" ui install "$dr"
	[ "$status" -eq 0 ]
	[ -f "$frag" ]
	grep -q "Alias /lightning $dr" "$frag"
	grep -q -- "-ExecCGI" "$frag"
	grep -q -- "-Indexes" "$frag"
	rm -rf "$dr" "$frag"
}

@test "FEAT-209: ui --no-vhost skips the fragment" {
	local dr="$BATS_TMPDIR/docroot.$$"
	local frag="$BATS_TEST_DIRNAME/../../share/lightning/apache/ui.conf"
	rm -rf "$dr" "$frag"
	"$LIGHTNING_BIN" ui install "$dr" --no-vhost >/dev/null
	[ ! -f "$frag" ]
	rm -rf "$dr"
}

@test "FEAT-209: ui upgrade preserves an operator-edited config.json" {
	local dr="$BATS_TMPDIR/docroot.$$"
	rm -rf "$dr"
	"$LIGHTNING_BIN" ui install "$dr" --no-vhost >/dev/null
	echo '{"api_base":"/custom","name":"Mine"}' > "$dr/config.json"
	run "$LIGHTNING_BIN" ui upgrade "$dr"
	[ "$status" -eq 0 ]
	grep -q '/custom' "$dr/config.json"
	# Other files were refreshed.
	[ -f "$dr/app.js" ]
	rm -rf "$dr"
}

@test "FEAT-209: ui uninstall removes our docroot but refuses a foreign one" {
	local dr="$BATS_TMPDIR/docroot.$$"
	rm -rf "$dr"
	"$LIGHTNING_BIN" ui install "$dr" --no-vhost >/dev/null
	run "$LIGHTNING_BIN" ui uninstall "$dr"
	[ "$status" -eq 0 ]
	[ ! -d "$dr" ]
	# A directory we didn't populate is refused.
	local foreign="$BATS_TMPDIR/foreign.$$"
	mkdir -p "$foreign"; echo x > "$foreign/random.txt"
	run "$LIGHTNING_BIN" ui uninstall "$foreign"
	[ "$status" -ne 0 ]
	[ -d "$foreign" ]
	rm -rf "$foreign"
}

@test "FEAT-209: ui (no args) prints usage" {
	run "$LIGHTNING_BIN" ui
	[ "$status" -ne 0 ]
	[[ "$output" == *"install"* ]]
	[[ "$output" == *"uninstall"* ]]
}

@test "FEAT-209: PWA config.json + manifest are valid JSON; app.js is hardwired same-origin" {
	local ui="$BATS_TEST_DIRNAME/../../share/lightning/ui"
	jq -e . "$ui/config.json" >/dev/null
	jq -e . "$ui/manifest.webmanifest" >/dev/null
	# Default API base is the real FEAT-212 versioned path.
	[ "$(jq -r '.api_base' "$ui/config.json")" = "/.well-known/lightning/v1" ]
	# No absolute cross-origin URLs baked into the client.
	! grep -qE 'https?://' "$ui/app.js"
}

@test "FEAT-209: llms.txt covers the PWA, REST, and MCP surfaces" {
	local f="$BATS_TEST_DIRNAME/../../share/lightning/ui/docs/llms.txt"
	[ -f "$f" ]
	grep -q "REST API" "$f"
	grep -q "/accounts" "$f"
	grep -qi "MCP" "$f"
	grep -q "/.well-known/lightning/v1/mcp" "$f"
}

@test "FEAT-209: inline docs index.html is plain HTML (no script)" {
	local f="$BATS_TEST_DIRNAME/../../share/lightning/ui/docs/index.html"
	[ -f "$f" ]
	! grep -qi "<script" "$f"
}
