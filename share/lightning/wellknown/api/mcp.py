#!/usr/bin/env python3
"""MCP server for the FEAT-212 account API.

JSON-RPC 2.0 dispatcher.  Maps the eight account verbs to MCP tools
+ three account resources.  Stdlib-only — same dependency posture
as the rest of the wellknown/ CGI scripts.

Why CGI instead of an ASGI long-runner?  The MCP transport spec
("Streamable HTTP", 2025-03-26) is only mandatory for servers
that initiate messages back to the client.  Our tool surface is
pure request/response: agent calls `account_balance`, we shell
out, return the result.  Under that constraint CGI works fine
and we keep the no-new-deps stance (no FastAPI, no `mcp` SDK).

If a future tool needs streaming (e.g. waiting for an invoice
to settle), the v1 contract here can grow a separate SSE
endpoint without breaking existing callers.

Protocol version reported: "2025-03-26".  Capabilities:
  - tools (list + call)
  - resources (list + read)
  - prompts (list — empty)
  - logging (no-op)

POST /.well-known/lightning/v1/mcp   body: JSON-RPC 2.0 envelope.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lightning"))
import _lib  # noqa: E402


PROTOCOL_VERSION = "2025-03-26"
SERVER_NAME = "lightning"
SERVER_VERSION = "0.1.0"

ACCOUNT_RESOURCE_RE = re.compile(
    r"^account://(bc1|tb1|bcrt1)[0-9a-z]{10,87}(/(ledger|topup))?$"
)


# --- JSON-RPC plumbing ----------------------------------------------------


def jsonrpc_response(req_id, result=None, error=None):
    body = {"jsonrpc": "2.0", "id": req_id}
    if error is not None:
        body["error"] = error
    else:
        body["result"] = result
    return body


def jsonrpc_error(req_id, code, message, data=None):
    err = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return jsonrpc_response(req_id, error=err)


# --- tool definitions ----------------------------------------------------

ID_PROP = {
    "type": "string",
    "description": "Bech32 bitcoin address that identifies the account "
                   "(returned by account_create).",
    "pattern": r"^(bc1|tb1|bcrt1)[0-9a-z]{10,87}$",
}

TOOLS = [
    {
        "name": "account_create",
        "description": "Open a new Lightning account.  Returns the "
                       "account ID (a bitcoin address that doubles as "
                       "the on-chain top-up destination) plus a one-"
                       "time API key.  Anonymous — no bearer needed.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "hint": {
                    "type": "string",
                    "description": "Optional human label, persisted in "
                                   "the description column.",
                    "maxLength": 64,
                },
            },
            "additionalProperties": False,
        },
        "auth": "anonymous",
        "verb": ["api-accounts-create"],
        "argmap": lambda a: ["--hint", a["hint"]] if a.get("hint") else [],
    },
    {
        "name": "account_balance",
        "description": "Return balance, limit, and overdraft policy.",
        "inputSchema": {
            "type": "object",
            "required": ["account_id"],
            "properties": {"account_id": ID_PROP},
            "additionalProperties": False,
        },
        "auth": "account",
        "verb": ["api-account-balance"],
        "argmap": lambda a: [a["account_id"]],
    },
    {
        "name": "account_topup",
        "description": "Get the BIP-21 URI for on-chain top-up.  The "
                       "account ID IS the top-up address; this is a "
                       "format-conversion convenience.",
        "inputSchema": {
            "type": "object",
            "required": ["account_id"],
            "properties": {
                "account_id": ID_PROP,
                "sat": {"type": "integer", "minimum": 1,
                        "description": "Optional amount; encoded into "
                                       "the BIP-21 amount= field in BTC."},
            },
            "additionalProperties": False,
        },
        "auth": "account",
        "verb": ["api-account-topup"],
        "argmap": lambda a: ([a["account_id"], str(a["sat"])]
                             if "sat" in a else [a["account_id"]]),
    },
    {
        "name": "account_withdraw",
        "description": "Withdraw on-chain via a submarine swap (Boltz). "
                       "Returns the swap ID; settles asynchronously.",
        "inputSchema": {
            "type": "object",
            "required": ["account_id", "sat", "address"],
            "properties": {
                "account_id": ID_PROP,
                "sat": {"type": "integer", "minimum": 1},
                "address": {"type": "string", "minLength": 26},
            },
            "additionalProperties": False,
        },
        "auth": "account",
        "verb": ["api-account-withdraw"],
        "argmap": lambda a: [a["account_id"], str(a["sat"]), a["address"]],
    },
    {
        "name": "account_pay",
        "description": "Pay a Lightning target.  Currently BOLT-11 "
                       "only; LNURL / BOLT-12 / keysend return a "
                       "`target_shape_not_implemented` error.",
        "inputSchema": {
            "type": "object",
            "required": ["account_id", "target"],
            "properties": {
                "account_id": ID_PROP,
                "target": {"type": "string", "minLength": 1,
                           "description": "BOLT-11 invoice (lnbc..., "
                                          "lntb..., lnbcrt...)."},
                "sat": {"type": "integer", "minimum": 1,
                        "description": "Required only for amount-less "
                                       "invoices."},
            },
            "additionalProperties": False,
        },
        "auth": "account",
        "verb": ["api-account-pay"],
        "argmap": lambda a: ([a["account_id"], a["target"], "--sat", str(a["sat"])]
                             if "sat" in a
                             else [a["account_id"], a["target"]]),
    },
    {
        "name": "account_recv",
        "description": "Mint a single-use BOLT-11 invoice for this "
                       "account.",
        "inputSchema": {
            "type": "object",
            "required": ["account_id", "sat"],
            "properties": {
                "account_id": ID_PROP,
                "sat": {"type": "integer", "minimum": 1},
                "description": {"type": "string", "maxLength": 256},
            },
            "additionalProperties": False,
        },
        "auth": "account",
        "verb": ["api-account-recv"],
        "argmap": lambda a: ([a["account_id"], str(a["sat"]),
                              "--desc", a["description"]]
                             if a.get("description")
                             else [a["account_id"], str(a["sat"])]),
    },
    {
        "name": "account_recv_reusable",
        "description": "Mint a reusable BOLT-12 offer.  `sat` may be "
                       "the literal string \"any\" for an open-ended "
                       "amount.",
        "inputSchema": {
            "type": "object",
            "required": ["account_id", "sat"],
            "properties": {
                "account_id": ID_PROP,
                "sat": {
                    "oneOf": [
                        {"type": "integer", "minimum": 1},
                        {"type": "string", "enum": ["any"]},
                    ],
                },
                "description": {"type": "string", "maxLength": 256},
            },
            "additionalProperties": False,
        },
        "auth": "account",
        "verb": ["api-account-recv-reusable"],
        "argmap": lambda a: ([a["account_id"], str(a["sat"]),
                              "--desc", a["description"]]
                             if a.get("description")
                             else [a["account_id"], str(a["sat"])]),
    },
    {
        "name": "account_history",
        "description": "Return recent ledger entries for the account.  "
                       "Each entry has id, ts, direction (\"in\"/\"out\"), "
                       "amount_msat, peer, payment_hash, message, note.  "
                       "Paginate backwards via before_id.  Default limit 50.",
        "inputSchema": {
            "type": "object",
            "required": ["account_id"],
            "properties": {
                "account_id": ID_PROP,
                "limit": {"type": "integer", "minimum": 1, "maximum": 200,
                          "default": 50},
                "before_id": {"type": "integer", "minimum": 1},
            },
            "additionalProperties": False,
        },
        "auth": "account",
        "verb": ["api-account-history"],
        "argmap": lambda a: (
            [a["account_id"]]
            + (["--limit", str(a["limit"])] if a.get("limit") else [])
            + (["--before", str(a["before_id"])] if a.get("before_id") else [])
        ),
    },
    {
        "name": "account_close",
        "description": "Close the account.  Revokes its API key and "
                       "stamps closed_at.",
        "inputSchema": {
            "type": "object",
            "required": ["account_id"],
            "properties": {"account_id": ID_PROP},
            "additionalProperties": False,
        },
        "auth": "account",
        "verb": ["api-account-close"],
        "argmap": lambda a: [a["account_id"]],
    },
    {
        "name": "node_info",
        "description": "Return the node's public identity: pubkey, alias, "
                       "active channel count, and total local capacity in "
                       "msat.  No account auth required.",
        "inputSchema": {
            "type": "object",
            "required": [],
            "properties": {},
            "additionalProperties": False,
        },
        "auth": None,
        "verb": ["api-node-info"],
        "argmap": lambda a: [],
    },
    {
        "name": "fee_list",
        "description": "List per-channel routing fee policy: base_msat and "
                       "ppm (parts-per-million) for each active channel. "
                       "No account auth required.",
        "inputSchema": {
            "type": "object",
            "required": [],
            "properties": {},
            "additionalProperties": False,
        },
        "auth": None,
        "verb": ["api-fee-list"],
        "argmap": lambda a: [],
    },
    {
        "name": "price",
        "description": "Return the latest stored sat/fiat price tick. "
                       "Returns {base, sat_per_unit, price_fiat, ts} or "
                       "{error: no_price_data} when no feed is configured. "
                       "No account auth required.",
        "inputSchema": {
            "type": "object",
            "required": [],
            "properties": {
                "base": {"type": "string", "default": "EUR",
                         "description": "Fiat currency code, e.g. EUR, USD."},
            },
            "additionalProperties": False,
        },
        "auth": None,
        "verb": ["api-price"],
        "argmap": lambda a: (["--base", a["base"]] if a.get("base") else []),
    },
    {
        "name": "invoice_decode",
        "description": "Decode a BOLT-11 invoice without paying it. "
                       "Returns {bolt11, amount_sat, description, "
                       "payee, expires_at, payment_hash}.  "
                       "No account auth required.",
        "inputSchema": {
            "type": "object",
            "required": ["bolt11"],
            "properties": {
                "bolt11": {"type": "string", "minLength": 10,
                           "description": "BOLT-11 invoice string."},
            },
            "additionalProperties": False,
        },
        "auth": None,
        "verb": ["invoice-decode"],
        "argmap": lambda a: [a["bolt11"]],
    },
    {
        "name": "account_transfer",
        "description": "Instantly move sats between two accounts on the "
                       "same node (atomic intra-node ledger transfer). "
                       "`to` may be another account ID or a label. "
                       "Returns {transfer_id, from, to, amount_sat}.",
        "inputSchema": {
            "type": "object",
            "required": ["account_id", "to", "sat"],
            "properties": {
                "account_id": ID_PROP,
                "to": {"type": "string", "minLength": 1,
                       "description": "Destination account ID or label."},
                "sat": {"type": "integer", "minimum": 1},
                "note": {"type": "string", "maxLength": 200},
            },
            "additionalProperties": False,
        },
        "auth": "account",
        "verb": ["api-account-transfer"],
        "argmap": lambda a: (
            [a["account_id"], a["to"], str(a["sat"])]
            + (["--note", a["note"]] if a.get("note") else [])
        ),
    },
    {
        "name": "channel_list",
        "description": "List all active Lightning channels on this node. "
                       "Returns an array of {peer_id, alias, channel_id, "
                       "capacity_sat, local_sat, remote_sat, state}.  "
                       "No account auth required.",
        "inputSchema": {
            "type": "object",
            "required": [],
            "properties": {},
            "additionalProperties": False,
        },
        "auth": None,
        "verb": ["api-channel-list"],
        "argmap": lambda a: [],
    },
    {
        "name": "node_funds",
        "description": "Return on-chain and off-chain fund totals for the "
                       "node: total_sat, onchain_sat, offchain_sat, "
                       "and detailed outputs/channels arrays.  "
                       "No account auth required.",
        "inputSchema": {
            "type": "object",
            "required": [],
            "properties": {},
            "additionalProperties": False,
        },
        "auth": None,
        "verb": ["node-funds"],
        "argmap": lambda a: [],
    },
]

TOOLS_BY_NAME = {t["name"]: t for t in TOOLS}


NODE_RESOURCE_URI = "node://info"

RESOURCES = [
    {
        "uri": "account://{id}",
        "name": "Account record",
        "description": "Balance + limit + overdraft policy for the "
                       "account identified by {id}.",
        "mimeType": "application/json",
    },
    {
        "uri": "account://{id}/ledger",
        "name": "Account ledger",
        "description": "Recent ledger entries for the account.",
        "mimeType": "application/json",
    },
    {
        "uri": "account://{id}/topup",
        "name": "Account top-up URI",
        "description": "BIP-21 URI for on-chain top-up.",
        "mimeType": "application/json",
    },
    {
        "uri": NODE_RESOURCE_URI,
        "name": "Node info",
        "description": "Node pubkey, alias, channel count, and local "
                       "capacity.  No auth required.",
        "mimeType": "application/json",
    },
]


# --- dispatch ------------------------------------------------------------


def call_verb_json(verb, *args):
    """Run a `lightning api-*` verb via sudo-to-operator and return its
    JSON output as a Python object."""
    r = subprocess.run(
        ["sudo", "-n", "-u", _lib.OPERATOR_USER, "lightning", verb, *args],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        try:
            payload = json.loads(r.stdout) if r.stdout else {}
        except json.JSONDecodeError:
            payload = {"error": "backend_failed",
                       "detail": r.stderr.strip()[:200]}
        return r.returncode, payload
    try:
        return 0, json.loads(r.stdout)
    except json.JSONDecodeError:
        return 1, {"error": "bad_json"}


def handle_initialize(params):
    return {
        "protocolVersion": PROTOCOL_VERSION,
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        "capabilities": {
            "tools": {"listChanged": False},
            "resources": {"listChanged": False, "subscribe": False},
            "prompts": {"listChanged": False},
            "logging": {},
        },
    }


def handle_tools_list(params):
    public = []
    for t in TOOLS:
        public.append({k: v for k, v in t.items()
                       if k in ("name", "description", "inputSchema")})
    return {"tools": public}


def _tool_call(name, arguments, bearer):
    tool = TOOLS_BY_NAME.get(name)
    if tool is None:
        return jsonrpc_error(None, -32602, "unknown_tool",
                             {"name": name})

    if tool["auth"] == "account":
        account_id = (arguments or {}).get("account_id")
        if not account_id or not _lib.ACCOUNT_ID_RE.match(account_id):
            return jsonrpc_error(None, -32602, "account_id_required")
        if not bearer:
            return jsonrpc_error(None, -32001, "missing_bearer")
        rc = subprocess.run(
            ["sudo", "-n", "-u", _lib.OPERATOR_USER, "lightning",
             "api-account-verify", account_id, bearer],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode
        if rc != 0:
            return jsonrpc_error(None, -32001, "invalid_bearer")

    try:
        verb_args = tool["argmap"](arguments or {})
    except KeyError as e:
        return jsonrpc_error(None, -32602, "missing_arg",
                             {"arg": str(e).strip("'")})
    rc, payload = call_verb_json(tool["verb"][0], *verb_args)

    # MCP tool-call result shape: {"content":[{"type":"text","text":"..."}],"isError":bool}.
    is_error = rc != 0
    return {
        "content": [{"type": "text",
                     "text": json.dumps(payload, separators=(",", ":"))}],
        "isError": is_error,
        "structuredContent": payload,
    }


def handle_tools_call(params, bearer):
    name = params.get("name", "")
    arguments = params.get("arguments", {}) or {}
    return _tool_call(name, arguments, bearer)


def handle_resources_list(params):
    return {"resources": RESOURCES}


def _resource_read(uri, bearer):
    if uri == NODE_RESOURCE_URI:
        rc, payload = call_verb_json("api-node-info")
        if rc != 0:
            return jsonrpc_error(None, -32000, "backend_failed", payload)
        return {"contents": [{"uri": uri, "mimeType": "application/json",
                               "text": json.dumps(payload, separators=(",", ":"))}]}
    if not ACCOUNT_RESOURCE_RE.match(uri):
        return jsonrpc_error(None, -32602, "bad_resource_uri", {"uri": uri})
    parts = uri[len("account://"):].split("/", 1)
    account_id = parts[0]
    sub = parts[1] if len(parts) > 1 else ""

    if not bearer:
        return jsonrpc_error(None, -32001, "missing_bearer")
    rc = subprocess.run(
        ["sudo", "-n", "-u", _lib.OPERATOR_USER, "lightning",
         "api-account-verify", account_id, bearer],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode
    if rc != 0:
        return jsonrpc_error(None, -32001, "invalid_bearer")

    if sub == "":
        verb_args = [account_id]
        verb = "api-account-balance"
    elif sub == "topup":
        verb_args = [account_id]
        verb = "api-account-topup"
    elif sub == "ledger":
        verb_args = [account_id]
        verb = "api-account-history"
    else:
        return jsonrpc_error(None, -32602, "bad_resource_uri", {"uri": uri})

    rc, payload = call_verb_json(verb, *verb_args)
    if rc != 0:
        return jsonrpc_error(None, -32000, "backend_failed", payload)
    return {
        "contents": [{
            "uri": uri,
            "mimeType": "application/json",
            "text": json.dumps(payload, separators=(",", ":")),
        }],
    }


def handle_resources_read(params, bearer):
    uri = params.get("uri", "")
    return _resource_read(uri, bearer)


def handle_prompts_list(params):
    return {"prompts": []}


def handle_ping(params):
    return {}


HANDLERS = {
    "initialize": ("simple", handle_initialize),
    "notifications/initialized": ("notify", None),
    "tools/list": ("simple", handle_tools_list),
    "tools/call": ("with_bearer", handle_tools_call),
    "resources/list": ("simple", handle_resources_list),
    "resources/read": ("with_bearer", handle_resources_read),
    "prompts/list": ("simple", handle_prompts_list),
    "ping": ("simple", handle_ping),
}


# --- HTTP envelope --------------------------------------------------------


def respond_json(body):
    """Write the entire HTTP response and exit."""
    data = json.dumps(body)
    sys.stdout.write("Status: 200 OK\r\n")
    sys.stdout.write("Content-Type: application/json\r\n")
    sys.stdout.write("\r\n")
    sys.stdout.write(data)
    sys.stdout.flush()
    sys.exit(0)


def respond_status(status):
    sys.stdout.write(f"Status: {status}\r\n")
    sys.stdout.write("Content-Type: application/json\r\n")
    sys.stdout.write("\r\n")
    sys.stdout.flush()
    sys.exit(0)


def main():
    method = os.environ.get("REQUEST_METHOD", "GET").upper()
    if method != "POST":
        respond_status("405 Method Not Allowed")

    bearer = os.environ.get("HTTP_AUTHORIZATION", "").strip()
    if bearer.lower().startswith("bearer "):
        bearer = bearer[7:].strip()

    body = _lib.read_body()
    if not isinstance(body, dict):
        respond_json(jsonrpc_error(None, -32600, "invalid_request"))

    rpc_id = body.get("id")
    method_name = body.get("method", "")
    params = body.get("params", {}) or {}

    handler = HANDLERS.get(method_name)
    if handler is None:
        respond_json(jsonrpc_error(rpc_id, -32601, "method_not_found",
                                   {"method": method_name}))

    kind, fn = handler
    if kind == "notify":
        # Notifications don't get a response per JSON-RPC 2.0.
        respond_status("204 No Content")
    elif kind == "simple":
        result = fn(params)
        if "error" in result and "code" in result.get("error", {}):
            result["id"] = rpc_id
            respond_json(result)
        respond_json(jsonrpc_response(rpc_id, result=result))
    elif kind == "with_bearer":
        result = fn(params, bearer)
        if isinstance(result, dict) and "error" in result and "code" in result.get("error", {}):
            result["id"] = rpc_id
            respond_json(result)
        respond_json(jsonrpc_response(rpc_id, result=result))


main()
