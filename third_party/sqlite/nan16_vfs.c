/* nan16_vfs.c - SQLite base VFS for the NaN16 guest.
 *
 * SQLite is built with SQLITE_OS_OTHER=1 and this file supplies both the
 * base VFS and the sqlite3_os_init()/sqlite3_os_end() entry points.  Files
 * live in named in-memory byte arrays.  They persist for the lifetime of the
 * process, so closing and reopening the same database name exercises the
 * normal pager/schema-reload path.  Nothing is written outside the VM.
 *
 * The port is configured single-threaded (SQLITE_THREADSAFE=0), with
 * SQLITE_TEMP_STORE=3 (temporary data in memory) and without WAL, so the
 * locking and shared-memory VFS methods are no-ops.
 */
#include "sqlite3.h"
#include <string.h>
#include <stdlib.h>
#include <time.h>

/* Guest monotonic clock published by the runner/kernel at 0x03EFF010. */
static unsigned int nan_now_ms(void)
{
    return *(volatile unsigned int *)0x03EFF010u;
}

#define NAN_VFS_FILES 16
#define NAN_VFS_NAME  64

typedef struct NanMemFile {
    char name[NAN_VFS_NAME];
    unsigned char *data;
    sqlite3_int64 size;
    sqlite3_int64 cap;
    int used;
    int temp;                 /* anonymous file: drop on last close */
    int unlinked;             /* named file removed while open */
    int open_count;
    unsigned int gen;         /* distinguishes reused slots for stale handles */
} NanMemFile;

static NanMemFile nan_files[NAN_VFS_FILES];
static NanMemFile nan_dead;
static unsigned int nan_temp_seq;

typedef struct NanFile {
    sqlite3_file base;
    int idx;
    unsigned int gen;
} NanFile;

static NanMemFile *nan_find(const char *name, int create)
{
    int i, slot = -1;
    if (!name) return 0;
    for (i = 0; i < NAN_VFS_FILES; i++) {
        if (nan_files[i].used && strcmp(nan_files[i].name, name) == 0)
            return &nan_files[i];
        if (!nan_files[i].used && slot < 0) slot = i;
    }
    if (!create || slot < 0) return 0;
    nan_files[slot].used = 1;
    nan_files[slot].temp = 0;
    nan_files[slot].unlinked = 0;
    nan_files[slot].open_count = 0;
    nan_files[slot].gen++;
    strncpy(nan_files[slot].name, name, NAN_VFS_NAME - 1);
    nan_files[slot].name[NAN_VFS_NAME - 1] = 0;
    nan_files[slot].data = 0;
    nan_files[slot].size = nan_files[slot].cap = 0;
    return &nan_files[slot];
}

static NanMemFile *nan_file(sqlite3_file *pFile)
{
    NanFile *nf = (NanFile *)pFile;
    NanMemFile *f = &nan_files[nf->idx];
    if (!f->used || f->gen != nf->gen) return &nan_dead;
    return f;
}

static void nan_drop(NanMemFile *f)
{
    if (!f || f == &nan_dead) return;
    if (f->data) free(f->data);
    f->used = 0;
    f->temp = 0;
    f->unlinked = 0;
    f->open_count = 0;
    f->data = 0;
    f->size = f->cap = 0;
    f->name[0] = 0;
}

static int nan_close(sqlite3_file *pFile)
{
    NanFile *nf = (NanFile *)pFile;
    NanMemFile *f = &nan_files[nf->idx];
    if (f->used && f->gen == nf->gen) {
        if (f->open_count > 0) f->open_count--;
        if (f->open_count == 0 && (f->temp || f->unlinked))
            nan_drop(f);
    }
    return SQLITE_OK;
}

static int nan_read(sqlite3_file *pFile, void *buf, int amt, sqlite3_int64 off)
{
    NanMemFile *f = nan_file(pFile);
    sqlite3_int64 avail;
    if (off < 0 || amt < 0) return SQLITE_IOERR_READ;
    if (!f->used || off >= f->size) {
        memset(buf, 0, (size_t)amt);
        return SQLITE_IOERR_SHORT_READ;
    }
    avail = f->size - off;
    if (avail > amt) avail = amt;
    memcpy(buf, f->data + off, (size_t)avail);
    if (avail < amt) {
        memset((unsigned char *)buf + avail, 0, (size_t)(amt - avail));
        return SQLITE_IOERR_SHORT_READ;
    }
    return SQLITE_OK;
}

