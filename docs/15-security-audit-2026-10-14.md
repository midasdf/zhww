# Security review — 2026-10-14

- **Reviewed base**: `4462068`
- **Scope**: current tracked source, target link harness, GitHub Actions workflow, secret-pattern scan, and existing security tests
- **Nature**: internal source review; not an independent audit, hardware validation, or release approval

## Result

Two defense-in-depth issues were fixed. No committed private key, GitHub token, AWS access key, or PEM/OpenSSH private-key marker was found in the reachable Git history. The existing host test suite passed 449/449 tests before the changes; the post-fix verification commands and results are recorded below.

The project remains experimental and unsuitable for real funds. The fixes do not turn the offline link harness into bootable firmware and do not resolve the release blockers listed below.

## Fixed findings

### 1. Raw target-harness lengths were used before boundary validation — high if reused as a gateway

**File**: `firmware/target/secure_link.zig`

The link-only C ABI exports constructed `raw[0..len]` directly. A caller-controlled oversized length could therefore describe memory outside the intended 64 KiB ingress policy before the parser had an opportunity to reject it. These exports are explicitly not CMSE gateways today, so this was not a remotely reachable production vulnerability; it was nevertheless an unsafe boundary pattern that could be copied into future gateway work.

The prepare and sign exports now reject zero or greater-than-64-KiB lengths before constructing a slice. Failed preparation also erases/reclaims the fixed parser workspace. Render initialization, page lookup, and rendering failures now abort the workflow and erase the workspace, so a failed display path cannot leave an approvable session alive.

This does **not** validate arbitrary raw pointer provenance. A real CMSE gateway must use platform pointer/range checks, copy Non-secure ingress into dedicated Secure-owned memory, enforce SAU/MPU attribution, and handle concurrent DMA/core access.

### 2. CI token permissions and credential persistence were implicit — medium

**File**: `.github/workflows/ci.yml`

The workflow runs repository-controlled build and test scripts but relied on repository-level defaults for `GITHUB_TOKEN` permissions, and checkout retained its credential. A malicious or compromised build step on a trusted-branch run could therefore receive more repository access than needed, depending on repository settings.

The workflow now declares `permissions: contents: read`, disables checkout credential persistence, and has a 45-minute job timeout. Third-party actions and Zig remain commit/digest pinned as before.

## Audit checks

- Reviewed the approval/session/secret ownership path, independent P2WPKH guard, signer preflight, target fatal path, ELF checker, dependency extraction, CI workflow, and development signing boundaries.
- Searched tracked source and reachable Git history for common private-key/token patterns; no match was found.
- Confirmed generated Zig caches and build outputs are ignored and untracked.
- Existing secp256k1 target source is commit- and SHA-256-pinned; archive extraction rejects traversal, links, special files, duplicate paths, excessive members, and excessive expansion.
- GitHub Actions are pinned by full commit SHA. The Ubuntu `apt` packages are still distribution-managed and are not a reproducible release dependency lock.

## Remaining release blockers

1. There is still no bootable RP2350 firmware, vector table/startup, real CMSE gateway, SAU/MPU/DMA attribution, or Secure HAL.
2. Boot evidence, TRNG, display completion, button events, SD/card lifecycle, and clock values are not yet collected from real trusted hardware.
3. I-2 key isolation and project-wide I-3 independent computation remain incomplete. The independent guard covers only approved native P2WPKH/SIGHASH_ALL.
4. Stack evidence is per-function metadata, not a transitive call/IRQ bound. Exception frames, FPU state, other-core state, DMA, and runtime watermark tests remain open.
5. Normal-return stack/register/compiler-spill erasure is not proven. Development CLI arguments and process memory are not a secure secret-entry boundary.
6. Taproot, multisig, and EVM are not integrated into the physical approved-request workflow.
7. Signed update/recovery, rollback protection, OTP provisioning/readback, debug/BOOTSEL lockdown, and reproducible release artifacts remain unimplemented.
8. The host CLI signing commands intentionally bypass the hardware approval workflow and must remain development-only.

## Verification

Run from the repository root / `firmware/` as appropriate:

```bash
cd firmware
zig build test --summary all
for mode in ReleaseSafe ReleaseFast ReleaseSmall; do
  zig build test -Doptimize="$mode" --summary all
done
zig build pico --summary all

cd ..
python3 -m unittest discover -s tools/tests -v
git diff --check
```

The target link check should also be run with the pinned cached archive (or explicit first-fetch permission):

```bash
cd firmware
zig build target-config-test -Dtarget-fetch=true --summary all
```

Post-fix results:

- Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall: **449/449 tests passed** in each mode.
- RP2040 and RP2350 compile checks: passed.
- Python security/tool tests: **19/19 passed**.
- Pinned-source target configuration tests: all four host optimization suites passed; Secure and Non-secure offline links passed the ELF, region, dependency, and fatal-entry checks.
- `shellcheck` for the EVM node script, Zig formatting, and `git diff --check`: passed.
