; narena_test.nas - alignment, overlap, mark/release, reset and exhaustion.
.org 0
JMP @main
.include "../lib/narena.nas"
main:
MOVI r13,1
LA r1,@ctx
LA r2,0x80000
LA r3,0x4000
CALL @nar_init

; p1 = base, 3 words
LA r1,@ctx
MOVI r2,3
MOVI r3,1
CALL @nar_alloc
LA r4,0x80000
CMP r1,r4
JMP[NE] @fail
ADD r10,r1,r0

; p2 = base+4, 3 words, align 4
LA r1,@ctx
MOVI r2,3
MOVI r3,4
CALL @nar_alloc
LA r4,0x80004
CMP r1,r4
JMP[NE] @fail
ADD r11,r1,r0

; p3 = base+16, 7 words, align 16
LA r1,@ctx
MOVI r2,7
MOVI r3,16
CALL @nar_alloc
LA r4,0x80010
CMP r1,r4
JMP[NE] @fail
ADD r12,r1,r0

; p4 = base+64, 1 word, align 64
LA r1,@ctx
MOVI r2,1
MOVI r3,64
CALL @nar_alloc
LA r4,0x80040
CMP r1,r4
JMP[NE] @fail

; fill and verify
LA r4,0x11111111
ST r4,r10,0
LA r4,0x22222222
ST r4,r10,1
LA r4,0x33333333
ST r4,r10,2
LA r4,0x44444444
ST r4,r11,0
LA r4,0x55555555
ST r4,r11,1
LA r4,0x66666666
ST r4,r11,2
LA r4,0x77777777
MOVI r5,0
fa:
ADD r6,r12,r5
ST r4,r6,0
ADD r5,r5,r13
MOVI r7,7
CMP r5,r7
JMP[LT] @fa
LA r5,0x88888888
ST r5,r1,0

LD r5,r10,0
LA r6,0x11111111
CMP r5,r6
JMP[NE] @fail
LD r5,r11,2
LA r6,0x66666666
CMP r5,r6
JMP[NE] @fail
LD r5,r12,6
LA r6,0x77777777
CMP r5,r6
JMP[NE] @fail

; mark / release / reuse
LA r1,@ctx
CALL @nar_mark
ADD r10,r1,r0
LA r1,@ctx
MOVI r2,10
MOVI r3,1
CALL @nar_alloc
ADD r11,r1,r0
LA r1,@ctx
ADD r2,r10,r0
CALL @nar_release
LA r1,@ctx
MOVI r2,10
MOVI r3,1
CALL @nar_alloc
CMP r1,r11
JMP[NE] @fail

; reset -> base
LA r1,@ctx
CALL @nar_reset
LA r1,@ctx
MOVI r2,1
MOVI r3,1
CALL @nar_alloc
LA r4,0x80000
CMP r1,r4
JMP[NE] @fail

; exhaustion
LA r1,@ctx
LA r2,0x4000
MOVI r3,1
CALL @nar_alloc
CMP r1,r0
JMP[NE] @fail

LA r1,@s_pass
CALL @puts
HALT
fail:
LA r1,@s_fail
CALL @puts
HALT
; puts: r1 = word address of NUL-terminated .str
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
.word 0,0,0,0
s_pass:
.str "ARENA PASS\n"
s_fail:
.str "ARENA FAIL\n"
