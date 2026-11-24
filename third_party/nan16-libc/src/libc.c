/* Minimal NaN16 C library for the self-hosted TCC.  Heap and files live in
   guest memory; stdout/stderr are captured buffers. */
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <ctype.h>
#include <setjmp.h>
#include <time.h>
#include <unistd.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <math.h>
#include <semaphore.h>
#include <glob.h>
#include "nan16_pow10.h"

int errno;

/* ---------------------------------------------------------------- memory */
#define HEAP_BASE ((unsigned char *)0x04000000u)
#ifndef HEAP_SIZE
#define HEAP_SIZE (64u * 1024u * 1024u)
#endif
#define HDR_ALIGN 16u

typedef struct Block {
    unsigned size;
    int free;
    struct Block *next;
    unsigned pad;       /* 16-byte header: keep the payload 16-byte aligned */
} Block;

static Block *heap_head;

static unsigned align_up(unsigned n)
{
    return (n + HDR_ALIGN - 1) & ~(HDR_ALIGN - 1);
}

static void heap_init(void)
{
    if (!heap_head) {
        heap_head = (Block *)HEAP_BASE;
        heap_head->size = HEAP_SIZE - sizeof(Block);
        heap_head->free = 1;
        heap_head->next = 0;
    }
}

void *malloc(size_t n)
{
    Block *b, *prev = 0;
    unsigned need;
    heap_init();
    need = align_up((unsigned)n);
    for (b = heap_head; b; prev = b, b = b->next) {
        if (b->free && b->size >= need) {
            if (b->size >= need + sizeof(Block) + HDR_ALIGN) {
                Block *nb = (Block *)((unsigned char *)(b + 1) + need);
                nb->size = b->size - need - sizeof(Block);
                nb->free = 1;
                nb->next = b->next;
                b->next = nb;
                b->size = need;
            }
            b->free = 0;
            return b + 1;
        }
    }
    return 0;
}

void free(void *p)
{
    Block *b, *n;
    if (!p) return;
    b = (Block *)p - 1;
    b->free = 1;
    for (n = heap_head; n; n = n->next) {
        if (n->free && n->next && n->next->free) {
            n->size += sizeof(Block) + n->next->size;
            n->next = n->next->next;
        }
    }
}

void *calloc(size_t n, size_t s)
{
    void *p = malloc(n * s);
    if (p) memset(p, 0, n * s);
    return p;
}

void *realloc(void *p, size_t n)
{
    Block *b;
    void *q;
    unsigned old;
    if (!p) return malloc(n);
    if (!n) { free(p); return 0; }
    b = (Block *)p - 1;
    old = b->size;
    if (old >= n) return p;
    q = malloc(n);
    if (!q) return 0;
    memcpy(q, p, old);
    free(p);
    return q;
}

/* ---------------------------------------------------------------- strings */
void *memcpy(void *d, const void *s, size_t n)
{
    unsigned char *dd = d; const unsigned char *ss = s;
    while (n--) *dd++ = *ss++;
    return d;
}
void *memmove(void *d, const void *s, size_t n)
{
    unsigned char *dd = d; const unsigned char *ss = s;
    if (dd < ss) { while (n--) *dd++ = *ss++; }
    else { dd += n; ss += n; while (n--) *--dd = *--ss; }
    return d;
}
void *memset(void *d, int c, size_t n)
{
    unsigned char *dd = d;
    while (n--) *dd++ = (unsigned char)c;
    return d;
}
size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *x = a, *y = b;
    while (n--) { if (*x != *y) return *x - *y; x++; y++; }
    return 0;
}
void *memchr(const void *a, int c, size_t n)
{
    const unsigned char *x = a;
    while (n--) { if (*x == (unsigned char)c) return (void *)x; x++; }
    return 0;
}
size_t strnlen(const char *s, size_t n) { size_t i = 0; while (i < n && s[i]) i++; return i; }
int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}
int strncmp(const char *a, const char *b, size_t n)
{
    while (n && *a && *a == *b) { a++; b++; n--; }
    if (!n) return 0;
    return (unsigned char)*a - (unsigned char)*b;
}
char *strcpy(char *d, const char *s) { char *r = d; while ((*d++ = *s++)) ; return r; }
char *strncpy(char *d, const char *s, size_t n)
{
    char *r = d;
    while (n && *s) { *d++ = *s++; n--; }
    while (n--) *d++ = 0;
    return r;
}
char *strcat(char *d, const char *s) { char *r = d; while (*d) d++; strcpy(d, s); return r; }
char *strncat(char *d, const char *s, size_t n)
{
    char *r = d; while (*d) d++;
    while (n-- && *s) *d++ = *s++;
    *d = 0;
    return r;
}
char *strchr(const char *s, int c)
{
    while (*s) { if (*s == (char)c) return (char *)s; s++; }
    return c ? 0 : (char *)s;
}
char *strrchr(const char *s, int c)
{
    const char *r = 0;
    while (*s) { if (*s == (char)c) r = s; s++; }
    return c ? (char *)r : (char *)s;
}
char *strstr(const char *a, const char *b)
{
    size_t n = strlen(b);
    if (!n) return (char *)a;
    while (*a) { if (!strncmp(a, b, n)) return (char *)a; a++; }
    return 0;
}
char *strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}
size_t strspn(const char *s, const char *a)
{
    size_t n = 0;
    while (s[n] && strchr(a, s[n])) n++;
    return n;
}
size_t strcspn(const char *s, const char *a)
{
    size_t n = 0;
    while (s[n] && !strchr(a, s[n])) n++;
    return n;
}
char *strpbrk(const char *s, const char *a)
{
    while (*s) { if (strchr(a, *s)) return (char *)s; s++; }
    return 0;
}
char *strtok(char *s, const char *a)
{
    static char *save;
    char *p;
    if (!s) s = save;
    if (!s) return 0;
    s += strspn(s, a);
    if (!*s) { save = 0; return 0; }
    p = s + strcspn(s, a);
    if (*p) { *p = 0; save = p + 1; } else save = 0;
    return s;
}
char *strerror(int e) { (void)e; return (char *)"error"; }

