; nansched_mp.nas - pure-NaN per-CPU scheduler for NanCore records (F2).
;
; This layer sits between the immutable block runtime (NanCore records,
; src/lib/nancore.nas) and a policy caller such as nansched.nas.  Every CPU
; owns a FIFO in its 64-word record:
;
;   NC_QHEAD  encoded task id + 1, 0 = empty
;   NC_QTAIL  encoded tail
;   NC_QCOUNT runnable tasks
;   word 32   NSD_NC_CUR: current task id + 1, 0 = none
;   word 33   NSD_NC_LOCK: queue lock word
;
; Words 32/33 are the scheduler-owned extension of the NanCore record; the
; NanCore base fields (0..31) are untouched.  Stolen tasks are enqueued on the
; thief with the same FIFO.  Migration is a two-lock remove/enqueue: the
; source lock is held only for removal, the destination lock only for the
; insert, so a cross-migration cannot deadlock on both queues.
;
; Task records live in a caller-supplied arena.  The default record is 16
; words and the stride is configurable:
;
;   +0  state        0 free, 1 ready, 2 running, 3 done
;   +1  cpu         last/current CPU
;   +2  home        placement hint
;   +3  affinity    bit mask, bit n = CPU n (32 CPUs max in this slice)
;   +4  budget      ticks left in the current dispatch
;   +5  deadline    absolute tick, 0 = none
;   +6  next        encoded next task id + 1, 0 = end
;   +7  id          task id
;   +8  flags       bit0 deadline missed, bit1 migration pending
;   +9  mig_to      last/desired target CPU
;   +10 epoch       migration epoch when last moved
;   +11 magic       0x4E53 ("NS")
;   +12..+15        caller payload
;
; Context (caller supplied, NSD_C_WORDS header words + 8 stats words/CPU):
;
;   +0 cpus        +1 arena       +2 stride      +3 capacity
;   +4 ops table   +5 tick        +6 epoch       +7 pushes
;   +8 pops        +9 steals      +10 migrations +11 affinity rejects
;   +12 budgets    +13 deadlines  +14 preempts   +15 migration requests
;   +16 ipis       +17..19 reserved
;   +20 per-CPU stats (8 words each)
;
; Per-CPU stats: +0 pushes, +1 pops, +2 steals in, +3 steals out,
;                +4 migrations in, +5 migrations out, +6 preemptions,
;                +7 ticks accounted.
;
; Ops table (6 word addresses):
;   +0 cas(addr,expected,new)->old
;   +1 fetch_add(addr,delta)->old
;   +2 fence()->0
;   +3 trylock(addr)->0 acquired / 1 busy
;   +4 unlock(addr)->0
;   +5 ipi(target)->0            (0 = no IPI transport)
;
; src/lib/nansched_nansmp.nas binds this table to nsp_cas, nsp_fetch_add,
; nsp_fence, nsp_trylock, nsp_unlock and nsp_ipi.  The test uses an
; equivalent single-thread shim so the same policy code runs under nan_cli.
;
; ABI: r0=0, r13=1, r14=SP, r15=link.  Public routines preserve r6..r12;
; results are in r1.  Return codes:
;   0 success, 1 affinity rejected, 2 busy/bad state, 3 bad argument,
;   4 not found, 0xFFFE current task busy (pop), 0xFFFF none.
;
; API:
;   nsched_init(ctx,cpus,arena,stride,capacity,ops) -> 0/3
;   nsched_task_add(ctx,id,home,affinity,budget,deadline) -> 0/3
;   nsched_push(ctx,cpu,id) -> 0/1/2/3
;   nsched_pop(ctx,cpu) -> id | 0xFFFE | 0xFFFF
;   nsched_steal(ctx,cpu) -> id | 0xFFFF
;   nsched_preempt(ctx,cpu) -> id | 0xFFFF
;   nsched_tick(ctx,cpu) -> 1 preempted / 0 accounted / 3 bad
;   nsched_migrate(ctx,id,from,to) -> 0/1/2/3/4
;   nsched_migrate_request(ctx,id,to) -> 0/1/2/3
;   nsched_affinity(ctx,id,mask) -> 0/2/3
;   nsched_budget(ctx,id,value) -> 0/3
;   nsched_deadline(ctx,id,value) -> 0/3
;   nsched_peek(ctx,cpu) -> id | 0xFFFF
;   nsched_current(ctx,cpu) -> id | 0xFFFF
;   nsched_qlen(ctx,cpu) -> count

; NanCore record shape (values mirror src/lib/nancore.nas).
.equ NC_TABLE       0x400000
.equ NC_STRIDE      64
.equ NC_MAX         4096
.equ NC_QHEAD       14
.equ NC_QTAIL       15
.equ NC_PREEMPT     26
.equ NC_QCOUNT      27
.equ NC_STEAL_HEAD  28
.equ NC_STEAL_TAIL  29
.equ NSD_NC_CUR     32
.equ NSD_NC_LOCK    33

; Scheduler context.
.equ NSD_C_CPUS     0
.equ NSD_C_ARENA    1
.equ NSD_C_STRIDE   2
.equ NSD_C_CAP      3
.equ NSD_C_OPS      4
.equ NSD_C_TICK     5
.equ NSD_C_EPOCH    6
.equ NSD_C_PUSHES   7
.equ NSD_C_POPS     8
.equ NSD_C_STEALS   9
.equ NSD_C_MIGS     10
.equ NSD_C_AFFREJ   11
.equ NSD_C_BUDGET   12
.equ NSD_C_DEADLINE 13
.equ NSD_C_PREEMPT  14
.equ NSD_C_MIGREQ   15
.equ NSD_C_IPIS     16
.equ NSD_C_STATS    20
.equ NSD_C_WORDS    20
.equ NSD_S_WORDS    8
.equ NSD_MAX_CPUS   32

; Per-CPU stats fields.
.equ NSD_S_PUSH      0
.equ NSD_S_POP       1
.equ NSD_S_STEAL_IN  2
.equ NSD_S_STEAL_OUT 3
.equ NSD_S_MIG_IN    4
.equ NSD_S_MIG_OUT   5
.equ NSD_S_PREEMPT   6
.equ NSD_S_TICKS     7

; Ops table.
.equ NSD_OP_CAS      0
.equ NSD_OP_FADD     1
.equ NSD_OP_FENCE    2
.equ NSD_OP_LOCK     3
.equ NSD_OP_UNLOCK   4
.equ NSD_OP_IPI      5
.equ NSD_OP_WORDS    6

