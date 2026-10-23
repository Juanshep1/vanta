/* Vanta canvas runtime: a beginner-friendly 2D graphics, input and sound API for native Vanta programs (games,
 * apps, tools), on SDL2. It lives next to the GBA-style video chip in vgame.c and shares nothing with it, so GBA
 * programs behave exactly as before.
 *
 * Everything is drawn in software into a framebuffer (the "canvas"), which is then scaled into the window. That
 * makes drawing identical with and without a window: VANTA_HEADLESS=1 never opens one, and screenshots, scripted
 * input and off-screen images all work the same way.
 *
 * Coordinates are canvas units (window(640, 480) gives 0..639 x 0..479, y grows downward). On a high-DPI screen the
 * framebuffer has 2x (or 3x) the pixels, so shapes and TTF text are sharp; the program never sees the difference.
 *
 * The whole API is documented in docs/GRAPHICS.md; the builtin table is at the bottom of this file.
 */
#include "vrt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <SDL.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#define VC_TOUCH 1
void vgame_ios_attach_window(SDL_Window *w);
#endif
#include "stb/stb_image.h"
#include "stb/stb_image_write.h"
#include "stb/stb_truetype.h"
int stb_vorbis_decode_filename(const char *filename, int *channels, int *sample_rate, short **output);
#include "vfont8x8.h"

#define PI_D 3.14159265358979323846

/* ================================================================ argument helpers */
static _Noreturn void argfail(const char *n, int lo, int hi, int got) {
    if (lo == hi) vrt_fail("%s expects %d value(s), got %d", n, lo, got);
    vrt_fail("%s expects %d to %d values, got %d", n, lo, hi, got);
}
#define ARGS(lo, hi, name) do { if (argc < (lo) || argc > (hi)) argfail(name, lo, hi, argc); } while (0)
static int isnum(V v) { return v.t == VT_INT || v.t == VT_FLOAT; }
static double num(V v, const char *n) {
    if (v.t == VT_INT) return (double)v.u.i;
    if (v.t == VT_FLOAT) return v.u.f;
    vrt_fail("%s needs numbers", n);
}
static int inum(V v, const char *n) { double d = num(v, n); return (int)floor(d + 0.5); }
static const char *txt(V v, const char *n) { if (v.t != VT_STR) vrt_fail("%s needs text", n); return vrt_cs(v); }
static int lower_eq(const char *a, const char *b) {
    for (; *a && *b; a++, b++) { char x = *a, y = *b; if (x >= 'A' && x <= 'Z') x += 32; if (y >= 'A' && y <= 'Z') y += 32; if (x != y) return 0; }
    return *a == *b;
}
static double clampd(double v, double lo, double hi) { return v < lo ? lo : v > hi ? hi : v; }
static V map_get_s(V map, const char *key, int *found) { return vrt_map_get(map, vrt_cstr(key), found); }

/* ================================================================ colours: 0xAARRGGBB, straight alpha */
typedef struct { const char *n; uint32_t c; } NamedColor;
static const NamedColor named_colors[] = {
    {"black", 0x000000}, {"white", 0xFFFFFF}, {"red", 0xFF0000}, {"green", 0x008000}, {"blue", 0x0000FF},
    {"yellow", 0xFFFF00}, {"orange", 0xFFA500}, {"purple", 0x800080}, {"pink", 0xFFC0CB}, {"cyan", 0x00FFFF},
    {"magenta", 0xFF00FF}, {"gray", 0x808080}, {"grey", 0x808080}, {"lightgray", 0xD3D3D3}, {"lightgrey", 0xD3D3D3},
    {"darkgray", 0xA9A9A9}, {"darkgrey", 0xA9A9A9}, {"dimgray", 0x696969}, {"silver", 0xC0C0C0}, {"brown", 0xA52A2A},
    {"lime", 0x00FF00}, {"navy", 0x000080}, {"teal", 0x008080}, {"olive", 0x808000}, {"maroon", 0x800000},
    {"gold", 0xFFD700}, {"skyblue", 0x87CEEB}, {"lightblue", 0xADD8E6}, {"darkblue", 0x00008B}, {"darkgreen", 0x006400},
    {"lightgreen", 0x90EE90}, {"darkred", 0x8B0000}, {"violet", 0xEE82EE}, {"indigo", 0x4B0082}, {"beige", 0xF5F5DC},
    {"coral", 0xFF7F50}, {"salmon", 0xFA8072}, {"tomato", 0xFF6347}, {"crimson", 0xDC143C}, {"turquoise", 0x40E0D0},
    {"aqua", 0x00FFFF}, {"fuchsia", 0xFF00FF}, {"khaki", 0xF0E68C}, {"lavender", 0xE6E6FA}, {"plum", 0xDDA0DD},
    {"tan", 0xD2B48C}, {"chocolate", 0xD2691E}, {"orchid", 0xDA70D6}, {"steelblue", 0x4682B4}, {"royalblue", 0x4169E1},
    {"forestgreen", 0x228B22}, {"seagreen", 0x2E8B57}, {"slategray", 0x708090}, {"midnightblue", 0x191970},
    {"hotpink", 0xFF69B4}, {"deeppink", 0xFF1493}, {"ivory", 0xFFFFF0}, {"snow", 0xFFFAFA}, {"mintcream", 0xF5FFFA},
    {"wheat", 0xF5DEB3}, {"sienna", 0xA0522D}, {"peru", 0xCD853F}, {"limegreen", 0x32CD32}, {"springgreen", 0x00FF7F},
    {"dodgerblue", 0x1E90FF}, {"deepskyblue", 0x00BFFF}, {"firebrick", 0xB22222}, {"darkorange", 0xFF8C00},
    {NULL, 0}};

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static int parse_color_text(const char *s, uint32_t *out) {
    while (*s == ' ') s++;
    if (*s == '#') {
        s++;
        int n = 0, d[8];
        while (s[n] && n < 9) { if ((d[n] = hexval(s[n])) < 0) break; n++; }
        while (s[n] == ' ') n++;
        if (s[n]) return 0;
        uint32_t r, g, b, a = 255;
        if (n == 3 || n == 4) { r = d[0] * 17; g = d[1] * 17; b = d[2] * 17; if (n == 4) a = d[3] * 17; }
        else if (n == 6 || n == 8) { r = d[0] * 16 + d[1]; g = d[2] * 16 + d[3]; b = d[4] * 16 + d[5]; if (n == 8) a = d[6] * 16 + d[7]; }
        else return 0;
        *out = (a << 24) | (r << 16) | (g << 8) | b;
        return 1;
    }
    char key[40]; int k = 0;
    for (; *s && k < 39; s++) { char c = *s; if (c == ' ' || c == '_' || c == '-') continue; if (c >= 'A' && c <= 'Z') c += 32; key[k++] = c; }
    key[k] = 0;
    if (!strcmp(key, "transparent") || !strcmp(key, "none") || !strcmp(key, "clear")) { *out = 0; return 1; }
    for (const NamedColor *nc = named_colors; nc->n; nc++) if (!strcmp(nc->n, key)) { *out = 0xFF000000u | nc->c; return 1; }
    return 0;
}
static int alpha_of(V v, const char *fn) {
    if (v.t == VT_FLOAT && v.u.f >= 0 && v.u.f <= 1.0) return (int)(v.u.f * 255 + 0.5);
    return (int)clampd(num(v, fn), 0, 255);
}
static uint32_t to_color(V v, const char *fn) {
    if (v.t == VT_STR) {
        uint32_t c;
        if (!parse_color_text(vrt_cs(v), &c)) vrt_fail("%s: I don't know the colour '%s' (try a name like \"red\" or \"#ff8800\")", fn, vrt_cs(v));
        return c;
    }
    if (v.t == VT_INT) return 0xFF000000u | (uint32_t)(v.u.i & 0xFFFFFF);
    if (v.t == VT_NIL) return 0;
    if (v.t == VT_LIST) {
        VList *l = AS_LIST(v);
        if (l->len < 3 || l->len > 4) vrt_fail("%s: a colour list needs [red, green, blue] or [red, green, blue, alpha]", fn);
        uint32_t r = (uint32_t)clampd(num(l->items[0], fn), 0, 255), g = (uint32_t)clampd(num(l->items[1], fn), 0, 255), b = (uint32_t)clampd(num(l->items[2], fn), 0, 255);
        uint32_t a = l->len == 4 ? (uint32_t)alpha_of(l->items[3], fn) : 255;
        return (a << 24) | (r << 16) | (g << 8) | b;
    }
    vrt_fail("%s needs a colour: a name like \"red\", \"#ff8800\", or rgb(255, 136, 0)", fn);
}
static V color_text(uint32_t c) {
    char buf[16];
    if ((c >> 24) == 255) snprintf(buf, sizeof buf, "#%02x%02x%02x", (c >> 16) & 255, (c >> 8) & 255, c & 255);
    else snprintf(buf, sizeof buf, "#%02x%02x%02x%02x", (c >> 16) & 255, (c >> 8) & 255, c & 255, c >> 24);
    return vrt_cstr(buf);
}
/* a trailing colour argument (text, or nothing) on a drawing call: removes it from argc */
static uint32_t cur_color = 0xFFE7E3F5u;
static uint32_t take_color(int *argc, V *a, int min_args, const char *fn) {
    if (*argc > min_args && (a[*argc - 1].t == VT_STR || a[*argc - 1].t == VT_LIST)) { (*argc)--; return to_color(a[*argc], fn); }
    return cur_color;
}

/* ================================================================ images */
typedef struct { int w, h, fw, fh; double dens; uint32_t *px; } Img;
static Img **imgs;
static int nimgs = 1, capimgs = 0;
static Img scr = {0, 0, 0, 0, 1, NULL};        /* the canvas */

static int img_new(int w, int h) {
    if (w < 1 || h < 1 || w > 16384 || h > 16384) vrt_fail("an image must be between 1x1 and 16384x16384 pixels (got %dx%d)", w, h);
    if (nimgs >= capimgs) { capimgs = capimgs ? capimgs * 2 : 64; imgs = realloc(imgs, sizeof(Img *) * capimgs); }
    Img *im = calloc(1, sizeof(Img));
    im->w = w; im->h = h; im->dens = 1;
    im->px = calloc((size_t)w * h, 4);
    if (!im->px) vrt_fail("out of memory for a %dx%d image", w, h);
    imgs[nimgs] = im;
    return nimgs++;
}
static Img *img_arg(V v, const char *fn) {
    if (v.t != VT_INT || v.u.i < 1 || v.u.i >= nimgs || !imgs[v.u.i]) vrt_fail("%s needs an image (from load_image or make_image)", fn);
    return imgs[v.u.i];
}

/* ================================================================ drawing state */
static Img *tgt = &scr;
static double T_s = 1, T_ox = 0, T_oy = 0;         /* target pixel = canvas unit * T_s + T_o */
static int clip_x0, clip_y0, clip_x1, clip_y1;     /* in target pixels, x1/y1 exclusive */
static int scr_clip[4], scr_clip_on = 0;
static double cam_x = 0, cam_y = 0, cam_zoom = 1;
static int cam_on = 0;
static double density = 1;
static double line_w = 1;
static int aa = 1;
static int align = 0;                               /* text: 0 left, 1 centre, 2 right */

static void update_transform(void) {
    if (tgt == &scr) {
        double z = cam_on ? cam_zoom : 1;
        T_s = density * z;
        T_ox = cam_on ? -cam_x * T_s : 0;
        T_oy = cam_on ? -cam_y * T_s : 0;
        if (scr_clip_on) { clip_x0 = scr_clip[0]; clip_y0 = scr_clip[1]; clip_x1 = scr_clip[2]; clip_y1 = scr_clip[3]; }
        else { clip_x0 = 0; clip_y0 = 0; clip_x1 = scr.w; clip_y1 = scr.h; }
    } else {
        T_s = 1; T_ox = 0; T_oy = 0;
        clip_x0 = 0; clip_y0 = 0; clip_x1 = tgt->w; clip_y1 = tgt->h;
    }
    if (clip_x1 > tgt->w) clip_x1 = tgt->w;
    if (clip_y1 > tgt->h) clip_y1 = tgt->h;
}
static inline double TX(double x) { return x * T_s + T_ox; }
static inline double TY(double y) { return y * T_s + T_oy; }

/* ================================================================ pixels */
static inline void put(Img *im, int x, int y, uint32_t c, int cov) {   /* cov 0..255; caller clipped */
    uint32_t a = ((c >> 24) * (uint32_t)cov + 127) / 255;
    if (!a) return;
    uint32_t *p = &im->px[(size_t)y * im->w + x];
    if (a >= 255) { *p = c | 0xFF000000u; return; }
    uint32_t d = *p, da = d >> 24, ia = 255 - a;
    uint32_t sr = (c >> 16) & 255, sg = (c >> 8) & 255, sb = c & 255, dr = (d >> 16) & 255, dg = (d >> 8) & 255, db = d & 255;
    if (da == 255) {
        *p = 0xFF000000u | (((sr * a + dr * ia + 127) / 255) << 16) | (((sg * a + dg * ia + 127) / 255) << 8) | ((sb * a + db * ia + 127) / 255);
        return;
    }
    uint32_t dw = da * ia / 255, oa = a + dw;
    if (!oa) { *p = 0; return; }
    *p = (oa << 24) | (((sr * a + dr * dw) / oa) << 16) | (((sg * a + dg * dw) / oa) << 8) | ((sb * a + db * dw) / oa);
}
static inline int covf(double v) {
    if (!aa) return v >= 0.5 ? 255 : 0;
    return v <= 0 ? 0 : v >= 1 ? 255 : (int)(v * 255 + 0.5);
}
static void fill_px(int x0, int y0, int x1, int y1, uint32_t c) {   /* a solid rectangle of target pixels */
    if (x0 < clip_x0) x0 = clip_x0;
    if (y0 < clip_y0) y0 = clip_y0;
    if (x1 > clip_x1) x1 = clip_x1;
    if (y1 > clip_y1) y1 = clip_y1;
    if (x0 >= x1 || y0 >= y1 || !(c >> 24)) return;
    if ((c >> 24) == 255) {
        for (int y = y0; y < y1; y++) { uint32_t *p = &tgt->px[(size_t)y * tgt->w + x0]; for (int x = x0; x < x1; x++) *p++ = c; }
    } else {
        for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) put(tgt, x, y, c, 255);
    }
}
static void rect_units(double x, double y, double w, double h, uint32_t c) {
    if (w < 0) { x += w; w = -w; }
    if (h < 0) { y += h; h = -h; }
    int x0 = (int)floor(TX(x) + 0.5), y0 = (int)floor(TY(y) + 0.5), x1 = (int)floor(TX(x + w) + 0.5), y1 = (int)floor(TY(y + h) + 0.5);
    if (x1 == x0 && w > 0) x1 = x0 + 1;
    if (y1 == y0 && h > 0) y1 = y0 + 1;
    fill_px(x0, y0, x1, y1, c);
}

/* ---------------------------------------------------------------- shapes in target pixels, antialiased */
static void ellipse_px(double cx, double cy, double rx, double ry, double t, uint32_t c) {   /* t = 0: filled */
    if (rx <= 0 || ry <= 0 || !(c >> 24)) return;
    double ext = (t > 0 ? t / 2 : 0) + 1;
    int y0 = (int)floor(cy - ry - ext), y1 = (int)ceil(cy + ry + ext), x0 = (int)floor(cx - rx - ext), x1 = (int)ceil(cx + rx + ext);
    if (y0 < clip_y0) y0 = clip_y0;
    if (y1 > clip_y1) y1 = clip_y1;
    if (x0 < clip_x0) x0 = clip_x0;
    if (x1 > clip_x1) x1 = clip_x1;
    int circle = fabs(rx - ry) < 1e-9;
    for (int y = y0; y < y1; y++) {
        double dy = y + 0.5 - cy;
        int xs = x0, xe = x1;
        if (circle) {   /* only visit the columns this row can touch */
            double R = rx + ext, h2 = R * R - dy * dy;
            if (h2 < 0) continue;
            double hw = sqrt(h2);
            if ((int)floor(cx - hw) > xs) xs = (int)floor(cx - hw);
            if ((int)ceil(cx + hw) < xe) xe = (int)ceil(cx + hw);
        }
        int ins = 1, ine = 0;      /* filled circles: the run of pixels certainly inside needs no maths */
        if (circle && t <= 0 && (c >> 24) == 255) {
            double ri = rx - 1, h2i = ri * ri - dy * dy;
            if (h2i > 0) { double hw = sqrt(h2i); ins = (int)ceil(cx - hw - 0.5); ine = (int)floor(cx + hw - 0.5); }
            if (ins < xs) ins = xs;
            if (ine > xe - 1) ine = xe - 1;
        }
        for (int x = xs; x < xe; x++) {
            if (x == ins && ins <= ine) { uint32_t *p = &tgt->px[(size_t)y * tgt->w + x]; for (; x <= ine; x++) *p++ = c; x = ine; continue; }
            double dx = x + 0.5 - cx, d;
            if (circle) d = sqrt(dx * dx + dy * dy) - rx;
            else {
                double nx = dx / rx, ny = dy / ry, q = sqrt(nx * nx + ny * ny);
                if (q < 1e-9) d = -(rx < ry ? rx : ry);
                else { double gx = dx / (rx * rx), gy = dy / (ry * ry), g = sqrt(gx * gx + gy * gy) / q; d = (q - 1) / g; }
            }
            double v = t > 0 ? (t / 2 - fabs(d) + 0.5) : (0.5 - d);
            int cov = covf(v);
            if (cov) put(tgt, x, y, c, cov);
        }
    }
}
static void rrect_px(double x0, double y0, double x1, double y1, double r, double t, uint32_t c) {
    if (x1 < x0) { double s = x0; x0 = x1; x1 = s; }
    if (y1 < y0) { double s = y0; y0 = y1; y1 = s; }
    double cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, hw = (x1 - x0) / 2, hh = (y1 - y0) / 2;
    if (r > hw) r = hw;
    if (r > hh) r = hh;
    if (r < 0) r = 0;
    double ext = (t > 0 ? t / 2 : 0) + 1;
    int ya = (int)floor(y0 - ext), yb = (int)ceil(y1 + ext), xa = (int)floor(x0 - ext), xb = (int)ceil(x1 + ext);
    if (ya < clip_y0) ya = clip_y0;
    if (yb > clip_y1) yb = clip_y1;
    if (xa < clip_x0) xa = clip_x0;
    if (xb > clip_x1) xb = clip_x1;
    for (int y = ya; y < yb; y++) {
        double qy = fabs(y + 0.5 - cy) - (hh - r);
        for (int x = xa; x < xb; x++) {
            double qx = fabs(x + 0.5 - cx) - (hw - r);
            double ox = qx > 0 ? qx : 0, oy = qy > 0 ? qy : 0, m = qx > qy ? qx : qy;
            double d = sqrt(ox * ox + oy * oy) + (m < 0 ? m : 0) - r;
            double v = t > 0 ? (t / 2 - fabs(d) + 0.5) : (0.5 - d);
            int cov = covf(v);
            if (cov) put(tgt, x, y, c, cov);
        }
    }
}
static void line_px(double ax, double ay, double bx, double by, double t, uint32_t c) {
    if (!(c >> 24)) return;
    if (t < 0.01) t = 0.01;
    double R = t / 2, ext = R + 1;
    double dx = bx - ax, dy = by - ay, L2 = dx * dx + dy * dy;
    int y0 = (int)floor((ay < by ? ay : by) - ext), y1 = (int)ceil((ay > by ? ay : by) + ext);
    int bx0 = (int)floor((ax < bx ? ax : bx) - ext), bx1 = (int)ceil((ax > bx ? ax : bx) + ext);
    if (y0 < clip_y0) y0 = clip_y0;
    if (y1 > clip_y1) y1 = clip_y1;
    if (bx0 < clip_x0) bx0 = clip_x0;
    if (bx1 > clip_x1) bx1 = clip_x1;
    double L = sqrt(L2), nx = L > 0 ? -dy / L : 0, ny = L > 0 ? dx / L : 0;
    for (int y = y0; y < y1; y++) {
        double yc = y + 0.5;
        int xs = bx0, xe = bx1;
        if (L > 0 && fabs(nx) > 1e-6) {
            double base = (yc - ay) * ny, xa = ax + (-ext - base) / nx, xb = ax + (ext - base) / nx;
            if (xa > xb) { double s = xa; xa = xb; xb = s; }
            if ((int)floor(xa) - 1 > xs) xs = (int)floor(xa) - 1;
            if ((int)ceil(xb) + 1 < xe) xe = (int)ceil(xb) + 1;
        }
        for (int x = xs; x < xe; x++) {
            double px = x + 0.5, k = L2 > 0 ? ((px - ax) * dx + (yc - ay) * dy) / L2 : 0;
            if (k < 0) k = 0; else if (k > 1) k = 1;
            double qx = ax + k * dx - px, qy = ay + k * dy - yc;
            int cov = covf(R - sqrt(qx * qx + qy * qy) + 0.5);
            if (cov) put(tgt, x, y, c, cov);
        }
    }
}
/* lines in canvas units: straight horizontal/vertical ones snap to whole pixels so they stay crisp */
static void line_units(double x1, double y1, double x2, double y2, double t, uint32_t c) {
    double tp = t * T_s;
    if (y1 == y2 || x1 == x2) {
        if (y1 == y2) {
            double lo = x1 < x2 ? x1 : x2, hi = x1 < x2 ? x2 : x1;
            int th = (int)floor(tp + 0.5); if (th < 1) th = 1;
            int ya = (int)floor(TY(y1) - th / 2.0 + 0.5);
            int xa = (int)floor(TX(lo) + 0.5), xb = (int)floor(TX(hi) + 0.5) + (int)floor(T_s + 0.5);
            fill_px(xa, ya, xb, ya + th, c);
        } else {
            double lo = y1 < y2 ? y1 : y2, hi = y1 < y2 ? y2 : y1;
            int th = (int)floor(tp + 0.5); if (th < 1) th = 1;
            int xa = (int)floor(TX(x1) - th / 2.0 + 0.5);
            int ya = (int)floor(TY(lo) + 0.5), yb = (int)floor(TY(hi) + 0.5) + (int)floor(T_s + 0.5);
            fill_px(xa, ya, xa + th, yb, c);
        }
        return;
    }
    line_px(TX(x1), TY(y1), TX(x2), TY(y2), tp, c);
}

