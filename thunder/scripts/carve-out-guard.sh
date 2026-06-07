#!/bin/sh
# FEAT-302 — carve-out guardrail.
#
# Enforces the one-way boundary from day one: the `thunderd/` workspace
# must have NO build- or runtime-dependency on the surrounding `lightning`
# bash package — not the verbs, not the wallet DB. That is what keeps the
# 2.0.0 repo extraction (FEAT-329/431) a mechanical `git filter-repo`.
#
# Scans Rust sources + Cargo manifests only (docs/README legitimately
# discuss the boundary). Note we intentionally do NOT forbid
# `lightning-rpc` (the CLN socket) or `lightningd` — those are the
# *standard* CLN surface thunderd is allowed to use.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Forbidden coupling: the bash CLI, the libexec verbs, and the shared
# wallet DB / wallet dir. (Patterns are path-shaped on purpose so they
# don't trip on Rust field access like `state.db` or boundary docs.)
pattern='lightning-cli|libexec/lightning|/bin/lightning|wallet/state\.db|\.lightning/wallet'

violations=$(
    find "$root/crates" \( -name '*.rs' -o -name 'Cargo.toml' \) -type f -print 2>/dev/null |
        while IFS= read -r f; do
            grep -EHn "$pattern" "$f" 2>/dev/null || true
        done
)

if [ -n "$violations" ]; then
    echo "FEAT-302 carve-out violation — thunderd must not couple to the" >&2
    echo "lightning bash package (verbs / wallet state.db):" >&2
    echo "$violations" >&2
    exit 1
fi

echo "carve-out guard: OK (no coupling to lightning bash verbs / wallet DB)"
