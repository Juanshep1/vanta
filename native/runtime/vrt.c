/* Vanta native runtime: memory, values, operators, calls, errors. See vrt.h. */
#include "vrt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>

int vrt_line = 0;
int vrt_argc = 0;
char **vrt_argv = NULL;
VTry *vrt_try = NULL;
char vrt_errmsg[1024];
static int vrt_errline = 0;
VEnv *vrt_globals = NULL;

/* =====================================================================================================
 * Errors
 * ===================================================================================================== */

_Noreturn void vrt_fail(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(vrt_errmsg, sizeof vrt_errmsg, fmt, ap);
    va_end(ap);
    vrt_errline = vrt_line;
    if (vrt_try) {
        VTry *t = vrt_try;
        vrt_try = t->prev;
        vrt_roots_restore(t->roots);
        longjmp(t->jb, 1);
    }
    fflush(stdout);
    printf("Oops! line %d: %s\n", vrt_errline, vrt_errmsg);
    fflush(stdout);
    exit(1);
}

void vrt_try_push(VTry *t) { t->prev = vrt_try; t->roots = vrt_roots_top(); vrt_try = t; }
void vrt_try_pop(void) { if (vrt_try) vrt_try = vrt_try->prev; }
V vrt_caught(void) { return vrt_cstr(vrt_errmsg); }

_Noreturn void vrt_unknown(const char *name) { vrt_fail("I don't know what '%s' is yet", name); }
_Noreturn void vrt_no_var(const char *name) { vrt_fail("'%s' doesn't exist yet (use: let %s be ...)", name, name); }
_Noreturn void vrt_fixed(const char *name) { vrt_fail("'%s' is fixed and can't be changed", name); }
_Noreturn void vrt_missing_arg(const char *f, const char *p) { vrt_fail("'%s' is missing a value for '%s'", f, p); }
void vrt_bind_check(const char *fname, int argc, int nparams) {
    if (argc > nparams) vrt_fail("'%s' takes at most %d value(s), but got %d", fname, nparams, argc);
}

/* =====================================================================================================
 * Memory: a precise mark-and-sweep collector. Allocation never collects; vrt_safepoint() does, when enough has
 * been allocated since the last collection. Roots: the scope stack, pinned values, and the globals.
 * ===================================================================================================== */

static VObj *heap = NULL;
static size_t allocated = 0, threshold = 8 << 20;
static VEnv **roots = NULL;
static int nroots = 0, caproots = 0;
static V *pins = NULL;
static int npins = 0, cappins = 0;

void *vrt_alloc(uint8_t type, size_t size) {
    VObj *o = calloc(1, size);
    if (!o) { fprintf(stderr, "Vanta: out of memory\n"); exit(2); }
    o->type = type;
    o->next = heap;
    heap = o;
    allocated += size;
    return o;
}

void vrt_root_push(VEnv *e) {
    if (nroots == caproots) { caproots = caproots ? caproots * 2 : 1024; roots = realloc(roots, caproots * sizeof *roots); }
    roots[nroots++] = e;
}
void vrt_root_pop(void) { nroots--; }
int vrt_roots_top(void) { return nroots * 0x10000 + npins; }
void vrt_roots_restore(int top) { nroots = top / 0x10000; npins = top % 0x10000; }
void vrt_pin(V v) {
    if (npins == cappins) { cappins = cappins ? cappins * 2 : 256; pins = realloc(pins, cappins * sizeof *pins); }
    pins[npins++] = v;
}
void vrt_unpin(int n) { npins -= n; }

VEnv *vrt_env(VEnv *parent, int n) {
    VEnv *e = vrt_alloc(VT_ENV, sizeof(VEnv) + (size_t)n * sizeof(V));
    e->parent = parent;
    e->n = n;
    return e;   /* calloc: every slot starts as VT_UNDEF */
}

static VObj **mstack = NULL;
static int64_t msp = 0, mcap = 0;
static void mark_obj(VObj *o) {
    if (!o || o->mark) return;
    o->mark = 1;
    if (msp == mcap) { mcap = mcap ? mcap * 2 : 4096; mstack = realloc(mstack, mcap * sizeof *mstack); }
    mstack[msp++] = o;
}
static inline void mark_v(V v) { if (v.t >= VT_STR && v.t != VT_PTR && v.u.o) mark_obj(v.u.o); }

static void trace(VObj *o) {
    switch (o->type) {
    case VT_LIST: { VList *l = (VList *)o; for (int64_t i = 0; i < l->len; i++) mark_v(l->items[i]); break; }
    case VT_MAP: { VMap *m = (VMap *)o; for (int64_t i = 0; i < m->nent; i++) if (m->ents[i].used) { mark_v(m->ents[i].key); mark_v(m->ents[i].val); } break; }
    case VT_ENV: { VEnv *e = (VEnv *)o; if (e->parent) mark_obj(&e->parent->h); for (int i = 0; i < e->n; i++) mark_v(e->s[i]); break; }
    case VT_FUNC: { VFunc *f = (VFunc *)o; if (f->env) mark_obj(&f->env->h); if (f->owner) mark_obj(&f->owner->h); break; }
    case VT_TYPE: { VType *t = (VType *)o; if (t->parent) mark_obj(&t->parent->h); if (t->fields) mark_obj(&t->fields->h); if (t->methods) mark_obj(&t->methods->h); break; }
    case VT_OBJ: { VInst *i = (VInst *)o; mark_obj(&i->type->h); mark_obj(&i->attrs->h); break; }
    case VT_BOUND: { VBound *b = (VBound *)o; mark_v(b->inst); mark_obj(&b->fn->h); break; }
    case VT_SUPER: { VSuper *s = (VSuper *)o; mark_v(s->inst); if (s->parent) mark_obj(&s->parent->h); break; }
    default: break;
    }
}

