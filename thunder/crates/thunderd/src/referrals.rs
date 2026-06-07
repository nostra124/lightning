//! Referral split (FEAT-320).
//!
//! After an account pays an operator fee (booked to `house`), a
//! configured share is forwarded `house → referrer` so the account's
//! referrer earns a cut. System-account `house` may run negative, so the
//! split nets out to: house keeps `fee - share`, referrer gets `share`.

use crate::error::AppError;
use crate::ledger;
use sqlx::SqlitePool;

/// Forward `share_ppm` of `fee_msat` to the payer's referrer (if any).
/// Returns the msat actually credited to the referrer (0 if none).
pub async fn apply(
    pool: &SqlitePool,
    payer: &str,
    fee_msat: i64,
    share_ppm: i64,
) -> Result<i64, AppError> {
    if fee_msat <= 0 || share_ppm <= 0 {
        return Ok(0);
    }
    let row: Option<(Option<String>,)> =
        sqlx::query_as("SELECT referrer_account FROM accounts WHERE id = ?1")
            .bind(payer)
            .fetch_optional(pool)
            .await
            .map_err(|_| AppError::Backend)?;
    let Some((Some(referrer),)) = row else {
        return Ok(0);
    };
    let part = (fee_msat as i128 * share_ppm as i128 / 1_000_000) as i64;
    if part <= 0 {
        return Ok(0);
    }
    ledger::transfer(
        pool,
        "house",
        &referrer,
        part,
        &format!("referral from {payer}"),
    )
    .await?;
    Ok(part)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::accounts;
    use crate::db::Db;

    #[tokio::test]
    async fn splits_fee_to_referrer() {
        let db = Db::memory().await.unwrap();
        let referrer = accounts::create(&db.pool, "ref", "custodial")
            .await
            .unwrap();
        let payer = accounts::create(&db.pool, "pay", "custodial")
            .await
            .unwrap();
        accounts::set_referrer(&db.pool, &payer.account.id, &referrer.account.id)
            .await
            .unwrap();

        // 50% of a 1000-msat fee.
        let part = apply(&db.pool, &payer.account.id, 1_000, 500_000)
            .await
            .unwrap();
        assert_eq!(part, 500);
        assert_eq!(
            ledger::balance(&db.pool, &referrer.account.id)
                .await
                .unwrap(),
            500
        );
        assert_eq!(ledger::balance(&db.pool, "house").await.unwrap(), -500);
    }

    #[tokio::test]
    async fn no_referrer_no_split() {
        let db = Db::memory().await.unwrap();
        let payer = accounts::create(&db.pool, "pay", "custodial")
            .await
            .unwrap();
        assert_eq!(
            apply(&db.pool, &payer.account.id, 1_000, 500_000)
                .await
                .unwrap(),
            0
        );
    }
}
