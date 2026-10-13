"""Offline instruction tripwire tests, not execution of ARM instructions."""
# SPDX-License-Identifier: GPL-3.0-or-later
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fatal_entry_check import check_code

# Known Cortex-M33 compilation, independently inspected using llvm-objdump.
CODE = bytes.fromhex("72b6 4af29060 c2f20600 80f30888 eff31481 21f00201 81f31488 bff36f8f "
                     "0020 0146 0246 0346 0446 0546 0646 0746 "
                     "8046 8146 8246 8346 8446 8646 80f30088 1ef07bbf fede")


class FatalEntryTest(unittest.TestCase):
    def check(self, code):
        check_code(code, 0x10000000, 0x2006a690, 0x1001ef38)

    def test_known_no_prologue_entry_and_every_truncation(self):
        self.check(CODE)
        self.check(CODE[:66]) # backend may omit terminal trap
        for length in range(66):
            with self.subTest(length=length), self.assertRaises(ValueError):
                self.check(CODE[:length])

    def test_every_single_bit_change_and_wrong_linker_addresses_fails(self):
        for i in range(len(CODE)):
            for bit in range(8):
                code = bytearray(CODE)
                code[i] ^= 1 << bit
                with self.subTest(i=i, bit=bit), self.assertRaises(ValueError):
                    self.check(bytes(code))
        for address, top, wipe in ((0x10000002, 0x2006a690, 0x1001ef38),
                                   (0x10000000, 0x2006a698, 0x1001ef38),
                                   (0x10000000, 0x2006a690, 0x1001ef40)):
            with self.assertRaises(ValueError):
                check_code(CODE, address, top, wipe)


if __name__ == "__main__":
    unittest.main()
