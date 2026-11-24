/* Extra prototypes/constants used by SQLite's official test C modules. */
#ifndef NAN16_SQLITE_COMPAT_H
#define NAN16_SQLITE_COMPAT_H
#include <stddef.h>
#include <time.h>
#ifndef _SC_NPROCESSORS_ONLN
#define _SC_NPROCESSORS_ONLN 84
#endif
long sysconf(int name);
size_t strftime(char *s, size_t max, const char *format, const struct tm *tm);
#include <stdio.h>
#include <sys/stat.h>
#include <sys/time.h>
void rewind(FILE *stream);
int chown(const char *path, unsigned int uid, unsigned int gid);
int fchmod(int fd, unsigned int mode);
#ifndef S_IFLNK
#define S_IFLNK 0120000
#endif
#ifndef S_ISLNK
#define S_ISLNK(m) 0
#endif
#ifndef S_IFSOCK
#define S_IFSOCK 0140000
#endif
#ifndef S_ISSOCK
#define S_ISSOCK(m) 0
#endif
#ifndef S_IFIFO
#define S_IFIFO 0010000
#endif
#ifndef S_ISFIFO
#define S_ISFIFO(m) 0
#endif
#ifndef S_IFCHR
#define S_IFCHR 0020000
#endif
#ifndef S_ISCHR
#define S_ISCHR(m) 0
#endif
#ifndef S_IFBLK
#define S_IFBLK 0060000
#endif
#ifndef S_ISBLK
#define S_ISBLK(m) 0
#endif
#endif
