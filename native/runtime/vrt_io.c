/* vantac: optional */
#define _GNU_SOURCE
/* Vanta native runtime: the generic I/O builtins that work on several kinds of handle — close, send, receive,
 * receive_bytes, read_line, read_all, write_to, wait, is_done. Each kind (channel, socket, file, process, server,
 * database, task) registers its own version with vrt_register_op; these look it up. Same names and messages as
 * vanta.py. */
#include "vrt.h"
#include <string.h>

#define NEED(n, name) do { if (argc != (n)) vrt_fail("%s expects %d value(s), got %d", name, n, argc); } while (0)

static V dispatch(const char *op, const char *msg, int argc, V *a) {
    VBuiltinPtr f = vrt_find_op(a[0], op);
    if (!f) vrt_fail("%s", msg);
    return f(argc, a);
}

static V b_close(int argc, V *a) { NEED(1, "close"); return dispatch("close", "close needs a file, socket, channel, process, server or database", argc, a); }
static V b_send(int argc, V *a) { NEED(2, "send"); return dispatch("send", "send needs a channel or a socket", argc, a); }
static V b_receive(int argc, V *a) {
    if (argc < 1 || argc > 2) vrt_fail("receive expects a channel or socket (and a timeout or a size)");
    return dispatch("receive", "receive needs a channel or a socket", argc, a);
}
static V b_receive_bytes(int argc, V *a) {
    if (argc < 1 || argc > 2) vrt_fail("receive_bytes expects a socket and an optional size");
    return dispatch("receive_bytes", "receive_bytes needs a socket", argc, a);
}
static V b_read_line(int argc, V *a) { NEED(1, "read_line"); return dispatch("read_line", "read_line needs a file, socket or process", argc, a); }
static V b_read_all(int argc, V *a) { NEED(1, "read_all"); return dispatch("read_all", "read_all needs a file, socket or process", argc, a); }
static V b_write_to(int argc, V *a) { NEED(2, "write_to"); return dispatch("write_to", "write_to needs a file, socket or process", argc, a); }
static V b_is_done(int argc, V *a) { NEED(1, "is_done"); return dispatch("is_done", "is_done needs a task", argc, a); }
static V b_wait(int argc, V *a) {
    if (argc < 1 || argc > 2) vrt_fail("wait expects a task (or a list of tasks, or a process) and an optional timeout");
    if (argc == 2 && a[1].t != VT_INT && a[1].t != VT_FLOAT && a[1].t != VT_NIL) vrt_fail("wait needs a number");
    if (a[0].t == VT_LIST) {
        V out = vrt_list(AS_LIST(a[0])->len);
        vrt_pin(out);
        for (int64_t i = 0; i < AS_LIST(a[0])->len; i++) {
            V args[2] = {AS_LIST(a[0])->items[i], argc == 2 ? a[1] : VNIL};
            vrt_pin(args[0]);
            V r = dispatch("wait", "wait needs a task or a process", argc, args);
            vrt_unpin(1);
            vrt_list_push(out, r);
        }
        vrt_unpin(1);
        return out;
    }
    return dispatch("wait", "wait needs a task or a process", argc, a);
}

typedef VEntry Entry;
static const Entry io_table[] = {
    {"close", b_close}, {"send", b_send}, {"receive", b_receive}, {"receive_bytes", b_receive_bytes},
    {"read_line", b_read_line}, {"read_all", b_read_all}, {"write_to", b_write_to}, {"wait", b_wait}, {"is_done", b_is_done},
    {NULL, NULL}
};
__attribute__((constructor)) static void vrt_io_register(void) { vrt_register_builtins(io_table); }
