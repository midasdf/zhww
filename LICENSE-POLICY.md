# License Policy

- **Last updated**: 2026-10-12

Because this project claims to be "fully open source", it **states a license explicitly for each kind
of deliverable**. The canonical license texts are obtained from each official source and bundled with
the repository (see the TODO below).

---

## 1. License by deliverable

| Deliverable | License | Reason |
|---|---|---|
| Hardware design (schematics, BOM, board data) | **CERN-OHL-S-2.0** | Strong copyleft. Modified versions must publish their design too. As an open-source hardware license it is consistent with OSHWA certification |
| Firmware | **GPL-3.0-or-later** | Requires modified versions to publish their source. It also works as the destination license if we incorporate code learned from Trezor firmware (GPLv3) |
| Enclosure and 3D data | **CC-BY-SA-4.0** | Fits the 3D-printing culture. Modified versions are shared under the same terms |
| Documentation | **CC-BY-4.0** | Quoting, translation and redistribution are welcome |
| Logo and name | **All rights reserved** | Distributing a modified version under this project's name would cause confusion |

For the differences between the CERN-OHL variants (S: strongly reciprocal / W: weakly reciprocal / P: permissive), see the [official explanation](https://ohwr.org/project/cernohl/-/wikis/uploads/c2e5e9d297949b5c2d324a6cbf6adda0/cern_ohl_w_v2_howto.pdf).

## 2. Policy on using third-party code

| Source | License | Handling when incorporated |
|---|---|---|
| SeedSigner | Open source | When reusing the parts list or the enclosure STL, state the source and the license |
| Krux | MIT | May be incorporated. Keep the copyright notice |
| Trezor firmware | **GPLv3** | If incorporated, this project's firmware becomes GPLv3 and the **"Trezor" name and logo cannot be used**. State the code's lineage |
| libsecp256k1 | MIT | Keep the notice when linking dynamically or bundling |
| BC-UR / bc-ur | BSD-family | Keep the notice |
| ERC-7730 descriptors | Follow the registry's license | Record the source and hash when bundling |

**Firmware defaults to GPL-3.0-or-later.** Code under an incompatible license (a proprietary EULA, etc.) must not be incorporated.

## 3. Stating the scope of "fully open source"

This project does **not** open the following. This is a design constraint and is stated in the README.

| Closed element | Reason |
|---|---|
| Raspberry Pi boot ROM and GPU firmware | Closed by the vendor. This project cannot replace them |
| The internal implementation of the LCD driver IC and camera module used | Closed by the vendor |
| (Only if adopted) the internals of a secure element | Not applicable at present, since none is adopted |

This project therefore takes the position of "**opening everything in the application layer and the design, and stating explicitly what is not open**". The phrase "fully open source" refers to this scope.

## 4. TODO (before the v0.1 release)

- [x] Obtain the canonical GPL-3.0 text and place it as `LICENSE` (for the firmware)
- [x] Obtain the canonical CERN-OHL-S-2.0 text and place it as `LICENSE-HARDWARE` (for the hardware design)
- [x] Place CC-BY-4.0 as `LICENSE-DOCS` (for documentation) and CC-BY-SA-4.0 as `LICENSE-ENCLOSURE`
      (for the enclosure)
- [x] Add a per-file SPDX header (`SPDX-License-Identifier: GPL-3.0-or-later`) to
      every Zig source (placed directly after the doc comment)
- [x] Create `THIRD-PARTY-NOTICES.md` for third-party code (libsecp256k1, test vectors, oracles)
- [x] Create the vulnerability disclosure policy `SECURITY.md`
