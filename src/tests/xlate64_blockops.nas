; xlate64_blockops.nas - NaN 64-bit BCOPY/BFILL.
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
MOVI r1,0xCAFE
MOVI r2,0x100
MOVI r3,10
STW r1,r2,r3
MOVI r4,0x200
MOVI r5,1
BCOPY r4,r2,r5
LD r6,r4,0
SUB r6,r6,r1
MOVI r7,0x300
MOVI r8,3
MOVI r9,0xBEEF
BFILL r7,r9,r8
LD r10,r7,0
SUB r10,r10,r9
LDN r11,r7,0
MOVI r12,10
SUB r11,r11,r12
ADD r1,r6,r10
ADD r1,r1,r11
ADDI r1,r1,45
HALT
