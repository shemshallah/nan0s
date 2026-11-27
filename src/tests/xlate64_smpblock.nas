; xlate64_smpblock.nas - one immutable block for the real-AP block runtime.
;
; The block adds 1 to the per-core r1, stores it through the per-core r2 and
; r3 into shared guest word memory, then halts.  The native AP gate runs the
; same bytes on two physical CPUs under per-core CR3 roots, so 0x50000 is a
; different 4 KiB state page on each CPU while 0x51000 (code) and 0x200000
; (guest words) stay shared identity mappings.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@p0
MOVI r2,4
LA r3,0x20000
MOVI r4,4
CALL @x64_block
HALT

p0:
ADDI r1,r1,1
ST r1,r2,0
ST r1,r3,0
HALT
