/* Vanta native runtime: big whole numbers (VT_BIG), with Python 3 int semantics.
 *
 * A VBig is sign * magnitude, the magnitude in little-endian 32-bit limbs stored inline (so the GC owns all of it).
 * Values are immutable, and every public result that fits int64 comes back as a plain VT_INT.
 * Internally the math works on N: a read-only view of an argument, or a malloc'd temporary that is freed (or copied
 * into a fresh VBig) before returning, so no GC object is ever half-built while temporaries exist.
 * Division is Knuth's algorithm D; decimal text uses repeated division by 10^9.
 */
#include "vrt.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdio.h>

typedef struct { int s; int n; uint32_t *d; } N;   /* s = +1 / -1 (zero: s = +1, n = 0) */

static uint32_t *mal(int64_t n) {
    if (n > INT32_MAX) vrt_fail("that number is too big");
    uint32_t *p = calloc((size_t)(n > 0 ? n : 1), sizeof(uint32_t));
    if (!p) vrt_fail("out of memory");
    return p;
}
static int trimn(const uint32_t *d, int n) { while (n > 0 && d[n - 1] == 0) n--; return n; }

/* a view of an argument (no allocation); buf must hold 2 limbs */
static void view(V a, N *x, uint32_t *buf) {
    if (a.t == VT_INT || a.t == VT_BOOL) {
        int64_t i = a.u.i;
        uint64_t m = i < 0 ? 0 - (uint64_t)i : (uint64_t)i;
        x->s = i < 0 ? -1 : 1;
        buf[0] = (uint32_t)m; buf[1] = (uint32_t)(m >> 32);
        x->d = buf; x->n = trimn(buf, 2);
    } else if (a.t == VT_BIG) {
        VBig *b = (VBig *)a.u.o;
        x->d = b->d; x->n = trimn(b->d, b->n);
        x->s = (b->sign < 0 && x->n) ? -1 : 1;
    } else {
        vrt_fail("big number math needs whole numbers");
    }
}

/* turn an owned temporary into a value (frees it): VT_INT when it fits int64 */
static V finish(N r) {
    r.n = trimn(r.d, r.n);
    if (r.n <= 2) {
        uint64_t m = r.n == 0 ? 0 : r.n == 1 ? r.d[0] : ((uint64_t)r.d[1] << 32 | r.d[0]);
        if (r.s > 0 && m <= (uint64_t)INT64_MAX) { free(r.d); return VI((int64_t)m); }
        if (r.s < 0 && m <= (1ull << 63)) { free(r.d); return VI(m == (1ull << 63) ? INT64_MIN : -(int64_t)m); }
    }
    VBig *b = vrt_alloc(VT_BIG, sizeof(VBig) + (size_t)r.n * sizeof(uint32_t));
    b->sign = r.n ? r.s : 1; b->n = r.n;
    if (r.n) memcpy(b->d, r.d, (size_t)r.n * sizeof(uint32_t));
    free(r.d);
    return VO(VT_BIG, b);
}

static N ncopy(const N *x, int extra) {
    N r = { x->s, x->n, mal(x->n + extra) };
    if (x->n) memcpy(r.d, x->d, (size_t)x->n * sizeof(uint32_t));
    return r;
}

