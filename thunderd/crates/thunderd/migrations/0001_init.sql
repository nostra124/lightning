-- thunderd Phase I (custodial) — initial owned schema (FEAT-306).
--
-- The daemon owns this state outright (design.md §4): no shared wallet
-- state.db, no bash verbs. Full commerce tables (invoices, standing
-- orders, charges, events, referrals, prices) land with their feature
-- ports in Phase 4; this migration establishes the core that the
-- skeleton's auth + ledger primitives need.

-- Human identity that owns one or more accounts (FEAT-222 wallet-user,
-- ported into thunderd). NB: distinct from FEAT-176 Lightning-Address
-- localparts.
CREATE TABLE IF NOT EXISTS wallet_users (
    id            TEXT PRIMARY KEY,
    created_at    INTEGER NOT NULL,
    referrer_user TEXT,
    label         TEXT NOT NULL DEFAULT '',
    max_downline  INTEGER
);

-- An account: a custodial msat balance keyed by a bech32 address.
CREATE TABLE IF NOT EXISTS accounts (
    id         TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL,
    label      TEXT NOT NULL DEFAULT '',
    owner_user TEXT REFERENCES wallet_users(id) ON DELETE SET NULL,
    capability TEXT NOT NULL DEFAULT 'custodial',
    closed_at  INTEGER
);

-- Bearer API keys (account-scoped). Only the SHA-256 hash is stored.
CREATE TABLE IF NOT EXISTS apikeys (
    id         TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    label      TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    revoked_at INTEGER
);

-- Direct-debit mandates, charged by secret. Only the hash is stored.
CREATE TABLE IF NOT EXISTS mandates (
    id          TEXT PRIMARY KEY,
    account_id  TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    secret_hash TEXT NOT NULL UNIQUE,
    created_at  INTEGER NOT NULL,
    revoked_at  INTEGER
);

-- Double-entry, msat-precision ledger. Each economic event writes a
-- balanced pair sharing a group_id; signed amounts (FEAT-307 fills in
-- the engine + invariants).
CREATE TABLE IF NOT EXISTS ledger (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts              INTEGER NOT NULL,
    group_id        TEXT NOT NULL,
    account_id      TEXT NOT NULL,
    counter_account TEXT NOT NULL,
    amount_msat     INTEGER NOT NULL,
    memo            TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_ledger_account ON ledger(account_id);
CREATE INDEX IF NOT EXISTS idx_ledger_group ON ledger(group_id);

-- Passkey / WebAuthn credentials for wallet-users (auth in thunderd).
CREATE TABLE IF NOT EXISTS webauthn_credentials (
    id         TEXT PRIMARY KEY,            -- credential id (base64url)
    user_id    TEXT NOT NULL REFERENCES wallet_users(id) ON DELETE CASCADE,
    public_key BLOB NOT NULL,
    sign_count INTEGER NOT NULL DEFAULT 0,
    label      TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_webauthn_user ON webauthn_credentials(user_id);
