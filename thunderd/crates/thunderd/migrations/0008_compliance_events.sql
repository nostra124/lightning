-- Compliance audit trail (FEAT-322): one row per checked money-move,
-- recording the decision so it can be reviewed/exported.
CREATE TABLE IF NOT EXISTS compliance_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts              INTEGER NOT NULL,
    account_id      TEXT NOT NULL,
    counter_account TEXT NOT NULL DEFAULT '',
    amount_msat     INTEGER NOT NULL,
    action          TEXT NOT NULL,    -- send | mandate_charge | ...
    decision        TEXT NOT NULL,    -- allow | deny
    reason          TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_compliance_account ON compliance_events(account_id);
