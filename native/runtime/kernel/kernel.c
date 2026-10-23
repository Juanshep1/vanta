/* Vanta kernel: the portable part — console, keyboard input, timers, interrupt hooks for Vanta functions,
 * the ram file system, framebuffer drawing, and the kernel builtins (`kernel_table`, read by vantac).
 *
 * The hardware itself (PC: VGA, PIC, PIT, PS/2, COM1, Bochs graphics; arm64: PL011 UART, generic timer) lives in
 * pc.c / virt_arm64.c behind the small plat_* interface in kplat.h.
 *
 * Interrupt handlers written in Vanta are "deferred": the C driver answers the hardware right away, marks the
 * interrupt as pending, and the Vanta function runs at the program's next safe point (every function call and loop
 * turn has one). That keeps the garbage collector safe and means a Vanta handler is just an ordinary function.
 */
#include "vrt.h"
#include "kernel.h"
#include "kplat.h"
#include "font8x16.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ctype.h>

/* ===================================================================================================== time */
volatile uint64_t kticks = 0;               /* milliseconds since boot (the platform timer adds to it) */
int64_t kboot_epoch_value = 0;
uint64_t kticks_ms(void) { return plat_ticks_ms(); }
int64_t kboot_epoch(void) { return kboot_epoch_value; }
uint64_t krandom_seed(void) { return plat_random_seed(); }

/* ===================================================================================================== deferred handlers */
volatile int kpending = 0;                  /* something for kdispatch to do */
static volatile uint32_t irq_pending = 0;    /* IRQs that happened and have a Vanta handler */
static uint32_t irq_hooked = 0;              /* IRQs with a Vanta handler */
static V handlers;                           /* pinned list: [0..15] IRQ handlers, then timer functions */
#define MAX_TIMERS 32
typedef struct { int active; uint64_t period, next; } KTimer;
static KTimer timers[MAX_TIMERS];
static volatile uint64_t next_due = ~0ULL;
static int in_dispatch = 0;
volatile int kirq_depth = 0;

static void recompute_due(void) {
    uint64_t d = ~0ULL;
    for (int i = 0; i < MAX_TIMERS; i++) if (timers[i].active && timers[i].next < d) d = timers[i].next;
    next_due = d;
}
void ktimer_tick(uint64_t now) {            /* called from the timer interrupt */
    if (now >= next_due) kpending = 1;
}
int kirq_notify(int irq) {                  /* called from interrupt context; returns 1 if a Vanta handler wants it */
    if (irq < 0 || irq > 15 || !(irq_hooked & (1u << irq))) return 0;
    irq_pending |= 1u << irq;
    kpending = 1;
    return 1;
}
static void run_handler(V fn, const char *what) {
    int line = vrt_line;                      /* the interrupted code's line, for its own error messages */
    VTry tr;
    vrt_try_push(&tr);
    if (setjmp(tr.jb) == 0) {
        vrt_call(fn, 0, NULL);
        vrt_try_pop();
    } else {
        printf("Oops! in %s: %s\n", what, vrt_errmsg);
    }
    vrt_line = line;
}
void kdispatch(void) {
    if (in_dispatch) return;
    in_dispatch = 1;
    kpending = 0;
    uint32_t mask = __atomic_exchange_n(&irq_pending, 0, __ATOMIC_SEQ_CST);
    for (int irq = 0; irq < 16; irq++) if (mask & (1u << irq)) {
        V fn = AS_LIST(handlers)->items[irq];
        if (fn.t != VT_NIL) run_handler(fn, "an interrupt handler");
        plat_irq_done(irq);
    }
    uint64_t now = plat_ticks_ms();
    if (now >= next_due) {
        for (int i = 0; i < MAX_TIMERS; i++) {
            if (!timers[i].active || now < timers[i].next) continue;
            timers[i].next += timers[i].period;
            if (timers[i].next <= now) timers[i].next = now + timers[i].period;   /* don't pile up if we fell behind */
            run_handler(AS_LIST(handlers)->items[16 + i], "a timer function");
        }
        recompute_due();
    }
    in_dispatch = 0;
}
/* The compiler puts vrt_safepoint() at every function entry and loop turn: run pending handlers there, then let
 * the garbage collector do its normal check. (vrt.c's own version is renamed vrt_gc_safepoint for kernel builds.) */
void vrt_gc_safepoint(void);
void vrt_safepoint(void) {
#ifdef KPLAT_POLLING
    static unsigned polls = 0;
    if ((++polls & 1023) == 0) plat_poll();
#endif
    if (kpending) kdispatch();
    vrt_gc_safepoint();
}
void kidle(void) {                          /* wait for something to happen (an interrupt), running handlers */
    if (kpending) kdispatch();
    plat_idle();
    if (kpending) kdispatch();
}
void ksleep_ms(uint64_t ms) {
    uint64_t end = plat_ticks_ms() + ms;
    while (plat_ticks_ms() < end) kidle();
}

/* ===================================================================================================== console */
static const uint32_t PALETTE[16] = {0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
                                     0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF};
static int con_cols = 80, con_rows = 25, cur_x = 0, cur_y = 0, cursor_on = 1, scroll_top = 0;
static uint8_t con_attr = 0x07;
static KFb fb;                               /* the framebuffer, when graphics mode is on */
static int gfx = 0;
static uint32_t *backbuf = NULL;             /* drawing target when double buffering */

static inline uint32_t *draw_target(void) { return backbuf ? backbuf : (uint32_t *)fb.addr; }
static inline int draw_pitch(void) { return backbuf ? fb.width : (int)(fb.pitch / 4); }
static inline uint32_t to_native(uint32_t rgb) {
    if (fb.red_pos == 16 && fb.green_pos == 8 && fb.blue_pos == 0) return rgb;
    return (((rgb >> 16) & 0xff) << fb.red_pos) | (((rgb >> 8) & 0xff) << fb.green_pos) | ((rgb & 0xff) << fb.blue_pos);
}
static inline void px(int x, int y, uint32_t c) {
    if ((unsigned)x < (unsigned)fb.width && (unsigned)y < (unsigned)fb.height) draw_target()[y * draw_pitch() + x] = c;
}
static void rect_native(int x, int y, int w, int h, uint32_t c) {
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > fb.width) w = fb.width - x;
    if (y + h > fb.height) h = fb.height - y;
    if (w <= 0 || h <= 0) return;
    uint32_t *t = draw_target(); int p = draw_pitch();
    for (int j = 0; j < h; j++) { uint32_t *row = t + (y + j) * p + x; for (int i = 0; i < w; i++) row[i] = c; }
}
static void glyph_native(int x, int y, int slot, uint32_t fg, uint32_t bg, int has_bg, int scale) {
    const unsigned char *g = kfont[slot];
    for (int r = 0; r < 16; r++) for (int c = 0; c < 8; c++) {
        int on = (g[r] >> (7 - c)) & 1;
        if (!on && !has_bg) continue;
        uint32_t col = on ? fg : bg;
        if (scale == 1) px(x + c, y + r, col);
        else rect_native(x + c * scale, y + r * scale, scale, scale, col);
    }
}

