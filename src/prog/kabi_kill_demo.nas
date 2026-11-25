; kabi_kill_demo.nas - signals via the frozen kill syscall.
;
; Process 0 (parent) spawns a child that sleeps for 100 ticks.  The parent
; calls SVC 22 kill(pid, 9); the kernel terminates the target, records status
; 128+signal, decrements the live count, wakes waiters, and returns 0 to the
; killer.  The parent waits, checks status 137, and prints KOK.  Process 2 is
; an idle loop so ticks advance while the child sleeps.
;
; Expected serial text: KOK
; Differential gate: C oracle and x86_64 S1 must agree exactly.

.equ FRAME0    0x1800
.equ FR_BASE   0x1800
.equ RT_BASE   0x1C00
.equ BOOTF     0x2100
.equ IDLEF     0x1A00
.equ KSTACK    0x3000
.equ T_STATE   0x2000
.equ T_WAIT    0x2004
.equ T_CODE    0x2008
.equ T_DATA    0x200C
.equ T_SLEEP   0x2010
.equ CUR       0x2020
.equ DESCP     0x2021
.equ FP        0x2022
.equ TICKS     0x2023
.equ LIVE      0x2024
.equ PID1      0x4500
.equ DESC1     0x4600
.equ PSTACK    0x47F0
.equ C1STACK   0x87F0
.equ IDLE_STK  0x97F0
.equ PARENT    0x4000
.equ PDATA     0x4400
.equ CHILD1    0x8000
.equ C1DATA    0x8400
.equ IDLE      0x9000
.equ SCR0      0x10000
.equ SCR1      0x18000
.equ SCR2      0x20000

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

  ; process table: parent 0, child 1 (spawned), idle 2
  MOVI r1,1
  ST r1,r0,#T_STATE
  ST r0,r0,#T_WAIT
  ST r0,r0,#T_CODE
  MOVI r1,0
  MOVHI r1,1
  ST r1,r0,#T_DATA
  ST r0,r0,#T_STATE+1
  MOVI r1,1
  ST r1,r0,#T_STATE+2
  ST r0,r0,#T_STATE+3
  ST r0,r0,#T_WAIT+1
  ST r0,r0,#T_WAIT+2
  ST r0,r0,#T_CODE+1
  ST r0,r0,#T_CODE+2
  ST r0,r0,#T_SLEEP+0
  ST r0,r0,#T_SLEEP+1
  ST r0,r0,#T_SLEEP+2
  MOVI r1,0
  MOVHI r1,2
  ST r1,r0,#T_DATA+2
  MOVI r1,1
  ST r1,r0,#LIVE
  ST r0,r0,#TICKS
  ST r0,r0,#CUR

  ; child descriptor
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
  MOVI r1,0x8000
  MOVHI r1,1
  ST r1,r0,#DESC1+6
  MOVI r1,0x1000
  ST r1,r0,#DESC1+7

  ; idle frame (slot 2)
  MOVI r1,#IDLEF
  MOVI r2,24
  MOVI r3,0
bz2:
  ST r3,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP[NE] @bz2
  MOVI r1,1
  ST r1,r0,#IDLEF+13
  MOVI r1,#IDLE_STK
  ST r1,r0,#IDLEF+14
  ST r1,r0,#IDLEF+22
  MOVI r1,#IDLE
  ST r1,r0,#IDLEF+16
  ; idle region: code RX only
  MOVI r1,#IDLE
  ST r1,r0,#RT_BASE+0x200+0
  MOVI r1,0x100
  ST r1,r0,#RT_BASE+0x200+1
  ST r0,r0,#RT_BASE+0x200+2
  MOVI r1,5
  ST r1,r0,#RT_BASE+0x200+3
  ST r0,r0,#RT_BASE+0x200+4

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
  MOVI r4,22
  CMP r3,r4
  JMP[EQ] @kkill
  MOVI r4,11
  CMP r3,r4
  JMP[EQ] @ktime
  MOVI r4,24
  CMP r3,r4
  JMP[EQ] @ksleep
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
  LD r1,r0,#TICKS
  ADD r1,r1,r13
  ST r1,r0,#TICKS
  MOVI r6,0
