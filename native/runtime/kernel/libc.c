/* Vanta kernel libc: the small C library the Vanta runtime needs on bare metal.
 *
 * Strings and memory, ctype, a complete printf family (including exact %f/%e/%g for doubles, done with a small
 * bignum so numbers print exactly like they do on a desktop), strtod/strtol, qsort, time, and stdio that writes to
 * the kernel console. There are no files on bare metal: fopen/stat/opendir always fail (kernel programs use the ram
 * file system builtins instead, and the compiler refuses the desktop file builtins).
 */
#include "kernel.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <math.h>
#include <time.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>

int errno = 0;

/* ===================================================================================== memory and strings */
void *memcpy(void *d, const void *s, size_t n) {
    unsigned char *dp = d; const unsigned char *sp = s;
    while (n >= 8 && (((uintptr_t)dp | (uintptr_t)sp) & 7) == 0) { *(uint64_t *)dp = *(const uint64_t *)sp; dp += 8; sp += 8; n -= 8; }
    while (n--) *dp++ = *sp++;
    return d;
}
void *memmove(void *d, const void *s, size_t n) {
    unsigned char *dp = d; const unsigned char *sp = s;
    if (dp == sp || n == 0) return d;
    if (dp < sp || dp >= sp + n) return memcpy(d, s, n);
    dp += n; sp += n;
    while (n >= 8 && (((uintptr_t)dp | (uintptr_t)sp) & 7) == 0) { dp -= 8; sp -= 8; *(uint64_t *)dp = *(const uint64_t *)sp; n -= 8; }
    while (n--) *--dp = *--sp;
    return d;
}
void *memset(void *d, int c, size_t n) {
    unsigned char *dp = d;
    uint64_t v = (unsigned char)c; v |= v << 8; v |= v << 16; v |= v << 32;
    while (n && ((uintptr_t)dp & 7)) { *dp++ = (unsigned char)c; n--; }
    while (n >= 8) { *(uint64_t *)dp = v; dp += 8; n -= 8; }
    while (n--) *dp++ = (unsigned char)c;
    return d;
}
int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = a, *y = b;
    for (size_t i = 0; i < n; i++) if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
    return 0;
}
void *memchr(const void *s, int c, size_t n) {
    const unsigned char *p = s;
    for (size_t i = 0; i < n; i++) if (p[i] == (unsigned char)c) return (void *)(p + i);
    return NULL;
}
size_t strlen(const char *s) { const char *p = s; while (*p) p++; return (size_t)(p - s); }
size_t strnlen(const char *s, size_t n) { size_t i = 0; while (i < n && s[i]) i++; return i; }
int strcmp(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return (unsigned char)*a - (unsigned char)*b; }
int strncmp(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) { if (a[i] != b[i] || !a[i]) return (unsigned char)a[i] - (unsigned char)b[i]; }
    return 0;
}
int strcasecmp(const char *a, const char *b) { while (*a && tolower(*a) == tolower(*b)) { a++; b++; } return tolower((unsigned char)*a) - tolower((unsigned char)*b); }
int strncasecmp(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) { int x = tolower((unsigned char)a[i]), y = tolower((unsigned char)b[i]); if (x != y || !x) return x - y; }
    return 0;
}
char *strcpy(char *d, const char *s) { char *r = d; while ((*d++ = *s++)) {} return r; }
char *strncpy(char *d, const char *s, size_t n) { size_t i = 0; for (; i < n && s[i]; i++) d[i] = s[i]; for (; i < n; i++) d[i] = 0; return d; }
char *strcat(char *d, const char *s) { strcpy(d + strlen(d), s); return d; }
char *strncat(char *d, const char *s, size_t n) { char *e = d + strlen(d); size_t i = 0; for (; i < n && s[i]; i++) e[i] = s[i]; e[i] = 0; return d; }
char *strchr(const char *s, int c) { for (;; s++) { if (*s == (char)c) return (char *)s; if (!*s) return NULL; } }
char *strrchr(const char *s, int c) { const char *r = NULL; for (;; s++) { if (*s == (char)c) r = s; if (!*s) return (char *)r; } }
char *strstr(const char *h, const char *n) {
    size_t ln = strlen(n);
    if (!ln) return (char *)h;
    for (; *h; h++) if (*h == *n && !strncmp(h, n, ln)) return (char *)h;
    return NULL;
}
char *strdup(const char *s) { size_t n = strlen(s) + 1; char *d = malloc(n); if (d) memcpy(d, s, n); return d; }
char *strndup(const char *s, size_t n) { size_t l = strnlen(s, n); char *d = malloc(l + 1); if (d) { memcpy(d, s, l); d[l] = 0; } return d; }
size_t strspn(const char *s, const char *a) { size_t i = 0; while (s[i] && strchr(a, s[i])) i++; return i; }
size_t strcspn(const char *s, const char *r) { size_t i = 0; while (s[i] && !strchr(r, s[i])) i++; return i; }
char *strpbrk(const char *s, const char *a) { for (; *s; s++) if (strchr(a, *s)) return (char *)s; return NULL; }
char *strtok(char *s, const char *delim) {
    static char *save;
    if (s) save = s;
    if (!save) return NULL;
    save += strspn(save, delim);
    if (!*save) { save = NULL; return NULL; }
    char *tok = save;
    save += strcspn(save, delim);
    if (*save) *save++ = 0; else save = NULL;
    return tok;
}
char *strerror(int e) { (void)e; return "not available on bare metal"; }

