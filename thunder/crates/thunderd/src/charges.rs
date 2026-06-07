//! Auth/capture charge lifecycle (FEAT-318).
//!
//! `authorize` holds the payer's funds in the `escrow` system account.
//! `capture` releases (up to) the held amount to the merchant and voids
//! any uncaptured remainder back to the payer. `void` returns the whole
//! hold. `refund` moves captured funds back from merchant to payer. The
//! ledger keeps every leg balanced; escrow nets to zero per charge.

use crate::error::AppError;
use crate::ledger;
use crate::util::{now, random_hex};
use sqlx::SqlitePool;

#[derive(Debug, Clone, serde::Serialize)]
pub struct Charge {
    pub id: String,
    pub payer_account: String,
    pub merchant_account: String,
    pub amount_msat: i64,
    pub captured_msat: i64,
    pub refunded_msat: i64,
    pub status: String,
}

async fn load(pool: &SqlitePool, id: &str) -> Result<Charge, AppError> {
    let row: Option<(String, String, String, i64, i64, i64, String)> = sqlx::query_as(
        "SELECT id, payer_account, merchant_account, amount_msat, captured_msat, refunded_msat, status \
         FROM commerce_charges WHERE id = ?1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    let (id, payer_account, merchant_account, amount_msat, captured_msat, refunded_msat, status) =
        row.ok_or(AppError::NotFound)?;
    Ok(Charge {
        id,
        payer_account,
        merchant_account,
        amount_msat,
        captured_msat,
        refunded_msat,
        status,
    })
}

/// Authorize: hold `amount_msat` of the payer's balance in escrow.
pub async fn authorize(
    pool: &SqlitePool,
    payer: &str,
    merchant: &str,
    amount_msat: i64,
) -> Result<Charge, AppError> {
    if amount_msat <= 0 {
        return Err(AppError::BadRequest("amount_msat must be positive".into()));
    }
    let id = format!("chg_{}", random_hex(10));
    ledger::transfer(
        pool,
        payer,
        "escrow",
        amount_msat,
        &format!("authorize {id}"),
    )
    .await?;
    let ts = now();
    sqlx::query(
        "INSERT INTO commerce_charges \
         (id, payer_account, merchant_account, amount_msat, created_at, updated_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
    )
    .bind(&id)
    .bind(payer)
    .bind(merchant)
    .bind(amount_msat)
    .bind(ts)
    .execute(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    load(pool, &id).await
}

/// Capture (up to) the held amount to the merchant; void the remainder.
pub async fn capture(
    pool: &SqlitePool,
    id: &str,
    amount_msat: Option<i64>,
) -> Result<Charge, AppError> {
    let c = load(pool, id).await?;
    if c.status != "authorized" {
        return Err(AppError::BadRequest(format!(
            "charge is {}, not authorized",
            c.status
        )));
    }
    let capture_amt = amount_msat.unwrap_or(c.amount_msat);
    if capture_amt <= 0 || capture_amt > c.amount_msat {
        return Err(AppError::BadRequest("invalid capture amount".into()));
    }
    ledger::transfer(
        pool,
        "escrow",
        &c.merchant_account,
        capture_amt,
        &format!("capture {id}"),
    )
    .await?;
    let remainder = c.amount_msat - capture_amt;
    if remainder > 0 {
        ledger::transfer(
            pool,
            "escrow",
            &c.payer_account,
            remainder,
            &format!("void rem {id}"),
        )
        .await?;
    }
    sqlx::query(
        "UPDATE commerce_charges SET captured_msat = ?1, status = 'captured', updated_at = ?2 WHERE id = ?3",
    )
    .bind(capture_amt)
    .bind(now())
    .bind(id)
    .execute(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    load(pool, id).await
}

/// Void an authorized charge — release the whole hold back to the payer.
pub async fn void(pool: &SqlitePool, id: &str) -> Result<Charge, AppError> {
    let c = load(pool, id).await?;
    if c.status != "authorized" {
        return Err(AppError::BadRequest(format!(
            "charge is {}, cannot void",
            c.status
        )));
    }
    ledger::transfer(
        pool,
        "escrow",
        &c.payer_account,
        c.amount_msat,
        &format!("void {id}"),
    )
    .await?;
    sqlx::query("UPDATE commerce_charges SET status = 'voided', updated_at = ?1 WHERE id = ?2")
        .bind(now())
        .bind(id)
        .execute(pool)
        .await
        .map_err(|_| AppError::Backend)?;
    load(pool, id).await
}

/// Refund (part of) a captured charge from merchant back to payer.
pub async fn refund(
    pool: &SqlitePool,
    id: &str,
    amount_msat: Option<i64>,
) -> Result<Charge, AppError> {
    let c = load(pool, id).await?;
    if c.status != "captured" && c.status != "refunded" {
        return Err(AppError::BadRequest("charge is not captured".into()));
    }
    let refundable = c.captured_msat - c.refunded_msat;
    let amt = amount_msat.unwrap_or(refundable);
    if amt <= 0 || amt > refundable {
        return Err(AppError::BadRequest("invalid refund amount".into()));
    }
    ledger::transfer(
        pool,
        &c.merchant_account,
        &c.payer_account,
        amt,
        &format!("refund {id}"),
    )
    .await?;
    let refunded = c.refunded_msat + amt;
    let status = if refunded >= c.captured_msat {
        "refunded"
    } else {
        "captured"
    };
    sqlx::query("UPDATE commerce_charges SET refunded_msat = ?1, status = ?2, updated_at = ?3 WHERE id = ?4")
        .bind(refunded)
        .bind(status)
        .bind(now())
        .bind(id)
        .execute(pool)
        .await
        .map_err(|_| AppError::Backend)?;
    load(pool, id).await
}

pub async fn get(pool: &SqlitePool, id: &str) -> Result<Charge, AppError> {
    load(pool, id).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Db;

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
    async fn authorize_holds_in_escrow_then_capture_pays_merchant() {
        let db = Db::memory().await.unwrap();
        seed(&db, "payer", 10_000).await;
        seed(&db, "shop", 0).await;

        let c = authorize(&db.pool, "payer", "shop", 4_000).await.unwrap();
        assert_eq!(c.status, "authorized");
        assert_eq!(ledger::balance(&db.pool, "payer").await.unwrap(), 6_000);
        assert_eq!(ledger::balance(&db.pool, "escrow").await.unwrap(), 4_000);

        // partial capture: 3000 to merchant, 1000 back to payer.
        let c = capture(&db.pool, &c.id, Some(3_000)).await.unwrap();
        assert_eq!(c.status, "captured");
        assert_eq!(c.captured_msat, 3_000);
        assert_eq!(ledger::balance(&db.pool, "shop").await.unwrap(), 3_000);
        assert_eq!(ledger::balance(&db.pool, "payer").await.unwrap(), 7_000);
        assert_eq!(ledger::balance(&db.pool, "escrow").await.unwrap(), 0);
    }

    #[tokio::test]
    async fn void_returns_the_hold() {
        let db = Db::memory().await.unwrap();
        seed(&db, "payer", 5_000).await;
        seed(&db, "shop", 0).await;
        let c = authorize(&db.pool, "payer", "shop", 2_000).await.unwrap();
        void(&db.pool, &c.id).await.unwrap();
        assert_eq!(ledger::balance(&db.pool, "payer").await.unwrap(), 5_000);
        assert_eq!(ledger::balance(&db.pool, "escrow").await.unwrap(), 0);
        // double void rejected.
        assert!(matches!(
            void(&db.pool, &c.id).await.unwrap_err(),
            AppError::BadRequest(_)
        ));
    }

    #[tokio::test]
    async fn refund_moves_back_to_payer() {
        let db = Db::memory().await.unwrap();
        seed(&db, "payer", 5_000).await;
        seed(&db, "shop", 0).await;
        let c = authorize(&db.pool, "payer", "shop", 2_000).await.unwrap();
        let c = capture(&db.pool, &c.id, None).await.unwrap();
        assert_eq!(c.captured_msat, 2_000);
        let c = refund(&db.pool, &c.id, Some(500)).await.unwrap();
        assert_eq!(c.refunded_msat, 500);
        assert_eq!(c.status, "captured"); // partial
        let c = refund(&db.pool, &c.id, None).await.unwrap();
        assert_eq!(c.status, "refunded");
        assert_eq!(ledger::balance(&db.pool, "payer").await.unwrap(), 5_000);
        assert_eq!(ledger::balance(&db.pool, "shop").await.unwrap(), 0);
    }

    #[tokio::test]
    async fn cannot_authorize_more_than_balance() {
        let db = Db::memory().await.unwrap();
        seed(&db, "payer", 1_000).await;
        seed(&db, "shop", 0).await;
        assert!(matches!(
            authorize(&db.pool, "payer", "shop", 2_000)
                .await
                .unwrap_err(),
            AppError::PaymentRequired
        ));
    }
}
