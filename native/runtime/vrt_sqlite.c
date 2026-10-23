/* vantac: optional; libs: -lsqlite3 */
/* Vanta native runtime: SQLite databases — db_open, db_query, db_execute, db_last_id, and close (through the generic
 * close builtin). Behaves like vanta.py, which uses Python's sqlite3 in autocommit mode (isolation_level=None):
 * the same conversions, the same "database error: ..." messages. */
#include "vrt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pwd.h>
#include <unistd.h>
#include <sqlite3.h>

#define NEED(n, name) do { if (argc != (n)) vrt_fail("%s expects %d value(s), got %d", name, n, argc); } while (0)

typedef struct { sqlite3 *db; } DB;

static void db_finalize(void *p) {
    DB *d = p;
    if (d->db) sqlite3_close_v2(d->db);
    free(d);
}

static sqlite3 *db_arg(V v, const char *fname) {
    DB *d = vrt_handle_data(v, "database", fname);
    if (!d->db) vrt_fail("database error: Cannot operate on a closed database.");
    return d->db;
}

/* os.path.expanduser */
static char *expand_user(const char *path) {
    if (path[0] != '~') return strdup(path);
    const char *rest = strchr(path, '/');
    size_t ulen = rest ? (size_t)(rest - path - 1) : strlen(path + 1);
    const char *home = NULL;
    if (ulen == 0) {
        home = getenv("HOME");
        if (!home) { struct passwd *pw = getpwuid(getuid()); if (pw) home = pw->pw_dir; }
    } else {
        char name[256];
        if (ulen >= sizeof name) return strdup(path);
        memcpy(name, path + 1, ulen); name[ulen] = 0;
        struct passwd *pw = getpwnam(name);
        if (pw) home = pw->pw_dir;
    }
    if (!home) return strdup(path);
    size_t hl = strlen(home);
    while (hl > 1 && home[hl - 1] == '/') hl--;
    if (hl == 1 && home[0] == '/' && rest) hl = 0;       /* home "/" + "/x" -> "/x" */
    const char *tail = rest ? rest : "";
    char *out = malloc(hl + strlen(tail) + 2);
    memcpy(out, home, hl);
    strcpy(out + hl, tail);
    if (!out[0]) strcpy(out, "/");
    return out;
}

static V b_db_open(int argc, V *a) {
    NEED(1, "db_open");
    const char *path = vrt_cs(vrt_display(a[0]));
    char *full = strcmp(path, ":memory:") == 0 ? strdup(path) : expand_user(path);
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(full, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL);
    free(full);
    if (rc != SQLITE_OK) {
        char msg[512];
        snprintf(msg, sizeof msg, "%s", db ? sqlite3_errmsg(db) : sqlite3_errstr(rc));
        if (db) sqlite3_close_v2(db);
        vrt_fail("database error: %s", msg);
    }
    sqlite3_busy_timeout(db, 5000);
    DB *d = malloc(sizeof *d);
    d->db = db;
    return vrt_handle("database", d, NULL, db_finalize);
}

static V db_close_op(int argc, V *a) {
    (void)argc;
    DB *d = vrt_handle_data(a[0], "database", "close");
    if (d->db) { sqlite3_close_v2(d->db); d->db = NULL; }
    return VNIL;
}

