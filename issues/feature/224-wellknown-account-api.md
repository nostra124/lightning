---
id: FEAT-224
type: feature
priority: medium
status: research
---

# Move the account API + MCP under `.well-known/lightning/`

## Description

The account API (FEAT-212 PR-2) currently lives at
`/api/accounts/*` and MCP at `/api/mcp`.  Relocate both under
`/.well-known/lightning/` so the transactional surface is a
*discoverable* protocol endpoint, aligning with the existing
`.well-known/lnurlp/` (FEAT-176) + `.well-known/lightning/
mcp.json` manifest (FEAT-212 PR-3).  Webshops integrate
against a standard, predictable location.

The **user API stays at `/api/users/`** — it's app-facing
(PWA), not a discoverable protocol.

## Scope

* Apache vhost: `ScriptAlias /.well-known/lightning/accounts
  → wellknown/api/accounts.py` (was `/api/accounts`);
  `/.well-known/lightning/mcp → wellknown/api/mcp.py` (was
  `/api/mcp`).
* The dispatcher's `endpoints` map + the MCP manifest URLs
  update to the new paths.
* The `api-accounts-create` response `endpoints` block emits
  the `.well-known` paths.
* Docs (FEAT-209 inline docs, llms.txt) reflect the move.
* **No back-compat dual-path** — `/api/accounts/*` is
  unreleased; just move it (operator confirmed nobody's
  using the old path yet).

## Out of scope

* The user API location (`/api/users/`) — stays put.
* Any change to auth, request/response shapes — pure
  routing relocation.

## Acceptance criteria

1. `GET /.well-known/lightning/accounts/<id>/balance` works
   exactly as `/api/accounts/<id>/balance` did.
2. `POST /.well-known/lightning/mcp` serves the JSON-RPC
   dispatcher.
3. The create-response `endpoints` block + mcp.json manifest
   carry `.well-known` URLs.
4. No route responds at the old `/api/accounts/*` paths.

## Dependencies

Touches FEAT-212 PR-2 (account dispatcher) + PR-3 (MCP).
Should land before FEAT-225/226/227 add new endpoints, so
those land at the right prefix from day one.

## Milestone

1.5.0.
