/* vantac: optional; libs: -lz */
/* Vanta native runtime: compress / decompress (zlib format) and gzip / gunzip, with zlib. Same results and messages
 * as vanta.py (zlib.compress at the default level; gzip.compress at level 9 with mtime 0 and OS byte 255). */
#include "vrt.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define NEED(n, name) do { if (argc != (n)) vrt_fail("%s expects %d value(s), got %d", name, n, argc); } while (0)

static const uint8_t *to_bytes(V v, int64_t *len) {
    if (v.t == VT_BYTES) { *len = AS_BYTES(v)->len; return AS_BYTES(v)->data; }
    V s = vrt_display(v);
    *len = AS_STR(s)->len;
    return (const uint8_t *)AS_STR(s)->data;
}
static V make_bytes(const uint8_t *p, int64_t n) {
    V b = vrt_bytes(n);
    if (n) memcpy(AS_BYTES(b)->data, p, (size_t)n);
    return b;
}

/* deflate everything at once; windowBits 15 = zlib wrapper, 31 = gzip wrapper */
static V deflate_all(const uint8_t *p, int64_t n, int level, int wbits, int gzip_fix) {
    z_stream z;
    memset(&z, 0, sizeof z);
    if (deflateInit2(&z, level, Z_DEFLATED, wbits, 8, Z_DEFAULT_STRATEGY) != Z_OK) vrt_fail("couldn't start compressing");
    uLong cap = deflateBound(&z, (uLong)n) + 64;
    uint8_t *out = malloc(cap);
    z.next_in = (Bytef *)p; z.avail_in = (uInt)n;
    z.next_out = out; z.avail_out = (uInt)cap;
    int r = deflate(&z, Z_FINISH);
    int64_t len = (int64_t)z.total_out;
    deflateEnd(&z);
    if (r != Z_STREAM_END) { free(out); vrt_fail("couldn't compress that data"); }
    if (gzip_fix && len >= 10) { out[4] = out[5] = out[6] = out[7] = 0; out[9] = 255; }
    V b = make_bytes(out, len);
    free(out);
    return b;
}

/* inflate one stream starting at p; returns 0 on success (stream ended), with *used = input bytes consumed */
static int inflate_one(const uint8_t *p, int64_t n, int wbits, uint8_t **out, int64_t *outlen, int64_t *used) {
    z_stream z;
    memset(&z, 0, sizeof z);
    if (inflateInit2(&z, wbits) != Z_OK) return -1;
    int64_t cap = n * 4 + 256, len = 0;
    uint8_t *o = malloc((size_t)cap);
    z.next_in = (Bytef *)p; z.avail_in = (uInt)n;
    int r;
    for (;;) {
        if (cap - len < 65536) { cap = cap * 2 + 65536; o = realloc(o, (size_t)cap); }
        z.next_out = o + len; z.avail_out = (uInt)(cap - len);
        r = inflate(&z, Z_NO_FLUSH);
        len = (int64_t)z.total_out;
        if (r == Z_STREAM_END) break;
        if (r == Z_OK) continue;
        if (r == Z_BUF_ERROR && z.avail_out == 0) continue;
        break;     /* data error, need dict, or input ran out before the end */
    }
    *used = (int64_t)z.total_in;
    inflateEnd(&z);
    if (r != Z_STREAM_END) { free(o); return -1; }
    *out = o; *outlen = len;
    return 0;
}

static V b_compress(int argc, V *a) {
    NEED(1, "compress");
    int64_t n; const uint8_t *p = to_bytes(a[0], &n);
    return deflate_all(p, n, Z_DEFAULT_COMPRESSION, 15, 0);
}
static V b_decompress(int argc, V *a) {
    NEED(1, "decompress");
    int64_t n, len, used; const uint8_t *p = to_bytes(a[0], &n);
    uint8_t *out;
    if (inflate_one(p, n, 15, &out, &len, &used) != 0) vrt_fail("that isn't zlib-compressed data");
    V b = make_bytes(out, len);
    free(out);
    return b;
}
static V b_gzip(int argc, V *a) {
    NEED(1, "gzip");
    int64_t n; const uint8_t *p = to_bytes(a[0], &n);
    return deflate_all(p, n, 9, 31, 1);
}

/* gzip.decompress: any number of members, each followed by its CRC-32 and length; zero padding between members is
 * skipped; empty input gives empty bytes. */
static V b_gunzip(int argc, V *a) {
    NEED(1, "gunzip");
    int64_t n; const uint8_t *p = to_bytes(a[0], &n);
    uint8_t *all = NULL; int64_t alen = 0;
    int64_t i = 0;
#define BAD() do { free(all); vrt_fail("that isn't gzip data"); } while (0)
    while (i < n) {
        if (n - i < 2 || p[i] != 0x1f || p[i + 1] != 0x8b) BAD();
        if (n - i < 10) BAD();
        uint8_t method = p[i + 2], flag = p[i + 3];
        if (method != 8) BAD();
        int64_t j = i + 10;
        if (flag & 4) {             /* FEXTRA */
            if (n - j < 2) BAD();
            int64_t xl = p[j] | (p[j + 1] << 8);
            j += 2;
            if (n - j < xl) BAD();
            j += xl;
        }
        if (flag & 8) { while (j < n && p[j]) j++; if (j < n) j++; }      /* FNAME */
        if (flag & 16) { while (j < n && p[j]) j++; if (j < n) j++; }     /* FCOMMENT */
        if (flag & 2) { if (n - j < 2) BAD(); j += 2; }                   /* FHCRC */
        uint8_t *out; int64_t len, used;
        if (inflate_one(p + j, n - j, -15, &out, &len, &used) != 0) BAD();
        j += used;
        if (n - j < 8) { free(out); BAD(); }
        uint32_t crc = (uint32_t)p[j] | (uint32_t)p[j + 1] << 8 | (uint32_t)p[j + 2] << 16 | (uint32_t)p[j + 3] << 24;
        uint32_t size = (uint32_t)p[j + 4] | (uint32_t)p[j + 5] << 8 | (uint32_t)p[j + 6] << 16 | (uint32_t)p[j + 7] << 24;
        uLong want = crc32(0L, Z_NULL, 0);
        int64_t k = 0;
        while (k < len) { uInt chunk = (uInt)((len - k) > (1 << 30) ? (1 << 30) : (len - k)); want = crc32(want, out + k, chunk); k += chunk; }
        if (crc != (uint32_t)want || size != (uint32_t)(len & 0xffffffff)) { free(out); BAD(); }
        all = realloc(all, (size_t)(alen + len + 1));
        if (len) memcpy(all + alen, out, (size_t)len);
        alen += len;
        free(out);
        j += 8;
        while (j < n && p[j] == 0) j++;
        i = j;
    }
#undef BAD
    V b = make_bytes(all, alen);
    free(all);
    return b;
}

typedef VEntry Entry;
static const Entry zlib_table[] = {
    {"compress", b_compress}, {"decompress", b_decompress}, {"gzip", b_gzip}, {"gunzip", b_gunzip},
    {NULL, NULL}
};
__attribute__((constructor)) static void vrt_zlib_register(void) { vrt_register_builtins(zlib_table); }
