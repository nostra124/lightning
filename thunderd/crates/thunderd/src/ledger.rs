//! Double-entry, msat-precision ledger engine (FEAT-307).
//!
//! Every economic event writes a *balanced pair* of rows sharing a
//! `group_id`: a debit on one account and an equal credit on the other,
//! so `SUM(amount_msat)` over any group is exactly zero and over the
//! whole ledger is zero too (the invariant the property tests assert).
//!
//! Balances are derived (`SUM(amount_msat)` per account), never stored —
//! there is no balance column to drift. Overdraft is refused for normal
//! accounts and allowed for the system accounts seeded in
//! `0002_system_accounts.sql`.

use crate::error::AppError;
use sqlx::SqlitePool;

/// System accounts that may carry a negative balance.
pub const SYSTEM_ACCOUNTS: &[&str] = &["house", "escrow", "others", "-"];

pub fn is_system(account: &str) -> bool {
    SYSTEM_ACCOUNTS.contains(&account)
}

/// Current balance (msat) of an account: the signed sum of its legs.
pub async fn balance(pool: &SqlitePool, account: &str) -> Result<i64, AppError> {
    let (bal,): (i64,) =
        sqlx::query_as("SELECT COALESCE(SUM(amount_msat), 0) FROM ledger WHERE account_id = ?1")
            .bind(account)
            .fetch_one(pool)
            .await
            .map_err(|_| AppError::Backend)?;
    Ok(bal)
}

/// Atomically move `amount_msat` from `from` to `to`, writing the
/// balanced double-entry pair. Refuses non-positive amounts and any
/// transfer that would overdraw a non-system source account.
///
/// Returns the `group_id` tying the two legs together.
pub async fn transfer(
    pool: &SqlitePool,
    from: &str,
    to: &str,
    amount_msat: i64,
    memo: &str,
) -> Result<String, AppError> {
    if amount_msat <= 0 {
        return Err(AppError::BadRequest("amount must be positive".into()));
    }
    if from == to {
        return Err(AppError::BadRequest("from and to must differ".into()));
    }

    let group_id = format!("g_{}", crate::util::random_hex(12));
    let ts = crate::util::now();

    let mut tx = pool.begin().await.map_err(|_| AppError::Backend)?;

    // Overdraft guard for the source (system accounts are exempt). Read
    // inside the transaction so concurrent transfers can't race past it.
    if !is_system(from) {
        let (bal,): (i64,) = sqlx::query_as(
            "SELECT COALESCE(SUM(amount_msat), 0) FROM ledger WHERE account_id = ?1",
        )
        .bind(from)
        .fetch_one(&mut *tx)
        .await
        .map_err(|_| AppError::Backend)?;
        if bal - amount_msat < 0 {
            return Err(AppError::PaymentRequired);
        }
    }

    for (account, counter, delta) in [(from, to, -amount_msat), (to, from, amount_msat)] {
        sqlx::query(
            "INSERT INTO ledger (ts, group_id, account_id, counter_account, amount_msat, memo) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        )
        .bind(ts)
        .bind(&group_id)
        .bind(account)
        .bind(counter)
        .bind(delta)
        .bind(memo)
        .execute(&mut *tx)
        .await
        .map_err(|_| AppError::Backend)?;
    }

    tx.commit().await.map_err(|_| AppError::Backend)?;
    Ok(group_id)
}

/// Credit an account from the external world (`-`) — e.g. a settled
/// inbound invoice or a topup. Booked as a normal transfer so the
/// invariant holds; `-` simply goes more negative.
pub async fn credit_external(
    pool: &SqlitePool,
    account: &str,
    amount_msat: i64,
    memo: &str,
) -> Result<String, AppError> {
    transfer(pool, "-", account, amount_msat, memo).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Db;
    use crate::util::now;

    async fn seed_account(db: &Db, id: &str) {
        sqlx::query("INSERT INTO accounts (id, created_at, label) VALUES (?1, ?2, '')")
            .bind(id)
            .bind(now())
            .execute(&db.pool)
            .await
            .unwrap();
    }

    async fn ledger_sum(db: &Db) -> i64 {
        let (s,): (i64,) = sqlx::query_as("SELECT COALESCE(SUM(amount_msat),0) FROM ledger")
            .fetch_one(&db.pool)
            .await
            .unwrap();
        s
    }

    #[tokio::test]
    async fn transfer_moves_balance_and_preserves_invariant() {
        let db = Db::memory().await.unwrap();
        seed_account(&db, "alice").await;
        seed_account(&db, "bob").await;

        credit_external(&db.pool, "alice", 10_000, "topup")
            .await
            .unwrap();
        transfer(&db.pool, "alice", "bob", 3_000, "pay")
            .await
            .unwrap();

        assert_eq!(balance(&db.pool, "alice").await.unwrap(), 7_000);
        assert_eq!(balance(&db.pool, "bob").await.unwrap(), 3_000);
        // Whole-ledger invariant: everything sums to zero.
        assert_eq!(ledger_sum(&db).await, 0);
        // The external world is down what alice received.
        assert_eq!(balance(&db.pool, "-").await.unwrap(), -10_000);
    }

    #[tokio::test]
    async fn overdraft_is_refused_for_normal_accounts() {
        let db = Db::memory().await.unwrap();
        seed_account(&db, "alice").await;
        seed_account(&db, "bob").await;
        credit_external(&db.pool, "alice", 1_000, "topup")
            .await
            .unwrap();

        let err = transfer(&db.pool, "alice", "bob", 5_000, "too much")
            .await
            .unwrap_err();
        assert!(matches!(err, AppError::PaymentRequired));
        // Balance unchanged; failed transfer left no rows.
        assert_eq!(balance(&db.pool, "alice").await.unwrap(), 1_000);
        assert_eq!(balance(&db.pool, "bob").await.unwrap(), 0);
        assert_eq!(ledger_sum(&db).await, 0);
    }

    #[tokio::test]
    async fn system_accounts_may_overdraw() {
        let db = Db::memory().await.unwrap();
        seed_account(&db, "alice").await;
        // house is a system account — allowed to go negative.
        transfer(&db.pool, "house", "alice", 500, "fee rebate")
            .await
            .unwrap();
        assert_eq!(balance(&db.pool, "house").await.unwrap(), -500);
        assert_eq!(balance(&db.pool, "alice").await.unwrap(), 500);
    }

    #[tokio::test]
    async fn rejects_nonpositive_and_self_transfer() {
        let db = Db::memory().await.unwrap();
        seed_account(&db, "alice").await;
        assert!(matches!(
            transfer(&db.pool, "alice", "bob", 0, "").await.unwrap_err(),
            AppError::BadRequest(_)
        ));
        assert!(matches!(
            transfer(&db.pool, "alice", "alice", 1, "")
                .await
                .unwrap_err(),
            AppError::BadRequest(_)
        ));
    }
}
