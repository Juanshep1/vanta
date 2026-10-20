/* Vanta game runtime: a GBA-style video chip, input and timing for native Vanta games, on SDL2 (Mac, Windows,
 * Linux). The video side works like the Game Boy Advance's: 96 KB of video memory (tiles and maps), 1 KB of palette
 * memory (15-bit colours), 128 sprites (OAM), and display registers (DISPCNT, BGxCNT, scroll, blending, windows) —
 * so GBA-format graphics drop straight in. Vanta code writes memory and registers; this file draws each frame.
 *
 * Builtins (see the table at the bottom):
 *   game_open(title, scale)        open the window (240x160 scaled; F11 = fullscreen). VANTA_HEADLESS=1: no window.
 *   game_frame()                   draw the frame, show it, wait for the next 1/60 s, read input; no when closed
 *   game_keys()                    held buttons, GBA bits: A B Select Start Right Left Up Down R L (1 = held)
 *   vram_write(at, data, [from, [count]])   vram_fill(at, count, byte)   vram_read(at, count)
 *   pal_write(at, data, [from, [count]])    pal_set(index, rgb15)        pal_get(index)
 *   oam_set(i, attr0, attr1, attr2)         oam_write(at, data, [from, [count]])   affine_set(i, pa, pb, pc, pd)
 *   io_write(reg, value)  io_read(reg)      16-bit display registers by offset (0x00 DISPCNT, 0x08 BG0CNT, ...)
 *   lz77(data, at)                          GBA BIOS LZ77 (0x10) decompression -> bytes
 *   game_screenshot(path)                   save the last frame as a BMP
 *   game_ms()                               milliseconds since start
 *   audio_open(rate, channels)              sound out: signed 16-bit, 1 or 2 channels (yes if it opened)
 *   audio_queue(samples)                    queue frames: bytes of little-endian s16 (interleaved) or a list of ints
 *   audio_queued()                          frames still waiting to be played (0 when headless)
 *   audio_close()
 */
#include "vrt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <SDL.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#define VGAME_TOUCH 1      /* iPhone/iPad: full screen, on-screen buttons, files next to the app */
#include <unistd.h>
void vgame_ios_attach_window(SDL_Window *w);   /* vgame_ios.m: puts the window into the app's UIScene */
#endif

#define W 240
#define H 160

static uint8_t vram[0x18000];
static uint8_t pal[0x400];
static uint8_t oam[0x400];
static uint16_t io[0x60 / 2];
static uint32_t fb[W * H];
static SDL_Window *win;
static SDL_Renderer *ren;
static SDL_Texture *tex;
static SDL_GameController *pad;
static int headless, running = 1, opened = 0;
static uint32_t keys = 0;
static uint64_t next_frame_ns = 0;

#define IO(r) io[(r) >> 1]
enum { DISPCNT = 0x00, BG0CNT = 0x08, BG0HOFS = 0x10, BG0VOFS = 0x12, WIN0H = 0x40, WIN1H = 0x42, WIN0V = 0x44, WIN1V = 0x46,
       WININ = 0x48, WINOUT = 0x4A, MOSAIC = 0x4C, BLDCNT = 0x50, BLDALPHA = 0x52, BLDY = 0x54 };

#define NEED(n, name) do { if (argc != (n)) vrt_fail("%s expects %d value(s), got %d", name, n, argc); } while (0)
static int64_t ia(V v, const char *name) { if (v.t != VT_INT) vrt_fail("%s needs whole numbers", name); return v.u.i; }

/* ---------------------------------------------------------------- memory access from Vanta */
static void copy_in(uint8_t *mem, int64_t size, int argc, V *a, const char *name) {
    if (argc < 2 || argc > 4) vrt_fail("%s expects a position, data, and an optional start and count", name);
    int64_t at = ia(a[0], name);
    if (a[1].t != VT_BYTES) vrt_fail("%s needs bytes", name);
    VBytes *b = AS_BYTES(a[1]);
    int64_t from = argc >= 3 ? ia(a[2], name) : 0, n = argc >= 4 ? ia(a[3], name) : b->len - from;
    if (from < 0 || n < 0 || from + n > b->len) vrt_fail("%s: that range is outside the %lld bytes", name, (long long)b->len);
    if (at < 0 || at + n > size) vrt_fail("%s: position %lld + %lld is outside memory (%lld bytes)", name, (long long)at, (long long)n, (long long)size);
    memcpy(mem + at, b->data + from, (size_t)n);
}
static V b_vram_write(int argc, V *a) { copy_in(vram, sizeof vram, argc, a, "vram_write"); return VNIL; }
static V b_pal_write(int argc, V *a) { copy_in(pal, sizeof pal, argc, a, "pal_write"); return VNIL; }
static V b_oam_write(int argc, V *a) { copy_in(oam, sizeof oam, argc, a, "oam_write"); return VNIL; }
static V b_vram_fill(int argc, V *a) {
    NEED(3, "vram_fill");
    int64_t at = ia(a[0], "vram_fill"), n = ia(a[1], "vram_fill"), v = ia(a[2], "vram_fill");
    if (at < 0 || n < 0 || at + n > (int64_t)sizeof vram) vrt_fail("vram_fill: outside video memory");
    memset(vram + at, (int)(v & 255), (size_t)n);
    return VNIL;
}
static V b_vram_read(int argc, V *a) {
    NEED(2, "vram_read");
    int64_t at = ia(a[0], "vram_read"), n = ia(a[1], "vram_read");
    if (at < 0 || n < 0 || at + n > (int64_t)sizeof vram) vrt_fail("vram_read: outside video memory");
    V r = vrt_bytes(n);
    memcpy(AS_BYTES(r)->data, vram + at, (size_t)n);
    return r;
}
static V b_pal_set(int argc, V *a) {
    NEED(2, "pal_set");
    int64_t i = ia(a[0], "pal_set"), c = ia(a[1], "pal_set");
    if (i < 0 || i >= 512) vrt_fail("pal_set: colour %lld is outside 0..511", (long long)i);
    pal[i * 2] = (uint8_t)c; pal[i * 2 + 1] = (uint8_t)(c >> 8);
    return VNIL;
}
static V b_pal_get(int argc, V *a) {
    NEED(1, "pal_get");
    int64_t i = ia(a[0], "pal_get");
    if (i < 0 || i >= 512) vrt_fail("pal_get: colour %lld is outside 0..511", (long long)i);
    return VI(pal[i * 2] | (pal[i * 2 + 1] << 8));
}
static V b_oam_set(int argc, V *a) {
    NEED(4, "oam_set");
    int64_t i = ia(a[0], "oam_set");
    if (i < 0 || i >= 128) vrt_fail("oam_set: sprite %lld is outside 0..127", (long long)i);
    for (int k = 0; k < 3; k++) { int64_t v = ia(a[1 + k], "oam_set"); oam[i * 8 + k * 2] = (uint8_t)v; oam[i * 8 + k * 2 + 1] = (uint8_t)(v >> 8); }
    return VNIL;
}
static V b_affine_set(int argc, V *a) {   /* rotation/scaling group i (0..31): pa pb pc pd, 8.8 fixed point */
    NEED(5, "affine_set");
    int64_t i = ia(a[0], "affine_set");
    if (i < 0 || i >= 32) vrt_fail("affine_set: group %lld is outside 0..31", (long long)i);
    for (int k = 0; k < 4; k++) { int64_t v = ia(a[1 + k], "affine_set"); oam[i * 32 + k * 8 + 6] = (uint8_t)v; oam[i * 32 + k * 8 + 7] = (uint8_t)(v >> 8); }
    return VNIL;
}
static V b_io_write(int argc, V *a) {
    NEED(2, "io_write");
    int64_t r = ia(a[0], "io_write"), v = ia(a[1], "io_write");
    if (r < 0 || r >= 0x60 || (r & 1)) vrt_fail("io_write: register 0x%llx isn't a display register", (long long)r);
    IO(r) = (uint16_t)v;
    return VNIL;
}
static V b_io_read(int argc, V *a) {
    NEED(1, "io_read");
    int64_t r = ia(a[0], "io_read");
    if (r < 0 || r >= 0x60 || (r & 1)) vrt_fail("io_read: register 0x%llx isn't a display register", (long long)r);
    return VI(IO(r));
}

