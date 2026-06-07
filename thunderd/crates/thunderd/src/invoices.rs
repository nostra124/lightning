//! Inbound invoice records + settlement booking (FEAT-309/310/315).
//!
//! The daemon issues invoices through the node (`cln invoice`), persists
//! a record keyed by `payment_hash`, and — when the node reports the
//! invoice paid (FEAT-310 `waitanyinvoice`) — books the inbound credit
//! to the owning account's ledger exactly once.

use crate::error::AppError;
use crate::ledger;
use crate::util::now;
use sqlx::SqlitePool;

#[derive(Debug, Clone, serde::Serialize)]
pub struct InvoiceRecord {
    pub id: String,
    pub account_id: String,
    pub payment_hash: String,
    pub bolt11: String,
    pub amount_msat: i64,
    pub description: String,
    pub status: String,
    pub created_at: i64,
    pub expires_at: Option<i64>,
    pub settled_at: Option<i64>,
}

#[allow(clippy::too_many_arguments)]
pub async fn record(
    pool: &SqlitePool,
    id: &str,
    account_id: &str,
    payment_hash: &str,
    label: &str,
    bolt11: &str,
    amount_msat: i64,
    description: &str,
    expires_at: i64,
) -> Result<(), AppError> {
    sqlx::query(
        "INSERT INTO commerce_invoices \
         (id, account_id, payment_hash, label, bolt11, amount_msat, description, created_at, expires_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
    )
    .bind(id)
    .bind(account_id)
    .bind(payment_hash)
    .bind(label)
    .bind(bolt11)
    .bind(amount_msat)
    .bind(description)
    .bind(now())
    .bind(expires_at)
    .execute(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    Ok(())
}

pub async fn get(pool: &SqlitePool, id: &str) -> Result<InvoiceRecord, AppError> {
    let row: Option<InvoiceRecord> = sqlx::query_as::<
        _,
        (
            String,
            String,
            String,
            String,
            i64,
            String,
            String,
            i64,
            Option<i64>,
            Option<i64>,
        ),
    >(
        "SELECT id, account_id, payment_hash, bolt11, amount_msat, description, status, \
         created_at, expires_at, settled_at FROM commerce_invoices WHERE id = ?1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(|_| AppError::Backend)?
    .map(
        |(
            id,
            account_id,
            payment_hash,
            bolt11,
            amount_msat,
            description,
            status,
            created_at,
            expires_at,
            settled_at,
        )| {
            InvoiceRecord {
                id,
                account_id,
                payment_hash,
                bolt11,
                amount_msat,
                description,
                status,
                created_at,
                expires_at,
                settled_at,
            }
        },
    );
    row.ok_or(AppError::NotFound)
}

/// Mark an invoice paid and credit its account — idempotent: a second
/// call for an already-settled hash is a no-op. Returns true if it
/// booked a settlement this call.
pub async fn settle(pool: &SqlitePool, payment_hash: &str) -> Result<bool, AppError> {
    let row: Option<(String, String, i64)> = sqlx::query_as(
        "SELECT id, account_id, amount_msat FROM commerce_invoices \
         WHERE payment_hash = ?1 AND status = 'unpaid'",
    )
    .bind(payment_hash)
    .fetch_optional(pool)
    .await
    .map_err(|_| AppError::Backend)?;

    let Some((id, account_id, amount_msat)) = row else {
        return Ok(false);
    };

    ledger::credit_external(pool, &account_id, amount_msat, &format!("invoice {id}")).await?;
    sqlx::query("UPDATE commerce_invoices SET status = 'paid', settled_at = ?1 WHERE id = ?2")
        .bind(now())
        .bind(&id)
        .execute(pool)
        .await
        .map_err(|_| AppError::Backend)?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Db;

    async fn seed_account(db: &Db, id: &str) {
        sqlx::query("INSERT INTO accounts (id, created_at, label) VALUES (?1, ?2, '')")
            .bind(id)
            .bind(now())
            .execute(&db.pool)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn settle_credits_once_and_is_idempotent() {
        let db = Db::memory().await.unwrap();
        seed_account(&db, "alice").await;
        record(
            &db.pool, "inv_1", "alice", "hash_1", "inv_1", "lnbc...", 4200, "coffee", 0,
        )
        .await
        .unwrap();

        assert_eq!(ledger::balance(&db.pool, "alice").await.unwrap(), 0);
        assert!(settle(&db.pool, "hash_1").await.unwrap());
        assert_eq!(ledger::balance(&db.pool, "alice").await.unwrap(), 4200);
        // Second settle is a no-op (no double credit).
        assert!(!settle(&db.pool, "hash_1").await.unwrap());
        assert_eq!(ledger::balance(&db.pool, "alice").await.unwrap(), 4200);

        let rec = get(&db.pool, "inv_1").await.unwrap();
        assert_eq!(rec.status, "paid");
        assert!(rec.settled_at.is_some());
    }

    #[tokio::test]
    async fn settle_unknown_hash_is_false() {
        let db = Db::memory().await.unwrap();
        assert!(!settle(&db.pool, "nope").await.unwrap());
    }
}
