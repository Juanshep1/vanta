/* vantac: optional; needs: vrt_thread.c vrt_io.c vrt_data.c */
#define _GNU_SOURCE
/* Vanta native runtime: TCP/UDP sockets, DNS, and the HTTP server (serve / start_server with routes) — the same
 * names, results and messages as vanta.py. Every call that can block lets go of the global lock (see vrt_thread.c),
 * so a server, a client and other tasks run at the same time. */
#include "vrt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <ctype.h>
#include <strings.h>
#include <time.h>
#include <math.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>

#define NEED(n, name) do { if (argc != (n)) vrt_fail("%s expects %d value(s), got %d", name, n, argc); } while (0)
static int64_t int_arg(V v, const char *name) { if (v.t != VT_INT) vrt_fail("%s needs whole numbers", name); return v.u.i; }
static double num_arg(V v, const char *name) {
    if (v.t == VT_INT) return (double)v.u.i;
    if (v.t == VT_FLOAT) return v.u.f;
    vrt_fail("%s needs a number", name);
}
static double opt_timeout(int argc, V *a, int i, const char *name) {
    if (argc <= i || a[i].t == VT_NIL) return -1;
    double d = num_arg(a[i], name);
    return d < 0 ? 0 : d;
}
static char *cdup(V v) { V s = vrt_display(v); return strdup(AS_STR(s)->data); }   /* a C copy, safe while unlocked */
typedef struct { char *p; size_t len, cap; } Buf;
static void bput(Buf *b, const void *s, size_t n) {
    if (b->len + n + 1 > b->cap) { b->cap = (b->len + n + 1) * 2 + 256; b->p = realloc(b->p, b->cap); }
    memcpy(b->p + b->len, s, n); b->len += n; b->p[b->len] = 0;
}
static void bputs(Buf *b, const char *s) { bput(b, s, strlen(s)); }
/* data to send: text as UTF-8, bytes raw, anything else shown as text (copied to C memory) */
static char *data_of(V v, size_t *n) {
    if (v.t == VT_BYTES) { *n = (size_t)AS_BYTES(v)->len; char *p = malloc(*n + 1); memcpy(p, AS_BYTES(v)->data, *n); return p; }
    V s = vrt_display(v); *n = (size_t)AS_STR(s)->len; char *p = malloc(*n + 1); memcpy(p, AS_STR(s)->data, *n); return p;
}

/* =====================================================================================================
 * Sockets
 * ===================================================================================================== */
typedef struct Sock { int fd; char *buf; size_t len; double timeout; } Sock;
static void sock_free(void *p) { Sock *s = p; if (s->fd >= 0) close(s->fd); free(s->buf); free(s); }
static V new_sock(int fd) {
    Sock *s = calloc(1, sizeof *s);
    s->fd = fd;
    s->timeout = -1;
#ifdef SO_NOSIGPIPE
    int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    return vrt_handle("socket", s, NULL, sock_free);
}
static Sock *sock_of(V v, const char *name) {
    Sock *s = vrt_handle_data(v, "socket", name);
    if (s->fd < 0) vrt_fail("%s: that socket is closed", name);
    return s;
}
/* wait until fd is readable/writable; 0 = timed out. Call with the lock released. */
static int wait_fd(int fd, int out, double timeout) {
    if (timeout < 0) return 1;
    struct pollfd p = {fd, (short)(out ? POLLOUT : POLLIN), 0};
    int ms = (int)(timeout * 1000);
    for (;;) { int r = poll(&p, 1, ms); if (r < 0 && errno == EINTR) continue; return r != 0; }
}
/* read more from the socket: returns bytes read (0 = end), -1 error (errno), -2 timeout */
static ssize_t fill(Sock *s, char *dst, size_t n) {
    ssize_t r;
    VRT_BLOCKING_BEGIN();
    if (!wait_fd(s->fd, 0, s->timeout)) r = -2;
    else do { r = recv(s->fd, dst, n, 0); } while (r < 0 && errno == EINTR);
    VRT_BLOCKING_END();
    return r;
}
static _Noreturn void conn_fail(ssize_t r) {
    if (r == -2 || errno == EAGAIN || errno == EWOULDBLOCK) vrt_fail("the connection timed out");
    vrt_fail("the connection failed: %s", strerror(errno));
}
static char *sock_recv(Sock *s, size_t n, size_t *got) {
    char *out = malloc(n + 1);
    if (s->len) {
        size_t k = s->len < n ? s->len : n;
        memcpy(out, s->buf, k);
        memmove(s->buf, s->buf + k, s->len - k);
        s->len -= k;
        *got = k;
        return out;
    }
    ssize_t r = fill(s, out, n);
    if (r < 0) { int e = errno; free(out); errno = e; conn_fail(r); }
    *got = (size_t)r;
    return out;
}
static void sock_append(Sock *s, const char *d, size_t n) { s->buf = realloc(s->buf, s->len + n + 1); memcpy(s->buf + s->len, d, n); s->len += n; }
static void send_all(Sock *s, const char *p, size_t n) {
    ssize_t err = 0;
    VRT_BLOCKING_BEGIN();
    while (n) {
        if (!wait_fd(s->fd, 1, s->timeout)) { err = -2; break; }
        ssize_t w = send(s->fd, p, n, 0);
        if (w < 0) { if (errno == EINTR) continue; err = -1; break; }
        p += w; n -= (size_t)w;
    }
    VRT_BLOCKING_END();
    if (err) conn_fail(err);
}

static V sock_send(int argc, V *a) {
    (void)argc;
    Sock *s = sock_of(a[0], "send");
    size_t n; char *d = data_of(a[1], &n);
    send_all(s, d, n);
    free(d);
    return VNIL;
}
static V sock_receive(int argc, V *a) {
    Sock *s = sock_of(a[0], "receive");
    int64_t n = argc == 2 ? int_arg(a[1], "receive") : 65536;
    if (n <= 0) vrt_fail("receive needs a size above zero");
    size_t got; char *d = sock_recv(s, (size_t)n, &got);
    V r = vrt_str(d, (int64_t)got); free(d); return r;
}
static V sock_receive_bytes(int argc, V *a) {
    Sock *s = sock_of(a[0], "receive_bytes");
    int64_t n = argc == 2 ? int_arg(a[1], "receive_bytes") : 65536;
    if (n <= 0) vrt_fail("receive needs a size above zero");
    size_t got; char *d = sock_recv(s, (size_t)n, &got);
    V r = vrt_bytes((int64_t)got); memcpy(AS_BYTES(r)->data, d, got); free(d); return r;
}
static V sock_read_line(int argc, V *a) {
    (void)argc;
    Sock *s = sock_of(a[0], "read_line");
    char tmp[65536];
    for (;;) {
        char *nl = s->len ? memchr(s->buf, '\n', s->len) : NULL;
        if (nl) {
            size_t k = (size_t)(nl - s->buf), keep = k;
            if (keep && s->buf[keep - 1] == '\r') keep--;
            V r = vrt_str(s->buf, (int64_t)keep);
            memmove(s->buf, nl + 1, s->len - k - 1);
            s->len -= k + 1;
            return r;
        }
        ssize_t r = fill(s, tmp, sizeof tmp);
        if (r < 0) conn_fail(r);
        if (r == 0) {
            if (!s->len) return VNIL;
            size_t keep = s->len;
            while (keep && s->buf[keep - 1] == '\r') keep--;
            V out = vrt_str(s->buf, (int64_t)keep);
            s->len = 0;
            return out;
        }
        sock_append(s, tmp, (size_t)r);
    }
}
static V sock_read_all(int argc, V *a) {
    (void)argc;
    Sock *s = sock_of(a[0], "read_all");
    char tmp[65536];
    for (;;) {
        ssize_t r = fill(s, tmp, sizeof tmp);
        if (r < 0) conn_fail(r);
        if (r == 0) break;
        sock_append(s, tmp, (size_t)r);
    }
    V out = vrt_str(s->buf ? s->buf : "", (int64_t)s->len);
    s->len = 0;
    return out;
}
static V sock_close(int argc, V *a) {
    (void)argc;
    Sock *s = vrt_handle_data(a[0], "socket", "close");
    if (s->fd >= 0) { close(s->fd); s->fd = -1; }
    return VNIL;
}

