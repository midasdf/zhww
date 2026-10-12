# 06. Roadmap

- **Target version**: v0.1
- **Last updated**: 2026-10-12

Each milestone is defined as a pair of "something that works" and "how to verify it". **Anything that cannot be reproduced on a test network is not considered done.**

---

## M0 — Preparation and groundwork (about 1 week)

| Item | Content |
|---|---|
| Deliverables | One assembled device, a development environment, the skeleton of CI |
| Work | (1) Order and assemble the parts in the [BOM](03-hardware-bom.md) (2) Run one reference implementation (SeedSigner / Krux) and measure the UX (3) Establish the Raspberry Pi OS Lite build procedure and **wireless disablement** ([07-zero2w-setup.md](07-zero2w-setup.md)) (4) Establish a Zig + libsecp256k1 build environment (both on the Mac and on the Pi) (5) Prepare the LCD/camera device tree overlays (6) Prepare testnet nodes/wallets (Core signet, Sepolia) |
| Done | (1) The device boots and can read a QR code with the camera (2) `zig build test` passes on the Pi (3) It can be confirmed that no wireless interface exists (4) Test data can be produced from Core (signet) and MetaMask (Sepolia) (5) The build is confirmed reproducible (same hash) once |

---

## M1 — Bitcoin single-signature (about 2–3 weeks)

| Item | Content |
|---|---|
| Deliverables | BTC P2WPKH address generation, PSBT signing, QR response |
| Implementation | BIP39 (dice + camera entropy) / BIP32 / BIP84 / Bech32 / PSBT parsing / BC-UR send and receive / approval UI |
| Tests | Match the official BIP39, BIP32 and BIP84 vectors. PSBT round trip with Core (signet) |
| Done | (1) The **same addresses are derived from the same seed** as the reference implementation (2) A send completes on signet (3) The seed cannot be recovered from the SD card after power loss (the test in [02](02-architecture.md) §8) |

### Progress (as of 2026-10-12)