; Task record.
.equ NSD_T_STATE     0
.equ NSD_T_CPU       1
.equ NSD_T_HOME      2
.equ NSD_T_AFF       3
.equ NSD_T_BUDGET    4
.equ NSD_T_DEADLINE  5
.equ NSD_T_NEXT      6
.equ NSD_T_ID        7
.equ NSD_T_FLAGS     8
.equ NSD_T_MIGTO     9
.equ NSD_T_EPOCH     10
.equ NSD_T_MAGIC     11
.equ NSD_T_QUANTUM   12
.equ NSD_T_WORDS     16
.equ NSD_MAGIC       0x4E53

; States and flags.
.equ NSD_FREE        0
.equ NSD_READY       1
.equ NSD_RUN         2
.equ NSD_DONE        3
.equ NSD_F_DEADLINE  1
.equ NSD_F_MIGRATE   2

; Return codes.
.equ NSD_OK          0
.equ NSD_AFF         1
.equ NSD_BUSY        2
.equ NSD_BAD         3
.equ NSD_NOENT       4
.equ NSD_CURBUSY     0xFFFE
.equ NSD_NONE        0xFFFF

.equ NSD_FRAME       40
.equ NSD_FRAME_NEG   -40
.equ NSD_SFRAME      24
.equ NSD_SFRAME_NEG  -24

; ---------------------------------------------------------------------------
; Leaf helpers.  These may clobber r1..r12; callers keep live state in frames.
; nsd_rec r1=ctx r2=id -> r1=record address.
nsd_rec:
  LD r3,r1,#NSD_C_ARENA
  LD r4,r1,#NSD_C_STRIDE
  MUL r2,r2,r4
  ADD r1,r3,r2
  RET

; nsd_nc r1=cpu -> r1=NanCore record address.
nsd_nc:
  SHL r2,r1,6
  LA r3,#NC_TABLE
  ADD r1,r3,r2
  RET

; nsd_stats r1=ctx r2=cpu -> r1=first per-CPU stat word.
nsd_stats:
  SHL r3,r2,3
  ADD r1,r1,r3
  ADDI r1,r1,#NSD_C_STATS
  RET

; nsd_cpu_bit r1=cpu -> r1=1<<cpu.
nsd_cpu_bit:
  ADD r2,r1,r0
  MOVI r1,1
  MOVI r3,0
nsd_cb_loop:
  CMP r3,r2
  JMP[GE] @nsd_cb_done
  SHL r1,r1,1
  ADDI r3,r3,1
  JMP @nsd_cb_loop
nsd_cb_done:
  RET

; nsd_fadd r1=ctx r2=addr r3=delta -> r1=old payload.
nsd_fadd:
  ST r15,r14,0
  ADDI r14,r14,#NSD_SFRAME
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LD r4,r1,#NSD_C_OPS
  LD r5,r4,#NSD_OP_FADD
  LD r1,r14,2
  LD r2,r14,3
  CALLR r5
  ADDI r14,r14,#NSD_SFRAME_NEG
  LD r15,r14,0
  RET

; nsd_fence r1=ctx -> 0.
nsd_fence:
  ST r15,r14,0
  ADDI r14,r14,#NSD_SFRAME
  ST r1,r14,1
  LD r2,r1,#NSD_C_OPS
  LD r3,r2,#NSD_OP_FENCE
  CALLR r3
  MOVI r1,0
  ADDI r14,r14,#NSD_SFRAME_NEG
  LD r15,r14,0
  RET

; nsd_stat_global r1=ctx r2=context offset -> 0.
nsd_stat_global:
  ST r15,r14,0
  ADDI r14,r14,#NSD_SFRAME
  ST r1,r14,1
  ST r2,r14,2
  ADD r2,r1,r2
  MOVI r3,1
  CALL @nsd_fadd
  MOVI r1,0
  ADDI r14,r14,#NSD_SFRAME_NEG
  LD r15,r14,0
  RET

; nsd_stat_cpu r1=ctx r2=cpu r3=field -> 0.
nsd_stat_cpu:
  ST r15,r14,0
  ADDI r14,r14,#NSD_SFRAME
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @nsd_stats
  LD r2,r14,3
  ADD r2,r1,r2
  LD r1,r14,1
  MOVI r3,1
  CALL @nsd_fadd
  MOVI r1,0
  ADDI r14,r14,#NSD_SFRAME_NEG
  LD r15,r14,0
  RET

; nsd_lock r1=ctx r2=cpu -> 0.  Spin on the ops trylock (nsp_trylock is CAS).
nsd_lock:
  ST r15,r14,0
  ADDI r14,r14,#NSD_SFRAME
  ST r1,r14,1
  ST r2,r14,2
  ADD r1,r2,r0
  CALL @nsd_nc
  ADDI r1,r1,#NSD_NC_LOCK
  ST r1,r14,3
nsd_lock_loop:
  LD r1,r14,1
  LD r2,r1,#NSD_C_OPS
  LD r3,r2,#NSD_OP_LOCK
  LD r1,r14,3
  CALLR r3
  CMP r1,r0
  JMP[EQ] @nsd_lock_done
  LD r1,r14,1
  CALL @nsd_fence
  JMP @nsd_lock_loop
nsd_lock_done:
  MOVI r1,0
  ADDI r14,r14,#NSD_SFRAME_NEG
  LD r15,r14,0
  RET

; nsd_unlock r1=ctx r2=cpu -> 0.
nsd_unlock:
  ST r15,r14,0
  ADDI r14,r14,#NSD_SFRAME
  ST r1,r14,1
  ST r2,r14,2
  ADD r1,r2,r0
  CALL @nsd_nc
  ADDI r1,r1,#NSD_NC_LOCK
  ST r1,r14,3
  LD r1,r14,1
  LD r2,r1,#NSD_C_OPS
  LD r3,r2,#NSD_OP_UNLOCK
  LD r1,r14,3
  CALLR r3
  LD r1,r14,1
  CALL @nsd_fence
  MOVI r1,0
  ADDI r14,r14,#NSD_SFRAME_NEG
  LD r15,r14,0
  RET

; nsd_enqueue_locked r1=ctx r2=cpu r3=id -> 0.  Queue lock must be held.
nsd_enqueue_locked:
  ST r15,r14,0
  ADDI r14,r14,#NSD_SFRAME
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ADD r1,r2,r0
  CALL @nsd_nc
  ST r1,r14,4
  LD r1,r14,1
  LD r2,r14,3
  CALL @nsd_rec
  ST r1,r14,5
  LD r3,r14,3
  ADDI r3,r3,1
  ST r3,r14,6
  LD r1,r14,4
  LD r2,r1,#NC_QCOUNT
  CMP r2,r0
  JMP[NE] @nsd_eq_tail
  LD r1,r14,4
  LD r3,r14,6
  ST r3,r1,#NC_QHEAD
  ST r3,r1,#NC_QTAIL
  JMP @nsd_eq_link
