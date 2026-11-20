.org 0
JMP @main
.include "../lib/mpp.nas"
main:
MOVI r13,1
LA r1,#MPOUT1
ST r1,r0,#W_MPDST
MOVI r1,65
CALL @mp_putc
MOVI r1,66
CALL @mp_putc
MOVI r1,67
CALL @mp_putc
MOVI r1,68
CALL @mp_putc
MOVI r1,0
CALL @mp_putc
HALT