sw_loop:
  MOVI r3,#T_STATE
  ADD r3,r3,r6
  LD r4,r3,0
  MOVI r5,4
  CMP r4,r5
  JMP[NE] @sw_next
  MOVI r3,#T_SLEEP
  ADD r3,r3,r6
  LD r4,r3,0
  LD r5,r0,#TICKS
  CMP r4,r5
  JMP[GT] @sw_next
  MOVI r4,1
  MOVI r3,#T_STATE
  ADD r3,r3,r6
  ST r4,r3,0
  MOVI r3,#T_SLEEP
  ADD r3,r3,r6
  ST r0,r3,0
sw_next:
  ADD r6,r6,r13
  MOVI r3,4
  CMP r6,r3
  JMP[LT] @sw_loop
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
kkill:
  CALL @do_kill
  LD r2,r0,#FP
  ST r1,r2,21
  SVCRET
ktime:
  LD r1,r0,#TICKS
  LD r2,r0,#FP
  ST r1,r2,21
  SVCRET
ksleep:
  LD r2,r0,#FP
  LD r1,r2,1
  LD r3,r0,#TICKS
  ADD r3,r3,r1
  LD r1,r0,#CUR
  MOVI r4,#T_SLEEP
  ADD r4,r4,r1
  ST r3,r4,0
  MOVI r4,#T_STATE
  ADD r4,r4,r1
  MOVI r5,4
  ST r5,r4,0
  ST r0,r2,21
  JMP @pick_next

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
  LD r3,r0,#LIVE
  ADD r3,r3,r13
  ST r3,r0,#LIVE
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
  LD r3,r0,#LIVE
  SUB r3,r3,r13
  ST r3,r0,#LIVE
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

; terminate pid in frame[1] with signal in frame[2] -> 0/-1
do_kill:
  LD r2,r0,#FP
  LD r1,r2,1
  LD r3,r2,2
  SUB r9,r1,r13
  MOVI r4,#T_STATE
  ADD r4,r4,r9
  LD r5,r4,0
  CMP r5,r0
  JMP[EQ] @kill_err
  MOVI r6,3
  CMP r5,r6
  JMP[EQ] @kill_err
  LD r6,r0,#CUR
  CMP r9,r6
  JMP[EQ] @kill_err
  MOVI r6,128
  ADD r6,r6,r3
  MOVI r5,3
  ST r5,r4,0
  MOVI r4,#T_CODE
  ADD r4,r4,r9
  ST r6,r4,0
  LD r4,r0,#LIVE
  SUB r4,r4,r13
  ST r4,r0,#LIVE
  MOVI r7,0
kw_loop:
  MOVI r4,#T_STATE
  ADD r4,r4,r7
  LD r5,r4,0
  MOVI r8,2
  CMP r5,r8
  JMP[NE] @kw_next
  MOVI r4,#T_WAIT
  ADD r4,r4,r7
  LD r5,r4,0
  CMP r5,r1
  JMP[NE] @kw_next
  MOVI r5,1
  MOVI r4,#T_STATE
  ADD r4,r4,r7
  ST r5,r4,0
  MOVI r4,#T_WAIT
  ADD r4,r4,r7
  ST r0,r4,0
  SHL r5,r7,8
  MOVI r4,#FR_BASE
  ADD r4,r4,r5
  ST r6,r4,21
kw_next:
  ADD r7,r7,r13
  MOVI r4,4
  CMP r7,r4
  JMP[LT] @kw_loop
  MOVI r1,0
  RET
kill_err:
  MOVI r1,-1
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
  LD r1,r0,#LIVE
  CMP r1,r0
  JMP[EQ] @no_live
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
no_live:
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
  MOVI r2,9
  SVC 22
  CMP r1,r0
  JMP[NE] @bad
  LD r1,r0,#PID1
  SVC 10
  MOVI r2,137
  CMP r1,r2
  JMP[NE] @bad
  MOVI r1,75
  PUTC r1
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

; ---- child ----
.org 0x8000
child1_entry:
  MOVI r13,1
  MOVI r14,#C1STACK
  MOVI r1,100
  SVC 24
  MOVI r1,90
  PUTC r1
  MOVI r1,1
  SVC 1
  HALT

.org 0x8400
c1data:
.str ""

; ---- idle loop ----
.org 0x9000
idle:
  NOP
  JMP @idle