typedef struct { uint8_t cp437; int16_t slot; } Glyph;
static Glyph glyph_for(uint32_t cp) {
    Glyph g = {'?', '?' - KFONT_FIRST};
    if (cp >= 32 && cp < 127) { g.cp437 = (uint8_t)cp; g.slot = (int16_t)(cp - KFONT_FIRST); return g; }
    for (unsigned i = 0; i < sizeof kfont_extra / sizeof kfont_extra[0]; i++)
        if (kfont_extra[i].cp == cp) { g.cp437 = kfont_extra[i].cp437; g.slot = kfont_extra[i].slot; return g; }
    switch (cp) {                                   /* typographic characters: the nearest plain one */
    case 0x2013: case 0x2014: case 0x2212: return glyph_for('-');
    case 0x2018: case 0x2019: return glyph_for('\'');
    case 0x201C: case 0x201D: return glyph_for('"');
    case 0x2026: return glyph_for('.');
    case 0x00A0: return glyph_for(' ');
    case 0x25CF: return glyph_for(0x2022);         /* ● -> • */
    }
    return g;
}
static void put_cell(int x, int y, Glyph g, uint8_t attr) {
    if (x < 0 || y < 0 || x >= con_cols || y >= con_rows) return;
    if (gfx) glyph_native(x * 8, y * 16, g.slot, to_native(PALETTE[attr & 15]), to_native(PALETTE[attr >> 4]), 1, 1);
    else plat_text_put(x, y, g.cp437, attr);
}
static void clear_cells(uint8_t attr) {
    if (gfx) rect_native(0, 0, fb.width, fb.height, to_native(PALETTE[attr >> 4]));
    else for (int y = 0; y < con_rows; y++) for (int x = 0; x < con_cols; x++) plat_text_put(x, y, ' ', attr);
}
static void scroll_up(void) {
    if (gfx) {
        uint32_t *t = draw_target(); int p = draw_pitch();
        memmove(t + scroll_top * 16 * p, t + (scroll_top + 1) * 16 * p, (size_t)(con_rows - 1 - scroll_top) * 16 * (size_t)p * 4);
        rect_native(0, (con_rows - 1) * 16, fb.width, fb.height - (con_rows - 1) * 16, to_native(PALETTE[con_attr >> 4]));
    } else plat_text_scroll(scroll_top, con_attr);
}
static void sync_cursor(void) { if (!gfx) plat_text_cursor(cur_x, cur_y, cursor_on); }
static void newline(void) {
    cur_x = 0;
    if (++cur_y >= con_rows) { scroll_up(); cur_y = con_rows - 1; }
}
static void screen_putcp(uint32_t cp) {
    if (cp == '\n') { newline(); return; }
    if (cp == '\r') { cur_x = 0; return; }
    if (cp == '\t') { do screen_putcp(' '); while (cur_x % 8); return; }
    if (cp == '\b') { if (cur_x > 0) cur_x--; return; }
    if (cp < 32) return;
    if (cur_x >= con_cols) newline();
    put_cell(cur_x, cur_y, glyph_for(cp), con_attr);
    cur_x++;
}
/* UTF-8 decoding, kept across calls */
static uint32_t u8_cp = 0; static int u8_need = 0;
static void screen_write(const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (u8_need) {
            if ((c & 0xC0) == 0x80) { u8_cp = (u8_cp << 6) | (c & 0x3F); if (--u8_need == 0) screen_putcp(u8_cp); continue; }
            u8_need = 0; screen_putcp('?');
        }
        if (c < 0x80) screen_putcp(c);
        else if ((c & 0xE0) == 0xC0) { u8_cp = c & 0x1F; u8_need = 1; }
        else if ((c & 0xF0) == 0xE0) { u8_cp = c & 0x0F; u8_need = 2; }
        else if ((c & 0xF8) == 0xF0) { u8_cp = c & 0x07; u8_need = 3; }
        else screen_putcp('?');
    }
    sync_cursor();
}
static void serial_write(const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) { if (s[i] == '\n') plat_serial_putc('\r'); plat_serial_putc(s[i]); }
}
void kcon_write(const char *s, size_t n) {
    serial_write(s, n);
    if (plat_has_screen() || gfx) screen_write(s, n);
}
static void kcon_puts(const char *s) { kcon_write(s, strlen(s)); }

_Noreturn void kpanic(const char *msg) {
    plat_interrupts_off();
    con_attr = 0x4F;
    kcon_puts("\nKERNEL PANIC: ");
    kcon_puts(msg);
    kcon_puts("\nSystem halted.\n");
    plat_halt();
}
_Noreturn void kexit(int code) {
    con_attr = code ? 0x0C : 0x0A;
    kcon_puts(code ? "\nThe program stopped because of an error. System halted.\n" : "\nProgram finished. System halted.\n");
    plat_halt();
}

/* ===================================================================================================== keyboard input */
enum { K_UP = 0x100, K_DOWN, K_LEFT, K_RIGHT, K_HOME, K_END, K_PGUP, K_PGDN, K_INS, K_DEL,
       K_F1 = 0x120, K_CTRL = 0x200 };
