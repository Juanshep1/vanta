/* Vanta native runtime, 6.0 core language: sets, generators, module namespaces, kinds (enums), shared (type-level)
 * members, named values in calls, operator methods on objects, `using` blocks, `when` type patterns and {x:spec}
 * formatting. Every message and result matches vanta.py's. Always linked (vantac adds it to every build). */
#include "vrt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <setjmp.h>

typedef VEntry Entry;

/* ---- values the core keeps alive for the whole run (module objects) ---- */
static V *proots = NULL;
static int nproots = 0, capproots = 0;
static void keep_forever(V v) {
    if (nproots == capproots) { capproots = capproots ? capproots * 2 : 16; proots = realloc(proots, (size_t)capproots * sizeof(V)); }
    proots[nproots++] = v;
}
void vrt_core_mark(void) { for (int i = 0; i < nproots; i++) vrt_mark(proots[i]); }

typedef struct { char *p; int64_t len, cap; } Buf;
static void bput(Buf *b, const char *s, int64_t n) {
    if (b->len + n + 1 > b->cap) { b->cap = (b->len + n + 1) * 2 + 64; b->p = realloc(b->p, (size_t)b->cap); }
    memcpy(b->p + b->len, s, (size_t)n); b->len += n; b->p[b->len] = 0;
}
static void bputs(Buf *b, const char *s) { bput(b, s, (int64_t)strlen(s)); }
static V bdone(Buf *b) { V s = vrt_str(b->p ? b->p : "", b->len); free(b->p); return s; }

/* =====================================================================================================
 * Methods on objects
 * ===================================================================================================== */

VFunc *vrt_method_of(V obj, const char *name) {
    if (obj.t != VT_OBJ) return NULL;
    int f = 0;
    V m = vrt_map_get(VO(VT_MAP, AS_INST(obj)->type->methods), vrt_cstr(name), &f);
    return f ? (VFunc *)m.u.o : NULL;
}

static V call_named(V obj, VFunc *fn, int argc, V *argv) {
    vrt_pin(obj);
    for (int i = 0; i < argc; i++) vrt_pin(argv[i]);
    V r = vrt_call_method(obj, fn, argc, argv);
    vrt_unpin(argc + 1);
    return r;
}

static const char *op_method(int op) {
    switch (op) { case '+': return "add"; case '-': return "subtract"; case '*': return "multiply"; case '/': return "divide"; case '%': return "remainder"; }
    return NULL;
}

int vrt_core_arith(int op, V a, V b, V *out) {
    const char *mn = op_method(op);
    if (a.t != VT_OBJ || !mn) return 0;
    VFunc *fn = vrt_method_of(a, mn);
    if (!fn) return 0;
    *out = call_named(a, fn, 1, &b);
    return 1;
}

V vrt_negate_obj(V a) {
    VFunc *fn = vrt_method_of(a, "negate");
    if (!fn) vrt_fail("only numbers can be negative");
    return call_named(a, fn, 0, NULL);
}

int vrt_obj_equal(V a, V b) {             /* both objects, different */
    VFunc *fn = vrt_method_of(a, "equals");
    if (!fn) return 0;
    return vrt_truthy(call_named(a, fn, 1, &b));
}

int vrt_core_less(V a, V b) {
    if (a.t == VT_OBJ) { VFunc *fn = vrt_method_of(a, "less_than"); if (fn) return vrt_truthy(call_named(a, fn, 1, &b)); }
    if (b.t == VT_OBJ) {
        VFunc *fn = vrt_method_of(b, "less_than");
        if (fn) return !vrt_truthy(call_named(b, fn, 1, &a)) && !vrt_equal(b, a);
    }
    vrt_fail("to compare objects with < or >, give their type a less_than(other) method");
}

int vrt_core_compare(int op, V a, V b, V *out) {
    if (a.t == VT_ENUMV && b.t == VT_ENUMV && ((VEnumV *)a.u.o)->e == ((VEnumV *)b.u.o)->e) {
        *out = vrt_compare(op, VI(((VEnumV *)a.u.o)->idx), VI(((VEnumV *)b.u.o)->idx));
        return 1;
    }
    if (a.t != VT_OBJ && b.t != VT_OBJ) return 0;
    int r;
    switch (op) {
    case '<': r = vrt_core_less(a, b); break;
    case '>': r = vrt_core_less(b, a); break;
    case 'l': r = !vrt_core_less(b, a); break;
    default: r = !vrt_core_less(a, b); break;
    }
    *out = VB(r);
    return 1;
}

