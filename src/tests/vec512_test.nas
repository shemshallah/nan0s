; vec512_test.nas - 512-bit abstract vector family, packed i8/i32 lanes.
.org 0
JMP @main
main:
MOVI r13,1
VZERO r0
LA r1,0x01010101
VBCAST r1,r1
VADD8 r2,r1,r1
VGET r3,r2,0
CALL @ph
VADD32 r3,r1,r1
VGET r3,r3,0
CALL @ph
LA r1,0x04030201
VBCAST r4,r1
LA r1,0x08070605
VBCAST r5,r1
VDP4B r6,r4,r5
VGET r3,r6,0
CALL @ph
LA r1,0xDEADBEEF
VSET r7,r1,3
VGET r3,r7,3
CALL @ph
; 16-word load/store roundtrip
MOVI r10,0
fill:
LA r1,0x4000
ADD r1,r1,r10
ADD r2,r10,r13
LA r3,0x11223344
MUL r3,r2,r3
ST r3,r1,0
ADD r10,r10,r13
MOVI r2,16
CMP r10,r2
JMP[LT] @fill
LA r1,0x10000
VLOAD r8,r1
LA r1,0x11000
VSTORE r8,r1
MOVI r10,0
cmp:
LA r1,0x4000
ADD r1,r1,r10
LD r2,r1,0
LA r1,0x4400
ADD r1,r1,r10
LD r3,r1,0
CMP r2,r3
JMP[NE] @fail
ADD r10,r10,r13
MOVI r2,16
CMP r10,r2
JMP[LT] @cmp
; unaligned VLOAD/VSTORE must fall back to the byte path and stay exact
LA r1,0x10001
VLOAD r7,r1
LA r1,0x11001
VSTORE r7,r1
MOVI r10,0
ucmp:
LA r1,0x10001
ADD r1,r1,r10
LDB r2,r1,0
LA r1,0x11001
ADD r1,r1,r10
LDB r3,r1,0
CMP r2,r3
JMP[NE] @fail
ADD r10,r10,r13
MOVI r2,64
CMP r10,r2
JMP[LT] @ucmp
LA r1,@s_pass
CALL @puts
HALT
fail:
LA r1,@s_fail
CALL @puts
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
s_pass:
.str "VEC512 PASS\n"
s_fail:
.str "VEC512 FAIL\n"
