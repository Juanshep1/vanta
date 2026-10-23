/* Vanta kernel boot code for x86 PCs (and QEMU's `-kernel`).
 *
 * 1. A Multiboot (v1) header, so QEMU, GRUB and Limine know how to load the kernel at 1 MiB.
 * 2. The loader jumps to _start in 32-bit protected mode. We check the CPU can run 64-bit code, build page tables
 *    that map the first 4 GiB of memory 1:1 (2 MiB pages), turn on long mode and paging, and jump to 64-bit code.
 * 3. 64-bit code turns on SSE (the compiler uses it for decimals) and calls kmain(magic, multiboot_info).
 *
 * Also here: the interrupt entry stubs (every interrupt saves all registers and the SSE state, then calls
 * isr_handler in kernel.c) and setjmp/longjmp, which Vanta's attempt/rescue uses.
 */
        .set MB_MAGIC, 0x1BADB002
        .set MB_FLAGS, 0x00000003          /* bit 0: align modules on pages, bit 1: give us the memory map */
        .set MB_CHECKSUM, -(MB_MAGIC + MB_FLAGS)

        .section .multiboot, "a"
        .align 4
        .global multiboot_header
multiboot_header:
        .long MB_MAGIC
        .long MB_FLAGS
        .long MB_CHECKSUM
        .long 0, 0, 0, 0, 0                /* load addresses (unused: this is an ELF) */
        /* Video request, used only if flag bit 2 is set. kernel_build.py turns it on for a "framebuffer" copy of
         * the kernel (UEFI machines have no text mode): linear graphics, 1024 x 768, 32 bits per pixel. */
        .long 0                            /* mode type: 0 = linear graphics */
        .long 1024
        .long 768
        .long 32

        .section .bss
        .align 4096
pml4:   .skip 4096
pdpt:   .skip 4096
pdirs:  .skip 4096 * 4                    /* 4 page directories x 512 entries x 2 MiB = 4 GiB */
        .align 16
        .global kstack_bottom
kstack_bottom:
        .skip 1024 * 1024                  /* a 1 MiB kernel stack: deep Vanta recursion is fine */
        .global kstack_top
kstack_top:

        .section .data
        .global mb_magic_saved
        .global mb_info_saved
mb_magic_saved: .long 0
mb_info_saved:  .long 0

        .align 16
gdt64:
        .quad 0                            /* null */
        .quad 0x00AF9A000000FFFF           /* 0x08: 64-bit code, ring 0 */
        .quad 0x00CF92000000FFFF           /* 0x10: data, ring 0 */
gdt64_end:
gdt64_ptr:
        .word gdt64_end - gdt64 - 1
        .quad gdt64

no64_msg: .asciz "Vanta needs a 64-bit (x86-64) CPU."

        .section .text
        .code32
        .global _start
        .type _start, @function
_start:
        cli
        cld
        mov $kstack_top, %esp
        mov %eax, mb_magic_saved
        mov %ebx, mb_info_saved

        /* does this CPU have long mode? */
        mov $0x80000000, %eax
        cpuid
        cmp $0x80000001, %eax
        jb no_long_mode
        mov $0x80000001, %eax
        cpuid
        test $(1 << 29), %edx
        jz no_long_mode

        /* page tables: PML4[0] -> PDPT, PDPT[0..3] -> 4 page directories, each entry a 2 MiB page */
        mov $pdpt, %eax
        or $0x3, %eax
        mov %eax, pml4
        mov $pdirs, %eax
        or $0x3, %eax
        mov %eax, pdpt
        add $4096, %eax
        mov %eax, pdpt + 8
        add $4096, %eax
        mov %eax, pdpt + 16
        add $4096, %eax
        mov %eax, pdpt + 24
        mov $pdirs, %edi
        mov $0x83, %eax                    /* present | writable | 2 MiB page */
        mov $2048, %ecx
1:      mov %eax, (%edi)
        movl $0, 4(%edi)
        add $0x200000, %eax
        add $8, %edi
        loop 1b

        mov $pml4, %eax
        mov %eax, %cr3
        mov %cr4, %eax
        or $(1 << 5), %eax                 /* PAE */
        mov %eax, %cr4
        mov $0xC0000080, %ecx              /* EFER */
        rdmsr
        or $(1 << 8), %eax                 /* long mode enable */
        wrmsr
        mov %cr0, %eax
        or $0x80000001, %eax               /* paging + protected mode */
        mov %eax, %cr0
        lgdt gdt64_ptr
        ljmp $0x08, $long_mode_entry

no_long_mode:
        mov $no64_msg, %esi
        mov $0xB8000, %edi
2:      lodsb
        test %al, %al
        jz 3f
        mov $0x4F, %ah
        stosw
        jmp 2b
3:      hlt
        jmp 3b

        .code64
