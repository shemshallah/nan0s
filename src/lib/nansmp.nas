; nansmp.nas - per-CPU scheduler interface for the x86_64 S1 SMP prototype.
;
; This is the NaN-side half of spec/SMP.md.  It is deliberately additive: the
; existing single-core scheduler in nansched.nas is untouched, and a kernel
; that wants SMP can call these helpers instead of the one-core queue code.
;
; ABI: r0=0, r13=1, r14=SP (grows up), r15=link.  Calls take arguments in
; r1..r3 and return r1.  Every public routine preserves r6..r12 and r13/r14;
; r1..r5 and the flags are scratch.  A task that needs live state across a
; call therefore keeps it in r6..r12 (or on its own stack).
;
; Stack frames use the nansched convention: a non-leaf routine stores its
; link at [SP], adds NSP_FRAME=9 to SP, and keeps locals above the new SP.
; The 9-word gap is the contract that stops a callee's saved link from
; overwriting a caller's local (the first SMP workload found exactly that
; bug with one-word frames: the lock word became a CALL return address).
;
; The atomic and CPU services are experimental S1 control ports, outside the
; frozen KERNEL_ABI v0.1 port map:
;
;   0x4E08 IN   current CPU index 0..N-1
;   0x4E09 IN   NaN instructions executed on this CPU (low 32)
;   0x4E0A OUT  send reschedule IPI to CPU value (vector 0x41)
;   0x4E0B OUT  atomic compare-and-swap; value = descriptor word address
;               IN  previous payload of the CAS word
;   0x4E0C OUT  atomic fetch-add; value = descriptor word address
;               IN  previous payload of the counter word
;   0x4E0D OUT  release/acquire fence (mfence)
;
; Descriptor layouts (all word addresses):
;   CAS   { addr, expected, new }    -> old payload
;   FADD  { addr, delta }            -> old payload
;
; The descriptor itself lives on the calling task's stack, so concurrent
; CPUs never share a mailbox.  The S1 port body performs the whole
; read-modify-write under one locked x86 operation; no hidden policy lives in
; this library.

.equ NSP_P_CPU    0x4E08
.equ NSP_P_STEPS  0x4E09
.equ NSP_P_IPI    0x4E0A
.equ NSP_P_CAS    0x4E0B
.equ NSP_P_FADD   0x4E0C
.equ NSP_P_FENCE  0x4E0D

.equ NSP_FRAME    9
.equ NSP_FRAME_NEG -9

; Per-CPU queue structure (word offsets).  A kernel allocates one per CPU:
;   +0 head (encoded tid+1, 0 empty)  +1 tail (encoded)
;   +2 count                          +3 link_base (word address)
; link_base[tid] holds encoded tid+1 of the next queued task, 0 = end.
.equ NSP_Q_HEAD   0
.equ NSP_Q_TAIL   1
.equ NSP_Q_COUNT  2
.equ NSP_Q_LINK   3
.equ NSP_Q_WORDS  4

; ------------------------------------------------------------------ CPU id
; nsp_cpu -> r1 = logical CPU index of the caller
nsp_cpu:
  MOVI r2,#NSP_P_CPU
  INL r1,r2
  RET

; nsp_steps -> r1 = NaN instructions executed on this CPU (low 32 bits)
nsp_steps:
  MOVI r2,#NSP_P_STEPS
  INL r1,r2
  RET

; nsp_ipi r1=target CPU -> r1=0
nsp_ipi:
  MOVI r2,#NSP_P_IPI
  OUTL r1,r2
  MOVI r1,0
  RET

; nsp_fence -> r1=0; sequentially consistent boundary for shared words
nsp_fence:
  MOVI r2,#NSP_P_FENCE
  OUTL r0,r2
  MOVI r1,0
  RET

; --------------------------------------------------------------- atomics
; nsp_cas r1=addr r2=expected r3=new -> r1=old payload
nsp_cas:
  ST r15,r14,0
  ADDI r14,r14,#NSP_FRAME
  ST r1,r14,4
  ST r2,r14,5
  ST r3,r14,6
  MOVI r4,#NSP_P_CAS
  ADDI r1,r14,4
  OUTL r1,r4
  INL r1,r4
  ADDI r14,r14,#NSP_FRAME_NEG
  LD r15,r14,0
  RET

