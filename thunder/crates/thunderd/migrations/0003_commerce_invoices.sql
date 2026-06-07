-- Inbound invoices the daemon issued via the node (FEAT-309/310/315).
-- Settlement (FEAT-310) flips status to 'paid' and books the credit.
CREATE TABLE IF NOT EXISTS commerce_invoices (
    id           TEXT PRIMARY KEY,
    account_id   TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    payment_hash TEXT NOT NULL UNIQUE,
    label        TEXT NOT NULL,
    bolt11       TEXT NOT NULL,
    amount_msat  INTEGER NOT NULL,
    description  TEXT NOT NULL DEFAULT '',
    status       TEXT NOT NULL DEFAULT 'unpaid',  -- unpaid | paid | expired
    created_at   INTEGER NOT NULL,
    expires_at   INTEGER,
    settled_at   INTEGER
);
CREATE INDEX IF NOT EXISTS idx_invoices_account ON commerce_invoices(account_id);
CREATE INDEX IF NOT EXISTS idx_invoices_status ON commerce_invoices(status);
