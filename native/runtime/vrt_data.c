/* vantac: optional */
/* Vanta native runtime: data builtins — hashes (md5, sha1, sha256, hmac), uuid, base64/hex/url/html encodings,
 * bytes_to_text, whole-number math and statistics (gcd, lcm, factorial, isqrt, mean, median, variance, stdev, mode)
 * and CSV. Same names, results and messages as vanta.py's. The hashes are written here in portable C. */
#if defined(__linux__)
#define _DEFAULT_SOURCE
#endif
#include "vrt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

#define NEED(n, name) do { if (argc != (n)) vrt_fail("%s expects %d value(s), got %d", name, n, argc); } while (0)

/* ---------------- small helpers ---------------- */
typedef struct { char *p; int64_t len, cap; } Buf;
static void bput(Buf *b, const void *s, int64_t n) {
    if (b->len + n + 1 > b->cap) { b->cap = (b->len + n + 1) * 2 + 64; b->p = realloc(b->p, (size_t)b->cap); }
    memcpy(b->p + b->len, s, (size_t)n); b->len += n; b->p[b->len] = 0;
}
static void bputc(Buf *b, char c) { bput(b, &c, 1); }
static void bputs(Buf *b, const char *s) { bput(b, s, (int64_t)strlen(s)); }
static V bdone(Buf *b) { V s = vrt_str(b->p ? b->p : "", b->len); free(b->p); b->p = NULL; return s; }

static double num_arg(V v, const char *name) {
    if (v.t == VT_INT) return (double)v.u.i;
    if (v.t == VT_FLOAT) return v.u.f;
    vrt_fail("%s needs a number", name);
}
static int64_t int_arg(V v, const char *name) {
    if (v.t != VT_INT) vrt_fail("%s needs whole numbers", name);
    return v.u.i;
}
static V tidy(double d) { if (d == floor(d) && fabs(d) < 9e18) return VI((int64_t)d); return VF(d); }

/* text -> its UTF-8 bytes; bytes stay as they are; anything else is shown as text first (vanta.py's _to_bytes) */
static const uint8_t *to_bytes(V v, int64_t *len) {
    if (v.t == VT_BYTES) { *len = AS_BYTES(v)->len; return AS_BYTES(v)->data; }
    V s = vrt_display(v);
    *len = AS_STR(s)->len;
    return (const uint8_t *)AS_STR(s)->data;
}
static VStr *text_arg(V v) { return AS_STR(vrt_display(v)); }

/* bytes -> text, invalid UTF-8 replaced by U+FFFD the way Python's decode("utf-8", "replace") does */
static void utf8_replace(Buf *b, const uint8_t *s, int64_t n) {
    static const char fffd[] = "\xEF\xBF\xBD";
    int64_t i = 0;
    while (i < n) {
        uint8_t c = s[i];
        if (c < 0x80) { bputc(b, (char)c); i++; continue; }
        int need; uint8_t lo = 0x80, hi = 0xBF;
        if (c >= 0xC2 && c <= 0xDF) need = 1;
        else if (c == 0xE0) { need = 2; lo = 0xA0; }
        else if ((c >= 0xE1 && c <= 0xEC) || c == 0xEE || c == 0xEF) need = 2;
        else if (c == 0xED) { need = 2; hi = 0x9F; }
        else if (c == 0xF0) { need = 3; lo = 0x90; }
        else if (c >= 0xF1 && c <= 0xF3) need = 3;
        else if (c == 0xF4) { need = 3; hi = 0x8F; }
        else { bput(b, fffd, 3); i++; continue; }
        int64_t j = i + 1; int k = 0;
        while (k < need) {
            if (j >= n || s[j] < lo || s[j] > hi) break;
            lo = 0x80; hi = 0xBF; j++; k++;
        }
        if (k == need) bput(b, s + i, j - i); else bput(b, fffd, 3);
        i = j;
    }
}
static V decode_utf8(const uint8_t *s, int64_t n) { Buf b = {0}; utf8_replace(&b, s, n); return bdone(&b); }

/* =====================================================================================================
 * Hashes: MD5 (RFC 1321), SHA-1 (FIPS 180-4), SHA-256 (FIPS 180-4)
 * ===================================================================================================== */
typedef struct {
    int algo;                 /* 0 md5, 1 sha1, 2 sha256 */
    uint32_t h[8];
    uint64_t total;
    uint8_t block[64];
    int fill;
} Hash;

