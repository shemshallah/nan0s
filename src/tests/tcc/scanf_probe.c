/* scanf_probe.c - scanf formats used by SQLite's test1.c and Tcl probes. */
#include <stdio.h>
#include <string.h>

int main(void)
{
    unsigned x = 0, y = 0;
    int n = 0, p = 0, r;
    char a[16], b[16], c1 = 0, c2 = 0;
    memset(a, 0, sizeof a); memset(b, 0, sizeof b);

    r = sscanf("deadbeefcafebabe", "%08x%08x", &x, &y);
    printf("hex=%d:%08x:%08x\n", r, x, y);
    r = sscanf("| size 4096 pagesize 1024", "| size %d pagesize %d", &n, &p);
    printf("size=%d:%d:%d\n", r, n, p);
    r = sscanf("| page 3 offset 512", "| page %d offset %d", &n, &p);
    printf("page=%d:%d:%d\n", r, n, p);
    r = sscanf("| 7: ff 1 2 3", "| %d: %x %x", &n, &x, &y);
    printf("row=%d:%d:%x:%x\n", r, n, x, y);
    r = sscanf("  hello world", "%s %s", a, b);
    printf("str=%d:%s:%s\n", r, a, b);
    r = sscanf("xyz", "%c%c", &c1, &c2);
    printf("chr=%d:%c:%c\n", r, c1, c2);
    r = sscanf("abc", "%d", &n);
    printf("bad=%d\n", r);
    r = sscanf("42rest", "%d%s", &n, a);
    printf("mix=%d:%d:%s\n", r, n, a);
    return 0;
}
