#ifndef _KUNISTD_H
#define _KUNISTD_H
#include "kcommon.h"
pid_t getpid(void);
unsigned sleep(unsigned s);
int usleep(unsigned us);
int chdir(const char *p);
char *getcwd(char *buf, size_t n);
int access(const char *p, int mode);
int unlink(const char *p);
int rmdir(const char *p);
int isatty(int fd);
ssize_t read(int fd, void *buf, size_t n);
ssize_t write(int fd, const void *buf, size_t n);
int close(int fd);
#define F_OK 0
#define R_OK 4
#define W_OK 2
#define X_OK 1
#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2
#endif