nsd_eq_tail:
  LD r2,r1,#NC_QTAIL
  SUB r2,r2,r13
  ST r2,r14,7
  LD r1,r14,1
  CALL @nsd_rec
  LD r3,r14,6
  ST r3,r1,#NSD_T_NEXT
  LD r1,r14,4
  LD r3,r14,6
  ST r3,r1,#NC_QTAIL
nsd_eq_link:
  LD r1,r14,5
  ST r0,r1,#NSD_T_NEXT
  LD r1,r14,4
  LD r2,r1,#NC_QCOUNT
  ADDI r2,r2,1
  ST r2,r1,#NC_QCOUNT
  MOVI r1,0
  ADDI r14,r14,#NSD_SFRAME_NEG
  LD r15,r14,0
  RET

; nsd_push_head_locked r1=ctx r2=cpu r3=id -> 0.  Queue lock must be held.
nsd_push_head_locked:
  ST r15,r14,0
  ADDI r14,r14,#NSD_SFRAME
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ADD r1,r2,r0
  CALL @nsd_nc
  ST r1,r14,4
  LD r1,r14,1
  LD r2,r14,3
  CALL @nsd_rec
  ST r1,r14,5
  LD r3,r14,3
  ADDI r3,r3,1
  ST r3,r14,6
  LD r1,r14,4
  LD r2,r1,#NC_QHEAD
  ST r2,r14,7
  LD r5,r14,5
  ST r2,r5,#NSD_T_NEXT
  LD r5,r14,6
  LD r1,r14,4
  ST r5,r1,#NC_QHEAD
  LD r2,r1,#NC_QCOUNT
  CMP r2,r0
  JMP[NE] @nsd_ph_count
  ST r5,r1,#NC_QTAIL
nsd_ph_count:
  ADDI r2,r2,1
  ST r2,r1,#NC_QCOUNT
  MOVI r1,0
  ADDI r14,r14,#NSD_SFRAME_NEG
  LD r15,r14,0
  RET

; nsd_dequeue_locked r1=ctx r2=cpu -> r1=id or NSD_NONE.
nsd_dequeue_locked:
  ST r15,r14,0
  ADDI r14,r14,#NSD_SFRAME
  ST r1,r14,1
  ST r2,r14,2
  ADD r1,r2,r0
  CALL @nsd_nc
  ST r1,r14,3
  LD r2,r1,#NC_QHEAD
  CMP r2,r0
  JMP[EQ] @nsd_dq_none
  ST r2,r14,4
  SUB r3,r2,r13
  ST r3,r14,5
  LD r1,r14,1
  ADD r2,r3,r0
  CALL @nsd_rec
  ST r1,r14,6
  LD r2,r1,#NSD_T_NEXT
  ST r2,r14,7
  LD r3,r14,3
  ST r2,r3,#NC_QHEAD
  CMP r2,r0
  JMP[NE] @nsd_dq_tail
  LD r3,r14,3
  ST r0,r3,#NC_QTAIL
nsd_dq_tail:
  LD r1,r14,6
  ST r0,r1,#NSD_T_NEXT
  LD r1,r14,3
  LD r2,r1,#NC_QCOUNT
  CMP r2,r0
  JMP[EQ] @nsd_dq_zero
  SUB r2,r2,r13
  ST r2,r1,#NC_QCOUNT
nsd_dq_zero:
  LD r1,r14,5
  JMP @nsd_dq_out
nsd_dq_none:
  MOVI r1,#NSD_NONE
nsd_dq_out:
  ADDI r14,r14,#NSD_SFRAME_NEG
  LD r15,r14,0
  RET

; nsd_remove_locked r1=ctx r2=cpu r3=id -> 0 found / 4 not found.
; Removes one task from a FIFO without touching state or stats.
nsd_remove_locked:
  ST r15,r14,0
  ADDI r14,r14,#NSD_SFRAME
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ADD r1,r2,r0
  CALL @nsd_nc
  ST r1,r14,4
  LD r2,r14,3
  ADDI r2,r2,1
  ST r2,r14,5
  LD r1,r14,4
  LD r3,r1,#NC_QHEAD
  CMP r3,r0
  JMP[EQ] @nsd_rm_noent
  LD r2,r14,5
  CMP r3,r2
  JMP[NE] @nsd_rm_scan
  LD r1,r14,1
  LD r2,r14,2
  CALL @nsd_dequeue_locked
  MOVI r1,0
  JMP @nsd_rm_out
nsd_rm_scan:
  ST r3,r14,6
nsd_rm_loop:
  LD r2,r14,6
  SUB r2,r2,r13
  LD r1,r14,1
  CALL @nsd_rec
  ST r1,r14,7
  LD r3,r1,#NSD_T_NEXT
  CMP r3,r0
  JMP[EQ] @nsd_rm_noent
  LD r2,r14,5
  CMP r3,r2
  JMP[EQ] @nsd_rm_hit
  ST r3,r14,6
  JMP @nsd_rm_loop
nsd_rm_hit:
  SUB r2,r3,r13
  LD r1,r14,1
  CALL @nsd_rec
  ST r1,r14,8
  LD r3,r1,#NSD_T_NEXT
  LD r2,r14,7
  ST r3,r2,#NSD_T_NEXT
  LD r1,r14,4
  LD r3,r1,#NC_QTAIL
  LD r2,r14,5
  CMP r3,r2
  JMP[NE] @nsd_rm_tail_ok
  LD r3,r14,6
  ST r3,r1,#NC_QTAIL
nsd_rm_tail_ok:
  LD r2,r1,#NC_QCOUNT
  CMP r2,r0
  JMP[EQ] @nsd_rm_count_ok
  SUB r2,r2,r13
  ST r2,r1,#NC_QCOUNT
nsd_rm_count_ok:
  LD r1,r14,8
  ST r0,r1,#NSD_T_NEXT
  MOVI r1,0
  JMP @nsd_rm_out
nsd_rm_noent:
  MOVI r1,#NSD_NOENT
nsd_rm_out:
  ADDI r14,r14,#NSD_SFRAME_NEG
  LD r15,r14,0
  RET

; nsd_ipi r1=ctx r2=target -> 0.  Optional transport; counts requests.
nsd_ipi:
  ST r15,r14,0
  ADDI r14,r14,#NSD_SFRAME
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,#NSD_C_OPS
  LD r3,r3,#NSD_OP_IPI
  CMP r3,r0
  JMP[EQ] @nsd_ipi_out
  ADD r1,r2,r0
  CALLR r3
  LD r1,r14,1
  MOVI r2,#NSD_C_IPIS
  CALL @nsd_stat_global
