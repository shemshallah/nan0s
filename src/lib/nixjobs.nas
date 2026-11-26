; nixjobs.nas - NANIX concurrent pipeline and background-job primitives.
;
; Contract: spec/NIX_JOBS.md.  This is the low-level layer only; it does not
; call nixsh, nixfd, nanpipe or any NX_* global.
;
; Model
; -----
; A worker is a real SVC 9 process with its own trap frame, region table,
; software stack and worker context.  It shares the flat physical image with
; every other process, so sharing is explicit: a caller-owned arena region is
; mapped RW in every worker and holds the ring, contexts, job table and
; witness words.
;
; The library deliberately does not use the process-global NFD table or the
; process-global nanpipe NP_W_* scratch words.  Each context carries its own
; 16-entry descriptor table in the same 5-word shape as NFD:
;
;   {used, kind, handle, flags, pipe_id}
;   kind 0 unused, 1 terminal, 2 reserved (worker file), 3 shared ring
;
; Kind 3 uses handle = ring word address and flags bit 0 = 1 for the write
; end.  Kind 1 writes bytes with PUTC.  Kind 2 is reserved because the NPAF
; open-file path is not reentrant; the shell must pre-open files and map them
; to a future worker-safe file backend.
;
; Ring
; ----
; One producer and one consumer, byte ring with a power-of-two capacity.
; Producer and consumer indexes are monotonic 32-bit byte counts; the bounded
; offset is index & (capacity-1).  The producer copies bytes then publishes
; tail; the consumer copies bytes then publishes head.  All index updates are
; aligned word stores, so on the single-core S1 a reader sees either the old
; or the new value, never a torn one.  This is SPSC only.  SMP needs a fence
; after the copy and CAS/atomic index updates (spec/NIX_JOBS.md section 4).
;
; A full writer and an empty reader back off with SVC 24 sleep(1).  That is a
; real scheduler block, not a spin, and it works at any priority.  A dedicated
; kernel pipe wait queue is the planned latency improvement; the public ABI
; does not assume timed waits.
;
; ABI
; ---
; r0=0, r13=1, r14=software stack (grows up), r15=link.
; Public routines preserve r12 (the worker context pointer), r13 and r14.
; They clobber r1..r11.  A stage receives its context in r12.
;
;   nj_ctx_init   r1=ctx r2=stage entry r3=stack base r4=stack words
;                 r5=priority r6=arena base r7=arena words
;                 r8=code base r9=code words r10=fd table
;                 r11=scratch byte ptr r12=scratch bytes -> ctx or 0
;   nj_spawn_worker r1=ctx -> pid or 0
;   nj_ctx_wait     r1=ctx -> exit status (reaps)
;
;   nj_fd_set     r1=ctx r2=fd r3=kind r4=handle r5=flags -> 0/-1
;   nj_fd_clear   r1=ctx r2=fd -> 0/-1
;   nj_fd_init_stdio r1=ctx -> 0/-1
;   nj_fd_pipe    r1=ctx r2=ring r3=read fd r4=write fd -> 0/-1
;   nj_fd_read    r1=ctx r2=fd r3=dst byte r4=len -> bytes/-1
;   nj_fd_write   r1=ctx r2=fd r3=src byte r4=len -> bytes/-1
;   nj_fd_putc    r1=ctx r2=fd r3=char -> 1/-1
;   nj_fd_puts    r1=ctx r2=fd r3=word string -> count/-1
;   nj_fd_close   r1=ctx r2=fd -> 0/-1
;
;   nj_ring_init        r1=ring r2=capacity bytes r3=buffer byte ptr -> 0/-1
;   nj_ring_try_write   r1=ring r2=src r3=len -> bytes/0/-1
;   nj_ring_try_read    r1=ring r2=dst r3=len -> bytes/0/-1
;   nj_ring_write       r1=ring r2=src r3=len -> bytes/-1 (blocks when full)
;   nj_ring_read        r1=ring r2=dst r3=len -> bytes/0 EOF/-1
;   nj_ring_close_write r1=ring -> 0
;   nj_ring_close_read  r1=ring -> 0
;
;   nj_job_init   r1=table r2=capacity (1..64) -> 0/-1
;   nj_job_start  r1=table r2=ctx -> job id or 0
;   nj_job_wait   r1=table r2=job -> status (SVC 10 wait; marks WAITED)
;   nj_job_reap   r1=table r2=job -> status (frees the job slot)
;   nj_job_state  r1=table r2=job -> state or -1
;   nj_job_pid    r1=table r2=job -> pid or 0
;
; Worker context is NJ_C_SIZE words; see the offsets below.  A caller places
; contexts, fd tables, scratch and ring storage in its shared arena.  The
; spawn descriptor is built inside the context at NJ_C_DESC, so a spawn needs
; no library-global descriptor buffer.

; ---------------------------------------------------------------- constants
.equ NJ_MAGIC     0x4E4A4F42          ; "NJOB"
.equ NJ_RMAGIC    0x4E4A5242          ; "NJR B" ring magic
.equ NJ_JMAGIC    0x4E4A4A54          ; "NJ JT" job table magic
.equ NJ_NPRIO     32

; Worker states.
.equ NJ_ST_FREE    0
.equ NJ_ST_READY   1
.equ NJ_ST_RUNNING 2
.equ NJ_ST_BLOCKED 3
.equ NJ_ST_EXITED  4

; Per-context descriptor kinds (the same values as NIX_FD.md).
.equ NJ_FD_UNUSED 0
.equ NJ_FD_TERM   1
.equ NJ_FD_FILE   2
.equ NJ_FD_RING   3

