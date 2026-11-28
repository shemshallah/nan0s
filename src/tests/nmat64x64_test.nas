; nmat64x64_test.nas - 8x8x8 packed-i8 matmul with 64-bit descriptors/results.
.org 0
JMP @main
.include "../lib/n64.nas"
.include "../lib/nmat.nas"
main:
MOVI r13,1
; A[i] = i+1 bytes, B[j] = j+1 bytes
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
LA r1,@ctx
LA r2,0x10000
ST r2,r1,0
ST r0,r1,1
LA r2,0x20000
ST r2,r1,2
ST r0,r1,3
LA r2,0x30000
ST r2,r1,4
ST r0,r1,5
MOVI r2,8
ST r2,r1,6
ST r2,r1,7
MOVI r2,2
ST r2,r1,8
ST r0,r1,9
ST r2,r1,10
ST r0,r1,11
ST r2,r1,12
ST r0,r1,13
MOVI r2,2
ST r2,r1,14
ST r0,r1,15
ST r0,r1,16
ST r0,r1,17
CALL @nmat_i8_64
MOVI r10,0
vi:
MOVI r11,0
vj:
LA r6,0x30000
MOVI r3,16
MUL r3,r10,r3
MOVI r4,2
MUL r4,r11,r4
ADD r3,r3,r4
ADD r1,r6,r3
LD r3,r1,0
LD r4,r1,1
ADD r5,r10,r13
ADD r6,r11,r13
MUL r5,r5,r6
MOVI r6,8
MUL r5,r5,r6
CMP r3,r5
JMP[NE] @fail
CMP r4,r0
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
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
s_pass:
.str "MAT64 PASS\n"
s_fail:
.str "MAT64 FAIL\n"