#define QSIZE 256
static volatile uint16_t kq[QSIZE];
static volatile unsigned kq_head = 0, kq_tail = 0;
static volatile uint8_t held[128];
void kinput_push(int code) {                 /* from interrupt context (or the arm64 poller) */
    unsigned next = (kq_head + 1) % QSIZE;
    if (next == kq_tail) return;              /* full: drop the key */
    kq[kq_head] = (uint16_t)code;
    kq_head = next;
}
void kinput_held(int scancode, int down) { held[scancode & 127] = (uint8_t)down; }
/* serial input: the same keys as the keyboard (enter, backspace, ctrl+letter, arrows from VT100 escape codes) */
static int esc_state = 0, esc_arg = 0;
static uint64_t esc_time = 0;
static int last_cr = 0;
void kserial_byte(uint8_t c) {      /* a byte typed on the serial line: keys, arrows (escape sequences) */
    if (esc_state == 1) {
        if (c == '[' || c == 'O') { esc_state = 2; esc_arg = 0; return; }
        esc_state = 0; kinput_push(27);
    } else if (esc_state == 2) {
        if (c >= '0' && c <= '9') { esc_arg = esc_arg * 10 + (c - '0'); return; }
        esc_state = 0;
        switch (c) {
        case 'A': kinput_push(KEY_UP); return;
        case 'B': kinput_push(KEY_DOWN); return;
        case 'C': kinput_push(KEY_RIGHT); return;
        case 'D': kinput_push(KEY_LEFT); return;
        case 'H': kinput_push(KEY_HOME); return;
        case 'F': kinput_push(KEY_END); return;
        case '~':
            switch (esc_arg) { case 1: case 7: kinput_push(KEY_HOME); break; case 2: kinput_push(KEY_INS); break;
            case 3: kinput_push(KEY_DEL); break; case 4: case 8: kinput_push(KEY_END); break;
            case 5: kinput_push(KEY_PGUP); break; case 6: kinput_push(KEY_PGDN); break; }
            return;
        default: return;
        }
    }
    if (c == 27) { esc_state = 1; esc_time = plat_ticks_ms(); return; }
    if (c == '\n' && last_cr) { last_cr = 0; return; }
    last_cr = c == '\r';
    if (c == '\r' || c == '\n') kinput_push('\n');
    else if (c == 127 || c == 8) kinput_push(8);
    else if (c >= 1 && c <= 26 && c != 9) kinput_push(KEY_CTRL | ('a' + c - 1));
    else kinput_push(c);
}
void kserial_tick(uint64_t now) { if (esc_state && now - esc_time > 50) { esc_state = 0; kinput_push(27); } }   /* a lone escape */

static int key_waiting(void) { return kq_head != kq_tail; }
static int key_take(void) {
    if (kq_head == kq_tail) return -1;
    int c = kq[kq_tail];
    kq_tail = (kq_tail + 1) % QSIZE;
    return c;
}
static int key_wait(void) {
    for (;;) {
        int c = key_take();
        if (c >= 0) return c;
        kidle();
    }
}
int kkey_getchar(void) { int c = key_wait(); return c == '\n' ? '\n' : c; }

static const char *FKEYS[] = {"f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"};
static V key_text(int c) {
    char b[16];
    switch (c) {
    case '\n': return vrt_cstr("enter");
    case 8: return vrt_cstr("backspace");
    case 9: return vrt_cstr("tab");
    case 27: return vrt_cstr("escape");
    case ' ': return vrt_cstr(" ");
    case K_UP: return vrt_cstr("up");
    case K_DOWN: return vrt_cstr("down");
    case K_LEFT: return vrt_cstr("left");
    case K_RIGHT: return vrt_cstr("right");
    case K_HOME: return vrt_cstr("home");
    case K_END: return vrt_cstr("end");
    case K_PGUP: return vrt_cstr("page up");
    case K_PGDN: return vrt_cstr("page down");
    case K_INS: return vrt_cstr("insert");
    case K_DEL: return vrt_cstr("delete");
    }
    if (c >= K_F1 && c < K_F1 + 12) return vrt_cstr(FKEYS[c - K_F1]);
    if (c & K_CTRL) { snprintf(b, sizeof b, "ctrl+%c", (char)(c & 0x7f)); return vrt_cstr(b); }
    b[0] = (char)c; b[1] = 0;
    return vrt_cstr(b);
}

/* the line editor behind `ask` (and fgets): echo, backspace, and up/down history */
#define HIST 16
static char *history[HIST];
static int nhist = 0;
static void echo_str(const char *s) { kcon_write(s, strlen(s)); }
static void erase_chars(int n) {
    for (int i = 0; i < n; i++) {
        serial_write("\b \b", 3);
        if (plat_has_screen() || gfx) {
            if (cur_x == 0 && cur_y > 0) { cur_y--; cur_x = con_cols; }
            if (cur_x > 0) cur_x--;
            put_cell(cur_x, cur_y, glyph_for(' '), con_attr);
        }
    }
    sync_cursor();
}
static void gfx_cursor(int show) {
    if (!gfx || cur_x >= con_cols) return;
    put_cell(cur_x, cur_y, glyph_for(show ? '_' : ' '), con_attr);
}
int kcon_read_line(char *buf, int max) {
    int len = 0, hpos = nhist;
    for (;;) {
        gfx_cursor(1);
        int c = key_wait();
        gfx_cursor(0);
        if (c == '\n') { echo_str("\n"); break; }
        if (c == 8 || c == K_DEL) { if (len) { len--; erase_chars(1); } continue; }
        if ((c == K_UP || c == K_DOWN) && nhist) {
            if (c == K_UP && hpos > 0) hpos--;
            else if (c == K_DOWN && hpos < nhist) hpos++;
            else continue;
            erase_chars(len);
            const char *h = hpos < nhist ? history[hpos] : "";
            len = (int)strlen(h);
            if (len > max) len = max;
            memcpy(buf, h, (size_t)len);
            kcon_write(buf, (size_t)len);
            continue;
        }
        if (c == (K_CTRL | 'u')) { erase_chars(len); len = 0; continue; }
        if (c >= 32 && c < 127 && len < max) { buf[len++] = (char)c; char ch = (char)c; kcon_write(&ch, 1); }
    }
    buf[len] = 0;
    if (len) {
        if (nhist == HIST) { free(history[0]); memmove(history, history + 1, sizeof(char *) * (HIST - 1)); nhist--; }
        history[nhist++] = strdup(buf);
    }
    return len;
}

/* ===================================================================================================== argument helpers */
#define KNEED(lo, hi, name) do { if (argc < (lo) || argc > (hi)) { \
    if ((lo) == (hi)) vrt_fail("%s expects %d value(s), got %d", name, lo, argc); \
    else vrt_fail("%s expects %d to %d values, got %d", name, lo, hi, argc); } } while (0)
static int64_t iarg(V v, const char *name) {
    if (v.t == VT_INT) return v.u.i;
    if (v.t == VT_FLOAT && v.u.f == floor(v.u.f)) return (int64_t)v.u.f;
    if (v.t == VT_BOOL) return v.u.i;
    vrt_fail("%s needs a whole number", name);
}
static VStr *sarg(V v) { return AS_STR(vrt_display(v)); }

