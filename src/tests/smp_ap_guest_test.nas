; smp_ap_guest_test.nas - one AP executes real guest NaN code.
;
; CPU0 publishes an entry PC and guest stack through the nansmp mailbox
; ports, then HALTs.  APIC id 1 wakes, reuses the (now idle) interpreter
; state page, and runs the guest program at word 0x1000: 1000 atomic
; fetch-adds on the shared word 0x20000, then prints "AP <hex>" and OK.
; APs other than id 1 park.  This is a single-AP handoff; per-CPU interpreter
; state/paging is the next step.
.equ CNT   0x20000
.equ ITER  1000
.equ APENT 0x1000
.equ APSTK 0x3C000
.org 0
JMP @main
.include "../lib/nansmp.nas"
.org 0x1000
ap_main:
MOVI r6,#ITER
ap_loop:
LA r1,#CNT
MOVI r2,1
CALL @nsp_fetch_add
ADDI r6,r6,0xFFFF
JMP[NE] @ap_loop
MOVI r1,65
PUTC r1
MOVI r1,80
PUTC r1
MOVI r1,32
PUTC r1
LA r2,#CNT
LD r1,r2,0
CALL @hex8
MOVI r1,10
PUTC r1
MOVI r1,79
PUTC r1
MOVI r1,75
PUTC r1
MOVI r1,10
PUTC r1
MOVI r1,0xF4
MOVI r2,0x10
OUTB r2,r1
HALT
.org 0x2000
main:
MOVI r13,1
MOVI r14,0xE000
LA r2,#CNT
ST r0,r2,0
MOVI r1,0x4E0F
INL r2,r1
ADDI r2,r2,0xFFFF
CMP r2,r0
JMP[EQ] @noap
MOVI r1,#APENT
MOVI r2,0x4E10
OUTL r1,r2
LA r1,#APSTK
MOVI r2,0x4E11
OUTL r1,r2
MOVI r1,0
MOVI r2,0x4E0D
OUTL r1,r2
MOVI r1,1
MOVI r2,0x4E12
OUTL r1,r2
HALT
noap:
MOVI r1,65
PUTC r1
MOVI r1,80
PUTC r1
MOVI r1,32
PUTC r1
MOVI r1,48
PUTC r1
MOVI r1,48
PUTC r1
MOVI r1,48
PUTC r1
MOVI r1,48
PUTC r1
MOVI r1,48
PUTC r1
MOVI r1,48
PUTC r1
MOVI r1,48
PUTC r1
MOVI r1,48
PUTC r1
MOVI r1,10
PUTC r1
MOVI r1,79
PUTC r1
MOVI r1,75
PUTC r1
MOVI r1,10
PUTC r1
MOVI r1,0xF4
MOVI r2,0x10
OUTB r2,r1
HALT
hex8:
MOVI r2,8
hex8_l:
ADD r3,r1,r0
SHR r3,r3,28
MOVI r4,10
CMP r3,r4
JMP[LT] @hex8_d
ADDI r3,r3,7
hex8_d:
ADDI r3,r3,48
PUTC r3
SHL r1,r1,4
ADDI r2,r2,0xFFFF
JMP[NE] @hex8_l
RET
.org 0x10000