/* ===================================================================================== ctype (ASCII) */
int isdigit(int c) { return c >= '0' && c <= '9'; }
int isupper(int c) { return c >= 'A' && c <= 'Z'; }
int islower(int c) { return c >= 'a' && c <= 'z'; }
int isalpha(int c) { return isupper(c) || islower(c); }
int isalnum(int c) { return isalpha(c) || isdigit(c); }
int isspace(int c) { return c == ' ' || (c >= '\t' && c <= '\r'); }
int isblank(int c) { return c == ' ' || c == '\t'; }
int isxdigit(int c) { return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
int iscntrl(int c) { return (c >= 0 && c < 32) || c == 127; }
int isprint(int c) { return c >= 32 && c < 127; }
int isgraph(int c) { return c > 32 && c < 127; }
int ispunct(int c) { return isgraph(c) && !isalnum(c); }
int toupper(int c) { return islower(c) ? c - 32 : c; }
int tolower(int c) { return isupper(c) ? c + 32 : c; }

/* ===================================================================================== exact decimal digits of a double
 * A double is m * 2^e exactly. For e >= 0 the digits are those of the integer m << e; for e < 0 they are the digits
 * of m * 5^-e with the decimal point -e places from the right. A little base-1e9 bignum does both exactly. */
typedef struct { uint32_t d[130]; int n; } Big;   /* little-endian base 1e9; 5^1074 * 2^53 needs ~87 limbs */
static void big_mul(Big *b, uint32_t m) {
    uint64_t carry = 0;
    for (int i = 0; i < b->n; i++) { uint64_t x = (uint64_t)b->d[i] * m + carry; b->d[i] = (uint32_t)(x % 1000000000u); carry = x / 1000000000u; }
    while (carry) { b->d[b->n++] = (uint32_t)(carry % 1000000000u); carry /= 1000000000u; }
}
/* digits of |f| (finite, nonzero) into out (no leading zeros); *point = position of the decimal point
 * (value = 0.DIGITS x 10^point). Returns the digit count. */
static int exact_digits(double f, char *out, int *point) {
    uint64_t bits; memcpy(&bits, &f, 8);
    int ex = (int)((bits >> 52) & 0x7ff);
    uint64_t m = bits & ((1ULL << 52) - 1);
    if (ex) m |= 1ULL << 52; else ex = 1;
    int e2 = ex - 1075;
    while (m && !(m & 1)) { m >>= 1; e2++; }
    Big b; b.n = 0;
    while (m) { b.d[b.n++] = (uint32_t)(m % 1000000000u); m /= 1000000000u; }
    int frac = 0;
    if (e2 > 0) { int k = e2; while (k >= 29) { big_mul(&b, 1u << 29); k -= 29; } if (k) big_mul(&b, 1u << k); }
    else if (e2 < 0) { int k = -e2; frac = k; while (k >= 13) { big_mul(&b, 1220703125u); k -= 13; } uint32_t p = 1; while (k--) p *= 5; if (p > 1) big_mul(&b, p); }
    char tmp[1300]; int len = 0;
    char part[10];
    snprintf(part, sizeof part, "%u", b.d[b.n - 1]);
    for (char *q = part; *q; q++) tmp[len++] = *q;
    for (int i = b.n - 2; i >= 0; i--) { uint32_t v = b.d[i]; for (int j = 8; j >= 0; j--) { tmp[len + j] = (char)('0' + v % 10); v /= 10; } len += 9; }
    int nd = len;
    while (nd > 1 && tmp[nd - 1] == '0') nd--;   /* trailing zeros carry no information */
    memcpy(out, tmp, (size_t)nd);
    *point = len - frac;
    return nd;
}
/* round digits to keep `keep` digits (round half to even on the exact value). May bump *point on carry. */
static int round_digits(char *d, int nd, int keep, int *point) {
    if (keep >= nd) return nd;
    if (keep < 0) { d[0] = '0'; return 1; }   /* far below the rounding unit: zero */
    int up;
    if (d[keep] > '5') up = 1;
    else if (d[keep] < '5') up = 0;
    else {
        int rest = 0;
        for (int i = keep + 1; i < nd; i++) if (d[i] != '0') { rest = 1; break; }
        up = rest || (keep > 0 && ((d[keep - 1] - '0') & 1));
    }
    if (keep == 0) { d[0] = up ? '1' : '0'; if (up) (*point)++; return 1; }
    if (up) {
        int i = keep - 1;
        while (i >= 0 && d[i] == '9') { d[i] = '0'; i--; }
        if (i >= 0) d[i]++;
        else { d[0] = '1'; for (int j = 1; j < keep; j++) d[j] = '0'; (*point)++; }
    }
    return keep;
}

/* ===================================================================================== printf */
typedef struct { char *buf; size_t cap, len; } Out;
static void out_c(Out *o, char c) { if (o->len + 1 < o->cap) o->buf[o->len] = c; o->len++; }
static void out_s(Out *o, const char *s, size_t n) { for (size_t i = 0; i < n; i++) out_c(o, s[i]); }
static void out_pad(Out *o, char c, int n) { while (n-- > 0) out_c(o, c); }

enum { F_LEFT = 1, F_PLUS = 2, F_SPACE = 4, F_ALT = 8, F_ZERO = 16 };

static void emit_field(Out *o, const char *sign, const char *body, size_t blen, int width, int flags, int zero_ok) {
    size_t slen = strlen(sign);
    int pad = width - (int)(slen + blen);
    if (flags & F_LEFT) { out_s(o, sign, slen); out_s(o, body, blen); out_pad(o, ' ', pad); return; }
    if ((flags & F_ZERO) && zero_ok) { out_s(o, sign, slen); out_pad(o, '0', pad); out_s(o, body, blen); return; }
    out_pad(o, ' ', pad); out_s(o, sign, slen); out_s(o, body, blen);
}

static void fmt_double(Out *o, double f, char conv, int prec, int width, int flags) {
    char sign[2] = {0, 0};
    if (signbit(f)) { sign[0] = '-'; f = -f; } else if (flags & F_PLUS) sign[0] = '+'; else if (flags & F_SPACE) sign[0] = ' ';
    int upper = conv == 'F' || conv == 'E' || conv == 'G';
    if (isnan(f) || isinf(f)) {
        const char *t = isnan(f) ? (upper ? "NAN" : "nan") : (upper ? "INF" : "inf");
        emit_field(o, sign, t, 3, width, flags, 0);
        return;
    }
    if (prec < 0) prec = 6;
    static char d[1400];
    char body[1500];
    int point, nd;
    if (f == 0) { d[0] = '0'; nd = 1; point = 1; }
    else nd = exact_digits(f, d, &point);
    char c = (char)tolower(conv);
    int strip = 0;
    if (c == 'g') {
        if (prec == 0) prec = 1;
        int pt = point;
        int n2 = f == 0 ? 1 : round_digits(d, nd, prec, &pt);
        int x = f == 0 ? 0 : pt - 1;
        if (x < -4 || x >= prec) { c = 'e'; prec = prec - 1; }
        else { c = 'f'; prec = prec - 1 - x; }
        (void)n2;
        if (f != 0) nd = exact_digits(f, d, &point);   /* start again from the exact digits */
        strip = !(flags & F_ALT);
    }
    int bl = 0;
    if (c == 'f') {
        if (f != 0) nd = round_digits(d, nd, point + prec, &point);
        if (f != 0 && point + prec < 0) { nd = 1; d[0] = '0'; point = 1; }
        /* integer part */
        if (point <= 0) body[bl++] = '0';
        else for (int i = 0; i < point; i++) body[bl++] = i < nd ? d[i] : '0';
        if (prec > 0 || (flags & F_ALT)) {
            body[bl++] = '.';
            for (int i = 0; i < prec; i++) { int idx = point + i; body[bl++] = (idx >= 0 && idx < nd) ? d[idx] : '0'; }
        }
        if (f == 0 || (nd == 1 && d[0] == '0')) { /* exact zero digits */ }
    } else {   /* e */
        int x = 0;
        if (f != 0) { nd = round_digits(d, nd, prec + 1, &point); x = point - 1; }
        body[bl++] = d[0];
        if (prec > 0 || (flags & F_ALT)) {
            body[bl++] = '.';
            for (int i = 1; i <= prec; i++) body[bl++] = i < nd ? d[i] : '0';
        }
        if (strip) {
            /* strip in the mantissa before adding the exponent */
            if (memchr(body, '.', (size_t)bl)) { while (bl > 0 && body[bl - 1] == '0') bl--; if (bl > 0 && body[bl - 1] == '.') bl--; }
            strip = 0;
        }
        body[bl++] = upper ? 'E' : 'e';
        body[bl++] = x < 0 ? '-' : '+';
        int ax = x < 0 ? -x : x;
        if (ax >= 100) body[bl++] = (char)('0' + ax / 100);
        body[bl++] = (char)('0' + (ax / 10) % 10);
        body[bl++] = (char)('0' + ax % 10);
    }
    if (strip && memchr(body, '.', (size_t)bl)) { while (bl > 0 && body[bl - 1] == '0') bl--; if (bl > 0 && body[bl - 1] == '.') bl--; }
    emit_field(o, sign, body, (size_t)bl, width, flags, 1);
}

int vsnprintf(char *buf, size_t n, const char *fmt, va_list ap) {
    Out o = {buf, n, 0};
    for (const char *p = fmt; *p; p++) {
        if (*p != '%') { out_c(&o, *p); continue; }
        p++;
        int flags = 0, width = 0, prec = -1;
        for (;; p++) {
            if (*p == '-') flags |= F_LEFT; else if (*p == '+') flags |= F_PLUS; else if (*p == ' ') flags |= F_SPACE;
            else if (*p == '#') flags |= F_ALT; else if (*p == '0') flags |= F_ZERO; else break;
        }
        if (*p == '*') { width = va_arg(ap, int); if (width < 0) { flags |= F_LEFT; width = -width; } p++; }
        else while (isdigit((unsigned char)*p)) width = width * 10 + (*p++ - '0');
        if (*p == '.') {
            p++; prec = 0;
            if (*p == '*') { prec = va_arg(ap, int); p++; }
            else while (isdigit((unsigned char)*p)) prec = prec * 10 + (*p++ - '0');
        }
        int lng = 0;   /* 0 int, 1 long, 2 long long, -1 short, -2 char, 3 size_t */
        for (;; p++) {
            if (*p == 'l') lng = lng >= 1 ? 2 : 1;
            else if (*p == 'h') lng = lng <= -1 ? -2 : -1;
            else if (*p == 'z' || *p == 'j' || *p == 't') lng = 2;
            else if (*p == 'L' || *p == 'q') lng = 2;
            else break;
        }
        char conv = *p;
        if (!conv) break;
        char tmp[80];
        switch (conv) {
        case 'd': case 'i': case 'u': case 'x': case 'X': case 'o': case 'p': {
            unsigned long long u; int neg = 0;
            if (conv == 'p') { u = (uintptr_t)va_arg(ap, void *); flags |= F_ALT; conv = 'x'; lng = 2; }
            else if (conv == 'd' || conv == 'i') {
                long long s = lng == 2 ? va_arg(ap, long long) : lng == 1 ? va_arg(ap, long) : va_arg(ap, int);
                if (lng == -1) s = (short)s; else if (lng == -2) s = (signed char)s;
                if (s < 0) { neg = 1; u = (unsigned long long)(-(s + 1)) + 1; } else u = (unsigned long long)s;
            } else {
                u = lng == 2 ? va_arg(ap, unsigned long long) : lng == 1 ? va_arg(ap, unsigned long) : va_arg(ap, unsigned int);
                if (lng == -1) u = (unsigned short)u; else if (lng == -2) u = (unsigned char)u;
            }
            unsigned base = conv == 'x' || conv == 'X' ? 16 : conv == 'o' ? 8 : 10;
            const char *digs = conv == 'X' ? "0123456789ABCDEF" : "0123456789abcdef";
            int l = 0;
            char rev[40];
            if (u == 0 && prec != 0) rev[l++] = '0';
            while (u) { rev[l++] = digs[u % base]; u /= base; }
            int bl = 0;
            for (int i = l; i < prec; i++) tmp[bl++] = '0';
            for (int i = l - 1; i >= 0; i--) tmp[bl++] = rev[i];
            char sign[4] = {0};
            if (neg) strcpy(sign, "-"); else if ((flags & F_PLUS) && (conv == 'd' || conv == 'i')) strcpy(sign, "+");
            else if ((flags & F_SPACE) && (conv == 'd' || conv == 'i')) strcpy(sign, " ");
            if ((flags & F_ALT) && base == 16 && bl) strcat(sign, conv == 'X' ? "0X" : "0x");
            emit_field(&o, sign, tmp, (size_t)bl, width, flags, prec < 0);
            break;
        }
        case 'c': tmp[0] = (char)va_arg(ap, int); emit_field(&o, "", tmp, 1, width, flags & ~F_ZERO, 0); break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            size_t l = prec >= 0 ? strnlen(s, (size_t)prec) : strlen(s);
            emit_field(&o, "", s, l, width, flags & ~F_ZERO, 0);
            break;
        }
        case 'f': case 'F': case 'e': case 'E': case 'g': case 'G':
            fmt_double(&o, va_arg(ap, double), conv, prec, width, flags);
            break;
        case 'n': *va_arg(ap, int *) = (int)o.len; break;
        case '%': out_c(&o, '%'); break;
        default: out_c(&o, '%'); out_c(&o, conv); break;
        }
    }
    if (n) buf[o.len < n ? o.len : n - 1] = 0;
    return (int)o.len;
}
int snprintf(char *buf, size_t n, const char *fmt, ...) { va_list ap; va_start(ap, fmt); int r = vsnprintf(buf, n, fmt, ap); va_end(ap); return r; }
int sprintf(char *buf, const char *fmt, ...) { va_list ap; va_start(ap, fmt); int r = vsnprintf(buf, (size_t)1 << 30, fmt, ap); va_end(ap); return r; }

