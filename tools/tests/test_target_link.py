"""Adversarial bounds, partition, metadata and dependency-source tests; no ARM execution."""
# SPDX-License-Identifier: GPL-3.0-or-later
import io
from pathlib import Path
import struct
import sys
import tarfile
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from target_elf import Elf, check_image
from check_target_link import extract_sources, verified_archive, symbol_u32

FLASH = (0x10000000, 0x10000040)
RAM = (0x20000000, 0x20000040)


def image(frame=None, function="main"):
    names = b"\0.text\0.stack_sizes\0.symtab\0.strtab\0.stack\0" + function.encode() + b"\0zhww_target_context_bytes\0"
    name = lambda text: names.index(text.encode() + b"\0")
    frame = struct.pack("<I", FLASH[0]) + b"\x10" if frame is None else frame
    text = b"\0" * 24 + struct.pack("<I", 184) + b"\0" * 4
    meta_offset = 160
    symbols_offset = (meta_offset + len(frame) + 3) & ~3
    symbols = b"\0" * 16
    symbols += struct.pack("<IIIBBH", name(function), FLASH[0] + 1, 16, 0x12, 0, 1)
    symbols += struct.pack("<IIIBBH", name("zhww_target_context_bytes"), FLASH[0] + 24, 4, 0x11, 0, 1)
    names_offset = symbols_offset + len(symbols)
    sections_offset = names_offset + len(names)
    header = struct.pack("<16sHHIIIIIHHHHHH", b"\x7fELF\x01\x01\x01" + b"\0" * 9,
                         2, 40, 1, FLASH[0] + 1, 52, sections_offset, 0x5000200, 52, 32, 2, 40, 6, 4)
    programs = struct.pack("<IIIIIIII", 1, 128, FLASH[0], FLASH[0], 32, 32, 5, 4)
    programs += struct.pack("<IIIIIIII", 1, meta_offset, RAM[0], RAM[0], 0, 8, 6, 8)
    sections = b"\0" * 40
    sections += struct.pack("<IIIIIIIIII", name(".text"), 1, 6, FLASH[0], 128, 32, 0, 0, 4, 0)
    sections += struct.pack("<IIIIIIIIII", name(".stack_sizes"), 1, 0, 0, meta_offset, len(frame), 0, 0, 1, 0)
    sections += struct.pack("<IIIIIIIIII", name(".symtab"), 2, 0, 0, symbols_offset, len(symbols), 4, 0, 4, 16)
    sections += struct.pack("<IIIIIIIIII", name(".strtab"), 3, 0, 0, names_offset, len(names), 0, 0, 1, 0)
    sections += struct.pack("<IIIIIIIIII", name(".stack"), 8, 3, RAM[0], meta_offset, 8, 0, 0, 8, 0)
    return header + programs + b"\0" * 12 + text + frame + b"\0" * (symbols_offset - meta_offset - len(frame)) + symbols + names + sections


def mutate_section(data, index, field, value):
    data = bytearray(data)
    offset = struct.unpack_from("<I", data, 32)[0] + 40 * index + 4 * field
    struct.pack_into("<I", data, offset, value)
    return bytes(data)


