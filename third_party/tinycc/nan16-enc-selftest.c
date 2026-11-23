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

    if (argc != 9) {
        fprintf(stderr, "usage: %s words.bin prog.nan loop.bin loop.nan call.bin call.nan const.bin const.nan\n", argv[0]);
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

    /* Branch-loop program:
       MOVI r1,0 ; MOVI r2,3 ; ADDI r1,r1,1 ; CMP r1,r2 ;
       JMP[LT] 2 ; ST r1,r0,0x100 ; HALT  */
    if (nan16_init(&p, 16)) return 1;
    if (nan16_movi(&p, 1, 0)
        || nan16_movi(&p, 2, 3)
        || nan16_addi(&p, 1, 1, 1)
        || nan16_cmp(&p, 1, 2)
        || nan16_jmp_cond(&p, 2, NAN16_PRED_LT)
        || nan16_st(&p, 1, 0, 0x100)
        || nan16_halt(&p))
        return 1;
    assert(p.n == 7);
    assert(nan16_near(p.w[4]) == 0x7FF1);   /* LT: near class 0 */
    assert(nan16_far(p.w[4]) == 0x7FF8);    /* LT: far class 2 */
    f = fopen(argv[3], "wb");
    if (!f || nan16_write_words(f, &p)) return 1;
    fclose(f);
    f = fopen(argv[4], "w");
    if (!f || nan16_write_text(f, &p)) return 1;
    fclose(f);
    printf("NAN16 ENC OK loop=%u\n", (unsigned)p.n);
    nan16_free(&p);

    /* CALL/RET program:
       CALL 3 ; ST r1,r0,0x100 ; HALT ; MOVI r1,7 ; RET  */
    if (nan16_init(&p, 16)) return 1;
    if (nan16_call(&p, 3)
        || nan16_st(&p, 1, 0, 0x100)
        || nan16_halt(&p)
        || nan16_movi(&p, 1, 7)
        || nan16_ret(&p))
        return 1;
    assert(p.n == 5);
    assert(nan16_payload(p.w[0]) == 0x0B000003);
    f = fopen(argv[5], "wb");
    if (!f || nan16_write_words(f, &p)) return 1;
    fclose(f);
    f = fopen(argv[6], "w");
    if (!f || nan16_write_text(f, &p)) return 1;
    fclose(f);
    printf("NAN16 ENC OK call=%u\n", (unsigned)p.n);
    nan16_free(&p);

    /* 32-bit constant: MOVI/MOVHI r1,0x12345678 ; ST ; HALT */
    if (nan16_init(&p, 16)) return 1;
    if (nan16_movi32(&p, 1, 0x12345678u)
        || nan16_st(&p, 1, 0, 0x100)
        || nan16_halt(&p))
        return 1;
    assert(p.n == 4);
    assert(nan16_payload(p.w[0]) == 0x01105678);   /* low half */
    assert(nan16_payload(p.w[1]) == 0x02101234);   /* high half */
    f = fopen(argv[7], "wb");
    if (!f || nan16_write_words(f, &p)) return 1;
    fclose(f);
    f = fopen(argv[8], "w");
    if (!f || nan16_write_text(f, &p)) return 1;
    fclose(f);
    printf("NAN16 ENC OK const=%u\n", (unsigned)p.n);
    nan16_free(&p);

    /* Label/fixup resolution: CALL func ; ST ; HALT ; func: MOVI r1,9 ; RET */
    if (nan16_init(&p, 16)) return 1;
    if (nan16_call(&p, 0)
        || nan16_st(&p, 1, 0, 0x100)
        || nan16_halt(&p)
        || nan16_label(&p, "func")
        || nan16_movi(&p, 1, 9)
        || nan16_ret(&p)
        || nan16_fixup16(&p, 0, "func")
        || nan16_resolve(&p))
        return 1;
    assert(p.n == 5);
    assert(nan16_payload(p.w[0]) == 0x0B000003);
    printf("NAN16 ENC OK label=%u\n", (unsigned)p.n);
    nan16_free(&p);
    return 0;
}
