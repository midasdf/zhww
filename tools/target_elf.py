"""Strict little-endian ARM ELF32 reader for offline link checks (no execution)."""
# SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
# SPDX-License-Identifier: MIT
from dataclasses import dataclass
import struct


@dataclass(frozen=True)
class Section:
    name: str
    kind: int
    flags: int
    address: int
    offset: int
    size: int
    link: int
    alignment: int
    entry_size: int


@dataclass(frozen=True)
class Symbol:
    name: str
    value: int
    size: int
    info: int
    section: int


class Elf:
    def region(self, offset, size):
        if offset < 0 or size < 0 or offset > len(self.data) or size > len(self.data) - offset:
            raise ValueError("ELF range outside file")
        return self.data[offset:offset + size]

    @staticmethod
    def string(data, offset):
        if offset >= len(data) or b"\0" not in data[offset:]:
            raise ValueError("Invalid ELF string")
        return data[offset:data.index(b"\0", offset)].decode("utf-8", errors="strict")

    def __init__(self, data):
        self.data = data
        h = struct.unpack("<16sHHIIIIIHHHHHH", self.region(0, 52))
        if h[0][:7] != b"\x7fELF\x01\x01\x01" or h[1] not in (1, 2) or h[2:4] != (40, 1):
            raise ValueError("Expected little-endian ARM ELF32")
        if h[8] != 52 or h[11] != 40 or not 0 < h[12] < 4096 or h[13] >= h[12]:
            raise ValueError("Unsupported ELF section table")
        self.kind, self.entry = h[1], h[4]
        table = self.region(h[6], h[11] * h[12])
        raw = [struct.unpack_from("<IIIIIIIIII", table, i * 40) for i in range(h[12])]
        strings = raw[h[13]]
        if strings[1] != 3:
            raise ValueError("Missing section-name STRTAB")
        names = self.region(strings[4], strings[5])
        self.sections = []
        for s in raw:
            if s[1] != 8:  # NOBITS has no file payload
                self.region(s[4], s[5])
            if s[8] and s[8] & (s[8] - 1):
                raise ValueError("Invalid section alignment")
            self.sections.append(Section(self.string(names, s[0]), s[1], s[2], s[3], s[4], s[5], s[6], s[8], s[9]))
        if self.sections[0].kind != 0:
            raise ValueError("Invalid NULL section")
        self.programs = []
        if h[10]:
            if h[9] != 32 or h[10] > 4096:
                raise ValueError("Unsupported program table")
            table = self.region(h[5], h[9] * h[10])
            for i in range(h[10]):
                p = struct.unpack_from("<IIIIIIII", table, i * 32)
                self.region(p[1], p[4])
                if p[0] == 1 and (p[4] > p[5] or p[2] + p[5] > 2**32 or p[3] + p[4] > 2**32):
                    raise ValueError("Invalid load segment")
                self.programs.append(p)
        self.symbols = []
        for s in self.sections:
            if s.kind != 2:
                continue
            if s.entry_size != 16 or s.size % 16 or s.link >= len(self.sections):
                raise ValueError("Malformed symbol table")
            strings = self.sections[s.link]
            if strings.kind != 3:
                raise ValueError("Symbol names must use STRTAB")
            names = self.region(strings.offset, strings.size)
            for row in struct.iter_unpack("<IIIBBH", self.region(s.offset, s.size)):
                name, value, size, info, _, index = row
                if index >= len(self.sections) and index not in (0xfff1, 0xfff2):
                    raise ValueError("Unsupported symbol section")
                self.symbols.append(Symbol(self.string(names, name), value, size, info, index))

    def section(self, name):
        found = [s for s in self.sections if s.name == name]
        if len(found) != 1:
            raise ValueError(f"Expected exactly one {name} section")
        return found[0]

    def frames(self):
        """Linked .stack_sizes entries: address u32 + canonical unsigned LEB128 size."""
        s = self.section(".stack_sizes")
        if s.kind != 1 or s.flags & 2:
            raise ValueError("Stack metadata must be non-allocated PROGBITS")
        data = self.region(s.offset, s.size)
        names = {}
        for symbol in self.symbols:
            if symbol.info & 15 == 2 and 0 < symbol.section < len(self.sections):
                section = self.sections[symbol.section]
                address = symbol.value & ~1
                if section.flags & 4 and section.address <= address < section.address + section.size and symbol.size <= section.address + section.size - address:
                    names.setdefault(address, set()).add(symbol.name)
        result, offset = [], 0
        seen = set()
        while offset < len(data):
            if len(data) - offset < 5:
                raise ValueError("Truncated stack-size entry")
            address = struct.unpack_from("<I", data, offset)[0]
            offset += 4
            value, shift, count = 0, 0, 0
            while True:
                if offset == len(data) or count == 5:
                    raise ValueError("Invalid stack-size ULEB128")
                byte = data[offset]
                offset += 1
                count += 1
                value |= (byte & 127) << shift
                if not byte & 128:
                    if value > 0xffffffff or (count > 1 and byte == 0):
                        raise ValueError("Noncanonical/overflow stack-size ULEB128")
                    break
                shift += 7
            if address not in names or address in seen:
                raise ValueError("Unresolved/duplicate stack-size function address")
            seen.add(address)
            result.append({"address": address, "functions": sorted(names[address]), "frame_bytes": value})
        return sorted(result, key=lambda f: (-f["frame_bytes"], f["address"]))


