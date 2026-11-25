; kabi_sched_demo.nas - two region-isolated processes with timer preemption.
;
; Boot programs two trap frames and two region tables, then enters the kernel.
; The kernel starts process A, arms the instruction timer, and switches
; between A and B on every timer IRQ.  Each process prints its letter and
; exits through SVC 1; the kernel halts after both exits.  A process can only
; fetch its own code region and read/write its own data region.
;
; This is a differential gate: the C oracle and the x86_64 S1 must produce
; identical serial text.  The transcript interleaving is instruction-timed.

.equ FR_A     0x1800
.equ FR_B     0x1900
.equ RT_A     0x1A00
.equ RT_B     0x1B00
.equ BOOTF    0x1C00
.equ CUR      0x1D00
.equ DA       0x1D01
.equ DB       0x1D02
.equ KSTACK   0x2000
.equ AC       0x4400
.equ BC       0x8400
.equ ASTACK   0x47F0
.equ BSTACK   0x87F0

.org 0
boot:
  MOVI r13,1
  ; zero both trap frames
  MOVI r1,#FR_A
  MOVI r2,48
  MOVI r3,0
bz:
  ST r3,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP[NE] @bz

  ; process A initial frame: r13=1, sp, pc, cause=0
  MOVI r1,1
  ST r1,r0,#FR_A+13
  MOVI r1,#ASTACK
  ST r1,r0,#FR_A+14
  ST r1,r0,#FR_A+22
  MOVI r1,@a_entry
  ST r1,r0,#FR_A+16
  ; process B initial frame
  MOVI r1,1
  ST r1,r0,#FR_B+13
  MOVI r1,#BSTACK
  ST r1,r0,#FR_B+14
  ST r1,r0,#FR_B+22
  MOVI r1,@b_entry
  ST r1,r0,#FR_B+16

  ; region table A: code RX, data RW
  MOVI r1,0x4000
  ST r1,r0,#RT_A+0
  MOVI r1,0x400
  ST r1,r0,#RT_A+1
  ST r0,r0,#RT_A+2
  MOVI r1,5
  ST r1,r0,#RT_A+3
  MOVI r1,0x4400
  ST r1,r0,#RT_A+4
  MOVI r1,0x400
  ST r1,r0,#RT_A+5
  ST r0,r0,#RT_A+6
  MOVI r1,3
  ST r1,r0,#RT_A+7
  ST r0,r0,#RT_A+8

  ; region table B: code RX, data RW
  MOVI r1,0x8000
  ST r1,r0,#RT_B+0
  MOVI r1,0x400
  ST r1,r0,#RT_B+1
  ST r0,r0,#RT_B+2
  MOVI r1,5
  ST r1,r0,#RT_B+3
  MOVI r1,0x8400
  ST r1,r0,#RT_B+4
  MOVI r1,0x400
  ST r1,r0,#RT_B+5
  ST r0,r0,#RT_B+6
  MOVI r1,3
  ST r1,r0,#RT_B+7
  ST r0,r0,#RT_B+8

  ST r0,r0,#CUR
  ST r0,r0,#DA
  ST r0,r0,#DB

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
  SVC 7                       ; start the scheduler
  HALT

; ---- kernel (not mapped) ----
.org 0x1000
kentry:
  MOVI r1,0x4E01
  INL r2,r1                   ; r2 = active trap frame
  LD r3,r2,19
  CMP r3,r0
  JMP[EQ] @ksvc
  MOVI r4,1
  CMP r3,r4
  JMP[EQ] @kirq
  HALT

ksvc:
  LD r3,r2,20
  MOVI r4,7
  CMP r3,r4
  JMP[EQ] @kstart
  MOVI r4,1
  CMP r3,r4
  JMP[EQ] @kexit
  ST r0,r2,21
  SVCRET

kstart:
  MOVI r1,0x4E02
  MOVI r2,30                  ; preempt every 30 instructions
  OUTL r2,r1
  JMP @to_a

kirq:
  LD r1,r0,#CUR
  CMP r1,r0
  JMP[EQ] @irq_b
  LD r2,r0,#DA
  CMP r2,r0
  JMP[NE] @irq_same
  JMP @to_a
irq_b:
  LD r2,r0,#DB
  CMP r2,r0
  JMP[NE] @irq_same
  JMP @to_b
irq_same:
  SVCRET

kexit:
  LD r1,r0,#CUR
  CMP r1,r0
  JMP[NE] @ex_b
  MOVI r1,1
  ST r1,r0,#DA
  JMP @ex_check
ex_b:
  MOVI r1,1
  ST r1,r0,#DB
ex_check:
  LD r1,r0,#DA
  LD r2,r0,#DB
  ADD r1,r1,r2
  MOVI r3,2
  CMP r1,r3
  JMP[EQ] @kdone
  JMP @to_other
kdone:
  HALT

to_a:
  ST r0,r0,#CUR
  MOVI r1,0x4E01
  MOVI r2,#FR_A
  OUTL r2,r1
  MOVI r1,0x4E04
  MOVI r2,#RT_A
  OUTL r2,r1
  SVCRET
to_b:
  MOVI r1,1
  ST r1,r0,#CUR
  MOVI r1,0x4E01
  MOVI r2,#FR_B
  OUTL r2,r1
  MOVI r1,0x4E04
  MOVI r2,#RT_B
  OUTL r2,r1
  SVCRET
to_other:
  LD r1,r0,#CUR
  CMP r1,r0
  JMP[EQ] @to_b
  JMP @to_a

; ---- process A ----
.org 0x4000
a_entry:
  MOVI r13,1
  MOVI r14,#ASTACK
  MOVI r7,65
  MOVI r6,6
  MOVI r9,0
  ST r9,r0,#AC
aloop:
  PUTC r7
  LD r9,r0,#AC
  ADD r9,r9,r13
  ST r9,r0,#AC
  CMP r9,r6
  JMP[LT] @aloop
  MOVI r1,0
  SVC 1
  JMP @aloop

; ---- A data/stack ----
.org 0x4400
a_data:
.str ""

; ---- process B ----
.org 0x8000
b_entry:
  MOVI r13,1
  MOVI r14,#BSTACK
  MOVI r7,66
  MOVI r6,6
  MOVI r9,0
  ST r9,r0,#BC
bloop:
  PUTC r7
  LD r9,r0,#BC
  ADD r9,r9,r13
  ST r9,r0,#BC
  CMP r9,r6
  JMP[LT] @bloop
  MOVI r1,0
  SVC 1
  JMP @bloop

; ---- B data/stack ----
.org 0x8400
b_data:
.str ""
