/* heap_probe.c - allocator split/coalesce/realloc/pattern checks. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fill(unsigned char *p, unsigned n, unsigned char v)
{
    unsigned i;
    for (i = 0; i < n; i++) p[i] = (unsigned char)(v + i);
    return 0;
}
static int check(const unsigned char *p, unsigned n, unsigned char v)
{
    unsigned i;
    for (i = 0; i < n; i++) if (p[i] != (unsigned char)(v + i)) return i + 1;
    return 0;
}
int main(void)
{
    unsigned char *a, *b, *c, *d, *e;
    int bad = 0;
    a = malloc(100); b = malloc(200); c = malloc(300);
    if (!a || !b || !c) return 1;
    fill(a, 100, 1); fill(b, 200, 2); fill(c, 300, 3);
    free(b);
    d = malloc(150); e = malloc(180);
    if (!d || !e) return 2;
    fill(d, 150, 4); fill(e, 180, 5);
    bad |= check(a, 100, 1) != 0;
    bad |= check(c, 300, 3) != 0;
    bad |= check(d, 150, 4) != 0;
    bad |= check(e, 180, 5) != 0;
    a = realloc(a, 250);
    if (!a) return 3;
    bad |= check(a, 100, 1) != 0;
    fill(a, 250, 6);
    free(c); free(d); free(e);
    b = malloc(5000); c = malloc(5000);
    if (!b || !c) return 4;
    fill(b, 5000, 7); fill(c, 5000, 8);
    bad |= check(b, 5000, 7) != 0;
    bad |= check(c, 5000, 8) != 0;
    free(a); free(b); free(c);
    printf("heap_bad=%d\n", bad);
    printf("HEAP %s\n", bad ? "FAIL" : "PASS");
    return bad ? 5 : 0;
}