/* =====================================================================================================
 * Sets: a VMap (keys = the items, values = yes) whose value tag is VT_SET
 * ===================================================================================================== */

V vrt_set_new(void) { V m = vrt_map(); m.t = VT_SET; return m; }

void vrt_set_add(V set, V item) {
    if (item.t == VT_LIST || item.t == VT_MAP || item.t == VT_SET || item.t == VT_BYTES)
        vrt_fail("a %s can't go in a set (only values like numbers, text, yes/no)", vrt_core_tname(item));
    V m = set; m.t = VT_MAP;
    vrt_map_set(m, item, VTRUE);
}

static V set_of(V items) {      /* items: a list */
    V s = vrt_set_new();
    VList *l = AS_LIST(items);
    for (int64_t i = 0; i < l->len; i++) vrt_set_add(s, l->items[i]);
    return s;
}

static V set_items(V set) {     /* the items in the order added, as a list */
    VMap *m = AS_MAP(set);
    V r = vrt_list(m->count);
    for (int64_t i = 0; i < m->nent; i++) if (m->ents[i].used) vrt_list_push(r, m->ents[i].key);
    return r;
}

static int set_has(V set, V item) {
    if (item.t == VT_LIST || item.t == VT_MAP || item.t == VT_SET || item.t == VT_BYTES) return 0;
    V m = set; m.t = VT_MAP;
    int f = 0; vrt_map_get(m, item, &f);
    return f;
}

void vrt_add_to(V item, V target) {
    if (target.t == VT_LIST) { vrt_list_push(target, item); return; }
    if (target.t == VT_SET) { vrt_set_add(target, item); return; }
    vrt_fail("you can only 'add ... to' a list or a set");
}

void vrt_remove(V item, V target) {
    if (target.t == VT_SET) {
        if (!set_has(target, item)) { V d = vrt_display_item(item); vrt_fail("%s is not in the set", vrt_cs(d)); }
        V m = target; m.t = VT_MAP;
        vrt_map_del(m, item);
        return;
    }
    if (target.t == VT_LIST) {
        VList *l = AS_LIST(target);
        for (int64_t i = 0; i < l->len; i++) if (vrt_equal(l->items[i], item)) {
            memmove(l->items + i, l->items + i + 1, (size_t)(l->len - i - 1) * sizeof(V));
            l->len--;
            return;
        }
        V d = vrt_display_item(item); vrt_fail("%s is not in the list", vrt_cs(d));
    }
    if (target.t == VT_MAP) {
        if (item.t == VT_LIST || item.t == VT_MAP || !vrt_map_del(target, item)) {
            V d = vrt_display_item(item); vrt_fail("this map has no key %s", vrt_cs(d));
        }
        return;
    }
    vrt_fail("you can only 'remove ... from' a set, list, or map");
}

static V set_arg(V v, const char *name) {
    if (v.t != VT_SET) vrt_fail("%s needs sets (make one with set([...]))", name);
    return v;
}
#define NEED(n, name) do { if (argc != (n)) vrt_fail("%s expects %d value(s), got %d", name, n, argc); } while (0)

