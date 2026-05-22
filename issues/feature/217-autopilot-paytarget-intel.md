---
id: FEAT-217
type: feature
priority: medium
status: research
---

# Autopilot pay-target intelligence

## Description

FEAT-205's channel autopilot opens channels based on heuristics
(capacity, peer reputation, etc.).  This ticket feeds it a new
signal: the destinations our users actually pay to.  A direct
channel to a frequently-paid destination skips one or more
intermediate hops, saving routing fees + improving reliability.

## Scope

* New nightly verb: `lightning channel paytarget-intel`
    * Reads `lightning-cli listpays` + `listsendpays` for the
      last 30 days.
    * Aggregates by destination pubkey: sat-volume + payment
      count.
    * Filters out peers we already have a direct channel with.
    * Writes the top N (configurable, default 10) to
      `$wallet/autopilot.suggest.recfile` as autopilot
      suggestion records.
    * FEAT-205's autopilot already consumes that suggest queue
      — pure extension, no autopilot changes.
* Wired into FEAT-205's `--autopilot` sidecar timer (no
  separate sidecar needed).

## Out of scope

* Inferring intent ("user keeps paying X, they probably want a
  direct channel") beyond raw volume.
* Cross-account aggregation that could leak per-user payment
  patterns to the autopilot's logs.  Aggregate only.

## Dependencies

* FEAT-205 (autopilot must exist as a consumer).  Pure
  extension — no API or schema change.

## Acceptance criteria

1. Synthetic 30-day pay history with a clear top destination
   produces a suggestion targeting that pubkey.
2. Destinations we're already directly connected to are
   excluded.
3. Empty pay history is a no-op (no suggestion written).

## Milestone

1.5.0.
