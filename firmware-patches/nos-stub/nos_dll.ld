/* NOS stand-in DLL: flash at 0x514A1C90 (CS0 0xA1C90), state in NOS BSS. */
ENTRY(_start)
SECTIONS
{
    . = 0x514A1C90;
    .entry4 : { KEEP(*(.entry4)) }
    . = 0x514A260C;
    .entry6 : { KEEP(*(.entry6)) }
    /* Whole words: the patch tools write this into the scrambled part of
     * CS0 (0xA000-0x2ACFFF), where flash is coded 16 bits at a time. */
    .text : { *(.text .text.*) *(.rodata .rodata.*) . = ALIGN(4); }
    /* NOS BSS 0x8000C378-0x800CE250 is zeroed by nosstarter.ext; the
     * entry stub uses 0x8000C378-0x8000C588. */
    .bss 0x8000D000 (NOLOAD) : { *(.bss .bss.* COMMON) }
    /DISCARD/ : { *(.data .data.*) *(.comment) *(.ARM.attributes) *(.ARM.exidx*) }
}
ASSERT(SIZEOF(.bss) < 0x40000, "NOS stand-in state too large")
