/* heap_stress.c - random malloc/realloc/free with pattern verification. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define N 2048
static unsigned char *p[N];
static unsigned sz[N];
static unsigned char pat[N];
extern int nan16_heap_check(void);
static unsigned seed = 12345;
static unsigned rnd(void) { seed = seed * 1103515245u + 12345u; return seed >> 8; }

int main(void)
{
    unsigned i, k, b = 0;
    for (k = 0; k < 20000; k++) {
        i = rnd() % N;
        if ((k % 500) == 0) { int h = nan16_heap_check(); if (h) { printf("heapcheck=%d at %u\n", h, k); b = 1; break; } }
        if (!p[i]) {
            unsigned n = 1 + rnd() % 2048;
            p[i] = (unsigned char *)malloc(n);
            if (!p[i]) { printf("oom at %u size %u\n", k, n); b = 1; break; }
            sz[i] = n; pat[i] = (unsigned char)(i + k);
            memset(p[i], pat[i], n);
        } else if (rnd() & 1) {
            unsigned n = 1 + rnd() % 4096, j, old = sz[i];
            unsigned char *q = (unsigned char *)realloc(p[i], n);
            if (!q) { printf("realloc oom at %u\n", k); b = 1; break; }
            for (j = 0; j < (old < n ? old : n); j++)
                if (q[j] != pat[i]) { printf("realloc data at %u:%u\n", k, j); b = 1; break; }
            if (b) break;
            p[i] = q; sz[i] = n; pat[i]++;
            memset(q, pat[i], n);
        } else {
            unsigned j;
            for (j = 0; j < sz[i]; j++)
                if (p[i][j] != pat[i]) { printf("data at %u:%u\n", k, j); b = 1; break; }
            if (b) break;
            free(p[i]); p[i] = 0; sz[i] = 0;
        }
    }
    for (i = 0; i < N; i++) free(p[i]);
    printf("heap_stress=%s\n", b ? "FAIL" : "PASS");
    return b;
}