static V b_set(int argc, V *a) {
    if (argc == 0) return vrt_set_new();
    NEED(1, "set");
    V items = vrt_iter_list(a[0]);
    if (items.t == VT_GEN) {               /* a generator: take its values one by one */
        V s = vrt_set_new(); vrt_pin(s); vrt_pin(items);
        V x;
        while (vrt_iter_next(items, &x)) vrt_set_add(s, x);
        vrt_unpin(2);
        return s;
    }
    return set_of(items);
}
static V b_is_set(int argc, V *a) { NEED(1, "is_set"); return VB(a[0].t == VT_SET); }
static V b_union(int argc, V *a) {
    NEED(2, "union"); set_arg(a[0], "union"); set_arg(a[1], "union");
    V r = set_of(set_items(a[0]));
    VList *l = AS_LIST(set_items(a[1]));
    for (int64_t i = 0; i < l->len; i++) vrt_set_add(r, l->items[i]);
    return r;
}
static V b_intersection(int argc, V *a) {
    NEED(2, "intersection"); set_arg(a[0], "intersection"); set_arg(a[1], "intersection");
    V r = vrt_set_new(); VList *l = AS_LIST(set_items(a[0]));
    for (int64_t i = 0; i < l->len; i++) if (set_has(a[1], l->items[i])) vrt_set_add(r, l->items[i]);
    return r;
}
static V b_difference(int argc, V *a) {
    NEED(2, "difference"); set_arg(a[0], "difference"); set_arg(a[1], "difference");
    V r = vrt_set_new(); VList *l = AS_LIST(set_items(a[0]));
    for (int64_t i = 0; i < l->len; i++) if (!set_has(a[1], l->items[i])) vrt_set_add(r, l->items[i]);
    return r;
}
static V b_is_subset(int argc, V *a) {
    NEED(2, "is_subset"); set_arg(a[0], "is_subset"); set_arg(a[1], "is_subset");
    VList *l = AS_LIST(set_items(a[0]));
    for (int64_t i = 0; i < l->len; i++) if (!set_has(a[1], l->items[i])) return VFALSE;
    return VTRUE;
}

/* =====================================================================================================
 * Generators. A function whose body yields compiles to a starter (binds the parameters, returns a VGen) plus a
 * resume function: a state machine over the body (every local and temporary lives in the generator's heap scope,
 * so nothing is lost between steps; the collector sees that scope through the VGen).
 * ===================================================================================================== */

V vrt_gen_new(const char *name, VEnv *env, VGenResume resume) {
    VGen *g = vrt_alloc(VT_GEN, sizeof(VGen));
    g->name = name; g->env = env; g->resume = resume;
    return VO(VT_GEN, g);
}

static int gen_step(VGen *g, V *out) {
    if (g->done) return 0;
    if (g->running) vrt_fail("a generator can't ask itself for its next value");
    g->running = 1;
    int saved_line = vrt_line;
    V result = VNIL;
    VTry tr; vrt_try_push(&tr);
    if (setjmp(tr.jb) != 0) { g->running = 0; g->done = 1; vrt_rethrow(); }
    int r = g->resume(g, &result);
    vrt_try_pop();
    g->running = 0;
    if (!r) g->done = 1;
    vrt_line = saved_line;
    if (r) *out = result;
    return r;
}

int vrt_iter_next(V it, V *out) {
    if (it.t == VT_GEN) return gen_step((VGen *)it.u.o, out);
    vrt_fail("you can only loop over a list, text, map, set, or bytes");
}

/* for each i, x in GENERATOR: a generator of [i, x] pairs (its scope holds the source and the count) */
static int pairs_resume(VGen *g, V *out) {
    V x;
    if (!vrt_iter_next(g->env->s[0], &x)) return 0;
    V p[2] = {g->env->s[1], x};
    g->env->s[1] = VI(g->env->s[1].u.i + 1);
    *out = vrt_list_of(2, p);
    return 1;
}

V vrt_core_iter(V v) {
    switch (v.t) {
    case VT_GEN: return v;
    case VT_SET: return set_items(v);
    case VT_ENUM: { VList *m = ((VEnum *)v.u.o)->members; return vrt_list_of((int)m->len, m->items); }
    case VT_OBJ: {
        VFunc *fn = vrt_method_of(v, "each");
        if (fn) return vrt_iter_list(call_named(v, fn, 0, NULL));
        break;
    }
    default: break;
    }
    vrt_fail("you can only loop over a list, text, map, set, or bytes");
}

V vrt_core_iter_pairs(V v) {
    if (v.t != VT_SET && v.t != VT_GEN && v.t != VT_ENUM && v.t != VT_OBJ) vrt_fail("looping with two names needs a map, list, or text");
    V items = vrt_core_iter(v);
    if (items.t == VT_LIST) {
        VList *l = AS_LIST(items); V r = vrt_list(l->len);
        for (int64_t i = 0; i < l->len; i++) { V p[2] = {VI(i), l->items[i]}; vrt_list_push(r, vrt_list_of(2, p)); }
        return r;
    }
    VEnv *e = vrt_env(NULL, 2);
    e->s[0] = items; e->s[1] = VI(0);
    return vrt_gen_new("pairs", e, pairs_resume);
}

