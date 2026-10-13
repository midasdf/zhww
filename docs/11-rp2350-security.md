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
project-wide I-3. The approved native-P2WPKH path now has an [independent wire-parser/BIP143
guard](13-independent-p2wpkh-guard.md), but other inputs/EVM/direct APIs and actual key/NS
isolation remain open. Large PSBT/FAT32/QR code should not all become trusted
merely to avoid implementing a gateway.

## 4. Implemented without hardware

Files under `firmware/src/security/`:

| Module | Implemented property | Important limit |
|---|---|---|
| `boot_policy.zig` | Fail-closed semantic requirements; every missing requirement tested | Evidence is caller-supplied, not hardware attestation; no MMIO/OTP code |
| `approval.zig` | Bounded owned input, exact page commitments, sequential traversal, release/fresh hold/release, timeout, rollback detection, single-use consume | Page rendering and GPIO events must come from trusted HAL; hashes do not prove human understanding |
| `secret_session.zig` | Pointer-owned backing storage, bounded reservation, full-capacity secure erasure, borrow-memory tests | Does not erase caller copies, stacks, registers, C contexts or power-loss remanence |
| `signing_session.zig` | Boot-policy check → seed ownership → review → approval → callback → unconditional wipe; no callback on invalid approval | Generic trusted callback, now used by the separate approved BTC workflow; not a physical HAL or secure gateway |
| `rng.zig` | Nonblocking status/read interface, bounded poll budget, full-output erasure and terminal failure latch | Mock-tested only; provider status is not hardware attestation or an entropy-quality test |
| `p2wpkh_guard.zig` | Independent, allocation-free PSBTv0/native-P2WPKH/SIGHASH_ALL wire parsing and streaming BIP143 messages; numeric totals/fee cross-check | Narrow subset, shared SHA/compiler/CPU, no target isolation or independent address rendering ([scope](13-independent-p2wpkh-guard.md)) |
| Target link/fatal harness | Pinned target C crypto; actual partial-image Secure/NS sections; static Zig/C frames; terminal context abandonment and compiled separate-stack fatal wipe | Not bootable, no attribution/gateway/HAL; no transitive stack/runtime/fault proof ([scope](14-target-link-and-fault-prototype.md)) |
| `workspace.zig` / `memory_budget.zig` | Measured fixed buffer with no fallback, reset erasure and provisional target ABI inventory | Host workload peaks and target type sizes, not a full linked-image/transitive-stack proof; see [memory budget](12-rp2350-memory-budget.md) |

The approval flow binds exact request bytes and rendered page bytes. It does **not** establish that
those page bytes are a complete or correct interpretation of the transaction. The BTC integration below constructs bounded pages from a frozen request and refuses unsupported
content. EVM and additional BTC input types still need their own complete review integration.
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

### Approved BTC workflow (host prototype)

`firmware/src/apps/btc/review.zig` and `approved_sign.zig` now connect the gate to the real
independent-plan-checked `signPsbtWithPlan` entry point, with integration tests in
`firmware/tests/approved_btc_test.zig`. Legacy `signPsbtBytes` remains a compatibility wrapper.

- Freeze at most 64 KiB before parsing. Retain no transport pointer in the workflow.
- Accept only non-finalized **native P2WPKH inputs**, SIGHASH_ALL, and known witness_utxo
  amounts. Redundant non_witness_utxo is deliberately outside the independent guard's policy.
  Other input types, unknown amounts, excess pages, unknown output scripts and invalid totals
  are refused before seed ownership. BIP32 input metadata, if supplied, is limited to eight exact
  five-level BIP84 candidates; mismatch does not trigger broad fallback. Metadata-free requests
  use only bounded BIP84 account-0 search (coin 0/1, branch 0/1, indices 0–20). No partial output
  or inferred change classification is published.
- Show network, version, locktime, input/output counts, sighash policy, every input txid/vout/
  sequence/amount, every complete destination and amount, totals and fee. All outputs are
  conservatively labeled payments: no output is hidden as presumed change.
- At most 64 explicit pages, six ASCII lines of at most 26 characters each. Addresses/txids are
  split across lines, never abbreviated. Rendering rejects implicit extra pagination and supports
  240×135 and 240×240 only. HAL must acknowledge each successfully transferred physical page.
- A Secure-selected network is displayed and committed; PSBTs do not authenticate networks.
  Witness UTXO amounts are host-supplied and **not independently checked against a blockchain**;
  review pages explicitly warn about this.
- Before approval and again before signing, independently parse the wire request and compute
  each BIP143 message; compare counts/totals/fee with primary review and commit the plan.
  Before entropy, rebuild/compare both presentation and independent plan from owned bytes.
  The primary signer preflights EVERY message before key lookup/signatures, then compares the
  actual key-derived message again directly before C signing and verifies every ECDSA result.
  Require signatures for every input and the reviewed fee. Consume approval before the operation, return
  output only after success, and wipe session-owned seed/input plus the adapter's master-key
  backing copy on all exits. Result allocations belong to a caller-owned arena, discarded on error.