/* ---- magnitudes ---- */
static int mcmp(const uint32_t *a, int an, const uint32_t *b, int bn) {
    if (an != bn) return an < bn ? -1 : 1;
    for (int i = an - 1; i >= 0; i--) if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    return 0;
}
static uint32_t *madd(const uint32_t *a, int an, const uint32_t *b, int bn, int *rn) {
    if (an < bn) { const uint32_t *t = a; a = b; b = t; int tn = an; an = bn; bn = tn; }
    uint32_t *r = mal((int64_t)an + 1); uint64_t c = 0;
    for (int i = 0; i < an; i++) { c += (uint64_t)a[i] + (i < bn ? b[i] : 0); r[i] = (uint32_t)c; c >>= 32; }
    r[an] = (uint32_t)c; *rn = an + 1;
    return r;
}
static uint32_t *msub(const uint32_t *a, int an, const uint32_t *b, int bn, int *rn) {   /* needs a >= b */
    uint32_t *r = mal(an); int64_t br = 0;
    for (int i = 0; i < an; i++) {
        int64_t t = (int64_t)a[i] - (i < bn ? b[i] : 0) - br;
        br = t < 0; r[i] = (uint32_t)(t + (br ? (1ll << 32) : 0));
    }
    *rn = an;
    return r;
}
static N nadd(const N *x, const N *y, int ysign) {
    N r;
    if (x->s == ysign) { r.d = madd(x->d, x->n, y->d, y->n, &r.n); r.s = x->s; return r; }
    if (mcmp(x->d, x->n, y->d, y->n) >= 0) { r.d = msub(x->d, x->n, y->d, y->n, &r.n); r.s = x->s; }
    else { r.d = msub(y->d, y->n, x->d, x->n, &r.n); r.s = ysign; }
    return r;
}
static N nmul(const N *x, const N *y) {
    N r = { x->s * y->s, x->n + y->n, mal((int64_t)x->n + y->n) };
    for (int i = 0; i < x->n; i++) {
        uint64_t c = 0, xi = x->d[i];
        if (!xi) continue;
        for (int j = 0; j < y->n; j++) { c += xi * y->d[j] + r.d[i + j]; r.d[i + j] = (uint32_t)c; c >>= 32; }
        r.d[i + y->n] = (uint32_t)c;
    }
    return r;
}
/* in place: d[0..n) = d / v, returns the remainder */
static uint32_t mdiv_small(uint32_t *d, int n, uint32_t v) {
    uint64_t rem = 0;
    for (int i = n - 1; i >= 0; i--) { uint64_t cur = rem << 32 | d[i]; d[i] = (uint32_t)(cur / v); rem = cur % v; }
    return (uint32_t)rem;
}
/* truncated |u| / |v| (v nonzero) -> magnitudes q and r (malloc'd), Knuth algorithm D */
static void mdivmod(const uint32_t *u, int m, const uint32_t *v, int n, N *q, N *r) {
    q->s = r->s = 1;
    if (mcmp(u, m, v, n) < 0) { q->n = 0; q->d = mal(1); r->n = m; r->d = mal(m); if (m) memcpy(r->d, u, (size_t)m * 4); return; }
    if (n == 1) {
        q->n = m; q->d = mal(m); memcpy(q->d, u, (size_t)m * 4);
        r->n = 1; r->d = mal(1); r->d[0] = mdiv_small(q->d, m, v[0]);
        return;
    }
    const uint64_t B = 1ull << 32;
    int s = __builtin_clz(v[n - 1]);
    uint32_t *vn = mal(n), *un = mal((int64_t)m + 1);
    for (int i = n - 1; i > 0; i--) vn[i] = (uint32_t)((((uint64_t)v[i] << 32) | v[i - 1]) >> (32 - s));
    vn[0] = (uint32_t)((uint64_t)v[0] << s);
    un[m] = (uint32_t)((uint64_t)u[m - 1] >> (32 - s));
    for (int i = m - 1; i > 0; i--) un[i] = (uint32_t)((((uint64_t)u[i] << 32) | u[i - 1]) >> (32 - s));
    un[0] = (uint32_t)((uint64_t)u[0] << s);
    q->n = m - n + 1; q->d = mal(q->n);
    for (int j = m - n; j >= 0; j--) {
        uint64_t num = ((uint64_t)un[j + n] << 32) | un[j + n - 1];
        uint64_t qhat = num / vn[n - 1], rhat = num % vn[n - 1];
        while (qhat >= B || qhat * vn[n - 2] > ((rhat << 32) | un[j + n - 2])) {
            qhat--; rhat += vn[n - 1];
            if (rhat >= B) break;
        }
        int64_t k = 0, t;
        for (int i = 0; i < n; i++) {
            uint64_t p = qhat * vn[i];
            t = (int64_t)un[i + j] - k - (int64_t)(p & 0xFFFFFFFFu);
            un[i + j] = (uint32_t)t;
            k = (int64_t)(p >> 32) - (t >> 32);
        }
        t = (int64_t)un[j + n] - k; un[j + n] = (uint32_t)t;
        if (t < 0) {   /* subtracted one too many: add back */
            qhat--; uint64_t c = 0;
            for (int i = 0; i < n; i++) { c += (uint64_t)un[i + j] + vn[i]; un[i + j] = (uint32_t)c; c >>= 32; }
            un[j + n] += (uint32_t)c;
        }
        q->d[j] = (uint32_t)qhat;
    }
    r->n = n; r->d = mal(n);
    for (int i = 0; i < n; i++) r->d[i] = (uint32_t)((((uint64_t)un[i + 1] << 32) | un[i]) >> s);
    free(vn); free(un);
}
/* floor division (Python //, %); y nonzero. Either output pointer may be NULL. */
static void nfloordiv(const N *x, const N *y, N *qo, N *ro) {
    N q, r;
    mdivmod(x->d, x->n, y->d, y->n, &q, &r);
    q.s = x->s * y->s; r.s = x->s;
    if (trimn(r.d, r.n) && x->s != y->s) {   /* round toward -inf: q -= 1, r += y */
        uint32_t one = 1; N o = { -1, 1, &one };
        N q2 = nadd(&q, &o, -1); free(q.d); q = q2;
        N r2 = nadd(&r, y, y->s); free(r.d); r = r2;
    }
    if (qo) *qo = q; else free(q.d);
    if (ro) *ro = r; else free(r.d);
}
static int64_t bitlen(const N *x) { return x->n ? (int64_t)(x->n - 1) * 32 + (32 - __builtin_clz(x->d[x->n - 1])) : 0; }
static N nshl(const N *x, int64_t sh) {
    int64_t w = sh / 32; int b = (int)(sh % 32);
    N r = { x->s, 0, mal(x->n + w + 1) }; r.n = (int)(x->n + w + 1);
    for (int i = 0; i < x->n; i++) {
        uint64_t t = (uint64_t)x->d[i] << b;
        r.d[i + w] |= (uint32_t)t; r.d[i + w + 1] |= (uint32_t)(t >> 32);
    }
    return r;
}
/* magnitude >> sh; *lost set when any 1 bit was shifted out */
static N nshr(const N *x, int64_t sh, int *lost) {
    int64_t w = sh / 32; int b = (int)(sh % 32);
    *lost = 0;
    for (int64_t i = 0; i < w && i < x->n; i++) if (x->d[i]) { *lost = 1; break; }
    if (w >= x->n) { N z = { x->s, 0, mal(1) }; return z; }
    if (b && (x->d[w] & ((1u << b) - 1))) *lost = 1;
    N r = { x->s, (int)(x->n - w), mal(x->n - w) };
    for (int i = 0; i < r.n; i++) {
        uint64_t lo = x->d[i + w], hi = i + w + 1 < x->n ? x->d[i + w + 1] : 0;
        r.d[i] = (uint32_t)(((hi << 32) | lo) >> b);
    }
    return r;
}
/* nearest double of sign * mag * 2^exp, with sticky = "more nonzero bits below" (round half even) */
static double ndouble(const N *x, int sticky, int64_t exp) {
    int64_t L = bitlen(x);
    if (L == 0) return 0.0;
    uint64_t m = 0;   /* top 64 bits, MSB at bit 63 */
    for (int64_t k = 0; k < 64; k++) {
        int64_t bit = L - 1 - k;
        if (bit < 0) break;
        if ((x->d[bit / 32] >> (bit % 32)) & 1) m |= 1ull << (63 - k);
    }
    if (L > 64) for (int64_t i = 0; i * 32 < L - 64 && !sticky; i++) {
        int64_t lowbits = L - 64 - i * 32;
        uint32_t w = x->d[i];
        if (lowbits < 32) w &= (1u << lowbits) - 1;
        if (w) sticky = 1;
    }
    int64_t e = L - 53 + exp, drop = 11;      /* keep 53 bits, fewer when the result is subnormal */
    if (e > 2000) return x->s * HUGE_VAL;
    if (e < -1074) drop += -1074 - e;
    if (drop > 64) return x->s * 0.0;
    uint64_t keep = drop == 64 ? 0 : m >> drop, rem = drop == 64 ? m : m & ((1ull << drop) - 1), half = 1ull << (drop - 1);
    if (rem > half || (rem == half && (sticky || (keep & 1)))) keep++;
    return x->s * ldexp((double)keep, (int)(L - 64 + drop + exp));
}
static int64_t shift_amount(const N *y) {
    if (y->s < 0 && y->n) vrt_fail("you can't shift by a negative amount");
    if (y->n > 2 || (y->n == 2 && y->d[1] >= (1u << 31))) return INT64_MAX;
    return y->n == 0 ? 0 : y->n == 1 ? y->d[0] : (int64_t)((uint64_t)y->d[1] << 32 | y->d[0]);
}
/* two's complement of x over m limbs (written into out) */
static void twos(const N *x, uint32_t *out, int m) {
    for (int i = 0; i < m; i++) out[i] = i < x->n ? x->d[i] : 0;
    if (x->s < 0) { uint64_t c = 1; for (int i = 0; i < m; i++) { c += (uint32_t)~out[i]; out[i] = (uint32_t)c; c >>= 32; } }
}