static V b_next(int argc, V *a) {
    if (argc != 1 && argc != 2) vrt_fail("next expects a generator (and an optional value for when it's finished)");
    if (a[0].t != VT_GEN) vrt_fail("next needs a generator (a function that uses yield)");
    V x;
    if (gen_step((VGen *)a[0].u.o, &x)) return x;
    if (argc == 2) return a[1];
    vrt_fail("the generator %s has no more values", ((VGen *)a[0].u.o)->name);
}

static V b_list(int argc, V *a) {
    if (argc == 0) return vrt_list(4);
    NEED(1, "list");
    V items = vrt_iter_list(a[0]);
    if (items.t != VT_GEN) return items.u.o == a[0].u.o ? vrt_list_of((int)AS_LIST(items)->len, AS_LIST(items)->items) : items;
    V r = vrt_list(8); vrt_pin(r); vrt_pin(items);
    V x;
    while (vrt_iter_next(items, &x)) vrt_list_push(r, x);
    vrt_unpin(2);
    return r;
}

/* =====================================================================================================
 * Module namespaces, kinds, shared members
 * ===================================================================================================== */

V vrt_module(const char *name, VEnv *env, int nexp, const char **names, const int *slots, int npriv, const char **priv) {
    VModule *m = vrt_alloc(VT_MODULE, sizeof(VModule));
    m->name = name; m->env = env;
    V mv = VO(VT_MODULE, m);
    keep_forever(mv);
    V sl = vrt_map();
    m->slots = AS_MAP(sl);
    for (int i = 0; i < nexp; i++) vrt_map_set(sl, vrt_cstr(names[i]), VI(slots[i]));
    for (int i = 0; i < npriv; i++) vrt_map_set(sl, vrt_cstr(priv[i]), VI(-1));    /* -1: private */
    return mv;
}

V vrt_module_get(V mod, V name) {
    VModule *m = (VModule *)mod.u.o;
    int f = 0; V s = vrt_map_get(VO(VT_MAP, m->slots), name, &f);
    if (f && s.u.i < 0) vrt_fail("'%s' is private to the module '%s'", vrt_cs(name), m->name);
    if (!f || m->env->s[s.u.i].t == VT_UNDEF) vrt_fail("the module '%s' has no '%s'", m->name, vrt_cs(name));
    return m->env->s[s.u.i];
}

V vrt_enum(const char *name, int n, const char **members) {
    VEnum *e = vrt_alloc(VT_ENUM, sizeof(VEnum));
    e->name = name;
    V ev = VO(VT_ENUM, e);
    vrt_pin(ev);
    V l = vrt_list(n);
    e->members = AS_LIST(l);
    for (int i = 0; i < n; i++) {
        VEnumV *m = vrt_alloc(VT_ENUMV, sizeof(VEnumV));
        m->e = e; m->idx = i; m->name = vrt_cstr(members[i]);
        vrt_list_push(l, VO(VT_ENUMV, m));
    }
    vrt_unpin(1);
    return ev;
}

void vrt_type_shared(V type, const char *name, V value) {
    VType *t = (VType *)type.u.o;
    if (!t->shared) { V m = vrt_map(); t->shared = AS_MAP(m); }
    vrt_map_set(VO(VT_MAP, t->shared), vrt_cstr(name), value);
}

static VType *shared_owner(VType *t, V name) {
    for (; t; t = t->parent) if (t->shared) { int f = 0; vrt_map_get(VO(VT_MAP, t->shared), name, &f); if (f) return t; }
    return NULL;
}

