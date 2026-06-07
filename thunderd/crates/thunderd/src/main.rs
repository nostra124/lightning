//! `thunderd` — a Lightning accounts companion daemon to `lightningd`.
//!
//! Phase I skeleton (FEAT-300): config + structured logging, an owned
//! SQLite store with embedded migrations, a `cln-rpc` probe of the
//! companion `lightningd` over its Unix socket, and an embedded axum
//! HTTP server (health + discovery + auth-gated stubs). It is an
//! external companion daemon — NOT a `cln-plugin` (no `getmanifest`
//! handshake).

mod auth;
mod clnrpc;
mod config;
mod db;
mod error;
mod http;
mod logging;
mod state;

use anyhow::Context;
use clap::Parser;
use std::sync::Arc;
use std::time::Instant;

#[derive(Parser, Debug)]
#[command(
    name = "thunderd",
    version,
    about = "Lightning accounts companion daemon (custodial + non-custodial)"
)]
struct Cli {
    #[command(flatten)]
    cfg: config::ConfigArgs,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    logging::init();

    let config = Arc::new(config::Config::from_args(cli.cfg)?);
    tracing::info!(
        db = %config.db_path.display(),
        cln_socket = %config.cln_socket.display(),
        bind = %config.http_bind,
        port = config.http_port,
        "thunderd starting"
    );

    let db = db::Db::connect(&config.db_path)
        .await
        .context("connect state db")?;
    db.migrate().await.context("apply migrations")?;
    tracing::info!("state db ready (migrations applied)");

    // Probe the companion lightningd; non-fatal if it's not up yet.
    match clnrpc::ClnRpc::new(&config.cln_socket).getinfo().await {
        Ok(info) => tracing::info!(
            id = %info.id,
            alias = %info.alias,
            blockheight = info.blockheight,
            version = %info.version,
            "connected to companion lightningd"
        ),
        Err(e) => tracing::warn!(
            error = %e,
            socket = %config.cln_socket.display(),
            "could not reach lightningd at startup (continuing; retried on demand)"
        ),
    }

    let state = state::AppState {
        config,
        db,
        started: Instant::now(),
    };

    http::serve(state).await
}