; Job states.
.equ NJ_J_FREE    0
.equ NJ_J_RUNNING 1
.equ NJ_J_WAITED  2

; Nanproc region kinds/protection (spec/PROCESS_MODEL.md).
.equ NJ_K_IMAGE 1
.equ NJ_K_STACK 3
.equ NJ_K_SHARE 4
.equ NJ_PROT_RX 5
.equ NJ_PROT_RW 3

; Worker context layout (word offsets).
.equ NJ_C_MAGIC       0
.equ NJ_C_STATE       1
.equ NJ_C_PID         2
.equ NJ_C_TID         3
.equ NJ_C_PRIO        4
.equ NJ_C_FLAGS       5
.equ NJ_C_ENTRY       6
.equ NJ_C_STACK_BASE  7
.equ NJ_C_STACK_WORDS 8
.equ NJ_C_STACK_TOP   9
.equ NJ_C_CODE_BASE   10
.equ NJ_C_CODE_WORDS  11
.equ NJ_C_ARENA_BASE  12
.equ NJ_C_ARENA_WORDS 13
.equ NJ_C_FDTAB       14
.equ NJ_C_SCRATCH     15
.equ NJ_C_SCRATCH_LEN 16
.equ NJ_C_RING        17
.equ NJ_C_JOB         18
.equ NJ_C_RESULT      19
.equ NJ_C_TOTAL       20
.equ NJ_C_DONE        21
.equ NJ_C_HASH        22
.equ NJ_C_TICKS       23
.equ NJ_C_PEER        24
.equ NJ_C_WIT         25
.equ NJ_C_TMP0        26
.equ NJ_C_TMP1        27
.equ NJ_C_TMP2        28
.equ NJ_C_TMP3        29
.equ NJ_C_DESC        32              ; 5 + 8*4 = 37 words
.equ NJ_C_SIZE        72

; Ring layout (word offsets).
.equ NJ_R_MAGIC    0
.equ NJ_R_CAP      1
.equ NJ_R_MASK     2
.equ NJ_R_HEAD     3               ; consumer monotonic byte index
.equ NJ_R_TAIL     4               ; producer monotonic byte index
.equ NJ_R_WBLK     5               ; writer blocked/full events
.equ NJ_R_RBLK     6               ; reader blocked/empty events
.equ NJ_R_WCLOSED  7
.equ NJ_R_RCLOSED  8
.equ NJ_R_BUF      9               ; byte pointer
.equ NJ_R_SIZE     16

; Job table layout (word offsets; entries start at NJ_J_ENTRIES).
.equ NJ_J_MAGIC    0
.equ NJ_J_COUNT    1
.equ NJ_J_CAP      2
.equ NJ_J_NEXT     3
.equ NJ_J_ENTRIES  4
.equ NJ_J_E_SIZE   8
; entry fields
.equ NJ_JE_STATE   0
.equ NJ_JE_PID     1
.equ NJ_JE_CTX     2
.equ NJ_JE_STATUS  3
.equ NJ_JE_SEQ     4
.equ NJ_J_CAP_MAX  64

; FD entry size.
.equ NJ_FD_SIZE    5
.equ NJ_FD_WORDS   80
.equ NJ_FD_MAX     16

; ---------------------------------------------------------------- ctx init
; nj_ctx_init - zero a worker context, record its spawn parameters, zero its
; fd table and record the stack top used by nj_worker_entry.
nj_ctx_init:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  ST r7,r14,7
  ST r8,r14,8
  ST r9,r14,9
  ST r10,r14,10
  ST r11,r14,11
  ST r12,r14,12
  CMP r1,r0
  JMP[EQ] @nj_ci_bad
  CMP r2,r0
  JMP[EQ] @nj_ci_bad
  MOVI r2,1
  CMP r4,r2
  JMP[LE] @nj_ci_bad
  CMP r10,r0
  JMP[EQ] @nj_ci_bad
  CMP r9,r0
  JMP[EQ] @nj_ci_bad
  CMP r7,r0
  JMP[EQ] @nj_ci_bad
  ; zero the whole context
  LD r1,r14,1
  ADD r3,r1,r0
  MOVI r2,#NJ_C_SIZE
nj_ci_zero:
  ST r0,r3,0
  ADD r3,r3,r13
  SUB r2,r2,r13
  CMP r2,r0
  JMP[NE] @nj_ci_zero
  ; scalar fields
  LD r1,r14,1
  LA r2,#NJ_MAGIC
  ST r2,r1,#NJ_C_MAGIC
  LD r2,r14,2
  ST r2,r1,#NJ_C_ENTRY
  LD r2,r14,3
  ST r2,r1,#NJ_C_STACK_BASE
  LD r3,r14,4
  ST r3,r1,#NJ_C_STACK_WORDS
  SHR r4,r3,1
  ADD r2,r2,r4
  ST r2,r1,#NJ_C_STACK_TOP
  LD r2,r14,5
  ST r2,r1,#NJ_C_PRIO
  LD r2,r14,6
  ST r2,r1,#NJ_C_ARENA_BASE
  LD r3,r14,7
  ST r3,r1,#NJ_C_ARENA_WORDS
  LD r2,r14,8
  ST r2,r1,#NJ_C_CODE_BASE
  LD r3,r14,9
  ST r3,r1,#NJ_C_CODE_WORDS
  LD r2,r14,10
  ST r2,r1,#NJ_C_FDTAB
  LD r2,r14,11
  ST r2,r1,#NJ_C_SCRATCH
  LD r3,r14,12
  ST r3,r1,#NJ_C_SCRATCH_LEN
  LA r2,0xFFFFFFFF
  ST r2,r1,#NJ_C_JOB
  ; zero the 16*5 descriptor table
  LD r3,r14,10
  MOVI r2,#NJ_FD_WORDS
