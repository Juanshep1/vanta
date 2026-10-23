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
    VT_STR, VT_LIST, VT_MAP, VT_BYTES, VT_FUNC, VT_BUILTIN, VT_TYPE, VT_OBJ, VT_BOUND, VT_SUPER, VT_ENV, VT_PTR,
    VT_HANDLE,      /* a runtime handle (task, channel, socket, file, ...): see VHandle below */
    /* 6.0 core (vrt_core.c, vrt_big.c): a set is a VMap tagged VT_SET; the others are their own objects */
    VT_SET, VT_BIG, VT_GEN, VT_MODULE, VT_ENUM, VT_ENUMV
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
typedef struct VFunc { VObj h; const char *name; VFnPtr fn; VEnv *env; struct VType *owner;
                       int nparams, rest; const char **pnames; } VFunc;   /* param names: for f(name: value) */
typedef V (*VBuiltinPtr)(int argc, V *argv);
typedef struct VBuiltin { VObj h; const char *name; VBuiltinPtr fn; uint8_t sets_ok; } VBuiltin;   /* sets_ok: give sets as lists */
typedef struct VType { VObj h; const char *name; struct VType *parent; VList *fields; VMap *methods; VMap *shared; } VType;
typedef struct VInst { VObj h; VType *type; VMap *attrs; } VInst;
typedef struct VBound { VObj h; V inst; VFunc *fn; } VBound;
typedef struct VSuper { VObj h; V inst; VType *parent; } VSuper;
/* 6.0 core values (vrt_core.c, vrt_big.c) */
typedef struct VBig { VObj h; int32_t sign; int32_t n; uint32_t d[]; } VBig;   /* sign * sum(d[i] * 2^(32i)); never fits int64 */
struct VGen;
typedef int (*VGenResume)(struct VGen *g, V *out);    /* 1 = produced *out, 0 = finished */
typedef struct VGen { VObj h; const char *name; VEnv *env; VGenResume resume; int state; uint8_t done, running; } VGen;
typedef struct VModule { VObj h; const char *name; VEnv *env; VMap *slots; } VModule;   /* slots: exported name -> slot */
typedef struct VEnum { VObj h; const char *name; VList *members; } VEnum;
typedef struct VEnumV { VObj h; VEnum *e; V name; int64_t idx; } VEnumV;

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
extern const char **vrt_file_names;
extern int vrt_file_count;
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
void vrt_bind_check2(const char *fname, int argc, int nparams, int nrequired);
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

/* Optional runtime files (vrt_net.c, vrt_sys.c, ...) register their own tables from a constructor:
 *     typedef VEntry Entry;  static const Entry net_table[] = {{"tcp_connect", b_tcp_connect}, ..., {NULL, NULL}};
 *     __attribute__((constructor)) static void reg(void) { vrt_register_builtins(net_table); }
 * vantac reads every `static const Entry *table*[]` to learn the names, and links a file only when one is used. */
typedef struct { const char *name; VBuiltinPtr fn; } VEntry;
void vrt_register_builtins(const VEntry *table);

/* Runtime handles: opaque objects owned by C code (tasks, channels, sockets, files, databases, ...).
 * `kind` is what type_of/typeof report and what `say` shows as <kind>. trace (may be NULL) marks any Vanta values the
 * handle holds via vrt_mark; finalize (may be NULL) frees the C side when the handle is collected. */
typedef struct VHandle { VObj h; const char *kind; void *data; void (*trace)(void *data); void (*finalize)(void *data); } VHandle;
V vrt_handle(const char *kind, void *data, void (*trace)(void *), void (*finalize)(void *));
void *vrt_handle_data(V v, const char *kind, const char *fname);   /* fails "<fname> needs a <kind>" otherwise */
int vrt_is_handle(V v, const char *kind);
void vrt_mark(V v);                       /* for trace callbacks */
/* Generic operations on handles (close, send, receive, read_line, read_all, write_to, wait): each runtime file
 * registers how its kind does an op, e.g. vrt_register_op("database", "close", db_close); the generic builtins in
 * vrt_io.c look it up. An op gets the builtin's (argc, argv) with argv[0] the handle. */
void vrt_register_op(const char *kind, const char *op, VBuiltinPtr fn);
VBuiltinPtr vrt_find_op(V handle, const char *op);       /* NULL when the value isn't a handle with that op */

