#!/usr/bin/env bash
# thunderd live-node integration check (FEAT-300/309/310 verification).
#
# Brings up a regtest stack with podman and drives the *real* cln-rpc
# integration of the Rust `thunderd` daemon end-to-end:
#
#     bitcoind (regtest)
#        └── cln   (Core Lightning)  ── thunderd talks to THIS over its
#        └── cln2  (counterparty)        lightning-rpc socket
#
# Unlike the unit suite (which mocks the node), this proves thunderd
# against a live lightningd: health/getinfo, BOLT-11 receive, BOLT-12
# offer, the bearer-auth contract, and a real channel payment
# (decode + pay + ledger debit). This is the shadow-run prerequisite
# for the 2.0 cutover (FEAT-326).
#
# Soft-skips (exit 0) when podman is unavailable, matching `make check-sit`.
#
# Usage:  tests/sit/thunderd-live.sh [--keep]
#   --keep   leave the stack running afterwards (default: tear down)

set -euo pipefail

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

if ! command -v podman >/dev/null 2>&1; then
	echo "podman not installed; soft-skipping thunderd live SIT"
	exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BTC_IMG="docker.io/polarlightning/bitcoind:27.0"
CLN_IMG="docker.io/polarlightning/clightning:24.11.1"
NET="thunderd-sit-net"
VOL="thunderd-sit-lndata"
LNDIR="/home/clightning/.lightning"
SOCK="$LNDIR/regtest/lightning-rpc"
BASE="http://127.0.0.1:9737/.well-known/thunder/v1"

PASS=0
FAIL=0
ok()   { echo "ok   - $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1 :: $2"; fi; }

