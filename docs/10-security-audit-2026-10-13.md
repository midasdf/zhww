# Security review — 2026-10-13

- **Reviewed commit**: `e84f1b7`
- **Review date**: 2026-10-13
- **Scope**: Zig firmware and host development CLI, with emphasis on key handling, BTC/PSBT signing, EVM parsing/signing, untrusted transport input, FAT32, and display/signing consistency
- **Result after fixes**: 391/391 tests pass in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall; RP2040 and RP2350 compile checks pass

This was an internal source review, not an independent third-party audit. It does not make the project suitable for real funds.

## 1. Executive summary

The repository contains substantial, well-tested protocol code, but it is not yet a hardware wallet firmware. The target-board HAL, device main loop, approval state machine, and end-to-end display-before-signing gate do not exist. Several statements in the architecture and status documents described target properties as if the code already enforced them.

The review found and fixed concrete parser, signing, display-consistency, memory-lifetime, and filesystem issues. The most important fixed issue allowed a malicious PSBT to make the display use `witness_utxo` for a legacy input while the signer used `non_witness_utxo`. This could spoof the displayed input amount and fee. The display and signer now call the same UTXO resolver.

The largest remaining risks are architectural rather than local parser bugs:

1. There is no on-device approval gate. Public signing functions and development CLI commands sign immediately.
2. The documented independent dual computation of the signing hash is not implemented.
3. Chain application code currently receives and handles private keys, contrary to documented invariant I-2.
4. Session-wide secret erasure is not implemented or demonstrated.
5. Taproot and multisig primitives are tested separately but are not integrated into the general PSBT workflow.

These are release blockers, not documentation nits.

## 2. Fixed findings

### 2.1 Display/signing UTXO mismatch for legacy Bitcoin inputs — critical

**Files**: `firmware/src/apps/btc/sign.zig`, `firmware/src/cli/main.zig`

The CLI display helper preferred `PSBT_IN_WITNESS_UTXO` for every input. The signer correctly refused to use only `witness_utxo` for a legacy input and instead used the full previous transaction from `non_witness_utxo`. A malicious PSBT could therefore provide a fake witness UTXO to control the displayed input amount and fee while the signer used a different previous output.

**Fix**:

- Added one shared UTXO resolver for signing and display.
- Required a nested P2SH-P2WPKH redeem script to hash to the P2SH scriptPubKey.
- When both UTXO forms are present, required their amount and scriptPubKey to match.
- Added regression tests for the legacy-input mismatch.

### 2.2 A “display-only” path generated signatures — high

**File**: `firmware/src/cli/main.zig`

Change detection called the full `btc_sign.sign` function. Therefore `show --mnemonic` and the screen preview generated signatures in memory even though they reported that nothing was signed.

**Fix**: exposed change detection as a non-signing function and changed the display paths to call it directly.

### 2.3 Requested PSBT sighash type was ignored — high

**File**: `firmware/src/apps/btc/sign.zig`

The parser retained `PSBT_IN_SIGHASH_TYPE`, but the signer always generated `SIGHASH_ALL`. This did not normally create a spendable wrong-output signature, but it violated the signing request and the stated refusal policy.

**Fix**: reject every requested type other than `SIGHASH_ALL`. Also reject already-finalized inputs instead of adding incompatible partial signatures.

### 2.4 Taproot witness returned a dangling slice — high

**File**: `firmware/src/apps/btc/taproot.zig`

`witnessFrom` accepted a 64-byte signature by value and returned a slice pointing into that parameter. The slice became invalid when the function returned.

**Fix**: accept a pointer to caller-owned stable storage. The Taproot signing path now also verifies that the private key owns the input script and verifies the generated Schnorr signature before returning it.

### 2.5 Multisig emitted too many signatures — high

**File**: `firmware/src/apps/btc/multisig.zig`

A 2-of-3 script supplied with all three private keys returned three signatures. `CHECKMULTISIG` consumes exactly the required number, so the resulting witness had an extra stack element and failed clean-stack rules.

**Fix**: stop after the required number of signatures. Added a regression check using all three keys.

### 2.6 Invalid or mistyped mnemonics were accepted by wallet entry points — high

**File**: `firmware/src/apps/btc/sign.zig`

PBKDF2 intentionally accepts arbitrary text, and `keysFromMnemonic` called it without first validating the BIP39 vocabulary and checksum. A typo could silently derive an unrelated wallet.

**Fix**: validate the mnemonic before deriving a seed. Seed and temporary entropy buffers now use `std.crypto.secureZero`.

### 2.7 Too few dice rolls produced a wallet — high

**File**: `firmware/src/core/seed/entropy.zig`

The documented policy required 50 rolls for 12 words and 99 for 24 words, but the low-level generation path accepted one roll. The CLI only printed a warning after already generating and outputting the mnemonic.

**Fix**: enforce the exact roll count in the generation function. Exact counts also prevent cross-length base-6 collisions caused by leading rolls of 1. Temporary entropy buffers are securely zeroed.

