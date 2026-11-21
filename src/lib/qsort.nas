; qsort.nas - qsort/bsearch with guest callbacks (raw NaN16).
; Callback invocation: ni_call sets up the C frame, then a nested
; ncc_ir_loop runs until the frame returns to the saved R_FP.

; nbi_cmp_call: r1=cmp symbol, r2=p1, r3=p2 -> r1=result
nbi_cmp_call:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_CMPFP
ST r2,r0,#W_CMPA
ST r3,r0,#W_CMPB
LD r4,r0,#R_FP
ST r4,r0,#W_CMPOLD
; push the two pointer arguments
LD r5,r0,#R_SP
LD r6,r0,#W_CMPA
ST r6,r5,0
LD r6,r0,#W_CMPB
ST r6,r5,1
ADDI r5,r5,2
ST r5,r0,#R_SP
; operand = (2 words << 16) | symbol
LD r6,r0,#W_CMPFP
MOVI r7,2
SHL r7,r7,16
BOOL.14 r6,r6,r7
ST r6,r0,#R_T0
; builtins execute synchronously (no IR frame)
LD r1,r0,#W_CMPFP
CALL @sym_entry
LD r2,r1,#SY_KIND
MOVI r3,#SK_BUILTIN
CMP r2,r3
JMP[NE] @cc_func
LD r1,r1,#SY_AUX
MOVI r2,2
CALL @ni_builtin
CALL @ni_pop
SUB r14,r14,r13
LD r15,r14,0
RET
cc_func:
CALL @ni_call
LD r4,r0,#W_CMPOLD
ST r4,r0,#W_IRYSTOP
CALL @ncc_ir_loop
ST r0,r0,#W_IRYSTOP
CALL @ni_pop
SUB r14,r14,r13
LD r15,r14,0
RET

; nbi_qsort: insertion sort via the user comparator
nbi_qsort:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ST r1,r0,#QS_CMP
CALL @ni_pop
ST r1,r0,#QS_SIZE
CALL @ni_pop
ST r1,r0,#QS_N
CALL @ni_pop
ST r1,r0,#QS_BASE
MOVI r1,1
ST r1,r0,#QS_I
qs_outer:
LD r1,r0,#QS_I
LD r2,r0,#QS_N
CMP r1,r2
JMP[GE] @qs_done
ST r1,r0,#QS_J
qs_inner:
LD r1,r0,#QS_J
CMP r1,r0
JMP[EQ] @qs_next
; p1 = base + (j-1)*size
LD r2,r0,#QS_BASE
LD r3,r0,#QS_SIZE
LD r4,r0,#QS_J
ADDI r4,r4,-1
MUL r4,r4,r3
ADD r2,r2,r4
ST r2,r0,#QS_P1
; p2 = base + j*size
LD r5,r0,#QS_BASE
LD r4,r0,#QS_J
MUL r4,r4,r3
ADD r5,r5,r4
ST r5,r0,#QS_P2
; cmp(p1,p2)
ADD r3,r5,r0
LD r1,r0,#QS_CMP
CALL @nbi_cmp_call
CMPS r1,r0
JMP[LE] @qs_next
; swap size bytes
LD r4,r0,#QS_SIZE
LD r6,r0,#QS_P1
LD r7,r0,#QS_P2
qs_swap:
LDB r8,r6,0
LDB r9,r7,0
STB r9,r6,0
STB r8,r7,0
ADDI r6,r6,1
ADDI r7,r7,1
SUB r4,r4,r13
CMP r4,r0
JMP[NE] @qs_swap
LD r1,r0,#QS_J
ADDI r1,r1,-1
ST r1,r0,#QS_J
JMP @qs_inner
qs_next:
LD r1,r0,#QS_I
ADD r1,r1,r13
ST r1,r0,#QS_I
JMP @qs_outer
qs_done:
MOVI r1,0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
RET

; nbi_bsearch: binary search via the user comparator
nbi_bsearch:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ST r1,r0,#QS_CMP
CALL @ni_pop
ST r1,r0,#QS_SIZE
CALL @ni_pop
ST r1,r0,#QS_N
CALL @ni_pop
ST r1,r0,#QS_BASE
CALL @ni_pop
ST r1,r0,#QS_KEY
ST r0,r0,#QS_I
LD r1,r0,#QS_N
ADDI r1,r1,-1
ST r1,r0,#QS_J
bs_loop:
LD r1,r0,#QS_I
LD r2,r0,#QS_J
CMP r1,r2
JMP[GT] @bs_none
ADD r1,r1,r2
SHR r1,r1,1
ST r1,r0,#QS_P2
LD r2,r0,#QS_BASE
LD r3,r0,#QS_SIZE
MUL r1,r1,r3
ADD r2,r2,r1
ST r2,r0,#QS_P1
LD r3,r0,#QS_KEY
LD r1,r0,#QS_CMP
CALL @nbi_cmp_call
CMPS r1,r0
JMP[EQ] @bs_found
JMP[LT] @bs_lo
LD r1,r0,#QS_P2
ADDI r1,r1,-1
ST r1,r0,#QS_J
JMP @bs_loop
bs_lo:
LD r1,r0,#QS_P2
ADD r1,r1,r13
ST r1,r0,#QS_I
JMP @bs_loop
bs_found:
LD r1,r0,#QS_P1
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
RET
bs_none:
MOVI r1,0
CALL @ni_push
SUB r14,r14,r13
LD r15,r14,0
RET

ncc_s_qsort:
.str "qsort"
ncc_s_bsearch:
.str "bsearch"