nj_ci_fdzero:
  ST r0,r3,0
  ADD r3,r3,r13
  SUB r2,r2,r13
  CMP r2,r0
  JMP[NE] @nj_ci_fdzero
  LD r1,r14,1
  JMP @nj_ci_out
nj_ci_bad:
  MOVI r1,0
nj_ci_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------- lifecycle
; nj_spawn_worker r1=ctx -> pid or 0.  The descriptor lives in the context:
;   {entry, sp, priority, name, 3, code, stack, shared arena}
; The child starts at nj_worker_entry with r14=stack_top and the context
; pointer in [r14].  The stage reuses that word for its first frame.  r12 is
; the context register for the stage.  The caller must map the stack pool
; that contains every worker stack (see spec/NIX_JOBS.md section 5).
nj_spawn_worker:
  ST r15,r14,0
  ADDI r14,r14,20
  ST r1,r14,1
  CMP r1,r0
  JMP[EQ] @nj_sw_bad
  LD r2,r1,#NJ_C_MAGIC
  LA r3,#NJ_MAGIC
  CMP r2,r3
  JMP[NE] @nj_sw_bad
  LD r2,r1,#NJ_C_STACK_TOP
  CMP r2,r0
  JMP[EQ] @nj_sw_bad
  ; stack_top <- ctx; nj_worker_entry reads it at offset 0 before using
  ; the same word for its own frame.
  ST r1,r2,0
  ; descriptor = ctx + NJ_C_DESC
  ADDI r2,r1,#NJ_C_DESC
  ST r2,r14,2
  LA r3,@nj_worker_entry
  ST r3,r2,0
  LD r3,r1,#NJ_C_STACK_TOP
  ST r3,r2,1
  LD r3,r1,#NJ_C_PRIO
  MOVI r4,#NJ_NPRIO
  CMP r3,r4
  JMP[LT] @nj_sw_prio
  MOVI r3,31
nj_sw_prio:
  ST r3,r2,2
  ST r0,r2,3
  MOVI r3,3
  ST r3,r2,4
  ; region 0: code image RX
  LD r3,r1,#NJ_C_CODE_BASE
  ST r3,r2,5
  LD r3,r1,#NJ_C_CODE_WORDS
  ST r3,r2,6
  MOVI r3,#NJ_K_IMAGE
  ST r3,r2,7
  MOVI r3,#NJ_PROT_RX
  ST r3,r2,8
  ; region 1: private stack RW
  LD r3,r1,#NJ_C_STACK_BASE
  ST r3,r2,9
  LD r3,r1,#NJ_C_STACK_WORDS
  ST r3,r2,10
  MOVI r3,#NJ_K_STACK
  ST r3,r2,11
  MOVI r3,#NJ_PROT_RW
  ST r3,r2,12
  ; region 2: shared arena RW
  LD r3,r1,#NJ_C_ARENA_BASE
  ST r3,r2,13
  LD r3,r1,#NJ_C_ARENA_WORDS
  ST r3,r2,14
  MOVI r3,#NJ_K_SHARE
  ST r3,r2,15
  MOVI r3,#NJ_PROT_RW
  ST r3,r2,16
  ; SVC 9 spawn(descriptor)
  ADD r1,r2,r0
  SVC 9
  LD r2,r14,1
  CMP r1,r0
  JMP[EQ] @nj_sw_fail
  ST r1,r2,#NJ_C_PID
  MOVI r3,#NJ_ST_READY
  ST r3,r2,#NJ_C_STATE
  JMP @nj_sw_out
nj_sw_fail:
  ST r0,r2,#NJ_C_STATE
nj_sw_bad:
  MOVI r1,0
nj_sw_out:
  ADDI r14,r14,-20
  LD r15,r14,0
  RET

; nj_worker_entry - common process entry.  The stage runs with r12=context.
nj_worker_entry:
  MOVI r13,1
  LD r12,r14,0
  CMP r12,r0
  JMP[EQ] @nj_we_bad
  MOVI r1,#NJ_ST_RUNNING
  ST r1,r12,#NJ_C_STATE
  LD r1,r12,#NJ_C_ENTRY
  CMP r1,r0
  JMP[EQ] @nj_we_bad
  CALLR r1
  ST r1,r12,#NJ_C_RESULT
  MOVI r2,#NJ_ST_EXITED
  ST r2,r12,#NJ_C_STATE
  SVC 1
nj_we_bad:
  MOVI r1,1
  SVC 1
  HALT

; nj_ctx_wait r1=ctx -> status, reaps the worker process.
nj_ctx_wait:
  ST r15,r14,0
  ADDI r14,r14,17
  ST r1,r14,1
  CMP r1,r0
  JMP[EQ] @nj_cw_bad
  LD r2,r1,#NJ_C_PID
  CMP r2,r0
  JMP[EQ] @nj_cw_bad
  ADD r1,r2,r0
  SVC 10
  ST r1,r14,2
  LD r2,r14,1
  ST r1,r2,#NJ_C_RESULT
  MOVI r3,#NJ_ST_FREE
  ST r3,r2,#NJ_C_STATE
  ST r0,r2,#NJ_C_PID
  LD r1,r14,2
  JMP @nj_cw_out
nj_cw_bad:
  LA r1,0xFFFFFFFF
nj_cw_out:
  ADDI r14,r14,-17
  LD r15,r14,0
  RET

