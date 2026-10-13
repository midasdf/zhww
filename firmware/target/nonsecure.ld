/* SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors */
/* SPDX-License-Identifier: MIT */
/* Candidate offline map only. No boot vectors or Secure->NS handoff. */
ENTRY(zhww_link_only_halt)
MEMORY {
 FLASH (rx) : ORIGIN = 0x10100000, LENGTH = 1024K
 RAM (rw) : ORIGIN = 0x2006e000, LENGTH = 80K
}
SECTIONS {
 .text : { KEEP(*(.text.zhww_link_only*)) *(.text*) *(.rodata*) } > FLASH
 .ARM.exidx : { *(.ARM.exidx*) } > FLASH
 .data : { *(.data*) } > RAM AT> FLASH
 .bss (NOLOAD) : { *(.bss*) *(COMMON) } > RAM
 .nonsecure_ingress (NOLOAD) : { KEEP(*(.nonsecure_ingress)) } > RAM
 .stack (NOLOAD) : { . = ALIGN(8); __stack_bottom = .; . += 8192; __stack_top = .; } > RAM
 __ram_end = .;
 ASSERT(__ram_end <= ORIGIN(RAM) + LENGTH(RAM), "Non-secure SRAM overflow")
 /DISCARD/ : { *(.comment) *(.note*) }
}
