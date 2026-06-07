//! Owned SQLite state (FEAT-306, initial). The daemon owns its commerce
//! / account schema outright — no shared `state.db`, no shell-outs — which
//! is what makes the later repo extraction mechanical (design.md §4).

use anyhow::{Context, Result};
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use sqlx::SqlitePool;
use std::path::Path;

#[derive(Clone)]
pub struct Db {
    pub pool: SqlitePool,
}

impl Db {
    pub async fn connect(path: &Path) -> Result<Self> {
        let opts = SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(true)
            .journal_mode(SqliteJournalMode::Wal)
            .foreign_keys(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(5)
            .connect_with(opts)
            .await
            .with_context(|| format!("open sqlite db at {}", path.display()))?;
        Ok(Self { pool })
    }

    /// Run embedded, versioned, idempotent migrations.
    pub async fn migrate(&self) -> Result<()> {
        sqlx::migrate!("./migrations")
            .run(&self.pool)
            .await
            .context("run migrations")?;
        Ok(())
    }

    pub async fn ping(&self) -> Result<()> {
        sqlx::query("SELECT 1").execute(&self.pool).await?;
        Ok(())
    }

    /// In-memory database with migrations applied — for unit tests.
    /// A single connection so the `:memory:` db is shared across queries.
    #[cfg(test)]
    pub async fn memory() -> Result<Self> {
        use std::str::FromStr;
        let opts = SqliteConnectOptions::from_str("sqlite::memory:")?.foreign_keys(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(opts)
            .await?;
        let db = Self { pool };
        db.migrate().await?;
        Ok(db)
    }
}