static void free_obj(VObj *o) {
    switch (o->type) {
    case VT_LIST: free(((VList *)o)->items); break;
    case VT_MAP: free(((VMap *)o)->ents); free(((VMap *)o)->index); break;
    case VT_BYTES: free(((VBytes *)o)->data); break;
    case VT_ENV: free(((VEnv *)o)->consts); break;
    default: break;
    }
    free(o);
}

static void collect(void) {
    for (int i = 0; i < nroots; i++) mark_obj(&roots[i]->h);
    for (int i = 0; i < npins; i++) mark_v(pins[i]);
    if (vrt_globals) mark_obj(&vrt_globals->h);
    while (msp > 0) trace(mstack[--msp]);
    VObj **p = &heap;
    size_t live = 0;
    while (*p) {
        VObj *o = *p;
        if (o->mark || o->perm) { o->mark = 0; p = &o->next; live++; }
        else { *p = o->next; free_obj(o); }
    }
    allocated = 0;
    (void)live;
}

void vrt_safepoint(void) { if (allocated > threshold) collect(); }

/* =====================================================================================================
 * Text: UTF-8, with the character count kept so indexing and length work in characters like the interpreter.
 * ===================================================================================================== */

static int64_t utf8_count(const char *s, int64_t len, uint8_t *ascii) {
    int64_t n = 0; int a = 1;
    for (int64_t i = 0; i < len; i++) { unsigned char c = (unsigned char)s[i]; if (c >= 0x80) a = 0; if ((c & 0xC0) != 0x80) n++; }
    *ascii = (uint8_t)a;
    return n;
}

V vrt_str(const char *s, int64_t len) {
    VStr *o = vrt_alloc(VT_STR, sizeof(VStr) + (size_t)len + 1);
    memcpy(o->data, s, (size_t)len);
    o->data[len] = 0;
    o->len = len;
    o->nchars = utf8_count(s, len, &o->ascii);
    uint32_t h = 2166136261u;
    for (int64_t i = 0; i < len; i++) { h ^= (unsigned char)s[i]; h *= 16777619u; }
    o->hash = h;
    return VO(VT_STR, o);
}
V vrt_cstr(const char *s) { return vrt_str(s, (int64_t)strlen(s)); }
V vrt_perm_str(const char *s, int64_t len) { V v = vrt_str(s, len); v.u.o->perm = 1; return v; }
const char *vrt_cs(V v) { return v.t == VT_STR ? AS_STR(v)->data : ""; }

static int64_t utf8_offset(VStr *s, int64_t ci) {  /* byte offset of character ci */
    if (s->ascii) return ci;
    int64_t n = 0;
    for (int64_t i = 0; i < s->len; i++) {
        if (((unsigned char)s->data[i] & 0xC0) != 0x80) { if (n == ci) return i; n++; }
    }
    return s->len;
}
V vrt_str_index(VStr *s, int64_t i) {
    int64_t a = utf8_offset(s, i), b = utf8_offset(s, i + 1);
    return vrt_str(s->data + a, b - a);
}

/* A growable C buffer for building text. */
typedef struct { char *p; int64_t len, cap; } Buf;
static void bput(Buf *b, const char *s, int64_t n) {
    if (b->len + n + 1 > b->cap) { b->cap = (b->len + n + 1) * 2 + 64; b->p = realloc(b->p, (size_t)b->cap); }
    memcpy(b->p + b->len, s, (size_t)n);
    b->len += n;
    b->p[b->len] = 0;
}
static void bputs(Buf *b, const char *s) { bput(b, s, (int64_t)strlen(s)); }

/* Numbers print the way Python prints them: whole decimals as whole numbers, others as the shortest repr. */
static void fmt_float(char *out, size_t n, double f) {
    if (isnan(f)) { snprintf(out, n, "nan"); return; }
    if (isinf(f)) { snprintf(out, n, f > 0 ? "inf" : "-inf"); return; }
    if (f == floor(f) && fabs(f) < 1e300) { snprintf(out, n, "%.0f", f); return; }
    for (int p = 1; p <= 17; p++) {
        snprintf(out, n, "%.*g", p, f);
        if (strtod(out, NULL) == f) break;
    }
    /* Python writes 1e-05, C writes 1e-05 too; Python never writes a '+' less than 2 digits: 1e+16 -> same */
}