static int nan_write(sqlite3_file *pFile, const void *buf, int amt,
                     sqlite3_int64 off)
{
    NanMemFile *f = nan_file(pFile);
    sqlite3_int64 need, nc;
    unsigned char *nb;
    if (!f->used || off < 0 || amt < 0) return SQLITE_IOERR_WRITE;
    need = off + amt;
    if (need > f->cap) {
        nc = f->cap ? f->cap : 4096;
        while (nc < need) nc *= 2;
        nb = (unsigned char *)malloc((size_t)nc);
        if (!nb) return SQLITE_IOERR_NOMEM;
        if (f->data) {
            memcpy(nb, f->data, (size_t)f->size);
            free(f->data);
        }
        f->data = nb;
        f->cap = nc;
    }
    if (off > f->size)
        memset(f->data + f->size, 0, (size_t)(off - f->size));
    memcpy(f->data + off, buf, (size_t)amt);
    if (need > f->size) f->size = need;
    return SQLITE_OK;
}

static int nan_truncate(sqlite3_file *pFile, sqlite3_int64 size)
{
    NanMemFile *f = nan_file(pFile);
    sqlite3_int64 nc;
    unsigned char *nb;
    if (!f->used || size < 0) return SQLITE_IOERR_TRUNCATE;
    if (size > f->cap) {
        nc = f->cap ? f->cap : 4096;
        while (nc < size) nc *= 2;
        nb = (unsigned char *)malloc((size_t)nc);
        if (!nb) return SQLITE_IOERR_NOMEM;
        if (f->data) {
            memcpy(nb, f->data, (size_t)f->size);
            free(f->data);
        }
        f->data = nb;
        f->cap = nc;
    }
    if (size > f->size)
        memset(f->data + f->size, 0, (size_t)(size - f->size));
    f->size = size;
    return SQLITE_OK;
}

static int nan_sync(sqlite3_file *pFile, int flags)
{
    (void)pFile;
    (void)flags;
    return SQLITE_OK;
}

static int nan_filesize(sqlite3_file *pFile, sqlite3_int64 *pSize)
{
    *pSize = nan_file(pFile)->size;
    return SQLITE_OK;
}

static int nan_lock(sqlite3_file *pFile, int lock)
{
    (void)pFile;
    (void)lock;
    return SQLITE_OK;
}

static int nan_unlock(sqlite3_file *pFile, int lock)
{
    (void)pFile;
    (void)lock;
    return SQLITE_OK;
}

static int nan_checkreserved(sqlite3_file *pFile, int *pOut)
{
    (void)pFile;
    *pOut = 0;
    return SQLITE_OK;
}

static int nan_filecontrol(sqlite3_file *pFile, int op, void *pArg)
{
    (void)pFile;
    (void)op;
    (void)pArg;
    return SQLITE_NOTFOUND;
}

static int nan_sectorsize(sqlite3_file *pFile)
{
    (void)pFile;
    return 4096;
}

static int nan_device(sqlite3_file *pFile)
{
    (void)pFile;
    return 0;
}

static const sqlite3_io_methods nan_io = {
    1,
    nan_close, nan_read, nan_write, nan_truncate, nan_sync,
    nan_filesize, nan_lock, nan_unlock, nan_checkreserved,
    nan_filecontrol, nan_sectorsize, nan_device
};

