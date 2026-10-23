/* vantac: optional; libs: -lcurl */
#define _GNU_SOURCE
/* Vanta native runtime: the HTTP client — http_get, http_post, http_request, download — on libcurl (so https,
 * redirects and proxies work), with the same results as vanta.py: {status, body, headers}. The transfer runs with the
 * global lock released, so other tasks keep going. */
#include "vrt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <strings.h>
#include <curl/curl.h>

typedef struct { char *p; size_t len, cap; } Buf;
static void bput(Buf *b, const void *s, size_t n) {
    if (b->len + n + 1 > b->cap) { b->cap = (b->len + n + 1) * 2 + 256; b->p = realloc(b->p, b->cap); }
    memcpy(b->p + b->len, s, n); b->len += n; b->p[b->len] = 0;
}
static size_t on_body(char *d, size_t sz, size_t n, void *u) { bput(u, d, sz * n); return sz * n; }
static size_t on_file(char *d, size_t sz, size_t n, void *u) { return fwrite(d, sz, n, (FILE *)u) * sz; }
static size_t on_header(char *d, size_t sz, size_t n, void *u) {
    Buf *b = u;
    if (sz * n >= 5 && !strncmp(d, "HTTP/", 5)) b->len = 0;     /* a new response (after a redirect): start over */
    bput(b, d, sz * n);
    return sz * n;
}
static char *cdup(V v) { V s = vrt_display(v); return strdup(AS_STR(s)->data); }

typedef struct { char *url, *method, *body; size_t blen; struct curl_slist *hdrs; } Req;

