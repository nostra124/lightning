//! Settlement reconciliation (FEAT-310).
//!
//! A background task that follows the node's `waitanyinvoice` stream and
//! books each newly-paid invoice to the owning account's ledger via
//! `invoices::settle` (idempotent). Resumes from index 0 on boot — since
//! settle is a no-op for already-paid hashes, replaying is safe; a
//! persisted `pay_index` is a later refinement.

use crate::clnrpc::ClnRpc;
use crate::invoices;
use crate::state::AppState;
use std::time::Duration;

pub fn spawn(state: AppState) {
    tokio::spawn(run(state));
}

async fn run(state: AppState) {
    let rpc = ClnRpc::new(&state.config.cln_socket);
    let mut last: u64 = 0;
    tracing::info!("settlement reconciler started");
    loop {
        match rpc.waitanyinvoice(last).await {
            Ok(inv) => {
                if inv.pay_index > last {
                    last = inv.pay_index;
                }
                match invoices::settle(&state.db.pool, &inv.payment_hash).await {
                    Ok(true) => tracing::info!(hash = %inv.payment_hash, "invoice settled"),
                    Ok(false) => {}
                    Err(e) => tracing::warn!(error = ?e, hash = %inv.payment_hash, "settle failed"),
                }
            }
            Err(e) => {
                // Node down / not reachable yet — back off and retry.
                tracing::debug!(error = %e, "waitanyinvoice unavailable; retrying");
                tokio::time::sleep(Duration::from_secs(3)).await;
            }
        }
    }
}
