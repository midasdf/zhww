# License Policy

- **Last updated**: 2026-10-14

This project calls itself "fully open source", so **every file states its own licence**, in the
[REUSE](https://reuse.software/) layout, and CI checks that none is missing. The licence texts are the
official ones, kept in [LICENSES/](LICENSES/).

---

## 1. Licence by deliverable

| Deliverable | Where | Licence | Why |
|---|---|---|---|
| Firmware and tools | `firmware/`, `tools/`, CI and config files | **MIT** ([LICENSE](LICENSE)) | Permissive and short: anyone may reuse the code (the PSBT and EVM parsers, the QR encoder and decoder, …) in their own wallets and libraries, products included, as long as the notice is kept. It is the licence of the two things the firmware links against, libsecp256k1 and the Zig standard library |
| Hardware design: the enclosure now, schematics and PCB if they are ever made | `hardware/` | **CERN-OHL-S-2.0** ([LICENSES/CERN-OHL-S-2.0.txt](LICENSES/CERN-OHL-S-2.0.txt)) | Strongly reciprocal and written for hardware: anyone who distributes a modified design, **or devices made from it**, must publish the modified source. Consistent with OSHWA certification |
| Documentation and its images | `*.md`, `docs/` | **CC-BY-4.0** ([LICENSES/CC-BY-4.0.txt](LICENSES/CC-BY-4.0.txt)) | Quoting, translation and redistribution are welcome with attribution |
| Logo (there is none yet) | — | **CC-BY-SA-4.0** when one is added | Open, and modified logos stay open. Add `LICENSES/CC-BY-SA-4.0.txt` in the same change |
| The name "zhww" | — | Not a copyright matter | See [TRADEMARKS.md](TRADEMARKS.md): forks are welcome, but under their own name |

The firmware is permissive and the hardware is reciprocal on purpose. Code is most useful when
other wallets can lift a parser without changing their licence; a device design is most useful when
every variant that is sold or shared stays buildable by its users.

For the differences between the CERN-OHL variants (S: strongly reciprocal / W: weakly reciprocal /
P: permissive), see the [official explanation](https://ohwr.org/project/cernohl/-/wikis/uploads/c2e5e9d297949b5c2d324a6cbf6adda0/cern_ohl_w_v2_howto.pdf).

## 2. How each file states its licence

| File | Where the licence is stated |
|---|---|
| Source files (`.zig`, `.py`, `.html`, `.sh`, `.ld`, `.h`, YAML, `.gitignore`) | A two-line SPDX header (the copyright line, then the licence identifier) right after the Zig doc comment, or at the top of the file |
| Files that cannot carry a header (Markdown, images, JSON, the BIP39 word list, the enclosure's SolidCraft scripts and its STEP / STL exports) | An annotation in [REUSE.toml](REUSE.toml); the last matching annotation wins |
| Licence texts | `LICENSES/<SPDX id>.txt`. The root `LICENSE` is the MIT text again, so GitHub shows the firmware's licence |

The check, run by CI on every push:

```bash
git ls-files -z | zig run tools/license_check.zig   # every file has a copyright and a licence
zig test tools/license_check.zig                    # the checker's own tests
```

It fails when a file states no licence, when an SPDX header has only one of its two lines, when a
licence is used without its text in `LICENSES/`, or when a text there is used by nothing. The official
`reuse lint` should agree with it; it is written in Python, so this repository does not depend on it.

## 3. Using third-party code and data

| Source licence | In the firmware / tools (MIT) | In `hardware/` (CERN-OHL-S-2.0) |
|---|---|---|
| MIT, BSD, ISC, Zlib, CC0, public domain | Yes. Keep the notice; record it in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and in the file's SPDX tags | Yes, the same way |
| Apache-2.0 | Yes, but that file stays Apache-2.0 and its NOTICE is kept | Yes, the same way |
| CERN-OHL-P / CERN-OHL-S | — | Yes |
| **GPL / LGPL / AGPL** (for example **Trezor firmware**, GPLv3) | **No.** It would force the firmware back under the GPL. Learn from it, do not copy from it | No |
| CC-BY-SA, CC-BY-NC, "free for personal use", no licence at all | No | No (for example most enclosure STLs on model-sharing sites) |

| Source | Licence | Handling |
|---|---|---|
| SeedSigner | MIT | May be reused with its notice. Its community enclosures carry their own, varying licences: check each one |
| Krux | MIT | May be incorporated. Keep the copyright notice |
| Trezor firmware | GPLv3 | **Not incorporated**, and the "Trezor" name and logo are not used |
| libsecp256k1 | MIT | Linked; the notice is kept |
| BC-UR / bc-ur | BSD-2-Clause-Patent | Keep the notice if code is ever incorporated (none is today) |
| ERC-7730 registry descriptors | CC0-1.0 | Record the source when bundling |

## 4. Stating the scope of "fully open source"

This project does **not** open the following. This is a design constraint and is stated in the README.

| Closed element | Reason |
|---|---|
| The RP2350 chip and the RP2350-PiZero board themselves | Vendor products. (The RP2350's boot ROM source is published by Raspberry Pi, but it is mask ROM: this project cannot replace it) |
| The internal implementation of the display's driver IC (ST7789) and the camera's image sensor (HM01B0) | Closed by the vendor |
| (Only if adopted) the internals of a secure element | Not applicable at present, since none is adopted |

This project therefore takes the position of "**opening everything in the application layer and the
design, and stating explicitly what is not open**". The phrase "fully open source" refers to this scope.

## 5. History

- **Until 2026-10-14** the firmware and the tools were GPL-3.0-or-later, the enclosure was
  CC-BY-SA-4.0, and the logo and name were "all rights reserved". Copies obtained before that keep
  the terms they came with. Every commit up to that point had a single author, who relicensed the
  project as described above.
