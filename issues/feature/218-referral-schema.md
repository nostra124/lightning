---
id: FEAT-218
type: feature
priority: medium
status: research
---

# Referral schema + invite codes

## Description

Foundation for the single-level affiliate system.  Each account
gets an optional `referrer` (a parent account); the default is
`house`.  Operators (and eventually users) mint short invite
codes that resolve to their account at signup time.

This ticket lays the schema + CLI plumbing.  Fee distribution
based on the referrer relationship lands in FEAT-219; PWA UX in
FEAT-220.

## Scope

* Schema additions (additive, idempotent ALTER):
    ```sql
    ALTER TABLE accounts ADD COLUMN referrer TEXT
        DEFAULT 'house'
        REFERENCES accounts(name);

    CREATE TABLE IF NOT EXISTS invite_codes (
        code        TEXT PRIMARY KEY,
        account     TEXT NOT NULL REFERENCES accounts(name) ON DELETE CASCADE,
        created_at  INTEGER NOT NULL,
        uses        INTEGER NOT NULL DEFAULT 0
    );
    ```

* New CLI verbs (subcommands of `account`):
    * `account invite-code create [<handle>] [--code <vanity>]`
      — mint a 6-8-char base32 code (or use the supplied
      vanity string) tied to an account.  Output: the code +
      a `?invite=<code>` URL fragment.
    * `account invite-code list [<handle>]` — TSV of codes +
      use counts.
    * `account invite-code revoke <code>` — delete a code (use
      counts on already-created accounts are preserved; the
      code just stops resolving for future signups).

* `POST /api/accounts` (FEAT-212 PR-2) learns an `invite_code`
  field in the body.  Server decodes → resolves to an account
  name → stamps `referrer = <that name>` on the new row.
  Unknown / revoked codes are silently ignored (referrer falls
  back to `house`); never reject account creation over a bad
  invite — that's a user-hostile failure mode.

* New endpoint: `GET /api/accounts/<id>/referrals`
    * Authorization: account-bearer.
    * Returns the list of direct downline accounts (id +
      created_at + accrued_fee_credits) — though credits stay
      at 0 until FEAT-219 wires distribution.

## Out of scope

* Multi-level cascade (single-level only, deliberate — see the
  FEAT-209 design conversation).
* Fee distribution (FEAT-219).
* PWA UX (FEAT-220).

## Dependencies

None — additive schema + new CLI verbs + one new field on an
existing endpoint.

## Acceptance criteria

1. `account invite-code create rent` outputs a 7-char base32
   code; the code resolves to `rent` in the `invite_codes`
   table.
2. `POST /api/accounts` with a valid `invite_code` stamps the
   new account's `referrer` to the inviter's name.
3. Same call with an unknown code creates the account with
   `referrer = 'house'` and no error.
4. `GET /api/accounts/<id>/referrals` lists direct downline
   only — never grandchildren (we're single-level).
5. Revoking a code doesn't break existing downline rows.

## Milestone

1.5.0.

## See also

* FEAT-219 — referral fee distribution (consumes this schema).
* FEAT-220 — referral UX in the PWA.
