# Next-session handoff

- **Last updated**: 2026-10-14

Earlier session logs are in the git history; the security history is in the internal reviews
([10](10-security-audit-2026-10-13.md), [15](15-security-audit-2026-10-14.md)) and design notes
([11](11-rp2350-security.md)–[14](14-target-link-and-fault-prototype.md)).

## Where things stand

- **Hardware** (decided 2026-10-14): RP2350-PiZero + Adafruit Mini PiTFT #4393 (240 × 135) +
  **ArduCam UC-805** (Arducam B0315, HM01B0), USB power only. No SD card, no battery, no radio. Data
  moves only as UR QR codes: the camera reads the host's, the screen shows the device's.
- **Pin map** (the RP2350-PiZero numbers pins 7, 8, 10, 19, 21, 23, 29, 32 differently from a Pi):
  PiTFT on **SPI1** (MOSI 11, SCK 10, CS 8), DC 25, BL 22, buttons 23/24, I²C1 2/3; camera D0 9,
  PCLK 13, HREF 15, VSYNC 16, I²C 0x24, 2.8 V I/O, never drive XCLK. See [03](03-hardware-bom.md) §3.
- **Enclosure**: `hardware/enclosure/case.zig` (CERN-OHL-S) is the parametric source: 42 analytic
  checks, three SolidCraft scripts, `zig run case.zig -- verify results.json` for SolidCraft's
  interference result. 97.2 × 38.6 × 19.7 mm, clear material recommended, seven M2 × 16 screws from
  underneath, the lens on the golden section of the depth, a 2.07 mm lip against torsion; STEP and
  three STLs exported with SolidCraft 0.8.0. **Nothing measured yet**: the UC-805 has no published drawing.
- **Licences**: firmware and tools MIT, hardware incl. enclosure CERN-OHL-S-2.0, docs CC-BY-4.0, a
  future logo CC-BY-SA-4.0, the name via `TRADEMARKS.md`; REUSE layout checked by `tools/license_check.zig`.
- **Firmware**: host-side components and security prototypes only; see [firmware/README.md](../firmware/README.md).
  The approved native-P2WPKH workflow has an independent guard ([13](13-independent-p2wpkh-guard.md)),
  owned-secret erasure and a fatal-wipe prototype ([14](14-target-link-and-fault-prototype.md)).
  **Not bootable firmware**: no startup/SDK/CMSE gateway/attribution/real HAL.
- **Removed 2026-10-14** (in the git history): the microSD/FAT32 path, the light input channel, the
  240 × 240 HAT layout and the battery indicator state.
- **Memory** ([12](12-rp2350-memory-budget.md), [14](14-target-link-and-fault-prototype.md)): inventory
  planned 459,144 bytes, margin 73,336. Link harness: Secure 385,456 / 450,560, NS 73,728 / 81,920,
  combined margin 73,296; Secure flash 200,924 (ReleaseSafe) / 127,292 (ReleaseSmall); largest
  individual frames 14,736 / 15,128 bytes. **Not transitive stack bounds.**
- **Verification**: 353 Zig tests in all four modes, with the host library and with the target's
  32-bit C configuration; 19 tool tests; Pico compile checks; the inventory; ReleaseSafe/Small links;
  CLI regressions; QR tool tests; licence and enclosure checks. All of it runs in CI.

## Next

1. Buy the parts and measure the `MEASURED` values (UC-805 outline/holes/lens, BAT connector height,
   header stack height, bare-terminal height), re-run the enclosure checks, print the base first.
2. Display HAL: the ST7789 on SPI1, and confirm the panel offset `src/ui/st7789.zig` takes from
   Adafruit's library (40, and 52 or 53 by orientation).
3. Camera HAL: PIO one-bit capture into `src/ui/qr_decode.zig` on the target.
4. Actual boot/SDK/CMSE gateway and attribution, transitive Zig/C/IRQ stack bounds, TRNG HAL.
5. Guarded P2TR/P2WSH/EVM integration into the approved workflow.
6. Port the remaining Python tools under `tools/` to Zig (the owner prefers not to keep Python).

## Verification commands

```bash
cd firmware
zig build test --summary all
for MODE in ReleaseSafe ReleaseFast ReleaseSmall; do zig build test -Doptimize="$MODE" --summary all; done
zig build pico --summary all
zig build memory --summary all
zig build target-link -Dtarget-fetch=true        # first run downloads the pinned secp256k1 source
zig build target-config-test -Dtarget-fetch=true
zig test --dep zhww -Mroot=src/cli/qr_tool.zig -Mzhww=src/root.zig -lc $(pkg-config --cflags --libs libsecp256k1)
cd ../hardware/enclosure && zig test case.zig && zig test solidcraft.zig && zig run case.zig -- check
cd ../.. && git ls-files -z | zig run tools/license_check.zig
python3 -m unittest discover -s tools/tests
```

## Landmines

- `signPsbtBytes` does not support P2TR or P2WSH. Do not infer integration from standalone Core interoperability tests.
- `zhww sign` and `zhww evm-sign` sign immediately. They are development tools, not an approval workflow.
- Do not call signing merely to compute display metadata. Change detection once did exactly that.
- Display and signing must use `btc_sign.utxoForDisplay`/the shared resolver. A separate preference for `witness_utxo` reintroduces the legacy-input fee-spoofing issue.
- Do not return slices or pointers into by-value parameters or loop-local arrays. The Taproot witness helper had this bug.
- Use `std.crypto.secureZero`, not `@memset`, for secret erasure. Even then, by-value copies and allocator pages remain a design problem.
- Do not use `(a + b - 1) / b` for attacker-controlled lengths. `a + b - 1` can overflow; use quotient/remainder ceiling division.
- ERC-7730 intent is untrusted presentation data until canonical calldata decoding and deployment/chain/address matching succeed.
- A framebuffer initialised at a size its storage cannot hold always fails, and the optimizer then drops
  the render path from a link without any error. After changing the screen size, check the `target-link` flash sizes.
- The crypto singleton/lease is not thread-safe: target integration must serialize trusted execution,
  park the other core and prevent crypto interrupt re-entry.
- No OTP programming or lockdown before the recovery path is reviewed; development stays reflashable.

## Decisions already made

- 2026-10-13: Keep the project marked experimental and unsuitable for real funds.
- 2026-10-13: Treat the reviews as internal source reviews, not third-party audits.
- 2026-10-13: Describe P2TR/P2WSH and EVM clear signing as standalone components until integrated into the approved workflow.
- 2026-10-13: Enforce exact documented dice counts rather than warning after producing a mnemonic.
- 2026-10-13: Reject unsupported PSBT sighash requests instead of silently signing `SIGHASH_ALL`.
- 2026-10-13: Reject non-empty EVM access lists in the CLI until parsing them into the signed transaction is implemented.
- 2026-10-13: No data exchange on SD cards (shared media through the untrusted host); camera in, display out.
- 2026-10-14: Parts as above; camera out of the back; thin first; no sealing, a clear case instead.
- 2026-10-14: CAD is SolidCraft; licences as above; Zig first, Go only where Zig cannot, no new Python.
