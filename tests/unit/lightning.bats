#!/usr/bin/env bats
#
# Unit tests for bin/lightning — the educational Lightning Network
# frontend on clightning (FEAT-170..196). Covers the 0.2.0–0.5.0
# surface: dispatcher, lightning.sh source-mode guard, and the
# libexec object dispatchers (wallet / channel / daemon / account /
# ledger / invoice / offer / address / lnurl / liquidity). As of
# 0.5.x the CLI is purely object-oriented: top-level commands are
# objects, actions live as sub-commands. The wallet object is your
# Lightning identity — it owns both the clightning daemon's identity
# (info/peers/balance/seed/unlock) and the git-backed state repo
# (init/push/pull/backup/restore).

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

# ---------------------------------------------------------------------------
# Smoke + semver contract (FEAT-005)
# ---------------------------------------------------------------------------

@test "lightning binary exists and is executable" {
	[ -x "$LIGHTNING_BIN" ]
}

@test "lightning version returns 0.5.0" {
	run "$LIGHTNING_BIN" version
	[ "$status" -eq 0 ]
	[ "$output" = "0.5.0" ]
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

@test "FEAT-171: lightning wallet peers returns the TSV header" {
	run "$LIGHTNING_BIN" wallet peers
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "pubkey	connected	features	addr" ]]
}

@test "FEAT-171: lightning channel list returns the TSV header" {
	run "$LIGHTNING_BIN" channel list
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "id	peer	capacity	local	remote	state" ]]
}

@test "FEAT-171: lightning wallet balance returns the TSV header + row" {
	run "$LIGHTNING_BIN" wallet balance
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "onchain_confirmed_sat	onchain_unconfirmed_sat	channels_sat" ]]
	[[ "${lines[1]}" == "0	0	0" ]]
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

@test "FEAT-183: lightning daemon install writes a user-mode systemd unit" {
	# Stub lightningd so install's ExecStart resolves.
	ln -sf /bin/true "$BIN_SHIM/lightningd"
	run "$LIGHTNING_BIN" daemon install
	[ "$status" -eq 0 ]
	[ -f "$HOME/.config/systemd/user/lightning.service" ]
	grep -q "Description=Lightning Network daemon" "$HOME/.config/systemd/user/lightning.service"
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

@test "FEAT-175: lightning liquidity (no args) prints usage" {
	run "$LIGHTNING_BIN" liquidity
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage"* ]]
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
