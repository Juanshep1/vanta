#ifndef _KTIME_H
#define _KTIME_H
#include "kcommon.h"
typedef long clock_t;
typedef int clockid_t;
struct timespec { time_t tv_sec; long tv_nsec; };
struct tm { int tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst; long tm_gmtoff; const char *tm_zone; };
#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1
#define CLOCKS_PER_SEC 1000
time_t time(time_t *t);
clock_t clock(void);
int clock_gettime(clockid_t id, struct timespec *ts);
int nanosleep(const struct timespec *req, struct timespec *rem);
struct tm *localtime(const time_t *t);
struct tm *gmtime(const time_t *t);
struct tm *localtime_r(const time_t *t, struct tm *out);
struct tm *gmtime_r(const time_t *t, struct tm *out);
time_t mktime(struct tm *tm);
time_t timegm(struct tm *tm);
size_t strftime(char *buf, size_t n, const char *fmt, const struct tm *tm);
char *strptime(const char *s, const char *fmt, struct tm *tm);
double difftime(time_t a, time_t b);
#endif
