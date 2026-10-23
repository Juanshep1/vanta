/* vantac: optional; needs: vrt_io.c */
#define _GNU_SOURCE
/* Vanta native runtime: the system side of the standard library — child processes with pipes, environment, exit,
 * file handles for big files, walking folders, glob, temp files, path helpers, and dates/times with time zones.
 * Same names, results and messages as vanta.py. Waiting on a child process or its pipes lets go of the global lock
 * (vrt_thread.c) so other tasks keep running. */
#include "vrt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <math.h>
#include <dirent.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>

extern char **environ;
#define NEED(n, name) do { if (argc != (n)) vrt_fail("%s expects %d value(s), got %d", name, n, argc); } while (0)
static int64_t int_arg(V v, const char *name) { if (v.t != VT_INT) vrt_fail("%s needs whole numbers", name); return v.u.i; }
static double num_arg(V v, const char *name) {
    if (v.t == VT_INT) return (double)v.u.i;
    if (v.t == VT_FLOAT) return v.u.f;
    vrt_fail("%s needs a number", name);
}
static V tidy(double d) { if (d == floor(d) && fabs(d) < 9e18) return VI((int64_t)d); return VF(d); }
static const char *cs(V v) { return AS_STR(vrt_display(v))->data; }   /* valid until the next collection */
typedef struct { char *p; size_t len, cap; } Buf;
static void bput(Buf *b, const void *s, size_t n) {
    if (b->len + n + 1 > b->cap) { b->cap = (b->len + n + 1) * 2 + 256; b->p = realloc(b->p, b->cap); }
    memcpy(b->p + b->len, s, n); b->len += n; b->p[b->len] = 0;
}
static void bputs(Buf *b, const char *s) { bput(b, s, strlen(s)); }
static char *data_of(V v, size_t *n) {
    if (v.t == VT_BYTES) { *n = (size_t)AS_BYTES(v)->len; char *p = malloc(*n + 1); memcpy(p, AS_BYTES(v)->data, *n); return p; }
    V s = vrt_display(v); *n = (size_t)AS_STR(s)->len; char *p = malloc(*n + 1); memcpy(p, AS_STR(s)->data, *n); p[*n] = 0; return p;
}
static char *expand_user(const char *p) {
    if (p[0] == '~' && (p[1] == '/' || !p[1])) {
        const char *h = getenv("HOME"); if (!h) h = "";
        char *o = malloc(strlen(h) + strlen(p) + 1); sprintf(o, "%s%s", h, p + 1); return o;
    }
    return strdup(p);
}

/* =====================================================================================================
 * Paths (os.path rules)
 * ===================================================================================================== */
static void join2(Buf *b, const char *part) {
    if (part[0] == '/') { b->len = 0; if (b->p) b->p[0] = 0; }
    else if (b->len && b->p[b->len - 1] != '/') bputs(b, "/");
    bputs(b, part);
}
static V b_path_join(int argc, V *a) {
    Buf b = {0}; bput(&b, "", 0);
    for (int i = 0; i < argc; i++) join2(&b, cs(a[i]));
    V r = vrt_str(b.p, (int64_t)b.len); free(b.p); return r;
}
static V dirname_of(const char *p) {
    const char *slash = strrchr(p, '/');
    if (!slash) return vrt_cstr("");
    size_t n = (size_t)(slash - p) + 1;
    size_t k = n;
    while (k && p[k - 1] == '/') k--;
    if (k == 0) return vrt_str(p, (int64_t)n);       /* all slashes: keep them */
    return vrt_str(p, (int64_t)k);
}
static V b_dirname(int argc, V *a) { NEED(1, "dirname"); return dirname_of(cs(a[0])); }
static V b_basename(int argc, V *a) { NEED(1, "basename"); const char *p = cs(a[0]); const char *s = strrchr(p, '/'); return vrt_cstr(s ? s + 1 : p); }
static V b_extname(int argc, V *a) {
    NEED(1, "extname");
    const char *p = cs(a[0]); const char *base = strrchr(p, '/'); base = base ? base + 1 : p;
    const char *dot = strrchr(base, '.');
    if (!dot) return vrt_cstr("");
    const char *q = base; while (*q == '.') q++;
    if (dot < q) return vrt_cstr("");
    return vrt_cstr(dot);
}
static V b_home_dir(int argc, V *a) { (void)a; NEED(0, "home_dir"); char *h = expand_user("~"); V r = vrt_cstr(h); free(h); return r; }
static char *normpath(const char *path) {
    if (!*path) return strdup(".");
    int lead = path[0] == '/' ? ((path[1] == '/' && path[2] != '/') ? 2 : 1) : 0;
    char *copy = strdup(path);
    char **parts = malloc(sizeof(char *) * (strlen(path) + 1)); int n = 0;
    for (char *tok = strtok(copy, "/"); tok; tok = strtok(NULL, "/")) {
        if (!strcmp(tok, ".")) continue;
        if (!strcmp(tok, "..") && ((n && strcmp(parts[n - 1], "..")) || lead)) { if (n && strcmp(parts[n - 1], "..")) n--; continue; }
        parts[n++] = tok;
    }
    Buf b = {0}; bput(&b, "", 0);
    for (int i = 0; i < lead; i++) bputs(&b, "/");
    for (int i = 0; i < n; i++) { if (i) bputs(&b, "/"); bputs(&b, parts[i]); }
    if (!b.len) bputs(&b, ".");
    free(parts); free(copy);
    return b.p;
}
static V b_absolute_path(int argc, V *a) {
    NEED(1, "absolute_path");
    char *p = expand_user(cs(a[0]));
    Buf b = {0}; bput(&b, "", 0);
    if (p[0] != '/') { char cwd[4096]; if (getcwd(cwd, sizeof cwd)) bputs(&b, cwd); }
    join2(&b, p);
    char *n = normpath(b.p);
    V r = vrt_cstr(n); free(n); free(b.p); free(p); return r;
}
static V b_current_dir(int argc, V *a) { (void)a; NEED(0, "current_dir"); char cwd[4096]; if (!getcwd(cwd, sizeof cwd)) vrt_fail("could not read the current folder"); return vrt_cstr(cwd); }
static V b_change_dir(int argc, V *a) {
    NEED(1, "change_dir");
    char *p = expand_user(cs(a[0]));
    if (chdir(p)) { char m[4200]; snprintf(m, sizeof m, "could not change to %s: %s", p, strerror(errno)); free(p); vrt_fail("%s", m); }
    free(p); return VNIL;
}
static _Noreturn void os_fail(const char *what, const char *path, int err) { vrt_fail("%s: [Errno %d] %s: '%s'", what, err, strerror(err), path); }
static V b_file_mtime(int argc, V *a) {
    NEED(1, "file_mtime"); const char *p = cs(a[0]); struct stat st;
    if (stat(p, &st)) os_fail("could not read file time", p, errno);
    return VI((int64_t)st.st_mtime);
}
static int mkdirs(const char *path) {
    char buf[4096]; snprintf(buf, sizeof buf, "%s", path);
    for (char *c = buf + 1; *c; c++) if (*c == '/') { *c = 0; mkdir(buf, 0755); *c = '/'; }
    return mkdir(buf, 0755) == 0 || errno == EEXIST ? 0 : -1;
}
static int copy_file(const char *src, const char *dst) {
    FILE *in = fopen(src, "rb"); if (!in) return -1;
    FILE *out = fopen(dst, "wb"); if (!out) { int e = errno; fclose(in); errno = e; return -1; }
    char buf[65536]; size_t n;
    while ((n = fread(buf, 1, sizeof buf, in)) > 0) fwrite(buf, 1, n, out);
    fclose(in); fclose(out);
    struct stat st; if (stat(src, &st) == 0) chmod(dst, st.st_mode & 07777);
    return 0;
}
static int copy_tree(const char *src, const char *dst) {
    struct stat st;
    if (stat(src, &st)) return -1;
    if (!S_ISDIR(st.st_mode)) return copy_file(src, dst);
    mkdirs(dst);
    DIR *d = opendir(src); if (!d) return -1;
    struct dirent *e; int rc = 0;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char s2[4096], d2[4096];
        snprintf(s2, sizeof s2, "%s/%s", src, e->d_name); snprintf(d2, sizeof d2, "%s/%s", dst, e->d_name);
        if (copy_tree(s2, d2)) rc = -1;
    }
    closedir(d);
    return rc;
}
static V b_copy_path(int argc, V *a) {
    NEED(2, "copy_path");
    char *src = strdup(cs(a[0])), *dst = strdup(cs(a[1]));
    struct stat st;
    int rc;
    if (stat(src, &st) == 0 && S_ISDIR(st.st_mode)) rc = copy_tree(src, dst);
    else {
        V dn = dirname_of(dst); const char *d = AS_STR(dn)->data;
        mkdirs(*d ? d : ".");
        rc = copy_file(src, dst);
    }
    int e = errno;
    if (rc) { char m[600]; snprintf(m, sizeof m, "could not copy %s", src); free(src); free(dst); vrt_fail("%s: [Errno %d] %s: '%s'", m, e, strerror(e), m + 15); }
    free(src); free(dst);
    return VNIL;
}
static V b_move_path(int argc, V *a) {
    NEED(2, "move_path");
    char *src = strdup(cs(a[0])), *dst = strdup(cs(a[1]));
    V dn = dirname_of(dst);
    if (AS_STR(dn)->len) mkdirs(AS_STR(dn)->data);
    struct stat st;
    char target[4096];
    if (stat(dst, &st) == 0 && S_ISDIR(st.st_mode)) { const char *b = strrchr(src, '/'); snprintf(target, sizeof target, "%s/%s", dst, b ? b + 1 : src); }
    else snprintf(target, sizeof target, "%s", dst);
    if (rename(src, target)) {
        int e = errno;
        if (e == EXDEV && copy_tree(src, target) == 0) { /* across disks: copy, then remove */
            char cmd[8300]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", src); if (system(cmd)) {}
        } else { char m[4200]; snprintf(m, sizeof m, "could not move %s: [Errno %d] %s: '%s'", src, e, strerror(e), src); free(src); free(dst); vrt_fail("%s", m); }
    }
    free(src); free(dst);
    return VNIL;
}

