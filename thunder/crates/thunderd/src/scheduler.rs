//! Background runner for standing orders (FEAT-316). Ticks periodically
//! and executes any due recurring transfers.

use crate::standing_orders;
use crate::state::AppState;
use crate::util::now;
use std::time::Duration;

pub fn spawn(state: AppState) {
    tokio::spawn(run(state));
}

async fn run(state: AppState) {
    let tick = Duration::from_secs(30);
    tracing::info!("standing-order runner started");
    loop {
        tokio::time::sleep(tick).await;
        match standing_orders::process_due(&state.db.pool, state.config.fee_policy(), now()).await {
            Ok(n) if n > 0 => tracing::info!(count = n, "standing orders executed"),
            Ok(_) => {}
            Err(e) => tracing::warn!(error = ?e, "standing-order run failed"),
        }
    }
}
