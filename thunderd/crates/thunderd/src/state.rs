//! Shared application state handed to every handler.

use crate::config::Config;
use crate::db::Db;
use crate::ratelimit::RateLimiter;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use webauthn_rs::prelude::{PasskeyAuthentication, PasskeyRegistration, Webauthn};

/// In-flight passkey registration challenge (between begin/finish).
pub struct RegState {
    pub user_id: String,
    pub reg: PasskeyRegistration,
}

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<Config>,
    pub db: Db,
    pub started: Instant,
    pub webauthn: Arc<Webauthn>,
    /// Short-lived passkey challenge state keyed by an opaque session id.
    pub reg_states: Arc<Mutex<HashMap<String, RegState>>>,
    pub auth_states: Arc<Mutex<HashMap<String, PasskeyAuthentication>>>,
    pub limiter: Arc<RateLimiter>,
}

impl AppState {
    pub fn new(config: Arc<Config>, db: Db) -> anyhow::Result<Self> {
        let webauthn = crate::passkey::build(&config.rp_id, &config.rp_origin)?;
        let limiter = RateLimiter::new(config.create_rate_per_min, Duration::from_secs(60));
        Ok(Self {
            config,
            db,
            started: Instant::now(),
            webauthn: Arc::new(webauthn),
            reg_states: Arc::new(Mutex::new(HashMap::new())),
            auth_states: Arc::new(Mutex::new(HashMap::new())),
            limiter: Arc::new(limiter),
        })
    }

    #[cfg(test)]
    pub fn for_test(db: Db) -> Self {
        let config = Arc::new(Config::default());
        Self::new(config, db).expect("build test webauthn")
    }
}
