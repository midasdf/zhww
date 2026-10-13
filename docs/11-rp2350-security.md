# 11. RP2350 security architecture and hardware-free implementation

**Status: experimental; no target security configuration has been programmed or verified.**
These components are host-tested prototypes, not a deployed secure wallet. Never use real funds.

## 1. Decisions

- Production candidate: **RP2350 A4, Arm Cortex-M33 / TrustZone**. A2, A3 and unknown
  steppings are rejected by the semantic production policy. A future stepping needs explicit
  errata review before it is added. Board name alone does not establish silicon revision.
- Keep the stateless wallet: seed, mnemonic, passphrase and derived keys belong in Secure
  SRAM, **not OTP, flash, SD, logs or crash dumps**. Public boot-key fingerprints and boot
  security configuration are appropriate OTP contents. Boot-signing keys are separate from
  wallet keys and never supplied to a wallet device.
- Disable debug, RISC-V selection, unused ROM boot interfaces, USB data and watchdog
  PC/SP reboot paths for production. Keep development provisioning separate.
- Secure boot is required but is not sufficient: it authenticates firmware, not transaction
  intent, and does not by itself prevent rollback to older signed firmware.
- No irreversible programming commands are supplied in this phase. Signing keys, update
  recovery and OTP allocation must be reviewed before provisioning a physical board.

## 2. Silicon limitations (official sources)

