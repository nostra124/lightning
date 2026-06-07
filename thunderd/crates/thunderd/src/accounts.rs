//! Account lifecycle + API-key minting (FEAT-313, initial).
//!
//! An account is a custodial msat balance; its balance is derived from
//! the ledger (see `ledger.rs`), never stored here. API keys are returned
//! exactly once at mint time and stored only as a SHA-256 hash.

use crate::auth::hash_secret;
use crate::error::AppError;
use crate::util::{now, random_hex};
use sqlx::SqlitePool;

#[derive(Debug, Clone, serde::Serialize)]
pub struct Account {
    pub id: String,
    pub label: String,
    pub capability: String,
    pub created_at: i64,
    pub closed_at: Option<i64>,
}

/// Freshly-minted account plus the one-time plaintext API key.
#[derive(Debug, serde::Serialize)]
pub struct NewAccount {
    #[serde(flatten)]
    pub account: Account,
    pub api_key: String,
}

/// Capability profiles / fund-class gates (FEAT-323).
pub const VALID_CAPABILITIES: &[&str] = &["custodial", "treasury", "family", "prepaid"];

/// Create an account and mint its first API key. The plaintext key is
/// returned once and never recoverable. `capability` must be one of
/// [`VALID_CAPABILITIES`].
pub async fn create(
    pool: &SqlitePool,
    label: &str,
    capability: &str,
) -> Result<NewAccount, AppError> {
    if !VALID_CAPABILITIES.contains(&capability) {
        return Err(AppError::BadRequest(format!(
            "unknown capability '{capability}' (one of: {})",
            VALID_CAPABILITIES.join(", ")
        )));
    }
    let id = format!("acct_{}", random_hex(10));
    let ts = now();
    sqlx::query("INSERT INTO accounts (id, created_at, label, capability) VALUES (?1, ?2, ?3, ?4)")
        .bind(&id)
        .bind(ts)
        .bind(label)
        .bind(capability)
        .execute(pool)
        .await
        .map_err(|_| AppError::Backend)?;

    let api_key = mint_api_key(pool, &id, "default").await?;

    Ok(NewAccount {
        account: Account {
            id,
            label: label.to_string(),
            capability: capability.to_string(),
            created_at: ts,
            closed_at: None,
        },
        api_key,
    })
}

/// Mint an additional API key for an existing account; returns the
/// one-time plaintext token (`lt_…`).
pub async fn mint_api_key(
    pool: &SqlitePool,
    account_id: &str,
    label: &str,
) -> Result<String, AppError> {
    let token = format!("lt_{}", random_hex(24));
    let key_id = format!("key_{}", random_hex(8));
    sqlx::query(
        "INSERT INTO apikeys (id, account_id, token_hash, label, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5)",
    )
    .bind(&key_id)
    .bind(account_id)
    .bind(hash_secret(&token))
    .bind(label)
    .bind(now())
    .execute(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    Ok(token)
}

pub async fn get(pool: &SqlitePool, id: &str) -> Result<Account, AppError> {
    let row: Option<(String, String, String, i64, Option<i64>)> = sqlx::query_as(
        "SELECT id, label, capability, created_at, closed_at FROM accounts WHERE id = ?1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    match row {
        Some((id, label, capability, created_at, closed_at)) => Ok(Account {
            id,
            label,
            capability,
            created_at,
            closed_at,
        }),
        None => Err(AppError::NotFound),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::{authenticate, Principal};
    use crate::db::Db;
    use axum::http::HeaderMap;

    #[tokio::test]
    async fn create_then_authenticate_with_minted_key() {
        let db = Db::memory().await.unwrap();
        let st = crate::state::AppState::for_test(db.clone());

        let made = create(&db.pool, "shop", "custodial").await.unwrap();
        assert!(made.api_key.starts_with("lt_"));
        assert_eq!(get(&db.pool, &made.account.id).await.unwrap().label, "shop");

        // The minted key authenticates back to its account.
        let mut h = HeaderMap::new();
        h.insert(
            "authorization",
            format!("Bearer {}", made.api_key).parse().unwrap(),
        );
        match authenticate(&st, &h).await.unwrap() {
            Principal::ApiKey { account_id, .. } => assert_eq!(account_id, made.account.id),
            other => panic!("expected ApiKey, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn unknown_account_is_not_found() {
        let db = Db::memory().await.unwrap();
        assert!(matches!(
            get(&db.pool, "acct_nope").await.unwrap_err(),
            AppError::NotFound
        ));
    }

    #[tokio::test]
    async fn rejects_unknown_capability() {
        let db = Db::memory().await.unwrap();
        assert!(matches!(
            create(&db.pool, "x", "wildcat").await.unwrap_err(),
            AppError::BadRequest(_)
        ));
    }
}
