---
id: FEAT-233
type: feature
priority: high
status: research
---

# Compliance module framework — toggleable, jurisdiction-agnostic

## Description

A hook framework that lets a hosted operator switch on the
record-keeping + control capabilities a regulator might demand,
**without baking any jurisdiction's rules into the code**.  The
capabilities are general modules (KYC, screening, AML
monitoring, Travel Rule, retention, reporting, data-subject
rights, proof of reserves, disclosures); a jurisdiction is just
a *preset* — a named bundle of module toggles + thresholds.

The goal is **preparedness**: when the solution is operated in
DE / US / UK / FR / RU / Brazil / South Africa / wherever, the
operator flips on the relevant modules via config rather than
forking the software.  We don't encode the regulations
themselves, and we don't give legal advice — we provide the
*technical capabilities* the regulations tend to require.

## The custodial dividing line

Almost all of this only matters when the operator **holds other
people's funds** (the hosted multi-account model).  A
self-hosted / personal node (own funds only) leaves every
module off — non-custodial operation carries little
documentation burden beyond the operator's own tax export
(FEAT-230).  So: **modules default off**; the hosted operator
opts in.

Concretely this is a **system-mode** concern (FEAT-183
three-user install — the daemon running a public, custodial
instance for others).  Private / family / user-mode installs:
people running their own node for their own (or close
relations') funds won't care, and nothing here is on for them.
The framework only earns its keep on a commercial system-mode
deployment.

## Mandatory legal disclaimer (a hard requirement)

Every surface that touches compliance — the `compliance.recfile`
header, `lightning compliance status`, each module's man page
(FEAT-221), the inline docs (FEAT-209), and the PWA's
operator/admin view — MUST carry a prominent disclaimer:

> These compliance tools were implemented with AI assistance.
> They provide *technical capabilities*, not legal advice and
> not a guarantee of regulatory compliance.  Whether they
> satisfy any obligation in your jurisdiction is your
> responsibility — **consult a qualified local lawyer** before
> operating a custodial service.

This text (or a close variant) is shipped in a single
`share/lightning/compliance/DISCLAIMER.txt`, referenced from
each surface so it stays consistent.  `compliance preset
<name>` prints it on first application; `compliance status`
footers it.  No compliance module's docs ship without it.

## The hook framework (the architecturally significant part)

Core value-moving verbs gain compliance hook-dispatch at three
points:

* **pre-transaction** — before `api-account-pay` /
  `api-account-transfer` / `api-account-withdraw` /
  `api-accounts-create` execute.  A pre-hook may **deny**
  (block the op with a clear error: `kyc_required`,
  `screening_block`, `travel_rule_required`, …).
* **post-transaction** — after the op settles.  Post-hooks
  observe + record (AML flagging, monitoring counters); they
  don't block.
* **lifecycle** — on account/user create (consent capture,
  KYC tier assignment) and on GC (retention check before
  delete).

Each module is a small libexec verb (`compliance-kyc`,
`compliance-screen`, `compliance-monitor`, …) the dispatcher
invokes at the right hook point.  Disabled module = the hook is
a no-op (cheap: a config check short-circuits before any
verb spawn).  This keeps the core verbs to a one-line
hook-dispatch call each + isolates all compliance logic.

```
api-account-pay
  → compliance_hook pre  pay   <ctx>   # deny → 4xx, abort
  → (execute the payment)
  → compliance_hook post pay   <ctx>   # observe + record
```

## Config

A new `compliance.recfile` under the wallet repo (git-tracked,
operator-edited).  Per-module enable + thresholds:

```
module: kyc
enabled: on
tier_anonymous_max_sat: 100000      # KYC required above this

module: screening
enabled: on
list: ofac,eu

module: travel_rule
enabled: on
threshold_sat: 1500000

module: retention
enabled: on
years: 5

module: monitoring
enabled: on

module: data_subject_rights
enabled: on

module: proof_of_reserves
enabled: off
```

Presets are convenience bundles applied by a verb
(`lightning compliance preset <name>`) that writes the
matching toggles — no jurisdiction logic in code.

## Capability modules (each its own sub-ticket)

| Module | Hook point | Data model |
|---|---|---|
| KYC / identity (FEAT-234) | pre-create, pre-tx (tiered) | `identities` table; tier on user/account |
| Sanctions screening (FEAT-235) | pre-tx | `blocklist`, `screening_log` |
| AML monitoring (FEAT-236) | post-tx | rules + `monitoring_flags` |
| Travel Rule (FEAT-237) | pre-tx ≥ threshold | originator/beneficiary on transfers; VASP exchange |
| Record retention (FEAT-238) | GC lifecycle | retention-aware GC + `legal_hold` flag |
| Regulatory reporting (FEAT-239) | offline export | report generators over ledger + flags |
| Data-subject rights / GDPR (FEAT-240) | offline + lifecycle | `consent_log`, export, erasure-with-hold |
| Proof of reserves (FEAT-241) | offline | attestation: node balance ≥ Σ accounts |
| Disclosures / ToS (FEAT-242) | lifecycle | versioned ToS + `consent_log` |

## Jurisdictions → the same modules (compact, illustrative only)

Confirms universality — every regime maps to a subset of the
*same* modules; only thresholds + report formats + retention
periods differ.  (Not legal research; just which capabilities
each tends to want.)

| Jurisdiction | Modules typically on |
|---|---|
| DE (private, own funds) | data_subject_rights, retention; tax export only |
| DE (custodial) | + kyc, screening, monitoring, travel_rule, reporting |
| US (Delaware LLC, MSB) | kyc, screening, monitoring, travel_rule (≥$3k), reporting (SAR/CTR), retention (5y), proof_of_reserves |
| UK (FCA) | kyc, screening, monitoring, travel_rule, disclosures |
| France (PSAN) | kyc, screening, monitoring, travel_rule, data_subject_rights |
| Russia | kyc, monitoring, reporting; screening (both directions) critical |
| Brazil (VASP/BCB) | kyc, monitoring, reporting, data_subject_rights (LGPD) |
| South Africa (FSCA/FIC) | kyc, monitoring, reporting, data_subject_rights (POPIA) |
| "minimal" / registration-only | none mandatory; all available |

Same eight-or-so capabilities everywhere.  That's the point:
build the capabilities once, bundle per jurisdiction in config.

## Two architectural tensions (resolved in the framework)

1. **Anonymous accounts (FEAT-212) vs. KYC** — coexist via
   *tiered KYC*: anonymous below `tier_anonymous_max_sat`,
   identity required above.  The threshold is module config;
   the anonymous model survives unchanged when KYC is off.
2. **Retention vs. erasure (GDPR)** — direct conflict (keep
   N years vs. delete-on-request).  Resolved with a
   `legal_hold` concept: erasure honours the request *except*
   for records under a retention obligation, which are
   **pseudonymised** (PII stripped, ledger math preserved)
   rather than deleted.  This is an explicit data-model
   decision the framework owns.

## Scope (this ticket = framework only)

* `compliance.recfile` + a loader.
* The hook-dispatch helper (`compliance_hook <when> <op>
  <ctx>`) wired into the four value-moving verbs + create +
  GC, as no-ops until a module is enabled.
* `lightning compliance status` (which modules on) +
  `lightning compliance preset <name>` (apply a bundle).
* A `compliance_events` append-only audit log (every
  hook decision recorded — itself a compliance requirement).
* `share/lightning/compliance/DISCLAIMER.txt` (the AI-built /
  consult-a-lawyer text) + its wiring into `compliance status`
  (footer) and `compliance preset` (printed on apply).
* NO actual module logic — each module ships in its own
  sub-ticket (FEAT-234..242).  The framework lands with all
  hooks no-op so the core verbs are wired + tested before any
  module exists.

## Out of scope

* The regulations themselves / legal advice / license
  applications — we provide capabilities, not counsel.
* Any individual module's logic (sub-tickets).
* Automatic jurisdiction detection — the operator picks the
  preset; we never infer it.

## Acceptance criteria

1. With an empty/absent `compliance.recfile`, every hook is a
   no-op and the value-moving verbs behave exactly as today
   (zero overhead, all existing tests pass).
2. `compliance preset us-msb` writes a `compliance.recfile`
   enabling the expected module set.
3. A stub pre-hook that denies blocks the transaction with its
   error surfaced as a 4xx; a stub post-hook records to
   `compliance_events` without blocking.
4. `compliance status` reports which modules are on + footers
   the legal disclaimer.
5. The hook-dispatch adds no measurable latency when all
   modules are off (config check short-circuits).
6. `compliance preset <name>` prints the DISCLAIMER.txt text
   on application; the file ships under
   `share/lightning/compliance/`.

## Phasing

* **PR-1 (this — spec)**
* **PR-2 (framework)** — config + hook dispatch + audit log +
  `compliance status`/`preset` + no-op wiring into the verbs.
* **PR-3..N** — one module per sub-ticket (FEAT-234..242),
  each plugging into the framework, shippable independently.

## Dependencies

* FEAT-212 (the value-moving verbs the hooks wrap).
* FEAT-222 (users — KYC + data-subject rights attach to users).
* FEAT-230 (tax export — reporting reuses its export machinery).
* FEAT-224/232 (versioned `.well-known` — compliance HTTP
  endpoints, where any, land at the versioned prefix).

## Milestone

alpha — must ship before the feature-complete **alpha** cut (the framework; individual compliance modules FEAT-234..242 are post-1.0 backlog, switched on per-jurisdiction as the hosted instance needs them).
