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

@test "lightning version returns 0.7.0" {
	run "$LIGHTNING_BIN" version
	[ "$status" -eq 0 ]
	[ "$output" = "0.7.0" ]
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

@test "help lists the top-level objects" {
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
# FEAT-174: wallet init + accounts (no multi-wallet — there is one wallet)
# ---------------------------------------------------------------------------

@test "FEAT-174: lightning wallet init creates wallet directory + state.db" {
	run "$LIGHTNING_BIN" wallet init
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
	[ -f "$HOME/.lightning/wallet/default/state.db" ]
	[ -f "$HOME/.lightning/wallet/default/.gitignore" ]
	[ -d "$HOME/.lightning/wallet/default/.git" ]
}

@test "FEAT-174: lightning wallet init is idempotent (refuses second init)" {
	"$LIGHTNING_BIN" wallet init
	run "$LIGHTNING_BIN" wallet init
	[ "$status" -ne 0 ]
	[[ "$output" == *"already exists"* ]]
}

@test "FEAT-174: lightning wallet init output is clean (no git status leak)" {
	# Regression: git commit's "nothing to commit" hint went to STDOUT
	# (not stderr), so --quiet and 2>/dev/null didn't suppress it.
	# Output must be exactly two lines: 'ok' and 'wallet: <path>'.
	run "$LIGHTNING_BIN" wallet init
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 2 ]
	[ "${lines[0]}" = "ok" ]
	[[ "${lines[1]}" == "wallet: "* ]]
	# These tokens (English + German) would appear if git status leaked.
	[[ "$output" != *"nothing to commit"* ]]
	[[ "$output" != *"Untracked files"* ]]
	[[ "$output" != *"Unversionierte Dateien"* ]]
	[[ "$output" != *"Initial commit"* ]]
	[[ "$output" != *"Initialer Commit"* ]]
}

@test "FEAT-174: lightning wallet init creates state.sql + commits all three files" {
	"$LIGHTNING_BIN" wallet init
	local wdir="$HOME/.lightning/wallet/default"
	[ -f "$wdir/state.sql" ]
	# The pre-commit hook should have auto-dumped state.db -> state.sql
	# and the initial commit should include all three tracked files.
	local files; files=$(git -C "$wdir" ls-tree --name-only HEAD | sort | tr '\n' ' ')
	[ "$files" = ".gitignore lightning-dir state.sql " ]
}

@test "FEAT-174: lightning account create creates an account" {
	"$LIGHTNING_BIN" wallet init
	run "$LIGHTNING_BIN" account create alice "Alice's account"
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

@test "FEAT-174: lightning account list shows created accounts" {
	"$LIGHTNING_BIN" wallet init
	"$LIGHTNING_BIN" account create alice "Alice's account"
	run "$LIGHTNING_BIN" account list
	[ "$status" -eq 0 ]
	[[ "$output" == *"alice"* ]]
}

@test "FEAT-174: lightning account show displays account info" {
	"$LIGHTNING_BIN" wallet init
	"$LIGHTNING_BIN" account create alice "Alice's account"
	run "$LIGHTNING_BIN" account show alice
	[ "$status" -eq 0 ]
	[[ "$output" == *"alice"* ]]
	[[ "$output" == *"ledger"* ]]
}

@test "FEAT-174: lightning account refuses duplicate names" {
	"$LIGHTNING_BIN" wallet init
	"$LIGHTNING_BIN" account create alice "Alice"
	run "$LIGHTNING_BIN" account create alice "Alice again"
	[ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# FEAT-193: ledger verbs (requires wallet)
# ---------------------------------------------------------------------------

@test "FEAT-193: lightning ledger list on empty ledger is clean" {
	"$LIGHTNING_BIN" wallet init
	run "$LIGHTNING_BIN" ledger list
	[ "$status" -eq 0 ]
}

@test "FEAT-193: lightning ledger balance on empty ledger is zero" {
	"$LIGHTNING_BIN" wallet init
	run "$LIGHTNING_BIN" ledger balance
	[ "$status" -eq 0 ]
}

@test "FEAT-193: lightning ledger requires wallet init" {
	run "$LIGHTNING_BIN" ledger list
	[ "$status" -ne 0 ]
	[[ "$output" == *"wallet init"* ]]
}

@test "FEAT-193: lightning ledger export tsv works on empty ledger" {
	"$LIGHTNING_BIN" wallet init
	run "$LIGHTNING_BIN" ledger export tsv
	[ "$status" -eq 0 ]
}

@test "FEAT-193: lightning ledger export csv works on empty ledger" {
	"$LIGHTNING_BIN" wallet init
	run "$LIGHTNING_BIN" ledger export csv
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# FEAT-185: seed + scb
# ---------------------------------------------------------------------------

@test "FEAT-185: lightning wallet seed export refuses without hsm_secret" {
	run "$LIGHTNING_BIN" wallet seed export
	[ "$status" -ne 0 ]
	[[ "$output" == *"hsm_secret"* ]]
}

@test "FEAT-185: lightning wallet seed export writes to --out file" {
	# Create a fake hsm_secret (32 bytes = unencrypted).
	mkdir -p "$HOME/.lightning/bitcoin"
	dd if=/dev/zero of="$HOME/.lightning/bitcoin/hsm_secret" bs=32 count=1 status=none
	out="$BATS_TMPDIR/seed.$$.out"
	run "$LIGHTNING_BIN" wallet seed export --out "$out"
	[ "$status" -eq 0 ]
	[ -s "$out" ]
	rm -f "$out"
}

@test "FEAT-185: lightning channel scb emit writes an SCB file" {
	mkdir -p "$HOME/.lightning/bitcoin"
	out="$BATS_TMPDIR/scb.$$.json"
	run "$LIGHTNING_BIN" channel scb emit --out "$out"
	[ "$status" -eq 0 ]
	[ -s "$out" ]
	rm -f "$out"
}

# ---------------------------------------------------------------------------
# FEAT-187: backup umbrella (now under `wallet`)
# ---------------------------------------------------------------------------

@test "FEAT-187: lightning wallet backup without wallet exits non-zero" {
	run "$LIGHTNING_BIN" wallet backup
	[ "$status" -ne 0 ]
}

@test "FEAT-187: lightning wallet backup runs scb + push" {
	"$LIGHTNING_BIN" wallet init
	run "$LIGHTNING_BIN" wallet backup
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-173 + FEAT-193: pay/invoice/send --account writes to ledger
# ---------------------------------------------------------------------------

@test "FEAT-173/193: lightning invoice create --account writes to invoices table" {
	"$LIGHTNING_BIN" wallet init
	"$LIGHTNING_BIN" account create alice "Alice"
	run "$LIGHTNING_BIN" invoice create 1000 test --account alice
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == lnbc* || "${lines[0]}" == lntb* || "${lines[0]}" == lnbcrt* ]]
}

@test "FEAT-173/193: lightning invoice pay --account writes to ledger" {
	"$LIGHTNING_BIN" wallet init
	"$LIGHTNING_BIN" account create alice "Alice" --overdraft allow
	run "$LIGHTNING_BIN" invoice pay lnbcrt10n1pmocktest --account alice
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
	# Should have created at least one ledger row.
	run "$LIGHTNING_BIN" ledger list
	[ "$status" -eq 0 ]
}

@test "FEAT-173/193: lightning send --account writes to ledger" {
	"$LIGHTNING_BIN" wallet init
	"$LIGHTNING_BIN" account create bob "Bob" --overdraft allow
	run "$LIGHTNING_BIN" send 020000000000000000000000000000000000000000000000000000000000000002 100 --account bob --note "test payment"
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

@test "FEAT-173/193: lightning ledger annotate updates a note" {
	"$LIGHTNING_BIN" wallet init
	"$LIGHTNING_BIN" invoice pay lnbcrt10n1pmocktest
	# Get payment_hash from ledger.
	run "$LIGHTNING_BIN" ledger list
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -gt 0 ] || skip "no ledger rows"
	# Extract hash from first data row (skip header).
	local hash; hash=$(echo "${lines[0]}" | awk '{print $7}' 2>/dev/null || echo "deadbeef")
	run "$LIGHTNING_BIN" ledger annotate "$hash" "my note"
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-176: Lightning Addresses
# ---------------------------------------------------------------------------

@test "FEAT-176: lightning address (no args) prints usage" {
	run "$LIGHTNING_BIN" address
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage"* ]]
}

@test "FEAT-176: lightning address create without Apache exits non-zero" {
	"$LIGHTNING_BIN" wallet init
	# Override PATH to hide httpd/apache2 (macOS ships httpd at /usr/sbin/httpd).
	PATH="/usr/bin:/bin" run "$LIGHTNING_BIN" address create alice@example.com
	[ "$status" -ne 0 ]
	[[ "$output" == *"Apache"* ]]
}

@test "FEAT-176: lightning address resolve without network fails gracefully" {
	# No curl to real network; should fail but not crash.
	"$LIGHTNING_BIN" wallet init
	run "$LIGHTNING_BIN" address resolve alice@coincorner.com
	[ "$status" -ne 0 ]
}

@test "FEAT-176: lightning address list after no create is empty" {
	"$LIGHTNING_BIN" wallet init
	run "$LIGHTNING_BIN" address list
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# FEAT-175: Liquidity
# ---------------------------------------------------------------------------

@test "FEAT-175: lightning liquidity (no args) prints recfile totals" {
	run "$LIGHTNING_BIN" liquidity
	[ "$status" -eq 0 ]
	[[ "$output" == *"outbound_sat:"* ]]
	[[ "$output" == *"inbound_sat:"* ]]
	[[ "$output" == *"channels:"* ]]
	[[ "$output" == *"ratio:"* ]]
}

@test "FEAT-175: lightning liquidity totals matches the no-arg invocation" {
	run "$LIGHTNING_BIN" liquidity totals
	[ "$status" -eq 0 ]
	[[ "$output" == *"outbound_sat:"* ]]
	[[ "$output" == *"inbound_sat:"* ]]
}

@test "FEAT-175: lightning liquidity status returns TSV" {
	run "$LIGHTNING_BIN" liquidity status
	[ "$status" -eq 0 ]
	[[ "$output" == *"channel_id"* ]]
}

@test "FEAT-175: lightning liquidity provider default sets provider" {
	"$LIGHTNING_BIN" wallet init
	run "$LIGHTNING_BIN" liquidity provider default loop
	[ "$status" -eq 0 ]
	[[ "$output" == *"loop"* ]]
}

@test "FEAT-175: lightning liquidity loop prints note about loopd" {
	run "$LIGHTNING_BIN" liquidity loop out 100000
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

@test "FEAT-175: lightning liquidity boltz prints note" {
	run "$LIGHTNING_BIN" liquidity boltz in 50000
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

@test "FEAT-175: lightning liquidity lsp buy prints note" {
	run "$LIGHTNING_BIN" liquidity lsp test-lsp buy 100000
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-195: Bank mode
# ---------------------------------------------------------------------------

@test "FEAT-195: lightning account create --limit sets ceiling" {
	"$LIGHTNING_BIN" wallet init
	run "$LIGHTNING_BIN" account create alice --limit 50000 --overdraft deny
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
	[[ "$output" == *"50000"* ]]
}

@test "FEAT-195: lightning account create --overdraft rejects invalid value" {
	"$LIGHTNING_BIN" wallet init
	run "$LIGHTNING_BIN" account create alice --overdraft invalid
	[ "$status" -ne 0 ]
}

@test "FEAT-195: lightning account list --balances shows balance" {
	"$LIGHTNING_BIN" wallet init
	"$LIGHTNING_BIN" account create alice --limit 50000 --overdraft deny
	run "$LIGHTNING_BIN" account list --balances
	[ "$status" -eq 0 ]
	[[ "$output" == *"alice"* ]]
}

@test "FEAT-195: lightning invoice pay --account refuses overdraw with deny policy" {
	"$LIGHTNING_BIN" wallet init
	"$LIGHTNING_BIN" account create alice --overdraft deny
	# Balance is 0, try paying 50000 sat — should refuse.
	run "$LIGHTNING_BIN" invoice pay lnbcrt10n1pmocktest --account alice
	[ "$status" -eq 3 ]
	[[ "$output" == *"overdraw"* ]]
}

@test "FEAT-195: lightning ledger statement produces formatted output" {
	"$LIGHTNING_BIN" wallet init
	"$LIGHTNING_BIN" account create alice "Alice account"
	run "$LIGHTNING_BIN" ledger statement --account alice --period 2026-01
	[ "$status" -eq 0 ]
	[[ "$output" == *"Statement for alice"* ]]
	[[ "$output" == *"Opening balance"* ]]
	[[ "$output" == *"Closing balance"* ]]
}

@test "FEAT-195: lightning account apikey create prints a key" {
	command -v secret >/dev/null || skip "secret package not installed"
	"$LIGHTNING_BIN" wallet init
	"$LIGHTNING_BIN" account create alice
	run "$LIGHTNING_BIN" account apikey create alice --scope read
	[ "$status" -eq 0 ]
	[ -n "$output" ]
}

# ---------------------------------------------------------------------------
# FEAT-197: plugin management (reckless wrapper)
# ---------------------------------------------------------------------------

# Stubs reckless so `plugin install/remove/search` are observable in
# tests without hitting GitHub or building anything. The stub records
# its invocations to $BATS_TMPDIR/reckless.log for assertion.
_stub_reckless() {
	cat > "$BIN_SHIM/reckless" <<EOF
#!/bin/sh
# Drop the global flags (-v, --json, etc.) so we can match \$1 against
# the actual subcommand.
while [ \$# -gt 0 ]; do
	case "\$1" in -v|--verbose|-j|--json|-r|--regtest) shift ;; *) break ;; esac
done
echo "reckless \$*" >> "$BATS_TMPDIR/reckless.log"
case "\$1" in
	install)
		# Plant a placeholder binary so 'plugin list' sees it.
		mkdir -p "$HOME/.lightning/plugins"
		printf '#!/bin/sh\nexit 0\n' > "$HOME/.lightning/plugins/\$2"
		chmod +x "$HOME/.lightning/plugins/\$2"
		exit 0
		;;
	uninstall)
		rm -f "$HOME/.lightning/plugins/\$2"
		exit 0
		;;
	search)
		echo "stub-result for \$2"
		exit 0
		;;
	enable|disable|source) exit 0 ;;
	*) exit 0 ;;
esac
EOF
	chmod +x "$BIN_SHIM/reckless"
	: > "$BATS_TMPDIR/reckless.log"
}

@test "FEAT-197: lightning plugin (no args) prints usage" {
	run "$LIGHTNING_BIN" plugin
	[ "$status" -ne 0 ]
	[[ "$output" == *"subcommands"* ]]
}

@test "FEAT-197: plugin list on empty plugins dir is exit 0" {
	run "$LIGHTNING_BIN" plugin list
	[ "$status" -eq 0 ]
}

@test "FEAT-197: plugin list shows installed plugins" {
	mkdir -p "$HOME/.lightning/plugins"
	printf '#!/bin/sh\nexit 0\n' > "$HOME/.lightning/plugins/rebalance"
	chmod +x "$HOME/.lightning/plugins/rebalance"
	printf '#!/bin/sh\nexit 0\n' > "$HOME/.lightning/plugins/summary"
	chmod +x "$HOME/.lightning/plugins/summary"
	run "$LIGHTNING_BIN" plugin list
	[ "$status" -eq 0 ]
	[[ "$output" == *"rebalance"* ]]
	[[ "$output" == *"summary"* ]]
}

@test "FEAT-197: plugin list skips dotfiles and non-executables" {
	mkdir -p "$HOME/.lightning/plugins"
	echo "non-exec content" > "$HOME/.lightning/plugins/.hidden"
	echo "non-exec content" > "$HOME/.lightning/plugins/notaplugin"
	printf '#!/bin/sh\nexit 0\n' > "$HOME/.lightning/plugins/realplugin"
	chmod +x "$HOME/.lightning/plugins/realplugin"
	run "$LIGHTNING_BIN" plugin list
	[ "$status" -eq 0 ]
	[[ "$output" == *"realplugin"* ]]
	[[ "$output" != *".hidden"* ]]
	[[ "$output" != *"notaplugin"* ]]
}

@test "FEAT-197: plugin install routes through reckless when available" {
	_stub_reckless
	run "$LIGHTNING_BIN" plugin install rebalance
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
	[ -x "$HOME/.lightning/plugins/rebalance" ]
	grep -q "install rebalance" "$BATS_TMPDIR/reckless.log"
}

@test "FEAT-197: plugin install <name> <owner/repo> registers source first" {
	_stub_reckless
	run "$LIGHTNING_BIN" plugin install trustedcoin nbd-wtf/trustedcoin
	[ "$status" -eq 0 ]
	# Source registration ran before install.
	grep -q "source add https://github.com/nbd-wtf/trustedcoin" "$BATS_TMPDIR/reckless.log"
	grep -q "install trustedcoin" "$BATS_TMPDIR/reckless.log"
}

@test "FEAT-197: plugin install <name> <full-url> registers source as URL" {
	_stub_reckless
	run "$LIGHTNING_BIN" plugin install foo https://gitlab.com/x/foo
	[ "$status" -eq 0 ]
	grep -q "source add https://gitlab.com/x/foo" "$BATS_TMPDIR/reckless.log"
}

@test "FEAT-197: plugin install errors clearly when reckless is absent" {
	export PATH="/usr/bin:/bin"
	run "$LIGHTNING_BIN" plugin install rebalance
	[ "$status" -eq 127 ]
	[[ "$output" == *"reckless not found"* ]]
	[[ "$output" == *"install/update CLN"* || "$output" == *"core-lightning"* ]]
}

@test "FEAT-197: plugin remove uses reckless when available" {
	_stub_reckless
	mkdir -p "$HOME/.lightning/plugins"
	printf '#!/bin/sh\nexit 0\n' > "$HOME/.lightning/plugins/rebalance"
	chmod +x "$HOME/.lightning/plugins/rebalance"
	run "$LIGHTNING_BIN" plugin remove rebalance
	[ "$status" -eq 0 ]
	grep -q "uninstall rebalance" "$BATS_TMPDIR/reckless.log"
	[ ! -f "$HOME/.lightning/plugins/rebalance" ]
}

@test "FEAT-197: plugin remove falls back to rm when reckless is absent" {
	export PATH="$BIN_SHIM:/usr/bin:/bin"
	mkdir -p "$HOME/.lightning/plugins"
	printf '#!/bin/sh\nexit 0\n' > "$HOME/.lightning/plugins/rebalance"
	chmod +x "$HOME/.lightning/plugins/rebalance"
	run "$LIGHTNING_BIN" plugin remove rebalance
	[ "$status" -eq 0 ]
	[ ! -f "$HOME/.lightning/plugins/rebalance" ]
}

@test "FEAT-197: plugin remove errors when target doesn't exist" {
	export PATH="$BIN_SHIM:/usr/bin:/bin"
	run "$LIGHTNING_BIN" plugin remove nonexistent
	[ "$status" -ne 0 ]
	[[ "$output" == *"no plugin"* ]]
}

@test "FEAT-197: plugin search requires reckless" {
	export PATH="/usr/bin:/bin"
	run "$LIGHTNING_BIN" plugin search rebalance
	[ "$status" -eq 127 ]
	[[ "$output" == *"reckless not found"* ]]
}

@test "FEAT-197: plugin search forwards the query to reckless" {
	_stub_reckless
	run "$LIGHTNING_BIN" plugin search rebalance
	[ "$status" -eq 0 ]
	[[ "$output" == *"stub-result for rebalance"* ]]
	grep -q "search rebalance" "$BATS_TMPDIR/reckless.log"
}

@test "FEAT-197: plugin pre-creates the network config so reckless doesn't prompt" {
	_stub_reckless
	# Make sure the file doesn't exist before.
	rm -f "$HOME/.lightning/bitcoin/config"
	"$LIGHTNING_BIN" plugin install rebalance >/dev/null 2>&1
	[ -f "$HOME/.lightning/bitcoin/config" ]
}

@test "FEAT-197: top-level help lists plugin" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"plugin"* ]]
	[[ "$output" == *"reckless"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-198 (peer verb + auto-bootstrap)
# ---------------------------------------------------------------------------

@test "FEAT-198: lightning peer (no args) prints usage" {
	run "$LIGHTNING_BIN" peer
	[ "$status" -ne 0 ]
	[[ "$output" == *"subcommands"* ]]
}

@test "FEAT-198: lightning peer list returns the TSV header" {
	run "$LIGHTNING_BIN" peer list
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "pubkey	connected	features	addr" ]]
}

@test "FEAT-198: peer list --raw passes the bitmap through unchanged" {
	# The mock's features are short; both modes should print a header
	# and (in --raw) any feature string emitted by the mock verbatim.
	run "$LIGHTNING_BIN" peer list --raw
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "pubkey	connected	features	addr" ]]
}