static int cmp_double(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static void poly_px(const double *xs, const double *ys, int n, uint32_t c) {   /* filled, even-odd, 4 sub-rows */
    if (n < 3 || !(c >> 24)) return;
    double minx = xs[0], maxx = xs[0], miny = ys[0], maxy = ys[0];
    for (int i = 1; i < n; i++) {
        if (xs[i] < minx) minx = xs[i];
        if (xs[i] > maxx) maxx = xs[i];
        if (ys[i] < miny) miny = ys[i];
        if (ys[i] > maxy) maxy = ys[i];
    }
    int x0 = (int)floor(minx), x1 = (int)ceil(maxx) + 1, y0 = (int)floor(miny), y1 = (int)ceil(maxy) + 1;
    if (x0 < clip_x0) x0 = clip_x0;
    if (x1 > clip_x1) x1 = clip_x1;
    if (y0 < clip_y0) y0 = clip_y0;
    if (y1 > clip_y1) y1 = clip_y1;
    if (x0 >= x1 || y0 >= y1) return;
    int w = x1 - x0, sub = aa ? 4 : 1;
    float *acc = malloc(sizeof(float) * (w + 1));
    double *cross = malloc(sizeof(double) * (n + 1));
    for (int y = y0; y < y1; y++) {
        memset(acc, 0, sizeof(float) * (w + 1));
        int any = 0;
        for (int s = 0; s < sub; s++) {
            double sy = y + (s + 0.5) / sub;
            int nc = 0;
            for (int i = 0, j = n - 1; i < n; j = i++) {
                double yi = ys[i], yj = ys[j];
                if ((yi <= sy && yj > sy) || (yj <= sy && yi > sy)) cross[nc++] = xs[i] + (sy - yi) * (xs[j] - xs[i]) / (yj - yi);
            }
            if (nc < 2) continue;
            qsort(cross, nc, sizeof(double), cmp_double);
            for (int k = 0; k + 1 < nc; k += 2) {
                double a = cross[k] - x0, b = cross[k + 1] - x0;
                if (!aa) { a = ceil(a - 0.5); b = ceil(b - 0.5); }
                if (a < 0) a = 0;
                if (b > w) b = w;
                if (b <= a) continue;
                any = 1;
                float wt = 1.0f / sub;
                int ia = (int)floor(a), ib = (int)floor(b);
                if (ia == ib) acc[ia] += (float)(b - a) * wt;
                else {
                    acc[ia] += (float)(ia + 1 - a) * wt;
                    for (int q = ia + 1; q < ib; q++) acc[q] += wt;
                    if (ib < w) acc[ib] += (float)(b - ib) * wt;
                }
            }
        }
        if (!any) continue;
        for (int x = 0; x < w; x++) {
            if (acc[x] <= 0) continue;
            int cov = aa ? (acc[x] >= 1 ? 255 : (int)(acc[x] * 255 + 0.5)) : (acc[x] >= 0.5f ? 255 : 0);
            if (cov) put(tgt, x0 + x, y, c, cov);
        }
    }
    free(acc);
    free(cross);
}

/* points: [[x, y], ...] or [x1, y1, x2, y2, ...] -> target pixels */
static int read_points(V v, double **xs, double **ys, const char *fn) {
    if (v.t != VT_LIST) vrt_fail("%s needs a list of points like [[10, 10], [50, 10], [30, 40]]", fn);
    VList *l = AS_LIST(v);
    int flat = l->len > 0 && isnum(l->items[0]);
    int n = flat ? (int)(l->len / 2) : (int)l->len;
    *xs = malloc(sizeof(double) * (n + 1));
    *ys = malloc(sizeof(double) * (n + 1));
    for (int i = 0; i < n; i++) {
        double x, y;
        if (flat) { x = num(l->items[i * 2], fn); y = num(l->items[i * 2 + 1], fn); }
        else {
            V p = l->items[i];
            if (p.t != VT_LIST || AS_LIST(p)->len < 2) { free(*xs); free(*ys); vrt_fail("%s: each point needs [x, y]", fn); }
            x = num(AS_LIST(p)->items[0], fn); y = num(AS_LIST(p)->items[1], fn);
        }
        (*xs)[i] = TX(x); (*ys)[i] = TY(y);
    }
    return n;
}

/* ================================================================ window, input, timing */
static SDL_Window *cwin;
static SDL_Renderer *cren;
static SDL_Texture *ctex;
static int tex_w = 0, tex_h = 0;
static int canvas_open = 0, headless = 0, running = 1, stop_req = 0;
static int cw = 480, ch = 360;                  /* canvas size in units */
static int follow = 0, pixel_art = 0, want_hidpi = 1;
static int frame_index = 0, input_frame = -1, max_frames = -1;
static double target_fps = 60, dt_last = 1.0 / 60, measured_fps = 60;
static uint64_t next_ns = 0, start_ns = 0, last_ns = 0;
static SDL_Rect view;                           /* where the canvas lands in the window, in output pixels */
static int touch_on = 0, kbd_shown = 0;

static uint64_t now_ns(void) { return (uint64_t)SDL_GetPerformanceCounter() * 1000000000ull / SDL_GetPerformanceFrequency(); }

static uint8_t kreal[SDL_NUM_SCANCODES], kvirt[SDL_NUM_SCANCODES], kcur[SDL_NUM_SCANCODES], kprev[SDL_NUM_SCANCODES], krep[SDL_NUM_SCANCODES];
static int mbtn = 0, mbtn_prev = 0, mbtn_script = 0, mreal = 0;
static double mx = 0, my = 0, wheel_x = 0, wheel_y = 0;
static char typed[512];
static int ntyped = 0;
static char last_key[32] = "";
#define MAXPADS 4
static SDL_GameController *pads[MAXPADS];
static uint8_t pbtn[MAXPADS][SDL_CONTROLLER_BUTTON_MAX], pbtn_prev[MAXPADS][SDL_CONTROLLER_BUTTON_MAX], pbtn_script[MAXPADS][SDL_CONTROLLER_BUTTON_MAX];
static float paxis[MAXPADS][SDL_CONTROLLER_AXIS_MAX], paxis_script[MAXPADS][SDL_CONTROLLER_AXIS_MAX];
static int paxis_script_on[MAXPADS][SDL_CONTROLLER_AXIS_MAX];
typedef struct { SDL_FingerID id; double x, y; int on; } Touch;
static Touch touches[10];

typedef struct { const char *n; int sc; } KeyName;
static const KeyName key_names[] = {
    {"left", SDL_SCANCODE_LEFT}, {"right", SDL_SCANCODE_RIGHT}, {"up", SDL_SCANCODE_UP}, {"down", SDL_SCANCODE_DOWN},
    {"space", SDL_SCANCODE_SPACE}, {"enter", SDL_SCANCODE_RETURN}, {"return", SDL_SCANCODE_RETURN},
    {"escape", SDL_SCANCODE_ESCAPE}, {"esc", SDL_SCANCODE_ESCAPE}, {"tab", SDL_SCANCODE_TAB},
    {"backspace", SDL_SCANCODE_BACKSPACE}, {"delete", SDL_SCANCODE_DELETE}, {"insert", SDL_SCANCODE_INSERT},
    {"home", SDL_SCANCODE_HOME}, {"end", SDL_SCANCODE_END}, {"pageup", SDL_SCANCODE_PAGEUP}, {"pagedown", SDL_SCANCODE_PAGEDOWN},
    {"lshift", SDL_SCANCODE_LSHIFT}, {"rshift", SDL_SCANCODE_RSHIFT}, {"lctrl", SDL_SCANCODE_LCTRL}, {"rctrl", SDL_SCANCODE_RCTRL},
    {"lalt", SDL_SCANCODE_LALT}, {"ralt", SDL_SCANCODE_RALT}, {"lcmd", SDL_SCANCODE_LGUI}, {"rcmd", SDL_SCANCODE_RGUI},
    {"minus", SDL_SCANCODE_MINUS}, {"-", SDL_SCANCODE_MINUS}, {"equals", SDL_SCANCODE_EQUALS}, {"=", SDL_SCANCODE_EQUALS},
    {"comma", SDL_SCANCODE_COMMA}, {",", SDL_SCANCODE_COMMA}, {"period", SDL_SCANCODE_PERIOD}, {".", SDL_SCANCODE_PERIOD},
    {"slash", SDL_SCANCODE_SLASH}, {"/", SDL_SCANCODE_SLASH}, {"semicolon", SDL_SCANCODE_SEMICOLON}, {";", SDL_SCANCODE_SEMICOLON},
    {"quote", SDL_SCANCODE_APOSTROPHE}, {"'", SDL_SCANCODE_APOSTROPHE}, {"backslash", SDL_SCANCODE_BACKSLASH}, {"\\", SDL_SCANCODE_BACKSLASH},
    {"leftbracket", SDL_SCANCODE_LEFTBRACKET}, {"[", SDL_SCANCODE_LEFTBRACKET}, {"rightbracket", SDL_SCANCODE_RIGHTBRACKET},
    {"]", SDL_SCANCODE_RIGHTBRACKET}, {"backquote", SDL_SCANCODE_GRAVE}, {"`", SDL_SCANCODE_GRAVE},
    {"f1", SDL_SCANCODE_F1}, {"f2", SDL_SCANCODE_F2}, {"f3", SDL_SCANCODE_F3}, {"f4", SDL_SCANCODE_F4}, {"f5", SDL_SCANCODE_F5},
    {"f6", SDL_SCANCODE_F6}, {"f7", SDL_SCANCODE_F7}, {"f8", SDL_SCANCODE_F8}, {"f9", SDL_SCANCODE_F9}, {"f10", SDL_SCANCODE_F10},
    {"f11", SDL_SCANCODE_F11}, {"f12", SDL_SCANCODE_F12},
    {"kp0", SDL_SCANCODE_KP_0}, {"kp1", SDL_SCANCODE_KP_1}, {"kp2", SDL_SCANCODE_KP_2}, {"kp3", SDL_SCANCODE_KP_3}, {"kp4", SDL_SCANCODE_KP_4},
    {"kp5", SDL_SCANCODE_KP_5}, {"kp6", SDL_SCANCODE_KP_6}, {"kp7", SDL_SCANCODE_KP_7}, {"kp8", SDL_SCANCODE_KP_8}, {"kp9", SDL_SCANCODE_KP_9},
    {"kpenter", SDL_SCANCODE_KP_ENTER}, {"kpplus", SDL_SCANCODE_KP_PLUS}, {"kpminus", SDL_SCANCODE_KP_MINUS},
    {"kpmultiply", SDL_SCANCODE_KP_MULTIPLY}, {"kpdivide", SDL_SCANCODE_KP_DIVIDE}, {"kpperiod", SDL_SCANCODE_KP_PERIOD},
    {NULL, 0}};
/* -1 = unknown; -2 shift, -3 ctrl, -4 alt, -5 cmd (either side) */
static int scancode_of(const char *n) {
    if (n[0] && !n[1]) {
        char c = n[0];
        if (c >= 'A' && c <= 'Z') c += 32;
        if (c >= 'a' && c <= 'z') return SDL_SCANCODE_A + (c - 'a');
        if (c >= '1' && c <= '9') return SDL_SCANCODE_1 + (c - '1');
        if (c == '0') return SDL_SCANCODE_0;
        if (c == ' ') return SDL_SCANCODE_SPACE;
    }
    if (lower_eq(n, "shift")) return -2;
    if (lower_eq(n, "ctrl") || lower_eq(n, "control")) return -3;
    if (lower_eq(n, "alt") || lower_eq(n, "option")) return -4;
    if (lower_eq(n, "cmd") || lower_eq(n, "command") || lower_eq(n, "meta") || lower_eq(n, "super")) return -5;
    for (const KeyName *k = key_names; k->n; k++) if (lower_eq(k->n, n)) return k->sc;
    SDL_Scancode s = SDL_GetScancodeFromName(n);
    return s == SDL_SCANCODE_UNKNOWN ? -1 : (int)s;
}
static int key_sc_arg(V v, const char *fn) {
    const char *n = txt(v, fn);
    int sc = scancode_of(n);
    if (sc == -1) vrt_fail("%s: I don't know a key called '%s' (try \"left\", \"space\", \"a\", \"enter\")", fn, n);
    return sc;
}
static int key_in(const uint8_t *st, int sc) {
    switch (sc) {
    case -2: return st[SDL_SCANCODE_LSHIFT] || st[SDL_SCANCODE_RSHIFT];
    case -3: return st[SDL_SCANCODE_LCTRL] || st[SDL_SCANCODE_RCTRL];
    case -4: return st[SDL_SCANCODE_LALT] || st[SDL_SCANCODE_RALT];
    case -5: return st[SDL_SCANCODE_LGUI] || st[SDL_SCANCODE_RGUI];
    default: return st[sc];
    }
}
static int script_sc(const char *n) {   /* a key for scripted input: either-side names press the left one */
    int sc = scancode_of(n);
    if (sc == -2) return SDL_SCANCODE_LSHIFT;
    if (sc == -3) return SDL_SCANCODE_LCTRL;
    if (sc == -4) return SDL_SCANCODE_LALT;
    if (sc == -5) return SDL_SCANCODE_LGUI;
    return sc;
}
static void key_name_of(int sc, char *out, int n) {
    for (const KeyName *k = key_names; k->n; k++) if (k->sc == sc && strlen(k->n) > 1) { snprintf(out, n, "%s", k->n); return; }
    const char *s = SDL_GetScancodeName((SDL_Scancode)sc);
    int i = 0;
    for (; s[i] && i < n - 1; i++) { char c = s[i]; out[i] = (c >= 'A' && c <= 'Z') ? c + 32 : (c == ' ' ? '_' : c); }
    out[i] = 0;
}
static int button_bit(const char *n) {
    if (lower_eq(n, "left")) return SDL_BUTTON_LMASK;
    if (lower_eq(n, "right")) return SDL_BUTTON_RMASK;
    if (lower_eq(n, "middle")) return SDL_BUTTON_MMASK;
    return 0;
}

/* ---------------------------------------------------------------- scripted input (tests, demos) */
enum { EV_DOWN, EV_UP, EV_MOVE, EV_MDOWN, EV_MUP, EV_WHEEL, EV_TYPE, EV_PDOWN, EV_PUP, EV_AXIS, EV_TOUCH, EV_UNTOUCH, EV_QUIT, EV_SHOT };
typedef struct { int frame, kind, a; double x, y; char *s; int done; } SEvent;
static SEvent *sev;
static int nsev = 0, capsev = 0;
static void sev_add(int frame, int kind, int a, double x, double y, const char *s) {
    if (nsev >= capsev) { capsev = capsev ? capsev * 2 : 64; sev = realloc(sev, sizeof(SEvent) * capsev); }
    SEvent *e = &sev[nsev++];
    e->frame = frame; e->kind = kind; e->a = a; e->x = x; e->y = y; e->done = 0;
    e->s = NULL;
    if (s) { size_t l = strlen(s); e->s = malloc(l + 1); memcpy(e->s, s, l + 1); }
}
static int pad_button_of(const char *n);
static int pad_axis_of(const char *n);
static void script_parse(const char *src, int default_frame) {
    char line[1024];
    while (*src) {
        int k = 0;
        while (*src && *src != ';' && *src != '\n' && k < 1023) line[k++] = *src++;
        line[k] = 0;
        if (*src) src++;
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (!*p || *p == '#') continue;
        int frame = default_frame;
        if (*p >= '0' && *p <= '9') { frame = (int)strtol(p, &p, 10); while (*p == ' ' || *p == '\t' || *p == ':') p++; }
        char act[32]; int ai = 0;
        while (*p && *p != ' ' && *p != '\t' && ai < 31) act[ai++] = *p++;
        act[ai] = 0;
        while (*p == ' ' || *p == '\t') p++;
        char *rest = p;
        char a1[256] = "", a2[64] = "", a3[64] = "";
        sscanf(rest, "%255s %63s %63s", a1, a2, a3);
        for (char *q = a1; *q; q++) if (*q == ',') *q = ' ';
        if (lower_eq(act, "down") || lower_eq(act, "keydown")) sev_add(frame, EV_DOWN, script_sc(a1), 0, 0, NULL);
        else if (lower_eq(act, "up") || lower_eq(act, "keyup")) sev_add(frame, EV_UP, script_sc(a1), 0, 0, NULL);
        else if (lower_eq(act, "press") || lower_eq(act, "tap")) { int sc = script_sc(a1); sev_add(frame, EV_DOWN, sc, 0, 0, NULL); sev_add(frame + 1, EV_UP, sc, 0, 0, NULL); }
        else if (lower_eq(act, "type")) sev_add(frame, EV_TYPE, 0, 0, 0, rest);
        else if (lower_eq(act, "move")) sev_add(frame, EV_MOVE, 0, atof(a1), atof(a2), NULL);
        else if (lower_eq(act, "click")) {
            int b = a3[0] ? button_bit(a3) : SDL_BUTTON_LMASK;
            sev_add(frame, EV_MOVE, 0, atof(a1), atof(a2), NULL);
            sev_add(frame, EV_MDOWN, b, 0, 0, NULL);
            sev_add(frame + 1, EV_MUP, b, 0, 0, NULL);
        } else if (lower_eq(act, "mousedown")) {
            if (a1[0] && (a1[0] == '-' || (a1[0] >= '0' && a1[0] <= '9'))) { sev_add(frame, EV_MOVE, 0, atof(a1), atof(a2), NULL); sev_add(frame, EV_MDOWN, SDL_BUTTON_LMASK, 0, 0, NULL); }
            else sev_add(frame, EV_MDOWN, a1[0] ? button_bit(a1) : SDL_BUTTON_LMASK, 0, 0, NULL);
        } else if (lower_eq(act, "mouseup")) sev_add(frame, EV_MUP, a1[0] ? button_bit(a1) : SDL_BUTTON_LMASK, 0, 0, NULL);
        else if (lower_eq(act, "wheel")) sev_add(frame, EV_WHEEL, 0, 0, atof(a1), NULL);
        else if (lower_eq(act, "pad_down")) sev_add(frame, EV_PDOWN, pad_button_of(a1), 0, 0, NULL);
        else if (lower_eq(act, "pad_up")) sev_add(frame, EV_PUP, pad_button_of(a1), 0, 0, NULL);
        else if (lower_eq(act, "pad_press")) { int b = pad_button_of(a1); sev_add(frame, EV_PDOWN, b, 0, 0, NULL); sev_add(frame + 1, EV_PUP, b, 0, 0, NULL); }
        else if (lower_eq(act, "axis")) sev_add(frame, EV_AXIS, pad_axis_of(a1), atof(a2), 0, NULL);
        else if (lower_eq(act, "touch")) sev_add(frame, EV_TOUCH, 0, atof(a1), atof(a2), NULL);
        else if (lower_eq(act, "untouch")) sev_add(frame, EV_UNTOUCH, 0, 0, 0, NULL);
        else if (lower_eq(act, "quit")) sev_add(frame, EV_QUIT, 0, 0, 0, NULL);
        else if (lower_eq(act, "shot") || lower_eq(act, "screenshot")) sev_add(frame, EV_SHOT, 0, 0, 0, a1);
        else vrt_fail("test input: I don't understand '%s' (use down/up/press KEY, type TEXT, move/click X Y, mousedown, mouseup, wheel N, pad_down/pad_up/pad_press BUTTON, axis NAME VALUE, touch X Y, untouch, shot PATH, quit)", act);
    }
}
static void save_png(Img *im, const char *path);
static void apply_script(void) {
    for (int i = 0; i < nsev; i++) {
        SEvent *e = &sev[i];
        if (e->done || e->frame > frame_index) continue;
        e->done = 1;
        switch (e->kind) {
        case EV_DOWN: if (e->a >= 0) { if (!kreal[e->a]) { char nm[32]; key_name_of(e->a, nm, sizeof nm); snprintf(last_key, sizeof last_key, "%s", nm); krep[e->a]++; } kreal[e->a] = 1; } break;
        case EV_UP: if (e->a >= 0) kreal[e->a] = 0; break;
        case EV_MOVE: mx = e->x; my = e->y; break;
        case EV_MDOWN: mbtn_script |= e->a; break;
        case EV_MUP: mbtn_script &= ~e->a; break;
        case EV_WHEEL: wheel_y += e->y; break;
        case EV_TYPE: { size_t l = strlen(e->s); if (ntyped + l < sizeof typed) { memcpy(typed + ntyped, e->s, l); ntyped += (int)l; typed[ntyped] = 0; } break; }
        case EV_PDOWN: if (e->a >= 0) pbtn_script[0][e->a] = 1; break;
        case EV_PUP: if (e->a >= 0) pbtn_script[0][e->a] = 0; break;
        case EV_AXIS: if (e->a >= 0) { paxis_script[0][e->a] = (float)e->x; paxis_script_on[0][e->a] = 1; } break;
        case EV_TOUCH: touches[0].on = 1; touches[0].id = 424242; touches[0].x = e->x; touches[0].y = e->y; mx = e->x; my = e->y; mbtn_script |= SDL_BUTTON_LMASK; break;
        case EV_UNTOUCH: touches[0].on = 0; mbtn_script &= ~SDL_BUTTON_LMASK; break;
        case EV_QUIT: running = 0; break;
        case EV_SHOT: if (e->s && e->s[0]) e->a = 1; break;   /* taken after this frame is drawn */
        }
    }
}

/* ---------------------------------------------------------------- the window */
static void fit_view(void) {
    int ow = scr.w, oh = scr.h;
    if (cren) SDL_GetRendererOutputSize(cren, &ow, &oh);
    double s = (double)ow / scr.w < (double)oh / scr.h ? (double)ow / scr.w : (double)oh / scr.h;
    if (pixel_art && s >= 1) s = floor(s);
    int w = (int)(scr.w * s + 0.5), h = (int)(scr.h * s + 0.5);
    view = (SDL_Rect){(ow - w) / 2, (oh - h) / 2, w, h};
}
static void alloc_screen(int w, int h) {   /* (re)size the canvas, keeping what's drawn in the top-left */
    int pw = (int)ceil(w * density - 1e-9), ph = (int)ceil(h * density - 1e-9);
    if (pw < 1) pw = 1;
    if (ph < 1) ph = 1;
    uint32_t *np = calloc((size_t)pw * ph, 4);
    if (!np) vrt_fail("out of memory for a %dx%d canvas", w, h);
    for (int i = 0; i < pw * ph; i++) np[i] = 0xFF0D0D17u;
    if (scr.px) {
        for (int y = 0; y < ph && y < scr.h; y++) memcpy(np + (size_t)y * pw, scr.px + (size_t)y * scr.w, 4 * (size_t)(pw < scr.w ? pw : scr.w));
        free(scr.px);
    }
    scr.px = np; scr.w = pw; scr.h = ph; scr.dens = density;
    cw = w; ch = h;
    scr_clip_on = 0;
    if (tgt == &scr) update_transform();
}
static void window_density(void) {
    if (!cwin || !cren || !want_hidpi) { density = 1; return; }
    int ww, wh, ow, oh;
    SDL_GetWindowSize(cwin, &ww, &wh);
    SDL_GetRendererOutputSize(cren, &ow, &oh);
    double d = ww > 0 ? (double)ow / ww : 1;
    density = d >= 2.5 ? 3 : d >= 1.5 ? 2 : 1;
}
static void begin_input(void);
static void shot_atexit(void);
static void open_canvas(int w, int h, const char *title, V opts) {
    int scale = 0, fullscreen = 0, resizable = 1;
    if (opts.t == VT_MAP) {
        int f; V v;
        v = map_get_s(opts, "follow", &f); if (f) follow = vrt_truthy(v);
        v = map_get_s(opts, "pixel_art", &f); if (f) pixel_art = vrt_truthy(v);
        v = map_get_s(opts, "hidpi", &f); if (f) want_hidpi = vrt_truthy(v);
        v = map_get_s(opts, "scale", &f); if (f) scale = inum(v, "window");
        v = map_get_s(opts, "fullscreen", &f); if (f) fullscreen = vrt_truthy(v);
        v = map_get_s(opts, "resizable", &f); if (f) resizable = vrt_truthy(v);
    } else if (opts.t != VT_UNDEF && opts.t != VT_NIL) vrt_fail("window: the options must be a map like {\"pixel_art\": yes}");
    if (canvas_open) {   /* a second window() call: new size and title */
        if (cwin) {
            SDL_SetWindowTitle(cwin, title);
            if (!follow) { SDL_SetWindowSize(cwin, w * (scale > 0 ? scale : 1), h * (scale > 0 ? scale : 1)); }
            window_density();
        }
        alloc_screen(w, h);
        return;
    }
    headless = getenv("VANTA_HEADLESS") != NULL;
    const char *mf = getenv("VANTA_FRAMES");
    if (mf && *mf) max_frames = atoi(mf);
    else if (headless) max_frames = 600;
    if (headless) {
        const char *d = getenv("VANTA_DENSITY");
        density = d && *d ? atof(d) : 1;
        if (density < 1) density = 1;
    } else {
        if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER | SDL_INIT_TIMER) != 0) vrt_fail("couldn't start the window: %s", SDL_GetError());
        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, pixel_art ? "0" : "1");
