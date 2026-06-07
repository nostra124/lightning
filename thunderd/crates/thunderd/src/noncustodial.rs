//! Phase II non-custodial — tenant + remote-signer transport (FEAT-400+).
//!
//! This is the **A2 remote-signer transport**: the daemon holds only a
//! watch-only xpub and enqueues signing requests (a sighash/PSBT); the
//! user's device fetches them, signs locally, and returns the signature.
//! The seed never reaches the server.
//!
//! What is real here: tenant/xpub registration and the request→sign→
//! return queue (all DB-backed, tested). What is **not** implemented yet:
//! the per-tenant LDK node engine and PSBT/commitment *construction*
//! (FEAT-407+) that will populate these requests — those need a live
//! Lightning/on-chain engine and are stubbed at the HTTP layer (501).

use crate::error::AppError;
use crate::util::{now, random_hex};
use sqlx::SqlitePool;

#[derive(Debug, Clone, serde::Serialize)]
pub struct Tenant {
    pub id: String,
    pub user_id: Option<String>,
    pub label: String,
    pub created_at: i64,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct SignerRequest {
    pub id: String,
    pub tenant_id: String,
    pub kind: String,
    pub payload: String,
    pub status: String,
    pub signature: Option<String>,
}

pub async fn register_tenant(
    pool: &SqlitePool,
    user_id: Option<&str>,
    label: &str,
    xpub: &str,
) -> Result<String, AppError> {
    if xpub.trim().is_empty() {
        return Err(AppError::BadRequest("xpub required".into()));
    }
    let id = format!("tnt_{}", random_hex(10));
    let ts = now();
    sqlx::query("INSERT INTO tenants (id, user_id, label, created_at) VALUES (?1, ?2, ?3, ?4)")
        .bind(&id)
        .bind(user_id)
        .bind(label)
        .bind(ts)
        .execute(pool)
        .await
        .map_err(|_| AppError::Backend)?;
    sqlx::query("INSERT INTO tenant_xpubs (tenant_id, xpub, created_at) VALUES (?1, ?2, ?3)")
        .bind(&id)
        .bind(xpub)
        .bind(ts)
        .execute(pool)
        .await
        .map_err(|_| AppError::Backend)?;
    Ok(id)
}

pub async fn get_tenant(pool: &SqlitePool, id: &str) -> Result<Tenant, AppError> {
    let row: Option<(String, Option<String>, String, i64)> =
        sqlx::query_as("SELECT id, user_id, label, created_at FROM tenants WHERE id = ?1")
            .bind(id)
            .fetch_optional(pool)
            .await
            .map_err(|_| AppError::Backend)?;
    let (id, user_id, label, created_at) = row.ok_or(AppError::NotFound)?;
    Ok(Tenant {
        id,
        user_id,
        label,
        created_at,
    })
}

/// Enqueue a signing request for a tenant's device. Returns its id.
pub async fn enqueue_signing(
    pool: &SqlitePool,
    tenant_id: &str,
    kind: &str,
    payload: &str,
) -> Result<String, AppError> {
    get_tenant(pool, tenant_id).await?; // must exist
    let id = format!("sig_{}", random_hex(10));
    sqlx::query(
        "INSERT INTO signer_requests (id, tenant_id, kind, payload, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5)",
    )
    .bind(&id)
    .bind(tenant_id)
    .bind(kind)
    .bind(payload)
    .bind(now())
    .execute(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    Ok(id)
}

pub async fn pending_for(
    pool: &SqlitePool,
    tenant_id: &str,
) -> Result<Vec<SignerRequest>, AppError> {
    let rows: Vec<(String, String, String, String, String, Option<String>)> = sqlx::query_as(
        "SELECT id, tenant_id, kind, payload, status, signature FROM signer_requests \
         WHERE tenant_id = ?1 AND status = 'pending' ORDER BY created_at",
    )
    .bind(tenant_id)
    .fetch_all(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    Ok(rows
        .into_iter()
        .map(
            |(id, tenant_id, kind, payload, status, signature)| SignerRequest {
                id,
                tenant_id,
                kind,
                payload,
                status,
                signature,
            },
        )
        .collect())
}

/// The device returns a signature for a pending request.
pub async fn submit_signature(
    pool: &SqlitePool,
    request_id: &str,
    signature: &str,
) -> Result<(), AppError> {
    let res = sqlx::query(
        "UPDATE signer_requests SET status = 'signed', signature = ?1, signed_at = ?2 \
         WHERE id = ?3 AND status = 'pending'",
    )
    .bind(signature)
    .bind(now())
    .bind(request_id)
    .execute(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(())
}

/// Tenant owner (for session ownership checks).
pub async fn owner(pool: &SqlitePool, tenant_id: &str) -> Result<Option<String>, AppError> {
    Ok(get_tenant(pool, tenant_id).await?.user_id)
}

/// The tenant's (first registered) watch-only xpub.
pub async fn first_xpub(pool: &SqlitePool, tenant_id: &str) -> Result<String, AppError> {
    let row: Option<(String,)> = sqlx::query_as(
        "SELECT xpub FROM tenant_xpubs WHERE tenant_id = ?1 ORDER BY created_at LIMIT 1",
    )
    .bind(tenant_id)
    .fetch_optional(pool)
    .await
    .map_err(|_| AppError::Backend)?;
    Ok(row.ok_or(AppError::NotFound)?.0)
}

/// Tenant a signing request belongs to.
pub async fn request_tenant(pool: &SqlitePool, request_id: &str) -> Result<String, AppError> {
    let row: Option<(String,)> =
        sqlx::query_as("SELECT tenant_id FROM signer_requests WHERE id = ?1")
            .bind(request_id)
            .fetch_optional(pool)
            .await
            .map_err(|_| AppError::Backend)?;
    Ok(row.ok_or(AppError::NotFound)?.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Db;

    #[tokio::test]
    async fn tenant_and_signer_roundtrip() {
        let db = Db::memory().await.unwrap();
        sqlx::query("INSERT INTO wallet_users (id, created_at, label) VALUES ('u1', 0, '')")
            .execute(&db.pool)
            .await
            .unwrap();
        let t = register_tenant(&db.pool, Some("u1"), "phone", "xpub6Dummy")
            .await
            .unwrap();
        assert_eq!(owner(&db.pool, &t).await.unwrap().as_deref(), Some("u1"));

        let req = enqueue_signing(&db.pool, &t, "sighash", "deadbeef")
            .await
            .unwrap();
        let pending = pending_for(&db.pool, &t).await.unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].id, req);
        assert_eq!(request_tenant(&db.pool, &req).await.unwrap(), t);

        submit_signature(&db.pool, &req, "3045signature")
            .await
            .unwrap();
        assert!(pending_for(&db.pool, &t).await.unwrap().is_empty());
        // double-sign rejected.
        assert!(matches!(
            submit_signature(&db.pool, &req, "x").await.unwrap_err(),
            AppError::NotFound
        ));
    }

    #[tokio::test]
    async fn register_requires_xpub() {
        let db = Db::memory().await.unwrap();
        assert!(matches!(
            register_tenant(&db.pool, None, "x", "  ")
                .await
                .unwrap_err(),
            AppError::BadRequest(_)
        ));
    }
}
