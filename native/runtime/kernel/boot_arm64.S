/* Vanta kernel boot code for QEMU's arm64 'virt' board (qemu-system-aarch64 -M virt -cpu cortex-a72 -kernel k.elf).
 *
 * QEMU loads the ELF at 0x40100000 (RAM starts at 0x40000000; the device tree sits at the start of RAM) and jumps
 * to _start on every CPU core... only core 0 continues, the others sleep. We drop from EL2 to EL1 if needed, turn
 * on the floating point unit, set up an identity-mapped MMU (so memory is normal cached memory and devices are
 * device memory), clear the bss and call kmain_arm64(device_tree).
 *
 * Also here: the exception vector table and setjmp/longjmp (which Vanta's attempt/rescue uses).
 */
        .section .text.boot, "ax"
        .global _start
_start:
        mrs x1, mpidr_el1
        and x1, x1, #0xff
        cbnz x1, park                      /* only core 0 runs the kernel */
        mov x19, x0                        /* device tree address (if the loader gave one) */

        mrs x1, CurrentEL
        lsr x1, x1, #2
        cmp x1, #2
        b.ne at_el1
        /* EL2 -> EL1 */
        mov x1, #(1 << 31)                 /* EL1 runs in AArch64 */
        msr hcr_el2, x1
        mov x1, #0x3c5                     /* EL1h, interrupts masked */
        msr spsr_el2, x1
        adr x1, at_el1
        msr elr_el2, x1
        eret
at_el1:
        ldr x1, =kstack_top
        mov sp, x1

        ldr x1, =__bss_start               /* clear the bss */
        ldr x2, =__bss_end
2:      cmp x1, x2
        b.hs 3f
        str xzr, [x1], #8
        b 2b
3:
        mov x1, #(3 << 20)                 /* CPACR_EL1.FPEN: let EL1 use floating point / SIMD */
        msr cpacr_el1, x1
        isb

        ldr x1, =vectors
        msr vbar_el1, x1

        /* page table: level 1, 1 GiB blocks, identity mapped.
         * 0-1 GiB: devices (UART, interrupt controller); 1-4 GiB: RAM (normal, cached) */
        ldr x1, =l1_table
        mov x2, #0x401                     /* block | access flag | attr index 0 (device) */
        str x2, [x1]
        mov x4, #1                         /* then: block | AF | inner shareable | attr index 1 (normal) */
        mov x7, #0x705
1:      lsl x5, x4, #30
        orr x6, x5, x7
        str x6, [x1, x4, lsl #3]
        add x4, x4, #1
        cmp x4, #4
        b.ne 1b
        ldr x2, =0xff00                    /* MAIR: attr0 = device nGnRnE, attr1 = normal write-back */
        msr mair_el1, x2
        ldr x2, =0x280993519               /* TCR: T0SZ=25 (39-bit), 4K granules, cached inner-shareable walks, no TTBR1, 40-bit PA */
        msr tcr_el1, x2
        msr ttbr0_el1, x1
        isb
        mrs x2, sctlr_el1
        orr x2, x2, #(1 << 0)              /* M: MMU on */
        orr x2, x2, #(1 << 2)              /* C: data cache */
        orr x2, x2, #(1 << 12)             /* I: instruction cache */
        bic x2, x2, #(1 << 1)              /* A: no alignment faults */
        msr sctlr_el1, x2
        isb

        mov x0, x19
        bl kmain_arm64
park:   wfe
        b park

/* ------------------------------------------------------------------ exceptions: everything goes to arm_exception */
        .macro VENT kind
        .align 7
        sub sp, sp, #256
        stp x0, x1, [sp, #0]
        stp x2, x3, [sp, #16]
        stp x4, x5, [sp, #32]
        stp x6, x7, [sp, #48]
        stp x8, x9, [sp, #64]
        stp x10, x11, [sp, #80]
        stp x12, x13, [sp, #96]
        stp x14, x15, [sp, #112]
        stp x16, x17, [sp, #128]
        stp x18, x30, [sp, #144]
        mov x0, #\kind
        mrs x1, esr_el1
        mrs x2, far_el1
        mrs x3, elr_el1
        bl arm_exception                   /* reports the fault (as a Vanta error) and never comes back */
        b .
        .endm

        .align 11
vectors:
        VENT 0
        VENT 1
        VENT 2
        VENT 3
        VENT 4
        VENT 5
        VENT 6
        VENT 7
        VENT 8
        VENT 9
        VENT 10
        VENT 11
        VENT 12
        VENT 13
        VENT 14
        VENT 15

/* ------------------------------------------------------------------ setjmp / longjmp (AAPCS64) */
        .text
        .global setjmp
setjmp:
        stp x19, x20, [x0, #0]
        stp x21, x22, [x0, #16]
        stp x23, x24, [x0, #32]
        stp x25, x26, [x0, #48]
        stp x27, x28, [x0, #64]
        stp x29, x30, [x0, #80]
        mov x2, sp
        str x2, [x0, #96]
        stp d8, d9, [x0, #104]
        stp d10, d11, [x0, #120]
        stp d12, d13, [x0, #136]
        stp d14, d15, [x0, #152]
        mov w0, #0
        ret

        .global longjmp
longjmp:
        ldp x19, x20, [x0, #0]
        ldp x21, x22, [x0, #16]
        ldp x23, x24, [x0, #32]
        ldp x25, x26, [x0, #48]
        ldp x27, x28, [x0, #64]
        ldp x29, x30, [x0, #80]
        ldr x2, [x0, #96]
        mov sp, x2
        ldp d8, d9, [x0, #104]
        ldp d10, d11, [x0, #120]
        ldp d12, d13, [x0, #136]
        ldp d14, d15, [x0, #152]
        cmp w1, #0
        csinc w0, w1, wzr, ne              /* longjmp(env, 0) returns 1 */
        br x30

        .section .bss
        .align 12
l1_table: .skip 4096
        .align 16
        .global kstack_bottom
kstack_bottom:
        .skip 1024 * 1024
        .global kstack_top
kstack_top:
