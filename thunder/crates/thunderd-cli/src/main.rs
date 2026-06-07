//! `thunderd-cli` — operator admin CLI for `thunderd` (FEAT-300).
//!
//! Skeleton ships the `health` subcommand: a minimal HTTP GET against
//! the daemon's loopback health endpoint. Tenant/account/channel admin
//! verbs land alongside their daemon features.

use anyhow::{anyhow, Context, Result};
use clap::{Parser, Subcommand};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

#[derive(Parser, Debug)]
#[command(name = "thunderd-cli", version, about = "Admin CLI for thunderd")]
struct Cli {
    /// Daemon base URL (loopback).
    #[arg(long, env = "THUNDERD_URL", default_value = "http://127.0.0.1:9737")]
    url: String,

    /// API base path (proxy-stripped prefix).
    #[arg(
        long,
        env = "THUNDERD_BASE_PATH",
        default_value = "/.well-known/thunder/v1"
    )]
    base_path: String,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Query the daemon's health endpoint.
    Health,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Health => health(&cli.url, &cli.base_path),
    }
}

fn health(base_url: &str, base_path: &str) -> Result<()> {
    let path = format!("{}/health", base_path.trim_end_matches('/'));
    let (status, body) = http_get(base_url, &path)?;
    let pretty = serde_json::from_str::<serde_json::Value>(&body)
        .ok()
        .and_then(|v| serde_json::to_string_pretty(&v).ok())
        .unwrap_or(body);
    println!("{pretty}");
    if (200..300).contains(&status) {
        Ok(())
    } else {
        Err(anyhow!("health returned HTTP {status}"))
    }
}

/// Tiny blocking HTTP/1.1 GET — enough for a loopback health check
/// without dragging in a full HTTP client (keeps the CLI lean).
fn http_get(base_url: &str, path: &str) -> Result<(u16, String)> {
    let rest = base_url
        .strip_prefix("http://")
        .ok_or_else(|| anyhow!("only http:// loopback URLs are supported, got {base_url}"))?;
    let authority = rest.trim_end_matches('/');
    let (host, port) = match authority.split_once(':') {
        Some((h, p)) => (h, p.parse::<u16>().context("parse port")?),
        None => (authority, 80),
    };

    let mut stream =
        TcpStream::connect((host, port)).with_context(|| format!("connect {host}:{port}"))?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;

    let req = format!(
        "GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\nAccept: application/json\r\n\r\n"
    );
    stream.write_all(req.as_bytes())?;
    stream.flush()?;

    let mut raw = Vec::new();
    stream.read_to_end(&mut raw)?;
    let text = String::from_utf8_lossy(&raw).into_owned();

    let (head, body) = text
        .split_once("\r\n\r\n")
        .ok_or_else(|| anyhow!("malformed HTTP response"))?;
    let status_line = head.lines().next().unwrap_or_default();
    let status = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse::<u16>().ok())
        .ok_or_else(|| anyhow!("could not parse status line: {status_line:?}"))?;
    Ok((status, body.to_string()))
}
