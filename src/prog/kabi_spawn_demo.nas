; kabi_spawn_demo.nas - process table, spawn, wait, and round-robin preemption.
;
; The boot path creates process 0 (the parent) and two program descriptors.
; The parent calls SVC 9 twice, then SVC 10 twice:
;   9  spawn(descriptor_ptr) -> pid
;   10 wait(pid)            -> exit status
; The kernel allocates a process slot, builds its trap frame and region table,
; and schedules it.  Children print '1' or '2', exit with SVC 1, and the
; parent prints OK before exiting.  The kernel halts when no process is
; runnable.  Timer IRQs rotate the run queue.
;
; This is a differential gate: the C oracle and x86_64 S1 must agree exactly.

.equ FRAME0    0x1800
.equ FR_BASE   0x1800
.equ RT_BASE   0x1C00
.equ BOOTF     0x2100
.equ KSTACK    0x3000
.equ T_STATE   0x2000
.equ T_WAIT    0x2004
.equ T_CODE    0x2008
.equ T_DATA    0x200C
.equ CUR       0x2020
.equ DESCP     0x2021
.equ FP        0x2022
.equ PID1      0x4500
.equ PID2      0x4501
.equ DESC1     0x4600
.equ DESC2     0x4640
.equ PSTACK    0x47F0
.equ C1STACK   0x87F0
.equ C2STACK   0xC7F0
.equ PARENT    0x4000
.equ PDATA     0x4400
.equ CHILD1    0x8000
.equ C1DATA    0x8400
.equ CHILD2    0xC000
.equ C2DATA    0xC400
.equ SCR0      0x10000
.equ SCR1      0x20000
.equ SCR2      0x30000

.org 0
boot:
  MOVI r13,1
  ; parent frame
  MOVI r1,#FRAME0
  MOVI r2,24
  MOVI r3,0
bz:
  ST r3,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP[NE] @bz
  MOVI r1,1
  ST r1,r0,#FRAME0+13
  MOVI r1,#PSTACK
  ST r1,r0,#FRAME0+14
  ST r1,r0,#FRAME0+22
  MOVI r1,@parent_entry
  ST r1,r0,#FRAME0+16

  ; parent region table: code RX, data RW, scratch RW
  MOVI r1,#PARENT
  ST r1,r0,#RT_BASE+0
  MOVI r1,0x400
  ST r1,r0,#RT_BASE+1
  ST r0,r0,#RT_BASE+2
  MOVI r1,5
  ST r1,r0,#RT_BASE+3
  MOVI r1,#PDATA
  ST r1,r0,#RT_BASE+4
  MOVI r1,0x400
  ST r1,r0,#RT_BASE+5
  ST r0,r0,#RT_BASE+6
  MOVI r1,3
  ST r1,r0,#RT_BASE+7
  MOVI r1,0
  MOVHI r1,1
  ST r1,r0,#RT_BASE+8
  MOVI r1,0x1000
  ST r1,r0,#RT_BASE+9
  ST r0,r0,#RT_BASE+10
  MOVI r1,3
  ST r1,r0,#RT_BASE+11
  ST r0,r0,#RT_BASE+12
  ST r0,r0,#RT_BASE+13
  ST r0,r0,#RT_BASE+14
  ST r0,r0,#RT_BASE+15

  ; process table
  MOVI r1,1
  ST r1,r0,#T_STATE
  ST r0,r0,#T_WAIT
  ST r0,r0,#T_CODE
  MOVI r1,0
  MOVHI r1,1
  ST r1,r0,#T_DATA
  ST r0,r0,#T_STATE+1
  ST r0,r0,#T_STATE+2
  ST r0,r0,#T_STATE+3
  ST r0,r0,#CUR

  ; descriptor 1
  MOVI r1,#CHILD1
  ST r1,r0,#DESC1+0
  MOVI r1,#C1STACK
  ST r1,r0,#DESC1+1
  MOVI r1,#CHILD1
  ST r1,r0,#DESC1+2
  MOVI r1,0x400
  ST r1,r0,#DESC1+3
  MOVI r1,#C1DATA
  ST r1,r0,#DESC1+4
  MOVI r1,0x400
  ST r1,r0,#DESC1+5
  MOVI r1,0
  MOVHI r1,2
  ST r1,r0,#DESC1+6
  MOVI r1,0x1000
  ST r1,r0,#DESC1+7
  ; descriptor 2
  MOVI r1,#CHILD2
  ST r1,r0,#DESC2+0
  MOVI r1,#C2STACK
  ST r1,r0,#DESC2+1
  MOVI r1,#CHILD2
  ST r1,r0,#DESC2+2
  MOVI r1,0x400
  ST r1,r0,#DESC2+3
  MOVI r1,#C2DATA
  ST r1,r0,#DESC2+4
  MOVI r1,0x400
  ST r1,r0,#DESC2+5
  MOVI r1,0
  MOVHI r1,3
  ST r1,r0,#DESC2+6
  MOVI r1,0x1000
  ST r1,r0,#DESC2+7

  ; boot frame, kernel stack, entry
  MOVI r1,0x4E01
  MOVI r2,#BOOTF
  OUTL r2,r1
  MOVI r1,0x4E03
  MOVI r2,#KSTACK
  OUTL r2,r1
  MOVI r1,0x4E00
  MOVI r2,@kentry
  OUTL r2,r1
  SVC 7
  HALT