/* ---- public API ---- */
V vrt_big_from_i64(int64_t x) {
    uint32_t buf[2]; N v; view(VI(x), &v, buf);
    VBig *b = vrt_alloc(VT_BIG, sizeof(VBig) + 2 * sizeof(uint32_t));
    b->sign = v.s; b->n = v.n; b->d[0] = buf[0]; b->d[1] = buf[1];
    return VO(VT_BIG, b);
}
V vrt_big_norm(V a) {
    if (a.t != VT_BIG) return a;
    uint32_t buf[2]; N x; view(a, &x, buf);
    if (x.n > 2) return a;
    return finish(ncopy(&x, 0));
}
V vrt_big_parse(const char *s, int64_t len) {
    int64_t i = 0; int sign = 1;
    while (i < len && (s[i] == ' ' || s[i] == '\t')) i++;
    if (i < len && (s[i] == '-' || s[i] == '+')) { if (s[i] == '-') sign = -1; i++; }
    N r = { sign, 0, mal(len / 9 + 2) };
    uint32_t chunk = 0, mulby = 1;
    for (; i <= len; i++) {
        int digit = i < len && s[i] >= '0' && s[i] <= '9';
        if (digit) { chunk = chunk * 10 + (uint32_t)(s[i] - '0'); mulby *= 10; }
        if ((mulby == 1000000000u) || (i == len && mulby > 1)) {   /* r = r * mulby + chunk */
            uint64_t c = chunk;
            for (int k = 0; k < r.n; k++) { c += (uint64_t)r.d[k] * mulby; r.d[k] = (uint32_t)c; c >>= 32; }
            if (c) r.d[r.n++] = (uint32_t)c;
            chunk = 0; mulby = 1;
        }
    }
    return finish(r);
}
V vrt_big_neg(V a) {
    uint32_t buf[2]; N x; view(a, &x, buf);
    N r = ncopy(&x, 0); r.s = -x.s;
    return finish(r);
}
int vrt_big_cmp(V a, V b) {
    uint32_t ba[2], bb[2]; N x, y; view(a, &x, ba); view(b, &y, bb);
    if (x.n == 0 && y.n == 0) return 0;
    int xs = x.n ? x.s : 0, ys = y.n ? y.s : 0;
    if (xs != ys) return xs < ys ? -1 : 1;
    int c = mcmp(x.d, x.n, y.d, y.n);
    return xs < 0 ? -c : c;
}
double vrt_big_to_double(V a) {
    uint32_t buf[2]; N x; view(a, &x, buf);
    return ndouble(&x, 0, 0);
}
char *vrt_big_text(V a, int64_t *len) {
    uint32_t buf[2]; N x; view(a, &x, buf);
    N t = ncopy(&x, 0);
    int64_t cap = (int64_t)x.n * 10 + 3, nc = 0;
    uint32_t *chunks = mal((int64_t)x.n * 2 + 1);
    while (t.n) { chunks[nc++] = mdiv_small(t.d, t.n, 1000000000u); t.n = trimn(t.d, t.n); }
    char *out = malloc((size_t)cap), *p = out;
    if (!out) vrt_fail("out of memory");
    if (x.s < 0 && x.n) *p++ = '-';
    if (nc == 0) *p++ = '0';
    else {
        p += snprintf(p, (size_t)(cap - (p - out)), "%u", chunks[nc - 1]);
        for (int64_t i = nc - 2; i >= 0; i--) p += snprintf(p, (size_t)(cap - (p - out)), "%09u", chunks[i]);
    }
    *p = 0; *len = p - out;
    free(t.d); free(chunks);
    return out;
}
uint32_t vrt_big_hash(V a) {
    uint32_t buf[2]; N x; view(a, &x, buf);
    uint32_t h = 2166136261u ^ (uint32_t)(x.s < 0);
    for (int i = 0; i < x.n; i++) { h ^= x.d[i]; h *= 16777619u; }
    return h;
}

