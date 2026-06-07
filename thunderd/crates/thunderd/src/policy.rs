//! Operator policy (FEAT-321 fee skim, more to come in FEAT-322/323).
//!
//! The fee model mirrors the bash verbs: a flat base plus a ppm rate,
//! skimmed to the `house` system account on outbound money-moves.

#[derive(Debug, Clone, Copy)]
pub struct FeePolicy {
    pub base_msat: i64,
    pub ppm: i64,
}

impl FeePolicy {
    /// Fee charged on top of `amount_msat`.
    pub fn fee(&self, amount_msat: i64) -> i64 {
        let rate = (amount_msat as i128 * self.ppm as i128 / 1_000_000) as i64;
        (self.base_msat + rate).max(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fee_is_base_plus_ppm() {
        let p = FeePolicy {
            base_msat: 1_000,
            ppm: 5_000,
        }; // 0.5%
        assert_eq!(p.fee(0), 1_000);
        assert_eq!(p.fee(1_000_000), 1_000 + 5_000);
    }

    #[test]
    fn zero_policy_is_free() {
        let p = FeePolicy {
            base_msat: 0,
            ppm: 0,
        };
        assert_eq!(p.fee(123_456), 0);
    }
}
