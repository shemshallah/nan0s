; xlate64_port.nas - translator OUTL/INL proof (one 6-word block).
.org 0
JMP @main
.include "../translate/x64_block.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@p0
MOVI r2,6
LA r3,0x10000
MOVI r4,6
CALL @x64_block
HALT
p0:
MOVI r1,0x1234
MOVI r2,0x4E01
OUTL r1,r2
MOVI r2,0x4E01
INL r1,r2
HALT
