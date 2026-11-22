; xlate64_call.nas - NaN 64-bit CALL/RET program.
; PC0: MOVI r1,5 ; CALL 4
; PC2: ADDI r1,r1,1 ; HALT
; PC4: MOVI r2,10 ; ADD r1,r1,r2 ; RET
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
MOVI r4,3
CALL @x64_block
LA r1,@p4
MOVI r2,3
LA r3,0x12000
MOVI r4,2
CALL @x64_block
HALT
p0:
MOVI r1,5
CALL 4
p2:
ADDI r1,r1,1
HALT
p4:
MOVI r2,10
ADD r1,r1,r2
RET