static void display_into(Buf *b, V v, int quoted, int depth);
static void display_into(Buf *b, V v, int quoted, int depth) {
    char tmp[64];
    if (depth > 60) { bputs(b, "..."); return; }
    switch (v.t) {
    case VT_UNDEF: case VT_NIL: bputs(b, "nothing"); return;
    case VT_BOOL: bputs(b, v.u.i ? "yes" : "no"); return;
    case VT_INT: snprintf(tmp, sizeof tmp, "%lld", (long long)v.u.i); bputs(b, tmp); return;
    case VT_FLOAT: fmt_float(tmp, sizeof tmp, v.u.f); bputs(b, tmp); return;
    case VT_STR:
        if (quoted) bputs(b, "\"");
        bput(b, AS_STR(v)->data, AS_STR(v)->len);
        if (quoted) bputs(b, "\"");
        return;
    case VT_LIST: {
        VList *l = AS_LIST(v);
        bputs(b, "[");
        for (int64_t i = 0; i < l->len; i++) { if (i) bputs(b, ", "); display_into(b, l->items[i], 1, depth + 1); }
        bputs(b, "]");
        return;
    }
    case VT_MAP: {
        VMap *m = AS_MAP(v); int first = 1;
        bputs(b, "{");
        for (int64_t i = 0; i < m->nent; i++) if (m->ents[i].used) {
            if (!first) bputs(b, ", ");
            first = 0;
            display_into(b, m->ents[i].key, 1, depth + 1); bputs(b, ": "); display_into(b, m->ents[i].val, 1, depth + 1);
        }
        bputs(b, "}");
        return;
    }
    case VT_BYTES: {
        VBytes *y = AS_BYTES(v);
        bputs(b, "bytes[");
        for (int64_t i = 0; i < y->len && i < 32; i++) { snprintf(tmp, sizeof tmp, i ? " %02x" : "%02x", y->data[i]); bputs(b, tmp); }
        if (y->len > 32) bputs(b, " …");
        bputs(b, "]");
        return;
    }
    case VT_FUNC: bputs(b, "<function "); bputs(b, ((VFunc *)v.u.o)->name); bputs(b, ">"); return;
    case VT_BUILTIN: bputs(b, "<builtin "); bputs(b, ((VBuiltin *)v.u.o)->name); bputs(b, ">"); return;
    case VT_BOUND: bputs(b, "<method "); bputs(b, ((VBound *)v.u.o)->fn->name); bputs(b, ">"); return;
    case VT_TYPE: bputs(b, "<type "); bputs(b, ((VType *)v.u.o)->name); bputs(b, ">"); return;
    case VT_OBJ: {
        VInst *in = AS_INST(v);
        int found = 0;
        V show = vrt_map_get(VO(VT_MAP, in->type->methods), vrt_cstr("show"), &found);
        if (found) {
            V r = ((VFunc *)show.u.o)->fn(((VFunc *)show.u.o)->env, 0, NULL, v, VNIL);
            display_into(b, r, 0, depth + 1);
            return;
        }
        bputs(b, in->type->name); bputs(b, "(");
        VList *fl = in->type->fields;
        for (int64_t i = 0; i < fl->len; i++) {
            if (i) bputs(b, ", ");
            bput(b, AS_STR(fl->items[i])->data, AS_STR(fl->items[i])->len); bputs(b, "=");
            int f2 = 0; V fv = vrt_map_get(VO(VT_MAP, in->attrs), fl->items[i], &f2);
            display_into(b, f2 ? fv : VNIL, 1, depth + 1);
        }
        bputs(b, ")");
        return;
    }
    default: bputs(b, "value"); return;
    }
}

V vrt_display(V v) {
    if (v.t == VT_STR) return v;
    Buf b = {0};
    display_into(&b, v, 0, 0);
    V s = vrt_str(b.p ? b.p : "", b.len);
    free(b.p);
    return s;
}
V vrt_display_item(V v) {
    Buf b = {0};
    display_into(&b, v, 1, 0);
    V s = vrt_str(b.p ? b.p : "", b.len);
    free(b.p);
    return s;
}
V vrt_format(int n, V *parts) {
    Buf b = {0};
    for (int i = 0; i < n; i++) display_into(&b, parts[i], 0, 0);
    V s = vrt_str(b.p ? b.p : "", b.len);
    free(b.p);
    return s;
}
void vrt_say(V v) {
    if (v.t == VT_UNDEF) { fputs("\n", stdout); return; }
    V s = vrt_display(v);
    fwrite(AS_STR(s)->data, 1, (size_t)AS_STR(s)->len, stdout);
    fputc('\n', stdout);
}

/* =====================================================================================================
 * Lists, maps, bytes
 * ===================================================================================================== */

V vrt_list(int64_t cap) {
    VList *l = vrt_alloc(VT_LIST, sizeof(VList));
    l->cap = cap > 4 ? cap : 4;
    l->items = malloc((size_t)l->cap * sizeof(V));
    allocated += (size_t)l->cap * sizeof(V);
    return VO(VT_LIST, l);
}
void vrt_list_push(V list, V item) {
    VList *l = AS_LIST(list);
    if (l->len == l->cap) { l->cap *= 2; l->items = realloc(l->items, (size_t)l->cap * sizeof(V)); allocated += (size_t)l->cap * sizeof(V) / 2; }
    l->items[l->len++] = item;
}
V vrt_list_of(int n, V *items) {
    V l = vrt_list(n);
    for (int i = 0; i < n; i++) vrt_list_push(l, items[i]);
    return l;
}

static uint32_t hash_v(V k) {
    switch (k.t) {
    case VT_NIL: return 0x9e3779b9u;
    case VT_BOOL: case VT_INT: { uint64_t x = (uint64_t)k.u.i; x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33; return (uint32_t)x; }
    case VT_FLOAT: if (k.u.f == floor(k.u.f) && fabs(k.u.f) < 9e18) return hash_v(VI((int64_t)k.u.f)); { uint64_t x; memcpy(&x, &k.u.f, 8); x ^= x >> 31; return (uint32_t)(x * 0x9E3779B97F4A7C15ULL >> 32); }
    case VT_STR: return AS_STR(k)->hash;
    case VT_LIST: vrt_fail("a list can't be a map key");
    case VT_MAP: vrt_fail("a map can't be a map key");
    case VT_BYTES: vrt_fail("bytes can't be a map key");
    default: return (uint32_t)((uintptr_t)k.u.o >> 4);
    }
}

