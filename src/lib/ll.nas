; ll.nas - 64-bit long long runtime (raw NaN16).
; Values live on the eval stack as low,high pairs (high on top).
.equ W_LLD0 61580
.equ W_LLD1 61581
.equ W_LLB0 61582
.equ W_LLB1 61583
.equ W_LLQ0 61584
.equ W_LLQ1 61585
.equ W_LLR0 61586
.equ W_LLR1 61587
.equ W_LLS  61588
.equ LLFMT  11020800
.equ LLREV  11020900
.equ W_LLF0 61590
.equ W_LLF1 61591

; ll_push_pair: r1=lo r2=hi
ll_push_pair:
LD r3,r0,#R_SP
ST r1,r3,0
ST r2,r3,1
ADDI r3,r3,2
ST r3,r0,#R_SP
RET

; ll_push_int: r1=value
ll_push_int:
LD r2,r0,#R_SP
ST r1,r2,0
ADD r2,r2,r13
ST r2,r0,#R_SP
RET

; ll_neg_pair: r1=lo r2=hi -> negated
ll_neg_pair:
SUB r1,r0,r1
ST r1,r0,#W_LLQ0
CMP r1,r0
JMP[NE] @lnp_borrow
MOVI r3,0
JMP @lnp_hi
lnp_borrow:
MOVI r3,1
lnp_hi:
SUB r2,r0,r2
SUB r2,r2,r3
LD r1,r0,#W_LLQ0
RET

; ll_udiv: unsigned 64-bit divide. Uses W_LLD/W_LLB; result in W_LLQ/W_LLR.
ll_udiv:
ST r0,r0,#W_LLQ0
ST r0,r0,#W_LLQ1
ST r0,r0,#W_LLR0
ST r0,r0,#W_LLR1
LD r1,r0,#W_LLB0
LD r2,r0,#W_LLB1
CMP r1,r0
JMP[NE] @lud_go
CMP r2,r0
JMP[EQ] @lud_zero
lud_go:
MOVI r9,64
lud_l:
; dividend <<= 1, carry out
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
SHR r10,r2,31
SHR r3,r1,31
SHL r1,r1,1
SHL r2,r2,1
ADD r2,r2,r3
ST r1,r0,#W_LLD0
ST r2,r0,#W_LLD1
; remainder = (remainder<<1)|carry
LD r3,r0,#W_LLR0
LD r4,r0,#W_LLR1
SHR r5,r3,31
SHL r3,r3,1
ADD r3,r3,r10
SHL r4,r4,1
ADD r4,r4,r5
ST r3,r0,#W_LLR0
ST r4,r0,#W_LLR1
; if remainder >= divisor
LD r5,r0,#W_LLB0
LD r6,r0,#W_LLB1
CMP r4,r6
JMP[GT] @lud_sub
JMP[LT] @lud_nosub
CMP r3,r5
JMP[LT] @lud_nosub
lud_sub:
ADD r7,r3,r0
SUB r3,r3,r5
CMP r7,r5
JMP[GE] @lud_nb
SUB r4,r4,r13
lud_nb:
SUB r4,r4,r6
ST r3,r0,#W_LLR0
ST r4,r0,#W_LLR1
MOVI r11,1
JMP @lud_q
lud_nosub:
MOVI r11,0
lud_q:
LD r3,r0,#W_LLQ0
LD r4,r0,#W_LLQ1
SHR r5,r3,31
SHL r3,r3,1
ADD r3,r3,r11
SHL r4,r4,1
ADD r4,r4,r5
ST r3,r0,#W_LLQ0
ST r4,r0,#W_LLQ1
SUB r9,r9,r13
CMP r9,r0
JMP[NE] @lud_l
RET
lud_zero:
RET

