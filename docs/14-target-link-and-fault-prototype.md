# 14. Offline Cortex-M33 linking, static frames and fatal-wipe prototype

**Experimental. These are link harnesses, NOT bootable RP2350 wallet firmware.**
They have no boot/vector metadata, initialized main loop, CMSE/NS gateway, SAU/MPU/DMA
attribution or target HAL. Entry halts; no synthetic approval, healthy entropy or real seed is
embedded. Do not package/flash these ELF files or infer that the silicon security policy is active.

## 1. What changed from the object-only smoke check

`zig build pico` continues to check source portability without resolving C symbols. The new
`zig build target-link` actually **links** the approved native-P2WPKH signing/review/rendering
path and target-built libsecp256k1, plus a separate minimal NS-region ELF. It checks real load
segments, allocated sections, unresolved symbols and surviving signing/context functions.

Large owned workflow/workspace/framebuffer objects are in dedicated retained NOLOAD
sections, not automatic event-loop objects. The NS harness reserves ingress and a stack but
contains no crypto. The exported Secure reachability functions are internal testing hooks,
**not NS-callable APIs**: they take trusted seed/evidence/provider pointers and must never be
exposed through a production gateway. Zig visibility and separate linker files do not enforce I-2.

The harness is intentionally not a UF2 and cannot validate authenticated updates, recovery,
rollback, boot policy, physical approval or execution on RP2350. BOOTSEL/SWD/OTP are untouched.

## 2. Pinned target crypto and safety mode

`firmware/target/dependencies.json` records:

- Zig **0.17.0**, rejected if the invoking compiler version differs.
- libsecp256k1 **0.8.0**, upstream commit
  `6e2c8bc4ecdc6e71dbe7a368f360d8d453ce435d`.
- Archive SHA256 `3fe9fd705f4fdf2fe90d6e04b6c1fedd7e8f244a119315886f6468f52c2dfc33`.
- `USE_FORCE_WIDEMUL_INT64=1`: 32-bit limb arithmetic (field 10×26/scalar 8×32), no
  assumed native 128-bit arithmetic. Verification window 4; generator COMB_BLOCKS=11,
  COMB_TEETH=6. Recovery/extrakeys/Schnorr modules are enabled at compilation; unused
  code is GC'd, not necessarily present in the approved-path image.

No host libsecp256k1, target heap or stdio implementation is linked. Minimal freestanding headers
provide declarations only; accidentally reachable heap/logging functions fail linking or the ELF
tripwire. Preallocated context create/randomize/destroy and ECDSA sign/verify must survive.
The selected target C context's **struct size is 184 bytes**, measured from an ELF constant,
not by running ARM code. Runtime preallocated-size/alignment checks still apply to the full
4,096-byte owned backing. This size observation is not a universal library ABI guarantee.

The target harness defaults to **ReleaseSafe** Zig IR, retaining bounds/overflow traps. Because
this Zig toolchain's stack-report option did not produce usable ARM metadata, the same bundled
Clang lowers emitted optimized IR with `-Os -fstack-size-section`. C also emits stack metadata.
This two-stage path is explicit, not an assumed report from the original Zig object backend.
The compiler-rt provided by the final Zig link does not emit all frame metadata.

Pinned versions/checksums improve input reproducibility, not a bit-for-bit reproducible-build or
constant-time target execution proof. Debug source paths may differ. Pico SDK is **not used** by
this harness; pin/review it when implementing actual startup, ROM helpers and HAL.

## 3. Commands, dependency checks and artifacts

```bash
cd firmware
# First invocation: explicit permission to download the verified source archive.
zig build target-link -Dtarget-fetch=true --summary all
# After caching, an offline rebuild needs no fetch permission:
zig build target-link --summary all
# Same C arithmetic/tables, run ALL wallet tests on HOST in four Zig modes:
zig build target-config-test -Dtarget-fetch=true --summary all
cd ..
python3 -m unittest discover -s tools/tests -v
# Optional separate smaller-code comparison, still not firmware execution:
python3 tools/check_target_link.py --optimize ReleaseSmall --out firmware/zig-out/target-link-small
# Offline source archive alternative (must match pinned SHA):
python3 tools/check_target_link.py --archive /path/to/secp256k1.tar.gz
```