/* ---------------------------------------------------------------- LZ77 (GBA BIOS format 0x10) */
static V b_lz77(int argc, V *a) {
    NEED(2, "lz77");
    if (a[0].t != VT_BYTES) vrt_fail("lz77 needs bytes");
    VBytes *src = AS_BYTES(a[0]);
    int64_t p = ia(a[1], "lz77");
    if (p < 0 || p + 4 > src->len || src->data[p] != 0x10) vrt_fail("lz77: no compressed data at %lld", (long long)p);
    int64_t size = src->data[p + 1] | (src->data[p + 2] << 8) | (src->data[p + 3] << 16), o = 0;
    p += 4;
    V out = vrt_bytes(size);
    uint8_t *d = AS_BYTES(out)->data;
    while (o < size) {
        if (p >= src->len) vrt_fail("lz77: data ends early");
        uint8_t flags = src->data[p++];
        for (int bit = 0; bit < 8 && o < size; bit++) {
            if (flags & (0x80 >> bit)) {
                if (p + 1 >= src->len) vrt_fail("lz77: data ends early");
                int n = (src->data[p] >> 4) + 3, disp = (((src->data[p] & 15) << 8) | src->data[p + 1]) + 1;
                p += 2;
                if (disp > o) vrt_fail("lz77: bad back-reference");
                for (int k = 0; k < n && o < size; k++, o++) d[o] = d[o - disp];
            } else {
                if (p >= src->len) vrt_fail("lz77: data ends early");
                d[o++] = src->data[p++];
            }
        }
    }
    return out;
}

/* ---------------------------------------------------------------- drawing: the GBA's mode 0/1/2 compositor */
static inline uint32_t rgb(uint16_t c) {
    uint32_t r = c & 31, g = (c >> 5) & 31, b = (c >> 10) & 31;
    return 0xFF000000u | ((r << 3 | r >> 2) << 16) | ((g << 3 | g >> 2) << 8) | (b << 3 | b >> 2);
}
static inline uint16_t palc(int i) { return (uint16_t)(pal[i * 2] | (pal[i * 2 + 1] << 8)); }

/* per scanline: for each pixel, the top two layers (colour index into palette RAM, -1 = none) */
typedef struct { int16_t col; uint8_t prio; uint8_t layer; } Px;   /* layer: 0-3 BG, 4 OBJ, 5 backdrop */
static Px line_px[4 + 1][W];
static uint8_t obj_semi[W], obj_win[W];

static void draw_text_bg(int n, int y) {
    uint16_t cnt = IO(BG0CNT + 2 * n);
    int prio = cnt & 3, cbase = ((cnt >> 2) & 3) * 0x4000, bpp8 = (cnt >> 7) & 1, sbase = ((cnt >> 8) & 31) * 0x800, size = (cnt >> 14) & 3;
    int wpx = (size & 1) ? 512 : 256, hpx = (size & 2) ? 512 : 256;
    int hofs = IO(BG0HOFS + 4 * n) & 0x1FF, vofs = IO(BG0VOFS + 4 * n) & 0x1FF;
    int sy = (y + vofs) & (hpx - 1);
    for (int x = 0; x < W; x++) {
        int sx = (x + hofs) & (wpx - 1);
        int block = (sx >> 8) + ((sy >> 8) * (wpx >> 8));
        if (wpx == 256 && hpx == 512) block = sy >> 8;
        int tx = (sx & 255) >> 3, ty = (sy & 255) >> 3;
        int addr = sbase + block * 0x800 + (ty * 32 + tx) * 2;
        if (addr + 1 >= (int)sizeof vram) { line_px[n][x].col = -1; continue; }
        uint16_t e = (uint16_t)(vram[addr] | (vram[addr + 1] << 8));
        int tile = e & 0x3FF, px = sx & 7, py = sy & 7;
        if (e & 0x400) px = 7 - px;
        if (e & 0x800) py = 7 - py;
        int ci;
        if (bpp8) {
            int ta = cbase + tile * 64 + py * 8 + px;
            ci = ta < 0x10000 ? vram[ta] : 0;
        } else {
            int ta = cbase + tile * 32 + py * 4 + (px >> 1);
            ci = ta < 0x10000 ? ((vram[ta] >> ((px & 1) * 4)) & 15) : 0;
            if (ci) ci += (e >> 12) * 16;
        }
        line_px[n][x].col = ci ? (int16_t)ci : -1;
        line_px[n][x].prio = (uint8_t)prio;
    }
}