; ---------------------------------------------------------------- fd table
; nj_fd_entry r1=ctx r2=fd -> entry or 0.  Internal; preserves r12.
nj_fd_entry:
  CMP r1,r0
  JMP[EQ] @nj_fe_no
  LD r3,r1,#NJ_C_MAGIC
  LA r4,#NJ_MAGIC
  CMP r3,r4
  JMP[NE] @nj_fe_no
  MOVI r3,#NJ_FD_MAX
  CMP r2,r3
  JMP[GE] @nj_fe_no
  LD r3,r1,#NJ_C_FDTAB
  CMP r3,r0
  JMP[EQ] @nj_fe_no
  MOVI r4,#NJ_FD_SIZE
  MUL r4,r2,r4
  ADD r3,r3,r4
  ADD r1,r3,r0
  RET
nj_fe_no:
  MOVI r1,0
  RET

; nj_fd_set r1=ctx r2=fd r3=kind r4=handle r5=flags -> 0/-1
nj_fd_set:
  ST r15,r14,0
  ADDI r14,r14,17
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  CALL @nj_fd_entry
  CMP r1,r0
  JMP[EQ] @nj_fs_bad
  MOVI r2,1
  ST r2,r1,0
  LD r2,r14,3
  ST r2,r1,1
  LD r2,r14,4
  ST r2,r1,2
  LD r2,r14,5
  ST r2,r1,3
  ST r0,r1,4
  MOVI r1,0
  JMP @nj_fs_out
nj_fs_bad:
  LA r1,0xFFFFFFFF
nj_fs_out:
  ADDI r14,r14,-17
  LD r15,r14,0
  RET

; nj_fd_clear r1=ctx r2=fd -> 0/-1
nj_fd_clear:
  ST r15,r14,0
  ADDI r14,r14,17
  ST r1,r14,1
  ST r2,r14,2
  CALL @nj_fd_entry
  CMP r1,r0
  JMP[EQ] @nj_fc_bad
  MOVI r2,#NJ_FD_SIZE
nj_fc_z:
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  CMP r2,r0
  JMP[NE] @nj_fc_z
  MOVI r1,0
  JMP @nj_fc_out
nj_fc_bad:
  LA r1,0xFFFFFFFF
nj_fc_out:
  ADDI r14,r14,-17
  LD r15,r14,0
  RET

; nj_fd_init_stdio r1=ctx -> 0/-1.  fd 0/1/2 are terminal descriptors.
nj_fd_init_stdio:
  ST r15,r14,0
  ADDI r14,r14,17
  ST r1,r14,1
  MOVI r2,0
  MOVI r3,#NJ_FD_TERM
  MOVI r4,0
  MOVI r5,0
  CALL @nj_fd_set
  CMP r1,r0
  JMP[NE] @nj_fis_bad
  LD r1,r14,1
  MOVI r2,1
  MOVI r3,#NJ_FD_TERM
  MOVI r4,1
  MOVI r5,0
  CALL @nj_fd_set
  CMP r1,r0
  JMP[NE] @nj_fis_bad
  LD r1,r14,1
  MOVI r2,2
  MOVI r3,#NJ_FD_TERM
  MOVI r4,2
  MOVI r5,0
  CALL @nj_fd_set
  CMP r1,r0
  JMP[NE] @nj_fis_bad
  MOVI r1,0
  JMP @nj_fis_out
nj_fis_bad:
  LA r1,0xFFFFFFFF
nj_fis_out:
  ADDI r14,r14,-17
  LD r15,r14,0
  RET

; nj_fd_pipe r1=ctx r2=ring r3=read fd r4=write fd -> 0/-1
nj_fd_pipe:
  ST r15,r14,0
  ADDI r14,r14,20
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  LD r2,r14,3
  MOVI r3,#NJ_FD_RING
  LD r4,r14,2
  MOVI r5,0
  CALL @nj_fd_set
  CMP r1,r0
  JMP[NE] @nj_fp_bad
  LD r1,r14,1
  LD r2,r14,4
  MOVI r3,#NJ_FD_RING
  LD r4,r14,2
  MOVI r5,1
  CALL @nj_fd_set
  CMP r1,r0
  JMP[NE] @nj_fp_bad
  MOVI r1,0
  JMP @nj_fp_out
nj_fp_bad:
  LA r1,0xFFFFFFFF
nj_fp_out:
  ADDI r14,r14,-20
  LD r15,r14,0
  RET

; nj_fd_write r1=ctx r2=fd r3=src byte r4=len -> bytes/-1
nj_fd_write:
  ST r15,r14,0
  ADDI r14,r14,20
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  CALL @nj_fd_entry
  CMP r1,r0
  JMP[EQ] @nj_fw_bad
  LD r2,r1,0
  CMP r2,r0
  JMP[EQ] @nj_fw_bad
  LD r2,r1,1
  MOVI r3,#NJ_FD_TERM
  CMP r2,r3
  JMP[EQ] @nj_fw_term
  MOVI r3,#NJ_FD_RING
  CMP r2,r3
  JMP[EQ] @nj_fw_ring
  JMP @nj_fw_bad
nj_fw_term:
  LD r1,r14,3
  LD r2,r14,4
  ST r2,r14,5
nj_fw_term_l:
  LD r3,r14,5
  CMP r3,r0
  JMP[EQ] @nj_fw_term_done
  LDB r4,r1,0
  PUTC r4
  ADD r1,r1,r13
  SUB r3,r3,r13
  ST r3,r14,5
  JMP @nj_fw_term_l
