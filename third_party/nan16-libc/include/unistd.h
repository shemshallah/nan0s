#ifndef _UNISTD_H
#define _UNISTD_H
#include <stddef.h>
typedef int ssize_t;
typedef long off_t;
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
ssize_t read(int, void *, size_t);
ssize_t write(int, const void *, size_t);
int close(int);
off_t lseek(int, off_t, int);
int unlink(const char *);
char *getcwd(char *, size_t);
int chdir(const char *);
int access(const char *, int);
int isatty(int);
int getpid(void);
void *mmap(void *, size_t, int, int, int, off_t);
int munmap(void *, size_t);
#endif
