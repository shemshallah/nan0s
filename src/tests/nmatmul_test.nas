; nmatmul_test.nas - packed-i8 matmul: 8x8x8, A rows=i+1, B rows=j+1.
; Expected C[i][j] = 8*(i+1)*(j+1).  Exercises DP4B through the NaN kernel.
.org 0
JMP @main
.include "../lib/nmat.nas"
main:
MOVI r13,1
; A[i][k] = i+1, 8 rows x 2 words
MOVI r10,0
fa:
LA r1,0x10000
MOVI r2,2
MUL r2,r10,r2
ADD r1,r1,r2
ADD r2,r10,r13
LA r3,0x01010101
MUL r3,r2,r3
ST r3,r1,0
ST r3,r1,1
ADD r10,r10,r13
MOVI r2,8
CMP r10,r2
JMP[LT] @fa
; B[j][k] = j+1
MOVI r10,0
fb:
LA r1,0x20000
MOVI r2,2
MUL r2,r10,r2
ADD r1,r1,r2
ADD r2,r10,r13
LA r3,0x01010101
MUL r3,r2,r3
ST r3,r1,0
ST r3,r1,1
ADD r10,r10,r13
MOVI r2,8
CMP r10,r2
JMP[LT] @fb
; context
LA r1,@ctx
LA r2,0x10000
ST r2,r1,0
LA r2,0x20000
ST r2,r1,1
LA r2,0x30000
ST r2,r1,2
MOVI r2,8
ST r2,r1,3
ST r2,r1,4
MOVI r2,2
ST r2,r1,5
ST r2,r1,6
ST r2,r1,7
MOVI r2,1
ST r2,r1,8
CALL @nmat_i8
; verify
MOVI r10,0
vi:
MOVI r11,0
vj:
LA r1,0x30000
MOVI r2,8
MUL r2,r10,r2
ADD r2,r2,r11
ADD r1,r1,r2
LD r3,r1,0
ADD r4,r10,r13
ADD r5,r11,r13
MUL r4,r4,r5
MOVI r5,8
MUL r4,r4,r5
CMP r3,r4
JMP[NE] @fail
ADD r11,r11,r13
MOVI r2,8
CMP r11,r2
JMP[LT] @vj
ADD r10,r10,r13
MOVI r2,8
CMP r10,r2
JMP[LT] @vi
LA r1,@s_pass
CALL @puts
HALT
fail:
LA r1,@s_fail
CALL @puts
HALT
puts:
SHL r1,r1,2
pl:
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @pd
PUTC r2
ADDI r1,r1,1
JMP @pl
pd:
RET
ctx:
.word 0,0,0,0,0,0,0,0,0
s_pass:
.str "MATMUL PASS\n"
s_fail:
.str "MATMUL FAIL\n"
