//! Small dependency-free helpers.

use std::io::Read;

/// `n` bytes of CSPRNG output as a lowercase hex string. Reads
/// `/dev/urandom` (the daemon is unix-only) — avoids pulling a rand
/// crate for the handful of tokens/ids we mint.
pub fn random_hex(n: usize) -> String {
    let mut buf = vec![0u8; n];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        if f.read_exact(&mut buf).is_ok() {
            return hex::encode(buf);
        }
    }
    // Fallback (should never hit on a real deployment): time + address mix.
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let salt = &nanos as *const _ as usize;
    format!("{nanos:x}{salt:x}")
}

/// Seconds since the Unix epoch.
pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or_default()
}