/* =====================================================================================================
 * Walking folders, glob, temp files
 * ===================================================================================================== */
typedef struct { char **v; int n, cap; } SList;
static void sl_add(SList *l, const char *s) { if (l->n == l->cap) { l->cap = l->cap ? l->cap * 2 : 32; l->v = realloc(l->v, sizeof(char *) * (size_t)l->cap); } l->v[l->n++] = strdup(s); }
static int cmp_s(const void *x, const void *y) { return strcmp(*(char *const *)x, *(char *const *)y); }
static V sl_list(SList *l) {
    qsort(l->v, (size_t)l->n, sizeof(char *), cmp_s);
    V out = vrt_list(l->n);
    for (int i = 0; i < l->n; i++) { vrt_list_push(out, vrt_cstr(l->v[i])); free(l->v[i]); }
    free(l->v);
    return out;
}
static void joined(char *out, size_t n, const char *base, const char *name) {
    if (!*base) snprintf(out, n, "%s", name);
    else if (base[strlen(base) - 1] == '/') snprintf(out, n, "%s%s", base, name);
    else snprintf(out, n, "%s/%s", base, name);
}
static void walk(const char *dir, SList *out) {
    DIR *d = opendir(dir); if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char p[4096]; joined(p, sizeof p, dir, e->d_name);
        struct stat lst, st;
        if (lstat(p, &lst)) continue;
        int isdir = stat(p, &st) == 0 && S_ISDIR(st.st_mode);
        if (isdir) { if (!S_ISLNK(lst.st_mode)) walk(p, out); }
        else sl_add(out, p);
    }
    closedir(d);
}
static V b_walk_dir(int argc, V *a) {
    NEED(1, "walk_dir");
    char *top = strdup(cs(a[0]));
    struct stat st;
    if (stat(top, &st) || !S_ISDIR(st.st_mode)) { char m[4200]; snprintf(m, sizeof m, "could not walk %s: not a folder", top); free(top); vrt_fail("%s", m); }
    SList l = {0};
    walk(top, &l);
    free(top);
    return sl_list(&l);
}
/* shell-style matching, the same rules as vanta.py's _fnmatch */
static int fnm(const char *name, const char *pat) {
    while (*pat) {
        char c = *pat;
        if (c == '*') {
            while (*pat == '*') pat++;
            if (!*pat) return 1;
            for (const char *k = name; ; k++) { if (fnm(k, pat)) return 1; if (!*k) return 0; }
        }
        if (!*name) return 0;
        if (c == '?') { name++; pat++; continue; }
        if (c == '[') {
            const char *k = pat + 1;
            int neg = *k == '!';
            if (neg) k++;
            const char *start = k; int hit = 0;
            while (*k && (*k != ']' || k == start)) {
                if (k[1] == '-' && k[2] && k[2] != ']') { if (k[0] <= *name && *name <= k[2]) hit = 1; k += 3; }
                else { if (*k == *name) hit = 1; k++; }
            }
            if (!*k) { if (*name != '[') return 0; name++; pat++; continue; }
            if (hit == neg) return 0;
            name++; pat = k + 1;
            continue;
        }
        if (c != *name) return 0;
        name++; pat++;
    }
    return !*name;
}
static int is_dir(const char *p) { struct stat st; return stat(p, &st) == 0 && S_ISDIR(st.st_mode); }
static int is_link(const char *p) { struct stat st; return lstat(p, &st) == 0 && S_ISLNK(st.st_mode); }
static int lexists(const char *p) { struct stat st; return lstat(p, &st) == 0; }
static void glob_walk(const char *base, char **parts, int np, int i, SList *res) {
    if (i == np) {
        if (!*base) return;
        for (int k = 0; k < res->n; k++) if (!strcmp(res->v[k], base)) return;
        sl_add(res, base);
        return;
    }
    const char *part = parts[i];
    if (!strcmp(part, "**")) {
        glob_walk(base, parts, np, i + 1, res);
        SList names = {0};
        DIR *d = opendir(*base ? base : ".");
        if (d) { struct dirent *e; while ((e = readdir(d))) if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) sl_add(&names, e->d_name); closedir(d); }
        qsort(names.v, (size_t)names.n, sizeof(char *), cmp_s);
        for (int k = 0; k < names.n; k++) {
            char p[4096]; joined(p, sizeof p, base, names.v[k]);
            if (names.v[k][0] != '.' && is_dir(p) && !is_link(p)) glob_walk(p, parts, np, i, res);
            free(names.v[k]);
        }
        free(names.v);
    } else if (strpbrk(part, "*?[")) {
        SList names = {0};
        DIR *d = opendir(*base ? base : ".");
        if (d) { struct dirent *e; while ((e = readdir(d))) if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) sl_add(&names, e->d_name); closedir(d); }
        qsort(names.v, (size_t)names.n, sizeof(char *), cmp_s);
        for (int k = 0; k < names.n; k++) {
            const char *n = names.v[k];
            if (!(n[0] == '.' && part[0] != '.') && fnm(n, part)) {
                char p[4096]; joined(p, sizeof p, base, n);
                if (i + 1 == np || is_dir(p)) glob_walk(p, parts, np, i + 1, res);
            }
            free(names.v[k]);
        }
        free(names.v);
    } else {
        char p[4096]; joined(p, sizeof p, base, part);
        if (lexists(p) && (i + 1 == np || is_dir(p))) glob_walk(p, parts, np, i + 1, res);
    }
}
static V b_glob(int argc, V *a) {
    NEED(1, "glob");
    char *pat = expand_user(cs(a[0]));
    char *copy = strdup(pat);
    char **parts = malloc(sizeof(char *) * (strlen(pat) + 1)); int np = 0;
    for (char *t = strtok(copy, "/"); t; t = strtok(NULL, "/")) parts[np++] = t;
    SList res = {0};
    glob_walk(pat[0] == '/' ? "/" : "", parts, np, 0, &res);
    free(parts); free(copy); free(pat);
    return sl_list(&res);
}
static V b_matches_pattern(int argc, V *a) { NEED(2, "matches_pattern"); V n = vrt_display(a[0]); vrt_pin(n); int r = fnm(AS_STR(n)->data, cs(a[1])); vrt_unpin(1); return VB(r); }
static void tmp_base(char *out, size_t n) {
    const char *t = getenv("TMPDIR"); if (!t || !*t) t = "/tmp";
    snprintf(out, n, "%s", t);
    size_t l = strlen(out); while (l > 1 && out[l - 1] == '/') out[--l] = 0;
}
static V b_temp_file(int argc, V *a) {
    if (argc > 1) vrt_fail("temp_file expects an optional ending like \".txt\"");
    char dir[2048], tmpl[4096]; tmp_base(dir, sizeof dir);
    const char *suf = argc ? cs(a[0]) : "";
    snprintf(tmpl, sizeof tmpl, "%s/vantaXXXXXX%s", dir, suf);
    int fd = mkstemps(tmpl, (int)strlen(suf));
    if (fd < 0) vrt_fail("could not make a temp file: %s", strerror(errno));
    close(fd);
    return vrt_cstr(tmpl);
}
static V b_temp_dir(int argc, V *a) {
    (void)a; NEED(0, "temp_dir");
    char dir[2048], tmpl[4096]; tmp_base(dir, sizeof dir);
    snprintf(tmpl, sizeof tmpl, "%s/vantaXXXXXX", dir);
    if (!mkdtemp(tmpl)) vrt_fail("could not make a temp folder: %s", strerror(errno));
    return vrt_cstr(tmpl);
}

