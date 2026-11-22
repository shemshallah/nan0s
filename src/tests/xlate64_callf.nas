; xlate64_callf.nas - NaN 64-bit CALLF (24-bit target).
; PC0: MOVI r1,7 ; CALLF 4
; PC2: ADDI r1,r1,1 ; HALT
; PC4: ADDI r1,r1,10 ; RET
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
MOVI r2,2
LA r3,0x11000
MOVI r4,0
CALL @x64_block
LA r1,@p4
MOVI r2,2
LA r3,0x12000
MOVI r4,2
CALL @x64_block
HALT
p0:
MOVI r1,7
CALLF 4
p2:
ADDI r1,r1,1
HALT
p4:
ADDI r1,r1,10
RET
