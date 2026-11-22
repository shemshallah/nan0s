; xlate64_byte.nas - NaN 64-bit byte memory block.
; STB 0xAB to byte address 0x4000, LDB it, CMP, JMP[EQ] 0x200.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@src
MOVI r2,6
LA r3,0x10000
MOVI r4,0
CALL @x64_block
HALT
src:
.raw FFF8_01404000_F8FF      ; MOVI r4,0x4000
.raw FFF8_012000AB_F8FF      ; MOVI r2,0xAB
.raw FFF8_2B240000_F8FF      ; STB r2,r4,0
.raw FFF8_2A140000_F8FF      ; LDB r1,r4,0
.raw FFF8_07010002_F8FF      ; CMP r1,r2
.raw FFF1_0A000200_F17F      ; JMP[EQ] 0x200
