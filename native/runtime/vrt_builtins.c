/* Vanta native builtins: the same names and behaviour as vanta.py's (math, text, lists, maps, bytes, files, time,
 * JSON). Builtins that call back into Vanta (map, keep, sort_by, ...) pin what they hold, since the callback may
 * collect. */
#include "vrt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <ctype.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>

#define NEED(n, name) do { if (argc != (n)) vrt_fail("%s expects %d value(s), got %d", name, n, argc); } while (0)
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
static V list_arg(V v, const char *msg) { if (v.t != VT_LIST) vrt_fail("%s", msg); return v; }
static V map_arg(V v, const char *msg) { if (v.t != VT_MAP) vrt_fail("%s", msg); return v; }
static V text_of(V v) { return vrt_display(v); }
static VStr *S(V v) { return AS_STR(v); }

typedef struct { char *p; int64_t len, cap; } Buf;
static void bput(Buf *b, const char *s, int64_t n) {
    if (b->len + n + 1 > b->cap) { b->cap = (b->len + n + 1) * 2 + 64; b->p = realloc(b->p, (size_t)b->cap); }
    memcpy(b->p + b->len, s, (size_t)n); b->len += n; b->p[b->len] = 0;
}
static void bputs(Buf *b, const char *s) { bput(b, s, (int64_t)strlen(s)); }
static V bdone(Buf *b) { V s = vrt_str(b->p ? b->p : "", b->len); free(b->p); return s; }

/* ---------------- math ---------------- */
static V b_abs(int argc, V *a) { NEED(1, "abs"); if (a[0].t == VT_INT) return VI(a[0].u.i < 0 ? -a[0].u.i : a[0].u.i); return VF(fabs(num_arg(a[0], "abs"))); }
static V b_ceil(int argc, V *a) { NEED(1, "ceil"); if (a[0].t == VT_INT) return a[0]; return VI((int64_t)ceil(num_arg(a[0], "ceil"))); }
static V b_floor(int argc, V *a) { NEED(1, "floor"); if (a[0].t == VT_INT) return a[0]; return VI((int64_t)floor(num_arg(a[0], "floor"))); }
static V b_clamp(int argc, V *a) {
    NEED(3, "clamp");
    double v = num_arg(a[0], "clamp"), lo = num_arg(a[1], "clamp"), hi = num_arg(a[2], "clamp");
    if (lo > hi) vrt_fail("clamp needs the low bound first");
    V r = a[0];
    if (v < lo) r = a[1];
    if (num_arg(r, "clamp") > hi) r = a[2];
    return r;
}
static int less(V x, V y) {
    int bn = (x.t == VT_INT || x.t == VT_FLOAT) && (y.t == VT_INT || y.t == VT_FLOAT), bt = x.t == VT_STR && y.t == VT_STR;
    if (!bn && !bt) vrt_fail("min/max need all numbers or all text");
    return vrt_truthy(vrt_compare('<', x, y));
}
static V minmax(int argc, V *a, int want_max, const char *name) {
    V *vals = a; int64_t n = argc;
    if (argc == 1 && a[0].t == VT_LIST) { vals = AS_LIST(a[0])->items; n = AS_LIST(a[0])->len; }
    if (n == 0) vrt_fail("%s needs at least one value", name);
    V best = vals[0];
    for (int64_t i = 1; i < n; i++) if (want_max ? less(best, vals[i]) : less(vals[i], best)) best = vals[i];
    return best;
}
static V b_max(int argc, V *a) { return minmax(argc, a, 1, "max"); }
static V b_min(int argc, V *a) { return minmax(argc, a, 0, "min"); }
static V b_power(int argc, V *a) { NEED(2, "power"); num_arg(a[0], "power"); num_arg(a[1], "power"); return vrt_arith('^', a[0], a[1]); }
static double round_half_even(double x) { double r = round(x); if (fabs(x - trunc(x)) == 0.5) r = 2.0 * round(x / 2.0); return r; }
static V b_round(int argc, V *a) {
    if (argc == 1) { if (a[0].t == VT_INT) return a[0]; return VI((int64_t)round_half_even(num_arg(a[0], "round"))); }
    if (argc == 2) {
        int64_t d = int_arg(a[1], "round");
        if (a[0].t == VT_INT && d >= 0) return a[0];
        double x = num_arg(a[0], "round"), m = pow(10.0, (double)d);
        char buf[64]; snprintf(buf, sizeof buf, "%.*f", d > 0 ? (int)d : 0, x);
        double r = d >= 0 ? strtod(buf, NULL) : round_half_even(x * m) / m;
        if (a[0].t == VT_INT) return VI((int64_t)r);
        return VF(r);
    }
    vrt_fail("round expects a number (and an optional digit count)");
}
static V b_sign(int argc, V *a) { NEED(1, "sign"); double v = num_arg(a[0], "sign"); return VI((v > 0) - (v < 0)); }
static V b_sqrt(int argc, V *a) { NEED(1, "sqrt"); double v = num_arg(a[0], "sqrt"); if (v < 0) vrt_fail("can't take the square root of a negative number"); return tidy(sqrt(v)); }
static V b_sum(int argc, V *a) {
    NEED(1, "sum"); list_arg(a[0], "sum needs a list of numbers");
    V t = VI(0); VList *l = AS_LIST(a[0]);
    for (int64_t i = 0; i < l->len; i++) { num_arg(l->items[i], "sum"); t = vrt_arith('+', t, l->items[i]); }
    return t;
}
static V b_product(int argc, V *a) {
    NEED(1, "product"); list_arg(a[0], "product needs a list of numbers");
    V t = VI(1); VList *l = AS_LIST(a[0]);
    for (int64_t i = 0; i < l->len; i++) { num_arg(l->items[i], "product"); t = vrt_arith('*', t, l->items[i]); }
    return t;
}
static uint64_t rng_state = 0;
static uint64_t rng(void) {
    if (!rng_state) rng_state = (uint64_t)time(NULL) ^ ((uint64_t)getpid() << 32) ^ 0x9E3779B97F4A7C15ULL;
    rng_state ^= rng_state << 13; rng_state ^= rng_state >> 7; rng_state ^= rng_state << 17;
    return rng_state;
}
static V b_random(int argc, V *a) {
    NEED(2, "random");
    int64_t lo = int_arg(a[0], "random"), hi = int_arg(a[1], "random");
    if (lo > hi) vrt_fail("random needs the low number first");
    return VI(lo + (int64_t)(rng() % (uint64_t)(hi - lo + 1)));
}
static V b_random_float(int argc, V *a) { (void)a; NEED(0, "random_float"); return VF((double)(rng() >> 11) / 9007199254740992.0); }
static V b_pick(int argc, V *a) {
    NEED(1, "pick");
    if (a[0].t != VT_LIST || AS_LIST(a[0])->len == 0) vrt_fail("pick needs a non-empty list");
    return AS_LIST(a[0])->items[rng() % (uint64_t)AS_LIST(a[0])->len];
}
static V b_shuffle(int argc, V *a) {
    NEED(1, "shuffle"); list_arg(a[0], "shuffle needs a list");
    V r = vrt_list_of((int)AS_LIST(a[0])->len, AS_LIST(a[0])->items); VList *l = AS_LIST(r);
    for (int64_t i = l->len - 1; i > 0; i--) { int64_t j = (int64_t)(rng() % (uint64_t)(i + 1)); V t = l->items[i]; l->items[i] = l->items[j]; l->items[j] = t; }
    return r;
}
#define MATH1(fname, cfn) static V b_##fname(int argc, V *a) { NEED(1, #fname); return VF(cfn(num_arg(a[0], #fname))); }
MATH1(exp, exp) MATH1(sin, sin) MATH1(cos, cos) MATH1(tan, tan) MATH1(asin, asin) MATH1(acos, acos) MATH1(atan, atan)
static V b_atan2(int argc, V *a) { NEED(2, "atan2"); return VF(atan2(num_arg(a[0], "atan2"), num_arg(a[1], "atan2"))); }
static V b_log(int argc, V *a) {
    if (argc == 1) { double v = num_arg(a[0], "log"); if (v <= 0) vrt_fail("log needs a number above zero"); return VF(log(v)); }
    if (argc == 2) { double v = num_arg(a[0], "log"), b = num_arg(a[1], "log"); if (v <= 0 || b <= 0) vrt_fail("log needs numbers above zero"); return VF(log(v) / log(b)); }
    vrt_fail("log expects a number (and an optional base)");
}