#ifdef VC_TOUCH
        SDL_SetHint(SDL_HINT_ORIENTATIONS, "Portrait LandscapeLeft LandscapeRight");
        cwin = SDL_CreateWindow(title, 0, 0, 0, 0, SDL_WINDOW_FULLSCREEN | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_BORDERLESS);
        if (cwin) vgame_ios_attach_window(cwin);
        touch_on = 1;
        if (follow) { int ww, wh; SDL_GetWindowSize(cwin, &ww, &wh); w = ww; h = wh; }
#else
        if (getenv("VANTA_TOUCH")) touch_on = 1;
        if (scale <= 0) {
            SDL_DisplayMode dm;
            scale = 1;
            if (!follow && SDL_GetDesktopDisplayMode(0, &dm) == 0) {
                int sx = (int)(dm.w * 0.8 / w), sy = (int)(dm.h * 0.8 / h);
                scale = sx < sy ? sx : sy;
                if (scale > 4) scale = 4;
                if (scale < 1) scale = 1;
            }
        }
        Uint32 flags = SDL_WINDOW_ALLOW_HIGHDPI | (resizable ? SDL_WINDOW_RESIZABLE : 0) | (fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
        cwin = SDL_CreateWindow(title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, w * scale, h * scale, flags);
#endif
        if (!cwin) vrt_fail("couldn't open a window: %s", SDL_GetError());
        cren = SDL_CreateRenderer(cwin, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
        if (!cren) cren = SDL_CreateRenderer(cwin, -1, 0);
        if (!cren) vrt_fail("couldn't draw to the window: %s", SDL_GetError());
        if (follow) { window_density(); }
        else {
            /* density: how many framebuffer pixels per canvas unit — enough to fill the window sharply */
            int ow, oh;
            SDL_GetRendererOutputSize(cren, &ow, &oh);
            double s = (double)ow / w < (double)oh / h ? (double)ow / w : (double)oh / h;
            density = want_hidpi && !pixel_art ? (s >= 2.5 ? 3 : s >= 1.5 ? 2 : 1) : 1;
        }
        for (int i = 0; i < SDL_NumJoysticks() && i < MAXPADS; i++) if (SDL_IsGameController(i)) pads[i] = SDL_GameControllerOpen(i);
#ifndef VC_TOUCH
        SDL_StartTextInput();
#endif
    }
    canvas_open = 1;
    alloc_screen(w, h);
    tgt = &scr;
    update_transform();
    const char *script = getenv("VANTA_INPUT");
    if (script && *script) {
        if (script[0] == '@') {
            FILE *f = fopen(script + 1, "rb");
            if (!f) vrt_fail("couldn't read the input script %s", script + 1);
            fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
            char *buf = malloc(n + 1);
            n = (long)fread(buf, 1, n, f); buf[n] = 0; fclose(f);
            script_parse(buf, 0);
            free(buf);
        } else script_parse(script, 0);
    }
    start_ns = last_ns = next_ns = now_ns();
    atexit(shot_atexit);
    begin_input();
}
static void ensure_canvas(void) { if (!canvas_open) open_canvas(480, 360, "Vanta", VUNDEF); }
static void begin_draw(void) { if (tgt == &scr) ensure_canvas(); }

static void pad_added(int which) {
    if (!SDL_IsGameController(which)) return;
    for (int i = 0; i < MAXPADS; i++) if (!pads[i]) { pads[i] = SDL_GameControllerOpen(which); return; }
}
static void to_canvas(double px, double py, double *x, double *y) {   /* output pixels -> canvas units */
    if (view.w <= 0 || view.h <= 0) { *x = px; *y = py; return; }
    *x = (px - view.x) * cw / (double)view.w;
    *y = (py - view.y) * ch / (double)view.h;
}
static void window_to_canvas(double wx, double wy, double *x, double *y) {   /* window points -> canvas units */
    int ww = 1, wh = 1, ow = 1, oh = 1;
    SDL_GetWindowSize(cwin, &ww, &wh);
    SDL_GetRendererOutputSize(cren, &ow, &oh);
    to_canvas(wx * ow / (double)ww, wy * oh / (double)wh, x, y);
}

/* on-screen controls for touch screens: a D-pad (arrow keys) and two buttons (space, enter) */
typedef struct { float x, y, r; } Circle;
static Circle tc_dpad, tc_a, tc_b;
static void touch_layout(int ow, int oh) {
    float u = (float)(ow < oh ? ow : oh);
    tc_dpad = (Circle){u * 0.2f, oh - u * 0.22f, u * 0.15f};
    tc_a = (Circle){ow - u * 0.12f, oh - u * 0.28f, u * 0.075f};
    tc_b = (Circle){ow - u * 0.28f, oh - u * 0.16f, u * 0.075f};
}
static void touch_keys(void) {
    memset(kvirt, 0, sizeof kvirt);
    if (!touch_on || headless || !cren) return;
    int ow, oh;
    SDL_GetRendererOutputSize(cren, &ow, &oh);
    touch_layout(ow, oh);
    for (int i = 0; i < 10; i++) {
        if (!touches[i].on || touches[i].id == 424242) continue;
        /* touches[] holds canvas units: back to output pixels */
        float fx = (float)(view.x + touches[i].x * view.w / cw), fy = (float)(view.y + touches[i].y * view.h / ch);
        float dx = fx - tc_dpad.x, dy = fy - tc_dpad.y, d2 = dx * dx + dy * dy;
        if (d2 < tc_dpad.r * tc_dpad.r * 1.7f && d2 > tc_dpad.r * tc_dpad.r * 0.03f) {
            float ax = dx < 0 ? -dx : dx, ay = dy < 0 ? -dy : dy;
            if (ax > ay * 0.45f) kvirt[dx > 0 ? SDL_SCANCODE_RIGHT : SDL_SCANCODE_LEFT] = 1;
            if (ay > ax * 0.45f) kvirt[dy > 0 ? SDL_SCANCODE_DOWN : SDL_SCANCODE_UP] = 1;
        }
        float ax = fx - tc_a.x, ay = fy - tc_a.y, bx = fx - tc_b.x, by = fy - tc_b.y, rr = tc_a.r * 1.4f;
        if (ax * ax + ay * ay < rr * rr) kvirt[SDL_SCANCODE_SPACE] = 1;
        if (bx * bx + by * by < rr * rr) kvirt[SDL_SCANCODE_RETURN] = 1;
    }
}
static void disc(float cx, float cy, float r, SDL_Color c) {
    SDL_Vertex v[50];
    int idx[48 * 3], n = 48;
    v[0] = (SDL_Vertex){{cx, cy}, c, {0, 0}};
    for (int i = 0; i < n; i++) { float t = (float)i / n * 6.2831853f; v[1 + i] = (SDL_Vertex){{cx + r * SDL_cosf(t), cy + r * SDL_sinf(t)}, c, {0, 0}}; }
    for (int i = 0; i < n; i++) { idx[i * 3] = 0; idx[i * 3 + 1] = 1 + i; idx[i * 3 + 2] = 1 + (i + 1) % n; }
    SDL_RenderGeometry(cren, NULL, v, n + 1, idx, n * 3);
}
static void draw_touch_controls(void) {
    SDL_SetRenderDrawBlendMode(cren, SDL_BLENDMODE_BLEND);
    SDL_Color base = {255, 255, 255, 50}, lit = {255, 255, 255, 130};
    disc(tc_dpad.x, tc_dpad.y, tc_dpad.r, base);
    float arm = tc_dpad.r * 0.36f, R = tc_dpad.r * 0.82f;
    SDL_SetRenderDrawColor(cren, 255, 255, 255, 70);
    SDL_FRect hb = {tc_dpad.x - R, tc_dpad.y - arm / 2, R * 2, arm}, vb = {tc_dpad.x - arm / 2, tc_dpad.y - R, arm, R * 2};
    SDL_RenderFillRectF(cren, &hb);
    SDL_RenderFillRectF(cren, &vb);
    disc(tc_a.x, tc_a.y, tc_a.r, kvirt[SDL_SCANCODE_SPACE] ? lit : base);
    disc(tc_b.x, tc_b.y, tc_b.r, kvirt[SDL_SCANCODE_RETURN] ? lit : base);
}