static V b_tcp_connect(int argc, V *a) {
    if (argc < 2 || argc > 3) vrt_fail("tcp_connect expects a host, a port and an optional timeout in seconds");
    int64_t port = int_arg(a[1], "tcp_connect");
    double timeout = opt_timeout(argc, a, 2, "tcp_connect");
    char *host = cdup(a[0]), ps[16];
    snprintf(ps, sizeof ps, "%lld", (long long)port);
    int fd = -1, gai = 0, err = 0, timed_out = 0;
    {
        VRT_BLOCKING_BEGIN();
        struct addrinfo hints, *res = NULL;
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        gai = getaddrinfo(host, ps, &hints, &res);
        for (struct addrinfo *ai = gai ? NULL : res; ai; ai = ai->ai_next) {
            fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
            if (fd < 0) { err = errno; continue; }
            int fl = fcntl(fd, F_GETFL, 0);
            if (timeout >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
            int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
            if (rc < 0 && errno == EINPROGRESS) {
                if (!wait_fd(fd, 1, timeout)) { timed_out = 1; close(fd); fd = -1; break; }
                socklen_t len = sizeof err; err = 0;
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
                rc = err ? -1 : 0;
                errno = err;
            }
            if (rc == 0) { fcntl(fd, F_SETFL, fl); break; }
            err = errno; close(fd); fd = -1;
        }
        if (res) freeaddrinfo(res);
        VRT_BLOCKING_END();
    }
    if (fd < 0) {
        char msg[600];
        if (gai) snprintf(msg, sizeof msg, "could not connect to %s:%lld: unknown host", host, (long long)port);
        else if (timed_out) snprintf(msg, sizeof msg, "could not connect to %s:%lld: timed out", host, (long long)port);
        else snprintf(msg, sizeof msg, "could not connect to %s:%lld: %s", host, (long long)port, strerror(err));
        free(host);
        vrt_fail("%s", msg);
    }
    free(host);
    int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    return new_sock(fd);
}
static int bind_inet(int type, V hostv, int64_t port, int *errout) {
    int fd = socket(AF_INET, type, 0);
    if (fd < 0) { *errout = errno; return -1; }
    int one = 1;
    if (type == SOCK_STREAM) setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    if (hostv.t != VT_UNDEF) {
        V h = vrt_display(hostv);
        const char *hs = AS_STR(h)->data;
        if (*hs && inet_pton(AF_INET, hs, &sa.sin_addr) != 1) {
            struct addrinfo hints, *res = NULL;
            memset(&hints, 0, sizeof hints);
            hints.ai_family = AF_INET;
            if (getaddrinfo(hs, NULL, &hints, &res) != 0 || !res) { close(fd); *errout = EADDRNOTAVAIL; return -1; }
            sa.sin_addr = ((struct sockaddr_in *)res->ai_addr)->sin_addr;
            freeaddrinfo(res);
        }
    }
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) < 0 || (type == SOCK_STREAM && listen(fd, 128) < 0)) { *errout = errno; close(fd); return -1; }
    return fd;
}
static V b_tcp_listen(int argc, V *a) {
    if (argc < 1 || argc > 2) vrt_fail("tcp_listen expects a port and an optional host");
    int64_t port = int_arg(a[0], "tcp_listen");
    int err = 0, fd = bind_inet(SOCK_STREAM, argc == 2 ? a[1] : VUNDEF, port, &err);
    if (fd < 0) vrt_fail("could not listen on port %lld: %s", (long long)port, strerror(err));
    return new_sock(fd);
}
static V b_accept(int argc, V *a) {
    if (argc < 1 || argc > 2) vrt_fail("accept expects a listening socket and an optional timeout");
    Sock *s = sock_of(a[0], "accept");
    double timeout = opt_timeout(argc, a, 1, "accept");
    int fd = -1, err = 0, timed_out = 0;
    {
        VRT_BLOCKING_BEGIN();
        if (!wait_fd(s->fd, 0, timeout)) timed_out = 1;
        else { do { fd = accept(s->fd, NULL, NULL); } while (fd < 0 && errno == EINTR); err = errno; }
        VRT_BLOCKING_END();
    }
    if (timed_out) return VNIL;
    if (fd < 0) vrt_fail("accept failed: %s", strerror(err));
    int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    return new_sock(fd);
}
static V b_set_timeout(int argc, V *a) {
    NEED(2, "set_timeout");
    Sock *s = sock_of(a[0], "set_timeout");
    s->timeout = a[1].t == VT_NIL ? -1 : num_arg(a[1], "set_timeout");
    if (s->timeout < -1) s->timeout = 0;
    return VNIL;
}
static void addr_parts(struct sockaddr_storage *ss, V *host, V *port) {
    char buf[INET6_ADDRSTRLEN] = "";
    if (ss->ss_family == AF_INET) { struct sockaddr_in *s = (struct sockaddr_in *)ss; inet_ntop(AF_INET, &s->sin_addr, buf, sizeof buf); *port = VI(ntohs(s->sin_port)); }
    else { struct sockaddr_in6 *s = (struct sockaddr_in6 *)ss; inet_ntop(AF_INET6, &s->sin6_addr, buf, sizeof buf); *port = VI(ntohs(s->sin6_port)); }
    *host = vrt_cstr(buf);
}
static V b_socket_info(int argc, V *a) {
    NEED(1, "socket_info");
    Sock *s = sock_of(a[0], "socket_info");
    V m = vrt_map(), h = VNIL, p = VNIL, rh = VNIL, rp = VNIL;
    struct sockaddr_storage ss; socklen_t len = sizeof ss;
    if (getsockname(s->fd, (struct sockaddr *)&ss, &len) == 0) addr_parts(&ss, &h, &p);
    len = sizeof ss;
    if (getpeername(s->fd, (struct sockaddr *)&ss, &len) == 0) addr_parts(&ss, &rh, &rp);
    vrt_map_set(m, vrt_cstr("local_host"), h); vrt_map_set(m, vrt_cstr("local_port"), p);
    vrt_map_set(m, vrt_cstr("remote_host"), rh); vrt_map_set(m, vrt_cstr("remote_port"), rp);
    return m;
}
static V b_udp_open(int argc, V *a) {
    if (argc > 2) vrt_fail("udp_open expects an optional port and host");
    int64_t port = argc >= 1 ? int_arg(a[0], "udp_open") : 0;
    int err = 0, fd = bind_inet(SOCK_DGRAM, argc == 2 ? a[1] : VUNDEF, port, &err);
    if (fd < 0) vrt_fail("could not open UDP port %lld: %s", (long long)port, strerror(err));
    return new_sock(fd);
}
static V b_udp_send(int argc, V *a) {
    NEED(4, "udp_send");
    Sock *s = sock_of(a[0], "udp_send");
    int64_t port = int_arg(a[2], "udp_send");
    char *host = cdup(a[1]), ps[16];
    snprintf(ps, sizeof ps, "%lld", (long long)port);
    size_t n; char *d = data_of(a[3], &n);
    int gai, err = 0;
    {
        VRT_BLOCKING_BEGIN();
        struct addrinfo hints, *res = NULL;
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_DGRAM;
        gai = getaddrinfo(host, ps, &hints, &res);
        if (!gai && sendto(s->fd, d, n, 0, res->ai_addr, res->ai_addrlen) < 0) err = errno;
        if (res) freeaddrinfo(res);
        VRT_BLOCKING_END();
    }
    free(d);
    if (gai || err) {
        char msg[600];
        snprintf(msg, sizeof msg, "could not send to %s:%lld: %s", host, (long long)port, gai ? "unknown host" : strerror(err));
        free(host);
        vrt_fail("%s", msg);
    }
    free(host);
    return VNIL;
}
static V b_udp_receive(int argc, V *a) {
    if (argc < 1 || argc > 3) vrt_fail("udp_receive expects a socket, an optional size and an optional timeout");
    Sock *s = sock_of(a[0], "udp_receive");
    int64_t n = argc >= 2 && a[1].t != VT_NIL ? int_arg(a[1], "udp_receive") : 65536;
    double timeout = opt_timeout(argc, a, 2, "udp_receive");
    if (n <= 0) n = 1;
    char *buf = malloc((size_t)n);
    struct sockaddr_storage ss; socklen_t len = sizeof ss;
    ssize_t r = -2; int err = 0;
    {
        VRT_BLOCKING_BEGIN();
        if (wait_fd(s->fd, 0, timeout)) { do { r = recvfrom(s->fd, buf, (size_t)n, 0, (struct sockaddr *)&ss, &len); } while (r < 0 && errno == EINTR); err = errno; }
        VRT_BLOCKING_END();
    }
    if (r == -2) { free(buf); return VNIL; }
    if (r < 0) { free(buf); vrt_fail("udp_receive failed: %s", strerror(err)); }
    V m = vrt_map(), h, p;
    vrt_map_set(m, vrt_cstr("data"), vrt_str(buf, r));
    free(buf);
    addr_parts(&ss, &h, &p);
    vrt_map_set(m, vrt_cstr("host"), h);
    vrt_map_set(m, vrt_cstr("port"), p);
    return m;
}
static V b_dns_lookup(int argc, V *a) {
    NEED(1, "dns_lookup");
    char *host = cdup(a[0]);
    struct addrinfo hints, *res = NULL;
    int gai;
    {
        VRT_BLOCKING_BEGIN();
        memset(&hints, 0, sizeof hints);
        hints.ai_socktype = SOCK_STREAM;
        gai = getaddrinfo(host, NULL, &hints, &res);
        VRT_BLOCKING_END();
    }
    if (gai) { char msg[600]; snprintf(msg, sizeof msg, "could not look up %s", host); free(host); vrt_fail("%s", msg); }
    free(host);
    V out = vrt_list(4);
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        char buf[INET6_ADDRSTRLEN] = "";
        if (ai->ai_family == AF_INET) inet_ntop(AF_INET, &((struct sockaddr_in *)ai->ai_addr)->sin_addr, buf, sizeof buf);
        else if (ai->ai_family == AF_INET6) inet_ntop(AF_INET6, &((struct sockaddr_in6 *)ai->ai_addr)->sin6_addr, buf, sizeof buf);
        else continue;
        V s = vrt_cstr(buf);
        if (!vrt_truthy(vrt_in(s, out))) vrt_list_push(out, s);
    }
    freeaddrinfo(res);
    return out;
}

