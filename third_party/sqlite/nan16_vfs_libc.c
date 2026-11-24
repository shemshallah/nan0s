/* nan16_vfs_libc.c - SQLite base VFS backed by the NaN16 libc VFS.
 *
 * The testfixture, Tcl file commands and SQLite must all see the same
 * test.db.  The earlier in-memory table was private to SQLite, so Tcl's
 * rename/delete/size saw a different namespace.  This VFS uses the libc
 * guest filesystem (cwd, implicit dirs, dynamic file table), making the two
 * layers one namespace.  It is single-threaded and WAL-free.
 */
#include "sqlite3.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>

typedef struct NanLFile {
    sqlite3_file base;
    int fd;
    int del;
    char path[128];
} NanLFile;

static unsigned int temp_seq;
static unsigned int rand_state = 0x12345678u;

static int l_close(sqlite3_file *pFile)
{
    NanLFile *f = (NanLFile *)pFile;
    if (f->del && f->path[0]) unlink(f->path);
    if (f->fd >= 0) close(f->fd);
    f->fd = -1;
    pFile->pMethods = 0;
    return SQLITE_OK;
}
static int l_read(sqlite3_file *pFile, void *buf, int amt, sqlite3_int64 off)
{
    NanLFile *f = (NanLFile *)pFile;
    int r;
    if (f->fd < 0) return SQLITE_IOERR_READ;
    if (lseek(f->fd, (off_t)off, SEEK_SET) < 0) return SQLITE_IOERR_READ;
    r = (int)read(f->fd, buf, (size_t)amt);
    if (r < 0) return SQLITE_IOERR_READ;
    if (r < amt) {
        memset((unsigned char *)buf + r, 0, (size_t)(amt - r));
        return SQLITE_IOERR_SHORT_READ;
    }
    return SQLITE_OK;
}
static int l_write(sqlite3_file *pFile, const void *buf, int amt, sqlite3_int64 off)
{
    NanLFile *f = (NanLFile *)pFile;
    int r;
    if (f->fd < 0) return SQLITE_IOERR_WRITE;
    if (lseek(f->fd, (off_t)off, SEEK_SET) < 0) return SQLITE_IOERR_WRITE;
    r = (int)write(f->fd, buf, (size_t)amt);
    return r == amt ? SQLITE_OK : SQLITE_IOERR_WRITE;
}
static int l_truncate(sqlite3_file *pFile, sqlite3_int64 size)
{
    NanLFile *f = (NanLFile *)pFile;
    return f->fd >= 0 && ftruncate(f->fd, (off_t)size) == 0
        ? SQLITE_OK : SQLITE_IOERR_TRUNCATE;
}
static int l_sync(sqlite3_file *pFile, int flags)
{
    NanLFile *f = (NanLFile *)pFile;
    (void)flags;
    return f->fd >= 0 && fsync(f->fd) == 0 ? SQLITE_OK : SQLITE_IOERR_FSYNC;
}
static int l_filesize(sqlite3_file *pFile, sqlite3_int64 *pSize)
{
    NanLFile *f = (NanLFile *)pFile;
    struct stat st;
    if (f->fd < 0 || fstat(f->fd, &st) < 0) return SQLITE_IOERR_FSTAT;
    *pSize = (sqlite3_int64)st.st_size;
    return SQLITE_OK;
}
static int l_lock(sqlite3_file *pFile, int lock)
{
    (void)pFile; (void)lock;
    return SQLITE_OK;
}
static int l_unlock(sqlite3_file *pFile, int lock)
{
    (void)pFile; (void)lock;
    return SQLITE_OK;
}
static int l_checkreserved(sqlite3_file *pFile, int *pRes)
{
    (void)pFile;
    *pRes = 0;
    return SQLITE_OK;
}
static int l_filecontrol(sqlite3_file *pFile, int op, void *arg)
{
    NanLFile *f = (NanLFile *)pFile;
    switch (op) {
    case SQLITE_FCNTL_SIZE_HINT: {
        sqlite3_int64 n = *(sqlite3_int64 *)arg;
        if (f->fd >= 0) ftruncate(f->fd, (off_t)n);
        return SQLITE_OK;
    }
    case SQLITE_FCNTL_CHUNK_SIZE:
    case SQLITE_FCNTL_SYNC:
    case SQLITE_FCNTL_COMMIT_PHASETWO:
        return SQLITE_OK;
    default:
        return SQLITE_NOTFOUND;
    }
}
static int l_sectorsize(sqlite3_file *pFile)
{
    (void)pFile;
    return 512;
}
static int l_device(sqlite3_file *pFile)
{
    (void)pFile;
    return 0;
}
static const sqlite3_io_methods l_io = {
    1, l_close, l_read, l_write, l_truncate, l_sync,
    l_filesize, l_lock, l_unlock, l_checkreserved,
    l_filecontrol, l_sectorsize, l_device
};

