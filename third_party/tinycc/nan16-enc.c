/* nan16-enc.c - host-side NaN16 word encoder for tcc0. */
#include <stdlib.h>
#include <string.h>
#include "nan16-enc.h"

int nan16_init(Nan16Prog *p, size_t cap)
{
    if (!cap) cap = 64;
    p->w = (uint64_t *)calloc(cap, sizeof(uint64_t));
    if (!p->w) return -1;
    p->n = 0;
    p->cap = cap;
    return 0;
}

void nan16_free(Nan16Prog *p)
{
    free(p->w);
    p->w = NULL;
    p->n = p->cap = 0;
}

int nan16_emit_word(Nan16Prog *p, uint64_t word)
{
    if (p->n == p->cap) {
        size_t nc = p->cap ? p->cap * 2 : 64;
        uint64_t *nw = (uint64_t *)realloc(p->w, nc * sizeof(uint64_t));
        if (!nw) return -1;
        p->w = nw;
        p->cap = nc;
    }
    p->w[p->n++] = word;
    return 0;
}

int nan16_emit(Nan16Prog *p, uint32_t payload, int n)
{
    return nan16_emit_word(p, nan16_mkword(payload, n));
}

uint32_t nan16_p(uint8_t op, uint8_t d, uint8_t a, uint16_t imm)
{
    return ((uint32_t)op << 24) | ((uint32_t)(d & 15) << 20)
         | ((uint32_t)(a & 15) << 16) | imm;
}

/* n=15 is ALWAYS; data words use n=10 and are emitted explicitly. */
#define EMIT(op, d, a, imm) nan16_emit(p, nan16_p((op), (d), (a), (imm)), 15)

int nan16_movi(Nan16Prog *p, int d, uint16_t imm)  { return EMIT(0x01, d, 0, imm); }
int nan16_movhi(Nan16Prog *p, int d, uint16_t imm) { return EMIT(0x02, d, 0, imm); }
int nan16_add(Nan16Prog *p, int d, int a, int b)   { return EMIT(0x03, d, a, b); }
int nan16_sub(Nan16Prog *p, int d, int a, int b)   { return EMIT(0x04, d, a, b); }
int nan16_shl(Nan16Prog *p, int d, int a, uint16_t imm) { return EMIT(0x05, d, a, imm); }
int nan16_shr(Nan16Prog *p, int d, int a, uint16_t imm) { return EMIT(0x06, d, a, imm); }
int nan16_cmp(Nan16Prog *p, int a, int b)          { return EMIT(0x07, 0, a, b); }
int nan16_ld(Nan16Prog *p, int d, int a, uint16_t imm)  { return EMIT(0x08, d, a, imm); }
int nan16_st(Nan16Prog *p, int d, int a, uint16_t imm)  { return EMIT(0x09, d, a, imm); }
int nan16_jmp(Nan16Prog *p, uint16_t target)       { return EMIT(0x0A, 0, 0, target); }
int nan16_call(Nan16Prog *p, uint16_t target)      { return EMIT(0x0B, 0, 0, target); }
int nan16_ret(Nan16Prog *p)                        { return EMIT(0x0C, 0, 0, 0); }
int nan16_jmpr(Nan16Prog *p, int a)                { return EMIT(0x0D, 0, a, 0); }
int nan16_putc(Nan16Prog *p, int d)                { return EMIT(0x15, d, 0, 0); }
int nan16_ldn(Nan16Prog *p, int d, int a, uint16_t imm) { return EMIT(0x17, d, a, imm); }
int nan16_mul(Nan16Prog *p, int d, int a, int b)   { return EMIT(0x20, d, a, b); }
int nan16_addi(Nan16Prog *p, int d, int a, int16_t imm) { return EMIT(0x29, d, a, (uint16_t)imm); }
int nan16_ldb(Nan16Prog *p, int d, int a, uint16_t imm) { return EMIT(0x2A, d, a, imm); }
int nan16_stb(Nan16Prog *p, int d, int a, uint16_t imm) { return EMIT(0x2B, d, a, imm); }
int nan16_halt(Nan16Prog *p)                       { return EMIT(0xFF, 0, 0, 0); }

int nan16_write_words(FILE *f, const Nan16Prog *p)
{
    size_t i;
    for (i = 0; i < p->n; i++) {
        uint64_t w = p->w[i];
        unsigned char b[8];
        int k;
        for (k = 0; k < 8; k++) b[k] = (unsigned char)(w >> (8 * k));
        if (fwrite(b, 1, 8, f) != 8) return -1;
    }
    return 0;
}

int nan16_write_text(FILE *f, const Nan16Prog *p)
{
    size_t i;
    /* .nan text format: near head _ payload _ byte-swapped far head. */
    for (i = 0; i < p->n; i++) {
        uint64_t w = p->w[i];
        uint16_t near = nan16_near(w);
        uint16_t far = nan16_far(w);
        uint16_t far_swapped = (uint16_t)((far >> 8) | (far << 8));
        if (fprintf(f, "%04X_%08X_%04X\n",
                    near, nan16_payload(w), far_swapped) < 0)
            return -1;
    }
    return 0;
}