V vrt_map(void) {
    VMap *m = vrt_alloc(VT_MAP, sizeof(VMap));
    return VO(VT_MAP, m);
}
static void map_reindex(VMap *m, int64_t icap) {
    free(m->index);
    m->icap = icap;
    m->index = malloc((size_t)icap * sizeof(int32_t));
    for (int64_t i = 0; i < icap; i++) m->index[i] = -1;
    for (int64_t i = 0; i < m->nent; i++) if (m->ents[i].used) {
        int64_t j = m->ents[i].hash & (icap - 1);
        while (m->index[j] >= 0) j = (j + 1) & (icap - 1);
        m->index[j] = (int32_t)i;
    }
}
static int64_t map_find(VMap *m, V key, uint32_t h) {
    if (!m->index) return -1;
    int64_t j = h & (m->icap - 1);
    while (m->index[j] >= 0) {
        VMapEnt *e = &m->ents[m->index[j]];
        if (e->used && e->hash == h && vrt_equal(e->key, key)) return m->index[j];
        j = (j + 1) & (m->icap - 1);
    }
    return -1;
}
V vrt_map_get(V map, V key, int *found) {
    VMap *m = AS_MAP(map);
    int64_t i = map_find(m, key, hash_v(key));
    if (i < 0) { *found = 0; return VNIL; }
    *found = 1;
    return m->ents[i].val;
}
void vrt_map_set(V map, V key, V val) {
    VMap *m = AS_MAP(map);
    uint32_t h = hash_v(key);
    int64_t i = map_find(m, key, h);
    if (i >= 0) { m->ents[i].val = val; return; }
    if (m->nent == m->capent) {
        if (m->count < m->nent) {   /* compact out deleted entries first */
            int64_t w = 0;
            for (int64_t r = 0; r < m->nent; r++) if (m->ents[r].used) m->ents[w++] = m->ents[r];
            m->nent = w;
        }
        if (m->nent == m->capent) { m->capent = m->capent ? m->capent * 2 : 8; m->ents = realloc(m->ents, (size_t)m->capent * sizeof(VMapEnt)); allocated += (size_t)m->capent * sizeof(VMapEnt) / 2; }
        map_reindex(m, m->icap ? m->icap : 16);
    }
    VMapEnt *e = &m->ents[m->nent++];
    e->key = key; e->val = val; e->hash = h; e->used = 1;
    m->count++;
    if (m->nent * 2 >= m->icap) map_reindex(m, m->icap ? m->icap * 2 : 16);
    else {
        int64_t j = h & (m->icap - 1);
        while (m->index[j] >= 0) j = (j + 1) & (m->icap - 1);
        m->index[j] = (int32_t)(m->nent - 1);
    }
}
int vrt_map_del(V map, V key) {
    VMap *m = AS_MAP(map);
    int64_t i = map_find(m, key, hash_v(key));
    if (i < 0) return 0;
    m->ents[i].used = 0;
    m->count--;
    map_reindex(m, m->icap);
    return 1;
}

V vrt_bytes(int64_t len) {
    VBytes *y = vrt_alloc(VT_BYTES, sizeof(VBytes));
    y->len = len;
    y->cap = len > 8 ? len : 8;
    y->data = calloc((size_t)y->cap, 1);
    allocated += (size_t)y->cap;
    return VO(VT_BYTES, y);
}

/* =====================================================================================================
 * Operators
 * ===================================================================================================== */

int vrt_truthy(V v) {
    switch (v.t) {
    case VT_UNDEF: case VT_NIL: return 0;
    case VT_BOOL: case VT_INT: return v.u.i != 0;
    case VT_FLOAT: return v.u.f != 0;
    case VT_STR: return AS_STR(v)->len > 0;
    case VT_LIST: return AS_LIST(v)->len > 0;
    case VT_MAP: return AS_MAP(v)->count > 0;
    case VT_BYTES: return AS_BYTES(v)->len > 0;
    default: return 1;
    }
}

static int is_num(V v) { return v.t == VT_INT || v.t == VT_FLOAT; }
static double num(V v) { return v.t == VT_INT ? (double)v.u.i : v.u.f; }

static V concat_text(V a, V b) {
    V sa = vrt_display(a), sb = vrt_display(b);
    VStr *x = AS_STR(sa), *y = AS_STR(sb);
    VStr *o = vrt_alloc(VT_STR, sizeof(VStr) + (size_t)(x->len + y->len) + 1);
    memcpy(o->data, x->data, (size_t)x->len);
    memcpy(o->data + x->len, y->data, (size_t)y->len);
    o->len = x->len + y->len;
    o->data[o->len] = 0;
    o->nchars = x->nchars + y->nchars;
    o->ascii = x->ascii && y->ascii;
    uint32_t h = 2166136261u;
    for (int64_t i = 0; i < o->len; i++) { h ^= (unsigned char)o->data[i]; h *= 16777619u; }
    o->hash = h;
    return VO(VT_STR, o);
}

static int64_t whole(V v, const char *what) {
    if (v.t == VT_INT) return v.u.i;
    if (v.t == VT_FLOAT && v.u.f == floor(v.u.f)) return (int64_t)v.u.f;
    vrt_fail("I can only do bit math (%s) with whole numbers", what);
}