/* ===================================================================================== stdio on the console */
static FILE f_in = {0}, f_out = {1}, f_err = {2};
FILE *stdin = &f_in, *stdout = &f_out, *stderr = &f_err;

int vfprintf(FILE *f, const char *fmt, va_list ap) {
    char small[512];
    va_list ap2; va_copy(ap2, ap);
    int n = vsnprintf(small, sizeof small, fmt, ap);
    if (n < (int)sizeof small) fwrite(small, 1, (size_t)n, f);
    else { char *big = malloc((size_t)n + 1); if (big) { vsnprintf(big, (size_t)n + 1, fmt, ap2); fwrite(big, 1, (size_t)n, f); free(big); } }
    va_end(ap2);
    return n;
}
int vprintf(const char *fmt, va_list ap) { return vfprintf(stdout, fmt, ap); }
int printf(const char *fmt, ...) { va_list ap; va_start(ap, fmt); int r = vfprintf(stdout, fmt, ap); va_end(ap); return r; }
int fprintf(FILE *f, const char *fmt, ...) { va_list ap; va_start(ap, fmt); int r = vfprintf(f, fmt, ap); va_end(ap); return r; }
size_t fwrite(const void *p, size_t size, size_t n, FILE *f) {
    if (!f || f->fd < 1 || f->fd > 2) return 0;
    kcon_write((const char *)p, size * n);
    return n;
}
int fputs(const char *s, FILE *f) { fwrite(s, 1, strlen(s), f); return 1; }
int fputc(int c, FILE *f) { char ch = (char)c; fwrite(&ch, 1, 1, f); return (unsigned char)c; }
int putc(int c, FILE *f) { return fputc(c, f); }
int putchar(int c) { return fputc(c, stdout); }
int puts(const char *s) { fputs(s, stdout); fputc('\n', stdout); return 1; }
int fflush(FILE *f) { (void)f; return 0; }
int setvbuf(FILE *f, char *buf, int mode, size_t size) { (void)f; (void)buf; (void)mode; (void)size; return 0; }
char *fgets(char *s, int n, FILE *f) {
    if (!f || f->fd != 0 || n <= 1) return NULL;
    int len = kcon_read_line(s, n - 1);
    if (len < 0) return NULL;
    if (len < n - 1) s[len++] = '\n';
    s[len] = 0;
    return s;
}
int fgetc(FILE *f) { (void)f; return kkey_getchar(); }
int getc(FILE *f) { return fgetc(f); }
int getchar(void) { return kkey_getchar(); }
size_t fread(void *p, size_t size, size_t n, FILE *f) { (void)p; (void)size; (void)n; (void)f; return 0; }
FILE *fopen(const char *path, const char *mode) { (void)path; (void)mode; errno = ENOENT; return NULL; }
FILE *popen(const char *cmd, const char *mode) { (void)cmd; (void)mode; return NULL; }
int pclose(FILE *f) { (void)f; return -1; }
int fclose(FILE *f) { (void)f; return 0; }
int fseek(FILE *f, long off, int whence) { (void)f; (void)off; (void)whence; return -1; }
long ftell(FILE *f) { (void)f; return -1; }
int feof(FILE *f) { (void)f; return 1; }
int ferror(FILE *f) { (void)f; return 0; }
int remove(const char *path) { (void)path; return -1; }
int rename(const char *a, const char *b) { (void)a; (void)b; return -1; }
void perror(const char *s) { printf("%s: error\n", s); }
int stat(const char *p, struct stat *st) { (void)p; (void)st; errno = ENOENT; return -1; }
int lstat(const char *p, struct stat *st) { return stat(p, st); }
int mkdir(const char *p, mode_t mode) { (void)p; (void)mode; return -1; }
DIR *opendir(const char *p) { (void)p; return NULL; }
struct dirent *readdir(DIR *d) { (void)d; return NULL; }
int closedir(DIR *d) { (void)d; return 0; }
int chdir(const char *p) { (void)p; return -1; }
char *getcwd(char *buf, size_t n) { if (buf && n > 1) { buf[0] = '/'; buf[1] = 0; } return buf; }
int access(const char *p, int mode) { (void)p; (void)mode; return -1; }
int unlink(const char *p) { (void)p; return -1; }
int rmdir(const char *p) { (void)p; return -1; }
int isatty(int fd) { return fd <= 2; }
ssize_t read(int fd, void *buf, size_t n) { (void)fd; (void)buf; (void)n; return -1; }
ssize_t write(int fd, const void *buf, size_t n) { if (fd == 1 || fd == 2) { kcon_write(buf, n); return (ssize_t)n; } return -1; }
int close(int fd) { (void)fd; return 0; }
char *getenv(const char *name) { (void)name; return NULL; }
int system(const char *cmd) { (void)cmd; return -1; }
char *realpath(const char *path, char *resolved) { (void)path; (void)resolved; return NULL; }
pid_t getpid(void) { return (pid_t)(krandom_seed() & 0x7fffffff); }
int atexit(void (*fn)(void)) { (void)fn; return 0; }
_Noreturn void exit(int code) { kexit(code); }
_Noreturn void abort(void) { kpanic("abort() called"); }

