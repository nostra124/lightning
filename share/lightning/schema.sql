-- lightning wallet schema (FEAT-193).
--
-- Five tables, no triggers, no views, no migrations in v1.
-- WAL mode is configured at open time by the verbs.

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS accounts (
    name        TEXT    PRIMARY KEY,
    description TEXT    NOT NULL DEFAULT '',
    limit_sat   INTEGER,
    overdraft   TEXT    NOT NULL DEFAULT 'deny'
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

-- Seed the unassigned account so the SET DEFAULT FK lands somewhere.
INSERT OR IGNORE INTO accounts(name, description) VALUES('-', 'unassigned');