static int32_t bg_ref[2][2];   /* affine BG2/BG3 internal reference point, stepped per line */
static void draw_affine_bg(int n, int y) {
    uint16_t cnt = IO(BG0CNT + 2 * n);
    int prio = cnt & 3, cbase = ((cnt >> 2) & 3) * 0x4000, sbase = ((cnt >> 8) & 31) * 0x800, size = (cnt >> 14) & 3, wrap = (cnt >> 13) & 1;
    int span = 128 << size;
    int16_t pa = (int16_t)IO(0x20 + (n - 2) * 0x10), pc = (int16_t)IO(0x24 + (n - 2) * 0x10);
    int32_t xr = bg_ref[n - 2][0], yr = bg_ref[n - 2][1];
    for (int x = 0; x < W; x++, xr += pa, yr += pc) {
        int sx = xr >> 8, sy = yr >> 8;
        line_px[n][x].col = -1;
        if (wrap) { sx &= span - 1; sy &= span - 1; }
        else if (sx < 0 || sy < 0 || sx >= span || sy >= span) continue;
        int tile = vram[sbase + (sy >> 3) * (span >> 3) + (sx >> 3)];
        int ci = vram[cbase + tile * 64 + (sy & 7) * 8 + (sx & 7)];
        if (ci) { line_px[n][x].col = (int16_t)ci; line_px[n][x].prio = (uint8_t)prio; }
    }
    (void)y;
}

static const int obj_dims[3][4][2] = {
    {{8, 8}, {16, 16}, {32, 32}, {64, 64}}, {{16, 8}, {32, 8}, {32, 16}, {64, 32}}, {{8, 16}, {8, 32}, {16, 32}, {32, 64}}};

static void draw_objs(int y) {
    uint16_t disp = IO(DISPCNT);
    int map1d = (disp >> 6) & 1;
    for (int x = 0; x < W; x++) { line_px[4][x].col = -1; line_px[4][x].prio = 4; obj_semi[x] = 0; obj_win[x] = 0; }
    for (int i = 0; i < 128; i++) {
        uint16_t a0 = (uint16_t)(oam[i * 8] | (oam[i * 8 + 1] << 8)), a1 = (uint16_t)(oam[i * 8 + 2] | (oam[i * 8 + 3] << 8)), a2 = (uint16_t)(oam[i * 8 + 4] | (oam[i * 8 + 5] << 8));
        int affine = (a0 >> 8) & 1, dbl = (a0 >> 9) & 1;
        if (!affine && dbl) continue;              /* hidden */
        int shape = (a0 >> 14) & 3, sz = (a1 >> 14) & 3;
        if (shape == 3) continue;
        int w = obj_dims[shape][sz][0], h = obj_dims[shape][sz][1];
        int bw = (affine && dbl) ? w * 2 : w, bh = (affine && dbl) ? h * 2 : h;
        int oy = a0 & 255, ox = a1 & 511;
        if (oy >= H) oy -= 256;
        if (ox >= W) ox -= 512;
        int ly = y - oy;
        if (ly < 0 || ly >= bh) continue;
        int mode = (a0 >> 10) & 3, bpp8 = (a0 >> 13) & 1, tile = a2 & 1023, prio = (a2 >> 10) & 3, palb = (a2 >> 12) & 15;
        int16_t pa = 256, pb = 0, pc = 0, pd = 256;
        if (affine) {
            int g = (a1 >> 9) & 31;
            pa = (int16_t)(oam[g * 32 + 6] | (oam[g * 32 + 7] << 8)); pb = (int16_t)(oam[g * 32 + 14] | (oam[g * 32 + 15] << 8));
            pc = (int16_t)(oam[g * 32 + 22] | (oam[g * 32 + 23] << 8)); pd = (int16_t)(oam[g * 32 + 30] | (oam[g * 32 + 31] << 8));
        }
        for (int lx = 0; lx < bw; lx++) {
            int sx = ox + lx;
            if (sx < 0 || sx >= W) continue;
            int tx, ty;
            if (affine) {
                int cx = lx - bw / 2, cy = ly - bh / 2;
                tx = ((pa * cx + pb * cy) >> 8) + w / 2;
                ty = ((pc * cx + pd * cy) >> 8) + h / 2;
                if (tx < 0 || ty < 0 || tx >= w || ty >= h) continue;
            } else {
                tx = (a1 & 0x1000) ? w - 1 - lx : lx;
                ty = (a1 & 0x2000) ? h - 1 - ly : ly;
            }
            int t, ci;
            if (bpp8) {
                t = map1d ? tile + (ty >> 3) * (w >> 3) * 2 + (tx >> 3) * 2 : (tile & ~1) + (ty >> 3) * 32 + (tx >> 3) * 2;
                int addr = 0x10000 + (t & 1023) * 32 + (ty & 7) * 8 + (tx & 7);
                ci = addr < (int)sizeof vram ? vram[addr] : 0;
                if (ci) ci += 256;
            } else {
                t = map1d ? tile + (ty >> 3) * (w >> 3) + (tx >> 3) : tile + (ty >> 3) * 32 + (tx >> 3);
                int addr = 0x10000 + (t & 1023) * 32 + (ty & 7) * 4 + ((tx & 7) >> 1);
                ci = addr < (int)sizeof vram ? (vram[addr] >> ((tx & 1) * 4)) & 15 : 0;
                if (ci) ci += 256 + palb * 16;
            }
            if (!ci) continue;
            if (mode == 2) { obj_win[sx] = 1; continue; }
            if (prio < line_px[4][sx].prio || line_px[4][sx].col < 0) {
                if (line_px[4][sx].col < 0 || prio < line_px[4][sx].prio) {
                    line_px[4][sx].col = (int16_t)ci; line_px[4][sx].prio = (uint8_t)prio; obj_semi[sx] = mode == 1;
                }
            }
        }
    }
}

