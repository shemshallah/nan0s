; xlate64_mem2.nas - NaN 64-bit STW/LDN/BSWAPM block.
; STW class 10, LDN=10, LD value, BSWAPM twice, LDN class 5.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@src
MOVI r2,23
LA r3,0x10000
MOVI r4,0
CALL @x64_block
HALT
src:
MOVI r1,0x1234
MOVI r2,0x5678
MOVHI r2,0x9ABC
MOVI r3,0x100
MOVI r4,10
STW r2,r3,r4
LDN r5,r3,0
LD r6,r3,0
BSWAPM r3,0
BSWAPM r3,0
LD r9,r3,0
SUB r7,r5,r4
SUB r8,r6,r2
ADD r1,r7,r8
SUB r9,r9,r2
ADD r1,r1,r9
ADDI r1,r1,45
MOVI r10,5
STW r2,r3,r10
LDN r11,r3,0
SUB r11,r11,r10
ADD r1,r1,r11
HALT
