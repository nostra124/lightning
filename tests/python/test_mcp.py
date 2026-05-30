"""Tests for share/lightning/wellknown/api/mcp.py (FEAT-212 PR-3).

Covers the JSON-RPC envelope: initialize, tools/list, tools/call
(both anonymous + authed paths), resources, error mappings, and
the HTTP method-enforcement.
"""

import json
import os

import pytest


ID = "bcrt1qtestaddress000000000000000000000000000099xxxx"
SCRIPT = "mcp.py"


def env(bin_shim, **extra):
    e = {
        "PATH": f"{bin_shim}:{os.environ['PATH']}",
        "REQUEST_METHOD": "POST",
    }
    e.update(extra)
    return e


def rpc(method, params=None, rid=1):
    body = {"jsonrpc": "2.0", "id": rid, "method": method}
    if params is not None:
        body["params"] = params
    return json.dumps(body).encode()


def post(api_dir, bin_shim, cgi, parse, payload, headers=None):
    e = env(bin_shim, CONTENT_LENGTH=str(len(payload)))
    if headers:
        e.update(headers)
    proc = cgi(api_dir / SCRIPT, env=e, body=payload)
    return parse(proc)


# --- HTTP envelope --------------------------------------------------------


def test_get_returns_405(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    proc = cgi(api_dir / SCRIPT, env=env(bin_shim, REQUEST_METHOD="GET"))
    status, _, _ = parse(proc)
    assert "405" in status


def test_non_json_body_is_invalid_request(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim, CONTENT_LENGTH="3"),
               body=b"abc")
    status, _, _ = parse(proc)
    # _lib.read_body() answers 400 directly on bad JSON.
    assert "400" in status


# --- initialize -----------------------------------------------------------


def test_initialize_returns_capabilities(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, rpc("initialize"))
    assert "200" in status
    j = json.loads(body_out)
    assert j["jsonrpc"] == "2.0"
    assert j["result"]["protocolVersion"] == "2025-03-26"
    assert j["result"]["serverInfo"]["name"] == "lightning"
    assert "tools" in j["result"]["capabilities"]


def test_unknown_method_returns_method_not_found(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, rpc("garbage/whatever"))
    j = json.loads(body_out)
    assert j["error"]["code"] == -32601