@test "FEAT-198: peer list errors clearly when daemon is down" {
	echo "down" > "$MOCK_STATE"
	run "$LIGHTNING_BIN" peer list
	[ "$status" -ne 0 ]
	[[ "$output" == *"listpeers failed"* ]]
	[[ "$output" == *"daemon status"* ]]
}

@test "FEAT-198: peer list hints at bootstrap when 0 peers" {
	# Default mock returns an empty peers array.
	run "$LIGHTNING_BIN" peer list
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "pubkey	connected	features	addr" ]]
	[[ "$output" == *"0 peers"* ]]
	[[ "$output" == *"peer bootstrap"* ]]
}

@test "FEAT-198: peer reconnect is an alias for bootstrap" {
	# Honor the skip env var so we don't need lightning-cli connect calls.
	export LIGHTNING_NO_BOOTSTRAP=1
	run "$LIGHTNING_BIN" -v peer reconnect
	[ "$status" -eq 0 ]
	[[ "$output" == *"skipping bootstrap"* ]]
}

@test "FEAT-198: peer reconnect --help mentions the laptop-sleep use case" {
	run "$LIGHTNING_BIN" peer reconnect --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"laptop sleep"* || "$output" == *"network outage"* ]]
}

@test "FEAT-198: peer features decode to BOLT-9 names via the helper" {
	# Sanity-check the decoder function directly: known bits map to
	# canonical names, dedupe collapses mandatory/optional pairs.
	. "$BATS_TEST_DIRNAME/../../libexec/lightning/peer" 2>/dev/null || true
	# 0x8000 -> bit 15 -> payment_secret
	result=$(decode_features 8000)
	[ "$result" = "payment_secret" ]
	# 0x03 -> bits 0 (mandatory) + 1 (optional), both data_loss_protect
	result=$(decode_features 03)
	[ "$result" = "data_loss_protect" ]
	# Empty input returns "-".
	result=$(decode_features "")
	[ "$result" = "-" ]
	# Unknown bit gets bit<N> placeholder.
	result=$(decode_features 8000000000000000000000000000)
	# bit 109 is set (rightmost 1 in 0x8 at the 27th hex char from right)
	[[ "$result" == bit* ]]
}

