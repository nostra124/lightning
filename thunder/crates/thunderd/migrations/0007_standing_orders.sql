-- Recurring transfers (Dauerauftrag) executed by the in-process runner
-- (FEAT-316).
CREATE TABLE IF NOT EXISTS standing_orders (
    id            TEXT PRIMARY KEY,
    from_account  TEXT NOT NULL,
    to_account    TEXT NOT NULL,
    amount_msat   INTEGER NOT NULL,
    interval_secs INTEGER NOT NULL,
    next_run      INTEGER NOT NULL,
    last_run      INTEGER,
    active        INTEGER NOT NULL DEFAULT 1,
    created_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_so_due ON standing_orders(next_run);
