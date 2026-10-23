/* Vanta kernel memory layout (x86): loaded at 1 MiB, identity mapped (virtual address = physical address).
 *   0x00000000 - 0x000FFFFF   first megabyte: BIOS data, VGA text memory at 0xB8000 (left alone)
 *   0x00100000 - _kernel_end  the kernel: Multiboot header, code, read-only data, data, bss (incl. 1 MiB stack)
 *   _kernel_end - top of RAM  free pages for the page allocator and the heap
 */
ENTRY(_start)
SECTIONS
{
    . = 0x100000;
    _kernel_start = .;
    .multiboot : { KEEP(*(.multiboot)) }
    .text : ALIGN(16) { *(.text .text.*) }
    .rodata : ALIGN(16) { *(.rodata .rodata.*) }
    .init_array : ALIGN(8) {                 /* C constructors (runtime files register their builtins) */
        __init_array_start = .;
        KEEP(*(SORT(.init_array.*)))
        KEEP(*(.init_array .ctors))
        __init_array_end = .;
    }
    .data : ALIGN(16) { *(.data .data.*) }
    .bss : ALIGN(4096) { *(COMMON) *(.bss .bss.*) }
    . = ALIGN(4096);
    _kernel_end = .;
    /DISCARD/ : { *(.comment) *(.eh_frame) *(.note .note.*) }
}