### 2.8 EVM decoder dropped nested access-list fields — high

**File**: `firmware/src/apps/evm/transaction.zig`

The top-level RLP collector omitted nested lists. Typed transactions therefore lost the access-list field while counting and positioning later fields. Unsigned EIP-1559/EIP-2930 transactions were rejected, and malformed field layouts could be interpreted ambiguously.

**Fix**:

- Preserve byte strings and lists as distinct top-level items.
- Require exact field counts for unsigned and signed forms.
- Validate access-list structure, signature parity, and signature scalar ranges.
- Reject priority fees above max fees.
- Added an unsigned EIP-1559 access-list regression test.

### 2.9 EIP-712 integer widths were not enforced — medium

**File**: `firmware/src/apps/evm/eip712.zig`

Values such as 256 for `uint8` and -129 for `int8` were encoded rather than rejected. Invalid names such as `uint7` could reach the generic integer branch. Mutually recursive types could also duplicate the primary definition in `encodeType`.

**Fix**: validate integer type names and signed/unsigned ranges, reject zero-length fixed arrays, and keep the primary type out of the dependency suffix.

### 2.10 ERC-7730 intent was shown before calldata validation — high

**File**: `firmware/src/apps/evm/clear_signing.zig`

Descriptor-provided text such as “Transfer token” was displayed even when calldata was non-canonical or used an unsupported tuple. The warning followed the misleading action text.

**Fix**: show descriptor intent only after canonical ABI decoding succeeds. Invalid or unsupported calls now show warnings and raw selector/hash information without an `Action` item.

### 2.11 FAT32 writes could escape the MBR partition — high

**File**: `firmware/src/fs/fat32.zig`

The BPB size was checked against the whole block device but not against the selected MBR partition length. A crafted card could describe a filesystem extending into another partition. Mirrored FAT handling also honored reserved active-FAT bits and could write a copy beyond the intended FAT area.

**Fix**:

- Require the BPB volume to fit inside the MBR partition.
- Reject volumes whose last LBA cannot be represented by the block API.
- Force FAT #0 when mirroring is enabled.
- Added mount regression tests.

### 2.12 Hostile UR metadata could overflow or divide by zero — high

**Files**: `firmware/src/transport/ur.zig`, `firmware/src/cli/main.zig`

The older generic UR decoder used `(a + b - 1) / b` on attacker-controlled metadata and did not reject zero-length fragments first. The CLI allocated bitmap/message buffers directly from QR metadata and accepted any UR type.

**Fix**:

- Use overflow-safe ceiling division and reject empty fragments.
- Bound the CLI to `ur:crypto-psbt`, the 64KB PSBT limit, bounded part size, and a part count consistent with the message.
- Use the stricter signing receiver, which detects conflicting duplicate fragments.
- Added overflow-safe length calculations to CBOR and Bytewords helpers.

### 2.13 Arithmetic and key-encoding hardening — medium

**Files**: BTC transaction/signing/display code, BIP32, PSBT, EVM CLI

The review also fixed:

- unchecked BTC input/output totals and percentage calculations;
- EVM fee-product overflow in the display path;
- BIP32 depth wrapping from 255 to 0;
- extended-key version/private-public mismatches;
- unvalidated serialized public-key curve points in xpub/PSBT paths;
- narrowing a PSBT CompactSize value before checking remaining input;
- silent omission of a non-empty EVM access list in `evm-sign`;
- a negative JSON integer reaching `@intCast`.

### 2.14 CI downloads and actions were not pinned strongly — medium

**File**: `.github/workflows/ci.yml`

The Zig archive was downloaded without checking a digest, GitHub Actions were referenced through
movable major tags, and Foundry had no explicit tool version.

**Fix**: verify the Zig 0.17.0 archive SHA-256, pin action commits, and request Foundry v1.8.5.
The Ubuntu `libsecp256k1-dev` package remains distribution-managed rather than source/digest-pinned;
a reproducible release build must pin and build that dependency separately.

## 3. Remaining release blockers

### 3.1 No approval state machine or hardware main loop — critical

The repository has rendering components, host previews, parsers, and signing functions, but no target-device workflow that enforces this sequence:

1. receive and parse;
2. derive all display pages from the exact parsed object;
3. require the user to view every mandatory page;
4. receive physical approval;
5. sign the immutable approved object;
6. wipe all session secrets.

`zhww sign`, `zhww card sign`, and `zhww evm-sign` are development tools and sign immediately. They must not be described as the device approval flow.

### 3.2 Documented dual hash computation is absent — critical

Architecture invariant I-3 says `apps` and `core` independently compute the signing hash and compare the results. The current code computes one hash in the chain module and passes it to libsecp256k1. There is no second implementation, comparison, or approved-display commitment.

Either implement the invariant with genuinely independent code paths or remove it from the design. Calling the same function twice is not independent computation.

### 3.3 Private-key isolation is absent — critical

