-- Direct-debit mandates (FEAT-317). Extends the bare mandates table from
-- 0001 with a per-pull cap + label, and records each pull.
ALTER TABLE mandates ADD COLUMN max_amount_msat INTEGER;
ALTER TABLE mandates ADD COLUMN label TEXT NOT NULL DEFAULT '';

CREATE TABLE IF NOT EXISTS mandate_pulls (
    id          TEXT PRIMARY KEY,
    mandate_id  TEXT NOT NULL REFERENCES mandates(id) ON DELETE CASCADE,
    to_account  TEXT NOT NULL,
    amount_msat INTEGER NOT NULL,
    fee_msat    INTEGER NOT NULL DEFAULT 0,
    group_id    TEXT NOT NULL,
    created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pulls_mandate ON mandate_pulls(mandate_id);
