# hardware/ — hardware design

## Current state

The device is built from **off-the-shelf parts only**, so there is no board design in this directory:
the RP2350-PiZero, the Adafruit Mini PiTFT and the ArduCam UC-805 camera are bought, and only the
enclosure is ours. See [../docs/03-hardware-bom.md](../docs/03-hardware-bom.md) for the parts list and
the wiring, and [enclosure/](enclosure/README.md) for the case and its assembly.

```
hardware/
├── README.md        ← this file
└── enclosure/       ← the case: Zig source → SolidCraft scripts → STEP / STL (see its README)
```

## Policy

| Item | Policy |
|---|---|
| PCB | None. Design one in KiCad only if a custom carrier board is ever made |
| Enclosure | **Parametric, in text**: [enclosure/case.zig](enclosure/case.zig) holds the dimensions and the clearance checks and writes [SolidCraft](https://github.com/bherbruck/solidcraft) command scripts, which SolidCraft turns into solids. Everything is version-controlled and reviewable as a diff |
| Published files | The Zig source, the generated SolidCraft scripts, **STEP** (for other CAD tools) and **STL** (to print), and the renders |
| EDA, if a PCB is made | KiCad, with the complete project, Gerber / drill files, BOM, interactive BOM and assembly drawing |
| Certification | Obtain **OSHWA certification** ([certification.oshwa.org](https://certification.oshwa.org/)) only if a custom PCB is made |
| License | **CERN-OHL-S-2.0** for everything in this directory ([../LICENSES/CERN-OHL-S-2.0.txt](../LICENSES/CERN-OHL-S-2.0.txt)); see [../LICENSE-POLICY.md](../LICENSE-POLICY.md) |

## Design constraints (ease of assembly)

1. **No soldering.** Off-the-shelf modules joined by their own headers, a STEMMA QT cable and jumper
   wires. Unhousing four jumper-wire ends and insulating them with heat-shrink or tape is the one
   hand step ([enclosure/README.md](enclosure/README.md#assembly))
2. **Ten parts or fewer** (excluding consumables and the enclosure)
3. **Keep to 0.1" pitch.** Do not assume hand assembly of fine-pitch or QFN parts
4. **USB power only.** No battery in the device
5. **It must come apart and go back together** with a screwdriver, for inspection
6. **Inspect, don't seal.** Every user builds and opens their own device, so a tamper-evident seal
   would prove nothing. Print the case in a **clear** material instead, so the inside can be checked
   against your own assembly photo before each use without opening it
