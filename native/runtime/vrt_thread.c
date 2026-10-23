/* vantac: optional; libs: -lpthread; needs: vrt_io.c */
#define _GNU_SOURCE
/* Vanta native runtime: threads, tasks, channels, locks, run_parallel and signals.
 *
 * Real OS threads, one global lock (like Python's GIL): only the thread holding it runs Vanta code, because the
 * collector isn't thread-safe. A thread lets go of it while it blocks — sleeping, socket I/O, waiting for a child
 * process, a task, a channel or a lock — so I/O-bound programs run concurrently, and a busy thread hands it over every
 * couple of milliseconds at a safepoint so CPU-bound tasks take turns. When a thread parks, its GC roots (scope stack,
 * pins), try stack and current line are saved in its ThreadRec; the collector marks every parked thread's roots.
 * run_parallel uses separate processes (fork) for real CPU parallelism. Nothing here costs anything until the first
 * thread starts: the hooks in vrt.c stay NULL. */
#include "vrt.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>

#define NEED(n, name) do { if (argc != (n)) vrt_fail("%s expects %d value(s), got %d", name, n, argc); } while (0)
static int callable(V v) { return v.t == VT_FUNC || v.t == VT_BUILTIN || v.t == VT_BOUND || v.t == VT_TYPE; }
static double num_arg(V v, const char *name) {
    if (v.t == VT_INT) return (double)v.u.i;
    if (v.t == VT_FLOAT) return v.u.f;
    vrt_fail("%s needs a number", name);
}

/* =====================================================================================================
 * The global lock
 * ===================================================================================================== */
typedef struct ThreadRec { VSavedState st; int parked; struct ThreadRec *next; } ThreadRec;
static ThreadRec *threads = NULL;                 /* every thread that runs Vanta code (changed only under the lock) */
static _Thread_local ThreadRec *me = NULL;
static int threads_on = 0, nthreads = 1;
static pthread_mutex_t gmx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gcv = PTHREAD_COND_INITIALIZER;
static int g_held = 0;
static volatile int g_waiting = 0;
static uint64_t g_switches = 0;
static int ticks = 0;
static struct timespec last_switch;

static void gil_take_locked(void) {
    g_waiting++;
    while (g_held) pthread_cond_wait(&gcv, &gmx);
    g_waiting--;
    g_held = 1;
    g_switches++;
    pthread_cond_broadcast(&gcv);
}
static void gil_take(void) { pthread_mutex_lock(&gmx); gil_take_locked(); pthread_mutex_unlock(&gmx); }
static void gil_drop(void) { pthread_mutex_lock(&gmx); g_held = 0; pthread_cond_broadcast(&gcv); pthread_mutex_unlock(&gmx); }
static void park(void) { vrt_save_state(&me->st); me->parked = 1; }
static void unpark(void) { me->parked = 0; vrt_restore_state(&me->st); clock_gettime(CLOCK_MONOTONIC, &last_switch); }

static void *blocking_begin(void) { park(); gil_drop(); return me; }
static void blocking_end(void *p) { (void)p; gil_take(); unpark(); }

/* signals (on_signal): the handler only sets a flag; the Vanta function runs at the next safepoint */
#define NSIGS 32
static volatile sig_atomic_t sig_pending[NSIGS], any_signal = 0;
static V sig_handler[NSIGS];
static const char *sig_name[NSIGS];
static void run_signal_handlers(void) {
    any_signal = 0;
    for (int s = 1; s < NSIGS; s++) if (sig_pending[s]) {
        sig_pending[s] = 0;
        if (sig_handler[s].t == VT_UNDEF || sig_handler[s].t == VT_NIL) continue;
        V arg = vrt_cstr(sig_name[s]);
        vrt_pin(arg);
        vrt_call(sig_handler[s], 1, &arg);
        vrt_unpin(1);
    }
}

static void yield_hook(void) {
    if (any_signal) run_signal_handlers();
    if (!g_waiting || ++ticks < 64) return;
    ticks = 0;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    if ((now.tv_sec - last_switch.tv_sec) * 1000000000L + (now.tv_nsec - last_switch.tv_nsec) < 2000000L) return;
    park();
    pthread_mutex_lock(&gmx);
    g_held = 0;
    uint64_t s = g_switches;
    pthread_cond_broadcast(&gcv);
    while (g_switches == s && g_waiting) pthread_cond_wait(&gcv, &gmx);   /* let someone else in first */
    gil_take_locked();
    pthread_mutex_unlock(&gmx);
    unpark();
}

