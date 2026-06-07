//! Minimal JSON-RPC client for the companion `lightningd` over its
//! `lightning-rpc` Unix socket (FEAT-300 / FEAT-309 groundwork).
//!
//! Hand-rolled on purpose: it speaks only *standard* CLN JSON-RPC, so
//! the workspace stays free of any CLN-crate (and any `lightning`-package)
//! coupling — the one-way carve-out boundary (FEAT-302). The richer call
//! surface (invoice/pay/newaddr/listfunds/waitanyinvoice) lands in
//! Phase 3; for the skeleton we only need `getinfo` for the health probe.

use anyhow::{anyhow, Context, Result};
use serde::Deserialize;
use std::path::{Path, PathBuf};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

#[derive(Debug, Clone, Deserialize)]
pub struct GetInfo {
    pub id: String,
    #[serde(default)]
    pub alias: String,
    #[serde(default)]
    pub blockheight: u64,
    #[serde(default)]
    pub version: String,
}

pub struct ClnRpc {
    socket: PathBuf,
}

impl ClnRpc {
    pub fn new(socket: &Path) -> Self {
        Self {
            socket: socket.to_path_buf(),
        }
    }

    /// One-shot JSON-RPC call. Opens a fresh connection per call — fine
    /// for the low-frequency control-plane calls the skeleton makes; a
    /// pooled/persistent connection arrives with FEAT-309.
    pub async fn call(&self, method: &str, params: serde_json::Value) -> Result<serde_json::Value> {
        let mut stream = UnixStream::connect(&self.socket)
            .await
            .with_context(|| format!("connect lightning-rpc at {}", self.socket.display()))?;

        let req = serde_json::json!({
            "jsonrpc": "2.0",
            "id": "thunderd",
            "method": method,
            "params": params,
        });
        let mut buf = serde_json::to_vec(&req)?;
        buf.push(b'\n');
        stream.write_all(&buf).await?;
        stream.flush().await?;

        // Read until the accumulated bytes parse as one JSON object.
        let mut data: Vec<u8> = Vec::with_capacity(4096);
        let mut tmp = [0u8; 4096];
        loop {
            let n = stream.read(&mut tmp).await?;
            if n == 0 {
                break;
            }
            data.extend_from_slice(&tmp[..n]);
            if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&data) {
                return Self::unwrap(v);
            }
        }
        let v: serde_json::Value =
            serde_json::from_slice(&data).context("parse lightning-rpc response")?;
        Self::unwrap(v)
    }

    fn unwrap(v: serde_json::Value) -> Result<serde_json::Value> {
        if let Some(err) = v.get("error") {
            if !err.is_null() {
                return Err(anyhow!("lightning-rpc error: {err}"));
            }
        }
        v.get("result")
            .cloned()
            .ok_or_else(|| anyhow!("lightning-rpc response had no result"))
    }

    pub async fn getinfo(&self) -> Result<GetInfo> {
        let v = self.call("getinfo", serde_json::json!({})).await?;
        serde_json::from_value(v).context("decode getinfo")
    }
}
