# 12. RP2350 SRAM inventory and bounded-workspace validation

**Experimental. This is not proof that a complete linked wallet firmware fits in SRAM.**
No target execution, linked Secure/Non-secure image, transitive stack bound, camera buffer or
real HAL is measured here. Stack/HAL values below are provisional reservations.

## 1. Reproduce without hardware

```bash
cd firmware
zig build memory --summary all
zig build test --summary all
# Reader bounds/schema tests, from the repository root:
cd ..
python3 -m unittest discover -s tools/tests -v
```

`zig build memory` compiles `firmware/memory_layout.zig` for **Cortex-M33, 32-bit Arm,
freestanding, ReleaseSmall** using the same Zig executable as the build. It exports a fixed-width
inventory constant; `tools/check_memory_layout.py` reads that symbol from the resulting ELF
without executing it. The script needs Python 3 only, no third-party packages or external ELF tool.
Malformed/truncated object files and inconsistent inventory sums fail the reader tests.

`src/security/memory_budget.zig` calculates workflow/control sizes with `@sizeOf` under the
**target ABI**, and compilation fails if the provisional reservations exceed 520 KiB. This is more
useful than inferring Arm sizes from macOS `sizeof`, but is still only a type/reservation inventory.
CI runs both the reader tests and target inventory.

## 2. Current target inventory (Zig 0.17.0)

| Term | Bytes | Basis |
|---|---:|---|
| Owned BTC workflow | 78,856 | Target ABI type size, includes frozen request, page/plan commitments, seed backing and review pages/totals |
| Fixed workspace control | 20 | Target ABI type size |
| RNG control | 12 | Target ABI type size; hardware-provider state is not included |
| Preallocated secp256k1 context owner | 4,160 | Target ABI size for the 4,096-byte capacity plus pointer/alignment padding |
| Parsing/signing/output workspace | 131,072 | Fixed 128 KiB policy allocation |
| Incoming request buffer | 65,536 | Fixed 64 KiB maximum request allocation |
| One 240×240 RGB565 framebuffer | 115,200 | 240 × 240 × 2; no double buffering |
| **Stack reserve — unvalidated** | 65,536 | Future Zig/C/interrupt stacks combined; NOT compiler-measured maximum |
| **HAL reserve — unvalidated** | 32,768 | Future driver/DMA/transport/control state; NOT an implemented HAL |
| **Planned total** | **493,160** | Sum of the counted terms |
| **Unallocated margin** | **39,320** | 532,480 − 493,160 (about 38.4 KiB) |

The review object is 11,048 bytes **inside** the workflow. It is reported for visibility but must
not be counted twice. Additional automatic/local review copies do use stack and are not covered
by that embedded size alone. The [independent P2WPKH guard](13-independent-p2wpkh-guard.md)
also uses bounded temporary reader/maps/plan state on stack; these must be included in the
future transitive stack measurement, not assumed free because the guard allocates no heap.

The workflow, ingress, workspace and framebuffer must be **dedicated stable storage**, not
large local stack objects in the final main loop. The compile-only Pico smoke helper still uses
local objects for code-generation coverage; it is not a memory-safe target startup/main loop.
Do not equate the above inventory with the smoke helper's actual stack consumption.

This assumes flash-resident public code/assets. Loading all code/secp tables into SRAM for
anti-XIP-substitution hardening or encrypted boot needs a different budget. Extra framebuffers,
camera capture/JPEG/QR decoding buffers, fonts copied into RAM, multicore stacks and additional
NS-side copies are **not included**. All library/SDK globals and actual linker sections still need
accounting; the margin is not a license to add unmeasured buffers.

## 3. Fixed workspace implementation

`src/security/workspace.zig` wraps Zig's `FixedBufferAllocator` with:

- No heap/page-allocator fallback.
- Peak offset accounting including alignment padding and allocations that cannot be reclaimed
  because they are not last-in-first-out.
- Failed allocation/resize attempt counting (an attempted growth can fail even if a later fallback
  allocation succeeds; the counter is not itself a session security fault).
- Maximum-length guards before fixed-buffer additions/growth, to avoid integer overflow.
- Full-buffer secure erasure/reset when all parser arenas and output borrows have expired.

Use at stable addresses and serialize access. Do not reset or copy the workspace while an
allocator, parser arena or returned signing-result slice still refers to it. Result storage is public
transaction data but privacy-sensitive; erase it after publication/discard, not before transport
finishes. Private keys and seeds belong to the separate owned secret/session storage, not this
allocator. A workspace reset does not erase key/register/C-stack copies outside its buffer.