/* values kept alive outside any scope: running tasks, servers' handlers, signal handlers */
static V *kept = NULL;
static int nkept = 0, capkept = 0;
void vrt_keep(V v) {
    if (nkept == capkept) { capkept = capkept ? capkept * 2 : 32; kept = realloc(kept, sizeof(V) * (size_t)capkept); }
    kept[nkept++] = v;
}
void vrt_unkeep(V v) {
    for (int i = nkept - 1; i >= 0; i--) if (kept[i].t == v.t && kept[i].u.o == v.u.o) { kept[i] = kept[--nkept]; return; }
}
static void mark_hook(void) {
    for (ThreadRec *r = threads; r; r = r->next) if (r->parked) vrt_mark_saved(&r->st);
    for (int i = 0; i < nkept; i++) vrt_mark(kept[i]);
    for (int s = 0; s < NSIGS; s++) vrt_mark(sig_handler[s]);
}

void vrt_threads_init(void) {
    if (threads_on) return;
    threads_on = 1;
    me = calloc(1, sizeof *me);
    me->next = threads;
    threads = me;
    g_held = 1;                                   /* the main thread is running Vanta code right now */
    clock_gettime(CLOCK_MONOTONIC, &last_switch);
    vrt_mark_hook = mark_hook;
    vrt_blocking_begin_hook = blocking_begin;
    vrt_blocking_end_hook = blocking_end;
    vrt_yield_hook = yield_hook;
}
int vrt_thread_count(void) { return nthreads; }

typedef struct { void (*fn)(void *); void *arg; } Start;
static void *thread_main(void *p) {
    Start s = *(Start *)p;
    free(p);
    gil_take();
    ThreadRec *r = calloc(1, sizeof *r);
    r->next = threads;
    threads = r;
    me = r;
    vrt_fresh_state();
    clock_gettime(CLOCK_MONOTONIC, &last_switch);
    s.fn(s.arg);
    for (ThreadRec **pp = &threads; *pp; pp = &(*pp)->next) if (*pp == r) { *pp = r->next; break; }
    VSavedState mine;
    vrt_save_state(&mine);
    free(mine.roots);
    free(mine.pins);
    vrt_fresh_state();
    free(r);
    me = NULL;
    nthreads--;
    vrt_notify_all();
    gil_drop();
    return NULL;
}
void vrt_thread_start(void (*fn)(void *), void *arg) {
    vrt_threads_init();
    Start *s = malloc(sizeof *s);
    s->fn = fn;
    s->arg = arg;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setstacksize(&at, 64u << 20);          /* deep recursion works inside tasks too */
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_t th;
    int rc = pthread_create(&th, &at, thread_main, s);
    pthread_attr_destroy(&at);
    if (rc) { free(s); vrt_fail("could not start a thread: %s", strerror(rc)); }
    nthreads++;
}

/* waiting for "something changed" (a task finished, a channel got a value, a lock was released) */
static pthread_mutex_t nmx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ncv = PTHREAD_COND_INITIALIZER;
static uint64_t nver = 0;
void vrt_notify_all(void) { pthread_mutex_lock(&nmx); nver++; pthread_cond_broadcast(&ncv); pthread_mutex_unlock(&nmx); }
uint64_t vrt_change_seen(void) { pthread_mutex_lock(&nmx); uint64_t v = nver; pthread_mutex_unlock(&nmx); return v; }
static double now_s(void) { struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); return (double)ts.tv_sec + ts.tv_nsec / 1e9; }
static int wait_change_until(uint64_t seen, double deadline) {
    int ok = 1;
    VRT_BLOCKING_BEGIN();
    pthread_mutex_lock(&nmx);
    while (nver == seen) {
        if (deadline < 0) { pthread_cond_wait(&ncv, &nmx); continue; }
        struct timespec ts;
        ts.tv_sec = (time_t)deadline;
        ts.tv_nsec = (long)((deadline - floor(deadline)) * 1e9);
        if (pthread_cond_timedwait(&ncv, &nmx, &ts) == ETIMEDOUT) { ok = nver != seen; break; }
    }
    pthread_mutex_unlock(&nmx);
    VRT_BLOCKING_END();
    return ok;
}
int vrt_wait_change(uint64_t seen, double timeout) { return wait_change_until(seen, timeout < 0 ? -1 : now_s() + timeout); }

/* =====================================================================================================
 * Tasks
 * ===================================================================================================== */