/* ---------------- conversions & inspection ---------------- */
static V b_length(int argc, V *a) {
    NEED(1, "length");
    switch (a[0].t) {
    case VT_STR: return VI(S(a[0])->nchars);
    case VT_LIST: return VI(AS_LIST(a[0])->len);
    case VT_MAP: return VI(AS_MAP(a[0])->count);
    case VT_BYTES: return VI(AS_BYTES(a[0])->len);
    default: vrt_fail("length works on text, lists, maps, or bytes");
    }
}
static V b_text(int argc, V *a) { NEED(1, "text"); return vrt_display(a[0]); }
static V b_number(int argc, V *a) {
    NEED(1, "number");
    V v = a[0];
    if (v.t == VT_BOOL) vrt_fail("can't turn yes/no into a number");
    if (v.t == VT_INT || v.t == VT_FLOAT) return v;
    if (v.t == VT_STR) {
        const char *s = S(v)->data; char *end;
        while (isspace((unsigned char)*s)) s++;
        if (*s) {
            long long i = strtoll(s, &end, 10);
            while (isspace((unsigned char)*end)) end++;
            if (*end == 0) return VI(i);
            double d = strtod(s, &end);
            while (isspace((unsigned char)*end)) end++;
            if (*end == 0) return VF(d);
        }
        vrt_fail("\"%s\" is not a number", S(v)->data);
    }
    vrt_fail("can't turn that into a number");
}
static const char *tname(V v) {
    switch (v.t) {
    case VT_NIL: case VT_UNDEF: return "nothing";
    case VT_BOOL: return "yes-no";
    case VT_INT: case VT_FLOAT: return "number";
    case VT_STR: return "text";
    case VT_LIST: return "list";
    case VT_MAP: return "map";
    case VT_BYTES: return "bytes";
    case VT_FUNC: case VT_BUILTIN: case VT_BOUND: return "function";
    case VT_TYPE: return "type";
    case VT_OBJ: return AS_INST(v)->type->name;
    default: return "value";
    }
}
static V b_type_of(int argc, V *a) { NEED(1, "type_of"); return vrt_cstr(tname(a[0])); }
static V b_typeof(int argc, V *a) {
    NEED(1, "typeof");
    switch (a[0].t) {
    case VT_BOOL: return vrt_cstr("bool");
    case VT_INT: case VT_FLOAT: return vrt_cstr("number");
    case VT_STR: return vrt_cstr("text");
    case VT_LIST: return vrt_cstr("list");
    case VT_MAP: return vrt_cstr("map");
    case VT_BYTES: return vrt_cstr("bytes");
    default: return vrt_cstr("nothing");
    }
}
static V b_is_number(int argc, V *a) { NEED(1, "is_number"); return VB(a[0].t == VT_INT || a[0].t == VT_FLOAT); }
static V b_is_text(int argc, V *a) { NEED(1, "is_text"); return VB(a[0].t == VT_STR); }
static V b_is_list(int argc, V *a) { NEED(1, "is_list"); return VB(a[0].t == VT_LIST); }
static V b_is_map(int argc, V *a) { NEED(1, "is_map"); return VB(a[0].t == VT_MAP); }
static V b_is_bytes(int argc, V *a) { NEED(1, "is_bytes"); return VB(a[0].t == VT_BYTES); }
static V b_is_function(int argc, V *a) { NEED(1, "is_function"); return VB(a[0].t == VT_FUNC || a[0].t == VT_BUILTIN || a[0].t == VT_BOUND); }
static V b_is_nothing(int argc, V *a) { NEED(1, "is_nothing"); return VB(a[0].t == VT_NIL); }
static V b_is_a(int argc, V *a) { NEED(2, "is_a"); if (a[1].t != VT_TYPE) vrt_fail("is_a's second value must be a type"); return vrt_isa(a[0], a[1]); }

