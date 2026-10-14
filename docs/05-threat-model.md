# 05. Threat model

- **Target version**: v0.1
- **Last updated**: 2026-10-14

This document aims to state explicitly what can be protected and what cannot. **Never write that something unprotected is protected** is the highest-priority rule.

---

## 1. Assets to protect

| Asset | Description |
|---|---|
| A-1 | BIP39 mnemonic / seed (the root of the keys for every chain) |
| A-2 | Derived private keys and extended private keys (xprv) |
| A-3 | Passphrase |
| A-4 | Integrity of what is signed (agreement between what is displayed and what is actually signed) |
| A-5 | Firmware integrity |

## 2. Trust boundaries and assumptions

| Subject | Trusted? | Description |
|---|---|---|
| Host PC / dApp | **Not trusted** | PSBTs and transactions are handled on the assumption that they may have been tampered with |
| QR display / camera | Not trusted | The possibility that data is swapped between the screen and the camera is taken into account |
| Parts (board / display / camera) | Trusted in principle | However, supply-chain risk remains (§5) |
| Firmware | Trusted by design | Authenticity is assured by reproducible builds and signatures |
| An attacker with physical access | **Not trusted (cannot be protected)** | §4-1 |

## 3. Attacker classes

| ID | Attacker | Capability |
|---|---|---|
| T-1 | Remote attacker | Over the network. However, this device has no wireless interface in normal operation |
| T-2 | Malicious host / dApp | Can present arbitrary PSBTs, transactions and messages |
| T-3 | Supply-chain attacker | Can interfere with parts and release images |
| T-4 | Attacker with physical access | Can seize, disassemble and probe the device |
| T-5 | Careless user | Ignores warnings, skips confirmation |

---

## 4. Threats and countermeasures

### 4-1. Physical access (T-4) — **cannot be protected**

| Threat | Detail |
|---|---|
| Chip readout | The board's flash and the RP2350's RAM can be read out under physical access |
| Voltage / clock glitching | Fault injection during signing can expose keys |
| Substitution by a man in the middle | The entire device can be swapped |

**Required countermeasures for release**
- The seed exists only in RAM. Make **powering off after use** a strict operational rule
- Make multisig (2-of-3 or better) the recommended configuration so that seizing one device does not lose the assets
- Passphrase separation is recommended
- State clearly that this device is **not suitable for hot storage of small-to-medium amounts**

**Residual risk**: physical attacks while the device is in use (while the seed is in RAM) cannot be prevented. This is a **direct consequence of the design choice not to include an SE**, and it is disclosed openly rather than hidden.

### 4-2. Mismatch between the display and what is signed (T-2) — **most important**

| Threat | Detail |
|---|---|
| Display spoofing | The host shows "sending 10 USDC" while actually having the user sign an approval for the full amount |
| Address swapping | Only the destination is swapped by tampering with the clipboard or the QR code |
| chainId spoofing | Make the user sign a transaction for a different chain |
| Visual review defeated by sheer length | Exhaust the user with a large number of outputs or enormous calldata so that they give up on checking |

**Required countermeasures for release**
- **The double-computation principle** ([02-architecture.md](02-architecture.md) §2 I-3): `apps` and `core` compute the hash to be signed independently, and signing is refused if they disagree
- Addresses are shown **in full**. Truncation and ellipses are forbidden
- EVM always displays the chainId
- Dangerous patterns (unlimited approve, `setApprovalForAll`, `permit`, unknown contract, contract creation) get a red warning + additional approval
- Limits are placed on the number of outputs and the calldata length; anything beyond them is refused (prevents DoS and defeat of visual review)

**Current gap:** I-3, the physical approval gate, mandatory page traversal, and the integrated
EVM clear-signing flow are not implemented. The existing CLI signing commands sign immediately.
See the [2026-10-13 internal review](10-security-audit-2026-10-13.md).

**Residual risk**: nothing can prevent a user who ignores the warning and approves anyway (T-5).

### 4-3. Supply chain (T-3)

| Threat | Detail |
|---|---|
| Counterfeit or used board | Pre-modified firmware or additional chips |
| Malicious camera / LCD module | Additional flash or an I2C chip that sends data outside |
| Tampered release image | Replacement of the release |

**Countermeasures**
- Buy from authorized distributors (avoid used units and grey-market personal imports)
- Disassemble and inspect on arrival, and confirm that there are no chips that are not in the datasheet
- **Print the enclosure in a clear material** (recommended, see [hardware/enclosure](../hardware/enclosure/README.md)):
  every board, cable and part stays visible, so the inside can be compared with the assembly photos
  before each use without opening the case. Tamper-evident seals are **not** part of the design: each
  user builds and opens their own device, so a seal would only prove that its owner closed it
- **Always build the release image yourself and compare the hash against the distributed value** (NFR-07). Do not flash an image someone else built
- Verify the PGP signature