typedef struct Task { V self, callee, args, result; int done, failed, line, errline; char err[1024]; } Task;
static void task_trace(void *p) { Task *t = p; vrt_mark(t->callee); vrt_mark(t->args); vrt_mark(t->result); }
static void task_body(void *p) {
    Task *t = p;
    vrt_line = t->line;
    VTry tr;
    vrt_try_push(&tr);
    if (setjmp(tr.jb) == 0) {
        V r = vrt_call(t->callee, (int)AS_LIST(t->args)->len, AS_LIST(t->args)->items);
        vrt_try_pop();
        t->result = r;
    } else {
        t->failed = 1;
        snprintf(t->err, sizeof t->err, "%s", vrt_errmsg);
        t->errline = vrt_line;
    }
    t->done = 1;
    vrt_unkeep(t->self);
}
static V b_spawn(int argc, V *a) {
    if (argc < 1 || !callable(a[0])) vrt_fail("spawn needs a function to run (and the values to give it)");
    Task *t = calloc(1, sizeof *t);
    t->callee = a[0];
    t->result = VNIL;
    t->args = vrt_list_of(argc - 1, a + 1);
    t->line = vrt_line;
    t->self = vrt_handle("task", t, task_trace, free);
    vrt_keep(t->self);
    vrt_thread_start(task_body, t);
    return t->self;
}
static double timeout_arg(int argc, V *a, int i, const char *name) {
    if (argc <= i || a[i].t == VT_NIL || a[i].t == VT_UNDEF) return -1;
    double d = num_arg(a[i], name);
    return d < 0 ? 0 : d;
}
static V task_wait(int argc, V *a) {
    Task *t = vrt_handle_data(a[0], "task", "wait");
    double timeout = timeout_arg(argc, a, 1, "wait");
    double deadline = timeout < 0 ? -1 : now_s() + timeout;
    while (!t->done) {
        uint64_t seen = vrt_change_seen();
        if (t->done) break;
        if (!wait_change_until(seen, deadline) && !t->done) return VNIL;
    }
    if (t->failed) { vrt_line = t->errline; vrt_fail("%s", t->err); }
    return t->result;
}
static V task_is_done(int argc, V *a) { (void)argc; return VB(((Task *)vrt_handle_data(a[0], "task", "is_done"))->done); }

/* =====================================================================================================
 * Channels
 * ===================================================================================================== */
typedef struct Chan { V *items; int64_t head, len, alloc, cap; int closed; } Chan;
static void chan_trace(void *p) { Chan *c = p; for (int64_t i = 0; i < c->len; i++) vrt_mark(c->items[(c->head + i) % c->alloc]); }
static void chan_free(void *p) { Chan *c = p; free(c->items); free(c); }
static V b_channel(int argc, V *a) {
    if (argc > 1) vrt_fail("channel expects an optional capacity");
    int64_t cap = 0;
    if (argc == 1) { if (a[0].t != VT_INT) vrt_fail("channel needs whole numbers"); cap = a[0].u.i; }
    if (cap < 0) vrt_fail("a channel's capacity can't be negative");
    Chan *c = calloc(1, sizeof *c);
    c->cap = cap;
    return vrt_handle("channel", c, chan_trace, chan_free);
}
static _Noreturn void forever(const char *what) { vrt_fail("%s would wait forever (nothing else is running)", what); }
static V chan_send(int argc, V *a) {
    (void)argc;
    Chan *c = vrt_handle_data(a[0], "channel", "send");
    while (c->cap && c->len >= c->cap && !c->closed) {
        if (vrt_thread_count() <= 1) forever("send");
        wait_change_until(vrt_change_seen(), -1);
    }
    if (c->closed) vrt_fail("can't send on a closed channel");
    if (c->len == c->alloc) {
        int64_t na = c->alloc ? c->alloc * 2 : 8;
        V *ni = malloc(sizeof(V) * (size_t)na);
        for (int64_t i = 0; i < c->len; i++) ni[i] = c->items[(c->head + i) % c->alloc];
        free(c->items);
        c->items = ni; c->alloc = na; c->head = 0;
    }
    c->items[(c->head + c->len) % c->alloc] = a[1];
    c->len++;
    vrt_notify_all();
    return VNIL;
}
static V chan_receive(int argc, V *a) {
    Chan *c = vrt_handle_data(a[0], "channel", "receive");
    double timeout = timeout_arg(argc, a, 1, "receive");
    double deadline = timeout < 0 ? -1 : now_s() + timeout;
    while (!c->len && !c->closed) {
        if (timeout < 0 && vrt_thread_count() <= 1) forever("receive");
        uint64_t seen = vrt_change_seen();
        if (!wait_change_until(seen, deadline) && !c->len) return VNIL;
    }
    if (!c->len) return VNIL;
    V v = c->items[c->head];
    c->head = (c->head + 1) % c->alloc;
    c->len--;
    vrt_notify_all();
    return v;
}
static V chan_close(int argc, V *a) { (void)argc; Chan *c = vrt_handle_data(a[0], "channel", "close"); c->closed = 1; vrt_notify_all(); return VNIL; }

