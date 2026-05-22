---
id: FEAT-221
type: feature
priority: medium
status: research
---

# Expand the man-page tree to cover every verb

## Description

`share/man/man1/lightning.1` is a single overview page covering
the entire CLI surface.  As the verb tree has grown (FEAT-205
autopilot, FEAT-211 account verbs, FEAT-212 PR-1..5, FEAT-213+
fee policy, etc.), the single-page format is straining.  Time
to split into one page per top-level verb, in the standard
unix style — `git` is the model (`git(1)`, `git-commit(1)`,
`git-push(1)`).

The PWA-shipped inline docs (FEAT-209) cover the user-facing
HTTP + MCP surface; man pages cover the operator-facing CLI.
No overlap, no drift risk.

## Scope

* Rewrite `share/man/man1/lightning.1` as a thin overview that
  lists the verbs + cross-references their per-verb pages,
  matching `git(1)`'s structure.
* Add one man page per top-level verb under `share/man/man1/`:
    * `lightning-wallet.1`
    * `lightning-account.1`
    * `lightning-channel.1`
    * `lightning-peer.1`
    * `lightning-invoice.1`
    * `lightning-offer.1`
    * `lightning-send.1`
    * `lightning-pay.1`
    * `lightning-recv.1`
    * `lightning-daemon.1`
    * `lightning-address.1`
    * `lightning-fee.1`
    * `lightning-rebalance.1`
    * `lightning-tor.1`
    * `lightning-tower.1`
    * `lightning-liquidity.1`
    * `lightning-plugin.1`
    * `lightning-history.1`
    * `lightning-ledger.1`
    * `lightning-alert.1`
    * `lightning-forward.1`
    * `lightning-backup.1`
    * `lightning-restore.1`
    * `lightning-scb.1`
    * `lightning-info.1`
    * `lightning-decode.1`
    * `lightning-qr.1`
    * `lightning-fee-policy.1`  *(when FEAT-213 lands)*
    * `lightning-ui.1`           *(when FEAT-209 PR-2 lands)*
* Each verb page lists its subcommands with `.B` headings and
  short examples; cross-refs the BOLT / LNURL spec the verb
  implements where relevant (kept from the educational pitch
  in CLAUDE.md).
* `make install` already copies `share/man/man1/*` — no
  Makefile change needed.

## Maintenance convention

A new convention to add to CLAUDE.md once this lands:

> When a verb's CLI surface changes, the matching
> `share/man/man1/lightning-<verb>.1` page MUST be updated
> in the same PR.  The single big `lightning.1` overview
> stays high-level; per-verb detail lives in the per-verb
> pages.

The CI check is light — `bats` already has a "help-text
mentions X" pattern for the close + nickname subcommands;
we extend it to "man page covers X" for the new pages.

## Out of scope

* Auto-generation of man pages from the verbs' `usage()`
  output.  Tempting (would prevent drift) but the formatting
  loses too much when you go shell-help → roff; per-verb
  pages are more readable hand-written.
* Translation / localisation.
* HTML rendering of man pages for the website
  (`groff -mandoc -Thtml` works but is a separate ticket if
  we ever want it).

## Dependencies

None — pure documentation work.  Lands independently of any
implementation PR.

## Acceptance criteria

1. `man lightning-account` renders correctly + covers create,
   show, close, nickname, topup, withdraw, pay, receive,
   apikey, topup-watcher, gc.
2. Every top-level verb has a corresponding
   `share/man/man1/lightning-<verb>.1` file.
3. New bats test: for each `libexec/lightning/<verb>` file
   (excluding `_*` internal helpers), assert a matching
   `share/man/man1/lightning-<verb>.1` exists and contains
   the verb name in `.SH NAME`.

## Phasing

Single PR.  Can be split alphabetically if the diff is too
big to review (e.g., a-c, d-l, m-s, t-z), but a single
review pass is preferable since the structure repeats.

## Milestone

1.5.0.

## See also

* FEAT-209 — PWA inline docs (the user-facing-API
  counterpart).  The two doc trees cover non-overlapping
  surfaces.
