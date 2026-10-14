# 06. Roadmap

- **Target version**: v0.1
- **Last updated**: 2026-10-14
- **Hardware**: the standard build is **RP2350-PiZero + Adafruit Mini PiTFT + ArduCam UC-805 camera** ([03-hardware-bom.md](03-hardware-bom.md)), decided 2026-10-14. The milestones below target it; the earlier Raspberry Pi Zero 2 WH Linux build ([07-zero2w-setup.md](07-zero2w-setup.md)) remains only as a host-side tool

Each milestone is defined as a pair of "something that works" and "how to verify it". **Anything that cannot be reproduced on a test network is not considered done.**

---

## M0 — Preparation and groundwork (about 1 week)

| Item | Content |
|---|---|
| Deliverables | One assembled device, a development environment, the skeleton of CI |
| Work | (1) Order the parts in the [BOM](03-hardware-bom.md), measure the `MEASURED` values and re-run the enclosure checks, then print and assemble the [enclosure](../hardware/enclosure/README.md) (2) Run one reference implementation (SeedSigner / Krux) and measure the UX (3) Pin the target toolchain — Pico SDK and picotool versions, image format, tool hashes ([11-rp2350-security.md](11-rp2350-security.md) §2) — and build a development UF2 (4) Build Zig + libsecp256k1 for the host and the Cortex-M33 (5) Bring up the HAL in the order of [08-rp2350-pizero.md](08-rp2350-pizero.md) §9: display on SPI1, the two buttons, camera capture over PIO (6) Prepare testnet nodes/wallets (Core signet, Sepolia) |
| Done | (1) The device boots from a UF2 and reads a UR QR code on a phone with its camera (2) `zig build test` passes on the host and `zig build pico` compiles for the target; the on-device self-test of the vectors passes ([08](08-rp2350-pizero.md) §8) (3) It works from a power-only USB cable, with no data connection (4) Test data can be produced from Core (signet) and MetaMask (Sepolia) (5) The build is confirmed reproducible (same hash) once |

---

## M1 — Bitcoin single-signature (about 2–3 weeks)

| Item | Content |
|---|---|
| Deliverables | BTC P2WPKH address generation, PSBT signing, QR response |
| Implementation | BIP39 (dice + camera entropy) / BIP32 / BIP84 / Bech32 / PSBT parsing / BC-UR send and receive / approval UI |
| Tests | Match the official BIP39, BIP32 and BIP84 vectors. PSBT round trip with Core (signet) |
| Done | (1) The **same addresses are derived from the same seed** as the reference implementation (2) A send completes on signet (3) The seed cannot be recovered from the device's flash after power loss (the test in [02](02-architecture.md) §8) |

### Component progress (as of 2026-10-13)

“Done” below means the named component passes its stated host tests. It does not mean the milestone
or hardware-wallet flow is done. The remaining architecture work is tracked in the
[2026-10-13 internal review](10-security-audit-2026-10-13.md).

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
| **2-of-3 multisig (P2WSH)** | 🧩 Standalone signer and Core interoperability test pass; not integrated into the normal PSBT workflow |
| **Taproot key-path signing (BIP341/BIP86)** | 🧩 Standalone signer and Core interoperability test pass; not integrated into the normal PSBT workflow |
| **QR transfer (BC-UR)** | ✅ Done (Bytewords / CBOR / single- and multi-part. Matches the strings of the specification and reference implementations. Redundant parts (MUR) are not implemented) |
| EIP-712 (typed data) | 🧩 Hash/sign library matches known and independent values; not integrated with approval UI |
| ERC-7730 (clear signing) and ABI decoding | 🧩 Renderer tests pass; not connected to EVM signing or authenticated descriptor provisioning |
| **EVM transaction signing (Legacy / EIP-1559)** | 🧩 Signatures match independent values; CLI has no approval gate |
| Screen UI layer (layouts, QR encoder, PNG preview) | 🧩 Rendering components and host previews pass; not yet connected to the approval gate |
| Mutation and fuzz tests on broken input | ✅ Present; the 2026-10-13 review still found additional issues |
| Sending on the real device (signet) | ⬜ Not started (hardware required) |
| Immutable prepare → display → physical approval → sign state machine | 🧩 Host gate now connects bounded canonical BTC review to actual P2WPKH-input PSBT signing, with a pinned Core-vector test. Physical HAL, key isolation, other BTC inputs and EVM remain open ([design](11-rp2350-security.md)) |
| I-2 key isolation and I-3 independent hash comparison | 🧩 Approved native-P2WPKH path has independent wire/BIP143 messages with all-input preflight and C-boundary checks; I-2/TrustZone and other inputs/EVM remain open ([scope](13-independent-p2wpkh-guard.md)) |
| Session-wide secret erasure | 🧩 Owned seed/master/intermediate/context wipe and terminal corrupted-context abandonment tested; separate-stack fatal entry/wipe compiled and instruction-checked. Normal-return spill/caller-copy/exception/FPU/DMA and runtime erasure still open |
| Secure entropy / context blinding | 🧩 Bounded RNG interface, mandatory approved-BTC context blinding and randomized/verified BIP340 primitive tested with mocks; actual TRNG HAL and approved Taproot integration remain open |
| SRAM/stack budget | 🧩 Fixed 128 KiB workspace including two-input 64 KiB requests; schema-2 inventory plus actual pinned-C Secure/NS link harness and individual frames. Complete boot image, transitive/IRQ bounds and HAL/camera buffers remain open ([scope](14-target-link-and-fault-prototype.md)) |
| On-device screen UI and QR send/receive | ⬜ Not started (HAL and hardware verification required) |
| Development CLI | ✅ Implemented as a development tool; signing commands sign immediately and are not the device flow |
| CI (build and tests on Linux) | ✅ Done (GitHub Actions. On Linux it verifies the tests, the CLI, Core-vector signing and the UR round trip on every run) |