/* Threads (vrt_thread.c): one thread runs Vanta code at a time (a global interpreter lock, since the collector isn't
 * thread-safe). Wrap anything that can block — sleeping, socket I/O, waiting for a child process — in
 * VRT_BLOCKING_BEGIN / VRT_BLOCKING_END so other threads run meanwhile. Between the two, don't touch Vanta values
 * (copy what you need into C memory first); values in argv stay alive because the caller's scope holds them. */
typedef struct VSavedState { void *roots; int nroots, caproots; void *pins; int npins, cappins; VTry *try_; int line; } VSavedState;
void vrt_save_state(VSavedState *s);      /* park this thread's GC roots/try stack/line */
void vrt_restore_state(VSavedState *s);
void vrt_fresh_state(void);               /* start a new thread with an empty root stack */
void vrt_mark_saved(VSavedState *s);      /* mark a parked thread's roots (from the collector hook) */
extern void (*vrt_yield_hook)(void);      /* called at safepoints when threads exist */
extern void (*vrt_mark_hook)(void);       /* called by the collector to mark roots held outside the scope stack */
extern void *(*vrt_blocking_begin_hook)(void);
extern void (*vrt_blocking_end_hook)(void *);
#define VRT_BLOCKING_BEGIN() void *vrt__blk = vrt_blocking_begin_hook ? vrt_blocking_begin_hook() : NULL
#define VRT_BLOCKING_END() do { if (vrt_blocking_end_hook) vrt_blocking_end_hook(vrt__blk); } while (0)
_Noreturn void vrt_rethrow(void);        /* re-raise the error just caught (keeps its message and line) */
void vrt_lock_enter(V lock);              /* the 'lock' statement (vrt_thread.c); VUNDEF = the program-wide lock */
void vrt_lock_exit(V lock);
void vrt_threads_init(void);              /* turn the lock on (idempotent); spawn/start_server call it */
void vrt_thread_start(void (*fn)(void *), void *arg);   /* run fn(arg) on a new thread that holds the lock */
void vrt_keep(V v);                       /* keep a value alive until vrt_unkeep (e.g. a running server's handler) */
void vrt_unkeep(V v);
uint64_t vrt_change_seen(void);           /* condition waiting: read the change counter (holding the lock), */
int vrt_wait_change(uint64_t seen, double timeout);  /* then wait with the lock released until it moves (0 = timed out; */
void vrt_notify_all(void);                /* timeout < 0 = forever); vrt_notify_all moves it. */
int vrt_thread_count(void);               /* threads running Vanta code (1 when none were started) */


/* ---- 6.0 core language (vrt_core.c) ---- */
V vrt_call_method(V inst, VFunc *fn, int argc, V *argv);  /* call fn with me = inst */
VFunc *vrt_method_of(V obj, const char *name);         /* an object's (ordinary) method, or NULL */
void vrt_core_mark(void);                              /* collector: values the core keeps alive */
V vrt_func_sig(V f, int nparams, const char **pnames, int rest);
V vrt_call_kw(V callee, int argc, V *argv, int nkw, const char **kwnames, V *kwvals);
/* sets (a VMap tagged VT_SET) */
V vrt_set_new(void);
void vrt_set_add(V set, V item);
void vrt_add_to(V item, V target);                     /* add X to LIST/SET */
void vrt_remove(V item, V target);                     /* remove X from SET/LIST/MAP */
/* generators */
V vrt_gen_new(const char *name, VEnv *env, VGenResume resume);
int vrt_iter_next(V it, V *out);                       /* the next item of a generator (0 = no more) */
V vrt_core_iter(V v);                                  /* what for each walks for sets, kinds, generators, objects */
V vrt_core_iter_pairs(V v);
/* modules, kinds, shared */
V vrt_module(const char *name, VEnv *env, int nexp, const char **names, const int *slots, int npriv, const char **priv);
V vrt_module_get(V mod, V name);
V vrt_enum(const char *name, int n, const char **members);
void vrt_type_shared(V type, const char *name, V value);
V vrt_core_getattr(V obj, V name);                     /* '.' on modules, types (shared), kinds and their values */
int vrt_core_setattr(V obj, V name, V val);
/* operators on objects, kinds, sets (called by vrt.c's general paths) */
int vrt_core_arith(int op, V a, V b, V *out);
int vrt_core_less(V a, V b);                           /* a < b for objects / kind values */
int vrt_core_compare(int op, V a, V b, V *out);
int vrt_obj_equal(V a, V b);
V vrt_core_in(V item, V coll);                         /* VUNDEF = not handled */
const char *vrt_core_tname(V v);
V vrt_core_length(V v);                                /* VUNDEF = not handled */
/* patterns, using, formatting */
int vrt_pat_type(V v, V tval, const char *tname);
void vrt_close(V res);
_Noreturn void vrt_close_rethrow(V res);
V vrt_format_spec(V v, V spec);
V vrt_negate_obj(V a);
void vrt_mutate_check(V cur, V amount, int sign);       /* increase/decrease need numbers */
/* ---- 6.0: big whole numbers (vrt_big.c). Whole numbers that overflow 64 bits become VT_BIG, exactly like Python's
 * ints; every result that fits back into int64 is returned as a plain VT_INT. Arguments may be VT_INT or VT_BIG. ---- */
