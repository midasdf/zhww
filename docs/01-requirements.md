# 01. Requirements

- **Target version**: v0.1 (initial scope)
- **Last updated**: 2026-10-12

---

## 1. Purpose

Design and publish a fully open-source, multi-chain signing device that can be assembled from commodity parts alone. Users must be able to settle "what to buy, how to assemble it, and how to verify it" using only the information in this repository.

## 2. Scope

### Chains in scope (initial)

| Family | Targets | Notes |
|---|---|---|
| Bitcoin | P2WPKH (BIP84), P2PKH/P2SH-P2WPKH, P2WSH multisig, P2TR key-path | Single-signature, 2-of-3 multisig and Taproot signing are implemented and verified against Bitcoin Core |
| EVM | Ethereum and major L2s (ERC-20 transfer/approve, EIP-191/EIP-712 signing) | Supported per chainId |

### Explicitly out of scope (v0.1)

- ed25519 chains (Solana, TON, Cardano, Polkadot, etc.) — v0.2 and later
- Developing our own mobile/desktop app (existing Sparrow / Electrum / MetaMask, etc. are used)
- Wireless communication (Wi-Fi / Bluetooth / NFC)
- Key protection with a secure element
- Regulatory compliance for Japanese radio certification (giteki), PSE and CE/FCC, and **selling** this design
- BIP85, SLIP-39, and the script path of multisig (Taproot script-path)

## 3. Functional requirements

| ID | Requirement | Priority |
|---|---|---|
| FR-01 | Generate a BIP39 seed from dice input (12 words: 50 rolls / 24 words: 99 rolls) and camera-image entropy | Required |
| FR-02 | Load a BIP39 mnemonic from a SeedQR (standard / Compact) | Required |
| FR-03 | Support a BIP39 passphrase (word 25), with re-entry or checksum display to detect typos | Required |
| FR-04 | Derive and display BTC addresses for the BIP44/49/84/86 derivation paths | Required |
| FR-05 | Receive a PSBT over QR (BC-UR, animated) or via the SD card, sign it and return it | Required |
| FR-06 | Show the PSBT's destination, amount, fee and change address on screen, and require approval | Required |
| FR-07 | RLP-parse EVM transactions (Legacy / EIP-1559), display the destination, amount, chain ID and fee, and sign them | Required |
| FR-08 | Decode ERC-20 `transfer` / `approve` and display the token amount | Required |
| FR-09 | Sign EIP-191 (personal_sign) and EIP-712 typed data, and display what is being signed | Required |
| FR-10 | Load ERC-7730 descriptors and display calls to supported contracts in human-readable form | High |
| FR-11 | For contract calls not covered by a descriptor, fall back to an "unknown contract" warning plus a raw calldata hash | Required |
| FR-12 | Derive xpubs and sign PSBTs for BTC multisig (P2WSH, sortedmulti) | High |
| FR-13 | After signing, erase the seed, intermediate keys and session state from memory, and let the user confirm that state on screen | Required |

## 4. Non-functional requirements

| ID | Requirement | Target |
|---|---|---|
| NFR-01 | Assembly requires no soldering | Zero soldering or special tools at any step |
| NFR-02 | Parts cost per unit | ¥12,000 or less (about USD 80) |
| NFR-03 | Number of parts | 10 or fewer (excluding consumables and the enclosure) |
| NFR-04 | Assembly time (experienced) | Within 60 minutes |
| NFR-05 | Seed persistence | Never written to flash, SD or swap |
| NFR-06 | Network connectivity | No wireless capability in hardware, or it is disabled |
| NFR-07 | Firmware verifiability | Reproducible builds + PGP-signed releases |
| NFR-08 | Elliptic-curve arithmetic | Use audited libsecp256k1 (pure-Python implementations forbidden) |
| NFR-09 | Boot time | 60 seconds or less (a target, not a measurement: the firmware has not run on hardware yet. The v0.1 Linux build targets the Pi Zero 2 WH; a wireless-free Zero 1.3 may boot more slowly, which is accepted) |
| NFR-10 | Host-side dependencies | Signing requests use only standard formats (PSBT / JSON-RPC payloads) |

## 5. Constraints

- **C-01**: The Raspberry Pi Zero (the v0.1 Linux build) has no secure boot. Firmware integrity can therefore only be assured by "reproducible builds + detection through SD-card swapping in operation" (stated as a residual risk).
- **C-02**: With no SE, seed protection cannot be guaranteed if an attacker gains physical access.
- **C-03**: A 240×240 screen limits full display of EVM calldata. A paged display is assumed (a larger-screen option is described in the BOM).
- **C-04**: The firmware is MIT, so GPL-licensed code (Trezor firmware is GPLv3) must not be copied into it, and the "Trezor" name is not used (see [LICENSE-POLICY.md](../LICENSE-POLICY.md) §3).

## 6. Acceptance criteria (definition of v0.1 Done)

v0.1 is complete when all of the following are satisfied.

1. A single unit can be assembled from the parts listed in the BOM without soldering (within 60 minutes following the procedure)
2. On Bitcoin Signet, the **same addresses are derived from the same seed** as existing devices such as SeedSigner (BIP84 test vectors match)
3. A PSBT received from Sparrow (or Electrum) is signed and returned, and the broadcast succeeds
4. An EIP-1559 transaction signed on Ethereum Sepolia **matches byte-for-byte** signatures produced with viem or ethers.js
5. ERC-20 `transfer` can be signed after displaying the contract address, the amount and the destination on screen
6. After power loss, no secret information including the seed can be recovered from the SD card or flash
7. Release images built in two different environments produce the same hash (reproducible build)
8. The residual risks described in the threat model can be reached from the README

## 7. Terminology

| Term | Meaning |
|---|---|
| clear signing | A design that displays the meaning of a transaction in human-readable form before signing, and guarantees that what is displayed matches what is signed |
| blind signing | Approving undecodable data as it is. Forbidden in this project |
| stateless | A design in which the seed is not placed in persistent storage and disappears when power is cut |
| PSBT | The Bitcoin partially signed transaction format defined in BIP174 |
| BC-UR | Blockchain Commons Uniform Resources. A format that splits arbitrary data for transfer over QR |
