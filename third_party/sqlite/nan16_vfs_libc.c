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
    int readonly;
    int lock;               /* current SQLITE_LOCK_* for this handle */
    unsigned int shm_shared; /* WAL shm locks held SHARED by this handle */
    unsigned int shm_excl;   /* WAL shm locks held EXCLUSIVE by this handle */
    int shm_mapped;          /* this handle has counted one NanShm ref */
    int psow;                /* POWERSAFE_OVERWRITE (FCNTL can clear it) */
    int szChunk;             /* SQLITE_FCNTL_CHUNK_SIZE (0 = none) */
    char path[128];
} NanLFile;

/* Last OS errno, surfaced through xGetLastError so sqlite3_system_errno()
   and the error message match the unix VFS. */
static int nan_last_errno;
static void nan_set_errno(void) { nan_last_errno = errno; }

/* SQLite's unix VFS detects same-process lock conflicts because POSIX locks
 * are process-wide.  The guest has no fcntl locks, so keep the same state
 * explicitly: one entry per open handle and path. */
typedef struct NanLock {
    struct NanLock *next;
    NanLFile *file;
    char path[128];
    int level;
} NanLock;
static NanLock *nan_locks;

static NanLock *lock_entry(NanLFile *f)
{
    NanLock *e;
    for (e = nan_locks; e; e = e->next)
        if (e->file == f) return e;
    return 0;
}
static int lock_conflict(NanLFile *f, int level)
{
    NanLock *e;
    for (e = nan_locks; e; e = e->next) {
        if (e->file == f || e->level == SQLITE_LOCK_NONE) continue;
        if (strcmp(e->path, f->path)) continue;
        if (level == SQLITE_LOCK_SHARED) {
            if (e->level >= SQLITE_LOCK_PENDING) return 1;
        } else if (level == SQLITE_LOCK_RESERVED) {
            if (e->level >= SQLITE_LOCK_RESERVED) return 1;
        } else if (level == SQLITE_LOCK_PENDING) {
            /* PENDING is the separate pending byte: existing SHARED readers
               do not conflict; it only blocks new SHARED locks. */
            if (e->level >= SQLITE_LOCK_PENDING) return 1;
        } else {
            if (e->level >= SQLITE_LOCK_SHARED) return 1;
        }
    }
    return 0;
}
static int lock_set(NanLFile *f, int level)
{
    NanLock *e = lock_entry(f);
    if (level == SQLITE_LOCK_NONE) {
        if (e) {
            NanLock **pp;
            for (pp = &nan_locks; *pp; pp = &(*pp)->next)
                if (*pp == e) { *pp = e->next; break; }
            free(e);
        }
        f->lock = SQLITE_LOCK_NONE;
        return SQLITE_OK;
    }
    if (!e) {
        e = (NanLock *)malloc(sizeof *e);
        if (!e) return SQLITE_IOERR;
        memset(e, 0, sizeof *e);
        e->file = f;
        strncpy(e->path, f->path, sizeof e->path - 1);
        e->next = nan_locks;
        nan_locks = e;
    }
    e->level = level;
    f->lock = level;
    return SQLITE_OK;
}

static unsigned int temp_seq;
static unsigned int rand_state = 0x12345678u;
#ifdef SQLITE_TEST
int sqlite3_sync_count;
int sqlite3_fullsync_count;
#endif

/* Single-process WAL shared memory.  Every connection to the same guest
   path sees one region.  There are no threads, but separate connections in
   one interpreter must still see each other's WAL locks, so keep the same
   lock model as os_unix.c: lock[i] is -1 for an exclusive holder, 0 for a
   free slot, or the number of shared holders.  Each handle additionally
   remembers which slots it owns so unlocks only drop its own references. */
typedef struct NanShm {
    struct NanShm *next;
    char path[128];
    unsigned char *mem;
    unsigned int bytes;
    int ref;
    int lock[SQLITE_SHM_NLOCK]; /* -1 exclusive, 0 free, >0 shared holders */
} NanShm;
static NanShm *nan_shm;

static NanShm *shm_find(const char *path, int create)
{
    NanShm *s;
    for (s = nan_shm; s; s = s->next)
        if (!strcmp(s->path, path)) return s;
    if (!create) return 0;
    s = (NanShm *)malloc(sizeof *s);
    if (!s) return 0;
    memset(s, 0, sizeof *s);
    strncpy(s->path, path, sizeof s->path - 1);
    s->next = nan_shm;
    nan_shm = s;
    return s;
}
/* Drop this handle's references in the shared slot array.  Mirror of the
   aLock[]/sharedMask bookkeeping in os_unix.c: exclusive slots go to 0,
   shared slots lose one holder. */
