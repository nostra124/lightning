---
id: FEAT-179
type: feature
priority: medium
status: open
---

# `lightning(1)` man page citing the vendored standards

## Description

**As a** user reading `man lightning` or `lightning help <verb>`
**I want** every implemented spec cited with title, status,
upstream URL, and local installed path
**So that** the spec is one step away from any operation,
and the educational mission is realised.

Mirrors FEAT-127 (dht), FEAT-115 (check), FEAT-035 (crypt),
FEAT-015 (bitcoin). Depends on FEAT-178.

## Implementation

`share/man/man1/lightning.1` (groff). Sections: NAME,
SYNOPSIS, DESCRIPTION (four design principles + clightning
focus + wallet/account model + addresses),
**ENVIRONMENT** (`LIGHTNING_DIR`, `LIGHTNING_NETWORK`),
SUBCOMMANDS (channel / pay / invoice / offer / lnurl /
wallet / account / liquidity / address / decode / daemon /
unlock / tor / ledger / qr), FILES, EXIT STATUS, EXAMPLES,
**STANDARDS**, SEE ALSO (`bitcoin(1)`, `secret(1)`,
`account(1)`, `cluster(1)`, `lightningd(8)`,
`lightning-cli(1)`).

DESCRIPTION opens with the four design principles and the
*educational Lightning toolkit on clightning* framing.

STANDARDS section enumerates every vendored spec from
FEAT-178 with title, status, upstream URL, and local path.

`lightning help <verb>` uses the standard `Implements:`
template:

    Implements:
      <STANDARD-ID>  <title>
      <upstream-url>
      local:   /usr/local/share/doc/lightning/standards/<filename>

Mapping examples:

    lightning pay         → BOLT-11 (11-payment-encoding.md)
    lightning offer       → BOLT-12 (12-offer-encoding.md)
    lightning lnurl pay   → LUD-06
    lightning address     → Lightning Address spec + BIP-353
    lightning channel open → BOLT-2
    lightning channel close → BOLT-2 + BOLT-5

## Acceptance Criteria

1. `man lightning` renders with all sections; STANDARDS
   populated.
2. `lightning help <verb>` for any spec-implementing verb
   prints the citation template with the correct local
   path for the active install prefix.
3. DESCRIPTION states the four design principles.
4. After `make install`, every cited local path resolves.
