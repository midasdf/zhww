"""Dependency tripwire, not proof of algorithmic correctness or fault independence."""
# SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
# SPDX-License-Identifier: MIT
from pathlib import Path
import re
import unittest


class GuardIndependenceTest(unittest.TestCase):
    def test_guard_imports_only_the_standard_library(self):
        source = (Path(__file__).resolve().parents[2] /
                  "firmware/src/security/p2wpkh_guard.zig").read_text()
        imports = re.findall(r'@import\s*\(\s*"([^"]+)"\s*\)', source)
        self.assertEqual(imports, ["std"], "Independent guard must not share application helpers")
        self.assertEqual(len(re.findall(r'@import\s*\(', source)), len(imports),
                         "Indirect/computed imports need explicit independent review")


if __name__ == "__main__":
    unittest.main()