static const char *opname(int op) {
    switch (op) { case '+': return "+"; case '-': return "-"; case '*': return "*"; case '/': return "/"; case '%': return "%";
    case '^': return "^"; case '&': return "&"; case '|': return "|"; case 'x': return "xor"; case '<': return "<<"; case '>': return ">>"; }
    return "?";
}

static V repeat_value(V seq, int64_t n) {
    if (n < 0) n = 0;
    if (seq.t == VT_STR) {
        VStr *s = AS_STR(seq);
        Buf b = {0};
        bput(&b, "", 0);
        for (int64_t i = 0; i < n; i++) bput(&b, s->data, s->len);
        V r = vrt_str(b.p, b.len); free(b.p); return r;
    }
    VList *l = AS_LIST(seq);
    V r = vrt_list(l->len * n);
    for (int64_t i = 0; i < n; i++) for (int64_t j = 0; j < l->len; j++) vrt_list_push(r, l->items[j]);
    return r;
}

V vrt_arith(int op, V a, V b) {
    if (op == '&' || op == '|' || op == 'x' || op == '<' || op == '>') {
        int64_t x = whole(a, opname(op)), y = whole(b, opname(op));
        switch (op) {
        case '&': return VI(x & y);
        case '|': return VI(x | y);
        case 'x': return VI(x ^ y);
        case '<': if (y < 0) vrt_fail("you can't shift by a negative amount"); return VI(y >= 64 ? 0 : (int64_t)((uint64_t)x << y));
        default: if (y < 0) vrt_fail("you can't shift by a negative amount"); return VI(y >= 64 ? (x < 0 ? -1 : 0) : x >> y);
        }
    }
    if (a.t == VT_INT && b.t == VT_INT) {
        int64_t x = a.u.i, y = b.u.i, r;
        switch (op) {
        case '+': if (!__builtin_add_overflow(x, y, &r)) return VI(r); return VF((double)x + (double)y);
        case '-': if (!__builtin_sub_overflow(x, y, &r)) return VI(r); return VF((double)x - (double)y);
        case '*': if (!__builtin_mul_overflow(x, y, &r)) return VI(r); return VF((double)x * (double)y);
        case '/':
            if (y == 0) vrt_fail("you can't divide by zero");
            if (x % y == 0) return VI(x / y);
            return VF((double)x / (double)y);
        case '%': {
            if (y == 0) vrt_fail("you can't take the remainder with zero");
            int64_t m = x % y;
            if (m != 0 && ((m < 0) != (y < 0))) m += y;
            return VI(m);
        }
        case '^': {
            if (y < 0) return VF(pow((double)x, (double)y));
            int64_t res = 1, base = x; int64_t e = y; int over = 0;
            while (e > 0) {
                if (e & 1) { if (__builtin_mul_overflow(res, base, &res)) { over = 1; break; } }
                e >>= 1;
                if (e && __builtin_mul_overflow(base, base, &base)) { over = 1; break; }
            }
            if (over) return VF(pow((double)x, (double)y));
            return VI(res);
        }
        }
    }
    if (is_num(a) && is_num(b)) {
        double x = num(a), y = num(b);
        switch (op) {
        case '+': return VF(x + y);
        case '-': return VF(x - y);
        case '*': return VF(x * y);
        case '/': {
            if (y == 0) vrt_fail("you can't divide by zero");
            double r = x / y;
            if (r == floor(r) && fabs(r) < 9e18) return VI((int64_t)r);
            return VF(r);
        }
        case '%': {
            if (y == 0) vrt_fail("you can't take the remainder with zero");
            double m = fmod(x, y);
            if (m != 0 && ((m < 0) != (y < 0))) m += y;
            return VF(m);
        }
        case '^': return VF(pow(x, y));
        }
    }
    if (op == '+') {
        if (a.t == VT_LIST && b.t == VT_LIST) {
            VList *x = AS_LIST(a), *y = AS_LIST(b);
            V r = vrt_list(x->len + y->len);
            for (int64_t i = 0; i < x->len; i++) vrt_list_push(r, x->items[i]);
            for (int64_t i = 0; i < y->len; i++) vrt_list_push(r, y->items[i]);
            return r;
        }
        if (a.t == VT_STR || b.t == VT_STR) return concat_text(a, b);
    }
    if (op == '*') {
        if ((a.t == VT_STR || a.t == VT_LIST) && b.t == VT_INT) return repeat_value(a, b.u.i);
        if ((b.t == VT_STR || b.t == VT_LIST) && a.t == VT_INT) return repeat_value(b, a.u.i);
    }
    vrt_fail("I can only do math (%s) with numbers", opname(op));
}

V vrt_neg(V a) {
    if (a.t == VT_INT) return a.u.i == INT64_MIN ? VF(9223372036854775808.0) : VI(-a.u.i);
    if (a.t == VT_FLOAT) return VF(-a.u.f);
    vrt_fail("only numbers can be negative");
}
V vrt_bitnot(V a) {
    if (a.t == VT_INT) return VI(~a.u.i);
    if (a.t == VT_FLOAT && a.u.f == floor(a.u.f)) return VI(~(int64_t)a.u.f);
    vrt_fail("~ only works on whole numbers");
}

