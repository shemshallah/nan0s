; nanfs_svc_test.nas - bare-metal NaN SVC file interface.
;
; kinit programs the S1 kernel ports, then user code calls SVC 4/5/6/7/8.
; The NaN kernel entry dispatches into the NPAF machine filesystem.  No C
; service code and no machine-interface function table are involved.
.org 0
JMP @kinit
.include "../lib/ncc.nas"
.include "../lib/nankernel.nas"
.equ H 0xF0800
kinit:
MOVI r13,1
MOVI r1,0x4E01
LA r2,#KFRAME
OUTL r2,r1
MOVI r1,0x4E03
LA r2,#KSTACK
OUTL r2,r1
MOVI r1,0x4E00
LA r2,@kentry
OUTL r2,r1
JMP @user
user:
MOVI r13,1
; ---- create and write /svc.txt ----
LA r1,@path
SHL r1,r1,2
MOVI r2,1
SVC 4
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,#H
LD r1,r0,#H
LA r2,@msg
SHL r2,r2,2
MOVI r3,5
SVC 6
MOVI r4,5
CMP r1,r4
JMP[NE] @fail
LD r1,r0,#H
SVC 8
; ---- read it back ----
LA r1,@path
SHL r1,r1,2
MOVI r2,0
SVC 4
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,#H
LD r1,r0,#H
LA r2,@buf
SHL r2,r2,2
MOVI r3,5
SVC 5
MOVI r4,5
CMP r1,r4
JMP[NE] @fail
; ---- seek to 1 and read "ell" ----
LD r1,r0,#H
MOVI r2,1
MOVI r3,0
SVC 7
LD r1,r0,#H
LA r2,@buf2
SHL r2,r2,2
MOVI r3,3
SVC 5
MOVI r4,3
CMP r1,r4
JMP[NE] @fail
LD r1,r0,#H
SVC 8
; ---- verify ----
LA r1,@buf
SHL r1,r1,2
LDB r2,r1,0
MOVI r3,104
CMP r2,r3
JMP[NE] @fail
LDB r2,r1,4
MOVI r3,111
CMP r2,r3
JMP[NE] @fail
LA r1,@buf2
SHL r1,r1,2
LDB r2,r1,0
MOVI r3,101
CMP r2,r3
JMP[NE] @fail
LDB r2,r1,2
MOVI r3,108
CMP r2,r3
JMP[NE] @fail
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
path:
.str "/svc.txt"
msg:
.str "hello"
buf:
.word 0,0
buf2:
.word 0,0