/* ---------------- text ---------------- */
static V map_chars(V v, int (*f)(int)) {
    V s = text_of(v); VStr *x = S(s);
    char *p = malloc((size_t)x->len + 1);
    for (int64_t i = 0; i < x->len; i++) { unsigned char c = (unsigned char)x->data[i]; p[i] = c < 0x80 ? (char)f(c) : (char)c; }
    V r = vrt_str(p, x->len); free(p); return r;
}
static V b_lowercase(int argc, V *a) { NEED(1, "lowercase"); return map_chars(a[0], tolower); }
static V b_uppercase(int argc, V *a) { NEED(1, "uppercase"); return map_chars(a[0], toupper); }
static V b_capitalize(int argc, V *a) {
    NEED(1, "capitalize");
    V s = text_of(a[0]); VStr *x = S(s);
    if (!x->len) return s;
    char *p = malloc((size_t)x->len + 1); memcpy(p, x->data, (size_t)x->len);
    if ((unsigned char)p[0] < 0x80) p[0] = (char)toupper((unsigned char)p[0]);
    V r = vrt_str(p, x->len); free(p); return r;
}
static V b_title_case(int argc, V *a) {
    NEED(1, "title_case");
    V s = text_of(a[0]); VStr *x = S(s);
    char *p = malloc((size_t)x->len + 1); int prev_alpha = 0;
    for (int64_t i = 0; i < x->len; i++) {
        unsigned char c = (unsigned char)x->data[i];
        if (c < 0x80 && isalpha(c)) { p[i] = (char)(prev_alpha ? tolower(c) : toupper(c)); prev_alpha = 1; }
        else { p[i] = (char)c; prev_alpha = c >= 0x80; }
    }
    V r = vrt_str(p, x->len); free(p); return r;
}
static V b_trim(int argc, V *a) {
    NEED(1, "trim");
    V s = text_of(a[0]); VStr *x = S(s);
    int64_t i = 0, j = x->len;
    while (i < j && isspace((unsigned char)x->data[i])) i++;
    while (j > i && isspace((unsigned char)x->data[j - 1])) j--;
    return vrt_str(x->data + i, j - i);
}
static V split_by(VStr *x, VStr *sep) {
    V r = vrt_list(8);
    if (sep->len == 0) vrt_fail("empty separator");
    int64_t start = 0;
    for (int64_t i = 0; i + sep->len <= x->len;) {
        if (memcmp(x->data + i, sep->data, (size_t)sep->len) == 0) { vrt_list_push(r, vrt_str(x->data + start, i - start)); i += sep->len; start = i; }
        else i++;
    }
    vrt_list_push(r, vrt_str(x->data + start, x->len - start));
    return r;
}
static V b_split(int argc, V *a) { NEED(2, "split"); V s = text_of(a[0]), p = text_of(a[1]); return split_by(S(s), S(p)); }
static V b_lines(int argc, V *a) { NEED(1, "lines"); V s = text_of(a[0]); VStr nl = {0}; (void)nl; V sep = vrt_cstr("\n"); return split_by(S(s), S(sep)); }
static V b_join(int argc, V *a) {
    NEED(2, "join");
    if (a[0].t != VT_LIST) vrt_fail("join needs a list as its first value");
    V sep = text_of(a[1]); VList *l = AS_LIST(a[0]); Buf b = {0};
    bput(&b, "", 0);
    for (int64_t i = 0; i < l->len; i++) { if (i) bput(&b, S(sep)->data, S(sep)->len); V t = vrt_display(l->items[i]); bput(&b, S(t)->data, S(t)->len); }
    return bdone(&b);
}
static V b_replace(int argc, V *a) {
    NEED(3, "replace");
    V s = text_of(a[0]), o = text_of(a[1]), n = text_of(a[2]);
    VStr *x = S(s), *f = S(o), *t = S(n); Buf b = {0};
    bput(&b, "", 0);
    if (f->len == 0) {   /* Python inserts the replacement between every character */
        bput(&b, t->data, t->len);
        for (int64_t i = 0; i < x->len; i++) { bput(&b, x->data + i, 1); if (((unsigned char)x->data[i + 1] & 0xC0) != 0x80) bput(&b, t->data, t->len); }
        return bdone(&b);
    }
    for (int64_t i = 0; i < x->len;) {
        if (i + f->len <= x->len && memcmp(x->data + i, f->data, (size_t)f->len) == 0) { bput(&b, t->data, t->len); i += f->len; }
        else { bput(&b, x->data + i, 1); i++; }
    }
    return bdone(&b);
}
static V b_contains(int argc, V *a) {
    NEED(2, "contains");
    if (a[0].t != VT_LIST && a[0].t != VT_STR && a[0].t != VT_MAP) vrt_fail("contains works on lists, text, or maps");
    return vrt_in(a[1], a[0]);
}
static V b_starts_with(int argc, V *a) { NEED(2, "starts_with"); V s = text_of(a[0]), p = text_of(a[1]); return VB(S(p)->len <= S(s)->len && memcmp(S(s)->data, S(p)->data, (size_t)S(p)->len) == 0); }
static V b_ends_with(int argc, V *a) { NEED(2, "ends_with"); V s = text_of(a[0]), p = text_of(a[1]); return VB(S(p)->len <= S(s)->len && memcmp(S(s)->data + S(s)->len - S(p)->len, S(p)->data, (size_t)S(p)->len) == 0); }
static int64_t char_index(VStr *x, int64_t byteoff) { int64_t n = 0; for (int64_t i = 0; i < byteoff; i++) if (((unsigned char)x->data[i] & 0xC0) != 0x80) n++; return n; }
static int64_t text_find(VStr *x, VStr *n, int last) {
    int64_t found = -1;
    for (int64_t i = 0; i + n->len <= x->len; i++) if (memcmp(x->data + i, n->data, (size_t)n->len) == 0) { found = i; if (!last) break; }
    return found < 0 ? -1 : char_index(x, found);
}
static V b_find(int argc, V *a) { NEED(2, "find"); V s = text_of(a[0]), n = text_of(a[1]); return VI(text_find(S(s), S(n), 0)); }
static V b_index_of(int argc, V *a) {
    NEED(2, "index_of");
    if (a[0].t == VT_STR) { V n = text_of(a[1]); return VI(text_find(S(a[0]), S(n), 0)); }
    if (a[0].t == VT_LIST) { VList *l = AS_LIST(a[0]); for (int64_t i = 0; i < l->len; i++) if (vrt_equal(l->items[i], a[1])) return VI(i); return VI(-1); }
    vrt_fail("index_of works on lists or text");
}
static V b_last_index_of(int argc, V *a) {
    NEED(2, "last_index_of");
    if (a[0].t == VT_STR) { V n = text_of(a[1]); return VI(text_find(S(a[0]), S(n), 1)); }
    if (a[0].t == VT_LIST) { VList *l = AS_LIST(a[0]); for (int64_t i = l->len - 1; i >= 0; i--) if (vrt_equal(l->items[i], a[1])) return VI(i); return VI(-1); }
    vrt_fail("last_index_of works on lists or text");
}
static V pad(int argc, V *a, int left, const char *name) {
    if (argc != 2 && argc != 3) vrt_fail("%s expects text, a width, and an optional character", name);
    V s = text_of(a[0]); int64_t w = int_arg(a[1], name);
    char fill[8] = " ";
    if (argc == 3) { V f = text_of(a[2]); if (S(f)->len) { int64_t n = 1; while (n < S(f)->len && ((unsigned char)S(f)->data[n] & 0xC0) == 0x80) n++; memcpy(fill, S(f)->data, (size_t)n); fill[n] = 0; } }
    int64_t need = w - S(s)->nchars; Buf b = {0};
    bput(&b, "", 0);
    if (!left) bput(&b, S(s)->data, S(s)->len);
    for (int64_t i = 0; i < need; i++) bputs(&b, fill);
    if (left) bput(&b, S(s)->data, S(s)->len);
    return bdone(&b);
}
static V b_pad_left(int argc, V *a) { return pad(argc, a, 1, "pad_left"); }
static V b_pad_right(int argc, V *a) { return pad(argc, a, 0, "pad_right"); }
static V b_repeat_text(int argc, V *a) {
    NEED(2, "repeat_text");
    int64_t n = int_arg(a[1], "repeat_text");
    if (n < 0) vrt_fail("repeat_text needs a count of 0 or more");
    return vrt_arith('*', text_of(a[0]), VI(n));
}
static V b_chr(int argc, V *a) {
    NEED(1, "chr");
    int64_t n = int_arg(a[0], "chr");
    if (n < 0 || n > 0x10FFFF) vrt_fail("chr needs a number from 0 to 1114111");
    char u[5]; int len;
    if (n < 0x80) { u[0] = (char)n; len = 1; }
    else if (n < 0x800) { u[0] = (char)(0xC0 | (n >> 6)); u[1] = (char)(0x80 | (n & 63)); len = 2; }
    else if (n < 0x10000) { u[0] = (char)(0xE0 | (n >> 12)); u[1] = (char)(0x80 | ((n >> 6) & 63)); u[2] = (char)(0x80 | (n & 63)); len = 3; }
    else { u[0] = (char)(0xF0 | (n >> 18)); u[1] = (char)(0x80 | ((n >> 12) & 63)); u[2] = (char)(0x80 | ((n >> 6) & 63)); u[3] = (char)(0x80 | (n & 63)); len = 4; }
    return vrt_str(u, len);
}
static V b_code(int argc, V *a) {
    NEED(1, "code");
    V s = text_of(a[0]); const unsigned char *p = (const unsigned char *)S(s)->data;
    if (!S(s)->len) vrt_fail("code needs a non-empty text value");
    if (p[0] < 0x80) return VI(p[0]);
    if ((p[0] & 0xE0) == 0xC0) return VI(((p[0] & 31) << 6) | (p[1] & 63));
    if ((p[0] & 0xF0) == 0xE0) return VI(((p[0] & 15) << 12) | ((p[1] & 63) << 6) | (p[2] & 63));
    return VI(((p[0] & 7) << 18) | ((p[1] & 63) << 12) | ((p[2] & 63) << 6) | (p[3] & 63));
}
static V b_format_number(int argc, V *a) {
    if (argc != 1 && argc != 2) vrt_fail("format_number expects a number and an optional digit count");
    double v = num_arg(a[0], "format_number");
    int64_t d = argc == 2 ? int_arg(a[1], "format_number") : 0;
    if (d < 0) vrt_fail("format_number needs a digit count of 0 or more");
    char raw[128]; snprintf(raw, sizeof raw, "%.*f", (int)d, v);
    char *dot = strchr(raw, '.'); int64_t intlen = dot ? dot - raw : (int64_t)strlen(raw);
    int neg = raw[0] == '-'; Buf b = {0};
    bput(&b, "", 0);
    if (neg) bputs(&b, "-");
    const char *digits = raw + neg; int64_t nd = intlen - neg;
    for (int64_t i = 0; i < nd; i++) { if (i && (nd - i) % 3 == 0) bputs(&b, ","); bput(&b, digits + i, 1); }
    if (dot) bputs(&b, dot);
    return bdone(&b);
}
static V b_reverse(int argc, V *a) {
    NEED(1, "reverse");
    if (a[0].t == VT_LIST) { VList *l = AS_LIST(a[0]); V r = vrt_list(l->len); for (int64_t i = l->len - 1; i >= 0; i--) vrt_list_push(r, l->items[i]); return r; }
    if (a[0].t == VT_STR) {
        VStr *x = S(a[0]); char *p = malloc((size_t)x->len + 1); int64_t w = x->len;
        for (int64_t i = 0; i < x->len;) { int64_t n = 1; while (i + n < x->len && ((unsigned char)x->data[i + n] & 0xC0) == 0x80) n++; w -= n; memcpy(p + w, x->data + i, (size_t)n); i += n; }
        V r = vrt_str(p, x->len); free(p); return r;
    }
    vrt_fail("reverse needs a list or text");
}
static V b_hex_encode(int argc, V *a) {
    NEED(1, "hex_encode");
    V s = text_of(a[0]); Buf b = {0}; char h[3];
    bput(&b, "", 0);
    for (int64_t i = 0; i < S(s)->len; i++) { snprintf(h, 3, "%02x", (unsigned char)S(s)->data[i]); bput(&b, h, 2); }
    return bdone(&b);
}