static void begin_input(void) {
    if (input_frame == frame_index) return;
    input_frame = frame_index;
    memcpy(kprev, kcur, sizeof kcur);
    memset(krep, 0, sizeof krep);
    mbtn_prev = mbtn;
    memcpy(pbtn_prev, pbtn, sizeof pbtn);
    wheel_x = wheel_y = 0;
    ntyped = 0; typed[0] = 0;
    last_key[0] = 0;
    if (!headless && cwin) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            switch (e.type) {
            case SDL_QUIT: running = 0; break;
            case SDL_KEYDOWN: {
                SDL_Scancode sc = e.key.keysym.scancode;
                int alt_enter = sc == SDL_SCANCODE_RETURN && (e.key.keysym.mod & (KMOD_ALT | KMOD_GUI));
                if (sc == SDL_SCANCODE_F11 || alt_enter) {
                    if (!e.key.repeat) { Uint32 f = SDL_GetWindowFlags(cwin) & SDL_WINDOW_FULLSCREEN_DESKTOP; SDL_SetWindowFullscreen(cwin, f ? 0 : SDL_WINDOW_FULLSCREEN_DESKTOP); }
                    break;
                }
                if (sc < SDL_NUM_SCANCODES) {
                    krep[sc]++;
                    if (!e.key.repeat) { kreal[sc] = 1; key_name_of(sc, last_key, sizeof last_key); }
                }
                break;
            }
            case SDL_KEYUP: if (e.key.keysym.scancode < SDL_NUM_SCANCODES) kreal[e.key.keysym.scancode] = 0; break;
            case SDL_TEXTINPUT: { size_t l = strlen(e.text.text); if (ntyped + l < sizeof typed) { memcpy(typed + ntyped, e.text.text, l); ntyped += (int)l; typed[ntyped] = 0; } break; }
            case SDL_MOUSEMOTION: if (e.motion.which != SDL_TOUCH_MOUSEID || !touch_on) window_to_canvas(e.motion.x, e.motion.y, &mx, &my); break;
            case SDL_MOUSEBUTTONDOWN: window_to_canvas(e.button.x, e.button.y, &mx, &my); mreal |= SDL_BUTTON(e.button.button); break;
            case SDL_MOUSEBUTTONUP: mreal &= ~SDL_BUTTON(e.button.button); break;
            case SDL_MOUSEWHEEL: wheel_x += e.wheel.preciseX; wheel_y += e.wheel.preciseY; break;
            case SDL_CONTROLLERDEVICEADDED: pad_added(e.cdevice.which); break;
            case SDL_CONTROLLERDEVICEREMOVED:
                for (int i = 0; i < MAXPADS; i++) if (pads[i] && SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(pads[i])) == e.cdevice.which) { SDL_GameControllerClose(pads[i]); pads[i] = NULL; }
                break;
            case SDL_FINGERDOWN: case SDL_FINGERMOTION: case SDL_FINGERUP: {
                int ow, oh, slot = -1, fr = -1;
                SDL_GetRendererOutputSize(cren, &ow, &oh);
                for (int i = 0; i < 10; i++) {
                    if (touches[i].on && touches[i].id == e.tfinger.fingerId) slot = i;
                    if (!touches[i].on && fr < 0) fr = i;
                }
                if (e.type == SDL_FINGERUP) { if (slot >= 0) touches[slot].on = 0; break; }
                if (slot < 0) slot = fr;
                if (slot < 0) break;
                touches[slot].id = e.tfinger.fingerId; touches[slot].on = 1;
                to_canvas(e.tfinger.x * ow, e.tfinger.y * oh, &touches[slot].x, &touches[slot].y);
                break;
            }
            case SDL_WINDOWEVENT:
                if (e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED && follow) {
                    int ww, wh;
                    SDL_GetWindowSize(cwin, &ww, &wh);
                    window_density();
                    if (ww != cw || wh != ch || (int)(ww * density) != scr.w) alloc_screen(ww, wh);
                }
                break;
            }
        }
        for (int i = 0; i < MAXPADS; i++) {
            if (!pads[i]) continue;
            for (int b = 0; b < SDL_CONTROLLER_BUTTON_MAX; b++) pbtn[i][b] = SDL_GameControllerGetButton(pads[i], (SDL_GameControllerButton)b);
            for (int a = 0; a < SDL_CONTROLLER_AXIS_MAX; a++) paxis[i][a] = SDL_GameControllerGetAxis(pads[i], (SDL_GameControllerAxis)a) / 32767.0f;
        }
    }
    apply_script();
    for (int b = 0; b < SDL_CONTROLLER_BUTTON_MAX; b++) if (pbtn_script[0][b]) pbtn[0][b] = 1; else if (!pads[0]) pbtn[0][b] = 0;
    for (int a = 0; a < SDL_CONTROLLER_AXIS_MAX; a++) if (paxis_script_on[0][a]) paxis[0][a] = paxis_script[0][a];
    touch_keys();
    for (int i = 0; i < SDL_NUM_SCANCODES; i++) kcur[i] = kreal[i] | kvirt[i];
    mbtn = mreal | mbtn_script;
}

static void present(void) {
    if (headless || !cren) return;
    if (!ctex || tex_w != scr.w || tex_h != scr.h) {
        if (ctex) SDL_DestroyTexture(ctex);
        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, pixel_art ? "0" : "1");
        ctex = SDL_CreateTexture(cren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, scr.w, scr.h);
        tex_w = scr.w; tex_h = scr.h;
    }
    SDL_UpdateTexture(ctex, NULL, scr.px, scr.w * 4);
    fit_view();
    SDL_SetRenderDrawColor(cren, 0, 0, 0, 255);
    SDL_RenderClear(cren);
    SDL_RenderCopy(cren, ctex, NULL, &view);
    if (touch_on) { int ow, oh; SDL_GetRendererOutputSize(cren, &ow, &oh); touch_layout(ow, oh); draw_touch_controls(); }
    SDL_RenderPresent(cren);
}

/* ---------------------------------------------------------------- screenshots */
static int shots_taken = 0;
static void save_image_file(Img *im, const char *path) {
    int n = im->w * im->h;
    uint8_t *rgba = malloc((size_t)n * 4);
    for (int i = 0; i < n; i++) { uint32_t p = im->px[i]; rgba[i * 4] = (p >> 16) & 255; rgba[i * 4 + 1] = (p >> 8) & 255; rgba[i * 4 + 2] = p & 255; rgba[i * 4 + 3] = p >> 24; }
    size_t l = strlen(path);
    int ok;
    const char *ext = l >= 4 ? path + l - 4 : "";
    if (lower_eq(ext, ".bmp")) ok = stbi_write_bmp(path, im->w, im->h, 4, rgba);
    else if (lower_eq(ext, ".jpg") || (l >= 5 && lower_eq(path + l - 5, ".jpeg"))) ok = stbi_write_jpg(path, im->w, im->h, 4, rgba, 92);
    else if (lower_eq(ext, ".tga")) ok = stbi_write_tga(path, im->w, im->h, 4, rgba);
    else ok = stbi_write_png(path, im->w, im->h, 4, rgba, im->w * 4);
    free(rgba);
    if (!ok) vrt_fail("couldn't write the image %s", path);
}
static void save_png(Img *im, const char *path) { save_image_file(im, path); }
static void shot_numbered(const char *pat, int n) {
    char path[1024];
    if (strstr(pat, "%d") || strstr(pat, "%0")) snprintf(path, sizeof path, pat, n);
    else {
        const char *dot = strrchr(pat, '.');
        int base = dot ? (int)(dot - pat) : (int)strlen(pat);
        snprintf(path, sizeof path, "%.*s_%04d%s", base, pat, n, dot ? dot : ".png");
    }
    save_png(&scr, path);
}
static void shot_atexit(void) {
    const char *p = getenv("VANTA_SHOT");
    if (p && *p && !shots_taken && scr.px && !getenv("VANTA_SHOT_FRAME")) { save_png(&scr, p); shots_taken++; }
}
static void final_shot(void) {
    const char *p = getenv("VANTA_SHOT");
    if (p && *p && !getenv("VANTA_SHOT_FRAME") && scr.px) { save_png(&scr, p); shots_taken++; }
}

/* ---------------------------------------------------------------- sound: a small mixer (44.1 kHz stereo float) */
#define RATE 44100
typedef struct { float *data; int frames; } Sound;
static Sound **sounds;
static int nsounds = 1, capsounds = 0;
typedef struct { int snd, id, loop, on; double pos, pitch; float vol, pan; } Voice;
#define NVOICES 32
static Voice voices[NVOICES];
static int next_voice_id = 1, music_id = 0;
static float master_vol = 1, music_vol = 1;
static SDL_AudioDeviceID cdev;
static int audio_tried = 0;
static FILE *sdump;
static uint32_t sdump_bytes = 0;

static void mix(float *out, int frames) {
    memset(out, 0, sizeof(float) * frames * 2);
    for (int v = 0; v < NVOICES; v++) {
        Voice *vo = &voices[v];
        if (!vo->on) continue;
        Sound *s = sounds[vo->snd];
        float vol = vo->vol * master_vol * (vo->id == music_id ? music_vol : 1);
        float lg = vol * (vo->pan > 0 ? 1 - vo->pan : 1), rg = vol * (vo->pan < 0 ? 1 + vo->pan : 1);
        for (int i = 0; i < frames; i++) {
            int k = (int)vo->pos;
            if (k >= s->frames) {
                if (vo->loop && s->frames > 0) { vo->pos -= s->frames; k = (int)vo->pos; if (k >= s->frames) k = 0; }
                else { vo->on = 0; break; }
            }
            out[i * 2] += s->data[k * 2] * lg;
            out[i * 2 + 1] += s->data[k * 2 + 1] * rg;
            vo->pos += vo->pitch;
        }
    }
    for (int i = 0; i < frames * 2; i++) { float x = out[i]; out[i] = x > 1 ? 1 : x < -1 ? -1 : x; }
}
static void audio_cb(void *ud, Uint8 *stream, int len) { (void)ud; mix((float *)stream, len / 8); }
static void sdump_header(void) {
    uint8_t h[44]; uint32_t v; uint16_t s;
    memcpy(h, "RIFF", 4); v = 36 + sdump_bytes; memcpy(h + 4, &v, 4); memcpy(h + 8, "WAVEfmt ", 8);
    v = 16; memcpy(h + 16, &v, 4); s = 1; memcpy(h + 20, &s, 2); s = 2; memcpy(h + 22, &s, 2);
    v = RATE; memcpy(h + 24, &v, 4); v = RATE * 4; memcpy(h + 28, &v, 4); s = 4; memcpy(h + 32, &s, 2); s = 16; memcpy(h + 34, &s, 2);
    memcpy(h + 36, "data", 4); memcpy(h + 40, &sdump_bytes, 4);
    fseek(sdump, 0, SEEK_SET); fwrite(h, 1, 44, sdump); fseek(sdump, 0, SEEK_END);
}
static void audio_lock(void) { if (cdev) SDL_LockAudioDevice(cdev); }
static void audio_unlock(void) { if (cdev) SDL_UnlockAudioDevice(cdev); }
static void ensure_audio(void) {
    if (audio_tried) return;
    audio_tried = 1;
    const char *dump = getenv("VANTA_SOUND_DUMP");
    if (dump && *dump) { sdump = fopen(dump, "wb"); if (sdump) sdump_header(); }
    if (getenv("VANTA_HEADLESS") || sdump) return;   /* dumping: the frame loop mixes instead of a device */
    if (SDL_InitSubSystem(SDL_INIT_AUDIO) != 0) return;
    SDL_AudioSpec want, have;
    SDL_zero(want);
    want.freq = RATE; want.format = AUDIO_F32SYS; want.channels = 2; want.samples = 512; want.callback = audio_cb;
    cdev = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
    if (cdev) SDL_PauseAudioDevice(cdev, 0);
}
static void frame_audio(void) {   /* without a device (headless / dumping): mix one frame's worth in step with the game */
    if (!sdump) return;
    int n = (int)(RATE / target_fps + 0.5);
    float *buf = malloc(sizeof(float) * n * 2);
    int16_t *s16 = malloc(sizeof(int16_t) * n * 2);
    mix(buf, n);
    for (int i = 0; i < n * 2; i++) s16[i] = (int16_t)(buf[i] * 32767);
    fwrite(s16, 2, (size_t)n * 2, sdump);
    sdump_bytes += (uint32_t)n * 4;
    sdump_header();
    fflush(sdump);
    free(buf); free(s16);
}

/* ---------------------------------------------------------------- frame end: present, screenshots, pacing */
static void end_frame(void) {
    ensure_canvas();
    present();
    frame_audio();
    frame_index++;
    const char *every = getenv("VANTA_SHOT_EVERY"), *at = getenv("VANTA_SHOT_FRAME"), *shot = getenv("VANTA_SHOT");
    if (shot && *shot && at && *at) {
        const char *p = at;
        while (*p) {   /* VANTA_SHOT_FRAME=30 or 30,60,90 */
            int f = atoi(p);
            if (f == frame_index) { if (strchr(at, ',')) shot_numbered(shot, f); else save_png(&scr, shot); shots_taken++; }
            while (*p && *p != ',') p++;
            if (*p == ',') p++;
        }
    }
    if (every && *every && atoi(every) > 0 && frame_index % atoi(every) == 0) shot_numbered(shot && *shot ? shot : "frame.png", frame_index), shots_taken++;
    for (int i = 0; i < nsev; i++) if (sev[i].kind == EV_SHOT && sev[i].done && sev[i].a == 1) { save_png(&scr, sev[i].s); sev[i].a = 2; shots_taken++; }
    if (max_frames >= 0 && frame_index >= max_frames) running = 0;
    uint64_t t = now_ns();
    if (headless) { dt_last = 1.0 / target_fps; measured_fps = target_fps; }
    else {
        uint64_t frame = (uint64_t)(1e9 / target_fps);
        next_ns += frame;
        if (next_ns > t) {
            uint64_t wait = next_ns - t;
            if (wait > 2000000) SDL_Delay((Uint32)((wait - 1000000) / 1000000));
            while (now_ns() < next_ns) {}
        } else if (t - next_ns > 100000000ull) next_ns = t;
        t = now_ns();
        dt_last = (t - last_ns) / 1e9;
        if (dt_last > 0.1) dt_last = 0.1;
        if (dt_last > 0) measured_fps = measured_fps * 0.9 + (1.0 / dt_last) * 0.1;
    }
    last_ns = t;
}

/* ================================================================ text */
typedef struct { stbtt_fontinfo info; unsigned char *data; } Font;
static Font *fonts[64];
static int nfonts = 1, cur_font = 0;
typedef struct { int font, px, cp, w, h, xoff, yoff; float adv; unsigned char *bmp; } Glyph;
#define GCACHE 4096
static Glyph gcache[GCACHE];
static int gcount = 0;

static Glyph *glyph(int f, int px, int cp) {
    uint32_t hsh = ((uint32_t)f * 2654435761u) ^ ((uint32_t)px * 40503u) ^ ((uint32_t)cp * 2246822519u);
    for (int probe = 0; probe < GCACHE; probe++) {
        Glyph *g = &gcache[(hsh + probe) & (GCACHE - 1)];
        if (!g->font) {
            if (gcount > GCACHE * 3 / 4) {   /* full: start over */
                for (int i = 0; i < GCACHE; i++) { free(gcache[i].bmp); gcache[i].bmp = NULL; gcache[i].font = 0; }
                gcount = 0;
                return glyph(f, px, cp);
            }
            Font *fo = fonts[f];
            float sc = stbtt_ScaleForPixelHeight(&fo->info, (float)px);
            int adv, lsb;
            stbtt_GetCodepointHMetrics(&fo->info, cp, &adv, &lsb);
            g->font = f; g->px = px; g->cp = cp; g->adv = adv * sc;
            g->bmp = stbtt_GetCodepointBitmap(&fo->info, sc, sc, cp, &g->w, &g->h, &g->xoff, &g->yoff);
            gcount++;
            return g;
        }
        if (g->font == f && g->px == px && g->cp == cp) return g;
    }
    return &gcache[0];
}
static int utf8_next(const char **s) {
    const unsigned char *p = (const unsigned char *)*s;
    int c = *p++;
    if (c >= 0xF0 && p[0] && p[1] && p[2]) { c = ((c & 7) << 18) | ((p[0] & 63) << 12) | ((p[1] & 63) << 6) | (p[2] & 63); p += 3; }
    else if (c >= 0xE0 && p[0] && p[1]) { c = ((c & 15) << 12) | ((p[0] & 63) << 6) | (p[1] & 63); p += 2; }
    else if (c >= 0xC0 && p[0]) { c = ((c & 31) << 6) | (p[0] & 63); p += 1; }
    *s = (const char *)p;
    return c;
}
/* pixel font: glyph block size in target pixels for a text size */
static int pix_k(double size) { int k = (int)floor(size / 8 * T_s + 0.25); return k < 1 ? 1 : k; }
static double font_scale(int f, double size) { return stbtt_ScaleForPixelHeight(&fonts[f]->info, (float)(int)floor(size * T_s + 0.5)); }
static double ascent_units(double size) {   /* baseline distance below the top of a line, in canvas units */
    if (!cur_font) return 7.0 * pix_k(size) / T_s;
    int asc, desc, gap;
    stbtt_GetFontVMetrics(&fonts[cur_font]->info, &asc, &desc, &gap);
    return asc * font_scale(cur_font, size) / T_s;
}
static double line_height_units(double size) {
    if (!cur_font) return 8.0 * pix_k(size) / T_s * 1.25;
    int asc, desc, gap;
    stbtt_GetFontVMetrics(&fonts[cur_font]->info, &asc, &desc, &gap);
    return (asc - desc + gap) * font_scale(cur_font, size) / T_s;
}
static double width_units(const char *s, int len, double size) {   /* one line */
    const char *e = s + len;
    if (!cur_font) { int n = 0; while (s < e) { utf8_next(&s); n++; } return n * 8.0 * pix_k(size) / T_s; }
    int px = (int)floor(size * T_s + 0.5);
    if (px < 1) px = 1;
    double w = 0, sc = font_scale(cur_font, size);
    int prev = 0;
    while (s < e) {
        int cp = utf8_next(&s);
        if (prev) w += stbtt_GetCodepointKernAdvance(&fonts[cur_font]->info, prev, cp) * sc;
        w += glyph(cur_font, px, cp)->adv;
        prev = cp;
    }
    return w / T_s;
}
static void draw_line_of_text(const char *s, int len, double x, double base, double size, uint32_t c) {
    const char *e = s + len;
    if (!cur_font) {
        int k = pix_k(size);
        double top = TY(base) - 7.0 * k;
        int py = (int)floor(top + 0.5);
        double pxf = TX(x);
        while (s < e) {
            int cp = utf8_next(&s);
            if (cp < 32 || cp > 126) cp = cp == '\t' ? ' ' : '?';
            int px = (int)floor(pxf + 0.5);
            for (int r = 0; r < 8; r++) {
                unsigned bits = vfont8x8[cp][r];
                for (int b = 0; b < 8; b++) if (bits & (1u << b)) fill_px(px + b * k, py + r * k, px + (b + 1) * k, py + (r + 1) * k, c);
            }
            pxf += 8 * k;
        }
        return;
    }
    int psz = (int)floor(size * T_s + 0.5);
    if (psz < 1) psz = 1;
    double sc = font_scale(cur_font, size), pen = TX(x);
    int by = (int)floor(TY(base) + 0.5), prev = 0;
    while (s < e) {
        int cp = utf8_next(&s);
        if (prev) pen += stbtt_GetCodepointKernAdvance(&fonts[cur_font]->info, prev, cp) * sc;
        Glyph *g = glyph(cur_font, psz, cp);
        int gx = (int)floor(pen + 0.5) + g->xoff, gy = by + g->yoff;
        for (int yy = 0; yy < g->h; yy++) {
            int ty = gy + yy;
            if (ty < clip_y0 || ty >= clip_y1) continue;
            for (int xx = 0; xx < g->w; xx++) {
                int tx = gx + xx;
                if (tx < clip_x0 || tx >= clip_x1) continue;
                int cov = g->bmp[yy * g->w + xx];
                if (cov) put(tgt, tx, ty, c, cov);
            }
        }
        pen += g->adv;
        prev = cp;
    }
}
/* draws text that may have several lines; y is the first line's baseline */
static void draw_text_at(const char *s, double x, double base, double size, uint32_t c) {
    double lh = line_height_units(size);
    while (1) {
        const char *nl = strchr(s, '\n');
        int len = nl ? (int)(nl - s) : (int)strlen(s);
        double lx = x;
        if (align) { double w = width_units(s, len, size); lx -= align == 1 ? w / 2 : w; }
        draw_line_of_text(s, len, lx, base, size, c);
        if (!nl) break;
        s = nl + 1;
        base += lh;
    }
}
static const char *font_paths(const char *name, int i) {
    static const char *sans[] = {"/System/Library/Fonts/Supplemental/Arial.ttf", "/Library/Fonts/Arial.ttf", "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Core/Helvetica.ttc", "/System/Library/Fonts/CoreUI/SFUI.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf", "/usr/share/fonts/dejavu/DejaVuSans.ttf", "C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/arial.ttf", NULL};
    static const char *bold[] = {"/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/Library/Fonts/Arial Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf", "C:/Windows/Fonts/arialbd.ttf", NULL};
    static const char *serif[] = {"/System/Library/Fonts/Supplemental/Georgia.ttf", "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
        "/Library/Fonts/Georgia.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf", "/usr/share/fonts/TTF/DejaVuSerif.ttf",
        "C:/Windows/Fonts/georgia.ttf", "C:/Windows/Fonts/times.ttf", NULL};
    static const char *mono[] = {"/System/Library/Fonts/Supplemental/Courier New.ttf", "/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Courier.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf", "C:/Windows/Fonts/consola.ttf",
        "C:/Windows/Fonts/cour.ttf", NULL};
    const char **list = lower_eq(name, "sans") ? sans : lower_eq(name, "bold") ? bold : lower_eq(name, "serif") ? serif : lower_eq(name, "mono") ? mono : NULL;
    return list ? list[i] : NULL;
}
static int font_load_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *data = malloc(n > 0 ? n : 1);
    if (fread(data, 1, n, f) != (size_t)n) { fclose(f); free(data); return 0; }
    fclose(f);
    if (nfonts >= 64) vrt_fail("load_font: at most 63 fonts");
    Font *fo = calloc(1, sizeof(Font));
    int off = stbtt_GetFontOffsetForIndex(data, 0);
    if (off < 0 || !stbtt_InitFont(&fo->info, data, off)) { free(data); free(fo); return -1; }
    fo->data = data;
    fonts[nfonts] = fo;
    return nfonts++;
}

