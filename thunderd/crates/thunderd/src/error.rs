//! Typed errors mapped to HTTP status (design.md §5 / accounts-plugin §9).
//!
//! Preserves the legacy external status contract that the bash verbs +
//! CGI encoded as exit codes:
//!   * insufficient funds / limit  (exit 6) -> 402 Payment Required
//!   * auth failure                (exit 7) -> 401 Unauthorized
//!   * backend (lightningd) error          -> 502 Bad Gateway

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;

// Variants encode the full external status contract; some are not
// constructed until their handlers land in Phase 4.
#[allow(dead_code)]
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("payment required")]
    PaymentRequired,
    #[error("unauthorized")]
    Unauthorized,
    #[error("forbidden")]
    Forbidden,
    #[error("not found")]
    NotFound,
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("not implemented")]
    NotImplemented,
    #[error("backend error")]
    Backend,
    #[error("internal error")]
    Internal,
}

impl AppError {
    fn parts(&self) -> (StatusCode, &'static str) {
        match self {
            AppError::PaymentRequired => (StatusCode::PAYMENT_REQUIRED, "payment_required"),
            AppError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            AppError::Forbidden => (StatusCode::FORBIDDEN, "forbidden"),
            AppError::NotFound => (StatusCode::NOT_FOUND, "not_found"),
            AppError::BadRequest(_) => (StatusCode::BAD_REQUEST, "bad_request"),
            AppError::NotImplemented => (StatusCode::NOT_IMPLEMENTED, "not_implemented"),
            AppError::Backend => (StatusCode::BAD_GATEWAY, "backend_error"),
            AppError::Internal => (StatusCode::INTERNAL_SERVER_ERROR, "internal_error"),
        }
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, code) = self.parts();
        let body = Json(json!({ "error": code, "message": self.to_string() }));
        (status, body).into_response()
    }
}

#[allow(dead_code)]
pub type AppResult<T> = Result<T, AppError>;
