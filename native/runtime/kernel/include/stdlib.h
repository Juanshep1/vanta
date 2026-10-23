#ifndef _KSTDLIB_H
#define _KSTDLIB_H
#include "kcommon.h"
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define RAND_MAX 0x7fffffff
void *malloc(size_t n);
void *calloc(size_t n, size_t size);
void *realloc(void *p, size_t n);
void free(void *p);
_Noreturn void exit(int code);
_Noreturn void abort(void);
int atexit(void (*fn)(void));
long strtol(const char *s, char **end, int base);
long long strtoll(const char *s, char **end, int base);
unsigned long strtoul(const char *s, char **end, int base);
unsigned long long strtoull(const char *s, char **end, int base);
double strtod(const char *s, char **end);
float strtof(const char *s, char **end);
double atof(const char *s);
int atoi(const char *s);
long atol(const char *s);
long long atoll(const char *s);
int abs(int x);
long labs(long x);
long long llabs(long long x);
void qsort(void *base, size_t n, size_t size, int (*cmp)(const void *, const void *));
void *bsearch(const void *key, const void *base, size_t n, size_t size, int (*cmp)(const void *, const void *));
int rand(void);
void srand(unsigned seed);
char *getenv(const char *name);
int system(const char *cmd);
char *realpath(const char *path, char *resolved);
#endif
