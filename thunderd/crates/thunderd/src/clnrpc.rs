//! Minimal JSON-RPC client for the companion `lightningd` over its
//! `lightning-rpc` Unix socket (FEAT-300 / FEAT-309 groundwork).
//!
//! Hand-rolled on purpose: it speaks only *standard* CLN JSON-RPC, so
//! the workspace stays free of any CLN-crate (and any `lightning`-package)
//! coupling — the one-way carve-out boundary (FEAT-302). Covers the call
//! surface the custodial tier needs: getinfo, invoice, pay, decode, and
//! waitanyinvoice (FEAT-309/310).

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

    // ---- FEAT-309: the call surface the custodial tier needs ----------

    /// Create a BOLT-11 invoice to receive into the node.
    pub async fn invoice(
        &self,
        amount_msat: i64,
        label: &str,
        description: &str,
    ) -> Result<Invoice> {
        let v = self
            .call(
                "invoice",
                serde_json::json!({
                    "amount_msat": amount_msat,
                    "label": label,
                    "description": description,
                }),
            )
            .await?;
        serde_json::from_value(v).context("decode invoice")
    }

    /// Pay a BOLT-11 invoice from the node's funds.
    pub async fn pay(&self, bolt11: &str) -> Result<PayResult> {
        let v = self
            .call("pay", serde_json::json!({ "bolt11": bolt11 }))
            .await?;
        serde_json::from_value(v).context("decode pay")
    }

    /// Decode a BOLT-11 / BOLT-12 string.
    pub async fn decode(&self, s: &str) -> Result<Decoded> {
        let v = self
            .call("decode", serde_json::json!({ "string": s }))
            .await?;
        serde_json::from_value(v).context("decode decode")
    }

    /// Block until any invoice with `pay_index > lastpay_index` is paid
    /// (FEAT-310 settlement source). Long-lived call by design.
    pub async fn waitanyinvoice(&self, lastpay_index: u64) -> Result<PaidInvoice> {
        let v = self
            .call(
                "waitanyinvoice",
                serde_json::json!({ "lastpay_index": lastpay_index }),
            )
            .await?;
        serde_json::from_value(v).context("decode waitanyinvoice")
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct PaidInvoice {
    pub payment_hash: String,
    #[serde(default)]
    pub pay_index: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Invoice {
    pub bolt11: String,
    pub payment_hash: String,
    #[serde(default)]
    pub expires_at: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PayResult {
    pub payment_preimage: String,
    #[serde(default)]
    pub status: String,
    #[serde(default, deserialize_with = "de_msat_opt")]
    pub amount_sent_msat: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Decoded {
    #[serde(default)]
    pub payment_hash: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default, deserialize_with = "de_msat_opt")]
    pub amount_msat: Option<u64>,
    /// `decode` reports `valid: true/false`.
    #[serde(default)]
    pub valid: bool,
}

/// CLN reports msat fields as a bare integer on modern nodes, but older
/// ones (or `deprecated-apis`) emit a `"1234msat"` string. Accept both.
fn de_msat_opt<'de, D>(d: D) -> Result<Option<u64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::Deserialize as _;
    let v = serde_json::Value::deserialize(d)?;
    match v {
        serde_json::Value::Null => Ok(None),
        serde_json::Value::Number(n) => Ok(n.as_u64()),
        serde_json::Value::String(s) => {
            let digits = s.trim_end_matches("msat");
            digits
                .parse::<u64>()
                .map(Some)
                .map_err(serde::de::Error::custom)
        }
        _ => Err(serde::de::Error::custom("invalid msat value")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::UnixListener;

    /// Spin a one-shot fake lightning-rpc that returns `result_json`,
    /// and capture the request the client sent.
    async fn mock_node(
        result_json: serde_json::Value,
    ) -> (
        std::path::PathBuf,
        tokio::task::JoinHandle<String>,
        tempdir::TempLike,
    ) {
        let dir = tempdir::TempLike::new();
        let sock = dir.path.join("lightning-rpc");
        let listener = UnixListener::bind(&sock).unwrap();
        let handle = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buf = vec![0u8; 4096];
            let n = stream.read(&mut buf).await.unwrap();
            let req = String::from_utf8_lossy(&buf[..n]).to_string();
            let resp = serde_json::json!({
                "jsonrpc": "2.0",
                "id": "thunderd",
                "result": result_json,
            });
            let mut bytes = serde_json::to_vec(&resp).unwrap();
            bytes.push(b'\n');
            stream.write_all(&bytes).await.unwrap();
            stream.flush().await.unwrap();
            req
        });
        (sock, handle, dir)
    }

    #[tokio::test]
    async fn invoice_roundtrip_and_request_shape() {
        let (sock, handle, _dir) = mock_node(serde_json::json!({
            "bolt11": "lnbc1...",
            "payment_hash": "deadbeef",
            "expires_at": 1234,
        }))
        .await;
        let rpc = ClnRpc::new(&sock);
        let inv = rpc.invoice(5000, "lbl", "desc").await.unwrap();
        assert_eq!(inv.bolt11, "lnbc1...");
        assert_eq!(inv.payment_hash, "deadbeef");
        let req = handle.await.unwrap();
        assert!(req.contains("\"method\":\"invoice\""));
        assert!(req.contains("\"amount_msat\":5000"));
    }

    #[tokio::test]
    async fn decode_accepts_integer_and_string_msat() {
        // integer form
        let (sock, h, _d) = mock_node(serde_json::json!({
            "valid": true, "payment_hash": "ab", "amount_msat": 4200,
        }))
        .await;
        let got = ClnRpc::new(&sock).decode("lnbc...").await.unwrap();
        assert_eq!(got.amount_msat, Some(4200));
        assert!(got.valid);
        h.await.unwrap();

        // string "Nmsat" form
        let (sock2, h2, _d2) = mock_node(serde_json::json!({
            "valid": true, "amount_msat": "4200msat",
        }))
        .await;
        let got2 = ClnRpc::new(&sock2).decode("lnbc...").await.unwrap();
        assert_eq!(got2.amount_msat, Some(4200));
        h2.await.unwrap();
    }

    #[tokio::test]
    async fn surfaces_rpc_errors() {
        let dir = tempdir::TempLike::new();
        let sock = dir.path.join("lightning-rpc");
        let listener = UnixListener::bind(&sock).unwrap();
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buf = vec![0u8; 1024];
            let _ = stream.read(&mut buf).await.unwrap();
            let resp = br#"{"jsonrpc":"2.0","id":"thunderd","error":{"code":-1,"message":"boom"}}"#;
            stream.write_all(resp).await.unwrap();
            stream.flush().await.unwrap();
        });
        let err = ClnRpc::new(&sock).getinfo().await.unwrap_err();
        assert!(err.to_string().contains("boom"));
    }
}

/// Minimal temp-dir helper (avoids a tempfile dependency).
#[cfg(test)]
pub mod tempdir {
    pub struct TempLike {
        pub path: std::path::PathBuf,
    }
    impl TempLike {
        pub fn new() -> Self {
            let p =
                std::env::temp_dir().join(format!("thunderd-test-{}", crate::util::random_hex(8)));
            std::fs::create_dir_all(&p).unwrap();
            Self { path: p }
        }
    }
    impl Drop for TempLike {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }
}