/* =====================================================================================================
 * File handles
 * ===================================================================================================== */
typedef struct File { FILE *f; } File;
static void file_free(void *p) { File *f = p; if (f->f) fclose(f->f); free(f); }
static File *file_of(V v, const char *name) {
    File *f = vrt_handle_data(v, "file", name);
    if (!f->f) vrt_fail("%s: that file is closed", name);
    return f;
}
static File *open_file_of(V v) { File *f = vrt_handle_data(v, "file", "read_line"); if (!f->f) vrt_fail("that file is closed"); return f; }
static V b_open_file(int argc, V *a) {
    if (argc < 1 || argc > 2) vrt_fail("open_file expects a path and an optional mode (read, write, append, update)");
    char *path = expand_user(cs(a[0]));
    char mode[32] = "read";
    if (argc == 2) { snprintf(mode, sizeof mode, "%s", cs(a[1])); for (char *c = mode; *c; c++) if (*c >= 'A' && *c <= 'Z') *c += 32; }
    const char *m = !strcmp(mode, "read") || !strcmp(mode, "r") ? "rb" : !strcmp(mode, "write") || !strcmp(mode, "w") ? "wb"
                  : !strcmp(mode, "append") || !strcmp(mode, "a") ? "ab" : !strcmp(mode, "update") || !strcmp(mode, "r+") ? "r+b" : NULL;
    if (!m) { free(path); vrt_fail("open_file: unknown mode '%s' (use read, write, append or update)", mode); }
    FILE *fp = fopen(path, m);
    if (!fp) { char msg[4200]; snprintf(msg, sizeof msg, "could not open %s: %s", path, strerror(errno)); free(path); vrt_fail("%s", msg); }
    free(path);
    File *f = calloc(1, sizeof *f); f->f = fp;
    return vrt_handle("file", f, NULL, file_free);
}
static V file_read_line(int argc, V *a) {
    (void)argc; File *f = open_file_of(a[0]);
    Buf b = {0}; int c, any = 0;
    clearerr(f->f);
    while ((c = fgetc(f->f)) != EOF) { any = 1; if (c == '\n') break; char ch = (char)c; bput(&b, &ch, 1); }
    if (ferror(f->f)) { free(b.p); vrt_fail("could not read from that file"); }
    if (!any) { free(b.p); return VNIL; }
    size_t n = b.len; if (n && b.p[n - 1] == '\r') n--;
    V r = vrt_str(b.p ? b.p : "", (int64_t)n); free(b.p); return r;
}
static Buf read_rest(FILE *fp) {
    Buf b = {0}; bput(&b, "", 0); char tmp[65536]; size_t n;
    clearerr(fp);
    while ((n = fread(tmp, 1, sizeof tmp, fp)) > 0) bput(&b, tmp, n);
    return b;
}
static V file_read_all(int argc, V *a) {
    (void)argc; File *f = open_file_of(a[0]);
    Buf b = read_rest(f->f);
    if (ferror(f->f)) { free(b.p); vrt_fail("could not read from that file"); }
    V r = vrt_str(b.p, (int64_t)b.len); free(b.p); return r;
}
static V file_write(int argc, V *a) {
    (void)argc; File *f = open_file_of(a[0]);
    size_t n; char *d = data_of(a[1], &n);
    size_t w = fwrite(d, 1, n, f->f); free(d);
    if (w != n) { clearerr(f->f); vrt_fail("could not write to that file"); }
    return VNIL;
}
static V file_close(int argc, V *a) { (void)argc; File *f = vrt_handle_data(a[0], "file", "close"); if (f->f) { fclose(f->f); f->f = NULL; } return VNIL; }
static V read_n(V fv, V nv, const char *name, int as_bytes) {
    File *f = file_of(fv, name);
    int64_t n = int_arg(nv, name);
    if (n < 0) { Buf b = read_rest(f->f); V r = as_bytes ? vrt_bytes((int64_t)b.len) : vrt_str(b.p, (int64_t)b.len); if (as_bytes) memcpy(AS_BYTES(r)->data, b.p, b.len); free(b.p); return r; }
    char *buf = malloc((size_t)n + 1);
    size_t got = fread(buf, 1, (size_t)n, f->f);
    V r;
    if (as_bytes) { r = vrt_bytes((int64_t)got); memcpy(AS_BYTES(r)->data, buf, got); }
    else r = vrt_str(buf, (int64_t)got);
    free(buf);
    return r;
}
static V b_read_chunk(int argc, V *a) { NEED(2, "read_chunk"); return read_n(a[0], a[1], "read_chunk", 0); }
static V b_read_chunk_bytes(int argc, V *a) { NEED(2, "read_chunk_bytes"); return read_n(a[0], a[1], "read_chunk_bytes", 1); }
static V b_seek(int argc, V *a) {
    if (argc < 2 || argc > 3) vrt_fail("seek expects a file, a position and an optional \"start\", \"current\" or \"end\"");
    File *f = file_of(a[0], "seek");
    int64_t pos = int_arg(a[1], "seek");
    const char *w = argc == 3 ? cs(a[2]) : "start";
    int wh = !strcmp(w, "start") ? SEEK_SET : !strcmp(w, "current") ? SEEK_CUR : !strcmp(w, "end") ? SEEK_END : -1;
    if (wh < 0) vrt_fail("seek counts from \"start\", \"current\" or \"end\"");
    if (wh == SEEK_SET && pos < 0) vrt_fail("seek failed: negative seek position %lld", (long long)pos);
    if (fseeko(f->f, (off_t)pos, wh)) vrt_fail("seek failed: [Errno %d] %s", errno, strerror(errno));
    return VNIL;
}
static V b_tell(int argc, V *a) { NEED(1, "tell"); return VI((int64_t)ftello(file_of(a[0], "tell")->f)); }

