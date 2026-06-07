//! Validating remote-signer core (A2) — the device side of the
//! non-custodial tier (FEAT-400/431). Pure: validate a daemon-built PSBT
//! against a local policy, then sign it with keys derived from the seed.
//! No network, no daemon dependency — shared by the `thunder` CLI and
//! (compiled to WASM later) `thunder-pay`.
//!
//! The "validating" part is what makes A2 safe: even though the daemon
//! builds the transaction, the device independently checks it against the
//! user's policy before producing a signature.

use anyhow::{anyhow, bail, Result};
use bitcoin::bip32::{DerivationPath, Xpriv};
use bitcoin::ecdsa::Signature as EcdsaSig;
use bitcoin::hashes::Hash;
use bitcoin::secp256k1::{Message, Secp256k1};
use bitcoin::sighash::{EcdsaSighashType, SighashCache};
use bitcoin::{psbt::Psbt, CompressedPublicKey, PrivateKey, PublicKey, ScriptBuf};
use std::str::FromStr;

/// Device-side signing policy (the "validating" in validating signer).
#[derive(Debug, Clone, Default)]
pub struct Policy {
    /// Reject if any single output exceeds this (0 = no cap).
    pub max_output_sat: u64,
    /// Reject if the implied fee exceeds this (0 = no cap).
    pub max_fee_sat: u64,
}

/// Validate a PSBT against `policy`; returns the implied fee (sat).
pub fn validate(psbt_b64: &str, policy: &Policy) -> Result<u64> {
    let psbt = Psbt::from_str(psbt_b64).map_err(|e| anyhow!("parse psbt: {e}"))?;
    let mut in_total = 0u64;
    for inp in &psbt.inputs {
        let wu = inp
            .witness_utxo
            .as_ref()
            .ok_or_else(|| anyhow!("input missing witness_utxo"))?;
        in_total += wu.value.to_sat();
    }
    let mut out_total = 0u64;
    for o in &psbt.unsigned_tx.output {
        let v = o.value.to_sat();
        if policy.max_output_sat > 0 && v > policy.max_output_sat {
            bail!(
                "output {v} sat exceeds policy cap {}",
                policy.max_output_sat
            );
        }
        out_total += v;
    }
    if in_total < out_total {
        bail!("inputs do not cover outputs");
    }
    let fee = in_total - out_total;
    if policy.max_fee_sat > 0 && fee > policy.max_fee_sat {
        bail!("fee {fee} sat exceeds policy cap {}", policy.max_fee_sat);
    }
    Ok(fee)
}