@test "FEAT-198: lightning peer connect requires a node-uri" {
	run "$LIGHTNING_BIN" peer connect
	[ "$status" -ne 0 ]
	[[ "$output" == *"node-uri"* ]]
}

@test "FEAT-198: lightning peer bootstrap honors LIGHTNING_NO_BOOTSTRAP" {
	export LIGHTNING_NO_BOOTSTRAP=1
	run "$LIGHTNING_BIN" -v peer bootstrap
	[ "$status" -eq 0 ]
	[[ "$output" == *"skipping bootstrap"* ]]
}

@test "FEAT-198: peer bootstrap reads share/lightning/bootstrap-nodes.txt" {
	# Disable lightning-cli connect so we don't depend on a real
	# daemon — bootstrap will report all-failed but exit 0.
	# rm -f first because BIN_SHIM/lightning-cli is a symlink to the
	# real fixture; cat > would follow the link and clobber the mock.
	rm -f "$BIN_SHIM/lightning-cli"
	cat > "$BIN_SHIM/lightning-cli" <<EOF
#!/bin/sh
[ "\$1" = "connect" ] && exit 1
exec "$FIXTURES/lightning-cli-mock" "\$@"
EOF
	chmod +x "$BIN_SHIM/lightning-cli"
	run "$LIGHTNING_BIN" -v peer bootstrap -n 3
	[ "$status" -eq 0 ]
	[[ "$output" == *"bootstrap source:"* ]]
	[[ "$output" == *"share/lightning/bootstrap-nodes.txt"* ]]
}