static const struct { const char *name; int idx; } COLORS[] = {
    {"black", 0}, {"blue", 1}, {"green", 2}, {"cyan", 3}, {"red", 4}, {"magenta", 5}, {"purple", 5}, {"brown", 6},
    {"orange", 6}, {"light gray", 7}, {"light grey", 7}, {"gray", 7}, {"grey", 7}, {"dark gray", 8}, {"dark grey", 8},
    {"light blue", 9}, {"light green", 10}, {"lime", 10}, {"light cyan", 11}, {"light red", 12}, {"pink", 13},
    {"light magenta", 13}, {"yellow", 14}, {"white", 15}, {NULL, 0}};
static int color_index(const char *s, size_t n, const char *fn) {
    while (n && *s == ' ') { s++; n--; }
    while (n && s[n - 1] == ' ') n--;
    for (int i = 0; COLORS[i].name; i++)
        if (strlen(COLORS[i].name) == n && !strncasecmp(COLORS[i].name, s, n)) return COLORS[i].idx;
    vrt_fail("%s: I don't know the color '%.*s' (try red, light blue, yellow, white, ... or \"white on blue\")", fn, (int)n, s);
}
/* a text console color: a number 0-255 (background * 16 + foreground), "yellow", or "yellow on blue".
 * One color name alone sets the foreground (or, with single_is_bg, the background with a readable foreground). */
static uint8_t parse_attr(V v, const char *fn, int single_is_bg) {
    if (v.t == VT_INT || v.t == VT_FLOAT) {
        int64_t a = iarg(v, fn);
        if (a < 0 || a > 255) vrt_fail("%s: a color number goes from 0 to 255 (background * 16 + text color)", fn);
        return (uint8_t)a;
    }
    if (v.t != VT_STR) vrt_fail("%s: a color is a name like \"yellow on blue\" or a number 0-255", fn);
    const char *s = AS_STR(v)->data;
    const char *on = strstr(s, " on ");
    if (on) {
        int fg = color_index(s, (size_t)(on - s), fn), bg = color_index(on + 4, strlen(on + 4), fn);
        return (uint8_t)(bg << 4 | fg);
    }
    int c = color_index(s, strlen(s), fn);
    if (single_is_bg) return (uint8_t)(c << 4 | ((c == 7 || c >= 10) ? 0 : 15));
    return (uint8_t)((con_attr & 0xF0) | c);
}
/* a drawing color: 0xRRGGBB, "#RRGGBB" or a color name */
static uint32_t parse_rgb(V v, const char *fn) {
    if (v.t == VT_INT || v.t == VT_FLOAT) return (uint32_t)(iarg(v, fn) & 0xFFFFFF);
    if (v.t == VT_STR) {
        const char *s = AS_STR(v)->data;
        if (s[0] == '#') return (uint32_t)(strtoul(s + 1, NULL, 16) & 0xFFFFFF);
        return PALETTE[color_index(s, strlen(s), fn)];
    }
    vrt_fail("%s: a color is a number like 0xFF8800, \"#FF8800\" or a name like \"red\"", fn);
}

/* ===================================================================================================== screen builtins */
static V k_clear_screen(int argc, V *a) {
    KNEED(0, 1, "clear_screen");
    if (argc == 1) con_attr = parse_attr(a[0], "clear_screen", 1);
    clear_cells(con_attr);
    cur_x = 0; cur_y = scroll_top;
    sync_cursor();
    if (!plat_has_screen() && !gfx) serial_write("\x1b[2J\x1b[H", 7);
    return VNIL;
}
static V k_print_at(int argc, V *a) {
    KNEED(3, 4, "print_at");
    int x = (int)iarg(a[0], "print_at"), y = (int)iarg(a[1], "print_at");
    uint8_t attr = argc == 4 ? parse_attr(a[3], "print_at", 0) : con_attr;
    VStr *s = sarg(a[2]);
    uint32_t cp = 0; int need = 0;
    for (int64_t i = 0; i < s->len; i++) {
        unsigned char c = (unsigned char)s->data[i];
        if (need) { cp = (cp << 6) | (c & 0x3F); if (--need) continue; }
        else if (c >= 0xF0) { cp = c & 7; need = 3; continue; }
        else if (c >= 0xE0) { cp = c & 15; need = 2; continue; }
        else if (c >= 0xC0) { cp = c & 31; need = 1; continue; }
        else cp = c;
        if (cp == '\n') { y++; x = (int)iarg(a[0], "print_at"); continue; }
        put_cell(x++, y, glyph_for(cp), attr);
    }
    return VNIL;
}
static V k_keep_top_rows(int argc, V *a) {
    KNEED(1, 1, "keep_top_rows");
    int64_t n = iarg(a[0], "keep_top_rows");
    if (n < 0 || n > con_rows - 2) vrt_fail("keep_top_rows: pick 0 to %d rows", con_rows - 2);
    scroll_top = (int)n;
    if (cur_y < scroll_top) { cur_y = scroll_top; cur_x = 0; sync_cursor(); }
    return VNIL;
}
static V k_set_color(int argc, V *a) { KNEED(1, 1, "set_color"); con_attr = parse_attr(a[0], "set_color", 0); return VNIL; }
static V k_set_cursor(int argc, V *a) {
    KNEED(2, 2, "set_cursor");
    int x = (int)iarg(a[0], "set_cursor"), y = (int)iarg(a[1], "set_cursor");
    cur_x = x < 0 ? 0 : x >= con_cols ? con_cols - 1 : x;
    cur_y = y < 0 ? 0 : y >= con_rows ? con_rows - 1 : y;
    sync_cursor();
    return VNIL;
}
static V k_cursor_position(int argc, V *a) { (void)a; KNEED(0, 0, "cursor_position"); V p[2] = {VI(cur_x), VI(cur_y)}; return vrt_list_of(2, p); }
static V k_show_cursor(int argc, V *a) { KNEED(0, 1, "show_cursor"); cursor_on = argc == 0 || vrt_truthy(a[0]); sync_cursor(); return VNIL; }
static V k_hide_cursor(int argc, V *a) { (void)a; KNEED(0, 0, "hide_cursor"); cursor_on = 0; sync_cursor(); return VNIL; }
static V k_screen_columns(int argc, V *a) { (void)a; KNEED(0, 0, "screen_columns"); return VI(con_cols); }
static V k_screen_rows(int argc, V *a) { (void)a; KNEED(0, 0, "screen_rows"); return VI(con_rows); }