static int in_window(int x, int y, int *effects) {
    uint16_t disp = IO(DISPCNT);
    int any = (disp >> 13) & 7;
    if (!any) { *effects = 1; return 0x3F; }
    for (int w = 0; w < 2; w++) {
        if (!((disp >> (13 + w)) & 1)) continue;
        int x1 = IO(WIN0H + 2 * w) >> 8, x2 = IO(WIN0H + 2 * w) & 255, y1 = IO(WIN0V + 2 * w) >> 8, y2 = IO(WIN0V + 2 * w) & 255;
        int inx = x1 <= x2 ? (x >= x1 && x < x2) : (x >= x1 || x < x2);
        int iny = y1 <= y2 ? (y >= y1 && y < y2) : (y >= y1 || y < y2);
        if (inx && iny) { int m = (IO(WININ) >> (8 * w)) & 0x3F; *effects = (m >> 5) & 1; return m; }
    }
    if (((disp >> 15) & 1) && obj_win[x]) { int m = (IO(WINOUT) >> 8) & 0x3F; *effects = (m >> 5) & 1; return m; }
    int m = IO(WINOUT) & 0x3F; *effects = (m >> 5) & 1; return m;
}

static inline uint16_t blend(uint16_t a, uint16_t b, int ea, int eb) {
    int r = ((a & 31) * ea + (b & 31) * eb) >> 4, g = (((a >> 5) & 31) * ea + ((b >> 5) & 31) * eb) >> 4, bl = (((a >> 10) & 31) * ea + ((b >> 10) & 31) * eb) >> 4;
    if (r > 31) r = 31; if (g > 31) g = 31; if (bl > 31) bl = 31;
    return (uint16_t)(r | (g << 5) | (bl << 10));
}
static inline uint16_t brighten(uint16_t c, int ey, int up) {
    int r = c & 31, g = (c >> 5) & 31, b = (c >> 10) & 31;
    if (up) { r += ((31 - r) * ey) >> 4; g += ((31 - g) * ey) >> 4; b += ((31 - b) * ey) >> 4; }
    else { r -= (r * ey) >> 4; g -= (g * ey) >> 4; b -= (b * ey) >> 4; }
    return (uint16_t)(r | (g << 5) | (b << 10));
}

static void render(void) {
    uint16_t disp = IO(DISPCNT);
    int mode = disp & 7;
    if (disp & 0x80) { for (int i = 0; i < W * H; i++) fb[i] = 0xFFFFFFFFu; return; }   /* forced blank */
    for (int k = 0; k < 2; k++) {   /* affine reference points latch at the start of the frame */
        bg_ref[k][0] = (int32_t)((uint32_t)IO(0x28 + k * 0x10) | ((uint32_t)IO(0x2A + k * 0x10) << 16)) << 4 >> 4;
        bg_ref[k][1] = (int32_t)((uint32_t)IO(0x2C + k * 0x10) | ((uint32_t)IO(0x2E + k * 0x10) << 16)) << 4 >> 4;
    }
    uint16_t bld = IO(BLDCNT), alpha = IO(BLDALPHA);
    int bmode = (bld >> 6) & 3, eva = alpha & 31, evb = (alpha >> 8) & 31, evy = IO(BLDY) & 31;
    if (eva > 16) eva = 16; if (evb > 16) evb = 16; if (evy > 16) evy = 16;
    for (int y = 0; y < H; y++) {
        int bg_on[4] = {0};
        for (int n = 0; n < 4; n++) {
            if (!((disp >> (8 + n)) & 1)) continue;
            int affine = (mode == 1 && n == 2) || (mode == 2 && n >= 2);
            if (mode == 1 && n == 3) continue;
            if (mode == 2 && n < 2) continue;
            bg_on[n] = 1;
            if (affine) draw_affine_bg(n, y); else draw_text_bg(n, y);
        }
        int obj_on = (disp >> 12) & 1;
        if (obj_on) draw_objs(y);
        for (int x = 0; x < W; x++) {
            int fx, mask = in_window(x, y, &fx);
            /* find the top two visible layers by priority (OBJ wins ties, then lower BG number) */
            int top = 5, second = 5, tc = 0, sc = 0, tp = 9, sp = 9;
            for (int pr = 0; pr < 4; pr++) {
                if (obj_on && (mask & 0x10) && line_px[4][x].col >= 0 && line_px[4][x].prio == pr) {
                    if (top == 5) { top = 4; tc = line_px[4][x].col; tp = pr; } else if (second == 5) { second = 4; sc = line_px[4][x].col; sp = pr; }
                }
                for (int n = 0; n < 4; n++) {
                    if (!bg_on[n] || !(mask & (1 << n)) || line_px[n][x].col < 0 || line_px[n][x].prio != pr) continue;
                    if (top == 5) { top = n; tc = line_px[n][x].col; tp = pr; } else if (second == 5) { second = n; sc = line_px[n][x].col; sp = pr; }
                }
            }
            (void)tp; (void)sp;
            uint16_t ctop = top == 5 ? palc(0) : palc(tc), csec = second == 5 ? palc(0) : palc(sc);
            uint16_t out = ctop;
            int top_is_1st = (bld >> (top == 5 ? 5 : top)) & 1, sec_is_2nd = (bld >> (8 + (second == 5 ? 5 : second))) & 1;
            if (top == 4 && obj_semi[x] && sec_is_2nd) out = blend(ctop, csec, eva, evb);
            else if (fx && top_is_1st) {
                if (bmode == 1 && sec_is_2nd) out = blend(ctop, csec, eva, evb);
                else if (bmode == 2) out = brighten(ctop, evy, 1);
                else if (bmode == 3) out = brighten(ctop, evy, 0);
            }
            fb[y * W + x] = rgb(out);
        }
        for (int k = 0; k < 2; k++) {   /* step the affine reference by pb/pd */
            bg_ref[k][0] += (int16_t)IO(0x22 + k * 0x10);
            bg_ref[k][1] += (int16_t)IO(0x26 + k * 0x10);
        }
    }
}

