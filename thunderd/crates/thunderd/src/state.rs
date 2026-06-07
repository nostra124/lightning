//! Shared application state handed to every handler.

use crate::config::Config;
use crate::db::Db;
use std::sync::Arc;
use std::time::Instant;

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<Config>,
    pub db: Db,
    pub started: Instant,
}

impl AppState {
    #[cfg(test)]
    pub fn for_test(db: Db) -> Self {
        Self {
            config: Arc::new(Config::default()),
            db,
            started: Instant::now(),
        }
    }
}