/* =====================================================================================================
 * HTTP server
 * ===================================================================================================== */
typedef struct Server { int fd, port, busy; volatile int stop; V handler, self; } Server;
static void server_trace(void *p) { vrt_mark(((Server *)p)->handler); }
static void server_free(void *p) { Server *s = p; if (s->fd >= 0) close(s->fd); free(s); }

static int hexv(int c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; }
static V unquote(const char *s, size_t n, int plus) {
    Buf b = {0}; bput(&b, "", 0);
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '%' && i + 2 < n && hexv(s[i + 1]) >= 0 && hexv(s[i + 2]) >= 0) {
            char c = (char)(hexv(s[i + 1]) * 16 + hexv(s[i + 2])); bput(&b, &c, 1); i += 2;
        } else if (plus && s[i] == '+') bput(&b, " ", 1);
        else bput(&b, s + i, 1);
    }
    V r = vrt_str(b.p, (int64_t)b.len); free(b.p); return r;
}
/* urllib.parse.parse_qs: a=1&b=2&a=3 -> {a: ["1", "3"], b: "2"} (blank values dropped, + is a space) */
static V parse_qs(const char *q, size_t n) {
    V m = vrt_map();
    size_t i = 0;
    while (i < n) {
        size_t j = i;
        while (j < n && q[j] != '&' && q[j] != ';') j++;
        const char *eq = memchr(q + i, '=', j - i);
        if (eq && (size_t)(q + j - eq - 1) > 0) {
            V k = unquote(q + i, (size_t)(eq - q - i), 1), v = unquote(eq + 1, (size_t)(q + j - eq - 1), 1);
            int f = 0; V old = vrt_map_get(m, k, &f);
            if (!f) vrt_map_set(m, k, v);
            else if (old.t == VT_LIST) vrt_list_push(old, v);
            else { V l = vrt_list(2); vrt_list_push(l, old); vrt_list_push(l, v); vrt_map_set(m, k, l); }
        }
        i = j + 1;
    }
    return m;
}
static const char *reason(int code) {
    switch (code) {
    case 200: return "OK"; case 201: return "Created"; case 202: return "Accepted"; case 204: return "No Content";
    case 301: return "Moved Permanently"; case 302: return "Found"; case 303: return "See Other"; case 304: return "Not Modified";
    case 307: return "Temporary Redirect"; case 308: return "Permanent Redirect";
    case 400: return "Bad Request"; case 401: return "Unauthorized"; case 403: return "Forbidden"; case 404: return "Not Found";
    case 405: return "Method Not Allowed"; case 409: return "Conflict"; case 410: return "Gone"; case 418: return "I'm a Teapot";
    case 422: return "Unprocessable Entity"; case 429: return "Too Many Requests";
    case 500: return "Internal Server Error"; case 501: return "Not Implemented"; case 502: return "Bad Gateway"; case 503: return "Service Unavailable";
    default: return "";
    }
}
static const char *MIME[][2] = {
    {".html", "text/html; charset=utf-8"}, {".htm", "text/html; charset=utf-8"}, {".css", "text/css"}, {".js", "text/javascript"},
    {".json", "application/json"}, {".txt", "text/plain; charset=utf-8"}, {".png", "image/png"}, {".jpg", "image/jpeg"},
    {".jpeg", "image/jpeg"}, {".gif", "image/gif"}, {".svg", "image/svg+xml"}, {".ico", "image/x-icon"}, {".pdf", "application/pdf"},
    {".wasm", "application/wasm"}, {".mp3", "audio/mpeg"}, {".mp4", "video/mp4"}, {".webp", "image/webp"}, {".xml", "application/xml"},
    {".csv", "text/csv"}, {".woff2", "font/woff2"}, {NULL, NULL}
};
static const char *mime_of(const char *path) {
    const char *slash = strrchr(path, '/'), *dot = strrchr(path, '.');
    if (!dot || (slash && dot < slash) || dot == (slash ? slash + 1 : path)) return "application/octet-stream";
    for (int i = 0; MIME[i][0]; i++) if (!strcasecmp(MIME[i][0], dot)) return MIME[i][1];
    return "application/octet-stream";
}