/* ---------------------------------------------------------------- window, input, timing */
static uint64_t now_ns(void) { return (uint64_t)SDL_GetPerformanceCounter() * 1000000000ull / SDL_GetPerformanceFrequency(); }

/* ---------------------------------------------------------------- on-screen controls (touch devices)
 * Portrait: the picture fills the width at the top, the buttons sit below it. Landscape: the picture is
 * centred at full height and the buttons go either side. A held finger counts until it lifts; sliding a
 * finger across the D-pad changes direction, so it plays like a real pad. */
typedef struct { float x, y, r; uint32_t bits; int round; } Pad;
static Pad pads[10];
static int npads = 0;
static SDL_Rect game_rect;
static float dpad_x, dpad_y, dpad_r;
typedef struct { SDL_FingerID id; float x, y; int on; } Finger;
static Finger fingers[10];
static int touch_mode = 0;

static void touch_layout(int w, int h) {
    npads = 0;
    float u = (float)(w < h ? w : h);              /* the short side sets the button size */
    if (h > w) {                                    /* portrait */
        int gh = w * H / W;
        int top = (int)(h * 0.07f);
        game_rect = (SDL_Rect){0, top, w, gh};
        float area = top + gh, room = h - area;
        dpad_x = w * 0.26f; dpad_y = area + room * 0.42f; dpad_r = u * 0.17f;
        pads[npads++] = (Pad){w * 0.84f, area + room * 0.34f, u * 0.085f, 1, 1};          /* A */
        pads[npads++] = (Pad){w * 0.64f, area + room * 0.47f, u * 0.085f, 2, 1};          /* B */
        pads[npads++] = (Pad){w * 0.40f, area + room * 0.84f, u * 0.06f, 4, 0};           /* Select */
        pads[npads++] = (Pad){w * 0.60f, area + room * 0.84f, u * 0.06f, 8, 0};           /* Start */
        pads[npads++] = (Pad){w * 0.10f, area + room * 0.08f, u * 0.07f, 512, 0};         /* L */
        pads[npads++] = (Pad){w * 0.90f, area + room * 0.08f, u * 0.07f, 256, 0};         /* R */
    } else {                                        /* landscape */
        int gw = h * W / H;
        if (gw > w * 0.72f) gw = (int)(w * 0.72f);
        int gh = gw * H / W;
        game_rect = (SDL_Rect){(w - gw) / 2, (h - gh) / 2, gw, gh};
        dpad_x = w * 0.11f; dpad_y = h * 0.62f; dpad_r = u * 0.2f;
        pads[npads++] = (Pad){w * 0.92f, h * 0.55f, u * 0.1f, 1, 1};
        pads[npads++] = (Pad){w * 0.82f, h * 0.70f, u * 0.1f, 2, 1};
        pads[npads++] = (Pad){w * 0.08f, h * 0.92f, u * 0.06f, 4, 0};
        pads[npads++] = (Pad){w * 0.92f, h * 0.92f, u * 0.06f, 8, 0};
        pads[npads++] = (Pad){w * 0.08f, h * 0.15f, u * 0.08f, 512, 0};
        pads[npads++] = (Pad){w * 0.92f, h * 0.15f, u * 0.08f, 256, 0};
    }
}

static uint32_t touch_bits(void) {
    uint32_t b = 0;
    for (int i = 0; i < 10; i++) {
        if (!fingers[i].on) continue;
        float fx = fingers[i].x, fy = fingers[i].y;
        float dx = fx - dpad_x, dy = fy - dpad_y, d2 = dx * dx + dy * dy;
        if (d2 < dpad_r * dpad_r * 1.6f && d2 > dpad_r * dpad_r * 0.04f) {
            /* eight directions: a diagonal is two buttons */
            float ax = dx < 0 ? -dx : dx, ay = dy < 0 ? -dy : dy;
            if (ax > ay * 0.45f) b |= dx > 0 ? 16 : 32;
            if (ay > ax * 0.45f) b |= dy > 0 ? 128 : 64;
            continue;
        }
        for (int k = 0; k < npads; k++) {
            float px = fx - pads[k].x, py = fy - pads[k].y, rr = pads[k].r * 1.35f;
            if (px * px + py * py < rr * rr) b |= pads[k].bits;
        }
    }
    return b;
}

static void fill_circle(float cx, float cy, float r, SDL_Color c) {
    SDL_Vertex v[50];
    int idx[48 * 3], n = 48;
    v[0] = (SDL_Vertex){{cx, cy}, c, {0, 0}};
    for (int i = 0; i <= n; i++) {
        float t = (float)i / n * 6.2831853f;
        v[1 + (i % n)] = (SDL_Vertex){{cx + r * SDL_cosf(t), cy + r * SDL_sinf(t)}, c, {0, 0}};
    }
    for (int i = 0; i < n; i++) { idx[i * 3] = 0; idx[i * 3 + 1] = 1 + i; idx[i * 3 + 2] = 1 + (i + 1) % n; }
    SDL_RenderGeometry(ren, NULL, v, n + 1, idx, n * 3);
}