cleanup() {
	[ "$KEEP" -eq 1 ] && { echo "--keep: leaving stack up"; return; }
	podman rm -f thunderd cln cln2 btc >/dev/null 2>&1 || true
	podman volume rm "$VOL" >/dev/null 2>&1 || true
	podman network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

BCLI() { podman exec btc bitcoin-cli -regtest -rpcuser=polaruser -rpcpassword=polarpass "$@"; }
MINER() { BCLI -rpcwallet=miner "$@"; }
CLI()  { podman exec cln  lightning-cli --lightning-dir="$LNDIR" --network=regtest "$@"; }
CLI2() { podman exec cln2 lightning-cli --lightning-dir="$LNDIR" --network=regtest "$@"; }

echo "==> building thunderd image"
podman build -t thunderd -f "$REPO_ROOT/tests/sit/podman/Dockerfile.thunderd" "$REPO_ROOT/thunder" >/dev/null
podman pull "$BTC_IMG" >/dev/null
podman pull "$CLN_IMG" >/dev/null

echo "==> fresh network + volume"
cleanup
podman network create "$NET" >/dev/null
podman volume create "$VOL" >/dev/null

echo "==> bitcoind (regtest)"
podman run -d --name btc --network "$NET" "$BTC_IMG" \
	bitcoind -server=1 -regtest=1 -txindex=1 \
		-rpcuser=polaruser -rpcpassword=polarpass \
		-rpcbind=0.0.0.0 -rpcallowip=0.0.0.0/0 -rpcport=18443 \
		-fallbackfee=0.0002 -dnsseed=0 -upnp=0 -listen=0 >/dev/null
sleep 4
MINER createwallet miner >/dev/null 2>&1 || true
MINER -generate 150 >/dev/null 2>&1 || MINER generatetoaddress 150 "$(MINER getnewaddress)" >/dev/null

echo "==> cln (the node thunderd drives) + cln2 (counterparty)"
for n in cln cln2; do
	# Only cln (the node thunderd drives) shares its lightning dir out on
	# the volume, so thunderd can reach the lightning-rpc socket.
	vol_args=()
	[ "$n" = cln ] && vol_args=(-v "$VOL:$LNDIR")
	podman run -d --name "$n" --network "$NET" "${vol_args[@]}" \
		"$CLN_IMG" \
		lightningd --alias="$n" --network=regtest --addr=0.0.0.0:9735 \
			--bitcoin-rpcuser=polaruser --bitcoin-rpcpassword=polarpass \
			--bitcoin-rpcconnect=btc --bitcoin-rpcport=18443 --log-level=info >/dev/null
done
until podman exec cln  test -S "$SOCK" 2>/dev/null; do sleep 2; done
until podman exec cln2 test -S "$SOCK" 2>/dev/null; do sleep 2; done

echo "==> fund cln + open a channel to cln2"
MINER sendtoaddress "$(CLI newaddr | jq -r .bech32)" 5 >/dev/null
MINER generatetoaddress 6 "$(MINER getnewaddress)" >/dev/null
for _ in $(seq 1 20); do [ "$(CLI listfunds | jq '[.outputs[]]|length')" -gt 0 ] && break; sleep 5; done
ID2=$(CLI2 getinfo | jq -r .id)
CLI connect "$ID2@cln2:9735" >/dev/null
# push_msat seeds cln2's side so it has spendable liquidity above the
# channel reserve — needed for the inbound-settlement assertion, where
# cln2 must pay a thunderd invoice back to cln.
CLI fundchannel id="$ID2" amount=2000000 push_msat=1000000000msat >/dev/null
MINER generatetoaddress 6 "$(MINER getnewaddress)" >/dev/null
for _ in $(seq 1 24); do [ "$(CLI  listpeerchannels | jq -r '.channels[0].state // ""')" = "CHANNELD_NORMAL" ] && break; sleep 5; done
for _ in $(seq 1 24); do [ "$(CLI2 listpeerchannels | jq -r '.channels[0].state // ""')" = "CHANNELD_NORMAL" ] && break; sleep 5; done

echo "==> thunderd against the live node"
podman run -d --name thunderd --network "$NET" -p 9737:9737 -v "$VOL:$LNDIR" \
	thunderd \
	--http-bind 0.0.0.0 --http-port 9737 --network regtest --cln-socket "$SOCK" >/dev/null
until curl -sf "$BASE/health" >/dev/null 2>&1; do sleep 2; done

echo
echo "==== assertions ===="

HEALTH=$(curl -s "$BASE/health")
NODE_ID=$(CLI getinfo | jq -r .id)
check "health reports the live node connected" \
	"[ \"\$(echo '$HEALTH' | jq -r .cln.connected)\" = true ]"
check "health node id matches the real lightningd" \
	"[ \"\$(echo '$HEALTH' | jq -r .cln.id)\" = \"$NODE_ID\" ]"

ACC=$(curl -s -X POST "$BASE/accounts" -H 'content-type: application/json' -d '{"label":"sit"}')
ID=$(echo "$ACC" | jq -r .id); KEY=$(echo "$ACC" | jq -r .api_key)
check "account create returns an account id + lt_ api key" \
	"[ -n \"$ID\" ] && [[ \"$KEY\" == lt_* ]]"

INV=$(curl -s -X POST "$BASE/accounts/$ID/invoice" -H "authorization: Bearer $KEY" \
	-H 'content-type: application/json' -d '{"amount_msat":123000,"description":"sit-recv"}')
BOLT11=$(echo "$INV" | jq -r .bolt11)
DEC=$(CLI decode "$BOLT11")
check "BOLT-11 minted via the node decodes as valid on-node" \
	"[ \"\$(echo '$DEC' | jq -r .valid)\" = true ] && [ \"\$(echo '$DEC' | jq -r .amount_msat)\" = 123000 ]"
check "the invoice actually exists on the node (real cln-rpc, not faked)" \
	"CLI listinvoices | jq -e '.invoices[]|select(.description==\"sit-recv\")' >/dev/null"

OFF=$(curl -s -X POST "$BASE/accounts/$ID/offer" -H "authorization: Bearer $KEY" \
	-H 'content-type: application/json' -d '{"amount_msat":50000,"description":"sit-offer"}')
check "BOLT-12 offer minted via the node decodes as a valid offer" \
	"[ \"\$(CLI decode \"\$(echo '$OFF' | jq -r .bolt12)\" | jq -r .type)\" = 'bolt12 offer' ]"

CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/accounts/$ID/invoice" \
	-H 'content-type: application/json' -d '{"amount_msat":1000}')
check "invoice without a bearer is rejected 401 (auth contract)" "[ \"$CODE\" = 401 ]"

curl -s -X POST "$BASE/accounts/$ID/topup" -H "authorization: Bearer $KEY" \
	-H 'content-type: application/json' -d '{"amount_msat":150000}' >/dev/null
INV2=$(CLI2 invoice 100000 "sit-pay-$$" "thunderd pays this" | jq -r .bolt11)
SEND=$(curl -s -X POST "$BASE/accounts/$ID/send" -H "authorization: Bearer $KEY" \
	-H 'content-type: application/json' -d "{\"bolt11\":\"$INV2\"}")
check "send pays a real invoice over the channel (status complete)" \
	"[ \"\$(echo '$SEND' | jq -r .status)\" = complete ]"
check "ledger debits the custodial balance 150000 -> 50000" \
	"[ \"\$(echo '$SEND' | jq -r .balance_msat)\" = 50000 ]"
check "counterparty cln2 confirms the invoice PAID" \
	"[ \"\$(CLI2 listinvoices | jq -r '.invoices[]|select(.label==\"sit-pay-$$\").status')\" = paid ]"

# Inbound settlement (FEAT-310): cln2 pays a thunderd-issued invoice; the
# reconciler (waitanyinvoice) must credit the account ledger. Balance was
# 50000 after the send; a 40000-msat inbound payment should take it to 90000.
RINV=$(curl -s -X POST "$BASE/accounts/$ID/invoice" -H "authorization: Bearer $KEY" \
	-H 'content-type: application/json' -d '{"amount_msat":40000,"description":"sit-settle"}' | jq -r .bolt11)
CLI2 pay "$RINV" >/dev/null
NEWBAL=0
for _ in $(seq 1 20); do
	NEWBAL=$(curl -s "$BASE/accounts/$ID" -H "authorization: Bearer $KEY" | jq -r .balance_msat)
	[ "$NEWBAL" = 90000 ] && break
	sleep 3
done
check "reconciler credits the ledger on inbound settlement (50000 -> 90000)" \
	"[ \"$NEWBAL\" = 90000 ]"

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
