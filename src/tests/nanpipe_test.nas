; nanpipe_test.nas - NaN16 pipe primitive: write/read/wrap/close.
.org 0
JMP @main
.include "../lib/ncc.nas"
.include "../lib/nanpipe.nas"
.equ H 0xF0790
.equ BUF 0x250000
main:
MOVI r13,1
CALL @np_open
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,#H
; ---- hello ----
LD r1,r0,#H
LA r2,@hello
SHL r2,r2,2
MOVI r3,5
CALL @np_write
MOVI r4,5
CMP r1,r4
JMP[NE] @fail
LD r1,r0,#H
LA r2,@got
SHL r2,r2,2
MOVI r3,5
CALL @np_read
MOVI r4,5
CMP r1,r4
JMP[NE] @fail
LA r1,@got
SHL r1,r1,2
LDB r2,r1,0
MOVI r3,104
CMP r2,r3
JMP[NE] @fail
LDB r2,r1,4
MOVI r3,111
CMP r2,r3
JMP[NE] @fail
; ---- fill 3000 'A' at BUF ----
LA r5,#BUF
SHL r5,r5,2
MOVI r6,3000
MOVI r7,65
fillA:
STB r7,r5,0
ADD r5,r5,r13
SUB r6,r6,r13
JMP[NE] @fillA
LD r1,r0,#H
LA r2,#BUF
SHL r2,r2,2
MOVI r3,3000
CALL @np_write
MOVI r4,3000
CMP r1,r4
JMP[NE] @fail
; drain 1000
LD r1,r0,#H
LA r2,@got
SHL r2,r2,2
MOVI r3,1000
CALL @np_read
MOVI r4,1000
CMP r1,r4
JMP[NE] @fail
; write 1000 'B' (wrap)
LA r5,#BUF
SHL r5,r5,2
MOVI r6,1000
MOVI r7,66
fillB:
STB r7,r5,0
ADD r5,r5,r13
SUB r6,r6,r13
JMP[NE] @fillB
LD r1,r0,#H
LA r2,#BUF
SHL r2,r2,2
MOVI r3,1000
CALL @np_write
MOVI r4,1000
CMP r1,r4
JMP[NE] @fail
; read 3000: 2000 A then 1000 B
LD r1,r0,#H
LA r2,#BUF
SHL r2,r2,2
MOVI r3,3000
CALL @np_read
MOVI r4,3000
CMP r1,r4
JMP[NE] @fail
LA r1,#BUF
SHL r1,r1,2
LDB r2,r1,0
MOVI r3,65
CMP r2,r3
JMP[NE] @fail
ADDI r4,r1,1999
LDB r2,r4,0
MOVI r3,65
CMP r2,r3
JMP[NE] @fail
ADDI r4,r1,2000
LDB r2,r4,0
MOVI r3,66
CMP r2,r3
JMP[NE] @fail
ADDI r4,r1,2999
LDB r2,r4,0
MOVI r3,66
CMP r2,r3
JMP[NE] @fail
; ---- second pipe and close ----
CALL @np_open
CMP r1,r0
JMP[EQ] @fail
MOVI r4,0
ST r4,r0,#H
LD r1,r0,#H
CALL @np_close
LD r1,r0,#H
LA r2,@got
SHL r2,r2,2
MOVI r3,1
CALL @np_read
CMP r1,r0
JMP[NE] @fail
; close the original pipe (saved id was overwritten); open a fresh one
CALL @np_open
CMP r1,r0
JMP[EQ] @fail
MOVI r4,0
ST r4,r0,#H
LD r1,r0,#H
CALL @np_close
MOVI r1,80
PUTC r1
MOVI r1,65
PUTC r1
MOVI r1,83
PUTC r1
MOVI r1,83
PUTC r1
MOVI r1,10
PUTC r1
HALT
fail:
MOVI r1,70
PUTC r1
MOVI r1,65
PUTC r1
MOVI r1,73
PUTC r1
MOVI r1,76
PUTC r1
MOVI r1,10
PUTC r1
HALT
hello:
.str "hello"
got:
.word 0,0