; ll_op: operand in R_T0.
; bit 8 = unsigned operation (division/shift/compare)
ll_op:
ST r15,r14,0
ADD r14,r14,r13
LD r10,r0,#R_SP
ADDI r10,r10,-4
LD r1,r10,0
LD r2,r10,1
LD r3,r10,2
LD r4,r10,3
ST r1,r0,#W_LLD0
ST r2,r0,#W_LLD1
ST r3,r0,#W_LLB0
ST r4,r0,#W_LLB1
LD r5,r0,#R_SP
ADDI r5,r5,-4
ST r5,r0,#R_SP
LD r6,r0,#R_T0
MOVI r7,0x100
BOOL.8 r8,r6,r7
ST r8,r0,#W_LLS
MOVI r7,0xFF
BOOL.8 r6,r6,r7
MOVI r7,#BIN_ADD
CMP r6,r7
JMP[EQ] @llo_add
MOVI r7,#BIN_SUB
CMP r6,r7
JMP[EQ] @llo_sub
MOVI r7,#BIN_MUL
CMP r6,r7
JMP[EQ] @llo_mul
MOVI r7,#BIN_DIV
CMP r6,r7
JMP[EQ] @llo_div
MOVI r7,#BIN_MOD
CMP r6,r7
JMP[EQ] @llo_mod
MOVI r7,#BIN_SHL
CMP r6,r7
JMP[EQ] @llo_shl
MOVI r7,#BIN_SHR
CMP r6,r7
JMP[EQ] @llo_shr
MOVI r7,#BIN_AND
CMP r6,r7
JMP[EQ] @llo_and
MOVI r7,#BIN_OR
CMP r6,r7
JMP[EQ] @llo_or
MOVI r7,#BIN_XOR
CMP r6,r7
JMP[EQ] @llo_xor
MOVI r7,#BIN_LT
CMP r6,r7
JMP[EQ] @llo_lt
MOVI r7,#BIN_GT
CMP r6,r7
JMP[EQ] @llo_gt
MOVI r7,#BIN_LE
CMP r6,r7
JMP[EQ] @llo_le
MOVI r7,#BIN_GE
CMP r6,r7
JMP[EQ] @llo_ge
MOVI r7,#BIN_EQ
CMP r6,r7
JMP[EQ] @llo_eq
MOVI r7,#BIN_NE
CMP r6,r7
JMP[EQ] @llo_ne
MOVI r1,0
CALL @ll_push_int
JMP @llo_d

llo_add:
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
LD r3,r0,#W_LLB0
LD r4,r0,#W_LLB1
ADD r5,r1,r3
MOVI r6,0
CMP r5,r1
JMP[GE] @llo_add_c
MOVI r6,1
llo_add_c:
ADD r7,r2,r4
ADD r7,r7,r6
ADD r1,r5,r0
ADD r2,r7,r0
CALL @ll_push_pair
JMP @llo_d

llo_sub:
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
LD r3,r0,#W_LLB0
LD r4,r0,#W_LLB1
SUB r5,r1,r3
MOVI r6,0
CMP r1,r3
JMP[GE] @llo_sub_b
MOVI r6,1
llo_sub_b:
SUB r7,r2,r4
SUB r7,r7,r6
ADD r1,r5,r0
ADD r2,r7,r0
CALL @ll_push_pair
JMP @llo_d

llo_mul:
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
LD r3,r0,#W_LLB0
LD r4,r0,#W_LLB1
MUL r5,r1,r3
MULHU r6,r1,r3
MUL r7,r1,r4
MUL r8,r2,r3
ADD r6,r6,r7
ADD r6,r6,r8
ADD r1,r5,r0
ADD r2,r6,r0
CALL @ll_push_pair
JMP @llo_d

