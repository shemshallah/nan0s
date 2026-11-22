; dp4b_test.nas - exact packed-i8 dot-product vectors (op 0x4A).
; Each payload holds four signed 8-bit lanes; DP4B sums their products.
.org 0
JMP @main
main:
MOVI r13,1
LA r1,0x04030201
LA r2,0x08070605
DP4B r3,r1,r2
CALL @ph
LA r1,0xFCFDFEFF
LA r2,0x04030201
DP4B r3,r1,r2
CALL @ph
LA r1,0x7F7F7F7F
LA r2,0x7F7F7F7F
DP4B r3,r1,r2
CALL @ph
LA r1,0x80808080
LA r2,0x80808080
DP4B r3,r1,r2
CALL @ph
LA r1,0x00000080
LA r2,0x00000001
DP4B r3,r1,r2
CALL @ph
LA r1,0x01020304
LA r2,0x00000000
DP4B r3,r1,r2
CALL @ph
HALT
; ph: print r3 as 8 uppercase hex digits + newline (clobbers r5-r7,r9)
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