/* ---------------- lists ---------------- */
static V b_push(int argc, V *a) { NEED(2, "push"); list_arg(a[0], "push needs a list"); vrt_list_push(a[0], a[1]); return VNIL; }
static V b_pop(int argc, V *a) { NEED(1, "pop"); if (a[0].t != VT_LIST || !AS_LIST(a[0])->len) vrt_fail("pop needs a non-empty list"); return AS_LIST(a[0])->items[--AS_LIST(a[0])->len]; }
static V b_insert_at(int argc, V *a) {
    NEED(3, "insert_at"); list_arg(a[0], "insert_at needs a list, a position, and a value");
    VList *l = AS_LIST(a[0]); int64_t i = int_arg(a[1], "insert_at"), n = l->len;
    if (i < 0) { i += n; if (i < 0) i = 0; }
    if (i > n) i = n;
    V r = vrt_list(n + 1);
    for (int64_t k = 0; k < i; k++) vrt_list_push(r, l->items[k]);
    vrt_list_push(r, a[2]);
    for (int64_t k = i; k < n; k++) vrt_list_push(r, l->items[k]);
    return r;
}
static V b_remove_at(int argc, V *a) {
    NEED(2, "remove_at"); list_arg(a[0], "remove_at needs a list");
    VList *l = AS_LIST(a[0]);
    V item = vrt_index(a[0], a[1]);
    int64_t i = a[1].u.i < 0 ? a[1].u.i + l->len : a[1].u.i;
    memmove(l->items + i, l->items + i + 1, (size_t)(l->len - i - 1) * sizeof(V));
    l->len--;
    return item;
}
static V b_first(int argc, V *a) {
    NEED(1, "first");
    if (a[0].t == VT_LIST && AS_LIST(a[0])->len) return AS_LIST(a[0])->items[0];
    if (a[0].t == VT_STR && S(a[0])->len) return vrt_str_index(S(a[0]), 0);
    vrt_fail("first needs a non-empty list or text");
}
static V b_last(int argc, V *a) {
    NEED(1, "last");
    if (a[0].t == VT_LIST && AS_LIST(a[0])->len) return AS_LIST(a[0])->items[AS_LIST(a[0])->len - 1];
    if (a[0].t == VT_STR && S(a[0])->len) return vrt_str_index(S(a[0]), S(a[0])->nchars - 1);
    vrt_fail("last needs a non-empty list or text");
}
static V b_slice(int argc, V *a) {
    NEED(3, "slice");
    if (a[0].t != VT_LIST && a[0].t != VT_STR) vrt_fail("slice needs a list or text");
    int_arg(a[1], "slice"); int_arg(a[2], "slice");
    return vrt_slice(a[0], a[1], a[2]);
}
static int sort_desc = 0;
static int cmp_sort(const void *x, const void *y) {
    V a = *(const V *)x, b = *(const V *)y;
    int bn = (a.t == VT_INT || a.t == VT_FLOAT) && (b.t == VT_INT || b.t == VT_FLOAT), bt = a.t == VT_STR && b.t == VT_STR;
    if (!bn && !bt) vrt_fail("sort needs a list of all numbers or all text");
    int c = vrt_truthy(vrt_compare('<', a, b)) ? -1 : vrt_truthy(vrt_compare('>', a, b)) ? 1 : 0;
    return sort_desc ? -c : c;
}
static void stable_sort(V *items, int64_t n, int (*cmp)(const void *, const void *)) {   /* merge sort: Python's sort is stable */
    if (n < 2) return;
    V *tmp = malloc((size_t)n * sizeof(V));
    for (int64_t w = 1; w < n; w *= 2) {
        for (int64_t i = 0; i < n; i += 2 * w) {
            int64_t m = i + w < n ? i + w : n, e = i + 2 * w < n ? i + 2 * w : n, p = i, q = m, k = i;
            while (p < m && q < e) tmp[k++] = cmp(&items[q], &items[p]) < 0 ? items[q++] : items[p++];
            while (p < m) tmp[k++] = items[p++];
            while (q < e) tmp[k++] = items[q++];
        }
        memcpy(items, tmp, (size_t)n * sizeof(V));
    }
    free(tmp);
}
static V b_sort(int argc, V *a) {
    if (argc != 1 && argc != 2) vrt_fail("sort expects a list (and an optional \"desc\")");
    list_arg(a[0], "sort needs a list");
    sort_desc = 0;
    if (argc == 2) {
        V o = b_lowercase(1, (V[]){a[1]}); const char *s = S(o)->data;
        if (!strcmp(s, "desc") || !strcmp(s, "descending") || !strcmp(s, "reverse")) sort_desc = 1;
        else if (strcmp(s, "asc") && strcmp(s, "ascending")) vrt_fail("sort's second value should be \"asc\" or \"desc\"");
    }
    V r = vrt_list_of((int)AS_LIST(a[0])->len, AS_LIST(a[0])->items);
    if (sort_desc) {   /* Python's reverse=True keeps equal items in their original order */
        int d = sort_desc; sort_desc = 0;
        stable_sort(AS_LIST(r)->items, AS_LIST(r)->len, cmp_sort);
        VList *l = AS_LIST(r);
        for (int64_t i = 0, j = l->len - 1; i < j; i++, j--) { V t = l->items[i]; l->items[i] = l->items[j]; l->items[j] = t; }
        (void)d;
        return r;
    }
    stable_sort(AS_LIST(r)->items, AS_LIST(r)->len, cmp_sort);
    return r;
}
static V call1(V fn, V x) { return vrt_call(fn, 1, &x); }
static V b_sort_by(int argc, V *a) {
    NEED(2, "sort_by");
    if (a[1].t != VT_LIST) vrt_fail("sort_by needs a function and a list");
    VList *l = AS_LIST(a[1]);
    V pairs = vrt_list(l->len); vrt_pin(pairs);
    for (int64_t i = 0; i < l->len; i++) { V p[2] = {call1(a[0], l->items[i]), l->items[i]}; vrt_list_push(pairs, vrt_list_of(2, p)); }
    VList *pl = AS_LIST(pairs);
    V *keys = malloc((size_t)pl->len * sizeof(V));
    for (int64_t i = 0; i < pl->len; i++) keys[i] = pairs.u.o ? AS_LIST(pl->items[i])->items[0] : VNIL;
    /* sort indices by key, stably */
    int64_t n = pl->len;
    V *items = malloc((size_t)n * sizeof(V));
    for (int64_t i = 0; i < n; i++) items[i] = pl->items[i];
    for (int64_t w = 1; w < n; w *= 2) {
        V *tmp = malloc((size_t)n * sizeof(V));
        for (int64_t i = 0; i < n; i += 2 * w) {
            int64_t m = i + w < n ? i + w : n, e = i + 2 * w < n ? i + 2 * w : n, p = i, q = m, k = i;
            while (p < m && q < e) {
                V kq = AS_LIST(items[q])->items[0], kp = AS_LIST(items[p])->items[0];
                int bn = (kq.t == VT_INT || kq.t == VT_FLOAT) && (kp.t == VT_INT || kp.t == VT_FLOAT), bt = kq.t == VT_STR && kp.t == VT_STR;
                if (!bn && !bt) vrt_fail("sort_by's keys must be all numbers or all text");
                tmp[k++] = vrt_truthy(vrt_compare('<', kq, kp)) ? items[q++] : items[p++];
            }
            while (p < m) tmp[k++] = items[p++];
            while (q < e) tmp[k++] = items[q++];
        }
        memcpy(items, tmp, (size_t)n * sizeof(V)); free(tmp);
    }
    V r = vrt_list(n);
    for (int64_t i = 0; i < n; i++) vrt_list_push(r, AS_LIST(items[i])->items[1]);
    free(items); free(keys);
    vrt_unpin(1);
    return r;
}
static V b_unique(int argc, V *a) {
    NEED(1, "unique"); list_arg(a[0], "unique needs a list");
    VList *l = AS_LIST(a[0]); V r = vrt_list(l->len);
    for (int64_t i = 0; i < l->len; i++) if (!vrt_truthy(vrt_in(l->items[i], r))) vrt_list_push(r, l->items[i]);
    return r;
}
static V b_flatten(int argc, V *a) {
    NEED(1, "flatten"); list_arg(a[0], "flatten needs a list");
    VList *l = AS_LIST(a[0]); V r = vrt_list(l->len);
    for (int64_t i = 0; i < l->len; i++) {
        if (l->items[i].t == VT_LIST) { VList *s = AS_LIST(l->items[i]); for (int64_t j = 0; j < s->len; j++) vrt_list_push(r, s->items[j]); }
        else vrt_list_push(r, l->items[i]);
    }
    return r;
}
static V b_range(int argc, V *a) {
    int64_t lo = 0, hi;
    if (argc == 1) hi = int_arg(a[0], "range");
    else if (argc == 2) { lo = int_arg(a[0], "range"); hi = int_arg(a[1], "range"); }
    else vrt_fail("range expects 1 or 2 numbers");
    V r = vrt_list(hi > lo ? hi - lo : 0);
    for (int64_t i = lo; i < hi; i++) vrt_list_push(r, VI(i));
    return r;
}
static V b_zip(int argc, V *a) {
    NEED(2, "zip");
    if (a[0].t != VT_LIST || a[1].t != VT_LIST) vrt_fail("zip needs two lists");
    VList *x = AS_LIST(a[0]), *y = AS_LIST(a[1]); int64_t n = x->len < y->len ? x->len : y->len;
    V r = vrt_list(n);
    for (int64_t i = 0; i < n; i++) { V p[2] = {x->items[i], y->items[i]}; vrt_list_push(r, vrt_list_of(2, p)); }
    return r;
}
static V b_chunk(int argc, V *a) {
    NEED(2, "chunk"); list_arg(a[0], "chunk needs a list and a size");
    int64_t size = int_arg(a[1], "chunk");
    if (size < 1) vrt_fail("chunk needs a size of at least 1");
    VList *l = AS_LIST(a[0]); V r = vrt_list(8);
    for (int64_t i = 0; i < l->len; i += size) vrt_list_push(r, vrt_list_of((int)(i + size < l->len ? size : l->len - i), l->items + i));
    return r;
}
#define HOF(fname, msg) if (argc != 2) vrt_fail(#fname " expects 2 value(s), got %d", argc); if (a[1].t != VT_LIST) vrt_fail(msg); \
    V seq = vrt_list_of((int)AS_LIST(a[1])->len, AS_LIST(a[1])->items); vrt_pin(seq); vrt_pin(a[0]); VList *l = AS_LIST(seq);