llo_div:
LD r1,r0,#W_LLS
CMP r1,r0
JMP[NE] @llo_divu
; signed dividend/divisor
ST r0,r0,#W_LLS
LD r1,r0,#W_LLD1
CMPS r1,r0
JMP[GE] @llo_div_dp
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
CALL @ll_neg_pair
ST r1,r0,#W_LLD0
ST r2,r0,#W_LLD1
LD r1,r0,#W_LLS
ADDI r1,r1,1
ST r1,r0,#W_LLS
llo_div_dp:
LD r1,r0,#W_LLB1
CMPS r1,r0
JMP[GE] @llo_div_bp
LD r1,r0,#W_LLB0
LD r2,r0,#W_LLB1
CALL @ll_neg_pair
ST r1,r0,#W_LLB0
ST r2,r0,#W_LLB1
LD r1,r0,#W_LLS
ADDI r1,r1,2
ST r1,r0,#W_LLS
llo_div_bp:
CALL @ll_udiv
LD r1,r0,#W_LLS
MOVI r2,1
BOOL.8 r1,r1,r2
CMP r1,r0
JMP[EQ] @llo_div_pos
LD r1,r0,#W_LLQ0
LD r2,r0,#W_LLQ1
CALL @ll_neg_pair
ST r1,r0,#W_LLQ0
ST r2,r0,#W_LLQ1
llo_div_pos:
LD r1,r0,#W_LLQ0
LD r2,r0,#W_LLQ1
CALL @ll_push_pair
JMP @llo_d
llo_divu:
CALL @ll_udiv
LD r1,r0,#W_LLQ0
LD r2,r0,#W_LLQ1
CALL @ll_push_pair
JMP @llo_d

llo_mod:
LD r1,r0,#W_LLS
CMP r1,r0
JMP[NE] @llo_modu
ST r0,r0,#W_LLS
LD r1,r0,#W_LLD1
CMPS r1,r0
JMP[GE] @llo_mod_dp
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
CALL @ll_neg_pair
ST r1,r0,#W_LLD0
ST r2,r0,#W_LLD1
MOVI r1,1
ST r1,r0,#W_LLS
llo_mod_dp:
LD r1,r0,#W_LLB1
CMPS r1,r0
JMP[GE] @llo_mod_bp
LD r1,r0,#W_LLB0
LD r2,r0,#W_LLB1
CALL @ll_neg_pair
ST r1,r0,#W_LLB0
ST r2,r0,#W_LLB1
llo_mod_bp:
CALL @ll_udiv
LD r1,r0,#W_LLS
CMP r1,r0
JMP[EQ] @llo_mod_pos
LD r1,r0,#W_LLR0
LD r2,r0,#W_LLR1
CALL @ll_neg_pair
ST r1,r0,#W_LLR0
ST r2,r0,#W_LLR1
llo_mod_pos:
LD r1,r0,#W_LLR0
LD r2,r0,#W_LLR1
CALL @ll_push_pair
JMP @llo_d
llo_modu:
CALL @ll_udiv
LD r1,r0,#W_LLR0
LD r2,r0,#W_LLR1
CALL @ll_push_pair
JMP @llo_d

llo_and:
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLB0
BOOL.6 r1,r1,r2
ST r1,r0,#W_LLQ0
LD r1,r0,#W_LLD1
LD r2,r0,#W_LLB1
BOOL.6 r1,r1,r2
ST r1,r0,#W_LLQ1
JMP @llo_pairq
llo_or:
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLB0
BOOL.14 r1,r1,r2
ST r1,r0,#W_LLQ0
LD r1,r0,#W_LLD1
LD r2,r0,#W_LLB1
BOOL.14 r1,r1,r2
ST r1,r0,#W_LLQ1
JMP @llo_pairq
llo_xor:
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLB0
BOOL.6 r1,r1,r2
ST r1,r0,#W_LLQ0
LD r1,r0,#W_LLD1
LD r2,r0,#W_LLB1
BOOL.6 r1,r1,r2
ST r1,r0,#W_LLQ1
JMP @llo_pairq
llo_pairq:
LD r1,r0,#W_LLQ0
LD r2,r0,#W_LLQ1
CALL @ll_push_pair
JMP @llo_d

llo_shl:
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
LD r3,r0,#W_LLB0
CMP r3,r0
JMP[EQ] @llo_pairq
MOVI r4,63
CMP r3,r4
JMP[LE] @llo_shl_l
ADD r3,r4,r0
llo_shl_l:
SHR r5,r1,31
SHL r1,r1,1
SHL r2,r2,1
ADD r2,r2,r5
SUB r3,r3,r13
CMP r3,r0
JMP[NE] @llo_shl_l
ST r1,r0,#W_LLQ0
ST r2,r0,#W_LLQ1
JMP @llo_pairq

