# Next-session handoff

## Latest: hardware decided, enclosure redesigned, licences aligned (2026-10-14)

Owner decisions this session:

- **Parts**: RP2350-PiZero + Adafruit Mini PiTFT #4393 + **ArduCam UC-805** (Arducam B0315, HM01B0).
  The light receiver (OPT4048) is out, and its code has been removed.
- **Camera looks out of the back** (SeedSigner style); **thin first**: the camera sits beside the board
  and the four header-side jumper ends are unhoused and insulated (heat-shrink/tape), so the case is
  the display's height.
- **No sealing** (users build their own); **a clear case is recommended** for inspection instead.
- **CAD = SolidCraft**. **Licences**: firmware and tools **MIT** (was GPL-3.0-or-later), hardware
  incl. enclosure **CERN-OHL-S-2.0** (enclosure was CC-BY-SA-4.0), docs CC-BY-4.0, logo CC-BY-SA-4.0
  when one exists, name via `TRADEMARKS.md`. REUSE layout (`LICENSES/`, `REUSE.toml`).
- **Language preference**: Zig first, Go only where Zig can't, **no new Python**.

State:

- `hardware/enclosure/case.zig` (CERN-OHL-S) is the parametric source: 42 analytic checks, writes three
  SolidCraft scripts; `zig run case.zig -- verify results.json` checks SolidCraft's interference
  result. Case 97.2 × 38.6 × 19.7 mm; 7 × M2 × 16 from underneath (one per corner at a 4.5 mm inset, one mid-rear, two through the board's own holes); the lens on the golden section of the depth from the front edge; a 2.07 mm lip against torsion; no feet, no engraving or lettering; STEP + 3 STLs exported with
  SolidCraft 0.8.0 and committed. **Nothing measured**: the UC-805 has no published drawing.
- `tools/license_check.zig` replaces `reuse lint` (Python); CI runs it and the enclosure checks.
- Pin map (RP2350-PiZero numbering differs from the Pi on pins 7, 8, 10, 19, 21, 23, 29, 32):
  PiTFT on **SPI1** (MOSI 11, SCK 10, CS 8), DC 25, BL 22, buttons 23/24, I²C1 2/3; camera
  D0 9, PCLK 13, HREF 15, VSYNC 16, I²C 0x24, 2.8 V I/O, never drive XCLK. See docs/03 §3.

Next:

1. Buy the parts and measure the `MEASURED` values (UC-805 outline/holes/lens, BAT connector height,
   header stack height, bare-terminal height), then re-run the checks and print the base first.
2. Camera HAL: PIO one-bit capture → `qr_decode.zig` on the target.
3. Port the remaining Python tools under `tools/` to Zig (the user prefers not to keep Python).

## Earlier: security review and boundary hardening

Internal follow-up review: [15-security-audit-2026-10-14.md](15-security-audit-2026-10-14.md).
The offline target harness now rejects zero/oversized ABI lengths before constructing raw-pointer
slices, erases the fixed workspace after failed preparation, and fail-closes the session on render
errors. GitHub Actions now has an explicit read-only token, no persisted checkout credential, and a
job timeout. Common secret markers were not found in tracked history. These are defense-in-depth
changes: the exports are still not CMSE gateways, raw-pointer provenance is not established, and
all previously documented hardware/release blockers remain.

## Latest offline target links, fatal-stack prototype and bounded discovery

Follow-up to `3c1d716`: see [14-target-link-and-fault-prototype.md](14-target-link-and-fault-prototype.md).
`zig build target-link -Dtarget-fetch=true` now performs actual Cortex-M33 Secure/NS-region
links using SHA256/commit-pinned secp256k1 0.8.0 (32-bit field/scalar arithmetic, verification
window 4). No host crypto/heap/stdio. Default ReleaseSafe Zig IR is lowered with bundled Clang
to obtain static frame metadata. Target ELF and archive/instruction readers have adversarial tests.
`target-config-test` also runs ALL wallet tests on HOST with selected C settings in four modes.

Stable dedicated workflow/workspace/framebuffer/NS ingress; 64 KiB main, 8 KiB fatal, 8 KiB NS
stacks. Provisional inventory schema 2 counts all three: planned 509,544, margin 22,936 bytes.
Actual harness combined SRAM 509,584, margin 22,896; Secure partition 435,856/450,560 bytes,
NS 73,728/81,920. Secure flash load 198,300 bytes (ReleaseSafe) / 128,060 (ReleaseSmall).
169/293 functions with frame metadata; largest 14,736/15,128 bytes. **NOT transitive bounds**;
compiler-rt/indirect callback/IRQ and runtime watermarks remain open.

ContextOwner fatal poison wipes fixed backing without calling C through a corrupted pointer,
permanently refuses reuse, and survives normal teardown. Host test uses a corrupt local pointer.
Offline target callbacks/panic dispatch use a noinline naked ARM entry: mask IRQ, switch MSP
onto fatal stack, clear general registers/LR/APSR, then poison and erase fixed buffers/designated
old main stack and halt. Compiled instruction/address sequence is tripwire-checked; bit mutation
unit tests pass. No real HardFault/NMI handler, FPU/other-core/DMA protection or runtime proof.

Input metadata is capped at eight compressed exact five-index BIP84 candidates (coin 0/1,
hardened account, branch 0/1, non-hardened index). Explicit mismatch never broad-falls-back.
Without metadata, only BIP84 account 0 / coin 0/1 / branch 0/1 / indices 0–20 are searched.
Approved adapter sets that cap; trusted direct plan callers must also respect it. Approved signing
skips unused change discovery and returns no inferred change. Legacy development behavior stays.
Two-input 64 KiB request signs both witnesses, preserves padding, fixed-workspace peak 100,550.
Foreign second input refuses whole result even after first internal signature; seed/request wiped
and context lease released. Small/single-input padded peaks remain 2,244/99,722.

Verification: 449 Zig tests, normal host library AND selected 32-bit C configuration, each in four
modes; 19 Python tests; Pico object checks; schema-2 inventory; ReleaseSafe/Small offline links;
CLI/vector/transport regressions. CI includes pinned-source target-config-test.

NOT bootable firmware: no vectors/startup/SDK/CMSE gateway/SAU-MPU attribution/real HAL,
real funds, OTP writing or debug/BOOTSEL lockdown. Next acceptance gates are actual boot/gateway/
HAL composition, full transitive/IRQ stack/runtime tests, normal-return spill/caller-copy erasure,
signed update/recovery and broader guarded BTC/EVM support. No hardware is available yet.

## Latest independent P2WPKH guard

Follow-up to `7ac030a` adds `security/p2wpkh_guard.zig`, importing only std (CI dependency
tripwire). It independently scans raw PSBTv0/canonical transaction bytes and streams BIP143
hashes, without application parsers/serializers/hash helpers or allocation. Scope: native P2WPKH,
SIGHASH_ALL, witness_utxo-only, 31 inputs/62 outputs/128 fields per map/64 KiB. Non-witness
UTXO metadata (even redundant), finalized inputs and other schemes are rejected. See
[13-independent-p2wpkh-guard.md](13-independent-p2wpkh-guard.md).

Approved workflow compares independent counts/totals/fee with primary review, commits the
plan before approval, and rebuilds it before entropy. `signPsbtWithPlan` checks EVERY primary
message before input-key discovery/signatures, then rechecks the actual key-derived message
immediately before C signing. Direct legacy APIs remain unguarded development paths.

Verification: 443 Zig tests in four modes, five Python tool/dependency tests, Pico compile checks,
target memory inventory, CLI build and BIP84/Core/fee-display/BC-UR/EIP-1559 CLI regressions.
Official BIP143 hash and pinned Core final transaction
match. Differential mutations: 468/512 accepted and all matched primary hashes; other mutations
refused. Plan-corruption test refuses before entropy and wipes; malformed/truncated/duplicate/
noncanonical/oversized input tests and all-input preflight test pass. Fixed workspace peaks remain
2,244 / 99,722 bytes for the small/padded Core requests. Target provisional total is now 493,160
bytes; margin 39,320. Guard temporaries are stack-resident, with transitive stack bounds still open.

This is partial I-3 software diversity, NOT project-wide I-3, I-2, independent SHA/compiler/CPU,
full BIP174/independent address rendering, actual physical approval or fault-injection resistance.
Next: actual Secure/NS link and constrained gateway, explicit-context/key ownership boundaries,
Zig/C/IRQ stack bounds and hardware HAL. No OTP changes; development remains reflashable.

## Latest bounded-memory work

Remote `main` was confirmed synchronized at `1794466` before continuing. New work adds
`security/workspace.zig` (fixed allocator, high-water/failure counters and whole-buffer reset),
`security/memory_budget.zig`, compile-only `memory_layout.zig` and dependency-free Python
ELF inventory reader/tests. `zig build memory` reads Cortex-M33 target ABI sizes; CI checks it.
See [12-rp2350-memory-budget.md](12-rp2350-memory-budget.md).

Provisional target inventory: 493,104 bytes counted including unvalidated stack/HAL reserves,
39,376 bytes unallocated margin. This is NOT a linked-image fit or transitive stack proof. Place
large workflow/ingress/workspace/framebuffer objects in dedicated stable storage, not the target
stack. The compile-only smoke helper is not a real main loop/memory layout.

Host approved-BTC workload checks use only a 128 KiB fixed workspace for request processing
and result allocations. Peaks: 2,244 bytes for the small pinned Core request; 99,722 bytes for that
transaction padded to exactly 64 KiB. Results match the pinned transaction; unknown padding is
preserved. Repeated reset sessions do not accumulate allocations, and the whole buffer is erased.
OOM at prepare, post-approval revalidation and post-entropy signer allocation wipes the owned
session and returns no result. These workloads are not a worst-case bound for every 64 KiB PSBT.

Verification: 432 Zig tests in four modes, four Python reader tests, Pico compile checks, target
inventory and CLI build. Still no real target/OTP/HAL/TRNG/security attribution. Next: actual
Secure/NS link/map and Zig/C/IRQ stack upper bounds, independent signing-plan validation,
explicit-context isolation and hardware drivers. Development remains reflashable.

## Latest entropy/context/key-lifecycle hardening

Follow-up to `6a263ec` adds `security/rng.zig`, mandatory RNG injection in approved BTC
`Workflow.sign(..., rng)`, preallocated libsecp256k1 context ownership and single-threaded
randomized signing leases. Context destruction is followed by whole-allocation erasure; context
heap allocation is removed. New `schnorrSignRandomized` requests separate blinding/auxiliary
bytes and verifies signatures, but is not an approved Taproot transaction workflow.

BIP32 master/parse/serialize/derivation buffers and BTC key-discovery intermediates have explicit
wipes. The approved signer borrows its owned key source via `signPsbtWithKeys`. This still does
not prove all by-value/caller copies, C internal stacks, registers or compiler spills are erased.
The crypto singleton/lease is not thread-safe: target integration must serialize trusted execution,
park the other core and prevent crypto interrupt re-entry. Never copy active owners/leases.

Verification: 425/425 tests in Debug/ReleaseSafe/ReleaseFast/ReleaseSmall and RP2040/RP2350
compilation checks (including injected-RNG BTC and randomized BIP340). No real TRNG/MMIO,
OTP, signed UF2, physical approval or TrustZone setup has been implemented. Development
interfaces remain writable. Next priorities: target memory/stack budget, independent signing-plan
validation, explicit-context crypto boundaries and actual Secure-world HAL.

## Latest approved BTC integration

Security foundations were committed and pushed as `24eab88`. Follow-up work adds
`src/apps/btc/review.zig`, `approved_sign.zig` and seven integration tests. The separate host
workflow freezes PSBT bytes, generates bounded complete review pages, traverses the gate,
revalidates presentation and calls the real signer. Its final transaction matches the pinned Core
vector. Initial input policy is P2WPKH/SIGHASH_ALL/known amounts; no hidden change or partial
signing result. All 412 tests passed in all four optimization modes, and both Pico compilation
checks include the actual adapter with synthetic events.

No OTP programming or hardware-interface lockdown is implemented. Development remains
reflashable. Still pending: physical HAL, actual seed entry, Secure/NS isolation, true independent
sighash validation, complete key-copy/context erasure, other BTC/EVM inputs, measured memory
budget and recovery/update/rollback design. Direct CLI signing stays a development tool.

The sections below preserve earlier snapshots; use the current firmware README and security
design for current capabilities.

## Latest hardware-free RP2350 security work

The base review fixes are committed in `1fbcc39`. Subsequent local work adds four modules under
`firmware/src/security/`: semantic boot policy, owned-request/page approval gate, erasable secret
session, and mock-signer orchestration. See [11-rp2350-security.md](11-rp2350-security.md).
No push, target provisioning, signed UF2, hardware execution or real-funds operation was performed.

Verification: **405/405** tests passed in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall;
RP2040/RP2350 compile checks (including the new orchestration) and CLI build passed on macOS.
Use installed Zig 0.17.0 (`/opt/homebrew/bin/zig`) in `/Users/midasdf/OSHWW/firmware` on this machine.

Next: integrate the prototype with a frozen canonical BTC request and complete display traversal,
then a trusted signer with signature verification and full key/context wipe. The existing CLI still
signs immediately. Collect boot evidence and GPIO/display events only from a future Secure HAL;
caller-supplied booleans and mock events are not hardware security. Target prerequisites include
A4 verification, Secure/NS linked images, SRAM/stack budget, TRNG, signed update/rollback policy,
OTP readback and deliberate NS/DMA access rejection. Do not provision OTP before recovery review.

The snapshot below is historical context from the previous internal review.

## State snapshot

- Date: 2026-10-13
- Base commit reviewed: `e84f1b7`
- Working tree: security fixes and documentation corrections are present but not committed or pushed.
- Internal review: [10-security-audit-2026-10-13.md](10-security-audit-2026-10-13.md)
- Verification completed after the fixes:
  - Debug: 391/391 tests passed
  - ReleaseSafe: 391/391 tests passed
  - ReleaseFast: 391/391 tests passed
  - ReleaseSmall: 391/391 tests passed
  - RP2040 and RP2350 ReleaseSmall compile checks passed
  - CLI build, BIP84 address, pinned Bitcoin signature, pinned EIP-1559 signature/decode, BC-UR round trip, FAT32 image handoff plus `fsck.fat`, and invalid-mnemonic rejection passed
- The project is still not hardware-wallet firmware. There is no target main loop, physical approval gate, I-2 key boundary, I-3 independent hash comparison, or complete session wipe.

## Next priority tasks

1. Review the current diff as a security patch; split it into coherent commits if desired.
2. Implement an immutable `PreparedRequest` → complete display traversal → physical approval → `ApprovedRequest` → sign state machine on the host before HAL work.
3. Decide how to implement the I-2 key boundary and whether I-3 will use a genuinely independent parser/hash implementation. Do not preserve the claim without the mechanism.
4. Introduce a session-owned secret container with a single secure wipe transition and backing-memory tests.
5. Integrate P2TR and P2WSH into PSBT parse/display/sign/serialize/finalize.
6. Integrate EVM transaction/EIP-712 parsing, ERC-7730 rendering, chainId display, and signing into the same approved-request flow.
7. Wire context randomization and BIP340 auxiliary randomness to a mockable RNG interface, then to target TRNG.

## Verification commands (verbatim)

The repository targets Zig 0.17.0. On this machine the downloaded compiler used for the review is under `/tmp`; download it again if that directory has been cleared.

```bash
export PATH=/tmp/zhww-tools/zig-x86_64-linux-0.17.0:$PATH
cd /home/midasdf/zhww/firmware
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test -Doptimize=ReleaseFast --summary all
zig build test -Doptimize=ReleaseSmall --summary all
zig build pico --summary all
zig build --summary all
./zig-out/bin/zhww version
```

Pinned Bitcoin and EVM smoke checks:

```bash
export PATH=/tmp/zhww-tools/zig-x86_64-linux-0.17.0:$PATH
cd /home/midasdf/zhww/firmware
MN='abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about'
test "$(./zig-out/bin/zhww address --mnemonic "$MN")" = 'bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu'
PSBT=$(jq -r .unsigned_psbt_base64 tests/vectors/core_psbt.json)
EXPECTED=$(jq -r .expected_final_tx tests/vectors/core_psbt.json)
MINE=$(printf '%s' "$PSBT" | ./zig-out/bin/zhww sign --mnemonic "$MN" 2>/dev/null | grep '^FINAL_TX=' | cut -d= -f2-)
test "$MINE" = "$EXPECTED"
UR_BACK=$(printf '%s' "$PSBT" | ./zig-out/bin/zhww ur --fragment 40 2>/dev/null | ./zig-out/bin/zhww ur-decode 2>/dev/null)
test "$UR_BACK" = "$PSBT"
TX=$(printf '%s' '{"chainId":1,"nonce":7,"gasLimit":21000,"maxFeePerGas":30000000000,"maxPriorityFeePerGas":1000000000,"to":"0x3535353535353535353535353535353535353535","value":123456789,"data":"0x"}' | ./zig-out/bin/zhww evm-sign --mnemonic "$MN" 2>/dev/null)
test "$TX" = '02f86f0107843b9aca008506fc23ac0082520894353535353535353535353535353535353535353584075bcd1580c080a08b29bfd611a0f695677f38218b2a6d02218f906adedbb1f171aa49b261794de2a02e5c9604faa6d3f48c89f8568aa04ea6cef7e058d0464ef4447989524c1bd4cf'
```

Documentation and diff checks:

```bash
cd /home/midasdf/zhww
git diff --check
uv run /home/midasdf/.agents/skills/natural-japanese/scripts/lint.py --json --genre tech README.ja.md
```

## Landmines

- `signPsbtBytes` does not support P2TR or P2WSH. Do not infer integration from standalone Core interoperability tests.
- `zhww sign`, `zhww card sign`, and `zhww evm-sign` sign immediately. They are development tools, not an approval workflow.
- Do not call signing merely to compute display metadata. This review removed exactly that behavior from change detection.
- Display and signing must use `btc_sign.utxoForDisplay`/the shared resolver. A separate preference for `witness_utxo` reintroduces the legacy-input fee-spoofing issue.
- Do not return slices or pointers into by-value parameters or loop-local arrays. The Taproot witness helper had this bug.
- Use `std.crypto.secureZero`, not `@memset`, for secret erasure. Even then, by-value copies and allocator pages remain a design problem.
- Do not use `(a + b - 1) / b` for attacker-controlled lengths. `a + b - 1` can overflow; use quotient/remainder ceiling division.
- MBR partition length and BPB volume length are separate trust boundaries. The BPB must not authorize sectors outside the partition.
- ERC-7730 intent is untrusted presentation data until canonical calldata decoding and deployment/chain/address matching succeed.
- The repository language policy requires English source documents. `README.ja.md` is a translation and was linted separately.
- No push, release, deployment, or real-funds operation was performed.

## Decisions already made

- 2026-10-13: Keep the project marked experimental and unsuitable for real funds.
- 2026-10-13: Treat the current review as an internal source review, not a third-party audit.
- 2026-10-13: Describe P2TR/P2WSH and EVM clear signing as standalone components until integrated into the normal approved-request workflow.
- 2026-10-13: Enforce exact documented dice counts rather than warning after producing a mnemonic.
- 2026-10-13: Reject unsupported PSBT sighash requests instead of silently signing `SIGHASH_ALL`.
- 2026-10-13: Reject non-empty EVM access lists in the CLI until parsing them into the signed transaction is implemented.
- 2026-10-13: Make documentation distinguish target invariants from current implementation properties.