V vrt_compare(int op, V a, V b) {
    int c;
    if (is_num(a) && is_num(b)) {
        if (a.t == VT_INT && b.t == VT_INT) c = a.u.i < b.u.i ? -1 : a.u.i > b.u.i;
        else { double x = num(a), y = num(b); c = x < y ? -1 : x > y; }
    } else if (a.t == VT_STR && b.t == VT_STR) {
        VStr *x = AS_STR(a), *y = AS_STR(b);
        int64_t n = x->len < y->len ? x->len : y->len;
        int r = memcmp(x->data, y->data, (size_t)n);
        c = r < 0 ? -1 : r > 0 ? 1 : (x->len < y->len ? -1 : x->len > y->len);
    } else vrt_fail("I can only compare numbers with numbers, or text with text");
    switch (op) { case '<': return VB(c < 0); case '>': return VB(c > 0); case 'l': return VB(c <= 0); default: return VB(c >= 0); }
}

int vrt_equal(V a, V b) {
    int an = a.t == VT_INT || a.t == VT_FLOAT || a.t == VT_BOOL, bn = b.t == VT_INT || b.t == VT_FLOAT || b.t == VT_BOOL;
    if (an && bn) {
        if (a.t != VT_FLOAT && b.t != VT_FLOAT) return a.u.i == b.u.i;
        return num(a.t == VT_BOOL ? VI(a.u.i) : a) == num(b.t == VT_BOOL ? VI(b.u.i) : b);
    }
    if ((a.t == VT_NIL || a.t == VT_UNDEF) && (b.t == VT_NIL || b.t == VT_UNDEF)) return 1;
    if (a.t != b.t) return 0;
    switch (a.t) {
    case VT_STR: return AS_STR(a)->len == AS_STR(b)->len && AS_STR(a)->hash == AS_STR(b)->hash && memcmp(AS_STR(a)->data, AS_STR(b)->data, (size_t)AS_STR(a)->len) == 0;
    case VT_LIST: {
        VList *x = AS_LIST(a), *y = AS_LIST(b);
        if (x == y) return 1;
        if (x->len != y->len) return 0;
        for (int64_t i = 0; i < x->len; i++) if (!vrt_equal(x->items[i], y->items[i])) return 0;
        return 1;
    }
    case VT_MAP: {
        VMap *x = AS_MAP(a), *y = AS_MAP(b);
        if (x == y) return 1;
        if (x->count != y->count) return 0;
        for (int64_t i = 0; i < x->nent; i++) if (x->ents[i].used) {
            int f = 0; V v = vrt_map_get(b, x->ents[i].key, &f);
            if (!f || !vrt_equal(v, x->ents[i].val)) return 0;
        }
        return 1;
    }
    case VT_BYTES: return AS_BYTES(a)->len == AS_BYTES(b)->len && memcmp(AS_BYTES(a)->data, AS_BYTES(b)->data, (size_t)AS_BYTES(a)->len) == 0;
    case VT_BOUND: return ((VBound *)a.u.o)->fn == ((VBound *)b.u.o)->fn && vrt_equal(((VBound *)a.u.o)->inst, ((VBound *)b.u.o)->inst);
    default: return a.u.o == b.u.o;
    }
}

V vrt_in(V item, V coll) {
    if (coll.t == VT_LIST) { VList *l = AS_LIST(coll); for (int64_t i = 0; i < l->len; i++) if (vrt_equal(item, l->items[i])) return VTRUE; return VFALSE; }
    if (coll.t == VT_MAP) { int f = 0; if (item.t == VT_LIST || item.t == VT_MAP) return VFALSE; vrt_map_get(coll, item, &f); return VB(f); }
    if (coll.t == VT_STR) {
        if (item.t != VT_STR) vrt_fail("'in <string>' requires string as left operand");
        VStr *h = AS_STR(coll), *n = AS_STR(item);
        if (n->len == 0) return VTRUE;
        for (int64_t i = 0; i + n->len <= h->len; i++) if (memcmp(h->data + i, n->data, (size_t)n->len) == 0) return VTRUE;
        return VFALSE;
    }
    vrt_fail("'in' needs a list, text, or map on the right side");
}

V vrt_isa(V a, V type) {
    if (type.t != VT_TYPE) vrt_fail("the right side of 'is a' must be a type");
    if (a.t != VT_OBJ) return VFALSE;
    for (VType *t = AS_INST(a)->type; t; t = t->parent) if (t == (VType *)type.u.o) return VTRUE;
    return VFALSE;
}

static int64_t whole_index(V idx, int64_t len) {
    if (idx.t != VT_INT) vrt_fail("a position must be a whole number");
    int64_t i = idx.u.i, r = i < 0 ? i + len : i;
    if (r < 0 || r >= len) vrt_fail("position %lld is outside the range -%lld..%lld", (long long)i, (long long)len, (long long)(len - 1));
    return r;
}

V vrt_index(V coll, V idx) {
    switch (coll.t) {
    case VT_LIST: return AS_LIST(coll)->items[whole_index(idx, AS_LIST(coll)->len)];
    case VT_BYTES: return VI(AS_BYTES(coll)->data[whole_index(idx, AS_BYTES(coll)->len)]);
    case VT_STR: return vrt_str_index(AS_STR(coll), whole_index(idx, AS_STR(coll)->nchars));
    case VT_MAP: {
        int f = 0; V v = vrt_map_get(coll, idx, &f);
        if (!f) { V d = vrt_display_item(idx); vrt_fail("this map has no key %s", AS_STR(d)->data); }
        return v;
    }
    default: vrt_fail("you can only look inside a list, text, or map");
    }
}

