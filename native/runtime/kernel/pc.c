/* Vanta kernel: x86 PC hardware.
 *
 *   VGA text mode   80x25 cells at 0xB8000 (character + color byte), hardware cursor via ports 0x3D4/0x3D5
 *   COM1 serial     0x3F8, 115200 baud 8N1; output mirrors the screen, input works like the keyboard
 *   IDT             256 interrupt gates; vectors 0-31 CPU exceptions, 32-47 hardware IRQs 0-15
 *   8259 PIC        remapped so IRQ 0-7 -> vectors 32-39 and IRQ 8-15 -> 40-47
 *   8253 PIT        channel 0 at 1000 Hz = one tick per millisecond; channel 2 drives the PC speaker
 *   PS/2 keyboard   IRQ 1, scancode set 1 translated to keys
 *   CMOS RTC        the date and time at boot
 *   Bochs/QEMU VBE  linear framebuffer graphics (or the boot loader's framebuffer, if it set one up)
 */
#include "vrt.h"
#include "kernel.h"
#include "kplat.h"
#include <string.h>
#include <stdio.h>

/* ------------------------------------------------------------------ Multiboot information */
typedef struct __attribute__((packed)) {
    uint32_t flags, mem_lower, mem_upper, boot_device, cmdline, mods_count, mods_addr;
    uint32_t syms[4];
    uint32_t mmap_length, mmap_addr, drives_length, drives_addr, config_table, boot_loader_name, apm_table;
    uint32_t vbe_control_info, vbe_mode_info;
    uint16_t vbe_mode, vbe_interface_seg, vbe_interface_off, vbe_interface_len;
    uint64_t framebuffer_addr;
    uint32_t framebuffer_pitch, framebuffer_width, framebuffer_height;
    uint8_t framebuffer_bpp, framebuffer_type;
    uint16_t pad;                                   /* the color info starts 4-byte aligned, at offset 112 */
    uint8_t red_pos, red_size, green_pos, green_size, blue_pos, blue_size;
} MbInfo;
typedef struct __attribute__((packed)) { uint32_t size; uint64_t addr, len; uint32_t type; } MbMmap;
typedef struct __attribute__((packed)) { uint32_t start, end, string, reserved; } MbModule;

extern char _kernel_start[], _kernel_end[];
static char loader_name[48] = "unknown";
static KFb boot_fb;
static int have_boot_fb = 0;

/* ------------------------------------------------------------------ serial (COM1) */
#define COM1 0x3F8
static int serial_ok = 0;
static uint8_t early[16];
static int nearly = 0;
static void serial_init(void) {
    for (int i = 0; i < 16 && inb(COM1 + 5) != 0xFF && (inb(COM1 + 5) & 1); i++) early[nearly++] = inb(COM1);   /* typed before boot */
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x80);      /* divisor latch */
    outb(COM1 + 0, 0x01);      /* 115200 baud */
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03);      /* 8 bits, no parity, one stop bit */
    outb(COM1 + 2, 0xC1);      /* FIFO on (keep bytes that already arrived) */
    outb(COM1 + 4, 0x0B);      /* DTR, RTS, OUT2 (needed for interrupts) */
    serial_ok = inb(COM1 + 5) != 0xFF;
    if (serial_ok) outb(COM1 + 1, 0x01);   /* interrupt when a byte arrives */
}
void plat_serial_putc(char c) {
    if (!serial_ok) return;
    for (int i = 0; i < 100000 && !(inb(COM1 + 5) & 0x20); i++) {}
    outb(COM1, (uint8_t)c);
}
static void serial_irq(void) {
    while (inb(COM1 + 5) & 1) kserial_byte(inb(COM1));
}

/* ------------------------------------------------------------------ VGA text mode */
static volatile uint16_t *const VGA = (volatile uint16_t *)0xB8000;
static int text_screen = 1;
int plat_has_screen(void) { return text_screen; }
void plat_text_size(int *cols, int *rows) { *cols = 80; *rows = 25; }
void plat_text_put(int x, int y, uint8_t ch, uint8_t attr) { if (text_screen) VGA[y * 80 + x] = (uint16_t)(ch | attr << 8); }
void plat_text_scroll(int top, uint8_t attr) {
    if (!text_screen) return;
    for (int i = top * 80; i < 80 * 24; i++) VGA[i] = VGA[i + 80];
    for (int i = 80 * 24; i < 80 * 25; i++) VGA[i] = (uint16_t)(' ' | attr << 8);
}
void plat_text_cursor(int x, int y, int visible) {
    if (!text_screen) return;
    if (!visible) { outb(0x3D4, 0x0A); outb(0x3D5, 0x20); return; }
    outb(0x3D4, 0x0A); outb(0x3D5, 14);
    outb(0x3D4, 0x0B); outb(0x3D5, 15);
    uint16_t pos = (uint16_t)(y * 80 + (x >= 80 ? 79 : x));
    outb(0x3D4, 0x0F); outb(0x3D5, (uint8_t)(pos & 0xFF));
    outb(0x3D4, 0x0E); outb(0x3D5, (uint8_t)(pos >> 8));
}
static void vga_no_blink(void) {        /* use all 16 background colors instead of blinking text */
    (void)inb(0x3DA);
    outb(0x3C0, 0x30);
    uint8_t v = inb(0x3C1);
    outb(0x3C0, v & ~0x08);
    (void)inb(0x3DA);
    outb(0x3C0, 0x20);
}

