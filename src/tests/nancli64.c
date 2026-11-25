/* nancli64.c - 64-bit NaN/0S text command line over the NaN POSIX table.
 *
 * The CLI is a C guest compiled to NaN; every filesystem operation goes
 * through the NaN service table (bare_fs_*).  Commands are read from a
 * built-in script so the gate is deterministic on the bare x86_64 machine.
 */
#include <stdio.h>
#include <string.h>

#define TAB ((volatile unsigned *)0x00A59000u)
typedef int (*load_fn)(const char *, void *, int);
typedef int (*save_fn)(const char *, const void *, int);
typedef int (*path_fn)(const char *);
typedef int (*stat_fn)(const char *, int *);
typedef int (*readdir_fn)(const char *, int *, char *, int, int *);
typedef int (*trunc_fn)(const char *, int);
typedef int (*tick_fn)(void);

#define CB_LOAD    ((load_fn)(unsigned long)TAB[0])
#define CB_SAVE    ((save_fn)(unsigned long)TAB[1])
#define CB_REMOVE  ((path_fn)(unsigned long)TAB[2])
#define CB_SIZE    ((path_fn)(unsigned long)TAB[3])
#define CB_TICK    ((tick_fn)(unsigned long)TAB[4])
#define CB_STAT    ((stat_fn)(unsigned long)TAB[5])
#define CB_MKDIR   ((path_fn)(unsigned long)TAB[6])
#define CB_RMDIR   ((path_fn)(unsigned long)TAB[7])
#define CB_READDIR ((readdir_fn)(unsigned long)TAB[8])
#define CB_ACCESS  ((path_fn)(unsigned long)TAB[9])
#define CB_TRUNC   ((trunc_fn)(unsigned long)TAB[10])

static const char script[] =
    "help\n"
    "mkdir /cli\n"
    "write /cli/a hello\n"
    "cat /cli/a\n"
    "ls /cli\n"
    "stat /cli/a\n"
    "truncate /cli/a 2\n"
    "cat /cli/a\n"
    "rm /cli/a\n"
    "rmdir /cli\n"
    "mkdir /cli2\n"
    "write /cli2/x world\n"
    "ls /cli2\n"
    "rm /cli2/x\n"
    "rmdir /cli2\n"
    "exit\n";

static char line[160];
static char name[96];
static unsigned char buf[512];

static int split(char *s, char **tok, int max)
{
    int n = 0;
    while (*s && n < max) {
        while (*s == ' ' || *s == '\t') *s++ = 0;
        if (!*s) break;
        tok[n++] = s;
        while (*s && *s != ' ' && *s != '\t') s++;
    }
    return n;
}

static int dec(const char *s)
{
    int v = 0;
    while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
    return v;
}

static void run_line(char *s)
{
    char *t[6];
    int n = split(s, t, 6);
    int i, idx, type, st[8];
    if (!n) return;
    if (!strcmp(t[0], "help")) {
        puts("commands: mkdir rmdir write cat ls stat truncate rm exit");
        return;
    }
    if (!strcmp(t[0], "exit")) return;
    if (!strcmp(t[0], "mkdir") && n == 2) {
        puts(CB_MKDIR(t[1]) == 0 ? "ok" : "error");
        return;
    }
    if (!strcmp(t[0], "rmdir") && n == 2) {
        puts(CB_RMDIR(t[1]) == 0 ? "ok" : "error");
        return;
    }
    if (!strcmp(t[0], "rm") && n == 2) {
        puts(CB_REMOVE(t[1]) != 0 ? "ok" : "error");
        return;
    }
    if (!strcmp(t[0], "write") && n >= 3) {
        int len = (int)strlen(t[2]);
        puts(CB_SAVE(t[1], t[2], len) ? "ok" : "error");
        return;
    }
    if (!strcmp(t[0], "cat") && n == 2) {
        int got = CB_LOAD(t[1], buf, (int)sizeof buf - 1);
        if (got < 0) { puts("error"); return; }
        buf[got] = 0;
        printf("%s\n", (char *)buf);
        return;
    }
    if (!strcmp(t[0], "ls") && n == 2) {
        idx = 0;
        while (CB_READDIR(t[1], &idx, name, (int)sizeof name, &type))
            printf("%s%s\n", name, type ? "/" : "");
        return;
    }
    if (!strcmp(t[0], "stat") && n == 2) {
        if (CB_STAT(t[1], st) != 0) { puts("error"); return; }
        printf("%s size=%d mode=%d\n", st[0] ? "dir" : "file", st[1], st[2]);
        return;
    }
    if (!strcmp(t[0], "truncate") && n == 3) {
        puts(CB_TRUNC(t[1], dec(t[2])) == 0 ? "ok" : "error");
        return;
    }
    (void)i;
    puts("unknown");
}

int main(void)
{
    const char *p = script;
    int pos = 0;
    while (*p) {
        pos = 0;
        while (*p && *p != '\n' && pos < (int)sizeof line - 1)
            line[pos++] = *p++;
        if (*p == '\n') p++;
        line[pos] = 0;
        printf("nancli64> %s\n", line);
        run_line(line);
        if (!strcmp(line, "exit")) break;
    }
    return 0;
}
