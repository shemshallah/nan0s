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
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <math.h>
#include <semaphore.h>
#include <glob.h>

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
extern long long __nan16_d2ll(unsigned long long);
extern unsigned long long __nan16_ddiv(unsigned long long, unsigned long long);

double strtod(const char *s, char **end)
{
    unsigned long long mant = 0;
    int neg = 0, any = 0, exp = 0, edig = 0, esign = 1, i;
    unsigned long long d = __nan16_i2d(0);
    unsigned long long ten = __nan16_ll2d(10);
    while (isspace((unsigned char)*s)) s++;
    if (*s == '+' || *s == '-') { neg = *s == '-'; s++; }
    while (isdigit((unsigned char)*s)) { mant = mant * 10 + (*s - '0'); any = 1; s++; }
    if (*s == '.') {
        s++;
        while (isdigit((unsigned char)*s)) {
            if (mant < 100000000000000000ULL) { mant = mant * 10 + (*s - '0'); exp--; }
            any = 1; s++;
        }
    }
    if (any && (*s == 'e' || *s == 'E')) {
        s++;
        if (*s == '+' || *s == '-') { esign = *s == '+'; s++; }
        while (isdigit((unsigned char)*s)) { edig = edig * 10 + (*s - '0'); s++; }
        exp += esign ? edig : -edig;
    }
    if (end) *end = (char *)s;
    if (!any) return 0.0;
    d = __nan16_ll2d((long long)mant);
    if (exp > 0) { for (i = 0; i < exp; i++) d = __nan16_dmul(d, ten); }
    else if (exp < 0) { for (i = 0; i < -exp; i++) d = __nan16_ddiv(d, ten); }
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

static char *envp[] = { 0 };
char *getenv(const char *name)
{
    unsigned i = 0;
    (void)name;
    while (envp[i]) {
        if (!strncmp(envp[i], name, strlen(name)) && envp[i][strlen(name)] == '=')
            return envp[i] + strlen(name) + 1;
        i++;
    }
    return 0;
}

int nan16_exit_code;
void exit(int code) { nan16_exit_code = code; for (;;) ; }
void _Exit(int code) { exit(code); }
void abort(void) { exit(134); }
int atexit(void (*fn)(void)) { (void)fn; return 0; }
int system(const char *s) { (void)s; return 0; }

/* ---------------------------------------------------------------- stdio/VFS */
#define MAXFILES 64
#define MAXSTREAMS 16
#define FD_VFS_BASE 3
typedef struct MemFile {
    char name[64];
    unsigned char *data;
    unsigned size, cap, pos;
    int used, writable;
} MemFile;
static MemFile files[MAXFILES];

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

static MemFile *mf_find(const char *name)
{
    int i;
    for (i = 0; i < MAXFILES; i++)
        if (files[i].used && !strcmp(files[i].name, name)) return &files[i];
    return 0;
}
static MemFile *mf_new(const char *name)
{
    int i;
    for (i = 0; i < MAXFILES; i++) {
        if (!files[i].used) {
            files[i].used = 1;
            strncpy(files[i].name, name, 63);
            files[i].name[63] = 0;
            files[i].data = 0; files[i].size = files[i].cap = files[i].pos = 0;
            files[i].writable = 1;
            return &files[i];
        }
    }
    return 0;
}
int nan16_vfs_add(const char *name, const void *data, unsigned size)
{
    MemFile *f = mf_find(name);
    if (!f) f = mf_new(name);
    if (!f) return -1;
    f->data = malloc(size);
    if (!f->data) return -1;
    memcpy(f->data, data, size);
    f->size = f->cap = size;
    f->pos = 0; f->writable = 0;
    return 0;
}
int nan16_vfs_get(const char *name, unsigned char **data, unsigned *size)
{
    MemFile *f = mf_find(name);
    if (!f) return -1;
    *data = f->data; *size = f->size;
    return 0;
}

int open(const char *name, int flags, ...)
{
    MemFile *f = mf_find(name);
    int i;
    if (!f) {
        if (!(flags & O_CREAT)) return -1;
        f = mf_new(name);
        if (!f) return -1;
    }
    if (flags & O_TRUNC) { f->size = 0; f->pos = 0; }
    for (i = 0; i < MAXFILES; i++)
        if (&files[i] == f) { f->pos = 0; return i + FD_VFS_BASE; }
    return -1;
}
int creat(const char *name, int mode) { (void)mode; return open(name, O_CREAT | O_WRONLY | O_TRUNC); }
int close(int fd)
{
    if (fd >= FD_VFS_BASE && fd < FD_VFS_BASE + MAXFILES) files[fd - FD_VFS_BASE].pos = 0;
    return 0;
}
ssize_t read(int fd, void *buf, size_t n)
{
    MemFile *f;
    unsigned avail;
    if (fd < FD_VFS_BASE || fd >= FD_VFS_BASE + MAXFILES) return -1;
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
        return n;
    }
    if (fd < FD_VFS_BASE || fd >= FD_VFS_BASE + MAXFILES) return -1;
    f = &files[fd - FD_VFS_BASE];
    if (!f->used) return -1;
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
    if (fd < FD_VFS_BASE || fd >= FD_VFS_BASE + MAXFILES) return -1;
    f = &files[fd - FD_VFS_BASE];
    if (!f->used) return -1;
    if (whence == SEEK_SET) np = off;
    else if (whence == SEEK_CUR) np = (long)f->pos + off;
    else np = (long)f->size + off;
    if (np < 0) np = 0;
    f->pos = (unsigned)np;
    return np;
}
int unlink(const char *name)
{
    MemFile *f = mf_find(name);
    if (!f) return -1;
    if (f->data) free(f->data);
    f->used = 0;
    return 0;
}
int remove(const char *name) { return unlink(name); }
int rename(const char *a, const char *b)
{
    MemFile *f = mf_find(a);
    if (!f) return -1;
    strncpy(f->name, b, 63); f->name[63] = 0;
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
    MemFile *f = mf_find(name);
    if (!f) return -1;
    memset(st, 0, sizeof *st);
    st->st_size = f->size;
    st->st_mode = S_IFREG | 0644;
    return 0;
}
int fstat(int fd, struct stat *st)
{
    if (fd < FD_VFS_BASE || fd >= FD_VFS_BASE + MAXFILES) return -1;
    memset(st, 0, sizeof *st);
    st->st_size = files[fd - FD_VFS_BASE].size;
    st->st_mode = S_IFREG | 0644;
    return 0;
}
int mkdir(const char *name, mode_t mode) { (void)name; (void)mode; return 0; }
char *getcwd(char *buf, size_t n) { if (n) { strncpy(buf, "/", n); buf[n - 1] = 0; } return buf; }
int chdir(const char *p) { (void)p; return 0; }
int access(const char *p, int m) { (void)m; return mf_find(p) ? 0 : -1; }
int isatty(int fd) { (void)fd; return 0; }
int getpid(void) { return 1; }
char *realpath(const char *p, char *out) { if (out) { strcpy(out, p); return out; } return strdup(p); }
void *mmap(void *a, size_t n, int p, int f, int fd, off_t o)
{
    (void)a; (void)n; (void)p; (void)f; (void)o;
    if (fd >= FD_VFS_BASE && fd < FD_VFS_BASE + MAXFILES && files[fd - FD_VFS_BASE].used)
        return files[fd - FD_VFS_BASE].data;
    return (void *)-1;
}
int munmap(void *a, size_t n) { (void)a; (void)n; return 0; }
int gettimeofday(struct timeval *tv, void *tz) { (void)tz; if (tv) { tv->tv_sec = 0; tv->tv_usec = 0; } return 0; }
time_t time(time_t *t) { if (t) *t = 0; return 0; }
clock_t clock(void) { return 0; }
struct tm *localtime(const time_t *t) { (void)t; return 0; }
struct tm *gmtime(const time_t *t) { (void)t; return 0; }
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
    long long i = (long long)x;
    if ((double)i > x) i--;
    return (double)i;
}
double ceil(double x)
{
    long long i = (long long)x;
    if ((double)i < x) i++;
    return (double)i;
}
double fmod(double a, double b)
{
    long long q;
    if (b == 0.0) return 0.0;
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
double pow(double x, double y)
{
    long long n = (long long)y;
    double r = 1.0;
    int neg = 0;
    if ((double)n != y) return 0.0;
    if (n < 0) { neg = 1; n = -n; }
    while (n) { if (n & 1) r = r * x; x = x * x; n >>= 1; }
    return neg ? 1.0 / r : r;
}
int isnan(double x) { return x != x; }
int isinf(double x) { return x > 1.7976931348623157e308 || x < -1.7976931348623157e308; }