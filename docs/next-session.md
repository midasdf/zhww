# Next-session handoff

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
