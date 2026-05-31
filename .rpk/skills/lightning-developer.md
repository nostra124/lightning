---
name: lightning-developer
description: Develop, test, and ship changes to the lightning(1) package
long_description: Develop, test, and ship changes to the lightning(1) package. Trigger when the user wants to add a new verb, fix a bug, write bats tests, update a man page, work on the Apache CGI endpoints, understand the no-shared-lib policy, or release a new version via rpk. Also trigger when reviewing a PR or auditing verb-to-FEAT traceability.
role: [dev]
references: rpk/developer
---

# lightning-developer

Develop and ship changes to the `lightning(1)` package — adding
verbs, writing bats tests, updating man pages, and releasing via
rpk.

## When to use

Trigger when the user says any of:

- "Add a new verb / subcommand to lightning".
- "Fix a bug in lightning".
- "Write a test for `lightning <verb>`".
- "Update the man page for `lightning-<verb>`".
- "Work on the Apache CGI endpoint for `/.well-known/lightning/`".
- "How does the libexec dispatch work?".
- "What is the no-shared-lib policy?".
- "Release a new version of lightning".
- "Run the lightning tests".

## Repo layout (key paths)

```
bin/lightning               # dispatcher — resolves libexec/<verb>
libexec/lightning/<verb>    # one file per verb; calls lightning-cli directly
share/man/man1/
  lightning.1               # high-level overview
  lightning-<verb>.1        # one man page per top-level verb (FEAT-221)
share/doc/lightning/
  standards/                # vendored BOLT / LUD / BIP / BLIP texts
  guides/                   # personal-node.md, routing-node.md
share/lightning/            # Apache CGI scripts + _lib.py
tests/unit/
  lightning.bats            # contract suite; every verb lives here
issues/
  feature/                  # FEAT-NNN-*.md
  bug/                      # BUG-NNN-*.md
.rpk/
  skills/                   # this directory — agent skills
```

## No-shared-lib policy

**Each verb script is self-contained.** There is no shared
`cli-helper` library. Every verb that needs to parse an invoice
implements that parsing inline. Every verb that calls `lightning-cli`
constructs the command inline.

The only permitted runtime dependency outside the package is
`account(1)`. Never `source` another libexec script or call another
`lightning` verb from inside a verb script.

This keeps each verb readable as a standalone document and prevents
cascading failures when one verb changes.

## Adding a new verb

1. **File a `FEAT-NNN` issue** in `issues/feature/` (see
   `rpk skills rpk features`).
2. **Create `libexec/lightning/<verb>`** — a self-contained bash
   script that calls `lightning-cli` inline. Cite the BOLT / LUD at
   the top.
3. **Write the bats test first** (TDD): add a `@test` in
   `tests/unit/lightning.bats` that fails before the verb exists.
4. **Implement** the verb until the test passes.
5. **Write the man page**: `share/man/man1/lightning-<verb>.1`. The
   bats suite asserts every dispatchable verb (excluding `_*`
   helpers and `api-*` HTTP-bridge verbs) has a matching man page
   whose `.SH NAME` carries the verb name (FEAT-221).
6. **Update `lightning.1`** if the verb is a new top-level noun.
7. **Run the full test suite** before pushing:
   ```sh
   make test
   ```
8. **Open a PR**; follow `rpk skills rpk automerging`.

## Verb script conventions

```bash
#!/bin/sh
# lightning-<verb> — one-line description (BOLT-NN / LUD-NN)
set -eu
# ...
exec lightning-cli <rpc-method> "$@"
```

- Use `#!/bin/sh`, not `#!/bin/bash` (POSIX portability).
- `set -eu` at the top.
- Call `lightning-cli` directly — no helper wrapper.
- Cite the spec in the first comment line.
- Exit codes: 0 = success, 1 = usage error, 2 = runtime error.

## Apache CGI endpoints (share/lightning/)

One Python file per `.well-known/lightning/` endpoint (FEAT-196).
Only `_lib.py` is shared between endpoint scripts. Endpoint scripts
shell out to `lightning <verb>` — they never call `lightning-cli`
directly and never reach across each other.

When adding an endpoint:
1. Add `share/lightning/<endpoint>.py`.
2. Register it in the Apache vhost template.
3. Document it in `share/doc/lightning/standards/api/spec.md`.

## Man page requirements (FEAT-221)

Every dispatchable verb (excluding `_*` helpers and `api-*` verbs)
**must** have `share/man/man1/lightning-<verb>.1` with a `.SH NAME`
section that names the verb. The bats test asserts this. When a
verb's CLI surface changes, update its man page in the same PR.

## Testing

```sh
make test                          # bats tests/unit/lightning.bats
bats tests/unit/lightning.bats     # same, direct
bats tests/unit/lightning.bats -f '<pattern>'  # single test
```

Tests follow the TDD-first discipline from `rpk skills rpk bugs`:
write the failing test, confirm it fails, then implement. Reference
the FEAT or BUG number in the test name:

```bash
@test "invoice creates a BOLT-11 invoice with expiry (FEAT-NN)" {
    ...
}
```

## Release workflow

`lightning` is an rpk package. After a PR merges:

1. In dev clone: `git push local master`
2. `rpk patch lightning` (or `minor` / `major`) — bumps version,
   commits to worktree, pushes to bare.
3. `git pull --rebase local master` in dev clone.
4. `git push origin master`
5. `rpk update lightning`

See `rpk skills rpk version` for the full matrix of when to bump
patch vs minor vs major.

## Issue traceability

Every verb and every behaviour must trace to a `FEAT-NNN` or
`BUG-NNN` file. Before adding code, check `issues/feature/` for an
existing FEAT. After merging, `git mv` the issue to
`issues/feature/done/` and flip `status: done`.

Use `rpk skills rpk audit` to verify traceability before a release.

## Guardrails

- **No shared lib.** Never extract a helper used by more than one
  verb into a shared file. Duplication is intentional; see
  §"No-shared-lib policy".
- **Cite the spec.** Every verb that implements a BOLT, LUD, BIP,
  or BLIP must cite it in the first comment line and in the man
  page's `STANDARDS` section.
- **Man page in the same PR.** A verb PR without a man page update
  fails the bats assertion. Reviewers should reject it.
- **TDD.** Write the failing test first. A PR that fixes a bug
  without a regression test should be rejected.
- **`lightning-cli` only.** Verb scripts never call the `bitcoin`
  package or shell out to `bitcoind`. On-chain operations are
  handled by clightning's built-in wallet.
- **Python CGI scripts shell out; they don't import.** The thin
  HTTP layer delegates to `lightning <verb>` via `subprocess`. It
  does not re-implement Lightning logic in Python.

## Related skills

- **rpk/bugs** — TDD-first bug-fix discipline; BUG-NNN file format.
- **rpk/features** — FEAT-NNN file format; phased sub-PRs.
- **rpk/testing** — pre-push test gate; which tier to run.
- **rpk/version** — when and how to bump patch / minor / major.
- **rpk/audit** — verify FEAT/BUG traceability before a release.
- **rpk/automerging** — drive PRs to merge through CI.

## Where to read more

- `CLAUDE.md` — package scope, no-shared-lib policy, man page rule.
- `tests/unit/lightning.bats` — the contract suite; semver anchor.
- `share/doc/lightning/standards/` — vendored specs to cite.
- `man rpk` — full rpk CLI reference.
