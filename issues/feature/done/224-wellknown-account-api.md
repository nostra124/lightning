---
id: FEAT-224
type: feature
priority: high
status: research
---

# Move the account API + MCP under `.well-known/lightning/v1/`

## Description

The account API (FEAT-212 PR-2) currently lives at
`/api/accounts/*` and MCP at `/api/mcp`.  Relocate both under
`/.well-known/lightning/v1/` so the transactional surface is a
*discoverable, versioned* protocol endpoint, aligning with the
existing `.well-known/lnurlp/` (FEAT-176) + `.well-known/
lightning/mcp.json` manifest (FEAT-212 PR-3).  Webshops
integrate against a standard, predictable, version-pinned
location.

The **user API moves to `/api/v1/users/`** — still app-facing
(PWA), not under `.well-known`, but takes the same `v1`
segment for consistency.

Versioning rationale + contract live in **FEAT-232**; this
ticket implements the move + the `v1` segment together so we
relocate only once.

## Scope

* Apache vhost:
  `ScriptAlias /.well-known/lightning/v1/accounts →
   wellknown/api/accounts.py` (was `/api/accounts`);
  `/.well-known/lightning/v1/mcp → wellknown/api/mcp.py`
  (was `/api/mcp`).
* The dispatcher's `endpoints` map + the MCP manifest URLs
  update to the new versioned paths.
* The `api-accounts-create` response `endpoints` block emits
  the versioned `.well-known` paths.
* New `/.well-known/lightning/versions.json` manifest
  advertising `{ "versions": ["v1"], "default": "v1" }`
  (FEAT-232).
* Dispatcher validates the `v<N>` segment; unknown version →
  `404 unknown_api_version`.
* Docs (FEAT-209 inline docs, llms.txt) reflect the move.
* **No back-compat dual-path** — `/api/accounts/*` is
  unreleased; just move it (operator confirmed nobody's
  using the old path yet).

## Out of scope

* Shipping a `v2` — FEAT-232 establishes the scheme; v2 lands
  when a breaking change is needed.
* Any change to auth, request/response shapes — pure
  routing relocation + version prefix.

## Acceptance criteria

1. `GET /.well-known/lightning/v1/accounts/<id>/balance` works
   exactly as `/api/accounts/<id>/balance` did.
2. `POST /.well-known/lightning/v1/mcp` serves the JSON-RPC
   dispatcher.
3. `GET /.well-known/lightning/versions.json` lists `["v1"]`.
4. An unknown version segment returns `404
   unknown_api_version`.
5. The create-response `endpoints` block + mcp.json manifest
   carry versioned `.well-known` URLs.
6. No route responds at the old `/api/accounts/*` paths.

## Dependencies

Touches FEAT-212 PR-2 (account dispatcher) + PR-3 (MCP).
Implements the FEAT-232 versioning decision.  Should land
before FEAT-225/226/227 add new endpoints, so those land at
the right versioned prefix from day one.

## Milestone

alpha — must ship before the feature-complete **alpha** cut (alpha = everything implemented; then beta hardening; then 1.0.0 is a formal version bump).
