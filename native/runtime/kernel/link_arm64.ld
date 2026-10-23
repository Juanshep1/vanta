/* Vanta kernel memory layout (QEMU arm64 'virt'): RAM starts at 0x40000000, where QEMU puts the device tree;
 * the kernel goes 1 MiB in. Physical address = virtual address (identity mapped). */
ENTRY(_start)
SECTIONS
{
    . = 0x40100000;
    _kernel_start = .;
    .text : { KEEP(*(.text.boot)) *(.text .text.*) }
    .rodata : ALIGN(16) { *(.rodata .rodata.*) }
    .init_array : ALIGN(8) {
        __init_array_start = .;
        KEEP(*(SORT(.init_array.*)))
        KEEP(*(.init_array .ctors))
        __init_array_end = .;
    }
    .data : ALIGN(16) { *(.data .data.*) }
    .bss : ALIGN(4096) { __bss_start = .; *(COMMON) *(.bss .bss.*) . = ALIGN(16); __bss_end = .; }
    . = ALIGN(4096);
    _kernel_end = .;
    /DISCARD/ : { *(.comment) *(.eh_frame) *(.note .note.*) }
}
