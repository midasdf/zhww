"""Compiled-instruction tripwire for the offline ARM fatal-stack entry.

Not runtime/privilege/MPU/interrupt/FPU/fault-injection verification. Require the
specific no-prologue sequence, relocated fault MSP and terminal wipe branch.
"""
# SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
# SPDX-License-Identifier: MIT
import struct

# msr MSP; mrs CONTROL; clear SPSEL; msr CONTROL; ISB; clear r0-r12/LR/APSR.
BODY = bytes.fromhex("80f30888 eff31481 21f00201 81f31488 bff36f8f "
                     "0020 0146 0246 0346 0446 0546 0646 0746 "
                     "8046 8146 8246 8346 8446 8646 80f30088")


def check_code(code, address, fault_top, wipe_address):
    if len(code) not in (66, 68) or code[:2] != b"\x72\xb6" or code[10:62] != BODY:
        raise ValueError("Fatal entry prologue/IRQ/SP/register sequence changed")
    if code[66:] not in (b"", b"\xfe\xde"):
        raise ValueError("Unexpected fatal entry trailing instructions")
    def immediate(offset, opcode):
        first, second = struct.unpack_from("<HH", code, offset)
        if first & 0xfbf0 != opcode or second & 0x8f00:
            raise ValueError("Fatal entry must load fault MSP using MOVW/MOVT r0")
        return ((first & 15) << 12) | (((first >> 10) & 1) << 11) | (((second >> 12) & 7) << 8) | (second & 255)
    if immediate(2, 0xf240) | immediate(6, 0xf2c0) << 16 != fault_top:
        raise ValueError("Fatal MSP does not equal linker fault-stack top")
    first, second = struct.unpack_from("<HH", code, 62)
    if first & 0xf800 != 0xf000 or second & 0xd000 != 0x9000:
        raise ValueError("Fatal entry must end in unconditional Thumb B.W")
    sign = (first >> 10) & 1
    i1, i2 = 1 ^ ((second >> 13) & 1) ^ sign, 1 ^ ((second >> 11) & 1) ^ sign
    delta = sign << 24 | i1 << 23 | i2 << 22 | (first & 1023) << 12 | (second & 2047) << 1
    if sign:
        delta -= 1 << 25
    if (address + 62 + 4 + delta) & 0xffffffff != wipe_address:
        raise ValueError("Fatal entry does not branch directly to wipe routine")


def check_fatal_entry(elf):
    def symbol(name):
        found = [s for s in elf.symbols if s.name == name]
        if len(found) != 1:
            raise ValueError(f"Expected unique {name} symbol")
        return found[0]
    for name, section_name in (("__stack", ".stack"), ("__fault_stack", ".fault_stack")):
        section = elf.section(section_name)
        if symbol(name + "_bottom").value != section.address or symbol(name + "_top").value != section.address + section.size:
            raise ValueError("Stack symbols do not describe dedicated storage")
    entry, wipe = symbol("zhww_target_fatal_enter"), symbol("zhww_target_fatal_wipe")
    if entry.info & 15 != 2 or wipe.info & 15 != 2 or not 0 < entry.section < len(elf.sections):
        raise ValueError("Fatal entry/wipe must be defined functions")
    section = elf.sections[entry.section]
    offset = (entry.value & ~1) - section.address
    if section.kind != 1 or not section.flags & 4 or offset < 0 or offset + entry.size > section.size:
        raise ValueError("Fatal entry outside executable PROGBITS")
    code = elf.region(section.offset + offset, entry.size)
    check_code(code, entry.value & ~1, symbol("__fault_stack_top").value, wipe.value & ~1)
