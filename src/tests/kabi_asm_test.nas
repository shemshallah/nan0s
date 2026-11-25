; kabi_asm_test.nas - assembler/disassembler round-trip for the kernel ABI ops.
; 4D INL da, 4E SVC i, 4F SVCRET.  Nothing here executes.
INL r1,r2
INL[EQ] r3,r4
SVC 0
SVC 7
SVC[EQ] 22
SVCRET
SVCRET[NE]
OUTL r1,r2
HALT
