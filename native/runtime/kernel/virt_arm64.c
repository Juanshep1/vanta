/* Vanta kernel: QEMU's arm64 'virt' board.
 *
 *   PL011 UART   0x09000000: the console (no screen on this board); input is polled
 *   PL031 RTC    0x09010000: the date and time at boot
 *   timer        the generic timer's counter (CNTVCT_EL0 / CNTFRQ_EL0) gives milliseconds
 *   memory       from the device tree QEMU puts at the start of RAM (0x40000000)
 *   power        PSCI calls (hvc) to reboot and power off
 *
 * There are no interrupts wired up here: the kernel polls the UART and the timer at safe points and while idle,
 * so `every`, `read_key`, `ask` and `sleep_ms` work; `on_interrupt`, ports and graphics are x86-only for now.
 */
#include "vrt.h"
#include "kernel.h"
#include "kplat.h"
#include <string.h>
#include <stdio.h>

#define UART 0x09000000UL
#define RTC 0x09010000UL
static inline uint32_t mmio_read(uintptr_t a) { return *(volatile uint32_t *)a; }
static inline void mmio_write(uintptr_t a, uint32_t v) { *(volatile uint32_t *)a = v; }

extern char _kernel_start[], _kernel_end[];

/* ------------------------------------------------------------------ console */
void plat_serial_putc(char c) {
    while (mmio_read(UART + 0x18) & (1 << 5)) {}   /* transmit FIFO full */
    mmio_write(UART, (uint8_t)c);
}
int plat_has_screen(void) { return 0; }
void plat_text_size(int *cols, int *rows) { *cols = 80; *rows = 25; }
void plat_text_put(int x, int y, uint8_t ch, uint8_t attr) { (void)x; (void)y; (void)ch; (void)attr; }
void plat_text_scroll(int top, uint8_t attr) { (void)top; (void)attr; }
void plat_text_cursor(int x, int y, int visible) { (void)x; (void)y; (void)visible; }
int plat_graphics_mode(int w, int h, KFb *out) { (void)w; (void)h; (void)out; return 0; }
int plat_scancode_for_char(int c) { (void)c; return -1; }

/* ------------------------------------------------------------------ time and polling */
static uint64_t counter(void) { uint64_t v; __asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(v)); return v; }
static uint64_t counter_hz(void) { uint64_t v; __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v)); return v ? v : 62500000; }
static uint64_t boot_count = 0;
uint64_t plat_ticks_ms(void) { return (counter() - boot_count) * 1000 / counter_hz(); }
uint64_t plat_random_seed(void) { return counter() * 0x9E3779B97F4A7C15ULL; }
void plat_poll(void) {
    while (!(mmio_read(UART + 0x18) & (1 << 4))) kserial_byte((uint8_t)mmio_read(UART));   /* receive FIFO not empty */
    uint64_t now = plat_ticks_ms();
    kticks = now;
    kserial_tick(now);
    ktimer_tick(now);
}
void plat_idle(void) {
    plat_poll();
    for (int i = 0; i < 2000; i++) __asm__ volatile("yield");
}
void plat_interrupts_on(void) {}
void plat_interrupts_off(void) {}
void plat_irq_enable(int irq) { (void)irq; vrt_fail("on_interrupt: hardware interrupts are only wired up on x86 PCs so far (use every() for timers)"); }
void plat_irq_done(int irq) { (void)irq; }
void plat_beep(uint32_t hz) { (void)hz; }

/* ------------------------------------------------------------------ hardware access, power */
uint32_t plat_port_in(uint16_t p, int bits, const char *fn) { (void)p; (void)bits; vrt_fail("%s: I/O ports only exist on x86 PCs (on arm64 devices are memory: use peek32/poke32)", fn); }
void plat_port_out(uint16_t p, uint32_t v, int bits, const char *fn) { (void)p; (void)v; (void)bits; vrt_fail("%s: I/O ports only exist on x86 PCs (on arm64 devices are memory: use peek32/poke32)", fn); }
_Noreturn void plat_halt(void) { for (;;) __asm__ volatile("msr daifset, #0xf; wfi"); }
static void psci(uint64_t fn) { register uint64_t x0 __asm__("x0") = fn; __asm__ volatile("hvc #0" : "+r"(x0) :: "memory"); }
_Noreturn void plat_reboot(void) { psci(0x84000009); plat_halt(); }
void plat_power_off(void) { psci(0x84000008); }
const char *plat_arch(void) { return "arm64"; }
const char *plat_loader_name(void) { return "qemu (arm64 virt)"; }
void plat_cpu_name(char *buf, int n) {
    uint64_t midr; __asm__ volatile("mrs %0, midr_el1" : "=r"(midr));
    unsigned impl = (unsigned)(midr >> 24) & 0xff, part = (unsigned)(midr >> 4) & 0xfff;
    const char *name = NULL;
    if (impl == 0x41) switch (part) {
        case 0xd03: name = "ARM Cortex-A53"; break; case 0xd07: name = "ARM Cortex-A57"; break;
        case 0xd08: name = "ARM Cortex-A72"; break; case 0xd0b: name = "ARM Cortex-A76"; break;
        case 0xd0c: name = "ARM Neoverse-N1"; break; case 0xd40: name = "ARM Neoverse-V1"; break;
        case 0xd49: name = "ARM Neoverse-N2"; break;
    }
    if (name) snprintf(buf, (size_t)n, "%s", name);
    else snprintf(buf, (size_t)n, "arm64 CPU (implementer 0x%x, part 0x%x)", impl, part);
}

