# Third-Party Software and Data Notices

- **Last updated**: 2026-10-14

This is a list of the third-party software and data used by this project (zhww). Every file's own
licence is stated in its SPDX header or in [REUSE.toml](REUSE.toml); the texts of the licences that
appear in this repository are in [LICENSES/](LICENSES/). For the others, refer to each project's
distribution.

---

## 1. Runtime dependencies (firmware)

| Name | Purpose | License | Source |
|---|---|---|---|
| **libsecp256k1** | Elliptic-curve operations (the only cryptographic primitive) | MIT | https://github.com/bitcoin-core/secp256k1 |
| Zig standard library | SHA-256 / SHA-512 / HMAC / PBKDF2 / Keccak, etc. | MIT | https://ziglang.org/ |
| **font8x8** (Daniel Hepper, from the VGA font by Marcel Sondaar / IBM) | The 8×8 bitmap font in `firmware/src/ui/font.zig` | Public domain (relicensed as MIT in that file) | https://github.com/dhepper/font8x8 |

> RIPEMD-160 does not exist in the Zig standard library, so **this project implements it itself**
> (`firmware/src/core/crypto/ripemd160.zig`). The implementation is verified against official test vectors.

## 2. Used for development and testing (not distributed)

| Name | Purpose | License |
|---|---|---|
| Zig compiler | Build (0.17 and later) | MIT |
| **eth-account 0.13.7** (external oracle) | **Cross-checking expected values** for EVM signing and EIP-712. Run outside the repository (`/tmp`) and not included as a dependency | MIT |
| **Bitcoin Core v31.1.0** (external oracle, interoperability) | Creates real PSBTs on regtest and verifies this implementation's signatures with `finalizepsbt` and `testmempoolaccept`. **The interoperability test vectors pin Core's output as-is** (`tests/vectors/core_*.json`) | MIT |
| **ethers.js 6.17.0** (external oracle) | Cross-checking EVM calldata generation (ABI encoding) and selectors. Run outside the repository and not included as a dependency | MIT |

> Oracles are used to "compute expected values with a third-party implementation independent of ours,
> and check whether they match byte for byte". **They are not included in the repository's
> dependencies** (the tests run against embedded fixed values).

## 3. Test data (official test vectors)

The tests use **third-party official vectors**. No expected values of our own are used. Each BIP
states its own licence in its header, and they are not all the same; the files below carry them in
[REUSE.toml](REUSE.toml).

| File (`firmware/…`) | Content | Source | License |
|---|---|---|---|
| `tests/vectors/bip39.json` | 24 official BIP39 vectors | https://github.com/trezor/python-mnemonic (© 2013-2016 Pavol Rusnak) | MIT |
| `src/core/seed/english.txt` | The BIP39 English word list | https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt | MIT (BIP 39) |
| `tests/vectors/bip32.json` | BIP32 test vector 1 | https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki (Pieter Wuille) | BSD-2-Clause |
| `tests/vectors/bip49.json` | BIP49 P2SH-P2WPKH | https://github.com/bitcoin/bips/blob/master/bip-0049.mediawiki | Public domain (our compilation: MIT) |
| `tests/vectors/bip84.json` | BIP84 P2WPKH | https://github.com/bitcoin/bips/blob/master/bip-0084.mediawiki | CC0-1.0 (our compilation: MIT) |
| `tests/vectors/bip86.json` | BIP86 P2TR | https://github.com/bitcoin/bips/blob/master/bip-0086.mediawiki (Ava Chow) | BSD-2-Clause |
| `tests/vectors/bip143.json` | BIP143 native P2WPKH (signature, signed tx) | https://github.com/bitcoin/bips/blob/master/bip-0143.mediawiki | Public domain (our compilation: MIT) |
| `tests/vectors/bip174.json` | BIP174 PSBT (20 invalid / 27 valid) | https://github.com/bitcoin/bips/blob/master/bip-0174.mediawiki (Ava Chow) | BSD-2-Clause |
| `tests/vectors/core_*.json` | PSBTs and transactions captured from Bitcoin Core regtest runs | Bitcoin Core v31.1.0 (see §2) | MIT (ours) |
| Inside `src/apps/evm/clear_signing.zig` | The Lido stETH, Ekubo Ve33 and ERC-20 descriptors, embedded verbatim in the tests | https://github.com/ethereum/clear-signing-erc7730-registry | CC0-1.0 |
| Inside `src/transport/bytewords.zig` and `ur.zig` | BC-UR / Bytewords test vectors | https://github.com/BlockchainCommons (the specifications and reference implementations) | Factual vectors only; no code is incorporated |

## 4. Specifications and implementations used as references (no code incorporated)

The following are listed as references for specifications or design; **no code has been incorporated from them**.

| Name | What we reference | Note |
|---|---|---|
| [SeedSigner](https://github.com/SeedSigner/seedsigner) | Parts list, dice entropy, air-gapped operation, the camera-on-the-back layout | MIT |
| [Krux](https://github.com/selfcustody/krux) | Screen design, approach to measuring entropy | MIT |
| [Specter DIY](https://github.com/cryptoadvance/specter-diy) | How to write a security model | Reference for the documentation |
| Trezor firmware | Multi-chain app separation structure (the idea only) | **GPLv3: must not be copied into this MIT firmware**, and the "Trezor" name is not used |
| [Ethereum Improvement Proposals](https://eips.ethereum.org/) | EIP-155 / EIP-1559 / EIP-191 / EIP-55 / ERC-7730 | Reference for the specifications |
| [BC-UR](https://github.com/BlockchainCommons/bc-ur) | QR transport scheme (implemented independently) | BSD-2-Clause-Patent; add a notice if code is ever incorporated |

## 5. License notes

- This project's firmware and tools are **MIT** ([LICENSE](LICENSE))
- The hardware design, the enclosure included, is **CERN-OHL-S-2.0** ([LICENSES/CERN-OHL-S-2.0.txt](LICENSES/CERN-OHL-S-2.0.txt))
- Documentation is **CC-BY-4.0** ([LICENSES/CC-BY-4.0.txt](LICENSES/CC-BY-4.0.txt)); see [LICENSE-POLICY.md](LICENSE-POLICY.md)
- When incorporating third-party code, use **only compatible licenses** (LICENSE-POLICY.md §3) and update this list
