/* vfs_paths.c - relative paths, cwd, normalization and realpath. */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

static unsigned char pack[512];
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

int main(void)
{
    char cwd[128], abs[128], buf[64];
    struct stat st;
    int fd, r;

    memcpy(pack, "N16PACK1", 8);
    w32(pack + 8, 2);
    add("/suite/a/one.txt", "1");
    add("/suite/b.txt", "xyz");
    if (nan16_vfs_add_pack(pack, poff) != 2) return 1;

    printf("cwd0=%d\n", getcwd(cwd, sizeof cwd) && !strcmp(cwd, "/"));
    printf("chdir1=%d\n", chdir("suite"));
    getcwd(cwd, sizeof cwd); printf("cwd1=%s\n", cwd);
    chdir("a");
    getcwd(cwd, sizeof cwd); printf("cwd2=%s\n", cwd);
    r = stat("one.txt", &st);
    printf("one=%d:%d\n", r == 0, (int)st.st_size);
    r = stat("../b.txt", &st);
    printf("dotdot=%d:%d\n", r == 0, (int)st.st_size);

    printf("abs=%s\n", realpath(".././b.txt", abs));
    printf("access=%d\n", access("../b.txt", R_OK));
    fd = open("../b.txt", O_RDONLY);
    r = fd >= 0 ? (int)read(fd, buf, sizeof buf) : -1;
    if (fd >= 0) close(fd);
    printf("read=%d\n", r == 3 && !memcmp(buf, "xyz", 3));

    printf("mkdir=%d\n", mkdir("tmp", 0755));
    stat("tmp", &st);
    printf("tmpdir=%d\n", S_ISDIR(st.st_mode));
    chdir("tmp");
    getcwd(cwd, sizeof cwd); printf("cwdtmp=%s\n", cwd);
    chdir("..");
    getcwd(cwd, sizeof cwd); printf("up=%s\n", cwd);
    printf("rmtmp=%d\n", rmdir("tmp"));
    printf("bad=%d\n", chdir("/nope"));
    getcwd(cwd, sizeof cwd); printf("final=%s\n", cwd);

    printf("env0=%d\n", getenv("NAN16_X") == 0);
    printf("set=%d\n", setenv("NAN16_X", "one", 1));
    printf("get=%d:%s\n", getenv("NAN16_X") != 0, getenv("NAN16_X"));
    r = setenv("NAN16_X", "two", 0);
    printf("noover=%d:%s\n", r, getenv("NAN16_X"));
    r = setenv("NAN16_X", "two", 1);
    printf("over=%d:%s\n", r, getenv("NAN16_X"));
    unsetenv("NAN16_X");
    printf("unset=%d\n", getenv("NAN16_X") == 0);

    fd = open("/trunc.txt", O_CREAT | O_WRONLY, 0644);
    if (fd >= 0) { write(fd, "abcdef", 6); close(fd); }
    stat("/trunc.txt", &st);
    r = (int)st.st_size;
    printf("trunc0=%d\n", r);
    printf("trunc1=%d\n", truncate("/trunc.txt", 3));
    stat("/trunc.txt", &st);
    printf("trunc2=%d\n", (int)st.st_size);
    fd = open("/trunc.txt", O_RDWR);
    r = fd >= 0 ? ftruncate(fd, 5) : -1;
    if (fd >= 0) close(fd);
    stat("/trunc.txt", &st);
    printf("trunc3=%d:%d\n", r, (int)st.st_size);
    fd = open("/trunc.txt", O_RDONLY);
    r = fd >= 0 ? (int)read(fd, buf, 8) : -1;
    if (fd >= 0) close(fd);
    printf("trunc4=%d:%d:%d\n", r, !memcmp(buf, "abc", 3), buf[3] == 0 && buf[4] == 0);

    printf("ro-open=%d\n", open("/suite/b.txt", O_WRONLY));
    fd = open("/append.txt", O_CREAT | O_WRONLY, 0644);
    if (fd >= 0) { write(fd, "a", 1); close(fd); }
    fd = open("/append.txt", O_WRONLY | O_APPEND);
    if (fd >= 0) { write(fd, "b", 1); close(fd); }
    fd = open("/append.txt", O_RDONLY);
    r = fd >= 0 ? (int)read(fd, buf, 4) : -1;
    if (fd >= 0) close(fd);
    printf("append=%d:%d\n", r, r == 2 && !memcmp(buf, "ab", 2));

    r = snprintf(buf, sizeof buf, "[%.*s][%*s]", -1, "abc", 5, "x");
    printf("star1=%d:%s\n", r, buf);
    r = snprintf(buf, sizeof buf, "[%*.*s]", -4, 2, "abcdef");
    printf("star2=%d:%s\n", r, buf);
    r = snprintf(buf, sizeof buf, "%.*s", -3, "abcdef");
    printf("star3=%d:%s\n", r, buf);
    printf("PATHS PASS\n");
    return 0;
}