nj_fw_term_done:
  LD r1,r14,4
  JMP @nj_fw_out
nj_fw_ring:
  LD r3,r1,3
  MOVI r4,1
  BOOL.8 r3,r3,r4
  CMP r3,r0
  JMP[EQ] @nj_fw_bad
  LD r1,r1,2
  LD r2,r14,3
  LD r3,r14,4
  CALL @nj_ring_write
  JMP @nj_fw_out
nj_fw_bad:
  LA r1,0xFFFFFFFF
nj_fw_out:
  ADDI r14,r14,-20
  LD r15,r14,0
  RET

; nj_fd_read r1=ctx r2=fd r3=dst byte r4=len -> bytes/0/-1
nj_fd_read:
  ST r15,r14,0
  ADDI r14,r14,20
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  CALL @nj_fd_entry
  CMP r1,r0
  JMP[EQ] @nj_fr_bad
  LD r2,r1,0
  CMP r2,r0
  JMP[EQ] @nj_fr_bad
  LD r2,r1,1
  MOVI r3,#NJ_FD_RING
  CMP r2,r3
  JMP[EQ] @nj_fr_ring
  MOVI r3,#NJ_FD_TERM
  CMP r2,r3
  JMP[EQ] @nj_fr_eof
  JMP @nj_fr_bad
nj_fr_ring:
  LD r3,r1,3
  MOVI r4,1
  BOOL.8 r3,r3,r4
  CMP r3,r0
  JMP[NE] @nj_fr_bad
  LD r1,r1,2
  LD r2,r14,3
  LD r3,r14,4
  CALL @nj_ring_read
  JMP @nj_fr_out
nj_fr_eof:
  MOVI r1,0
  JMP @nj_fr_out
nj_fr_bad:
  LA r1,0xFFFFFFFF
nj_fr_out:
  ADDI r14,r14,-20
  LD r15,r14,0
  RET

; nj_fd_putc r1=ctx r2=fd r3=char -> 1/-1
nj_fd_putc:
  ST r15,r14,0
  ADDI r14,r14,17
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,4               ; one-byte staging word
  ADDI r5,r14,4
  SHL r5,r5,2               ; byte pointer to its lane 0
  LD r1,r14,1
  LD r2,r14,2
  ADD r3,r5,r0
  MOVI r4,1
  CALL @nj_fd_write
  CMP r1,r0
  JMP[LE] @nj_fp_bad2
  MOVI r1,1
  JMP @nj_fp_out2
nj_fp_bad2:
  LA r1,0xFFFFFFFF
nj_fp_out2:
  ADDI r14,r14,-17
  LD r15,r14,0
  RET

; nj_fd_puts r1=ctx r2=fd r3=word string -> count/-1
nj_fd_puts:
  ST r15,r14,0
  ADDI r14,r14,20
  ST r1,r14,1
  ST r2,r14,2
  SHL r3,r3,2
  ST r3,r14,3
  ST r0,r14,4
nj_fps_l:
  LD r3,r14,3
  LDB r4,r3,0
  CMP r4,r0
  JMP[EQ] @nj_fps_done
  LD r1,r14,1
  LD r2,r14,2
  ADD r3,r4,r0
  CALL @nj_fd_putc
  CMP r1,r0
  JMP[LE] @nj_fps_bad
  LD r3,r14,3
  ADD r3,r3,r13
  ST r3,r14,3
  LD r3,r14,4
  ADD r3,r3,r13
  ST r3,r14,4
  JMP @nj_fps_l
nj_fps_done:
  LD r1,r14,4
  JMP @nj_fps_out
nj_fps_bad:
  LA r1,0xFFFFFFFF
nj_fps_out:
  ADDI r14,r14,-20
  LD r15,r14,0
  RET

; nj_fd_close r1=ctx r2=fd -> 0/-1
nj_fd_close:
  ST r15,r14,0
  ADDI r14,r14,20
  ST r1,r14,1
  ST r2,r14,2
  CALL @nj_fd_entry
  CMP r1,r0
  JMP[EQ] @nj_fcl_bad
  ST r1,r14,3
  LD r2,r1,0
  CMP r2,r0
  JMP[EQ] @nj_fcl_clear
  LD r2,r1,1
  MOVI r3,#NJ_FD_RING
  CMP r2,r3
  JMP[NE] @nj_fcl_clear
  LD r2,r1,3
  MOVI r3,1
  BOOL.8 r2,r2,r3
  LD r1,r1,2
  CMP r2,r0
  JMP[EQ] @nj_fcl_read
  CALL @nj_ring_close_write
  JMP @nj_fcl_clear
nj_fcl_read:
  CALL @nj_ring_close_read
nj_fcl_clear:
  LD r1,r14,3
  MOVI r2,#NJ_FD_SIZE
nj_fcl_z:
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  CMP r2,r0
  JMP[NE] @nj_fcl_z
  MOVI r1,0
  JMP @nj_fcl_out
nj_fcl_bad:
  LA r1,0xFFFFFFFF
nj_fcl_out:
  ADDI r14,r14,-20
  LD r15,r14,0
  RET