Every build checks the archive checksum and extracts a fresh source tree. Extraction rejects
traversal, links/special files, duplicate normalized paths and excessive expansion. Downloads are
published atomically, not trusted from a partially written cache. A failed invocation invalidates
its old success report. Separate outputs avoid target-link/config-test artifact races.

Artifacts are ignored build outputs under `firmware/zig-out/target-link/` (or `target-config-test/`):
`secure-link-only.elf`, `nonsecure-link-only.elf`, target C/Zig objects, `secure.ll`, `report.json`,
and `stack-frames.json`. No seed or test mnemonic is embedded by the link harness itself.
The optional host test executable uses public fixtures as before, **not actual ARM execution**.

The dependency-free ELF reader checks truncation/table/string bounds, ARM ELF32/Thumb entry,
partition containment, matching file/memory load segments, no allocated-section overlap, RAM
non-execution, flash non-writability, dedicated sizes and absence of heap/logging/context-allocation
APIs. It parses linked stack ULEB128 data and rejects unresolved/duplicate entries. These tests
are tooling regression checks, not a general verified ELF loader or secure boot verifier.

## 4. Measured candidate map (not configured hardware attribution)

| Partition | Range | Capacity |
|---|---|---:|
| Secure code/data load | `0x10000000..0x10100000` | 1 MiB |
| NS code/data load | `0x10100000..0x10200000` | 1 MiB |
| Secure SRAM | `0x20000000..0x2006e000` | 440 KiB |
| NS SRAM | `0x2006e000..0x20082000` | 80 KiB |

These are candidate virtual memory assignments. SRAM banks/aliases, boot-ROM scratch use,
NSC granularity and actual SDK/board attribution must be reviewed before real target use.

Current measurements:

| Harness | Flash load bytes | Reserved SRAM bytes | Partition margin |
|---|---:|---:|---:|
| Secure, ReleaseSafe IR | 200,924 | 385,456 | 65,104 |
| Secure, ReleaseSmall IR | 127,292 | 385,456 | 65,104 |
| Minimal NS | 24 | 73,728 | 8,192 |

Combined SRAM reservation is **459,184 bytes**, leaving **73,296 bytes** across both partitions.
This includes the 64 KiB main stack, separate 8 KiB fatal stack, 8 KiB NS stack and provisional
32 KiB HAL reserve. The type inventory schema is now 2 and counts those separate stacks;
its planned total is 459,144 bytes, differing slightly from actual sections/alignment/globals.

This is a real fit check of this **partial link harness**, NOT a complete-wallet fit or stack proof.
The real gateway, SDK globals/boot workspaces, TRNG/SPI/DMA/IRQ state, camera/QR pipeline,
other chains and update/recovery implementation are not all linked/reserved here. The
framebuffer is already included; a camera frame (320 × 240, 76,800 bytes) does not fit in the margin.

## 5. Stack evidence and limits

ReleaseSafe currently reports **167 functions with metadata**; the largest observed frame is
**14,736 bytes** at the signing reachability entry. ReleaseSmall reports 292, largest 15,128.
The independent guard itself has a 6,032-byte measured frame. Inlining changes counts/frames.

These are **individual static frames, not a transitive maximum**. Reports explicitly contain
`transitive_bound_proven: false` and list functions without metadata, notably compiler-rt/ARM
helpers. Indirect allocator/RNG callbacks, recursion/call-chain composition, interrupt nesting,
exception frames, MSP/PSP usage, guards/MSPLIM and runtime high-water remain open. Never
replace the 64 KiB reserve with the largest single frame or claim 8 KiB is a proven fatal-stack bound.

## 6. Fatal ownership and ARM entry prototype

