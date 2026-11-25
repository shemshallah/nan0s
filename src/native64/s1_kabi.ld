ENTRY(_start)
SECTIONS {
  . = 0x10000;
  .text : { *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  .bss (NOLOAD) : {
    __bss_start = .;
    *(.bss*) *(COMMON)
    __bss_end = .;
  }
  /* s1_boot.S owns 0x30000..0x33fff for PML4/PDPT/PD/spare.  The loaded
     image and its BSS must never collide with those live page tables. */
  ASSERT(_start == 0x10000, "S1 entry must be at 0x10000")
  ASSERT(__bss_end <= 0x30000, "S1 image/BSS overlaps page tables at 0x30000")
}