/* =====================================================================================================
 * Locks (reentrant: the same thread may enter a lock it already holds)
 * ===================================================================================================== */
typedef struct VLock { pthread_t owner; int64_t count; } VLock;
static VLock global_lock;
static V b_new_lock(int argc, V *a) { (void)a; NEED(0, "new_lock"); return vrt_handle("lock", calloc(1, sizeof(VLock)), NULL, free); }
static VLock *lock_of(V l) { return l.t == VT_UNDEF || l.t == VT_NIL ? &global_lock : vrt_handle_data(l, "lock", "lock"); }
void vrt_lock_enter(V l) {
    VLock *k = lock_of(l);
    pthread_t self = pthread_self();
    while (k->count && !pthread_equal(k->owner, self)) wait_change_until(vrt_change_seen(), -1);
    k->owner = self;
    k->count++;
}
void vrt_lock_exit(V l) {
    VLock *k = lock_of(l);
    if (k->count > 0 && --k->count == 0 && threads_on) vrt_notify_all();
}

/* =====================================================================================================
 * run_parallel: fork one worker process per chunk, ship plain values back through a pipe
 * ===================================================================================================== */
typedef struct { char *p; size_t len, cap; } Out;
static void oput(Out *o, const void *d, size_t n) {
    if (o->len + n > o->cap) { o->cap = (o->len + n) * 2 + 256; o->p = realloc(o->p, o->cap); }
    memcpy(o->p + o->len, d, n);
    o->len += n;
}
static int ser(Out *o, V v) {
    char tag;
    switch (v.t) {
    case VT_NIL: case VT_UNDEF: tag = 'n'; oput(o, &tag, 1); return 1;
    case VT_BOOL: tag = v.u.i ? 't' : 'f'; oput(o, &tag, 1); return 1;
    case VT_INT: tag = 'i'; oput(o, &tag, 1); oput(o, &v.u.i, 8); return 1;
    case VT_FLOAT: tag = 'd'; oput(o, &tag, 1); oput(o, &v.u.f, 8); return 1;
    case VT_STR: { tag = 's'; int64_t n = AS_STR(v)->len; oput(o, &tag, 1); oput(o, &n, 8); oput(o, AS_STR(v)->data, (size_t)n); return 1; }
    case VT_BYTES: { tag = 'b'; int64_t n = AS_BYTES(v)->len; oput(o, &tag, 1); oput(o, &n, 8); oput(o, AS_BYTES(v)->data, (size_t)n); return 1; }
    case VT_LIST: {
        tag = 'l'; int64_t n = AS_LIST(v)->len; oput(o, &tag, 1); oput(o, &n, 8);
        for (int64_t i = 0; i < n; i++) if (!ser(o, AS_LIST(v)->items[i])) return 0;
        return 1;
    }
    case VT_MAP: {
        VMap *m = AS_MAP(v); tag = 'm'; int64_t n = m->count; oput(o, &tag, 1); oput(o, &n, 8);
        for (int64_t i = 0; i < m->nent; i++) if (m->ents[i].used) { if (!ser(o, m->ents[i].key) || !ser(o, m->ents[i].val)) return 0; }
        return 1;
    }
    default: return 0;
    }
}
typedef struct { const char *p; size_t i, n; } In;
static V deser(In *in) {
    if (in->i >= in->n) vrt_fail("a run_parallel worker stopped unexpectedly");
    char tag = in->p[in->i++];
    int64_t n = 0;
    if (strchr("idslbm", tag)) { if (in->i + 8 > in->n) vrt_fail("a run_parallel worker stopped unexpectedly"); memcpy(&n, in->p + in->i, 8); in->i += 8; }
    switch (tag) {
    case 'n': return VNIL;
    case 't': return VTRUE;
    case 'f': return VFALSE;
    case 'i': return VI(n);
    case 'd': { V f; f.t = VT_FLOAT; f.aux = 0; memcpy(&f.u.f, &n, 8); return f; }
    case 's': { V s = vrt_str(in->p + in->i, n); in->i += (size_t)n; return s; }
    case 'b': { V b = vrt_bytes(n); memcpy(AS_BYTES(b)->data, in->p + in->i, (size_t)n); in->i += (size_t)n; return b; }
    case 'l': { V l = vrt_list(n); for (int64_t k = 0; k < n; k++) vrt_list_push(l, deser(in)); return l; }
    case 'm': { V m = vrt_map(); for (int64_t k = 0; k < n; k++) { V key = deser(in); V val = deser(in); vrt_map_set(m, key, val); } return m; }
    default: vrt_fail("a run_parallel worker stopped unexpectedly");
    }
}
static void write_all(int fd, const char *p, size_t n) {
    while (n) { ssize_t w = write(fd, p, n); if (w < 0) { if (errno == EINTR) continue; return; } p += w; n -= (size_t)w; }
}
static V b_run_parallel(int argc, V *a) {
    if (argc < 2 || argc > 3) vrt_fail("run_parallel expects a function, a list, and an optional number of workers");
    if (!callable(a[0])) vrt_fail("run_parallel needs a function first");
    if (a[1].t != VT_LIST) vrt_fail("run_parallel needs a list of values");
    int64_t n = AS_LIST(a[1])->len, workers;
    if (argc == 3) { if (a[2].t != VT_INT) vrt_fail("run_parallel needs whole numbers"); workers = a[2].u.i; }
    else { long c = sysconf(_SC_NPROCESSORS_ONLN); workers = c > 0 ? c : 2; }
    if (workers > n) workers = n;
    if (workers < 1) workers = 1;
    V out = vrt_list(n);
    vrt_pin(out);
    if (workers <= 1) {
        for (int64_t i = 0; i < AS_LIST(a[1])->len; i++) { V x = AS_LIST(a[1])->items[i]; vrt_list_push(out, vrt_call(a[0], 1, &x)); }
        vrt_unpin(1);
        return out;
    }
    int64_t size = (n + workers - 1) / workers;
    int nk = 0;
    pid_t pids[256];
    int fds[256];
    fflush(stdout);
    for (int64_t start = 0; start < n && nk < 256; start += size, nk++) {
        int p[2];
        if (pipe(p)) vrt_fail("run_parallel couldn't start a worker");
        pid_t pid = fork();
        if (pid < 0) vrt_fail("run_parallel couldn't start a worker");
        if (pid == 0) {                                   /* the worker: compute, send back, vanish */
            close(p[0]);
            Out o = {0};
            VTry tr;
            vrt_try_push(&tr);
            if (setjmp(tr.jb) == 0) {
                V res = vrt_list(size);
                vrt_pin(res);
                for (int64_t i = start; i < start + size && i < n; i++) { V x = AS_LIST(a[1])->items[i]; vrt_list_push(res, vrt_call(a[0], 1, &x)); }
                vrt_try_pop();
                char ok = 'O';
                oput(&o, &ok, 1);
                if (!ser(&o, res)) {
                    o.len = 0;
                    const char *m = "run_parallel results must be plain values (numbers, text, lists, maps, bytes)";
                    char e = 'E'; int line = vrt_line;
                    oput(&o, &e, 1); oput(&o, &line, sizeof line); oput(&o, m, strlen(m));
                }
            } else {
                char e = 'E'; int line = vrt_line;
                o.len = 0;
                oput(&o, &e, 1); oput(&o, &line, sizeof line); oput(&o, vrt_errmsg, strlen(vrt_errmsg));
            }
            fflush(stdout);
            write_all(p[1], o.p, o.len);
            _exit(0);
        }
        close(p[1]);
        pids[nk] = pid;
        fds[nk] = p[0];
    }
    Out bufs[256];
    memset(bufs, 0, sizeof bufs);
    {
        VRT_BLOCKING_BEGIN();
        for (int k = 0; k < nk; k++) {
            char tmp[65536];
            for (;;) {
                ssize_t r = read(fds[k], tmp, sizeof tmp);
                if (r < 0 && errno == EINTR) continue;
                if (r <= 0) break;
                oput(&bufs[k], tmp, (size_t)r);
            }
            close(fds[k]);
            int st;
            while (waitpid(pids[k], &st, 0) < 0 && errno == EINTR) {}
        }
        VRT_BLOCKING_END();
    }
    for (int k = 0; k < nk; k++) {
        if (bufs[k].len >= 1 && bufs[k].p[0] == 'E') {
            char msg[1024]; int line = 0;
            if (bufs[k].len >= 1 + sizeof line) memcpy(&line, bufs[k].p + 1, sizeof line);
            size_t ml = bufs[k].len > 1 + sizeof line ? bufs[k].len - 1 - sizeof line : 0;
            if (ml > sizeof msg - 1) ml = sizeof msg - 1;
            memcpy(msg, bufs[k].p + 1 + sizeof line, ml);
            msg[ml] = 0;
            for (int j = 0; j < nk; j++) free(bufs[j].p);
            vrt_line = line;
            vrt_fail("%s", msg);
        }
    }
    for (int k = 0; k < nk; k++) {
        if (bufs[k].len < 1 || bufs[k].p[0] != 'O') { for (int j = 0; j < nk; j++) free(bufs[j].p); vrt_fail("a run_parallel worker stopped unexpectedly"); }
        In in = {bufs[k].p + 1, 0, bufs[k].len - 1};
        V part = deser(&in);
        for (int64_t i = 0; i < AS_LIST(part)->len; i++) vrt_list_push(out, AS_LIST(part)->items[i]);
        free(bufs[k].p);
    }
    vrt_unpin(1);
    return out;
}

