; hello.nas - first NaN program assembled and run inside NANIX.
; It is seeded into / so the shell can run: asm /hello.nas
.org 0
MOVI r1,72
PUTC r1
MOVI r1,73
PUTC r1
MOVI r1,10
PUTC r1
HALT
