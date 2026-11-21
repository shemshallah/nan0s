; setjmp.nas - non-local jumps (raw NaN16).
; jmp_buf is a pointer-sized object. setjmp(env) receives &env, allocates a
; snapshot block in the C heap, stores its address in env, and saves the IR
; continuation plus a copy of the live evaluation stack. longjmp restores it.

.equ SJ_WORDS 64

nbi_setjmp:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ST r1,r0,#W_LLQ0
; allocate (4 + SJ_WORDS) words = 272 bytes
MOVI r1,272
CALL @ni_malloc
ST r1,r0,#W_LLQ1
; *env = block
LD r1,r0,#W_LLQ0
LD r2,r0,#W_LLQ1
MOVI r3,#SZ_32
CALL @ni_storev
; block word pointer
LD r4,r0,#W_LLQ1
SHR r4,r4,2
LD r1,r0,#R_IP
ST r1,r4,0
LD r1,r0,#R_FP
ST r1,r4,1
LD r1,r0,#R_SP
ST r1,r4,2
; depth = R_SP - NCC_ESB, clamp to SJ_WORDS
LD r1,r0,#R_SP
LA r2,#NCC_ESB
SUB r1,r1,r2
MOVI r2,#SJ_WORDS
CMP r1,r2
JMP[LE] @sjs_ok
MOVI r1,#SJ_WORDS
sjs_ok:
ST r1,r4,3
MOVI r5,0
sjs_l:
LD r1,r4,3
CMP r5,r1
JMP[GE] @sjs_d
LA r2,#NCC_ESB
ADD r2,r2,r5
LD r3,r2,0
ADDI r6,r4,4
ADD r6,r6,r5
ST r3,r6,0
ADD r5,r5,r13
JMP @sjs_l
sjs_d:
MOVI r1,0
CALL @ni_push
JMP @nbi_d

nbi_longjmp:
ST r15,r14,0
ADD r14,r14,r13
CALL @ni_pop
ST r1,r0,#W_LLQ1
CALL @ni_pop
ST r1,r0,#W_LLQ0
LD r1,r0,#W_LLQ0
MOVI r2,#SZ_32
CALL @ni_loadv
ST r1,r0,#W_LLQ0
CMP r1,r0
JMP[EQ] @nlj_noblock
SHR r4,r1,2
MOVI r5,0
nlj_l:
LD r1,r4,3
CMP r5,r1
JMP[GE] @nlj_d
ADDI r6,r4,4
ADD r6,r6,r5
LD r2,r6,0
LA r3,#NCC_ESB
ADD r3,r3,r5
ST r2,r3,0
ADD r5,r5,r13
JMP @nlj_l
nlj_d:
LD r1,r4,0
ST r1,r0,#R_IP
LD r1,r4,1
ST r1,r0,#R_FP
LD r1,r4,2
ST r1,r0,#R_SP
nlj_noblock:
LD r1,r0,#W_LLQ1
CMP r1,r0
JMP[NE] @nlj_push
MOVI r1,1
nlj_push:
CALL @ni_push
JMP @nbi_d

ncc_s_setjmp:
.str "setjmp"
ncc_s_longjmp:
.str "longjmp"
ncc_s_jmp_buf:
.str "jmp_buf"