/* ===================================================================================== numbers from text */
static int digit_val(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'z') return c - 'a' + 10;
    if (c >= 'A' && c <= 'Z') return c - 'A' + 10;
    return 99;
}
unsigned long long strtoull(const char *s, char **end, int base) {
    const char *p = s;
    while (isspace((unsigned char)*p)) p++;
    int neg = 0;
    if (*p == '+' || *p == '-') neg = *p++ == '-';
    if ((base == 0 || base == 16) && p[0] == '0' && (p[1] == 'x' || p[1] == 'X') && digit_val(p[2]) < 16) { p += 2; base = 16; }
    else if (base == 0 && p[0] == '0') base = 8;
    else if (base == 0) base = 10;
    unsigned long long v = 0;
    const char *start = p;
    int over = 0;
    while (digit_val(*p) < base) {
        unsigned long long nv = v * (unsigned)base + (unsigned)digit_val(*p);
        if (nv / (unsigned)base != v && !over) over = 1;
        v = nv; p++;
    }
    if (p == start) { if (end) *end = (char *)s; return 0; }
    if (end) *end = (char *)p;
    if (over) { errno = ERANGE; return ~0ULL; }
    return neg ? (unsigned long long)(-(long long)v) : v;
}
long long strtoll(const char *s, char **end, int base) {
    const char *p = s;
    while (isspace((unsigned char)*p)) p++;
    int neg = *p == '-';
    char *e;
    unsigned long long u = strtoull(p, &e, base);
    if (e == p) { if (end) *end = (char *)s; return 0; }
    if (end) *end = e;
    unsigned long long mag = neg ? (unsigned long long)(-(long long)u) : u;
    if (!neg && mag > 0x7fffffffffffffffULL) { errno = ERANGE; return 0x7fffffffffffffffLL; }
    if (neg && mag > 0x8000000000000000ULL) { errno = ERANGE; return (long long)0x8000000000000000ULL; }
    return neg ? -(long long)(mag - 1) - 1 : (long long)mag;
}
long strtol(const char *s, char **end, int base) { return (long)strtoll(s, end, base); }
unsigned long strtoul(const char *s, char **end, int base) { return (unsigned long)strtoull(s, end, base); }
int atoi(const char *s) { return (int)strtol(s, NULL, 10); }
long atol(const char *s) { return strtol(s, NULL, 10); }
long long atoll(const char *s) { return strtoll(s, NULL, 10); }
int abs(int x) { return x < 0 ? -x : x; }
long labs(long x) { return x < 0 ? -x : x; }
long long llabs(long long x) { return x < 0 ? -x : x; }

