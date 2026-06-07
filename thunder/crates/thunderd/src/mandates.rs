//! Direct-debit mandates (FEAT-317).
//!
//! A mandate lets a creditor pull funds from a debtor account by
//! presenting a secret (`X-Mandate-Secret`), up to an optional per-pull
//! cap. Each pull is a fee-aware ledger charge from the debtor to the
//! creditor's account, recorded in `mandate_pulls`.

use crate::error::AppError;
use crate::ledger;
use crate::policy::FeePolicy;
use crate::util::{now, random_hex};
use sqlx::SqlitePool;

/// Create a mandate against `account_id`; returns `(mandate_id, secret)`.
/// The secret is shown once and stored only as a hash.
pub async fn create(
    pool: &SqlitePool,
    account_id: &str,
    label: &str,
    max_amount_msat: Option<i64>,
) -> Result<(String, String), AppError> {
    let id = format!("mnd_{}", random_hex(10));
    let secret = format!("ms_{}", random_hex(24));
    sqlx::query(
        "INSERT INTO mandates (id, account_id, secret_hash, label, max_amount_msat, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
    .bind(&id)
    .bind(account_id)
    .bind(crate::auth::hash_secret(&secret))
    .bind(label)
    .bind(max_amount_msat)
    .bind(now())
    .execute(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    Ok((id, secret))
}

#[derive(Debug, serde::Serialize)]
pub struct PullReceipt {
    pub pull_id: String,
    pub group_id: String,
    pub amount_msat: i64,
    pub fee_msat: i64,
}

/// Pull `amount_msat` from the mandate's debtor account into `to_account`,
/// applying the operator fee. Enforces the per-pull cap and active state.
pub async fn charge(
    pool: &SqlitePool,
    mandate_id: &str,
    to_account: &str,
    amount_msat: i64,
    fee: FeePolicy,
) -> Result<PullReceipt, AppError> {
    if amount_msat <= 0 {
        return Err(AppError::BadRequest("amount_msat must be positive".into()));
    }

    let row: Option<(String, Option<i64>)> = sqlx::query_as(
        "SELECT account_id, max_amount_msat FROM mandates \
         WHERE id = ?1 AND revoked_at IS NULL",
    )
    .bind(mandate_id)
    .fetch_optional(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    let (debtor, cap) = row.ok_or(AppError::NotFound)?;

    if let Some(cap) = cap {
        if amount_msat > cap {
            return Err(AppError::Forbidden);
        }
    }

    let fee_msat = fee.fee(amount_msat);
    let group_id = ledger::charge(
        pool,
        &debtor,
        to_account,
        amount_msat,
        fee_msat,
        &format!("mandate {mandate_id}"),
    )
    .await?;

    let pull_id = format!("pull_{}", random_hex(8));
    sqlx::query(
        "INSERT INTO mandate_pulls (id, mandate_id, to_account, amount_msat, fee_msat, group_id, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    )
    .bind(&pull_id)
    .bind(mandate_id)
    .bind(to_account)
    .bind(amount_msat)
    .bind(fee_msat)
    .bind(&group_id)
    .bind(now())
    .execute(pool)
    .await
    .map_err(|_| AppError::Backend)?;

    Ok(PullReceipt {
        pull_id,
        group_id,
        amount_msat,
        fee_msat,
    })
}

/// The account a mandate debits (for ownership checks).
pub async fn account_of(pool: &SqlitePool, mandate_id: &str) -> Result<String, AppError> {
    let row: Option<(String,)> = sqlx::query_as("SELECT account_id FROM mandates WHERE id = ?1")
        .bind(mandate_id)
        .fetch_optional(pool)
        .await
        .map_err(|_| AppError::Backend)?;
    Ok(row.ok_or(AppError::NotFound)?.0)
}

pub async fn revoke(pool: &SqlitePool, mandate_id: &str) -> Result<(), AppError> {
    let res =
        sqlx::query("UPDATE mandates SET revoked_at = ?1 WHERE id = ?2 AND revoked_at IS NULL")
            .bind(now())
            .bind(mandate_id)
            .execute(pool)
            .await
            .map_err(|_| AppError::Backend)?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(())
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

    fn free() -> FeePolicy {
        FeePolicy {
            base_msat: 0,
            ppm: 0,
        }
    }

    #[tokio::test]
    async fn charge_pulls_within_cap_and_records() {
        let db = Db::memory().await.unwrap();
        seed(&db, "debtor", 10_000).await;
        seed(&db, "creditor", 0).await;
        let (mid, _secret) = create(&db.pool, "debtor", "rent", Some(5_000))
            .await
            .unwrap();

        let r = charge(&db.pool, &mid, "creditor", 4_000, free())
            .await
            .unwrap();
        assert_eq!(r.amount_msat, 4_000);
        assert_eq!(ledger::balance(&db.pool, "debtor").await.unwrap(), 6_000);
        assert_eq!(ledger::balance(&db.pool, "creditor").await.unwrap(), 4_000);

        // Over the cap -> forbidden.
        assert!(matches!(
            charge(&db.pool, &mid, "creditor", 6_000, free())
                .await
                .unwrap_err(),
            AppError::Forbidden
        ));
    }

    #[tokio::test]
    async fn revoked_mandate_cannot_be_charged() {
        let db = Db::memory().await.unwrap();
        seed(&db, "debtor", 10_000).await;
        seed(&db, "creditor", 0).await;
        let (mid, _s) = create(&db.pool, "debtor", "x", None).await.unwrap();
        revoke(&db.pool, &mid).await.unwrap();
        assert!(matches!(
            charge(&db.pool, &mid, "creditor", 1_000, free())
                .await
                .unwrap_err(),
            AppError::NotFound
        ));
    }

    #[tokio::test]
    async fn fee_is_skimmed_to_house() {
        let db = Db::memory().await.unwrap();
        seed(&db, "debtor", 10_000).await;
        seed(&db, "creditor", 0).await;
        let (mid, _s) = create(&db.pool, "debtor", "x", None).await.unwrap();
        let fee = FeePolicy {
            base_msat: 100,
            ppm: 0,
        };
        let r = charge(&db.pool, &mid, "creditor", 1_000, fee)
            .await
            .unwrap();
        assert_eq!(r.fee_msat, 100);
        assert_eq!(ledger::balance(&db.pool, "debtor").await.unwrap(), 8_900);
        assert_eq!(ledger::balance(&db.pool, "house").await.unwrap(), 100);
    }
}