/* ================================================================ image drawing */
/* bilinear sample of region (rx, ry, rw, rh) at continuous texel position (fu, fv); outside the region is clear */
static uint32_t sample_smooth(const Img *im, int rx, int ry, int rw, int rh, double fu, double fv) {
    int x0 = (int)floor(fu), y0 = (int)floor(fv);
    double ax = fu - x0, ay = fv - y0;
    double acc[4] = {0, 0, 0, 0};   /* premultiplied r, g, b, and alpha */
    for (int k = 0; k < 4; k++) {
        int x = x0 + (k & 1), y = y0 + (k >> 1);
        double wgt = ((k & 1) ? ax : 1 - ax) * ((k >> 1) ? ay : 1 - ay);
        if (wgt <= 0 || x < 0 || y < 0 || x >= rw || y >= rh) continue;
        uint32_t p = im->px[(size_t)(ry + y) * im->w + rx + x];
        double a = (p >> 24) * wgt;
        acc[0] += ((p >> 16) & 255) * a; acc[1] += ((p >> 8) & 255) * a; acc[2] += (p & 255) * a; acc[3] += a;
    }
    if (acc[3] < 0.5) return 0;
    uint32_t r = (uint32_t)(acc[0] / acc[3] + 0.5), g = (uint32_t)(acc[1] / acc[3] + 0.5), b = (uint32_t)(acc[2] / acc[3] + 0.5), a = (uint32_t)(acc[3] + 0.5);
    if (r > 255) r = 255; if (g > 255) g = 255; if (b > 255) b = 255; if (a > 255) a = 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
}
typedef struct { double sx, sy, rot, ox, oy; int flipx, flipy, alpha, center, has_origin, smooth; uint32_t tint; double w, h; int rx, ry, rw, rh; } DrawOpts;
static void opts_default(DrawOpts *o) { memset(o, 0, sizeof *o); o->sx = o->sy = 1; o->alpha = 255; o->tint = 0xFFFFFFFFu; o->w = o->h = -1; o->rw = o->rh = -1; o->smooth = -1; }
static void opts_read(DrawOpts *o, V m, const char *fn) {
    if (m.t == VT_NIL) return;
    if (isnum(m)) { o->sx = o->sy = num(m, fn); return; }   /* draw_image(img, x, y, 2) = scale 2 */
    if (m.t != VT_MAP) vrt_fail("%s: the options must be a map like {\"scale\": 2, \"rotation\": 45}", fn);
    int f; V v;
    v = map_get_s(m, "scale", &f); if (f) o->sx = o->sy = num(v, fn);
    v = map_get_s(m, "scale_x", &f); if (f) o->sx = num(v, fn);
    v = map_get_s(m, "scale_y", &f); if (f) o->sy = num(v, fn);
    v = map_get_s(m, "rotation", &f); if (f) o->rot = num(v, fn);
    v = map_get_s(m, "angle", &f); if (f) o->rot = num(v, fn);
    v = map_get_s(m, "flip_x", &f); if (f) o->flipx = vrt_truthy(v);
    v = map_get_s(m, "flip_y", &f); if (f) o->flipy = vrt_truthy(v);
    v = map_get_s(m, "alpha", &f); if (f) o->alpha = alpha_of(v, fn);
    v = map_get_s(m, "tint", &f); if (f) o->tint = to_color(v, fn);
    v = map_get_s(m, "center", &f); if (f) o->center = vrt_truthy(v);
    v = map_get_s(m, "smooth", &f); if (f) o->smooth = vrt_truthy(v);
    v = map_get_s(m, "width", &f); if (f) o->w = num(v, fn);
    v = map_get_s(m, "height", &f); if (f) o->h = num(v, fn);
    v = map_get_s(m, "origin_x", &f); if (f) { o->ox = num(v, fn); o->has_origin = 1; }
    v = map_get_s(m, "origin_y", &f); if (f) { o->oy = num(v, fn); o->has_origin = 1; }
    v = map_get_s(m, "region", &f);
    if (f) {
        if (v.t != VT_LIST || AS_LIST(v)->len != 4) vrt_fail("%s: region needs [x, y, width, height]", fn);
        VList *l = AS_LIST(v);
        o->rx = inum(l->items[0], fn); o->ry = inum(l->items[1], fn); o->rw = inum(l->items[2], fn); o->rh = inum(l->items[3], fn);
    }
}
/* draws part (rx, ry, rw, rh) of an image with its top-left at (x, y) canvas units; rotation turns it about its
 * centre (or the origin point given in image pixels) */
static void blit(Img *im, int rx, int ry, int rw, int rh, double x, double y, DrawOpts *o) {
    if (rx < 0) { rw += rx; rx = 0; }
    if (ry < 0) { rh += ry; ry = 0; }
    if (rx + rw > im->w) rw = im->w - rx;
    if (ry + rh > im->h) rh = im->h - ry;
    if (rw <= 0 || rh <= 0) return;
    double lw = rw / im->dens, lh = rh / im->dens;            /* size in canvas units at scale 1 */
    double sx = o->sx, sy = o->sy;
    if (o->w >= 0) sx = o->w / lw;
    if (o->h >= 0) sy = o->h / lh;
    if (o->w >= 0 && o->h < 0) sy = sx;
    if (o->h >= 0 && o->w < 0) sx = sy;
    double dw = lw * sx, dh = lh * sy;
    if (dw == 0 || dh == 0) return;
    double px_, py_;                                           /* pivot within the drawn box, canvas units */
    if (o->has_origin) { px_ = o->ox / im->dens * sx; py_ = o->oy / im->dens * sy; }
    else { px_ = dw / 2; py_ = dh / 2; }
    if (o->center) { x -= px_; y -= py_; }
    double cx = x + px_, cy = y + py_;                         /* pivot in canvas units */
    double th = o->rot * PI_D / 180, cs = cos(th), sn = sin(th);
    /* corners -> target pixels for the bounding box */
    double minx = 1e18, miny = 1e18, maxx = -1e18, maxy = -1e18;
    double cxs[4] = {-px_, dw - px_, dw - px_, -px_}, cys[4] = {-py_, -py_, dh - py_, dh - py_};
    for (int i = 0; i < 4; i++) {
        double X = TX(cx + cxs[i] * cs - cys[i] * sn), Y = TY(cy + cxs[i] * sn + cys[i] * cs);
        if (X < minx) minx = X; if (X > maxx) maxx = X; if (Y < miny) miny = Y; if (Y > maxy) maxy = Y;
    }
    int x0 = (int)floor(minx + 0.5), x1 = (int)floor(maxx + 0.5), y0 = (int)floor(miny + 0.5), y1 = (int)floor(maxy + 0.5);
    if (x0 < clip_x0) x0 = clip_x0;
    if (y0 < clip_y0) y0 = clip_y0;
    if (x1 > clip_x1) x1 = clip_x1;
    if (y1 > clip_y1) y1 = clip_y1;
    if (x0 >= x1 || y0 >= y1) return;
    int plain = o->alpha == 255 && o->tint == 0xFFFFFFFFu;
    uint32_t tr = (o->tint >> 16) & 255, tg = (o->tint >> 8) & 255, tb = o->tint & 255, ta = (uint32_t)o->alpha * (o->tint >> 24) / 255;
    if (o->rot == 0) {   /* no rotation: rows and columns map independently */
        int *us = malloc(sizeof(int) * (x1 - x0));
        for (int X = x0; X < x1; X++) {
            double u = ((X + 0.5 - T_ox) / T_s - x) / dw * rw;
            int iu = (int)floor(u);
            if (iu < 0 || iu >= rw) iu = -1;
            else if (o->flipx) iu = rw - 1 - iu;
            us[X - x0] = iu;
        }
        for (int Y = y0; Y < y1; Y++) {
            double v = ((Y + 0.5 - T_oy) / T_s - y) / dh * rh;
            int iv = (int)floor(v);
            if (iv < 0 || iv >= rh) continue;
            if (o->flipy) iv = rh - 1 - iv;
            const uint32_t *row = im->px + (size_t)(ry + iv) * im->w + rx;
            uint32_t *dst = tgt->px + (size_t)Y * tgt->w;
            for (int X = x0; X < x1; X++) {
                int iu = us[X - x0];
                if (iu < 0) continue;
                uint32_t s = row[iu];
                if (plain) { uint32_t sa = s >> 24; if (sa == 255) dst[X] = s; else if (sa) put(tgt, X, Y, s, 255); }
                else {
                    uint32_t a = (s >> 24) * ta / 255;
                    if (!a) continue;
                    uint32_t c = (a << 24) | (((s >> 16) & 255) * tr / 255) << 16 | (((s >> 8) & 255) * tg / 255) << 8 | ((s & 255) * tb / 255);
                    put(tgt, X, Y, c, 255);
                }
            }
        }
        free(us);
        return;
    }
    int smooth = o->smooth >= 0 ? o->smooth : !pixel_art;
    for (int Y = y0; Y < y1; Y++) {
        for (int X = x0; X < x1; X++) {
            double lx = (X + 0.5 - T_ox) / T_s - cx, ly = (Y + 0.5 - T_oy) / T_s - cy;
            double lu = lx * cs + ly * sn + px_, lv = -lx * sn + ly * cs + py_;
            uint32_t s;
            if (smooth) {
                double fu = lu / dw * rw - 0.5, fv = lv / dh * rh - 0.5;
                if (fu < -1 || fv < -1 || fu >= rw || fv >= rh) continue;
                if (o->flipx) fu = rw - 1 - fu;
                if (o->flipy) fv = rh - 1 - fv;
                s = sample_smooth(im, rx, ry, rw, rh, fu, fv);
            } else {
                int iu = (int)floor(lu / dw * rw), iv = (int)floor(lv / dh * rh);
                if (iu < 0 || iu >= rw || iv < 0 || iv >= rh) continue;
                if (o->flipx) iu = rw - 1 - iu;
                if (o->flipy) iv = rh - 1 - iv;
                s = im->px[(size_t)(ry + iv) * im->w + rx + iu];
            }
            uint32_t a = (s >> 24) * ta / 255;
            if (!a) continue;
            uint32_t c = plain ? s : ((a << 24) | (((s >> 16) & 255) * tr / 255) << 16 | (((s >> 8) & 255) * tg / 255) << 8 | ((s & 255) * tb / 255));
            put(tgt, X, Y, c, 255);
        }
    }
}

/* ================================================================ builtins: window and loop */
static V b_window(int argc, V *a) {
    ARGS(0, 4, "window");
    int w = argc >= 1 ? inum(a[0], "window") : 480, h = argc >= 2 ? inum(a[1], "window") : 360;
    if (w < 1 || h < 1 || w > 8192 || h > 8192) vrt_fail("window: %dx%d isn't a usable size", w, h);
    const char *title = argc >= 3 && a[2].t != VT_NIL ? vrt_cs(vrt_display(a[2])) : "Vanta";
    open_canvas(w, h, title, argc >= 4 ? a[3] : VUNDEF);
    return VNIL;
}
static V b_canvas(int argc, V *a) { ARGS(2, 3, "canvas"); return b_window(argc, a); }
static int game_running(void) { return running && !stop_req; }
static V b_next_frame(int argc, V *a) {
    (void)a; ARGS(0, 0, "next_frame");
    ensure_canvas();
    end_frame();
    if (!game_running()) { final_shot(); return VFALSE; }
    begin_input();
    return VTRUE;
}
/* run_game(on_frame)  run_game(update, draw)  — the compiler adds run_game(on_frame, update, draw, takes_dt) at the
 * end of a canvas program that defines those functions (or a still picture), so most programs never call it */
