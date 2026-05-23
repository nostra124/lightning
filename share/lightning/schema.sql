-- lightning wallet schema (FEAT-193, extended FEAT-212, FEAT-218,
-- FEAT-222).
--
-- WAL mode is configured at open time by the verbs.
-- Migrations: idempotent ALTER TABLE / CREATE TABLE IF NOT EXISTS in
-- libexec/lightning/account's migrate_accounts_schema().  Existing
-- wallets pick up new columns + tables on their next account-verb
-- invocation.

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS accounts (
    name             TEXT    PRIMARY KEY,
    description      TEXT    NOT NULL DEFAULT '',
    limit_sat        INTEGER,
    overdraft        TEXT    NOT NULL DEFAULT 'deny',
    -- FEAT-212 — Bitcoin address that doubles as the canonical
    -- account ID for the HTTP API (minted via lightning-cli newaddr
    -- at create time).  NULL for legacy operator-created accounts.
    address          TEXT,
    -- FEAT-212 — lifecycle bookkeeping for the cleanup cron.
    created_at       INTEGER,
    closed_at        INTEGER,
    last_api_call_at INTEGER,
    -- FEAT-218 — single-level referrer.  Default 'house' so every
    -- account participates in the operator-fee chain by default.
    -- Manual override via `lightning account set-referrer` (admin
    -- escape hatch for sybil-defence cases).
    referrer         TEXT    DEFAULT 'house'
                             REFERENCES accounts(name) ON DELETE SET DEFAULT,
    -- FEAT-222 — the owning wallet-user (the human identity above
    -- accounts).  NULL = anonymous account (no owner).  FK to
    -- wallet_users (NOT the FEAT-176 `users` lnaddr table, which is a
    -- different concept).  ON DELETE SET NULL orphans the account if
    -- its owner is removed; the GC later reaps idle orphans.
    owner_user       TEXT    REFERENCES wallet_users(id) ON DELETE SET NULL
);

-- FEAT-218 — invite codes minted by accounts that want to refer
-- newcomers.  Anonymous; the only secret is the code value itself.
-- FEAT-222 grows owner_user + credit_account: a user-minted code
-- names which of the user's accounts receives the referral credit.
-- The legacy `account` column is the fallback credit target when
-- owner_user is NULL (pre-FEAT-222 account-linked codes).
CREATE TABLE IF NOT EXISTS invite_codes (
    code           TEXT    PRIMARY KEY,
    account        TEXT    NOT NULL REFERENCES accounts(name) ON DELETE CASCADE,
    created_at     INTEGER NOT NULL,
    uses           INTEGER NOT NULL DEFAULT 0,
    owner_user     TEXT    REFERENCES wallet_users(id) ON DELETE CASCADE,
    credit_account TEXT    REFERENCES accounts(name) ON DELETE SET NULL
);

-- FEAT-222 — the user layer above accounts.  A wallet-user is the
-- human identity (passkey-authed in the PWA) that owns one or more
-- accounts.  Named `wallet_users` to avoid colliding with the
-- FEAT-176 `users` table (Lightning-Address localparts).
CREATE TABLE IF NOT EXISTS wallet_users (
    id            TEXT    PRIMARY KEY,            -- usr_<base32>
    created_at    INTEGER NOT NULL,
    referrer_user TEXT    REFERENCES wallet_users(id) ON DELETE SET NULL,
    label         TEXT    NOT NULL DEFAULT ''
);

-- FEAT-225 — commercial invoices.  A merchant-issued invoice that
-- carries a structured order/shipment reference + optional payment
-- terms (due date, Skonto early-pay discount, late fee).  Keyed by
-- payment_hash so a settled payment reconciles back to the order.
-- The effective amount (face / discounted / late) is computed at
-- query time from `terms` + `issued_at`; the BOLT-11 itself is a
-- fixed-amount quote at the face value.
CREATE TABLE IF NOT EXISTS commerce_invoices (
    payment_hash TEXT    PRIMARY KEY,
    account      TEXT    NOT NULL REFERENCES accounts(name) ON DELETE CASCADE,
    bolt11       TEXT    NOT NULL,
    face_sat     INTEGER NOT NULL,
    reference    TEXT,               -- JSON: {order_id, delivery_note, ...}
    terms        TEXT,               -- JSON: {due_days, skonto, late_fee}
    issued_at    INTEGER NOT NULL,
    state        TEXT    NOT NULL DEFAULT 'issued'   -- issued | paid
);

-- FEAT-226 — standing orders (Dauerauftrag).  A scheduled recurring
-- push payment to a *re-payable* target (LN address, BOLT-12 offer, or
-- a local account name).  The runner sidecar picks up due rows
-- (next_run <= now), pays via the normal pay/transfer path (so the
-- operator fee tier applies), advances next_run by the cadence, and
-- auto-pauses an order after too many consecutive failures.
CREATE TABLE IF NOT EXISTS standing_orders (
    id          TEXT    PRIMARY KEY,            -- so_<base32>
    account     TEXT    NOT NULL REFERENCES accounts(name) ON DELETE CASCADE,
    target      TEXT    NOT NULL,               -- LN address | BOLT-12 offer | local account
    sat         INTEGER NOT NULL,
    cadence     TEXT    NOT NULL,               -- 'daily'|'weekly'|'monthly'
    next_run    INTEGER NOT NULL,
    last_run    INTEGER,
    failures    INTEGER NOT NULL DEFAULT 0,     -- consecutive failed runs
    status      TEXT    NOT NULL DEFAULT 'active',  -- active|paused|cancelled
    created_at  INTEGER NOT NULL
);

