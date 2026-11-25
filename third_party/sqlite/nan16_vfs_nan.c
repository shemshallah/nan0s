/* nan16_vfs_nan.c - SQLite VFS whose persistent store is the NaN16 machine
 * filesystem.
 *
 * SQLite keeps a working copy of each file in the guest heap.  xSync and
 * xClose send the whole file through the NaN service table; xOpen loads it
 * back with the same table.  No host or libc file I/O is involved: the
 * boundary is the C-ABI table of bare_fs_load/bare_fs_save/remove/size.
 *
 * The VFS is single-threaded (SQLITE_THREADSAFE=0) and WAL is not built, so
 * locking and shared-memory methods are local no-ops.
 */
#include "sqlite3.h"
#include <string.h>
#include <stdlib.h>

/* Word 0x296400 in the C-ABI service stub; TCC data pointers are byte
   addresses (four per NaN word). */
#ifndef NAN16_VFS_TABLE
#define NAN16_VFS_TABLE 0x00A59000u
#endif
#define NAN_TAB ((volatile unsigned *)(unsigned long)NAN16_VFS_TABLE)

typedef int (*nan_load_fn)(const char *, void *, int);
typedef int (*nan_save_fn)(const char *, const void *, int);
typedef int (*nan_path_fn)(const char *);
typedef int (*nan_tick_fn)(void);

static int nan_svc_load(const char *p, void *d, int n)
{ return ((nan_load_fn)(unsigned long)NAN_TAB[0])(p, d, n); }
static int nan_svc_save(const char *p, const void *s, int n)
{ return ((nan_save_fn)(unsigned long)NAN_TAB[1])(p, s, n); }
static int nan_svc_remove(const char *p)
{ return ((nan_path_fn)(unsigned long)NAN_TAB[2])(p); }
static int nan_svc_size(const char *p)
{ return ((nan_path_fn)(unsigned long)NAN_TAB[3])(p); }
static int nan_svc_tick(void)
{ return ((nan_tick_fn)(unsigned long)NAN_TAB[4])(); }

#ifndef NAN16_VFS_NAME
#define NAN16_VFS_NAME 192
#endif

typedef struct NanFile {
    sqlite3_file base;
    unsigned char *data;
    sqlite3_int64 size;
    sqlite3_int64 cap;
    int readonly;
    int dirty;
    int del;
    int anonymous;
    char path[NAN16_VFS_NAME];
} NanFile;

static int nf_reserve(NanFile *f, sqlite3_int64 need)
{
    sqlite3_int64 ncap = f->cap ? f->cap : 512;
    unsigned char *nd;
    while (ncap < need) {
        if (ncap > (sqlite3_int64)0x3FFFFFFF) { ncap = need; break; }
        ncap *= 2;
    }
    if (ncap < need) return SQLITE_NOMEM;
    nd = (unsigned char *)realloc(f->data, (size_t)ncap);
    if (!nd) return SQLITE_NOMEM;
    f->data = nd;
    f->cap = ncap;
    return SQLITE_OK;
}

/* Load a named file into the handle.  A missing file is an empty file when
   the caller is creating it. */
static int nf_load(NanFile *f)
{
    int n = nan_svc_size(f->path);
    if (n < 0) { f->size = 0; return SQLITE_OK; }
    if (nf_reserve(f, n + 1) != SQLITE_OK) return SQLITE_NOMEM;
    if (n > 0) {
        int got = nan_svc_load(f->path, f->data, n);
        if (got < 0) return SQLITE_IOERR_READ;
        f->size = got;
        if (got < n) memset(f->data + got, 0, (size_t)(n - got));
    } else {
        f->size = 0;
    }
    return SQLITE_OK;
}

static int nf_flush(NanFile *f)
{
    if (!f->dirty || f->readonly || f->anonymous || !f->path[0])
        return SQLITE_OK;
    if (nan_svc_save(f->path, f->data, (int)f->size) == 0)
        return SQLITE_IOERR_WRITE;
    f->dirty = 0;
    return SQLITE_OK;
}

static int nf_close(sqlite3_file *pFile)
{
    NanFile *f = (NanFile *)pFile;
    int rc = nf_flush(f);
    if (f->del && f->path[0]) nan_svc_remove(f->path);
    free(f->data);
    f->data = 0;
    pFile->pMethods = 0;
    return rc;
}