static V b_map(int argc, V *a) { HOF(map, "map needs a function and a list") V r = vrt_list(l->len); vrt_pin(r); for (int64_t i = 0; i < l->len; i++) vrt_list_push(r, call1(a[0], l->items[i])); vrt_unpin(3); return r; }
static V b_keep(int argc, V *a) { HOF(keep, "keep needs a function and a list") V r = vrt_list(l->len); vrt_pin(r); for (int64_t i = 0; i < l->len; i++) if (vrt_truthy(call1(a[0], l->items[i]))) vrt_list_push(r, l->items[i]); vrt_unpin(3); return r; }
static V b_each(int argc, V *a) { HOF(each, "each needs a function and a list") for (int64_t i = 0; i < l->len; i++) call1(a[0], l->items[i]); vrt_unpin(2); return VNIL; }
static V b_find_where(int argc, V *a) { HOF(find_where, "find_where needs a function and a list") for (int64_t i = 0; i < l->len; i++) if (vrt_truthy(call1(a[0], l->items[i]))) { V x = l->items[i]; vrt_unpin(2); return x; } vrt_unpin(2); return VNIL; }
static V b_count_where(int argc, V *a) { HOF(count_where, "count_where needs a function and a list") int64_t n = 0; for (int64_t i = 0; i < l->len; i++) if (vrt_truthy(call1(a[0], l->items[i]))) n++; vrt_unpin(2); return VI(n); }
static V b_any_where(int argc, V *a) { HOF(any_where, "any_where needs a function and a list") for (int64_t i = 0; i < l->len; i++) if (vrt_truthy(call1(a[0], l->items[i]))) { vrt_unpin(2); return VTRUE; } vrt_unpin(2); return VFALSE; }
static V b_all_where(int argc, V *a) { HOF(all_where, "all_where needs a function and a list") for (int64_t i = 0; i < l->len; i++) if (!vrt_truthy(call1(a[0], l->items[i]))) { vrt_unpin(2); return VFALSE; } vrt_unpin(2); return VTRUE; }
static V b_reduce(int argc, V *a) {
    NEED(3, "reduce");
    if (a[1].t != VT_LIST) vrt_fail("reduce needs a function, a list, and a starting value");
    V seq = vrt_list_of((int)AS_LIST(a[1])->len, AS_LIST(a[1])->items); vrt_pin(seq); vrt_pin(a[0]);
    V acc = a[2]; VList *l = AS_LIST(seq);
    for (int64_t i = 0; i < l->len; i++) { vrt_pin(acc); V args[2] = {acc, l->items[i]}; acc = vrt_call(a[0], 2, args); vrt_unpin(1); }
    vrt_unpin(2);
    return acc;
}

/* ---------------- maps ---------------- */
static V b_keys(int argc, V *a) { NEED(1, "keys"); map_arg(a[0], "keys needs a map"); return vrt_iter_list(a[0]); }
static V b_values(int argc, V *a) { NEED(1, "values"); map_arg(a[0], "values needs a map"); VMap *m = AS_MAP(a[0]); V r = vrt_list(m->count); for (int64_t i = 0; i < m->nent; i++) if (m->ents[i].used) vrt_list_push(r, m->ents[i].val); return r; }
static V b_entries(int argc, V *a) { NEED(1, "entries"); map_arg(a[0], "entries needs a map"); return vrt_iter_pairs(a[0]); }
static V b_has_key(int argc, V *a) { NEED(2, "has_key"); map_arg(a[0], "has_key needs a map"); return vrt_in(a[1], a[0]); }
static V b_get(int argc, V *a) {
    if (argc != 2 && argc != 3) vrt_fail("get expects a map, a key, and an optional fallback");
    map_arg(a[0], "get needs a map");
    int f = 0; V v = vrt_map_get(a[0], a[1], &f);
    return f ? v : (argc == 3 ? a[2] : VNIL);
}
static V copy_map(V m) { V r = vrt_map(); VMap *x = AS_MAP(m); for (int64_t i = 0; i < x->nent; i++) if (x->ents[i].used) vrt_map_set(r, x->ents[i].key, x->ents[i].val); return r; }
static V b_remove_key(int argc, V *a) { NEED(2, "remove_key"); map_arg(a[0], "remove_key needs a map"); V r = copy_map(a[0]); vrt_map_del(r, a[1]); return r; }
static V b_merge(int argc, V *a) {
    if (argc < 2) vrt_fail("merge needs at least two maps");
    V r = vrt_map();
    for (int i = 0; i < argc; i++) { map_arg(a[i], "merge needs maps"); VMap *x = AS_MAP(a[i]); for (int64_t k = 0; k < x->nent; k++) if (x->ents[k].used) vrt_map_set(r, x->ents[k].key, x->ents[k].val); }
    return r;
}