llo_shr:
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
LD r3,r0,#W_LLB0
CMP r3,r0
JMP[EQ] @llo_pairq
MOVI r4,63
CMP r3,r4
JMP[LE] @llo_shr_l
ADD r3,r4,r0
llo_shr_l:
SHL r5,r2,31
SHR r1,r1,1
ADD r1,r1,r5
LD r5,r0,#W_LLS
CMP r5,r0
JMP[NE] @llo_shr_u
SAR r2,r2,1
JMP @llo_shr_n
llo_shr_u:
SHR r2,r2,1
llo_shr_n:
SUB r3,r3,r13
CMP r3,r0
JMP[NE] @llo_shr_l
ST r1,r0,#W_LLQ0
ST r2,r0,#W_LLQ1
JMP @llo_pairq

; comparisons: result int
llo_eq:
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
LD r3,r0,#W_LLB0
LD r4,r0,#W_LLB1
CMP r1,r3
JMP[NE] @llo_false
CMP r2,r4
JMP[NE] @llo_false
JMP @llo_true
llo_ne:
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
LD r3,r0,#W_LLB0
LD r4,r0,#W_LLB1
CMP r1,r3
JMP[NE] @llo_true
CMP r2,r4
JMP[NE] @llo_true
JMP @llo_false
llo_lt:
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
LD r3,r0,#W_LLB0
LD r4,r0,#W_LLB1
LD r5,r0,#W_LLS
CMP r5,r0
JMP[NE] @llo_ltu
CMPS r2,r4
JMP[LT] @llo_true
JMP[GT] @llo_false
CMP r1,r3
JMP[LT] @llo_true
JMP @llo_false
llo_ltu:
CMP r2,r4
JMP[LT] @llo_true
JMP[GT] @llo_false
CMP r1,r3
JMP[LT] @llo_true
JMP @llo_false
llo_gt:
; a > b  ==  b < a
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
LD r3,r0,#W_LLB0
LD r4,r0,#W_LLB1
LD r5,r0,#W_LLS
CMP r5,r0
JMP[NE] @llo_gtu
CMPS r4,r2
JMP[LT] @llo_true
JMP[GT] @llo_false
CMP r3,r1
JMP[LT] @llo_true
JMP @llo_false
llo_gtu:
CMP r4,r2
JMP[LT] @llo_true
JMP[GT] @llo_false
CMP r3,r1
JMP[LT] @llo_true
JMP @llo_false
llo_le:
; a <= b == !(a > b)
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
LD r3,r0,#W_LLB0
LD r4,r0,#W_LLB1
LD r5,r0,#W_LLS
CMP r5,r0
JMP[NE] @llo_leu
CMPS r2,r4
JMP[LT] @llo_true
JMP[GT] @llo_false
CMP r1,r3
JMP[LE] @llo_true
JMP @llo_false
llo_leu:
CMP r2,r4
JMP[LT] @llo_true
JMP[GT] @llo_false
CMP r1,r3
JMP[LE] @llo_true
JMP @llo_false
llo_ge:
; a >= b == !(a < b)
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
LD r3,r0,#W_LLB0
LD r4,r0,#W_LLB1
LD r5,r0,#W_LLS
CMP r5,r0
JMP[NE] @llo_geu
CMPS r2,r4
JMP[GT] @llo_true
JMP[LT] @llo_false
CMP r1,r3
JMP[GE] @llo_true
JMP @llo_false
llo_geu:
CMP r2,r4
JMP[GT] @llo_true
JMP[LT] @llo_false
CMP r1,r3
JMP[GE] @llo_true
JMP @llo_false
llo_true:
MOVI r1,1
CALL @ll_push_int
JMP @llo_d
llo_false:
MOVI r1,0
CALL @ll_push_int
llo_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ll_ext: operand=(unsigned<<16)|depth; widen value at depth to a pair
ll_ext:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#R_T0
MOVI r3,0xFFFF
BOOL.8 r4,r2,r3
SHR r2,r2,16
LD r3,r0,#R_SP
SUB r3,r3,r13
SUB r3,r3,r4
LD r5,r3,0
CMP r2,r0
JMP[NE] @lle_zero
MOVI r6,31
SAR r6,r5,31
JMP @lle_have
lle_zero:
MOVI r6,0
lle_have:
; shift words above the value up one slot
LD r7,r0,#R_SP
SUB r7,r7,r13
lle_sh:
CMP r7,r3
JMP[LE] @lle_shd
LD r8,r7,0
ADD r9,r7,r13
ST r8,r9,0
SUB r7,r7,r13
JMP @lle_sh
lle_shd:
ADD r8,r3,r13
ST r6,r8,0
LD r8,r0,#R_SP
ADD r8,r8,r13
ST r8,r0,#R_SP
SUB r14,r14,r13
LD r15,r14,0
RET