/* =====================================================================================================
 * Processes
 * ===================================================================================================== */
typedef struct Proc { pid_t pid; int in, out, err; int exited, status; Buf buf; } Proc;
static int proc_code(int st) { return WIFEXITED(st) ? WEXITSTATUS(st) : WIFSIGNALED(st) ? -WTERMSIG(st) : 0; }
static void proc_reap(Proc *p, int block) {
    if (p->exited) return;
    int st; pid_t r;
    do { r = waitpid(p->pid, &st, block ? 0 : WNOHANG); } while (r < 0 && errno == EINTR);
    if (r == p->pid) { p->exited = 1; p->status = proc_code(st); }
}
static void proc_free(void *v) {
    Proc *p = v;
    if (p->in >= 0) close(p->in);
    if (p->out >= 0) close(p->out);
    if (p->err >= 0) close(p->err);
    if (!p->exited) { proc_reap(p, 0); if (!p->exited) { kill(p->pid, SIGKILL); proc_reap(p, 1); } }
    free(p->buf.p); free(p);
}
typedef struct { char **argv; char *cwd; char **envset; int nenv; char *label; } Cmd;
static void cmd_free(Cmd *c) {
    for (char **p = c->argv; p && *p; p++) free(*p);
    free(c->argv); free(c->cwd);
    for (int i = 0; i < c->nenv; i++) free(c->envset[i]);
    free(c->envset); free(c->label);
}
static void cmd_build(Cmd *c, V cmd, V opts, const char *name) {
    memset(c, 0, sizeof *c);
    if (opts.t != VT_UNDEF && opts.t != VT_NIL && opts.t != VT_MAP) vrt_fail("%s's options must be a map", name);
    if (cmd.t == VT_LIST) {
        VList *l = AS_LIST(cmd);
        c->argv = calloc((size_t)l->len + 1, sizeof(char *));
        for (int64_t i = 0; i < l->len; i++) c->argv[i] = strdup(cs(l->items[i]));
        V d = vrt_display(cmd); c->label = strdup(AS_STR(d)->data);
    } else {
        c->argv = calloc(4, sizeof(char *));
        c->argv[0] = strdup("/bin/sh"); c->argv[1] = strdup("-c"); c->argv[2] = strdup(cs(cmd));
        c->label = strdup(c->argv[2]);
    }
    if (opts.t == VT_MAP) {
        int f; V d = vrt_map_get(opts, vrt_cstr("dir"), &f);
        if (f && d.t != VT_NIL) c->cwd = expand_user(cs(d));
        V e = vrt_map_get(opts, vrt_cstr("env"), &f);
        if (f && e.t == VT_MAP) {
            VMap *m = AS_MAP(e);
            c->envset = calloc((size_t)m->count * 2 + 1, sizeof(char *));
            for (int64_t i = 0; i < m->nent; i++) if (m->ents[i].used) {
                c->envset[c->nenv++] = strdup(cs(m->ents[i].key));
                c->envset[c->nenv++] = strdup(cs(m->ents[i].val));
            }
        }
    }
}
/* fork + exec with pipes; stdin_mode: 0 inherit, 1 pipe, 2 /dev/null. err_mode: 1 pipe, 2 merge into stdout.
 * Returns the pid, or -1 with errno set when the program couldn't start. */