typedef struct { int status; Buf headers; char *body; size_t blen; char ctype[256]; } Reply;
static void reply_text(Reply *r, int status, const char *text, const char *ctype) {
    r->status = status; r->blen = strlen(text); r->body = strdup(text); snprintf(r->ctype, sizeof r->ctype, "%s", ctype);
}
static int read_file(const char *path, Reply *r) {
    struct stat st;
    if (stat(path, &st) || !S_ISREG(st.st_mode)) return 0;
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    r->body = malloc((size_t)st.st_size + 1);
    r->blen = fread(r->body, 1, (size_t)st.st_size, f);
    fclose(f);
    return 1;
}
static char *expand_home(V v) {
    V s = vrt_display(v); const char *p = AS_STR(s)->data;
    if (p[0] == '~' && (p[1] == '/' || !p[1])) { const char *h = getenv("HOME"); char *o = malloc(strlen(h ? h : "") + strlen(p) + 1); sprintf(o, "%s%s", h ? h : "", p + 1); return o; }
    return strdup(p);
}
static void static_reply(V folder, const char *rest, Reply *r) {
    char *dir = expand_home(folder);
    Buf path = {0}; bputs(&path, dir); free(dir);
    const char *p = rest;
    while (*p) {
        while (*p == '/') p++;
        const char *e = p; while (*e && *e != '/') e++;
        if (e > p) {
            if (e - p == 2 && p[0] == '.' && p[1] == '.') { free(path.p); reply_text(r, 404, "not found", "text/plain; charset=utf-8"); return; }
            bputs(&path, "/"); bput(&path, p, (size_t)(e - p));
        }
        p = e;
    }
    struct stat st;
    if (stat(path.p, &st) == 0 && S_ISDIR(st.st_mode)) bputs(&path, "/index.html");
    if (!read_file(path.p, r)) { free(path.p); reply_text(r, 404, "not found", "text/plain; charset=utf-8"); return; }
    r->status = 200;
    snprintf(r->ctype, sizeof r->ctype, "%s", mime_of(path.p));
    free(path.p);
}
static V mget(V m, const char *k, int *found) { return vrt_map_get(m, vrt_cstr(k), found); }
static void add_header(Reply *r, const char *k, const char *v) { bputs(&r->headers, k); bputs(&r->headers, ": "); bputs(&r->headers, v); bputs(&r->headers, "\r\n"); }
static int has_header(Reply *r, const char *k) {
    if (!r->headers.p) return 0;
    size_t n = strlen(k);
    for (const char *p = r->headers.p; *p; ) { if (!strncasecmp(p, k, n) && p[n] == ':') return 1; p = strstr(p, "\r\n"); if (!p) break; p += 2; }
    return 0;
}
static void respond(V result, Reply *r) {
    r->status = 200;
    snprintf(r->ctype, sizeof r->ctype, "text/html; charset=utf-8");
    if (result.t == VT_MAP) {
        int f;
        V st = mget(result, "status", &f);
        if (f) { if (st.t == VT_INT) r->status = (int)st.u.i; else if (st.t == VT_FLOAT) r->status = (int)st.u.f; else r->status = atoi(AS_STR(vrt_display(st))->data); }
        V hh = mget(result, "headers", &f);
        if (f && hh.t == VT_MAP) {
            VMap *m = AS_MAP(hh);
            for (int64_t i = 0; i < m->nent; i++) if (m->ents[i].used) {
                V k = vrt_display(m->ents[i].key); vrt_pin(k);
                V v = vrt_display(m->ents[i].val);
                add_header(r, AS_STR(k)->data, AS_STR(v)->data);
                vrt_unpin(1);
            }
        }
        int ft, fc; V ty = mget(result, "type", &ft), ct = mget(result, "content_type", &fc);
        V file = mget(result, "file", &f);
        if (f) {
            char *fp = expand_home(file);
            if (ft || fc) snprintf(r->ctype, sizeof r->ctype, "%s", AS_STR(vrt_display(ft ? ty : ct))->data);
            else snprintf(r->ctype, sizeof r->ctype, "%s", mime_of(fp));
            V dl = mget(result, "download", &f);
            if (f && vrt_truthy(dl) && !has_header(r, "Content-Disposition")) {
                const char *base = strrchr(fp, '/'); base = base ? base + 1 : fp;
                char hv[600]; snprintf(hv, sizeof hv, "attachment; filename=\"%s\"", base);
                add_header(r, "Content-Disposition", hv);
            }
            if (!read_file(fp, r)) {
                char msg[4200]; snprintf(msg, sizeof msg, "not found: %s", fp);
                free(r->headers.p); r->headers = (Buf){0};
                reply_text(r, 404, msg, "text/plain; charset=utf-8");
            }
            free(fp);
            return;
        }
        V bl = mget(result, "bytes", &f);
        if (f && bl.t == VT_LIST) {
            VList *l = AS_LIST(bl);
            r->body = malloc((size_t)l->len + 1); r->blen = (size_t)l->len;
            for (int64_t i = 0; i < l->len; i++) r->body[i] = (char)((l->items[i].t == VT_INT ? l->items[i].u.i : (int64_t)l->items[i].u.f) & 0xFF);
            snprintf(r->ctype, sizeof r->ctype, "%s", (ft || fc) ? AS_STR(vrt_display(ft ? ty : ct))->data : "application/octet-stream");
            return;
        }
        V raw = mget(result, "body", &f);
        if (!f) raw = vrt_cstr("");
        if (raw.t == VT_MAP || raw.t == VT_LIST) {
            V tj = vrt_builtin_named("to_json");
            V js = vrt_call(tj, 1, &raw);
            r->blen = (size_t)AS_STR(js)->len; r->body = malloc(r->blen + 1); memcpy(r->body, AS_STR(js)->data, r->blen);
            snprintf(r->ctype, sizeof r->ctype, "application/json");
        } else if (raw.t == VT_BYTES) {
            r->blen = (size_t)AS_BYTES(raw)->len; r->body = malloc(r->blen + 1); memcpy(r->body, AS_BYTES(raw)->data, r->blen);
            snprintf(r->ctype, sizeof r->ctype, "application/octet-stream");
        } else {
            V s = vrt_display(raw);
            r->blen = (size_t)AS_STR(s)->len; r->body = malloc(r->blen + 1); memcpy(r->body, AS_STR(s)->data, r->blen);
        }
        if (ft || fc) snprintf(r->ctype, sizeof r->ctype, "%s", AS_STR(vrt_display(ft ? ty : ct))->data);
        return;
    }
    if (result.t == VT_BYTES) {
        r->blen = (size_t)AS_BYTES(result)->len; r->body = malloc(r->blen + 1); memcpy(r->body, AS_BYTES(result)->data, r->blen);
        snprintf(r->ctype, sizeof r->ctype, "application/octet-stream");
        return;
    }
    V s = vrt_display(result);
    r->blen = (size_t)AS_STR(s)->len; r->body = malloc(r->blen + 1); memcpy(r->body, AS_STR(s)->data, r->blen);
}
/* '/users/:id' against '/users/7' -> {id: "7"}; a final '*' takes the rest. Returns VUNDEF when it doesn't match. */
static V route_match(const char *pat, const char *path) {
    V params = vrt_map();
    const char *p = pat, *x = path;
    for (;;) {
        while (*p == '/') p++;
        while (*x == '/') x++;
        if (!*p) return *x ? VUNDEF : params;
        const char *pe = p; while (*pe && *pe != '/') pe++;
        if (pe - p == 1 && *p == '*') {
            Buf rest = {0}; bput(&rest, "", 0);
            /* join the remaining non-empty segments with '/' */
            const char *q = x;
            while (*q) {
                while (*q == '/') q++;
                const char *qe = q; while (*qe && *qe != '/') qe++;
                if (qe > q) { if (rest.len) bput(&rest, "/", 1); bput(&rest, q, (size_t)(qe - q)); }
                q = qe;
            }
            vrt_map_set(params, vrt_cstr("*"), vrt_str(rest.p, (int64_t)rest.len));
            free(rest.p);
            return params;
        }
        if (!*x) return VUNDEF;
        const char *xe = x; while (*xe && *xe != '/') xe++;
        if (*p == ':') vrt_map_set(params, vrt_str(p + 1, pe - p - 1), vrt_str(x, xe - x));
        else if (pe - p != xe - x || strncmp(p, x, (size_t)(pe - p))) return VUNDEF;
        p = pe; x = xe;
    }
}
static void dispatch(V handler, V request, Reply *r) {
    if (handler.t != VT_MAP) { V res = vrt_call(handler, 1, &request); respond(res, r); return; }
    int f;
    char method[32]; snprintf(method, sizeof method, "%s", AS_STR(mget(request, "method", &f))->data);
    V pathv = mget(request, "path", &f);
    VMap *m = AS_MAP(handler);
    for (int64_t i = 0; i < m->nent; i++) {
        if (!m->ents[i].used) continue;
        V kd = vrt_display(m->ents[i].key);
        char key[1024]; snprintf(key, sizeof key, "%s", AS_STR(kd)->data);
        char *k = key; while (isspace((unsigned char)*k)) k++;
        size_t kl = strlen(k); while (kl && isspace((unsigned char)k[kl - 1])) k[--kl] = 0;
        char want[64] = ""; char *pattern = k;
        char *sp = strchr(k, ' ');
        if (sp) { size_t wl = (size_t)(sp - k); if (wl > 63) wl = 63; memcpy(want, k, wl); want[wl] = 0; pattern = sp + 1; while (*pattern == ' ') pattern++; }
        for (char *c = want; *c; c++) *c = (char)toupper((unsigned char)*c);
        if (*want && strcmp(want, method) && !(!strcmp(want, "GET") && !strcmp(method, "HEAD"))) continue;
        V params = route_match(pattern, AS_STR(pathv)->data);
        if (params.t == VT_UNDEF) continue;
        V target = m->ents[i].val;
        if (target.t == VT_STR) {
            int fs; V star = vrt_map_get(params, vrt_cstr("*"), &fs);
            const char *rest = fs ? AS_STR(star)->data : (strchr(pattern, '*') ? "" : AS_STR(pathv)->data);
            static_reply(target, rest, r);
            return;
        }
        vrt_map_set(request, vrt_cstr("params"), params);
        V res = vrt_call(target, 1, &request);
        respond(res, r);
        return;
    }
    reply_text(r, 404, "not found", "text/plain; charset=utf-8");
}