static const double P10[] = {1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16,
                             1e17, 1e18, 1e19, 1e20, 1e21, 1e22};
double strtod(const char *s, char **end) {
    const char *p = s;
    while (isspace((unsigned char)*p)) p++;
    int neg = 0;
    if (*p == '+' || *p == '-') neg = *p++ == '-';
    if (!strncasecmp(p, "inf", 3)) { p += 3; if (!strncasecmp(p, "inity", 5)) p += 5; if (end) *end = (char *)p; return neg ? -INFINITY : INFINITY; }
    if (!strncasecmp(p, "nan", 3)) { p += 3; if (end) *end = (char *)p; return NAN; }
    uint64_t m = 0; int digits = 0, exp10 = 0, any = 0;
    while (isdigit((unsigned char)*p)) { any = 1; if (digits < 19) { m = m * 10 + (uint64_t)(*p - '0'); if (m) digits++; } else exp10++; p++; }
    if (*p == '.') {
        p++;
        while (isdigit((unsigned char)*p)) { any = 1; if (digits < 19) { m = m * 10 + (uint64_t)(*p - '0'); if (m) digits++; exp10--; } p++; }
    }
    if (!any) { if (end) *end = (char *)s; return 0; }
    if (*p == 'e' || *p == 'E') {
        const char *q = p + 1; int eneg = 0, ev = 0, ed = 0;
        if (*q == '+' || *q == '-') eneg = *q++ == '-';
        while (isdigit((unsigned char)*q)) { if (ev < 100000) ev = ev * 10 + (*q - '0'); q++; ed = 1; }
        if (ed) { exp10 += eneg ? -ev : ev; p = q; }
    }
    if (end) *end = (char *)p;
    double r;
    if (m == 0) r = 0;
    else if (m <= (1ULL << 53) && exp10 >= -22 && exp10 <= 22) r = exp10 >= 0 ? (double)m * P10[exp10] : (double)m / P10[-exp10];
    else {
        r = (double)m;
        int e = exp10;
        while (e > 22) { r *= 1e22; e -= 22; if (isinf(r)) break; }
        while (e < -22) { r /= 1e22; e += 22; if (r == 0) break; }
        r = e >= 0 ? r * P10[e] : r / P10[-e];
    }
    return neg ? -r : r;
}
float strtof(const char *s, char **end) { return (float)strtod(s, end); }
double atof(const char *s) { return strtod(s, NULL); }

