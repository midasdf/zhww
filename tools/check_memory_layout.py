#!/usr/bin/env python3
"""Compile a Cortex-M33 ABI inventory and read its exported constant without execution.

No external Python packages. This is a provisional inventory, NOT a linked SRAM/stack
proof. The stack and HAL entries are reservations, not compiler/hardware measurements.
"""
# SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
# SPDX-License-Identifier: MIT
import argparse
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

FIELDS = (
    "schema", "pointer_bits", "sram", "workflow", "review_in_workflow",
    "workspace_control", "rng_control", "context_owner", "workspace", "ingress",
    "framebuffer", "stack_reserve", "fault_stack_reserve", "nonsecure_stack_reserve",
    "hal_reserve", "planned_total", "unallocated_margin",
)
COUNTED = (
    "workflow", "workspace_control", "rng_control", "context_owner", "workspace",
    "ingress", "framebuffer", "stack_reserve", "fault_stack_reserve", "nonsecure_stack_reserve", "hal_reserve",
)


def read_layout(data: bytes) -> dict[str, int]:
    """Read exactly one global OBJECT symbol from a little-endian ARM ELF32 object."""
    def region(offset: int, size: int) -> bytes:
        if offset < 0 or size < 0 or offset > len(data) or size > len(data) - offset:
            raise ValueError("ELF range outside file")
        return data[offset:offset + size]

    header = struct.unpack("<16sHHIIIIIHHHHHH", region(0, 52))
    if header[0][:7] != b"\x7fELF\x01\x01\x01" or header[1:4] != (1, 40, 1):
        raise ValueError("Expected little-endian ARM ELF32 relocatable object")
    if header[8] != 52 or header[11] != 40 or header[12] == 0:
        raise ValueError("Unsupported ELF header/section table")
    table = region(header[6], header[11] * header[12])
    sections = [struct.unpack_from("<IIIIIIIIII", table, i * 40) for i in range(header[12])]
    found = []
    for symbols in sections:
        if symbols[1] != 2:  # SHT_SYMTAB
            continue
        if symbols[9] != 16 or symbols[5] % 16 or symbols[6] >= len(sections):
            raise ValueError("Malformed symbol table")
        strings_section = sections[symbols[6]]
        if strings_section[1] != 3:
            raise ValueError("Symbol names must use SHT_STRTAB")
        strings = region(strings_section[4], strings_section[5])
        entries = region(symbols[4], symbols[5])
        for offset in range(0, len(entries), 16):
            name, value, size, info, _, index = struct.unpack_from("<IIIBBH", entries, offset)
            if name >= len(strings) or b"\0" not in strings[name:]:
                raise ValueError("Invalid symbol name")
            if strings[name:].split(b"\0", 1)[0] != b"zhww_memory_layout":
                continue
            if info != 0x11 or index == 0 or index >= len(sections) or size != len(FIELDS) * 4:
                raise ValueError("Invalid layout symbol type, section or size")
            section = sections[index]
            if section[1] != 1 or value > section[5] or size > section[5] - value:
                raise ValueError("Layout symbol must reside in file-backed PROGBITS")
            values = struct.unpack("<" + "I" * len(FIELDS), region(section[4] + value, size))
            found.append(dict(zip(FIELDS, values)))
    if len(found) != 1:
        raise ValueError("Expected exactly one layout symbol")
    layout = found[0]
    if layout["schema"] != 2 or layout["pointer_bits"] != 32 or layout["sram"] != 520 * 1024:
        raise ValueError("Unsupported memory inventory schema/ABI/SRAM")
    if layout["workflow"] <= layout["review_in_workflow"]:
        raise ValueError("Embedded review inventory is inconsistent")
    if sum(layout[field] for field in COUNTED) != layout["planned_total"]:
        raise ValueError("Memory inventory sum mismatch")
    if layout["planned_total"] + layout["unallocated_margin"] != layout["sram"]:
        raise ValueError("SRAM reservations exceed capacity or margin mismatch")
    return layout


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig", help="Compiler used for the firmware build")
    args = parser.parse_args()
    firmware = Path(__file__).resolve().parents[1] / "firmware"
    with tempfile.TemporaryDirectory(prefix="zhww-memory-") as directory:
        obj = Path(directory) / "memory_layout.o"
        subprocess.run([
            args.zig, "build-obj", "memory_layout.zig", "-target", "thumb-freestanding",
            "-mcpu=cortex_m33", "-OReleaseSmall", f"-femit-bin={obj}",
        ], cwd=firmware, check=True)
        layout = read_layout(obj.read_bytes())
    print(json.dumps({
        "target": "thumb-freestanding/cortex_m33", "status": "provisional_inventory",
        "unmeasured": ["linked image and other globals", "transitive Zig/C/interrupt stacks", "HAL and DMA buffers"],
        "bytes": layout,
    }, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"memory inventory failed: {exc}", file=sys.stderr)
        sys.exit(1)
