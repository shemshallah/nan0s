; xlate64_putc.nas - PUTC writes a byte to COM1.
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@src
MOVI r2,3
LA r3,0x10000
MOVI r4,0
CALL @x64_block
HALT
src:
MOVI r1,0x41
PUTC r1
HALT