V vrt_big_from_i64(int64_t x);            /* always a VT_BIG object (for building); use vrt_big_norm to shrink */
V vrt_big_norm(V a);                      /* VT_BIG that fits int64 -> VT_INT; anything else unchanged */
V vrt_big_parse(const char *s, int64_t len); /* decimal digits with optional leading '-' -> VT_INT or VT_BIG */
V vrt_big_arith(int op, V a, V b);        /* '+','-','*','%' (Python sign rules),'/' (exact when divisible, else
                                             VF(double)), '^' (b >= 0), '<' '>' (shifts), '&','|','x' */
V vrt_big_neg(V a);
int vrt_big_cmp(V a, V b);                /* -1/0/1 */
double vrt_big_to_double(V a);
char *vrt_big_text(V a, int64_t *len);    /* malloc'd decimal text */
uint32_t vrt_big_hash(V a);
#endif

/* ---- fast paths the compiler emits: whole-number math and indexing inline, everything else via the runtime ---- */
static inline V VRT_ADD(V a, V b) { int64_t r; if (a.t == VT_INT && b.t == VT_INT && !__builtin_add_overflow(a.u.i, b.u.i, &r)) return VI(r); return vrt_arith('+', a, b); }
static inline V VRT_SUB(V a, V b) { int64_t r; if (a.t == VT_INT && b.t == VT_INT && !__builtin_sub_overflow(a.u.i, b.u.i, &r)) return VI(r); return vrt_arith('-', a, b); }
static inline V VRT_MUL(V a, V b) { int64_t r; if (a.t == VT_INT && b.t == VT_INT && !__builtin_mul_overflow(a.u.i, b.u.i, &r)) return VI(r); return vrt_arith('*', a, b); }
static inline V VRT_MOD(V a, V b) { if (a.t == VT_INT && b.t == VT_INT && b.u.i > 0 && a.u.i >= 0) return VI(a.u.i % b.u.i); return vrt_arith('%', a, b); }
static inline V VRT_BAND(V a, V b) { if (a.t == VT_INT && b.t == VT_INT) return VI(a.u.i & b.u.i); return vrt_arith('&', a, b); }
static inline V VRT_BOR(V a, V b) { if (a.t == VT_INT && b.t == VT_INT) return VI(a.u.i | b.u.i); return vrt_arith('|', a, b); }
static inline V VRT_BXOR(V a, V b) { if (a.t == VT_INT && b.t == VT_INT) return VI(a.u.i ^ b.u.i); return vrt_arith('x', a, b); }
static inline V VRT_SHL(V a, V b) {
    if (a.t == VT_INT && b.t == VT_INT && b.u.i >= 0 && b.u.i < 63) { int64_t r = (int64_t)((uint64_t)a.u.i << b.u.i); if ((r >> b.u.i) == a.u.i) return VI(r); }
    return vrt_arith('<', a, b);
}
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
/* one step of 'for each': lists inline, generators (and other lazy sources) through the runtime */
static inline int VRT_STEP(V it, int64_t i, V *out) {
    if (it.t == VT_LIST) { VList *l = AS_LIST(it); if (i < l->len) { *out = l->items[i]; return 1; } return 0; }
    return vrt_iter_next(it, out);
}