| Item | State |
|---|---|
| BIP39 / BIP32 / address generation | ✅ Done (matches the official vectors) |
| Transaction parsing and serialization | ✅ Done |
| Legacy sighash / BIP143 sighash | ✅ Done (BIP143 signatures match byte-for-byte) |
| ECDSA signing (RFC6979, low-s, DER) | ✅ Done |
| PSBT (BIP174) parsing and validation | ✅ Done (20 invalid PSBTs rejected, 27 valid ones accepted) |
| **Signing and finalization from a PSBT** | ✅ Done (P2WPKH, P2PKH, P2SH-P2WPKH, P2PK / writing out a signed PSBT) |
| Fee calculation and change detection | ✅ Done (no fee is computed when an input amount is unknown) |
| Combining dice and camera entropy | ✅ Done (verified with HKDF-SHA256 / RFC 5869 vectors) |
| **Interoperability with Bitcoin Core** | ✅ Done (signs a PSBT created by Core; Core's `finalizepsbt` returns `complete: true` and `testmempoolaccept` returns `allowed: true`. The finalized result matches byte-for-byte) |
| **2-of-3 multisig (P2WSH)** | ✅ Done (sends to a 2-of-3 address from Core, signs with this implementation, and Core accepts it. The public-key order in the witnessScript also matches Core) |
| **Taproot key-path signing (BIP341/BIP86)** | ✅ Done (sends to a P2TR address from Core, signs with this implementation, and Core accepts it. The Schnorr signature also passes BIP340 verification. The script path is out of scope) |
| **QR transfer (BC-UR)** | ✅ Done (Bytewords / CBOR / single- and multi-part. Matches the strings of the specification and reference implementations. Redundant parts (MUR) are not implemented) |
| **FAT32 (microSD exchange)** | ✅ Done (reading and writing, `IN.PSBT` → `OUT.PSBT` handoff with the `OUT.TMP` → rename scheme. Verified in CI with `mtools` and `fsck.fat`) |
| EIP-712 (typed data) | ✅ Done (matches known values from the specification; signatures also match an independent implementation) |
| ERC-7730 (clear signing) and ABI decoding | ✅ Done (display fields verified against real registry descriptors; dangerous patterns raise a warning) |
| **EVM transaction signing (Legacy / EIP-1559)** | ✅ Done (the examples given in the EIPs, plus byte-for-byte agreement with viem / ethers.js signatures) |
| Screen UI layer (layouts, QR encoder, PNG preview) | ✅ Done (hardware-independent; the whole 7-screen device flow can be reproduced on a PC) |
| Mutation and fuzz tests on broken input | ✅ Done (added; 11 bugs found so far) |
| Sending on the real device (signet) | ⬜ Not started (hardware required) |
| On-device screen UI and QR send/receive | ⬜ Not started (hardware required; the screen UI layer above is the hardware-independent part) |
| Development CLI | ✅ Done (`address` / `sign` / `show` / `screen` / `walkthrough` / `card` / `mnemonic` / `ur` / `ur-decode` / `evm-sign` / `evm-show`. Supports Zig 0.17's `std.Io`) |
| CI (build and tests on Linux) | ✅ Done (GitHub Actions. On the same Linux as the device it verifies the tests, the CLI, Core-vector signing, the UR round trip and the FAT32 microSD handoff on every run) |

### Work that can be done without hardware ends here

As of 2026-10-12, **all work that does not require hardware is complete**.
Only the following three items remain.

| What remains | Type | Reason |
|---|---|---|
| On-device display, camera and buttons | **Hardware required** | The LCD (ST7789) and camera (OV5647) must be connected and verified (the screen layouts themselves are already implemented and can be previewed on a PC) |
| Sending on the real device (signet) | **Hardware required** | It can only be confirmed by exchanging data with a real node (over QR or microSD) |
| MUR (the redundant parts of the fountain code) | Optional hardening | Repeating the sequential parts is enough in practice. An improvement for environments with heavy packet loss |

---

## M1.5 — Bitcoin display completeness (about 1 week)

| Item | Content |
|---|---|
| Deliverables | Fee and change detection, warning display |
| Implementation | Aggregating inputs and outputs, computing sat/vB, judging change by actually deriving the change key, high-fee warnings, rejecting unknown inputs |
| Done | (1) A PSBT designed to fool change detection is still classified correctly as a "send" (2) A PSBT missing `witness_utxo` is rejected (3) A high-fee case raises a warning |

---

## M2 — EVM signing (about 2–3 weeks)

| Item | Content |
|---|---|
| Deliverables | Legacy / EIP-1559 signing, chainId display, EIP-55 address display |
| Implementation | RLP, Keccak-256, EIP-155 / 1559 signing hashes, low-s normalization, `m/44'/60'/0'/0/i` derivation |
| Tests | Official test vectors, byte-for-byte agreement with viem / ethers.js (automated in CI) |
| Done | (1) Signing and broadcasting succeed on Sepolia (2) Signatures match viem byte-for-byte (3) The chainId is always shown on screen |

---

## M2.5 — ERC-20 and dangerous-pattern warnings (about 1–2 weeks)

| Item | Content |
|---|---|
| Deliverables | Decoding and warnings for transfer / approve / setApprovalForAll / permit |
| Done | (1) An unlimited approve raises a red warning plus an extra approval (2) When decimals are unknown, no guessed value is displayed (3) Unknown selectors fall back to displaying the hash |

---

## M2.6 — EIP-191 / EIP-712 (about 1–2 weeks)

| Item | Content |
|---|---|
| Deliverables | Signing and display of personal_sign and typed data v4 |
| Done | (1) `domainSeparator` / `hashStruct` match known samples (2) A warning is raised when `verifyingContract` is unknown (3) Excessively deep nesting or arrays are rejected |

---

## M3 — Clear signing and advanced BTC features (about 3–4 weeks)

| Item | Content |
|---|---|
| Deliverables | Clear signing with ERC-7730 descriptors, BTC multisig, Taproot key-path |
| Implementation | Bundling descriptors together with their signatures, plus chainId validation, P2WSH sortedmulti, BIP86 |
| Done | (1) Known DeFi calls are displayed in human-readable form from ERC-7730 descriptors (2) Descriptors with a mismatched chainId are rejected (3) Signatures for 2-of-3 multisig match Sparrow (4) Taproot addresses match the BIP86 vectors |

---

## M4 — Public release (about 2–3 weeks)

| Item | Content |
|---|---|
| Deliverables | Public repository, the full set of design documents, reproducible builds, certification |
| Published material | (1) This complete document set (2) The firmware (GPL-3.0-or-later) (3) Reproducible build instructions (4) PGP-signed releases (5) Enclosure STL / STEP (6) Assembly instructions (with photos) (7) Threat model (8) Vulnerability disclosure policy |
| Hardware design | A board design is not required because the device is built from off-the-shelf parts. Only if a custom board is made should the full KiCad set be published and **OSHWA certification** obtained |
| Done | (1) A third party (one or more people) can assemble and verify operation on their own from the BOM alone (2) Builds in two environments produce the same hash (3) An application is filed to register with [WalletScrutiny](https://walletscrutiny.com/) (4) The vulnerability disclosure policy is published |

---

## Ongoing items (candidates for v0.2 and later)

| Candidate | Notes |
|---|---|
| ed25519 chains (Solana / TON / Cardano) | Add SLIP-0010 to `core` and keep the structure extensible by adding an app |
| SLIP-39 Shamir splitting | An option for the backup scheme |
| **Porting to the RP2350-PiZero** | **The main v0.2 candidate**. Same size and 40-pin compatible with the Pi Zero, no wireless, no soldering, microSD, LiPo charging, UF2 flashing. Compiling the core and building libsecp256k1 have been confirmed by measurement. The plan is [08-rp2350-pizero.md](08-rp2350-pizero.md). The remaining work is implementing the HAL, the QR approach (decided: microSD handoff first, SPI camera later) and measuring signing speed |
| **Support for all-in-one hardware (M5Stack etc.)** | Devices with a screen, buttons and camera built in are "solder-free and easy to popularize". However, they do not run Linux, and current Zig has no official support for the ESP32-S3 and similar parts, so **the firmware would have to be redesigned as a separate line** |
| Custom board (ESP32-S3 etc.) | Smaller size, lower cost. The full KiCad set would be published |
| Considering an auditable SE (TROPIC01) | The main candidate if availability improves |
| Support for larger display panels | Better UX for displaying EVM calldata |

---

## Working principles

1. **Do not implement a feature that cannot be reproduced on a test network** (keep the order: implement, then verify)
2. **Do not sign anything that cannot be displayed** (do not postpone clear signing)
3. **Secrets are always temporary** (do not make design changes that assume persistence)
4. When in doubt, decide by **comparing byte-for-byte** against existing implementations (SeedSigner / Krux / Trezor)
