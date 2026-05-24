# MCP surface

The node exposes a Model Context Protocol endpoint so an LLM agent can
drive an account with its API key.

- Endpoint: `POST /.well-known/lightning/v1/mcp`
- Descriptor: `GET /.well-known/lightning/mcp.json`
- Auth: `Authorization: Bearer <api_key>` (an account's `lt_…` key).

JSON-RPC 2.0 envelope:

```
{ "jsonrpc": "2.0", "id": 1, "method": "tools/call",
  "params": { "name": "balance", "arguments": { "account_id": "bc1…" } } }
```

`tools/list` enumerates the available tools (balance, topup, pay, recv,
transfer, …), each mirroring the REST endpoint above with the same
inputs, outputs, and error codes.

To point an agent at this node: give it the base URL, the account's API
key, and this `llms.txt`. One fetch of `/lightning/docs/llms.txt` is
enough to learn the whole surface.
