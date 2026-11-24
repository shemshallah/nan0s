/*
 * tclUnixPort.h -- NaN16 port header for Tcl 9.0.3.
 *
 * generic/tclPort.h includes this name.  Only guest-libc facilities are
 * exposed here; the file deliberately does not include the host POSIX
 * headers Tcl's unix/tclUnixPort.h expects (pwd.h, grp.h, signal.h, sockets,
 * sys/wait.h, ...).
 */
#ifndef _TCLUNIXPORT
#define _TCLUNIXPORT

#include "tclConfig.h"

#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <limits.h>
#include <unistd.h>
#include <float.h>
#include <stdint.h>
#include <utime.h>

/* int_leastN_t are absent from the guest stdint.h but bison output uses them. */
#ifndef NAN16_LEAST_TYPES
#define NAN16_LEAST_TYPES
typedef signed char	int_least8_t;
typedef unsigned char	uint_least8_t;
typedef short		int_least16_t;
typedef unsigned short	uint_least16_t;
typedef int		int_least32_t;
typedef unsigned int	uint_least32_t;
typedef long long	int_least64_t;
typedef unsigned long long uint_least64_t;
#endif

#ifndef SIZE_MAX
#   define SIZE_MAX	((size_t)-1)
#endif
#ifndef PTRDIFF_MAX
#   define PTRDIFF_MAX	((ptrdiff_t)(((size_t)-1) >> 1))
#endif
#ifndef PTRDIFF_MIN
#   define PTRDIFF_MIN	(-PTRDIFF_MAX - 1)
#endif

/* POSIX types absent from the guest <sys/types.h>. */
typedef unsigned int uid_t;
typedef unsigned int gid_t;
typedef unsigned long ino_t;
typedef unsigned long dev_t;
typedef unsigned long nlink_t;
typedef long blkcnt_t;
typedef long blksize_t;
int getuid(void);
int geteuid(void);
int getgid(void);
int getegid(void);

#ifndef SEEK_SET
#   define SEEK_SET 0
#endif
#ifndef SEEK_CUR
#   define SEEK_CUR 1
#endif
#ifndef SEEK_END
#   define SEEK_END 2
#endif

#ifndef STDIN_FILENO
#   define STDIN_FILENO 0
#   define STDOUT_FILENO 1
#   define STDERR_FILENO 2
#endif

/* Directory API: the NaN16 libc implements POSIX-shaped opendir/readdir. */
typedef struct dirent	Tcl_DirEntry;
#define TclOSreaddir	readdir
typedef DIR		TclDIR;
#define TclOSopendir	opendir
#define TclOSrewinddir	rewinddir
#define TclOSclosedir	closedir

typedef off_t		Tcl_SeekOffset;
#define TclOSseek	lseek
#define TclOSopen	open
#define TclOSfstat	fstat
#define TclOSstat	stat

/*
 * The VFS is flat and has no links; lstat is stat and there is no symlink
 * support.  TclpObjLink returns an explicit ENOSYS error.
 */
#ifndef S_IFLNK
#   undef TclOSlstat
#   define lstat	stat
#   define TclOSlstat	TclOSstat
#endif

#ifndef S_ISREG
#   define S_ISREG(m)	(((m) & S_IFMT) == S_IFREG)
#endif
#ifndef S_ISDIR
#   define S_ISDIR(m)	(((m) & S_IFMT) == S_IFDIR)
#endif
#ifndef S_ISCHR
#   define S_ISCHR(m)	0
#endif
#ifndef S_ISBLK
#   define S_ISBLK(m)	0
#endif
#ifndef S_ISFIFO
#   define S_ISFIFO(m)	0
#endif
#ifndef S_ISLNK
#   define S_ISLNK(m)	0
#endif
#ifndef S_ISSOCK
#   define S_ISSOCK(m)	0
#endif

#ifndef MAXPATHLEN
#   define MAXPATHLEN	1024
#endif

#ifndef O_NONBLOCK
#   define O_NONBLOCK	0x80
#endif
#ifndef O_ACCMODE
#   define O_ACCMODE	3
#endif
#ifndef O_EXCL
#   define O_EXCL	128
#endif
#ifndef O_BINARY
#   define O_BINARY	0
#endif

#ifndef WNOHANG
#   define WNOHANG	1
#   define WUNTRACED	2
#endif
#ifndef WIFEXITED
#   define WIFEXITED(s)	((((int)(s)) & 0x7F) == 0)
#   define WEXITSTATUS(s) ((((int)(s)) >> 8) & 0xFF)
#   define WIFSIGNALED(s) ((((int)(s)) & 0x7F) != 0 && (((int)(s)) & 0x7F) != 0x7F)
#   define WTERMSIG(s)	(((int)(s)) & 0x7F)
#   define WIFSTOPPED(s) ((((int)(s)) & 0xFF) == 0x7F)
#   define WSTOPSIG(s)	((((int)(s)) >> 8) & 0xFF)
#endif
#ifndef F_OK
#   define F_OK		0
#endif
#ifndef X_OK
#   define X_OK		1
#endif
#ifndef W_OK
#   define W_OK		2
#endif
#ifndef R_OK
#   define R_OK		4
#endif
#ifndef FD_CLOEXEC
#   define FD_CLOEXEC	1
#endif

#define TCL_PLATFORM_TRANSLATION	TCL_TRANSLATE_LF
#define TclpReleaseFile(file)		/* Nothing. */

#define TclpSysAlloc(size)		malloc(size)
#define TclpSysFree(ptr)		free(ptr)
#define TclpSysRealloc(ptr, size)	realloc(ptr, size)

/*
 * Generic code only uses environ when syncing env variables.  The guest has
 * no inherited environment; Tcl's tclEnv module owns its own array on top.
 */
extern char **environ;

/* Functions supplied by the host libc, absent from the NaN16 libc. */
char *strdup(const char *s);
char *strndup(const char *s, size_t n);
int strcasecmp(const char *a, const char *b);
int strncasecmp(const char *a, const char *b, size_t n);
char *setlocale(int category, const char *locale);
struct tm *gmtime_r(const time_t *t, struct tm *out);
struct tm *localtime_r(const time_t *t, struct tm *out);
time_t mktime(struct tm *tm);
void tzset(void);
double difftime(time_t a, time_t b);

/* double-precision math still supplied by the port (tclNan16Math.c). */
double hypot(double, double);
#endif /* _TCLUNIXPORT */
