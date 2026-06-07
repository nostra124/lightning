//! Authentication (FEAT-304 + the folded-in identity layer).
//!
//! Decision: the auth / identity layer lives **inside `thunderd`** (not
//! deferred to a separate plugin) — see roadmap-overview.md. Two runtime
//! credential types are honoured today:
//!
//!   * `Authorization: Bearer lt_…`  — account API keys
//!   * `X-Mandate-Secret: …`         — direct-debit mandate secrets
//!
//! Both are stored only as SHA-256 hashes and compared in constant time.
//! The passkey/WebAuthn registration+login flow (the FEAT-222 wallet-user
//! layer, ported here) has its schema in `0001_init.sql` and its HTTP
//! routes scaffolded in `http`; the WebAuthn crypto wiring is the next
//! increment.

use crate::error::AppError;
use crate::state::AppState;
use axum::http::HeaderMap;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

/// SHA-256 hex digest of a secret — the at-rest form for tokens/secrets.
pub fn hash_secret(secret: &str) -> String {
    let mut h = Sha256::new();
    h.update(secret.as_bytes());
    hex::encode(h.finalize())
}

/// Constant-time string compare (equal-length hex digests in practice).
/// Part of the auth toolkit; first runtime use lands with the API-key /
/// mandate mint handlers (Phase 4).
#[allow(dead_code)]
pub fn ct_eq(a: &str, b: &str) -> bool {
    a.as_bytes().ct_eq(b.as_bytes()).into()
}

/// The authenticated caller. Fields are consumed by the business
/// handlers as their feature ports land (Phase 4).
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub enum Principal {
    ApiKey { account_id: String, key_id: String },
    Mandate { mandate_id: String },
}

fn bearer(headers: &HeaderMap) -> Option<String> {
    let v = headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?;
    let rest = v
        .strip_prefix("Bearer ")
        .or_else(|| v.strip_prefix("bearer "))?;
    let t = rest.trim();
    (!t.is_empty()).then(|| t.to_string())
}

/// Resolve the caller from request headers, or fail with 401.
pub async fn authenticate(state: &AppState, headers: &HeaderMap) -> Result<Principal, AppError> {
    if let Some(token) = bearer(headers) {
        let th = hash_secret(&token);
        let row: Option<(String, String)> = sqlx::query_as(
            "SELECT id, account_id FROM apikeys WHERE token_hash = ?1 AND revoked_at IS NULL",
        )
        .bind(&th)
        .fetch_optional(&state.db.pool)
        .await
        .map_err(|_| AppError::Backend)?;
        return match row {
            Some((key_id, account_id)) => Ok(Principal::ApiKey { account_id, key_id }),
            None => Err(AppError::Unauthorized),
        };
    }

    if let Some(secret) = headers
        .get("x-mandate-secret")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
    {
        let sh = hash_secret(&secret);
        let row: Option<(String,)> =
            sqlx::query_as("SELECT id FROM mandates WHERE secret_hash = ?1 AND revoked_at IS NULL")
                .bind(&sh)
                .fetch_optional(&state.db.pool)
                .await
                .map_err(|_| AppError::Backend)?;
        return match row {
            Some((mandate_id,)) => Ok(Principal::Mandate { mandate_id }),
            None => Err(AppError::Unauthorized),
        };
    }

    Err(AppError::Unauthorized)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_is_stable_and_hex() {
        let h = hash_secret("lt_example");
        assert_eq!(h.len(), 64);
        assert_eq!(h, hash_secret("lt_example"));
        assert_ne!(h, hash_secret("lt_other"));
    }

    #[test]
    fn ct_eq_matches_str_eq() {
        assert!(ct_eq("abc", "abc"));
        assert!(!ct_eq("abc", "abd"));
        assert!(!ct_eq("abc", "abcd"));
    }
}