/* ---------------- bytes ---------------- */
static V b_bytes(int argc, V *a) {
    NEED(1, "bytes");
    V v = a[0];
    if (v.t == VT_INT) { if (v.u.i < 0) vrt_fail("bytes needs a size of 0 or more"); return vrt_bytes(v.u.i); }
    if (v.t == VT_STR) { V r = vrt_bytes(S(v)->len); memcpy(AS_BYTES(r)->data, S(v)->data, (size_t)S(v)->len); return r; }
    if (v.t == VT_BYTES) { V r = vrt_bytes(AS_BYTES(v)->len); memcpy(AS_BYTES(r)->data, AS_BYTES(v)->data, (size_t)AS_BYTES(v)->len); return r; }
    if (v.t == VT_LIST) {
        VList *l = AS_LIST(v); V r = vrt_bytes(l->len);
        for (int64_t i = 0; i < l->len; i++) { V x = l->items[i]; if (x.t != VT_INT || x.u.i < 0 || x.u.i > 255) vrt_fail("bytes needs numbers from 0 to 255"); AS_BYTES(r)->data[i] = (uint8_t)x.u.i; }
        return r;
    }
    vrt_fail("bytes takes a size, a list of numbers, or text");
}
static V read_whole(const char *path, int64_t *len, const char *what) {
    FILE *f = fopen(path, "rb");
    if (!f) vrt_fail("could not %s file: [Errno 2] No such file or directory: '%s'", what, path);
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    V r = vrt_bytes(n);
    if (n > 0 && fread(AS_BYTES(r)->data, 1, (size_t)n, f) != (size_t)n) { fclose(f); vrt_fail("could not %s file: read error", what); }
    fclose(f);
    *len = n;
    return r;
}
static V b_read_binary(int argc, V *a) { NEED(1, "read_binary"); V p = text_of(a[0]); int64_t n; return read_whole(S(p)->data, &n, "read"); }
static V b_read_bytes(int argc, V *a) {
    NEED(1, "read_bytes"); V p = text_of(a[0]); int64_t n;
    V y = read_whole(S(p)->data, &n, "read"); vrt_pin(y);
    V r = vrt_list(n);
    for (int64_t i = 0; i < n; i++) vrt_list_push(r, VI(AS_BYTES(y)->data[i]));
    vrt_unpin(1);
    return r;
}
static V b_write_binary(int argc, V *a) {
    NEED(2, "write_binary");
    V p = text_of(a[0]);
    FILE *f = fopen(S(p)->data, "wb");
    if (!f) vrt_fail("could not write file: %s", S(p)->data);
    if (a[1].t == VT_BYTES) fwrite(AS_BYTES(a[1])->data, 1, (size_t)AS_BYTES(a[1])->len, f);
    else if (a[1].t == VT_LIST) { VList *l = AS_LIST(a[1]); for (int64_t i = 0; i < l->len; i++) fputc((int)l->items[i].u.i, f); }
    fclose(f);
    return VNIL;
}
static void byte_check(int argc, V *a, const char *name, int width, int args) {
    if (argc != args) vrt_fail("%s expects %d value(s), got %d", name, args, argc);
    if (a[0].t != VT_BYTES && a[0].t != VT_LIST) vrt_fail("%s reads from bytes", name);
    int64_t len = a[0].t == VT_BYTES ? AS_BYTES(a[0])->len : AS_LIST(a[0])->len;
    if (a[1].t != VT_INT || a[1].u.i < 0 || a[1].u.i + width > len) { V d = vrt_display(a[1]); vrt_fail("%s: position %s is outside the %lld bytes", name, S(d)->data, (long long)len); }
}
static uint64_t rd(V b, int64_t off, int w) {
    uint64_t v = 0;
    for (int i = w - 1; i >= 0; i--) v = (v << 8) | (b.t == VT_BYTES ? AS_BYTES(b)->data[off + i] : (uint64_t)AS_LIST(b)->items[off + i].u.i);
    return v;
}
static V b_u8(int argc, V *a) { byte_check(argc, a, "u8", 1, 2); return VI((int64_t)rd(a[0], a[1].u.i, 1)); }
static V b_s8(int argc, V *a) { byte_check(argc, a, "s8", 1, 2); return VI((int8_t)rd(a[0], a[1].u.i, 1)); }
static V b_u16(int argc, V *a) { byte_check(argc, a, "u16", 2, 2); return VI((int64_t)rd(a[0], a[1].u.i, 2)); }
static V b_s16(int argc, V *a) { byte_check(argc, a, "s16", 2, 2); return VI((int16_t)rd(a[0], a[1].u.i, 2)); }
static V b_u32(int argc, V *a) { byte_check(argc, a, "u32", 4, 2); return VI((int64_t)rd(a[0], a[1].u.i, 4)); }
static V b_s32(int argc, V *a) { byte_check(argc, a, "s32", 4, 2); return VI((int32_t)rd(a[0], a[1].u.i, 4)); }
static V put(int argc, V *a, const char *name, int w) {
    byte_check(argc, a, name, w, 3);
    if (a[2].t != VT_INT) vrt_fail("%s writes whole numbers", name);
    if (a[0].t != VT_BYTES) vrt_fail("%s writes into bytes", name);
    uint64_t v = (uint64_t)a[2].u.i;
    for (int i = 0; i < w; i++) AS_BYTES(a[0])->data[a[1].u.i + i] = (uint8_t)(v >> (8 * i));
    return VNIL;
}
static V b_put_u8(int argc, V *a) { return put(argc, a, "put_u8", 1); }
static V b_put_u16(int argc, V *a) { return put(argc, a, "put_u16", 2); }
static V b_put_u32(int argc, V *a) { return put(argc, a, "put_u32", 4); }
static V b_band(int argc, V *a) { NEED(2, "band"); return VI(int_arg(a[0], "band") & int_arg(a[1], "band")); }
static V b_bor(int argc, V *a) { NEED(2, "bor"); return VI(int_arg(a[0], "bor") | int_arg(a[1], "bor")); }
static V b_bxor(int argc, V *a) { NEED(2, "bxor"); return VI(int_arg(a[0], "bxor") ^ int_arg(a[1], "bxor")); }
static V b_bnot(int argc, V *a) { NEED(2, "bnot"); int64_t v = int_arg(a[0], "bnot"), bits = int_arg(a[1], "bnot"); return VI(~v & (bits >= 63 ? -1 : (((int64_t)1 << bits) - 1))); }
static V b_shift_left(int argc, V *a) { NEED(2, "shift_left"); return vrt_arith('<', VI(int_arg(a[0], "shift_left")), VI(int_arg(a[1], "shift_left"))); }
static V b_shift_right(int argc, V *a) { NEED(2, "shift_right"); return vrt_arith('>', VI(int_arg(a[0], "shift_right")), VI(int_arg(a[1], "shift_right"))); }

