//! Compliance pre-hook + audit (FEAT-322).
//!
//! Every outbound money-move passes `gate`, which enforces the configured
//! per-transaction ceiling and writes an audit row to `compliance_events`
//! recording the decision. A denied move never reaches the node/ledger.
//! The ceiling is the in-daemon stand-in for the old external hook layer;
//! a pluggable webhook can replace the predicate later.

use crate::error::AppError;
use crate::util::now;
use sqlx::SqlitePool;

/// Check + audit an outbound move. `max_msat == 0` disables the ceiling.
/// Returns `Forbidden` (and records `deny`) when over the ceiling.
pub async fn gate(
    pool: &SqlitePool,
    account: &str,
    counter: &str,
    amount_msat: i64,
    action: &str,
    max_msat: i64,
) -> Result<(), AppError> {
    let (decision, reason): (&str, String) = if max_msat > 0 && amount_msat > max_msat {
        (
            "deny",
            format!("amount {amount_msat} over ceiling {max_msat}"),
        )
    } else {
        ("allow", String::new())
    };
    record(
        pool,
        account,
        counter,
        amount_msat,
        action,
        decision,
        &reason,
    )
    .await?;
    if decision == "deny" {
        return Err(AppError::Forbidden);
    }
    Ok(())
}

async fn record(
    pool: &SqlitePool,
    account: &str,
    counter: &str,
    amount_msat: i64,
    action: &str,
    decision: &str,
    reason: &str,
) -> Result<(), AppError> {
    sqlx::query(
        "INSERT INTO compliance_events \
         (ts, account_id, counter_account, amount_msat, action, decision, reason) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    )
    .bind(now())
    .bind(account)
    .bind(counter)
    .bind(amount_msat)
    .bind(action)
    .bind(decision)
    .bind(reason)
    .execute(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Db;

    async fn audit_count(db: &Db, decision: &str) -> i64 {
        let (n,): (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM compliance_events WHERE decision = ?1")
                .bind(decision)
                .fetch_one(&db.pool)
                .await
                .unwrap();
        n
    }

    #[tokio::test]
    async fn allows_under_ceiling_and_audits() {
        let db = Db::memory().await.unwrap();
        gate(&db.pool, "a", "-", 1_000, "send", 5_000)
            .await
            .unwrap();
        assert_eq!(audit_count(&db, "allow").await, 1);
    }

    #[tokio::test]
    async fn denies_over_ceiling_and_audits() {
        let db = Db::memory().await.unwrap();
        let r = gate(&db.pool, "a", "-", 9_000, "send", 5_000).await;
        assert!(matches!(r.unwrap_err(), AppError::Forbidden));
        assert_eq!(audit_count(&db, "deny").await, 1);
    }

    #[tokio::test]
    async fn zero_ceiling_disables_limit() {
        let db = Db::memory().await.unwrap();
        gate(&db.pool, "a", "-", 1_000_000, "send", 0)
            .await
            .unwrap();
        assert_eq!(audit_count(&db, "allow").await, 1);
    }
}