static int nf_read(sqlite3_file *pFile, void *buf, int amt, sqlite3_int64 off)
{
    NanFile *f = (NanFile *)pFile;
    sqlite3_int64 avail;
    if (off < 0 || amt < 0) return SQLITE_IOERR_READ;
    if (off >= f->size) {
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

static int nf_write(sqlite3_file *pFile, const void *buf, int amt,
                    sqlite3_int64 off)
{
    NanFile *f = (NanFile *)pFile;
    if (f->readonly) return SQLITE_READONLY;
    if (off < 0 || amt < 0) return SQLITE_IOERR_WRITE;
    if (off + amt > f->cap) {
        int rc = nf_reserve(f, off + amt);
        if (rc != SQLITE_OK) return rc;
    }
    if (off > f->size)
        memset(f->data + f->size, 0, (size_t)(off - f->size));
    memcpy(f->data + off, buf, (size_t)amt);
    if (off + amt > f->size) f->size = off + amt;
    f->dirty = 1;
    return SQLITE_OK;
}

static int nf_truncate(sqlite3_file *pFile, sqlite3_int64 size)
{
    NanFile *f = (NanFile *)pFile;
    if (f->readonly) return SQLITE_READONLY;
    if (size < 0) return SQLITE_IOERR_TRUNCATE;
    if (size > f->cap) {
        int rc = nf_reserve(f, size);
        if (rc != SQLITE_OK) return rc;
        memset(f->data + f->size, 0, (size_t)(size - f->size));
    } else if (size < f->size && size < f->cap) {
        memset(f->data + size, 0, (size_t)(f->size - size));
    }
    f->size = size;
    f->dirty = 1;
    return SQLITE_OK;
}

static int nf_sync(sqlite3_file *pFile, int flags)
{
    (void)flags;
    return nf_flush((NanFile *)pFile);
}

static int nf_filesize(sqlite3_file *pFile, sqlite3_int64 *pSize)
{
    *pSize = ((NanFile *)pFile)->size;
    return SQLITE_OK;
}

static int nf_lock(sqlite3_file *pFile, int lock) { (void)pFile; (void)lock; return SQLITE_OK; }
static int nf_unlock(sqlite3_file *pFile, int lock) { (void)pFile; (void)lock; return SQLITE_OK; }
static int nf_checkreserved(sqlite3_file *pFile, int *pRes)
{ (void)pFile; *pRes = 0; return SQLITE_OK; }

static int nf_filecontrol(sqlite3_file *pFile, int op, void *arg)
{
    NanFile *f = (NanFile *)pFile;
    switch (op) {
    case SQLITE_FCNTL_SIZE_HINT: {
        sqlite3_int64 n = *(sqlite3_int64 *)arg;
        return n > f->cap ? nf_reserve(f, n) : SQLITE_OK;
    }
    case SQLITE_FCNTL_CHUNK_SIZE:
        return SQLITE_OK;
    case SQLITE_FCNTL_POWERSAFE_OVERWRITE:
        if (arg && *(int *)arg < 0) *(int *)arg = 1;
        return SQLITE_OK;
    case SQLITE_FCNTL_LOCKSTATE:
        *(int *)arg = SQLITE_LOCK_NONE;
        return SQLITE_OK;
    case SQLITE_FCNTL_SYNC:
    case SQLITE_FCNTL_COMMIT_PHASETWO:
        return SQLITE_OK;
    default:
        return SQLITE_NOTFOUND;
    }
}

static int nf_sectorsize(sqlite3_file *pFile) { (void)pFile; return 512; }
static int nf_device(sqlite3_file *pFile) { (void)pFile; return 0; }
static int nf_shmmap(sqlite3_file *pFile, int iPg, int pgsz, int bExtend,
                     void volatile **pp)
{ (void)pFile; (void)iPg; (void)pgsz; (void)bExtend; (void)pp;
  return SQLITE_IOERR_SHMMAP; }
static int nf_shmlock(sqlite3_file *pFile, int off, int n, int flags)
{ (void)pFile; (void)off; (void)n; (void)flags; return SQLITE_IOERR_SHMLOCK; }
static void nf_shmbarrier(sqlite3_file *pFile) { (void)pFile; }
static int nf_shmunmap(sqlite3_file *pFile, int delFlag)
{ (void)pFile; (void)delFlag; return SQLITE_OK; }

static const sqlite3_io_methods nf_io = {
    3,
    nf_close, nf_read, nf_write, nf_truncate, nf_sync,
    nf_filesize, nf_lock, nf_unlock, nf_checkreserved,
    nf_filecontrol, nf_sectorsize, nf_device,
    nf_shmmap, nf_shmlock, nf_shmbarrier, nf_shmunmap
};

static unsigned int nf_temp_seq;

static int nf_open(sqlite3_vfs *pVfs, const char *name, sqlite3_file *pFile,
                   int flags, int *pOutFlags)
{
    NanFile *f = (NanFile *)pFile;
    int rc;
    (void)pVfs;
    memset(f, 0, sizeof(*f));
    f->readonly = (flags & SQLITE_OPEN_READONLY) != 0;
    f->del = (flags & SQLITE_OPEN_DELETEONCLOSE) != 0;
    if (!name) {
        f->anonymous = 1;
        sqlite3_snprintf((int)sizeof(f->path), f->path, "__nan_tmp_%u",
                         ++nf_temp_seq);
        rc = SQLITE_OK;
    } else {
        int n = (int)strlen(name);
        if (n >= (int)sizeof(f->path)) return SQLITE_CANTOPEN;
        memcpy(f->path, name, (size_t)n + 1);
        rc = nf_load(f);
        if (rc != SQLITE_OK && (flags & SQLITE_OPEN_CREATE)) {
            /* Missing file: keep an empty buffer; the name appears on sync. */
            f->size = 0;
            rc = SQLITE_OK;
        }
    }
    if (rc != SQLITE_OK) return rc;
    pFile->pMethods = &nf_io;
    if (pOutFlags) *pOutFlags = flags;
    return SQLITE_OK;
}

static int nf_delete(sqlite3_vfs *pVfs, const char *name, int syncDir)
{
    (void)pVfs; (void)syncDir;
    if (name && name[0]) nan_svc_remove(name);
    return SQLITE_OK;
}

static int nf_access(sqlite3_vfs *pVfs, const char *name, int flags,
                     int *pResOut)
{
    (void)pVfs; (void)flags;
    *pResOut = (name && name[0] && nan_svc_size(name) >= 0) ? 1 : 0;
    return SQLITE_OK;
}

static int nf_fullpathname(sqlite3_vfs *pVfs, const char *name, int nOut,
                           char *zOut)
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

static int nf_randomness(sqlite3_vfs *pVfs, int nByte, char *zOut)
{
    static unsigned int seed = 0x9E3779B9u;
    int i;
    (void)pVfs;
    for (i = 0; i < nByte; i++) {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
        zOut[i] = (char)(seed >> 16);
    }
    return nByte;
}

static int nf_sleep(sqlite3_vfs *pVfs, int microseconds)
{ (void)pVfs; (void)microseconds; return 0; }

static int nf_currenttime(sqlite3_vfs *pVfs, double *pTime)
{
    (void)pVfs;
    *pTime = 2440587.5 + ((double)nan_svc_tick() / 1000.0) / 86400.0;
    return SQLITE_OK;
}

static int nf_currenttimeint64(sqlite3_vfs *pVfs, sqlite3_int64 *pTime)
{
    (void)pVfs;
    *pTime = 2440587.5 * 86400000.0 + (sqlite3_int64)nan_svc_tick();
    return SQLITE_OK;
}

static int nf_getlasterror(sqlite3_vfs *pVfs, int nBuf, char *zBuf)
{ (void)pVfs; (void)nBuf; (void)zBuf; return 0; }

static sqlite3_vfs nf_vfs = {
    .iVersion = 3,
    .szOsFile = sizeof(NanFile),
    .mxPathname = NAN16_VFS_NAME,
    .zName = "nan16-nanfs",
    .xOpen = nf_open,
    .xDelete = nf_delete,
    .xAccess = nf_access,
    .xFullPathname = nf_fullpathname,
    .xRandomness = nf_randomness,
    .xSleep = nf_sleep,
    .xCurrentTime = nf_currenttime,
    .xGetLastError = nf_getlasterror,
    .xCurrentTimeInt64 = nf_currenttimeint64
};

int sqlite3_os_init(void)
{
    return sqlite3_vfs_register(&nf_vfs, 1);
}

int sqlite3_os_end(void)
{
    return SQLITE_OK;
}
