; xlate64_abi.nas - translator SVC/SVCRET + control-port proof.
;
; Block 0: set kentry/frame/kstack through OUTL, r1=0x10, SVC 7.
; Block 1: ADDI r1,1; HALT.
; Kernel: read frame[20] (must be 7), return 0x99 in frame[21], SVCRET.
; Expected: r1=0x9A, XPC=11.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@p0
MOVI r2,11
LA r3,0x20000
MOVI r4,11
CALL @x64_block
LA r1,@p1
MOVI r2,2
LA r3,0x21000
MOVI r4,13
CALL @x64_block
LA r1,@p2
MOVI r2,5
LA r3,0x22000
MOVI r4,18
CALL @x64_block
HALT

p0:
MOVI r1,13
MOVI r2,0x4E00
OUTL r1,r2
MOVI r1,0x1000
MOVI r2,0x4E01
OUTL r1,r2
MOVI r1,0x3000
MOVI r2,0x4E03
OUTL r1,r2
MOVI r1,0x10
SVC 7

p1:
ADDI r1,r1,1
HALT

p2:
MOVI r2,0x1000
LD r3,r2,20
ADDI r3,r3,0x92
ST r3,r2,21
SVCRET
