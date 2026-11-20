.org 0
JMP @main
.include "../lib/mpp.nas"
main:
MOVI r13,1
LA r1,@src
SHL r1,r1,2
ADD r1,r1,r13
ST r1,r0,#W_MPCUR
CALL @mp_skipsp
LA r2,@mp_s_define
CALL @mp_match_word
ADDI r1,r1,48
PUTC r1
MOVI r1,32
PUTC r1
; print cursor offset from source
LD r1,r0,#W_MPCUR
LA r2,@src
SHL r2,r2,2
SUB r1,r1,r2
ADDI r1,r1,48
CMP r1,r2
PUTC r1
MOVI r1,10
PUTC r1
HALT
src:
.str "#define F(x) 1\n"