/* ------------------------------------------------------------------ interrupts */
typedef struct { uint16_t off_lo, sel; uint8_t ist, type; uint16_t off_mid; uint32_t off_hi, zero; } __attribute__((packed)) IdtEntry;
static IdtEntry idt[256];
extern const uint64_t isr_table[48];
typedef struct {
    uint64_t r15, r14, r13, r12, r11, r10, r9, r8, rbp, rdi, rsi, rdx, rcx, rbx, rax, vec, err, rip, cs, rflags, rsp, ss;
} Frame;
static uint16_t irq_mask = 0xFFFF;

static void pic_set_mask(void) { outb(0x21, (uint8_t)(irq_mask & 0xFF)); outb(0xA1, (uint8_t)(irq_mask >> 8)); }
static void pic_init(void) {
    outb(0x20, 0x11); io_wait(); outb(0xA0, 0x11); io_wait();     /* start initialisation */
    outb(0x21, 32); io_wait(); outb(0xA1, 40); io_wait();           /* vector offsets */
    outb(0x21, 4); io_wait(); outb(0xA1, 2); io_wait();             /* master/slave wiring */
    outb(0x21, 1); io_wait(); outb(0xA1, 1); io_wait();             /* 8086 mode */
    irq_mask = (uint16_t)~((1 << 0) | (1 << 1) | (1 << 2) | (1 << 4));   /* timer, keyboard, cascade, COM1 */
    pic_set_mask();
}
void plat_irq_enable(int irq) { irq_mask &= (uint16_t)~(1u << irq); if (irq >= 8) irq_mask &= (uint16_t)~(1u << 2); pic_set_mask(); }
static int driver_irq(int irq) { return irq == 0 || irq == 1 || irq == 4; }
void plat_irq_done(int irq) { if (!driver_irq(irq)) { irq_mask &= (uint16_t)~(1u << irq); pic_set_mask(); } }
static void idt_init(void) {
    for (int i = 0; i < 48; i++) {
        uint64_t h = isr_table[i];
        idt[i] = (IdtEntry){(uint16_t)h, 0x08, 0, 0x8E, (uint16_t)(h >> 16), (uint32_t)(h >> 32), 0};
    }
    struct __attribute__((packed)) { uint16_t limit; uint64_t base; } ptr = {sizeof idt - 1, (uint64_t)(uintptr_t)idt};
    __asm__ volatile("lidt %0" ::"m"(ptr));
}
void plat_interrupts_on(void) { __asm__ volatile("sti"); }
void plat_interrupts_off(void) { __asm__ volatile("cli"); }
void plat_idle(void) { __asm__ volatile("sti; hlt"); }
void plat_poll(void) {}

/* ------------------------------------------------------------------ PIT timer and the PC speaker */
static void pit_init(void) {
    uint16_t div = 1193182 / 1000;
    outb(0x43, 0x36);
    outb(0x40, (uint8_t)(div & 0xFF));
    outb(0x40, (uint8_t)(div >> 8));
}
uint64_t plat_ticks_ms(void) { return kticks; }
uint64_t plat_random_seed(void) { uint32_t lo, hi; __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi)); return ((uint64_t)hi << 32 | lo) ^ (kticks * 0x9E3779B97F4A7C15ULL); }
void plat_beep(uint32_t hz) {
    if (hz == 0) { outb(0x61, inb(0x61) & 0xFC); return; }
    uint32_t div = 1193182 / hz;
    outb(0x43, 0xB6);
    outb(0x42, (uint8_t)div);
    outb(0x42, (uint8_t)(div >> 8));
    outb(0x61, inb(0x61) | 3);
}