; ll_trunc: operand=depth of the pair high; drop the high word
ll_trunc:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#R_T0
LD r3,r0,#R_SP
SUB r3,r3,r13
SUB r3,r3,r2
; shift words above high down one
ADD r5,r3,r0
ADD r5,r5,r13
lle_tl:
LD r6,r0,#R_SP
CMP r5,r6
JMP[GE] @lle_td
LD r7,r5,0
ADDI r8,r5,-1
ST r7,r8,0
ADD r5,r5,r13
JMP @lle_tl
lle_td:
LD r6,r0,#R_SP
SUB r6,r6,r13
ST r6,r0,#R_SP
SUB r14,r14,r13
LD r15,r14,0
RET

; ll_load: pop address, push 8-byte value
ll_load:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#R_SP
SUB r1,r1,r13
ST r1,r0,#R_SP
LD r2,r1,0
LDB r3,r2,0
LDB r4,r2,1
SHL r4,r4,8
BOOL.14 r3,r3,r4
LDB r4,r2,2
SHL r4,r4,16
BOOL.14 r3,r3,r4
LDB r4,r2,3
SHL r4,r4,24
BOOL.14 r3,r3,r4
ADDI r2,r2,4
LDB r5,r2,0
LDB r4,r2,1
SHL r4,r4,8
BOOL.14 r5,r5,r4
LDB r4,r2,2
SHL r4,r4,16
BOOL.14 r5,r5,r4
LDB r4,r2,3
SHL r4,r4,24
BOOL.14 r5,r5,r4
ADD r1,r3,r0
ADD r2,r5,r0
CALL @ll_push_pair
SUB r14,r14,r13
LD r15,r14,0
RET

