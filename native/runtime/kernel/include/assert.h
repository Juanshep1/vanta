#ifndef _KASSERT_H
#define _KASSERT_H
void kpanic(const char *msg);
#define assert(c) do { if (!(c)) kpanic("assertion failed: " #c); } while (0)
#endif