### Substantial host-side architecture work remains

The next tasks do not require target hardware and must precede HAL work.

| What remains | Type | Reason |
|---|---|---|
| Complete approved-flow/physical HAL integration | **Release blocker** | Host BTC integration is separate from direct CLI signing; no real button/display or isolated key gateway exists yet |
| Key isolation and full guarded signing coverage | **Release blocker** | Native-P2WPKH dual software calculation exists, but actual isolated key/NS boundaries and other BTC/EVM guards do not |
| Session-wide secret erasure | **Release blocker** | Temporary buffer wipes do not erase master/derived/session copies |
| Integrate P2TR/P2WSH into PSBT | **Required feature integration** | Current Core tests call standalone modules |
| Integrate EVM parsing, ERC-7730/EIP-712 display, and signing | **Required feature integration** | Current modules and CLI are separate |
| Descriptor authenticity/update design | **Security design** | Clear-signing metadata changes what users believe they authorize |
| On-device display, buttons, camera and RNG | **Hardware required** | The HAL must be implemented and verified on the selected board |
| Sending on the real device (signet/Sepolia) | **Hardware required** | End-to-end behavior must be checked against real nodes |
| MUR fountain recovery | Optional hardening | Sequential retransmission works but is less robust under frame loss |

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
| Published material | (1) This complete document set (2) The firmware (MIT) (3) Reproducible build instructions (4) PGP-signed releases (5) Enclosure SolidCraft scripts, STEP and STL (CERN-OHL-S-2.0) (6) Assembly instructions (with photos) (7) Threat model (8) Vulnerability disclosure policy |
| Hardware design | A board design is not required because the device is built from off-the-shelf parts. Only if a custom board is made should the full KiCad set be published and **OSHWA certification** obtained |
| Done | (1) A third party (one or more people) can assemble and verify operation on their own from the BOM alone (2) Builds in two environments produce the same hash (3) An application is filed to register with [WalletScrutiny](https://walletscrutiny.com/) (4) The vulnerability disclosure policy is published |

---

## Ongoing items (candidates for v0.2 and later)

| Candidate | Notes |
|---|---|
| ed25519 chains (Solana / TON / Cardano) | Add SLIP-0010 to `core` and keep the structure extensible by adding an app |
| SLIP-39 Shamir splitting | An option for the backup scheme |
| **Support for all-in-one hardware (M5Stack etc.)** | Devices with a screen, buttons and camera built in are "solder-free and easy to popularize". However, current Zig has no official support for the ESP32-S3 and similar parts, so **the firmware would have to be redesigned as a separate line** |
| Custom board (ESP32-S3 etc.) | Smaller size, lower cost. The full KiCad set would be published |
| Considering an auditable SE (TROPIC01) | The main candidate if availability improves |
| Support for larger display panels | Better UX for displaying EVM calldata |

---

## Working principles

1. **Do not implement a feature that cannot be reproduced on a test network** (keep the order: implement, then verify)
2. **Do not sign anything that cannot be displayed** (do not postpone clear signing)
3. **Secrets are always temporary** (do not make design changes that assume persistence)
4. When in doubt, decide by **comparing byte-for-byte** against existing implementations (SeedSigner / Krux / Trezor)