/* =====================================================================================================
 * Signals
 * ===================================================================================================== */
static const struct { const char *name; int num; } SIGS[] = {
    {"INT", SIGINT}, {"TERM", SIGTERM}, {"HUP", SIGHUP}, {"USR1", SIGUSR1}, {"USR2", SIGUSR2}, {"QUIT", SIGQUIT}, {"ALRM", SIGALRM}, {NULL, 0}
};
static int signum_of(V name, const char *fname, const char **canon) {
    V t = vrt_display(name);
    char up[32]; size_t i = 0;
    const char *s = AS_STR(t)->data;
    for (; s[i] && i < sizeof up - 1; i++) up[i] = (char)((s[i] >= 'a' && s[i] <= 'z') ? s[i] - 32 : s[i]);
    up[i] = 0;
    const char *n = strncmp(up, "SIG", 3) == 0 ? up + 3 : up;
    for (int k = 0; SIGS[k].name; k++) if (!strcmp(SIGS[k].name, n)) { if (canon) *canon = SIGS[k].name; return SIGS[k].num; }
    vrt_fail("%s: unknown signal '%s' (use one of INT, TERM, HUP, USR1, USR2, QUIT, ALRM)", fname, s);
}
static void on_sig(int s) { if (s > 0 && s < NSIGS) { sig_pending[s] = 1; any_signal = 1; } }
static V b_on_signal(int argc, V *a) {
    NEED(2, "on_signal");
    const char *canon = NULL;
    int s = signum_of(a[0], "on_signal", &canon);
    if (a[1].t == VT_NIL) { signal(s, SIG_DFL); sig_handler[s] = VNIL; return VNIL; }
    if (!callable(a[1])) vrt_fail("on_signal needs a function to call (or nothing to reset)");
    vrt_threads_init();                          /* the safepoint hook runs the handler */
    sig_handler[s] = a[1];
    sig_name[s] = canon;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_sig;
    sigemptyset(&sa.sa_mask);
    sigaction(s, &sa, NULL);
    return VNIL;
}
static V b_send_signal(int argc, V *a) {
    NEED(2, "send_signal");
    int s = signum_of(a[1], "send_signal", NULL);
    int64_t pid;
    VBuiltinPtr pidf = vrt_find_op(a[0], "process_id");
    if (pidf) pid = pidf(1, a).u.i;
    else if (a[0].t == VT_INT) pid = a[0].u.i;
    else vrt_fail("send_signal needs whole numbers");
    if (kill((pid_t)pid, s)) vrt_fail("could not signal process %lld: %s", (long long)pid, strerror(errno));
    return VNIL;
}

typedef VEntry Entry;
static const Entry thread_table[] = {
    {"spawn", b_spawn}, {"channel", b_channel}, {"new_lock", b_new_lock}, {"run_parallel", b_run_parallel},
    {"on_signal", b_on_signal}, {"send_signal", b_send_signal},
    {NULL, NULL}
};
__attribute__((constructor)) static void vrt_thread_register(void) {
    vrt_register_builtins(thread_table);
    vrt_register_op("task", "wait", task_wait);
    vrt_register_op("task", "is_done", task_is_done);
    vrt_register_op("channel", "send", chan_send);
    vrt_register_op("channel", "receive", chan_receive);
    vrt_register_op("channel", "close", chan_close);
}
