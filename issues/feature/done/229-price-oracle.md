---
id: FEAT-229
type: feature
priority: medium
status: research
---

# Price oracle — fetch + store sat/fiat prices

## Description

A base-fiat price for sats, fetched from an operator-configured
source + **stored historically**.  Two consumers:

* **Convenience** — the PWA + POS show amounts in the user's
  base fiat (EUR/USD/...) alongside sats.
* **Tax** (FEAT-230) — every ledger entry needs the fiat value
  *at the time it occurred*, so we must record price history,
  not just the latest tick.

## Scope

* New `prices` table:
    ```sql
    CREATE TABLE prices (
        ts        INTEGER NOT NULL,   -- unix epoch of the tick
        base      TEXT    NOT NULL,   -- 'EUR' | 'USD' | ...
        sat_price REAL    NOT NULL,   -- fiat per 1 sat (or per BTC; document)
        source    TEXT    NOT NULL,   -- which feed
        PRIMARY KEY (ts, base)
    );
    ```
* Price source is operator-configured (`price.recfile`):
  a feed URL + a base currency + a poll cadence.  Candidates:
  Kraken, Coinbase, mempool.space, CoinGecko — operator picks
  (network policy dependent).  Pluggable: one small fetch
  function per source, selected by name.
* Sidecar `lightning price poll` (cron, e.g. every 5–15 min):
  fetch latest → insert a `prices` row.  `daemon install
  --price-oracle`.
* Verb `lightning price now [--base EUR]` + `lightning price
  at <unix-ts> [--base EUR]` (nearest stored tick).
* HTTP `GET /.well-known/lightning/v1/price?base=EUR` →
  `{base, sat_price, ts, source}`.  Public (no auth) — it's
  just a price.
* A helper other verbs/exports call: "value N sats in <base>
  at <ts>" → looks up the nearest stored tick.

## Out of scope

* Multi-source aggregation / median (one source per base for
  v1; operator trusts their chosen feed).
* Intraday OHLC / charting.
* Forex between two fiats (we store sat→base only).

## Acceptance criteria

1. `price poll` against a (mocked) feed inserts a row.
2. `price now --base EUR` returns the latest stored tick.
3. `price at <ts>` returns the nearest tick to that timestamp.
4. `GET .../price?base=EUR` serves it over HTTP, no auth.
5. Unknown base / no data → clear empty/err response.

## Dependencies

* FEAT-224 (versioned `.well-known` prefix for the HTTP route).
* Feeds the FEAT-230 tax-data export.

## Milestone

alpha — must ship before the feature-complete **alpha** cut (alpha = everything implemented; then beta hardening; then 1.0.0 is a formal version bump).