nsd_ipi_out:
  MOVI r1,0
  ADDI r14,r14,#NSD_SFRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsched_init ctx,cpus,arena,stride,capacity,ops -> 0/3.
nsched_init:
  ST r15,r14,0
  ADDI r14,r14,#NSD_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  ST r5,r14,12
  ST r6,r14,13
  CMP r1,r0
  JMP[EQ] @nsd_init_bad
  CMP r2,r0
  JMP[EQ] @nsd_init_bad
  MOVI r7,#NSD_MAX_CPUS
  CMP r2,r7
  JMP[GT] @nsd_init_bad
  CMP r3,r0
  JMP[EQ] @nsd_init_bad
  MOVI r7,#NSD_T_WORDS
  CMP r4,r7
  JMP[LT] @nsd_init_bad
  CMP r5,r0
  JMP[EQ] @nsd_init_bad
  CMP r6,r0
  JMP[EQ] @nsd_init_bad
  ST r2,r1,#NSD_C_CPUS
  ST r3,r1,#NSD_C_ARENA
  ST r4,r1,#NSD_C_STRIDE
  ST r5,r1,#NSD_C_CAP
  ST r6,r1,#NSD_C_OPS
  MOVI r2,#NSD_C_TICK
  MOVI r3,#NSD_C_WORDS
nsd_init_hdr:
  CMP r2,r3
  JMP[GE] @nsd_init_hdr_done
  ADD r4,r1,r2
  ST r0,r4,0
  ADDI r2,r2,1
  JMP @nsd_init_hdr
nsd_init_hdr_done:
  MOVI r6,0
  ST r6,r14,14
nsd_init_cpu:
  LD r6,r14,14
  LD r7,r14,9
  CMP r6,r7
  JMP[GE] @nsd_init_ok
  ADD r1,r6,r0
  CALL @nsd_nc
  ST r0,r1,#NC_QHEAD
  ST r0,r1,#NC_QTAIL
  ST r0,r1,#NC_QCOUNT
  ST r0,r1,#NC_STEAL_HEAD
  ST r0,r1,#NC_STEAL_TAIL
  ST r0,r1,#NSD_NC_CUR
  ST r0,r1,#NSD_NC_LOCK
  ST r0,r1,#NC_PREEMPT
  LD r1,r14,8
  ADD r2,r6,r0
  CALL @nsd_stats
  ST r0,r1,0
  ST r0,r1,1
  ST r0,r1,2
  ST r0,r1,3
  ST r0,r1,4
  ST r0,r1,5
  ST r0,r1,6
  ST r0,r1,7
  LD r6,r14,14
  ADDI r6,r6,1
  ST r6,r14,14
  JMP @nsd_init_cpu
nsd_init_ok:
  MOVI r1,0
  JMP @nsd_init_out
nsd_init_bad:
  MOVI r1,#NSD_BAD
nsd_init_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NSD_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsched_task_add ctx,id,home,affinity,budget,deadline -> 0/3.
nsched_task_add:
  ST r15,r14,0
  ADDI r14,r14,#NSD_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  ST r5,r14,12
  ST r6,r14,13
  CMP r1,r0
  JMP[EQ] @nsd_ta_bad
  LD r7,r1,#NSD_C_CAP
  CMP r2,r7
  JMP[GE] @nsd_ta_bad
  LD r7,r1,#NSD_C_CPUS
  CMP r3,r7
  JMP[GE] @nsd_ta_bad
  CMP r4,r0
  JMP[EQ] @nsd_ta_bad
  CALL @nsd_rec
  ST r1,r14,14
  ST r0,r1,#NSD_T_STATE
  LD r3,r14,10
  ST r3,r1,#NSD_T_CPU
  ST r3,r1,#NSD_T_HOME
  LD r3,r14,11
  ST r3,r1,#NSD_T_AFF
  LD r3,r14,12
  ST r3,r1,#NSD_T_BUDGET
  ST r3,r1,#NSD_T_QUANTUM
  LD r3,r14,13
  ST r3,r1,#NSD_T_DEADLINE
  ST r0,r1,#NSD_T_NEXT
  LD r3,r14,9
  ST r3,r1,#NSD_T_ID
  ST r0,r1,#NSD_T_FLAGS
  MOVI r3,#NSD_NONE
  ST r3,r1,#NSD_T_MIGTO
  ST r0,r1,#NSD_T_EPOCH
  MOVI r3,#NSD_MAGIC
  ST r3,r1,#NSD_T_MAGIC
  MOVI r1,0
  JMP @nsd_ta_out
nsd_ta_bad:
  MOVI r1,#NSD_BAD
nsd_ta_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NSD_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsched_affinity ctx,id,mask -> 0/2/3.
nsched_affinity:
  ST r15,r14,0
  ADDI r14,r14,#NSD_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  CMP r1,r0
  JMP[EQ] @nsd_af_bad
  CMP r3,r0
  JMP[EQ] @nsd_af_bad
  LD r7,r1,#NSD_C_CAP
  CMP r2,r7
  JMP[GE] @nsd_af_bad
  CALL @nsd_rec
  ST r1,r14,11
  LD r3,r1,#NSD_T_MAGIC
  MOVI r4,#NSD_MAGIC
  CMP r3,r4
  JMP[NE] @nsd_af_bad
  LD r3,r1,#NSD_T_STATE
  CMP r3,r0
  JMP[EQ] @nsd_af_set
  CMP r3,r13
  JMP[EQ] @nsd_af_check
  MOVI r4,#NSD_RUN
  CMP r3,r4
  JMP[NE] @nsd_af_set
nsd_af_check:
  LD r3,r1,#NSD_T_CPU
  ADD r1,r3,r0
  CALL @nsd_cpu_bit
  LD r3,r14,10
  BOOL.8 r4,r1,r3
  CMP r4,r0
  JMP[NE] @nsd_af_set
  MOVI r1,#NSD_BUSY
  JMP @nsd_af_out
nsd_af_set:
  LD r1,r14,11
  LD r3,r14,10
  ST r3,r1,#NSD_T_AFF
  MOVI r1,0
  JMP @nsd_af_out
nsd_af_bad:
  MOVI r1,#NSD_BAD
nsd_af_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NSD_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsched_budget ctx,id,value -> 0/3.  Sets ticks left, not the quantum.
nsched_budget:
  ST r15,r14,0
  ADDI r14,r14,#NSD_FRAME
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CMP r1,r0
  JMP[EQ] @nsd_bud_bad
  LD r4,r1,#NSD_C_CAP
  CMP r2,r4
  JMP[GE] @nsd_bud_bad
  CALL @nsd_rec
  LD r3,r14,3
  ST r3,r1,#NSD_T_BUDGET
  MOVI r1,0
  JMP @nsd_bud_out