; ---------------------------------------------------------------- ring
; nj_ring_init r1=ring r2=capacity bytes r3=buffer byte ptr -> 0/-1.
; Capacity must be a power of two and at least 16 bytes.
nj_ring_init:
  CMP r1,r0
  JMP[EQ] @nj_ri_bad
  MOVI r4,16
  CMP r2,r4
  JMP[LT] @nj_ri_bad
  SUB r4,r2,r13
  BOOL.8 r5,r2,r4
  CMP r5,r0
  JMP[NE] @nj_ri_bad
  LA r4,#NJ_RMAGIC
  ST r4,r1,#NJ_R_MAGIC
  ST r2,r1,#NJ_R_CAP
  SUB r2,r2,r13
  ST r2,r1,#NJ_R_MASK
  ST r0,r1,#NJ_R_HEAD
  ST r0,r1,#NJ_R_TAIL
  ST r0,r1,#NJ_R_WBLK
  ST r0,r1,#NJ_R_RBLK
  ST r0,r1,#NJ_R_WCLOSED
  ST r0,r1,#NJ_R_RCLOSED
  ST r3,r1,#NJ_R_BUF
  MOVI r1,0
  RET
nj_ri_bad:
  LA r1,0xFFFFFFFF
  RET

; nj_ring_try_write r1=ring r2=src r3=len -> bytes/0 full/-1 invalid.
nj_ring_try_write:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CMP r1,r0
  JMP[EQ] @nj_rtw_bad
  LD r4,r1,#NJ_R_MAGIC
  LA r5,#NJ_RMAGIC
  CMP r4,r5
  JMP[NE] @nj_rtw_bad
  LD r4,r1,#NJ_R_RCLOSED
  CMP r4,r0
  JMP[NE] @nj_rtw_bad
  LD r3,r14,3
  CMP r3,r0
  JMP[EQ] @nj_rtw_zero
  LD r4,r1,#NJ_R_TAIL
  LD r5,r1,#NJ_R_HEAD
  SUB r6,r4,r5
  ST r6,r14,4               ; used
  LD r7,r1,#NJ_R_CAP
  CMP r6,r7
  JMP[GE] @nj_rtw_zero
  SUB r8,r7,r6              ; space
  ST r8,r14,5
  LD r3,r14,3
  CMP r3,r8
  JMP[LE] @nj_rtw_n
  ADD r3,r8,r0
nj_rtw_n:
  ST r3,r14,6               ; n
  LD r4,r1,#NJ_R_TAIL
  LD r5,r1,#NJ_R_MASK
  BOOL.8 r4,r4,r5           ; offset
  ST r4,r14,7
  LD r7,r1,#NJ_R_CAP
  SUB r7,r7,r4              ; room to end
  ST r7,r14,8
  LD r3,r14,6
  CMP r3,r7
  JMP[LE] @nj_rtw_have
  ADD r3,r7,r0
  ST r3,r14,6
nj_rtw_have:
  LD r6,r14,6
  CMP r6,r0
  JMP[EQ] @nj_rtw_zero
  LD r4,r14,7
  LD r5,r1,#NJ_R_BUF
  ADD r5,r5,r4
  ST r5,r14,9               ; dest
  ADD r1,r5,r0
  LD r2,r14,2
  ADD r3,r6,r0
  CALL @nj_bcopy
  LD r1,r14,1
  LD r2,r1,#NJ_R_TAIL
  LD r3,r14,6
  ADD r2,r2,r3
  ST r2,r1,#NJ_R_TAIL
  ADD r1,r3,r0
  JMP @nj_rtw_out
nj_rtw_zero:
  MOVI r1,0
  JMP @nj_rtw_out
nj_rtw_bad:
  LA r1,0xFFFFFFFF
nj_rtw_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nj_ring_try_read r1=ring r2=dst r3=len -> bytes/0 empty/-1 invalid.
nj_ring_try_read:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CMP r1,r0
  JMP[EQ] @nj_rtr_bad
  LD r4,r1,#NJ_R_MAGIC
  LA r5,#NJ_RMAGIC
  CMP r4,r5
  JMP[NE] @nj_rtr_bad
  LD r3,r14,3
  CMP r3,r0
  JMP[EQ] @nj_rtr_zero
  LD r4,r1,#NJ_R_TAIL
  LD r5,r1,#NJ_R_HEAD
  SUB r6,r4,r5              ; used
  ST r6,r14,4
  CMP r6,r0
  JMP[EQ] @nj_rtr_zero
  LD r3,r14,3
  CMP r3,r6
  JMP[LE] @nj_rtr_n
  ADD r3,r6,r0
nj_rtr_n:
  ST r3,r14,6
  LD r4,r1,#NJ_R_HEAD
  LD r5,r1,#NJ_R_MASK
  BOOL.8 r4,r4,r5
  ST r4,r14,7
  LD r7,r1,#NJ_R_CAP
  SUB r7,r7,r4
  ST r7,r14,8
  LD r3,r14,6
  CMP r3,r7
  JMP[LE] @nj_rtr_have
  ADD r3,r7,r0
  ST r3,r14,6
nj_rtr_have:
  LD r6,r14,6
  CMP r6,r0
  JMP[EQ] @nj_rtr_zero
  LD r4,r14,7
  LD r5,r1,#NJ_R_BUF
  ADD r5,r5,r4
  LD r1,r14,2
  ADD r2,r5,r0
  ADD r3,r6,r0
  CALL @nj_bcopy
  LD r1,r14,1
  LD r2,r1,#NJ_R_HEAD
  LD r3,r14,6
  ADD r2,r2,r3
  ST r2,r1,#NJ_R_HEAD
  ADD r1,r3,r0
  JMP @nj_rtr_out
nj_rtr_zero:
  MOVI r1,0
  JMP @nj_rtr_out
nj_rtr_bad:
  LA r1,0xFFFFFFFF
