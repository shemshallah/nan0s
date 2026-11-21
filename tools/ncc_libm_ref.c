/* ncc_libm_ref.c - host reference for tools/ncc_libm_exact.sh.
 *
 * Reads the same checked-in corpus files as the ncc guest program and writes
 * the expected bit patterns. sin/cos reference is (float)sin((double)x) /
 * (float)cos((double)x); the helpers use the float32 libm entry points.
 * Build: cc -O2 -ffp-contract=off -fno-fast-math ncc_libm_ref.c -o ncc_libm_ref -lm
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

union F { float f; unsigned u; };

static unsigned bits(float f) { union F v; v.f = f; return v.u; }
static float fbits(unsigned u) { union F v; v.u = u; return v.f; }

int main(int argc, char **argv)
{
    FILE *f;
    char line[256];
    if (argc != 4) {
        fprintf(stderr, "usage: %s sin_corpus unary_corpus fmod_corpus\n", argv[0]);
        return 2;
    }
    f = fopen(argv[1], "r");
    if (!f) return 1;
    while (fgets(line, sizeof line, f)) {
        unsigned b;
        if (sscanf(line, "%x", &b) != 1) continue;
        float x = fbits(b);
        printf("s %08x %08x\n", b, bits((float)sin((double)x)));
        printf("c %08x %08x\n", b, bits((float)cos((double)x)));
    }
    fclose(f);

    f = fopen(argv[2], "r");
    if (!f) return 1;
    while (fgets(line, sizeof line, f)) {
        char tag[16];
        unsigned b;
        float x, y;
        if (sscanf(line, "%15s %x", tag, &b) != 2) continue;
        x = fbits(b);
        if (!strcmp(tag, "sqrt")) y = sqrtf(x);
        else if (!strcmp(tag, "fabs")) y = fabsf(x);
        else if (!strcmp(tag, "floor")) y = floorf(x);
        else if (!strcmp(tag, "ceil")) y = ceilf(x);
        else if (!strcmp(tag, "trunc")) y = truncf(x);
        else if (!strcmp(tag, "round")) y = roundf(x);
        else continue;
        printf("%s %08x %08x\n", tag, b, bits(y));
    }
    fclose(f);

    f = fopen(argv[3], "r");
    if (!f) return 1;
    while (fgets(line, sizeof line, f)) {
        unsigned a, b;
        if (sscanf(line, "%x %x", &a, &b) != 2) continue;
        printf("fmod %08x %08x %08x\n", a, b, bits(fmodf(fbits(a), fbits(b))));
    }
    fclose(f);
    return 0;
}
