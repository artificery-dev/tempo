ENTRY(_start)
SECTIONS {
    . = 0x80000000;
    .text : { *(.text.entry) *(.text*) *(.rodata*) }
    /DISCARD/ : { *(.ARM.attributes) *(.comment) }
    ASSERT(SIZEOF(.text) <= 0x1000, "RAM entry overlaps DTB")
}