V vrt_core_getattr(V obj, V name) {
    switch (obj.t) {
    case VT_MODULE: return vrt_module_get(obj, name);
    case VT_TYPE: {
        VType *o = shared_owner((VType *)obj.u.o, name);
        if (!o) vrt_fail("the type %s has no shared '%s'", ((VType *)obj.u.o)->name, vrt_cs(name));
        int f = 0; return vrt_map_get(VO(VT_MAP, o->shared), name, &f);
    }
    case VT_ENUMV: {
        VEnumV *m = (VEnumV *)obj.u.o;
        if (!strcmp(vrt_cs(name), "name")) return m->name;
        if (!strcmp(vrt_cs(name), "index")) return VI(m->idx);
        vrt_fail("a %s value has 'name' and 'index', not '%s'", m->e->name, vrt_cs(name));
    }
    case VT_ENUM: {
        VEnum *e = (VEnum *)obj.u.o;
        for (int64_t i = 0; i < e->members->len; i++)
            if (vrt_equal(((VEnumV *)e->members->items[i].u.o)->name, name)) return e->members->items[i];
        Buf b = {0};
        for (int64_t i = 0; i < e->members->len; i++) { if (i) bputs(&b, ", "); bputs(&b, vrt_cs(((VEnumV *)e->members->items[i].u.o)->name)); }
        char msg[900]; snprintf(msg, sizeof msg, "the kind %s has no value '%s' (it has %s)", e->name, vrt_cs(name), b.p ? b.p : "");
        free(b.p);
        vrt_fail("%s", msg);
    }
    default: vrt_fail("you can only use '.' on an object made from a type");
    }
}

int vrt_core_setattr(V obj, V name, V val) {
    if (obj.t == VT_TYPE) {
        VType *o = shared_owner((VType *)obj.u.o, name);
        if (!o) vrt_fail("the type %s has no shared '%s' (add: shared %s be ...)", ((VType *)obj.u.o)->name, vrt_cs(name), vrt_cs(name));
        vrt_map_set(VO(VT_MAP, o->shared), name, val);
        return 1;
    }
    if (obj.t == VT_MODULE) {
        vrt_module_get(obj, name);
        VModule *m = (VModule *)obj.u.o;
        int f = 0; V s = vrt_map_get(VO(VT_MAP, m->slots), name, &f);
        m->env->s[s.u.i] = val;
        return 1;
    }
    return 0;
}

/* =====================================================================================================
 * Membership, type names, length
 * ===================================================================================================== */

V vrt_core_in(V item, V coll) {
    switch (coll.t) {
    case VT_SET: return VB(set_has(coll, item));
    case VT_ENUM: return VB(item.t == VT_ENUMV && ((VEnumV *)item.u.o)->e == (VEnum *)coll.u.o);
    case VT_OBJ: {
        VFunc *fn = vrt_method_of(coll, "contains");
        if (fn) return VB(vrt_truthy(call_named(coll, fn, 1, &item)));
        if (!vrt_method_of(coll, "each")) return VUNDEF;
    }   /* fall through: look through what each() gives */
    case VT_GEN: {
        V items = vrt_iter_list(coll);
        vrt_pin(items);
        int64_t i = 0; V x; int hit = 0;
        while (VRT_STEP(items, i++, &x)) if (vrt_equal(item, x)) { hit = 1; break; }
        vrt_unpin(1);
        return VB(hit);
    }
    default: return VUNDEF;
    }
}

const char *vrt_core_tname(V v) {
    switch (v.t) {
    case VT_NIL: case VT_UNDEF: return "nothing";
    case VT_BOOL: return "yes-no";
    case VT_INT: case VT_FLOAT: case VT_BIG: return "number";
    case VT_STR: return "text";
    case VT_LIST: return "list";
    case VT_MAP: return "map";
    case VT_BYTES: return "bytes";
    case VT_FUNC: case VT_BUILTIN: case VT_BOUND: return "function";
    case VT_TYPE: return "type";
    case VT_OBJ: return AS_INST(v)->type->name;
    case VT_SET: return "set";
    case VT_GEN: return "generator";
    case VT_MODULE: return "module";
    case VT_ENUM: return "kind";
    case VT_ENUMV: return ((VEnumV *)v.u.o)->e->name;
    default: return "value";
    }
}

V vrt_core_length(V v) {
    if (v.t == VT_SET) return VI(AS_MAP(v)->count);
    if (v.t == VT_ENUM) return VI(((VEnum *)v.u.o)->members->len);
    VFunc *fn = vrt_method_of(v, "length");
    if (fn) return call_named(v, fn, 0, NULL);
    return VUNDEF;
}