long_mode_entry:
        mov $0x10, %ax
        mov %ax, %ds
        mov %ax, %es
        mov %ax, %ss
        mov %ax, %fs
        mov %ax, %gs
        mov $kstack_top, %rsp
        lgdt gdt64_ptr                     /* reload with the 64-bit base */

        /* turn on SSE: CR0.EM = 0, CR0.MP = 1, CR4.OSFXSR = CR4.OSXMMEXCPT = 1 */
        mov %cr0, %rax
        and $~(1 << 2), %rax
        or $(1 << 1), %rax
        mov %rax, %cr0
        mov %cr4, %rax
        or $(3 << 9), %rax
        mov %rax, %cr4
        fninit

        xor %rbp, %rbp
        movl mb_magic_saved, %edi
        movl mb_info_saved, %esi
        call kmain
4:      cli
        hlt
        jmp 4b

/* ------------------------------------------------------------------ interrupts
 * The CPU pushes ss, rsp, rflags, cs, rip (and an error code for some exceptions). Each stub pushes a dummy error
 * code if needed and the vector number; isr_common saves every register and the SSE state and calls
 * isr_handler(struct frame *). */
        .macro ISR_NOERR n
        .global isr\n
isr\n:  pushq $0
        pushq $\n
        jmp isr_common
        .endm
        .macro ISR_ERR n
        .global isr\n
isr\n:  pushq $\n
        jmp isr_common
        .endm

        ISR_NOERR 0
        ISR_NOERR 1
        ISR_NOERR 2
        ISR_NOERR 3
        ISR_NOERR 4
        ISR_NOERR 5
        ISR_NOERR 6
        ISR_NOERR 7
        ISR_ERR 8
        ISR_NOERR 9
        ISR_ERR 10
        ISR_ERR 11
        ISR_ERR 12
        ISR_ERR 13
        ISR_ERR 14
        ISR_NOERR 15
        ISR_NOERR 16
        ISR_ERR 17
        ISR_NOERR 18
        ISR_NOERR 19
        ISR_NOERR 20
        ISR_ERR 21
        ISR_NOERR 22
        ISR_NOERR 23
        ISR_NOERR 24
        ISR_NOERR 25
        ISR_NOERR 26
        ISR_NOERR 27
        ISR_NOERR 28
        ISR_ERR 29
        ISR_ERR 30
        ISR_NOERR 31
        ISR_NOERR 32
        ISR_NOERR 33
        ISR_NOERR 34
        ISR_NOERR 35
        ISR_NOERR 36
        ISR_NOERR 37
        ISR_NOERR 38
        ISR_NOERR 39
        ISR_NOERR 40
        ISR_NOERR 41
        ISR_NOERR 42
        ISR_NOERR 43
        ISR_NOERR 44
        ISR_NOERR 45
        ISR_NOERR 46
        ISR_NOERR 47

isr_common:
        push %rax
        push %rbx
        push %rcx
        push %rdx
        push %rsi
        push %rdi
        push %rbp
        push %r8
        push %r9
        push %r10
        push %r11
        push %r12
        push %r13
        push %r14
        push %r15
        mov %rsp, %rbx                     /* rbx = the saved frame (callee-saved, survives the call) */
        sub $512, %rsp
        and $-16, %rsp
        fxsave (%rsp)
        mov %rbx, %rdi
        cld
        call isr_handler
        fxrstor (%rsp)
        mov %rbx, %rsp
        pop %r15
        pop %r14
        pop %r13
        pop %r12
        pop %r11
        pop %r10
        pop %r9
        pop %r8
        pop %rbp
        pop %rdi
        pop %rsi
        pop %rdx
        pop %rcx
        pop %rbx
        pop %rax
        add $16, %rsp                      /* vector + error code */
        iretq

        .section .rodata
        .global isr_table
        .align 8
isr_table:
        .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47
        .quad isr\n
        .endr

/* ------------------------------------------------------------------ setjmp / longjmp (System V x86-64) */
        .section .text
        .global setjmp
        .type setjmp, @function
setjmp:
        mov %rbx, 0(%rdi)
        mov %rbp, 8(%rdi)
        mov %r12, 16(%rdi)
        mov %r13, 24(%rdi)
        mov %r14, 32(%rdi)
        mov %r15, 40(%rdi)
        lea 8(%rsp), %rdx                  /* the caller's stack pointer after we return */
        mov %rdx, 48(%rdi)
        mov (%rsp), %rdx                   /* the return address */
        mov %rdx, 56(%rdi)
        xor %eax, %eax
        ret

        .global longjmp
        .type longjmp, @function
longjmp:
        mov %esi, %eax
        test %eax, %eax
        jnz 1f
        inc %eax
1:      mov 0(%rdi), %rbx
        mov 8(%rdi), %rbp
        mov 16(%rdi), %r12
        mov 24(%rdi), %r13
        mov 32(%rdi), %r14
        mov 40(%rdi), %r15
        mov 48(%rdi), %rsp
        jmp *56(%rdi)

        .section .note.GNU-stack, "", @progbits