static pid_t start_child(Cmd *c, int stdin_mode, int err_mode, int *in, int *out, int *err) {
    int pi[2] = {-1, -1}, po[2], pe[2] = {-1, -1}, px[2];
    if (stdin_mode == 1 && pipe(pi)) return -1;
    if (pipe(po) || (err_mode == 1 && pipe(pe)) || pipe(px)) return -1;
    fcntl(px[1], F_SETFD, FD_CLOEXEC);
    fflush(stdout);
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        if (stdin_mode == 1) { dup2(pi[0], 0); close(pi[0]); close(pi[1]); }
        else if (stdin_mode == 2) { int dn = open("/dev/null", O_RDONLY); dup2(dn, 0); close(dn); }
        dup2(po[1], 1);
        if (err_mode == 2) dup2(po[1], 2); else dup2(pe[1], 2);
        close(po[0]); close(po[1]);
        if (err_mode == 1) { close(pe[0]); close(pe[1]); }
        close(px[0]);
        for (int fd = 3; fd < 256; fd++) if (fd != px[1]) close(fd);
        signal(SIGPIPE, SIG_DFL);
        if (c->cwd && chdir(c->cwd)) { int e = errno; if (write(px[1], &e, sizeof e)) {} _exit(127); }
        for (int i = 0; i + 1 < c->nenv; i += 2) setenv(c->envset[i], c->envset[i + 1], 1);
        execvp(c->argv[0], c->argv);
        int e = errno; if (write(px[1], &e, sizeof e)) {}
        _exit(127);
    }
    close(px[1]);
    if (stdin_mode == 1) close(pi[0]);
    close(po[1]);
    if (err_mode == 1) close(pe[1]);
    int e = 0; ssize_t r;
    do { r = read(px[0], &e, sizeof e); } while (r < 0 && errno == EINTR);
    close(px[0]);
    if (r == sizeof e) {               /* exec failed */
        int st; waitpid(pid, &st, 0);
        if (stdin_mode == 1) close(pi[1]);
        close(po[0]); if (err_mode == 1) close(pe[0]);
        errno = e;
        return -1;
    }
    *in = stdin_mode == 1 ? pi[1] : -1;
    *out = po[0];
    *err = err_mode == 1 ? pe[0] : -1;
    return pid;
}
static double now_mono(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (double)ts.tv_sec + ts.tv_nsec / 1e9; }
/* run to completion, feeding input and collecting stdout/stderr; returns 0 ok, -1 couldn't start, -2 timed out */
static int run_child(Cmd *c, int stdin_mode, const char *input, size_t ilen, double timeout, Buf *out, Buf *err, int *code) {
    int in, o, e;
    signal(SIGPIPE, SIG_IGN);
    pid_t pid = start_child(c, stdin_mode, 1, &in, &o, &e);
    if (pid < 0) return -1;
    int rc = 0;
    VRT_BLOCKING_BEGIN();
    size_t off = 0;
    if (in >= 0 && ilen == 0) { close(in); in = -1; }
    double deadline = timeout >= 0 ? now_mono() + timeout : -1;
    while (o >= 0 || e >= 0) {
        struct pollfd p[3]; int n = 0, io = -1, ie = -1, ii = -1;
        if (o >= 0) { io = n; p[n++] = (struct pollfd){o, POLLIN, 0}; }
        if (e >= 0) { ie = n; p[n++] = (struct pollfd){e, POLLIN, 0}; }
        if (in >= 0) { ii = n; p[n++] = (struct pollfd){in, POLLOUT, 0}; }
        int ms = -1;
        if (deadline >= 0) { double left = deadline - now_mono(); if (left <= 0) { rc = -2; break; } ms = (int)(left * 1000) + 1; }
        int r = poll(p, (nfds_t)n, ms);
        if (r < 0) { if (errno == EINTR) continue; break; }
        if (r == 0) continue;
        char tmp[65536];
        if (io >= 0 && p[io].revents) { ssize_t k = read(o, tmp, sizeof tmp); if (k > 0) bput(out, tmp, (size_t)k); else { close(o); o = -1; } }
        if (ie >= 0 && p[ie].revents) { ssize_t k = read(e, tmp, sizeof tmp); if (k > 0) bput(err, tmp, (size_t)k); else { close(e); e = -1; } }
        if (ii >= 0 && p[ii].revents) {
            ssize_t k = write(in, input + off, ilen - off);
            if (k > 0) off += (size_t)k;
            if (k < 0 || off >= ilen) { close(in); in = -1; }
        }
    }
    if (in >= 0) close(in);
    if (o >= 0) close(o);
    if (e >= 0) close(e);
    if (rc == -2) kill(pid, SIGKILL);
    int st;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    *code = proc_code(st);
    VRT_BLOCKING_END();
    return rc;
}
static V b_run_process(int argc, V *a) {
    if (argc < 1 || argc > 2) vrt_fail("run_process expects a command (text or list) and an optional options map");
    V opts = argc == 2 ? a[1] : VNIL;
    Cmd c; cmd_build(&c, a[0], opts, "run_process");
    char *input = NULL; size_t ilen = 0; double timeout = -1;
    if (opts.t == VT_MAP) {
        int f; V v = vrt_map_get(opts, vrt_cstr("input"), &f);
        if (f && v.t != VT_NIL) input = data_of(v, &ilen);
        V t = vrt_map_get(opts, vrt_cstr("timeout"), &f);
        if (f && t.t != VT_NIL) timeout = num_arg(t, "run_process");
    }
    Buf out = {0}, err = {0}; bput(&out, "", 0); bput(&err, "", 0);
    int code = 0;
    int rc = run_child(&c, input ? 1 : 2, input, ilen, timeout, &out, &err, &code);
    free(input);
    if (rc == -1) { char m[4200]; snprintf(m, sizeof m, "could not run %s: %s", c.label, strerror(errno)); cmd_free(&c); free(out.p); free(err.p); vrt_fail("%s", m); }
    cmd_free(&c);
    if (rc == -2) { free(out.p); free(err.p); vrt_fail("the command timed out"); }
    V m = vrt_map();
    vrt_map_set(m, vrt_cstr("output"), vrt_str(out.p, (int64_t)out.len));
    vrt_map_set(m, vrt_cstr("error"), vrt_str(err.p, (int64_t)err.len));
    vrt_map_set(m, vrt_cstr("code"), VI(code));
    free(out.p); free(err.p);
    return m;
}
static V combined(V cmd, V dir, V env, int *code) {
    V opts = vrt_map(); vrt_pin(opts);
    if (dir.t != VT_UNDEF) vrt_map_set(opts, vrt_cstr("dir"), dir);
    if (env.t != VT_UNDEF) vrt_map_set(opts, vrt_cstr("env"), env);
    Cmd c; cmd_build(&c, cmd, opts, "run");
    vrt_unpin(1);
    Buf out = {0}, err = {0}; bput(&out, "", 0); bput(&err, "", 0);
    if (run_child(&c, 0, NULL, 0, -1, &out, &err, code) == -1) { char m[4200]; snprintf(m, sizeof m, "could not run %s: %s", c.label, strerror(errno)); cmd_free(&c); vrt_fail("%s", m); }
    cmd_free(&c);
    bput(&out, err.p, err.len);
    size_t n = out.len; while (n && out.p[n - 1] == '\n') n--;
    V r = vrt_str(out.p, (int64_t)n);
    free(out.p); free(err.p);
    return r;
}
static V b_run(int argc, V *a) {
    if (argc != 1 && argc != 2) vrt_fail("run expects a command (and an optional directory)");
    int code; return combined(vrt_display(a[0]), argc == 2 ? vrt_display(a[1]) : VUNDEF, VUNDEF, &code);
}
static V b_shell(int argc, V *a) {
    if (argc < 1 || argc > 3) vrt_fail("shell expects a command, an optional directory, and an optional map of environment variables");
    if (argc == 3 && a[2].t != VT_MAP) vrt_fail("shell's third value must be a map of variables");
    int code;
    V out = combined(vrt_display(a[0]), argc >= 2 ? vrt_display(a[1]) : VUNDEF, argc == 3 ? a[2] : VUNDEF, &code);
    vrt_pin(out);
    V m = vrt_map();
    vrt_map_set(m, vrt_cstr("output"), out);
    vrt_map_set(m, vrt_cstr("code"), VI(code));
    vrt_unpin(1);
    return m;
}
static V b_open_process(int argc, V *a) {
    if (argc < 1 || argc > 2) vrt_fail("open_process expects a command (text or list) and an optional options map");
    V opts = argc == 2 ? a[1] : VNIL;
    Cmd c; cmd_build(&c, a[0], opts, "open_process");
    int merge = 0;
    if (opts.t == VT_MAP) { int f; V m = vrt_map_get(opts, vrt_cstr("merge_errors"), &f); merge = f && vrt_truthy(m); }
    signal(SIGPIPE, SIG_IGN);
    Proc *p = calloc(1, sizeof *p);
    p->pid = start_child(&c, 1, merge ? 2 : 1, &p->in, &p->out, &p->err);
    if (p->pid < 0) { char m[4200]; snprintf(m, sizeof m, "could not run %s: %s", c.label, strerror(errno)); cmd_free(&c); free(p); vrt_fail("%s", m); }
    cmd_free(&c);
    return vrt_handle("process", p, NULL, proc_free);
}
static Proc *proc_of(V v, const char *name) { return vrt_handle_data(v, "process", name); }
static ssize_t read_fd(int fd, char *b, size_t n) {
    ssize_t r;
    VRT_BLOCKING_BEGIN();
    do { r = read(fd, b, n); } while (r < 0 && errno == EINTR);
    VRT_BLOCKING_END();
    return r;
}
static V proc_read_line(int argc, V *a) {
    (void)argc; Proc *p = proc_of(a[0], "read_line");
    char tmp[65536];
    for (;;) {
        char *nl = p->buf.len ? memchr(p->buf.p, '\n', p->buf.len) : NULL;
        if (nl) {
            size_t k = (size_t)(nl - p->buf.p), keep = k;
            if (keep && p->buf.p[keep - 1] == '\r') keep--;
            V r = vrt_str(p->buf.p, (int64_t)keep);
            memmove(p->buf.p, nl + 1, p->buf.len - k - 1); p->buf.len -= k + 1;
            return r;
        }
        ssize_t r = p->out >= 0 ? read_fd(p->out, tmp, sizeof tmp) : 0;
        if (r <= 0) {
            if (!p->buf.len) return VNIL;
            size_t keep = p->buf.len; if (keep && p->buf.p[keep - 1] == '\r') keep--;
            V out = vrt_str(p->buf.p, (int64_t)keep); p->buf.len = 0; return out;
        }
        bput(&p->buf, tmp, (size_t)r);
    }
}
static Buf drain(int fd) {
    Buf b = {0}; bput(&b, "", 0);
    if (fd < 0) return b;
    char tmp[65536]; ssize_t r;
    while ((r = read_fd(fd, tmp, sizeof tmp)) > 0) bput(&b, tmp, (size_t)r);
    return b;
}
static V proc_read_all(int argc, V *a) {
    (void)argc; Proc *p = proc_of(a[0], "read_all");
    Buf b = drain(p->out);
    Buf all = {0}; bput(&all, "", 0);
    if (p->buf.len) bput(&all, p->buf.p, p->buf.len);
    p->buf.len = 0;
    bput(&all, b.p, b.len); free(b.p);
    V r = vrt_str(all.p, (int64_t)all.len); free(all.p); return r;
}
static V proc_write(int argc, V *a) {
    (void)argc; Proc *p = proc_of(a[0], "write_to");
    if (p->in < 0) vrt_fail("the process isn't reading its input any more");
    size_t n; char *d = data_of(a[1], &n); int bad = 0;
    {
        VRT_BLOCKING_BEGIN();
        size_t off = 0;
        while (off < n) { ssize_t w = write(p->in, d + off, n - off); if (w < 0) { if (errno == EINTR) continue; bad = 1; break; } off += (size_t)w; }
        VRT_BLOCKING_END();
    }
    free(d);
    if (bad) vrt_fail("the process isn't reading its input any more");
    return VNIL;
}
static V b_close_input(int argc, V *a) { NEED(1, "close_input"); Proc *p = proc_of(a[0], "close_input"); if (p->in >= 0) { close(p->in); p->in = -1; } return VNIL; }
static V b_process_errors(int argc, V *a) {
    NEED(1, "process_errors"); Proc *p = proc_of(a[0], "process_errors");
    Buf b = drain(p->err);
    V r = vrt_str(b.p, (int64_t)b.len); free(b.p); return r;
}
static V b_kill_process(int argc, V *a) { NEED(1, "kill_process"); Proc *p = proc_of(a[0], "kill_process"); proc_reap(p, 0); if (!p->exited) kill(p->pid, SIGKILL); return VNIL; }
static V b_process_id(int argc, V *a) { NEED(1, "process_id"); return VI(proc_of(a[0], "process_id")->pid); }
static V proc_wait(int argc, V *a) {
    Proc *p = proc_of(a[0], "wait");
    double timeout = argc == 2 && a[1].t != VT_NIL ? num_arg(a[1], "wait") : -1;
    if (!p->exited) {
        VRT_BLOCKING_BEGIN();
        if (timeout < 0) proc_reap(p, 1);
        else {
            double end = now_mono() + timeout;
            for (;;) { proc_reap(p, 0); if (p->exited || now_mono() >= end) break; struct timespec ts = {0, 5000000}; nanosleep(&ts, NULL); }
        }
        VRT_BLOCKING_END();
    }
    return p->exited ? VI(p->status) : VNIL;
}
static V proc_is_done(int argc, V *a) { (void)argc; Proc *p = proc_of(a[0], "is_done"); proc_reap(p, 0); return VB(p->exited); }
static V proc_close(int argc, V *a) {
    (void)argc; Proc *p = proc_of(a[0], "close");
    if (p->in >= 0) { close(p->in); p->in = -1; }
    if (p->out >= 0) { close(p->out); p->out = -1; }
    if (p->err >= 0) { close(p->err); p->err = -1; }
    proc_reap(p, 0);
    if (!p->exited) kill(p->pid, SIGKILL);
    { VRT_BLOCKING_BEGIN(); proc_reap(p, 1); VRT_BLOCKING_END(); }
    return VNIL;
}

