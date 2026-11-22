; q4dot_test.nas - VDP4B4: 8 Q4 weights x 8 i8 activations per lane.
; Lane 0: [1,-1,2,-2,3,-3,4,-4] x [1..8] = -10
; Lane 1: eight 7 x eight 1 = 56
; Lane 2: eight -8 x eight 127 = -8128
; Lane 3: [0..7] x [0..7] = 140
; Then b=15 must wrap to V0 for the second activation vector, giving 56.
.org 0
JMP @main
main:
MOVI r13,1
; lane 0
LA r1,0xC4D3E2F1
VSET r1,r1,0
LA r1,0x04030201
VSET r2,r1,0
LA r1,0x08070605
VSET r3,r1,0
; lane 1
LA r1,0x77777777
VSET r1,r1,1
LA r1,0x01010101
VSET r2,r1,1
VSET r3,r1,1
; lane 2
LA r1,0x88888888
VSET r1,r1,2
LA r1,0x7F7F7F7F
VSET r2,r1,2
VSET r3,r1,2
; lane 3
LA r1,0x76543210
VSET r1,r1,3
LA r1,0x03020100
VSET r2,r1,3
LA r1,0x07060504
VSET r3,r1,3
VDP4B4 r4,r1,r2
VGET r3,r4,0
CALL @ph
VGET r3,r4,1
CALL @ph
VGET r3,r4,2
CALL @ph
VGET r3,r4,3
CALL @ph
; b=15 -> second activation vector wraps to V0
VZERO r5
LA r1,0x77777777
VSET r5,r1,0
VZERO r15
LA r1,0x01010101
VSET r15,r1,0
VSET r0,r1,0
VDP4B4 r6,r5,r15
VGET r3,r6,0
CALL @ph
LA r1,@s_pass
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
.str "Q4 PASS\n"
