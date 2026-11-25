/* vfs_dirs.c - implicit directories, mkdir/rmdir, dirent enumeration. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>

static unsigned char pack[4096];
static unsigned poff = 12;

static void w16(unsigned char *p, unsigned v) { p[0] = (unsigned char)v; p[1] = (unsigned char)(v >> 8); }
static void w32(unsigned char *p, unsigned v)
{
    p[0] = (unsigned char)v; p[1] = (unsigned char)(v >> 8);
    p[2] = (unsigned char)(v >> 16); p[3] = (unsigned char)(v >> 24);
}
static void add(const char *name, const char *data)
{
    unsigned nl = (unsigned)strlen(name) + 1u, dl = (unsigned)strlen(data);
    unsigned char *p = pack + poff;
    w16(p, nl); w16(p + 2, 0); w32(p + 4, dl);
    memcpy(p + 8, name, nl);
    memcpy(p + 8 + nl, data, dl);
    poff += 8 + nl + dl;
}

static void list(const char *path)
{
    DIR *d = opendir(path);
    struct dirent *e;
    int first = 1;
    printf("list %s=", path);
    if (!d) { printf("ERR\n"); return; }
    while ((e = readdir(d)) != 0) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (!first) printf(" ");
        printf("%s%s", e->d_name, e->d_type == DT_DIR ? "/" : "");
        first = 0;
    }
    printf("\n");
    closedir(d);
}

int main(void)
{
    struct stat st;
    int fd, r;

    memcpy(pack, "N16PACK1", 8);
    w32(pack + 8, 3);
    add("/suite/a/one.txt", "1");
    add("/suite/a/two.txt", "22");
    add("/suite/b.txt", "xyz");
    if (poff != 89u) return 1;
    if (nan16_vfs_add_pack(pack, poff) != 3) return 2;

    r = stat("/suite", &st);
    printf("stat suite=%d:%d\n", r == 0, S_ISDIR(st.st_mode));
    r = stat("/suite/a", &st);
    printf("stat a=%d:%d\n", r == 0, S_ISDIR(st.st_mode));
    r = stat("/suite/b.txt", &st);
    printf("stat b=%d:%d:%d\n", r == 0, S_ISREG(st.st_mode), (int)st.st_size);

    printf("access=%d:%d\n", access("/suite/a", R_OK | X_OK),
           access("/suite/b.txt", W_OK));
    list("/suite");
    list("/suite/a");

    printf("mkdir=%d\n", mkdir("/empty", 0755));
    printf("mkdir2=%d\n", mkdir("/empty", 0755));
    list("/empty");
    printf("mkdir-implicit=%d\n", mkdir("/suite/a", 0755));
    printf("rmdir-suite=%d\n", rmdir("/suite"));
    printf("unlink-suite=%d\n", unlink("/suite"));
    printf("rmdir-empty=%d\n", rmdir("/empty"));
    r = stat("/empty", &st);
    printf("absent=%d\n", r != 0);

    mkdir("/empty", 0755);
    fd = open("/empty/x", O_CREAT | O_WRONLY, 0644);
    printf("create=%d\n", fd >= 0);
    if (fd >= 0) { write(fd, "hi", 2); close(fd); }
    printf("rmdir-full=%d\n", rmdir("/empty"));
    printf("unlink-x=%d\n", unlink("/empty/x"));
    printf("rmdir-empty2=%d\n", rmdir("/empty"));
    printf("count=%u\n", nan16_vfs_count());
    printf("VFS DIRS PASS\n");
    return 0;
}