/* ------------------------------------------------------------------ PS/2 keyboard (scancode set 1) */
static const char SC_LOWER[128] = {
    0, 27, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 8, 9,
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0, 'a', 's',
    'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0, '\\', 'z', 'x', 'c', 'v',
    'b', 'n', 'm', ',', '.', '/', 0, '*', 0, ' ', 0};
static const char SC_UPPER[128] = {
    0, 27, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 8, 9,
    'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n', 0, 'A', 'S',
    'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0, '|', 'Z', 'X', 'C', 'V',
    'B', 'N', 'M', '<', '>', '?', 0, '*', 0, ' ', 0};
static int kb_shift = 0, kb_ctrl = 0, kb_caps = 0, kb_ext = 0;
int plat_scancode_for_char(int c) {
    for (int i = 0; i < 128; i++) if (SC_LOWER[i] == c && c) return i;
    return -1;
}
static void kbd_irq(void) {
    uint8_t sc = inb(0x60);
    if (sc == 0xE0) { kb_ext = 1; return; }
    int ext = kb_ext; kb_ext = 0;
    int up = sc & 0x80, code = sc & 0x7F;
    kinput_held(code, !up);
    if (code == 0x2A || code == 0x36) { kb_shift = !up; return; }
    if (code == 0x1D) { kb_ctrl = !up; return; }
    if (code == 0x38) return;                        /* alt */
    if (up) return;
    if (code == 0x3A) { kb_caps = !kb_caps; return; }
    if (code >= 0x3B && code <= 0x44) { kinput_push(KEY_F1 + code - 0x3B); return; }
    if (code == 0x57 || code == 0x58) { kinput_push(KEY_F1 + 10 + code - 0x57); return; }
    switch (code) {                                  /* arrows and friends (also the number pad without num lock) */
    case 0x48: kinput_push(KEY_UP); return;
    case 0x50: kinput_push(KEY_DOWN); return;
    case 0x4B: kinput_push(KEY_LEFT); return;
    case 0x4D: kinput_push(KEY_RIGHT); return;
    case 0x47: kinput_push(KEY_HOME); return;
    case 0x4F: kinput_push(KEY_END); return;
    case 0x49: kinput_push(KEY_PGUP); return;
    case 0x51: kinput_push(KEY_PGDN); return;
    case 0x52: kinput_push(KEY_INS); return;
    case 0x53: kinput_push(KEY_DEL); return;
    case 0x1C: kinput_push('\n'); return;           /* both enter keys */
    case 0x35: if (ext) { kinput_push('/'); return; } break;
    }
    char c = (kb_shift ? SC_UPPER : SC_LOWER)[code];
    if (!c) return;
    if (kb_caps && c >= 'a' && c <= 'z') c = (char)(c - 32);
    else if (kb_caps && c >= 'A' && c <= 'Z') c = (char)(c + 32);
    if (kb_ctrl && ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) { kinput_push(KEY_CTRL | (c | 32)); return; }
    kinput_push((unsigned char)c);
}

/* ------------------------------------------------------------------ the interrupt handler (called by isr_common) */
static const char *EXC[32] = {"divide by zero", "debug", "non-maskable interrupt", "breakpoint", "overflow",
    "bound range exceeded", "invalid instruction", "no FPU", "double fault", "coprocessor segment overrun",
    "invalid TSS", "segment not present", "stack segment fault", "general protection fault", "page fault",
    "reserved", "x87 floating point error", "alignment check", "machine check", "SIMD floating point error",
    "virtualization", "control protection", "reserved", "reserved", "reserved", "reserved", "reserved", "reserved",
    "hypervisor injection", "VMM communication", "security", "reserved"};
void isr_handler(Frame *f) {
    uint64_t v = f->vec;
    if (v < 32) {
        char msg[200];
        if (v == 14) {
            uint64_t cr2; __asm__ volatile("mov %%cr2, %0" : "=r"(cr2));
            snprintf(msg, sizeof msg, "the CPU stopped: %s at address 0x%llx (that memory isn't there)", EXC[v], (unsigned long long)cr2);
        } else snprintf(msg, sizeof msg, "the CPU stopped: %s (exception %d, code at 0x%llx)", EXC[v], (int)v, (unsigned long long)f->rip);
        if (kirq_depth > 0 || v == 8 || v == 18) kpanic(msg);
        /* a fault in the program itself (a bad peek/poke address, ...): report it as a normal Vanta error, which
         * `attempt ... rescue` can catch */
        if (f->rflags & 0x200) __asm__ volatile("sti");
        vrt_fail("%s", msg);
    }
    int irq = (int)v - 32;
    if (irq == 7 || irq == 15) {                     /* spurious interrupt? */
        uint16_t port = irq == 7 ? 0x20 : 0xA0;
        outb(port, 0x0B);
        if (!(inb(port) & 0x80)) { if (irq == 15) outb(0x20, 0x20); return; }
    }
    kirq_depth++;
    if (irq == 0) {
        kticks++;
        ktimer_tick(kticks);
        kserial_tick(kticks);
    } else if (irq == 1) kbd_irq();
    else if (irq == 4) serial_irq();
    if (kirq_notify(irq) && !driver_irq(irq)) { irq_mask |= (uint16_t)(1u << irq); pic_set_mask(); }   /* until the Vanta handler ran */
    if (irq >= 8) outb(0xA0, 0x20);
    outb(0x20, 0x20);
    kirq_depth--;
}

