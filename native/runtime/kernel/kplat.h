/* Vanta kernel: what each machine (pc.c for x86 PCs, virt_arm64.c for QEMU's arm64 board) provides to kernel.c. */
#ifndef VANTA_KPLAT_H
#define VANTA_KPLAT_H
#include <stdint.h>

typedef struct { void *addr; int width, height; uint32_t pitch; int red_pos, green_pos, blue_pos; } KFb;

/* set up by the platform's boot code, then it calls kmain_common() (which runs the Vanta program) */
void kmain_common(void);

/* console hardware */
int plat_has_screen(void);                              /* a text screen (VGA) exists */
void plat_text_size(int *cols, int *rows);
void plat_text_put(int x, int y, uint8_t ch, uint8_t attr);
void plat_text_scroll(int top, uint8_t attr);            /* rows above `top` stay put */
void plat_text_cursor(int x, int y, int visible);
void plat_serial_putc(char c);
int plat_graphics_mode(int w, int h, KFb *out);         /* 1 if graphics mode is on */
int plat_scancode_for_char(int c);                      /* PC scancode (set 1) of the key that types c, or -1 */

/* time, interrupts, power */
uint64_t plat_ticks_ms(void);
uint64_t plat_random_seed(void);
void plat_idle(void);                                   /* sleep until the next interrupt (or poll input) */
void plat_poll(void);                                   /* machines without interrupts: check input and timers */
#if defined(__aarch64__)
#define KPLAT_POLLING 1
#endif
void plat_interrupts_on(void);
void plat_interrupts_off(void);
void plat_irq_enable(int irq);
void plat_irq_done(int irq);                            /* a deferred Vanta handler for this IRQ has run */
_Noreturn void plat_halt(void);
_Noreturn void plat_reboot(void);
void plat_power_off(void);
void plat_beep(uint32_t hz);

/* hardware access */
uint32_t plat_port_in(uint16_t port, int bits, const char *fn);
void plat_port_out(uint16_t port, uint32_t v, int bits, const char *fn);
const char *plat_arch(void);
const char *plat_loader_name(void);
void plat_cpu_name(char *buf, int n);

/* kernel.c, for the platform */
extern volatile uint64_t kticks;
extern int64_t kboot_epoch_value;
extern volatile int kpending;
extern volatile int kirq_depth;
void ktimer_tick(uint64_t now);
int kirq_notify(int irq);
void kinput_push(int code);
void kinput_held(int scancode, int down);
void kserial_byte(uint8_t c);                          /* a byte arrived on the serial line */
void kserial_tick(uint64_t now);                       /* call now and then (timer) */
void kcon_framebuffer(const KFb *f);             /* the boot loader already set up graphics: put the console there */
enum { KEY_UP = 0x100, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PGUP, KEY_PGDN, KEY_INS, KEY_DEL,
       KEY_F1 = 0x120, KEY_CTRL = 0x200 };
#endif
