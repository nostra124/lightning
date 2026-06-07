//! On-chain wallet primitives (FEAT-41x) — the "fat daemon builds the
//! transaction, the device signs" half of the non-custodial tier.
//!
//! Pure construction: xpub→address derivation and unsigned-PSBT assembly
//! from supplied UTXOs. No private keys here (watch-only). UTXO discovery
//! (chain scan) and broadcast need a live node and are NOT in this module;
//! the PSBT produced here is what gets enqueued to the remote signer.

use crate::error::AppError;
use bitcoin::bip32::{DerivationPath, Xpub};
use bitcoin::secp256k1::Secp256k1;
use bitcoin::{
    absolute::LockTime, transaction::Version, Address, Amount, CompressedPublicKey, Network,
    OutPoint, PublicKey, ScriptBuf, Sequence, Transaction, TxIn, TxOut, Txid, Witness,
};
use std::str::FromStr;

/// Derive the external-chain (`m/0/index`) p2wpkh address for an xpub.
pub fn derive_address(xpub: &str, index: u32, network: Network) -> Result<String, AppError> {
    let xpub = Xpub::from_str(xpub).map_err(|_| AppError::BadRequest("invalid xpub".into()))?;
    let secp = Secp256k1::verification_only();
    let path = DerivationPath::from_str(&format!("m/0/{index}")).map_err(|_| AppError::Internal)?;
    let child = xpub
        .derive_pub(&secp, &path)
        .map_err(|_| AppError::BadRequest("derivation failed".into()))?;
    let cpk = CompressedPublicKey(child.public_key);
    Ok(Address::p2wpkh(&cpk, network).to_string())
}

/// A spendable input the caller supplies (until chain-scan lands).
pub struct InputUtxo {
    pub txid: String,
    pub vout: u32,
    pub value_sat: u64,
    /// Compressed pubkey (hex) controlling this p2wpkh utxo.
    pub pubkey_hex: String,
}

/// Build an unsigned PSBT spending `utxos` to `outputs` (address, sat).
/// Returns the base64 PSBT and the implied fee. Errors if inputs don't
/// cover outputs. Change, if any, must be an explicit output (keeps this
/// deterministic and testable).
pub fn build_psbt(
    utxos: &[InputUtxo],
    outputs: &[(String, u64)],
    network: Network,
) -> Result<(String, u64), AppError> {
    let mut tx_in = Vec::new();
    let mut witness_utxos = Vec::new();
    let mut in_total: u64 = 0;
    for u in utxos {
        let txid = Txid::from_str(&u.txid).map_err(|_| AppError::BadRequest("bad txid".into()))?;
        tx_in.push(TxIn {
            previous_output: OutPoint { txid, vout: u.vout },
            script_sig: ScriptBuf::new(),
            sequence: Sequence::ENABLE_RBF_NO_LOCKTIME,
            witness: Witness::new(),
        });
        let pk = PublicKey::from_str(&u.pubkey_hex)
            .map_err(|_| AppError::BadRequest("bad pubkey".into()))?;
        let cpk = CompressedPublicKey::try_from(pk)
            .map_err(|_| AppError::BadRequest("uncompressed pubkey".into()))?;
        witness_utxos.push(TxOut {
            value: Amount::from_sat(u.value_sat),
            script_pubkey: Address::p2wpkh(&cpk, network).script_pubkey(),
        });
        in_total += u.value_sat;
    }

    let mut tx_out = Vec::new();
    let mut out_total: u64 = 0;
    for (addr, sat) in outputs {
        let address = Address::from_str(addr)
            .map_err(|_| AppError::BadRequest("bad address".into()))?
            .require_network(network)
            .map_err(|_| AppError::BadRequest("address network mismatch".into()))?;
        tx_out.push(TxOut {
            value: Amount::from_sat(*sat),
            script_pubkey: address.script_pubkey(),
        });
        out_total += *sat;
    }

    if in_total < out_total {
        return Err(AppError::PaymentRequired);
    }
    let fee = in_total - out_total;

    let tx = Transaction {
        version: Version::TWO,
        lock_time: LockTime::ZERO,
        input: tx_in,
        output: tx_out,
    };
    let mut psbt = bitcoin::psbt::Psbt::from_unsigned_tx(tx).map_err(|_| AppError::Internal)?;
    for (i, w) in witness_utxos.into_iter().enumerate() {
        psbt.inputs[i].witness_utxo = Some(w);
    }
    Ok((psbt.to_string(), fee))
}

#[cfg(test)]
mod tests {
    use super::*;
    use bitcoin::bip32::Xpriv;

    fn test_xpub() -> (String, String) {
        // Derive a real xpub + the m/0/0 child pubkey from a fixed seed,
        // so the vectors are guaranteed valid.
        let secp = Secp256k1::new();
        let seed = [7u8; 32];
        let xpriv = Xpriv::new_master(Network::Regtest, &seed).unwrap();
        let xpub = Xpub::from_priv(&secp, &xpriv);
        let child = xpub
            .derive_pub(&secp, &DerivationPath::from_str("m/0/0").unwrap())
            .unwrap();
        (xpub.to_string(), child.public_key.to_string())
    }

    #[test]
    fn derives_a_valid_p2wpkh_address() {
        let (xpub, _) = test_xpub();
        let addr = derive_address(&xpub, 0, Network::Regtest).unwrap();
        assert!(addr.starts_with("bcrt1"), "got {addr}");
        // deterministic
        assert_eq!(addr, derive_address(&xpub, 0, Network::Regtest).unwrap());
        // different index -> different address
        assert_ne!(addr, derive_address(&xpub, 1, Network::Regtest).unwrap());
    }

    #[test]
    fn rejects_bad_xpub() {
        assert!(matches!(
            derive_address("not-an-xpub", 0, Network::Regtest).unwrap_err(),
            AppError::BadRequest(_)
        ));
    }

    #[test]
    fn builds_psbt_with_correct_fee() {
        let (xpub, pubkey_hex) = test_xpub();
        let to = derive_address(&xpub, 1, Network::Regtest).unwrap();
        let utxos = vec![InputUtxo {
            txid: "0000000000000000000000000000000000000000000000000000000000000001".into(),
            vout: 0,
            value_sat: 100_000,
            pubkey_hex,
        }];
        let (psbt_b64, fee) = build_psbt(&utxos, &[(to, 90_000)], Network::Regtest).unwrap();
        assert_eq!(fee, 10_000);
        // round-trips as a valid PSBT with 1 input + 1 output.
        let psbt = bitcoin::psbt::Psbt::from_str(&psbt_b64).unwrap();
        assert_eq!(psbt.inputs.len(), 1);
        assert_eq!(psbt.unsigned_tx.output.len(), 1);
        assert!(psbt.inputs[0].witness_utxo.is_some());
    }

    #[test]
    fn refuses_when_inputs_dont_cover_outputs() {
        let (xpub, pubkey_hex) = test_xpub();
        let to = derive_address(&xpub, 1, Network::Regtest).unwrap();
        let utxos = vec![InputUtxo {
            txid: "0000000000000000000000000000000000000000000000000000000000000001".into(),
            vout: 0,
            value_sat: 1_000,
            pubkey_hex,
        }];
        assert!(matches!(
            build_psbt(&utxos, &[(to, 90_000)], Network::Regtest).unwrap_err(),
            AppError::PaymentRequired
        ));
    }
}
