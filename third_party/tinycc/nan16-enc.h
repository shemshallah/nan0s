/* nan16-enc.h - host-side NaN16 word encoder for tcc0.
 *
 * This is the encoding layer a TCC backend calls: it emits NaN16 words with
 * the standard class nibble n=10 and never interprets them.  The emitted
 * stream is a flat cartridge; the product execution path is the NaN16 core,
 * not this host code.
 */
#ifndef NAN16_ENC_H
#define NAN16_ENC_H

#include <stddef.h>
#include <stdio.h>
#include <stdint.h>
#include "nan16-abi.h"

typedef struct {
    uint64_t *w;
    size_t n;
    size_t cap;
} Nan16Prog;

int  nan16_init(Nan16Prog *p, size_t cap);
void nan16_free(Nan16Prog *p);
int  nan16_emit(Nan16Prog *p, uint32_t payload, int n);
int  nan16_emit_word(Nan16Prog *p, uint64_t word);

/* Predicate nibbles: bit k is set when the instruction executes for flag
   state k (FLAGM = 1 << k). */
#define NAN16_PRED_NEVER  0
#define NAN16_PRED_GT     1
#define NAN16_PRED_LT     2
#define NAN16_PRED_NE     3
#define NAN16_PRED_EQ     4
#define NAN16_PRED_GE     5
#define NAN16_PRED_LE     6
#define NAN16_PRED_ALWAYS 15
int  nan16_emit_pred(Nan16Prog *p, uint32_t payload, int pred);

/* Payload constructors. */
uint32_t nan16_p(uint8_t op, uint8_t d, uint8_t a, uint16_t imm);

/* Opcode emitters (opcode values match the NaN16 ISA table). */
int nan16_movi(Nan16Prog *p, int d, uint16_t imm);       /* 0x01 */
int nan16_movhi(Nan16Prog *p, int d, uint16_t imm);      /* 0x02 */
int nan16_add(Nan16Prog *p, int d, int a, int b);        /* 0x03 */
int nan16_sub(Nan16Prog *p, int d, int a, int b);        /* 0x04 */
int nan16_shl(Nan16Prog *p, int d, int a, uint16_t imm); /* 0x05 */
int nan16_shr(Nan16Prog *p, int d, int a, uint16_t imm); /* 0x06 */
int nan16_cmp(Nan16Prog *p, int a, int b);               /* 0x07 */
int nan16_ld(Nan16Prog *p, int d, int a, uint16_t imm);  /* 0x08 */
int nan16_st(Nan16Prog *p, int d, int a, uint16_t imm);  /* 0x09 */
int nan16_jmp(Nan16Prog *p, uint16_t target);            /* 0x0A */
int nan16_jmp_cond(Nan16Prog *p, uint16_t target, int pred); /* 0x0A */
int nan16_call(Nan16Prog *p, uint16_t target);           /* 0x0B */
int nan16_ret(Nan16Prog *p);                             /* 0x0C */
int nan16_jmpr(Nan16Prog *p, int a);                     /* 0x0D */
int nan16_putc(Nan16Prog *p, int d);                     /* 0x15 */
int nan16_ldn(Nan16Prog *p, int d, int a, uint16_t imm); /* 0x17 */
int nan16_mul(Nan16Prog *p, int d, int a, int b);        /* 0x20 */
int nan16_addi(Nan16Prog *p, int d, int a, int16_t imm); /* 0x29 */
int nan16_ldb(Nan16Prog *p, int d, int a, uint16_t imm); /* 0x2A */
int nan16_stb(Nan16Prog *p, int d, int a, uint16_t imm); /* 0x2B */
int nan16_halt(Nan16Prog *p);                            /* 0xFF */

/* Writers. */
int nan16_write_words(FILE *f, const Nan16Prog *p);
int nan16_write_text(FILE *f, const Nan16Prog *p);

#endif
