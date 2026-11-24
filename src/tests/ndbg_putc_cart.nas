; ndbg_putc_cart.nas - tiny cart for the serial-capture gate.
; It prints HELLO through PUTC and halts.
.org 8192
MOVI r13,1
MOVI r1,0x1234
MOVI r2,0x2020
MOVI r3,5
STW r1,r2,r3
MOVI r1,72
PUTC r1
MOVI r1,69
PUTC r1
MOVI r1,76
PUTC r1
MOVI r1,76
PUTC r1
MOVI r1,79
PUTC r1
MOVI r1,10
PUTC r1
HALT
