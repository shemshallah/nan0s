.org 0
JMP @main
.include "../lib/mpp.nas"
main:
MOVI r13,1
MOVI r2,40
CALL @mp_idc
ADDI r1,r1,48
PUTC r1
MOVI r2,65
CALL @mp_idc
ADDI r1,r1,48
PUTC r1
MOVI r2,48
CALL @mp_idc
ADDI r1,r1,48
PUTC r1
MOVI r1,10
PUTC r1
HALT