; ---- kernel ----
.org 0x1000
kentry:
  MOVI r1,0x4E01
  INL r2,r1
  ST r2,r0,#FP
  LD r3,r2,19
  CMP r3,r0
  JMP[EQ] @ksvc
  MOVI r4,1
  CMP r3,r4
  JMP[EQ] @kirq
  HALT

ksvc:
  LD r3,r2,20
  CMP r3,r0
  JMP[EQ] @kyield
  MOVI r4,7
  CMP r3,r4
  JMP[EQ] @kstart
  MOVI r4,1
  CMP r3,r4
  JMP[EQ] @kexit
  MOVI r4,9
  CMP r3,r4
  JMP[EQ] @kspawn
  MOVI r4,10
  CMP r3,r4
  JMP[EQ] @kwait
  MOVI r3,-1
  ST r3,r2,21
  SVCRET

kstart:
  MOVI r1,0x4E02
  MOVI r2,8
  OUTL r2,r1
  JMP @pick_next
kyield:
  ST r0,r2,21
  JMP @pick_next
kirq:
  JMP @pick_next
kexit:
  CALL @do_exit
  JMP @pick_next
kspawn:
  CALL @do_spawn
  LD r2,r0,#FP
  ST r1,r2,21
  SVCRET
kwait:
  CALL @do_wait
  HALT

; allocate a slot from descriptor r1 (guest pointer) -> pid in r1
do_spawn:
  LD r1,r0,#FP
  LD r1,r1,1
  ST r1,r0,#DESCP
  MOVI r1,1
fs_loop:
  MOVI r2,#T_STATE
  ADD r2,r2,r1
  LD r3,r2,0
  CMP r3,r0
  JMP[EQ] @fs_found
  ADD r1,r1,r13
  MOVI r2,4
  CMP r1,r2
  JMP[LT] @fs_loop
  MOVI r1,0
  RET
fs_found:
  MOVI r3,1
  ST r3,r2,0
  SHL r4,r1,8
  MOVI r9,#FR_BASE
  ADD r9,r9,r4
  MOVI r10,#RT_BASE
  ADD r10,r10,r4
  LD r11,r0,#DESCP
  ; zero the new frame
  ADD r5,r9,r0
  MOVI r7,24
  MOVI r8,0
zf:
  ST r8,r5,0
  ADD r5,r5,r13
  SUB r7,r7,r13
  JMP[NE] @zf
  ; frame fields
  LD r2,r11,0
  ST r2,r9,16
  LD r2,r11,1
  ST r2,r9,14
  ST r2,r9,22
  MOVI r2,1
  ST r2,r9,13
  ; code region
  LD r2,r11,2
  ST r2,r10,0
  LD r2,r11,3
  ST r2,r10,1
  ST r0,r10,2
  MOVI r2,5
  ST r2,r10,3
  ; data region
  LD r2,r11,4
  ST r2,r10,4
  LD r2,r11,5
  ST r2,r10,5
  ST r0,r10,6
  MOVI r2,3
  ST r2,r10,7
  ; scratch region
  LD r2,r11,6
  ST r2,r10,8
  LD r2,r11,7
  ST r2,r10,9
  ST r0,r10,10
  MOVI r2,3
  ST r2,r10,11
  ST r0,r10,12
  ST r0,r10,13
  ST r0,r10,14
  ST r0,r10,15
  ; per-process data base
  LD r2,r11,6
  MOVI r3,#T_DATA
  ADD r3,r3,r1
  ST r2,r3,0
  ADD r1,r1,r13
  RET

; current process exits with frame[1]
do_exit:
  LD r2,r0,#FP
  LD r1,r2,1
  LD r5,r0,#CUR
  MOVI r3,#T_STATE
  ADD r3,r3,r5
  MOVI r4,3
  ST r4,r3,0
  MOVI r3,#T_CODE
  ADD r3,r3,r5
  ST r1,r3,0
  ; wake processes waiting for this pid
  MOVI r6,0
