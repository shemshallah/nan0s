; xlate64_block.nas - NaN bit block driver -> x86-64.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@src
MOVI r2,4
LA r3,0x10000
MOVI r4,0
CALL @x64_block
HALT
src:
.word 0x0110002A      ; MOVI r1,42
.word 0x03110001      ; ADD r1,r1,r1
.word 0x01200004      ; MOVI r2,4
.word 0x04110002      ; SUB r1,r1,r2
