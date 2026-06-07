//! Passkey / WebAuthn registration + authentication (FEAT-222, folded
//! into thunderd per the auth-in-the-daemon decision).
//!
//! A wallet-user registers a passkey (the device holds the private key),
//! then logs in with it; a successful login mints a session bearer
//! (`st_…`) stored hashed in `sessions`. Challenge state between the
//! begin/finish round-trips is held in-process (short-lived); persisted
//! credentials live in `webauthn_credentials`.

use crate::error::AppError;
use crate::util::{now, random_hex};
use sqlx::SqlitePool;
use webauthn_rs::prelude::*;

/// Build the relying-party instance from config.
pub fn build(rp_id: &str, rp_origin: &str) -> anyhow::Result<Webauthn> {
    let origin = Url::parse(rp_origin)?;
    Ok(WebauthnBuilder::new(rp_id, &origin)?.build()?)
}

/// Begin registration: mints a wallet-user and returns the creation
/// challenge plus an opaque registration-session id to echo back.
pub async fn register_begin(
    webauthn: &Webauthn,
    pool: &SqlitePool,
    name: &str,
) -> Result<(String, Uuid, CreationChallengeResponse, PasskeyRegistration), AppError> {
    let user_id = format!("usr_{}", random_hex(10));
    let user_uuid = Uuid::new_v4();
    sqlx::query("INSERT INTO wallet_users (id, created_at, label) VALUES (?1, ?2, ?3)")
        .bind(&user_id)
        .bind(now())
        .bind(name)
        .execute(pool)
        .await
        .map_err(|_| AppError::Backend)?;

    let (ccr, reg) = webauthn
        .start_passkey_registration(user_uuid, name, name, None)
        .map_err(|_| AppError::Internal)?;
    Ok((user_id, user_uuid, ccr, reg))
}

/// Finish registration: verify the attestation and persist the credential.
pub async fn register_finish(
    webauthn: &Webauthn,
    pool: &SqlitePool,
    user_id: &str,
    reg: &PasskeyRegistration,
    cred: &RegisterPublicKeyCredential,
) -> Result<(), AppError> {
    let passkey = webauthn
        .finish_passkey_registration(cred, reg)
        .map_err(|_| AppError::BadRequest("registration failed".into()))?;
    let cred_id = hex::encode(passkey.cred_id());
    let blob = serde_json::to_vec(&passkey).map_err(|_| AppError::Internal)?;
    sqlx::query(
        "INSERT INTO webauthn_credentials (id, user_id, public_key, created_at) \
         VALUES (?1, ?2, ?3, ?4)",
    )
    .bind(&cred_id)
    .bind(user_id)
    .bind(blob)
    .bind(now())
    .execute(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    Ok(())
}

/// All persisted passkeys for a user.
pub async fn passkeys_for(pool: &SqlitePool, user_id: &str) -> Result<Vec<Passkey>, AppError> {
    let rows: Vec<(Vec<u8>,)> =
        sqlx::query_as("SELECT public_key FROM webauthn_credentials WHERE user_id = ?1")
            .bind(user_id)
            .fetch_all(pool)
            .await
            .map_err(|_| AppError::Backend)?;
    Ok(rows
        .into_iter()
        .filter_map(|(blob,)| serde_json::from_slice::<Passkey>(&blob).ok())
        .collect())
}

/// Resolve a credential id back to its owning user.
pub async fn user_for_credential(pool: &SqlitePool, cred_id_hex: &str) -> Result<String, AppError> {
    let row: Option<(String,)> =
        sqlx::query_as("SELECT user_id FROM webauthn_credentials WHERE id = ?1")
            .bind(cred_id_hex)
            .fetch_optional(pool)
            .await
            .map_err(|_| AppError::Backend)?;
    Ok(row.ok_or(AppError::Unauthorized)?.0)
}

/// Apply the post-authentication counter bump for the used credential.
pub async fn apply_auth_result(
    pool: &SqlitePool,
    result: &AuthenticationResult,
) -> Result<(), AppError> {
    let cred_id = hex::encode(result.cred_id());
    if result.needs_update() {
        let row: Option<(Vec<u8>,)> =
            sqlx::query_as("SELECT public_key FROM webauthn_credentials WHERE id = ?1")
                .bind(&cred_id)
                .fetch_optional(pool)
                .await
                .map_err(|_| AppError::Backend)?;
        if let Some((blob,)) = row {
            if let Ok(mut pk) = serde_json::from_slice::<Passkey>(&blob) {
                pk.update_credential(result);
                if let Ok(updated) = serde_json::to_vec(&pk) {
                    sqlx::query(
                        "UPDATE webauthn_credentials SET public_key = ?1, sign_count = ?2 WHERE id = ?3",
                    )
                    .bind(updated)
                    .bind(result.counter() as i64)
                    .bind(&cred_id)
                    .execute(pool)
                    .await
                    .map_err(|_| AppError::Backend)?;
                }
            }
        }
    }
    Ok(())
}

/// Mint a session bearer for a user; returns the one-time plaintext token.
pub async fn mint_session(pool: &SqlitePool, user_id: &str) -> Result<String, AppError> {
    let token = format!("st_{}", random_hex(24));
    let id = format!("sess_{}", random_hex(8));
    sqlx::query(
        "INSERT INTO sessions (id, user_id, token_hash, created_at) VALUES (?1, ?2, ?3, ?4)",
    )
    .bind(&id)
    .bind(user_id)
    .bind(crate::auth::hash_secret(&token))
    .bind(now())
    .execute(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    Ok(token)
}

/// Resolve a session bearer token to its user id.
pub async fn user_for_session(pool: &SqlitePool, token: &str) -> Result<String, AppError> {
    let th = crate::auth::hash_secret(token);
    let row: Option<(String,)> =
        sqlx::query_as("SELECT user_id FROM sessions WHERE token_hash = ?1")
            .bind(&th)
            .fetch_optional(pool)
            .await
            .map_err(|_| AppError::Backend)?;
    Ok(row.ok_or(AppError::Unauthorized)?.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Db;

    fn wa() -> Webauthn {
        build("localhost", "http://localhost:9737").unwrap()
    }

    #[tokio::test]
    async fn register_begin_mints_user_and_challenge() {
        let db = Db::memory().await.unwrap();
        let (user_id, _uuid, _ccr, _reg) =
            register_begin(&wa(), &db.pool, "alice").await.unwrap();
        // user row exists, no credentials yet.
        let (cnt,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM wallet_users WHERE id = ?1")
            .bind(&user_id)
            .fetch_one(&db.pool)
            .await
            .unwrap();
        assert_eq!(cnt, 1);
        assert!(passkeys_for(&db.pool, &user_id).await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn session_roundtrip() {
        let db = Db::memory().await.unwrap();
        sqlx::query("INSERT INTO wallet_users (id, created_at, label) VALUES ('u1', 0, 'a')")
            .execute(&db.pool)
            .await
            .unwrap();
        let token = mint_session(&db.pool, "u1").await.unwrap();
        assert!(token.starts_with("st_"));
        assert_eq!(user_for_session(&db.pool, &token).await.unwrap(), "u1");
        assert!(matches!(
            user_for_session(&db.pool, "st_bogus").await.unwrap_err(),
            AppError::Unauthorized
        ));
    }
}