/* Build the request from Vanta values (holding the lock): headers map, and a body that is JSON for maps/lists. */
static void prepare(Req *r, const char *method, V url, V body, V headers, const char *fname) {
    static int inited = 0;
    if (!inited) { curl_global_init(CURL_GLOBAL_DEFAULT); inited = 1; }
    memset(r, 0, sizeof *r);
    r->url = cdup(url);
    r->method = strdup(method);
    int has_ctype = 0;
    if (headers.t == VT_MAP) {
        VMap *m = AS_MAP(headers);
        for (int64_t i = 0; i < m->nent; i++) if (m->ents[i].used) {
            V k = vrt_display(m->ents[i].key); vrt_pin(k);
            V v = vrt_display(m->ents[i].val);
            Buf h = {0};
            bput(&h, AS_STR(k)->data, (size_t)AS_STR(k)->len); bput(&h, ": ", 2); bput(&h, AS_STR(v)->data, (size_t)AS_STR(v)->len);
            r->hdrs = curl_slist_append(r->hdrs, h.p);
            if (!strcasecmp(AS_STR(k)->data, "Content-Type")) has_ctype = 1;
            free(h.p);
            vrt_unpin(1);
        }
    } else if (headers.t != VT_NIL && headers.t != VT_UNDEF) vrt_fail("%s's headers must be a map", fname);
    if (body.t != VT_UNDEF && body.t != VT_NIL && !(body.t == VT_STR && AS_STR(body)->len == 0)) {
        V s;
        if (body.t == VT_MAP || body.t == VT_LIST) {
            s = vrt_call(vrt_builtin_named("to_json"), 1, &body);
            if (!has_ctype) r->hdrs = curl_slist_append(r->hdrs, "Content-Type: application/json");
        } else s = vrt_display(body);
        r->blen = (size_t)AS_STR(s)->len;
        r->body = malloc(r->blen + 1);
        memcpy(r->body, AS_STR(s)->data, r->blen);
    }
}
static void release(Req *r) { free(r->url); free(r->method); free(r->body); curl_slist_free_all(r->hdrs); }
static CURL *easy(Req *r, long timeout) {
    CURL *c = curl_easy_init();
    curl_easy_setopt(c, CURLOPT_URL, r->url);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, timeout);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_USERAGENT, "Vanta/6.0");
    if (r->hdrs) curl_easy_setopt(c, CURLOPT_HTTPHEADER, r->hdrs);
    if (r->body) {
        curl_easy_setopt(c, CURLOPT_POSTFIELDS, r->body);
        curl_easy_setopt(c, CURLOPT_POSTFIELDSIZE, (long)r->blen);
    }
    if (strcmp(r->method, "GET") || r->body) {
        if (!strcmp(r->method, "HEAD")) curl_easy_setopt(c, CURLOPT_NOBODY, 1L);
        else curl_easy_setopt(c, CURLOPT_CUSTOMREQUEST, r->method);
    }
    return c;
}
static V request(const char *method, V url, V body, V headers, const char *fname) {
    Req r;
    prepare(&r, method, url, body, headers, fname);
    Buf out = {0}, hdr = {0};
    bput(&out, "", 0); bput(&hdr, "", 0);
    CURL *c = easy(&r, 30);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, on_body);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &out);
    curl_easy_setopt(c, CURLOPT_HEADERFUNCTION, on_header);
    curl_easy_setopt(c, CURLOPT_HEADERDATA, &hdr);
    CURLcode rc;
    long status = 0;
    { VRT_BLOCKING_BEGIN(); rc = curl_easy_perform(c); VRT_BLOCKING_END(); }
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_cleanup(c);
    if (rc != CURLE_OK) {
        char msg[1200];
        snprintf(msg, sizeof msg, "could not reach %s: %s", r.url, curl_easy_strerror(rc));
        release(&r); free(out.p); free(hdr.p);
        vrt_fail("%s", msg);
    }
    release(&r);
    V m = vrt_map();
    vrt_pin(m);
    vrt_map_set(m, vrt_cstr("status"), VI(status));
    vrt_map_set(m, vrt_cstr("body"), vrt_str(out.p, (int64_t)out.len));
    V hm = vrt_map();
    vrt_map_set(m, vrt_cstr("headers"), hm);
    char *line = strstr(hdr.p, "\r\n");             /* skip the status line */
    while (line) {
        char *ls = line + 2, *le = strstr(ls, "\r\n");
        if (!le || le == ls) break;
        char *colon = memchr(ls, ':', (size_t)(le - ls));
        if (colon) {
            char *v = colon + 1; while (v < le && (*v == ' ' || *v == '\t')) v++;
            vrt_map_set(hm, vrt_str(ls, colon - ls), vrt_str(v, le - v));
        }
        line = le;
    }
    free(out.p); free(hdr.p);
    vrt_unpin(1);
    return m;
}
static V b_http_get(int argc, V *a) {
    if (argc != 1 && argc != 2) vrt_fail("http_get expects a url (and an optional headers map)");
    return request("GET", a[0], VUNDEF, argc == 2 ? a[1] : VNIL, "http");
}
static V b_http_post(int argc, V *a) {
    if (argc != 2 && argc != 3) vrt_fail("http_post expects a url and a body (and an optional headers map)");
    return request("POST", a[0], a[1], argc == 3 ? a[2] : VNIL, "http");
}
static V b_http_request(int argc, V *a) {
    if (argc < 2 || argc > 4) vrt_fail("http_request expects a method, a url, an optional body, and an optional headers map");
    V m = vrt_display(a[0]);
    char method[32]; size_t i = 0;
    for (; i < sizeof method - 1 && AS_STR(m)->data[i]; i++) method[i] = (char)toupper((unsigned char)AS_STR(m)->data[i]);
    method[i] = 0;
    return request(method, a[1], argc >= 3 ? a[2] : VUNDEF, argc == 4 ? a[3] : VNIL, "http");
}
static V result(int ok, long status, long bytes, const char *path, const char *err) {
    V m = vrt_map();
    vrt_map_set(m, vrt_cstr("ok"), VB(ok));
    vrt_map_set(m, vrt_cstr("status"), VI(status));
    vrt_map_set(m, vrt_cstr("bytes"), VI(bytes));
    vrt_map_set(m, vrt_cstr("path"), vrt_cstr(path));
    vrt_map_set(m, vrt_cstr("error"), vrt_cstr(err));
    return m;
}
static V b_download(int argc, V *a) {
    if (argc != 2 && argc != 3) vrt_fail("download expects a url, a destination path (and an optional headers map)");
    Req r;
    prepare(&r, "GET", a[0], VUNDEF, argc == 3 ? a[2] : VNIL, "download");
    V dv = vrt_display(a[1]);
    char dest[4096];
    const char *dp = AS_STR(dv)->data;
    if (dp[0] == '~' && (dp[1] == '/' || !dp[1])) snprintf(dest, sizeof dest, "%s%s", getenv("HOME") ? getenv("HOME") : "", dp + 1);
    else snprintf(dest, sizeof dest, "%s", dp);
    Buf body = {0};
    CURL *c = easy(&r, 120);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, on_body);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &body);
    CURLcode rc;
    long status = 0;
    { VRT_BLOCKING_BEGIN(); rc = curl_easy_perform(c); VRT_BLOCKING_END(); }
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_cleanup(c);
    if (rc != CURLE_OK) {
        char msg[1200];
        snprintf(msg, sizeof msg, "could not reach %s: %s", r.url, curl_easy_strerror(rc));
        release(&r); free(body.p);
        return result(0, 0, 0, dest, msg);
    }
    release(&r);
    if (status >= 400) { char msg[64]; snprintf(msg, sizeof msg, "HTTP %ld", status); free(body.p); return result(0, status, 0, dest, msg); }
    FILE *f = fopen(dest, "wb");
    if (!f) { free(body.p); vrt_fail("could not write %s", dest); }
    if (body.len) fwrite(body.p, 1, body.len, f);
    fclose(f);
    free(body.p);
    (void)on_file;
    return result(1, status, (long)body.len, dest, "");
}

typedef VEntry Entry;
static const Entry http_table[] = {
    {"http_get", b_http_get}, {"http_post", b_http_post}, {"http_request", b_http_request}, {"download", b_download},
    {NULL, NULL}
};
__attribute__((constructor)) static void vrt_http_register(void) { vrt_register_builtins(http_table); }