Architecture invariant I-2 says application code never holds key material. In the current implementation, BTC and EVM application functions receive private keys or `ExtendedKey` values and call signing functions directly. This is a structural mismatch, not a naming issue.

A hardware-wallet boundary should expose a narrow signer API that accepts an approved request identifier/path and never returns private material to chain code.

### 3.4 Session secret erasure is incomplete — critical

Some temporary buffers now use `std.crypto.secureZero`, but master extended private keys, derived nodes, by-value private-key parameters, CLI argument strings, allocator pages, and application session state remain. There is no session object with an auditable `wipe` transition, and FR-13 is not met.

### 3.5 General PSBT workflow lacks Taproot and multisig — high

`signPsbtBytes` supports P2WPKH, P2PKH, P2SH-P2WPKH, and P2PK. Taproot and P2WSH multisig exist as separate modules and interoperability tests, but the normal PSBT parser/sign/serialize/finalize path does not invoke them. Status documentation must preserve this distinction.

### 3.6 EVM clear signing is not connected to EVM signing — high

The ERC-7730 renderer, EIP-712 library, and transaction signer are separate APIs. `evm-sign` signs JSON without invoking clear signing or an approval UI. There is no authenticated descriptor provisioning/update mechanism. Contract descriptors must be treated as security-sensitive data.

### 3.7 Display completeness is not enforced by a signing gate — high

The host `show` command lists all BTC outputs. The bitmap confirmation preview now refuses to hide multiple payment outputs, but this is not tied to signing. A future paged UI must prevent approval until every output, warning, fee, and chain identifier has been visited; merely rendering page numbers is insufficient.

### 3.8 Side-channel randomization is not wired — high

`secp256k1.randomize` exists but no startup path calls it with hardware entropy. Schnorr signing uses all-zero auxiliary randomness. Deterministic signing is valid cryptographically, but target hardware should use context randomization and fresh BIP340 auxiliary randomness for side-channel hardening.

### 3.9 Typed-data and descriptor resource limits are incomplete — high

EIP-712 struct recursion, type dependency traversal, JSON array sizes, and descriptor/ABI type
nesting do not yet have one device-level budget. A 64KB transport limit is not a substitute for
stack-depth and work limits. The approved-request parser must reject input that exceeds explicit
nesting, field-count, array-length, and display-page limits before rendering or signing.

### 3.10 Hardware and release security claims are unverified — high

The firmware has not run on the target board. Secure boot, read-only rootfs/tmpfs behavior, SD unmounting, USB-data disablement, camera input, button approval, TRNG health tests, reproducible release images, PGP releases, and post-power-loss residue checks are not implemented and verified end to end.

## 4. Verification performed

From `firmware/`, with Zig 0.17.0 and libsecp256k1 0.7.1:

```bash
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test -Doptimize=ReleaseFast --summary all
zig build test -Doptimize=ReleaseSmall --summary all
zig build pico --summary all
zig build --summary all
./zig-out/bin/zhww version
```

Results:

- Debug: **391/391 tests passed**
- ReleaseSafe: **391/391 tests passed**
- ReleaseFast: **391/391 tests passed**
- ReleaseSmall: **391/391 tests passed**
- RP2040 ReleaseSmall compile check: passed
- RP2350 ReleaseSmall compile check: passed
- CLI build/version: passed
- BIP84 address smoke check: matched `bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu`
- Bitcoin signed transaction: matched the pinned Bitcoin Core vector byte for byte
- EIP-1559 signed transaction: matched the pinned independent vector byte for byte and decoded successfully
- BC-UR PSBT round trip: passed
- FAT32 image handoff: signed output matched pinned SHA-256 `afb511882d4f36b2b526ad52561c3875401cb82368a8148c846098a2f6e49117`; `fsck.fat -n` was clean
- Light-channel PSBT round trip: 4/4 UR parts received; 807,200 generated samples round-tripped byte for byte
- Invalid BIP39 checksum through the CLI: rejected

The existing fuzz/mutation tests ran as part of both test modes. Passing them is evidence of exercised behavior, not proof of memory safety or protocol correctness.

## 5. Recommended next work, in order

1. Implement an explicit immutable `PreparedRequest` → physical approval → `ApprovedRequest` → sign state machine.
2. Decide whether I-2 and I-3 are real release requirements. Implement them or remove the claims before adding features.
3. Add a session-owned secret container with one non-bypassable secure wipe path and tests that inspect the backing memory.
4. Integrate P2TR and P2WSH into PSBT parsing, signing, serialization, display, and finalization.
5. Integrate EVM transaction/EIP-712 parsing, ERC-7730 rendering, chainId display, and signing into one approved-object flow.
6. Wire libsecp256k1 context randomization and BIP340 auxiliary randomness to a tested hardware RNG interface.
7. Run the complete flow on the target board and add power-cut, malformed-SD, malformed-QR, button-order, and secret-residue tests.
8. Obtain an independent review only after the architecture above exists; another review of host-only primitives cannot validate a hardware-wallet security boundary.
