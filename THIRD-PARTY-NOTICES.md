# Third-Party Software and Data Notices

- **Last updated**: 2026-10-12

This is a list of the third-party software and data used by this project (zhww).
For the full license texts, refer to each project's distribution.

---

## 1. Runtime dependencies (firmware)

| Name | Purpose | License | Source |
|---|---|---|---|
| **libsecp256k1** | Elliptic-curve operations (the only cryptographic primitive) | MIT | https://github.com/bitcoin-core/secp256k1 |
| Zig standard library | SHA-256 / SHA-512 / HMAC / PBKDF2 / Keccak, etc. | MIT | https://ziglang.org/ |

> RIPEMD-160 does not exist in the Zig standard library, so **this project implements it itself**
> (`firmware/src/core/crypto/ripemd160.zig`). The implementation is verified against official test vectors.

## 2. Used for development and testing

| Name | Purpose | License |
|---|---|---|
| Zig compiler | Build (0.17 and later) | MIT |
| **eth-account 0.13.7** (external oracle) | **Cross-checking expected values** for EVM signing and EIP-712. Run outside the repository (`/tmp`) and not included as a dependency | MIT |
| **Bitcoin Core v31.1.0** (external oracle, interoperability) | Creates real PSBTs on regtest and verifies this implementation's signatures with `finalizepsbt` and `testmempoolaccept`. **The interoperability test vectors pin Core's output as-is** (`tests/vectors/core_psbt.json`) | MIT |
| **ethers.js 6.17.0** (external oracle) | Cross-checking EVM calldata generation (ABI encoding) and selectors. Run outside the repository and not included as a dependency | MIT |
| **ERC-7730 descriptor registry** | Test data for clear signing (the Lido stETH / Ekubo / ERC-20 descriptors are embedded as-is) | Follows the registry's license (source: https://github.com/ethereum/clear-signing-erc7730-registry ) |

> Oracles are used to "compute expected values with a third-party implementation independent of ours,
> and check whether they match byte for byte". **They are not included in the repository's
> dependencies** (the tests run against embedded fixed values).

## 3. Test data (official test vectors)

The tests use **third-party official vectors**. No expected values of our own are used.
The sources for each file are as follows (`firmware/tests/vectors/`).

| File | Content | Source | License |
|---|---|---|---|
| `bip39.json` | 24 official BIP39 vectors | https://github.com/trezor/python-mnemonic | MIT |
| `bip32.json` | BIP32 test vector 1 | https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki | BIPs are CC0-1.0 |
| `bip49.json` | BIP49 P2SH-P2WPKH | https://github.com/bitcoin/bips/blob/master/bip-0049.mediawiki | Same as above |
| `bip84.json` | BIP84 P2WPKH | https://github.com/bitcoin/bips/blob/master/bip-0084.mediawiki | Same as above |
| `bip86.json` | BIP86 P2TR | https://github.com/bitcoin/bips/blob/master/bip-0086.mediawiki | Same as above |
| `bip143.json` | BIP143 native P2WPKH (signature, signed tx) | https://github.com/bitcoin/bips/blob/master/bip-0143.mediawiki | Same as above |
| `bip174.json` | BIP174 PSBT (20 invalid / 27 valid) | https://github.com/bitcoin/bips/blob/master/bip-0174.mediawiki | Same as above |

> The BIP39 English word list (`firmware/src/core/seed/english.txt`) is also
> taken from https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt (CC0-1.0).

## 4. Specifications and implementations used as references (no code incorporated)

The following are listed as references for specifications or design; **no code has been incorporated from them**.

| Name | What we reference | Note |
|---|---|---|
| [SeedSigner](https://github.com/SeedSigner/seedsigner) | Parts list, dice entropy, air-gapped operation | Reference for the hardware design |
| [Krux](https://github.com/selfcustody/krux) | Screen design, approach to measuring entropy | MIT |
| [Specter DIY](https://github.com/cryptoadvance/specter-diy) | How to write a security model | Reference for the documentation |
| Trezor firmware | Multi-chain app separation structure (the idea only) | **If code were incorporated, this project's firmware would become GPLv3 and the "Trezor" name could not be used** |
| [Ethereum Improvement Proposals](https://eips.ethereum.org/) | EIP-155 / EIP-1559 / EIP-191 / EIP-55 / ERC-7730 | Reference for the specifications |
| [BC-UR](https://github.com/BlockchainCommons/bc-ur) | QR transport scheme (not implemented) | Add a license notice if it is introduced |

## 5. License notes

- This project's firmware is **GPL-3.0-or-later** ([LICENSE](LICENSE))
- The hardware design is **CERN-OHL-S-2.0** ([LICENSE-HARDWARE](LICENSE-HARDWARE))
- Documentation is **CC-BY-4.0**, the enclosure is **CC-BY-SA-4.0** ([LICENSE-POLICY.md](LICENSE-POLICY.md))
- When incorporating third-party code, use **only compatible licenses** and update this list
