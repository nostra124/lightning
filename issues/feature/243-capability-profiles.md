---
id: FEAT-243
type: feature
priority: high
status: research
---

# Capability profiles + fund classification — tune the service to a use case

## Description

The full FEAT-212/222 stack makes the node behave like a **bank for
Lightning**: accounts, receive, send between accounts (same user /
different user / external node), top-up, withdrawal.  Most of that is
only regulated when you move **other people's money out or between
people**.  This ticket lets an operator switch individual
money-movements on/off — **per account**, with a node default — and
**label each account's funds as own vs foreign** (balance-sheet
classification), so the same software serves a family wallet, a
corporate treasury, a prepaid-credit shop, or a full custodial service
without forking.

It sits *above* the FEAT-233 compliance modules: capabilities + fund
class decide *what business you're in*; the compliance modules decide
*how you document it* once you're custodial.

## The two axes

### 1. Capabilities (the gated money-movements)

| Capability            | What it gates                                   | Regulatory weight |
|-----------------------|-------------------------------------------------|-------------------|
| `recv`                | mint a receive invoice / offer                  | none              |
| `topup`               | credit an on-chain deposit                      | none              |
| `transfer_intra_user` | account→account, **same** `owner_user`          | none (own money)  |
| `transfer_inter_user` | account→account, **different** owner on-node    | **banking**       |
| `pay_external`        | account→another Lightning node                  | **banking**       |
| `withdraw`            | on-chain pay-out                                | **banking**       |

The top three are the safe core; the bottom three are what make you a
money service.  `owner_user` (FEAT-222) lets the transfer verb tell
intra- from inter-user apart.

### 2. Fund class

`accounts.fund_class ∈ {own, foreign}`:

* `own` — your money (corporate treasury, a parent's funds, prepayment
  that has become your revenue).  Outside deposit / money-transmission
  rules.
* `foreign` — third-party money held on their behalf.  The trigger for
  KYC / AML / licensing.

**Custodial line:** any `foreign`-funds account with a banking
capability enabled = a custodial money service.

## Profiles (the unit of configuration)

A **profile** bundles a capability set + a default fund class + a risk
tier.  Profiles are the primary knob (per the design decision); they
are hard-coded (like FEAT-233 presets) and assigned **per account**,
with a node-wide default in `access.recfile`.

| Profile     | fund_class | recv | topup | intra | inter | pay_ext | withdraw | risk   |
|-------------|------------|------|-------|-------|-------|---------|----------|--------|
| `treasury`  | own        | on   | on    | on    | on    | on      | on       | low    |
| `family`    | own        | on   | on    | on    | off   | on      | on       | low    |
| `prepaid`   | own        | on   | on    | on    | off   | on      | **off**  | medium |
| `custodial` | foreign    | on   | on    | on    | on    | on      | on       | high   |

`treasury` = all-on / own-funds — the **default**, so a fresh node
behaves exactly as today until the operator restricts it.  An account's
effective profile = its `profile` column → `access.recfile`
`default_profile` → `treasury`.  Its effective `fund_class` = its
`fund_class` column → the profile's default.

### Mapping the motivating use cases

* **Corp, employees manage employer funds** → all accounts `treasury`,
  one `owner_user`.  Not banking.
* **Corp, customers prepay & consume (no cash-out)** → customer
  accounts `prepaid` (withdraw off, fund_class own), paired with a
  **standing order (FEAT-226)** auto-sweeping to the treasury account.
* **Family father→son** → son's account `family`.  Not banking.
* **Full regulatory** → `custodial`; enable the FEAT-233 modules.

## Scope (this ticket)

* `accounts.profile` + `accounts.fund_class` columns (additive
  migration; both NULL = resolve to the default).
* `default_profile` in `access.recfile` (FEAT-222 PR-6).
* The hard-coded profile→capability table + resolver in the `account`
  verb: `account profiles` (list the table), `account capability
  <handle> <cap>` (exit 0/1), `account set-profile <handle> <profile>`,
  `account set-fund-class <handle> own|foreign`.
* Enforcement gate in the value-moving HTTP verbs (api-account-pay /
  -transfer / -withdraw / -topup / -recv / -recv-reusable): deny a
  disabled capability with `{"error":"capability_disabled",...}` → 402.
  The transfer verb resolves intra- vs inter-user from `owner_user`.
* Risk audit folded into `lightning compliance status`: rates the live
  profile / fund-class mix (LOW / MEDIUM / HIGH) + names the FEAT-233
  modules a custodial setup wants, under the existing disclaimer.

## Out of scope (follow-ups)

* PWA surfacing (hide disabled buttons via an effective-capabilities
  endpoint) — FEAT-209-style follow-up.
* Per-account raw capability overrides beyond profiles.
* The `referral_discount_pct` fee tier (separate pricing change).
* Auto-sweep wiring as a profile side-effect (operator composes it
  from FEAT-226 standing orders for now).

## Acceptance criteria

1. Default (no profile set) → every capability allowed; existing
   behaviour unchanged.
2. `account set-profile <a> prepaid` → `withdraw` + `transfer_inter_user`
   denied for `a` (402 `capability_disabled`); `recv`/`topup`/`pay`
   still work.
3. `account set-fund-class <a> foreign` labels the account; `compliance
   status` then rates the node HIGH and names the recommended modules.
4. A same-owner transfer is gated by `transfer_intra_user`; a
   cross-owner / to-anonymous transfer by `transfer_inter_user`.
5. `account profiles` prints the table; an unknown profile is rejected.

## Dependencies

* FEAT-212 (the value-moving verbs), FEAT-222 (`owner_user`,
  `access.recfile`), FEAT-233 (compliance status — the risk audit's
  home), FEAT-226 (standing orders — the prepaid sweep).

## Milestone

alpha — must ship before the feature-complete **alpha** cut.