/* when a Circle / when a number */
int vrt_pat_type(V v, V tval, const char *tname) {
    if (tval.t == VT_TYPE) return vrt_truthy(vrt_isa(v, tval));
    if (tval.t == VT_ENUM) return v.t == VT_ENUMV && ((VEnumV *)v.u.o)->e == (VEnum *)tval.u.o;
    static const char *words[] = {"number", "text", "list", "map", "set", "function", "nothing", "generator", "bytes", "module", "kind", NULL};
    for (int i = 0; words[i]; i++) if (!strcmp(words[i], tname)) return !strcmp(vrt_core_tname(v), tname);
    vrt_fail("'%s' is not a type", tname);
}

/* =====================================================================================================
 * Named values in calls: f(a, size: 2)
 * ===================================================================================================== */

V vrt_func_sig(V f, int nparams, const char **pnames, int rest) {
    VFunc *fn = (VFunc *)f.u.o;
    fn->nparams = nparams; fn->pnames = pnames; fn->rest = rest;
    return f;
}

V vrt_call_kw(V callee, int argc, V *argv, int nkw, const char **kwnames, V *kwvals) {
    const char *fname; int np, rest = 0; const char **pn = NULL; VType *fields_of = NULL;
    VFunc *fn = NULL;
    switch (callee.t) {
    case VT_FUNC: fn = (VFunc *)callee.u.o; break;
    case VT_BOUND: fn = ((VBound *)callee.u.o)->fn; break;
    case VT_TYPE: {
        VType *t = (VType *)callee.u.o;
        int f = 0; V setup = vrt_map_get(VO(VT_MAP, t->methods), vrt_cstr("setup"), &f);
        if (f) fn = (VFunc *)setup.u.o; else fields_of = t;
        break;
    }
    case VT_BUILTIN: vrt_fail("the builtin '%s' doesn't take named values", ((VBuiltin *)callee.u.o)->name);
    default: vrt_fail("that value is not a function you can call");
    }
    if (fn) { fname = fn->name; np = fn->nparams; pn = fn->pnames; rest = fn->rest; }
    else { fname = fields_of->name; np = (int)fields_of->fields->len; }
    int last = rest ? np - 1 : np;
    int total = argc;
    V *merged = malloc(sizeof(V) * (size_t)(np + argc + 1));
    for (int i = 0; i < argc; i++) merged[i] = argv[i];
    for (int k = 0; k < nkw; k++) {
        int idx = -1;
        for (int i = 0; i < np; i++) {
            const char *nm = pn ? pn[i] : vrt_cs(fields_of->fields->items[i]);
            if (!strcmp(nm, kwnames[k])) { idx = i; break; }
        }
        if (idx < 0) { free(merged); vrt_fail("'%s' has no value named '%s'", fname, kwnames[k]); }
        if (idx >= last) { free(merged); vrt_fail("'%s...' collects plain values, so it can't be given by name", kwnames[k]); }
        if (idx < argc) { free(merged); vrt_fail("'%s' got two values for '%s'", fname, kwnames[k]); }
        while (total <= idx) merged[total++] = VUNDEF;
        merged[idx] = kwvals[k];
    }
    if (fields_of) {
        for (int i = 0; i < np; i++) if (i >= total || merged[i].t == VT_UNDEF) {
            char msg[512]; snprintf(msg, sizeof msg, "%s is missing a value for '%s'", fname, vrt_cs(fields_of->fields->items[i]));
            free(merged); vrt_fail("%s", msg);
        }
    }
    V r;
    {
        V *copy = merged;
        r = vrt_call(callee, total, copy);
    }
    free(merged);
    return r;
}

/* =====================================================================================================
 * using NAME be VALUE ... end
 * ===================================================================================================== */

void vrt_close(V res) {
    if (res.t == VT_NIL || res.t == VT_UNDEF) return;
    VFunc *fn = vrt_method_of(res, "close");
    if (fn) { call_named(res, fn, 0, NULL); return; }
    if (res.t != VT_INT && res.t != VT_FLOAT && res.t != VT_STR && res.t != VT_LIST && res.t != VT_MAP && res.t != VT_BOOL) {
        V closer = vrt_builtin_named("close");
        if (closer.t != VT_UNDEF) { vrt_pin(res); vrt_call(closer, 1, &res); vrt_unpin(1); return; }
    }
    vrt_fail("'using' needs something that can be closed (an object with a close() method), not a %s", vrt_core_tname(res));
}