/* ---------------- files, time, system ---------------- */
static V b_read_file(int argc, V *a) {
    NEED(1, "read_file"); V p = text_of(a[0]); int64_t n;
    V y = read_whole(S(p)->data, &n, "read");
    return vrt_str((const char *)AS_BYTES(y)->data, n);
}
static V write_mode(int argc, V *a, const char *mode, const char *name, const char *verb) {
    NEED(2, name);
    V p = text_of(a[0]), s = text_of(a[1]);
    FILE *f = fopen(S(p)->data, mode);
    if (!f) vrt_fail("could not %s file: %s", verb, S(p)->data);
    fwrite(S(s)->data, 1, (size_t)S(s)->len, f);
    fclose(f);
    return VNIL;
}
static V b_write_file(int argc, V *a) { return write_mode(argc, a, "w", "write_file", "write"); }
static V b_append_file(int argc, V *a) { return write_mode(argc, a, "a", "append_file", "append to"); }
static V b_path_exists(int argc, V *a) { NEED(1, "path_exists"); V p = text_of(a[0]); struct stat st; return VB(stat(S(p)->data, &st) == 0); }
static V b_is_file(int argc, V *a) { NEED(1, "is_file"); V p = text_of(a[0]); struct stat st; return VB(stat(S(p)->data, &st) == 0 && S_ISREG(st.st_mode)); }
static V b_is_dir(int argc, V *a) { NEED(1, "is_dir"); V p = text_of(a[0]); struct stat st; return VB(stat(S(p)->data, &st) == 0 && S_ISDIR(st.st_mode)); }
static V b_file_size(int argc, V *a) { NEED(1, "file_size"); V p = text_of(a[0]); struct stat st; if (stat(S(p)->data, &st)) vrt_fail("could not read file size: %s", S(p)->data); return VI((int64_t)st.st_size); }
static V b_now(int argc, V *a) { (void)a; NEED(0, "now"); return VI((int64_t)time(NULL)); }
static V b_now_ms(int argc, V *a) {
    (void)a; NEED(0, "now_ms");
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    return VI((int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}
static V b_clock(int argc, V *a) { (void)a; NEED(0, "clock"); char buf[16]; time_t t = time(NULL); strftime(buf, sizeof buf, "%H:%M:%S", localtime(&t)); return vrt_cstr(buf); }
static V b_sleep(int argc, V *a) {
    NEED(1, "sleep");
    if (a[0].t != VT_INT && a[0].t != VT_FLOAT) vrt_fail("sleep expects a number of seconds");
    double s = num_arg(a[0], "sleep");
    if (s > 0) { struct timespec ts = {(time_t)s, (long)((s - floor(s)) * 1e9)}; nanosleep(&ts, NULL); }
    return VNIL;
}
static V b_assert(int argc, V *a) {
    if (argc != 1 && argc != 2) vrt_fail("assert expects a condition and an optional message");
    if (!vrt_truthy(a[0])) { if (argc == 2) { V m = vrt_display(a[1]); vrt_fail("%s", S(m)->data); } vrt_fail("assertion failed"); }
    return VNIL;
}
static V b_fail(int argc, V *a) { NEED(1, "fail"); V m = vrt_display(a[0]); vrt_fail("%s", S(m)->data); }
static V b_arguments(int argc, V *a) {
    (void)a; NEED(0, "arguments");
    V r = vrt_list(vrt_argc);
    for (int i = 1; i < vrt_argc; i++) vrt_list_push(r, vrt_cstr(vrt_argv[i]));
    return r;
}
static V b_os_name(int argc, V *a) {
    (void)a; NEED(0, "os_name");
#if defined(__APPLE__)
    return vrt_cstr("mac");
#elif defined(_WIN32)
    return vrt_cstr("windows");
#else
    return vrt_cstr("linux");
#endif
}
static V b_env(int argc, V *a) {
    if (argc != 1 && argc != 2) vrt_fail("env expects a name and an optional fallback");
    V n = text_of(a[0]); const char *v = getenv(S(n)->data);
    if (v) return vrt_cstr(v);
    return argc == 2 ? a[1] : VNIL;
}

/* ---------------- JSON ---------------- */
static void json_out(Buf *b, V v) {
    char tmp[64];
    switch (v.t) {
    case VT_NIL: case VT_UNDEF: bputs(b, "null"); return;
    case VT_BOOL: bputs(b, v.u.i ? "true" : "false"); return;
    case VT_INT: snprintf(tmp, sizeof tmp, "%lld", (long long)v.u.i); bputs(b, tmp); return;
    case VT_FLOAT: {
        if (v.u.f == floor(v.u.f) && fabs(v.u.f) < 1e16) { snprintf(tmp, sizeof tmp, "%.1f", v.u.f); bputs(b, tmp); return; }
        V d = vrt_display(v); bputs(b, S(d)->data); return;
    }
    case VT_STR: {
        VStr *s = S(v);
        bputs(b, "\"");
        for (int64_t i = 0; i < s->len;) {
            unsigned char c = (unsigned char)s->data[i];
            if (c == '"') { bputs(b, "\\\""); i++; }
            else if (c == '\\') { bputs(b, "\\\\"); i++; }
            else if (c == '\n') { bputs(b, "\\n"); i++; }
            else if (c == '\r') { bputs(b, "\\r"); i++; }
            else if (c == '\t') { bputs(b, "\\t"); i++; }
            else if (c < 0x20) { snprintf(tmp, sizeof tmp, "\\u%04x", c); bputs(b, tmp); i++; }
            else if (c < 0x80) { bput(b, s->data + i, 1); i++; }
            else {   /* ensure_ascii: \uXXXX, with surrogate pairs above the BMP */
                uint32_t cp; int n;
                if ((c & 0xE0) == 0xC0) { cp = c & 31; n = 2; } else if ((c & 0xF0) == 0xE0) { cp = c & 15; n = 3; } else { cp = c & 7; n = 4; }
                for (int k = 1; k < n; k++) cp = (cp << 6) | ((unsigned char)s->data[i + k] & 63);
                if (cp >= 0x10000) { cp -= 0x10000; snprintf(tmp, sizeof tmp, "\\u%04x\\u%04x", 0xD800 + (cp >> 10), 0xDC00 + (cp & 1023)); }
                else snprintf(tmp, sizeof tmp, "\\u%04x", cp);
                bputs(b, tmp);
                i += n;
            }
        }
        bputs(b, "\"");
        return;
    }
    case VT_LIST: { VList *l = AS_LIST(v); bputs(b, "["); for (int64_t i = 0; i < l->len; i++) { if (i) bputs(b, ", "); json_out(b, l->items[i]); } bputs(b, "]"); return; }
    case VT_MAP: {
        VMap *m = AS_MAP(v); int first = 1; bputs(b, "{");
        for (int64_t i = 0; i < m->nent; i++) if (m->ents[i].used) {
            if (!first) bputs(b, ", ");
            first = 0;
            V k = m->ents[i].key;
            if (k.t == VT_STR) json_out(b, k);
            else if (k.t == VT_BOOL) bputs(b, k.u.i ? "\"true\"" : "\"false\"");
            else if (k.t == VT_NIL) bputs(b, "\"null\"");
            else { V d = vrt_display(k); bputs(b, "\""); bputs(b, S(d)->data); bputs(b, "\""); }
            bputs(b, ": ");
            json_out(b, m->ents[i].val);
        }
        bputs(b, "}");
        return;
    }
    default: vrt_fail("that value can't be turned into JSON");
    }
}
static V b_to_json(int argc, V *a) { NEED(1, "to_json"); Buf b = {0}; bput(&b, "", 0); json_out(&b, a[0]); return bdone(&b); }

typedef struct { const char *s; int64_t i, n; } JP;
static void jws(JP *p) { while (p->i < p->n && isspace((unsigned char)p->s[p->i])) p->i++; }
static _Noreturn void jbad(void) { vrt_fail("that text is not valid JSON"); }
static V jval(JP *p);
static void jutf8(Buf *b, uint32_t cp) {
    char u[4]; int n;
    if (cp < 0x80) { u[0] = (char)cp; n = 1; }
    else if (cp < 0x800) { u[0] = (char)(0xC0 | (cp >> 6)); u[1] = (char)(0x80 | (cp & 63)); n = 2; }
    else if (cp < 0x10000) { u[0] = (char)(0xE0 | (cp >> 12)); u[1] = (char)(0x80 | ((cp >> 6) & 63)); u[2] = (char)(0x80 | (cp & 63)); n = 3; }
    else { u[0] = (char)(0xF0 | (cp >> 18)); u[1] = (char)(0x80 | ((cp >> 12) & 63)); u[2] = (char)(0x80 | ((cp >> 6) & 63)); u[3] = (char)(0x80 | (cp & 63)); n = 4; }
    bput(b, u, n);
}
static V jstr(JP *p) {
    Buf b = {0}; bput(&b, "", 0);
    p->i++;
    while (p->i < p->n && p->s[p->i] != '"') {
        char c = p->s[p->i++];
        if (c != '\\') { bput(&b, &c, 1); continue; }
        if (p->i >= p->n) jbad();
        char e = p->s[p->i++];
        switch (e) {
        case 'n': bputs(&b, "\n"); break; case 't': bputs(&b, "\t"); break; case 'r': bputs(&b, "\r"); break;
        case 'b': bputs(&b, "\b"); break; case 'f': bputs(&b, "\f"); break; case '/': bputs(&b, "/"); break;
        case '"': bputs(&b, "\""); break; case '\\': bputs(&b, "\\"); break;
        case 'u': {
            if (p->i + 4 > p->n) jbad();
            char h[5] = {0}; memcpy(h, p->s + p->i, 4); p->i += 4;
            uint32_t cp = (uint32_t)strtoul(h, NULL, 16);
            if (cp >= 0xD800 && cp < 0xDC00 && p->i + 6 <= p->n && p->s[p->i] == '\\' && p->s[p->i + 1] == 'u') {
                char h2[5] = {0}; memcpy(h2, p->s + p->i + 2, 4); uint32_t lo = (uint32_t)strtoul(h2, NULL, 16);
                if (lo >= 0xDC00 && lo < 0xE000) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); p->i += 6; }
            }
            jutf8(&b, cp);
            break;
        }
        default: free(b.p); jbad();
        }
    }
    if (p->i >= p->n) { free(b.p); jbad(); }
    p->i++;
    return bdone(&b);
}
static V jval(JP *p) {
    jws(p);
    if (p->i >= p->n) jbad();
    char c = p->s[p->i];
    if (c == '"') return jstr(p);
    if (c == '{') {
        p->i++; V m = vrt_map(); jws(p);
        if (p->i < p->n && p->s[p->i] == '}') { p->i++; return m; }
        for (;;) {
            jws(p);
            if (p->i >= p->n || p->s[p->i] != '"') jbad();
            V k = jstr(p); jws(p);
            if (p->i >= p->n || p->s[p->i] != ':') jbad();
            p->i++;
            V v = jval(p);
            vrt_map_set(m, k, v);
            jws(p);
            if (p->i < p->n && p->s[p->i] == ',') { p->i++; continue; }
            if (p->i < p->n && p->s[p->i] == '}') { p->i++; return m; }
            jbad();
        }
    }
    if (c == '[') {
        p->i++; V l = vrt_list(4); jws(p);
        if (p->i < p->n && p->s[p->i] == ']') { p->i++; return l; }
        for (;;) {
            vrt_list_push(l, jval(p)); jws(p);
            if (p->i < p->n && p->s[p->i] == ',') { p->i++; continue; }
            if (p->i < p->n && p->s[p->i] == ']') { p->i++; return l; }
            jbad();
        }
    }
    if (!strncmp(p->s + p->i, "true", 4)) { p->i += 4; return VTRUE; }
    if (!strncmp(p->s + p->i, "false", 5)) { p->i += 5; return VFALSE; }
    if (!strncmp(p->s + p->i, "null", 4)) { p->i += 4; return VNIL; }
    char *end; const char *start = p->s + p->i;
    int isfloat = 0;
    for (const char *q = start; *q && (isdigit((unsigned char)*q) || strchr("+-.eE", *q)); q++) if (strchr(".eE", *q)) isfloat = 1;
    if (isfloat) { double d = strtod(start, &end); if (end == start) jbad(); p->i += end - start; return VF(d); }
    long long iv = strtoll(start, &end, 10);
    if (end == start) jbad();
    p->i += end - start;
    return VI(iv);
}
static V b_from_json(int argc, V *a) {
    NEED(1, "from_json");
    V s = text_of(a[0]);
    JP p = {S(s)->data, 0, S(s)->len};
    V v = jval(&p); jws(&p);
    if (p.i != p.n) jbad();
    return v;
}