static int l_open(sqlite3_vfs *pVfs, const char *name, sqlite3_file *pFile,
                  int flags, int *pOutFlags)
{
    NanLFile *f = (NanLFile *)pFile;
    int oflags = O_RDONLY, fd;
    char tmp[64];
    (void)pVfs;
    f->fd = -1;
    f->del = 0;
    f->path[0] = 0;
    if (!name) {
        snprintf(tmp, sizeof tmp, "/.nan_tmp_%u", ++temp_seq);
        name = tmp;
        f->del = 1;
    }
    if (flags & SQLITE_OPEN_READWRITE) oflags = O_RDWR;
    if (flags & SQLITE_OPEN_CREATE) oflags |= O_CREAT;
    if (flags & SQLITE_OPEN_DELETEONCLOSE) f->del = 1;
    fd = open(name, oflags, 0644);
    if (fd < 0) return SQLITE_CANTOPEN;
    f->fd = fd;
    strncpy(f->path, name, sizeof f->path - 1);
    f->path[sizeof f->path - 1] = 0;
    if (pOutFlags) *pOutFlags = flags;
    pFile->pMethods = &l_io;
    return SQLITE_OK;
}
static int l_delete(sqlite3_vfs *pVfs, const char *name, int syncDir)
{
    (void)pVfs; (void)syncDir;
    if (!name) return SQLITE_OK;
    unlink(name);
    return SQLITE_OK;
}
static int l_access(sqlite3_vfs *pVfs, const char *name, int flags, int *pResOut)
{
    (void)pVfs;
    if (flags == SQLITE_ACCESS_EXISTS)
        *pResOut = access(name, F_OK) == 0;
    else
        *pResOut = access(name, R_OK | W_OK) == 0;
    return SQLITE_OK;
}
static int l_fullpathname(sqlite3_vfs *pVfs, const char *name, int nOut, char *zOut)
{
    char *r;
    (void)pVfs;
    if (nOut <= 0) return SQLITE_OK;
    if (!name) name = "";
    r = realpath(name, 0);
    if (r) {
        strncpy(zOut, r, (size_t)nOut - 1);
        zOut[nOut - 1] = 0;
        free(r);
    } else {
        strncpy(zOut, name, (size_t)nOut - 1);
        zOut[nOut - 1] = 0;
    }
    return SQLITE_OK;
}
static int l_randomness(sqlite3_vfs *pVfs, int nByte, char *zOut)
{
    int i;
    (void)pVfs;
    for (i = 0; i < nByte; i++) {
        rand_state = rand_state * 1103515245u + 12345u;
        zOut[i] = (char)(rand_state >> 16);
    }
    return nByte;
}
static int l_sleep(sqlite3_vfs *pVfs, int usec)
{
    struct timespec ts;
    (void)pVfs;
    if (usec <= 0) return 0;
    ts.tv_sec = usec / 1000000;
    ts.tv_nsec = (long)(usec % 1000000) * 1000L;
    nanosleep(&ts, 0);
    return 0;
}
static unsigned int l_now_ms(void)
{
    return *(volatile unsigned int *)0x03EFF010u;
}
static int l_currenttime(sqlite3_vfs *pVfs, double *pTime)
{
    (void)pVfs;
    *pTime = 2440587.5 + ((double)l_now_ms() / 1000.0) / 86400.0;
    return SQLITE_OK;
}
static int l_currenttimeint64(sqlite3_vfs *pVfs, sqlite3_int64 *pTime)
{
    (void)pVfs;
    *pTime = (sqlite3_int64)l_now_ms();
    return SQLITE_OK;
}
static int l_getlasterror(sqlite3_vfs *pVfs, int nBuf, char *zBuf)
{
    (void)pVfs;
    if (nBuf > 0) zBuf[0] = 0;
    return 0;
}
static sqlite3_vfs l_vfs = {
    .iVersion = 2,
    .szOsFile = sizeof(NanLFile),
    .mxPathname = 128,
    .zName = "nan16libc",
    .xOpen = l_open,
    .xDelete = l_delete,
    .xAccess = l_access,
    .xFullPathname = l_fullpathname,
    .xRandomness = l_randomness,
    .xSleep = l_sleep,
    .xCurrentTime = l_currenttime,
    .xGetLastError = l_getlasterror,
    .xCurrentTimeInt64 = l_currenttimeint64
};
int sqlite3_os_init(void) { return sqlite3_vfs_register(&l_vfs, 1); }
int sqlite3_os_end(void) { return SQLITE_OK; }
