//! Daemon configuration (design.md §3.1).
//!
//! Resolved from CLI flags / environment with sensible localhost
//! defaults — the HTTP listener is bound to loopback and TLS is
//! terminated by the reverse proxy (Apache/nginx), never here.

use clap::Args;
use std::net::{IpAddr, Ipv4Addr};
use std::path::PathBuf;

/// CLI-facing options. Flattened into the binary's arg parser.
#[derive(Args, Debug, Clone)]
pub struct ConfigArgs {
    /// HTTP listener address (loopback only by default).
    #[arg(
        long = "http-bind",
        env = "THUNDERD_HTTP_BIND",
        default_value = "127.0.0.1"
    )]
    pub http_bind: IpAddr,

    /// HTTP listener port.
    #[arg(long = "http-port", env = "THUNDERD_HTTP_PORT", default_value_t = 9737)]
    pub http_port: u16,

    /// Path to the owned SQLite state file (created if missing).
    #[arg(long = "db", env = "THUNDERD_DB", default_value = "thunderd.sqlite3")]
    pub db_path: PathBuf,

    /// Public path prefix the reverse proxy strips; used for self-links.
    #[arg(
        long = "base-path",
        env = "THUNDERD_BASE_PATH",
        default_value = "/.well-known/thunder/v1"
    )]
    pub base_path: String,

    /// Path to the companion lightningd `lightning-rpc` Unix socket.
    #[arg(
        long = "cln-socket",
        env = "THUNDERD_CLN_SOCKET",
        default_value = "lightning-rpc"
    )]
    pub cln_socket: PathBuf,

    /// CORS allowed origin(s). Repeatable. `*` allows any origin
    /// (scaffold default; tighten per deployment). Empty disables CORS.
    #[arg(
        long = "cors-origin",
        env = "THUNDERD_CORS_ORIGIN",
        value_delimiter = ','
    )]
    pub cors_origin: Vec<String>,

    /// Max request body size in bytes.
    #[arg(long = "body-limit", env = "THUNDERD_BODY_LIMIT", default_value_t = 64 * 1024)]
    pub body_limit: usize,

    /// Operator fee base (msat) skimmed to `house` on outbound pays.
    #[arg(
        long = "fee-base-msat",
        env = "THUNDERD_FEE_BASE_MSAT",
        default_value_t = 0
    )]
    pub fee_base_msat: i64,

    /// Operator fee rate (parts-per-million) on outbound pays.
    #[arg(long = "fee-ppm", env = "THUNDERD_FEE_PPM", default_value_t = 0)]
    pub fee_ppm: i64,
}

/// Resolved, validated configuration.
#[derive(Debug, Clone)]
pub struct Config {
    pub http_bind: IpAddr,
    pub http_port: u16,
    pub db_path: PathBuf,
    pub base_path: String,
    pub cln_socket: PathBuf,
    pub cors_origin: Vec<String>,
    pub body_limit: usize,
    pub fee_base_msat: i64,
    pub fee_ppm: i64,
}

impl Config {
    pub fn fee_policy(&self) -> crate::policy::FeePolicy {
        crate::policy::FeePolicy {
            base_msat: self.fee_base_msat,
            ppm: self.fee_ppm,
        }
    }

    pub fn from_args(a: ConfigArgs) -> anyhow::Result<Self> {
        let mut base_path = a.base_path;
        if !base_path.starts_with('/') {
            base_path.insert(0, '/');
        }
        // Trailing slash would make axum nest paths awkward.
        while base_path.len() > 1 && base_path.ends_with('/') {
            base_path.pop();
        }
        // CORS scaffold default: allow any origin so the thunder-pay PWA
        // can talk to a dev daemon out of the box. Lock down in prod.
        let cors_origin = if a.cors_origin.is_empty() {
            vec!["*".to_string()]
        } else {
            a.cors_origin
        };
        Ok(Self {
            http_bind: a.http_bind,
            http_port: a.http_port,
            db_path: a.db_path,
            base_path,
            cln_socket: a.cln_socket,
            cors_origin,
            body_limit: a.body_limit,
            fee_base_msat: a.fee_base_msat,
            fee_ppm: a.fee_ppm,
        })
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            http_bind: IpAddr::V4(Ipv4Addr::LOCALHOST),
            http_port: 9737,
            db_path: PathBuf::from("thunderd.sqlite3"),
            base_path: "/.well-known/thunder/v1".to_string(),
            cln_socket: PathBuf::from("lightning-rpc"),
            cors_origin: vec!["*".to_string()],
            body_limit: 64 * 1024,
            fee_base_msat: 0,
            fee_ppm: 0,
        }
    }
}
