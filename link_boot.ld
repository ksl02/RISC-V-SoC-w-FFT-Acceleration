/* bootloader lives at 0x3000 (word index 0xC00 in imem). */

ENTRY(_start)

SECTIONS
{
    . = 0x00003000;
    _stack_top = 0x00002FFC;   /* stack grows down, below bootloader */

    .text : {
        *(.text.init)
        *(.text*)
    }

    .rodata : { *(.rodata*) }
    .data   : { *(.data*) }
    .bss    : { *(.bss*) *(COMMON) }

    /DISCARD/ : { *(.comment*) *(.eh_frame*) *(.riscv.attributes*) }
}
