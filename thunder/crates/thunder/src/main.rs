//! `thunder` — the user's remote-signer client (non-custodial tier).
//!
//! Holds the seed locally; validates daemon-built PSBTs against a policy
//! and signs them via `signer-core`. The `sign-psbt` subcommand is the
//! offline core (the device half of A2); networked polling of a tenant's
//! pending requests builds on the same primitive.

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use signer_core::{validate, validate_and_sign, Policy};

#[derive(Parser, Debug)]
#[command(name = "thunder", version, about = "Remote-signer client for thunderd")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Validate + sign a daemon-built PSBT with keys derived from the seed.
    SignPsbt {
        /// BIP32 master xpriv (the device seed, never leaves here).
        #[arg(long)]
        xpriv: String,
        /// Base64 PSBT to sign.
        #[arg(long)]
        psbt: String,
        /// Derivation path(s) to try, e.g. m/0/0 (repeatable).
        #[arg(long = "path", default_values_t = [String::from("m/0/0")])]
        paths: Vec<String>,
        /// Reject any output above this many sats (0 = no cap).
        #[arg(long, default_value_t = 0)]
        max_output_sat: u64,
        /// Reject a fee above this many sats (0 = no cap).
        #[arg(long, default_value_t = 0)]
        max_fee_sat: u64,
    },
    /// Validate a PSBT against a policy without signing; prints the fee.
    Inspect {
        #[arg(long)]
        psbt: String,
        #[arg(long, default_value_t = 0)]
        max_output_sat: u64,
        #[arg(long, default_value_t = 0)]
        max_fee_sat: u64,
    },
}

fn main() -> Result<()> {
    match Cli::parse().cmd {
        Cmd::SignPsbt {
            xpriv,
            psbt,
            paths,
            max_output_sat,
            max_fee_sat,
        } => {
            let policy = Policy {
                max_output_sat,
                max_fee_sat,
            };
            let signed =
                validate_and_sign(&xpriv, &psbt, &paths, &policy).context("validate + sign")?;
            println!("{signed}");
            Ok(())
        }
        Cmd::Inspect {
            psbt,
            max_output_sat,
            max_fee_sat,
        } => {
            let policy = Policy {
                max_output_sat,
                max_fee_sat,
            };
            let fee = validate(&psbt, &policy).context("validate")?;
            println!("ok: fee = {fee} sat");
            Ok(())
        }
    }
}
