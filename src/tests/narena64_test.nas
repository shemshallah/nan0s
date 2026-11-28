; narena64_test.nas - 64-bit arena sizing/alignment and high-half pointers.
.org 0
JMP @main
.include "../lib/n64.nas"
.include "../lib/narena64.nas"
main:
MOVI r13,1
LA r1,@ctx
LA r2,0x80000
MOVI r3,1
LA r4,0x4000
MOVI r5,0
CALL @nar64_init
; p1 = 0x1_00080000
LA r1,@ctx
MOVI r2,3
MOVI r3,0
MOVI r4,4
CALL @nar64_alloc
LA r6,0x80000
CMP r1,r6
JMP[NE] @fail
CMP r2,r13
JMP[NE] @fail
; p2 = 0x1_00080010
LA r1,@ctx
MOVI r2,3
MOVI r3,0
MOVI r4,16
CALL @nar64_alloc
LA r6,0x80010
CMP r1,r6
JMP[NE] @fail
CMP r2,r13
JMP[NE] @fail
; p3 = 0x1_00080040
LA r1,@ctx
MOVI r2,1
MOVI r3,0
MOVI r4,64
CALL @nar64_alloc
LA r6,0x80040
CMP r1,r6
JMP[NE] @fail
CMP r2,r13
JMP[NE] @fail
; mark = 65
LA r1,@ctx
CALL @nar64_mark
MOVI r6,65
CMP r1,r6
JMP[NE] @fail
CMP r2,r0
JMP[NE] @fail
; release and reallocate the same pointer
LA r1,@ctx
ADD r2,r1,r0
LD r2,r2,4
LD r3,r1,5
CALL @nar64_release
LA r1,@ctx
MOVI r2,10
MOVI r3,0
MOVI r4,1
CALL @nar64_alloc
LA r6,0x80041
CMP r1,r6
JMP[NE] @fail
; 64-bit overflow must fail
LA r1,@ctx
LA r2,0xFFFFFFFF
MOVI r3,1
MOVI r4,1
CALL @nar64_alloc
CMP r1,r0
JMP[NE] @fail
CMP r2,r0
JMP[NE] @fail
; reset -> base again
LA r1,@ctx
CALL @nar64_reset
LA r1,@ctx
MOVI r2,1
MOVI r3,0
MOVI r4,1
CALL @nar64_alloc
LA r6,0x80000
CMP r1,r6
JMP[NE] @fail
CMP r2,r13
JMP[NE] @fail
; carry across the 4 GiB boundary
LA r1,@ctx2
LA r2,0xFFFFFF00
MOVI r3,0
LA r4,0x20000
MOVI r5,0
CALL @nar64_init
LA r1,@ctx2
MOVI r2,0x200
MOVI r3,0
MOVI r4,1
CALL @nar64_alloc
LA r6,0xFFFFFF00
CMP r1,r6
JMP[NE] @fail
CMP r2,r0
JMP[NE] @fail
LA r1,@ctx2
MOVI r2,0x100
MOVI r3,0
MOVI r4,1
CALL @nar64_alloc
MOVI r6,0x100
CMP r1,r6
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
.word 0,0,0,0,0,0,0,0
ctx2:
.word 0,0,0,0,0,0,0,0
s_pass:
.str "ARENA64 PASS\n"
s_fail:
.str "ARENA64 FAIL\n"
