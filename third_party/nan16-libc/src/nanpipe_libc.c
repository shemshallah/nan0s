/* nanpipe_libc.c - POSIX pipe fds over the NaN16 np_* byte-pipe primitive.
 *
 * The pipe storage and all byte movement stay in NaN: this file is only the
 * syscall wrapper.  The NaN service table is linked at guest byte address
 * 0xA59000 (word 0x296400) by src/tests/cbare_pipe_stub.nas.
 *
 * Single-threaded semantics: read() returns 0 when the pipe is empty, and a
 * closed/absent write end also reads as 0 (EOF).  The fd range 40..63 holds
 * 12 pipes x read/write ends.  VFS descriptors remain in their existing
 * FD_VFS_BASE range and are dispatched by libc.c.
 */
#include <stddef.h>
#include <errno.h>
#include <unistd.h>

#define NPL_TAB ((volatile unsigned *)0x00A59000u)
#define NPL_FD_BASE 40
#define NPL_FD_LIMIT 64
#define NPL_SLOTS (NPL_FD_LIMIT - NPL_FD_BASE)

typedef int (*npl_open_fn)(void);
typedef int (*npl_io_fn)(int, const void *, int);
typedef int (*npl_close_fn)(int);

static int np_open_call(void)
{
    return ((npl_open_fn)(unsigned long)NPL_TAB[0])();
}
static int np_write_call(int id, const void *src, int len)
{
    return ((npl_io_fn)(unsigned long)NPL_TAB[1])(id, src, len);
}
static int np_read_call(int id, void *dst, int len)
{
    return ((npl_io_fn)(unsigned long)NPL_TAB[2])(id, dst, len);
}
static int np_close_call(int id)
{
    return ((npl_close_fn)(unsigned long)NPL_TAB[3])(id);
}

typedef struct PipeEnd {
    int id;       /* np_open() id, 1..8 */
    int write;    /* 1 write end, 0 read end */
    int used;
} PipeEnd;

static PipeEnd pipe_ends[NPL_SLOTS];

int npl_is_pipe(int fd)
{
    if (fd < NPL_FD_BASE || fd >= NPL_FD_LIMIT) return 0;
    return pipe_ends[fd - NPL_FD_BASE].used;
}

int pipe(int fds[2])
{
    int id, i, a = -1, b = -1;

    if (!fds) { errno = EINVAL; return -1; }
    id = np_open_call();
    if (!id) { errno = EMFILE; return -1; }

    for (i = 0; i < NPL_SLOTS; i++) {
        if (pipe_ends[i].used) continue;
        if (a < 0) a = i;
        else { b = i; break; }
    }
    if (b < 0) {
        np_close_call(id);
        errno = EMFILE;
        return -1;
    }

    pipe_ends[a].id = id;
    pipe_ends[a].write = 0;
    pipe_ends[a].used = 1;
    pipe_ends[b].id = id;
    pipe_ends[b].write = 1;
    pipe_ends[b].used = 1;

    fds[0] = NPL_FD_BASE + a;
    fds[1] = NPL_FD_BASE + b;
    return 0;
}

ssize_t npl_read(int fd, void *buf, size_t n)
{
    PipeEnd *e;
    int got;

    e = &pipe_ends[fd - NPL_FD_BASE];
    if (!e->used || e->write) { errno = EBADF; return -1; }
    if (!n) return 0;
    got = np_read_call(e->id, buf, (int)n);
    /* np_read() returns 0 for an empty pipe: EOF in single-thread mode. */
    return (ssize_t)got;
}

ssize_t npl_write(int fd, const void *buf, size_t n)
{
    PipeEnd *e;
    int put;

    e = &pipe_ends[fd - NPL_FD_BASE];
    if (!e->used || !e->write) { errno = EBADF; return -1; }
    if (!n) return 0;
    put = np_write_call(e->id, buf, (int)n);
    return (ssize_t)put;
}

int npl_close(int fd)
{
    PipeEnd *e;
    int id, i, still = 0;

    if (!npl_is_pipe(fd)) { errno = EBADF; return -1; }
    e = &pipe_ends[fd - NPL_FD_BASE];
    id = e->id;
    e->used = 0;
    for (i = 0; i < NPL_SLOTS; i++)
        if (pipe_ends[i].used && pipe_ends[i].id == id) still = 1;
    if (!still) np_close_call(id);
    return 0;
}

int dup2(int oldfd, int newfd)
{
    int oi, ni;

    if (!npl_is_pipe(oldfd)) { errno = EBADF; return -1; }
    if (newfd < NPL_FD_BASE || newfd >= NPL_FD_LIMIT) {
        errno = EBADF;
        return -1;
    }
    oi = oldfd - NPL_FD_BASE;
    ni = newfd - NPL_FD_BASE;
    if (oi == ni) return newfd;
    if (pipe_ends[ni].used && npl_close(newfd) < 0) return -1;
    pipe_ends[ni] = pipe_ends[oi];
    return newfd;
}
