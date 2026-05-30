---
id: FEAT-226
type: feature
priority: medium
status: research
---

# Standing order (Dauerauftrag) — scheduled recurring payment

## Description

**As an** account holder
**I want** to schedule a recurring payment (rent, allowance,
subscription)
**So that** it executes automatically on a cadence without me
re-initiating each time.

A standing order is a cron job that pays a *re-payable* target
on schedule.  Cross-node by nature — it uses the existing
`pay` path against a target that can be paid repeatedly.

## Scope

* New `standing_orders` table:
    ```sql
    CREATE TABLE standing_orders (
        id          TEXT PRIMARY KEY,       -- so_<...>
        account     TEXT NOT NULL REFERENCES accounts(name) ON DELETE CASCADE,
        target      TEXT NOT NULL,          -- LN address | BOLT-12 offer | local account
        sat         INTEGER NOT NULL,
        cadence     TEXT NOT NULL,          -- 'daily'|'weekly'|'monthly'
        next_run    INTEGER NOT NULL,
        last_run    INTEGER,
        status      TEXT NOT NULL DEFAULT 'active',  -- active|paused|cancelled
        created_at  INTEGER NOT NULL
    );
    ```
* Target must be **re-payable**: a Lightning address (LNURL-
  pay), a BOLT-12 offer, OR a local account name (intra-node
  transfer via FEAT-223).  NOT a single-use BOLT-11.
* CLI: `lightning account standing-order create/list/pause/
  resume/cancel`.
* HTTP: `POST/GET/DELETE /.well-known/lightning/accounts/<id>/
  standing-orders[/<so_id>]`.
* Sidecar: `lightning account standing-order run` invoked by
  a daily (or finer) timer — `daemon install --standing-orders`.
  Picks up due orders (`next_run <= now`), pays, advances
  `next_run` by the cadence, logs the result.
* Operator fee: each execution pays the normal `pay` /
  `transfer` fee tier (FEAT-213/219).
* Failure handling: a failed run is logged + retried on the
  next tick (no infinite same-tick retry); after N
  consecutive failures the order auto-pauses + alerts
  (FEAT-187 alert hook).

## Out of scope

* Direct debit / pull (FEAT-227) — this is push-on-schedule.
* Variable amounts (each run is a fixed sat amount in v1).
* Cross-node target liveness guarantees — if the target is
  unreachable at run time, we log + retry next tick.

## Acceptance criteria

1. Create a monthly standing order; the row lands with
   `next_run` one month out.
2. `standing-order run` with a due order pays the target +
   advances `next_run`; not-yet-due orders are skipped.
3. Pause/resume/cancel transition the status correctly;
   paused orders are skipped by the runner.
4. A failed payment auto-pauses after N failures + fires an
   alert.
5. `daemon install --standing-orders` writes the sidecar
   timer.

## Dependencies

* FEAT-223 (local-account targets) + FEAT-224 (endpoint
  prefix).  Cross-node targets use the existing pay path.

## Milestone

alpha — must ship before the feature-complete **alpha** cut (alpha = everything implemented; then beta hardening; then 1.0.0 is a formal version bump).