/* ---------------- registry ---------------- */
typedef struct { const char *name; VBuiltinPtr fn; } Entry;
static const Entry table[] = {
    {"abs", b_abs}, {"ceil", b_ceil}, {"floor", b_floor}, {"clamp", b_clamp}, {"max", b_max}, {"min", b_min}, {"power", b_power},
    {"round", b_round}, {"sign", b_sign}, {"sqrt", b_sqrt}, {"sum", b_sum}, {"product", b_product}, {"random", b_random},
    {"random_float", b_random_float}, {"pick", b_pick}, {"shuffle", b_shuffle}, {"exp", b_exp}, {"sin", b_sin}, {"cos", b_cos},
    {"tan", b_tan}, {"asin", b_asin}, {"acos", b_acos}, {"atan", b_atan}, {"atan2", b_atan2}, {"log", b_log},
    {"length", b_length}, {"text", b_text}, {"number", b_number}, {"type_of", b_type_of}, {"typeof", b_typeof},
    {"is_number", b_is_number}, {"is_text", b_is_text}, {"is_list", b_is_list}, {"is_map", b_is_map}, {"is_bytes", b_is_bytes},
    {"is_function", b_is_function}, {"is_nothing", b_is_nothing}, {"is_a", b_is_a},
    {"lowercase", b_lowercase}, {"uppercase", b_uppercase}, {"capitalize", b_capitalize}, {"title_case", b_title_case},
    {"trim", b_trim}, {"split", b_split}, {"lines", b_lines}, {"join", b_join}, {"replace", b_replace}, {"contains", b_contains},
    {"starts_with", b_starts_with}, {"ends_with", b_ends_with}, {"find", b_find}, {"index_of", b_index_of},
    {"last_index_of", b_last_index_of}, {"pad_left", b_pad_left}, {"pad_right", b_pad_right}, {"repeat_text", b_repeat_text},
    {"chr", b_chr}, {"code", b_code}, {"format_number", b_format_number}, {"reverse", b_reverse}, {"hex_encode", b_hex_encode},
    {"push", b_push}, {"pop", b_pop}, {"insert_at", b_insert_at}, {"remove_at", b_remove_at}, {"first", b_first}, {"last", b_last},
    {"slice", b_slice}, {"sort", b_sort}, {"sort_by", b_sort_by}, {"unique", b_unique}, {"flatten", b_flatten}, {"range", b_range},
    {"zip", b_zip}, {"chunk", b_chunk}, {"map", b_map}, {"keep", b_keep}, {"reduce", b_reduce}, {"each", b_each},
    {"find_where", b_find_where}, {"count_where", b_count_where}, {"any_where", b_any_where}, {"all_where", b_all_where},
    {"keys", b_keys}, {"values", b_values}, {"entries", b_entries}, {"has_key", b_has_key}, {"get", b_get},
    {"remove_key", b_remove_key}, {"merge", b_merge},
    {"bytes", b_bytes}, {"read_binary", b_read_binary}, {"read_bytes", b_read_bytes}, {"write_binary", b_write_binary},
    {"write_bytes", b_write_binary}, {"u8", b_u8}, {"s8", b_s8}, {"u16", b_u16}, {"s16", b_s16}, {"u32", b_u32}, {"s32", b_s32},
    {"put_u8", b_put_u8}, {"put_u16", b_put_u16}, {"put_u32", b_put_u32}, {"band", b_band}, {"bor", b_bor}, {"bxor", b_bxor},
    {"bnot", b_bnot}, {"shift_left", b_shift_left}, {"shift_right", b_shift_right},
    {"read_file", b_read_file}, {"write_file", b_write_file}, {"append_file", b_append_file}, {"path_exists", b_path_exists},
    {"is_file", b_is_file}, {"is_dir", b_is_dir}, {"file_size", b_file_size}, {"now", b_now}, {"now_ms", b_now_ms},
    {"clock", b_clock}, {"sleep", b_sleep}, {"assert", b_assert}, {"fail", b_fail}, {"arguments", b_arguments},
    {"os_name", b_os_name}, {"env", b_env}, {"to_json", b_to_json}, {"from_json", b_from_json},
    {NULL, NULL}
};

V vrt_builtin_named(const char *name) {
    for (const Entry *e = table; e->name; e++) if (!strcmp(e->name, name)) return vrt_builtin(e->name, e->fn);
    return VUNDEF;
}
/* The compiler asks which names exist (so a program using one that isn't here gets a clear message). */
const char *vrt_builtin_list(int i) { return table[i].name; }
