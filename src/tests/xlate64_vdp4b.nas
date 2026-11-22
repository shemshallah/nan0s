; xlate64_vdp4b.nas - NaN 64-bit VDP4B.
; bytes 01 02 03 04 dot 05 06 07 08 = 5+14+24+32 = 70.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@src
MOVI r2,9
LA r3,0x10000
MOVI r4,0
CALL @x64_block
HALT
src:
MOVI r1,0x0304
MOVHI r1,0x0102
MOVI r2,0x0708
MOVHI r2,0x0506
VBCAST r1,r1
VBCAST r2,r2
VDP4B r3,r1,r2
VGET r4,r3,0
ADD r1,r4,r0
HALT
