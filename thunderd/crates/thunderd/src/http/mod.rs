//! Embedded HTTP server (FEAT-303) + routing/auth parity scaffold
//! (FEAT-304/305). axum/hyper, loopback-bound; CORS scaffold; request
//! body limit; health + discovery; stub handlers return 501 until the
//! business features land (Phase 4).

use crate::auth::{self, Principal};
use crate::clnrpc::ClnRpc;
use crate::error::AppError;
use crate::state::AppState;
use crate::util::random_hex;
use crate::{accounts, invoices, ledger};
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
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
        // Custodial surface (FEAT-313/314).
        .route("/accounts", post(create_account))
        .route("/accounts/{id}", get(get_account))
        .route("/accounts/{id}/topup", post(topup_account))
        .route("/accounts/{id}/invoice", post(create_invoice))
        .route("/accounts/{id}/send", post(send))
        .route("/invoices/{id}", get(get_invoice))
        .route("/pay", post(pay))
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

// ---- account / payment handlers (custodial tier) ----------------------

#[derive(Deserialize)]
struct CreateAccountBody {
    #[serde(default)]
    label: String,
}

/// Create a custodial account + mint its first API key (returned once).
/// Open for now; invite-gating + rate-limit land with FEAT-320/324.
async fn create_account(
    State(st): State<AppState>,
    body: Option<Json<CreateAccountBody>>,
) -> Result<impl IntoResponse, AppError> {
    let label = body.map(|b| b.0.label).unwrap_or_default();
    let made = accounts::create(&st.db.pool, &label).await?;
    Ok((StatusCode::CREATED, Json(made)))
}

/// Account info + derived balance. Bearer must own the account.
async fn get_account(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    require_account(&p, &id)?;
    let account = accounts::get(&st.db.pool, &id).await?;
    let balance_msat = ledger::balance(&st.db.pool, &id).await?;
    Ok(Json(
        json!({ "account": account, "balance_msat": balance_msat }),
    ))
}

#[derive(Deserialize)]
struct AmountBody {
    amount_msat: i64,
}

/// Dev/admin topup: credit the account from the external world without a
/// real settlement. Replaced by invoice-settlement booking (FEAT-309/310).
async fn topup_account(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(body): Json<AmountBody>,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    require_account(&p, &id)?;
    if body.amount_msat <= 0 {
        return Err(AppError::BadRequest("amount_msat must be positive".into()));
    }
    ledger::credit_external(&st.db.pool, &id, body.amount_msat, "topup (dev)").await?;
    let balance_msat = ledger::balance(&st.db.pool, &id).await?;
    Ok(Json(json!({ "balance_msat": balance_msat })))
}

#[derive(Deserialize)]
struct PayBody {
    to: String,
    amount_msat: i64,
    #[serde(default)]
    memo: String,
}

/// Internal custodial transfer from the caller's account to another
/// account. External Lightning payment (decode + cln `pay`) lands with
/// FEAT-309/314.
async fn pay(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<PayBody>,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    let from = require_api_key(&p)?;
    // 404 if the destination doesn't exist.
    accounts::get(&st.db.pool, &body.to).await?;
    let group_id =
        ledger::transfer(&st.db.pool, from, &body.to, body.amount_msat, &body.memo).await?;
    let balance_msat = ledger::balance(&st.db.pool, from).await?;
    Ok(Json(
        json!({ "group_id": group_id, "balance_msat": balance_msat }),
    ))
}

#[derive(Deserialize)]
struct CreateInvoiceBody {
    amount_msat: i64,
    #[serde(default)]
    description: String,
}

/// Receive: issue a BOLT-11 invoice via the node for this account
/// (FEAT-314 recv). Settlement is booked by FEAT-310's reconciler.
async fn create_invoice(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(body): Json<CreateInvoiceBody>,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    require_account(&p, &id)?;
    if body.amount_msat <= 0 {
        return Err(AppError::BadRequest("amount_msat must be positive".into()));
    }
    let inv_id = format!("inv_{}", random_hex(10));
    let rpc = ClnRpc::new(&st.config.cln_socket);
    let inv = rpc
        .invoice(body.amount_msat, &inv_id, &body.description)
        .await
        .map_err(|_| AppError::Backend)?;
    invoices::record(
        &st.db.pool,
        &inv_id,
        &id,
        &inv.payment_hash,
        &inv_id,
        &inv.bolt11,
        body.amount_msat,
        &body.description,
        inv.expires_at,
    )
    .await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "invoice_id": inv_id,
            "bolt11": inv.bolt11,
            "payment_hash": inv.payment_hash,
            "amount_msat": body.amount_msat,
            "expires_at": inv.expires_at,
        })),
    ))
}

async fn get_invoice(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    let rec = invoices::get(&st.db.pool, &id).await?;
    require_account(&p, &rec.account_id)?;
    Ok(Json(rec))
}

#[derive(Deserialize)]
struct SendBody {
    bolt11: String,
}

/// Send: pay an external BOLT-11 from this account's custodial balance
/// (FEAT-314). Decodes for the amount, checks funds, pays via the node,
/// then books the debit to the ledger.
async fn send(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(body): Json<SendBody>,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    require_account(&p, &id)?;
    let rpc = ClnRpc::new(&st.config.cln_socket);

    let dec = rpc
        .decode(&body.bolt11)
        .await
        .map_err(|_| AppError::Backend)?;
    if !dec.valid {
        return Err(AppError::BadRequest("invalid invoice".into()));
    }
    let amount = dec
        .amount_msat
        .ok_or_else(|| AppError::BadRequest("amountless invoices are not supported".into()))?
        as i64;

    // Pre-flight funds check (the ledger transfer re-checks atomically).
    if ledger::balance(&st.db.pool, &id).await? < amount {
        return Err(AppError::PaymentRequired);
    }

    let res = rpc.pay(&body.bolt11).await.map_err(|_| AppError::Backend)?;

    let memo = format!(
        "pay {}: {}",
        dec.payment_hash.unwrap_or_default(),
        dec.description.unwrap_or_default()
    );
    ledger::transfer(&st.db.pool, &id, "-", amount, &memo).await?;

    let balance_msat = ledger::balance(&st.db.pool, &id).await?;
    Ok(Json(json!({
        "payment_preimage": res.payment_preimage,
        "amount_sent_msat": res.amount_sent_msat,
        "status": res.status,
        "balance_msat": balance_msat,
    })))
}

/// The caller must present an account API key.
fn require_api_key(p: &Principal) -> Result<&str, AppError> {
    match p {
        Principal::ApiKey { account_id, .. } => Ok(account_id),
        _ => Err(AppError::Forbidden),
    }
}

/// The caller's API key must belong to `account_id`.
fn require_account(p: &Principal, account_id: &str) -> Result<(), AppError> {
    match require_api_key(p)? == account_id {
        true => Ok(()),
        false => Err(AppError::Forbidden),
    }
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