The workflow accepts a caller-supplied allocator, so a future target main loop must deliberately
pass this fixed allocator. Direct development CLI paths still use host allocators. Adding this
wrapper does not automatically constrain every application or the future Non-secure runtime.

## 4. Measured host-side workloads

The test suite calls the **real approved BTC workflow and signer**, with synthetic trusted
review/button events and test-only entropy. JSON/vector/seed setup happens outside the measured
workspace. Its public parsing, presentation scratch, signing allocations and output storage have
only the fixed allocator available. Static workflow/framebuffer/C-context storage and stack use
are not counted in this high-water measurement.

Measured on the development macOS/aarch64 host with Zig 0.17.0:

| Workload | Prepare peak | Combined prepare/sign peak | Workspace capacity |
|---|---:|---:|---:|
| Pinned Core single-input/single-output PSBT | 2,244 bytes | 2,244 bytes | 131,072 bytes |
| Same transaction padded with an unknown global field to exactly 64 KiB | 98,366 bytes | 99,722 bytes | 131,072 bytes |

The signed transaction remains byte-for-byte equal to the pinned Bitcoin Core vector. The large
unknown field is preserved in the signed PSBT. The small-vector flow runs three sessions with
explicit resets; peak usage does not accumulate, and the entire workspace is zero after each reset.
The numbers may change with compiler/allocator/ABI changes; tests report current peaks and
assert the fixed capacity, not historical exact values.

**This is not a worst-case PSBT bound.** Many-input/output maps, non-witness transactions,
unknown-field distributions and allocation fragmentation can cost more than one large padding
field. The approved input policy is native-P2WPKH/SIGHASH_ALL/witness_utxo-only known amounts/
at most 64 review pages, with the independent guard's additional map-field limits. A syntactically valid request under the 64 KiB file limit may still be refused for workspace
exhaustion. Never silently truncate a request, a destination, a warning or an output to make it fit.

## 5. Failure checks

The tests deliberately exhaust workspace at several stages:

1. Preparation with a one-byte workspace: fail before review/seed ownership completes; owned
   workflow storage ends wiped/terminal.
2. After complete approval but before presentation revalidation: no entropy request, no result,
   approval consumed, owned seed/request wiped.
3. Immediately after all context-blinding entropy is returned: signing-context acquisition succeeds,
   the subsequent signer allocation fails, keys/seed are erased and the context lease is released.
4. Allocator maximum-sized requests, failed growth, alignment padding and reset erasure are
   covered separately.

These are stage-specific tests, not exhaustive fault injection at every allocation/instruction.
Output borrows are checked only before workspace reset. A failed attempt is not retried with the
same approval, larger heap fallback or partially published signature.

## 6. Remaining memory acceptance gates

- Link the actual Secure/NS images, SDK and selected libsecp256k1 configuration. Check map files
  for `.data`, `.bss`, TLS if any, SRAM-resident code, tables, vector tables, DMA/driver buffers,
  guards, mailboxes and boot-ROM/SDK reserved SRAM.
- Assign explicit linker regions to owned secrets, workflow, ingress, workspace, framebuffer,
  Secure/NS stacks and any IRQ stack. Prevent NS/DMA writes to Secure regions.
- Produce per-function Zig **and C** stack measurements, including indirect callbacks, recursion,
  error unwinding, interrupt nesting and compiler-generated copies. A maximum individual frame
  is not a transitive call-chain maximum. `zig build pico` does not prove stack safety.
- Replace the provisional 64 KiB stack/32 KiB HAL reserves with measured upper bounds. Add
  stack guards/MPU coverage and fail-closed overflow behavior on the actual target.
- Exercise multi-input/output and adversarial PSBT structures on the exact linked target. Verify
  explicit refusal and erasure under memory pressure; measure actual runtime stack high-water
  without leaking secrets in diagnostics.
- Decide whether camera buffers/decoded input, QR output, FAT32 and signing scratch can share
  non-overlapping lifetimes. Do not share memory across trust domains without explicit ownership
  and erasure transitions.

See [11-rp2350-security.md](11-rp2350-security.md) for the current security boundary and other
release blockers. No OTP programming, development-interface lockdown or real-funds operation
is introduced by this work.
