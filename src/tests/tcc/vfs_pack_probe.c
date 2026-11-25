/* vfs_pack_probe.c - byte-level N16PACK1 guest VFS check.
 *
 * The gate places this program's pack at GUEST_PACK_BASE.  Every byte of a
 * 256-byte binary pattern, a non-ASCII blob, and a 3-byte text file is read
 * back through open()/read() and compared.  It also checks libc snprintf
 * '*' width/precision (including negative precision and runtime values).
 */
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include "guest_pack.h"

extern int nan16_vfs_add_pack(const void *, unsigned);
extern unsigned nan16_vfs_count(void);

#ifdef VFS_PACK_MANY
/* Dynamic-VFS capacity test: a real 2,133-file pack.  The last file must be
   registered and readable, and nan16_vfs_count() must reach MANY_COUNT. */
#ifndef MANY_COUNT
#define MANY_COUNT 2133
#endif
#ifndef MANY_I
#define MANY_I 2132
#endif
int main(void)
{
    unsigned char want[5];
    unsigned char buf[8];
    int fd, got, i;
    {
        int rc = nan16_vfs_add_pack((const void *)GUEST_PACK_BASE, GUEST_PACK_LEN);
        *(unsigned *)0x03000000u = (unsigned)rc;
        *(unsigned *)0x03000004u = (unsigned)GUEST_PACK_LEN;
        *(unsigned *)0x03000008u = (unsigned)GUEST_PACK_BASE;
        if (rc < 0)
            return 1;
    }
    if (nan16_vfs_count() < MANY_COUNT)
        return 2;
    *(unsigned *)0x0300000Cu = nan16_vfs_count();
    want[0] = (unsigned char)(MANY_I & 0xFF);
    want[1] = (unsigned char)((MANY_I >> 8) & 0xFF);
    want[2] = 0;
    want[3] = 0;
    want[4] = 0x80;
    fd = open("/many/f2132.bin", O_RDONLY);
    if (fd < 0) return 3;
    got = (int)read(fd, buf, sizeof buf);
    close(fd);
    if (got != 5) return 4;
    for (i = 0; i < 5; i++)
        if (buf[i] != want[i]) return 5;
    *(volatile unsigned *)0x02fffff0u = 1;
    return 0;
}
#else

static const unsigned char nonascii[] = {
    0xde, 0xad, 0xbe, 0xef, 0x00, 0x80, 0xff, 0x7f, 0x0a, 0x0d, 0xc3, 0xa9
};
static const unsigned char small[] = { 'h', 'i', '\n' };

static int check_file(const char *name, const unsigned char *want, unsigned n)
{
    unsigned char buf[512];
    int fd, got, i;
    fd = open(name, O_RDONLY);
    if (fd < 0) return 1;
    got = (int)read(fd, buf, sizeof buf);
    close(fd);
    if (got != (int)n) return 2;
    for (i = 0; i < got; i++)
        if (buf[i] != want[i]) return 3;
    return 0;
}

int main(void)
{
    unsigned char pattern[256];
    char buf[128];
    int i, w, p;

    for (i = 0; i < 256; i++) pattern[i] = (unsigned char)i;
    if (nan16_vfs_add_pack((const void *)GUEST_PACK_BASE, GUEST_PACK_LEN) < 0)
        return 1;
    if (check_file("/test/pattern.bin", pattern, 256)) return 2;
    if (check_file("/test/nonascii.bin", nonascii, sizeof nonascii)) return 3;
    if (check_file("/test/small.txt", small, sizeof small)) return 4;

    i = snprintf(buf, sizeof buf, "[%.*s][%*s]", -1, "abc", 5, "x");
    if (i != 12 || strcmp(buf, "[abc][    x]")) return 5;

    w = 4;
    p = 2;
    i = snprintf(buf, sizeof buf, "[%*.*s]", -w, p, "abcdef");
    if (i != 6 || strcmp(buf, "[ab  ]")) return 6;

    i = snprintf(buf, sizeof buf, "#define %.*s %s\n", 10, "TCC_TARGET_NAN16", "1");
    if (i != 21 || strcmp(buf, "#define TCC_TARGET 1\n")) return 7;

    *(volatile unsigned *)0x02fffff0u = 1;
    return 0;
}

#endif /* VFS_PACK_MANY */