nsd_bud_bad:
  MOVI r1,#NSD_BAD
nsd_bud_out:
  ADDI r14,r14,#NSD_FRAME_NEG
  LD r15,r14,0
  RET

; nsched_deadline ctx,id,tick -> 0/3.
nsched_deadline:
  ST r15,r14,0
  ADDI r14,r14,#NSD_FRAME
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CMP r1,r0
  JMP[EQ] @nsd_dl_bad
  LD r4,r1,#NSD_C_CAP
  CMP r2,r4
  JMP[GE] @nsd_dl_bad
  CALL @nsd_rec
  LD r3,r14,3
  ST r3,r1,#NSD_T_DEADLINE
  MOVI r1,0
  JMP @nsd_dl_out
nsd_dl_bad:
  MOVI r1,#NSD_BAD
nsd_dl_out:
  ADDI r14,r14,#NSD_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsched_push ctx,cpu,id -> 0/1/2/3.
nsched_push:
  ST r15,r14,0
  ADDI r14,r14,#NSD_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  CMP r1,r0
  JMP[EQ] @nsd_push_bad
  LD r7,r1,#NSD_C_CPUS
  CMP r2,r7
  JMP[GE] @nsd_push_bad
  LD r7,r1,#NSD_C_CAP
  CMP r3,r7
  JMP[GE] @nsd_push_bad
  ADD r2,r3,r0
  CALL @nsd_rec
  ST r1,r14,11
  LD r7,r1,#NSD_T_MAGIC
  MOVI r8,#NSD_MAGIC
  CMP r7,r8
  JMP[NE] @nsd_push_bad
  LD r7,r1,#NSD_T_STATE
  CMP r7,r0
  JMP[NE] @nsd_push_busy
  LD r8,r14,9
  ADD r1,r8,r0
  CALL @nsd_cpu_bit
  ST r1,r14,12
  LD r7,r14,11
  LD r7,r7,#NSD_T_AFF
  BOOL.8 r8,r7,r1
  CMP r8,r0
  JMP[EQ] @nsd_push_aff
  LD r1,r14,8
  LD r2,r14,9
  CALL @nsd_lock
  LD r1,r14,11
  LD r7,r14,9
  ST r7,r1,#NSD_T_CPU
  MOVI r7,#NSD_READY
  ST r7,r1,#NSD_T_STATE
  LD r1,r14,8
  LD r2,r14,9
  LD r3,r14,10
  CALL @nsd_enqueue_locked
  LD r1,r14,8
  LD r2,r14,9
  CALL @nsd_unlock
  LD r1,r14,8
  LD r2,r14,9
  MOVI r3,#NSD_S_PUSH
  CALL @nsd_stat_cpu
  LD r1,r14,8
  MOVI r2,#NSD_C_PUSHES
  CALL @nsd_stat_global
  LD r1,r14,8
  CALL @nsd_fence
  MOVI r1,0
  JMP @nsd_push_out
nsd_push_aff:
  LD r1,r14,8
  MOVI r2,#NSD_C_AFFREJ
  CALL @nsd_stat_global
  MOVI r1,#NSD_AFF
  JMP @nsd_push_out
nsd_push_busy:
  MOVI r1,#NSD_BUSY
  JMP @nsd_push_out
nsd_push_bad:
  MOVI r1,#NSD_BAD
nsd_push_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NSD_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsched_pop ctx,cpu -> id / NSD_CURBUSY / NSD_NONE / NSD_BAD.
nsched_pop:
  ST r15,r14,0
  ADDI r14,r14,#NSD_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  CMP r1,r0
  JMP[EQ] @nsd_pop_bad
  LD r7,r1,#NSD_C_CPUS
  CMP r2,r7
  JMP[GE] @nsd_pop_bad
  ADD r1,r2,r0
  CALL @nsd_nc
  ST r1,r14,10
  LD r3,r1,#NSD_NC_CUR
  CMP r3,r0
  JMP[NE] @nsd_pop_busy
  LD r1,r14,8
  LD r2,r14,9
  CALL @nsd_lock
  LD r1,r14,8
  LD r2,r14,9
  CALL @nsd_dequeue_locked
  ST r1,r14,11
  LD r1,r14,8
  LD r2,r14,9
  CALL @nsd_unlock
  LD r3,r14,11
  MOVI r4,#NSD_NONE
  CMP r3,r4
  JMP[EQ] @nsd_pop_none
  LD r1,r14,8
  ADD r2,r3,r0
  CALL @nsd_rec
  ST r1,r14,12
  LD r3,r14,11
  ST r3,r1,#NSD_T_ID
  LD r3,r14,9
  ST r3,r1,#NSD_T_CPU
  MOVI r3,#NSD_RUN
  ST r3,r1,#NSD_T_STATE
  LD r3,r1,#NSD_T_QUANTUM
  ST r3,r1,#NSD_T_BUDGET
  LD r3,r14,11
  ADDI r3,r3,1
  LD r1,r14,10
  ST r3,r1,#NSD_NC_CUR
  LD r1,r14,8
  LD r2,r14,9
  MOVI r3,#NSD_S_POP
  CALL @nsd_stat_cpu
  LD r1,r14,8
  MOVI r2,#NSD_C_POPS
  CALL @nsd_stat_global
  LD r1,r14,8
  CALL @nsd_fence
  LD r1,r14,11
  JMP @nsd_pop_out
nsd_pop_busy:
  MOVI r1,#NSD_CURBUSY
  JMP @nsd_pop_out
nsd_pop_none:
  MOVI r1,#NSD_NONE
  JMP @nsd_pop_out
nsd_pop_bad:
  MOVI r1,#NSD_BAD