/// Validate, then sign every p2wpkh input the derived keys control.
/// Returns the updated PSBT (base64) with partial signatures attached.
pub fn validate_and_sign(
    xpriv: &str,
    psbt_b64: &str,
    paths: &[String],
    policy: &Policy,
) -> Result<String> {
    validate(psbt_b64, policy)?;

    let secp = Secp256k1::new();
    let master = Xpriv::from_str(xpriv).map_err(|e| anyhow!("parse xpriv: {e}"))?;

    // Derive (pubkey, privkey, p2wpkh-script) for each requested path.
    let mut keyset: Vec<(PublicKey, PrivateKey, ScriptBuf)> = Vec::new();
    for p in paths {
        let path = DerivationPath::from_str(p).map_err(|e| anyhow!("path {p}: {e}"))?;
        let child = master
            .derive_priv(&secp, &path)
            .map_err(|e| anyhow!("derive {p}: {e}"))?;
        let sk = child.to_priv();
        let pk = sk.public_key(&secp);
        let cpk = CompressedPublicKey::try_from(pk)
            .map_err(|_| anyhow!("derived key is uncompressed"))?;
        let script = ScriptBuf::new_p2wpkh(&cpk.wpubkey_hash());
        keyset.push((pk, sk, script));
    }

    let mut psbt = Psbt::from_str(psbt_b64).map_err(|e| anyhow!("parse psbt: {e}"))?;
    let tx = psbt.unsigned_tx.clone();
    let mut cache = SighashCache::new(&tx);
    let mut signed = 0usize;

    for i in 0..psbt.inputs.len() {
        let Some(wu) = psbt.inputs[i].witness_utxo.clone() else {
            continue;
        };
        for (pk, sk, script) in &keyset {
            if *script != wu.script_pubkey {
                continue;
            }
            let sighash = cache
                .p2wpkh_signature_hash(i, script, wu.value, EcdsaSighashType::All)
                .map_err(|e| anyhow!("sighash: {e}"))?;
            let msg = Message::from_digest(sighash.to_byte_array());
            let sig = secp.sign_ecdsa(&msg, &sk.inner);
            psbt.inputs[i].partial_sigs.insert(
                *pk,
                EcdsaSig {
                    signature: sig,
                    sighash_type: EcdsaSighashType::All,
                },
            );
            signed += 1;
            break;
        }
    }

    if signed == 0 {
        bail!("no inputs matched the derived keys");
    }
    Ok(psbt.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use bitcoin::bip32::Xpub;
    use bitcoin::{
        absolute::LockTime, transaction::Version, Address, Amount, Network, OutPoint, Sequence,
        Transaction, TxIn, TxOut, Txid, Witness,
    };

    /// Build a 1-in/1-out PSBT whose input is a p2wpkh controlled by the
    /// m/0/0 key of a fixed seed, so the signer has something to sign.
    fn fixture() -> (String, String, Vec<String>) {
        let secp = Secp256k1::new();
        let master = Xpriv::new_master(Network::Regtest, &[9u8; 32]).unwrap();
        let path = DerivationPath::from_str("m/0/0").unwrap();
        let child = master.derive_priv(&secp, &path).unwrap();
        let cpk = CompressedPublicKey(child.private_key.public_key(&secp));
        let in_spk = ScriptBuf::new_p2wpkh(&cpk.wpubkey_hash());

        // some destination
        let xpub = Xpub::from_priv(&secp, &master);
        let dest = {
            let c = xpub
                .derive_pub(&secp, &DerivationPath::from_str("m/0/1").unwrap())
                .unwrap();
            Address::p2wpkh(&CompressedPublicKey(c.public_key), Network::Regtest)
        };

        let tx = Transaction {
            version: Version::TWO,
            lock_time: LockTime::ZERO,
            input: vec![TxIn {
                previous_output: OutPoint {
                    txid: Txid::from_str(
                        "0000000000000000000000000000000000000000000000000000000000000001",
                    )
                    .unwrap(),
                    vout: 0,
                },
                script_sig: ScriptBuf::new(),
                sequence: Sequence::ENABLE_RBF_NO_LOCKTIME,
                witness: Witness::new(),
            }],
            output: vec![TxOut {
                value: Amount::from_sat(90_000),
                script_pubkey: dest.script_pubkey(),
            }],
        };
        let mut psbt = Psbt::from_unsigned_tx(tx).unwrap();
        psbt.inputs[0].witness_utxo = Some(TxOut {
            value: Amount::from_sat(100_000),
            script_pubkey: in_spk,
        });
        (
            master.to_string(),
            psbt.to_string(),
            vec!["m/0/0".to_string()],
        )
    }

    #[test]
    fn signs_a_controlled_input() {
        let (xpriv, psbt_b64, paths) = fixture();
        let signed = validate_and_sign(&xpriv, &psbt_b64, &paths, &Policy::default()).unwrap();
        let psbt = Psbt::from_str(&signed).unwrap();
        assert_eq!(
            psbt.inputs[0].partial_sigs.len(),
            1,
            "expected one signature"
        );
    }

    #[test]
    fn validate_reports_fee() {
        let (_xpriv, psbt_b64, _paths) = fixture();
        let fee = validate(&psbt_b64, &Policy::default()).unwrap();
        assert_eq!(fee, 10_000);
    }

    #[test]
    fn policy_rejects_oversized_output() {
        let (_x, psbt_b64, _p) = fixture();
        let policy = Policy {
            max_output_sat: 50_000,
            max_fee_sat: 0,
        };
        assert!(validate(&psbt_b64, &policy).is_err());
    }

    #[test]
    fn policy_rejects_high_fee() {
        let (_x, psbt_b64, _p) = fixture();
        let policy = Policy {
            max_output_sat: 0,
            max_fee_sat: 5_000,
        };
        assert!(validate(&psbt_b64, &policy).is_err());
    }
}
