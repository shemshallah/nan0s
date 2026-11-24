; ndbg_call_cart.nas - a CALL/RET pair for terminal next/finish gating.
; next must step over the CALL; finish must run out of the shadow frame.
.org 8192
JMP @main
main:
MOVI r13,1
CALL @sub
MOVI r1,0xAA
HALT
sub:
MOVI r2,0x55
RET