nj_rtr_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nj_ring_write r1=ring r2=src r3=len -> bytes/-1.  Sleeps while full.
nj_ring_write:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r0,r14,4               ; total
nj_rw_loop:
  LD r3,r14,3
  CMP r3,r0
  JMP[EQ] @nj_rw_done
  LD r1,r14,1
  LD r4,r1,#NJ_R_RCLOSED
  CMP r4,r0
  JMP[NE] @nj_rw_bad
  LD r2,r14,2
  CALL @nj_ring_try_write
  CMP r1,r0
  JMP[LT] @nj_rw_bad
  CMP r1,r0
  JMP[NE] @nj_rw_got
  LD r1,r14,1
  LD r2,r1,#NJ_R_WBLK
  ADD r2,r2,r13
  ST r2,r1,#NJ_R_WBLK
  MOVI r1,1
  SVC 24
  JMP @nj_rw_loop
nj_rw_got:
  ST r1,r14,5
  LD r2,r14,2
  ADD r2,r2,r1
  ST r2,r14,2
  LD r2,r14,3
  SUB r2,r2,r1
  ST r2,r14,3
  LD r2,r14,4
  ADD r2,r2,r1
  ST r2,r14,4
  JMP @nj_rw_loop
nj_rw_done:
  LD r1,r14,4
  JMP @nj_rw_out
nj_rw_bad:
  LA r1,0xFFFFFFFF
nj_rw_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nj_ring_read r1=ring r2=dst r3=len -> bytes/0 EOF/-1.  Sleeps while empty.
nj_ring_read:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r0,r14,4               ; total
nj_rr_loop:
  LD r3,r14,3
  CMP r3,r0
  JMP[EQ] @nj_rr_done
  LD r1,r14,1
  LD r2,r14,2
  CALL @nj_ring_try_read
  CMP r1,r0
  JMP[LT] @nj_rr_bad
  CMP r1,r0
  JMP[NE] @nj_rr_got
  ; empty: EOF if the writer has closed, else block one tick
  LD r1,r14,1
  LD r2,r1,#NJ_R_WCLOSED
  CMP r2,r0
  JMP[NE] @nj_rr_done
  LD r2,r1,#NJ_R_RBLK
  ADD r2,r2,r13
  ST r2,r1,#NJ_R_RBLK
  MOVI r1,1
  SVC 24
  JMP @nj_rr_loop
nj_rr_got:
  ST r1,r14,5
  LD r2,r14,2
  ADD r2,r2,r1
  ST r2,r14,2
  LD r2,r14,3
  SUB r2,r2,r1
  ST r2,r14,3
  LD r2,r14,4
  ADD r2,r2,r1
  ST r2,r14,4
  JMP @nj_rr_loop
nj_rr_done:
  LD r1,r14,4
  JMP @nj_rr_out
nj_rr_bad:
  LA r1,0xFFFFFFFF
nj_rr_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nj_ring_close_write / nj_ring_close_read r1=ring -> 0
nj_ring_close_write:
  CMP r1,r0
  JMP[EQ] @nj_rcw_out
  MOVI r2,1
  ST r2,r1,#NJ_R_WCLOSED
nj_rcw_out:
  MOVI r1,0
  RET
nj_ring_close_read:
  CMP r1,r0
  JMP[EQ] @nj_rcr_out
  MOVI r2,1
  ST r2,r1,#NJ_R_RCLOSED
nj_rcr_out:
  MOVI r1,0
  RET

; nj_bcopy r1=dst byte r2=src byte r3=count.  Leaf; clobbers r1..r4.
nj_bcopy:
  CMP r3,r0
  JMP[EQ] @nj_bc_out
nj_bc_loop:
  LDB r4,r2,0
  STB r4,r1,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  SUB r3,r3,r13
  CMP r3,r0
  JMP[NE] @nj_bc_loop
nj_bc_out:
  RET

; ---------------------------------------------------------------- jobs
; nj_job_entry r1=table r2=job -> entry or 0.  Internal; preserves r12.
nj_job_entry:
  CMP r1,r0
  JMP[EQ] @nj_je_no
  LD r3,r1,#NJ_J_MAGIC
  LA r4,#NJ_JMAGIC
  CMP r3,r4
  JMP[NE] @nj_je_no
  CMP r2,r0
  JMP[EQ] @nj_je_no
  LD r3,r1,#NJ_J_CAP
  CMP r2,r3
  JMP[GT] @nj_je_no
  SUB r2,r2,r13
  MOVI r4,#NJ_J_E_SIZE
  MUL r2,r2,r4
  ADDI r1,r1,#NJ_J_ENTRIES
  ADD r1,r1,r2
  RET
nj_je_no:
  MOVI r1,0
  RET

; nj_job_init r1=table r2=capacity -> 0/-1
nj_job_init:
  CMP r1,r0
  JMP[EQ] @nj_ji_bad
  CMP r2,r0
  JMP[EQ] @nj_ji_bad
  MOVI r3,#NJ_J_CAP_MAX
  CMP r2,r3
  JMP[GT] @nj_ji_bad
  LA r3,#NJ_JMAGIC
  ST r3,r1,#NJ_J_MAGIC
  ST r2,r1,#NJ_J_CAP
  ST r0,r1,#NJ_J_COUNT
  MOVI r3,1
  ST r3,r1,#NJ_J_NEXT
  ; zero capacity*8 entry words
  ADDI r4,r1,#NJ_J_ENTRIES
  MOVI r5,#NJ_J_E_SIZE
  MUL r5,r2,r5
nj_ji_z:
  CMP r5,r0
  JMP[EQ] @nj_ji_done
  ST r0,r4,0
  ADD r4,r4,r13
  SUB r5,r5,r13
  JMP @nj_ji_z
nj_ji_done:
  MOVI r1,0
  RET