/* ------------------------------------------------------------------ real-time clock */
static uint8_t cmos(uint8_t reg) { outb(0x70, reg); return inb(0x71); }
static int64_t rtc_epoch(void) {
    for (int i = 0; i < 100000 && (cmos(0x0A) & 0x80); i++) {}
    uint8_t s = cmos(0x00), mi = cmos(0x02), h = cmos(0x04), d = cmos(0x07), mo = cmos(0x08), y = cmos(0x09), b = cmos(0x0B);
    int pm = h & 0x80; h &= 0x7F;
    if (!(b & 0x04)) {
#define BCD(x) (uint8_t)(((x) & 15) + ((x) >> 4) * 10)
        s = BCD(s); mi = BCD(mi); h = BCD(h); d = BCD(d); mo = BCD(mo); y = BCD(y);
    }
    if (!(b & 0x02) && pm) h = (uint8_t)((h % 12) + 12);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return 0;
    return kdays_from_civil(2000 + y, mo, d) * 86400 + h * 3600 + mi * 60 + s;
}

/* ------------------------------------------------------------------ PCI and Bochs/QEMU graphics */
static uint32_t pci_read(int bus, int dev, int fn, int off) {
    outl(0xCF8, 0x80000000u | (uint32_t)bus << 16 | (uint32_t)dev << 11 | (uint32_t)fn << 8 | (uint32_t)(off & 0xFC));
    return inl(0xCFC);
}
static uint32_t find_lfb(void) {
    for (int bus = 0; bus < 8; bus++) for (int dev = 0; dev < 32; dev++) {
        uint32_t id = pci_read(bus, dev, 0, 0);
        if ((id & 0xFFFF) == 0xFFFF) continue;
        uint32_t cls = pci_read(bus, dev, 0, 8) >> 16;
        if (id == 0x11111234 || id == 0xBEEF80EE || cls == 0x0300) {
            uint32_t bar = pci_read(bus, dev, 0, 0x10);
            if (!(bar & 1) && (bar & ~0xFu)) return bar & ~0xFu;
        }
    }
    return 0;
}
static void bga_write(uint16_t idx, uint16_t v) { outw(0x1CE, idx); outw(0x1CF, v); }
static uint16_t bga_read(uint16_t idx) { outw(0x1CE, idx); return inw(0x1CF); }
int plat_graphics_mode(int w, int h, KFb *out) {
    if (have_boot_fb) { *out = boot_fb; text_screen = 0; return 1; }
    uint16_t id = bga_read(0);
    if (id < 0xB0C0 || id > 0xB0C6) return 0;
    uint32_t lfb = find_lfb();
    if (!lfb) return 0;
    bga_write(4, 0);              /* off while changing */
    bga_write(1, (uint16_t)w);
    bga_write(2, (uint16_t)h);
    bga_write(3, 32);
    bga_write(4, 0x41);           /* on, with the linear framebuffer */
    if (bga_read(1) != w || bga_read(2) != h) { bga_write(4, 0); return 0; }
    *out = (KFb){(void *)(uintptr_t)lfb, w, h, (uint32_t)w * 4, 16, 8, 0};
    text_screen = 0;
    return 1;
}