@test "FEAT-198: peer bootstrap respects \$LIGHTNING_BOOTSTRAP_NODES override" {
	# Custom file with one bogus node.
	local f="$BATS_TMPDIR/boot.$$"
	printf '# header\n%s\n' "deadbeef@127.0.0.1:9999  # custom" > "$f"
	export LIGHTNING_BOOTSTRAP_NODES="$f"
	rm -f "$BIN_SHIM/lightning-cli"
	cat > "$BIN_SHIM/lightning-cli" <<EOF
#!/bin/sh
[ "\$1" = "connect" ] && exit 1
exec "$FIXTURES/lightning-cli-mock" "\$@"
EOF
	chmod +x "$BIN_SHIM/lightning-cli"
	run "$LIGHTNING_BIN" -v peer bootstrap
	[ "$status" -eq 0 ]
	[[ "$output" == *"$f"* ]]
	rm -f "$f"
}

@test "FEAT-198: daemon start auto-bootstraps when peer count is 0" {
	# Daemon down at first, then comes up. Peers count = 0 → bootstrap should run.
	echo "down" > "$MOCK_STATE"
	# Stub lightningd: turns the mock state on AND seeds an empty peers
	# response. The wrapper around lightning-cli needs to return success
	# for getinfo + listpeers with empty .peers, and track 'connect' calls.
	rm -f "$HOME/Library/LaunchAgents/network.lightning.lightningd.plist" 2>/dev/null
	rm -f "$HOME/.config/systemd/user/lightning.service" 2>/dev/null
	cat > "$BIN_SHIM/lightningd" <<EOF
#!/bin/sh
rm -f "$MOCK_STATE"
exit 0
EOF
	chmod +x "$BIN_SHIM/lightningd"

	# Wrap lightning-cli: getinfo + listpeers (empty) succeed; connect
	# attempts are silently dropped so bootstrap completes.
	rm -f "$BIN_SHIM/lightning-cli"
	cat > "$BIN_SHIM/lightning-cli" <<EOF
#!/bin/sh
# Drop --lightning-dir=/--network= flags.
while [ \$# -gt 0 ]; do case "\$1" in --*=*) shift ;; *) break ;; esac; done
case "\$1" in
	getinfo)
		[ -f "$MOCK_STATE" ] && exit 1
		echo '{"id":"x","alias":"x","color":"x","network":"regtest","version":"v","blockheight":1,"num_active_channels":0,"num_pending_channels":0,"num_inactive_channels":0,"num_peers":0}'
		;;
	listpeers)  echo '{"peers": []}' ;;
	listfunds)  echo '{"outputs": [], "channels": []}' ;;
	connect)    echo "{\"id\":\"\$2\"}" ;;   # claim success
	*) exit 0 ;;
esac
EOF
	chmod +x "$BIN_SHIM/lightning-cli"

	run "$LIGHTNING_BIN" -v daemon start
	[ "$status" -eq 0 ]
	[[ "$output" == *"zero peers"* ]]
	[[ "$output" == *"bootstrapping"* ]]
}

@test "FEAT-198: daemon start skips bootstrap when LIGHTNING_NO_BOOTSTRAP set" {
	echo "down" > "$MOCK_STATE"
	rm -f "$HOME/Library/LaunchAgents/network.lightning.lightningd.plist" 2>/dev/null
	rm -f "$HOME/.config/systemd/user/lightning.service" 2>/dev/null
	cat > "$BIN_SHIM/lightningd" <<EOF
#!/bin/sh
rm -f "$MOCK_STATE"
exit 0
EOF
	chmod +x "$BIN_SHIM/lightningd"
	export LIGHTNING_NO_BOOTSTRAP=1
	run "$LIGHTNING_BIN" -v daemon start
	[ "$status" -eq 0 ]
	# Should NOT have run the bootstrap path.
	[[ "$output" != *"bootstrapping the gossip graph"* ]]
}

@test "FEAT-198: top-level help lists peer" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"peer"* ]]
	[[ "$output" == *"bootstrap"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-199 — important-peer persistence + keepalive
# ---------------------------------------------------------------------------

@test "FEAT-199: peer bootstrap appends managed important-peer block" {
	# Bootstrap with a known small node list so we know what to expect.
	local f="$BATS_TMPDIR/boot.$$"
	cat > "$f" <<'EOF'
0301010101010101010101010101010101010101010101010101010101010101@host1:9735
0302020202020202020202020202020202020202020202020202020202020202@host2:9735
0303030303030303030303030303030303030303030303030303030303030303@host3:9735
EOF
	export LIGHTNING_BOOTSTRAP_NODES="$f"
	# Stub the connect calls so we don't need a real daemon.
	rm -f "$BIN_SHIM/lightning-cli"
	cat > "$BIN_SHIM/lightning-cli" <<EOF
#!/bin/sh
case "\$3" in
	connect) printf '{"id":"%s"}\n' "\$4" ;;
	listpeers) echo '{"peers":[]}' ;;
	*) exec "$FIXTURES/lightning-cli-mock" "\$@" ;;