def check_image(elf, flash, ram, expected_sections):
    if elf.kind != 2 or not elf.entry & 1:
        raise ValueError("Expected linked Thumb executable")
    def within(start, size, region):
        return size >= 0 and region[0] <= start <= region[1] and size <= region[1] - start
    allocated = [s for s in elf.sections if s.flags & 2 and s.size]
    for s in allocated:
        if s.alignment and s.address % s.alignment:
            raise ValueError("Misaligned allocated section")
        if not (within(s.address, s.size, flash) or within(s.address, s.size, ram)):
            raise ValueError(f"Allocated section outside partition: {s.name}")
        if s.flags & 1 and not within(s.address, s.size, ram):
            raise ValueError(f"Writable section in flash: {s.name}")
        if s.flags & 4 and (s.flags & 1 or not within(s.address, s.size, flash)):
            raise ValueError(f"Executable writable/RAM section: {s.name}")
    ranges = sorted((s.address, s.address + s.size) for s in allocated)
    if any(a[1] > b[0] for a, b in zip(ranges, ranges[1:])):
        raise ValueError("Overlapping allocated sections")
    if any(p[0] == 0x6474e551 and p[6] & 1 for p in elf.programs):
        raise ValueError("Executable GNU stack")
    loads = [p for p in elf.programs if p[0] == 1]
    if not loads:
        raise ValueError("No load segments")
    for p in loads:
        _, offset, address, physical, filesz, memsz, flags, _ = p
        if not (within(address, memsz, flash) or within(address, memsz, ram)):
            raise ValueError("Load segment outside partition")
        if flags & 2 and flags & 1:
            raise ValueError("Writable executable load segment")
        if flags & 1 and not within(address, memsz, flash):
            raise ValueError("RAM executable load segment")
        if filesz and not within(physical, filesz, flash):
            raise ValueError("Initial load bytes outside flash partition")
    for s in allocated:
        if not any(within(s.address, s.size, (p[2], p[2] + p[5])) and
                   (s.kind == 8 or (s.offset >= p[1] and s.offset + s.size <= p[1] + p[4] and
                                   s.address - p[2] == s.offset - p[1])) for p in loads):
            raise ValueError(f"Allocated section not backed by a matching load segment: {s.name}")
    if not any(s.flags & 4 and within(elf.entry & ~1, 2, (s.address, s.address + s.size)) for s in allocated):
        raise ValueError("Entry outside executable section")
    if any(s.name and s.section == 0 for s in elf.symbols):
        raise ValueError("Unresolved symbols")
    forbidden = {"malloc", "calloc", "realloc", "free", "printf", "fprintf", "stderr",
                 "secp256k1_context_create", "secp256k1_context_clone"}
    if forbidden.intersection(s.name for s in elf.symbols):
        raise ValueError("Heap/logging/allocating context API linked")
    for name, size in expected_sections.items():
        s = elf.section(name)
        if s.kind != 8 or s.size != size or not within(s.address, s.size, ram):
            raise ValueError(f"Unexpected dedicated storage: {name}")
    end = max(s.address + s.size for s in allocated if within(s.address, s.size, ram))
    flash_end = max(p[3] + p[4] for p in loads if p[4])
    return {"flash_load_bytes": flash_end - flash[0], "ram_reserved_bytes": end - ram[0],
            "ram_margin_bytes": ram[1] - end,
            "sections": {s.name: {"address": s.address, "bytes": s.size} for s in allocated}}
