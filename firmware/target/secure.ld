/* Candidate offline map, NOT programmed SAU/MPU/boot policy. No vectors/boot block. */
ENTRY(zhww_link_only_halt)
MEMORY {
 FLASH (rx) : ORIGIN = 0x10000000, LENGTH = 1024K
 RAM (rw) : ORIGIN = 0x20000000, LENGTH = 440K
}
SECTIONS {
 .text : { KEEP(*(.text.zhww_link_only*)) KEEP(*(.text.secp256k1_default*)) *(.text*) KEEP(*(.rodata.zhww_target_context_bytes)) *(.rodata*) } > FLASH
 .ARM.extab : { *(.ARM.extab*) } > FLASH
 .ARM.exidx : { *(.ARM.exidx*) } > FLASH
 .data : { *(.data*) } > RAM AT> FLASH
 .bss (NOLOAD) : { *(.bss*) *(COMMON) } > RAM
 .secure_workflow (NOLOAD) : { KEEP(*(.secure_workflow)) } > RAM
 .secure_workspace (NOLOAD) : { KEEP(*(.secure_workspace)) } > RAM
 .secure_framebuffer (NOLOAD) : { KEEP(*(.secure_framebuffer)) } > RAM
 .hal_reserve (NOLOAD) : { . = ALIGN(8); . += 32768; } > RAM
 .stack (NOLOAD) : { . = ALIGN(8); __stack_bottom = .; . += 65536; __stack_top = .; } > RAM
 .fault_stack (NOLOAD) : { . = ALIGN(8); __fault_stack_bottom = .; . += 8192; __fault_stack_top = .; } > RAM
 __ram_end = .;
 ASSERT(__ram_end <= ORIGIN(RAM) + LENGTH(RAM), "Secure SRAM overflow")
 .stack_sizes 0 : { *(.stack_sizes) }
 /DISCARD/ : { *(.comment) *(.note*) }
}
