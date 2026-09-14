ENTRY(_start)

SECTIONS
{
  . = 0x00000000;
  _stack_top = 0x00001000;

  .text : {
    *(.text.init)
    *(.text*)
  }

  .rodata : { *(.rodata*) }
  .data   : { *(.data*) }
  .bss    : { *(.bss*) *(COMMON) }

  /DISCARD/ : { *(.comment*) *(.eh_frame*) *(.riscv.attributes*) }
}