/* =====================================================================================================
 * Environment, exit, pid
 * ===================================================================================================== */
static V b_set_env(int argc, V *a) {
    NEED(2, "set_env");
    char *n = strdup(cs(a[0]));
    if (a[1].t == VT_NIL) unsetenv(n); else setenv(n, cs(a[1]), 1);
    free(n);
    return VNIL;
}
static V b_env_vars(int argc, V *a) {
    (void)a; NEED(0, "env_vars");
    SList l = {0};
    for (char **e = environ; *e; e++) sl_add(&l, *e);
    /* sort by name (the part before '=') */
    for (int i = 0; i < l.n; i++) { char *eq = strchr(l.v[i], '='); if (eq) *eq = 0; }
    qsort(l.v, (size_t)l.n, sizeof(char *), cmp_s);
    V m = vrt_map();
    for (int i = 0; i < l.n; i++) {
        const char *val = getenv(l.v[i]);
        vrt_map_set(m, vrt_cstr(l.v[i]), vrt_cstr(val ? val : ""));
        free(l.v[i]);
    }
    free(l.v);
    return m;
}
static V b_exit(int argc, V *a) {
    if (argc > 1) vrt_fail("exit expects an optional exit code");
    int64_t code = argc ? int_arg(a[0], "exit") : 0;
    fflush(stdout);
    _exit((int)code);
}
static V b_my_pid(int argc, V *a) { (void)a; NEED(0, "my_pid"); return VI(getpid()); }

