//! Embedded HTTP server (FEAT-303) + routing/auth parity scaffold
//! (FEAT-304/305). axum/hyper, loopback-bound; CORS scaffold; request
//! body limit; health + discovery; stub handlers return 501 until the
//! business features land (Phase 4).

use crate::auth::{self, Principal};
use crate::clnrpc::ClnRpc;
use crate::error::AppError;
use crate::state::AppState;
use crate::state::RegState;
use crate::util::random_hex;
use crate::{accounts, charges, compliance, invoices, ledger, mandates, passkey, standing_orders};
use axum::extract::{DefaultBodyLimit, Path, Query, State};
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::json;
use std::net::SocketAddr;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use webauthn_rs::prelude::{PublicKeyCredential, RegisterPublicKeyCredential};

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
        .route("/accounts/{id}/mandates", post(create_mandate))
        .route("/accounts/{id}/history", get(get_history))
        .route("/accounts/{id}/history.csv", get(get_history_csv))
        .route("/accounts/{id}/charges", post(authorize_charge))
        .route(
            "/accounts/{id}/standing-orders",
            get(list_standing_orders).post(create_standing_order),
        )
        .route("/standing-orders/{id}/cancel", post(cancel_standing_order))
        .route("/invoices/{id}", get(get_invoice))
        .route("/charges/{id}", get(get_charge))
        .route("/charges/{id}/capture", post(capture_charge))
        .route("/charges/{id}/void", post(void_charge))
        .route("/charges/{id}/refund", post(refund_charge))
        .route("/mandates/charge", post(mandate_charge))
        .route("/mandates/{id}/revoke", post(revoke_mandate))
        .route("/pay", post(pay))
        // Passkey / WebAuthn identity (folded into thunderd, FEAT-222).
        .route("/auth/passkey/register/begin", post(passkey_register_begin))
        .route(
            "/auth/passkey/register/finish",
            post(passkey_register_finish),
        )
        .route("/auth/passkey/login/begin", post(passkey_login_begin))
        .route("/auth/passkey/login/finish", post(passkey_login_finish))
        .route("/auth/me", get(auth_me))
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
    #[serde(default)]
    capability: Option<String>,
}

/// Create an account + mint its first API key (returned once).
/// Rate-limited (FEAT-324); capability profile per FEAT-323.
async fn create_account(
    State(st): State<AppState>,
    body: Option<Json<CreateAccountBody>>,
) -> Result<impl IntoResponse, AppError> {
    if !st.limiter.allow("create") {
        return Err(AppError::TooManyRequests);
    }
    let b = body.map(|b| b.0).unwrap_or(CreateAccountBody {
        label: String::new(),
        capability: None,
    });
    let capability = b.capability.as_deref().unwrap_or("custodial");
    let made = accounts::create(&st.db.pool, &b.label, capability).await?;
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
    let fee_msat = st.config.fee_policy().fee(body.amount_msat);
    let group_id = ledger::charge(
        &st.db.pool,
        from,
        &body.to,
        body.amount_msat,
        fee_msat,
        &body.memo,
    )
    .await?;
    let balance_msat = ledger::balance(&st.db.pool, from).await?;
    Ok(Json(json!({
        "group_id": group_id,
        "fee_msat": fee_msat,
        "balance_msat": balance_msat,
    })))
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

    // Compliance pre-hook (FEAT-322): veto + audit before any spend.
    compliance::gate(
        &st.db.pool,
        &id,
        "-",
        amount,
        "send",
        st.config.compliance_max_msat,
    )
    .await?;

    let fee_msat = st.config.fee_policy().fee(amount);
    // Pre-flight funds check incl. the operator fee (ledger::charge
    // re-checks atomically before booking).
    if ledger::balance(&st.db.pool, &id).await? < amount + fee_msat {
        return Err(AppError::PaymentRequired);
    }

    let res = rpc.pay(&body.bolt11).await.map_err(|_| AppError::Backend)?;

    let memo = format!(
        "pay {}: {}",
        dec.payment_hash.unwrap_or_default(),
        dec.description.unwrap_or_default()
    );
    ledger::charge(&st.db.pool, &id, "-", amount, fee_msat, &memo).await?;

    let balance_msat = ledger::balance(&st.db.pool, &id).await?;
    Ok(Json(json!({
        "payment_preimage": res.payment_preimage,
        "amount_sent_msat": res.amount_sent_msat,
        "status": res.status,
        "fee_msat": fee_msat,
        "balance_msat": balance_msat,
    })))
}

// ---- history / export (FEAT-319) --------------------------------------

#[derive(Deserialize)]
struct HistoryQuery {
    #[serde(default)]
    limit: Option<i64>,
}

async fn get_history(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Query(q): Query<HistoryQuery>,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    require_account(&p, &id)?;
    let limit = q.limit.unwrap_or(100).clamp(1, 1000);
    let entries = ledger::history(&st.db.pool, &id, limit).await?;
    Ok(Json(json!({ "account": id, "entries": entries })))
}

