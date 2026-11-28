; nansched_native_test.nas - nansched_mp policy with the real native nansmp ops.
; One logical CPU is enough here; the same context/task API is AP-ready.
.equ CTX   0x20000
.equ OPS   0x20800
.equ ARENA 0x21000
.equ STACK 0x7000
.org 0
JMP @main
.include "../lib/nansmp.nas"
.include "../lib/nansched_mp.nas"
.include "../lib/nansched_nansmp.nas"
main:
MOVI r13,1
MOVI r14,#STACK
MOVI r1,126
PUTC r1
LA r1,#CTX
MOVI r2,1
LA r3,#ARENA
MOVI r4,16
MOVI r5,4
LA r6,#OPS
CALL @nsched_init
CMP r1,r0
JMP[NE] @bad
LA r1,#CTX
CALL @nsched_bind_nansmp
CMP r1,r0
JMP[NE] @bad
LA r1,#CTX
MOVI r2,1
MOVI r3,0
MOVI r4,1
MOVI r5,5
MOVI r6,0
CALL @nsched_task_add
CMP r1,r0
JMP[NE] @bad
LA r1,#CTX
MOVI r2,0
MOVI r3,1
CALL @nsched_push
CMP r1,r0
JMP[NE] @bad
LA r1,#CTX
MOVI r2,0
CALL @nsched_pop
MOVI r4,1
CMP r1,r4
JMP[NE] @bad
LA r1,#CTX
MOVI r2,0
CALL @nsched_qlen
CMP r1,r0
JMP[NE] @bad
MOVI r1,79
PUTC r1
MOVI r1,75
PUTC r1
MOVI r1,10
PUTC r1
HALT
bad:
MOVI r1,33
PUTC r1
HALT
.org 0x10000
