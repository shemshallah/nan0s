; xlate64_vdp4b4.nas - Q4 weights (all 1) x eight int8 ones = 8.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@src
MOVI r2,12
LA r3,0x10000
MOVI r4,0
CALL @x64_block
HALT
src:
MOVI r1,0x1111
MOVHI r1,0x1111
MOVI r2,0x0101
MOVHI r2,0x0101
MOVI r3,0x0101
MOVHI r3,0x0101
VBCAST r1,r1
VBCAST r2,r2
VBCAST r3,r3
VDP4B4 r4,r1,r2
VGET r5,r4,0
ADD r1,r5,r0
HALT
