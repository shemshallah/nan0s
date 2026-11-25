#ifndef _DIRENT_H
#define _DIRENT_H
#include <stddef.h>
typedef struct __nan16_DIR DIR;
struct dirent {
    unsigned long d_ino;
    unsigned long d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[256];
};
#define DT_UNKNOWN 0
#define DT_DIR     4
#define DT_REG     8
DIR *opendir(const char *);
struct dirent *readdir(DIR *);
int closedir(DIR *);
void rewinddir(DIR *);
#endif