static void draw_touch_overlay(void) {
    SDL_SetRenderDrawBlendMode(ren, SDL_BLENDMODE_BLEND);
    SDL_Color base = {255, 255, 255, 46}, lit = {255, 255, 255, 120};
    fill_circle(dpad_x, dpad_y, dpad_r, base);
    float arm = dpad_r * 0.36f;
    SDL_Color armc = {255, 255, 255, 70};
    SDL_SetRenderDrawColor(ren, armc.r, armc.g, armc.b, armc.a);
    SDL_FRect hbar = {dpad_x - dpad_r * 0.82f, dpad_y - arm / 2, dpad_r * 1.64f, arm};
    SDL_FRect vbar = {dpad_x - arm / 2, dpad_y - dpad_r * 0.82f, arm, dpad_r * 1.64f};
    SDL_RenderFillRectF(ren, &hbar);
    SDL_RenderFillRectF(ren, &vbar);
    SDL_SetRenderDrawColor(ren, 255, 255, 255, 140);
    if (keys & 16) { SDL_FRect r = {dpad_x + arm / 2, dpad_y - arm / 2, dpad_r * 0.82f - arm / 2, arm}; SDL_RenderFillRectF(ren, &r); }
    if (keys & 32) { SDL_FRect r = {dpad_x - dpad_r * 0.82f, dpad_y - arm / 2, dpad_r * 0.82f - arm / 2, arm}; SDL_RenderFillRectF(ren, &r); }
    if (keys & 64) { SDL_FRect r = {dpad_x - arm / 2, dpad_y - dpad_r * 0.82f, arm, dpad_r * 0.82f - arm / 2}; SDL_RenderFillRectF(ren, &r); }
    if (keys & 128) { SDL_FRect r = {dpad_x - arm / 2, dpad_y + arm / 2, arm, dpad_r * 0.82f - arm / 2}; SDL_RenderFillRectF(ren, &r); }
    for (int k = 0; k < npads; k++) {
        SDL_Color c = (keys & pads[k].bits) ? lit : base;
        if (pads[k].round) fill_circle(pads[k].x, pads[k].y, pads[k].r, c);
        else {
            SDL_SetRenderDrawColor(ren, c.r, c.g, c.b, c.a);
            SDL_FRect r = {pads[k].x - pads[k].r * 1.3f, pads[k].y - pads[k].r * 0.45f, pads[k].r * 2.6f, pads[k].r * 0.9f};
            SDL_RenderFillRectF(ren, &r);
        }
    }
}

static void touch_event(SDL_Event *e, int w, int h) {
    if (e->type != SDL_FINGERDOWN && e->type != SDL_FINGERMOTION && e->type != SDL_FINGERUP) return;
    int slot = -1, free_slot = -1;
    for (int i = 0; i < 10; i++) {
        if (fingers[i].on && fingers[i].id == e->tfinger.fingerId) slot = i;
        if (!fingers[i].on && free_slot < 0) free_slot = i;
    }
    if (e->type == SDL_FINGERUP) { if (slot >= 0) fingers[slot].on = 0; return; }
    if (slot < 0) slot = free_slot;
    if (slot < 0) return;
    fingers[slot] = (Finger){e->tfinger.fingerId, e->tfinger.x * w, e->tfinger.y * h, 1};
}

static V b_game_open(int argc, V *a) {
    if (argc > 2) vrt_fail("game_open expects a title and an optional scale");
    const char *title = argc >= 1 ? vrt_cs(vrt_display(a[0])) : "Vanta";
    int scale = argc >= 2 ? (int)ia(a[1], "game_open") : 3;
    headless = getenv("VANTA_HEADLESS") != NULL;
    if (headless) { opened = 1; SDL_Init(SDL_INIT_TIMER); next_frame_ns = now_ns(); return VTRUE; }
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER | SDL_INIT_TIMER) != 0) vrt_fail("couldn't start the window: %s", SDL_GetError());
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
#ifdef VGAME_TOUCH
    touch_mode = 1;
    SDL_SetHint(SDL_HINT_ORIENTATIONS, "Portrait LandscapeLeft LandscapeRight");
    SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "0");
    win = SDL_CreateWindow(title, 0, 0, 0, 0, SDL_WINDOW_FULLSCREEN | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_BORDERLESS);
    if (win) vgame_ios_attach_window(win);
#else
    if (getenv("VANTA_TOUCH")) touch_mode = 1;     /* try the on-screen buttons on a computer */
    win = SDL_CreateWindow(title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, W * scale, H * scale, SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
#endif
    if (!win) vrt_fail("couldn't open a window: %s", SDL_GetError());
    ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!ren) ren = SDL_CreateRenderer(win, -1, 0);
    if (!touch_mode) {
        SDL_RenderSetLogicalSize(ren, W, H);
        SDL_RenderSetIntegerScale(ren, SDL_FALSE);
    }
    tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, W, H);
    for (int i = 0; i < SDL_NumJoysticks(); i++) if (SDL_IsGameController(i)) { pad = SDL_GameControllerOpen(i); break; }
    opened = 1;
    next_frame_ns = now_ns();
    return VTRUE;
}

