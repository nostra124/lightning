---
id: FEAT-256
type: feature
priority: medium
status: research
---

# api-account-list verb — list / search accounts

## Description

Operators need to look up accounts from the CLI for support queries,
scripting, and bulk operations.  `lightning api-account-list
[--search <term>] [--limit N]` queries the `accounts` table and
returns a JSON array of `{address, name, balance_sat, created_at}`.

## Scope

* `api-account-list` (new verb) — optional `--search` (substring match
  on name / description), `--limit` (default 50, max 500).  Runs as the
  operator (no sudo needed — called from the shell directly, not via CGI).
* Man page update for the dispatch table.
* bats tests.

No CGI route — this is an operator-only CLI verb; exposing it over
HTTP would require admin auth which is out of scope.

## Acceptance criteria

1. `lightning api-account-list` returns JSON array of accounts.
2. `--search` filters by name.
3. `--limit` caps results.

## Milestone

alpha polish (follows FEAT-255).
