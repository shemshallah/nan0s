; nansmp_test.nas - NaN16 workload for the x86_64 S1 SMP prototype.
;
; Word 0 is task A and word 1 is task B: the S1 SMP prototype points a task
; context at each and lets every CPU execute the same flat image.  The load
; has three independent synchronization proofs:
;
;   1. a lock-free atomic fetch-add on one shared counter (all CPUs);
;   2. a per-CPU spinlock guarding a per-CPU counter (task A vs task B on
;      the same CPU);
;   3. a short global spinlock phase across CPUs (50 iterations per task).
;
; Guest data map (word indices; the S1 SMP kernel provides the stacks):
;   0x8000 + cpu*16 + task*8   result: [0] count [1] cpu [2] queue checksum
;   0x9000                     shared atomic counter
;   0x9001                     global spinlock
;   0x9002                     global locked counter
;   0x9010 + cpu               per-CPU spinlock
;   0x9020 + cpu               per-CPU locked counter
;   0xA000 + cpu*32 + task*16  per-CPU/task queue structure (NSP_Q_WORDS=4)
;   0xB000 + (cpu*2+task)*64   per-CPU/task FIFO link table
;   0xE000 + cpu*0x100         task A stack (task B uses +0x80)
;
; The kernel reads the results and prints the exact transcript; this image
; never prints, so concurrent CPUs cannot interleave console text.

.equ SMP_RESULT 0x8000
.equ SMP_SHARED 0x9000
.equ SMP_LOCK   0x9001
.equ SMP_LOCKED 0x9002
.equ SMP_CPULOCK 0x9010
.equ SMP_CPUTOT  0x9020
.equ SMP_QCTX   0xA000
.equ SMP_QLINK  0xB000

.equ A_LOOPS    5000
.equ B_LOOPS    1000
.equ G_LOOPS    50

.org 0
JMP @ta
JMP @tb

.org 2
ta:
  MOVI r9,0                 ; task result/queue offset: A = 0
  MOVI r7,#A_LOOPS
  JMP @work

tb:
  MOVI r9,8                 ; task result/queue offset: B = 8 words
  MOVI r7,#B_LOOPS

work:
  CALL @nsp_cpu
  ADD r10,r1,r0             ; CPU index
  SHL r8,r10,4
  MOVI r2,#SMP_RESULT
  ADD r8,r8,r2
  ADD r8,r8,r9              ; per-task result slot
  MOVI r2,#SMP_CPULOCK
  ADD r11,r10,r2            ; per-CPU spinlock
  MOVI r2,#SMP_CPUTOT
  ADD r12,r10,r2            ; per-CPU counter

  MOVI r6,0
work_loop:
  LA r1,#SMP_SHARED
  MOVI r2,1
  CALL @nsp_fetch_add       ; lock-free shared atomic increment

  ADD r1,r11,r0
  CALL @nsp_lock            ; per-CPU lock: task A vs task B
  ADD r1,r12,r0
  MOVI r2,1
  CALL @nsp_fetch_add
  ADD r1,r11,r0
  CALL @nsp_unlock

  ADDI r6,r6,1
  CMP r6,r7
  JMP[NE] @work_loop
  ADD r11,r6,r0             ; keep the main-loop count

  ; Short cross-CPU global lock phase.
  MOVI r6,0
gloop:
  LA r1,#SMP_LOCK
  CALL @nsp_lock
  LA r1,#SMP_LOCKED
  MOVI r2,1
  CALL @nsp_fetch_add
  LA r1,#SMP_LOCK
  CALL @nsp_unlock
  ADDI r6,r6,1
  MOVI r2,#G_LOOPS
  CMP r6,r2
  JMP[NE] @gloop

  ST r11,r8,0               ; NaN-computed count
  CALL @nsp_cpu
  ST r1,r8,1                ; CPU that ran this task

  ; per-CPU FIFO self-test: push 1, push 2, pop -> 1, pop -> 2, checksum 12
  CALL @nsp_cpu
  SHL r2,r1,5               ; cpu * 32
  SHL r3,r9,1               ; task * 16
  ADD r2,r2,r3
  MOVI r3,#SMP_QCTX
  ADD r10,r2,r3
  ADD r1,r10,r0
  MOVI r2,1
  CALL @nsp_q_push
  ADD r1,r10,r0
  MOVI r2,2
  CALL @nsp_q_push
  ADD r1,r10,r0
  CALL @nsp_q_pop
  ADD r11,r1,r0
  ADD r1,r10,r0
  CALL @nsp_q_pop
  ADD r12,r1,r0
  MOVI r3,10
  MUL r11,r11,r3
  ADD r11,r11,r12
  ST r11,r8,2               ; queue checksum
  HALT

.include "../lib/nansmp.nas"