/* ===================================================================================== sorting, random */
static void msort(char *a, char *tmp, size_t n, size_t size, int (*cmp)(const void *, const void *)) {
    if (n < 2) return;
    size_t h = n / 2;
    msort(a, tmp, h, size, cmp);
    msort(a + h * size, tmp, n - h, size, cmp);
    size_t i = 0, j = h, k = 0;
    while (i < h && j < n) {
        if (cmp(a + j * size, a + i * size) < 0) memcpy(tmp + (k++) * size, a + (j++) * size, size);
        else memcpy(tmp + (k++) * size, a + (i++) * size, size);
    }
    while (i < h) memcpy(tmp + (k++) * size, a + (i++) * size, size);
    while (j < n) memcpy(tmp + (k++) * size, a + (j++) * size, size);
    memcpy(a, tmp, n * size);
}
void qsort(void *base, size_t n, size_t size, int (*cmp)(const void *, const void *)) {
    if (n < 2) return;
    char *tmp = malloc(n * size);
    if (!tmp) kpanic("qsort: out of memory");
    msort(base, tmp, n, size, cmp);
    free(tmp);
}
void *bsearch(const void *key, const void *base, size_t n, size_t size, int (*cmp)(const void *, const void *)) {
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        int c = cmp(key, (const char *)base + mid * size);
        if (c == 0) return (char *)base + mid * size;
        if (c < 0) hi = mid; else lo = mid + 1;
    }
    return NULL;
}
static uint64_t rstate = 0;
int rand(void) { if (!rstate) rstate = krandom_seed() | 1; rstate ^= rstate << 13; rstate ^= rstate >> 7; rstate ^= rstate << 17; return (int)(rstate & RAND_MAX); }
void srand(unsigned seed) { rstate = seed ? seed : 1; }