esac
EOF
	chmod +x "$BIN_SHIM/lightning-cli"
	run "$LIGHTNING_BIN" peer bootstrap -n 3
	[ "$status" -eq 0 ]
	[ -f "$HOME/.lightning/config" ]
	grep -q "lightning peers" "$HOME/.lightning/config"
	# Every bootstrap URI should appear as an important-peer= line.
	grep -q "^important-peer=0301010101010101010101010101010101010101010101010101010101010101@host1:9735$" "$HOME/.lightning/config"
	grep -q "^important-peer=0302020202020202020202020202020202020202020202020202020202020202@host2:9735$" "$HOME/.lightning/config"
	grep -q "^important-peer=0303030303030303030303030303030303030303030303030303030303030303@host3:9735$" "$HOME/.lightning/config"
	rm -f "$f"
}

@test "FEAT-199: peer bootstrap re-run is idempotent (single managed block)" {
	local f="$BATS_TMPDIR/boot.$$"
	echo "0301010101010101010101010101010101010101010101010101010101010101@host1:9735" > "$f"
	export LIGHTNING_BOOTSTRAP_NODES="$f"
	rm -f "$BIN_SHIM/lightning-cli"
	cat > "$BIN_SHIM/lightning-cli" <<EOF
#!/bin/sh
case "\$3" in connect) printf '{"id":"%s"}\n' "\$4" ;; *) exec "$FIXTURES/lightning-cli-mock" "\$@" ;; esac
EOF
	chmod +x "$BIN_SHIM/lightning-cli"
	"$LIGHTNING_BIN" peer bootstrap >/dev/null 2>&1
	"$LIGHTNING_BIN" peer bootstrap >/dev/null 2>&1
	"$LIGHTNING_BIN" peer bootstrap >/dev/null 2>&1
	# Exactly one managed block — 2 markers (begin + end), not 6.
	local markers; markers=$(grep -c "lightning peers" "$HOME/.lightning/config" || true)
	[ "$markers" -eq 2 ]
	rm -f "$f"
}

@test "FEAT-199: peer keepalive is no-op when peers >= threshold" {
	# Default mock returns 0 peers; raise threshold to 0 to force no-op.
	run "$LIGHTNING_BIN" -v peer keepalive --threshold 0
	[ "$status" -eq 0 ]
	[[ "$output" == *"no-op"* ]]
}

@test "FEAT-199: peer keepalive runs bootstrap when peers < threshold" {
	# Mock returns 0 peers by default. Stub a small bootstrap file
	# + stub lightning-cli connect to always succeed so bootstrap
	# completes (no real network).
	local f="$BATS_TMPDIR/boot.$$"
	echo "0301010101010101010101010101010101010101010101010101010101010101@host:9735" > "$f"
	export LIGHTNING_BOOTSTRAP_NODES="$f"
	rm -f "$BIN_SHIM/lightning-cli"
	cat > "$BIN_SHIM/lightning-cli" <<EOF
#!/bin/sh
case "\$3" in
	connect)   printf '{"id":"%s"}\n' "\$4" ;;
	listpeers) echo '{"peers":[]}' ;;
	*) exec "$FIXTURES/lightning-cli-mock" "\$@" ;;
esac
EOF
	chmod +x "$BIN_SHIM/lightning-cli"
	run "$LIGHTNING_BIN" -v peer keepalive --threshold 3 --target 2
	[ "$status" -eq 0 ]
	[[ "$output" == *"bootstrapping"* ]]
	[[ "$output" == *"bootstrap source:"* ]]
	rm -f "$f"
}

@test "FEAT-199: peer keepalive errors when daemon is down" {
	echo "down" > "$MOCK_STATE"
	run "$LIGHTNING_BIN" peer keepalive
	[ "$status" -ne 0 ]
	[[ "$output" == *"listpeers failed"* ]]
}

@test "FEAT-199: peer keepalive honors LIGHTNING_NO_BOOTSTRAP" {
	export LIGHTNING_NO_BOOTSTRAP=1
	run "$LIGHTNING_BIN" -v peer keepalive
	[ "$status" -eq 0 ]
	# Exits early before even checking listpeers.
	[[ "$output" == *"keepalive no-op"* ]]
}

@test "FEAT-199: daemon install writes keepalive sidecar (macOS)" {
	if [ "$(uname -s)" != "Darwin" ]; then
		skip "macOS-only — checks the keepalive LaunchAgent plist"
	fi
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" daemon install
	[ "$status" -eq 0 ]
	local plist="$HOME/Library/LaunchAgents/network.lightning.keepalive.plist"
	[ -f "$plist" ]
	grep -q "<string>network.lightning.keepalive</string>" "$plist"
	grep -q "<string>peer</string>" "$plist"
	grep -q "<string>keepalive</string>" "$plist"
	grep -q "<key>NetworkState</key>" "$plist"
	grep -q "<key>StartInterval</key>" "$plist"
	grep -q "<integer>600</integer>" "$plist"
}

@test "FEAT-199: daemon install --no-keepalive skips the sidecar" {
	if [ "$(uname -s)" != "Darwin" ]; then
		skip "macOS-only — Linux test uses different plist path"
	fi
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" daemon install --no-keepalive
	[ "$status" -eq 0 ]
	[ ! -f "$HOME/Library/LaunchAgents/network.lightning.keepalive.plist" ]
}

@test "FEAT-199: daemon install on Linux writes keepalive .timer + .service" {
	if [ "$(uname -s)" = "Darwin" ]; then
		skip "Linux-only — macOS uses launchd"
	fi
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" daemon install
	[ "$status" -eq 0 ]
	[ -f "$HOME/.config/systemd/user/lightning-keepalive.timer" ]
	[ -f "$HOME/.config/systemd/user/lightning-keepalive.service" ]
	grep -q "OnUnitActiveSec=10min" "$HOME/.config/systemd/user/lightning-keepalive.timer"
	grep -q "peer keepalive" "$HOME/.config/systemd/user/lightning-keepalive.service"
}

# ---------------------------------------------------------------------------
# FEAT-200 — fee verb (get / set / policy)
# ---------------------------------------------------------------------------

# Stub lightning-cli to return a synthetic listpeerchannels with two
# channels (one balanced, one depleted) plus a working setchannel.
# Records setchannel calls to $BATS_TMPDIR/setchannel.log for asserts.
_stub_cli_with_channels() {
	rm -f "$BIN_SHIM/lightning-cli"
	cat > "$BIN_SHIM/lightning-cli" <<EOF
#!/bin/sh
# Drop the standard --lightning-dir=/--network= flags.
while [ \$# -gt 0 ]; do
	case "\$1" in --*=*) shift ;; *) break ;; esac
done
case "\$1" in
	listpeerchannels)
		cat <<JSON
{"channels":[
  {"short_channel_id":"100x1x0","peer_id":"02alice","state":"CHANNELD_NORMAL",
   "to_us_msat":500000000,"total_msat":1000000000,
   "fee_base_msat":1000,"fee_proportional_millionths":100,
   "htlc_minimum_msat":1,"htlc_maximum_msat":990000000},
  {"short_channel_id":"100x2x0","peer_id":"02bob","state":"CHANNELD_NORMAL",
   "to_us_msat":50000000,"total_msat":1000000000,
   "fee_base_msat":1000,"fee_proportional_millionths":100,
   "htlc_minimum_msat":1,"htlc_maximum_msat":990000000}
]}
JSON
		;;
	setchannel)
		echo "setchannel \$2 \$3 \$4" >> "$BATS_TMPDIR/setchannel.log"
		echo '{"channels":[]}'
		;;
	getinfo)
		echo '{"id":"02ournode"}'
		;;
	listchannels)
		# match-peer asks for the per-scid update; return a fake update
		# with .destination = our node id so the policy picks it.
		cat <<JSON
{"channels":[
  {"destination":"02ournode","base_fee_millisatoshi":2222,"fee_per_millionth":333}
]}
JSON
		;;
	*) exec "$FIXTURES/lightning-cli-mock" "\$@" ;;