Raspberry Pi's [A4 announcement](https://www.raspberrypi.com/news/rp2350-a4-rp2354-and-a-new-hacking-challenge/)
identifies fixes for **E16** (OTP power-fault behavior), **E20/E21/E24** (boot-ROM security
vulnerabilities). E9 is a GPIO erratum, not a secure-boot fix. A4 still has the antifuse
array readout risk involving passive voltage contrast; it is **not a tamper-proof secure element**.
The [challenge results](https://www.raspberrypi.com/news/security-through-transparency-rp2350-hacking-challenge-results-are-in/)
also show why glitch detection cannot be treated as comprehensive EM/laser fault protection.

Primary references for implementation and provisioning:

- [RP2350 datasheet, stable document link](https://pip.raspberrypi.com/documents/RP-008373-DS)
- [Understanding RP2350's security features](https://pip-assets.raspberrypi.com/categories/1214-rp2350/documents/RP-009377-WP-1-Understanding%20RP2350_s%20security%20features.pdf)
- [Pico SDK](https://github.com/raspberrypi/pico-sdk) and [picotool](https://github.com/raspberrypi/picotool)

Pin exact SDK/picotool versions, datasheet revision, image format and tool hashes when the target
build is introduced. Do not infer register layouts from the semantic model in this repository.

## 3. Intended trust boundary (not yet implemented in hardware)

| Secure world | Non-secure / untrusted |
|---|---|
| Boot evidence collection, OTP policy/readback | SD filesystem, transport and camera input |
| Seed entry, BIP39/KDF, BIP32 and libsecp256k1 context | Request delivery and non-authoritative previews |
| Canonical request validation, signing policy | ERC-7730 descriptors and external metadata |
| Authoritative display content, SPI/GPIO display ownership | No access to framebuffer that authorizes signatures |
| Button GPIO/debounce and monotonic time | No synthetic approval events |
| TRNG/health handling, signature verification and wipe | No seed, private key, RNG or arbitrary-hash signing API |

Secure SRAM/code, SAU/MPU, bus access control, peripheral attribution, GPIO security masks,
DMA channels, interrupt routing and both cores need to agree. Park the secondary core initially;
no Non-secure-controlled DMA may touch seed memory or the authoritative display. Check
attribution with deliberate Non-secure read/write attempts, not only register readback.

Secure APIs must bounds-check and **copy untrusted input once** into bounded Secure storage.
Do not retain NS pointers across validation, review and signing. Gate/session objects themselves
must live in Secure memory: ordinary Zig fields and function visibility provide no isolation.

The current BTC/EVM APIs still receive private keys. The prototype does **not** satisfy I-2 or
I-3: a small gate cannot replace canonical validation, independent sighash computation or
chain-specific display/sign integration. Large PSBT/FAT32/QR code should not all become trusted
merely to avoid implementing a gateway.

## 4. Implemented without hardware

Files under `firmware/src/security/`:

| Module | Implemented property | Important limit |
|---|---|---|
| `boot_policy.zig` | Fail-closed semantic requirements; every missing requirement tested | Evidence is caller-supplied, not hardware attestation; no MMIO/OTP code |
| `approval.zig` | Bounded owned input, exact page commitments, sequential traversal, release/fresh hold/release, timeout, rollback detection, single-use consume | Page rendering and GPIO events must come from trusted HAL; hashes do not prove human understanding |
| `secret_session.zig` | Pointer-owned backing storage, bounded reservation, full-capacity secure erasure, borrow-memory tests | Does not erase caller copies, stacks, registers, C contexts or power-loss remanence |
| `signing_session.zig` | Boot-policy check → seed ownership → review → approval → callback → unconditional wipe; no callback on invalid approval | Trusted mock callback in tests, **not connected to CLI/BTC/EVM signing yet** |

The approval flow binds exact request bytes and rendered page bytes. It does **not** establish that
those page bytes are a complete or correct interpretation of the transaction. The next integration
must construct all pages from the frozen canonical request and reject undisplayable content.
Recompute/compare the authoritative signing plan at the signing boundary; merely checking a
PSBT byte hash is not independent sighash validation.

A button held during review cannot approve. After all pages are transferred, observe a released
button, then a fresh press held at least 1,000 ms, then release. Approval expires 120 seconds
from preparation. These are initial UX defaults, not fault-injection countermeasures.
The trusted loop must poll the timeout even when no user events occur. Any media removal,
display error, timeout, signing error or success ends the session. Aborted orchestration instances
are terminal; instantiate a new zeroed object for another session.

`SigningSession.sign` consumes approval before calling the signer and erases owned seed and
request on every exit. The signer must verify generated signatures, wipe derived-key/context
copies, and keep outputs private until it succeeds. This prototype cannot retract output already
published by a faulty callback.

The CLI intentionally remains a test-vector development tool that signs immediately. There is
no command-line flag that turns it into a physically approved hardware wallet.

## 5. TRNG and fault response plan

The production policy requires healthy entropy, but no target RNG exists yet. Implement a
mockable Secure-world RNG that checks hardware status, applies bounded waits, rejects hardware
health failures, wipes partial output and latches failure for the session. No time/ADC/PRNG fallback.
Follow the datasheet's actual TRNG initialization/health semantics; statistical tests or observing
nonzero output do not prove entropy. Existing required dice input remains required.

Wire context randomization and BIP340 auxiliary randomness through this interface. Measure
constant-time target compilation and stack use for the actual linked libsecp256k1 configuration.
On a security fault, erase software-owned secrets and halt/reset to the locked state; never
continue signing after a retry. Hardware reset/power removal does not prove all SRAM was erased.

## 6. Safe provisioning and signed update plan (hardware required)

1. Confirm A4 marking and independently read supported identity/revision fields; archive photos,
   board schematic, SDK version and readback. Reject an ambiguous board for production.
2. Build a minimal signed recovery/update path before disabling development interfaces. Updates
   need no seed and must authenticate the complete image **and read-only assets/descriptors**.
3. Define anti-rollback policy with bounded OTP/version capacity, power-failure behavior and
   an approved key-rotation scheme. Do not use unsigned SD files as an update mechanism.
4. Test signed/unsigned images, wrong keys, corrupted data, older signed versions and power
   interruption on a sacrificial development board. Secure boot alone accepts old valid signatures.
5. Review a dry-run OTP plan with exact key fingerprints and all permission/boot flags. Install
   approved key fingerprints, establish validity/revocation policy, then lock appropriate OTP
   access and debug/boot paths following the official enable procedure. Re-read every stage.
6. Unused boot-key slots must not remain available to an attacker. Deliberately reserve any
   recovery key before locking/revoking slots; never burn wallet keys into those slots.
7. Enable glitch detection with a measured sensitivity, not an assumed universally safe maximum.
   Confirm its reset/fault behavior and ordinary voltage/temperature stability.
8. Only after successful recovery tests and independent review, enable irreversible production
   secure boot. A mismatched fingerprint or premature interface disable can brick the device.

Encrypted boot is optional, **not a substitute for signed boot**. Public open-source firmware
usually gains little from confidentiality alone. Executing authenticated code/assets from Secure
SRAM can reduce external-flash substitution risks, but the 520 KB SRAM budget, secp tables,
framebuffers, request copy and scratch usage need measurement. Do not claim signed XIP code
is continuously authenticated after boot. Investigate a SRAM-resident trusted core versus
load/decrypt/re-sign before deciding; no boot-decryption secret is provisioned today.

## 7. Verification / remaining acceptance gates

```bash
cd firmware
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test -Doptimize=ReleaseFast --summary all
zig build test -Doptimize=ReleaseSmall --summary all
zig build pico --summary all
```

New modules are included in the full host suite. The Pico smoke check references the orchestrator
with a synthetic review and hash-only callback; it compiles for both Cortex-M0+ and Cortex-M33.
Compilation on RP2040 does not give it RP2350 security features. Neither result is execution,
a signed UF2, a linked Secure/Non-secure image or a hardware security test.

Before any real-funds claim: actual linked target boot, measured SRAM/stack budget, trusted
complete display and physical approval, constrained NS gateway, seed-copy/C-context erasure,
TRNG error tests, secure-boot/OTP readback, invalid-boot and NS/DMA access rejection, signed
update/rollback/power-failure tests, BTC Signet/EVM Sepolia interoperability, independent security
review and physical side-channel/fault assessment. These gates remain open.