static void shm_release_locks(NanLFile *f, NanShm *s)
{
    int i;
    if (!s) {
        f->shm_shared = f->shm_excl = 0;
        return;
    }
    for (i = 0; i < SQLITE_SHM_NLOCK; i++) {
        unsigned int bit = 1u << i;
        if (f->shm_excl & bit) {
            if (s->lock[i] == -1) s->lock[i] = 0;
            f->shm_excl &= ~bit;
        } else if (f->shm_shared & bit) {
            if (s->lock[i] > 0) s->lock[i]--;
            f->shm_shared &= ~bit;
        }
    }
}
static void shm_unmap_file(NanLFile *f, int deleteFlag)
{
    NanShm **pp, *s;
    for (pp = &nan_shm; *pp; pp = &(*pp)->next)
        if (!strcmp((*pp)->path, f->path)) break;
    s = *pp;
    if (!s) return;
    shm_release_locks(f, s);
    if (f->shm_mapped) {
        f->shm_mapped = 0;
        if (s->ref > 0) s->ref--;
    }
    /* deleteFlag is set when SQLite closes the last connection; ref covers
       a close order where another handle is still mapped. */
    if (s->ref == 0) {
        *pp = s->next;
        free(s->mem);
        free(s);
    }
}
static int l_shmmap(sqlite3_file *pFile, int iPg, int pgsz, int isWrite,
                    void volatile **pp)
{
    NanLFile *f = (NanLFile *)pFile;
    NanShm *s = shm_find(f->path, 1);
    unsigned int need = (unsigned int)(iPg + 1) * (unsigned int)pgsz;
    (void)isWrite;
    if (!s) return SQLITE_IOERR;
    if (!f->shm_mapped) {
        f->shm_mapped = 1;
        s->ref++;
    }
    if (need > s->bytes) {
        unsigned char *p = (unsigned char *)realloc(s->mem, need);
        if (!p) return SQLITE_NOMEM;
        memset(p + s->bytes, 0, need - s->bytes);
        s->mem = p;
        s->bytes = need;
    }
    *pp = s->mem + (unsigned int)iPg * (unsigned int)pgsz;
    return SQLITE_OK;
}
static int l_shmlock(sqlite3_file *pFile, int offset, int n, int flags)
{
    NanLFile *f = (NanLFile *)pFile;
    NanShm *s = shm_find(f->path, 0);
    unsigned int bits;
    int i;

    if (!s || offset < 0 || n < 1 || offset + n > SQLITE_SHM_NLOCK)
        return SQLITE_IOERR_SHMLOCK;
    bits = ((1u << n) - 1u) << offset;

    if (flags & SQLITE_SHM_UNLOCK) {
        if (flags & SQLITE_SHM_EXCLUSIVE) {
            for (i = offset; i < offset + n; i++)
                if (f->shm_excl & (1u << i)) {
                    if (s->lock[i] == -1) s->lock[i] = 0;
                    f->shm_excl &= ~(1u << i);
                }
        } else {
            for (i = offset; i < offset + n; i++)
                if (f->shm_shared & (1u << i)) {
                    if (s->lock[i] > 0) s->lock[i]--;
                    f->shm_shared &= ~(1u << i);
                }
        }
        return SQLITE_OK;
    }

    if (flags & SQLITE_SHM_EXCLUSIVE) {
        if ((f->shm_excl & bits) == bits) return SQLITE_OK;
        if (f->shm_shared & bits) return SQLITE_BUSY; /* no upgrade */
        for (i = offset; i < offset + n; i++)
            if (s->lock[i] != 0) return SQLITE_BUSY;
        for (i = offset; i < offset + n; i++) s->lock[i] = -1;
        f->shm_excl |= bits;
        return SQLITE_OK;
    }

    /* SHARED: several connections may own the same slot at once. */
    for (i = offset; i < offset + n; i++) {
        unsigned int bit = 1u << i;
        if (f->shm_excl & bit) return SQLITE_BUSY;
        if (!(f->shm_shared & bit) && s->lock[i] < 0) return SQLITE_BUSY;
    }
    for (i = offset; i < offset + n; i++) {
        unsigned int bit = 1u << i;
        if (!(f->shm_shared & bit)) {
            s->lock[i]++;
            f->shm_shared |= bit;
        }
    }
    return SQLITE_OK;
}
static void l_shmbarrier(sqlite3_file *pFile) { (void)pFile; }
static int l_shmunmap(sqlite3_file *pFile, int deleteFlag)
{
    shm_unmap_file((NanLFile *)pFile, deleteFlag);
    return SQLITE_OK;
}

