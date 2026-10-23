#ifndef _KDIRENT_H
#define _KDIRENT_H
typedef struct KDIR DIR;
struct dirent { char d_name[256]; unsigned char d_type; };
#define DT_DIR 4
#define DT_REG 8
DIR *opendir(const char *p);
struct dirent *readdir(DIR *d);
int closedir(DIR *d);
#endif
