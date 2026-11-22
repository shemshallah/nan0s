; xlate64_mem.nas - NaN 64-bit memory block.
; ST 0x12345678 to word 0x1000, LD it back, CMP, JMP[EQ] 0x200.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@src
MOVI r2,7
LA r3,0x10000
MOVI r4,0
CALL @x64_block
HALT
src:
.raw FFF8_01401000_F8FF      ; MOVI r4,0x1000
.raw FFF8_01205678_F8FF      ; MOVI r2,0x5678
.raw FFF8_02201234_F8FF      ; MOVHI r2,0x1234
.raw FFF8_09240000_F8FF      ; ST r2,r4,0
.raw FFF8_08140000_F8FF      ; LD r1,r4,0
.raw FFF8_07010002_F8FF      ; CMP r1,r2
.raw FFF1_0A000200_F17F      ; JMP[EQ] 0x200