- The pinned Core transaction matches byte-for-byte after synthetic review/approval. Tests also
  exercise pre-approval refusal, request mutation, network changes, media removal, timeout,
  wrong wallet, multiple outputs, unsupported schemes and rendering on both screen sizes.

Presentation revalidation still uses the primary parser; [independent message validation](13-independent-p2wpkh-guard.md)
now protects only the approved native-P2WPKH subset, not project-wide I-3 or physical isolation. Owned master,
derivation intermediates and C-context backing storage are erased, but by-value parameters,
compiler spills/registers and C internal temporary stacks are still not proven erased. TrustZone, physical HAL, seed entry,
periodic polling and result transport are still pending. Direct CLI signing remains separate.
The development board remains reflashable; none of this code burns OTP or disables BOOTSEL/SWD.

## 5. TRNG and fault response plan

The production policy requires healthy entropy, but no target TRNG HAL exists yet. The new
`security/rng.zig` provides the mockable bounded interface: at most 256 output bytes and 1,024
nonblocking provider polls per fill. It accepts ready words, waits for not-ready status within the
budget, rejects reported health failure/unavailability, wipes the entire destination on error and
latches failure for the session. No time/ADC/PRNG fallback or deterministic production source.
The provider must implement actual Secure-world hardware initialization/status semantics; a poll
count is not a wall-clock timeout if a provider violates the nonblocking contract. Statistical tests
or observing nonzero output do not prove entropy. Existing required dice input remains required.

Approved BTC `Workflow.sign` now requires an explicit `*rng.Rng`. It requests 32 fresh blinding
bytes only after valid approval and presentation revalidation, before key derivation/signing. A
failed entropy request consumes approval and erases the owned session. Context randomization
does not change RFC6979 signature bytes; the pinned Bitcoin Core transaction still matches.

`secp256k1.ContextOwner` uses the library's
[preallocated API](https://github.com/bitcoin-core/secp256k1/blob/master/include/secp256k1_preallocated.h):
no context malloc/free, 4,096-byte aligned backing capacity, actual required size checked at
runtime. `SigningLease` retires the development context, creates/randomizes a fresh one, rejects
nested signing scopes, and on exit calls the correct C preallocated destructor **before** securely
erasing the whole allocation. Tests check the backing bytes only after destruction. Legacy CLI
operations still lazily create an unrandomized development context; they are not production APIs.

The compatibility context remains a shared singleton, **not thread-safe or a TrustZone boundary**.
Only serialized trusted execution may use the lease: park the secondary core and prevent crypto
interrupt re-entry. Never copy an active owner/lease; do not read live C backing memory. Nested
lease refusal is a logical guard, not synchronization or fault-injection resistance.

The new `schnorrSignRandomized` primitive requests 64 fresh bytes (separate halves for context
blinding and BIP340 auxiliary randomness), verifies the result and wipes its entropy/context.
It is not yet connected to an approved Taproot transaction workflow. Deterministic `schnorrSign`
and low-level explicit-aux helpers remain for vectors/development, not the production path.

BIP32/key-source ownership now has explicit wipe methods. Derivation loops erase intermediates
before replacement and on exit; BTC key discovery erases each derived node, including nonmatching
candidates, and the approved adapter borrows its key source rather than forwarding it by value.
Master-generation and extended-key parse/serialization buffers are also erased. This is NOT proof
that caller copies, all by-value API parameters, encoding/HMAC internals, spills, registers or C
stack temporaries are erased. Measure constant-time target compilation and stack use for the
actual linked libsecp256k1 configuration.
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
SRAM can reduce external-flash substitution risks, but the complete linked-image/stack budget
and SRAM-resident secp tables still need measurement. The [new provisional inventory and fixed
workspace tests](12-rp2350-memory-budget.md) do not establish an SRAM-resident-code fit. Do not claim signed XIP code
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
zig build memory --summary all  # provisional ABI inventory, not actual stack/image bounds
```

New modules are included in the full host suite. The Pico smoke check references the orchestrator
with a synthetic review and hash-only callback, plus the actual approved BTC adapter with
synthetic trusted events and an injected RNG, plus the randomized BIP340 primitive;
all compile for Cortex-M0+ and Cortex-M33.
Compilation on RP2040 does not give it RP2350 security features. Neither result is execution,
a signed UF2, a complete bootable Secure/Non-secure wallet or a hardware security test.
The separate [offline link/fatal harness](14-target-link-and-fault-prototype.md) now provides real
partial-image section/frame measurements and instruction checks, not actual hardware attribution.

Before any real-funds claim: actual linked target boot, measured SRAM/stack budget, trusted
complete display and physical approval, constrained NS gateway, seed-copy/C-context erasure,
TRNG error tests, secure-boot/OTP readback, invalid-boot and NS/DMA access rejection, signed
update/rollback/power-failure tests, BTC Signet/EVM Sepolia interoperability, independent security
review and physical side-channel/fault assessment. These gates remain open.
