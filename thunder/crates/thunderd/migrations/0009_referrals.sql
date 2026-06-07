-- Referral chain (FEAT-320): an account may credit a share of the
-- operator fee it generates to its referrer's account.
ALTER TABLE accounts ADD COLUMN referrer_account TEXT;
