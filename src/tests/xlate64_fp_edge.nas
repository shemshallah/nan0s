; xlate64_fp_edge.nas - NaN 64-bit scalar FP edge cases.
; 0/0 -> qNaN -> 0; sqrt(-1) -> qNaN -> 0;
; (int)+inf -> INT_MAX; (int)-inf -> INT_MIN; sum = -1, +46 = 45.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@src
MOVI r2,22
LA r3,0x10000
MOVI r4,0
CALL @x64_block
HALT
src:
MOVI r1,0
MOVI r2,0
FDIV r3,r1,r2
MOVI r4,0
MOVHI r4,0xBF80
FSQRT r5,r4
MOVI r6,0
MOVHI r6,0x3F80
MOVI r7,0
FDIV r8,r6,r7
MOVI r9,0
MOVHI r9,0xBF80
FDIV r10,r9,r7
CVTFI r11,r3
CVTFI r12,r5
CVTFI r13,r8
CVTFI r14,r10
ADD r1,r11,r12
ADD r1,r1,r13
ADD r1,r1,r14
ADDI r1,r1,46
HALT