nsd_pop_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NSD_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsched_preempt ctx,cpu -> id / NSD_NONE / NSD_BAD.
nsched_preempt:
  ST r15,r14,0
  ADDI r14,r14,#NSD_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  CMP r1,r0
  JMP[EQ] @nsd_pre_bad
  LD r7,r1,#NSD_C_CPUS
  CMP r2,r7
  JMP[GE] @nsd_pre_bad
  ADD r1,r2,r0
  CALL @nsd_nc
  ST r1,r14,10
  LD r3,r1,#NSD_NC_CUR
  CMP r3,r0
  JMP[EQ] @nsd_pre_none
  SUB r3,r3,r13
  ST r3,r14,11
  LD r1,r14,8
  ADD r2,r3,r0
  CALL @nsd_rec
  ST r1,r14,12
  LD r3,r1,#NSD_T_STATE
  MOVI r4,#NSD_RUN
  CMP r3,r4
  JMP[NE] @nsd_pre_none
  LD r1,r14,10
  ST r0,r1,#NSD_NC_CUR
  LD r1,r14,8
  LD r2,r14,9
  CALL @nsd_lock
  LD r1,r14,12
  MOVI r3,#NSD_READY
  ST r3,r1,#NSD_T_STATE
  LD r1,r14,8
  LD r2,r14,9
  LD r3,r14,11
  CALL @nsd_enqueue_locked
  LD r1,r14,8
  LD r2,r14,9
  CALL @nsd_unlock
  LD r1,r14,8
  LD r2,r14,9
  MOVI r3,#NSD_S_PREEMPT
  CALL @nsd_stat_cpu
  LD r1,r14,8
  MOVI r2,#NSD_C_PREEMPT
  CALL @nsd_stat_global
  LD r1,r14,10
  LD r2,r14,8
  LD r2,r2,#NSD_C_TICK
  ST r2,r1,#NC_PREEMPT
  LD r1,r14,8
  CALL @nsd_fence
  LD r1,r14,11
  JMP @nsd_pre_out
nsd_pre_none:
  MOVI r1,#NSD_NONE
  JMP @nsd_pre_out
nsd_pre_bad:
  MOVI r1,#NSD_BAD
nsd_pre_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NSD_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsched_tick ctx,cpu -> 1 preempted / 0 accounted / 3 bad.
nsched_tick:
  ST r15,r14,0
  ADDI r14,r14,#NSD_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  CMP r1,r0
  JMP[EQ] @nsd_tick_bad
  LD r7,r1,#NSD_C_CPUS
  CMP r2,r7
  JMP[GE] @nsd_tick_bad
  ADDI r2,r1,#NSD_C_TICK
  MOVI r3,1
  CALL @nsd_fadd
  ADDI r1,r1,1
  ST r1,r14,10
  LD r1,r14,8
  LD r2,r14,9
  ADD r1,r2,r0
  CALL @nsd_nc
  ST r1,r14,11
  LD r3,r1,#NSD_NC_CUR
  CMP r3,r0
  JMP[EQ] @nsd_tick_zero
  SUB r3,r3,r13
  ST r3,r14,12
  LD r1,r14,8
  ADD r2,r3,r0
  CALL @nsd_rec
  ST r1,r14,13
  LD r1,r14,8
  LD r2,r14,9
  MOVI r3,#NSD_S_TICKS
  CALL @nsd_stat_cpu
  LD r1,r14,13
  LD r3,r1,#NSD_T_DEADLINE
  CMP r3,r0
  JMP[EQ] @nsd_tick_budget
  LD r4,r14,10
  CMP r4,r3
  JMP[LE] @nsd_tick_budget
  LD r3,r1,#NSD_T_FLAGS
  MOVI r4,1
  BOOL.8 r5,r3,r4
  CMP r5,r0
  JMP[NE] @nsd_tick_budget
  MOVI r4,1
  BOOL.14 r3,r3,r4
  ST r3,r1,#NSD_T_FLAGS
  LD r1,r14,8
  MOVI r2,#NSD_C_DEADLINE
  CALL @nsd_stat_global
nsd_tick_budget:
  LD r1,r14,13
  LD r3,r1,#NSD_T_BUDGET
  CMP r3,r0
  JMP[EQ] @nsd_tick_exhaust
  SUB r3,r3,r13
  ST r3,r1,#NSD_T_BUDGET
  CMP r3,r0
  JMP[NE] @nsd_tick_zero
nsd_tick_exhaust:
  LD r1,r14,8
  MOVI r2,#NSD_C_BUDGET
  CALL @nsd_stat_global
  LD r1,r14,11
  ST r0,r1,#NSD_NC_CUR
  LD r1,r14,8
  LD r2,r14,9
  CALL @nsd_lock
  LD r1,r14,13
  MOVI r3,#NSD_READY
  ST r3,r1,#NSD_T_STATE
  LD r1,r14,8
  LD r2,r14,9
  LD r3,r14,12
  CALL @nsd_enqueue_locked
  LD r1,r14,8
  LD r2,r14,9
  CALL @nsd_unlock
  LD r1,r14,8
  LD r2,r14,9
  MOVI r3,#NSD_S_PREEMPT
  CALL @nsd_stat_cpu
  LD r1,r14,8
  MOVI r2,#NSD_C_PREEMPT
  CALL @nsd_stat_global
  LD r1,r14,11
  LD r2,r14,10
  ST r2,r1,#NC_PREEMPT
  LD r1,r14,8
  CALL @nsd_fence
  MOVI r1,1
  JMP @nsd_tick_out
nsd_tick_zero:
  MOVI r1,0
  JMP @nsd_tick_out
nsd_tick_bad:
  MOVI r1,#NSD_BAD
nsd_tick_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NSD_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsched_migrate_request ctx,id,to -> 0/1/2/3.
nsched_migrate_request:
  ST r15,r14,0
  ADDI r14,r14,#NSD_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  CMP r1,r0
  JMP[EQ] @nsd_mr_bad
  LD r7,r1,#NSD_C_CPUS
  CMP r3,r7
  JMP[GE] @nsd_mr_bad
  LD r7,r1,#NSD_C_CAP
  CMP r2,r7
  JMP[GE] @nsd_mr_bad
  CALL @nsd_rec
  ST r1,r14,11
  LD r3,r1,#NSD_T_MAGIC
  MOVI r4,#NSD_MAGIC
  CMP r3,r4
  JMP[NE] @nsd_mr_bad
  LD r3,r1,#NSD_T_STATE
  CMP r3,r0
  JMP[EQ] @nsd_mr_bad
  MOVI r4,#NSD_DONE
  CMP r3,r4
  JMP[EQ] @nsd_mr_bad
  LD r3,r1,#NSD_T_CPU
  LD r4,r14,10
  CMP r3,r4
  JMP[EQ] @nsd_mr_busy
  ADD r1,r4,r0
  CALL @nsd_cpu_bit
  ST r1,r14,12
  LD r1,r14,11
  LD r3,r1,#NSD_T_AFF
  LD r4,r14,12
  BOOL.8 r5,r3,r4
  CMP r5,r0
  JMP[EQ] @nsd_mr_aff
  LD r3,r1,#NSD_T_FLAGS
  MOVI r4,#NSD_F_MIGRATE
  BOOL.14 r3,r3,r4
  ST r3,r1,#NSD_T_FLAGS
  LD r3,r14,10
  ST r3,r1,#NSD_T_MIGTO
  LD r1,r14,8
  MOVI r2,#NSD_C_MIGREQ
  CALL @nsd_stat_global
  MOVI r1,0
  JMP @nsd_mr_out
