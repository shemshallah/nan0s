.org 0
JMP @main
.include "../lib/mpp.nas"
main:
MOVI r13,1
LA r1,@src
SHL r1,r1,2
CALL @mp_has_func
ADDI r1,r1,48
PUTC r1
MOVI r1,10
PUTC r1
LA r1,@src
SHL r1,r1,2
ST r1,r0,#W_MPCUR
LD r1,r0,#W_MPCUR
ST r1,r0,@startp
HALT
startp:
.word 0
src:
.str "#define F(x) 1\n"