static V b_run_game(int argc, V *a) {
    ARGS(1, 4, "run_game");
    V frame_fn = VNIL, upd = VNIL, drw = VNIL;
    int wants_dt = 1, auto_call = argc == 4;
    if (argc == 1) frame_fn = a[0];
    else if (argc == 2) { upd = a[0]; drw = a[1]; }
    else { frame_fn = a[0]; upd = a[1]; drw = argc >= 3 ? a[2] : VNIL; if (argc == 4) wants_dt = vrt_truthy(a[3]); }
    if (auto_call && !canvas_open) return VNIL;          /* never drew anything: not a canvas program after all */
    ensure_canvas();
    vrt_pin(frame_fn); vrt_pin(upd); vrt_pin(drw);
    while (game_running()) {
        begin_input();
        if (frame_fn.t != VT_NIL) vrt_call(frame_fn, 0, NULL);
        if (upd.t != VT_NIL) { V dt = VF(dt_last); vrt_call(upd, wants_dt ? 1 : 0, &dt); }
        if (drw.t != VT_NIL) vrt_call(drw, 0, NULL);
        end_frame();
    }
    vrt_unpin(3);
    final_shot();
    return VNIL;
}
static V b_stop_game(int argc, V *a) { (void)a; ARGS(0, 0, "stop_game"); stop_req = 1; return VNIL; }
static V b_frame_rate(int argc, V *a) {
    ARGS(1, 1, "frame_rate");
    double f = num(a[0], "frame_rate");
    if (f < 1 || f > 1000) vrt_fail("frame_rate: %g isn't a usable frame rate (1 to 1000)", f);
    target_fps = f;
    return VNIL;
}
static V b_fps(int argc, V *a) { (void)a; ARGS(0, 0, "fps"); return VI((int64_t)floor(measured_fps + 0.5)); }
static V b_frame_count(int argc, V *a) { (void)a; ARGS(0, 0, "frame_count"); return VI(frame_index); }
static V b_delta_time(int argc, V *a) { (void)a; ARGS(0, 0, "delta_time"); return VF(dt_last); }
static V b_game_time(int argc, V *a) {
    (void)a; ARGS(0, 0, "game_time");
    if (!canvas_open) return VF(0);
    if (headless) return VF(frame_index / target_fps);
    return VF((now_ns() - start_ns) / 1e9);
}
static V b_screen_width(int argc, V *a) { (void)a; ARGS(0, 0, "screen_width"); return VI(cw); }
static V b_screen_height(int argc, V *a) { (void)a; ARGS(0, 0, "screen_height"); return VI(ch); }
static V b_window_title(int argc, V *a) { ARGS(1, 1, "window_title"); ensure_canvas(); if (cwin) SDL_SetWindowTitle(cwin, vrt_cs(vrt_display(a[0]))); return VNIL; }
static V b_fullscreen(int argc, V *a) {
    ARGS(0, 1, "fullscreen");
    ensure_canvas();
    if (!cwin) return VFALSE;
    Uint32 f = SDL_GetWindowFlags(cwin) & SDL_WINDOW_FULLSCREEN_DESKTOP;
    int on = argc ? vrt_truthy(a[0]) : !f;
    SDL_SetWindowFullscreen(cwin, on ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
    return VB(on);
}
static V b_screenshot(int argc, V *a) { ARGS(1, 1, "screenshot"); ensure_canvas(); save_png(&scr, txt(a[0], "screenshot")); shots_taken++; return VNIL; }
static V b_touch_controls(int argc, V *a) { ARGS(1, 1, "touch_controls"); touch_on = vrt_truthy(a[0]); return VNIL; }
static V b_show_keyboard(int argc, V *a) {
    ARGS(1, 1, "show_keyboard");
    int on = vrt_truthy(a[0]);
    if (!headless && canvas_open && on != kbd_shown) { if (on) SDL_StartTextInput(); else SDL_StopTextInput(); }
    kbd_shown = on;
    return VNIL;
}
static V b_test_input(int argc, V *a) { ARGS(1, 1, "test_input"); script_parse(txt(a[0], "test_input"), canvas_open ? frame_index + 1 : 0); return VNIL; }

/* ================================================================ builtins: colours and state */
static V b_clear(int argc, V *a) {
    ARGS(0, 1, "clear");
    begin_draw();
    uint32_t c = argc ? to_color(a[0], "clear") : 0xFF0D0D17u;
    if (tgt == &scr || (c >> 24) == 255) {
        int x0 = clip_x0, y0 = clip_y0, x1 = clip_x1, y1 = clip_y1;
        for (int y = y0; y < y1; y++) { uint32_t *p = &tgt->px[(size_t)y * tgt->w + x0]; for (int x = x0; x < x1; x++) *p++ = tgt == &scr ? (c | 0xFF000000u) : c; }
    } else {
        for (int y = clip_y0; y < clip_y1; y++) for (int x = clip_x0; x < clip_x1; x++) tgt->px[(size_t)y * tgt->w + x] = c;
    }
    return VNIL;
}
static V b_color(int argc, V *a) {
    ARGS(1, 4, "color");
    if (argc == 1) cur_color = to_color(a[0], "color");
    else if (argc >= 3) {
        uint32_t r = (uint32_t)clampd(num(a[0], "color"), 0, 255), g = (uint32_t)clampd(num(a[1], "color"), 0, 255), b = (uint32_t)clampd(num(a[2], "color"), 0, 255);
        uint32_t al = argc == 4 ? (uint32_t)alpha_of(a[3], "color") : 255;
        cur_color = (al << 24) | (r << 16) | (g << 8) | b;
    } else vrt_fail("color expects a colour, or red, green, blue (and alpha)");
    return VNIL;
}
static V b_rgb(int argc, V *a) {
    ARGS(3, 4, "rgb");
    uint32_t r = (uint32_t)clampd(num(a[0], "rgb"), 0, 255), g = (uint32_t)clampd(num(a[1], "rgb"), 0, 255), b = (uint32_t)clampd(num(a[2], "rgb"), 0, 255);
    uint32_t al = argc == 4 ? (uint32_t)alpha_of(a[3], "rgb") : 255;
    return color_text((al << 24) | (r << 16) | (g << 8) | b);
}
static V b_rgba(int argc, V *a) { ARGS(4, 4, "rgba"); return b_rgb(argc, a); }
static V b_hsv(int argc, V *a) {
    ARGS(3, 4, "hsv");
    double h = fmod(num(a[0], "hsv"), 360), s = clampd(num(a[1], "hsv"), 0, 1), v = clampd(num(a[2], "hsv"), 0, 1);
    if (h < 0) h += 360;
    double c = v * s, x = c * (1 - fabs(fmod(h / 60, 2) - 1)), m = v - c, r = 0, g = 0, b = 0;
    if (h < 60) { r = c; g = x; } else if (h < 120) { r = x; g = c; } else if (h < 180) { g = c; b = x; }
    else if (h < 240) { g = x; b = c; } else if (h < 300) { r = x; b = c; } else { r = c; b = x; }
    uint32_t al = argc == 4 ? (uint32_t)alpha_of(a[3], "hsv") : 255;
    return color_text((al << 24) | ((uint32_t)((r + m) * 255 + 0.5) << 16) | ((uint32_t)((g + m) * 255 + 0.5) << 8) | (uint32_t)((b + m) * 255 + 0.5));
}
static V b_mix_color(int argc, V *a) {
    ARGS(3, 3, "mix_color");
    uint32_t p = to_color(a[0], "mix_color"), q = to_color(a[1], "mix_color");
    double t = clampd(num(a[2], "mix_color"), 0, 1);
    uint32_t out = 0;
    for (int sh = 0; sh < 32; sh += 8) { double x = ((p >> sh) & 255) * (1 - t) + ((q >> sh) & 255) * t; out |= (uint32_t)(x + 0.5) << sh; }
    return color_text(out);
}
static V b_with_alpha(int argc, V *a) {
    ARGS(2, 2, "with_alpha");
    uint32_t c = to_color(a[0], "with_alpha");
    return color_text((c & 0xFFFFFFu) | ((uint32_t)alpha_of(a[1], "with_alpha") << 24));
}
static V b_line_width(int argc, V *a) { ARGS(1, 1, "line_width"); line_w = num(a[0], "line_width"); if (line_w < 0.1) line_w = 0.1; return VNIL; }
static V b_antialias(int argc, V *a) { ARGS(1, 1, "antialias"); aa = vrt_truthy(a[0]); return VNIL; }
static V b_clip(int argc, V *a) {
    ARGS(4, 4, "clip");
    begin_draw();
    double x = num(a[0], "clip"), y = num(a[1], "clip"), w = num(a[2], "clip"), h = num(a[3], "clip");
    double s = tgt == &scr ? density : 1;
    int x0 = (int)floor(x * s + 0.5), y0 = (int)floor(y * s + 0.5), x1 = (int)floor((x + w) * s + 0.5), y1 = (int)floor((y + h) * s + 0.5);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > tgt->w) x1 = tgt->w;
    if (y1 > tgt->h) y1 = tgt->h;
    if (x1 < x0) x1 = x0;
    if (y1 < y0) y1 = y0;
    if (tgt == &scr) { scr_clip[0] = x0; scr_clip[1] = y0; scr_clip[2] = x1; scr_clip[3] = y1; scr_clip_on = 1; }
    clip_x0 = x0; clip_y0 = y0; clip_x1 = x1; clip_y1 = y1;
    return VNIL;
}
static V b_no_clip(int argc, V *a) { (void)a; ARGS(0, 0, "no_clip"); if (tgt == &scr) scr_clip_on = 0; update_transform(); return VNIL; }
static V b_camera(int argc, V *a) {
    ARGS(2, 3, "camera");
    cam_x = num(a[0], "camera"); cam_y = num(a[1], "camera");
    cam_zoom = argc == 3 ? num(a[2], "camera") : 1;
    if (cam_zoom <= 0) vrt_fail("camera: zoom must be above 0");
    cam_on = 1;
    update_transform();
    return VNIL;
}
static V b_camera_center(int argc, V *a) {
    ARGS(2, 3, "camera_center");
    ensure_canvas();
    double z = argc == 3 ? num(a[2], "camera_center") : 1;
    if (z <= 0) vrt_fail("camera_center: zoom must be above 0");
    cam_zoom = z;
    cam_x = num(a[0], "camera_center") - cw / 2.0 / z;
    cam_y = num(a[1], "camera_center") - ch / 2.0 / z;
    cam_on = 1;
    update_transform();
    return VNIL;
}
static V b_no_camera(int argc, V *a) { (void)a; ARGS(0, 0, "no_camera"); cam_on = 0; update_transform(); return VNIL; }

/* ================================================================ builtins: shapes */
static V b_rect(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 4, "rect");
    ARGS(4, 4, "rect");
    begin_draw();
    rect_units(num(a[0], "rect"), num(a[1], "rect"), num(a[2], "rect"), num(a[3], "rect"), c);
    return VNIL;
}
static V b_outline_rect(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 4, "outline_rect");
    ARGS(4, 4, "outline_rect");
    begin_draw();
    double x = num(a[0], "outline_rect"), y = num(a[1], "outline_rect"), w = num(a[2], "outline_rect"), h = num(a[3], "outline_rect"), t = line_w;
    if (w < 0) { x += w; w = -w; }
    if (h < 0) { y += h; h = -h; }
    if (t * 2 >= w || t * 2 >= h) { rect_units(x, y, w, h, c); return VNIL; }
    rect_units(x, y, w, t, c);
    rect_units(x, y + h - t, w, t, c);
    rect_units(x, y + t, t, h - 2 * t, c);
    rect_units(x + w - t, y + t, t, h - 2 * t, c);
    return VNIL;
}
static V b_round_rect(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 5, "round_rect");
    ARGS(5, 5, "round_rect");
    begin_draw();
    double x = num(a[0], "round_rect"), y = num(a[1], "round_rect"), w = num(a[2], "round_rect"), h = num(a[3], "round_rect"), r = num(a[4], "round_rect");
    rrect_px(TX(x), TY(y), TX(x + w), TY(y + h), r * T_s, 0, c);
    return VNIL;
}
static V b_outline_round_rect(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 5, "outline_round_rect");
    ARGS(5, 5, "outline_round_rect");
    begin_draw();
    double x = num(a[0], "outline_round_rect"), y = num(a[1], "outline_round_rect"), w = num(a[2], "outline_round_rect"), h = num(a[3], "outline_round_rect"), r = num(a[4], "outline_round_rect");
    double t = line_w * T_s, hfw = line_w / 2;   /* the stroke sits inside the box */
    rrect_px(TX(x + hfw), TY(y + hfw), TX(x + w - hfw), TY(y + h - hfw), (r - hfw) * T_s, t, c);
    return VNIL;
}
static V b_circle(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 3, "circle");
    ARGS(3, 3, "circle");
    begin_draw();
    double r = num(a[2], "circle");
    ellipse_px(TX(num(a[0], "circle")), TY(num(a[1], "circle")), r * T_s, r * T_s, 0, c);
    return VNIL;
}
static V b_outline_circle(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 3, "outline_circle");
    ARGS(3, 3, "outline_circle");
    begin_draw();
    double r = num(a[2], "outline_circle");
    ellipse_px(TX(num(a[0], "outline_circle")), TY(num(a[1], "outline_circle")), r * T_s, r * T_s, line_w * T_s, c);
    return VNIL;
}
static V b_ellipse(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 4, "ellipse");
    ARGS(4, 4, "ellipse");
    begin_draw();
    ellipse_px(TX(num(a[0], "ellipse")), TY(num(a[1], "ellipse")), num(a[2], "ellipse") * T_s, num(a[3], "ellipse") * T_s, 0, c);
    return VNIL;
}
static V b_outline_ellipse(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 4, "outline_ellipse");
    ARGS(4, 4, "outline_ellipse");
    begin_draw();
    ellipse_px(TX(num(a[0], "outline_ellipse")), TY(num(a[1], "outline_ellipse")), num(a[2], "outline_ellipse") * T_s, num(a[3], "outline_ellipse") * T_s, line_w * T_s, c);
    return VNIL;
}
static V b_line(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 4, "line");
    ARGS(4, 4, "line");
    begin_draw();
    line_units(num(a[0], "line"), num(a[1], "line"), num(a[2], "line"), num(a[3], "line"), line_w, c);
    return VNIL;
}
static V b_triangle(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 6, "triangle");
    ARGS(6, 6, "triangle");
    begin_draw();
    double xs[3], ys[3];
    for (int i = 0; i < 3; i++) { xs[i] = TX(num(a[i * 2], "triangle")); ys[i] = TY(num(a[i * 2 + 1], "triangle")); }
    poly_px(xs, ys, 3, c);
    return VNIL;
}
static void outline_poly_px(const double *xs, const double *ys, int n, int closed, uint32_t c) {
    double t = line_w * T_s;
    for (int i = 0; i + 1 < n + (closed ? 1 : 0); i++) { int j = (i + 1) % n; line_px(xs[i], ys[i], xs[j], ys[j], t, c); }
}
static V b_outline_triangle(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 6, "outline_triangle");
    ARGS(6, 6, "outline_triangle");
    begin_draw();
    double xs[3], ys[3];
    for (int i = 0; i < 3; i++) { xs[i] = TX(num(a[i * 2], "outline_triangle")); ys[i] = TY(num(a[i * 2 + 1], "outline_triangle")); }
    outline_poly_px(xs, ys, 3, 1, c);
    return VNIL;
}
static V b_polygon(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 1, "polygon");
    ARGS(1, 1, "polygon");
    begin_draw();
    double *xs, *ys;
    int n = read_points(a[0], &xs, &ys, "polygon");
    poly_px(xs, ys, n, c);
    free(xs); free(ys);
    return VNIL;
}
static V b_outline_polygon(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 1, "outline_polygon");
    ARGS(1, 1, "outline_polygon");
    begin_draw();
    double *xs, *ys;
    int n = read_points(a[0], &xs, &ys, "outline_polygon");
    outline_poly_px(xs, ys, n, 1, c);
    free(xs); free(ys);
    return VNIL;
}
static V b_lines(int argc, V *a) {   /* a connected path through the points (not closed) */
    uint32_t c = take_color(&argc, a, 1, "polyline");
    ARGS(1, 1, "polyline");
    begin_draw();
    double *xs, *ys;
    int n = read_points(a[0], &xs, &ys, "polyline");
    outline_poly_px(xs, ys, n, 0, c);
    free(xs); free(ys);
    return VNIL;
}
static int arc_points(double cx, double cy, double r, double a0, double a1, double *xs, double *ys, int max) {
    double span = a1 - a0;
    int n = (int)(fabs(span) / 360 * 96) + 2;
    if (n > max) n = max;
    for (int i = 0; i < n; i++) { double t = (a0 + span * i / (n - 1)) * PI_D / 180; xs[i] = TX(cx + r * cos(t)); ys[i] = TY(cy + r * sin(t)); }
    return n;
}
static V b_arc(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 5, "arc");
    ARGS(5, 5, "arc");
    begin_draw();
    double xs[100], ys[100];
    int n = arc_points(num(a[0], "arc"), num(a[1], "arc"), num(a[2], "arc"), num(a[3], "arc"), num(a[4], "arc"), xs, ys, 98);
    outline_poly_px(xs, ys, n, 0, c);
    return VNIL;
}
static V b_pie(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 5, "pie");
    ARGS(5, 5, "pie");
    begin_draw();
    double xs[100], ys[100], cx = num(a[0], "pie"), cy = num(a[1], "pie");
    int n = arc_points(cx, cy, num(a[2], "pie"), num(a[3], "pie"), num(a[4], "pie"), xs, ys, 98);
    xs[n] = TX(cx); ys[n] = TY(cy);
    poly_px(xs, ys, n + 1, c);
    return VNIL;
}
static V b_pixel(int argc, V *a) {
    uint32_t c = take_color(&argc, a, 2, "pixel");
    ARGS(2, 2, "pixel");
    begin_draw();
    double x = floor(num(a[0], "pixel")), y = floor(num(a[1], "pixel"));
    rect_units(x, y, 1, 1, c);
    return VNIL;
}
static V b_get_pixel(int argc, V *a) {
    ARGS(2, 2, "get_pixel");
    begin_draw();
    int x = (int)floor(TX(floor(num(a[0], "get_pixel")) + 0.5 / T_s)), y = (int)floor(TY(floor(num(a[1], "get_pixel")) + 0.5 / T_s));
    if (x < 0 || y < 0 || x >= tgt->w || y >= tgt->h) return VNIL;
    return color_text(tgt->px[(size_t)y * tgt->w + x]);
}

/* ================================================================ builtins: text */
static double size_arg(int argc, V *a, int i, const char *fn) { return argc > i && a[i].t != VT_NIL ? num(a[i], fn) : 16; }
static V b_text_at(int argc, V *a) {   /* the IDE's text_at: y is the baseline */
    uint32_t c = take_color(&argc, a, 3, "text_at");
    ARGS(3, 4, "text_at");
    begin_draw();
    draw_text_at(vrt_cs(vrt_display(a[2])), num(a[0], "text_at"), num(a[1], "text_at"), size_arg(argc, a, 3, "text_at"), c);
    return VNIL;
}
static V b_draw_text(int argc, V *a) {   /* top-left corner at (x, y) */
    ARGS(3, 5, "draw_text");
    uint32_t c = cur_color;
    if (argc == 5) { c = to_color(a[4], "draw_text"); argc = 4; }
    else if (argc == 4 && (a[3].t == VT_STR || a[3].t == VT_LIST)) { c = to_color(a[3], "draw_text"); argc = 3; }
    begin_draw();
    double size = size_arg(argc, a, 3, "draw_text");
    double y = num(a[2], "draw_text");
    draw_text_at(vrt_cs(vrt_display(a[0])), num(a[1], "draw_text"), y + ascent_units(size), size, c);
    return VNIL;
}
static V b_text_width(int argc, V *a) {
    ARGS(1, 2, "text_width");
    if (tgt == &scr && canvas_open) update_transform();
    const char *s = vrt_cs(vrt_display(a[0]));
    double size = size_arg(argc, a, 1, "text_width"), best = 0;
    while (1) {
        const char *nl = strchr(s, '\n');
        int len = nl ? (int)(nl - s) : (int)strlen(s);
        double w = width_units(s, len, size);
        if (w > best) best = w;
        if (!nl) break;
        s = nl + 1;
    }
    return VF(floor(best * 100 + 0.5) / 100);
}
static V b_text_height(int argc, V *a) {
    ARGS(0, 2, "text_height");
    double size = 16;
    int lines = 1;
    if (argc == 1 && a[0].t == VT_STR) { for (const char *s = vrt_cs(a[0]); *s; s++) if (*s == '\n') lines++; }
    else if (argc == 1) size = num(a[0], "text_height");
    if (argc == 2) { for (const char *s = vrt_cs(vrt_display(a[0])); *s; s++) if (*s == '\n') lines++; size = num(a[1], "text_height"); }
    double lh = line_height_units(size), first = cur_font ? lh : 8.0 * pix_k(size) / T_s;
    return VF(floor((first + (lines - 1) * lh) * 100 + 0.5) / 100);
}
static V b_text_align(int argc, V *a) {
    ARGS(1, 1, "text_align");
    const char *s = txt(a[0], "text_align");
    if (lower_eq(s, "left")) align = 0; else if (lower_eq(s, "center") || lower_eq(s, "centre")) align = 1; else if (lower_eq(s, "right")) align = 2;
    else vrt_fail("text_align needs \"left\", \"center\" or \"right\"");
    return VNIL;
}
static V b_load_font(int argc, V *a) {
    ARGS(1, 1, "load_font");
    const char *p = txt(a[0], "load_font");
    if (font_paths(p, 0)) {
        for (int i = 0; font_paths(p, i); i++) { int id = font_load_file(font_paths(p, i)); if (id > 0) return VI(id); }
        return VNIL;
    }
    int id = font_load_file(p);
    if (id == 0) vrt_fail("load_font: couldn't open %s", p);
    if (id < 0) vrt_fail("load_font: %s isn't a TrueType font", p);
    return VI(id);
}
static V b_font(int argc, V *a) {
    ARGS(1, 1, "font");
    if (a[0].t == VT_NIL || (a[0].t == VT_INT && a[0].u.i == 0)) { cur_font = 0; return VNIL; }
    if (a[0].t == VT_STR) {   /* font("sans") — load it once */
        static int named[8]; static const char *names[] = {"sans", "bold", "serif", "mono"};
        for (int i = 0; i < 4; i++) if (lower_eq(vrt_cs(a[0]), names[i])) {
            if (!named[i]) { V r = b_load_font(1, a); named[i] = r.t == VT_INT ? (int)r.u.i : -1; }
            if (named[i] > 0) cur_font = named[i];
            return VB(named[i] > 0);
        }
        V r = b_load_font(1, a);
        cur_font = (int)r.u.i;
        return VTRUE;
    }
    if (a[0].t != VT_INT || a[0].u.i < 1 || a[0].u.i >= nfonts) vrt_fail("font needs a font from load_font (or nothing for the built-in pixel font)");
    cur_font = (int)a[0].u.i;
    return VTRUE;
}

