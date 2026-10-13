"""Bounds/schema tests for the compile-only Cortex-M33 inventory reader."""
# SPDX-License-Identifier: GPL-3.0-or-later
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_memory_layout import COUNTED, FIELDS, read_layout


def object_file(**changes):
    values = dict(zip(FIELDS, (
        1, 32, 520 * 1024, 80 * 1024, 12 * 1024, 40, 12, 4160,
        128 * 1024, 64 * 1024, 240 * 240 * 2, 64 * 1024, 32 * 1024, 0, 0,
    )))
    values["planned_total"] = sum(values[field] for field in COUNTED)
    values["unallocated_margin"] = values["sram"] - values["planned_total"]
    values.update(changes)
    payload = struct.pack("<" + "I" * len(FIELDS), *(values[field] for field in FIELDS))
    strings = b"\0zhww_memory_layout\0"
    data_offset = 52
    symbol_offset = data_offset + len(payload)
    strings_offset = symbol_offset + 16
    table_offset = strings_offset + len(strings)
    header = struct.pack("<16sHHIIIIIHHHHHH", b"\x7fELF\x01\x01\x01" + b"\0" * 9,
                         1, 40, 1, 0, 0, table_offset, 0, 52, 0, 0, 40, 4, 0)
    symbol = struct.pack("<IIIBBH", 1, 0, len(payload), 0x11, 0, 1)
    sections = b"\0" * 40
    sections += struct.pack("<IIIIIIIIII", 0, 1, 0, 0, data_offset, len(payload), 0, 0, 4, 0)
    sections += struct.pack("<IIIIIIIIII", 0, 2, 0, 0, symbol_offset, 16, 3, 0, 4, 16)
    sections += struct.pack("<IIIIIIIIII", 0, 3, 0, 0, strings_offset, len(strings), 0, 0, 1, 0)
    return header + payload + symbol + strings + sections


class MemoryLayoutTest(unittest.TestCase):
    def test_valid_layout(self):
        layout = read_layout(object_file())
        self.assertEqual(layout["planned_total"] + layout["unallocated_margin"], 520 * 1024)

    def test_every_truncation_fails(self):
        data = object_file()
        for length in range(len(data)):
            with self.subTest(length=length), self.assertRaises(ValueError):
                read_layout(data[:length])

    def test_schema_abi_and_sum_mismatch(self):
        for change in ({"schema": 2}, {"pointer_bits": 64}, {"planned_total": 1},
                       {"unallocated_margin": 0}, {"review_in_workflow": 90 * 1024}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                read_layout(object_file(**change))

    def test_symbol_ranges_and_types(self):
        original = object_file()
        for offset, fmt, value in ((112, "I", 9999), (116, "I", 9999),
                                   (120, "I", 4), (124, "B", 0x12), (126, "H", 0)):
            data = bytearray(original)
            struct.pack_into("<" + fmt, data, offset, value)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                read_layout(bytes(data))


if __name__ == "__main__":
    unittest.main()