/* =====================================================================================================
 * Dates and times (time zones through the OS: TZ + tzset, like vanta.py)
 * ===================================================================================================== */
static char saved_tz[512]; static int had_tz;
static int tz_push(int argc, V *a, int i) {
    if (argc <= i || a[i].t == VT_NIL) return 0;
    const char *tz = cs(a[i]);
    int ok = !strcmp(tz, "UTC") || !strcmp(tz, "GMT");
    if (!ok) {
        ok = *tz != 0;
        for (const char *c = tz; *c; c++) if (!(isalnum((unsigned char)*c) || strchr("_+-/", *c))) ok = 0;
        if (ok && (tz[0] == '/' || strstr(tz, "//") || tz[strlen(tz) - 1] == '/')) ok = 0;
        if (ok) { char p[1024]; snprintf(p, sizeof p, "/usr/share/zoneinfo/%s", tz); struct stat st; ok = stat(p, &st) == 0 && S_ISREG(st.st_mode); }
    }
    if (!ok) vrt_fail("unknown time zone '%s'", tz);
    const char *old = getenv("TZ");
    had_tz = old != NULL;
    if (old) snprintf(saved_tz, sizeof saved_tz, "%s", old);
    setenv("TZ", tz, 1);
    tzset();
    return 1;
}
static void tz_pop(int pushed) {
    if (!pushed) return;
    if (had_tz) setenv("TZ", saved_tz, 1); else unsetenv("TZ");
    tzset();
}
static V b_today(int argc, V *a) { (void)a; NEED(0, "today"); char buf[32]; time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm); strftime(buf, sizeof buf, "%Y-%m-%d", &tm); return vrt_cstr(buf); }
static V b_format_date(int argc, V *a) {
    if (argc < 1 || argc > 3) vrt_fail("format_date expects a timestamp, an optional pattern and an optional time zone");
    time_t t = (time_t)floor(num_arg(a[0], "format_date"));
    char pat[1024]; snprintf(pat, sizeof pat, "%s", argc >= 2 && a[1].t != VT_NIL ? cs(a[1]) : "%Y-%m-%d %H:%M:%S");
    int pushed = tz_push(argc, a, 2);
    struct tm tm; char buf[4096] = "";
    int ok = localtime_r(&t, &tm) != NULL;
    if (ok) strftime(buf, sizeof buf, pat, &tm);
    tz_pop(pushed);
    if (!ok) vrt_fail("format_date couldn't format that timestamp");
    return vrt_cstr(buf);
}
static V b_parse_date(int argc, V *a) {
    if (argc < 1 || argc > 3) vrt_fail("parse_date expects a date text, an optional pattern and an optional time zone");
    char text[1024], pat[1024];
    snprintf(text, sizeof text, "%s", cs(a[0]));
    snprintf(pat, sizeof pat, "%s", argc >= 2 && a[1].t != VT_NIL ? cs(a[1]) : "%Y-%m-%d");
    int pushed = tz_push(argc, a, 2);
    struct tm tm; memset(&tm, 0, sizeof tm);
    tm.tm_mday = 1; tm.tm_year = 0;
    char *end = strptime(text, pat, &tm);
    time_t t = -1;
    if (end && !*end) { tm.tm_isdst = -1; t = mktime(&tm); }
    tz_pop(pushed);
    if (!end || *end) vrt_fail("parse_date couldn't read '%s' with pattern '%s'", text, pat);
    return VI((int64_t)t);
}
static V b_date_parts(int argc, V *a) {
    if (argc < 1 || argc > 2) vrt_fail("date_parts expects a timestamp and an optional time zone");
    time_t t = (time_t)floor(num_arg(a[0], "date_parts"));
    int pushed = tz_push(argc, a, 1);
    struct tm tm; char dn[64] = "", mn[64] = "", zn[64] = "";
    int ok = localtime_r(&t, &tm) != NULL;
    if (ok) { strftime(dn, sizeof dn, "%A", &tm); strftime(mn, sizeof mn, "%B", &tm); strftime(zn, sizeof zn, "%Z", &tm); }
    tz_pop(pushed);
    if (!ok) vrt_fail("date_parts couldn't read that timestamp");
    V m = vrt_map();
    vrt_map_set(m, vrt_cstr("year"), VI(tm.tm_year + 1900)); vrt_map_set(m, vrt_cstr("month"), VI(tm.tm_mon + 1));
    vrt_map_set(m, vrt_cstr("day"), VI(tm.tm_mday)); vrt_map_set(m, vrt_cstr("hour"), VI(tm.tm_hour));
    vrt_map_set(m, vrt_cstr("minute"), VI(tm.tm_min)); vrt_map_set(m, vrt_cstr("second"), VI(tm.tm_sec));
    vrt_map_set(m, vrt_cstr("weekday"), VI(tm.tm_wday == 0 ? 7 : tm.tm_wday)); vrt_map_set(m, vrt_cstr("day_name"), vrt_cstr(dn));
    vrt_map_set(m, vrt_cstr("month_name"), vrt_cstr(mn)); vrt_map_set(m, vrt_cstr("yearday"), VI(tm.tm_yday + 1));
    vrt_map_set(m, vrt_cstr("zone"), vrt_cstr(zn)); vrt_map_set(m, vrt_cstr("offset"), VI((int64_t)tm.tm_gmtoff));
    return m;
}
static V b_make_date(int argc, V *a) {
    if (argc < 3 || argc > 7) vrt_fail("make_date expects year, month, day, and optional hour, minute, second and time zone");
    int64_t n[6] = {0, 0, 0, 0, 0, 0};
    for (int i = 0; i < argc && i < 6; i++) n[i] = int_arg(a[i], "make_date");
    int pushed = tz_push(argc, a, 6);
    struct tm tm; memset(&tm, 0, sizeof tm);
    tm.tm_year = (int)n[0] - 1900; tm.tm_mon = (int)n[1] - 1; tm.tm_mday = (int)n[2];
    tm.tm_hour = (int)n[3]; tm.tm_min = (int)n[4]; tm.tm_sec = (int)n[5]; tm.tm_isdst = -1;
    time_t t = mktime(&tm);
    tz_pop(pushed);
    return VI((int64_t)t);
}
static V scaled(int argc, V *a, const char *name, int64_t k) {
    NEED(1, name);
    if (a[0].t == VT_INT) return VI(a[0].u.i * k);
    return tidy(num_arg(a[0], name) * (double)k);
}
static V b_days(int argc, V *a) { return scaled(argc, a, "days", 86400); }
static V b_hours(int argc, V *a) { return scaled(argc, a, "hours", 3600); }
static V b_minutes(int argc, V *a) { return scaled(argc, a, "minutes", 60); }
static V b_format_duration(int argc, V *a) {
    NEED(1, "format_duration");
    double secs = num_arg(a[0], "format_duration");
    int64_t s = (int64_t)fabs(secs);
    int64_t d = s / 86400; s %= 86400; int64_t h = s / 3600; s %= 3600; int64_t m = s / 60; s %= 60;
    Buf b = {0}; bput(&b, "", 0);
    if (secs < 0) bputs(&b, "-");
    char tmp[64]; int any = 0;
    if (d) { snprintf(tmp, sizeof tmp, "%lldd", (long long)d); bputs(&b, tmp); any = 1; }
    if (h) { snprintf(tmp, sizeof tmp, "%s%lldh", any ? " " : "", (long long)h); bputs(&b, tmp); any = 1; }
    if (m) { snprintf(tmp, sizeof tmp, "%s%lldm", any ? " " : "", (long long)m); bputs(&b, tmp); any = 1; }
    if (s || !any) { snprintf(tmp, sizeof tmp, "%s%llds", any ? " " : "", (long long)s); bputs(&b, tmp); }
    V r = vrt_str(b.p, (int64_t)b.len); free(b.p); return r;
}
static V b_timezone(int argc, V *a) {
    (void)a; NEED(0, "timezone");
    const char *tz = getenv("TZ");
    if (tz && *tz) { while (*tz == ':') tz++; return vrt_cstr(tz); }
    char link[1024]; ssize_t n = readlink("/etc/localtime", link, sizeof link - 1);
    if (n > 0) { link[n] = 0; char *z = strstr(link, "zoneinfo/"); if (z) return vrt_cstr(z + 9); }
    char buf[64]; time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm); strftime(buf, sizeof buf, "%Z", &tm);
    return vrt_cstr(buf);
}

