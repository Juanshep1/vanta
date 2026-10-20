/* Vanta native runtime: the values and operations compiled Vanta programs run on.
 *
 * A value (V) is a tag plus a payload: nothing, yes/no, whole numbers (64-bit), decimals, or a pointer to a heap
 * object (text, list, map, bytes, function, type, object, ...). Heap objects are collected by a precise mark-and-sweep
 * collector that only runs at safe points the compiler places at function entry and loop back-edges, where every
 * live value sits in a scope (VEnv) on the root stack. Errors unwind with setjmp/longjmp to the nearest
 * attempt/rescue, carrying the same messages the Python interpreter (vanta.py) gives.
 */
#ifndef VRT_H
#define VRT_H
#include <stdint.h>
#include <stddef.h>
#include <setjmp.h>

typedef enum {
    VT_UNDEF = 0,   /* a scope slot that hasn't been defined yet (never visible to programs) */
    VT_NIL, VT_BOOL, VT_INT, VT_FLOAT,
    VT_STR, VT_LIST, VT_MAP, VT_BYTES, VT_FUNC, VT_BUILTIN, VT_TYPE, VT_OBJ, VT_BOUND, VT_SUPER, VT_ENV, VT_PTR
} VTag;

typedef struct VObj VObj;
typedef struct { uint32_t t; uint32_t aux; union { int64_t i; double f; VObj *o; void *p; } u; } V;

struct VObj { uint8_t type; uint8_t mark; uint8_t perm; VObj *next; };

typedef struct VStr { VObj h; int64_t len; int64_t nchars; uint32_t hash; uint8_t ascii; char data[]; } VStr;
typedef struct VList { VObj h; int64_t len, cap; V *items; } VList;
typedef struct VBytes { VObj h; int64_t len, cap; uint8_t *data; } VBytes;
typedef struct VMapEnt { V key, val; uint32_t hash; uint8_t used; } VMapEnt;
typedef struct VMap { VObj h; int64_t count, nent, capent; VMapEnt *ents; int32_t *index; int64_t icap; } VMap;
typedef struct VEnv { VObj h; struct VEnv *parent; int n; uint8_t *consts; V s[]; } VEnv;

typedef V (*VFnPtr)(VEnv *clo, int argc, V *argv, V self, V super_);
typedef struct VFunc { VObj h; const char *name; VFnPtr fn; VEnv *env; struct VType *owner; } VFunc;
typedef V (*VBuiltinPtr)(int argc, V *argv);
typedef struct VBuiltin { VObj h; const char *name; VBuiltinPtr fn; } VBuiltin;
typedef struct VType { VObj h; const char *name; struct VType *parent; VList *fields; VMap *methods; } VType;
typedef struct VInst { VObj h; VType *type; VMap *attrs; } VInst;
typedef struct VBound { VObj h; V inst; VFunc *fn; } VBound;
typedef struct VSuper { VObj h; V inst; VType *parent; } VSuper;

/* ---- constructors ---- */
#define VUNDEF ((V){VT_UNDEF, 0, {.i = 0}})
#define VNIL ((V){VT_NIL, 0, {.i = 0}})
#define VTRUE ((V){VT_BOOL, 0, {.i = 1}})
#define VFALSE ((V){VT_BOOL, 0, {.i = 0}})
static inline V VB(int b) { V v = {VT_BOOL, 0, {.i = b ? 1 : 0}}; return v; }
static inline V VI(int64_t i) { V v = {VT_INT, 0, {.i = i}}; return v; }
static inline V VF(double f) { V v = {VT_FLOAT, 0, {.f = f}}; return v; }
static inline V VO(uint32_t t, void *o) { V v = {t, 0, {.o = (VObj *)o}}; return v; }
#define AS_STR(v) ((VStr *)(v).u.o)
#define AS_LIST(v) ((VList *)(v).u.o)
#define AS_MAP(v) ((VMap *)(v).u.o)
#define AS_BYTES(v) ((VBytes *)(v).u.o)
#define AS_INST(v) ((VInst *)(v).u.o)

/* ---- runtime state ---- */
extern int vrt_line;
extern int vrt_argc;
extern char **vrt_argv;

/* errors */
typedef struct VTry { jmp_buf jb; int roots; struct VTry *prev; } VTry;
extern VTry *vrt_try;
extern char vrt_errmsg[1024];
_Noreturn void vrt_fail(const char *fmt, ...);
void vrt_try_push(VTry *t);
void vrt_try_pop(void);
V vrt_caught(void);          /* the message of the error just caught, as text (line number dropped) */

/* memory */
void vrt_init(int argc, char **argv);
void *vrt_alloc(uint8_t type, size_t size);
void vrt_safepoint(void);
void vrt_root_push(VEnv *e);
void vrt_root_pop(void);
int vrt_roots_top(void);
void vrt_roots_restore(int top);
void vrt_pin(V v);           /* keep a value alive while C code holds it (builtins calling back into Vanta) */
void vrt_unpin(int n);
VEnv *vrt_env(VEnv *parent, int n);
extern VEnv *vrt_globals;

/* text */
V vrt_str(const char *s, int64_t len);
V vrt_cstr(const char *s);
V vrt_perm_str(const char *s, int64_t len);   /* a program constant: never collected */
V vrt_display(V v);          /* the text 'say' prints for a value */
V vrt_display_item(V v);     /* same, with quotes around text (inside lists and maps) */
const char *vrt_cs(V v);     /* C string of a text value (valid until the next collection) */
V vrt_format(int n, V *parts);
V vrt_str_index(VStr *s, int64_t i);