static int l_close(sqlite3_file *pFile)
{
    NanLFile *f = (NanLFile *)pFile;
    shm_unmap_file(f, 0);
    lock_set(f, SQLITE_LOCK_NONE);
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
    if (f->fd < 0) { errno = EISDIR; nan_set_errno(); return SQLITE_IOERR_READ; }
    if (lseek(f->fd, (off_t)off, SEEK_SET) < 0) {
        nan_set_errno();
        return SQLITE_IOERR_READ;
    }
    r = (int)read(f->fd, buf, (size_t)amt);
    if (r < 0) { nan_set_errno(); return SQLITE_IOERR_READ; }
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
    if (f->fd < 0) { errno = EBADF; nan_set_errno(); return SQLITE_IOERR_WRITE; }
    if (f->readonly) { errno = EACCES; nan_set_errno(); return SQLITE_READONLY; }
    if (lseek(f->fd, (off_t)off, SEEK_SET) < 0) {
        nan_set_errno();
        return SQLITE_IOERR_WRITE;
    }
    r = (int)write(f->fd, buf, (size_t)amt);
    if (r != amt) { nan_set_errno(); return SQLITE_IOERR_WRITE; }
    return SQLITE_OK;
}
static int l_truncate(sqlite3_file *pFile, sqlite3_int64 size)
{
    NanLFile *f = (NanLFile *)pFile;
    sqlite3_int64 nSize = size;
    if (f->readonly) return SQLITE_READONLY;
    /* Match unixTruncate(): when a chunk size is configured, round the
       file up so the allocation happens in the requested chunks. */
    if (f->szChunk > 0) {
        sqlite3_int64 nRound =
            ((nSize + f->szChunk - 1) / f->szChunk) * f->szChunk;
        if (nRound > nSize) nSize = nRound;
    }
    if (f->fd >= 0 && ftruncate(f->fd, (off_t)nSize) == 0) return SQLITE_OK;
    nan_set_errno();
    return SQLITE_IOERR_TRUNCATE;
}
static int l_sync(sqlite3_file *pFile, int flags)
{
    NanLFile *f = (NanLFile *)pFile;
#ifdef SQLITE_TEST
    /* SQLITE_SYNC_FULL is 0x03 and NORMAL is 0x02; testing a single bit
       counts NORMAL as full.  Match os_unix.c's (flags&0x0F) test. */
    if ((flags & 0x0F) == SQLITE_SYNC_FULL) sqlite3_fullsync_count++;
    sqlite3_sync_count++;
#endif
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
    NanLFile *f = (NanLFile *)pFile;
    if (lock < SQLITE_LOCK_SHARED || lock > SQLITE_LOCK_EXCLUSIVE)
        return SQLITE_OK;
    if (lock == SQLITE_LOCK_EXCLUSIVE) {
        /* Match unixLock(): take the pending byte before attempting the
           exclusive shared-byte lock.  If another connection still holds
           SHARED, leave this handle in PENDING after returning BUSY; that is
           the state PRAGMA lock_status reports. */
        if (f->lock < SQLITE_LOCK_PENDING) {
            if (lock_conflict(f, SQLITE_LOCK_PENDING)) return SQLITE_BUSY;
            if (lock_set(f, SQLITE_LOCK_PENDING) != SQLITE_OK)
                return SQLITE_IOERR;
        }
        if (lock_conflict(f, SQLITE_LOCK_EXCLUSIVE)) return SQLITE_BUSY;
        return lock_set(f, SQLITE_LOCK_EXCLUSIVE);
    }
    if (lock_conflict(f, lock)) return SQLITE_BUSY;
    return lock_set(f, lock);
}
static int l_unlock(sqlite3_file *pFile, int lock)
{
    NanLFile *f = (NanLFile *)pFile;
    if (lock < SQLITE_LOCK_SHARED) lock = SQLITE_LOCK_NONE;
    return lock_set(f, lock);
}
static int l_checkreserved(sqlite3_file *pFile, int *pRes)
{
    NanLFile *f = (NanLFile *)pFile;
    NanLock *e;
    *pRes = 0;
    for (e = nan_locks; e; e = e->next) {
        if (e->file == f || e->level < SQLITE_LOCK_RESERVED) continue;
        if (!strcmp(e->path, f->path)) { *pRes = 1; break; }
    }
    return SQLITE_OK;
}
static int l_filecontrol(sqlite3_file *pFile, int op, void *arg)
{
    NanLFile *f = (NanLFile *)pFile;
    switch (op) {
    case SQLITE_FCNTL_LOCKSTATE:
        *(int *)arg = f->lock;
        return SQLITE_OK;
    case SQLITE_FCNTL_SIZE_HINT: {
        sqlite3_int64 n = *(sqlite3_int64 *)arg;
        /* Like unix fcntlSizeHint(): round the hint up to the configured
           chunk size so the file grows in whole chunks. */
        if (f->szChunk > 0) {
            n = ((n + f->szChunk - 1) / f->szChunk) * f->szChunk;
        }
        if (f->fd >= 0 && ftruncate(f->fd, (off_t)n) != 0) {
            nan_set_errno();
            return SQLITE_IOERR_TRUNCATE;
        }
        return SQLITE_OK;
    }
    case SQLITE_FCNTL_POWERSAFE_OVERWRITE: {
        int *p = (int *)arg;
        if (!p) return SQLITE_NOTFOUND;
        if (*p < 0) *p = f->psow;
        else f->psow = *p != 0;
        return SQLITE_OK;
    }
    case SQLITE_FCNTL_CHUNK_SIZE:
        f->szChunk = arg ? *(int *)arg : 0;
        return SQLITE_OK;
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
    NanLFile *f = (NanLFile *)pFile;
    /* The guest file store is RAM-backed and byte-addressable: an overwrite
       within a sector cannot tear across power loss.  Without PSOW,
       synchronous=FULL WAL pads every commit to a 512-byte sector boundary
       by repeating the last frame, which changes logical mxFrame counts.
       PRAGMA journal_mode=wal&psow=0 clears it per handle via fcntl. */
    return (f->psow ? SQLITE_IOCAP_POWERSAFE_OVERWRITE : 0)
         | SQLITE_IOCAP_SUBPAGE_READ;
}
static const sqlite3_io_methods l_io = {
    2, l_close, l_read, l_write, l_truncate, l_sync,
    l_filesize, l_lock, l_unlock, l_checkreserved,
    l_filecontrol, l_sectorsize, l_device,
    l_shmmap, l_shmlock, l_shmbarrier, l_shmunmap
};

/* SQLite may open the same database as "test.db" and "./test.db".  WAL
   shared memory is keyed by this string, so store the canonical absolute
   path to make separate connections share one shm/lock region. */
static void shm_set_path(NanLFile *f, const char *name)
{
    char resolved[128];
    if (nan16_vfs_resolve(name, resolved) == 0)
        strncpy(f->path, resolved, sizeof f->path - 1);
    else
        strncpy(f->path, name, sizeof f->path - 1);
    f->path[sizeof f->path - 1] = 0;
}

static int l_open(sqlite3_vfs *pVfs, const char *name, sqlite3_file *pFile,
                  int flags, int *pOutFlags)
{
    NanLFile *f = (NanLFile *)pFile;
    int oflags = O_RDONLY, fd;
    int outFlags = flags;
    char tmp[64];
    struct stat lst;
    (void)pVfs;
    if (name && (flags & SQLITE_OPEN_NOFOLLOW)
        && lstat(name, &lst) == 0 && S_ISLNK(lst.st_mode)) {
        errno = ELOOP;
        nan_set_errno();
        return SQLITE_CANTOPEN;
    }
    f->fd = -1;
    f->del = 0;
    f->readonly = !(flags & (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE));
    f->lock = SQLITE_LOCK_NONE;
    f->shm_shared = 0;
    f->shm_excl = 0;
    f->shm_mapped = 0;
    f->psow = 1;
    f->szChunk = 0;
    f->path[0] = 0;
    if (!name) {
        snprintf(tmp, sizeof tmp, "/.nan_tmp_%u", ++temp_seq);
        name = tmp;
        f->del = 1;
    }
    /* A POSIX read-only open of a directory succeeds; the first read then
       fails with EISDIR, which SQLite reports as SQLITE_IOERR_READ ("disk
       I/O error").  The guest libc refuses open() on a directory outright,
       so give the pager a read-only handle whose xRead reports the I/O
       error.  This is what backup2-10. */
    if (!(flags & (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE))
        && stat(name, &lst) == 0 && S_ISDIR(lst.st_mode)
    ) {
        f->readonly = 1;
        f->fd = -1;
        shm_set_path(f, name);
        if (pOutFlags) *pOutFlags = flags;
        pFile->pMethods = &l_io;
        return SQLITE_OK;
    }
    if (flags & SQLITE_OPEN_READWRITE) oflags = O_RDWR;
    if (flags & SQLITE_OPEN_CREATE) oflags |= O_CREAT;
    if (flags & SQLITE_OPEN_DELETEONCLOSE) f->del = 1;
    fd = open(name, oflags, 0644);
    if (fd < 0 && (flags & SQLITE_OPEN_READWRITE) && errno == EACCES) {
        /* Match unixOpen(): if read-write access is denied, retry read-only
           and tell the caller.  Writes then fail with SQLITE_READONLY
           instead of the open failing with CANTOPEN (backup2-6). */
        fd = open(name, O_RDONLY);
        if (fd >= 0) {
            f->readonly = 1;
            outFlags = (flags & ~(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE))
                     | SQLITE_OPEN_READONLY;
        }
    }
    if (fd < 0) {
        nan_set_errno();
        return SQLITE_CANTOPEN;
    }
    f->fd = fd;
    shm_set_path(f, name);
    if (pOutFlags) *pOutFlags = outFlags;
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
    char resolved[128];
    int symlink = 0;
    (void)pVfs;
    if (nOut <= 0) return SQLITE_OK;
    if (!name) name = "";
    symlink = nan16_vfs_is_symlink_path(name);
    if (nan16_vfs_resolve(name, resolved) == 0) {
        strncpy(zOut, resolved, (size_t)nOut - 1);
        zOut[nOut - 1] = 0;
    } else {
        strncpy(zOut, name, (size_t)nOut - 1);
        zOut[nOut - 1] = 0;
    }
    return symlink ? SQLITE_OK_SYMLINK : SQLITE_OK;
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
    volatile unsigned *slept = (volatile unsigned *)0x03EFF01Cu;
    (void)pVfs;
    if (usec <= 0) return 0;
    /* Advance the guest's virtual clock instead of busy-waiting in the
       guest nanosleep(), which can only observe time at runner slice
       boundaries.  Busy-handler timeouts then match Tcl's clock and do not
       consume millions of instructions. */
    *slept += (unsigned)((usec + 999) / 1000);
    /* xSleep returns microseconds; sqlite3_sleep() divides by 1000. */
    return usec;
}
static unsigned int l_now_ms(void)
{
    return *(volatile unsigned int *)0x03EFF010u;
}
/* Test hook: date.test sets sqlite_current_time through a Tcl link to fake
   the wall clock (os_unix.c uses the same variable). */
extern int sqlite3_current_time;
static int l_currenttime(sqlite3_vfs *pVfs, double *pTime)
{
    (void)pVfs;
    if (sqlite3_current_time) {
        *pTime = 2440587.5 + (double)sqlite3_current_time / 86400.0;
    } else {
        *pTime = 2440587.5 + ((double)l_now_ms() / 1000.0) / 86400.0;
    }
    return SQLITE_OK;
}
static int l_currenttimeint64(sqlite3_vfs *pVfs, sqlite3_int64 *pTime)
{
    (void)pVfs;
    if (sqlite3_current_time) {
        *pTime = 1000LL * (sqlite3_int64)sqlite3_current_time
               + 210866760000000LL;
    } else {
        *pTime = (sqlite3_int64)l_now_ms() + 210866760000000LL;
    }
    return SQLITE_OK;
}
static int l_getlasterror(sqlite3_vfs *pVfs, int nBuf, char *zBuf)
{
    const char *zMsg;
    (void)pVfs;
    if (nBuf <= 0) return nan_last_errno;
    zMsg = nan_last_errno ? strerror(nan_last_errno) : "";
    if (zMsg == 0) zMsg = "";
    snprintf(zBuf, (size_t)nBuf, "%s", zMsg);
    return nan_last_errno;
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
