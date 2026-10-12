# hardware/ — hardware design

## Current state

v0.1 is built from **off-the-shelf parts only**, so there is no board design in this directory. See [../docs/03-hardware-bom.md](../docs/03-hardware-bom.md) for the parts list and assembly instructions.

```
hardware/
├── README.md        ← this file
├── enclosure/       ← enclosure (parametric OpenSCAD design. Hole positions to be confirmed by measuring real hardware)
└── pcb/             ← custom PCB (v0.2 and later. Currently empty)
```

## Policy

| Item | Policy |
|---|---|
| PCB | Not made for v0.1 (we only mount off-the-shelf parts). Design in KiCad only if we shrink it |
| Enclosure | **Our own OpenSCAD** (text-based, so it can be version-controlled and regenerated). The SeedSigner case is only a reference for dimensions (the port cut-outs do not fit; see [enclosure/README.md](enclosure/README.md) for details) |
| EDA | KiCad (open source; the files are text and can be version-controlled) |
| Published artifacts (if a PCB is made) | The complete KiCad project, Gerber / drill files, BOM (LCSC / Mouser part numbers), interactive BOM, assembly drawing |
| Enclosure | Publish both STL and STEP (STEP is easier to modify) |
| Certification | Obtain **OSHWA certification** ([certification.oshwa.org](https://certification.oshwa.org/)) only if a custom PCB is made |
| License | Schematics and board data: CERN-OHL-S-2.0 / enclosure: CC-BY-SA-4.0 |

## Design constraints (ease of assembly)

1. **No soldering required.** Use off-the-shelf modules and connect them with pin headers, harnesses and connectors
2. **Ten parts or fewer** (excluding consumables and the enclosure)
3. **Keep to 0.1" pitch.** Do not assume hand-assembly of fine-pitch or QFN parts
4. Power is primarily over USB (battery operation is optional)
5. It must be possible to disassemble and reassemble it (for visual inspection and for sealing the enclosure in use)
