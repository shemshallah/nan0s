/* vfs_capacity.c - large N16PACK1 registration and directive checks.
 *
 * Non-capped build (default):
 *   - NAN16_VFS_INIT_CAP=2 forces repeated table growth.
 *   - register VFS_TEST_COUNT (5000) files, then read first/last back.
 * Capped build (-DVFS_TEST_EXPECT_FAIL -DNAN16_VFS_MAXFILES=4096):
 *   - the same 5000-file pack must be refused without registering anything.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int nan16_vfs_add_pack(const void *, unsigned);
extern int nan16_vfs_get(const char *, unsigned char **, unsigned *);
extern unsigned nan16_vfs_count(void);

#ifndef VFS_TEST_COUNT
#define VFS_TEST_COUNT 5000u
#endif

static void w16(unsigned char *p, unsigned v)
{
    p[0] = (unsigned char)v;
    p[1] = (unsigned char)(v >> 8);
}

static void w32(unsigned char *p, unsigned v)
{
    p[0] = (unsigned char)v;
    p[1] = (unsigned char)(v >> 8);
    p[2] = (unsigned char)(v >> 16);
    p[3] = (unsigned char)(v >> 24);
}

static void make_name(char *out, unsigned i)
{
    snprintf(out, 32, "/vfs/%05u", i);
}

int main(void)
{
    unsigned count = VFS_TEST_COUNT, i, k, off, len, nl;
    unsigned char *pack, *p, *data;
    unsigned size;
    char name[32];
    int added;

    len = 12u;
    for (i = 0; i < count; i++) {
        make_name(name, i);
        len += 8u + (unsigned)strlen(name) + 1u + 8u;
    }
    pack = (unsigned char *)malloc(len);
    if (!pack) return 1;

    memcpy(pack, "N16PACK1", 8);
    w32(pack + 8, count);
    off = 12;
    for (i = 0; i < count; i++) {
        make_name(name, i);
        nl = (unsigned)strlen(name) + 1u;
        p = pack + off;
        w16(p, nl);
        w16(p + 2, 0);
        w32(p + 4, 8);
        memcpy(p + 8, name, nl);
        for (k = 0; k < 8; k++)
            p[8 + nl + k] = (unsigned char)(i >> (8u * (k & 3u)));
        off += 8u + nl + 8u;
    }
    if (off != len) return 2;

    added = nan16_vfs_add_pack(pack, len);
    printf("add=%d\n", added);
    printf("count=%u\n", nan16_vfs_count());

#ifdef VFS_TEST_EXPECT_FAIL
    if (added >= 0 || nan16_vfs_count() != 0) return 3;
    printf("capped=1\n");
    return 0;
#else
    if (added != (int)count || nan16_vfs_count() != count) return 3;

    make_name(name, 0);
    if (nan16_vfs_get(name, &data, &size) < 0 || size != 8) return 4;
    printf("first=%u:%02x\n", size, data[0]);

    make_name(name, count - 1u);
    if (nan16_vfs_get(name, &data, &size) < 0 || size != 8) return 5;
    printf("last=%u", size);
    for (k = 0; k < 8; k++) printf(":%02x", data[k]);
    printf("\n");

    free(pack);
    return 0;
#endif
}