/* ------------------------------------------------------------------ CPU exceptions -> Vanta errors */
void arm_exception(uint64_t kind, uint64_t esr, uint64_t far, uint64_t elr) {
    char msg[200];
    unsigned ec = (unsigned)(esr >> 26) & 0x3f;
    if (ec == 0x25 || ec == 0x24) snprintf(msg, sizeof msg, "the CPU stopped: memory fault at address 0x%llx (that memory isn't there)", (unsigned long long)far);
    else if (ec == 0x21 || ec == 0x20) snprintf(msg, sizeof msg, "the CPU stopped: it tried to run code at 0x%llx", (unsigned long long)far);
    else if (ec == 0x00) snprintf(msg, sizeof msg, "the CPU stopped: invalid instruction at 0x%llx", (unsigned long long)elr);
    else snprintf(msg, sizeof msg, "the CPU stopped: exception class 0x%x (vector %d) at 0x%llx", ec, (int)kind, (unsigned long long)elr);
    if ((kind & 3) != 0 || kind >= 8) kpanic(msg);   /* not a synchronous fault in kernel code */
    vrt_fail("%s", msg);                              /* a bad peek/poke: an ordinary Vanta error */
}

/* ------------------------------------------------------------------ device tree: how much memory is there? */
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static int fdt_memory(const uint8_t *fdt, uint64_t *base, uint64_t *size) {
    if (!fdt || be32(fdt) != 0xd00dfeed) return 0;
    const uint8_t *st = fdt + be32(fdt + 8);
    const char *strings = (const char *)fdt + be32(fdt + 12);
    int depth = 0, in_memory = 0;
    for (uint32_t off = 0; off < be32(fdt + 36);) {
        uint32_t tok = be32(st + off); off += 4;
        if (tok == 1) {                                   /* begin node */
            const char *name = (const char *)st + off;
            depth++;
            in_memory = depth == 2 && !strncmp(name, "memory", 6);
            off += (uint32_t)(strlen(name) + 4) & ~3u;
        } else if (tok == 2) { depth--; in_memory = 0; }
        else if (tok == 3) {                              /* property */
            uint32_t len = be32(st + off), nameoff = be32(st + off + 4);
            const uint8_t *val = st + off + 8;
            if (in_memory && !strcmp(strings + nameoff, "reg") && len >= 16) {
                *base = (uint64_t)be32(val) << 32 | be32(val + 4);
                *size = (uint64_t)be32(val + 8) << 32 | be32(val + 12);
                return 1;
            }
            off += 8 + ((len + 3) & ~3u);
        } else if (tok == 4) continue;
        else break;
    }
    return 0;
}

/* ------------------------------------------------------------------ boot */
void kmain_arm64(uint64_t dtb) {
    boot_count = counter();
    kmem_init((uintptr_t)_kernel_end);
    uint64_t base = 0x40000000ULL, size = 128ULL << 20;
    const uint8_t *fdt = (dtb >= 0x40000000ULL && dtb < 0x100000000ULL) ? (const uint8_t *)dtb : (const uint8_t *)0x40000000UL;
    fdt_memory(fdt, &base, &size);
    if (base + size > (4ULL << 30)) size = (4ULL << 30) - base;   /* the page tables map the first 4 GiB */
    kmem_add_region(base, size);
    kmem_reserve(base, (uintptr_t)_kernel_end - base);            /* the device tree and the kernel */
    if (dtb > (uintptr_t)_kernel_end && be32((const uint8_t *)dtb) == 0xd00dfeed) kmem_reserve(dtb, be32((const uint8_t *)dtb + 4));
    kmem_ready();
    kboot_epoch_value = (int64_t)mmio_read(RTC);
    kmain_common();
}