void vrt_set_index(V coll, V idx, V val) {
    switch (coll.t) {
    case VT_LIST: AS_LIST(coll)->items[whole_index(idx, AS_LIST(coll)->len)] = val; return;
    case VT_MAP: vrt_map_set(coll, idx, val); return;
    case VT_BYTES:
        if (val.t != VT_INT || val.u.i < 0 || val.u.i > 255) vrt_fail("a byte must be a whole number from 0 to 255");
        AS_BYTES(coll)->data[whole_index(idx, AS_BYTES(coll)->len)] = (uint8_t)val.u.i;
        return;
    default: vrt_fail("you can only change a position inside a list or map");
    }
}

static void slice_bounds(V start, V end, int64_t len, int64_t *a, int64_t *b) {
    if ((start.t != VT_UNDEF && start.t != VT_INT) || (end.t != VT_UNDEF && end.t != VT_INT)) vrt_fail("slice positions must be whole numbers");
    int64_t s = start.t == VT_INT ? start.u.i : 0, e = end.t == VT_INT ? end.u.i : len;
    if (s < 0) s += len;
    if (e < 0) e += len;
    if (s < 0) s = 0;
    if (e > len) e = len;
    if (s > len) s = len;
    if (e < s) e = s;
    *a = s; *b = e;
}
V vrt_slice(V t, V start, V end) {
    int64_t a, b;
    if (t.t == VT_LIST) {
        slice_bounds(start, end, AS_LIST(t)->len, &a, &b);
        return vrt_list_of((int)(b - a), AS_LIST(t)->items + a);
    }
    if (t.t == VT_BYTES) {
        slice_bounds(start, end, AS_BYTES(t)->len, &a, &b);
        V r = vrt_bytes(b - a);
        memcpy(AS_BYTES(r)->data, AS_BYTES(t)->data + a, (size_t)(b - a));
        return r;
    }
    if (t.t == VT_STR) {
        VStr *s = AS_STR(t);
        slice_bounds(start, end, s->nchars, &a, &b);
        int64_t x = utf8_offset(s, a), y = utf8_offset(s, b);
        return vrt_str(s->data + x, y - x);
    }
    vrt_fail("you can only slice a list, text, or bytes");
}

V vrt_getattr(V obj, V name) {
    if (obj.t == VT_SUPER) {
        VSuper *s = (VSuper *)obj.u.o;
        if (!s->parent) vrt_fail("there is no parent type to reach with 'super'");
        int f = 0; V m = vrt_map_get(VO(VT_MAP, s->parent->methods), name, &f);
        if (!f) vrt_fail("the parent type has no '%s'", vrt_cs(name));
        VBound *b = vrt_alloc(VT_BOUND, sizeof(VBound)); b->inst = s->inst; b->fn = (VFunc *)m.u.o;
        return VO(VT_BOUND, b);
    }
    if (obj.t == VT_OBJ) {
        VInst *in = AS_INST(obj);
        int f = 0; V v = vrt_map_get(VO(VT_MAP, in->attrs), name, &f);
        if (f) return v;
        V m = vrt_map_get(VO(VT_MAP, in->type->methods), name, &f);
        if (f) { VBound *b = vrt_alloc(VT_BOUND, sizeof(VBound)); b->inst = obj; b->fn = (VFunc *)m.u.o; return VO(VT_BOUND, b); }
        vrt_fail("a %s has no '%s'", in->type->name, vrt_cs(name));
    }
    vrt_fail("you can only use '.' on an object made from a type");
}
void vrt_setattr(V obj, V name, V val) {
    if (obj.t == VT_OBJ) { vrt_map_set(VO(VT_MAP, AS_INST(obj)->attrs), name, val); return; }
    vrt_fail("you can only set a '.' field on an object made from a type");
}

V vrt_iter_list(V v) {
    switch (v.t) {
    case VT_LIST: return vrt_list_of((int)AS_LIST(v)->len, AS_LIST(v)->items);
    case VT_STR: { VStr *s = AS_STR(v); V r = vrt_list(s->nchars); for (int64_t i = 0; i < s->nchars; i++) vrt_list_push(r, vrt_str_index(s, i)); return r; }
    case VT_MAP: { VMap *m = AS_MAP(v); V r = vrt_list(m->count); for (int64_t i = 0; i < m->nent; i++) if (m->ents[i].used) vrt_list_push(r, m->ents[i].key); return r; }
    case VT_BYTES: { VBytes *y = AS_BYTES(v); V r = vrt_list(y->len); for (int64_t i = 0; i < y->len; i++) vrt_list_push(r, VI(y->data[i])); return r; }
    default: vrt_fail("you can only loop over a list, text, map, or bytes");
    }
}
V vrt_iter_pairs(V v) {
    V r;
    if (v.t == VT_MAP) {
        VMap *m = AS_MAP(v); r = vrt_list(m->count);
        for (int64_t i = 0; i < m->nent; i++) if (m->ents[i].used) { V p[2] = {m->ents[i].key, m->ents[i].val}; vrt_list_push(r, vrt_list_of(2, p)); }
        return r;
    }
    if (v.t == VT_LIST || v.t == VT_STR) {
        V items = vrt_iter_list(v);
        VList *l = AS_LIST(items); r = vrt_list(l->len);
        for (int64_t i = 0; i < l->len; i++) { V p[2] = {VI(i), l->items[i]}; vrt_list_push(r, vrt_list_of(2, p)); }
        return r;
    }
    vrt_fail("looping with two names needs a map, list, or text");
}

