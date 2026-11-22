; xlate64_fp.nas - NaN 64-bit scalar FP block.
; 1.5+2.25=3.75, 1.5-2.25=-0.75, 1.5*2.25=3.375, 1.5/2.25=0.6667,
; sqrt(4)=2, (int)7=7.0.  Convert results back to ints and sum to 45;
; then FCMP 3.75 < 2.25 is false, so use 1.5 vs 2.25 -> LT taken.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@p0
MOVI r2,28
LA r3,0x10000
MOVI r4,0xBAD
CALL @x64_block
LA r1,@p2
MOVI r2,2
LA r3,0x11000
MOVI r4,0xBAD
CALL @x64_block
HALT
p0:
MOVI r1,0
MOVHI r1,0x3FC0
MOVI r2,0
MOVHI r2,0x4010
FADD r3,r1,r2
FSUB r4,r1,r2
FMUL r5,r1,r2
FDIV r6,r1,r2
MOVI r7,0
MOVHI r7,0x4080
FSQRT r8,r7
MOVI r9,7
CVTIF r10,r9
CVTFI r11,r3
CVTFI r12,r4
CVTFI r13,r5
CVTFI r14,r6
CVTFI r15,r8
ADD r9,r11,r12
ADD r9,r9,r13
ADD r9,r9,r14
ADD r9,r9,r15
CVTFI r15,r10
ADD r9,r9,r15
ADDI r9,r9,30
MOVI r14,45
CMP r9,r14
JMP[EQ] 2
p2:
FCMP r1,r2
JMP[LT] 0x200