; nsp_fetch_add r1=addr r2=delta -> r1=old payload
nsp_fetch_add:
  ST r15,r14,0
  ADDI r14,r14,#NSP_FRAME
  ST r1,r14,4
  ST r2,r14,5
  MOVI r4,#NSP_P_FADD
  ADDI r1,r14,4
  OUTL r1,r4
  INL r1,r4
  ADDI r14,r14,#NSP_FRAME_NEG
  LD r15,r14,0
  RET

; ------------------------------------------------------------------ lock
; nsp_trylock r1=lock word -> r1=0 acquired, 1 busy
nsp_trylock:
  ST r15,r14,0
  ADDI r14,r14,#NSP_FRAME
  ST r1,r14,1
  MOVI r2,0
  MOVI r3,1
  CALL @nsp_cas
  CMP r1,r0
  JMP[EQ] @nsp_try_ok
  MOVI r1,1
  JMP @nsp_try_out
nsp_try_ok:
  MOVI r1,0
nsp_try_out:
  ADDI r14,r14,#NSP_FRAME_NEG
  LD r15,r14,0
  RET

; nsp_lock r1=lock word -> r1=0
nsp_lock:
  ST r15,r14,0
  ADDI r14,r14,#NSP_FRAME
  ST r1,r14,1
nsp_lock_loop:
  LD r1,r14,1
  CALL @nsp_trylock
  CMP r1,r0
  JMP[EQ] @nsp_lock_done
  JMP @nsp_lock_loop
nsp_lock_done:
  MOVI r1,0
  ADDI r14,r14,#NSP_FRAME_NEG
  LD r15,r14,0
  RET

; nsp_unlock r1=lock word -> r1=0
nsp_unlock:
  ST r0,r1,0
  MOVI r2,#NSP_P_FENCE
  OUTL r0,r2
  MOVI r1,0
  RET

; ------------------------------------------------------------ per-CPU queue
; nsp_q_push r1=queue structure r2=tid -> r1=0
nsp_q_push:
  ST r15,r14,0
  ADDI r14,r14,#NSP_FRAME
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,#NSP_Q_LINK
  ADD r3,r3,r2
  ST r0,r3,0
  ADD r4,r2,r13              ; encoded tid
  LD r3,r1,#NSP_Q_TAIL
  CMP r3,r0
  JMP[EQ] @nsp_qp_empty
  SUB r3,r3,r13
  LD r5,r1,#NSP_Q_LINK
  ADD r5,r5,r3
  ST r4,r5,0
  ST r4,r1,#NSP_Q_TAIL
  JMP @nsp_qp_count
nsp_qp_empty:
  ST r4,r1,#NSP_Q_HEAD
  ST r4,r1,#NSP_Q_TAIL
nsp_qp_count:
  LD r3,r1,#NSP_Q_COUNT
  ADD r3,r3,r13
  ST r3,r1,#NSP_Q_COUNT
  MOVI r1,0
  ADDI r14,r14,#NSP_FRAME_NEG
  LD r15,r14,0
  RET

; nsp_q_pop r1=queue structure -> r1=tid or 0xFFFF when empty
nsp_q_pop:
  LD r2,r1,#NSP_Q_HEAD
  CMP r2,r0
  JMP[EQ] @nsp_qpop_none
  SUB r3,r2,r13              ; tid
  LD r4,r1,#NSP_Q_LINK
  ADD r4,r4,r3
  LD r5,r4,0                 ; next encoded
  ST r5,r1,#NSP_Q_HEAD
  CMP r5,r0
  JMP[NE] @nsp_qpop_have
  ST r0,r1,#NSP_Q_TAIL
nsp_qpop_have:
  ST r0,r4,0
  LD r5,r1,#NSP_Q_COUNT
  SUB r5,r5,r13
  ST r5,r1,#NSP_Q_COUNT
  ADD r1,r3,r0
  RET
nsp_qpop_none:
  MOVI r1,0xFFFF
  RET

; nsp_q_len r1=queue structure -> r1=count
nsp_q_len:
  LD r1,r1,#NSP_Q_COUNT
  RET