static int nan_open(sqlite3_vfs *pVfs, const char *name, sqlite3_file *pFile,
                    int flags, int *pOutFlags)
{
    NanMemFile *f;
    char tmp[NAN_VFS_NAME];
    int temp = 0;

    (void)pVfs;
    if (!name) {
        /* The VFS contract requires an anonymous temporary file when the
           caller passes a NULL name.  It disappears on xClose. */
        sqlite3_snprintf((int)sizeof(tmp), tmp, "__nan_temp_%u",
                         ++nan_temp_seq);
        name = tmp;
        temp = 1;
    }
    f = nan_find(name, (flags & SQLITE_OPEN_CREATE) != 0);
    if (!f) return SQLITE_CANTOPEN;
    f->temp = temp;
    f->open_count++;
    ((NanFile *)pFile)->idx = (int)(f - nan_files);
    ((NanFile *)pFile)->gen = f->gen;
    pFile->pMethods = &nan_io;
    if (pOutFlags) *pOutFlags = flags;
    return SQLITE_OK;
}

static int nan_delete(sqlite3_vfs *pVfs, const char *name, int syncDir)
{
    NanMemFile *f;
    (void)pVfs;
    (void)syncDir;
    if (!name) return SQLITE_OK;
    f = nan_find(name, 0);
    if (!f) return SQLITE_OK;
    if (f->open_count > 0) {
        /* POSIX unlink semantics: the open handle keeps its data, but the
           name disappears so a new file can be created in another slot. */
        f->unlinked = 1;
        f->name[0] = 0;
    } else {
        nan_drop(f);
    }
    return SQLITE_OK;
}

static int nan_access(sqlite3_vfs *pVfs, const char *name, int flags,
                      int *pResOut)
{
    (void)pVfs;
    (void)flags;
    *pResOut = name && nan_find(name, 0) ? 1 : 0;
    return SQLITE_OK;
}

static int nan_fullpathname(sqlite3_vfs *pVfs, const char *name,
                            int nOut, char *zOut)
{
    int n;
    (void)pVfs;
    if (nOut <= 0) return SQLITE_OK;
    if (!name) name = "";
    n = (int)strlen(name);
    if (n >= nOut) n = nOut - 1;
    memcpy(zOut, name, (size_t)n);
    zOut[n] = 0;
    return SQLITE_OK;
}

static int nan_randomness(sqlite3_vfs *pVfs, int nByte, char *zOut)
{
    static unsigned int seed = 0x12345678u;
    int i;
    (void)pVfs;
    for (i = 0; i < nByte; i++) {
        seed = seed * 1103515245u + 12345u;
        zOut[i] = (char)(seed >> 16);
    }
    return nByte;
}

static int nan_sleep(sqlite3_vfs *pVfs, int microseconds)
{
    struct timespec ts;
    (void)pVfs;
    if (microseconds <= 0) return 0;
    ts.tv_sec = microseconds / 1000000;
    ts.tv_nsec = (long)(microseconds % 1000000) * 1000L;
    nanosleep(&ts, 0);
    return 0;
}

static int nan_currenttime(sqlite3_vfs *pVfs, double *pTime)
{
    (void)pVfs;
    *pTime = 2440587.5 + ((double)nan_now_ms() / 1000.0) / 86400.0;
    return SQLITE_OK;
}

static int nan_currenttimeint64(sqlite3_vfs *pVfs, sqlite3_int64 *pTime)
{
    (void)pVfs;
    *pTime = (sqlite3_int64)nan_now_ms();
    return SQLITE_OK;
}

static int nan_getlasterror(sqlite3_vfs *pVfs, int nBuf, char *zBuf)
{
    (void)pVfs;
    (void)nBuf;
    (void)zBuf;
    return 0;
}

static sqlite3_vfs nan_vfs = {
    .iVersion = 2,
    .szOsFile = sizeof(NanFile),
    .mxPathname = NAN_VFS_NAME,
    .zName = "nan16",
    .xOpen = nan_open,
    .xDelete = nan_delete,
    .xAccess = nan_access,
    .xFullPathname = nan_fullpathname,
    .xRandomness = nan_randomness,
    .xSleep = nan_sleep,
    .xCurrentTime = nan_currenttime,
    .xGetLastError = nan_getlasterror,
    .xCurrentTimeInt64 = nan_currenttimeint64
};

int sqlite3_os_init(void)
{
    return sqlite3_vfs_register(&nan_vfs, 1);
}

int sqlite3_os_end(void)
{
    return SQLITE_OK;
}
