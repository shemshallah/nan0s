; smp_ap_guest_test.nas - every AP executes real guest NaN code concurrently.
;
; CPU0 publishes an entry PC and guest stack through the nansmp mailbox
; ports, then HALTs.  Each AP maps virtual 0x8000 to a private interpreter
; state page, enables paging, and runs the guest program at word 0x1000:
; 1000 atomic fetch-adds on the shared word 0x20000.  APIC id 1 waits until
; every AP has finished, prints "AP <hex>" and OK.  This is the multi-AP
; per-CPU interpreter state proof.
.equ CNT   0x20000
.equ ITER  1000
.equ APENT 0x1000
.equ APSTK 0x3C000
.org 0
JMP @main
.include "../lib/nansmp.nas"
.org 0x1000
ap_main:
MOVI r1,0x4E14
INL r7,r1
MOVI r6,#ITER
ap_loop:
LA r1,#CNT
MOVI r2,1
CALL @nsp_fetch_add
ADDI r6,r6,0xFFFF
JMP[NE] @ap_loop
; only APIC id 1 reports; wait until every AP has finished its increments
MOVI r1,1
CMP r7,r1
JMP[NE] @ap_halt
MOVI r1,0x4E0F
INL r8,r1
ADDI r8,r8,0xFFFF
MOVI r9,#ITER
MUL r8,r8,r9
LA r9,#CNT
LA r10,0x4000000
ap_poll:
LD r1,r9,0
CMP r1,r8
JMP[EQ] @ap_print
ADDI r10,r10,0xFFFF
JMP[NE] @ap_poll
JMP @ap_halt
ap_print:
MOVI r1,65
PUTC r1
MOVI r1,80
PUTC r1
MOVI r1,32
PUTC r1
LD r1,r9,0
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
ap_halt:
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