/* ===================================================================================== time (UTC, from the real-time clock) */
time_t time(time_t *t) { time_t v = (time_t)(kboot_epoch() + (int64_t)(kticks_ms() / 1000)); if (t) *t = v; return v; }
clock_t clock(void) { return (clock_t)kticks_ms(); }
int clock_gettime(clockid_t id, struct timespec *ts) {
    uint64_t ms = kticks_ms();
    ts->tv_sec = (time_t)(id == CLOCK_MONOTONIC ? (int64_t)(ms / 1000) : kboot_epoch() + (int64_t)(ms / 1000));
    ts->tv_nsec = (long)(ms % 1000) * 1000000L;
    return 0;
}
int gettimeofday(struct timeval *tv, void *tz) {
    (void)tz; uint64_t ms = kticks_ms();
    tv->tv_sec = (time_t)(kboot_epoch() + (int64_t)(ms / 1000)); tv->tv_usec = (long)(ms % 1000) * 1000L;
    return 0;
}
int nanosleep(const struct timespec *req, struct timespec *rem) {
    (void)rem;
    ksleep_ms((uint64_t)req->tv_sec * 1000 + (uint64_t)(req->tv_nsec / 1000000));
    return 0;
}
unsigned sleep(unsigned s) { ksleep_ms((uint64_t)s * 1000); return 0; }
int usleep(unsigned us) { ksleep_ms(us / 1000); return 0; }
double difftime(time_t a, time_t b) { return (double)(a - b); }