nsd_mr_aff:
  LD r1,r14,8
  MOVI r2,#NSD_C_AFFREJ
  CALL @nsd_stat_global
  MOVI r1,#NSD_AFF
  JMP @nsd_mr_out
nsd_mr_busy:
  MOVI r1,#NSD_BUSY
  JMP @nsd_mr_out
nsd_mr_bad:
  MOVI r1,#NSD_BAD
nsd_mr_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NSD_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsched_migrate ctx,id,from,to -> 0/1/2/3/4.
nsched_migrate:
  ST r15,r14,0
  ADDI r14,r14,#NSD_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  CMP r1,r0
  JMP[EQ] @nsd_mig_bad
  LD r7,r1,#NSD_C_CPUS
  CMP r3,r7
  JMP[GE] @nsd_mig_bad
  CMP r4,r7
  JMP[GE] @nsd_mig_bad
  LD r7,r1,#NSD_C_CAP
  CMP r2,r7
  JMP[GE] @nsd_mig_bad
  LD r3,r14,10
  LD r4,r14,11
  CMP r3,r4
  JMP[EQ] @nsd_mig_ok_zero
  LD r1,r14,8
  LD r2,r14,9
  CALL @nsd_rec
  ST r1,r14,12
  LD r3,r1,#NSD_T_MAGIC
  MOVI r4,#NSD_MAGIC
  CMP r3,r4
  JMP[NE] @nsd_mig_bad
  LD r3,r1,#NSD_T_STATE
  CMP r3,r0
  JMP[EQ] @nsd_mig_busy
  MOVI r4,#NSD_DONE
  CMP r3,r4
  JMP[EQ] @nsd_mig_busy
  LD r4,r1,#NSD_T_CPU
  LD r5,r14,10
  CMP r4,r5
  JMP[NE] @nsd_mig_noent
  LD r4,r14,11
  ADD r1,r4,r0
  CALL @nsd_cpu_bit
  ST r1,r14,13
  LD r1,r14,12
  LD r3,r1,#NSD_T_AFF
  LD r4,r14,13
  BOOL.8 r5,r3,r4
  CMP r5,r0
  JMP[EQ] @nsd_mig_aff
  LD r3,r1,#NSD_T_STATE
  MOVI r4,#NSD_READY
  CMP r3,r4
  JMP[EQ] @nsd_mig_dequeue
  LD r1,r14,8
  LD r2,r14,10
  ADD r1,r2,r0
  CALL @nsd_nc
  ST r1,r14,14
  LD r3,r1,#NSD_NC_CUR
  LD r4,r14,9
  ADDI r4,r4,1
  CMP r3,r4
  JMP[NE] @nsd_mig_noent
  ST r0,r1,#NSD_NC_CUR
  JMP @nsd_mig_insert
nsd_mig_dequeue:
  LD r1,r14,8
  LD r2,r14,10
  CALL @nsd_lock
  LD r1,r14,8
  LD r2,r14,10
  LD r3,r14,9
  CALL @nsd_remove_locked
  ST r1,r14,15
  LD r1,r14,8
  LD r2,r14,10
  CALL @nsd_unlock
  LD r3,r14,15
  CMP r3,r0
  JMP[NE] @nsd_mig_noent
nsd_mig_insert:
  LD r1,r14,8
  LD r2,r14,11
  CALL @nsd_lock
  LD r1,r14,12
  MOVI r3,#NSD_READY
  ST r3,r1,#NSD_T_STATE
  LD r3,r14,11
  ST r3,r1,#NSD_T_CPU
  LD r3,r1,#NSD_T_FLAGS
  LA r4,0xFFFFFFFD
  BOOL.8 r3,r3,r4
  ST r3,r1,#NSD_T_FLAGS
  LD r3,r14,11
  ST r3,r1,#NSD_T_MIGTO
  LD r1,r14,8
  LD r2,r14,11
  LD r3,r14,9
  CALL @nsd_enqueue_locked
  LD r1,r14,8
  LD r2,r14,11
  CALL @nsd_unlock
  LD r1,r14,8
  LD r2,r14,8
  ADDI r2,r2,#NSD_C_EPOCH
  MOVI r3,1
  CALL @nsd_fadd
  ADDI r1,r1,1
  LD r3,r14,12
  ST r1,r3,#NSD_T_EPOCH
  LD r1,r14,8
  LD r2,r14,10
  MOVI r3,#NSD_S_MIG_OUT
  CALL @nsd_stat_cpu
  LD r1,r14,8
  LD r2,r14,11
  MOVI r3,#NSD_S_MIG_IN
  CALL @nsd_stat_cpu
  LD r1,r14,8
  MOVI r2,#NSD_C_MIGS
  CALL @nsd_stat_global
  LD r1,r14,8
  LD r2,r14,11
  CALL @nsd_ipi
  LD r1,r14,8
  CALL @nsd_fence
  MOVI r1,0
  JMP @nsd_mig_out
nsd_mig_ok_zero:
  MOVI r1,0
  JMP @nsd_mig_out
nsd_mig_aff:
  LD r1,r14,8
  MOVI r2,#NSD_C_AFFREJ
  CALL @nsd_stat_global
  MOVI r1,#NSD_AFF
  JMP @nsd_mig_out
nsd_mig_busy:
  MOVI r1,#NSD_BUSY
  JMP @nsd_mig_out
nsd_mig_noent:
  MOVI r1,#NSD_NOENT
  JMP @nsd_mig_out
nsd_mig_bad:
  MOVI r1,#NSD_BAD
nsd_mig_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NSD_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsched_steal ctx,cpu -> id / NSD_NONE / NSD_BAD.  The thief must be empty.
nsched_steal:
  ST r15,r14,0
  ADDI r14,r14,#NSD_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  CMP r1,r0
  JMP[EQ] @nsd_st_bad
  LD r7,r1,#NSD_C_CPUS
  CMP r2,r7
  JMP[GE] @nsd_st_bad
  ADD r1,r2,r0
  CALL @nsd_nc
  LD r3,r1,#NC_QCOUNT
  CMP r3,r0
  JMP[NE] @nsd_st_none
  MOVI r3,1
  ST r3,r14,10
nsd_st_loop:
  LD r3,r14,10
  LD r4,r14,8
  LD r4,r4,#NSD_C_CPUS
  CMP r3,r4
  JMP[GE] @nsd_st_none
  LD r4,r14,9
  ADD r5,r4,r3
  LD r6,r14,8
  LD r6,r6,#NSD_C_CPUS
  CMP r5,r6
  JMP[LT] @nsd_st_victim
  SUB r5,r5,r6
