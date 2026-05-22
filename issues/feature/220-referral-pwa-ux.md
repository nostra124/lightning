---
id: FEAT-220
type: feature
priority: medium
status: research
---

# Referral UX in the PWA

## Description

Wraps the FEAT-218 + FEAT-219 backend in a user-facing UI.
Settings → "Invite a friend" + "My referrals" dashboard.
Honours the `?invite=<code>` URL parameter at account creation.

## Scope

* New PWA screens (under `/settings/referrals`):
    * **Invite a friend** — shows the user's invite code + full
      shareable link (`https://<this-host>/?invite=<code>`).
      Copy + QR + share-sheet buttons.
    * **My referrals** — list of direct downline accounts,
      redacted IDs (first 8 chars of address + ellipsis), join
      date, accrued credits this month + lifetime.

* Account-creation flow honours `?invite=<code>` URL parameter
  from the moment the PWA loads:
    * If present, store in `sessionStorage` for the duration of
      the create flow.
    * `POST /api/accounts` sends `invite_code` in the body.
    * Drop the URL parameter from `window.location` after
      consumption (don't keep it in the address bar across
      pages).

* New endpoint `GET /api/accounts/<id>/invite-codes` returns
  the user's mint-once codes; PWA calls it on the Invite screen
  rather than holding the code in localStorage (so revocation
  via the CLI takes effect immediately).

## Out of scope

* Multi-level UI (not applicable — we're single-level by
  design).
* Push notifications when a downline transacts.
* Referrer-to-referee messaging.

## Dependencies

* FEAT-218 (schema + invite codes).
* FEAT-219 (fee distribution — so there are credits to display).
* FEAT-209 PR-2 (the PWA itself must exist before we can add
  screens to it).

## Acceptance criteria

1. Loading the PWA with `?invite=ABC123` and tapping "Create
   account" stamps the new account with `referrer` resolved
   from `ABC123`.
2. URL parameter is consumed once and removed from
   `window.location.search` afterwards.
3. Invite screen shows the user's code + a copy button + a QR.
4. Referrals screen shows accurate downline + credit totals
   sourced from the backend's per-account ledger queries.

## Milestone

1.5.0.

## See also

* FEAT-209 — the PWA.
* FEAT-218 — referral schema.
* FEAT-219 — fee distribution.