ew_loop:
  MOVI r3,#T_STATE
  ADD r3,r3,r6
  LD r4,r3,0
  MOVI r7,2
  CMP r4,r7
  JMP[NE] @ew_next
  MOVI r3,#T_WAIT
  ADD r3,r3,r6
  LD r7,r3,0
  ADD r8,r5,r13
  CMP r7,r8
  JMP[NE] @ew_next
  MOVI r4,1
  MOVI r3,#T_STATE
  ADD r3,r3,r6
  ST r4,r3,0
  MOVI r3,#T_WAIT
  ADD r3,r3,r6
  ST r0,r3,0
  SHL r4,r6,8
  MOVI r3,#FR_BASE
  ADD r3,r3,r4
  ST r1,r3,21
ew_next:
  ADD r6,r6,r13
  MOVI r3,4
  CMP r6,r3
  JMP[LT] @ew_loop
  RET

; wait for pid in frame[1]; returns status or blocks
do_wait:
  LD r2,r0,#FP
  LD r1,r2,1
  SUB r9,r1,r13
  MOVI r3,#T_STATE
  ADD r3,r3,r9
  LD r4,r3,0
  MOVI r5,3
  CMP r4,r5
  JMP[EQ] @w_ready
  LD r6,r0,#CUR
  MOVI r3,#T_WAIT
  ADD r3,r3,r6
  ST r1,r3,0
  MOVI r3,#T_STATE
  ADD r3,r3,r6
  MOVI r4,2
  ST r4,r3,0
  JMP @pick_next
w_ready:
  MOVI r3,#T_CODE
  ADD r3,r3,r9
  LD r4,r3,0
  ST r4,r2,21
  SVCRET

; round-robin: next runnable slot, then switch_to
pick_next:
  LD r1,r0,#CUR
  MOVI r2,0
pn_loop:
  ADD r1,r1,r13
  MOVI r3,4
  CMP r1,r3
  JMP[LT] @pn_ok
  MOVI r1,0
pn_ok:
  MOVI r3,#T_STATE
  ADD r3,r3,r1
  LD r4,r3,0
  MOVI r5,1
  CMP r4,r5
  JMP[EQ] @switch_to
  ADD r2,r2,r13
  MOVI r3,4
  CMP r2,r3
  JMP[LT] @pn_loop
  HALT

; switch to slot r1: frame, region table, data base
switch_to:
  ST r1,r0,#CUR
  SHL r2,r1,8
  MOVI r3,#FR_BASE
  ADD r3,r3,r2
  MOVI r4,0x4E01
  OUTL r3,r4
  MOVI r3,#RT_BASE
  ADD r3,r3,r2
  MOVI r4,0x4E04
  OUTL r3,r4
  MOVI r3,#T_DATA
  ADD r3,r3,r1
  LD r2,r3,0
  MOVI r4,0x4E07
  OUTL r2,r4
  SVCRET

; ---- parent process ----
.org 0x4000
parent_entry:
  MOVI r13,1
  MOVI r14,#PSTACK
  MOVI r1,#DESC1
  SVC 9
  ST r1,r0,#PID1
  MOVI r1,#DESC2
  SVC 9
  ST r1,r0,#PID2
  LD r1,r0,#PID1
  SVC 10
  MOVI r2,10
  CMP r1,r2
  JMP[NE] @bad
  LD r1,r0,#PID2
  SVC 10
  MOVI r2,20
  CMP r1,r2
  JMP[NE] @bad
  MOVI r1,79
  PUTC r1
  MOVI r1,75
  PUTC r1
  MOVI r1,10
  PUTC r1
  MOVI r1,0
  SVC 1
  HALT
bad:
  MOVI r1,66
  PUTC r1
  MOVI r1,65
  PUTC r1
  MOVI r1,68
  PUTC r1
  MOVI r1,10
  PUTC r1
  MOVI r1,1
  SVC 1
  HALT

.org 0x4400
pdata:
.str ""

; ---- child 1 ----
.org 0x8000
child1_entry:
  MOVI r13,1
  MOVI r14,#C1STACK
  MOVI r1,49
  PUTC r1
  MOVI r1,10
  SVC 1
  HALT
.org 0x8400
c1data:
.str ""

; ---- child 2 ----
.org 0xC000
child2_entry:
  MOVI r13,1
  MOVI r14,#C2STACK
  MOVI r1,50
  PUTC r1
  MOVI r1,20
  SVC 1
  HALT
.org 0xC400
c2data:
.str ""