/* ---- parameters (vanta.py's _db_params): check every value before touching the database ---- */
static void check_value(V v) {
    if (v.t == VT_NIL || v.t == VT_STR || v.t == VT_FLOAT || v.t == VT_INT || v.t == VT_BOOL || v.t == VT_BYTES) return;
    vrt_fail("database values must be numbers, text, bytes, yes/no or nothing");
}
static void check_params(V p) {
    if (p.t == VT_NIL) return;
    if (p.t == VT_LIST) { for (int64_t i = 0; i < AS_LIST(p)->len; i++) check_value(AS_LIST(p)->items[i]); return; }
    if (p.t == VT_MAP) {
        VMap *m = AS_MAP(p);
        for (int64_t i = 0; i < m->nent; i++) if (m->ents[i].used) check_value(m->ents[i].val);
        return;
    }
    vrt_fail("database parameters must be a list (for ?) or a map (for :name)");
}
static int bind_value(sqlite3_stmt *st, int i, V v) {
    switch (v.t) {
    case VT_NIL: return sqlite3_bind_null(st, i);
    case VT_BOOL: case VT_INT: return sqlite3_bind_int64(st, i, v.u.i);
    case VT_FLOAT: return sqlite3_bind_double(st, i, v.u.f);
    case VT_STR: return sqlite3_bind_text(st, i, AS_STR(v)->data, (int)AS_STR(v)->len, SQLITE_TRANSIENT);
    case VT_BYTES: return sqlite3_bind_blob(st, i, AS_BYTES(v)->len ? (const void *)AS_BYTES(v)->data : "", (int)AS_BYTES(v)->len, SQLITE_TRANSIENT);
    default: return SQLITE_MISMATCH;
    }
}
/* returns NULL, or a message (in buf) for a binding problem */
static const char *bind_params(sqlite3_stmt *st, V p, char *buf, size_t bn) {
    int need = sqlite3_bind_parameter_count(st);
    if (p.t == VT_MAP) {
        for (int i = 1; i <= need; i++) {
            const char *name = sqlite3_bind_parameter_name(st, i);
            if (!name) { snprintf(buf, bn, "Binding %d has no name, but you supplied a dictionary (which has only names).", i); return buf; }
            int found = 0;
            V key = vrt_cstr(name + 1);
            V v = VNIL;
            VMap *m = AS_MAP(p);
            for (int64_t k = 0; k < m->nent; k++) {
                if (!m->ents[k].used) continue;
                V dk = m->ents[k].key;
                if (dk.t != VT_STR) dk = vrt_display(dk);
                if (vrt_equal(dk, key)) { v = m->ents[k].val; found = 1; }
            }
            if (!found) { snprintf(buf, bn, "You did not supply a value for binding parameter %s.", name); return buf; }
            if (bind_value(st, i, v) != SQLITE_OK) { snprintf(buf, bn, "Error binding parameter %s", name); return buf; }
        }
        return NULL;
    }
    int64_t have = p.t == VT_LIST ? AS_LIST(p)->len : 0;
    if (have != need) {
        snprintf(buf, bn, "Incorrect number of bindings supplied. The current statement uses %d, and there are %lld supplied.", need, (long long)have);
        return buf;
    }
    for (int i = 1; i <= need; i++)
        if (bind_value(st, i, AS_LIST(p)->items[i - 1]) != SQLITE_OK) { snprintf(buf, bn, "Error binding parameter %d", i); return buf; }
    return NULL;
}

