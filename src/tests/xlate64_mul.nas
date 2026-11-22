; xlate64_mul.nas - NaN 64-bit MUL/MULHU/BOOL block.
; 7*6=42; 42 XOR 6 = 44; 0x10000*0x10000 high = 1; 44+1=45.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@src
MOVI r2,11
LA r3,0x10000
MOVI r4,0
CALL @x64_block
HALT
src:
MOVI r1,7
MOVI r2,6
MUL r1,r1,r2
BOOL.6 r3,r1,r2
MOVI r5,0
MOVHI r5,1
MOVI r6,0
MOVHI r6,1
MULHU r4,r5,r6
ADD r1,r3,r4
HALT