-- FEAT-227 — direct debit (Lastschrift) mandates.  A customer
-- pre-authorizes a merchant to pull up to `max_per_period` every
-- `period`.  Lightning is push-only, so a "pull" is a
-- merchant-triggered, customer-side-executed push gated by the
-- mandate: the merchant presents the per-mandate `secret` on the
-- charge call.  `mode` = 'auto' pulls execute immediately; 'approval'
-- holds each pull pending the customer's OK.  `merchant` is a local
-- account name (intra-node, executed as a FEAT-223 transfer) OR an
-- external payable target (cross-node, executed as a pay push); it is
-- therefore not FK-constrained.  `customer` is always local.
CREATE TABLE IF NOT EXISTS mandates (
    id              TEXT    PRIMARY KEY,            -- mdt_<base32>
    merchant        TEXT    NOT NULL,               -- local account | payable target
    customer        TEXT    NOT NULL REFERENCES accounts(name) ON DELETE CASCADE,
    max_per_period  INTEGER NOT NULL,
    period          TEXT    NOT NULL,               -- 'daily'|'weekly'|'monthly'
    mode            TEXT    NOT NULL DEFAULT 'auto', -- 'auto'|'approval'
    status          TEXT    NOT NULL DEFAULT 'active',  -- active|paused|revoked
    secret          TEXT    NOT NULL,               -- bearer for the charge call
    created_at      INTEGER NOT NULL
);

-- Individual pull attempts against a mandate.  state walks
-- pending -> approved -> executed (mode 'approval') or straight to
-- executed (mode 'auto'); a customer-denied pull lands 'denied'.
CREATE TABLE IF NOT EXISTS mandate_pulls (
    id          TEXT    PRIMARY KEY,                -- mpl_<base32>
    mandate     TEXT    NOT NULL REFERENCES mandates(id) ON DELETE CASCADE,
    sat         INTEGER NOT NULL,
    reference   TEXT,                               -- FEAT-225 order/shipment ref
    state       TEXT    NOT NULL,                   -- pending|approved|executed|denied
    created_at  INTEGER NOT NULL
);

-- FEAT-229 — price history.  One row per poll tick.  Stores the BTC
-- price in a base fiat (whole-unit, e.g. EUR per 1 BTC); per-sat
-- value is btc_fiat / 1e8, computed at query time.  History (not
-- just the latest tick) is required so every ledger entry can be
-- valued at the fiat price for ITS timestamp (FEAT-230 tax export).
CREATE TABLE IF NOT EXISTS prices (
    ts        INTEGER NOT NULL,   -- unix epoch of the tick
    base      TEXT    NOT NULL,   -- 'EUR' | 'USD' | ...
    btc_fiat  REAL    NOT NULL,   -- base-fiat units per 1 BTC
    source    TEXT    NOT NULL,   -- which feed produced it
    PRIMARY KEY (ts, base)
);

CREATE TABLE IF NOT EXISTS ledger (
    id           INTEGER PRIMARY KEY,
    ts           TEXT    NOT NULL,
    account      TEXT    NOT NULL DEFAULT '-'
                         REFERENCES accounts(name) ON DELETE SET DEFAULT,
    direction    TEXT    NOT NULL,
    amount_msat  INTEGER NOT NULL,
    peer         TEXT    NOT NULL DEFAULT '-',
    payment_hash TEXT    NOT NULL DEFAULT '-',
    message      TEXT    NOT NULL DEFAULT '',
    note         TEXT    NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS invoices (
    bolt11       TEXT    PRIMARY KEY,
    payment_hash TEXT    NOT NULL,
    account      TEXT    NOT NULL DEFAULT '-'
                         REFERENCES accounts(name) ON DELETE SET DEFAULT,
    amount_msat  INTEGER NOT NULL,
    expiry       TEXT    NOT NULL,
    message      TEXT    NOT NULL DEFAULT '',
    state        TEXT    NOT NULL DEFAULT 'pending'
);

CREATE TABLE IF NOT EXISTS channel_notes (
    channel_id TEXT PRIMARY KEY,
    note       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
    user        TEXT    PRIMARY KEY,
    account     TEXT    NOT NULL
                        REFERENCES accounts(name) ON DELETE CASCADE,
    min_sat     INTEGER NOT NULL DEFAULT 1,
    max_sat     INTEGER NOT NULL DEFAULT 100000000,
    comment_max INTEGER NOT NULL DEFAULT 256
);

-- Seed house FIRST so the default `referrer = 'house'` on every
-- subsequent insert has a valid FK target.  Same overdraft=allow as
-- in FEAT-213's lazy bootstrap.  House's own referrer is itself
-- (self-FK; SQLite allows this).
INSERT OR IGNORE INTO accounts(name, description, overdraft)
    VALUES('house', 'operator fee revenue', 'allow');

-- Seed the unassigned account so the SET DEFAULT FK lands somewhere.
INSERT OR IGNORE INTO accounts(name, description) VALUES('-', 'unassigned');
