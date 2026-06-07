-- Phase II non-custodial scaffolding (FEAT-400+): per-tenant identity,
-- watch-only xpub (the daemon never holds a spendable key — custody bar
-- A2), and the remote-signer request queue (device signs, returns sig).
-- NOTE: the LDK node engine + PSBT construction are not implemented yet;
-- this is the tenant/transport layer those will plug into.
CREATE TABLE IF NOT EXISTS tenants (
    id         TEXT PRIMARY KEY,
    user_id    TEXT REFERENCES wallet_users(id) ON DELETE SET NULL,
    label      TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS tenant_xpubs (
    tenant_id  TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    xpub       TEXT NOT NULL,          -- watch-only; cannot spend
    derivation TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    PRIMARY KEY (tenant_id, xpub)
);

-- Remote-signer transport: the daemon enqueues a sighash/PSBT to sign;
-- the device fetches pending requests, signs locally, returns the sig.
CREATE TABLE IF NOT EXISTS signer_requests (
    id         TEXT PRIMARY KEY,
    tenant_id  TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL,          -- psbt | commitment | sighash
    payload    TEXT NOT NULL,          -- what to sign (hex/base64)
    status     TEXT NOT NULL DEFAULT 'pending',  -- pending | signed | rejected
    signature  TEXT,
    created_at INTEGER NOT NULL,
    signed_at  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_signer_tenant ON signer_requests(tenant_id, status);
