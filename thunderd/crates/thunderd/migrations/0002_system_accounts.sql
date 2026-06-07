-- System accounts (FEAT-307). These are the double-entry counterparties
-- the ledger needs and may run negative (overdraft=allow):
--   house    — operator fee skim destination (FEAT-213/321)
--   escrow   — held funds for the charge/auth-capture lifecycle (FEAT-318)
--   others   — reconciliation bucket for external/unattributed flows
--   -        — the external world (Lightning/on-chain counterparty)
INSERT OR IGNORE INTO accounts (id, created_at, label, capability)
VALUES
    ('house',  unixepoch(), 'operator fees',        'system'),
    ('escrow', unixepoch(), 'charge escrow',        'system'),
    ('others', unixepoch(), 'reconciliation',       'system'),
    ('-',      unixepoch(), 'external world',       'system');
