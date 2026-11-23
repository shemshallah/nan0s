/* nan16-enc-selftest.c - encoder smoke test for tcc0.
 *
 * Emits:  MOVI r1,42 ; ST r1,r0,0x100 ; HALT
 * The program is written as raw 8-byte words and as .nan text.  The gate
 * executes both with nan_cli and expects the stored payload 0x2A.
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "nan16-enc.h"

int main(int argc, char **argv)
{
    Nan16Prog p;
    FILE *f;

    if (argc != 3) {
        fprintf(stderr, "usage: %s words.bin prog.nan\n", argv[0]);
        return 2;
    }
    if (nan16_init(&p, 16)) return 1;
    if (nan16_movi(&p, 1, 42)
        || nan16_st(&p, 1, 0, 0x100)
        || nan16_halt(&p))
        return 1;

    assert(p.n == 3);
    assert(nan16_near(p.w[0]) == 0xFFF8);
    assert(nan16_far(p.w[0]) == 0xFFF8);
    assert(nan16_payload(p.w[0]) == 0x0110002A);
    assert(nan16_payload(p.w[1]) == 0x09100100);
    assert(nan16_payload(p.w[2]) == 0xFF000000);

    f = fopen(argv[1], "wb");
    if (!f || nan16_write_words(f, &p)) return 1;
    fclose(f);
    f = fopen(argv[2], "w");
    if (!f || nan16_write_text(f, &p)) return 1;
    fclose(f);

    printf("NAN16 ENC OK words=%u\n", (unsigned)p.n);
    nan16_free(&p);
    return 0;
}
