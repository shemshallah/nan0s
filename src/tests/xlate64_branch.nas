; xlate64_branch.nas - NaN 64-bit conditional block.
; CMP 10,3 sets k=0 (FLAGM=1); JMP[GT] has n=1, so the branch is taken.
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
.raw FFF8_0110000A_F8FF      ; MOVI r1,10
.raw FFF8_01200003_F8FF      ; MOVI r2,3
.raw FFF8_07010002_F8FF      ; CMP r1,r2
.raw 7FF1_0A000200_F1FF      ; JMP[GT] 0x200