class TargetElfTest(unittest.TestCase):
    def check(self, data):
        return check_image(Elf(data), FLASH, RAM, {".stack": 8})

    def test_valid_image_and_metadata(self):
        elf = Elf(image())
        r = self.check(image())
        self.assertEqual(r["ram_reserved_bytes"], 8)
        self.assertEqual(r["ram_margin_bytes"], 56)
        self.assertEqual(r["flash_load_bytes"], 32)
        self.assertEqual(elf.frames()[0]["frame_bytes"], 16)
        self.assertEqual(symbol_u32(elf, "zhww_target_context_bytes"), 184)

    def test_every_truncated_prefix_fails(self):
        data = image()
        for n in range(len(data)):
            with self.subTest(n=n), self.assertRaises(ValueError):
                Elf(data[:n])

    def test_bad_header_and_program_bounds(self):
        for offset, fmt, value in ((4, "B", 2), (5, "B", 2), (18, "H", 62),
                                   (32, "I", 0xffffffff), (46, "H", 39),
                                   (50, "H", 6), (52 + 16, "I", 33)):
            data = bytearray(image())
            struct.pack_into("<" + fmt, data, offset, value)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                Elf(bytes(data))

    def test_partition_permissions_storage_and_alignment(self):
        for index, field, value in ((1, 3, FLASH[1]), (1, 2, 7),
                                    (5, 3, RAM[1]), (5, 2, 7), (5, 5, 9),
                                    (5, 8, 3), (5, 3, RAM[0] + 1), (5, 1, 1)):
            with self.subTest(index=index, field=field), self.assertRaises(ValueError):
                self.check(mutate_section(image(), index, field, value))

    def test_load_mapping_and_thumb_entry(self):
        for offset, value in ((24, FLASH[0]), (52 + 24, 7), (84 + 8, RAM[1]),
                              (52 + 12, FLASH[1]), (52 + 4, 120)):
            data = bytearray(image())
            struct.pack_into("<I", data, offset, value)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                self.check(bytes(data))

    def test_heap_and_logging_tripwire(self):
        for name in ("malloc", "free", "printf", "secp256k1_context_create"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.check(image(function=name))

    def test_unresolved_symbols_and_invalid_symbol_strings(self):
        original = image()
        table = struct.unpack_from("<I", original, 32)[0]
        syms = struct.unpack_from("<I", original, table + 3 * 40 + 16)[0]
        for relative, fmt, value in ((16 + 14, "H", 0), (16, "I", 0xffffffff),
                                     (16 + 14, "H", 0xffff)):
            data = bytearray(original)
            struct.pack_into("<" + fmt, data, syms + relative, value)
            with self.subTest(relative=relative), self.assertRaises(ValueError):
                self.check(bytes(data))

    def test_stack_uleb_bounds_duplicates_and_resolution(self):
        address = struct.pack("<I", FLASH[0])
        for frame in (b"\0", address + b"\x80", address + b"\x80\0",
                      address + b"\xff\xff\xff\xff\x10", address + b"\x80" * 6,
                      struct.pack("<I", FLASH[1]) + b"\0", (address + b"\0") * 2):
            with self.subTest(frame=frame), self.assertRaises(ValueError):
                Elf(image(frame=frame)).frames()
        self.assertEqual(Elf(image(frame=address + b"\x80\x01")).frames()[0]["frame_bytes"], 128)

    def test_context_constant_rejects_bad_type_size_or_absolute(self):
        original = image()
        table = struct.unpack_from("<I", original, 32)[0]
        syms = struct.unpack_from("<I", original, table + 3 * 40 + 16)[0] + 32
        for offset, fmt, value in ((8, "I", 8), (12, "B", 0x12), (14, "H", 0xfff1)):
            data = bytearray(original)
            struct.pack_into("<" + fmt, data, syms + offset, value)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                symbol_u32(Elf(bytes(data)), "zhww_target_context_bytes")


class SourceArchiveTest(unittest.TestCase):
    def archive(self, path, members):
        with tarfile.open(path, "w:gz") as out:
            for name, kind in members:
                member = tarfile.TarInfo(name)
                member.type = kind
                member.size = 1 if kind == tarfile.REGTYPE else 0
                member.linkname = "../../outside"
                out.addfile(member, io.BytesIO(b"x") if member.size else None)

    def test_archive_checksum_and_limit(self):
        import hashlib
        verified_archive(b"x", hashlib.sha256(b"x").hexdigest())
        for data in (b"y", b"x" * (8 * 1024 * 1024 + 1)):
            with self.assertRaises(ValueError):
                verified_archive(data, hashlib.sha256(b"x").hexdigest())

    def test_safe_source_extraction(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "source.tar.gz"
            self.archive(path, [("secp/file", tarfile.REGTYPE)])
            result = extract_sources(path, root / "out", "secp")
            self.assertEqual((result / "file").read_bytes(), b"x")

    def test_archive_traversal_links_special_and_duplicate_paths(self):
        cases = [[("/secp/file", tarfile.REGTYPE)], [("secp/../file", tarfile.REGTYPE)],
                 [("other/file", tarfile.REGTYPE)], [("secp/link", tarfile.SYMTYPE)],
                 [("secp/link", tarfile.LNKTYPE)], [("secp/fifo", tarfile.FIFOTYPE)],
                 [("secp/file", tarfile.REGTYPE), ("secp//file", tarfile.REGTYPE)]]
        for members in cases:
            with self.subTest(members=members), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                path = root / "source.tar.gz"
                self.archive(path, members)
                with self.assertRaises(ValueError):
                    extract_sources(path, root / "out", "secp")
                self.assertFalse((root / "out").exists())


if __name__ == "__main__":
    unittest.main()