async fn get_history_csv(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Query(q): Query<HistoryQuery>,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    require_account(&p, &id)?;
    let limit = q.limit.unwrap_or(1000).clamp(1, 10_000);
    let entries = ledger::history(&st.db.pool, &id, limit).await?;
    let mut csv = String::from("ts,group_id,counter_account,amount_msat,memo\n");
    for e in entries {
        csv.push_str(&format!(
            "{},{},{},{},{}\n",
            e.ts,
            e.group_id,
            e.counter_account,
            e.amount_msat,
            csv_field(&e.memo),
        ));
    }
    Ok((
        [(axum::http::header::CONTENT_TYPE, "text/csv; charset=utf-8")],
        csv,
    ))
}

/// RFC-4180 CSV field quoting.
fn csv_field(s: &str) -> String {
    if s.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

// ---- standing orders (FEAT-316) ---------------------------------------

#[derive(Deserialize)]
struct CreateStandingOrderBody {
    to: String,
    amount_msat: i64,
    interval_secs: i64,
}

async fn create_standing_order(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(body): Json<CreateStandingOrderBody>,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    require_account(&p, &id)?;
    accounts::get(&st.db.pool, &body.to).await?;
    let so_id = standing_orders::create(
        &st.db.pool,
        &id,
        &body.to,
        body.amount_msat,
        body.interval_secs,
    )
    .await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({ "standing_order_id": so_id })),
    ))
}

async fn list_standing_orders(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    require_account(&p, &id)?;
    Ok(Json(json!({
        "orders": standing_orders::list(&st.db.pool, &id).await?
    })))
}

async fn cancel_standing_order(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    let owner = standing_orders::owner(&st.db.pool, &id).await?;
    require_account(&p, &owner)?;
    standing_orders::cancel(&st.db.pool, &id).await?;
    Ok(Json(json!({ "standing_order_id": id, "cancelled": true })))
}

// ---- charges: auth/capture lifecycle (FEAT-318) -----------------------

#[derive(Deserialize)]
struct AuthorizeChargeBody {
    merchant: String,
    amount_msat: i64,
}

/// Payer authorizes a hold to a merchant (escrow). Caller = payer.
async fn authorize_charge(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(body): Json<AuthorizeChargeBody>,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    require_account(&p, &id)?;
    accounts::get(&st.db.pool, &body.merchant).await?;
    let c = charges::authorize(&st.db.pool, &id, &body.merchant, body.amount_msat).await?;
    Ok((StatusCode::CREATED, Json(c)))
}

#[derive(Deserialize, Default)]
struct CaptureBody {
    #[serde(default)]
    amount_msat: Option<i64>,
}

/// Merchant captures (part of) a hold.
async fn capture_charge(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    body: Option<Json<CaptureBody>>,
) -> Result<impl IntoResponse, AppError> {
    let c = charges::get(&st.db.pool, &id).await?;
    let p = auth::authenticate(&st, &headers).await?;
    require_account(&p, &c.merchant_account)?;
    let amt = body.and_then(|b| b.0.amount_msat);
    Ok(Json(charges::capture(&st.db.pool, &id, amt).await?))
}

/// Merchant or payer voids an authorized hold.
async fn void_charge(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let c = charges::get(&st.db.pool, &id).await?;
    let p = auth::authenticate(&st, &headers).await?;
    let who = require_api_key(&p)?;
    if who != c.merchant_account && who != c.payer_account {
        return Err(AppError::Forbidden);
    }
    Ok(Json(charges::void(&st.db.pool, &id).await?))
}

/// Merchant refunds (part of) a captured charge.
async fn refund_charge(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    body: Option<Json<CaptureBody>>,
) -> Result<impl IntoResponse, AppError> {
    let c = charges::get(&st.db.pool, &id).await?;
    let p = auth::authenticate(&st, &headers).await?;
    require_account(&p, &c.merchant_account)?;
    let amt = body.and_then(|b| b.0.amount_msat);
    Ok(Json(charges::refund(&st.db.pool, &id, amt).await?))
}

async fn get_charge(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let c = charges::get(&st.db.pool, &id).await?;
    let p = auth::authenticate(&st, &headers).await?;
    let who = require_api_key(&p)?;
    if who != c.merchant_account && who != c.payer_account {
        return Err(AppError::Forbidden);
    }
    Ok(Json(c))
}

// ---- mandates / direct debit (FEAT-317) -------------------------------

#[derive(Deserialize, Default)]
struct CreateMandateBody {
    #[serde(default)]
    label: String,
    #[serde(default)]
    max_amount_msat: Option<i64>,
}

/// Create a direct-debit mandate against the caller's account; returns
/// the secret once.
async fn create_mandate(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    body: Option<Json<CreateMandateBody>>,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    require_account(&p, &id)?;
    let b = body.map(|x| x.0).unwrap_or_default();
    let (mandate_id, secret) =
        mandates::create(&st.db.pool, &id, &b.label, b.max_amount_msat).await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "mandate_id": mandate_id,
            "secret": secret,
            "max_amount_msat": b.max_amount_msat,
        })),
    ))
}

#[derive(Deserialize)]
struct MandateChargeBody {
    to: String,
    amount_msat: i64,
}