typedef struct Conn { int fd; Server *srv; char ip[64]; } Conn;
static ssize_t recv_some(int fd, char *b, size_t n) {
    ssize_t r;
    VRT_BLOCKING_BEGIN();
    if (!wait_fd(fd, 0, 30)) r = -1;
    else do { r = recv(fd, b, n, 0); } while (r < 0 && errno == EINTR);
    VRT_BLOCKING_END();
    return r;
}
static int ws_serve(int fd, V handler, V request, const char *key, const char *pre, size_t npre);
static void conn_main(void *p) {
    Conn *c = p;
    Server *srv = c->srv;
    Buf in = {0};
    char tmp[16384];
    char *hdr_end = NULL;
    while (!(hdr_end = in.p ? strstr(in.p, "\r\n\r\n") : NULL)) {
        ssize_t r = recv_some(c->fd, tmp, sizeof tmp);
        if (r <= 0 || in.len > (1 << 20)) { close(c->fd); free(in.p); free(c); return; }
        bput(&in, tmp, (size_t)r);
    }
    size_t head_len = (size_t)(hdr_end - in.p) + 4;
    /* request line */
    char method[32] = "", target[8192] = "";
    sscanf(in.p, "%31s %8191s", method, target);
    /* Content-Length */
    size_t clen = 0;
    for (char *line = strstr(in.p, "\r\n"); line && line < hdr_end; line = strstr(line + 2, "\r\n")) {
        if (!strncasecmp(line + 2, "Content-Length:", 15)) clen = (size_t)strtoull(line + 17, NULL, 10);
    }
    while (in.len < head_len + clen) {
        ssize_t r = recv_some(c->fd, tmp, sizeof tmp);
        if (r <= 0) break;
        bput(&in, tmp, (size_t)r);
    }
    if (in.len < head_len + clen) clen = in.len - head_len;

    /* build the request map (holding the lock) */
    V request = vrt_map();
    vrt_pin(request);
    char *q = strchr(target, '?');
    size_t plen = q ? (size_t)(q - target) : strlen(target);
    char *frag = strchr(target, '#');
    if (frag && (!q || frag < q)) plen = (size_t)(frag - target);
    vrt_map_set(request, vrt_cstr("method"), vrt_cstr(method));
    vrt_map_set(request, vrt_cstr("path"), unquote(target, plen, 0));
    size_t qlen = q ? (frag && frag > q ? (size_t)(frag - q - 1) : strlen(q + 1)) : 0;
    vrt_map_set(request, vrt_cstr("query"), q ? parse_qs(q + 1, qlen) : vrt_map());
    V headers = vrt_map();
    vrt_map_set(request, vrt_cstr("headers"), headers);
    char ctype[256] = "", upgrade[64] = "", wskey[128] = "";
    for (char *line = strstr(in.p, "\r\n"); line && line < hdr_end; ) {
        char *ls = line + 2, *le = strstr(ls, "\r\n");
        if (!le || ls >= hdr_end) break;
        char *colon = memchr(ls, ':', (size_t)(le - ls));
        if (colon) {
            char *v = colon + 1; while (v < le && (*v == ' ' || *v == '\t')) v++;
            char *ve = le; while (ve > v && (ve[-1] == ' ' || ve[-1] == '\t')) ve--;
            vrt_map_set(headers, vrt_str(ls, colon - ls), vrt_str(v, ve - v));
            size_t vl = (size_t)(ve - v);
            if ((size_t)(colon - ls) == 7 && !strncasecmp(ls, "Upgrade", 7)) { size_t k = vl < 63 ? vl : 63; for (size_t i = 0; i < k; i++) upgrade[i] = (char)tolower((unsigned char)v[i]); upgrade[k] = 0; }
            if ((size_t)(colon - ls) == 17 && !strncasecmp(ls, "Sec-WebSocket-Key", 17)) { size_t k = vl < 127 ? vl : 127; memcpy(wskey, v, k); wskey[k] = 0; }
            if ((size_t)(colon - ls) == 12 && !strncasecmp(ls, "Content-Type", 12)) {
                size_t n = (size_t)(ve - v) < sizeof ctype - 1 ? (size_t)(ve - v) : sizeof ctype - 1;
                for (size_t i = 0; i < n; i++) ctype[i] = (char)tolower((unsigned char)v[i]);
                ctype[n] = 0;
            }
        }
        line = le;
    }
    V body = vrt_str(in.p + head_len, (int64_t)clen);
    vrt_map_set(request, vrt_cstr("body"), body);
    vrt_map_set(request, vrt_cstr("params"), vrt_map());
    V js = VNIL;
    if (strstr(ctype, "json") && clen) {
        VTry tr; vrt_try_push(&tr);
        if (setjmp(tr.jb) == 0) { V fj = vrt_builtin_named("from_json"); js = vrt_call(fj, 1, &body); vrt_try_pop(); }
        else js = VNIL;
    }
    vrt_map_set(request, vrt_cstr("json"), js);
    vrt_map_set(request, vrt_cstr("form"), strstr(ctype, "application/x-www-form-urlencoded") ? parse_qs(in.p + head_len, clen) : vrt_map());
    vrt_map_set(request, vrt_cstr("client"), vrt_cstr(c->ip));
    if (!strcmp(method, "GET") && srv->handler.t == VT_MAP && !strcmp(upgrade, "websocket")
        && ws_serve(c->fd, srv->handler, request, wskey, in.p + head_len + clen, in.len - head_len - clen)) {
        free(in.p); free(c); vrt_unpin(1);
        return;
    }
    free(in.p);

    /* handlers take turns: one at a time per server */
    while (srv->busy) vrt_wait_change(vrt_change_seen(), -1);
    srv->busy = 1;
    Reply r;
    memset(&r, 0, sizeof r);
    VTry tr;
    vrt_try_push(&tr);
    if (setjmp(tr.jb) == 0) {
        dispatch(srv->handler, request, &r);
        vrt_try_pop();
    } else {
        char msg[1200];
        int ln = vrt_line & 0xFFFFF;
        if (ln) snprintf(msg, sizeof msg, "Vanta error: line %d: %s", ln, vrt_errmsg);
        else snprintf(msg, sizeof msg, "Vanta error: %s", vrt_errmsg);
        free(r.body); free(r.headers.p);
        memset(&r, 0, sizeof r);
        reply_text(&r, 500, msg, "text/plain; charset=utf-8");
    }
    srv->busy = 0;
    vrt_notify_all();
    vrt_unpin(1);

    /* the reply, written without the lock */
    Buf out = {0};
    char line[512];
    snprintf(line, sizeof line, "HTTP/1.0 %d %s\r\n", r.status, reason(r.status));
    bputs(&out, line);
    bputs(&out, "Server: Vanta/6.0\r\n");
    char date[64]; time_t now = time(NULL); struct tm g; gmtime_r(&now, &g);
    strftime(date, sizeof date, "%a, %d %b %Y %H:%M:%S GMT", &g);
    snprintf(line, sizeof line, "Date: %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n", date, r.ctype, r.blen);
    bputs(&out, line);
    if (r.headers.p) bputs(&out, r.headers.p);
    bputs(&out, "\r\n");
    if (strcmp(method, "HEAD") && r.blen) bput(&out, r.body, r.blen);
    {
        VRT_BLOCKING_BEGIN();
        const char *pp = out.p; size_t n = out.len;
        while (n) { ssize_t w = send(c->fd, pp, n, 0); if (w < 0) { if (errno == EINTR) continue; break; } pp += w; n -= (size_t)w; }
        shutdown(c->fd, SHUT_WR);
        char drain[512];
        struct pollfd pf = {c->fd, POLLIN, 0};
        if (poll(&pf, 1, 100) > 0) (void)recv(c->fd, drain, sizeof drain, 0);
        close(c->fd);
        VRT_BLOCKING_END();
    }
    free(out.p); free(r.body); free(r.headers.p); free(c);
}
static void accept_loop(Server *srv) {
    while (!srv->stop) {
        int fd = -1;
        struct sockaddr_storage ss; socklen_t len = sizeof ss;
        {
            VRT_BLOCKING_BEGIN();
            if (wait_fd(srv->fd, 0, 0.2) && !srv->stop) fd = accept(srv->fd, (struct sockaddr *)&ss, &len);
            VRT_BLOCKING_END();
        }
        if (fd < 0) continue;
#ifdef SO_NOSIGPIPE
        int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
        Conn *c = calloc(1, sizeof *c);
        c->fd = fd; c->srv = srv;
        if (ss.ss_family == AF_INET) inet_ntop(AF_INET, &((struct sockaddr_in *)&ss)->sin_addr, c->ip, sizeof c->ip);
        else inet_ntop(AF_INET6, &((struct sockaddr_in6 *)&ss)->sin6_addr, c->ip, sizeof c->ip);
        vrt_thread_start(conn_main, c);
    }
}
static void server_thread(void *p) {
    Server *srv = p;
    accept_loop(srv);
    if (srv->fd >= 0) { close(srv->fd); srv->fd = -1; }
    vrt_unkeep(srv->self);
    vrt_notify_all();
}
static void stop_and_wait(Server *s) {
    s->stop = 1;
    while (s->fd >= 0) vrt_wait_change(vrt_change_seen(), 0.05);
}
static Server *new_server(int64_t port, V handler, const char *fname) {
    if (!(handler.t == VT_FUNC || handler.t == VT_BUILTIN || handler.t == VT_BOUND || handler.t == VT_TYPE || handler.t == VT_MAP))
        vrt_fail("a server's handler must be a function (request -> page) or a map of routes");
    (void)fname;
    int err = 0, fd = bind_inet(SOCK_STREAM, VUNDEF, port, &err);
    if (fd < 0) vrt_fail("could not listen on port %lld: %s", (long long)port, strerror(err));
    signal(SIGPIPE, SIG_IGN);
    Server *s = calloc(1, sizeof *s);
    s->fd = fd;
    s->handler = handler;
    struct sockaddr_in sa; socklen_t len = sizeof sa;
    getsockname(fd, (struct sockaddr *)&sa, &len);
    s->port = ntohs(sa.sin_port);
    s->self = vrt_handle("server", s, server_trace, server_free);
    return s;
}
static V b_start_server(int argc, V *a) {
    NEED(2, "start_server");
    Server *s = new_server(int_arg(a[0], "start_server"), a[1], "start_server");
    vrt_keep(s->self);
    vrt_thread_start(server_thread, s);
    return s->self;
}
static V b_serve(int argc, V *a) {
    if (argc != 1 && argc != 2) vrt_fail("serve expects a port and a handler function or routes map (or just a handler — port defaults to 8080)");
    Server *s = new_server(argc == 1 ? 8080 : int_arg(a[0], "serve"), argc == 1 ? a[0] : a[1], "serve");
    vrt_pin(s->self);
    vrt_threads_init();
    printf("Vanta server running on http://localhost:%d  (press Stop / Ctrl-C to quit)\n", s->port);
    fflush(stdout);
    accept_loop(s);
    vrt_unpin(1);
    printf("Server stopped.\n");
    return VNIL;
}
static V b_server_port(int argc, V *a) { NEED(1, "server_port"); return VI(((Server *)vrt_handle_data(a[0], "server", "server_port"))->port); }
static V b_stop_server(int argc, V *a) {
    NEED(1, "stop_server");
    stop_and_wait(vrt_handle_data(a[0], "server", "stop_server"));
    return VNIL;
}
static V server_close(int argc, V *a) { (void)argc; stop_and_wait(vrt_handle_data(a[0], "server", "close")); return VNIL; }
static V b_json_response(int argc, V *a) {
    if (argc != 1 && argc != 2) vrt_fail("json_response expects a value and an optional status");
    V tj = vrt_builtin_named("to_json");
    V m = vrt_map();
    vrt_map_set(m, vrt_cstr("status"), argc == 2 ? VI(int_arg(a[1], "json_response")) : VI(200));
    vrt_map_set(m, vrt_cstr("body"), vrt_call(tj, 1, a));
    vrt_map_set(m, vrt_cstr("type"), vrt_cstr("application/json"));
    return m;
}