esac
EOF
	chmod +x "$BIN_SHIM/lightning-cli"
	: > "$BATS_TMPDIR/setchannel.log"
}

@test "FEAT-200: lightning fee (no args) prints usage" {
	run "$LIGHTNING_BIN" fee
	[ "$status" -ne 0 ]
	[[ "$output" == *"subcommands"* ]]
}

@test "FEAT-200: fee get on empty channels is exit 0" {
	# Default mock returns {"channels":[]}.
	run "$LIGHTNING_BIN" fee get
	[ "$status" -eq 0 ]
}

@test "FEAT-200: fee get prints one recfile record per channel" {
	_stub_cli_with_channels
	run "$LIGHTNING_BIN" fee get
	[ "$status" -eq 0 ]
	[[ "$output" == *"channel_id:     100x1x0"* ]]
	[[ "$output" == *"channel_id:     100x2x0"* ]]
	[[ "$output" == *"peer:           02alice"* ]]
	[[ "$output" == *"base_msat:      1000"* ]]
	[[ "$output" == *"ppm:            100"* ]]
}

@test "FEAT-200: fee get <channel-id> filters to one record" {
	_stub_cli_with_channels
	run "$LIGHTNING_BIN" fee get 100x2x0
	[ "$status" -eq 0 ]
	[[ "$output" == *"100x2x0"* ]]
	[[ "$output" != *"100x1x0"* ]]
}

@test "FEAT-200: fee get with unknown channel exits 4" {
	_stub_cli_with_channels
	run "$LIGHTNING_BIN" fee get nonexistent
	[ "$status" -eq 4 ]
	[[ "$output" == *"no channel"* ]]
}

@test "FEAT-200: fee set wraps setchannel" {
	_stub_cli_with_channels
	run "$LIGHTNING_BIN" fee set 100x1x0 2000 250
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
	grep -q "setchannel 100x1x0 2000 250" "$BATS_TMPDIR/setchannel.log"
}

@test "FEAT-200: fee set rejects non-numeric values" {
	_stub_cli_with_channels
	run "$LIGHTNING_BIN" fee set 100x1x0 abc 100
	[ "$status" -ne 0 ]
	[[ "$output" == *"non-negative integers"* ]]
}

@test "FEAT-200: fee policy flat (dry-run) shows would_apply" {
	_stub_cli_with_channels
	run "$LIGHTNING_BIN" fee policy flat
	[ "$status" -eq 0 ]
	# Already at base=1000 ppm=100, which is the flat policy.
	[[ "$output" == *"unchanged"* ]]
	# Did NOT call setchannel.
	[ ! -s "$BATS_TMPDIR/setchannel.log" ]
}

@test "FEAT-200: fee policy balanced (dry-run) proposes asymmetric fees" {
	_stub_cli_with_channels
	run "$LIGHTNING_BIN" fee policy balanced
	[ "$status" -eq 0 ]
	# Channel 1 (50% local) -> base=1000 ppm=200 (proposed)
	# Channel 2 (5% local)  -> higher base + ppm
	# Just assert both records appear with different proposed values.
	[[ "$output" == *"channel_id:   100x1x0"* ]]
	[[ "$output" == *"channel_id:   100x2x0"* ]]
	[[ "$output" == *"proposed:"* ]]
	# Dry-run: no setchannel calls.
	[ ! -s "$BATS_TMPDIR/setchannel.log" ]
}

@test "FEAT-200: fee policy balanced --apply calls setchannel" {
	_stub_cli_with_channels
	run "$LIGHTNING_BIN" fee policy balanced --apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"applied"* ]]
	# Both channels differ from flat 1000/100 under balanced, so two calls.
	[ "$(wc -l < $BATS_TMPDIR/setchannel.log)" -gt 0 ]
}

@test "FEAT-200: fee policy match-peer pulls peer's update" {
	_stub_cli_with_channels
	run "$LIGHTNING_BIN" fee policy match-peer
	[ "$status" -eq 0 ]
	# The stub's listchannels returns base=2222 ppm=333.
	[[ "$output" == *"proposed:     base=2222 ppm=333"* ]]
}

@test "FEAT-200: fee policy rejects unknown name" {
	run "$LIGHTNING_BIN" fee policy bogus
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown policy"* ]]
}

@test "FEAT-200: top-level help lists fee" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"fee"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-201 — rebalance verb (LN circular + swap fallback)
# ---------------------------------------------------------------------------

# Plant a fake rebalance plugin so the dispatcher's
# rebalance_plugin_installed check returns true.
_install_fake_rebalance_plugin() {
	mkdir -p "$HOME/.lightning/plugins"
	touch "$HOME/.lightning/plugins/rebalance.py"
}

# Stub lightning-cli: returns 2 normal channels for auto-pair,
# and emits a fake successful rebalance result.
_stub_cli_for_rebalance() {
	rm -f "$BIN_SHIM/lightning-cli"
	cat > "$BIN_SHIM/lightning-cli" <<EOF
#!/bin/sh
while [ \$# -gt 0 ]; do case "\$1" in --*=*) shift ;; *) break ;; esac; done
case "\$1" in
	listpeerchannels)
		cat <<JSON
{"channels":[
  {"short_channel_id":"100x1x0","peer_id":"02alice","state":"CHANNELD_NORMAL",
   "to_us_msat":900000000,"total_msat":1000000000},
  {"short_channel_id":"100x2x0","peer_id":"02bob","state":"CHANNELD_NORMAL",
   "to_us_msat":100000000,"total_msat":1000000000}
]}
JSON
		;;
	rebalance)
		# Args: amount_msat outgoing_scid incoming_scid ...
		echo "rebalance \$2 \$3 \$4" >> "$BATS_TMPDIR/rebalance.log"
		sent=\$(( \$2 + 234 ))
		cat <<JSON
{"sent": \$sent, "received": \$2, "outgoing_route_hops": 4, "status": "complete"}
JSON
		;;
	*) exec "$FIXTURES/lightning-cli-mock" "\$@" ;;
esac
EOF
	chmod +x "$BIN_SHIM/lightning-cli"
	: > "$BATS_TMPDIR/rebalance.log"
}

@test "FEAT-201: lightning rebalance (no args) prints usage" {
	run "$LIGHTNING_BIN" rebalance
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage"* ]]
}

@test "FEAT-201: rebalance errors clearly when plugin not installed" {
	run "$LIGHTNING_BIN" rebalance 100000
	[ "$status" -eq 127 ]
	[[ "$output" == *"plugin install rebalance"* ]]
}

@test "FEAT-201: rebalance rejects non-numeric amount" {
	_install_fake_rebalance_plugin
	run "$LIGHTNING_BIN" rebalance abc
	[ "$status" -ne 0 ]
	[[ "$output" == *"positive integer"* ]]
}

@test "FEAT-201: rebalance auto-picks the most asymmetric pair" {
	_install_fake_rebalance_plugin
	_stub_cli_for_rebalance
	run "$LIGHTNING_BIN" -v rebalance 100000
	[ "$status" -eq 0 ]
	# auto-pair: from=highest outbound (100x1x0), to=lowest (100x2x0)
	[[ "$output" == *"auto-pair: from=100x1x0 to=100x2x0"* ]]
	grep -q "rebalance 100000000 100x1x0 100x2x0" "$BATS_TMPDIR/rebalance.log"
}

