#ifndef _KSYS_STAT_H
#define _KSYS_STAT_H
#include "../kcommon.h"
struct stat { mode_t st_mode; off_t st_size; time_t st_mtime; };
#define S_IFMT 0170000
#define S_IFDIR 0040000
#define S_IFREG 0100000
#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)
int stat(const char *p, struct stat *st);
int lstat(const char *p, struct stat *st);
int mkdir(const char *p, mode_t mode);
#endif
