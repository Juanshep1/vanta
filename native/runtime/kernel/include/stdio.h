#ifndef _KSTDIO_H
#define _KSTDIO_H
#include "kcommon.h"
typedef struct KFILE { int fd; } FILE;
extern FILE *stdin, *stdout, *stderr;
#define EOF (-1)
#define _IOFBF 0
#define _IOLBF 1
#define _IONBF 2
#define BUFSIZ 1024
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
int printf(const char *fmt, ...);
int fprintf(FILE *f, const char *fmt, ...);
int sprintf(char *buf, const char *fmt, ...);
int snprintf(char *buf, size_t n, const char *fmt, ...);
int vsnprintf(char *buf, size_t n, const char *fmt, va_list ap);
int vprintf(const char *fmt, va_list ap);
int vfprintf(FILE *f, const char *fmt, va_list ap);
int puts(const char *s);
int putchar(int c);
int fputs(const char *s, FILE *f);
int fputc(int c, FILE *f);
int putc(int c, FILE *f);
size_t fwrite(const void *p, size_t size, size_t n, FILE *f);
size_t fread(void *p, size_t size, size_t n, FILE *f);
int fflush(FILE *f);
int setvbuf(FILE *f, char *buf, int mode, size_t size);
char *fgets(char *s, int n, FILE *f);
int getchar(void);
int fgetc(FILE *f);
int getc(FILE *f);
/* There are no files on bare metal (the kernel's ram file system has its own builtins): these always fail. */
FILE *fopen(const char *path, const char *mode);
FILE *popen(const char *cmd, const char *mode);
int pclose(FILE *f);
int fclose(FILE *f);
int fseek(FILE *f, long off, int whence);
long ftell(FILE *f);
int feof(FILE *f);
int ferror(FILE *f);
int remove(const char *path);
int rename(const char *a, const char *b);
void perror(const char *s);
#endif