@test "FEAT-201: rebalance --from / --to override auto-pair" {
	_install_fake_rebalance_plugin
	_stub_cli_for_rebalance
	run "$LIGHTNING_BIN" rebalance 50000 --from foo --to bar
	[ "$status" -eq 0 ]
	grep -q "rebalance 50000000 foo bar" "$BATS_TMPDIR/rebalance.log"
}

@test "FEAT-201: rebalance --dry-run doesn't call the plugin" {
	_install_fake_rebalance_plugin
	_stub_cli_for_rebalance
	run "$LIGHTNING_BIN" -v rebalance 100000 --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"status:        dry_run"* ]]
	[ ! -s "$BATS_TMPDIR/rebalance.log" ]
}

@test "FEAT-201: rebalance success emits the recfile summary" {
	_install_fake_rebalance_plugin
	_stub_cli_for_rebalance
	run "$LIGHTNING_BIN" rebalance 100000 --from 100x1x0 --to 100x2x0
	[ "$status" -eq 0 ]
	[[ "$output" == *"status:        complete"* ]]
	[[ "$output" == *"from:          100x1x0"* ]]
	[[ "$output" == *"to:            100x2x0"* ]]
	[[ "$output" == *"amount_sat:    100000"* ]]
	[[ "$output" == *"fee_msat:"* ]]
	[[ "$output" == *"fee_ppm:"* ]]
	[[ "$output" == *"route_hops:    4"* ]]
}

@test "FEAT-201: rebalance --fallback swap shells out when LN fails" {
	_install_fake_rebalance_plugin
	# Stub lightning-cli to make `rebalance` fail.
	rm -f "$BIN_SHIM/lightning-cli"
	cat > "$BIN_SHIM/lightning-cli" <<EOF
#!/bin/sh
while [ \$# -gt 0 ]; do case "\$1" in --*=*) shift ;; *) break ;; esac; done
case "\$1" in
	listpeerchannels)
		cat <<JSON
{"channels":[
  {"short_channel_id":"100x1x0","peer_id":"02alice","state":"CHANNELD_NORMAL",
   "to_us_msat":900000000,"total_msat":1000000000},
  {"short_channel_id":"100x2x0","peer_id":"02bob","state":"CHANNELD_NORMAL",
   "to_us_msat":100000000,"total_msat":1000000000}
]}
JSON
		;;
	rebalance) echo "no route" >&2; exit 1 ;;
	listpeers) echo '{"peers":[]}' ;;
	getinfo)   echo '{"id":"02x","alias":"x","color":"x","network":"regtest","version":"v","blockheight":1,"num_active_channels":0,"num_pending_channels":0,"num_inactive_channels":0,"num_peers":0}' ;;
	*) exec "$FIXTURES/lightning-cli-mock" "\$@" ;;
esac
EOF
	chmod +x "$BIN_SHIM/lightning-cli"
	run "$LIGHTNING_BIN" -v rebalance 100000 --fallback swap
	[ "$status" -eq 0 ]
	[[ "$output" == *"swap fallback"* ]]
	[[ "$output" == *"status:        swap_complete"* ]]
}

@test "FEAT-201: top-level help lists rebalance" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"rebalance"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-204 — alert verb (threshold-driven webhooks)
# ---------------------------------------------------------------------------

# Stub curl to record webhook calls to a log.
_stub_webhook_curl() {
	cat > "$BIN_SHIM/curl" <<EOF
#!/bin/sh
# Record the URL (last arg) and payload (after --data).
url=""
payload=""
while [ \$# -gt 0 ]; do
	case "\$1" in
		--data) payload="\$2"; shift 2 ;;
		--data-urlencode) payload="\$2"; shift 2 ;;
		-X|-H|-G|-f|-s|-S|-L|--fail|--silent|--show-error|--location) shift ;;
		https://*|http://*) url="\$1"; shift ;;
		*) shift ;;
	esac
done
echo "webhook \$url payload=\$payload" >> "$BATS_TMPDIR/webhook.log"
exit 0
EOF
	chmod +x "$BIN_SHIM/curl"
	: > "$BATS_TMPDIR/webhook.log"
}

@test "FEAT-204: lightning alert (no args) prints usage" {
	run "$LIGHTNING_BIN" alert
	[ "$status" -ne 0 ]
	[[ "$output" == *"subcommands"* ]]
}

@test "FEAT-204: alert create stores a recfile rule" {
	run "$LIGHTNING_BIN" alert create my-rule \
		--on balance_below \
		--threshold 100000 \
		--webhook https://hooks.slack.com/services/foo
	[ "$status" -eq 0 ]
	[ -f "$HOME/.lightning/alerts/my-rule.conf" ]
	grep -q "on:.*balance_below" "$HOME/.lightning/alerts/my-rule.conf"
	grep -q "threshold:.*100000" "$HOME/.lightning/alerts/my-rule.conf"
	grep -q "webhook:.*hooks.slack.com" "$HOME/.lightning/alerts/my-rule.conf"
}

@test "FEAT-204: alert create rejects missing --on" {
	run "$LIGHTNING_BIN" alert create r --webhook https://example.com
	[ "$status" -ne 0 ]
	[[ "$output" == *"--on"* ]]
}

@test "FEAT-204: alert create rejects missing --webhook" {
	run "$LIGHTNING_BIN" alert create r --on daemon_down
	[ "$status" -ne 0 ]
	[[ "$output" == *"--webhook"* ]]
}

@test "FEAT-204: alert list returns multi-record recfile" {
	"$LIGHTNING_BIN" alert create a --on daemon_down --webhook https://x/a
	"$LIGHTNING_BIN" alert create b --on peer_offline --webhook https://x/b
	run "$LIGHTNING_BIN" alert list
	[ "$status" -eq 0 ]
	[[ "$output" == *"name:        a"* ]]
	[[ "$output" == *"name:        b"* ]]
}

@test "FEAT-204: alert list on empty dir is exit 0" {
	run "$LIGHTNING_BIN" alert list
	[ "$status" -eq 0 ]
}

@test "FEAT-204: alert remove deletes the rule" {
	"$LIGHTNING_BIN" alert create r --on daemon_down --webhook https://x
	run "$LIGHTNING_BIN" alert remove r
	[ "$status" -eq 0 ]
	[ ! -f "$HOME/.lightning/alerts/r.conf" ]
}

@test "FEAT-204: alert remove unknown rule exits 4" {
	run "$LIGHTNING_BIN" alert remove nope
	[ "$status" -eq 4 ]
}

@test "FEAT-204: alert test fires the [TEST] webhook" {
	_stub_webhook_curl
	# daemon_down condition: stub cli to fail getinfo.
	echo "down" > "$MOCK_STATE"
	"$LIGHTNING_BIN" alert create r --on daemon_down --webhook https://example.com/hook
	run "$LIGHTNING_BIN" alert test r
	[ "$status" -eq 0 ]
	[[ "$output" == *"would_fire"* ]]
	grep -q "webhook https://example.com/hook" "$BATS_TMPDIR/webhook.log"
	grep -q "TEST" "$BATS_TMPDIR/webhook.log"
}

@test "FEAT-204: alert test on non-firing condition reports not_firing" {
	# daemon_down: cli getinfo succeeds (default mock state = up).
	"$LIGHTNING_BIN" alert create r --on daemon_down --webhook https://x
	run "$LIGHTNING_BIN" alert test r
	[ "$status" -eq 0 ]
	[[ "$output" == *"not_firing"* ]]
}