static void read_input(void) {
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
        if (e.type == SDL_QUIT) running = 0;
        else if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_F11) {
            Uint32 f = SDL_GetWindowFlags(win) & SDL_WINDOW_FULLSCREEN_DESKTOP;
            SDL_SetWindowFullscreen(win, f ? 0 : SDL_WINDOW_FULLSCREEN_DESKTOP);
        } else if (e.type == SDL_CONTROLLERDEVICEADDED && !pad) pad = SDL_GameControllerOpen(e.cdevice.which);
        else if (touch_mode) { int ow, oh; SDL_GetRendererOutputSize(ren, &ow, &oh); touch_event(&e, ow, oh); }
    }
    const Uint8 *k = SDL_GetKeyboardState(NULL);
    uint32_t b = 0;
    if (k[SDL_SCANCODE_X] || k[SDL_SCANCODE_K]) b |= 1;          /* A */
    if (k[SDL_SCANCODE_Z] || k[SDL_SCANCODE_J]) b |= 2;          /* B */
    if (k[SDL_SCANCODE_BACKSPACE] || k[SDL_SCANCODE_RSHIFT]) b |= 4;   /* Select */
    if (k[SDL_SCANCODE_RETURN]) b |= 8;                          /* Start */
    if (k[SDL_SCANCODE_RIGHT] || k[SDL_SCANCODE_D]) b |= 16;
    if (k[SDL_SCANCODE_LEFT] || k[SDL_SCANCODE_A]) b |= 32;
    if (k[SDL_SCANCODE_UP] || k[SDL_SCANCODE_W]) b |= 64;
    if (k[SDL_SCANCODE_DOWN] || k[SDL_SCANCODE_S]) b |= 128;
    if (k[SDL_SCANCODE_E] || k[SDL_SCANCODE_L]) b |= 256;        /* R */
    if (k[SDL_SCANCODE_Q]) b |= 512;                             /* L */
    if (pad) {
        if (SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_A)) b |= 1;   /* bottom face button */
        if (SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_B)) b |= 2;
        if (SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_BACK)) b |= 4;
        if (SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_START)) b |= 8;
        if (SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_RIGHT)) b |= 16;
        if (SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_LEFT)) b |= 32;
        if (SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_UP)) b |= 64;
        if (SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_DPAD_DOWN)) b |= 128;
        if (SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_RIGHTSHOULDER)) b |= 256;
        if (SDL_GameControllerGetButton(pad, SDL_CONTROLLER_BUTTON_LEFTSHOULDER)) b |= 512;
        int lx = SDL_GameControllerGetAxis(pad, SDL_CONTROLLER_AXIS_LEFTX), ly = SDL_GameControllerGetAxis(pad, SDL_CONTROLLER_AXIS_LEFTY);
        if (lx > 16000) b |= 16; if (lx < -16000) b |= 32; if (ly < -16000) b |= 64; if (ly > 16000) b |= 128;
    }
    if (touch_mode) b |= touch_bits();
    keys = b;
}

static V b_game_frame(int argc, V *a) {
    (void)a; NEED(0, "game_frame");
    if (!opened) vrt_fail("call game_open first");
    render();
    if (!headless) {
        SDL_UpdateTexture(tex, NULL, fb, W * 4);
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        SDL_RenderClear(ren);
        if (touch_mode) {
            int ow, oh;
            SDL_GetRendererOutputSize(ren, &ow, &oh);
            touch_layout(ow, oh);
            SDL_RenderCopy(ren, tex, NULL, &game_rect);
            draw_touch_overlay();
        } else {
            SDL_RenderCopy(ren, tex, NULL, NULL);
        }
        SDL_RenderPresent(ren);
        read_input();
        /* pace to the GBA's 59.73 Hz even when vsync is off or faster */
        uint64_t frame = 16742706ull;
        next_frame_ns += frame;
        uint64_t t = now_ns();
        if (next_frame_ns > t) { uint64_t wait = next_frame_ns - t; if (wait > 2000000) SDL_Delay((Uint32)((wait - 1000000) / 1000000)); while (now_ns() < next_frame_ns) {} }
        else if (t - next_frame_ns > 100000000ull) next_frame_ns = t;   /* fell far behind (a pause): don't race to catch up */
    }
    return VB(running);
}
static V b_game_keys(int argc, V *a) { (void)a; NEED(0, "game_keys"); return VI(keys); }
static V b_game_ms(int argc, V *a) { (void)a; NEED(0, "game_ms"); return VI(opened ? (int64_t)SDL_GetTicks() : 0); }
static V b_game_set_keys(int argc, V *a) { NEED(1, "game_set_keys"); keys = (uint32_t)ia(a[0], "game_set_keys"); return VNIL; }   /* for scripted tests */
static V b_game_screenshot(int argc, V *a) {
    NEED(1, "game_screenshot");
    const char *path = vrt_cs(vrt_display(a[0]));
    FILE *f = fopen(path, "wb");
    if (!f) vrt_fail("couldn't write %s", path);
    uint32_t rowb = W * 3, size = 54 + rowb * H;
    uint8_t h[54] = {'B', 'M'};
    memcpy(h + 2, &size, 4); h[10] = 54; h[14] = 40;
    int32_t w = W, hh = H; memcpy(h + 18, &w, 4); memcpy(h + 22, &hh, 4); h[26] = 1; h[28] = 24;
    fwrite(h, 1, 54, f);
    for (int y = H - 1; y >= 0; y--) for (int x = 0; x < W; x++) { uint32_t p = fb[y * W + x]; uint8_t px[3] = {(uint8_t)p, (uint8_t)(p >> 8), (uint8_t)(p >> 16)}; fwrite(px, 1, 3, f); }
    fclose(f);
    return VNIL;
}

/* ---------------------------------------------------------------- audio
 * The game mixes its own sound (no sound chip here) and queues one video frame's worth of samples per frame;
 * SDL resamples to whatever the device wants. Queue policy, device side only: when the device has run dry
 * (a stall) one chunk of silence goes in first so playback restarts with a little slack, and when more than
 * 8 chunks are already waiting (the device clock running slow) a chunk is dropped. VANTA_HEADLESS=1: no
 * device, every call still works and audio_queued() is 0. VANTA_AUDIO_DUMP=out.wav writes exactly what the
 * game queued to a WAV file, headless or not (the header is kept valid after every write). */
static SDL_AudioDeviceID adev;
static int audio_on = 0, audio_rate = 0, audio_chans = 2;
static FILE *wav;
static uint32_t wav_bytes = 0;