nj_ji_bad:
  LA r1,0xFFFFFFFF
  RET

; nj_job_start r1=table r2=ctx -> job id or 0
nj_job_start:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  CMP r1,r0
  JMP[EQ] @nj_js_bad
  LD r3,r1,#NJ_J_MAGIC
  LA r4,#NJ_JMAGIC
  CMP r3,r4
  JMP[NE] @nj_js_bad
  MOVI r3,1
  ST r3,r14,3               ; candidate id
nj_js_scan:
  LD r3,r14,3
  LD r4,r14,1
  LD r5,r4,#NJ_J_CAP
  CMP r3,r5
  JMP[GT] @nj_js_bad
  ADD r1,r4,r0
  ADD r2,r3,r0
  CALL @nj_job_entry
  CMP r1,r0
  JMP[EQ] @nj_js_bad
  LD r2,r1,0
  CMP r2,r0
  JMP[EQ] @nj_js_found
  LD r3,r14,3
  ADD r3,r3,r13
  ST r3,r14,3
  JMP @nj_js_scan
nj_js_found:
  ST r1,r14,4               ; entry
  ; spawn outside the table lock (single core, but keep the window short)
  LD r1,r14,2
  CALL @nj_spawn_worker
  CMP r1,r0
  JMP[EQ] @nj_js_bad
  ST r1,r14,5               ; pid
  LD r2,r14,4
  MOVI r3,#NJ_J_RUNNING
  ST r3,r2,#NJ_JE_STATE
  LD r3,r14,5
  ST r3,r2,#NJ_JE_PID
  LD r3,r14,2
  ST r3,r2,#NJ_JE_CTX
  ST r0,r2,#NJ_JE_STATUS
  LD r3,r14,3
  ST r3,r2,#NJ_JE_SEQ
  ; job slot back-reference in the context
  LD r2,r14,2
  LD r3,r14,3
  ST r3,r2,#NJ_C_JOB
  ; count++
  LD r1,r14,1
  LD r2,r1,#NJ_J_COUNT
  ADD r2,r2,r13
  ST r2,r1,#NJ_J_COUNT
  LD r1,r14,3
  JMP @nj_js_out
nj_js_bad:
  MOVI r1,0
nj_js_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nj_job_wait r1=table r2=job -> status, marks WAITED.  Reaps the process.
nj_job_wait:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  CALL @nj_job_entry
  CMP r1,r0
  JMP[EQ] @nj_jw_bad
  ST r1,r14,3
  LD r2,r1,0
  MOVI r3,#NJ_J_RUNNING
  CMP r2,r3
  JMP[NE] @nj_jw_bad
  LD r2,r1,1
  CMP r2,r0
  JMP[EQ] @nj_jw_bad
  ADD r1,r2,r0
  SVC 10
  ST r1,r14,4
  LD r2,r14,3
  LD r3,r14,4
  ST r3,r2,#NJ_JE_STATUS
  MOVI r3,#NJ_J_WAITED
  ST r3,r2,#NJ_JE_STATE
  ; mirror into the worker context
  LD r1,r2,#NJ_JE_CTX
  CMP r1,r0
  JMP[EQ] @nj_jw_ret
  LD r2,r14,4
  ST r2,r1,#NJ_C_RESULT
  MOVI r3,#NJ_ST_FREE
  ST r3,r1,#NJ_C_STATE
  ST r0,r1,#NJ_C_PID
nj_jw_ret:
  LD r1,r14,4
  JMP @nj_jw_out
nj_jw_bad:
  LA r1,0xFFFFFFFF
nj_jw_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nj_job_reap r1=table r2=job -> status, frees the job slot.
nj_job_reap:
  ST r15,r14,0
  ADDI r14,r14,20
  ST r1,r14,1
  ST r2,r14,2
  CALL @nj_job_entry
  CMP r1,r0
  JMP[EQ] @nj_jr_bad
  ST r1,r14,3
  LD r2,r1,0
  MOVI r3,#NJ_J_WAITED
  CMP r2,r3
  JMP[NE] @nj_jr_bad
  LD r2,r1,#NJ_JE_STATUS
  ST r2,r14,4
  MOVI r2,#NJ_J_E_SIZE
nj_jr_z:
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  CMP r2,r0
  JMP[NE] @nj_jr_z
  LD r1,r14,1
  LD r2,r1,#NJ_J_COUNT
  SUB r2,r2,r13
  ST r2,r1,#NJ_J_COUNT
  LD r1,r14,4
  JMP @nj_jr_out
nj_jr_bad:
  LA r1,0xFFFFFFFF
nj_jr_out:
  ADDI r14,r14,-20
  LD r15,r14,0
  RET

; nj_job_state r1=table r2=job -> state or -1
nj_job_state:
  ST r15,r14,0
  ADDI r14,r14,17
  CALL @nj_job_entry
  CMP r1,r0
  JMP[EQ] @nj_jst_bad
  LD r1,r1,0
  JMP @nj_jst_out
nj_jst_bad:
  LA r1,0xFFFFFFFF
nj_jst_out:
  ADDI r14,r14,-17
  LD r15,r14,0
  RET

; nj_job_pid r1=table r2=job -> pid or 0
nj_job_pid:
  ST r15,r14,0
  ADDI r14,r14,17
  CALL @nj_job_entry
  CMP r1,r0
  JMP[EQ] @nj_jp_bad
  LD r1,r1,#NJ_JE_PID
  JMP @nj_jp_out
nj_jp_bad:
  MOVI r1,0
nj_jp_out:
  ADDI r14,r14,-17
  LD r15,r14,0
  RET
