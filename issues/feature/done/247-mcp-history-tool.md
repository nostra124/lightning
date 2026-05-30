---
id: FEAT-247
type: feature
priority: medium
status: research
---

# MCP account_history tool + wire ledger resource

## Description

The MCP server (FEAT-212 PR-3) exposed an `account://id/ledger`
resource as a placeholder returning `not_implemented`. Now that
FEAT-246 ships the `api-account-history` verb, wire the resource to
the real backend and add an `account_history` MCP tool so LLM agents
can query payment history programmatically.

## Scope

* `mcp.py` — add `account_history` tool with `limit` and `before_id`
  parameters; replace the `not_implemented` stub in `_resource_read`
  for the `ledger` sub-resource with a call to `api-account-history`.
* `llms.txt` — mention the new tool and the wired resource.
* pytest test for the new tool call + updated ledger resource test.

## Acceptance criteria

1. `tools/list` includes `account_history`.
2. `tools/call account_history` returns `{entries, has_more}`.
3. `resources/read account://id/ledger` returns history (no longer
   `not_implemented`).

## Milestone

alpha polish (follows FEAT-246).