static void wav_header(void) {
    uint8_t h[44];
    uint32_t v;
    memcpy(h, "RIFF", 4); v = 36 + wav_bytes; memcpy(h + 4, &v, 4); memcpy(h + 8, "WAVEfmt ", 8);
    v = 16; memcpy(h + 16, &v, 4);
    uint16_t fmt = 1, ch = (uint16_t)audio_chans, bits = 16, align = (uint16_t)(audio_chans * 2);
    memcpy(h + 20, &fmt, 2); memcpy(h + 22, &ch, 2);
    v = (uint32_t)audio_rate; memcpy(h + 24, &v, 4); v = (uint32_t)(audio_rate * audio_chans * 2); memcpy(h + 28, &v, 4);
    memcpy(h + 32, &align, 2); memcpy(h + 34, &bits, 2);
    memcpy(h + 36, "data", 4); memcpy(h + 40, &wav_bytes, 4);
    fseek(wav, 0, SEEK_SET); fwrite(h, 1, 44, wav); fseek(wav, 0, SEEK_END);
}
static void audio_shutdown(void) {
    if (adev) { SDL_CloseAudioDevice(adev); adev = 0; }
    if (wav) { wav_header(); fclose(wav); wav = NULL; }
    audio_on = 0;
}
static V b_audio_open(int argc, V *a) {
    if (argc < 1 || argc > 2) vrt_fail("audio_open expects a sample rate and an optional channel count");
    int rate = (int)ia(a[0], "audio_open"), chans = argc >= 2 ? (int)ia(a[1], "audio_open") : 2;
    if (rate < 1000 || rate > 192000) vrt_fail("audio_open: %d isn't a usable sample rate", rate);
    if (chans != 1 && chans != 2) vrt_fail("audio_open: channels must be 1 or 2");
    if (audio_on) audio_shutdown();
    audio_rate = rate; audio_chans = chans; audio_on = 1;
    const char *dump = getenv("VANTA_AUDIO_DUMP");
    if (dump && *dump) {
        wav = fopen(dump, "wb");
        if (!wav) vrt_fail("couldn't write %s", dump);
        wav_bytes = 0; wav_header();
    }
    static int registered = 0;
    if (!registered) { atexit(audio_shutdown); registered = 1; }
    if (getenv("VANTA_HEADLESS")) return VTRUE;
    if (SDL_InitSubSystem(SDL_INIT_AUDIO) != 0) return VFALSE;
    SDL_AudioSpec want, have;
    SDL_zero(want);
    want.freq = rate; want.format = AUDIO_S16LSB; want.channels = (Uint8)chans; want.samples = 256; want.callback = NULL;   /* ~19 ms at 13379 Hz */
    adev = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);   /* no allowed changes: SDL converts for us */
    if (!adev) return VFALSE;
    SDL_PauseAudioDevice(adev, 0);
    return VTRUE;
}
static int16_t audio_tmp[8192];
static V b_audio_queue(int argc, V *a) {
    NEED(1, "audio_queue");
    if (!audio_on) vrt_fail("call audio_open first");
    const void *data; uint32_t len;
    if (a[0].t == VT_BYTES) {
        VBytes *b = AS_BYTES(a[0]);
        data = b->data; len = (uint32_t)b->len & ~(uint32_t)(audio_chans * 2 - 1);
    } else if (a[0].t == VT_LIST) {
        VList *l = AS_LIST(a[0]);
        int64_t n = l->len - l->len % audio_chans;
        if (n > (int64_t)(sizeof audio_tmp / 2)) vrt_fail("audio_queue: at most %d samples at a time", (int)(sizeof audio_tmp / 2));
        for (int64_t i = 0; i < n; i++) {
            int64_t v = ia(l->items[i], "audio_queue");
            audio_tmp[i] = (int16_t)(v < -32768 ? -32768 : v > 32767 ? 32767 : v);
        }
        data = audio_tmp; len = (uint32_t)(n * 2);
    } else vrt_fail("audio_queue needs bytes or a list of numbers");
    if (len == 0) return VNIL;
    if (wav) { fwrite(data, 1, len, wav); wav_bytes += len; wav_header(); }
    if (adev) {
        uint32_t queued = SDL_GetQueuedAudioSize(adev);
        if (queued == 0) { static uint8_t zeros[16384]; SDL_QueueAudio(adev, zeros, len < sizeof zeros ? len : sizeof zeros); }
        if (queued <= len * 8) SDL_QueueAudio(adev, data, len);
    }
    return VNIL;
}
static V b_audio_queued(int argc, V *a) {
    (void)a; NEED(0, "audio_queued");
    if (!adev) return VI(0);
    return VI((int64_t)(SDL_GetQueuedAudioSize(adev) / (uint32_t)(audio_chans * 2)));
}
static V b_audio_close(int argc, V *a) { (void)a; NEED(0, "audio_close"); audio_shutdown(); return VNIL; }

typedef struct { const char *name; VBuiltinPtr fn; } Entry;
static const Entry game_table[] = {
    {"game_open", b_game_open}, {"game_frame", b_game_frame}, {"game_keys", b_game_keys}, {"game_ms", b_game_ms},
    {"game_set_keys", b_game_set_keys}, {"game_screenshot", b_game_screenshot},
    {"vram_write", b_vram_write}, {"vram_fill", b_vram_fill}, {"vram_read", b_vram_read},
    {"pal_write", b_pal_write}, {"pal_set", b_pal_set}, {"pal_get", b_pal_get},
    {"oam_set", b_oam_set}, {"oam_write", b_oam_write}, {"affine_set", b_affine_set},
    {"io_write", b_io_write}, {"io_read", b_io_read}, {"lz77", b_lz77},
    {"audio_open", b_audio_open}, {"audio_queue", b_audio_queue}, {"audio_queued", b_audio_queued}, {"audio_close", b_audio_close},
    {NULL, NULL}
};
V vgame_builtin_named(const char *name) {
    for (const Entry *e = game_table; e->name; e++) if (!strcmp(e->name, name)) return vrt_builtin(e->name, e->fn);
    return VUNDEF;
}
extern V (*vrt_extra_builtins)(const char *name);
__attribute__((constructor)) static void vgame_register(void) {
    vrt_extra_builtins = vgame_builtin_named;
#ifdef VGAME_TOUCH
    /* on a phone the program's data files sit inside the app bundle: run from there */
    char *base = SDL_GetBasePath();
    if (base) { if (chdir(base) != 0) {} SDL_free(base); }
#endif
}