/* ================================================================ builtins: images */
static V b_load_image(int argc, V *a) {
    ARGS(1, 1, "load_image");
    const char *p = txt(a[0], "load_image");
    int w, h, n;
    unsigned char *d = stbi_load(p, &w, &h, &n, 4);
    if (!d) vrt_fail("load_image: couldn't load %s (%s)", p, stbi_failure_reason());
    int id = img_new(w, h);
    uint32_t *px = imgs[id]->px;
    for (int i = 0; i < w * h; i++) px[i] = ((uint32_t)d[i * 4 + 3] << 24) | ((uint32_t)d[i * 4] << 16) | ((uint32_t)d[i * 4 + 1] << 8) | d[i * 4 + 2];
    stbi_image_free(d);
    return VI(id);
}
static V b_make_image(int argc, V *a) {
    ARGS(2, 3, "make_image");
    int id = img_new(inum(a[0], "make_image"), inum(a[1], "make_image"));
    if (argc == 3) { uint32_t c = to_color(a[2], "make_image"); Img *im = imgs[id]; for (int i = 0; i < im->w * im->h; i++) im->px[i] = c; }
    return VI(id);
}
/* a multi-line text ("""...""") as a list of its non-empty lines, each trimmed */
static V text_rows(V t) {
    const char *p = vrt_cs(t);
    V l = vrt_list(8);
    vrt_pin(l);
    while (*p) {
        const char *e = strchr(p, '\n');
        if (!e) e = p + strlen(p);
        const char *a = p, *b = e;
        while (a < b && (*a == ' ' || *a == '\t' || *a == '\r')) a++;
        while (b > a && (b[-1] == ' ' || b[-1] == '\t' || b[-1] == '\r')) b--;
        if (b > a) vrt_list_push(l, vrt_str(a, b - a));
        p = *e ? e + 1 : e;
    }
    vrt_unpin(1);
    return l;
}
static V b_image_from_rows(int argc, V *a) {
    ARGS(2, 2, "image_from_rows");
    V rv = a[0].t == VT_STR ? text_rows(a[0]) : a[0];
    if (rv.t != VT_LIST || AS_LIST(rv)->len == 0) vrt_fail("image_from_rows needs a list of text rows, like [\"..XX..\", \".X..X.\"], or one multi-line text");
    if (a[1].t != VT_MAP) vrt_fail("image_from_rows needs a palette map, like {\"X\": \"red\", \".\": nothing}");
    vrt_pin(rv);
    VList *rows = AS_LIST(rv);
    int w = 0;
    for (int64_t i = 0; i < rows->len; i++) { V r = rows->items[i]; if (r.t != VT_STR) vrt_fail("image_from_rows: every row must be text"); if (AS_STR(r)->len > w) w = (int)AS_STR(r)->len; }
    int id = img_new(w, (int)rows->len);
    Img *im = imgs[id];
    uint32_t lut[256]; uint8_t known[256] = {0};
    for (int64_t y = 0; y < rows->len; y++) {
        VStr *st = AS_STR(rows->items[y]);
        for (int64_t x = 0; x < st->len; x++) {
            unsigned char chr = (unsigned char)st->data[x];
            if (!known[chr]) {
                char key[2] = {(char)chr, 0};
                int f; V v = vrt_map_get(a[1], vrt_str(key, 1), &f);
                lut[chr] = f ? to_color(v, "image_from_rows") : 0;
                known[chr] = 1;
            }
            im->px[y * w + x] = lut[chr];
        }
    }
    vrt_unpin(1);
    return VI(id);
}
static V b_image_width(int argc, V *a) { ARGS(1, 1, "image_width"); Img *im = img_arg(a[0], "image_width"); return VI((int64_t)floor(im->w / im->dens + 0.5)); }
static V b_image_height(int argc, V *a) { ARGS(1, 1, "image_height"); Img *im = img_arg(a[0], "image_height"); return VI((int64_t)floor(im->h / im->dens + 0.5)); }
static V b_draw_image(int argc, V *a) {
    ARGS(3, 4, "draw_image");
    Img *im = img_arg(a[0], "draw_image");
    if (im == tgt) vrt_fail("draw_image: can't draw an image onto itself");
    begin_draw();
    DrawOpts o; opts_default(&o);
    if (argc == 4) opts_read(&o, a[3], "draw_image");
    int rx = 0, ry = 0, rw = im->w, rh = im->h;
    if (o.rw >= 0) { rx = o.rx; ry = o.ry; rw = o.rw; rh = o.rh; }
    blit(im, rx, ry, rw, rh, num(a[1], "draw_image"), num(a[2], "draw_image"), &o);
    return VNIL;
}
static V b_sprite_sheet(int argc, V *a) {
    ARGS(3, 3, "sprite_sheet");
    Img *im = img_arg(a[0], "sprite_sheet");
    int fw = inum(a[1], "sprite_sheet"), fh = inum(a[2], "sprite_sheet");
    if (fw < 1 || fh < 1 || fw > im->w || fh > im->h) vrt_fail("sprite_sheet: a %dx%d frame doesn't fit a %dx%d image", fw, fh, im->w, im->h);
    im->fw = fw; im->fh = fh;
    return a[0];
}
static V b_frame_count_of(int argc, V *a) {
    ARGS(1, 1, "frames_in");
    Img *im = img_arg(a[0], "frames_in");
    if (!im->fw) return VI(1);
    return VI((int64_t)(im->w / im->fw) * (im->h / im->fh));
}
static void frame_rect(Img *im, int64_t idx, int *rx, int *ry, const char *fn) {
    if (!im->fw) vrt_fail("%s: call sprite_sheet(image, frame_width, frame_height) first", fn);
    int cols = im->w / im->fw, rows = im->h / im->fh;
    int64_t n = (int64_t)cols * rows;
    if (n <= 0) vrt_fail("%s: the sheet has no frames", fn);
    idx %= n;
    if (idx < 0) idx += n;
    *rx = (int)(idx % cols) * im->fw;
    *ry = (int)(idx / cols) * im->fh;
}
static V b_draw_frame(int argc, V *a) {
    ARGS(4, 5, "draw_frame");
    Img *im = img_arg(a[0], "draw_frame");
    begin_draw();
    int rx, ry;
    frame_rect(im, (int64_t)floor(num(a[1], "draw_frame")), &rx, &ry, "draw_frame");
    DrawOpts o; opts_default(&o);
    if (argc == 5) opts_read(&o, a[4], "draw_frame");
    blit(im, rx, ry, im->fw, im->fh, num(a[2], "draw_frame"), num(a[3], "draw_frame"), &o);
    return VNIL;
}
static V b_draw_tilemap(int argc, V *a) {
    ARGS(4, 5, "draw_tilemap");
    Img *im = img_arg(a[0], "draw_tilemap");
    if (!im->fw) vrt_fail("draw_tilemap: call sprite_sheet(image, tile_width, tile_height) first");
    V grid = a[1].t == VT_STR ? text_rows(a[1]) : a[1];
    if (grid.t != VT_LIST) vrt_fail("draw_tilemap needs a grid: a list of rows, each a list of tile numbers (or text rows)");
    vrt_pin(grid);
    begin_draw();
    double x = num(a[2], "draw_tilemap"), y = num(a[3], "draw_tilemap"), sc = argc == 5 ? num(a[4], "draw_tilemap") : 1;
    double tw = im->fw / im->dens * sc, th = im->fh / im->dens * sc;
    DrawOpts o; opts_default(&o); o.sx = o.sy = sc;
    /* visible range of cells, in canvas units */
    double vx0 = (clip_x0 - T_ox) / T_s, vy0 = (clip_y0 - T_oy) / T_s, vx1 = (clip_x1 - T_ox) / T_s, vy1 = (clip_y1 - T_oy) / T_s;
    VList *rows = AS_LIST(grid);
    int r0 = (int)floor((vy0 - y) / th), r1 = (int)ceil((vy1 - y) / th);
    if (r0 < 0) r0 = 0;
    if (r1 > rows->len) r1 = (int)rows->len;
    for (int r = r0; r < r1; r++) {
        V row = rows->items[r];
        if (row.t == VT_STR) {   /* a row may also be text: each character's code is looked up as a digit/letter */
            VStr *s = AS_STR(row);
            for (int64_t c = 0; c < s->len; c++) {
                char chh = s->data[c];
                int t = chh >= '0' && chh <= '9' ? chh - '0' : chh >= 'a' && chh <= 'z' ? chh - 'a' + 10 : chh >= 'A' && chh <= 'Z' ? chh - 'A' + 36 : -1;
                if (t < 0) continue;
                double cx = x + c * tw;
                if (cx + tw < vx0 || cx > vx1) continue;
                int rx, ry; frame_rect(im, t, &rx, &ry, "draw_tilemap");
                blit(im, rx, ry, im->fw, im->fh, cx, y + r * th, &o);
            }
            continue;
        }
        if (row.t != VT_LIST) vrt_fail("draw_tilemap: each row of the grid must be a list of tile numbers");
        VList *cells = AS_LIST(row);
        int c0 = (int)floor((vx0 - x) / tw), c1 = (int)ceil((vx1 - x) / tw);
        if (c0 < 0) c0 = 0;
        if (c1 > cells->len) c1 = (int)cells->len;
        for (int c = c0; c < c1; c++) {
            V cell = cells->items[c];
            if (cell.t == VT_NIL) continue;
            int64_t t = (int64_t)floor(num(cell, "draw_tilemap"));
            if (t < 0) continue;
            int rx, ry; frame_rect(im, t, &rx, &ry, "draw_tilemap");
            blit(im, rx, ry, im->fw, im->fh, x + c * tw, y + r * th, &o);
        }
    }
    vrt_unpin(1);
    return VNIL;
}
static V b_draw_to(int argc, V *a) {
    ARGS(0, 1, "draw_to");
    if (argc == 0 || a[0].t == VT_NIL) { tgt = &scr; if (canvas_open) update_transform(); return VNIL; }
    tgt = img_arg(a[0], "draw_to");
    update_transform();
    return VNIL;
}
static V b_draw_to_screen(int argc, V *a) { (void)a; ARGS(0, 0, "draw_to_screen"); tgt = &scr; if (canvas_open) update_transform(); return VNIL; }
static V b_save_image(int argc, V *a) { ARGS(2, 2, "save_image"); save_image_file(img_arg(a[0], "save_image"), txt(a[1], "save_image")); return VNIL; }
static V b_copy_image(int argc, V *a) {
    ARGS(1, 1, "copy_image");
    Img *im = img_arg(a[0], "copy_image");
    int id = img_new(im->w, im->h);
    memcpy(imgs[id]->px, im->px, (size_t)im->w * im->h * 4);
    imgs[id]->fw = im->fw; imgs[id]->fh = im->fh; imgs[id]->dens = im->dens;
    return VI(id);
}
static V b_copy_screen(int argc, V *a) {
    (void)a; ARGS(0, 0, "copy_screen");
    ensure_canvas();
    int id = img_new(scr.w, scr.h);
    memcpy(imgs[id]->px, scr.px, (size_t)scr.w * scr.h * 4);
    imgs[id]->dens = scr.dens;
    return VI(id);
}
static V b_image_pixel(int argc, V *a) {
    ARGS(3, 3, "image_pixel");
    Img *im = img_arg(a[0], "image_pixel");
    int x = inum(a[1], "image_pixel"), y = inum(a[2], "image_pixel");
    if (x < 0 || y < 0 || x >= im->w || y >= im->h) return VNIL;
    return color_text(im->px[(size_t)y * im->w + x]);
}
static V b_set_image_pixel(int argc, V *a) {
    ARGS(4, 4, "set_image_pixel");
    Img *im = img_arg(a[0], "set_image_pixel");
    int x = inum(a[1], "set_image_pixel"), y = inum(a[2], "set_image_pixel");
    if (x >= 0 && y >= 0 && x < im->w && y < im->h) im->px[(size_t)y * im->w + x] = to_color(a[3], "set_image_pixel");
    return VNIL;
}
static V b_free_image(int argc, V *a) {
    ARGS(1, 1, "free_image");
    Img *im = img_arg(a[0], "free_image");
    if (tgt == im) { tgt = &scr; if (canvas_open) update_transform(); }
    free(im->px); free(im);
    imgs[a[0].u.i] = NULL;
    return VNIL;
}

/* ================================================================ builtins: input */
static V b_key_down(int argc, V *a) { ARGS(1, 1, "key_down"); int sc = key_sc_arg(a[0], "key_down"); begin_draw(); return VB(key_in(kcur, sc)); }
static V b_key_pressed(int argc, V *a) { ARGS(1, 1, "key_pressed"); int sc = key_sc_arg(a[0], "key_pressed"); begin_draw(); return VB(key_in(kcur, sc) && !key_in(kprev, sc)); }
static V b_key_released(int argc, V *a) { ARGS(1, 1, "key_released"); int sc = key_sc_arg(a[0], "key_released"); begin_draw(); return VB(!key_in(kcur, sc) && key_in(kprev, sc)); }
static V b_key_repeat(int argc, V *a) {
    ARGS(1, 1, "key_repeated");
    int sc = key_sc_arg(a[0], "key_repeated");
    begin_draw();
    if (sc < 0) return VB(key_in(kcur, sc) && !key_in(kprev, sc));
    return VB(krep[sc] > 0 || (kcur[sc] && !kprev[sc]));
}
static V b_last_key(int argc, V *a) { (void)a; ARGS(0, 0, "last_key"); begin_draw(); return vrt_cstr(last_key); }
static V b_text_input(int argc, V *a) { (void)a; ARGS(0, 0, "text_input"); begin_draw(); return vrt_str(typed, ntyped); }
static int mbutton_arg(int argc, V *a, const char *fn) {
    if (!argc) return SDL_BUTTON_LMASK;
    int b = button_bit(txt(a[0], fn));
    if (!b) vrt_fail("%s needs \"left\", \"right\" or \"middle\"", fn);
    return b;
}
static V b_mouse_x(int argc, V *a) { (void)a; ARGS(0, 0, "mouse_x"); begin_draw(); return VI((int64_t)floor(mx)); }
static V b_mouse_y(int argc, V *a) { (void)a; ARGS(0, 0, "mouse_y"); begin_draw(); return VI((int64_t)floor(my)); }
static V b_mouse_down(int argc, V *a) { ARGS(0, 1, "mouse_down"); int b = mbutton_arg(argc, a, "mouse_down"); begin_draw(); return VB(mbtn & b); }
static V b_mouse_pressed(int argc, V *a) { ARGS(0, 1, "mouse_pressed"); int b = mbutton_arg(argc, a, "mouse_pressed"); begin_draw(); return VB((mbtn & b) && !(mbtn_prev & b)); }
static V b_mouse_released(int argc, V *a) { ARGS(0, 1, "mouse_released"); int b = mbutton_arg(argc, a, "mouse_released"); begin_draw(); return VB(!(mbtn & b) && (mbtn_prev & b)); }
static V b_mouse_wheel(int argc, V *a) { (void)a; ARGS(0, 0, "mouse_wheel"); begin_draw(); return VF(wheel_y); }
static V b_mouse_world_x(int argc, V *a) { (void)a; ARGS(0, 0, "mouse_world_x"); begin_draw(); return VF(cam_on ? mx / cam_zoom + cam_x : mx); }
static V b_mouse_world_y(int argc, V *a) { (void)a; ARGS(0, 0, "mouse_world_y"); begin_draw(); return VF(cam_on ? my / cam_zoom + cam_y : my); }
static V b_hide_mouse(int argc, V *a) { ARGS(1, 1, "show_mouse"); if (!headless && canvas_open) SDL_ShowCursor(vrt_truthy(a[0]) ? SDL_ENABLE : SDL_DISABLE); return VNIL; }

typedef struct { const char *n; int b; } PadName;
static const PadName pad_names[] = {
    {"a", SDL_CONTROLLER_BUTTON_A}, {"b", SDL_CONTROLLER_BUTTON_B}, {"x", SDL_CONTROLLER_BUTTON_X}, {"y", SDL_CONTROLLER_BUTTON_Y},
    {"back", SDL_CONTROLLER_BUTTON_BACK}, {"select", SDL_CONTROLLER_BUTTON_BACK}, {"guide", SDL_CONTROLLER_BUTTON_GUIDE},
    {"home", SDL_CONTROLLER_BUTTON_GUIDE}, {"start", SDL_CONTROLLER_BUTTON_START}, {"l3", SDL_CONTROLLER_BUTTON_LEFTSTICK},
    {"r3", SDL_CONTROLLER_BUTTON_RIGHTSTICK}, {"leftstick", SDL_CONTROLLER_BUTTON_LEFTSTICK}, {"rightstick", SDL_CONTROLLER_BUTTON_RIGHTSTICK},
    {"lb", SDL_CONTROLLER_BUTTON_LEFTSHOULDER}, {"l1", SDL_CONTROLLER_BUTTON_LEFTSHOULDER}, {"l", SDL_CONTROLLER_BUTTON_LEFTSHOULDER},
    {"rb", SDL_CONTROLLER_BUTTON_RIGHTSHOULDER}, {"r1", SDL_CONTROLLER_BUTTON_RIGHTSHOULDER}, {"r", SDL_CONTROLLER_BUTTON_RIGHTSHOULDER},
    {"leftshoulder", SDL_CONTROLLER_BUTTON_LEFTSHOULDER}, {"rightshoulder", SDL_CONTROLLER_BUTTON_RIGHTSHOULDER},
    {"up", SDL_CONTROLLER_BUTTON_DPAD_UP}, {"down", SDL_CONTROLLER_BUTTON_DPAD_DOWN}, {"left", SDL_CONTROLLER_BUTTON_DPAD_LEFT},
    {"right", SDL_CONTROLLER_BUTTON_DPAD_RIGHT}, {NULL, 0}};
