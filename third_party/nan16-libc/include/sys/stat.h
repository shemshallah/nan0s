#ifndef _SYS_STAT_H
#define _SYS_STAT_H
#include <sys/types.h>
struct stat {
    unsigned long st_dev; unsigned long st_ino; unsigned long st_mode;
    unsigned long st_nlink; unsigned long st_uid; unsigned long st_gid;
    unsigned long st_rdev; long st_size; long st_blksize; long st_blocks;
    long st_atime; long st_mtime; long st_ctime;
};
int stat(const char *, struct stat *);
int fstat(int, struct stat *);
int mkdir(const char *, mode_t);
#define S_IFMT 0170000
#define S_IFREG 0100000
#define S_IFDIR 0040000
#define S_ISREG(m) (((m)&S_IFMT)==S_IFREG)
#define S_ISDIR(m) (((m)&S_IFMT)==S_IFDIR)
#endif
