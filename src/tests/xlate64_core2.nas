; xlate64_core2.nas - one immutable block for per-core CR3 dispatch.
;
; The block adds 1 to the per-core r1 and stores it through the per-core r2
; into shared guest memory, then halts.  The native gate runs the same bytes
; under two different CR3 roots so 0x50000 maps to different state pages.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@p0
MOVI r2,3
LA r3,0x20000
MOVI r4,3
CALL @x64_block
HALT

p0:
ADDI r1,r1,1
ST r1,r2,0
HALT