static int pad_button_of(const char *n) {
    for (const PadName *p = pad_names; p->n; p++) if (lower_eq(p->n, n)) return p->b;
    SDL_GameControllerButton b = SDL_GameControllerGetButtonFromString(n);
    return b == SDL_CONTROLLER_BUTTON_INVALID ? -1 : (int)b;
}
static int pad_axis_of(const char *n) {
    if (lower_eq(n, "left_x") || lower_eq(n, "leftx") || lower_eq(n, "x")) return SDL_CONTROLLER_AXIS_LEFTX;
    if (lower_eq(n, "left_y") || lower_eq(n, "lefty") || lower_eq(n, "y")) return SDL_CONTROLLER_AXIS_LEFTY;
    if (lower_eq(n, "right_x") || lower_eq(n, "rightx")) return SDL_CONTROLLER_AXIS_RIGHTX;
    if (lower_eq(n, "right_y") || lower_eq(n, "righty")) return SDL_CONTROLLER_AXIS_RIGHTY;
    if (lower_eq(n, "lt") || lower_eq(n, "left_trigger") || lower_eq(n, "l2")) return SDL_CONTROLLER_AXIS_TRIGGERLEFT;
    if (lower_eq(n, "rt") || lower_eq(n, "right_trigger") || lower_eq(n, "r2")) return SDL_CONTROLLER_AXIS_TRIGGERRIGHT;
    return -1;
}
static void pad_args(int argc, V *a, const char *fn, int *btn, int *who) {
    const char *n = txt(a[0], fn);
    *btn = pad_button_of(n);
    if (*btn < 0) vrt_fail("%s: I don't know a controller button called '%s' (try \"a\", \"b\", \"start\", \"left\")", fn, n);
    *who = argc == 2 ? inum(a[1], fn) - 1 : 0;
    if (*who < 0 || *who >= MAXPADS) vrt_fail("%s: player must be 1 to %d", fn, MAXPADS);
}
static V b_pad_count(int argc, V *a) { (void)a; ARGS(0, 0, "pad_count"); begin_draw(); int n = 0; for (int i = 0; i < MAXPADS; i++) if (pads[i]) n++; return VI(n); }
static V b_pad_down(int argc, V *a) { ARGS(1, 2, "pad_down"); int b, w; pad_args(argc, a, "pad_down", &b, &w); begin_draw(); return VB(pbtn[w][b]); }
static V b_pad_pressed(int argc, V *a) { ARGS(1, 2, "pad_pressed"); int b, w; pad_args(argc, a, "pad_pressed", &b, &w); begin_draw(); return VB(pbtn[w][b] && !pbtn_prev[w][b]); }
static V b_pad_released(int argc, V *a) { ARGS(1, 2, "pad_released"); int b, w; pad_args(argc, a, "pad_released", &b, &w); begin_draw(); return VB(!pbtn[w][b] && pbtn_prev[w][b]); }
static V b_pad_axis(int argc, V *a) {
    ARGS(1, 2, "pad_axis");
    const char *n = txt(a[0], "pad_axis");
    int ax = pad_axis_of(n);
    if (ax < 0) vrt_fail("pad_axis: I don't know an axis called '%s' (try \"left_x\", \"left_y\", \"right_x\", \"lt\")", n);
    int w = argc == 2 ? inum(a[1], "pad_axis") - 1 : 0;
    if (w < 0 || w >= MAXPADS) vrt_fail("pad_axis: player must be 1 to %d", MAXPADS);
    begin_draw();
    double v = paxis[w][ax], dz = 0.15;
    if (fabs(v) < dz) return VF(0);
    v = (fabs(v) - dz) / (1 - dz) * (v < 0 ? -1 : 1);
    return VF(clampd(v, -1, 1));
}
static V b_touch_count(int argc, V *a) { (void)a; ARGS(0, 0, "touch_count"); begin_draw(); int n = 0; for (int i = 0; i < 10; i++) if (touches[i].on) n++; return VI(n); }
static Touch *nth_touch(int k) { for (int i = 0; i < 10; i++) if (touches[i].on && k-- == 0) return &touches[i]; return NULL; }
static V b_touch_x(int argc, V *a) { ARGS(0, 1, "touch_x"); begin_draw(); Touch *t = nth_touch(argc ? inum(a[0], "touch_x") - 1 : 0); return t ? VI((int64_t)floor(t->x)) : VNIL; }
static V b_touch_y(int argc, V *a) { ARGS(0, 1, "touch_y"); begin_draw(); Touch *t = nth_touch(argc ? inum(a[0], "touch_y") - 1 : 0); return t ? VI((int64_t)floor(t->y)) : VNIL; }
static V b_touches(int argc, V *a) {
    (void)a; ARGS(0, 0, "touches");
    begin_draw();
    V l = vrt_list(4);
    vrt_pin(l);
    for (int i = 0; i < 10; i++) if (touches[i].on) { V p[2] = {VI((int64_t)floor(touches[i].x)), VI((int64_t)floor(touches[i].y))}; vrt_list_push(l, vrt_list_of(2, p)); }
    vrt_unpin(1);
    return l;
}

/* ================================================================ builtins: sound */
static int sound_new(float *data, int frames) {
    if (nsounds >= capsounds) { capsounds = capsounds ? capsounds * 2 : 32; sounds = realloc(sounds, sizeof(Sound *) * capsounds); }
    Sound *s = calloc(1, sizeof(Sound));
    s->data = data; s->frames = frames;
    sounds[nsounds] = s;
    return nsounds++;
}
static Sound *sound_arg(V v, const char *fn) {
    if (v.t != VT_INT || v.u.i < 1 || v.u.i >= nsounds || !sounds[v.u.i]) vrt_fail("%s needs a sound (from load_sound or make_tone)", fn);
    return sounds[v.u.i];
}
/* any SDL audio format -> our float stereo 44.1 kHz */
static int convert_sound(SDL_AudioFormat fmt, int chans, int rate, const uint8_t *buf, uint32_t len, const char *what) {
    SDL_AudioCVT cvt;
    if (SDL_BuildAudioCVT(&cvt, fmt, (Uint8)chans, rate, AUDIO_F32SYS, 2, RATE) < 0) vrt_fail("load_sound: can't convert %s (%s)", what, SDL_GetError());
    cvt.len = (int)len;
    cvt.buf = malloc((size_t)len * (cvt.len_mult > 0 ? cvt.len_mult : 1) + 64);
    memcpy(cvt.buf, buf, len);
    if (cvt.needed && SDL_ConvertAudio(&cvt) < 0) { free(cvt.buf); vrt_fail("load_sound: can't convert %s (%s)", what, SDL_GetError()); }
    int out_len = cvt.needed ? cvt.len_cvt : (int)len;
    return sound_new((float *)cvt.buf, out_len / 8);
}
static V b_load_sound(int argc, V *a) {
    ARGS(1, 1, "load_sound");
    const char *p = txt(a[0], "load_sound");
    size_t l = strlen(p);
    if (l >= 4 && lower_eq(p + l - 4, ".ogg")) {
        int ch, rate; short *out;
        int n = stb_vorbis_decode_filename(p, &ch, &rate, &out);
        if (n < 0) vrt_fail("load_sound: couldn't load %s", p);
        int id = convert_sound(AUDIO_S16SYS, ch, rate, (const uint8_t *)out, (uint32_t)n * ch * 2, p);
        free(out);
        return VI(id);
    }
    SDL_AudioSpec spec;
    Uint8 *buf; Uint32 len;
    if (!SDL_LoadWAV(p, &spec, &buf, &len)) vrt_fail("load_sound: couldn't load %s (%s)", p, SDL_GetError());
    int id = convert_sound(spec.format, spec.channels, spec.freq, buf, len, p);
    SDL_FreeWAV(buf);
    return VI(id);
}
static int wave_of(const char *w) {
    if (lower_eq(w, "sine")) return 0;
    if (lower_eq(w, "square")) return 1;
    if (lower_eq(w, "triangle")) return 2;
    if (lower_eq(w, "saw") || lower_eq(w, "sawtooth")) return 3;
    if (lower_eq(w, "noise")) return 4;
    vrt_fail("unknown wave '%s' (use \"sine\", \"square\", \"triangle\", \"saw\" or \"noise\")", w);
}
static int tone_sound(double freq, double secs, int wave, double vol) {
    if (secs <= 0 || secs > 60) vrt_fail("a tone must last between 0 and 60 seconds");
    int n = (int)(secs * RATE);
    if (n < 1) n = 1;
    float *d = malloc(sizeof(float) * n * 2);
    uint32_t seed = 22222;
    double ph = 0, fade = RATE * 0.005;
    for (int i = 0; i < n; i++) {
        double s;
        switch (wave) {
        case 1: s = ph < 0.5 ? 1 : -1; break;
        case 2: s = ph < 0.5 ? ph * 4 - 1 : 3 - ph * 4; break;
        case 3: s = ph * 2 - 1; break;
        case 4: seed = seed * 1664525u + 1013904223u; s = ((seed >> 9) / (double)(1 << 23)) * 2 - 1; break;
        default: s = sin(ph * 2 * PI_D);
        }
        ph += freq / RATE;
        ph -= floor(ph);
        double env = 1;
        if (i < fade) env = i / fade;
        if (n - i < fade) env = (n - i) / fade;
        float v = (float)(s * vol * env * (wave == 1 || wave == 3 ? 0.6 : 1));
        d[i * 2] = d[i * 2 + 1] = v;
    }
    return sound_new(d, n);
}
static V b_make_tone(int argc, V *a) {
    ARGS(2, 4, "make_tone");
    int wave = argc >= 3 ? wave_of(txt(a[2], "make_tone")) : 0;
    double vol = argc >= 4 ? clampd(num(a[3], "make_tone"), 0, 1) : 0.5;
    return VI(tone_sound(num(a[0], "make_tone"), num(a[1], "make_tone"), wave, vol));
}
static V b_make_sound(int argc, V *a) {
    ARGS(1, 2, "make_sound");
    if (a[0].t != VT_LIST) vrt_fail("make_sound needs a list of samples between -1 and 1");
    VList *l = AS_LIST(a[0]);
    double rate = argc == 2 ? num(a[1], "make_sound") : RATE;
    if (rate < 1000 || rate > 192000) vrt_fail("make_sound: %g isn't a usable sample rate", rate);
    int n = (int)(l->len * RATE / rate);
    if (n < 1) n = 1;
    float *d = malloc(sizeof(float) * n * 2);
    for (int i = 0; i < n; i++) {
        double pos = i * rate / RATE;
        int k = (int)pos;
        double f = pos - k, s0 = k < l->len ? num(l->items[k], "make_sound") : 0, s1 = k + 1 < l->len ? num(l->items[k + 1], "make_sound") : s0;
        float v = (float)clampd(s0 + (s1 - s0) * f, -1, 1);
        d[i * 2] = d[i * 2 + 1] = v;
    }
    return VI(sound_new(d, n));
}
static int voice_start(int snd, double vol, double pan, double pitch, int loop) {
    ensure_audio();
    audio_lock();
    int slot = -1;
    for (int i = 0; i < NVOICES; i++) if (!voices[i].on) { slot = i; break; }
    if (slot < 0) {   /* all busy: replace the one nearest its end (never the music) */
        double best = -1;
        for (int i = 0; i < NVOICES; i++) {
            if (voices[i].id == music_id) continue;
            double done = voices[i].pos / (sounds[voices[i].snd]->frames + 1);
            if (done > best) { best = done; slot = i; }
        }
    }
    int id = 0;
    if (slot >= 0) {
        id = next_voice_id++;
        voices[slot] = (Voice){snd, id, loop, 1, 0, pitch > 0 ? pitch : 1, (float)vol, (float)clampd(pan, -1, 1)};
    }
    audio_unlock();
    return id;
}
static V b_play_sound(int argc, V *a) {
    ARGS(1, 5, "play_sound");
    sound_arg(a[0], "play_sound");
    double vol = argc >= 2 ? clampd(num(a[1], "play_sound"), 0, 4) : 1, pan = argc >= 3 ? num(a[2], "play_sound") : 0, pitch = argc >= 4 ? num(a[3], "play_sound") : 1;
    int loop = argc >= 5 ? vrt_truthy(a[4]) : 0;
    return VI(voice_start((int)a[0].u.i, vol, pan, pitch, loop));
}
static V b_stop_sound(int argc, V *a) {
    ARGS(1, 1, "stop_sound");
    int64_t id = (int64_t)num(a[0], "stop_sound");
    audio_lock();
    for (int i = 0; i < NVOICES; i++) if (voices[i].on && voices[i].id == id) voices[i].on = 0;
    audio_unlock();
    return VNIL;
}
static V b_stop_all_sounds(int argc, V *a) { (void)a; ARGS(0, 0, "stop_all_sounds"); audio_lock(); for (int i = 0; i < NVOICES; i++) voices[i].on = 0; music_id = 0; audio_unlock(); return VNIL; }
static V b_sound_playing(int argc, V *a) {
    ARGS(1, 1, "sound_playing");
    int64_t id = (int64_t)num(a[0], "sound_playing");
    int on = 0;
    audio_lock();
    for (int i = 0; i < NVOICES; i++) if (voices[i].on && voices[i].id == id) on = 1;
    audio_unlock();
    return VB(on);
}
static V b_play_music(int argc, V *a) {
    ARGS(1, 2, "play_music");
    int snd;
    if (a[0].t == VT_STR) { V r = b_load_sound(1, a); snd = (int)r.u.i; }
    else { sound_arg(a[0], "play_music"); snd = (int)a[0].u.i; }
    if (argc == 2) music_vol = (float)clampd(num(a[1], "play_music"), 0, 4);
    audio_lock();
    for (int i = 0; i < NVOICES; i++) if (voices[i].on && voices[i].id == music_id) voices[i].on = 0;
    audio_unlock();
    music_id = voice_start(snd, 1, 0, 1, 1);
    return VNIL;
}
static V b_stop_music(int argc, V *a) {
    (void)a; ARGS(0, 0, "stop_music");
    audio_lock();
    for (int i = 0; i < NVOICES; i++) if (voices[i].on && voices[i].id == music_id) voices[i].on = 0;
    music_id = 0;
    audio_unlock();
    return VNIL;
}
static V b_music_volume(int argc, V *a) { ARGS(1, 1, "music_volume"); audio_lock(); music_vol = (float)clampd(num(a[0], "music_volume"), 0, 4); audio_unlock(); return VNIL; }
static V b_master_volume(int argc, V *a) { ARGS(1, 1, "master_volume"); audio_lock(); master_vol = (float)clampd(num(a[0], "master_volume"), 0, 4); audio_unlock(); return VNIL; }
static V b_sound_length(int argc, V *a) { ARGS(1, 1, "sound_length"); return VF(sound_arg(a[0], "sound_length")->frames / (double)RATE); }
/* beep(frequency, seconds, [wave], [volume]): the same tone reuses one sound */
static V b_beep(int argc, V *a) {
    ARGS(0, 4, "beep");
    double f = argc >= 1 ? num(a[0], "beep") : 880, s = argc >= 2 ? num(a[1], "beep") : 0.1, vol = argc >= 4 ? clampd(num(a[3], "beep"), 0, 1) : 0.4;
    int wave = argc >= 3 ? wave_of(txt(a[2], "beep")) : 1;
    static struct { double f, s, v; int w, id; } cache[32];
    static int ncache = 0, nextc = 0;
    int id = 0;
    for (int i = 0; i < ncache; i++) if (cache[i].f == f && cache[i].s == s && cache[i].v == vol && cache[i].w == wave) id = cache[i].id;
    if (!id) {
        id = tone_sound(f, s, wave, vol);
        int slot = ncache < 32 ? ncache++ : nextc++ % 32;
        if (cache[slot].id && ncache == 32) { /* the old sound stays loaded: a few KB */ }
        cache[slot].f = f; cache[slot].s = s; cache[slot].v = vol; cache[slot].w = wave; cache[slot].id = id;
    }
    return VI(voice_start(id, 1, 0, 1, 0));
}

/* ================================================================ the table */
typedef struct { const char *name; VBuiltinPtr fn; } Entry;
static const Entry canvas_table[] = {
    {"window", b_window}, {"canvas", b_canvas}, {"run_game", b_run_game}, {"next_frame", b_next_frame}, {"stop_game", b_stop_game},
    {"frame_rate", b_frame_rate}, {"fps", b_fps}, {"frame_count", b_frame_count}, {"delta_time", b_delta_time}, {"game_time", b_game_time},
    {"screen_width", b_screen_width}, {"screen_height", b_screen_height}, {"window_title", b_window_title}, {"fullscreen", b_fullscreen},
    {"screenshot", b_screenshot}, {"touch_controls", b_touch_controls}, {"show_keyboard", b_show_keyboard}, {"test_input", b_test_input},
    {"clear", b_clear}, {"color", b_color}, {"rgb", b_rgb}, {"rgba", b_rgba}, {"hsv", b_hsv}, {"mix_color", b_mix_color}, {"with_alpha", b_with_alpha},
    {"line_width", b_line_width}, {"antialias", b_antialias}, {"clip", b_clip}, {"no_clip", b_no_clip},
    {"camera", b_camera}, {"camera_center", b_camera_center}, {"no_camera", b_no_camera},
    {"rect", b_rect}, {"fill_rect", b_rect}, {"outline_rect", b_outline_rect}, {"round_rect", b_round_rect}, {"outline_round_rect", b_outline_round_rect},
    {"circle", b_circle}, {"outline_circle", b_outline_circle}, {"ellipse", b_ellipse}, {"outline_ellipse", b_outline_ellipse},
    {"line", b_line}, {"polyline", b_lines}, {"triangle", b_triangle}, {"outline_triangle", b_outline_triangle},
    {"polygon", b_polygon}, {"outline_polygon", b_outline_polygon}, {"arc", b_arc}, {"pie", b_pie}, {"pixel", b_pixel}, {"get_pixel", b_get_pixel},
    {"text_at", b_text_at}, {"draw_text", b_draw_text}, {"text_width", b_text_width}, {"text_height", b_text_height}, {"text_align", b_text_align},
    {"load_font", b_load_font}, {"font", b_font},
    {"load_image", b_load_image}, {"make_image", b_make_image}, {"image_from_rows", b_image_from_rows}, {"image_width", b_image_width},
    {"image_height", b_image_height}, {"draw_image", b_draw_image}, {"sprite_sheet", b_sprite_sheet}, {"frames_in", b_frame_count_of},
    {"draw_frame", b_draw_frame}, {"draw_tilemap", b_draw_tilemap}, {"draw_to", b_draw_to}, {"draw_to_screen", b_draw_to_screen},
    {"save_image", b_save_image}, {"copy_image", b_copy_image}, {"copy_screen", b_copy_screen}, {"image_pixel", b_image_pixel},
    {"set_image_pixel", b_set_image_pixel}, {"free_image", b_free_image},
    {"key_down", b_key_down}, {"key_pressed", b_key_pressed}, {"key_released", b_key_released}, {"key_repeated", b_key_repeat},
    {"last_key", b_last_key}, {"text_input", b_text_input},
    {"mouse_x", b_mouse_x}, {"mouse_y", b_mouse_y}, {"mouse_down", b_mouse_down}, {"mouse_pressed", b_mouse_pressed},
    {"mouse_released", b_mouse_released}, {"mouse_wheel", b_mouse_wheel}, {"mouse_world_x", b_mouse_world_x}, {"mouse_world_y", b_mouse_world_y},
    {"show_mouse", b_hide_mouse},
    {"pad_count", b_pad_count}, {"pad_down", b_pad_down}, {"pad_pressed", b_pad_pressed}, {"pad_released", b_pad_released}, {"pad_axis", b_pad_axis},
    {"touch_count", b_touch_count}, {"touch_x", b_touch_x}, {"touch_y", b_touch_y}, {"touches", b_touches},
    {"load_sound", b_load_sound}, {"make_tone", b_make_tone}, {"make_sound", b_make_sound}, {"play_sound", b_play_sound},
    {"stop_sound", b_stop_sound}, {"stop_all_sounds", b_stop_all_sounds}, {"sound_playing", b_sound_playing},
    {"play_music", b_play_music}, {"stop_music", b_stop_music}, {"music_volume", b_music_volume}, {"master_volume", b_master_volume},
    {"sound_length", b_sound_length}, {"beep", b_beep},
    {NULL, NULL}
};
static V (*prev_extra)(const char *name);
static V vcanvas_builtin_named(const char *name) {
    for (const Entry *e = canvas_table; e->name; e++) if (!strcmp(e->name, name)) return vrt_builtin(e->name, e->fn);
    return prev_extra ? prev_extra(name) : VUNDEF;
}
extern V (*vrt_extra_builtins)(const char *name);
__attribute__((constructor)) static void vcanvas_register(void) {
    prev_extra = vrt_extra_builtins;   /* chain: vgame.c may register before or after us */
    vrt_extra_builtins = vcanvas_builtin_named;
}