V vrt_big_arith(int op, V a, V b) {
    uint32_t ba[2], bb[2]; N x, y; view(a, &x, ba); view(b, &y, bb);
    switch (op) {
    case '+': return finish(nadd(&x, &y, y.s));
    case '-': return finish(nadd(&x, &y, -y.s));
    case '*': return finish(nmul(&x, &y));
    case '%': {
        if (!y.n) vrt_fail("you can't take the remainder with zero");
        N r; nfloordiv(&x, &y, NULL, &r); return finish(r);
    }
    case '/': {
        if (!y.n) vrt_fail("you can't divide by zero");
        N q, r; mdivmod(x.d, x.n, y.d, y.n, &q, &r);
        if (!trimn(r.d, r.n)) { free(r.d); q.s = x.s * y.s; return finish(q); }
        free(q.d); free(r.d);
        /* correctly rounded: q = (|x| << k) / |y| with >= 66 significant bits, remainder as the sticky bit */
        int64_t k = 66 - (bitlen(&x) - bitlen(&y));
        if (k < 0) k = 0;
        N xs = nshl(&x, k); xs.s = 1;
        mdivmod(xs.d, trimn(xs.d, xs.n), y.d, y.n, &q, &r);
        q.s = x.s * y.s; q.n = trimn(q.d, q.n);
        double d = ndouble(&q, trimn(r.d, r.n) != 0, -k);
        free(xs.d); free(q.d); free(r.d);
        return VF(d);
    }
    case '^': {
        if (y.s < 0 && y.n) return VF(pow(ndouble(&x, 0, 0), ndouble(&y, 0, 0)));
        int ylow_odd = y.n && (y.d[0] & 1);
        if (x.n == 0) return VI(y.n ? 0 : 1);
        if (x.n == 1 && x.d[0] == 1) return VI(x.s < 0 && ylow_odd ? -1 : 1);
        if (bitlen(&y) > 40) vrt_fail("that number is too big");
        uint64_t e = y.n == 0 ? 0 : y.n == 1 ? y.d[0] : ((uint64_t)y.d[1] << 32 | y.d[0]);
        N res = { 1, 1, mal(1) }; res.d[0] = 1;
        N base = ncopy(&x, 0); base.s = 1;
        while (e) {
            if (e & 1) { N t = nmul(&res, &base); free(res.d); res = t; res.n = trimn(res.d, res.n); }
            e >>= 1;
            if (e) { N t = nmul(&base, &base); free(base.d); base = t; base.n = trimn(base.d, base.n); }
        }
        free(base.d);
        res.s = (x.s < 0 && ylow_odd) ? -1 : 1;
        return finish(res);
    }
    case '<': {
        int64_t sh = shift_amount(&y);
        if (x.n == 0) return VI(0);
        if (sh > ((int64_t)1 << 35)) vrt_fail("that number is too big");
        return finish(nshl(&x, sh));
    }
    case '>': {
        int64_t sh = shift_amount(&y), lost;
        int l;
        if (sh >= bitlen(&x)) return VI(x.n && x.s < 0 ? -1 : 0);
        N r = nshr(&x, sh, &l); lost = l;
        if (x.s < 0 && lost) {   /* floor: -(|x| >> sh) - 1 */
            uint32_t one = 1; N o = { -1, 1, &one };
            N r2 = nadd(&r, &o, -1); free(r.d); r = r2;
        }
        return finish(r);
    }
    case '&': case '|': case 'x': {
        int m = (x.n > y.n ? x.n : y.n) + 1;
        uint32_t *ta = mal(m), *tb = mal(m);
        twos(&x, ta, m); twos(&y, tb, m);
        for (int i = 0; i < m; i++) ta[i] = op == '&' ? (ta[i] & tb[i]) : op == '|' ? (ta[i] | tb[i]) : (ta[i] ^ tb[i]);
        free(tb);
        N r = { 1, m, ta };
        if (ta[m - 1] >> 31) {   /* negative: magnitude is the two's complement back */
            uint64_t c = 1;
            for (int i = 0; i < m; i++) { c += (uint32_t)~ta[i]; ta[i] = (uint32_t)c; c >>= 32; }
            r.s = -1;
        }
        return finish(r);
    }
    }
    vrt_fail("unknown big number operation");
}