def test_notifications_initialized_returns_204(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    proc = cgi(api_dir / SCRIPT,
               env=env(bin_shim,
                       CONTENT_LENGTH=str(len(rpc("notifications/initialized")))),
               body=rpc("notifications/initialized"))
    status, _, _ = parse(proc)
    assert "204" in status


# --- tools/list -----------------------------------------------------------


def test_tools_list_returns_tools(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, rpc("tools/list"))
    assert "200" in status
    j = json.loads(body_out)
    tools = j["result"]["tools"]
    names = {t["name"] for t in tools}
    assert names == {
        "account_create", "account_balance", "account_topup",
        "account_withdraw", "account_pay", "account_recv",
        "account_recv_reusable", "account_history", "account_close",
        "node_info", "channel_list", "node_funds", "account_transfer",
        "invoice_decode", "price", "fee_list", "forward_stats", "peer_summary",
        "node_health", "payment_status", "invoice_status", "peers_score",
    }
    # No `auth` / `verb` / `argmap` keys leak into the public schema.
    for t in tools:
        assert set(t.keys()) <= {"name", "description", "inputSchema"}


# --- tools/call -----------------------------------------------------------


def test_tools_call_account_create_no_auth(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"account_id":"' + ID + '","api_key":"lt_x"}'
    lightning_stub({"api-accounts-create": (0, body)})
    payload = rpc("tools/call",
                  {"name": "account_create", "arguments": {}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    assert "200" in status
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"]["account_id"] == ID


def test_tools_call_account_balance_no_bearer_errors(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""),
                    "api-account-balance": (0, "{}")})
    payload = rpc("tools/call",
                  {"name": "account_balance", "arguments": {"account_id": ID}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["error"]["code"] == -32001
    assert j["error"]["message"] == "missing_bearer"


def test_tools_call_account_balance_bad_bearer_errors(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (1, ""),
                    "api-account-balance": (0, "{}")})
    payload = rpc("tools/call",
                  {"name": "account_balance", "arguments": {"account_id": ID}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload,
                               headers={"HTTP_AUTHORIZATION": "Bearer lt_x"})
    j = json.loads(body_out)
    assert j["error"]["code"] == -32001
    assert j["error"]["message"] == "invalid_bearer"


def test_tools_call_account_balance_happy_path(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"balance_sat":42,"limit_sat":50000,"overdraft":"deny"}'
    lightning_stub({"api-account-verify": (0, ""),
                    "api-account-balance": (0, body)})
    payload = rpc("tools/call",
                  {"name": "account_balance", "arguments": {"account_id": ID}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload,
                               headers={"HTTP_AUTHORIZATION": "Bearer lt_x"})
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"]["balance_sat"] == 42


def test_tools_call_unknown_tool_errors(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    payload = rpc("tools/call", {"name": "explode", "arguments": {}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["error"]["code"] == -32602
    assert j["error"]["message"] == "unknown_tool"


def test_tools_call_bad_account_id_errors(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, "")})
    payload = rpc("tools/call",
                  {"name": "account_balance",
                   "arguments": {"account_id": "NotAnAddress"}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload,
                               headers={"HTTP_AUTHORIZATION": "Bearer lt_x"})
    j = json.loads(body_out)
    assert j["error"]["code"] == -32602
    assert j["error"]["message"] == "account_id_required"


def test_tools_call_pay_routes_optional_sat(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""),
                    "api-account-pay": (0, '{"payment_hash":"deadbeef","amount_sat":42,"fee_sat":1,"status":"complete"}')})
    payload = rpc("tools/call",
                  {"name": "account_pay",
                   "arguments": {"account_id": ID,
                                 "target": "lnbc1pxx",
                                 "sat": 100}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload,
                               headers={"HTTP_AUTHORIZATION": "Bearer lt_x"})
    j = json.loads(body_out)
    assert j["result"]["structuredContent"]["payment_hash"] == "deadbeef"


def test_tools_call_recv_reusable_with_any(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""),
                    "api-account-recv-reusable": (0, '{"bolt12":"lno1xxx","offer_id":"oid","amount_sat":null}')})
    payload = rpc("tools/call",
                  {"name": "account_recv_reusable",
                   "arguments": {"account_id": ID, "sat": "any"}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload,
                               headers={"HTTP_AUTHORIZATION": "Bearer lt_x"})
    j = json.loads(body_out)
    assert j["result"]["structuredContent"]["bolt12"] == "lno1xxx"


def test_tools_call_backend_failure_returns_isError(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({"api-account-verify": (0, ""),
                    "api-account-pay": (6, '{"error":"target_shape_not_implemented"}')})
    payload = rpc("tools/call",
                  {"name": "account_pay",
                   "arguments": {"account_id": ID, "target": "lnurl1xxx"}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload,
                               headers={"HTTP_AUTHORIZATION": "Bearer lt_x"})
    j = json.loads(body_out)
    assert j["result"]["isError"] is True
    assert j["result"]["structuredContent"]["error"] == "target_shape_not_implemented"


# --- resources -----------------------------------------------------------


def test_resources_list_returns_four(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, rpc("resources/list"))
    j = json.loads(body_out)
    uris = {r["uri"] for r in j["result"]["resources"]}
    assert uris == {"account://{id}", "account://{id}/ledger", "account://{id}/topup",
                    "node://info", "node://health"}


def test_resources_read_account_root(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"balance_sat":7,"limit_sat":null,"overdraft":"deny"}'
    lightning_stub({"api-account-verify": (0, ""),
                    "api-account-balance": (0, body)})
    payload = rpc("resources/read", {"uri": f"account://{ID}"})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload,
                               headers={"HTTP_AUTHORIZATION": "Bearer lt_x"})
    j = json.loads(body_out)
    contents = j["result"]["contents"]
    assert len(contents) == 1
    assert contents[0]["uri"] == f"account://{ID}"
    assert "balance_sat" in contents[0]["text"]


def test_resources_read_topup(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"address":"' + ID + '","uri":"bitcoin:' + ID + '","qr_text":"x"}'
    lightning_stub({"api-account-verify": (0, ""),
                    "api-account-topup": (0, body)})
    payload = rpc("resources/read", {"uri": f"account://{ID}/topup"})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload,
                               headers={"HTTP_AUTHORIZATION": "Bearer lt_x"})
    j = json.loads(body_out)
    assert "bitcoin:" in j["result"]["contents"][0]["text"]


def test_resources_read_ledger_returns_history(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"entries":[],"has_more":false}'
    lightning_stub({"api-account-verify": (0, ""),
                    "api-account-history": (0, body)})
    payload = rpc("resources/read", {"uri": f"account://{ID}/ledger"})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload,
                               headers={"HTTP_AUTHORIZATION": "Bearer lt_x"})
    j = json.loads(body_out)
    assert "entries" in j["result"]["contents"][0]["text"]


def test_tools_call_node_info(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"pubkey":"0266e4598d1d3c415f572a8488830b60f7e744ed9235eb0b1ba93283b315c03518","alias":"alice","num_channels":2,"local_msat":200000}'
    lightning_stub({"api-node-info": (0, body)})
    payload = rpc("tools/call", {"name": "node_info", "arguments": {}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"]["alias"] == "alice"


def test_tools_call_history(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"entries":[{"id":1,"ts":"2026-01-01","direction":"in","amount_msat":5000,"peer":"-","payment_hash":"-","message":"","note":""}],"has_more":false}'
    lightning_stub({"api-account-verify": (0, ""),
                    "api-account-history": (0, body)})
    payload = rpc("tools/call",
                  {"name": "account_history",
                   "arguments": {"account_id": ID}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload,
                               headers={"HTTP_AUTHORIZATION": "Bearer lt_x"})
    j = json.loads(body_out)
    assert j["result"]["structuredContent"]["entries"][0]["direction"] == "in"


def test_resources_read_node_info(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"pubkey":"0266e4598d1d3c415f572a8488830b60f7e744ed9235eb0b1ba93283b315c03518","alias":"alice","num_channels":2,"local_msat":200000}'
    lightning_stub({"api-node-info": (0, body)})
    payload = rpc("resources/read", {"uri": "node://info"})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert "pubkey" in j["result"]["contents"][0]["text"]


def test_tools_call_node_health(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"ok":true,"daemon":true,"block_height":900000,"num_channels":3,"balanced":true,"pending_htlcs":0,"warnings":[]}'
    lightning_stub({"api-node-health": (0, body)})
    payload = rpc("tools/call", {"name": "node_health", "arguments": {}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"]["ok"] is True
    assert j["result"]["structuredContent"]["block_height"] == 900000


def test_tools_call_peer_summary(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '[{"peer_id":"02aaa","alias":"bob","connected":true,"num_channels":1,"local_sat":500000,"remote_sat":500000}]'
    lightning_stub({"api-peer-summary": (0, body)})
    payload = rpc("tools/call", {"name": "peer_summary", "arguments": {}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"][0]["alias"] == "bob"


def test_tools_call_forward_stats(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"count":5,"earned_msat":2500,"failed_count":1}'
    lightning_stub({"api-forward-stats": (0, body)})
    payload = rpc("tools/call", {"name": "forward_stats", "arguments": {}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"]["earned_msat"] == 2500


def test_tools_call_fee_list(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '[{"channel_id":"100x1x0","base_msat":1000,"ppm":1}]'
    lightning_stub({"api-fee-list": (0, body)})
    payload = rpc("tools/call", {"name": "fee_list", "arguments": {}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"][0]["channel_id"] == "100x1x0"


def test_tools_call_price(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"base":"EUR","sat_per_unit":0.000009,"price_fiat":111111,"ts":"2026-05-30T10:00:00Z"}'
    lightning_stub({"api-price": (0, body)})
    payload = rpc("tools/call", {"name": "price", "arguments": {"base": "EUR"}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"]["base"] == "EUR"


def test_tools_call_invoice_decode(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"bolt11":"lnbc1pxx","amount_sat":1000,"description":"test","payee":"02aaa","expires_at":"2026-06-01T00:00:00Z","payment_hash":"deadbeef"}'
    lightning_stub({"invoice-decode": (0, body)})
    payload = rpc("tools/call",
                  {"name": "invoice_decode",
                   "arguments": {"bolt11": "lnbc1pxx"}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"]["payment_hash"] == "deadbeef"


def test_tools_call_account_transfer(api_dir, bin_shim, lightning_stub, cgi, parse):
    ID2 = "bcrt1qtestaddress000000000000000000000000000088yyyy"
    body = f'{{"transfer_id":"xfer:1","from":"{ID}","to":"{ID2}","amount_sat":10}}'
    lightning_stub({"api-account-verify": (0, ""),
                    "api-account-transfer": (0, body)})
    payload = rpc("tools/call",
                  {"name": "account_transfer",
                   "arguments": {"account_id": ID, "to": ID2, "sat": 10}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload,
                               headers={"HTTP_AUTHORIZATION": "Bearer lt_x"})
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"]["amount_sat"] == 10


def test_tools_call_channel_list(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '[{"peer_id":"02aaa","alias":"bob","channel_id":"abc","capacity_sat":1000000,"local_sat":500000,"remote_sat":500000,"state":"CHANNELD_NORMAL"}]'
    lightning_stub({"api-channel-list": (0, body)})
    payload = rpc("tools/call", {"name": "channel_list", "arguments": {}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"][0]["alias"] == "bob"


def test_tools_call_node_funds(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"total_sat":5000,"onchain_sat":1000,"offchain_sat":4000,"outputs":[],"channels":[]}'
    lightning_stub({"node-funds": (0, body)})
    payload = rpc("tools/call", {"name": "node_funds", "arguments": {}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"]["total_sat"] == 5000


def test_resources_read_node_health(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"ok":true,"daemon":true,"block_height":900000,"num_channels":2,"balanced":true,"pending_htlcs":0,"warnings":[]}'
    lightning_stub({"api-node-health": (0, body)})
    payload = rpc("resources/read", {"uri": "node://health"})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert "ok" in j["result"]["contents"][0]["text"]


def test_resources_read_bad_uri_errors(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    payload = rpc("resources/read", {"uri": "http://elsewhere/"})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["error"]["code"] == -32602


def test_resources_read_no_bearer_errors(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    payload = rpc("resources/read", {"uri": f"account://{ID}"})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["error"]["code"] == -32001
    assert j["error"]["message"] == "missing_bearer"


# --- prompts -------------------------------------------------------------


def test_prompts_list_returns_empty(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, rpc("prompts/list"))
    j = json.loads(body_out)
    assert j["result"]["prompts"] == []


# --- ping ---------------------------------------------------------------


def test_ping(api_dir, bin_shim, lightning_stub, cgi, parse):
    lightning_stub({})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, rpc("ping"))
    j = json.loads(body_out)
    assert j["result"] == {}


def test_tools_call_payment_status(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"payment_hash":"abc123","status":"complete","amount_msat":10000,"fee_msat":1,"destination":"02aaa","created_at":1700000000}'
    lightning_stub({"api-payment-status": (0, body)})
    payload = rpc("tools/call", {"name": "payment_status", "arguments": {"payment_hash": "abc123"}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"]["status"] == "complete"


def test_tools_call_invoice_status(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '{"payment_hash":"abc123","label":"my-label","status":"paid","amount_msat":5000,"paid_at":1700000001}'
    lightning_stub({"api-invoice-status": (0, body)})
    payload = rpc("tools/call", {"name": "invoice_status", "arguments": {"query": "my-label"}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"]["status"] == "paid"


def test_tools_call_peers_score(api_dir, bin_shim, lightning_stub, cgi, parse):
    body = '[{"peer_id":"02aaa","alias":"bob","score":80,"num_channels":2,"local_sat":500000,"remote_sat":500000,"connected":true,"local_ratio":0.5}]'
    lightning_stub({"api-node-peers-score": (0, body)})
    payload = rpc("tools/call", {"name": "peers_score", "arguments": {}})
    status, _, body_out = post(api_dir, bin_shim, cgi, parse, payload)
    j = json.loads(body_out)
    assert j["result"]["isError"] is False
    assert j["result"]["structuredContent"][0]["score"] == 80