typedef VEntry Entry;
static const Entry sys_table[] = {
    {"path_join", b_path_join}, {"dirname", b_dirname}, {"basename", b_basename}, {"extname", b_extname}, {"home_dir", b_home_dir},
    {"absolute_path", b_absolute_path}, {"current_dir", b_current_dir}, {"change_dir", b_change_dir}, {"file_mtime", b_file_mtime},
    {"copy_path", b_copy_path}, {"move_path", b_move_path}, {"walk_dir", b_walk_dir}, {"glob", b_glob},
    {"matches_pattern", b_matches_pattern}, {"temp_file", b_temp_file}, {"temp_dir", b_temp_dir},
    {"open_file", b_open_file}, {"read_chunk", b_read_chunk}, {"read_chunk_bytes", b_read_chunk_bytes}, {"seek", b_seek}, {"tell", b_tell},
    {"run_process", b_run_process}, {"open_process", b_open_process}, {"close_input", b_close_input},
    {"process_errors", b_process_errors}, {"kill_process", b_kill_process}, {"process_id", b_process_id},
    {"run", b_run}, {"shell", b_shell},
    {"set_env", b_set_env}, {"env_vars", b_env_vars}, {"exit", b_exit}, {"my_pid", b_my_pid},
    {"today", b_today}, {"format_date", b_format_date}, {"parse_date", b_parse_date}, {"date_parts", b_date_parts},
    {"make_date", b_make_date}, {"days", b_days}, {"hours", b_hours}, {"minutes", b_minutes},
    {"format_duration", b_format_duration}, {"timezone", b_timezone},
    {NULL, NULL}
};
__attribute__((constructor)) static void vrt_sys_register(void) {
    vrt_register_builtins(sys_table);
    vrt_register_op("file", "read_line", file_read_line);
    vrt_register_op("file", "read_all", file_read_all);
    vrt_register_op("file", "write_to", file_write);
    vrt_register_op("file", "close", file_close);
    vrt_register_op("process", "read_line", proc_read_line);
    vrt_register_op("process", "read_all", proc_read_all);
    vrt_register_op("process", "write_to", proc_write);
    vrt_register_op("process", "wait", proc_wait);
    vrt_register_op("process", "is_done", proc_is_done);
    vrt_register_op("process", "close", proc_close);
    vrt_register_op("process", "process_id", b_process_id);
}