; ll_store: operand=keep; stack addr,lo,hi
ll_store:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,#R_SP
ADDI r1,r1,-3
LD r2,r1,0
LD r3,r1,1
LD r4,r1,2
ST r3,r0,#W_LLD0
ST r4,r0,#W_LLD1
STB r3,r2,0
SHR r3,r3,8
ADDI r2,r2,1
STB r3,r2,0
SHR r3,r3,8
ADDI r2,r2,1
STB r3,r2,0
SHR r3,r3,8
ADDI r2,r2,1
STB r3,r2,0
ADDI r2,r2,1
STB r4,r2,0
SHR r4,r4,8
ADDI r2,r2,1
STB r4,r2,0
SHR r4,r4,8
ADDI r2,r2,1
STB r4,r2,0
SHR r4,r4,8
ADDI r2,r2,1
STB r4,r2,0
LD r5,r0,#R_SP
ADDI r5,r5,-3
ST r5,r0,#R_SP
LD r6,r0,#R_T0
CMP r6,r0
JMP[EQ] @lls_d
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
CALL @ll_push_pair
lls_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ll_fmt_base: r1=base -> r2=length, digits at LLFMT
ll_fmt_base:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_LLB0
ST r0,r0,#W_LLB1
LA r3,#LLREV
MOVI r4,0
lfb_l:
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
CMP r1,r0
JMP[NE] @lfb_div
CMP r2,r0
JMP[EQ] @lfb_rev
lfb_div:
ST r3,r0,#W_LLF0
ST r4,r0,#W_LLF1
CALL @ll_udiv
LD r1,r0,#W_LLQ0
LD r2,r0,#W_LLQ1
ST r1,r0,#W_LLD0
ST r2,r0,#W_LLD1
LD r3,r0,#W_LLF0
LD r4,r0,#W_LLF1
LD r5,r0,#W_LLR0
MOVI r6,10
CMP r5,r6
JMP[LT] @lfb_num
ADDI r5,r5,55
JMP @lfb_st
lfb_num:
ADDI r5,r5,48
lfb_st:
STB r5,r3,0
ADD r3,r3,r13
ADD r4,r4,r13
JMP @lfb_l
lfb_rev:
CMP r4,r0
JMP[NE] @lfb_cp
LA r1,#LLFMT
MOVI r2,48
STB r2,r1,0
MOVI r2,1
JMP @lfb_d
lfb_cp:
LA r1,#LLFMT
MOVI r2,0
lfb_cl:
CMP r4,r0
JMP[EQ] @lfb_d2
SUB r3,r3,r13
LDB r5,r3,0
ADD r6,r1,r2
STB r5,r6,0
ADD r2,r2,r13
SUB r4,r4,r13
JMP @lfb_cl
lfb_d2:
ADD r2,r2,r0
lfb_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ll_fmt16: hex (significant digits) -> r2=length
ll_fmt16:
ST r15,r14,0
ADD r14,r14,r13
LA r1,#LLFMT
MOVI r2,0
MOVI r3,0
MOVI r4,16
lhx_l:
LD r5,r0,#W_LLD1
SHR r5,r5,28
LD r6,r0,#W_LLD0
SHR r7,r6,28
SHL r6,r6,4
LD r8,r0,#W_LLD1
SHL r8,r8,4
ADD r8,r8,r7
ST r6,r0,#W_LLD0
ST r8,r0,#W_LLD1
CMP r3,r0
JMP[NE] @lhx_put
CMP r5,r0
JMP[NE] @lhx_put
MOVI r7,1
CMP r4,r7
JMP[NE] @lhx_next
lhx_put:
MOVI r3,1
MOVI r6,10
CMP r5,r6
JMP[LT] @lhx_num
ADDI r5,r5,55
JMP @lhx_st
lhx_num:
ADDI r5,r5,48
lhx_st:
ADD r6,r1,r2
STB r5,r6,0
ADD r2,r2,r13
lhx_next:
SUB r4,r4,r13
CMP r4,r0
JMP[NE] @lhx_l
CMP r2,r0
JMP[NE] @lhx_d
LA r1,#LLFMT
MOVI r5,48
STB r5,r1,0
MOVI r2,1
lhx_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ni_store64: r1=byte addr r2=lo r3=hi
ni_store64:
STB r2,r1,0
SHR r2,r2,8
ADDI r1,r1,1
STB r2,r1,0
SHR r2,r2,8
ADDI r1,r1,1
STB r2,r1,0
SHR r2,r2,8
ADDI r1,r1,1
STB r2,r1,0
ADDI r1,r1,1
STB r3,r1,0
SHR r3,r3,8
ADDI r1,r1,1
STB r3,r1,0
SHR r3,r3,8
ADDI r1,r1,1
STB r3,r1,0
SHR r3,r3,8
ADDI r1,r1,1
STB r3,r1,0
RET

