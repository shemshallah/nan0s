#ifndef _UNISTD_H
#define _UNISTD_H
#include <stddef.h>
typedef int ssize_t;
typedef long off_t;
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#define F_OK 0
#define X_OK 1
#define W_OK 2
#define R_OK 4
extern char **environ;
ssize_t read(int, void *, size_t);
ssize_t write(int, const void *, size_t);
int close(int);
off_t lseek(int, off_t, int);
int ftruncate(int, off_t);
int truncate(const char *, off_t);
int unlink(const char *);
int rmdir(const char *);
char *getcwd(char *, size_t);
int chdir(const char *);
int access(const char *, int);
int isatty(int);
int getpid(void);
void *mmap(void *, size_t, int, int, int, off_t);
int munmap(void *, size_t);
/* NaN16 guest VFS extensions (not POSIX). */
unsigned nan16_vfs_count(void);
unsigned nan16_vfs_capacity(void);
int nan16_vfs_entry(unsigned, const char **, unsigned *, int *);
int nan16_vfs_get(const char *, unsigned char **, unsigned *);
int nan16_vfs_add_pack(const void *, unsigned);
int nan16_vfs_add(const char *, const void *, unsigned);
int nan16_vfs_add_ro(const char *, const void *, unsigned);
int nan16_vfs_isdir(const char *);
#endif