nsd_st_victim:
  ST r5,r14,11
  ADD r1,r5,r0
  CALL @nsd_nc
  ST r1,r14,12
  LD r3,r1,#NC_QCOUNT
  CMP r3,r0
  JMP[EQ] @nsd_st_next
  LD r3,r1,#NC_QHEAD
  CMP r3,r0
  JMP[EQ] @nsd_st_next
  SUB r3,r3,r13
  ST r3,r14,13
  LD r1,r14,8
  ADD r2,r3,r0
  CALL @nsd_rec
  ST r1,r14,14
  LD r1,r14,9
  CALL @nsd_cpu_bit
  LD r3,r14,14
  LD r3,r3,#NSD_T_AFF
  BOOL.8 r4,r3,r1
  CMP r4,r0
  JMP[NE] @nsd_st_take
  LD r1,r14,8
  MOVI r2,#NSD_C_AFFREJ
  CALL @nsd_stat_global
  JMP @nsd_st_next
nsd_st_take:
  LD r1,r14,8
  LD r2,r14,11
  CALL @nsd_lock
  LD r1,r14,12
  LD r3,r1,#NC_QCOUNT
  CMP r3,r0
  JMP[EQ] @nsd_st_unlock_next
  LD r1,r14,8
  LD r2,r14,11
  CALL @nsd_dequeue_locked
  ST r1,r14,15
  LD r1,r14,8
  LD r2,r14,11
  CALL @nsd_unlock
  LD r3,r14,15
  MOVI r4,#NSD_NONE
  CMP r3,r4
  JMP[EQ] @nsd_st_next
  LD r1,r14,8
  ADD r2,r3,r0
  CALL @nsd_rec
  ST r1,r14,14
  LD r1,r14,9
  CALL @nsd_cpu_bit
  LD r3,r14,14
  LD r3,r3,#NSD_T_AFF
  BOOL.8 r4,r3,r1
  CMP r4,r0
  JMP[NE] @nsd_st_insert
  LD r1,r14,8
  LD r2,r14,11
  CALL @nsd_lock
  LD r1,r14,8
  LD r2,r14,11
  LD r3,r14,15
  CALL @nsd_push_head_locked
  LD r1,r14,8
  LD r2,r14,11
  CALL @nsd_unlock
  LD r1,r14,8
  MOVI r2,#NSD_C_AFFREJ
  CALL @nsd_stat_global
  JMP @nsd_st_next
nsd_st_insert:
  LD r1,r14,8
  LD r2,r14,9
  CALL @nsd_lock
  LD r1,r14,14
  MOVI r3,#NSD_READY
  ST r3,r1,#NSD_T_STATE
  LD r3,r14,9
  ST r3,r1,#NSD_T_CPU
  LD r1,r14,8
  LD r2,r14,9
  LD r3,r14,15
  CALL @nsd_enqueue_locked
  LD r1,r14,8
  LD r2,r14,9
  CALL @nsd_unlock
  LD r1,r14,8
  LD r2,r14,9
  MOVI r3,#NSD_S_STEAL_IN
  CALL @nsd_stat_cpu
  LD r1,r14,8
  LD r2,r14,11
  MOVI r3,#NSD_S_STEAL_OUT
  CALL @nsd_stat_cpu
  LD r1,r14,8
  MOVI r2,#NSD_C_STEALS
  CALL @nsd_stat_global
  LD r1,r14,8
  CALL @nsd_fence
  LD r1,r14,15
  JMP @nsd_st_out
nsd_st_unlock_next:
  LD r1,r14,8
  LD r2,r14,11
  CALL @nsd_unlock
nsd_st_next:
  LD r3,r14,10
  ADDI r3,r3,1
  ST r3,r14,10
  JMP @nsd_st_loop
nsd_st_none:
  MOVI r1,#NSD_NONE
  JMP @nsd_st_out
nsd_st_bad:
  MOVI r1,#NSD_BAD
nsd_st_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NSD_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsched_peek ctx,cpu -> head id / NSD_NONE / NSD_BAD.
nsched_peek:
  ST r15,r14,0
  ADDI r14,r14,#NSD_FRAME
  ST r1,r14,1
  ST r2,r14,2
  CMP r1,r0
  JMP[EQ] @nsd_pk_bad
  LD r3,r1,#NSD_C_CPUS
  CMP r2,r3
  JMP[GE] @nsd_pk_bad
  ADD r1,r2,r0
  CALL @nsd_nc
  LD r3,r1,#NC_QHEAD
  CMP r3,r0
  JMP[EQ] @nsd_pk_none
  SUB r1,r3,r13
  JMP @nsd_pk_out
nsd_pk_none:
  MOVI r1,#NSD_NONE
  JMP @nsd_pk_out
nsd_pk_bad:
  MOVI r1,#NSD_BAD
nsd_pk_out:
  ADDI r14,r14,#NSD_FRAME_NEG
  LD r15,r14,0
  RET

; nsched_current ctx,cpu -> id / NSD_NONE / NSD_BAD.
nsched_current:
  ST r15,r14,0
  ADDI r14,r14,#NSD_FRAME
  ST r1,r14,1
  ST r2,r14,2
  CMP r1,r0
  JMP[EQ] @nsd_cur_bad
  LD r3,r1,#NSD_C_CPUS
  CMP r2,r3
  JMP[GE] @nsd_cur_bad
  ADD r1,r2,r0
  CALL @nsd_nc
  LD r3,r1,#NSD_NC_CUR
  CMP r3,r0
  JMP[EQ] @nsd_cur_none
  SUB r1,r3,r13
  JMP @nsd_cur_out
nsd_cur_none:
  MOVI r1,#NSD_NONE
  JMP @nsd_cur_out
nsd_cur_bad:
  MOVI r1,#NSD_BAD
nsd_cur_out:
  ADDI r14,r14,#NSD_FRAME_NEG
  LD r15,r14,0
  RET

; nsched_qlen ctx,cpu -> count / NSD_BAD.
nsched_qlen:
  CMP r1,r0
  JMP[EQ] @nsd_ql_bad
  LD r3,r1,#NSD_C_CPUS
  CMP r2,r3
  JMP[GE] @nsd_ql_bad
  ST r15,r14,0
  ADDI r14,r14,#NSD_SFRAME
  ST r1,r14,1
  ST r2,r14,2
  ADD r1,r2,r0
  CALL @nsd_nc
  LD r1,r1,#NC_QCOUNT
  ADDI r14,r14,#NSD_SFRAME_NEG
  LD r15,r14,0
  RET
nsd_ql_bad:
  MOVI r1,#NSD_BAD
  RET