**Residual risk**: modifications that cannot be detected visually (such as alterations inside the die) cannot be detected. In this area the device is inferior to commercial products that have an SE and secure boot.

### 4-4. Firmware integrity (T-3, T-4)

The design is in [11-rp2350-security.md](11-rp2350-security.md); **none of it is implemented or
provisioned yet**.

| Threat | Detail |
|---|---|
| Firmware replacement | A modified image is flashed (a UF2 over USB, or the external flash rewritten) that leaks the seed — for example through the QR codes it shows — or signs something other than what it displays |
| Rollback | An older, validly signed image with a known flaw is reinstalled; secure boot alone accepts it |
| Interfaces left open | SWD debug, RISC-V selection, unused boot-ROM interfaces or USB data stay enabled on a production device |

**Countermeasures (planned)**
- RP2350 **signed boot**, with the boot-key fingerprints in OTP, on A4 silicon only ([11](11-rp2350-security.md) §1, §6)
- An **anti-rollback** policy within the OTP's version capacity, with key rotation defined before provisioning (§6 there)
- Production locks — debug, RISC-V, unused boot interfaces and USB data disabled — only after a signed recovery path has been tested (§1, §6 there)
- Updates authenticate the complete image and its read-only assets; **no SD-card updates** (§6 there; card exchange is ruled out, [03-hardware-bom.md](03-hardware-bom.md) §2.4)
- Reproducible builds + signed releases (NFR-07): build the image yourself and compare the hash

**Residual risk**: until that is provisioned, **the board runs whatever UF2 it is given** — holding BOOT
while plugging in USB is enough — so a moment of physical access is enough to replace the firmware.
Even afterwards, signed XIP code is not continuously authenticated after boot, the antifuse array has a
readout risk, and the glitch detectors are not comprehensive fault protection (§2, §6 there). Keeping
the device in your own possession and powering it from a power-only cable reduce the opportunities; the
clear case reveals added hardware but not changed firmware, so when in doubt re-flash an image you
built yourself.

### 4-5. Randomness quality

| Threat | Detail |
|---|---|
| RNG defect | A predictable seed is generated |
| Dependence on a single entropy source | A particular source can fail without being noticed |

**Countermeasures**
- Combine dice (mandatory) + camera-image entropy + the SoC TRNG with HKDF
- Run health tests on the bit distribution and on repeated patterns at generation time, and abort on an anomaly
- Document how dice input is verified (following SeedSigner's dice verification)

### 4-6. Implementation bugs (T-2, T-5)

**Implemented verification and required countermeasures**
- Elliptic-curve arithmetic uses only the audited libsecp256k1 (no elliptic-curve code of our own)
- Nonces use RFC6979 deterministic generation
- RLP, Bech32/Bech32m and PSBT are verified for exact agreement with the official test vectors
- **Byte-for-byte cross-checks** against external implementations (Bitcoin Core / viem / ethers.js) run in CI
- To prevent descriptors and implementation from drifting apart, ERC-7730 display is pinned by snapshot tests

Passing these tests does not close the architectural gaps above. The review found exploitable
display/signing inconsistency and parser boundary issues despite the existing test suite.

### 4-7. Cross-chain-specific risks

| Threat | Detail |
|---|---|
| Larger blast radius | One seed is used on every chain, so a single leak puts every asset at risk |
| Similar addresses | The same address exists on multiple chains, so the destination chain can be misidentified |
| Replay | Signatures are reused across chains |

**Countermeasures**
- The UI recommends per-chain separation via passphrase and warns when none is set
- Always display the chainId
- Do not omit the chainId binding from EIP-155 onward

---

### 4-8. Power path (T-3, T-4)

| Threat | Countermeasure |
|---|---|
| Something is planted by the host over the USB power cable's data lines | Use a **power-only cable**, or a mobile battery pack / dry-cell box (which have no data lines). In normal operation the firmware does not use USB data (writing happens only when BOOTSEL is pressed) |
| The host cuts power during USB operation to interrupt signing | The result exists only as QR codes drawn after signing has completed, so a power cut leaves no partial signature |
| Fire or swelling caused by the charging circuit or the battery | **Not putting a battery in the device** eliminates this path entirely |

## 5. Things explicitly *not* protected

1. Protection of the seed under physical access (because there is no SE)
2. Loss of assets when the user ignores warnings
3. Modifications to parts from an authorized distributor that cannot be detected visually
4. **Prevention** of firmware replacement until RP2350 signed boot is provisioned (§4-4); until then, detection only

## 6. Operational guidelines (summary to be copied into the README)

- First verify the whole flow on **test networks** (Signet / Sepolia)
- Base real use on **multisig**; do not depend on a single device
- **Always power off after use** (RAM wipe)
- Back up the seed **by hand on a metal plate or similar**. Leave no digital copy
- **Build the release image yourself** and compare the hash
- Do not carry out an approval that raised a warning until you understand what it is