V vrt_unpack(V v, int count) {
    if (v.t != VT_LIST) vrt_fail("to unpack into several names, the value must be a list");
    if (AS_LIST(v)->len != count) vrt_fail("expected %d values but the list has %lld", count, (long long)AS_LIST(v)->len);
    return v;
}

/* =====================================================================================================
 * Functions, types, calls
 * ===================================================================================================== */

V vrt_func(const char *name, VFnPtr fn, VEnv *env) {
    VFunc *f = vrt_alloc(VT_FUNC, sizeof(VFunc));
    f->name = name; f->fn = fn; f->env = env;
    return VO(VT_FUNC, f);
}
V vrt_builtin(const char *name, VBuiltinPtr fn) {
    VBuiltin *b = vrt_alloc(VT_BUILTIN, sizeof(VBuiltin));
    b->name = name; b->fn = fn; b->h.perm = 1;
    return VO(VT_BUILTIN, b);
}

V vrt_type(const char *name, V parent, int nfields, const char **fields, int nmethods, const char **mnames, V *methods) {
    VType *t = vrt_alloc(VT_TYPE, sizeof(VType));
    t->name = name;
    V fl = vrt_list(8), ms = vrt_map();
    if (parent.t != VT_UNDEF && parent.t != VT_NIL) {
        if (parent.t != VT_TYPE) vrt_fail("that parent is not a type to inherit from");
        VType *p = (VType *)parent.u.o;
        t->parent = p;
        for (int64_t i = 0; i < p->fields->len; i++) vrt_list_push(fl, p->fields->items[i]);
        for (int64_t i = 0; i < p->methods->nent; i++) if (p->methods->ents[i].used) vrt_map_set(ms, p->methods->ents[i].key, p->methods->ents[i].val);
    }
    for (int i = 0; i < nfields; i++) {
        V f = vrt_cstr(fields[i]);
        if (!vrt_truthy(vrt_in(f, fl))) vrt_list_push(fl, f);
    }
    t->fields = AS_LIST(fl);
    t->methods = AS_MAP(ms);
    for (int i = 0; i < nmethods; i++) {
        ((VFunc *)methods[i].u.o)->owner = t;
        vrt_map_set(ms, vrt_cstr(mnames[i]), methods[i]);
    }
    return VO(VT_TYPE, t);
}

static V call_method(V inst, VFunc *fn, int argc, V *argv) {
    VSuper *s = vrt_alloc(VT_SUPER, sizeof(VSuper));
    s->inst = inst;
    s->parent = fn->owner ? fn->owner->parent : NULL;
    return fn->fn(fn->env, argc, argv, inst, VO(VT_SUPER, s));
}

V vrt_call(V callee, int argc, V *argv) {
    switch (callee.t) {
    case VT_FUNC: { VFunc *f = (VFunc *)callee.u.o; return f->fn(f->env, argc, argv, VNIL, VNIL); }
    case VT_BUILTIN: return ((VBuiltin *)callee.u.o)->fn(argc, argv);
    case VT_BOUND: { VBound *b = (VBound *)callee.u.o; return call_method(b->inst, b->fn, argc, argv); }
    case VT_TYPE: {
        VType *t = (VType *)callee.u.o;
        VInst *in = vrt_alloc(VT_OBJ, sizeof(VInst));
        in->type = t;
        V attrs = vrt_map();
        in->attrs = AS_MAP(attrs);
        V obj = VO(VT_OBJ, in);
        for (int64_t i = 0; i < t->fields->len; i++) vrt_map_set(attrs, t->fields->items[i], VNIL);
        int f = 0; V setup = vrt_map_get(VO(VT_MAP, t->methods), vrt_cstr("setup"), &f);
        if (f) {
            vrt_pin(obj);
            call_method(obj, (VFunc *)setup.u.o, argc, argv);
            vrt_unpin(1);
        } else if (argc == t->fields->len) {
            for (int i = 0; i < argc; i++) vrt_map_set(attrs, t->fields->items[i], argv[i]);
        } else {
            Buf b = {0};
            for (int64_t i = 0; i < t->fields->len; i++) { if (i) bputs(&b, ", "); bputs(&b, AS_STR(t->fields->items[i])->data); }
            char msg[512];
            snprintf(msg, sizeof msg, "%s expects %lld value(s) (%s), but got %d", t->name, (long long)t->fields->len, b.p ? b.p : "", argc);
            free(b.p);
            vrt_fail("%s", msg);
        }
        return obj;
    }
    default: vrt_fail("that value is not a function you can call");
    }
}

V vrt_ask(V prompt) {
    if (prompt.t != VT_UNDEF) { V s = vrt_display(prompt); if (AS_STR(s)->len) { fputs(AS_STR(s)->data, stdout); fputc(' ', stdout); } }
    fflush(stdout);
    char line[4096];
    if (!fgets(line, sizeof line, stdin)) { fflush(stdout); exit(1); }   /* no more input: the interpreter stops here too */
    size_t n = strlen(line);
    while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
    char *end;
    long long iv = strtoll(line, &end, 10);
    if (n && *end == 0) return VI(iv);
    double dv = strtod(line, &end);
    if (n && *end == 0) return VF(dv);
    return vrt_str(line, (int64_t)n);
}

void vrt_init(int argc, char **argv) {
    vrt_argc = argc;
    vrt_argv = argv;
    setvbuf(stdout, NULL, _IOFBF, 1 << 16);
}