/* ===================================================================================================== keyboard builtins */
static V k_read_key(int argc, V *a) { (void)a; KNEED(0, 0, "read_key"); return key_text(key_wait()); }
static V k_poll_key(int argc, V *a) {
    (void)a; KNEED(0, 0, "poll_key");
    if (kpending) kdispatch();
    int c = key_take();
    return c < 0 ? vrt_cstr("") : key_text(c);
}
static int scancode_for(const char *n) {
    static const struct { const char *name; int sc; } N[] = {
        {"escape", 0x01}, {"esc", 0x01}, {"backspace", 0x0E}, {"tab", 0x0F}, {"enter", 0x1C}, {"ctrl", 0x1D},
        {"shift", 0x2A}, {"left shift", 0x2A}, {"right shift", 0x36}, {"alt", 0x38}, {"space", 0x39}, {" ", 0x39},
        {"caps lock", 0x3A}, {"up", 0x48}, {"down", 0x50}, {"left", 0x4B}, {"right", 0x4D}, {"home", 0x47},
        {"end", 0x4F}, {"page up", 0x49}, {"page down", 0x51}, {"insert", 0x52}, {"delete", 0x53},
        {"f1", 0x3B}, {"f2", 0x3C}, {"f3", 0x3D}, {"f4", 0x3E}, {"f5", 0x3F}, {"f6", 0x40}, {"f7", 0x41},
        {"f8", 0x42}, {"f9", 0x43}, {"f10", 0x44}, {"f11", 0x57}, {"f12", 0x58}, {NULL, 0}};
    for (int i = 0; N[i].name; i++) if (!strcasecmp(N[i].name, n)) return N[i].sc;
    if (n[0] && !n[1]) return plat_scancode_for_char(tolower((unsigned char)n[0]));
    return -1;
}
static V k_key_pressed(int argc, V *a) {
    KNEED(0, 1, "key_pressed");
    if (kpending) kdispatch();
    if (argc == 0) return VB(key_waiting());
    int sc = scancode_for(sarg(a[0])->data);
    if (sc < 0) vrt_fail("key_pressed: I don't know the key '%s'", sarg(a[0])->data);
    if (sc == 0x2A) return VB(held[0x2A] || held[0x36]);
    return VB(held[sc]);
}
static V k_clear_keys(int argc, V *a) { (void)a; KNEED(0, 0, "clear_keys"); kq_tail = kq_head; return VNIL; }

/* ===================================================================================================== time builtins */
static V k_ticks(int argc, V *a) { (void)a; KNEED(0, 0, "ticks"); return VI((int64_t)plat_ticks_ms()); }
static V k_uptime(int argc, V *a) { (void)a; KNEED(0, 0, "uptime"); return VI((int64_t)(plat_ticks_ms() / 1000)); }
static V k_sleep_ms(int argc, V *a) { KNEED(1, 1, "sleep_ms"); int64_t ms = iarg(a[0], "sleep_ms"); if (ms > 0) ksleep_ms((uint64_t)ms); return VNIL; }
static V k_every(int argc, V *a) {
    KNEED(2, 2, "every");
    int64_t ms = iarg(a[0], "every");
    if (ms < 1) vrt_fail("every needs at least 1 millisecond");
    if (a[1].t != VT_FUNC && a[1].t != VT_BUILTIN && a[1].t != VT_BOUND) vrt_fail("every needs a function to run");
    for (int i = 0; i < MAX_TIMERS; i++) if (!timers[i].active) {
        AS_LIST(handlers)->items[16 + i] = a[1];
        timers[i].period = (uint64_t)ms;
        timers[i].next = plat_ticks_ms() + (uint64_t)ms;
        timers[i].active = 1;
        recompute_due();
        return VI(i + 1);
    }
    vrt_fail("every: at most %d timers can run at once", MAX_TIMERS);
}
static V k_stop_timer(int argc, V *a) {
    KNEED(1, 1, "stop_timer");
    int64_t id = iarg(a[0], "stop_timer");
    if (id >= 1 && id <= MAX_TIMERS) { timers[id - 1].active = 0; AS_LIST(handlers)->items[16 + id - 1] = VNIL; recompute_due(); }
    return VNIL;
}
static V k_on_interrupt(int argc, V *a) {
    KNEED(2, 2, "on_interrupt");
    int64_t irq = iarg(a[0], "on_interrupt");
    if (irq < 0 || irq > 15) vrt_fail("on_interrupt: hardware interrupts (IRQs) are numbered 0 to 15");
    if (a[1].t == VT_NIL) { irq_hooked &= ~(1u << irq); AS_LIST(handlers)->items[irq] = VNIL; return VNIL; }
    if (a[1].t != VT_FUNC && a[1].t != VT_BUILTIN && a[1].t != VT_BOUND) vrt_fail("on_interrupt needs a function to run");
    AS_LIST(handlers)->items[irq] = a[1];
    irq_hooked |= 1u << irq;
    plat_irq_enable((int)irq);
    return VNIL;
}
static V k_enable_interrupts(int argc, V *a) { (void)a; KNEED(0, 0, "enable_interrupts"); plat_interrupts_on(); return VNIL; }
static V k_disable_interrupts(int argc, V *a) { (void)a; KNEED(0, 0, "disable_interrupts"); plat_interrupts_off(); return VNIL; }

/* ===================================================================================================== hardware access */
static V k_port_in(int argc, V *a, int bits, const char *name) {
    KNEED(1, 1, name);
    int64_t p = iarg(a[0], name);
    if (p < 0 || p > 0xFFFF) vrt_fail("%s: port numbers go from 0 to 0xFFFF", name);
    return VI((int64_t)plat_port_in((uint16_t)p, bits, name));
}
static V k_port_out(int argc, V *a, int bits, const char *name) {
    KNEED(2, 2, name);
    int64_t p = iarg(a[0], name), v = iarg(a[1], name);
    if (p < 0 || p > 0xFFFF) vrt_fail("%s: port numbers go from 0 to 0xFFFF", name);
    plat_port_out((uint16_t)p, (uint32_t)v, bits, name);
    return VNIL;
}
static V k_port_in8(int argc, V *a) { return k_port_in(argc, a, 8, "port_in8"); }
static V k_port_in16(int argc, V *a) { return k_port_in(argc, a, 16, "port_in16"); }
static V k_port_in32(int argc, V *a) { return k_port_in(argc, a, 32, "port_in32"); }
static V k_port_out8(int argc, V *a) { return k_port_out(argc, a, 8, "port_out8"); }
static V k_port_out16(int argc, V *a) { return k_port_out(argc, a, 16, "port_out16"); }
static V k_port_out32(int argc, V *a) { return k_port_out(argc, a, 32, "port_out32"); }
static uintptr_t addr_arg(V v, const char *name, int size) {
    int64_t p = iarg(v, name);
    if (p < 0) vrt_fail("%s: an address can't be negative", name);
    if (p & (size - 1)) vrt_fail("%s: address 0x%llx isn't a multiple of %d", name, (long long)p, size);
    return (uintptr_t)p;
}
static V k_peek8(int argc, V *a) { KNEED(1, 1, "peek8"); return VI(*(volatile uint8_t *)addr_arg(a[0], "peek8", 1)); }
static V k_peek16(int argc, V *a) { KNEED(1, 1, "peek16"); return VI(*(volatile uint16_t *)addr_arg(a[0], "peek16", 2)); }
static V k_peek32(int argc, V *a) { KNEED(1, 1, "peek32"); return VI(*(volatile uint32_t *)addr_arg(a[0], "peek32", 4)); }
static V k_poke8(int argc, V *a) { KNEED(2, 2, "poke8"); *(volatile uint8_t *)addr_arg(a[0], "poke8", 1) = (uint8_t)iarg(a[1], "poke8"); return VNIL; }
static V k_poke16(int argc, V *a) { KNEED(2, 2, "poke16"); *(volatile uint16_t *)addr_arg(a[0], "poke16", 2) = (uint16_t)iarg(a[1], "poke16"); return VNIL; }
static V k_poke32(int argc, V *a) { KNEED(2, 2, "poke32"); *(volatile uint32_t *)addr_arg(a[0], "poke32", 4) = (uint32_t)iarg(a[1], "poke32"); return VNIL; }

