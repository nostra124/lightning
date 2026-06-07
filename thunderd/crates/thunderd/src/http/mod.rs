//! Embedded HTTP server (FEAT-303) + routing/auth parity scaffold
//! (FEAT-304/305). axum/hyper, loopback-bound; CORS scaffold; request
//! body limit; health + discovery; stub handlers return 501 until the
//! business features land (Phase 4).

use crate::auth;
use crate::clnrpc::ClnRpc;
use crate::error::AppError;
use crate::state::AppState;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::json;
use std::net::SocketAddr;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;

pub async fn serve(state: AppState) -> anyhow::Result<()> {
    let cfg = state.config.clone();

    // Routes served under the (proxy-stripped) base path.
    let api = Router::new()
        .route("/health", get(health))
        .route("/versions.json", get(versions))
        // Custodial surface — auth-gated, 501 until Phase 4 (FEAT-313+).
        .route("/accounts", get(stub_protected).post(stub_protected))
        // Passkey / WebAuthn identity (folded into thunderd) — schema in
        // 0001_init.sql; crypto wiring is the next increment.
        .route("/auth/passkey/register/begin", post(stub_open))
        .route("/auth/passkey/register/finish", post(stub_open))
        .route("/auth/passkey/login/begin", post(stub_open))
        .route("/auth/passkey/login/finish", post(stub_open))
        .fallback(not_found);

    let app = Router::new()
        .nest(&cfg.base_path, api)
        .fallback(not_found)
        .layer(DefaultBodyLimit::max(cfg.body_limit))
        .layer(cors_layer(&cfg.cors_origin))
        .layer(TraceLayer::new_for_http())
        .with_state(state.clone());

    let addr = SocketAddr::new(cfg.http_bind, cfg.http_port);
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!(%addr, base = %cfg.base_path, "thunderd HTTP listening");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

/// CORS scaffold (FEAT-303). `*` → permissive any-origin; otherwise an
/// explicit allow-list. Tighten per deployment.
fn cors_layer(origins: &[String]) -> CorsLayer {
    let base = CorsLayer::new()
        .allow_methods([Method::GET, Method::POST, Method::OPTIONS])
        .allow_headers(Any);
    if origins.iter().any(|o| o == "*") {
        base.allow_origin(Any)
    } else {
        let parsed: Vec<HeaderValue> = origins
            .iter()
            .filter_map(|o| o.parse::<HeaderValue>().ok())
            .collect();
        base.allow_origin(parsed)
    }
}

async fn health(State(st): State<AppState>) -> impl IntoResponse {
    let db_ok = st.db.ping().await.is_ok();
    let cln = ClnRpc::new(&st.config.cln_socket).getinfo().await.ok();
    let cln_ok = cln.is_some();
    let status = if db_ok {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    let overall = match (db_ok, cln_ok) {
        (true, true) => "healthy",
        (true, false) => "degraded",
        _ => "down",
    };
    let body = json!({
        "service": "thunderd",
        "status": overall,
        "version": env!("CARGO_PKG_VERSION"),
        "uptime_s": st.started.elapsed().as_secs(),
        "db": db_ok,
        "cln": {
            "connected": cln_ok,
            "id": cln.as_ref().map(|i| i.id.clone()),
            "alias": cln.as_ref().map(|i| i.alias.clone()),
            "blockheight": cln.as_ref().map(|i| i.blockheight),
        },
    });
    (status, Json(body))
}

async fn versions(State(st): State<AppState>) -> impl IntoResponse {
    Json(json!({
        "service": "thunderd",
        "namespace": st.config.base_path,
        "versions": ["v1"],
        "tiers": ["custodial"],
    }))
}

/// Auth-gated placeholder: proves the bearer / mandate-secret gate works
/// (401 without creds) and returns 501 once authenticated.
async fn stub_protected(
    State(st): State<AppState>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let _principal = auth::authenticate(&st, &headers).await?;
    Err::<Json<serde_json::Value>, _>(AppError::NotImplemented)
}

async fn stub_open() -> AppError {
    AppError::NotImplemented
}

async fn not_found() -> AppError {
    AppError::NotFound
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut sig) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            sig.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
    tracing::info!("shutdown signal received");
}
