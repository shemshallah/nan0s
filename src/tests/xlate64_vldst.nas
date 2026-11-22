; xlate64_vldst.nas - NaN 64-bit VLOAD/VSTORE.
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
MOVI r1,0x3344
MOVHI r1,0x1122
MOVI r2,0x100
MOVI r3,10
STW r1,r2,r3
MOVI r4,0x400
VLOAD r5,r4
VGET r6,r5,0
SUB r6,r6,r1
MOVI r7,0xCCDD
MOVHI r7,0xAABB
VSET r8,r7,0
MOVI r9,0x500
VSTORE r8,r9
VLOAD r11,r9
VGET r12,r11,0
SUB r12,r12,r7
ADD r1,r6,r12
ADDI r1,r1,45
HALT