; ll_from_f: pop float, push 64-bit integer pair. operand in W_LLS (1=unsigned).
ll_from_f:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r0,#R_SP
SUB r2,r2,r13
LD r3,r2,0
ST r2,r0,#R_SP
MOVI r4,0
ST r4,r0,#W_LLQ0
; sign bit
LA r4,0x80000000
BOOL.8 r5,r3,r4
CMP r5,r0
JMP[EQ] @lff_pos
BOOL.14 r3,r3,r4
MOVI r4,1
ST r4,r0,#W_LLQ0
lff_pos:
ST r3,r0,#W_LLD0
MOVI r6,0
LA r7,0x4F000000
lff_scale:
FCMP r3,r7
JMP[LT] @lff_conv
LA r8,0x3F000000
FMUL r3,r3,r8
ADD r6,r6,r13
JMP @lff_scale
lff_conv:
CVTFI r3,r3
ST r3,r0,#W_LLD1
ST r0,r0,#W_LLB0
ST r0,r0,#W_LLB1
; pair = (int,0) << shift
MOVI r1,0
ST r3,r0,#W_LLD0
ST r0,r0,#W_LLD1
lff_sh:
CMP r6,r0
JMP[EQ] @lff_sgn
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
SHR r5,r1,31
SHL r1,r1,1
SHL r2,r2,1
ADD r2,r2,r5
ST r1,r0,#W_LLD0
ST r2,r0,#W_LLD1
SUB r6,r6,r13
JMP @lff_sh
lff_sgn:
LD r1,r0,#W_LLD0
LD r2,r0,#W_LLD1
LD r5,r0,#W_LLQ0
CMP r5,r0
JMP[EQ] @lff_push
CALL @ll_neg_pair
lff_push:
CALL @ll_push_pair
SUB r14,r14,r13
LD r15,r14,0
RET

; ll_to_f: pop 64-bit pair, push float (approximate for >24 bits)
ll_to_f:
ST r15,r14,0
ADD r14,r14,r13
; pair high is at SP-1-depth (operand in R_T0)
LD r5,r0,#R_T0
LD r6,r0,#R_SP
ADDI r6,r6,-1
SUB r6,r6,r5
ADDI r7,r6,-1
LD r3,r7,0
LD r4,r6,0
ST r3,r0,#W_LLD0
ST r4,r0,#W_LLD1
CALL @ll_pair_to_f
LD r5,r0,#R_T0
LD r6,r0,#R_SP
ADDI r6,r6,-1
SUB r6,r6,r5
ADDI r7,r6,-1
ST r1,r7,0
ADD r8,r6,r13
ltf_shl:
LD r9,r0,#R_SP
CMP r8,r9
JMP[GE] @ltf_shld
LD r10,r8,0
ADDI r11,r8,-1
ST r10,r11,0
ADD r8,r8,r13
JMP @ltf_shl
ltf_shld:
LD r8,r0,#R_SP
SUB r8,r8,r13
ST r8,r0,#R_SP
SUB r14,r14,r13
LD r15,r14,0
RET

; ll_pair_to_f: W_LLD0/1 -> float bits in r1
ll_pair_to_f:
ST r15,r14,0
ADD r14,r14,r13
LD r3,r0,#W_LLD0
LD r4,r0,#W_LLD1
MOVI r5,0
; sign
CMPS r4,r0
JMP[GE] @ltf_pos
MOVI r5,1
ADD r1,r3,r0
ADD r2,r4,r0
CALL @ll_neg_pair
ADD r3,r1,r0
ADD r4,r2,r0
ltf_pos:
MOVI r6,0
MOVI r7,32
ltf_h:
FADD r6,r6,r6
SHR r8,r4,31
CVTIF r8,r8
FADD r6,r6,r8
SHL r4,r4,1
SUB r7,r7,r13
CMP r7,r0
JMP[NE] @ltf_h
MOVI r7,32
ltf_l:
FADD r6,r6,r6
SHR r8,r3,31
CVTIF r8,r8
FADD r6,r6,r8
SHL r3,r3,1
SUB r7,r7,r13
CMP r7,r0
JMP[NE] @ltf_l
CMP r5,r0
JMP[EQ] @ltf_push
LA r8,0x80000000
BOOL.14 r6,r6,r8
ltf_push:
ADD r1,r6,r0
SUB r14,r14,r13
LD r15,r14,0
RET
