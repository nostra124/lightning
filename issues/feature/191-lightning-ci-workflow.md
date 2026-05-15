---
id: FEAT-191
type: feature
priority: high
status: open
---

# Lightning CI workflow — bats unit tests on every PR

## Description

**As a** maintainer
**I want** GitHub Actions running `bats tests/unit/` on every
push and PR
**So that** the contract suite that guards `bin/lightning`'s
shape doesn't silently rot.

Today PR #1 reported `total_count: 0` — there is no CI. The
test suite exists; only the runner is missing.

## Implementation

1. **`.github/workflows/test.yml`** — single job:
   - `ubuntu-latest`
   - install `bats-core` via apt
   - `bats tests/unit/`
2. **README badge** — link to the workflow status.
3. **Branch protection** (documented, not enforced from a PR)
   — `master` requires the workflow to pass.
4. **SIT (FEAT-182)** lands its own separate workflow later;
   this ticket scopes only the unit suite.

## Acceptance Criteria

1. `.github/workflows/test.yml` exists and triggers on `push`
   + `pull_request`.
2. The workflow goes green against the current bats suite.
3. README links to the workflow.
