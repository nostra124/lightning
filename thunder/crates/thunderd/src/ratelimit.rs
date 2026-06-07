//! Fixed-window rate limiter (FEAT-324).
//!
//! In-process, keyed counters with a sliding reset — enough to blunt
//! account-create / auth-begin abuse on a single-process daemon. Not a
//! distributed limiter; that's a later concern.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub struct RateLimiter {
    max: u32,
    window: Duration,
    buckets: Mutex<HashMap<String, (Instant, u32)>>,
}

impl RateLimiter {
    pub fn new(max: u32, window: Duration) -> Self {
        Self {
            max,
            window,
            buckets: Mutex::new(HashMap::new()),
        }
    }

    /// Record a hit for `key`; returns false when the window quota is
    /// already spent. `max == 0` disables limiting (always allows).
    pub fn allow(&self, key: &str) -> bool {
        if self.max == 0 {
            return true;
        }
        let now = Instant::now();
        let mut g = self.buckets.lock().unwrap();
        let e = g.entry(key.to_string()).or_insert((now, 0));
        if now.duration_since(e.0) > self.window {
            *e = (now, 0);
        }
        if e.1 >= self.max {
            false
        } else {
            e.1 += 1;
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enforces_quota_within_window() {
        let rl = RateLimiter::new(3, Duration::from_secs(60));
        assert!(rl.allow("k"));
        assert!(rl.allow("k"));
        assert!(rl.allow("k"));
        assert!(!rl.allow("k")); // 4th in window denied
                                 // Different key has its own bucket.
        assert!(rl.allow("other"));
    }

    #[test]
    fn window_resets() {
        let rl = RateLimiter::new(1, Duration::from_millis(20));
        assert!(rl.allow("k"));
        assert!(!rl.allow("k"));
        std::thread::sleep(Duration::from_millis(30));
        assert!(rl.allow("k"));
    }

    #[test]
    fn zero_max_disables() {
        let rl = RateLimiter::new(0, Duration::from_secs(1));
        for _ in 0..1000 {
            assert!(rl.allow("k"));
        }
    }
}