static int is_leap(long y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }
static const int MDAYS[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
int64_t kdays_from_civil(int64_t y, unsigned m, unsigned d) {   /* days since 1970-01-01 (Howard Hinnant's algorithm) */
    y -= m <= 2;
    int64_t era = (y >= 0 ? y : y - 399) / 400;
    unsigned yoe = (unsigned)(y - era * 400);
    unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (int64_t)doe - 719468;
}
struct tm *gmtime_r(const time_t *t, struct tm *tm) {
    int64_t s = *t, days = s / 86400, rem = s % 86400;
    if (rem < 0) { rem += 86400; days--; }
    tm->tm_hour = (int)(rem / 3600); tm->tm_min = (int)(rem % 3600 / 60); tm->tm_sec = (int)(rem % 60);
    tm->tm_wday = (int)((days + 4) % 7); if (tm->tm_wday < 0) tm->tm_wday += 7;
    long y = 1970;
    while (days < 0) { y--; days += is_leap(y) ? 366 : 365; }
    while (days >= (is_leap(y) ? 366 : 365)) { days -= is_leap(y) ? 366 : 365; y++; }
    tm->tm_year = (int)(y - 1900); tm->tm_yday = (int)days;
    int m = 0;
    while (1) { int md = MDAYS[m] + (m == 1 && is_leap(y)); if (days < md) break; days -= md; m++; }
    tm->tm_mon = m; tm->tm_mday = (int)days + 1; tm->tm_isdst = 0; tm->tm_gmtoff = 0; tm->tm_zone = "UTC";
    return tm;
}
struct tm *localtime_r(const time_t *t, struct tm *out) { return gmtime_r(t, out); }
struct tm *gmtime(const time_t *t) { static struct tm tm; return gmtime_r(t, &tm); }
struct tm *localtime(const time_t *t) { return gmtime(t); }
time_t timegm(struct tm *tm) {
    int64_t y = tm->tm_year + 1900 + tm->tm_mon / 12; int mon = tm->tm_mon % 12;
    if (mon < 0) { mon += 12; y--; }
    int64_t days = kdays_from_civil(y, (unsigned)mon + 1, 1) + tm->tm_mday - 1;
    return (time_t)(days * 86400 + tm->tm_hour * 3600 + tm->tm_min * 60 + tm->tm_sec);
}
time_t mktime(struct tm *tm) { return timegm(tm); }

static const char *WDAY[] = {"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
static const char *MON[] = {"January", "February", "March", "April", "May", "June", "July", "August", "September",
                            "October", "November", "December"};
size_t strftime(char *buf, size_t n, const char *fmt, const struct tm *tm) {
    Out o = {buf, n, 0};
    char t[64];
    for (const char *p = fmt; *p; p++) {
        if (*p != '%' || !p[1]) { out_c(&o, *p); continue; }
        p++;
        t[0] = 0;
        switch (*p) {
        case 'Y': snprintf(t, sizeof t, "%d", tm->tm_year + 1900); break;
        case 'y': snprintf(t, sizeof t, "%02d", (tm->tm_year + 1900) % 100); break;
        case 'm': snprintf(t, sizeof t, "%02d", tm->tm_mon + 1); break;
        case 'd': snprintf(t, sizeof t, "%02d", tm->tm_mday); break;
        case 'e': snprintf(t, sizeof t, "%2d", tm->tm_mday); break;
        case 'H': snprintf(t, sizeof t, "%02d", tm->tm_hour); break;
        case 'I': snprintf(t, sizeof t, "%02d", tm->tm_hour % 12 ? tm->tm_hour % 12 : 12); break;
        case 'M': snprintf(t, sizeof t, "%02d", tm->tm_min); break;
        case 'S': snprintf(t, sizeof t, "%02d", tm->tm_sec); break;
        case 'p': snprintf(t, sizeof t, "%s", tm->tm_hour < 12 ? "AM" : "PM"); break;
        case 'j': snprintf(t, sizeof t, "%03d", tm->tm_yday + 1); break;
        case 'A': snprintf(t, sizeof t, "%s", WDAY[tm->tm_wday % 7]); break;
        case 'a': snprintf(t, sizeof t, "%.3s", WDAY[tm->tm_wday % 7]); break;
        case 'B': snprintf(t, sizeof t, "%s", MON[tm->tm_mon % 12]); break;
        case 'b': case 'h': snprintf(t, sizeof t, "%.3s", MON[tm->tm_mon % 12]); break;
        case 'Z': snprintf(t, sizeof t, "UTC"); break;
        case 'z': snprintf(t, sizeof t, "+0000"); break;
        case 'F': snprintf(t, sizeof t, "%d-%02d-%02d", tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday); break;
        case 'T': snprintf(t, sizeof t, "%02d:%02d:%02d", tm->tm_hour, tm->tm_min, tm->tm_sec); break;
        case 'D': snprintf(t, sizeof t, "%02d/%02d/%02d", tm->tm_mon + 1, tm->tm_mday, (tm->tm_year + 1900) % 100); break;
        case 'c': snprintf(t, sizeof t, "%.3s %.3s %2d %02d:%02d:%02d %d", WDAY[tm->tm_wday % 7], MON[tm->tm_mon % 12],
                           tm->tm_mday, tm->tm_hour, tm->tm_min, tm->tm_sec, tm->tm_year + 1900); break;
        case 'n': snprintf(t, sizeof t, "\n"); break;
        case 't': snprintf(t, sizeof t, "\t"); break;
        case '%': snprintf(t, sizeof t, "%%"); break;
        default: snprintf(t, sizeof t, "%%%c", *p); break;
        }
        out_s(&o, t, strlen(t));
    }
    if (o.len >= n) { if (n) buf[0] = 0; return 0; }
    buf[o.len] = 0;
    return o.len;
}
static const char *scan_int(const char *s, int maxd, int *out) {
    int v = 0, d = 0, neg = 0;
    if (*s == '-' || *s == '+') neg = *s++ == '-';
    while (d < maxd && isdigit((unsigned char)*s)) { v = v * 10 + (*s++ - '0'); d++; }
    if (!d) return NULL;
    *out = neg ? -v : v;
    return s;
}
char *strptime(const char *s, const char *fmt, struct tm *tm) {
    for (const char *p = fmt; *p; p++) {
        if (isspace((unsigned char)*p)) { while (isspace((unsigned char)*s)) s++; continue; }
        if (*p != '%') { if (*s != *p) return NULL; s++; continue; }
        p++;
        int v;
        switch (*p) {
        case 'Y': if (!(s = scan_int(s, 4, &v))) return NULL; tm->tm_year = v - 1900; break;
        case 'y': if (!(s = scan_int(s, 2, &v))) return NULL; tm->tm_year = v < 69 ? v + 100 : v; break;
        case 'm': if (!(s = scan_int(s, 2, &v))) return NULL; tm->tm_mon = v - 1; break;
        case 'd': case 'e': if (!(s = scan_int(s, 2, &v))) return NULL; tm->tm_mday = v; break;
        case 'H': if (!(s = scan_int(s, 2, &v))) return NULL; tm->tm_hour = v; break;
        case 'M': if (!(s = scan_int(s, 2, &v))) return NULL; tm->tm_min = v; break;
        case 'S': if (!(s = scan_int(s, 2, &v))) return NULL; tm->tm_sec = v; break;
        case 'j': if (!(s = scan_int(s, 3, &v))) return NULL; tm->tm_yday = v - 1; break;
        case 'F': if (!(s = strptime(s, "%Y-%m-%d", tm))) return NULL; break;
        case 'T': if (!(s = strptime(s, "%H:%M:%S", tm))) return NULL; break;
        case 'b': case 'B': case 'h': {
            int found = 0;
            for (int i = 0; i < 12 && !found; i++) {
                size_t l = strlen(MON[i]);
                if (!strncasecmp(s, MON[i], l)) { tm->tm_mon = i; s += l; found = 1; }
                else if (!strncasecmp(s, MON[i], 3)) { tm->tm_mon = i; s += 3; found = 1; }
            }
            if (!found) return NULL;
            break;
        }
        case 'a': case 'A': {
            int found = 0;
            for (int i = 0; i < 7 && !found; i++) {
                size_t l = strlen(WDAY[i]);
                if (!strncasecmp(s, WDAY[i], l)) { tm->tm_wday = i; s += l; found = 1; }
                else if (!strncasecmp(s, WDAY[i], 3)) { tm->tm_wday = i; s += 3; found = 1; }
            }
            if (!found) return NULL;
            break;
        }
        case 'p': if (!strncasecmp(s, "pm", 2)) { if (tm->tm_hour < 12) tm->tm_hour += 12; s += 2; } else if (!strncasecmp(s, "am", 2)) { if (tm->tm_hour == 12) tm->tm_hour = 0; s += 2; } else return NULL; break;
        case '%': if (*s != '%') return NULL; s++; break;
        default: return NULL;
        }
    }
    return (char *)s;
}
