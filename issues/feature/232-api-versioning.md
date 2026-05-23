---
id: FEAT-232
type: feature
priority: high
status: research
---

# API versioning

## Description

As the HTTP surface grows + webshops integrate against it, we
need a versioning scheme so breaking changes don't strand
existing callers.  URL-path versioning under the `.well-known`
move (FEAT-224), baked in from day one so we relocate only
once.

## Decision: URL-path versioning

```
/.well-known/lightning/v1/accounts/<id>/...
/.well-known/lightning/v1/mcp
/api/v1/users/...
```

Rationale:

* **Cache-friendly + debuggable** — `curl` against an explicit
  URL; intermediaries cache per-version cleanly.  Beats header-
  based (`Accept: application/vnd...`) for a public API that
  webshop devs poke at by hand.
* **Coexistence** — a breaking change ships as `v2` alongside
  `v1`; we deprecate `v1` on our own timeline + announce via
  the manifest.
* **Discovery** — the `mcp.json` manifest (and a new
  `/.well-known/lightning/versions.json`) advertises supported
  versions + the current default + deprecation dates.

## Scope

* Fold the `v1` segment into FEAT-224's `.well-known` move so
  the relocation + versioning happen in one PR (no double
  move).
* `versions.json` manifest at `/.well-known/lightning/
  versions.json`: `{ "versions": ["v1"], "default": "v1",
  "deprecated": {} }`.
* The dispatcher strips + validates the `v<N>` segment; an
  unknown version → `404 unknown_api_version`.
* Each version is a routing namespace; the dispatcher can
  serve multiple concurrently when v2 arrives (shared verb
  layer where the contract is unchanged, version-specific
  shims where it diverged).
* Docs (FEAT-209 inline + llms.txt) + the MCP manifest emit
  versioned URLs.

## Out of scope

* A v2 — this ticket establishes the scheme + ships v1; v2 is
  whenever a breaking change is actually needed.
* Per-endpoint (sub-resource) versioning — version is global
  to the API.
* Semantic-version negotiation — coarse `v1`/`v2` only.

## Acceptance criteria

1. `GET /.well-known/lightning/v1/accounts/<id>/balance`
   works; the unversioned path no longer resolves.
2. `GET /.well-known/lightning/versions.json` lists `["v1"]`.
3. An unknown version (`/v9/...`) returns `404
   unknown_api_version`.
4. The MCP manifest + create-response `endpoints` block emit
   `v1` URLs.

## Dependencies

* FEAT-224 (the `.well-known` move — versioning rides in the
  same PR).  This ticket is effectively a sub-decision of
  FEAT-224, filed separately so the versioning rationale +
  contract are explicit.

## Milestone

1.5.0 — must land with FEAT-224 before external callers
integrate, so they start on `v1`.
