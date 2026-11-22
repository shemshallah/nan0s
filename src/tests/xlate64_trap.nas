; xlate64_trap.nas - unsupported opcode produces a runtime trap.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@src
MOVI r2,3
LA r3,0x10000
MOVI r4,0
CALL @x64_block
HALT
src:
MOVI r1,7
VPOKE r2,r3
HALT