/* ===================================================================================================== system */
static V k_halt(int argc, V *a) { (void)a; KNEED(0, 0, "halt"); con_attr = 0x0E; kcon_puts("System halted.\n"); plat_halt(); }
static V k_reboot(int argc, V *a) { (void)a; KNEED(0, 0, "reboot"); kcon_puts("Rebooting...\n"); plat_reboot(); }
static V k_power_off(int argc, V *a) { (void)a; KNEED(0, 0, "power_off"); kcon_puts("Powering off...\n"); plat_power_off(); kcon_puts("It's now safe to turn off your computer.\n"); plat_halt(); }
static void mset(V m, const char *k, V v) { vrt_map_set(m, vrt_cstr(k), v); }
static V k_memory_info(int argc, V *a) {
    (void)a; KNEED(0, 0, "memory_info");
    KMemInfo mi; kmem_info(&mi);
    V m = vrt_map();
    mset(m, "total", VI((int64_t)mi.total_bytes));
    mset(m, "free", VI((int64_t)mi.free_bytes));
    mset(m, "used", VI((int64_t)(mi.total_bytes - mi.free_bytes)));
    mset(m, "heap", VI((int64_t)mi.heap_bytes));
    mset(m, "heap_used", VI((int64_t)mi.heap_used_bytes));
    mset(m, "blocks", VI((int64_t)mi.allocations));
    mset(m, "page_size", VI((int64_t)mi.page_size));
    mset(m, "pages", VI((int64_t)mi.total_pages));
    mset(m, "free_pages", VI((int64_t)mi.free_pages));
    return m;
}
static V k_system_info(int argc, V *a) {
    (void)a; KNEED(0, 0, "system_info");
    char cpu[64];
    plat_cpu_name(cpu, sizeof cpu);
    V m = vrt_map();
    mset(m, "arch", vrt_cstr(plat_arch()));
    mset(m, "cpu", vrt_cstr(cpu));
    mset(m, "loader", vrt_cstr(plat_loader_name()));
    KMemInfo mi; kmem_info(&mi);
    mset(m, "memory", VI((int64_t)mi.total_bytes));
    mset(m, "screen", vrt_cstr(gfx ? "framebuffer" : plat_has_screen() ? "vga text" : "serial only"));
    mset(m, "columns", VI(con_cols));
    mset(m, "rows", VI(con_rows));
    return m;
}
static V k_beep(int argc, V *a) {
    KNEED(0, 2, "beep");
    int64_t f = argc > 0 ? iarg(a[0], "beep") : 880, ms = argc > 1 ? iarg(a[1], "beep") : 100;
    plat_beep((uint32_t)(f > 0 ? f : 0));
    if (ms > 0) { ksleep_ms((uint64_t)ms); plat_beep(0); }
    return VNIL;
}