/* ---------------------------------------------------------------- ctype */
int isalpha(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
int isdigit(int c) { return c >= '0' && c <= '9'; }
int isalnum(int c) { return isalpha(c) || isdigit(c); }
int isspace(int c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'; }
int isupper(int c) { return c >= 'A' && c <= 'Z'; }
int islower(int c) { return c >= 'a' && c <= 'z'; }
int isprint(int c) { return c >= 32 && c < 127; }
int ispunct(int c) { return isprint(c) && !isalnum(c) && c != ' '; }
int isxdigit(int c) { return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
int iscntrl(int c) { return c < 32 || c == 127; }
int isgraph(int c) { return c > 32 && c < 127; }
int toupper(int c) { return islower(c) ? c - 32 : c; }
int tolower(int c) { return isupper(c) ? c + 32 : c; }

/* ---------------------------------------------------------------- stdlib */
static int digit_val(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'z') return c - 'a' + 10;
    if (c >= 'A' && c <= 'Z') return c - 'A' + 10;
    return 99;
}

long strtol(const char *s, char **end, int base)
{
    unsigned long v = 0; int neg = 0, any = 0, d;
    while (isspace((unsigned char)*s)) s++;
    if (*s == '+' || *s == '-') { neg = *s == '-'; s++; }
    if ((base == 0 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
    else if (base == 0 && s[0] == '0') { base = 8; s++; }
    else if (base == 0) base = 10;
    while ((d = digit_val((unsigned char)*s)) < base) { v = v * base + d; any = 1; s++; }
    if (end) *end = (char *)(any ? s : s);
    return neg ? -(long)v : (long)v;
}
unsigned long strtoul(const char *s, char **end, int base)
{
    unsigned long v = 0; int any = 0, d;
    while (isspace((unsigned char)*s)) s++;
    if (*s == '+') s++;
    if ((base == 0 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
    else if (base == 0 && s[0] == '0') { base = 8; s++; }
    else if (base == 0) base = 10;
    while ((d = digit_val((unsigned char)*s)) < base) { v = v * base + d; any = 1; s++; }
    if (end) *end = (char *)(any ? s : s);
    return v;
}
long long strtoll(const char *s, char **end, int base) { return (long long)strtol(s, end, base); }
unsigned long long strtoull(const char *s, char **end, int base) { return (unsigned long long)strtoul(s, end, base); }
int atoi(const char *s) { return (int)strtol(s, 0, 10); }
long atol(const char *s) { return strtol(s, 0, 10); }
long long atoll(const char *s) { return strtoll(s, 0, 10); }
int abs(int x) { return x < 0 ? -x : x; }
long labs(long x) { return x < 0 ? -x : x; }
long long llabs(long long x) { return x < 0 ? -x : x; }

extern unsigned long long __nan16_f2d(unsigned);
extern unsigned long long __nan16_dmul(unsigned long long, unsigned long long);
extern unsigned long long __nan16_dadd(unsigned long long, unsigned long long);
extern unsigned long long __nan16_i2d(int);
extern unsigned long long __nan16_ll2d(long long);
extern unsigned long long __nan16_ull2d(unsigned long long);
extern long long __nan16_d2ll(unsigned long long);
extern unsigned long long __nan16_ddiv(unsigned long long, unsigned long long);

/* Decimal to binary64.  Keep at most 19 significant digits in a 64-bit
   mantissa (the exact limit before unsigned overflow would lose digits),
   remember the discarded digits for round-to-nearest-even, then apply one
   correctly rounded power of ten.  The old implementation accumulated
   every integer digit without an overflow check, so 2^64 and 2^96 wrapped
   to zero, and repeated multiplication by ten lost the low bits of
   values like DBL_MAX. */
double strtod(const char *s, char **end)
{
    unsigned long long mant = 0;
    unsigned long long d;
    int neg = 0, any = 0, sig = 0, frac = 0;
    int kept = 0, dropped = 0, frac_digits = 0;
    int exp = 0, edig = 0, esign = 1;
    int first_drop = 0, sticky = 0;
    int dexp, k;
    const char *p = s;

    while (isspace((unsigned char)*p)) p++;
    if (*p == '+' || *p == '-') { neg = *p == '-'; p++; }

    while (isdigit((unsigned char)*p) || *p == '.') {
        int c = *p;
        if (c == '.') {
            if (frac) break;
            frac = 1;
            p++;
            continue;
        }
        any = 1;
        if (frac) frac_digits++;
        if (sig || c != '0') {
            sig = 1;
            if (kept < 19) {
                mant = mant * 10 + (unsigned)(c - '0');
                kept++;
            } else {
                if (!dropped) first_drop = c;
                else if (c != '0') sticky = 1;
                dropped++;
            }
        }
        p++;
    }
    if (any && (*p == 'e' || *p == 'E')) {
        p++;
        if (*p == '+' || *p == '-') { esign = (*p == '+') ? 1 : -1; p++; }
        while (isdigit((unsigned char)*p)) {
            if (edig < 100000) edig = edig * 10 + (*p - '0');
            p++;
        }
        exp = esign * edig;
    }
    if (end) *end = (char *)p;
    if (!any) return 0.0;
    if (!sig) {
        d = 0;
        if (neg) d ^= 0x8000000000000000ULL;
        return *(double *)&d;
    }

    if (first_drop) {
        if (first_drop > '5'
            || (first_drop == '5' && (sticky || (mant & 1))))
            mant++;
    }

    dexp = exp - frac_digits + dropped;
    d = __nan16_ull2d(mant);
    if (dexp >= 0) {
        if (dexp > 308) {
            d = 0x7FF0000000000000ULL;
        } else {
            d = __nan16_dmul(d, nan16_pow10_bits[dexp]);
        }
    } else {
        k = -dexp;
        if (k > 308) {
            d = __nan16_ddiv(d, nan16_pow10_bits[308]);
            k -= 308;
            if (k <= 308)
                d = __nan16_ddiv(d, nan16_pow10_bits[k]);
            else
                d = 0;
        } else {
            d = __nan16_ddiv(d, nan16_pow10_bits[k]);
        }
    }
    if (neg) d ^= 0x8000000000000000ULL;
    return *(double *)&d;
}
float strtof(const char *s, char **end) { double d = strtod(s, end); return (float)d; }
long double strtold(const char *s, char **end) { return (long double)strtod(s, end); }

static void swap_bytes(void *a, void *b, size_t n)
{
    unsigned char *x = a, *y = b, t;
    while (n--) { t = *x; *x++ = *y; *y++ = t; }
}
void qsort(void *base, size_t n, size_t size, int (*cmp)(const void *, const void *))
{
    unsigned char *a = base;
    size_t i, j;
    if (n < 2) return;
    for (i = 1; i < n; i++)
        for (j = i; j > 0 && cmp(a + (j - 1) * size, a + j * size) > 0; j--)
            swap_bytes(a + (j - 1) * size, a + j * size, size);
}
void *bsearch(const void *key, const void *base, size_t n, size_t size,
              int (*cmp)(const void *, const void *))
{
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        const void *p = (const unsigned char *)base + mid * size;
        int c = cmp(key, p);
        if (c == 0) return (void *)p;
        if (c < 0) hi = mid; else lo = mid + 1;
    }
    return 0;
}

static char *env_store[64];
char **environ = env_store;
static int env_index(const char *name, size_t n)
{
    int i;
    for (i = 0; environ[i]; i++)
        if (!strncmp(environ[i], name, n) && environ[i][n] == '=')
            return i;
    return -1;
}
char *getenv(const char *name)
{
    int i = env_index(name, strlen(name));
    return i < 0 ? 0 : environ[i] + strlen(name) + 1;
}
int setenv(const char *name, const char *value, int overwrite)
{
    char *s;
    size_t n = strlen(name);
    int i;
    if (!name || !*name || strchr(name, '=')) { errno = EINVAL; return -1; }
    i = env_index(name, n);
    if (i >= 0 && !overwrite) return 0;
    s = (char *)malloc(n + strlen(value) + 2);
    if (!s) { errno = ENOMEM; return -1; }
    memcpy(s, name, n);
    s[n] = '=';
    strcpy(s + n + 1, value);
    if (i >= 0) { environ[i] = s; return 0; }
    for (i = 0; environ[i]; i++) ;
    if (i >= 63) { free(s); errno = ENOMEM; return -1; }
    environ[i] = s;
    environ[i + 1] = 0;
    return 0;
}
int putenv(char *s)
{
    char *eq;
    size_t n;
    int i;
    if (!s) { errno = EINVAL; return -1; }
    eq = strchr(s, '=');
    if (!eq) {
        n = strlen(s);
        i = env_index(s, n);
        if (i >= 0) {
            while (environ[i]) { environ[i] = environ[i + 1]; i++; }
        }
        return 0;
    }
    n = (size_t)(eq - s);
    i = env_index(s, n);
    if (i >= 0) { environ[i] = s; return 0; }
    for (i = 0; environ[i]; i++) ;
    if (i >= 63) { errno = ENOMEM; return -1; }
    environ[i] = s;
    environ[i + 1] = 0;
    return 0;
}
int unsetenv(const char *name)
{
    int i = env_index(name, strlen(name));
    if (i < 0) return 0;
    while (environ[i]) { environ[i] = environ[i + 1]; i++; }
    return 0;
}

int nan16_exit_code;
#ifdef NAN16_EXIT_DIAG
extern unsigned char *nan16_stderr_data;
extern unsigned nan16_stderr_len;
extern unsigned char *nan16_stdout_data;
extern unsigned nan16_stdout_len;
static void exit_diag(int code)
{
    unsigned char *d;
    unsigned n;
    d = (unsigned char *)0x03E00000u;
    n = nan16_stderr_len; if (n > 262144u) n = 262144u;
    if (n && nan16_stderr_data) memcpy(d, nan16_stderr_data, n);
    d[n] = 0;
    *(volatile unsigned *)0x03DFFFF0u = n;
    d = (unsigned char *)0x03E40000u;
    n = nan16_stdout_len; if (n > 262144u) n = 262144u;
    if (n && nan16_stdout_data) memcpy(d, nan16_stdout_data, n);
    d[n] = 0;
    *(volatile unsigned *)0x03DFFFF4u = n;
    *(volatile unsigned *)0x03DFFFF8u = (unsigned)code;
}
#endif
void exit(int code) {
#ifdef NAN16_EXIT_DIAG
    exit_diag(code);
#endif
    nan16_exit_code = code; for (;;) ;
}
void _Exit(int code) { exit(code); }
void abort(void) { exit(134); }

#ifdef NAN16_ASSERT_DIAG
void __nan16_assert_fail(const char *expr, const char *file, int line)
{
    volatile char *d = (volatile char *)0x03000400u;
    int i, n = 0;
    for (i = 0; expr && expr[i] && n < 100; i++) d[n++] = expr[i];
    d[n++] = 0;
    for (i = 0; file && file[i] && n < 200; i++) d[n++] = file[i];
    d[n++] = 0;
    *(volatile unsigned *)0x03000500u = (unsigned)line;
    *(volatile unsigned *)0x02FFFFF0u = 0xAB0B0000u;
    for (;;) ;
}
#endif
int atexit(void (*fn)(void)) { (void)fn; return 0; }
int system(const char *s) { (void)s; return 0; }

/* ---------------------------------------------------------------- stdio/VFS */
/* VFS capacity is a compile-time directive, not a fixed array:
   -DNAN16_VFS_INIT_CAP=N   initial pointer-table slots (default 16)
   -DNAN16_VFS_MAXFILES=N   optional hard cap; omitted = grow without a cap
   The table doubles on demand and supports arbitrary pack sizes. */
#ifndef NAN16_VFS_INIT_CAP
#define NAN16_VFS_INIT_CAP 16u
#endif
#define MAXSTREAMS 64
#define FD_VFS_BASE 3
#define VFS_NAME_MAX 128
typedef struct MemFile {
    char name[VFS_NAME_MAX];
    unsigned char *data;
    unsigned size, cap, pos;
    int used, writable, owned, isdir;
} MemFile;
static MemFile *files;
static unsigned vfs_cap, vfs_used;
static int vfs_abspath(const char *, char *);
static MemFile *mf_find_p(const char *);

typedef struct NFile {
    int fd;       /* 3.. or -1 for stdout/stderr */
    int is_err;
    int eof;
} NFile;
static NFile streams[MAXSTREAMS];
static NFile f_stdin = { 0, 0, 0 };
static NFile f_stdout = { -1, 0, 0 };
static NFile f_stderr = { -1, 1, 0 };
FILE *stdin = (FILE *)&f_stdin;
FILE *stdout = (FILE *)&f_stdout;
FILE *stderr = (FILE *)&f_stderr;

unsigned char *nan16_stdout_data;
unsigned nan16_stdout_len, nan16_stdout_cap;
unsigned char *nan16_stderr_data;
unsigned nan16_stderr_len, nan16_stderr_cap;

static void outcap(unsigned char **buf, unsigned *len, unsigned *cap, int c)
{
    if (*len + 1 >= *cap) {
        unsigned nc = *cap ? *cap * 2 : 256;
        unsigned char *nb = malloc(nc);
        if (*buf) { memcpy(nb, *buf, *len); free(*buf); }
        *buf = nb; *cap = nc;
    }
    (*buf)[(*len)++] = (unsigned char)c;
}

static int vfs_reserve(unsigned need)
{
    unsigned ncap;
    MemFile *nf;
    if (need <= vfs_cap) return 0;
    ncap = vfs_cap ? vfs_cap : NAN16_VFS_INIT_CAP;
    while (ncap < need) {
        if (ncap > 0x7FFFFFFFu / 2u) return -1;
        ncap *= 2;
    }
#ifdef NAN16_VFS_MAXFILES
    if (ncap > (unsigned)NAN16_VFS_MAXFILES) ncap = (unsigned)NAN16_VFS_MAXFILES;
    if (need > ncap) return -1;
#endif
    nf = (MemFile *)realloc(files, (size_t)ncap * sizeof(MemFile));
    if (!nf) return -1;
    memset(nf + vfs_cap, 0, (size_t)(ncap - vfs_cap) * sizeof(MemFile));
    files = nf;
    vfs_cap = ncap;
    return 0;
}
static MemFile *mf_find(const char *name)
{
    unsigned i;
    for (i = 0; i < vfs_cap; i++)
        if (files[i].used && !strcmp(files[i].name, name)) return &files[i];
    return 0;
}
static MemFile *mf_new(const char *name)
{
    unsigned i, slot;
    for (i = 0; i < vfs_cap; i++) {
        if (!files[i].used) {
            slot = i;
            goto init;
        }
    }
    slot = vfs_cap;
    if (vfs_reserve(slot + 1) < 0) return 0;
init:
    files[slot].used = 1;
    strncpy(files[slot].name, name, VFS_NAME_MAX - 1);
    files[slot].name[VFS_NAME_MAX - 1] = 0;
    files[slot].data = 0; files[slot].size = files[slot].cap = files[slot].pos = 0;
    files[slot].writable = 1;
    files[slot].owned = 1;
    files[slot].isdir = 0;
    vfs_used++;
    return &files[slot];
}
/* Fill a known-free slot directly.  nan16_vfs_add_pack reserves capacity for
   the whole archive, so appending must not re-scan the table per file. */
static int mf_put_ro(unsigned slot, const char *name, const void *data,
                     unsigned size)
{
    if (slot >= vfs_cap || files[slot].used) return -1;
    strncpy(files[slot].name, name, VFS_NAME_MAX - 1);
    files[slot].name[VFS_NAME_MAX - 1] = 0;
    files[slot].data = (unsigned char *)(void *)data;
    files[slot].size = files[slot].cap = size;
    files[slot].pos = 0;
    files[slot].used = 1;
    files[slot].writable = 0;
    files[slot].owned = 0;
    files[slot].isdir = 0;
    vfs_used++;
    return 0;
}
int nan16_vfs_add(const char *name, const void *data, unsigned size)
{
    MemFile *f = mf_find(name);
    if (!f) f = mf_new(name);
    if (!f) return -1;
    if (f->owned && f->data) free(f->data);
    f->data = malloc(size ? size : 1);
    if (!f->data) return -1;
    memcpy(f->data, data, size);
    f->size = f->cap = size;
    f->pos = 0; f->writable = 0; f->owned = 1;
    f->isdir = 0;
    return 0;
}

/* Register a read-only file backed directly by embedded ROM data.  The
   compiler and the test suite use this to avoid a second copy of multi-
   megabyte sources in the guest heap. */
int nan16_vfs_add_ro(const char *name, const void *data, unsigned size)
{
    MemFile *f = mf_find(name);
    if (!f) f = mf_new(name);
    if (!f) return -1;
    if (f->owned && f->data) free(f->data);
    f->data = (unsigned char *)(void *)data;
    f->size = f->cap = size;
    f->pos = 0; f->writable = 0; f->owned = 0;
    f->isdir = 0;
    return 0;
}
/* Register every file in an N16PACK1 archive (see
   src/tests/tcl_sqlite/PACK_FORMAT.md).  The pack is a byte stream in guest
   memory; callers place it with tools/nan16_pack_image.py, which encodes four
   bytes per NaN16 payload word.  All integers are little-endian. */
static unsigned pk_u16(const unsigned char *p)
{
    return (unsigned)p[0] | ((unsigned)p[1] << 8);
}
static unsigned pk_u32(const unsigned char *p)
{
    return (unsigned)p[0] | ((unsigned)p[1] << 8)
         | ((unsigned)p[2] << 16) | ((unsigned)p[3] << 24);
}
int nan16_vfs_add_pack(const void *pack, unsigned len)
{
    const unsigned char *p = (const unsigned char *)pack;
    unsigned count, off, i, slot;
    if (len < 12 || memcmp(p, "N16PACK1", 8))
        return -1;
    count = pk_u32(p + 8);
    /* Reserve once so 2,133-file (or larger) suites do not repeatedly grow
       and re-copy the table.  This is an upper bound; duplicate names reuse
       an existing slot. */
    if (count > 0x7FFFFFFFu - vfs_used || vfs_reserve(vfs_used + count) < 0)
        return -1;
    off = 12;
    slot = vfs_used;
    for (i = 0; i < count; i++) {
        unsigned nl, flags, dl;
        char name[VFS_NAME_MAX];
        if (off + 8 > len)
            return -1;
        nl = pk_u16(p + off);
        flags = pk_u16(p + off + 2);
        dl = pk_u32(p + off + 4);
        off += 8;
        if (!nl || nl >= VFS_NAME_MAX || flags)
            return -1;
        if (off + nl + dl > len)
            return -1;
        memcpy(name, p + off, nl);
        name[nl] = 0;
        if (name[0] != '/')
            return -1;
        /* Boot loads have contiguous slots; a hole or duplicate falls back
           to the general lookup path. */
        if (mf_put_ro(slot, name, p + off + nl, dl) < 0 &&
            nan16_vfs_add_ro(name, p + off + nl, dl) < 0)
            return -1;
        off += nl + dl;
        slot = vfs_used;
    }
    if (off != len)
        return -1;
    return (int)count;
}
unsigned nan16_vfs_count(void) { return vfs_used; }
unsigned nan16_vfs_capacity(void) { return vfs_cap; }
/* Enumerate the table by slot: returns 1 for a live entry.  Callers loop
   i=0..nan16_vfs_capacity()-1 and skip holes.  Pointers stay valid until the
   next table growth or mutation. */
int nan16_vfs_entry(unsigned i, const char **name, unsigned *size, int *isdir)
{
    if (i >= vfs_cap || !files[i].used) return 0;
    if (name) *name = files[i].name;
    if (size) *size = files[i].size;
    if (isdir) *isdir = files[i].isdir;
    return 1;
}
int nan16_vfs_get(const char *name, unsigned char **data, unsigned *size)
{
    MemFile *f = mf_find_p(name);
    if (!f) return -1;
    *data = f->data; *size = f->size;
    return 0;
}
/* A path is a directory if it has an explicit directory entry or if any file
   lives beneath it.  N16PACK1 stores only files, so suite directories such as
   /sqlite/test are implicit.  Trailing slashes are ignored except for root. */
static int mf_isdir_name(const char *name)
{
    char norm[VFS_NAME_MAX];
    unsigned n, i;
    MemFile *f;
    if (!name || name[0] != '/') return 0;
    n = (unsigned)strlen(name);
    while (n > 1 && name[n - 1] == '/') n--;
    if (n >= VFS_NAME_MAX) return 0;
    memcpy(norm, name, n);
    norm[n] = 0;
    if (n == 1) return 1;
    f = mf_find(norm);
    if (f) return f->isdir;
    for (i = 0; i < vfs_cap; i++)
        if (files[i].used && !strncmp(files[i].name, norm, n) &&
            files[i].name[n] == '/')
            return 1;
    return 0;
}
static int vfs_abspath(const char *, char *);
int nan16_vfs_isdir(const char *name)
{
    char abs[VFS_NAME_MAX];
    if (vfs_abspath(name, abs) < 0) return 0;
    return mf_isdir_name(abs);
}
/* Absolute, normalized guest path.  Handles relative paths against vfs_cwd,
   duplicate slashes, "." and ".."; result keeps the leading "/" and drops any
   trailing slash except for root. */
static char vfs_cwd[VFS_NAME_MAX] = "/";
static int vfs_abspath(const char *name, char *out)
{
    char joined[2 * VFS_NAME_MAX];
    const char *p, *comp;
    unsigned olen = 1, clen, len;
    if (!name || !*name) { errno = ENOENT; return -1; }
    if (name[0] == '/') {
        if (strlen(name) >= sizeof joined) { errno = ENAMETOOLONG; return -1; }
        strcpy(joined, name);
    } else {
        clen = (unsigned)strlen(vfs_cwd);
        len = (unsigned)strlen(name);
        if (clen + 1u + len >= sizeof joined) { errno = ENAMETOOLONG; return -1; }
        strcpy(joined, vfs_cwd);
        if (clen == 0 || joined[clen - 1] != '/') strcat(joined, "/");
        strcat(joined, name);
    }
    out[0] = '/'; out[1] = 0;
    p = joined;
    while (*p) {
        while (*p == '/') p++;
        if (!*p) break;
        comp = p;
        while (*p && *p != '/') p++;
        len = (unsigned)(p - comp);
        if (len == 1 && comp[0] == '.') continue;
        if (len == 2 && comp[0] == '.' && comp[1] == '.') {
            while (olen > 1 && out[olen - 1] != '/') olen--;
            if (olen > 1) olen--;
            out[olen] = 0;
            continue;
        }
        if (olen + (olen > 1 ? 1u : 0u) + len >= VFS_NAME_MAX) {
            errno = ENAMETOOLONG; return -1;
        }
        if (olen > 1) out[olen++] = '/';
        memcpy(out + olen, comp, len);
        olen += len;
        out[olen] = 0;
    }
    return 0;
}
static MemFile *mf_find_p(const char *name)
{
    char abs[VFS_NAME_MAX];
    if (vfs_abspath(name, abs) < 0) return 0;
    return mf_find(abs);
}

/* ------------------------------------------------------------ directory API */
struct __nan16_DIR {
    char path[VFS_NAME_MAX];
    struct dirent ent;
    unsigned count, index, cap;
    char **names;
    unsigned char *types;
};
/* Return the immediate child component of file under dir.  *isdir is set when
   the remaining path continues past a slash. */
static int dir_child(const char *dir, const char *file, char *out,
                     unsigned outsz, int *isdir)
{
    const char *start, *slash;
    unsigned n, len;
    n = (unsigned)strlen(dir);
    while (n > 1 && dir[n - 1] == '/') n--;
    if (file[0] != '/') return 0;
    if (n == 1) {
        start = file + 1;
    } else {
        if (strncmp(file, dir, n) || file[n] != '/') return 0;
        start = file + n + 1;
    }
    if (!*start) return 0;
    slash = strchr(start, '/');
    len = slash ? (unsigned)(slash - start) : (unsigned)strlen(start);
    if (!len || len >= outsz) return 0;
    memcpy(out, start, len);
    out[len] = 0;
    *isdir = slash != 0;
    return 1;
}
static int dir_add(DIR *d, const char *name, int isdir)
{
    unsigned i;
    for (i = 0; i < d->count; i++) {
        if (!strcmp(d->names[i], name)) {
            if (isdir) d->types[i] = DT_DIR;
            return 0;
        }
    }
    if (d->count == d->cap) {
        unsigned nc = d->cap ? d->cap * 2 : 16;
        char **nn = (char **)realloc(d->names, nc * sizeof(char *));
        unsigned char *nt;
        if (!nn) return -1;
        d->names = nn;
        nt = (unsigned char *)realloc(d->types, nc);
        if (!nt) return -1;
        d->types = nt;
        d->cap = nc;
    }
    d->names[d->count] = strdup(name);
    if (!d->names[d->count]) return -1;
    d->types[d->count] = isdir ? DT_DIR : DT_REG;
    d->count++;
    return 0;
}
DIR *opendir(const char *path)
{
    DIR *d;
    unsigned i;
    char comp[VFS_NAME_MAX], norm[VFS_NAME_MAX];
    if (vfs_abspath(path, norm) < 0 || !mf_isdir_name(norm)) {
        errno = ENOENT; return 0;
    }
    d = (DIR *)calloc(1, sizeof *d);
    if (!d) { errno = ENOMEM; return 0; }
    strcpy(d->path, norm);
    if (dir_add(d, ".", 1) || dir_add(d, "..", 1)) goto fail;
    for (i = 0; i < vfs_cap; i++) {
        int isdir = 0;
        if (!files[i].used) continue;
        if (dir_child(norm, files[i].name, comp, sizeof comp, &isdir) &&
            dir_add(d, comp, isdir || files[i].isdir))
            goto fail;
    }
    return d;
fail:
    closedir(d);
    errno = ENOMEM;
    return 0;
}
struct dirent *readdir(DIR *d)
{
    if (!d || d->index >= d->count) return 0;
    memset(&d->ent, 0, sizeof d->ent);
    strncpy(d->ent.d_name, d->names[d->index], sizeof d->ent.d_name - 1);
    d->ent.d_type = d->types[d->index];
    d->ent.d_ino = d->index + 1;
    d->ent.d_reclen = sizeof d->ent;
    d->index++;
    return &d->ent;
}
void rewinddir(DIR *d) { if (d) d->index = 0; }
int closedir(DIR *d)
{
    unsigned i;
    if (!d) return -1;
    for (i = 0; i < d->count; i++) free(d->names[i]);
    free(d->names);
    free(d->types);
    free(d);
    return 0;
}

int open(const char *name, int flags, ...)
{
    char abs[VFS_NAME_MAX];
    MemFile *f;
    int i;
    if (vfs_abspath(name, abs) < 0) return -1;
    f = mf_find(abs);
    if (!f) {
        if (!(flags & O_CREAT)) { errno = ENOENT; return -1; }
        f = mf_new(abs);
        if (!f) return -1;
    }
    if (flags & O_TRUNC) { f->size = 0; f->pos = 0; }
    (void)i;
    f->pos = 0;
    return (int)(f - files) + FD_VFS_BASE;
}
int creat(const char *name, int mode) { (void)mode; return open(name, O_CREAT | O_WRONLY | O_TRUNC); }
int close(int fd)
{
    if (fd >= FD_VFS_BASE && (unsigned)(fd - FD_VFS_BASE) < vfs_cap) files[fd - FD_VFS_BASE].pos = 0;
    return 0;
}
ssize_t read(int fd, void *buf, size_t n)
{
    MemFile *f;
    unsigned avail;
    if (fd < FD_VFS_BASE || (unsigned)(fd - FD_VFS_BASE) >= vfs_cap) return -1;
    f = &files[fd - FD_VFS_BASE];
    if (!f->used) return -1;
    avail = f->size - f->pos;
    if (n > avail) n = avail;
    memcpy(buf, f->data + f->pos, n);
    f->pos += n;
    return n;
}
ssize_t write(int fd, const void *buf, size_t n)
{
    MemFile *f;
    unsigned i;
    if (fd == 1 || fd == 2) {
        for (i = 0; i < n; i++)
            if (fd == 1) outcap(&nan16_stdout_data, &nan16_stdout_len, &nan16_stdout_cap, ((const unsigned char *)buf)[i]);
            else outcap(&nan16_stderr_data, &nan16_stderr_len, &nan16_stderr_cap, ((const unsigned char *)buf)[i]);
        /* Fixed terminal-client control block (guest byte addresses):
           0x03EFF000 stdout pointer, +4 length, +8 stderr pointer, +12 length.
           nan_cli --guest-stdout/--guest-stderr reads this without symbols. */
        *(volatile unsigned *)(unsigned long)0x03EFF000u =
            (unsigned)(unsigned long)nan16_stdout_data;
        *(volatile unsigned *)(unsigned long)0x03EFF004u = nan16_stdout_len;
        *(volatile unsigned *)(unsigned long)0x03EFF008u =
            (unsigned)(unsigned long)nan16_stderr_data;
        *(volatile unsigned *)(unsigned long)0x03EFF00Cu = nan16_stderr_len;
        return n;
    }
    if (fd < FD_VFS_BASE || (unsigned)(fd - FD_VFS_BASE) >= vfs_cap) return -1;
    f = &files[fd - FD_VFS_BASE];
    if (!f->used || !f->writable) return -1;
    if (f->pos + n > f->cap) {
        unsigned nc = f->cap ? f->cap : 256;
        unsigned char *nb;
        while (nc < f->pos + n) nc *= 2;
        nb = malloc(nc);
        if (!nb) return -1;
        if (f->data) { memcpy(nb, f->data, f->size); free(f->data); }
        f->data = nb; f->cap = nc;
    }
    memcpy(f->data + f->pos, buf, n);
    f->pos += n;
    if (f->pos > f->size) f->size = f->pos;
    return n;
}
off_t lseek(int fd, off_t off, int whence)
{
    MemFile *f;
    long np;
    if (fd < FD_VFS_BASE || (unsigned)(fd - FD_VFS_BASE) >= vfs_cap) return -1;
    f = &files[fd - FD_VFS_BASE];
    if (!f->used) return -1;
    if (whence == SEEK_SET) np = off;
    else if (whence == SEEK_CUR) np = (long)f->pos + off;
    else np = (long)f->size + off;
    if (np < 0) np = 0;
    f->pos = (unsigned)np;
    return np;
}
static int mf_resize(MemFile *f, unsigned n)
{
    if (n > f->cap) {
        unsigned nc = f->cap ? f->cap : 256;
        unsigned char *nb;
        while (nc < n) nc *= 2;
        nb = (unsigned char *)malloc(nc);
        if (!nb) { errno = ENOMEM; return -1; }
        if (f->data) {
            memcpy(nb, f->data, f->size);
            free(f->data);
        }
        memset(nb + f->size, 0, nc - f->size);
        f->data = nb;
        f->cap = nc;
    } else if (n > f->size) {
        memset(f->data + f->size, 0, n - f->size);
    }
    f->size = n;
    if (f->pos > n) f->pos = n;
    return 0;
}
int ftruncate(int fd, off_t len)
{
    MemFile *f;
    if (fd < FD_VFS_BASE || (unsigned)(fd - FD_VFS_BASE) >= vfs_cap) return -1;
    f = &files[fd - FD_VFS_BASE];
    if (!f->used || f->isdir || !f->writable || len < 0) { errno = EINVAL; return -1; }
    return mf_resize(f, (unsigned)len);
}
int truncate(const char *name, off_t len)
{
    MemFile *f = mf_find_p(name);
    if (!f || f->isdir || !f->writable || len < 0) { errno = EINVAL; return -1; }
    return mf_resize(f, (unsigned)len);
}
int unlink(const char *name)
{
    char abs[VFS_NAME_MAX];
    MemFile *f;
    if (vfs_abspath(name, abs) < 0) return -1;
    f = mf_find(abs);
    if (!f) {
        if (mf_isdir_name(abs)) { errno = EISDIR; return -1; }
        errno = ENOENT; return -1;
    }
    if (f->isdir) { errno = EISDIR; return -1; }
    if (f->owned && f->data) free(f->data);
    f->used = 0;
    if (vfs_used) vfs_used--;
    return 0;
}
int rmdir(const char *name)
{
    char norm[VFS_NAME_MAX];
    unsigned n, i;
    MemFile *f;
    if (vfs_abspath(name, norm) < 0) return -1;
    n = (unsigned)strlen(norm);
    f = mf_find(norm);
    if (!f || !f->isdir) {
        if (!f && mf_isdir_name(norm)) { errno = ENOTEMPTY; return -1; }
        errno = ENOENT; return -1;
    }
    for (i = 0; i < vfs_cap; i++)
        if (files[i].used &&
            ((n == 1) ? (files[i].name[0] == '/' && files[i].name[1])
                      : (!strncmp(files[i].name, norm, n) &&
                         files[i].name[n] == '/'))) {
            errno = ENOTEMPTY; return -1;
        }
    if (f->owned && f->data) free(f->data);
    f->used = 0;
    if (vfs_used) vfs_used--;
    return 0;
}
int remove(const char *name) { return unlink(name); }
int rename(const char *a, const char *b)
{
    char absa[VFS_NAME_MAX], absb[VFS_NAME_MAX], tmp[VFS_NAME_MAX];
    MemFile *f;
    unsigned alen, i;
    if (vfs_abspath(a, absa) < 0 || vfs_abspath(b, absb) < 0) return -1;
    f = mf_find(absa);
    if (!f) { errno = ENOENT; return -1; }
    if (mf_find(absb) || mf_isdir_name(absb)) { errno = EEXIST; return -1; }
    alen = (unsigned)strlen(absa);
    if (f->isdir) {
        for (i = 0; i < vfs_cap; i++) {
            const char *suffix;
            if (!files[i].used || &files[i] == f) continue;
            if (strncmp(files[i].name, absa, alen) || files[i].name[alen] != '/')
                continue;
            suffix = files[i].name + alen;
            if (strlen(absb) + strlen(suffix) >= VFS_NAME_MAX) {
                errno = ENAMETOOLONG; return -1;
            }
        }
        for (i = 0; i < vfs_cap; i++) {
            const char *suffix;
            if (!files[i].used || &files[i] == f) continue;
            if (strncmp(files[i].name, absa, alen) || files[i].name[alen] != '/')
                continue;
            suffix = files[i].name + alen;
            strcpy(tmp, absb);
            strcat(tmp, suffix);
            strcpy(files[i].name, tmp);
        }
    }
    strcpy(f->name, absb);
    return 0;
}

static NFile *nf(FILE *fp) { return (NFile *)fp; }
FILE *fopen(const char *name, const char *mode)
{
    int i, fd;
    int flags = 0;
    if (strchr(mode, 'w')) flags = O_CREAT | O_WRONLY | O_TRUNC;
    else if (strchr(mode, 'a')) flags = O_CREAT | O_WRONLY;
    else flags = O_RDONLY;
    fd = open(name, flags, 0666);
    if (fd < 0) return 0;
    for (i = 0; i < MAXSTREAMS; i++) {
        if (!streams[i].fd && !streams[i].is_err) {
            streams[i].fd = fd; streams[i].is_err = 0; streams[i].eof = 0;
            return (FILE *)&streams[i];
        }
    }
    close(fd);
    return 0;
}
FILE *fdopen(int fd, const char *mode) { (void)mode; (void)fd; return 0; }
int fclose(FILE *fp)
{
    NFile *f = nf(fp);
    if (f == &f_stdout || f == &f_stderr) return 0;
    if (f->fd > 0) close(f->fd);
    f->fd = 0;
    return 0;
}
size_t fread(void *buf, size_t sz, size_t n, FILE *fp)
{
    NFile *f = nf(fp);
    ssize_t r = read(f->fd, buf, sz * n);
    if (r < 0) return 0;
    if ((size_t)r < sz * n) f->eof = 1;
    return r / sz;
}
size_t fwrite(const void *buf, size_t sz, size_t n, FILE *fp)
{
    NFile *f = nf(fp);
    ssize_t r;
    int fd = (f == &f_stdout) ? 1 : (f == &f_stderr) ? 2 : f->fd;
    r = write(fd, buf, sz * n);
    return r < 0 ? 0 : r / sz;
}
int fgetc(FILE *fp)
{
    unsigned char c;
    if (fread(&c, 1, 1, fp) != 1) return EOF;
    return c;
}
int getc(FILE *fp) { return fgetc(fp); }
int getchar(void) { return fgetc(stdin); }
int fputc(int c, FILE *fp) { unsigned char x = (unsigned char)c; return fwrite(&x, 1, 1, fp) == 1 ? c : EOF; }
int putc(int c, FILE *fp) { return fputc(c, fp); }
int putchar(int c) { return fputc(c, stdout); }
char *fgets(char *s, int n, FILE *fp)
{
    int i = 0, c;
    if (n <= 0) return 0;
    while (i < n - 1 && (c = fgetc(fp)) != EOF) {
        s[i++] = (char)c;
        if (c == '\n') break;
    }
    s[i] = 0;
    return i ? s : 0;
}
int fputs(const char *s, FILE *fp) { return fwrite(s, 1, strlen(s), fp) == strlen(s) ? 0 : EOF; }
int puts(const char *s) { return fputs(s, stdout) < 0 ? EOF : fputc('\n', stdout); }
int fseek(FILE *fp, long off, int whence) { return lseek(nf(fp)->fd, off, whence) < 0 ? -1 : 0; }
long ftell(FILE *fp) { return lseek(nf(fp)->fd, 0, SEEK_CUR); }
int feof(FILE *fp) { return nf(fp)->eof; }
int ferror(FILE *fp) { (void)fp; return 0; }
void clearerr(FILE *fp) { nf(fp)->eof = 0; }
int fileno(FILE *fp) { return nf(fp)->fd; }
int fflush(FILE *fp) { (void)fp; return 0; }

/* ---------------------------------------------------------------- printf */
typedef struct { char *buf; unsigned cap, len; } Out;
static void oc(Out *o, int c)
{
    if (o->len + 1 < o->cap) o->buf[o->len] = (char)c;
    o->len++;
}
static void os(Out *o, const char *s) { while (*s) oc(o, *s++); }
static void onum(Out *o, unsigned long long v, int base, int width, int zero, int upper)
{
    char tmp[32]; int n = 0, i;
    const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    if (!v) tmp[n++] = '0';
    while (v) { tmp[n++] = dig[v % base]; v /= base; }
    for (i = n; i < width; i++) oc(o, zero ? '0' : ' ');
    while (n) oc(o, tmp[--n]);
}
static void oprintf(Out *o, const char *fmt, va_list ap)
{
    while (*fmt) {
        int width = 0, zero = 0, left = 0, lng = 0, prec = -1;
        if (*fmt != '%') { oc(o, *fmt++); continue; }
        fmt++;
        if (*fmt == '-') { left = 1; fmt++; }
        if (*fmt == '0') { zero = 1; fmt++; }
        while (isdigit((unsigned char)*fmt)) width = width * 10 + (*fmt++ - '0');
        if (*fmt == '.') { fmt++; prec = 0; while (isdigit((unsigned char)*fmt)) prec = prec * 10 + (*fmt++ - '0'); }
        while (*fmt == 'l') { lng++; fmt++; }
        if (*fmt == 'z') { lng = 2; fmt++; }
        if (*fmt == 'h') { fmt++; if (*fmt == 'h') fmt++; }
        switch (*fmt++) {
        case 'd': case 'i': {
            long long v = lng ? va_arg(ap, long long) : (long long)va_arg(ap, int);
            unsigned long long u;
            if (v < 0) { oc(o, '-'); u = (unsigned long long)(-v); }
            else u = (unsigned long long)v;
            onum(o, u, 10, width, zero, 0);
            break;
        }
        case 'u': {
            unsigned long long v = lng ? va_arg(ap, unsigned long long) : (unsigned long long)va_arg(ap, unsigned);
            onum(o, v, 10, width, zero, 0); break;
        }
        case 'x': case 'X': {
            unsigned long long v = lng ? va_arg(ap, unsigned long long) : (unsigned long long)va_arg(ap, unsigned);
            onum(o, v, 16, width, zero, *fmt == 'X' || fmt[-1] == 'X'); break;
        }
        case 'o': {
            unsigned long long v = lng ? va_arg(ap, unsigned long long) : (unsigned long long)va_arg(ap, unsigned);
            onum(o, v, 8, width, zero, 0); break;
        }
        case 'p': {
            unsigned long long v = (unsigned long long)(uintptr_t)va_arg(ap, void *);
            oc(o, '0'); oc(o, 'x'); onum(o, v, 16, 8, 1, 0); break;
        }
        case 'c': oc(o, va_arg(ap, int)); break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            int n = 0;
            if (!s) s = "(null)";
            while (s[n] && (prec < 0 || n < prec)) n++;
            if (!left) for (; n < width; width--) oc(o, ' ');
            while (n--) oc(o, *s++);
            break;
        }
        case 'f': case 'e': case 'g': {
            double d = va_arg(ap, double);
            long long ip = (long long)d;
            double frac = d - (double)ip;
            int i;
            if (frac < 0.0) frac = -frac;
            if (ip < 0) { oc(o, '-'); ip = -ip; }
            onum(o, (unsigned long long)ip, 10, 0, 0, 0);
            oc(o, '.');
            for (i = 0; i < 6; i++) { frac *= 10.0; }
            onum(o, (unsigned long long)frac, 10, 6, 1, 0);
            break;
        }
        case '%': oc(o, '%'); break;
        default: oc(o, '%'); oc(o, fmt[-1]); break;
        }
    }
}
int vsnprintf(char *buf, size_t n, const char *fmt, va_list ap)
{
    Out o; o.buf = buf; o.cap = n; o.len = 0;
    oprintf(&o, fmt, ap);
    if (n) buf[o.len < n ? o.len : n - 1] = 0;
    return o.len;
}
int snprintf(char *buf, size_t n, const char *fmt, ...)
{
    va_list ap; int r;
    va_start(ap, fmt); r = vsnprintf(buf, n, fmt, ap); va_end(ap);
    return r;
}
int vsprintf(char *buf, const char *fmt, va_list ap) { return vsnprintf(buf, 0xFFFFFFFFu, fmt, ap); }
int sprintf(char *buf, const char *fmt, ...)
{
    va_list ap; int r;
    va_start(ap, fmt); r = vsprintf(buf, fmt, ap); va_end(ap);
    return r;
}
static int vout(FILE *fp, const char *fmt, va_list ap)
{
    char tmp[1024];
    int r = vsnprintf(tmp, sizeof tmp, fmt, ap);
    if (r > 0) fwrite(tmp, 1, r < (int)sizeof tmp ? r : (int)sizeof tmp - 1, fp);
    return r;
}
int vfprintf(FILE *fp, const char *fmt, va_list ap) { return vout(fp, fmt, ap); }
int vprintf(const char *fmt, va_list ap) { return vout(stdout, fmt, ap); }
int fprintf(FILE *fp, const char *fmt, ...)
{
    va_list ap; int r;
    va_start(ap, fmt); r = vout(fp, fmt, ap); va_end(ap);
    return r;
}
int printf(const char *fmt, ...)
{
    va_list ap; int r;
    va_start(ap, fmt); r = vout(stdout, fmt, ap); va_end(ap);
    return r;
}
int scanf(const char *fmt, ...) { (void)fmt; return 0; }
int sscanf(const char *s, const char *fmt, ...) { (void)s; (void)fmt; return 0; }
int fscanf(FILE *fp, const char *fmt, ...) { (void)fp; (void)fmt; return 0; }

/* ---------------------------------------------------------------- system */
int stat(const char *name, struct stat *st)
{
    char abs[VFS_NAME_MAX];
    MemFile *f;
    if (vfs_abspath(name, abs) < 0) return -1;
    f = mf_find(abs);
    if (!f) {
        if (!mf_isdir_name(abs)) { errno = ENOENT; return -1; }
        memset(st, 0, sizeof *st);
        st->st_mode = S_IFDIR | 0755;
        st->st_nlink = 2;
        return 0;
    }
    memset(st, 0, sizeof *st);
    st->st_size = f->isdir ? 0 : (long)f->size;
    st->st_mode = f->isdir ? (S_IFDIR | 0755) : (S_IFREG | (f->writable ? 0644 : 0444));
    st->st_nlink = f->isdir ? 2 : 1;
    return 0;
}
int fstat(int fd, struct stat *st)
{
    if (fd < FD_VFS_BASE || (unsigned)(fd - FD_VFS_BASE) >= vfs_cap) return -1;
    memset(st, 0, sizeof *st);
    st->st_size = files[fd - FD_VFS_BASE].size;
    st->st_mode = files[fd - FD_VFS_BASE].isdir
        ? (S_IFDIR | 0755) : (S_IFREG | 0644);
    return 0;
}
int mkdir(const char *name, mode_t mode)
{
    char abs[VFS_NAME_MAX];
    MemFile *f;
    (void)mode;
    if (vfs_abspath(name, abs) < 0) return -1;
    if (mf_find(abs) || mf_isdir_name(abs)) { errno = EEXIST; return -1; }
    f = mf_new(abs);
    if (!f) { errno = ENOSPC; return -1; }
    f->isdir = 1;
    f->writable = 0;
    return 0;
}
char *getcwd(char *buf, size_t n)
{
    if (!buf || n <= strlen(vfs_cwd)) { errno = ERANGE; return 0; }
    strcpy(buf, vfs_cwd);
    return buf;
}
int chdir(const char *p)
{
    char abs[VFS_NAME_MAX];
    if (vfs_abspath(p, abs) < 0) return -1;
    if (!mf_isdir_name(abs)) { errno = ENOENT; return -1; }
    strcpy(vfs_cwd, abs);
    return 0;
}
int access(const char *p, int m)
{
    char abs[VFS_NAME_MAX];
    MemFile *f;
    if (vfs_abspath(p, abs) < 0) return -1;
    f = mf_find(abs);
    if (!f) return mf_isdir_name(abs) ? 0 : -1;
    if ((m & W_OK) && !f->writable) { errno = EACCES; return -1; }
    return 0;
}
int isatty(int fd) { (void)fd; return 0; }
int getpid(void) { return 1; }
char *realpath(const char *p, char *out)
{
    char abs[VFS_NAME_MAX], *r = out;
    if (vfs_abspath(p, abs) < 0) return 0;
    if (!r) r = (char *)malloc(strlen(abs) + 1);
    if (!r) { errno = ENOMEM; return 0; }
    strcpy(r, abs);
    return r;
}
void *mmap(void *a, size_t n, int p, int f, int fd, off_t o)
{
    (void)a; (void)n; (void)p; (void)f; (void)o;
    if (fd >= FD_VFS_BASE && (unsigned)(fd - FD_VFS_BASE) < vfs_cap && files[fd - FD_VFS_BASE].used)
        return files[fd - FD_VFS_BASE].data;
    return (void *)-1;
}
int munmap(void *a, size_t n) { (void)a; (void)n; return 0; }
/* The runner publishes monotonic time and executed steps at guest byte
   0x03EFF010 (ms, steps low, steps high).  The x86_64/S1 kernel must publish
   the same block. */
static unsigned nan16_now_ms(void)
{
    return *(volatile unsigned *)0x03EFF010u;
}
static long days_from_civil(int y, unsigned m, unsigned d)
{
    long era, yoe, doy, doe;
    y -= m <= 2;
    era = (y >= 0 ? y : y - 399) / 400;
    yoe = y - era * 400;
    doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}
static void civil_from_days(long z, int *yy, int *mm, int *dd)
{
    long era;
    unsigned doe, yoe, doy, mp, d, m;
    int y;
    z += 719468;
    era = (z >= 0 ? z : z - 146096) / 146097;
    doe = (unsigned)(z - era * 146097);
    yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    y = (int)(yoe + era * 400);
    doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    mp = (5 * doy + 2) / 153;
    d = doy - (153 * mp + 2) / 5 + 1;
    m = mp + (mp < 10 ? 3 : (unsigned)-9);
    y += (m <= 2);
    *yy = y; *mm = (int)m; *dd = (int)d;
}
static struct tm *tm_from_time(time_t t)
{
    static struct tm out;
    long days = (long)(t / 86400);
    long rem = (long)(t % 86400);
    int y, m, d;
    if (rem < 0) { rem += 86400; days--; }
    civil_from_days(days, &y, &m, &d);
    out.tm_sec = (int)(rem % 60);
    out.tm_min = (int)((rem / 60) % 60);
    out.tm_hour = (int)(rem / 3600);
    out.tm_mday = d;
    out.tm_mon = m - 1;
    out.tm_year = y - 1900;
    out.tm_wday = (int)((days + 4) % 7);
    if (out.tm_wday < 0) out.tm_wday += 7;
    out.tm_yday = (int)(days - days_from_civil(y, 1, 1));
    out.tm_isdst = 0;
    return &out;
}
int gettimeofday(struct timeval *tv, void *tz)
{
    unsigned ms = nan16_now_ms();
    (void)tz;
    if (tv) { tv->tv_sec = (long)(ms / 1000u); tv->tv_usec = (long)(ms % 1000u) * 1000L; }
    return 0;
}
time_t time(time_t *t)
{
    time_t s = (time_t)(nan16_now_ms() / 1000u);
    if (t) *t = s;
    return s;
}
clock_t clock(void) { return (clock_t)(nan16_now_ms() * 1000u); }
int clock_gettime(clockid_t id, struct timespec *ts)
{
    unsigned ms = nan16_now_ms();
    (void)id;
    if (!ts) { errno = EINVAL; return -1; }
    ts->tv_sec = (long)(ms / 1000u);
    ts->tv_nsec = (long)(ms % 1000u) * 1000000L;
    return 0;
}
int nanosleep(const struct timespec *req, struct timespec *rem)
{
    unsigned target, now;
    if (!req) { errno = EINVAL; return -1; }
    target = nan16_now_ms() + (unsigned)(req->tv_sec * 1000L + req->tv_nsec / 1000000L)
           + (req->tv_nsec % 1000000L ? 1u : 0u);
    do { now = nan16_now_ms(); } while (now < target);
    if (rem) { rem->tv_sec = 0; rem->tv_nsec = 0; }
    return 0;
}
struct tm *localtime(const time_t *t) { return tm_from_time(t ? *t : time(0)); }
struct tm *gmtime(const time_t *t) { return tm_from_time(t ? *t : time(0)); }
int setjmp(jmp_buf b) { (void)b; return 0; }
void longjmp(jmp_buf b, int v) { (void)b; (void)v; exit(1); }
int sem_init(sem_t *s, int p, unsigned v) { (void)p; s->v = v; return 0; }
int sem_wait(sem_t *s) { (void)s; return 0; }
int sem_post(sem_t *s) { (void)s; return 0; }
int sem_destroy(sem_t *s) { (void)s; return 0; }
void *dlopen(const char *f, int m) { (void)f; (void)m; return 0; }
void *dlsym(void *h, const char *s) { (void)h; (void)s; return 0; }
int dlclose(void *h) { (void)h; return 0; }
char *dlerror(void) { return (char *)"no dynamic loader"; }
int glob(const char *p, int f, int (*e)(const char *, int), glob_t *g) { (void)p; (void)f; (void)e; (void)g; return GLOB_NOMATCH; }
void globfree(glob_t *g) { (void)g; }
int setvbuf(FILE *fp, char *b, int m, size_t s) { (void)fp; (void)b; (void)m; (void)s; return 0; }
void setbuf(FILE *fp, char *b) { (void)fp; (void)b; }

/* ---------------------------------------------------------------- math */
double ldexp(double x, int e)
{
    while (e > 0) { x = x * 2.0; e--; }
    while (e < 0) { x = x * 0.5; e++; }
    return x;
}
long double ldexpl(long double x, int e) { return (long double)ldexp((double)x, e); }
double frexp(double x, int *e)
{
    int n = 0;
    double a = x;
    if (a < 0) a = -a;
    if (a == 0.0) { if (e) *e = 0; return x; }
    while (a >= 1.0) { a = a * 0.5; n++; }
    while (a < 0.5) { a = a * 2.0; n--; }
    if (e) *e = n;
    return x < 0 ? -a : a;
}
long double frexpl(long double x, int *e) { return (long double)frexp((double)x, e); }
double fabs(double x) { return x < 0 ? -x : x; }
long double fabsl(long double x) { return x < 0 ? -x : x; }
double floor(double x)
{
    long long i;
    if (x >= 9223372036854775808.0 || x < -9223372036854775808.0) return x;
    i = (long long)x;
    if ((double)i > x) i--;
    return (double)i;
}
double ceil(double x)
{
    long long i;
    if (x >= 9223372036854775808.0 || x < -9223372036854775808.0) return x;
    i = (long long)x;
    if ((double)i < x) i++;
    return (double)i;
}
double fmod(double a, double b)
{
    long long q;
    if (b == 0.0) return 0.0;
    if (a >= 9223372036854775808.0 || a < -9223372036854775808.0)
        return 0.0;
    q = (long long)(a / b);
    return a - (double)q * b;
}
double sqrt(double x)
{
    double r, last;
    if (x <= 0.0) return x == 0.0 ? 0.0 : 0.0 / 0.0;
    r = x > 1.0 ? x : 1.0;
    last = 0.0;
    while (r != last) { last = r; r = (r + x / r) * 0.5; }
    return r;
}

#define NAN16_PI    3.14159265358979323846
#define NAN16_PIO2  1.57079632679489661923
#define NAN16_PIO4  0.78539816339744830962
#define NAN16_LN2   0.69314718055994530942
#define NAN16_ILN2  1.44269504088896340736
#define NAN16_SQ1_2 0.70710678118654752440
#define NAN16_LN10  2.30258509299404568402

double trunc(double x)
{
    if (x >= 9223372036854775808.0 || x < -9223372036854775808.0) return x;
    return (double)(long long)x;
}
double round(double x)
{
    if (x >= 0.0) return floor(x + 0.5);
    return ceil(x - 0.5);
}
double copysign(double x, double y)
{
    union { double d; unsigned long long u; } v;
    v.d = fabs(x);
    if (y < 0.0 || (y == 0.0 && 1.0 / y < 0.0))
        v.u |= 0x8000000000000000ULL;
    return v.d;
}
double exp(double x)
{
    int k;
    double r, r2, p;
    if (x != x) return x;
    if (x > 709.782712893384) return 1.0 / 0.0;
    if (x < -745.133219101941) return 0.0;
    k = (int)floor(x * NAN16_ILN2 + (x >= 0.0 ? 0.5 : -0.5));
    r = x - (double)k * NAN16_LN2;
    r2 = r * r;
    p = 1.0 + r + r2 * (0.5 + r * (0.16666666666666666 +
        r * (0.041666666666666664 + r * (0.008333333333333333 +
        r * (0.001388888888888889 + r * (0.0001984126984126984 +
        r * (0.0000248015873015873 + r * (0.0000027557319223985893 +
        r * (0.0000002755731922398589 + r * (0.00000002505210838544172 +
        r * 0.00000000208767569878681))))))))));
    return ldexp(p, k);
}
double log(double x)
{
    int e, n, neg = 0;
    double m, z, z2, term, sum;
    if (x != x) return x;
    if (x < 0.0) return 0.0 / 0.0;
    if (x == 0.0) return -1.0 / 0.0;
    if (x == 1.0) return 0.0;
    if (x < 1.0) { x = 1.0 / x; neg = 1; }
    m = frexp(x, &e);
    if (m < NAN16_SQ1_2) { m *= 2.0; e--; }
    z = (m - 1.0) / (m + 1.0);
    z2 = z * z;
    sum = 1.0;
    term = 1.0;
    for (n = 3; n <= 41; n += 2) {
        term *= z2;
        sum += term / (double)n;
    }
    sum = 2.0 * z * sum + (double)e * NAN16_LN2;
    return neg ? -sum : sum;
}
double log10(double x) { return log(x) / NAN16_LN10; }
double log2(double x) { return log(x) / NAN16_LN2; }
double pow(double x, double y)
{
    double ax, r;
    long long n;
    int isint;
    if (y == 0.0) return 1.0;
    if (x == 1.0) return 1.0;
    if (y == 1.0) return x;
    n = (long long)y;
    isint = ((double)n == y && y < 9007199254740992.0 && y > -9007199254740992.0);
    if (x == 0.0) {
        if (y < 0.0) return 1.0 / 0.0;
        return 0.0;
    }
    if (x < 0.0 && !isint) return 0.0 / 0.0;
    ax = x < 0.0 ? -x : x;
    r = exp(y * log(ax));
    if (x < 0.0 && (n & 1)) r = -r;
    return r;
}
static void sin_cos(double x, double *sp, double *cp)
{
    double y, r, r2, s, c;
    int q;
    y = fmod(x, 2.0 * NAN16_PI);
    if (y > NAN16_PI) y -= 2.0 * NAN16_PI;
    if (y < -NAN16_PI) y += 2.0 * NAN16_PI;
    q = (int)floor(y / NAN16_PIO2 + 0.5);
    r = y - (double)q * 1.5707963267948966 - (double)q * 6.123233995736766e-17;
    r2 = r * r;
    s = r * (1.0 + r2 * (-0.16666666666666666 + r2 *
        (0.008333333333333333 + r2 * (-0.0001984126984126984 + r2 *
        (0.0000027557319223985893 + r2 * (-0.00000002505210838544172 +
        r2 * 0.00000000016059043836821615))))));
    c = 1.0 + r2 * (-0.5 + r2 * (0.041666666666666664 + r2 *
        (-0.001388888888888889 + r2 * (0.0000248015873015873 + r2 *
        (-0.0000002755731922398589 + r2 * 0.00000000208767569878681)))));
    q = ((q % 4) + 4) % 4;
    if (q == 0) { *sp = s; *cp = c; }
    else if (q == 1) { *sp = c; *cp = -s; }
    else if (q == 2) { *sp = -s; *cp = -c; }
    else { *sp = -c; *cp = s; }
}
double sin(double x) { double s, c; sin_cos(x, &s, &c); return s; }
double cos(double x) { double s, c; sin_cos(x, &s, &c); return c; }
double tan(double x) { double s, c; sin_cos(x, &s, &c); return s / c; }
static double atan_small(double z)
{
    double z2 = z * z, term = z, sum = z;
    int n;
    for (n = 3; n <= 49; n += 2) {
        term *= -z2;
        sum += term / (double)n;
    }
    return sum;
}
double atan(double x)
{
    if (x != x) return x;
    if (x < 0.0) return -atan(-x);
    if (x > 1.0) return NAN16_PIO2 - atan_small(1.0 / x);
    if (x > 0.4142135623730950)
        return NAN16_PIO4 + atan_small((x - 1.0) / (x + 1.0));
    return atan_small(x);
}
double atan2(double y, double x)
{
    if (x > 0.0) return atan(y / x);
    if (x < 0.0) return y >= 0.0 ? atan(y / x) + NAN16_PI
                                 : atan(y / x) - NAN16_PI;
    if (y > 0.0) return NAN16_PIO2;
    if (y < 0.0) return -NAN16_PIO2;
    return 0.0;
}
double asin(double x)
{
    if (x > 1.0 || x < -1.0) return 0.0 / 0.0;
    return atan2(x, sqrt(1.0 - x * x));
}
double acos(double x)
{
    if (x > 1.0 || x < -1.0) return 0.0 / 0.0;
    return atan2(sqrt(1.0 - x * x), x);
}
double sinh(double x)
{
    double e = exp(x);
    return (e - 1.0 / e) * 0.5;
}
double cosh(double x)
{
    double e = exp(x);
    return (e + 1.0 / e) * 0.5;
}
double tanh(double x)
{
    double e;
    if (x > 20.0) return 1.0;
    if (x < -20.0) return -1.0;
    e = exp(2.0 * x);
    return (e - 1.0) / (e + 1.0);
}
double modf(double x, double *iptr)
{
    double ip = trunc(x);
    if (iptr) *iptr = ip;
    return x - ip;
}
int isnan(double x) { return x != x; }
int isinf(double x) { return x > 1.7976931348623157e308 || x < -1.7976931348623157e308; }