/// Pull funds via a mandate. Authenticated by `X-Mandate-Secret`.
async fn mandate_charge(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<MandateChargeBody>,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    let mandate_id = match &p {
        Principal::Mandate { mandate_id } => mandate_id.clone(),
        _ => return Err(AppError::Forbidden),
    };
    // Destination must exist.
    accounts::get(&st.db.pool, &body.to).await?;
    // Compliance pre-hook (FEAT-322).
    let debtor = mandates::account_of(&st.db.pool, &mandate_id).await?;
    compliance::gate(
        &st.db.pool,
        &debtor,
        &body.to,
        body.amount_msat,
        "mandate_charge",
        st.config.compliance_max_msat,
    )
    .await?;
    let receipt = mandates::charge(
        &st.db.pool,
        &mandate_id,
        &body.to,
        body.amount_msat,
        st.config.fee_policy(),
    )
    .await?;
    Ok(Json(receipt))
}

/// Revoke a mandate. The account owner (bearer) must own it.
async fn revoke_mandate(
    State(st): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let p = auth::authenticate(&st, &headers).await?;
    let owner = mandates::account_of(&st.db.pool, &id).await?;
    require_account(&p, &owner)?;
    mandates::revoke(&st.db.pool, &id).await?;
    Ok(Json(json!({ "mandate_id": id, "revoked": true })))
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

// ---- passkey / WebAuthn (FEAT-222) ------------------------------------

#[derive(Deserialize)]
struct RegisterBeginBody {
    name: String,
}

async fn passkey_register_begin(
    State(st): State<AppState>,
    Json(body): Json<RegisterBeginBody>,
) -> Result<impl IntoResponse, AppError> {
    if !st.limiter.allow("register") {
        return Err(AppError::TooManyRequests);
    }
    if body.name.trim().is_empty() {
        return Err(AppError::BadRequest("name required".into()));
    }
    let (user_id, _uuid, ccr, reg) =
        passkey::register_begin(&st.webauthn, &st.db.pool, &body.name).await?;
    let session = format!("reg_{}", random_hex(12));
    st.reg_states.lock().unwrap().insert(
        session.clone(),
        RegState {
            user_id: user_id.clone(),
            reg,
        },
    );
    Ok(Json(json!({
        "session": session,
        "user_id": user_id,
        "challenge": ccr,
    })))
}

#[derive(Deserialize)]
struct RegisterFinishBody {
    session: String,
    credential: RegisterPublicKeyCredential,
}

async fn passkey_register_finish(
    State(st): State<AppState>,
    Json(body): Json<RegisterFinishBody>,
) -> Result<impl IntoResponse, AppError> {
    let RegState { user_id, reg } = st
        .reg_states
        .lock()
        .unwrap()
        .remove(&body.session)
        .ok_or_else(|| AppError::BadRequest("unknown or expired session".into()))?;
    passkey::register_finish(&st.webauthn, &st.db.pool, &user_id, &reg, &body.credential).await?;
    Ok(Json(json!({ "user_id": user_id, "registered": true })))
}

#[derive(Deserialize)]
struct LoginBeginBody {
    user_id: String,
}

async fn passkey_login_begin(
    State(st): State<AppState>,
    Json(body): Json<LoginBeginBody>,
) -> Result<impl IntoResponse, AppError> {
    let passkeys = passkey::passkeys_for(&st.db.pool, &body.user_id).await?;
    if passkeys.is_empty() {
        return Err(AppError::Unauthorized);
    }
    let (rcr, auth) = st
        .webauthn
        .start_passkey_authentication(&passkeys)
        .map_err(|_| AppError::Internal)?;
    let session = format!("auth_{}", random_hex(12));
    st.auth_states.lock().unwrap().insert(session.clone(), auth);
    Ok(Json(json!({ "session": session, "challenge": rcr })))
}

#[derive(Deserialize)]
struct LoginFinishBody {
    session: String,
    credential: PublicKeyCredential,
}

async fn passkey_login_finish(
    State(st): State<AppState>,
    Json(body): Json<LoginFinishBody>,
) -> Result<impl IntoResponse, AppError> {
    let auth = st
        .auth_states
        .lock()
        .unwrap()
        .remove(&body.session)
        .ok_or_else(|| AppError::BadRequest("unknown or expired session".into()))?;
    let result = st
        .webauthn
        .finish_passkey_authentication(&body.credential, &auth)
        .map_err(|_| AppError::Unauthorized)?;
    passkey::apply_auth_result(&st.db.pool, &result).await?;
    let user_id = passkey::user_for_credential(&st.db.pool, &hex::encode(result.cred_id())).await?;
    let session_token = passkey::mint_session(&st.db.pool, &user_id).await?;
    Ok(Json(
        json!({ "user_id": user_id, "session_token": session_token }),
    ))
}

/// Resolve the current wallet-user from a session bearer (`st_…`).
async fn auth_me(
    State(st): State<AppState>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, AppError> {
    let token = auth::bearer(&headers).ok_or(AppError::Unauthorized)?;
    let user_id = passkey::user_for_session(&st.db.pool, &token).await?;
    Ok(Json(json!({ "user_id": user_id })))
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