_Noreturn void vrt_close_rethrow(V res) {
    char msg[1024];
    snprintf(msg, sizeof msg, "%s", vrt_errmsg);
    vrt_close(res);
    snprintf(vrt_errmsg, sizeof vrt_errmsg, "%s", msg);
    vrt_rethrow();
}

/* =====================================================================================================
 * {value:spec} — [[fill]align][0][width][,][.precision][type], exactly like vanta.py's format_value
 * ===================================================================================================== */

static int64_t utf8_len(const char *s, int64_t n) { int64_t c = 0; for (int64_t i = 0; i < n; i++) if (((unsigned char)s[i] & 0xC0) != 0x80) c++; return c; }
static int utf8_char_bytes(const char *s) { unsigned char c = (unsigned char)*s; return c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4; }

typedef struct { char fill[8]; char align; int zero; int width; int comma; int prec; char kind; } Spec;

static int parse_spec(const char *s, Spec *sp) {
    memset(sp, 0, sizeof *sp); sp->prec = -1; sp->width = -1;
    const char *p = s;
    if (*p) {
        int fb = utf8_char_bytes(p);
        if (p[fb] && strchr("<>^", p[fb]) && p[fb] != 0) { memcpy(sp->fill, p, (size_t)fb); sp->align = p[fb]; p += fb + 1; }
        else if (strchr("<>^", *p) && *p) { sp->align = *p; p++; }
    }
    if (*p == '0') { sp->zero = 1; p++; }
    if (*p >= '0' && *p <= '9') { sp->width = 0; while (*p >= '0' && *p <= '9') sp->width = sp->width * 10 + (*p++ - '0'); }
    if (*p == ',') { sp->comma = 1; p++; }
    if (*p == '.') {
        p++;
        if (!(*p >= '0' && *p <= '9')) return 0;
        sp->prec = 0; while (*p >= '0' && *p <= '9') sp->prec = sp->prec * 10 + (*p++ - '0');
    }
    if (*p && strchr("feExXbo%s", *p)) sp->kind = *p++;
    return *p == 0;
}

static void group_thousands(Buf *out, const char *body) {
    const char *d = body;
    if (*d == '-') { bputs(out, "-"); d++; }
    int64_t k = 0; while (d[k] >= '0' && d[k] <= '9') k++;
    for (int64_t i = 0; i < k; i++) { if (i && (k - i) % 3 == 0) bputs(out, ","); bput(out, d + i, 1); }
    bputs(out, d + k);
}

static void int_in_base(Buf *b, int64_t v, char kind) {
    char tmp[80]; int n = 0;
    uint64_t u = v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v;
    int base = kind == 'b' ? 2 : kind == 'o' ? 8 : 16;
    const char *digits = kind == 'X' ? "0123456789ABCDEF" : "0123456789abcdef";
    do { tmp[n++] = digits[u % (uint64_t)base]; u /= (uint64_t)base; } while (u);
    if (v < 0) bputs(b, "-");
    while (n) bput(b, &tmp[--n], 1);
}