@test "FEAT-204: alert run fires + records last_fired; cooldown holds next run" {
	_stub_webhook_curl
	echo "down" > "$MOCK_STATE"
	"$LIGHTNING_BIN" alert create r --on daemon_down --webhook https://x/hook --cooldown 1h
	# First run fires.
	"$LIGHTNING_BIN" -v alert run >/dev/null 2>&1
	grep -q "webhook https://x/hook" "$BATS_TMPDIR/webhook.log"
	[ "$(grep -c webhook $BATS_TMPDIR/webhook.log)" -eq 1 ]
	# Rule file now has last_fired set.
	grep -q "^last_fired:[[:space:]]*[0-9]" "$HOME/.lightning/alerts/r.conf"
	# Second run within cooldown: no new webhook.
	"$LIGHTNING_BIN" -v alert run >/dev/null 2>&1
	[ "$(grep -c webhook $BATS_TMPDIR/webhook.log)" -eq 1 ]
}

@test "FEAT-204: daemon install writes the alert sidecar (macOS)" {
	if [ "$(uname -s)" != "Darwin" ]; then
		skip "macOS-only — Linux uses systemd .timer"
	fi
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" daemon install
	[ "$status" -eq 0 ]
	local plist="$HOME/Library/LaunchAgents/network.lightning.alert.plist"
	[ -f "$plist" ]
	grep -q "<string>alert</string>" "$plist"
	grep -q "<string>run</string>" "$plist"
	grep -q "<integer>60</integer>" "$plist"
}

@test "FEAT-204: daemon install --no-alert skips the sidecar" {
	if [ "$(uname -s)" != "Darwin" ]; then
		skip "macOS-only"
	fi
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" daemon install --no-alert
	[ "$status" -eq 0 ]
	[ ! -f "$HOME/Library/LaunchAgents/network.lightning.alert.plist" ]
}

@test "FEAT-204: daemon install writes alert sidecar on Linux" {
	if [ "$(uname -s)" = "Darwin" ]; then
		skip "Linux-only"
	fi
	printf '#!/bin/sh\nexit 0\n' > "$BIN_SHIM/lightningd"
	chmod +x "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" daemon install
	[ "$status" -eq 0 ]
	[ -f "$HOME/.config/systemd/user/lightning-alert.timer" ]
	[ -f "$HOME/.config/systemd/user/lightning-alert.service" ]
	grep -q "OnUnitActiveSec=1min" "$HOME/.config/systemd/user/lightning-alert.timer"
}

@test "FEAT-204: top-level help lists alert" {
	run "$LIGHTNING_BIN" help
	[[ "$output" == *"alert"* ]]
}

# ---------------------------------------------------------------------------
# FEAT-202 / FEAT-203 — operational guides
# ---------------------------------------------------------------------------

@test "FEAT-202: personal-node guide ships" {
	local guide="$BATS_TEST_DIRNAME/../../share/doc/lightning/guides/personal-node.md"
	[ -f "$guide" ]
	# Cites every verb the guide depends on.
	grep -q "lightning peer bootstrap" "$guide"
	grep -q "lightning plugin install feeadjuster" "$guide"
	grep -q "lightning fee policy balanced" "$guide"
	grep -q "lightning rebalance" "$guide"
	grep -q "lightning alert create" "$guide"
	# Has the honest economics section.
	grep -q "Realistic economics" "$guide"
}

# ---------------------------------------------------------------------------
# FEAT-206 — peer score (Amboss / 1ML / mempool.space)
# ---------------------------------------------------------------------------

# Stub curl: returns canned mempool.space JSON for the test node-id;
# fails for everything else.
_stub_score_curl() {
	cat > "$BIN_SHIM/curl" <<'EOF'
#!/bin/sh
# Pull the URL (last positional). Mempool path includes /lightning/nodes/.
url=""
for a in "$@"; do url="$a"; done
case "$url" in
	*lightning/nodes/0388*)
		cat <<'JSON'
{"public_key":"038888888888888888888888888888888888888888888888888888888888888888",
 "alias":"TESTNODE","color":"#abcdef","first_seen":1546452819,"updated_at":1716224000,
 "sockets":"1.2.3.4:9735","as_number":42,"country_id":1,"longitude":0,"latitude":0,
 "as_organization":"TestCorp","country":{"en":"Testland"},"city":null,
 "features":[],"featuresBits":"deadbeef","active_channel_count":12,
 "capacity":"500000000","opened_channel_count":15,"closed_channel_count":3,
 "custom_records":{}}
JSON
		exit 0
		;;
	*) exit 22 ;;
esac
EOF
	chmod +x "$BIN_SHIM/curl"
}

@test "FEAT-206: peer score requires a node-id" {
	run "$LIGHTNING_BIN" peer score
	[ "$status" -ne 0 ]
	[[ "$output" == *"node-id"* ]]
}

@test "FEAT-206: peer score from mempool emits recfile" {
	_stub_score_curl
	run "$LIGHTNING_BIN" peer score 0388888888888888888888888888888888888888888888888888888888888888888
	[ "$status" -eq 0 ]
	[[ "$output" == *"alias:             TESTNODE"* ]]
	[[ "$output" == *"capacity_sat:      500000000"* ]]
	[[ "$output" == *"channels_active:   12"* ]]
	[[ "$output" == *"country:           Testland"* ]]
	[[ "$output" == *"source:            mempool"* ]]
}

@test "FEAT-206: peer score caches result under \$LIGHTNING_DIR" {
	_stub_score_curl
	"$LIGHTNING_BIN" peer score 0388888888888888888888888888888888888888888888888888888888888888888 >/dev/null
	[ -f "$HOME/.lightning/score-cache/0388888888888888888888888888888888888888888888888888888888888888888.json" ]
}

@test "FEAT-206: peer score --json prints raw upstream JSON" {
	_stub_score_curl
	run "$LIGHTNING_BIN" peer score 0388888888888888888888888888888888888888888888888888888888888888888 --json
	[ "$status" -eq 0 ]
	[[ "$output" == *'"public_key"'* ]]
	[[ "$output" == *'"alias":"TESTNODE"'* ]]
}

@test "FEAT-206: peer score errors clearly when all sources fail" {
	# Stub curl to always fail.
	printf '#!/bin/sh\nexit 22\n' > "$BIN_SHIM/curl"
	chmod +x "$BIN_SHIM/curl"
	run "$LIGHTNING_BIN" peer score 0388888888888888888888888888888888888888888888888888888888888888888
	[ "$status" -eq 4 ]
	[[ "$output" == *"no source returned data"* ]]
}

@test "FEAT-206: peer score --source rejects unknown source" {
	_stub_score_curl
	run "$LIGHTNING_BIN" peer score 0388888888888888888888888888888888888888888888888888888888888888888 --source bogus
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown source"* ]]
}

@test "FEAT-203: routing-node guide ships and cross-links to personal-node" {
	local guide="$BATS_TEST_DIRNAME/../../share/doc/lightning/guides/routing-node.md"
	local personal="$BATS_TEST_DIRNAME/../../share/doc/lightning/guides/personal-node.md"
	[ -f "$guide" ]
	# Cross-link to the personal-node guide (and vice versa).
	grep -q "personal-node.md" "$guide"
	grep -q "routing-node.md" "$personal"
	# Names the operational verbs.
	grep -q "lightning fee" "$guide"
	grep -q "lightning rebalance" "$guide"
	grep -q "lightning alert" "$guide"
	# Honest scope statement up front.
	grep -q "5+ BTC" "$guide"
}
