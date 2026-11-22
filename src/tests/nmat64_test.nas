; nmat64_test.nas - 64-bit dot accumulation past 2^32.
.org 0
JMP @main
.include "../lib/nmat.nas"
main:
MOVI r13,1
; fill 100000 words of A and B with 0x7F7F7F7F
LA r1,0x10000
LA r2,0x20000
MOVI r10,0
LA r11,0x186A0
LA r12,0x7F7F7F7F
f:
ST r12,r1,0
ST r12,r2,0
ADDI r1,r1,1
ADDI r2,r2,1
SUB r11,r11,r13
JMP[NE] @f
LA r1,0x10000
MOVI r2,0
LA r3,0x20000
MOVI r4,0
LA r5,0x186A0
CALL @nmat_dot64
ADD r3,r1,r0
CALL @ph
ADD r3,r2,r0
CALL @ph
; signed vector: -128 * 1 * 4 = -512
LA r1,0x40000
LA r2,0x80808080
ST r2,r1,0
LA r1,0x40010
LA r2,0x01010101
ST r2,r1,0
LA r1,0x40000
MOVI r2,0
LA r3,0x40010
MOVI r4,0
MOVI r5,1
CALL @nmat_dot64
ADD r3,r1,r0
CALL @ph
ADD r3,r2,r0
CALL @ph
HALT
ph:
MOVI r9,8
ph1:
SHR r5,r3,28
SHL r3,r3,4
MOVI r6,10
CMP r5,r6
MOVI r7,48
MOVI[GE] r7,55
ADD r7,r7,r5
PUTC r7
SUB r9,r9,r13
CMP r9,r0
JMP[NE] @ph1
MOVI r7,10
PUTC r7
RET