V vrt_format_spec(V v, V specv) {
    const char *spec = vrt_cs(specv);
    Spec sp;
    if (!parse_spec(spec, &sp)) vrt_fail("I don't understand the format ':%s' (try :.2 for two decimals, :8 for a width, :, for 1,000s)", spec);
    int is_num = v.t == VT_INT || v.t == VT_FLOAT || v.t == VT_BIG;
    double x = v.t == VT_INT ? (double)v.u.i : v.t == VT_FLOAT ? v.u.f : v.t == VT_BIG ? vrt_big_to_double(v) : 0;
    Buf body = {0};
    char tmp[512];
    if (sp.kind == 'x' || sp.kind == 'X' || sp.kind == 'b' || sp.kind == 'o') {
        if (!is_num || (v.t == VT_FLOAT && v.u.f != floor(v.u.f)) || v.t == VT_BIG) vrt_fail("the format ':%s' needs a whole number", spec);
        int_in_base(&body, v.t == VT_INT ? v.u.i : (int64_t)v.u.f, sp.kind);
    } else if (sp.kind == 'e' || sp.kind == 'E') {
        if (!is_num) vrt_fail("the format ':%s' needs a number", spec);
        snprintf(tmp, sizeof tmp, sp.kind == 'e' ? "%.*e" : "%.*E", sp.prec < 0 ? 6 : sp.prec, x); bputs(&body, tmp);
    } else if (sp.kind == '%') {
        if (!is_num) vrt_fail("the format ':%s' needs a number", spec);
        snprintf(tmp, sizeof tmp, "%.*f%%", sp.prec < 0 ? 0 : sp.prec, x * 100); bputs(&body, tmp);
    } else if (is_num && (sp.kind == 'f' || sp.prec >= 0)) {
        char *big = malloc(400 + (size_t)(sp.prec < 0 ? 6 : sp.prec));
        sprintf(big, "%.*f", sp.prec < 0 ? 6 : sp.prec, x); bputs(&body, big); free(big);
    } else {
        V d = vrt_display(v);
        VStr *s = AS_STR(d);
        if (sp.prec >= 0) {        /* text cut to a length (in characters) */
            int64_t i = 0, c = 0;
            while (i < s->len && c < sp.prec) { i += utf8_char_bytes(s->data + i); c++; }
            bput(&body, s->data, i);
        } else bput(&body, s->data, s->len);
    }
    if (!body.p) bput(&body, "", 0);
    if (sp.comma && is_num && !(sp.kind == 'x' || sp.kind == 'X' || sp.kind == 'b' || sp.kind == 'o')) {
        Buf g = {0}; group_thousands(&g, body.p); free(body.p); body = g;
    }
    int64_t w = sp.width < 0 ? 0 : sp.width, n = utf8_len(body.p, body.len);
    Buf out = {0};
    if (sp.zero && is_num && !sp.align && n < w) {
        const char *b = body.p;
        if (*b == '-') { bputs(&out, "-"); b++; }
        for (int64_t i = 0; i < w - n; i++) bputs(&out, "0");
        bputs(&out, b); free(body.p);
        return bdone(&out);
    }
    if (n >= w) return bdone(&body);
    const char *fill = sp.fill[0] ? sp.fill : (!sp.zero || sp.align) ? " " : "0";
    char align = sp.align ? sp.align : (is_num ? '>' : '<');
    int64_t pad = w - n, left = align == '<' ? 0 : align == '>' ? pad : pad / 2;
    for (int64_t i = 0; i < left; i++) bputs(&out, fill);
    bput(&out, body.p, body.len);
    for (int64_t i = 0; i < pad - left; i++) bputs(&out, fill);
    free(body.p);
    return bdone(&out);
}

void vrt_mutate_check(V cur, V amount, int sign) {
    V vs[2] = {cur, amount};
    for (int i = 0; i < 2; i++) if (vs[i].t != VT_INT && vs[i].t != VT_FLOAT && vs[i].t != VT_BIG)
        vrt_fail("'%s' needs numbers, but got %s (to join text, use: change NAME to NAME + ...)", sign == '+' ? "increase" : "decrease", vrt_core_tname(vs[i]));
}

static V b_say(int argc, V *a) {     /* say(x) as a function, for lambdas */
    for (int i = 0; i < argc; i++) { if (i) fputc(' ', stdout); V s = vrt_display(a[i]); fwrite(AS_STR(s)->data, 1, (size_t)AS_STR(s)->len, stdout); }
    fputc('\n', stdout);
    return VNIL;
}

static V b_format(int argc, V *a) { NEED(2, "format"); return vrt_format_spec(a[0], vrt_display(a[1])); }

static const Entry core_table[] = {
    {"set", b_set}, {"is_set", b_is_set}, {"union", b_union}, {"intersection", b_intersection},
    {"difference", b_difference}, {"is_subset", b_is_subset}, {"list", b_list}, {"next", b_next},
    {"format", b_format}, {"say", b_say},
    {NULL, NULL}
};
__attribute__((constructor)) static void core_register(void) { vrt_register_builtins(core_table); }