`ContextOwner.poison` permanently refuses reuse and erases its known fixed backing **without
calling C with a potentially corrupt context/pointer**. Normal deinit does not clear the poison
latch. A host test corrupts a local owned pointer to address 1, poisons it without dereferencing it,
checks full backing erasure, then verifies that get/deinit/get cannot reconstruct it. The shared
`poisonContextAndAbandon` is fatal-only: caller must abandon borrows and never resume C.

The offline target C callbacks and Zig panic dispatcher enter a non-inlined naked ARM routine:

1. Mask ordinary interrupts with CPSID I; install the dedicated fatal MSP; clear CONTROL.SPSEL
   and issue ISB. This assumes **privileged Secure execution**, not an arbitrary caller state.
2. Clear r0–r12, LR and APSR_NZCVQ before the C-ABI wipe routine can spill old general registers
   onto the new stack.
3. Abandon/poison the C context, erase fixed workflow/workspace/control/framebuffer spans,
   then erase the known old designated signing stack from the separate fatal stack.
4. Halt without logging, returning to C, resetting the poison latch or publishing partial results.

The compiler cannot inline this naked sequence. `fatal_entry_check.py` validates its compiled
bytes: no prologue, IRQ masking, MOVW/MOVT relocated exactly to the linker fatal-stack top,
MSP/CONTROL/barrier/register-clear instructions and unconditional branch to the wipe routine.
Tests reject every single-bit mutation of the inspected sequence and incorrect linker addresses.
This is a **build tripwire**, not evidence that the operations execute correctly on silicon.

It is not an installed HardFault/NMI handler. It does not prove erasure of every possible
PSP/interrupt/exception stack, caller-copy buffer, FPU/special register, other core, DMA/peripheral
state, remanence or power-loss state. It does not configure MSP/MSPLIM/MPU for normal startup.
NMI/HardFault during wiping and damaged stack/control state before dispatch need actual target
handling/tests. Secondary-core parking and DMA exclusion remain prerequisites. Do not infer
fault-injection resistance or complete session-wide erasure from compilation.

## 7. Signing work is bounded more conservatively

The independent guard now limits input BIP32 metadata to **eight** compressed-key candidates,
each an exact five-index `m/84'/coin'/account'/branch/index` path: coin 0 or 1, hardened account,
branch 0/1, non-hardened address index. This excludes arbitrary-depth metadata, master-key
signing and unrelated EVM/legacy purposes from the approved subset. Public point validity is
still checked by the primary parser. Coin path is not authenticated network selection.

Explicit metadata that does not match the wallet cannot silently trigger broad discovery. For
metadata-free Core-compatible requests, approved signing searches only BIP84 account 0,
coin 0/1, branch 0/1, indices 0–20: at most 84 candidate paths, 420 private-child operations per
input. Runtime/time/power bounds on the real chip remain unmeasured; there is no measured
signing deadline. Larger indices/accounts should supply correct bounded explicit metadata.
The approved adapter fixes this scan cap; trusted direct plan API callers must also respect it.

Approved signing no longer runs unused change-discovery scans: every output stays a payment,
and `change_outputs` is empty. Legacy CLI APIs retain their broader development behavior.

Additional host tests cover valid/invalid metadata shapes/purposes/branches, eight-candidate
boundary, over-cap metadata-free scans, explicit fingerprint mismatch without fallback, and:

- A two-input PSBT padded to exactly 64 KiB signs both inputs using the fixed 128 KiB workspace;
  all unknown padding is preserved, peak **100,550 bytes**, two complete witnesses, no inferred
  change. UTXOs are synthetic host-supplied data, not independently authenticated chain outputs.
- A foreign second input refuses the entire result even after an internal first signature; owned
  seed/request are erased and the next context lease can be acquired. No partial output is returned.

## 8. Remaining release blockers

Actual SDK/startup/vector/boot integration and Secure→NS transition; authenticated boot/update/
recovery/rollback; constrained CMSE gateway with no key/evidence/provider pointers supplied by
NS; real attribution/physical display and approval; TRNG health semantics; all transitive/IRQ stack
bounds and normal-success spill/register erasure; broader guarded BTC/EVM coverage; target
execution and independent audit. Development must remain reflashable throughout this work.
