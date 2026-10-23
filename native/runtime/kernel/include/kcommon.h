/* Vanta kernel libc: shared declarations for the tiny freestanding C library that lets the normal Vanta runtime
 * (vrt.c, vrt_builtins.c) run on bare metal. Only what the runtime needs is here. */
#ifndef KCOMMON_H
#define KCOMMON_H
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
typedef long ssize_t;
typedef long off_t;
typedef int pid_t;
typedef unsigned int mode_t;
typedef long time_t;
#endif
