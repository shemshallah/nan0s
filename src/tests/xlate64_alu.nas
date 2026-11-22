; xlate64_alu.nas - NaN 64-bit ALU/flag block.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@src
MOVI r2,8
LA r3,0x10000
MOVI r4,0
CALL @x64_block
HALT
src:
.word 0x0110FFFF      ; MOVI r1,0xFFFF
.word 0x02100001      ; MOVHI r1,1
.word 0x29110001      ; ADDI r1,r1,1
.word 0x05110004      ; SHL r1,r1,4
.word 0x06110004      ; SHR r1,r1,4
.word 0x27110004      ; SAR r1,r1,4
.word 0x01200002      ; MOVI r2,2
.word 0x07010002      ; CMP r1,r2
