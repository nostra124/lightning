//! One-shot legacy importer — `thunderd migrate` (FEAT-308).
//!
//! Reads a legacy wallet SQLite (the operator passes its path; no
//! hardcoded coupling, so the carve-out boundary holds) and copies the
//! commerce/account rows into thunderd's owned DB. Idempotent
//! (`INSERT OR IGNORE`) and re-runnable; `--dry-run` only counts.

use crate::db::Db;
use anyhow::{Context, Result};
use sqlx::sqlite::{SqliteConnectOptions, SqliteRow};
use sqlx::{Row, SqlitePool};
use std::path::Path;

#[derive(Debug, Default)]
pub struct Summary {
    pub wallet_users: u64,
    pub accounts: u64,
    pub ledger: u64,
}

pub async fn run(target: &Db, from: &Path, dry_run: bool) -> Result<Summary> {
    let src = SqlitePool::connect_with(
        SqliteConnectOptions::new()
            .filename(from)
            .read_only(true)
            .create_if_missing(false),
    )
    .await
    .with_context(|| format!("open legacy db {}", from.display()))?;

    let mut s = Summary::default();

    if let Some(rows) = try_select(
        &src,
        "SELECT id, created_at, referrer_user, label FROM wallet_users",
    )
    .await
    {
        s.wallet_users = rows.len() as u64;
        if !dry_run {
            for r in &rows {
                sqlx::query(
                    "INSERT OR IGNORE INTO wallet_users (id, created_at, referrer_user, label) \
                     VALUES (?1,?2,?3,?4)",
                )
                .bind(r.get::<String, _>(0))
                .bind(r.get::<i64, _>(1))
                .bind(r.get::<Option<String>, _>(2))
                .bind(r.get::<String, _>(3))
                .execute(&target.pool)
                .await
                .context("insert wallet_users")?;
            }
        }
    }

    if let Some(rows) = try_select(&src, "SELECT id, created_at, label FROM accounts").await {
        s.accounts = rows.len() as u64;
        if !dry_run {
            for r in &rows {
                sqlx::query(
                    "INSERT OR IGNORE INTO accounts (id, created_at, label) VALUES (?1,?2,?3)",
                )
                .bind(r.get::<String, _>(0))
                .bind(r.get::<i64, _>(1))
                .bind(r.get::<String, _>(2))
                .execute(&target.pool)
                .await
                .context("insert accounts")?;
            }
        }
    }

    if let Some(rows) = try_select(
        &src,
        "SELECT ts, group_id, account_id, counter_account, amount_msat, memo FROM ledger",
    )
    .await
    {
        s.ledger = rows.len() as u64;
        if !dry_run {
            for r in &rows {
                sqlx::query(
                    "INSERT OR IGNORE INTO ledger \
                     (ts, group_id, account_id, counter_account, amount_msat, memo) \
                     VALUES (?1,?2,?3,?4,?5,?6)",
                )
                .bind(r.get::<i64, _>(0))
                .bind(r.get::<String, _>(1))
                .bind(r.get::<String, _>(2))
                .bind(r.get::<String, _>(3))
                .bind(r.get::<i64, _>(4))
                .bind(r.get::<String, _>(5))
                .execute(&target.pool)
                .await
                .context("insert ledger")?;
            }
        }
    }

    src.close().await;
    Ok(s)
}

/// Select all rows, or `None` if the table/columns aren't present in the
/// source (logged, non-fatal) so a partial legacy schema still imports.
async fn try_select(src: &SqlitePool, sql: &str) -> Option<Vec<SqliteRow>> {
    match sqlx::query(sql).fetch_all(src).await {
        Ok(r) => Some(r),
        Err(e) => {
            tracing::warn!(error = %e, "import: skipping (table/columns not in source)");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn make_source() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("thunderd-mig-{}", crate::util::random_hex(8)));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("state.db");
        let pool = SqlitePool::connect_with(
            SqliteConnectOptions::new()
                .filename(&path)
                .create_if_missing(true),
        )
        .await
        .unwrap();
        sqlx::query(
            "CREATE TABLE wallet_users (id TEXT, created_at INTEGER, referrer_user TEXT, label TEXT)",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO wallet_users VALUES ('u1', 1, NULL, 'old user')")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("CREATE TABLE accounts (id TEXT, created_at INTEGER, label TEXT)")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO accounts VALUES ('acct_legacy', 1, 'shop')")
            .execute(&pool)
            .await
            .unwrap();
        pool.close().await;
        path
    }

    #[tokio::test]
    async fn imports_idempotently_with_dry_run() {
        let target = Db::memory().await.unwrap();
        let src = make_source().await;

        // dry-run counts but does not insert.
        let s = run(&target, &src, true).await.unwrap();
        assert_eq!(s.accounts, 1);
        assert_eq!(s.wallet_users, 1);
        let (n,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM accounts WHERE id='acct_legacy'")
            .fetch_one(&target.pool)
            .await
            .unwrap();
        assert_eq!(n, 0);

        // real run inserts; second run is a no-op (idempotent).
        run(&target, &src, false).await.unwrap();
        run(&target, &src, false).await.unwrap();
        let (n,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM accounts WHERE id='acct_legacy'")
            .fetch_one(&target.pool)
            .await
            .unwrap();
        assert_eq!(n, 1);
    }
}
