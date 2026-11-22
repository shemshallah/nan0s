; xlate64_div.nas - NaN 64-bit signed/unsigned DIV/MOD block.
; -10/3=-3, -10%3=-1, 10/3=3, 10%3=1, then zero-divisor DIVU/MODU (0,10).
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@src
MOVI r2,19
LA r3,0x10000
MOVI r4,0
CALL @x64_block
HALT
src:
MOVI r1,0xFFF6
MOVHI r1,0xFFFF
MOVI r2,3
DIV r3,r1,r2
MOD r4,r1,r2
MOVI r5,10
MOVI r6,3
DIVU r7,r5,r6
MODU r8,r5,r6
ADD r1,r3,r4
ADD r1,r1,r7
ADD r1,r1,r8
ADDI r1,r1,45
MOVI r9,0
DIVU r10,r5,r9
MODU r11,r5,r9
ADD r1,r1,r10
ADD r1,r1,r11
HALT
