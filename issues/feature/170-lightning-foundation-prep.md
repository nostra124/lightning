---
id: FEAT-170
type: feature
priority: high
status: open
---

# Lightning foundation prep — sourceable lib + minimal runtime deps

## Description

**As a** maintainer creating the educational `lightning`
package
**I want** a clean foundation: `bin/lightning` callable as
`lightning.sh` (sourceable for tests), only `account` +
`config` + `secret` at runtime, soft probe for
`lightning-cli`
**So that** the clightning backend wiring (FEAT-171) and the
rest of the lightning feature set build on a solid base
that mirrors bitcoin's foundation (FEAT-006 / FEAT-010).

Today there's no real verbs — this ticket creates the shell
+ the foundation contract for the clightning-only scope.

## Implementation

1. **Create `bin/lightning`** — small dispatcher with
   builtin `help` / `version` plus the standard libexec
   lookup for verbs to be added by FEAT-171..176.

2. **Source-mode guard** for tests, mirroring bitcoin's
   pattern from FEAT-006:

       [[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

   Install as `bin/lightning` plus a `bin/lightning.sh`
   symlink so `. lightning.sh` in test files resolves.

3. **Runtime deps**: only `account` + `config` + `secret`
   at runtime; `rpk` deployment-only. No direct dep on the
   `bitcoin` package — on-chain channel funding goes through
   the backend daemon's own bitcoind connection.

4. **Soft system dep** probed at runtime: `lightning-cli`
   (Core Lightning). Required for any non-trivial verb;
   help / version work without it.

5. **Add `docs/templates/CLAUDE.md.lightning`** derived
   from the foundation template. Sections: scope
   (educational Lightning toolkit on clightning), the four
   design principles, no-shared-lib policy.

## Acceptance Criteria

1. `bin/lightning` exists with `help` and `version`
   builtins plus the libexec lookup pattern.
2. `bin/lightning.sh` symlink resolves to `bin/lightning`.
3. Sourcing `bin/lightning.sh` defines functions but
   doesn't execute the dispatcher (the source-mode guard
   works).
4. `grep -wEn '(cache|check|data|hosts|repo|scripts|task|user)' bin/lightning`
   returns no script-invocation matches.
5. `docs/templates/CLAUDE.md.lightning` exists.
