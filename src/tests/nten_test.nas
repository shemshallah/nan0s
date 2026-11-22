; nten_test.nas - 64-bit tensor path arithmetic, including a 4 GiB crossing.
.org 0
JMP @main
.include "../lib/nten.nas"
main:
MOVI r13,1
LA r1,@ctx
LA r2,0xFFFFF000
MOVI r3,0
MOVI r4,4
LA r5,0x200000
MOVI r6,0x200
MOVI r7,0
MOVI r8,0x10
MOVI r9,0
CALL @nten_init
; (0,0) = base
LA r1,@ctx
MOVI r2,0
MOVI r3,0
CALL @nten_ptr
LA r6,0xFFFFF000
CMP r1,r6
JMP[NE] @fail
CMP r2,r0
JMP[NE] @fail
; (1,0) = base + 0x200
LA r1,@ctx
MOVI r2,1
MOVI r3,0
CALL @nten_ptr
LA r6,0xFFFFF200
CMP r1,r6
JMP[NE] @fail
CMP r2,r0
JMP[NE] @fail
; (0,1) = base + 0x10
LA r1,@ctx
MOVI r2,0
MOVI r3,1
CALL @nten_ptr
LA r6,0xFFFFF010
CMP r1,r6
JMP[NE] @fail
; (1,0x100000) crosses 4 GiB: base + 0x200 + 0x1000000 = 0x1_0FFFF200
LA r1,@ctx
MOVI r2,1
LA r3,0x100000
CALL @nten_ptr
LA r6,0x00FFF200
CMP r1,r6
JMP[NE] @fail
CMP r2,r13
JMP[NE] @fail
; high-half stride: s0_hi=1
LA r1,@ctx
LA r2,0
MOVI r3,0
MOVI r4,1
MOVI r5,1
MOVI r6,0
MOVI r7,1
MOVI r8,0
MOVI r9,0
CALL @nten_init
LA r1,@ctx
MOVI r2,1
MOVI r3,0
CALL @nten_ptr
CMP r1,r0
JMP[NE] @fail
CMP r2,r13
JMP[NE] @fail
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
.word 0,0,0,0,0,0,0,0,0,0
s_pass:
.str "TENSOR PASS\n"
s_fail:
.str "TENSOR FAIL\n"