/* collections */
V vrt_list(int64_t cap);
void vrt_list_push(V list, V item);
V vrt_list_of(int n, V *items);
V vrt_map(void);
V vrt_map_get(V map, V key, int *found);
void vrt_map_set(V map, V key, V val);
int vrt_map_del(V map, V key);
V vrt_bytes(int64_t len);

/* operators */
int vrt_truthy(V v);
V vrt_arith(int op, V a, V b);          /* op: '+','-','*','/','%','^','&','|','x' (xor),'<','>' (shifts) */
V vrt_neg(V a);
V vrt_bitnot(V a);
V vrt_compare(int op, V a, V b);        /* op: '<','>','l' (<=),'g' (>=) */
int vrt_equal(V a, V b);
V vrt_in(V item, V coll);
V vrt_isa(V a, V type);
V vrt_index(V coll, V idx);
void vrt_set_index(V coll, V idx, V val);
V vrt_slice(V target, V start, V end);  /* start/end VT_UNDEF = open */
V vrt_getattr(V obj, V name);
void vrt_setattr(V obj, V name, V val);
V vrt_iter_list(V v);                   /* what 'for each' walks: a list snapshot */
V vrt_iter_pairs(V v);                  /* list of [a, b] pairs for 'for each a, b in' */

/* calls, functions, types */
V vrt_call(V callee, int argc, V *argv);
V vrt_func(const char *name, VFnPtr fn, VEnv *env);
V vrt_builtin(const char *name, VBuiltinPtr fn);
V vrt_type(const char *name, V parent, int nfields, const char **fields, int nmethods, const char **mnames, V *methods);
void vrt_bind_check(const char *fname, int argc, int nparams);
_Noreturn void vrt_missing_arg(const char *fname, const char *pname);
_Noreturn void vrt_unknown(const char *name);
_Noreturn void vrt_no_var(const char *name);
_Noreturn void vrt_fixed(const char *name);
V vrt_unpack(V v, int count);           /* let a, b be LIST */
void vrt_say(V v);
V vrt_ask(V prompt);
V vrt_import_once(const char *path);

/* builtins table: name -> function, for names the compiler resolves to builtins */
V vrt_builtin_named(const char *name);
#endif

/* ---- fast paths the compiler emits: whole-number math and indexing inline, everything else via the runtime ---- */
static inline V VRT_ADD(V a, V b) { int64_t r; if (a.t == VT_INT && b.t == VT_INT && !__builtin_add_overflow(a.u.i, b.u.i, &r)) return VI(r); return vrt_arith('+', a, b); }
static inline V VRT_SUB(V a, V b) { int64_t r; if (a.t == VT_INT && b.t == VT_INT && !__builtin_sub_overflow(a.u.i, b.u.i, &r)) return VI(r); return vrt_arith('-', a, b); }
static inline V VRT_MUL(V a, V b) { int64_t r; if (a.t == VT_INT && b.t == VT_INT && !__builtin_mul_overflow(a.u.i, b.u.i, &r)) return VI(r); return vrt_arith('*', a, b); }
static inline V VRT_MOD(V a, V b) { if (a.t == VT_INT && b.t == VT_INT && b.u.i > 0 && a.u.i >= 0) return VI(a.u.i % b.u.i); return vrt_arith('%', a, b); }
static inline V VRT_BAND(V a, V b) { if (a.t == VT_INT && b.t == VT_INT) return VI(a.u.i & b.u.i); return vrt_arith('&', a, b); }
static inline V VRT_BOR(V a, V b) { if (a.t == VT_INT && b.t == VT_INT) return VI(a.u.i | b.u.i); return vrt_arith('|', a, b); }
static inline V VRT_BXOR(V a, V b) { if (a.t == VT_INT && b.t == VT_INT) return VI(a.u.i ^ b.u.i); return vrt_arith('x', a, b); }
static inline V VRT_SHL(V a, V b) { if (a.t == VT_INT && b.t == VT_INT && b.u.i >= 0 && b.u.i < 63) return VI((int64_t)((uint64_t)a.u.i << b.u.i)); return vrt_arith('<', a, b); }
static inline V VRT_SHR(V a, V b) { if (a.t == VT_INT && b.t == VT_INT && b.u.i >= 0 && b.u.i < 63) return VI(a.u.i >> b.u.i); return vrt_arith('>', a, b); }
static inline V VRT_CMP(int op, V a, V b) {
    if (a.t == VT_INT && b.t == VT_INT) {
        switch (op) { case '<': return VB(a.u.i < b.u.i); case '>': return VB(a.u.i > b.u.i); case 'l': return VB(a.u.i <= b.u.i); default: return VB(a.u.i >= b.u.i); }
    }
    return vrt_compare(op, a, b);
}
static inline V VRT_INDEX(V c, V i) {
    if (i.t == VT_INT) {
        if (c.t == VT_LIST) { VList *l = AS_LIST(c); if (i.u.i >= 0 && i.u.i < l->len) return l->items[i.u.i]; }
        else if (c.t == VT_BYTES) { VBytes *y = AS_BYTES(c); if (i.u.i >= 0 && i.u.i < y->len) return VI(y->data[i.u.i]); }
    }
    return vrt_index(c, i);
}