/* ===================================================================================================== graphics */
static void need_gfx(const char *fn) { if (!gfx) vrt_fail("%s: turn on graphics first with graphics_mode(width, height)", fn); }
static V k_graphics_mode(int argc, V *a) {
    KNEED(0, 2, "graphics_mode");
    int w = argc > 0 ? (int)iarg(a[0], "graphics_mode") : 800, h = argc > 1 ? (int)iarg(a[1], "graphics_mode") : 600;
    if (w < 320 || h < 200 || w > 1920 || h > 1200) vrt_fail("graphics_mode: pick a size from 320x200 to 1920x1200");
    KFb f;
    if (!plat_graphics_mode(w, h, &f)) return VFALSE;
    fb = f;
    gfx = 1;
    free(backbuf); backbuf = NULL;
    con_cols = fb.width / 8; con_rows = fb.height / 16;
    cur_x = 0; cur_y = scroll_top;
    clear_cells(con_attr);
    return VTRUE;
}
void kcon_framebuffer(const KFb *f) {
    fb = *f; gfx = 1;
    con_cols = fb.width / 8; con_rows = fb.height / 16;
    cur_x = cur_y = 0;
}
static V k_screen_width(int argc, V *a) { (void)a; KNEED(0, 0, "screen_width"); return VI(gfx ? fb.width : con_cols); }
static V k_screen_height(int argc, V *a) { (void)a; KNEED(0, 0, "screen_height"); return VI(gfx ? fb.height : con_rows); }
static V k_rgb(int argc, V *a) {
    KNEED(3, 3, "rgb");
    int64_t r = iarg(a[0], "rgb"), g = iarg(a[1], "rgb"), b = iarg(a[2], "rgb");
    r = r < 0 ? 0 : r > 255 ? 255 : r; g = g < 0 ? 0 : g > 255 ? 255 : g; b = b < 0 ? 0 : b > 255 ? 255 : b;
    return VI(r << 16 | g << 8 | b);
}
static V k_put_pixel(int argc, V *a) {
    KNEED(3, 3, "put_pixel"); need_gfx("put_pixel");
    px((int)iarg(a[0], "put_pixel"), (int)iarg(a[1], "put_pixel"), to_native(parse_rgb(a[2], "put_pixel")));
    return VNIL;
}
static V k_fill_rect(int argc, V *a) {
    KNEED(5, 5, "fill_rect"); need_gfx("fill_rect");
    rect_native((int)iarg(a[0], "fill_rect"), (int)iarg(a[1], "fill_rect"), (int)iarg(a[2], "fill_rect"), (int)iarg(a[3], "fill_rect"),
                to_native(parse_rgb(a[4], "fill_rect")));
    return VNIL;
}
static V k_draw_rect(int argc, V *a) {
    KNEED(5, 5, "draw_rect"); need_gfx("draw_rect");
    int x = (int)iarg(a[0], "draw_rect"), y = (int)iarg(a[1], "draw_rect"), w = (int)iarg(a[2], "draw_rect"), h = (int)iarg(a[3], "draw_rect");
    uint32_t c = to_native(parse_rgb(a[4], "draw_rect"));
    rect_native(x, y, w, 1, c); rect_native(x, y + h - 1, w, 1, c); rect_native(x, y, 1, h, c); rect_native(x + w - 1, y, 1, h, c);
    return VNIL;
}
static V k_draw_line(int argc, V *a) {
    KNEED(5, 5, "draw_line"); need_gfx("draw_line");
    int x0 = (int)iarg(a[0], "draw_line"), y0 = (int)iarg(a[1], "draw_line"), x1 = (int)iarg(a[2], "draw_line"), y1 = (int)iarg(a[3], "draw_line");
    uint32_t c = to_native(parse_rgb(a[4], "draw_line"));
    int dx = x1 > x0 ? x1 - x0 : x0 - x1, dy = y1 > y0 ? y0 - y1 : y1 - y0, sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, err = dx + dy;
    for (int guard = 0; guard < 10000; guard++) {
        px(x0, y0, c);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
    return VNIL;
}
static V k_fill_circle(int argc, V *a) {
    KNEED(4, 4, "fill_circle"); need_gfx("fill_circle");
    int cx = (int)iarg(a[0], "fill_circle"), cy = (int)iarg(a[1], "fill_circle"), r = (int)iarg(a[2], "fill_circle");
    uint32_t c = to_native(parse_rgb(a[3], "fill_circle"));
    for (int y = -r; y <= r; y++) { int w = (int)sqrt((double)(r * r - y * y)); rect_native(cx - w, cy + y, 2 * w + 1, 1, c); }
    return VNIL;
}
static V k_draw_text(int argc, V *a) {
    KNEED(4, 5, "draw_text"); need_gfx("draw_text");
    int x = (int)iarg(a[0], "draw_text"), y = (int)iarg(a[1], "draw_text");
    VStr *s = sarg(a[2]);
    uint32_t c = to_native(parse_rgb(a[3], "draw_text"));
    int scale = argc == 5 ? (int)iarg(a[4], "draw_text") : 1;
    if (scale < 1) scale = 1;
    uint32_t cp = 0; int need = 0, x0 = x;
    for (int64_t i = 0; i < s->len; i++) {
        unsigned char ch = (unsigned char)s->data[i];
        if (need) { cp = (cp << 6) | (ch & 0x3F); if (--need) continue; }
        else if (ch >= 0xF0) { cp = ch & 7; need = 3; continue; }
        else if (ch >= 0xE0) { cp = ch & 15; need = 2; continue; }
        else if (ch >= 0xC0) { cp = ch & 31; need = 1; continue; }
        else cp = ch;
        if (cp == '\n') { x = x0; y += 16 * scale; continue; }
        glyph_native(x, y, glyph_for(cp).slot, c, 0, 0, scale);
        x += 8 * scale;
    }
    return VNIL;
}
static V k_double_buffer(int argc, V *a) {
    KNEED(1, 1, "double_buffer"); need_gfx("double_buffer");
    if (vrt_truthy(a[0])) {
        if (!backbuf) {
            backbuf = malloc((size_t)fb.width * (size_t)fb.height * 4);
            if (!backbuf) vrt_fail("double_buffer: not enough memory");
            for (int y = 0; y < fb.height; y++) memcpy(backbuf + y * fb.width, (uint8_t *)fb.addr + (size_t)y * fb.pitch, (size_t)fb.width * 4);
        }
    } else { free(backbuf); backbuf = NULL; }
    return VNIL;
}
static V k_show_frame(int argc, V *a) {
    (void)a; KNEED(0, 0, "show_frame"); need_gfx("show_frame");
    if (backbuf) for (int y = 0; y < fb.height; y++) memcpy((uint8_t *)fb.addr + (size_t)y * fb.pitch, backbuf + y * fb.width, (size_t)fb.width * 4);
    return VNIL;
}

/* ===================================================================================================== the ram file system
 * Files live in memory (gone when the computer turns off): a flat list of names, each with its bytes. Names can
 * contain '/' so programs can pretend to have folders. */
typedef struct { char *name; char *data; size_t len, cap; } RFile;
static RFile *rfiles = NULL;
static int nfiles = 0, capfiles = 0;
static int rfind(const char *name) { for (int i = 0; i < nfiles; i++) if (!strcmp(rfiles[i].name, name)) return i; return -1; }
static const char *fname_arg(V v, const char *fn) {
    if (v.t != VT_STR) vrt_fail("%s needs a file name (text)", fn);
    const char *n = AS_STR(v)->data;
    if (!n[0]) vrt_fail("%s: a file name can't be empty", fn);
    if (AS_STR(v)->len > 200) vrt_fail("%s: that file name is too long", fn);
    return n;
}
static RFile *rcreate(const char *name) {
    int i = rfind(name);
    if (i >= 0) return &rfiles[i];
    if (nfiles == capfiles) {
        capfiles = capfiles ? capfiles * 2 : 16;
        rfiles = realloc(rfiles, sizeof(RFile) * (size_t)capfiles);
        if (!rfiles) vrt_fail("out of memory for files");
    }
    RFile *f = &rfiles[nfiles++];
    f->name = strdup(name); f->data = NULL; f->len = f->cap = 0;
    return f;
}
static void rput(RFile *f, const char *s, size_t n, int append) {
    if (!append) f->len = 0;
    if (f->len + n > f->cap) {
        size_t nc = (f->len + n) * 2 + 16;
        char *d = realloc(f->data, nc);
        if (!d) vrt_fail("out of memory for files");
        f->data = d; f->cap = nc;
    }
    memcpy(f->data + f->len, s, n);
    f->len += n;
}
static V k_create_file(int argc, V *a) { KNEED(1, 1, "create_file"); rcreate(fname_arg(a[0], "create_file")); return VNIL; }
static V k_write_to_file(int argc, V *a) {
    KNEED(2, 2, "write_to_file");
    RFile *f = rcreate(fname_arg(a[0], "write_to_file"));
    if (a[1].t == VT_BYTES) rput(f, (const char *)AS_BYTES(a[1])->data, (size_t)AS_BYTES(a[1])->len, 0);
    else { VStr *s = sarg(a[1]); rput(f, s->data, (size_t)s->len, 0); }
    return VNIL;
}
static V k_append_to_file(int argc, V *a) {
    KNEED(2, 2, "append_to_file");
    RFile *f = rcreate(fname_arg(a[0], "append_to_file"));
    VStr *s = sarg(a[1]); rput(f, s->data, (size_t)s->len, 1);
    return VNIL;
}
static V k_read_from_file(int argc, V *a) {
    KNEED(1, 1, "read_from_file");
    const char *n = fname_arg(a[0], "read_from_file");
    int i = rfind(n);
    if (i < 0) vrt_fail("there's no file called '%s'", n);
    return vrt_str(rfiles[i].data ? rfiles[i].data : "", (int64_t)rfiles[i].len);
}
static int cmp_names(const void *x, const void *y) { return strcmp(((const RFile *)x)->name, ((const RFile *)y)->name); }
static V k_list_files(int argc, V *a) {
    (void)a; KNEED(0, 0, "list_files");
    if (nfiles > 1) qsort(rfiles, (size_t)nfiles, sizeof(RFile), cmp_names);
    V l = vrt_list(nfiles);
    for (int i = 0; i < nfiles; i++) vrt_list_push(l, vrt_cstr(rfiles[i].name));
    return l;
}
static V k_file_exists(int argc, V *a) { KNEED(1, 1, "file_exists"); return VB(rfind(fname_arg(a[0], "file_exists")) >= 0); }
static V k_delete_file(int argc, V *a) {
    KNEED(1, 1, "delete_file");
    const char *n = fname_arg(a[0], "delete_file");
    int i = rfind(n);
    if (i < 0) vrt_fail("there's no file called '%s'", n);
    free(rfiles[i].name); free(rfiles[i].data);
    rfiles[i] = rfiles[--nfiles];
    return VNIL;
}
static V k_rename_file(int argc, V *a) {
    KNEED(2, 2, "rename_file");
    const char *o = fname_arg(a[0], "rename_file"), *n = fname_arg(a[1], "rename_file");
    int i = rfind(o);
    if (i < 0) vrt_fail("there's no file called '%s'", o);
    if (rfind(n) >= 0) vrt_fail("a file called '%s' already exists", n);
    free(rfiles[i].name); rfiles[i].name = strdup(n);
    return VNIL;
}
static V k_file_length(int argc, V *a) {
    KNEED(1, 1, "file_length");
    const char *n = fname_arg(a[0], "file_length");
    int i = rfind(n);
    if (i < 0) vrt_fail("there's no file called '%s'", n);
    return VI((int64_t)rfiles[i].len);
}

/* ===================================================================================================== the table vantac reads */
typedef VEntry Entry;
static const Entry kernel_table[] = {
    {"clear_screen", k_clear_screen}, {"print_at", k_print_at}, {"set_color", k_set_color}, {"keep_top_rows", k_keep_top_rows}, {"set_cursor", k_set_cursor},
    {"cursor_position", k_cursor_position}, {"show_cursor", k_show_cursor}, {"hide_cursor", k_hide_cursor},
    {"screen_columns", k_screen_columns}, {"screen_rows", k_screen_rows},
    {"read_key", k_read_key}, {"poll_key", k_poll_key}, {"key_pressed", k_key_pressed}, {"clear_keys", k_clear_keys},
    {"ticks", k_ticks}, {"uptime", k_uptime}, {"sleep_ms", k_sleep_ms}, {"every", k_every}, {"stop_timer", k_stop_timer},
    {"on_interrupt", k_on_interrupt}, {"enable_interrupts", k_enable_interrupts}, {"disable_interrupts", k_disable_interrupts},
    {"port_in8", k_port_in8}, {"port_in16", k_port_in16}, {"port_in32", k_port_in32},
    {"port_out8", k_port_out8}, {"port_out16", k_port_out16}, {"port_out32", k_port_out32},
    {"peek8", k_peek8}, {"peek16", k_peek16}, {"peek32", k_peek32}, {"poke8", k_poke8}, {"poke16", k_poke16}, {"poke32", k_poke32},
    {"halt", k_halt}, {"reboot", k_reboot}, {"power_off", k_power_off}, {"memory_info", k_memory_info},
    {"system_info", k_system_info}, {"beep", k_beep},
    {"graphics_mode", k_graphics_mode}, {"screen_width", k_screen_width}, {"screen_height", k_screen_height}, {"rgb", k_rgb},
    {"put_pixel", k_put_pixel}, {"fill_rect", k_fill_rect}, {"draw_rect", k_draw_rect}, {"draw_line", k_draw_line},
    {"fill_circle", k_fill_circle}, {"draw_text", k_draw_text}, {"double_buffer", k_double_buffer}, {"show_frame", k_show_frame},
    {"create_file", k_create_file}, {"write_to_file", k_write_to_file}, {"append_to_file", k_append_to_file},
    {"read_from_file", k_read_from_file}, {"list_files", k_list_files}, {"file_exists", k_file_exists},
    {"delete_file", k_delete_file}, {"rename_file", k_rename_file}, {"file_length", k_file_length},
    {NULL, NULL}
};

/* The kernel runs one program on one CPU: the `lock` statement has nothing to wait for (vrt_thread.c, which has the
 * real versions, needs an operating system and is never linked into a kernel). */
__attribute__((weak)) void vrt_lock_enter(V lock) { (void)lock; }
__attribute__((weak)) void vrt_lock_exit(V lock) { (void)lock; }

/* ===================================================================================================== boot */
int main(int argc, char **argv);              /* the compiled Vanta program */
extern void (*__init_array_start[])(void), (*__init_array_end[])(void);

void kmain_common(void) {
    if (!gfx) plat_text_size(&con_cols, &con_rows);
    if (plat_has_screen() || gfx) { clear_cells(con_attr); cur_x = cur_y = 0; sync_cursor(); }
    handlers = vrt_list(16 + MAX_TIMERS);
    for (int i = 0; i < 16 + MAX_TIMERS; i++) vrt_list_push(handlers, VNIL);
    vrt_pin(handlers);
    for (void (**c)(void) = __init_array_start; c < __init_array_end; c++) (*c)();   /* C constructors */
    vrt_register_builtins(kernel_table);
    static char *argv[] = {"kernel", NULL};
    main(1, argv);
    kexit(0);
}