/* Python's check that only one statement was given: anything but whitespace and comments after it is an error */
static int more_sql(const char *s) {
    while (*s) {
        if (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r' || *s == '\f') { s++; continue; }
        if (s[0] == '-' && s[1] == '-') { while (*s && *s != '\n') s++; continue; }
        if (s[0] == '/' && s[1] == '*') { const char *e = strstr(s + 2, "*/"); if (!e) return 0; s = e + 2; continue; }
        return 1;
    }
    return 0;
}

static _Noreturn void db_error(sqlite3 *db, sqlite3_stmt *st) {
    char msg[1000];
    snprintf(msg, sizeof msg, "%s", sqlite3_errmsg(db));
    if (st) sqlite3_finalize(st);
    vrt_fail("database error: %s", msg);
}
static _Noreturn void db_error_msg(sqlite3_stmt *st, const char *m) {
    char msg[1000];
    snprintf(msg, sizeof msg, "%s", m);
    if (st) sqlite3_finalize(st);
    vrt_fail("database error: %s", msg);
}

/* prepare one statement and bind; *st is NULL for empty SQL */
static sqlite3_stmt *prepare(sqlite3 *db, V sqlv, V params) {
    VStr *sql = AS_STR(sqlv);
    sqlite3_stmt *st = NULL;
    const char *tail = NULL;
    if (sqlite3_prepare_v2(db, sql->data, (int)sql->len + 1, &st, &tail) != SQLITE_OK) db_error(db, st);
    if (tail && more_sql(tail)) db_error_msg(st, "You can only execute one statement at a time.");
    if (!st) return NULL;
    char buf[512];
    const char *err = bind_params(st, params, buf, sizeof buf);
    if (err) db_error_msg(st, err);
    return st;
}

static V column_value(sqlite3_stmt *st, int i) {
    switch (sqlite3_column_type(st, i)) {
    case SQLITE_INTEGER: return VI(sqlite3_column_int64(st, i));
    case SQLITE_FLOAT: return VF(sqlite3_column_double(st, i));
    case SQLITE_TEXT: return vrt_str((const char *)sqlite3_column_text(st, i), sqlite3_column_bytes(st, i));
    case SQLITE_BLOB: {
        const void *p = sqlite3_column_blob(st, i);
        int n = sqlite3_column_bytes(st, i);
        V b = vrt_bytes(n);
        if (n) memcpy(AS_BYTES(b)->data, p, (size_t)n);
        return b;
    }
    default: return VNIL;
    }
}

static V b_db_query(int argc, V *a) {
    if (argc < 2 || argc > 3) vrt_fail("db_query expects a database, SQL and optional parameters");
    sqlite3 *db = db_arg(a[0], "db_query");
    V sql = vrt_display(a[1]);
    V params = argc == 3 ? a[2] : VNIL;
    check_params(params);
    sqlite3_stmt *st = prepare(db, sql, params);
    V out = vrt_list(0);
    if (!st) return out;
    int ncol = sqlite3_column_count(st);
    V cols = vrt_list(ncol);
    for (int i = 0; i < ncol; i++) vrt_list_push(cols, vrt_cstr(sqlite3_column_name(st, i)));
    for (;;) {
        int rc = sqlite3_step(st);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) db_error(db, st);
        if (ncol == 0) continue;
        V row = vrt_map();
        for (int i = 0; i < ncol; i++) vrt_map_set(row, AS_LIST(cols)->items[i], column_value(st, i));
        vrt_list_push(out, row);
    }
    sqlite3_finalize(st);
    return ncol == 0 ? vrt_list(0) : out;
}

static V b_db_execute(int argc, V *a) {
    if (argc < 2 || argc > 3) vrt_fail("db_execute expects a database, SQL and optional parameters");
    sqlite3 *db = db_arg(a[0], "db_execute");
    int before = sqlite3_total_changes(db);
    V sql = vrt_display(a[1]);
    if (argc == 3 && a[2].t != VT_NIL) {
        check_params(a[2]);
        sqlite3_stmt *st = prepare(db, sql, a[2]);
        if (st) {
            int rc;
            while ((rc = sqlite3_step(st)) == SQLITE_ROW) {}
            if (rc != SQLITE_DONE) db_error(db, st);
            sqlite3_finalize(st);
        }
    } else {
        char *err = NULL;
        if (sqlite3_exec(db, AS_STR(sql)->data, NULL, NULL, &err) != SQLITE_OK) {
            char msg[1000];
            snprintf(msg, sizeof msg, "%s", err ? err : sqlite3_errmsg(db));
            sqlite3_free(err);
            vrt_fail("database error: %s", msg);
        }
    }
    return VI(sqlite3_total_changes(db) - before);
}

static V b_db_last_id(int argc, V *a) {
    NEED(1, "db_last_id");
    sqlite3 *db = db_arg(a[0], "db_last_id");
    return VI(sqlite3_last_insert_rowid(db));
}

typedef VEntry Entry;
static const Entry sqlite_table[] = {
    {"db_open", b_db_open}, {"db_query", b_db_query}, {"db_execute", b_db_execute}, {"db_last_id", b_db_last_id},
    {NULL, NULL}
};
__attribute__((constructor)) static void vrt_sqlite_register(void) {
    vrt_register_builtins(sqlite_table);
    vrt_register_op("database", "close", db_close_op);
}
