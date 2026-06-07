-- Auth/capture charge lifecycle (FEAT-318). The held amount lives in the
-- `escrow` system account between authorize and capture/void.
CREATE TABLE IF NOT EXISTS commerce_charges (
    id               TEXT PRIMARY KEY,
    payer_account    TEXT NOT NULL,
    merchant_account TEXT NOT NULL,
    amount_msat      INTEGER NOT NULL,
    captured_msat    INTEGER NOT NULL DEFAULT 0,
    refunded_msat    INTEGER NOT NULL DEFAULT 0,
    status           TEXT NOT NULL DEFAULT 'authorized', -- authorized|captured|voided|refunded
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_charges_merchant ON commerce_charges(merchant_account);
CREATE INDEX IF NOT EXISTS idx_charges_payer ON commerce_charges(payer_account);
