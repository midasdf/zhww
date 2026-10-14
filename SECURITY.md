# Security Policy

---

## Summary

This project is experimental and is not audited. Security reports are genuinely welcome — even
for a hobby project, a wallet bug matters.

- **How to report**: open a [GitHub security advisory](https://github.com/midasdf/zhww/security/advisories/new)
  (private) or an issue if the matter is not sensitive.
- **Please include**: what you found, how to reproduce it, and which commit you tested.
- **Response**: best effort. This is a volunteer, experimental project with no guaranteed SLA.
- **Most interesting classes**: signature or sighash mistakes, PSBT/QR parsing that leads to
  signing the wrong thing, key material leaking into flash or logs, anything that makes the device
  display something different from what it signs.

---

- **Last updated**: 2026-10-14
- **Scope**: every deliverable in this repository (firmware, documentation, hardware design)

---

## 1. Where this project stands

**zhww is an experimental research and development project and has not undergone a third-party security audit.**
It is not finished as a hardware wallet at this point, and **is not intended for use with real funds**.

See [DISCLAIMER.md](DISCLAIMER.md) for details.

## 2. How to report a vulnerability

If you find a security problem, please **do not open a public issue**; report it privately through one of the following.

1. **GitHub Security Advisories** (recommended)
   - Report it from the repository's "Security" tab → "Report a vulnerability"
   - You can discuss it privately and publish the disclosure in the same place after the fix

2. If that is not possible, open a repository issue saying that you would like to make contact
   privately, and we will work out a channel (**do not put the vulnerability itself in a public issue**)

### What to include in the report

- The affected file, function and commit
- Steps to reproduce (test code or input data if possible)
- The expected impact (key leakage, signing something other than what is displayed, loss of funds, etc.)
- Whether it is already public

### Response targets (best effort)

| Stage | Target |
|---|---|
| Acknowledgement | As soon as possible (aiming for within a few days) |
| Initial assessment | Within 2 weeks |
| Fix | Depends on the issue and the state of development |

**This project is volunteer-based and cannot guarantee any response.**
Even so, letting us know helps protect users.

## 3. Vulnerability classes we consider especially important

The following are handled with priority.

| Class | Example |
|---|---|
| Key leakage | The seed, private keys or passphrase remain in memory or storage, or are sent outside the device |
| Signing something other than what is displayed | What the screen shows and what is actually signed disagree. The target I-3 boundary is not yet implemented; see [the 2026-10-13 review](docs/10-security-audit-2026-10-13.md). |
| Forged signatures / missing verification | A generated signature does not pass verification, or someone else's signature is accepted |
| Spoofed fees or destinations | Paying to an output that is not displayed, or inflating the fee |
| Missing PSBT validation | Accepting an invalid PSBT (duplicate keys, wrong key lengths, mismatched map counts, etc.) |
| RNG flaws | A predictable seed is generated |

## 4. Out of scope

- Vulnerabilities in the external libraries this project uses ([libsecp256k1](https://github.com/bitcoin-core/secp256k1) and others)
  → please report them to those projects
- Known design constraints (already listed under "what we cannot protect" in [docs/05-threat-model.md](docs/05-threat-model.md))
  → e.g. protecting the seed under physical access, or the lack of secure boot on the Raspberry Pi
- The facts that it "has not been audited" and "is developed with heavy LLM use"
  → these are already disclosed in [DISCLAIMER.md](DISCLAIMER.md)

## 5. Disclosure policy

- We would appreciate it if you held off publishing the details until a fix is available
- After the fix, we will publish it through GitHub Security Advisories according to the reporter's wishes
- Let us know if you would like credit

## 6. Acknowledgements

Security reports, however small, make this project more valuable.
We would like to thank everyone who has reported something.