static uint32_t rol(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }
static uint32_t ror(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

static void md5_block(uint32_t *h, const uint8_t *p) {
    static const uint32_t K[64] = {
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391};
    static const int R[64] = {7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                              5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                              4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                              6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21};
    uint32_t m[16];
    for (int i = 0; i < 16; i++) m[i] = (uint32_t)p[i * 4] | (uint32_t)p[i * 4 + 1] << 8 | (uint32_t)p[i * 4 + 2] << 16 | (uint32_t)p[i * 4 + 3] << 24;
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3];
    for (int i = 0; i < 64; i++) {
        uint32_t f; int g;
        if (i < 16) { f = (b & c) | (~b & d); g = i; }
        else if (i < 32) { f = (d & b) | (~d & c); g = (5 * i + 1) % 16; }
        else if (i < 48) { f = b ^ c ^ d; g = (3 * i + 5) % 16; }
        else { f = c ^ (b | ~d); g = (7 * i) % 16; }
        uint32_t t = d; d = c; c = b;
        b = b + rol(a + f + K[i] + m[g], R[i]);
        a = t;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d;
}

static void sha1_block(uint32_t *h, const uint8_t *p) {
    uint32_t w[80];
    for (int i = 0; i < 16; i++) w[i] = (uint32_t)p[i * 4] << 24 | (uint32_t)p[i * 4 + 1] << 16 | (uint32_t)p[i * 4 + 2] << 8 | (uint32_t)p[i * 4 + 3];
    for (int i = 16; i < 80; i++) w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
    for (int i = 0; i < 80; i++) {
        uint32_t f, k;
        if (i < 20) { f = (b & c) | (~b & d); k = 0x5A827999; }
        else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1; }
        else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
        else { f = b ^ c ^ d; k = 0xCA62C1D6; }
        uint32_t t = rol(a, 5) + f + e + k + w[i];
        e = d; d = c; c = rol(b, 30); b = a; a = t;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
}

static void sha256_block(uint32_t *h, const uint8_t *p) {
    static const uint32_t K[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
    uint32_t w[64];
    for (int i = 0; i < 16; i++) w[i] = (uint32_t)p[i * 4] << 24 | (uint32_t)p[i * 4 + 1] << 16 | (uint32_t)p[i * 4 + 2] << 8 | (uint32_t)p[i * 4 + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ror(w[i - 15], 7) ^ ror(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ror(w[i - 2], 17) ^ ror(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = hh + S1 + ch + K[i] + w[i];
        uint32_t S0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22);
        uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + mj;
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

static int hash_size(int algo) { return algo == 0 ? 16 : algo == 1 ? 20 : 32; }

static void hash_init(Hash *s, int algo) {
    memset(s, 0, sizeof *s);
    s->algo = algo;
    if (algo == 0) { s->h[0] = 0x67452301; s->h[1] = 0xefcdab89; s->h[2] = 0x98badcfe; s->h[3] = 0x10325476; }
    else if (algo == 1) { s->h[0] = 0x67452301; s->h[1] = 0xEFCDAB89; s->h[2] = 0x98BADCFE; s->h[3] = 0x10325476; s->h[4] = 0xC3D2E1F0; }
    else {
        static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
        memcpy(s->h, iv, sizeof iv);
    }
}
static void hash_block(Hash *s, const uint8_t *p) {
    if (s->algo == 0) md5_block(s->h, p); else if (s->algo == 1) sha1_block(s->h, p); else sha256_block(s->h, p);
}
static void hash_update(Hash *s, const uint8_t *p, int64_t n) {
    s->total += (uint64_t)n;
    while (n > 0) {
        int take = 64 - s->fill;
        if (take > n) take = (int)n;
        memcpy(s->block + s->fill, p, (size_t)take);
        s->fill += take; p += take; n -= take;
        if (s->fill == 64) { hash_block(s, s->block); s->fill = 0; }
    }
}
static void hash_final(Hash *s, uint8_t *out) {
    uint64_t bits = s->total * 8;
    uint8_t pad = 0x80, zero = 0, len[8];
    uint64_t keep = s->total;
    hash_update(s, &pad, 1);
    while (s->fill != 56) hash_update(s, &zero, 1);
    for (int i = 0; i < 8; i++) len[i] = s->algo == 0 ? (uint8_t)(bits >> (8 * i)) : (uint8_t)(bits >> (56 - 8 * i));
    hash_update(s, len, 8);
    s->total = keep;
    int words = hash_size(s->algo) / 4;
    for (int i = 0; i < words; i++)
        for (int j = 0; j < 4; j++)
            out[i * 4 + j] = s->algo == 0 ? (uint8_t)(s->h[i] >> (8 * j)) : (uint8_t)(s->h[i] >> (24 - 8 * j));
}
static void hash_once(int algo, const uint8_t *p, int64_t n, uint8_t *out) {
    Hash s; hash_init(&s, algo); hash_update(&s, p, n); hash_final(&s, out);
}
static V hex_text(const uint8_t *d, int n) {
    static const char hx[] = "0123456789abcdef";
    char buf[129];
    for (int i = 0; i < n; i++) { buf[i * 2] = hx[d[i] >> 4]; buf[i * 2 + 1] = hx[d[i] & 15]; }
    return vrt_str(buf, n * 2);
}
static V hash_builtin(int argc, V *a, int algo, const char *name) {
    NEED(1, name);
    int64_t n; const uint8_t *p = to_bytes(a[0], &n);
    uint8_t out[32];
    hash_once(algo, p, n, out);
    return hex_text(out, hash_size(algo));
}
static V b_md5(int argc, V *a) { return hash_builtin(argc, a, 0, "md5"); }
static V b_sha1(int argc, V *a) { return hash_builtin(argc, a, 1, "sha1"); }
static V b_sha256(int argc, V *a) { return hash_builtin(argc, a, 2, "sha256"); }

static V b_hmac(int argc, V *a) {
    if (argc < 2 || argc > 3) vrt_fail("hmac expects a key, a message and an optional algorithm (sha256, sha1, md5)");
    int algo = 2;
    if (argc == 3) {
        VStr *s = text_arg(a[2]);
        char name[8] = {0};
        if (s->len > 6) vrt_fail("hmac's algorithm must be sha256, sha1 or md5");
        for (int64_t i = 0; i < s->len; i++) { char c = s->data[i]; name[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c; }
        if (!strcmp(name, "sha256")) algo = 2;
        else if (!strcmp(name, "sha1")) algo = 1;
        else if (!strcmp(name, "md5")) algo = 0;
        else vrt_fail("hmac's algorithm must be sha256, sha1 or md5");
    }
    int64_t klen, mlen;
    const uint8_t *key = to_bytes(a[0], &klen);
    const uint8_t *msg = to_bytes(a[1], &mlen);
    uint8_t k[64] = {0}, ipad[64], opad[64], inner[32], out[32];
    int hs = hash_size(algo);
    if (klen > 64) hash_once(algo, key, klen, k); else memcpy(k, key, (size_t)klen);
    for (int i = 0; i < 64; i++) { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c; }
    Hash s;
    hash_init(&s, algo); hash_update(&s, ipad, 64); hash_update(&s, msg, mlen); hash_final(&s, inner);
    hash_init(&s, algo); hash_update(&s, opad, 64); hash_update(&s, inner, hs); hash_final(&s, out);
    return hex_text(out, hs);
}

/* ---------------- uuid ---------------- */
#if defined(__linux__)
#include <sys/random.h>
#endif
static void random_bytes(uint8_t *p, size_t n) {
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    arc4random_buf(p, n);
#else
    size_t got = 0;
#if defined(__linux__)
    while (got < n) { ssize_t r = getrandom(p + got, n - got, 0); if (r <= 0) break; got += (size_t)r; }
#endif
    if (got < n) {
        int fd = open("/dev/urandom", O_RDONLY);
        if (fd >= 0) { while (got < n) { ssize_t r = read(fd, p + got, n - got); if (r <= 0) break; got += (size_t)r; } close(fd); }
    }
    if (got < n) vrt_fail("uuid couldn't get random bytes");
#endif
}
static V b_uuid(int argc, V *a) {
    (void)a;
    NEED(0, "uuid");
    uint8_t b[16];
    random_bytes(b, 16);
    b[6] = (uint8_t)((b[6] & 0x0f) | 0x40);
    b[8] = (uint8_t)((b[8] & 0x3f) | 0x80);
    char out[37];
    snprintf(out, sizeof out, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
    return vrt_str(out, 36);
}

/* =====================================================================================================
 * base64, hex, url, html
 * ===================================================================================================== */
static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static V b64_encode(const uint8_t *p, int64_t n) {
    Buf b = {0};
    bput(&b, "", 0);
    for (int64_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)p[i] << 16 | (i + 1 < n ? (uint32_t)p[i + 1] << 8 : 0) | (i + 2 < n ? p[i + 2] : 0);
        char q[4] = {B64[(v >> 18) & 63], B64[(v >> 12) & 63], i + 1 < n ? B64[(v >> 6) & 63] : '=', i + 2 < n ? B64[v & 63] : '='};
        bput(&b, q, 4);
    }
    return bdone(&b);
}
static int b64_val(unsigned char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}
/* Python's base64.b64decode (binascii.a2b_base64, non-strict): characters outside the alphabet are skipped, padding
 * ends the data. Returns malloc'd bytes, or NULL with *err set to Python's message. */
static uint8_t *b64_decode(VStr *s, int64_t *outlen, char *err, size_t errn) {
    if (!s->ascii) { for (int64_t i = 0; i < s->len; i++) if ((unsigned char)s->data[i] >= 0x80) { snprintf(err, errn, "string argument should contain only ASCII characters"); return NULL; } }
    uint8_t *out = malloc((size_t)(s->len / 4 * 3 + 4));
    int64_t o = 0; int quad = 0, pads = 0; uint32_t left = 0;
    for (int64_t i = 0; i < s->len; i++) {
        unsigned char c = (unsigned char)s->data[i];
        if (c == '=') {
            if (quad >= 2 && quad + ++pads >= 4) { quad = 0; break; }
            continue;
        }
        int v = b64_val(c);
        if (v < 0) continue;
        pads = 0;
        switch (quad) {
        case 0: quad = 1; left = (uint32_t)v; break;
        case 1: quad = 2; out[o++] = (uint8_t)((left << 2) | ((uint32_t)v >> 4)); left = (uint32_t)v & 0xf; break;
        case 2: quad = 3; out[o++] = (uint8_t)((left << 4) | ((uint32_t)v >> 2)); left = (uint32_t)v & 3; break;
        default: quad = 0; out[o++] = (uint8_t)((left << 6) | (uint32_t)v); left = 0; break;
        }
    }
    if (quad != 0) {
        if (quad == 1) snprintf(err, errn, "Invalid base64-encoded string: number of data characters (%lld) cannot be 1 more than a multiple of 4", (long long)(o / 3 * 4 + 1));
        else snprintf(err, errn, "Incorrect padding");
        free(out);
        return NULL;
    }
    *outlen = o;
    return out;
}

static V b_base64_encode(int argc, V *a) {
    NEED(1, "base64_encode");
    VStr *s = text_arg(a[0]);
    return b64_encode((const uint8_t *)s->data, s->len);
}
static V b_base64_decode(int argc, V *a) {
    NEED(1, "base64_decode");
    char err[256]; int64_t n;
    uint8_t *d = b64_decode(text_arg(a[0]), &n, err, sizeof err);
    if (!d) vrt_fail("that is not valid base64: %s", err);
    Buf b = {0}; utf8_replace(&b, d, n); free(d);
    return bdone(&b);
}
static V b_base64_to_bytes(int argc, V *a) {
    NEED(1, "base64_to_bytes");
    char err[256]; int64_t n;
    uint8_t *d = b64_decode(text_arg(a[0]), &n, err, sizeof err);
    if (!d) vrt_fail("that is not valid base64: %s", err);
    V out = vrt_list(n);
    for (int64_t i = 0; i < n; i++) vrt_list_push(out, VI(d[i]));
    free(d);
    return out;
}
static V b_bytes_to_base64(int argc, V *a) {
    NEED(1, "bytes_to_base64");
    if (a[0].t != VT_LIST) vrt_fail("bytes_to_base64 needs a list of 0-255 numbers");
    VList *l = AS_LIST(a[0]);
    uint8_t *p = malloc((size_t)l->len + 1);
    for (int64_t i = 0; i < l->len; i++) {
        V x = l->items[i]; int64_t v;
        if (x.t == VT_INT || x.t == VT_BOOL) v = x.u.i;
        else if (x.t == VT_FLOAT && isfinite(x.u.f)) v = (int64_t)x.u.f;
        else if (x.t == VT_STR) {
            char *end; errno = 0;
            long long r = strtoll(AS_STR(x)->data, &end, 10);
            while (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r') end++;
            if (end == AS_STR(x)->data || *end || errno) { free(p); vrt_fail("bytes_to_base64 needs a list of 0-255 numbers"); }
            v = r;
        } else { free(p); vrt_fail("bytes_to_base64 needs a list of 0-255 numbers"); }
        p[i] = (uint8_t)(v & 0xFF);
    }
    V r = b64_encode(p, l->len);
    free(p);
    return r;
}

static int hex_val(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static int is_space(unsigned char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'; }
static int64_t char_pos(const unsigned char *p, int64_t at) { int64_t c = 0; for (int64_t k = 0; k < at; k++) if ((p[k] & 0xC0) != 0x80) c++; return c; }
static V b_hex_decode(int argc, V *a) {
    NEED(1, "hex_decode");
    VStr *s = text_arg(a[0]);
    const unsigned char *p = (const unsigned char *)s->data;
    int64_t n = s->len, i = 0, o = 0;
    uint8_t *out = malloc((size_t)(n / 2 + 1));
    while (i < n) {
        if (is_space(p[i])) { while (i < n && is_space(p[i])) i++; if (i >= n) break; }
        int top = hex_val(p[i]);
        if (top < 0) { int64_t pos = char_pos(p, i); free(out); vrt_fail("that is not valid hex: non-hexadecimal number found in fromhex() arg at position %lld", (long long)pos); }
        i++;
        int bot = i < n ? hex_val(p[i]) : -1;
        if (bot < 0) { int64_t pos = char_pos(p, i); free(out); vrt_fail("that is not valid hex: non-hexadecimal number found in fromhex() arg at position %lld", (long long)pos); }
        i++;
        out[o++] = (uint8_t)(top << 4 | bot);
    }
    Buf b = {0}; utf8_replace(&b, out, o); free(out);
    return bdone(&b);
}

static V b_url_encode(int argc, V *a) {
    NEED(1, "url_encode");
    VStr *s = text_arg(a[0]);
    static const char hx[] = "0123456789ABCDEF";
    Buf b = {0};
    bput(&b, "", 0);
    for (int64_t i = 0; i < s->len; i++) {
        unsigned char c = (unsigned char)s->data[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-' || c == '~') bputc(&b, (char)c);
        else { char e[3] = {'%', hx[c >> 4], hx[c & 15]}; bput(&b, e, 3); }
    }
    return bdone(&b);
}
/* urllib.parse.unquote: each run of ASCII has its %XX escapes turned into bytes and is decoded as UTF-8 (bad bytes
 * become U+FFFD); invalid escapes stay as they are; non-ASCII characters pass through. */
static V b_url_decode(int argc, V *a) {
    NEED(1, "url_decode");
    V t = vrt_display(a[0]);
    VStr *s = AS_STR(t);
    if (!memchr(s->data, '%', (size_t)s->len)) return t;
    const unsigned char *p = (const unsigned char *)s->data;
    int64_t n = s->len, i = 0;
    Buf b = {0}, run = {0};
    bput(&b, "", 0);
    while (i < n) {
        if (p[i] >= 0x80) {
            int64_t j = i;
            while (j < n && p[j] >= 0x80) j++;
            bput(&b, p + i, j - i);
            i = j;
            continue;
        }
        int64_t j = i;
        while (j < n && p[j] < 0x80) j++;
        run.len = 0;
        for (int64_t k = i; k < j; k++) {
            if (p[k] == '%' && k + 2 < j && hex_val(p[k + 1]) >= 0 && hex_val(p[k + 2]) >= 0) {
                uint8_t v = (uint8_t)(hex_val(p[k + 1]) << 4 | hex_val(p[k + 2]));
                bput(&run, &v, 1);
                k += 2;
            } else bput(&run, p + k, 1);
        }
        utf8_replace(&b, (const uint8_t *)run.p, run.len);
        i = j;
    }
    free(run.p);
    return bdone(&b);
}

static V b_html_escape(int argc, V *a) {
    NEED(1, "html_escape");
    VStr *s = text_arg(a[0]);
    Buf b = {0};
    bput(&b, "", 0);
    for (int64_t i = 0; i < s->len; i++) {
        char c = s->data[i];
        switch (c) {
        case '&': bputs(&b, "&amp;"); break;
        case '<': bputs(&b, "&lt;"); break;
        case '>': bputs(&b, "&gt;"); break;
        case '"': bputs(&b, "&quot;"); break;
        case '\'': bputs(&b, "&#39;"); break;
        default: bputc(&b, c);
        }
    }
    return bdone(&b);
}

static V b_bytes_to_text(int argc, V *a) {
    NEED(1, "bytes_to_text");
    if (a[0].t != VT_BYTES) vrt_fail("bytes_to_text needs bytes");
    return decode_utf8(AS_BYTES(a[0])->data, AS_BYTES(a[0])->len);
}

/* =====================================================================================================
 * Whole-number math and statistics
 * ===================================================================================================== */
static V *ints_of(int argc, V *a, const char *name, int64_t *n) {
    V *vals = a; int64_t cnt = argc;
    if (argc == 1 && a[0].t == VT_LIST) { vals = AS_LIST(a[0])->items; cnt = AS_LIST(a[0])->len; }
    if (cnt == 0) vrt_fail("%s needs at least one number", name);
    for (int64_t i = 0; i < cnt; i++) int_arg(vals[i], name);
    *n = cnt;
    return vals;
}
static uint64_t ugcd(uint64_t x, uint64_t y) { while (y) { uint64_t t = x % y; x = y; y = t; } return x; }
static uint64_t uabs(int64_t x) { return x < 0 ? (uint64_t)0 - (uint64_t)x : (uint64_t)x; }
static V from_u64(uint64_t u) {
    if (u <= (uint64_t)INT64_MAX) return VI((int64_t)u);
    return vrt_arith('+', VI(INT64_MAX), VI((int64_t)(u - (uint64_t)INT64_MAX)));
}
static V b_gcd(int argc, V *a) {
    int64_t n; V *vals = ints_of(argc, a, "gcd", &n);
    uint64_t r = 0;
    for (int64_t i = 0; i < n; i++) r = ugcd(r, uabs(vals[i].u.i));
    return from_u64(r);
}
static V b_lcm(int argc, V *a) {
    int64_t n; V *vals = ints_of(argc, a, "lcm", &n);
    uint64_t r = 1;
    for (int64_t i = 0; i < n; i++) {
        uint64_t v = uabs(vals[i].u.i);
        if (!r || !v) { r = 0; continue; }
        uint64_t q = r / ugcd(r, v), out;
        if (__builtin_mul_overflow(q, v, &out)) {
            if (i == n - 1) return vrt_arith('*', from_u64(q), from_u64(v));
            vrt_fail("lcm's result is too large for native builds");
        }
        r = out;
    }
    return from_u64(r);
}
static V b_factorial(int argc, V *a) {
    NEED(1, "factorial");
    int64_t n = int_arg(a[0], "factorial");
    if (n < 0) vrt_fail("factorial needs a whole number of 0 or more");
    V acc = VI(1);
    for (int64_t i = 2; i <= n; i++) acc = vrt_arith('*', acc, VI(i));
    return acc;
}
static V b_isqrt(int argc, V *a) {
    NEED(1, "isqrt");
    int64_t n = int_arg(a[0], "isqrt");
    if (n < 0) vrt_fail("isqrt needs a whole number of 0 or more");
    uint64_t r = (uint64_t)sqrtl((long double)n);
    while (r > 0 && r * r > (uint64_t)n) r--;
    while ((r + 1) * (r + 1) <= (uint64_t)n) r++;
    return VI((int64_t)r);
}

static VList *nums_of(int argc, V *a, const char *name, int least) {
    NEED(1, name);
    if (a[0].t != VT_LIST) vrt_fail("%s needs a list of numbers", name);
    VList *l = AS_LIST(a[0]);
    for (int64_t i = 0; i < l->len; i++) num_arg(l->items[i], name);
    if (l->len < least) vrt_fail("%s needs at least %s", name, least == 1 ? "one value" : "two values");
    return l;
}
static double mean_of(VList *l) {
    double t = 0.0;
    for (int64_t i = 0; i < l->len; i++) t += num_arg(l->items[i], "mean");
    return t / (double)l->len;
}
static double variance_of(VList *l) {
    double m = mean_of(l), t = 0.0;
    for (int64_t i = 0; i < l->len; i++) { double v = num_arg(l->items[i], "variance"); t += (v - m) * (v - m); }
    return t / (double)(l->len - 1);
}
static V b_mean(int argc, V *a) { return tidy(mean_of(nums_of(argc, a, "mean", 1))); }
static V b_variance(int argc, V *a) { return tidy(variance_of(nums_of(argc, a, "variance", 2))); }
static V b_stdev(int argc, V *a) { return tidy(sqrt(variance_of(nums_of(argc, a, "stdev", 2)))); }

static int num_less(V x, V y) {
    if (x.t == VT_INT && y.t == VT_INT) return x.u.i < y.u.i;
    return num_arg(x, "median") < num_arg(y, "median");
}
static void merge_sort(V *v, V *tmp, int64_t n) {        /* stable, like Python's sorted */
    if (n < 2) return;
    int64_t h = n / 2;
    merge_sort(v, tmp, h); merge_sort(v + h, tmp, n - h);
    int64_t i = 0, j = h, k = 0;
    while (i < h && j < n) tmp[k++] = num_less(v[j], v[i]) ? v[j++] : v[i++];
    while (i < h) tmp[k++] = v[i++];
    while (j < n) tmp[k++] = v[j++];
    memcpy(v, tmp, (size_t)n * sizeof(V));
}
static V b_median(int argc, V *a) {
    VList *l = nums_of(argc, a, "median", 1);
    int64_t n = l->len;
    V *v = malloc((size_t)n * sizeof(V)), *tmp = malloc((size_t)n * sizeof(V));
    memcpy(v, l->items, (size_t)n * sizeof(V));
    merge_sort(v, tmp, n);
    V r;
    if (n % 2) r = v[n / 2];
    else {
        V x = v[n / 2 - 1], y = v[n / 2];
        int64_t s;
        if (x.t == VT_INT && y.t == VT_INT && !__builtin_add_overflow(x.u.i, y.u.i, &s)) r = tidy((double)s / 2);
        else r = tidy((num_arg(x, "median") + num_arg(y, "median")) / 2);
    }
    free(v); free(tmp);
    return r;
}
static V b_mode(int argc, V *a) {
    NEED(1, "mode");
    if (a[0].t != VT_LIST || AS_LIST(a[0])->len == 0) vrt_fail("mode needs a non-empty list");
    VList *l = AS_LIST(a[0]);
    V best = VNIL; int64_t best_n = 0;
    for (int64_t i = 0; i < l->len; i++) {
        int64_t c = 0;
        for (int64_t j = 0; j < l->len; j++) if (vrt_equal(l->items[j], l->items[i])) c++;
        if (c > best_n) { best = l->items[i]; best_n = c; }
    }
    return best;
}

/* =====================================================================================================
 * CSV: the same small RFC-4180 reader/writer as vanta.py (_csv_parse / _csv_format)
 * ===================================================================================================== */
typedef struct { const char *p; int64_t n; } Delim;

static Delim delim_arg(int argc, V *a, int i, const char *name) {
    if (argc <= i || a[i].t == VT_NIL) return (Delim){",", 1};
    VStr *s = text_arg(a[i]);
    if (s->nchars != 1) vrt_fail("%s's delimiter must be one character", name);
    return (Delim){s->data, s->len};
}

static V csv_parse(const char *text, int64_t n, Delim d) {
    V rows = vrt_list(0), row = vrt_list(0);
    Buf field = {0};
    int quoted = 0, in_q = 0;
    int64_t i = 0;
#define FIELD() vrt_str(field.p ? field.p : "", field.len)
    while (i < n) {
        char c = text[i];
        if (in_q) {
            if (c == '"') {
                if (i + 1 < n && text[i + 1] == '"') { bputc(&field, '"'); i += 2; continue; }
                in_q = 0;
            } else bputc(&field, c);
            i++;
            continue;
        }
        if (c == '"' && field.len == 0) { in_q = quoted = 1; i++; continue; }
        if (i + d.n <= n && memcmp(text + i, d.p, (size_t)d.n) == 0) {
            vrt_list_push(row, FIELD());
            field.len = 0; quoted = 0;
            i += d.n;
            continue;
        }
        if (c == '\n' || c == '\r') {
            vrt_list_push(row, FIELD());
            VList *r = AS_LIST(row);
            if (!(r->len == 1 && AS_STR(r->items[0])->len == 0 && !quoted)) vrt_list_push(rows, row);
            row = vrt_list(0); field.len = 0; quoted = 0;
            if (c == '\r' && i + 1 < n && text[i + 1] == '\n') i++;
        } else bputc(&field, c);
        i++;
    }
    if (field.len || AS_LIST(row)->len || quoted) {
        vrt_list_push(row, FIELD());
        vrt_list_push(rows, row);
    }
#undef FIELD
    free(field.p);
    return rows;
}

static int has_sub(const char *s, int64_t n, const char *sub, int64_t m) {
    for (int64_t i = 0; i + m <= n; i++) if (memcmp(s + i, sub, (size_t)m) == 0) return 1;
    return 0;
}
/* appends to b; on bad input frees b's memory and fails */
static void csv_format(V rows, Delim d, Buf *b) {
    if (rows.t != VT_LIST) { free(b->p); vrt_fail("csv needs a list of rows"); }
    VList *l = AS_LIST(rows);
    for (int64_t r = 0; r < l->len; r++) {
        if (l->items[r].t != VT_LIST) { free(b->p); vrt_fail("each csv row must be a list"); }
        VList *row = AS_LIST(l->items[r]);
        for (int64_t c = 0; c < row->len; c++) {
            if (c) bput(b, d.p, d.n);
            VStr *s = AS_STR(vrt_display(row->items[c]));
            if (has_sub(s->data, s->len, d.p, d.n) || memchr(s->data, '"', (size_t)s->len) || memchr(s->data, '\n', (size_t)s->len) || memchr(s->data, '\r', (size_t)s->len)) {
                bputc(b, '"');
                for (int64_t k = 0; k < s->len; k++) { if (s->data[k] == '"') bputc(b, '"'); bputc(b, s->data[k]); }
                bputc(b, '"');
            } else bput(b, s->data, s->len);
        }
        bputc(b, '\n');
    }
}

static V read_text(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) vrt_fail("could not read %s: %s", path, strerror(errno));
    Buf b = {0};
    char tmp[65536];
    size_t got;
    while ((got = fread(tmp, 1, sizeof tmp, f)) > 0) bput(&b, tmp, (int64_t)got);
    if (ferror(f)) { int e = errno; fclose(f); free(b.p); vrt_fail("could not read %s: %s", path, strerror(e)); }
    fclose(f);
    V r = decode_utf8((const uint8_t *)(b.p ? b.p : ""), b.len);
    free(b.p);
    return r;
}
static void write_text(const char *path, Buf *b) {
    FILE *f = fopen(path, "wb");
    if (!f) { int e = errno; free(b->p); vrt_fail("could not write %s: %s", path, strerror(e)); }
    if (b->len && fwrite(b->p, 1, (size_t)b->len, f) != (size_t)b->len) { int e = errno; fclose(f); free(b->p); vrt_fail("could not write %s: %s", path, strerror(e)); }
    if (fclose(f) != 0) { int e = errno; free(b->p); vrt_fail("could not write %s: %s", path, strerror(e)); }
    free(b->p);
}

static V b_csv_parse(int argc, V *a) {
    if (argc < 1 || argc > 2) vrt_fail("csv_parse expects text and an optional delimiter");
    VStr *s = text_arg(a[0]);
    return csv_parse(s->data, s->len, delim_arg(argc, a, 1, "csv_parse"));
}
static V b_csv_format(int argc, V *a) {
    if (argc < 1 || argc > 2) vrt_fail("csv_format expects a list of rows and an optional delimiter");
    Delim d = delim_arg(argc, a, 1, "csv_format");
    Buf b = {0};
    bput(&b, "", 0);
    csv_format(a[0], d, &b);
    return bdone(&b);
}
static V b_csv_read(int argc, V *a) {
    if (argc < 1 || argc > 2) vrt_fail("csv_read expects a path and an optional delimiter");
    V t = read_text(vrt_cs(vrt_display(a[0])));
    return csv_parse(AS_STR(t)->data, AS_STR(t)->len, delim_arg(argc, a, 1, "csv_read"));
}
static V b_csv_write(int argc, V *a) {
    if (argc < 2 || argc > 3) vrt_fail("csv_write expects a path, a list of rows and an optional delimiter");
    Delim d = delim_arg(argc, a, 2, "csv_write");
    Buf b = {0};
    bput(&b, "", 0);
    csv_format(a[1], d, &b);
    write_text(vrt_cs(vrt_display(a[0])), &b);
    return VNIL;
}
static V b_csv_read_maps(int argc, V *a) {
    if (argc < 1 || argc > 2) vrt_fail("csv_read_maps expects a path and an optional delimiter");
    V t = read_text(vrt_cs(vrt_display(a[0])));
    V rows = csv_parse(AS_STR(t)->data, AS_STR(t)->len, delim_arg(argc, a, 1, "csv_read_maps"));
    VList *rl = AS_LIST(rows);
    V out = vrt_list(rl->len ? rl->len - 1 : 0);
    if (!rl->len) return out;
    VList *head = AS_LIST(rl->items[0]);
    for (int64_t r = 1; r < rl->len; r++) {
        VList *row = AS_LIST(rl->items[r]);
        V m = vrt_map();
        for (int64_t i = 0; i < head->len; i++) vrt_map_set(m, head->items[i], i < row->len ? row->items[i] : vrt_str("", 0));
        vrt_list_push(out, m);
    }
    return out;
}
static V b_csv_write_maps(int argc, V *a) {
    if (argc < 2 || argc > 3) vrt_fail("csv_write_maps expects a path, a list of maps and an optional list of columns");
    V maps = a[1];
    int ok = maps.t == VT_LIST;
    if (ok) for (int64_t i = 0; i < AS_LIST(maps)->len; i++) if (AS_LIST(maps)->items[i].t != VT_MAP) { ok = 0; break; }
    if (!ok) vrt_fail("csv_write_maps needs a list of maps");
    VList *ml = AS_LIST(maps);
    V cols;
    if (argc == 3 && a[2].t != VT_NIL) {
        if (a[2].t != VT_LIST) vrt_fail("csv_write_maps's columns must be a list");
        cols = a[2];
    } else {
        cols = vrt_list(0);
        if (ml->len) {
            VMap *m0 = AS_MAP(ml->items[0]);
            for (int64_t i = 0; i < m0->nent; i++) if (m0->ents[i].used) vrt_list_push(cols, m0->ents[i].key);
        }
    }
    VList *cl = AS_LIST(cols);
    V rows = vrt_list(ml->len + 1);
    vrt_list_push(rows, cols);
    for (int64_t r = 0; r < ml->len; r++) {
        V row = vrt_list(cl->len);
        for (int64_t c = 0; c < cl->len; c++) {
            int found = 0;
            V v = vrt_map_get(ml->items[r], cl->items[c], &found);
            vrt_list_push(row, found ? v : vrt_str("", 0));
        }
        vrt_list_push(rows, row);
    }
    Buf b = {0};
    bput(&b, "", 0);
    csv_format(rows, (Delim){",", 1}, &b);
    write_text(vrt_cs(vrt_display(a[0])), &b);
    return VNIL;
}

typedef VEntry Entry;
static const Entry data_table[] = {
    {"md5", b_md5}, {"sha1", b_sha1}, {"sha256", b_sha256}, {"hmac", b_hmac}, {"uuid", b_uuid},
    {"base64_encode", b_base64_encode}, {"base64_decode", b_base64_decode}, {"base64_to_bytes", b_base64_to_bytes},
    {"bytes_to_base64", b_bytes_to_base64}, {"hex_decode", b_hex_decode}, {"url_encode", b_url_encode},
    {"url_decode", b_url_decode}, {"html_escape", b_html_escape}, {"bytes_to_text", b_bytes_to_text},
    {"gcd", b_gcd}, {"lcm", b_lcm}, {"factorial", b_factorial}, {"isqrt", b_isqrt}, {"mean", b_mean},
    {"median", b_median}, {"variance", b_variance}, {"stdev", b_stdev}, {"mode", b_mode},
    {"csv_parse", b_csv_parse}, {"csv_format", b_csv_format}, {"csv_read", b_csv_read}, {"csv_write", b_csv_write},
    {"csv_read_maps", b_csv_read_maps}, {"csv_write_maps", b_csv_write_maps},
    {NULL, NULL}
};
__attribute__((constructor)) static void vrt_data_register(void) { vrt_register_builtins(data_table); }
