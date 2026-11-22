; xlate64_prog.nas - three-block NaN 64-bit program:
; PC0: MOVI r1,0; MOVI r2,3
; PC2: ADDI r1,r1,1; CMP r1,r2; JMP[LT] PC2
; PC5: HALT
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@p0
MOVI r2,2
LA r3,0x10000
MOVI r4,2
CALL @x64_block
LA r1,@p2
MOVI r2,3
LA r3,0x11000
MOVI r4,5
CALL @x64_block
LA r1,@p5
MOVI r2,1
LA r3,0x12000
MOVI r4,5
CALL @x64_block
HALT
p0:
MOVI r1,0
MOVI r2,3
p2:
ADDI r1,r1,1
CMP r1,r2
JMP[LT] 2
p5:
HALT
