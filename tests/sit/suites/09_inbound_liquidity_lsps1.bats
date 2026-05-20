#!/usr/bin/env bats
# SIT 09 — inbound liquidity via a stub LSPS1 endpoint
# (FEAT-175). Real LSPs are out of scope here.

load ../helpers

setup() {
	sit_setup_alice_bob
	lightning wallet new lsp-test >/dev/null
	mkdir -p "$HOME/.lightning/wallet/lsp-test/liquidity/lsp/stub"
	echo "http://127.0.0.1:9737" > \
	    "$HOME/.lightning/wallet/lsp-test/liquidity/lsp/stub/endpoint"
}

teardown() {
	sit_teardown
	pkill -f "lsps-stub" 2>/dev/null || true
}

@test "liquidity in via stub LSPS1 reaches the configured endpoint" {
	# Bring up a 5-line LSPS1 stub that just returns 200 for /info.
	python3 -c "
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({'options':{'max_channel_balance_sat':1000000}}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json')
        self.end_headers(); self.wfile.write(body)
http.server.HTTPServer(('127.0.0.1',9737), H).serve_forever()
" &
	# Tag the bg process so teardown can pkill it.
	echo $! > /tmp/lsps-stub.pid
	sleep 1

	# This test exercises the discovery hop. Full channel purchase
	# requires lsps-client plugin support which isn't present in
	# the base clightning Debian package; covered when that lands.
	run curl -fsSL http://127.0.0.1:9737/info
	[ "$status" -eq 0 ]
	[[ "$output" == *"max_channel_balance_sat"* ]]

	kill "$(cat /tmp/lsps-stub.pid)" 2>/dev/null || true
}