/* =====================================================================================================
 * WebSockets (ws://): ws_connect, and "WS /path" routes in the server
 * ===================================================================================================== */
typedef struct WS { Sock *sk; int mask, closed; } WS;
static void ws_free(void *p) { WS *w = p; sock_free(w->sk); free(w); }
static void rand_bytes(unsigned char *b, size_t n) {
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__)
    arc4random_buf(b, n);
#else
    FILE *f = fopen("/dev/urandom", "rb");
    if (!f || fread(b, 1, n, f) != n) for (size_t i = 0; i < n; i++) b[i] = (unsigned char)rand();
    if (f) fclose(f);
#endif
}
static void b64(const unsigned char *in, size_t n, char *out) {
    static const char T[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t o = 0;
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)in[i] << 16 | (i + 1 < n ? (uint32_t)in[i + 1] << 8 : 0) | (i + 2 < n ? in[i + 2] : 0);
        out[o++] = T[v >> 18 & 63]; out[o++] = T[v >> 12 & 63];
        out[o++] = i + 1 < n ? T[v >> 6 & 63] : '='; out[o++] = i + 2 < n ? T[v & 63] : '=';
    }
    out[o] = 0;
}
static void ws_accept(const char *key, char *out) {      /* base64(sha1(key + GUID)) */
    char joined[256];
    snprintf(joined, sizeof joined, "%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", key);
    V arg = vrt_cstr(joined);
    V hex = vrt_call(vrt_builtin_named("sha1"), 1, &arg);
    unsigned char dig[20];
    for (int i = 0; i < 20; i++) dig[i] = (unsigned char)(hexv(AS_STR(hex)->data[2 * i]) * 16 + hexv(AS_STR(hex)->data[2 * i + 1]));
    b64(dig, 20, out);
}
static int ws_exact(Sock *s, unsigned char *dst, size_t n) {    /* 1 ok, 0 end, -2 timeout, -1 error */
    size_t got = 0;
    while (got < n) {
        if (s->len) {
            size_t k = s->len < n - got ? s->len : n - got;
            memcpy(dst + got, s->buf, k); memmove(s->buf, s->buf + k, s->len - k); s->len -= k; got += k;
            continue;
        }
        ssize_t r = fill(s, (char *)dst + got, n - got);
        if (r == 0) return 0;
        if (r < 0) return (int)r;
        got += (size_t)r;
    }
    return 1;
}
static void ws_frame(WS *w, int op, const char *data, size_t n) {
    if (w->closed) vrt_fail("that websocket is closed");
    unsigned char head[14]; size_t h = 0;
    head[h++] = (unsigned char)(0x80 | op);
    unsigned char mbit = w->mask ? 0x80 : 0;
    if (n < 126) head[h++] = (unsigned char)(mbit | n);
    else if (n < 65536) { head[h++] = mbit | 126; head[h++] = (unsigned char)(n >> 8); head[h++] = (unsigned char)n; }
    else { head[h++] = mbit | 127; for (int i = 7; i >= 0; i--) head[h++] = (unsigned char)((uint64_t)n >> (8 * i)); }
    char *buf = malloc(h + 4 + n + 1);
    memcpy(buf, head, h);
    if (w->mask) {
        unsigned char key[4]; rand_bytes(key, 4);
        memcpy(buf + h, key, 4); h += 4;
        for (size_t i = 0; i < n; i++) buf[h + i] = (char)(data[i] ^ key[i % 4]);
    } else memcpy(buf + h, data, n);
    send_all(w->sk, buf, h + n);
    free(buf);
}
static V ws_send(int argc, V *a) {
    (void)argc;
    WS *w = vrt_handle_data(a[0], "websocket", "send");
    size_t n; char *d = data_of(a[1], &n);
    ws_frame(w, a[1].t == VT_BYTES ? 2 : 1, d, n);
    free(d);
    return VNIL;
}
static V ws_receive(int argc, V *a) {
    WS *w = vrt_handle_data(a[0], "websocket", "receive");
    if (w->closed) return VNIL;
    double saved = w->sk->timeout;
    w->sk->timeout = argc == 2 && a[1].t != VT_NIL ? num_arg(a[1], "receive") : -1;
    Buf msg = {0}; bput(&msg, "", 0);
    int kind = 1;
    for (;;) {
        unsigned char h[2]; int rc = ws_exact(w->sk, h, 2);
        if (rc == -2) { w->sk->timeout = saved; free(msg.p); return VNIL; }
        if (rc <= 0) { w->closed = 1; w->sk->timeout = saved; free(msg.p); return VNIL; }
        int op = h[0] & 15; uint64_t n = h[1] & 127;
        unsigned char ext[8], key[4];
        if (n == 126) { if (ws_exact(w->sk, ext, 2) <= 0) break; n = (uint64_t)ext[0] << 8 | ext[1]; }
        else if (n == 127) { if (ws_exact(w->sk, ext, 8) <= 0) break; n = 0; for (int i = 0; i < 8; i++) n = n << 8 | ext[i]; }
        if ((h[1] & 128) && ws_exact(w->sk, key, 4) <= 0) break;
        unsigned char *data = malloc(n + 1);
        if (n && ws_exact(w->sk, data, n) <= 0) { free(data); break; }
        if (h[1] & 128) for (uint64_t i = 0; i < n; i++) data[i] ^= key[i % 4];
        if (op == 8) {
            if (!w->closed) { ws_frame(w, 8, (char *)data, n < 2 ? n : 2); }
            w->closed = 1; free(data); free(msg.p);
            if (w->sk->fd >= 0) { close(w->sk->fd); w->sk->fd = -1; }
            return VNIL;
        }
        if (op == 9) { ws_frame(w, 10, (char *)data, n); free(data); continue; }
        if (op == 10) { free(data); continue; }
        if (op == 1 || op == 2) kind = op;
        bput(&msg, data, n);
        free(data);
        if (h[0] & 128) {
            w->sk->timeout = saved;
            V r;
            if (kind == 1) r = vrt_str(msg.p, (int64_t)msg.len);
            else { r = vrt_bytes((int64_t)msg.len); memcpy(AS_BYTES(r)->data, msg.p, msg.len); }
            free(msg.p);
            return r;
        }
    }
    w->closed = 1; w->sk->timeout = saved; free(msg.p);
    return VNIL;
}
static V ws_close(int argc, V *a) {
    (void)argc;
    WS *w = vrt_handle_data(a[0], "websocket", "close");
    if (!w->closed && w->sk->fd >= 0) {
        VTry tr; vrt_try_push(&tr);
        if (setjmp(tr.jb) == 0) { ws_frame(w, 8, "\x03\xe8", 2); vrt_try_pop(); }
        w->closed = 1;
    }
    w->closed = 1;
    if (w->sk->fd >= 0) { close(w->sk->fd); w->sk->fd = -1; }
    return VNIL;
}
static V new_ws(int fd, int mask, const char *pre, size_t npre) {
    Sock *s = calloc(1, sizeof *s);
    s->fd = fd; s->timeout = -1;
    if (npre) { s->buf = malloc(npre); memcpy(s->buf, pre, npre); s->len = npre; }
    WS *w = calloc(1, sizeof *w);
    w->sk = s; w->mask = mask;
    return vrt_handle("websocket", w, NULL, ws_free);
}
/* the server side: upgrade if a "WS /path" route matches, then run the route's function with (ws, request) */
static int ws_serve(int fd, V handler, V request, const char *key, const char *pre, size_t npre) {
    int f;
    V pathv = vrt_map_get(request, vrt_cstr("path"), &f);
    VMap *m = AS_MAP(handler);
    for (int64_t i = 0; i < m->nent; i++) {
        if (!m->ents[i].used || m->ents[i].val.t == VT_STR) continue;
        V kd = vrt_display(m->ents[i].key);
        char k[1024]; snprintf(k, sizeof k, "%s", AS_STR(kd)->data);
        char *p = k; while (isspace((unsigned char)*p)) p++;
        if (strncasecmp(p, "WS ", 3)) continue;
        char *pattern = p + 3; while (*pattern == ' ') pattern++;
        size_t pl = strlen(pattern); while (pl && isspace((unsigned char)pattern[pl - 1])) pattern[--pl] = 0;
        V params = route_match(pattern, AS_STR(pathv)->data);
        if (params.t == VT_UNDEF) continue;
        vrt_map_set(request, vrt_cstr("params"), params);
        char acc[64]; ws_accept(key, acc);
        char resp[256];
        snprintf(resp, sizeof resp, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", acc);
        V ws = new_ws(fd, 0, pre, npre);
        vrt_pin(ws);
        WS *w = ((VHandle *)ws.u.o)->data;
        VTry tr; vrt_try_push(&tr);
        if (setjmp(tr.jb) == 0) {
            send_all(w->sk, resp, strlen(resp));
            V args[2] = {ws, request};
            vrt_call(m->ents[i].val, 2, args);
            vrt_try_pop();
        }
        ws_close(1, &ws);
        vrt_unpin(1);
        return 1;
    }
    return 0;
}
static V b_ws_connect(int argc, V *a) {
    if (argc != 1 && argc != 2) vrt_fail("ws_connect expects a ws:// url and an optional headers map");
    V uv = vrt_display(a[0]);
    const char *url = AS_STR(uv)->data;
    if (strncmp(url, "ws://", 5)) vrt_fail("ws_connect needs a ws:// url");
    const char *hp = url + 5, *slash = strchr(hp, '/'), *qm = strchr(hp, '?');
    if (qm && (!slash || qm < slash)) slash = qm;
    char host[512]; size_t hl = slash ? (size_t)(slash - hp) : strlen(hp);
    if (hl == 0 || hl >= sizeof host) vrt_fail("ws_connect needs a ws:// url");
    memcpy(host, hp, hl); host[hl] = 0;
    int64_t port = 80;
    char *colon = strrchr(host, ':');
    if (colon && !strchr(colon, ']')) { port = atoll(colon + 1); *colon = 0; }
    char path[4096]; snprintf(path, sizeof path, "%s%s", slash && *slash == '?' ? "/" : "", slash ? slash : "/");
    V cargs[3] = {vrt_cstr(host), VI(port), VI(10)};
    vrt_pin(cargs[0]);
    V sock = b_tcp_connect(3, cargs);
    vrt_unpin(1);
    vrt_pin(sock);
    Sock *s = vrt_handle_data(sock, "socket", "ws_connect");
    unsigned char raw[16]; char key[32]; rand_bytes(raw, 16); b64(raw, 16, key);
    Buf req = {0};
    char line[4700];
    snprintf(line, sizeof line, "GET %s HTTP/1.1\r\nHost: %s:%lld\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n", path, host, (long long)port, key);
    bput(&req, line, strlen(line));
    if (argc == 2 && a[1].t == VT_MAP) {
        VMap *m = AS_MAP(a[1]);
        for (int64_t i = 0; i < m->nent; i++) if (m->ents[i].used) {
            V k = vrt_display(m->ents[i].key); vrt_pin(k); V v = vrt_display(m->ents[i].val);
            bput(&req, AS_STR(k)->data, (size_t)AS_STR(k)->len); bput(&req, ": ", 2); bput(&req, AS_STR(v)->data, (size_t)AS_STR(v)->len); bput(&req, "\r\n", 2);
            vrt_unpin(1);
        }
    }
    bput(&req, "\r\n", 2);
    send_all(s, req.p, req.len);
    free(req.p);
    char want[64]; ws_accept(key, want);
    V statusv = sock_read_line(1, &sock);
    char status[512] = "no reply";
    if (statusv.t == VT_STR) snprintf(status, sizeof status, "%s", AS_STR(statusv)->data);
    int ok = 0;
    for (;;) {
        V l = sock_read_line(1, &sock);
        if (l.t != VT_STR || AS_STR(l)->len == 0) break;
        const char *ls = AS_STR(l)->data, *c = strchr(ls, ':');
        if (c && (size_t)(c - ls) == 20 && !strncasecmp(ls, "Sec-WebSocket-Accept", 20)) {
            const char *v = c + 1; while (*v == ' ') v++;
            char val[128]; snprintf(val, sizeof val, "%s", v);
            size_t vl = strlen(val); while (vl && isspace((unsigned char)val[vl - 1])) val[--vl] = 0;
            if (!strcmp(val, want)) ok = 1;
        }
    }
    if (!strstr(status, " 101") || !ok) { sock_close(1, &sock); vrt_unpin(1); vrt_fail("websocket handshake failed: %s", status); }
    /* hand the connection (and anything already read) to a websocket handle */
    V ws = new_ws(s->fd, 1, s->buf, s->len);
    s->fd = -1; s->len = 0;
    vrt_unpin(1);
    return ws;
}

static V b_redirect(int argc, V *a) {
    if (argc != 1 && argc != 2) vrt_fail("redirect expects a url and an optional status");
    V m = vrt_map(), h = vrt_map();
    vrt_map_set(m, vrt_cstr("status"), argc == 2 ? VI(int_arg(a[1], "redirect")) : VI(302));
    vrt_map_set(h, vrt_cstr("Location"), vrt_display(a[0]));
    vrt_map_set(m, vrt_cstr("headers"), h);
    vrt_map_set(m, vrt_cstr("body"), vrt_cstr(""));
    return m;
}

typedef VEntry Entry;
static const Entry net_table[] = {
    {"tcp_connect", b_tcp_connect}, {"tcp_listen", b_tcp_listen}, {"accept", b_accept}, {"set_timeout", b_set_timeout},
    {"socket_info", b_socket_info}, {"udp_open", b_udp_open}, {"udp_send", b_udp_send}, {"udp_receive", b_udp_receive},
    {"dns_lookup", b_dns_lookup}, {"ws_connect", b_ws_connect}, {"serve", b_serve}, {"start_server", b_start_server}, {"server_port", b_server_port},
    {"stop_server", b_stop_server}, {"json_response", b_json_response}, {"redirect", b_redirect},
    {NULL, NULL}
};
__attribute__((constructor)) static void vrt_net_register(void) {
    vrt_register_builtins(net_table);
    vrt_register_op("socket", "send", sock_send);
    vrt_register_op("socket", "write_to", sock_send);
    vrt_register_op("socket", "receive", sock_receive);
    vrt_register_op("socket", "receive_bytes", sock_receive_bytes);
    vrt_register_op("socket", "read_line", sock_read_line);
    vrt_register_op("socket", "read_all", sock_read_all);
    vrt_register_op("socket", "close", sock_close);
    vrt_register_op("server", "close", server_close);
    vrt_register_op("websocket", "send", ws_send);
    vrt_register_op("websocket", "receive", ws_receive);
    vrt_register_op("websocket", "close", ws_close);
}
