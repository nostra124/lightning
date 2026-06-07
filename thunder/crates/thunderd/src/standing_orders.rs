//! Recurring transfers + in-process runner (FEAT-316).
//!
//! Replaces the old cron/sidecar: a background task calls `process_due`
//! on a tick, executing every order whose `next_run` has passed as a
//! fee-aware ledger charge. Insufficient funds skip the cycle (the order
//! stays active and retries next interval).

use crate::error::AppError;
use crate::ledger;
use crate::policy::FeePolicy;
use crate::util::{now, random_hex};
use sqlx::SqlitePool;

#[derive(Debug, Clone, serde::Serialize)]
pub struct StandingOrder {
    pub id: String,
    pub from_account: String,
    pub to_account: String,
    pub amount_msat: i64,
    pub interval_secs: i64,
    pub next_run: i64,
    pub last_run: Option<i64>,
    pub active: bool,
}

pub async fn create(
    pool: &SqlitePool,
    from: &str,
    to: &str,
    amount_msat: i64,
    interval_secs: i64,
) -> Result<String, AppError> {
    if amount_msat <= 0 || interval_secs <= 0 {
        return Err(AppError::BadRequest(
            "amount_msat and interval_secs must be positive".into(),
        ));
    }
    let id = format!("so_{}", random_hex(10));
    let next_run = now() + interval_secs;
    sqlx::query(
        "INSERT INTO standing_orders \
         (id, from_account, to_account, amount_msat, interval_secs, next_run, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    )
    .bind(&id)
    .bind(from)
    .bind(to)
    .bind(amount_msat)
    .bind(interval_secs)
    .bind(next_run)
    .bind(now())
    .execute(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    Ok(id)
}

type SoRow = (String, String, String, i64, i64, i64, Option<i64>, i64);

pub async fn list(pool: &SqlitePool, account: &str) -> Result<Vec<StandingOrder>, AppError> {
    let rows: Vec<SoRow> = sqlx::query_as(
        "SELECT id, from_account, to_account, amount_msat, interval_secs, next_run, last_run, active \
         FROM standing_orders WHERE from_account = ?1 ORDER BY created_at DESC",
    )
    .bind(account)
    .fetch_all(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    Ok(rows
        .into_iter()
        .map(
            |(
                id,
                from_account,
                to_account,
                amount_msat,
                interval_secs,
                next_run,
                last_run,
                active,
            )| {
                StandingOrder {
                    id,
                    from_account,
                    to_account,
                    amount_msat,
                    interval_secs,
                    next_run,
                    last_run,
                    active: active != 0,
                }
            },
        )
        .collect())
}

pub async fn owner(pool: &SqlitePool, id: &str) -> Result<String, AppError> {
    let row: Option<(String,)> =
        sqlx::query_as("SELECT from_account FROM standing_orders WHERE id = ?1")
            .bind(id)
            .fetch_optional(pool)
            .await
            .map_err(|_| AppError::Backend)?;
    Ok(row.ok_or(AppError::NotFound)?.0)
}

pub async fn cancel(pool: &SqlitePool, id: &str) -> Result<(), AppError> {
    let res = sqlx::query("UPDATE standing_orders SET active = 0 WHERE id = ?1 AND active = 1")
        .bind(id)
        .execute(pool)
        .await
        .map_err(|_| AppError::Backend)?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(())
}

/// Execute all due orders as of `now_ts`. Returns the count that paid.
/// Each order's `next_run` advances by its interval whether or not the
/// charge succeeded (a skipped cycle is not retried until next interval).
pub async fn process_due(pool: &SqlitePool, fee: FeePolicy, now_ts: i64) -> Result<u32, AppError> {
    let due: Vec<(String, String, String, i64, i64)> = sqlx::query_as(
        "SELECT id, from_account, to_account, amount_msat, interval_secs \
         FROM standing_orders WHERE active = 1 AND next_run <= ?1",
    )
    .bind(now_ts)
    .fetch_all(pool)
    .await
    .map_err(|_| AppError::Backend)?;

    let mut paid = 0u32;
    for (id, from, to, amount, interval) in due {
        let fee_msat = fee.fee(amount);
        match ledger::charge(
            pool,
            &from,
            &to,
            amount,
            fee_msat,
            &format!("standing order {id}"),
        )
        .await
        {
            Ok(_) => {
                paid += 1;
                let _ = sqlx::query(
                    "UPDATE standing_orders SET next_run = ?1, last_run = ?2 WHERE id = ?3",
                )
                .bind(now_ts + interval)
                .bind(now_ts)
                .bind(&id)
                .execute(pool)
                .await;
            }
            Err(_) => {
                // Insufficient funds (or other) — skip this cycle.
                let _ = sqlx::query("UPDATE standing_orders SET next_run = ?1 WHERE id = ?2")
                    .bind(now_ts + interval)
                    .bind(&id)
                    .execute(pool)
                    .await;
            }
        }
    }
    Ok(paid)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Db;

    fn free() -> FeePolicy {
        FeePolicy {
            base_msat: 0,
            ppm: 0,
        }
    }

    async fn seed(db: &Db, id: &str, bal: i64) {
        sqlx::query("INSERT INTO accounts (id, created_at, label) VALUES (?1, ?2, '')")
            .bind(id)
            .bind(now())
            .execute(&db.pool)
            .await
            .unwrap();
        if bal > 0 {
            ledger::credit_external(&db.pool, id, bal, "seed")
                .await
                .unwrap();
        }
    }

    #[tokio::test]
    async fn due_order_executes_and_advances() {
        let db = Db::memory().await.unwrap();
        seed(&db, "alice", 10_000).await;
        seed(&db, "bob", 0).await;
        let id = create(&db.pool, "alice", "bob", 1_000, 86_400)
            .await
            .unwrap();

        // Not due yet.
        assert_eq!(process_due(&db.pool, free(), now()).await.unwrap(), 0);
        // Force it due.
        let paid = process_due(&db.pool, free(), now() + 100_000)
            .await
            .unwrap();
        assert_eq!(paid, 1);
        assert_eq!(ledger::balance(&db.pool, "bob").await.unwrap(), 1_000);

        let orders = list(&db.pool, "alice").await.unwrap();
        assert_eq!(orders.len(), 1);
        assert!(orders[0].last_run.is_some());

        // Cancel stops further runs.
        cancel(&db.pool, &id).await.unwrap();
        assert_eq!(
            process_due(&db.pool, free(), now() + 1_000_000)
                .await
                .unwrap(),
            0
        );
    }

    #[tokio::test]
    async fn insufficient_funds_skips_but_keeps_order() {
        let db = Db::memory().await.unwrap();
        seed(&db, "alice", 500).await;
        seed(&db, "bob", 0).await;
        create(&db.pool, "alice", "bob", 1_000, 3_600)
            .await
            .unwrap();
        // Due but underfunded -> 0 paid, order still active.
        assert_eq!(
            process_due(&db.pool, free(), now() + 10_000).await.unwrap(),
            0
        );
        assert!(list(&db.pool, "alice").await.unwrap()[0].active);
    }
}