/* ------------------------------------------------------------------ ports, power, CPU */
uint32_t plat_port_in(uint16_t p, int bits, const char *fn) { (void)fn; return bits == 8 ? inb(p) : bits == 16 ? inw(p) : inl(p); }
void plat_port_out(uint16_t p, uint32_t v, int bits, const char *fn) {
    (void)fn;
    if (bits == 8) outb(p, (uint8_t)v); else if (bits == 16) outw(p, (uint16_t)v); else outl(p, v);
}
_Noreturn void plat_halt(void) { for (;;) __asm__ volatile("cli; hlt"); }
_Noreturn void plat_reboot(void) {
    __asm__ volatile("cli");
    for (int i = 0; i < 100000 && (inb(0x64) & 2); i++) {}
    outb(0x64, 0xFE);                                /* pulse the reset line through the keyboard controller */
    for (volatile int i = 0; i < 10000000; i++) {}
    struct __attribute__((packed)) { uint16_t limit; uint64_t base; } none = {0, 0};
    __asm__ volatile("lidt %0; int3" ::"m"(none));   /* no interrupt table + an interrupt = the CPU resets */
    plat_halt();
}
void plat_power_off(void) {
    outw(0x604, 0x2000);                             /* QEMU (newer machines) */
    outw(0xB004, 0x2000);                            /* QEMU (older) and Bochs */
    outw(0x4004, 0x3400);                            /* VirtualBox */
}
const char *plat_arch(void) { return "x86_64"; }
const char *plat_loader_name(void) { return loader_name; }
void plat_cpu_name(char *buf, int n) {
    uint32_t r[12];
    uint32_t a, b, c, d;
    __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(0x80000000));
    if (a < 0x80000004) { snprintf(buf, (size_t)n, "x86-64 CPU"); return; }
    for (int i = 0; i < 3; i++) __asm__ volatile("cpuid" : "=a"(r[i * 4]), "=b"(r[i * 4 + 1]), "=c"(r[i * 4 + 2]), "=d"(r[i * 4 + 3]) : "a"(0x80000002 + i));
    char s[49]; memcpy(s, r, 48); s[48] = 0;
    char *p = s; while (*p == ' ') p++;
    snprintf(buf, (size_t)n, "%s", p);
}

/* ------------------------------------------------------------------ boot */
void kmain(uint32_t magic, uint32_t info_addr) {
    serial_init();
    kmem_init((uintptr_t)_kernel_end);
    MbInfo *mb = magic == 0x2BADB002 ? (MbInfo *)(uintptr_t)info_addr : NULL;
    if (mb && (mb->flags & (1 << 6))) {
        for (uint32_t off = 0; off < mb->mmap_length;) {
            MbMmap *e = (MbMmap *)(uintptr_t)(mb->mmap_addr + off);
            if (e->type == 1) kmem_add_region(e->addr, e->len);
            off += e->size + 4;
        }
    } else if (mb && (mb->flags & 1)) {
        kmem_add_region(0x100000, (uint64_t)mb->mem_upper * 1024);
    } else {
        kmem_add_region(0x100000, 31 * 1024 * 1024);   /* no information: assume 32 MiB */
    }
    kmem_reserve(0, 0x100000);                          /* BIOS area, VGA memory, boot information */
    kmem_reserve((uintptr_t)_kernel_start, (uintptr_t)(_kernel_end - _kernel_start));
    if (mb) {
        kmem_reserve(info_addr, sizeof(MbInfo));
        if (mb->flags & (1 << 6)) kmem_reserve(mb->mmap_addr, mb->mmap_length);
        if (mb->flags & (1 << 3)) {
            kmem_reserve(mb->mods_addr, mb->mods_count * sizeof(MbModule));
            MbModule *m = (MbModule *)(uintptr_t)mb->mods_addr;
            for (uint32_t i = 0; i < mb->mods_count; i++) kmem_reserve(m[i].start, m[i].end - m[i].start);
        }
        if (mb->flags & (1 << 9)) snprintf(loader_name, sizeof loader_name, "%s", (const char *)(uintptr_t)mb->boot_loader_name);
        if ((mb->flags & (1 << 12)) && mb->framebuffer_type == 1 && mb->framebuffer_bpp == 32 && mb->framebuffer_addr < (1ULL << 32)) {
            boot_fb = (KFb){(void *)(uintptr_t)mb->framebuffer_addr, (int)mb->framebuffer_width, (int)mb->framebuffer_height,
                            mb->framebuffer_pitch, mb->red_pos, mb->green_pos, mb->blue_pos};
            have_boot_fb = 1;
            text_screen = 0;                            /* the loader already left text mode */
        }
    }
    kmem_ready();
    if (text_screen) vga_no_blink();
    idt_init();
    pic_init();
    pit_init();
    while (inb(0x64) & 1) (void)inb(0x60);             /* empty the keyboard buffer */
    kboot_epoch_value = rtc_epoch();
    for (int i = 0; i < nearly; i++) kserial_byte(early[i]);
    if (serial_ok) serial_irq();                       /* bytes typed before we were listening */
    __asm__ volatile("sti");
    if (have_boot_fb) kcon_framebuffer(&boot_fb);
    kmain_common();
}
