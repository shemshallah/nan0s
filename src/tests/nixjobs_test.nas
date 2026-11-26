; nixjobs_test.nas - S1 gate for concurrent pipeline + background jobs.
;
; The image is a real nan0s boot: nsch_init installs the S1 scheduler ports,
; nk_install_proc keeps SVC 4..8 on NPAF and routes SVC 9/10/24 to nansched.
; The root process then:
;
;   1. initialises a shared power-of-two byte ring (8 KiB, twice nanpipe);
;   2. gives two worker processes private contexts, stacks and fd tables;
;   3. starts a background job and records its job-table state;
;   4. starts the producer alone and polls until the ring reports a full-write
;      block, proving it cannot finish without a consumer;
;   5. starts the consumer, which first observes that the producer is only
;      partially done (overlap witness), then drains 16 KiB through the ring;
;   6. waits/reaps both foreground workers and the background job.
;
; The expected final stream is bytes (i & 0xFF) for i=0..16383.  The consumer
; verifies every byte and a djb2-style h = h*33 + b hash (seed 5381).
;
; No NFD, nanpipe or NX_* state is used: each worker's descriptors live in its
; own context and the only shared mutable object is the ring/arena.

.org 0
JMP @nj_boot
.include "../lib/ncc.nas"
.include "../lib/nankernel.nas"
.include "../lib/nansched.nas"
.include "../lib/nixjobs.nas"

; Later .equ wins.  The scheduler layout matches src/tests/nansched_test.nas.
.equ NP_BASE      0x40000
.equ NP_VARS      0x69000
.equ NS_BASE      0x58000

.equ CODE_BASE      0
.equ CODE_WORDS     0x20000
.equ BOOTSTACK      0x7F000

.equ ROOT_STACK     0x2A000
.equ ROOT_STACK_WORDS 0x800
.equ ROOT_STACK_TOP 0x2A400

.equ NJ_ARENA       0x2C000
.equ NJ_ARENA_WORDS 0x2000
.equ STACK_POOL     0x2E000
.equ STACK_POOL_WORDS 0x1800
.equ NJ_RING        0x2C000
.equ NJ_RING_CAP    8192
.equ NJ_RING_BUF    0x2C040
.equ PROD_CTX       0x2C900
.equ CONS_CTX       0x2CA00
.equ BG_CTX         0x2CB00
.equ JOBTAB         0x2CC00
.equ RES            0x2CD00
.equ PROD_FD        0x2D000
.equ CONS_FD        0x2D080
.equ BG_FD          0x2D100
.equ PROD_SCR       0x2D200
.equ CONS_SCR       0x2D300
.equ BG_SCR         0x2D400

.equ PROD_STACK     0x2E000
.equ CONS_STACK     0x2E800
.equ BG_STACK       0x2F000
.equ STACK_WORDS    0x400
.equ PROD_STACK_TOP 0x2E200
.equ CONS_STACK_TOP 0x2EA00
.equ BG_STACK_TOP   0x2F200

.equ STREAM_TOTAL   16384
.equ POLL_MAX       400000

; Result/witness block.  Shared by root and the consumer.
.equ RES_PREBLOCK   0
.equ RES_OVERLAP    1
.equ RES_BGMARK     2
.equ RES_BGJOB      3
.equ RES_PROD       4
.equ RES_CONS       5
.equ RES_HASH       6
.equ RES_WBLK       7
.equ RES_RBLK       8
.equ RES_PIDP       9
.equ RES_PIDC       10
.equ RES_JOB_PRE    11
.equ RES_JOB_WAIT   12
.equ RES_JOB_POST   13
.equ RES_BGSTAT     14
.equ RES_BGREAP     15

; ---------------------------------------------------------------------------
nj_boot:
  MOVI r13,1
  LA r14,#BOOTSTACK
  CALL @nsch_init
  LA r1,@ns_svc
  CALL @nk_install_proc
  MOVI r1,0
  LA r2,@desc_root
  CALL @nsch_spawn_desc
  CMP r1,r0
  JMP[EQ] @nj_boot_fail
  SVC 0
  HALT
nj_boot_fail:
  LA r1,@msg_bootfail
  CALL @tj_puts
  HALT

; ---------------------------------------------------------------------------
; Serial helpers.
tj_puts:
  ST r15,r14,0
  ADDI r14,r14,17
  SHL r1,r1,2
  ADD r2,r1,r0
tj_puts_l:
  LDB r3,r2,0
  CMP r3,r0
  JMP[EQ] @tj_puts_d
  PUTC r3
  ADD r2,r2,r13
  JMP @tj_puts_l
tj_puts_d:
  ADDI r14,r14,-17
  LD r15,r14,0
  RET

tj_hex32:
  ST r15,r14,0
  ADDI r14,r14,17
  ST r1,r14,1
  MOVI r2,8
tj_hex_l:
  LD r1,r14,1
  SHR r3,r1,28
  MOVI r4,15
  BOOL.8 r3,r3,r4
  MOVI r4,10
  CMP r3,r4
  JMP[LT] @tj_hex_dig
  ADDI r3,r3,55
  JMP @tj_hex_put
tj_hex_dig:
  ADDI r3,r3,48
tj_hex_put:
  PUTC r3
  LD r1,r14,1
  SHL r1,r1,4
  ST r1,r14,1
  SUB r2,r2,r13
  CMP r2,r0
  JMP[NE] @tj_hex_l
  ADDI r14,r14,-17
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
root_entry:
  MOVI r13,1
  LA r14,#ROOT_STACK_TOP
  CALL @nj_root
  SVC 1
  HALT

; nj_root returns 0 on pass, 1 on failure.
nj_root:
  ST r15,r14,0
  ADDI r14,r14,24
  LA r1,@msg_begin
  CALL @tj_puts

  ; Clear the shared result block.
  LA r2,#RES
  MOVI r3,16
nj_root_zero:
  ST r0,r2,0
  ADD r2,r2,r13
  SUB r3,r3,r13
  CMP r3,r0
  JMP[NE] @nj_root_zero

  ; ring: 8 KiB, power of two, greater than nanpipe's 4 KiB
  LA r1,#NJ_RING
  MOVI r2,#NJ_RING_CAP
  LA r3,#NJ_RING_BUF
  SHL r3,r3,2
  CALL @nj_ring_init
  CMP r1,r0
  JMP[NE] @nj_root_fail
  LA r1,@msg_ring
  CALL @tj_puts
  MOVI r1,#NJ_RING_CAP
  CALL @tj_hex32
  CALL @tj_nl

  ; job table: 8 slots
  LA r1,#JOBTAB
  MOVI r2,8
  CALL @nj_job_init
  CMP r1,r0
  JMP[NE] @nj_root_fail

  ; ---- producer context -------------------------------------------------
  LA r1,#PROD_CTX
  LA r2,@nj_prod_stage
  LA r3,#PROD_STACK
  MOVI r4,#STACK_WORDS
  MOVI r5,2
  LA r6,#NJ_ARENA
  MOVI r7,#NJ_ARENA_WORDS
  MOVI r8,#CODE_BASE
  LA r9,#CODE_WORDS
  LA r10,#PROD_FD
  LA r11,#PROD_SCR
  SHL r11,r11,2
  MOVI r12,256
  CALL @nj_ctx_init
  CMP r1,r0
  JMP[EQ] @nj_root_fail
  LA r2,#NJ_RING
  ST r2,r1,#NJ_C_RING
  MOVI r2,#STREAM_TOTAL
  ST r2,r1,#NJ_C_TOTAL
  LA r2,#RES
  ST r2,r1,#NJ_C_WIT

  ; ---- consumer context -------------------------------------------------
  LA r1,#CONS_CTX
  LA r2,@nj_cons_stage
  LA r3,#CONS_STACK
  MOVI r4,#STACK_WORDS
  MOVI r5,2
  LA r6,#NJ_ARENA
  MOVI r7,#NJ_ARENA_WORDS
  MOVI r8,#CODE_BASE
  LA r9,#CODE_WORDS
  LA r10,#CONS_FD
  LA r11,#CONS_SCR
  SHL r11,r11,2
  MOVI r12,256
  CALL @nj_ctx_init
  CMP r1,r0
  JMP[EQ] @nj_root_fail
  LA r2,#NJ_RING
  ST r2,r1,#NJ_C_RING
  MOVI r2,#STREAM_TOTAL
  ST r2,r1,#NJ_C_TOTAL
  LA r2,#PROD_CTX
  ST r2,r1,#NJ_C_PEER
  LA r2,#RES
  ST r2,r1,#NJ_C_WIT

  ; ---- background context ----------------------------------------------
  LA r1,#BG_CTX
  LA r2,@nj_bg_stage
  LA r3,#BG_STACK
  MOVI r4,#STACK_WORDS
  MOVI r5,2
  LA r6,#NJ_ARENA
  MOVI r7,#NJ_ARENA_WORDS
  MOVI r8,#CODE_BASE
  LA r9,#CODE_WORDS
  LA r10,#BG_FD
  LA r11,#BG_SCR
  SHL r11,r11,2
  MOVI r12,256
  CALL @nj_ctx_init
  CMP r1,r0
  JMP[EQ] @nj_root_fail
  LA r2,#RES
  ST r2,r1,#NJ_C_WIT

  ; ---- per-worker fd tables are independent -----------------------------
  LA r1,#PROD_CTX
  MOVI r2,1
  MOVI r3,#NJ_FD_RING
  LA r4,#NJ_RING
  MOVI r5,1
  CALL @nj_fd_set
  CMP r1,r0
  JMP[NE] @nj_root_fail
  LA r1,#CONS_CTX
  MOVI r2,0
  MOVI r3,#NJ_FD_RING
  LA r4,#NJ_RING
  MOVI r5,0
  CALL @nj_fd_set
  CMP r1,r0
  JMP[NE] @nj_root_fail

  ; producer fd 1: used ring write; fd 0 unused
  LA r2,#PROD_FD
  LD r3,r2,0
  CMP r3,r0
  JMP[NE] @nj_root_fail
  LD r3,r2,5
  CMP r3,r0
  JMP[EQ] @nj_root_fail
  LD r3,r2,6
  MOVI r4,#NJ_FD_RING
  CMP r3,r4
  JMP[NE] @nj_root_fail
  LD r3,r2,8
  CMP r3,r13
  JMP[NE] @nj_root_fail
  ; consumer fd 0: used ring read; fd 1 unused
  LA r2,#CONS_FD
  LD r3,r2,0
  CMP r3,r0
  JMP[EQ] @nj_root_fail
  LD r3,r2,1
  MOVI r4,#NJ_FD_RING
  CMP r3,r4
  JMP[NE] @nj_root_fail
  LD r3,r2,3
  CMP r3,r0
  JMP[NE] @nj_root_fail
  LD r3,r2,5
  CMP r3,r0
  JMP[NE] @nj_root_fail
  LA r1,@msg_fds
  CALL @tj_puts

  ; ---- start a background job before the foreground pipeline ------------
  LA r1,#JOBTAB
  LA r2,#BG_CTX
  CALL @nj_job_start
  CMP r1,r0
  JMP[EQ] @nj_root_fail
  LA r2,#RES
  ST r1,r2,#RES_BGJOB
  LA r1,@msg_bgstart
  CALL @tj_puts
  LA r2,#RES
  LD r1,r2,#RES_BGJOB
  CALL @tj_hex32
  CALL @tj_nl

  ; ---- producer alone: it must fill the ring and block ------------------
  LA r1,#PROD_CTX
  CALL @nj_spawn_worker
  CMP r1,r0
  JMP[EQ] @nj_root_fail
  LA r2,#RES
  ST r1,r2,#RES_PIDP
  MOVI r6,0
nj_root_poll:
  LA r3,#NJ_RING
  LD r4,r3,#NJ_R_WBLK
  CMP r4,r0
  JMP[NE] @nj_root_poll_ok
  SVC 0
  ADDI r6,r6,1
  LA r7,#POLL_MAX
  CMP r6,r7
  JMP[LT] @nj_root_poll
  JMP @nj_root_fail
nj_root_poll_ok:
  LA r2,#RES
  MOVI r3,1
  ST r3,r2,#RES_PREBLOCK
  LA r3,#NJ_RING
  LD r4,r3,#NJ_R_WBLK
  ST r4,r2,#RES_WBLK

  ; ---- consumer: overlaps the already-blocked producer -------------------
  LA r1,#CONS_CTX
  CALL @nj_spawn_worker
  CMP r1,r0
  JMP[EQ] @nj_root_fail
  LA r2,#RES
  ST r1,r2,#RES_PIDC

  ; Wait for both foreground workers (the producer completes only because
  ; the consumer drains the ring).
  LA r1,#PROD_CTX
  CALL @nj_ctx_wait
  CMP r1,r0
  JMP[NE] @nj_root_fail
  LA r2,#RES
  ST r1,r2,#RES_PROD
  LA r1,#CONS_CTX
  CALL @nj_ctx_wait
  CMP r1,r0
  JMP[NE] @nj_root_fail
  LA r2,#RES
  ST r1,r2,#RES_CONS

  ; ---- wait and reap the background job ---------------------------------
  LA r1,#JOBTAB
  LA r2,#RES
  LD r2,r2,#RES_BGJOB
  CALL @nj_job_state
  LA r2,#RES
  ST r1,r2,#RES_JOB_PRE
  ; reload the job id (the previous call clobbered r1/r2)
  LA r1,#JOBTAB
  LA r3,#RES
  LD r2,r3,#RES_BGJOB
  CALL @nj_job_wait
  LA r2,#RES
  ST r1,r2,#RES_BGSTAT
  LA r1,#JOBTAB
  LA r3,#RES
  LD r2,r3,#RES_BGJOB
  CALL @nj_job_state
  LA r2,#RES
  ST r1,r2,#RES_JOB_WAIT
  LA r1,#JOBTAB
  LA r3,#RES
  LD r2,r3,#RES_BGJOB
  CALL @nj_job_reap
  LA r2,#RES
  ST r1,r2,#RES_BGREAP
  LA r1,#JOBTAB
  LA r3,#RES
  LD r2,r3,#RES_BGJOB
  CALL @nj_job_state
  LA r2,#RES
  ST r1,r2,#RES_JOB_POST

  ; ---- validation -------------------------------------------------------
  ; ring drained exactly
  LA r2,#RES
  LA r3,#NJ_RING
  LD r4,r3,#NJ_R_TAIL
  MOVI r5,#STREAM_TOTAL
  CMP r4,r5
  JMP[NE] @nj_root_fail
  LD r4,r3,#NJ_R_HEAD
  CMP r4,r5
  JMP[NE] @nj_root_fail
  ; producer/consumer completion and hash
  LA r3,#PROD_CTX
  LD r4,r3,#NJ_C_DONE
  CMP r4,r5
  JMP[NE] @nj_root_fail
  LA r3,#CONS_CTX
  LD r4,r3,#NJ_C_DONE
  CMP r4,r5
  JMP[NE] @nj_root_fail
  LD r6,r3,#NJ_C_HASH
  LA r7,0xF8DFF505
  CMP r6,r7
  JMP[NE] @nj_root_fail
  ST r6,r2,#RES_HASH
  ; overlap witness: producer was partial when the consumer first ran
  LD r4,r2,#RES_OVERLAP
  CMP r4,r13
  JMP[NE] @nj_root_fail
  ; producer blocked before the consumer existed
  LD r4,r2,#RES_PREBLOCK
  CMP r4,r13
  JMP[NE] @nj_root_fail
  ; background job lifecycle and marker
  LD r4,r2,#RES_BGMARK
  CMP r4,r13
  JMP[NE] @nj_root_fail
  LD r4,r2,#RES_JOB_PRE
  MOVI r5,#NJ_J_RUNNING
  CMP r4,r5
  JMP[NE] @nj_root_fail
  LD r4,r2,#RES_BGSTAT
  MOVI r5,42
  CMP r4,r5
  JMP[NE] @nj_root_fail
  LD r4,r2,#RES_JOB_WAIT
  MOVI r5,#NJ_J_WAITED
  CMP r4,r5
  JMP[NE] @nj_root_fail
  LD r4,r2,#RES_BGREAP
  MOVI r5,42
  CMP r4,r5
  JMP[NE] @nj_root_fail
  LD r4,r2,#RES_JOB_POST
  CMP r4,r0
  JMP[NE] @nj_root_fail

  ; ---- transcript -------------------------------------------------------
  LA r1,@msg_preblock
  CALL @tj_puts
  LA r1,@msg_pipe
  CALL @tj_puts
  MOVI r1,#STREAM_TOTAL
  CALL @tj_hex32
  MOVI r1,32
  PUTC r1
  LA r3,#RES
  LD r1,r3,#RES_HASH
  CALL @tj_hex32
  CALL @tj_nl
  LA r1,@msg_overlap
  CALL @tj_puts
  LA r1,@msg_wblk
  CALL @tj_puts
  LA r1,@msg_bgwait
  CALL @tj_puts
  LA r2,#RES
  LD r1,r2,#RES_BGSTAT
  CALL @tj_hex32
  MOVI r1,32
  PUTC r1
  LA r2,#RES
  LD r1,r2,#RES_JOB_WAIT
  CALL @tj_hex32
  CALL @tj_nl
  LA r1,@msg_bgreap
  CALL @tj_puts
  LA r2,#RES
  LD r1,r2,#RES_BGREAP
  CALL @tj_hex32
  MOVI r1,32
  PUTC r1
  LA r2,#RES
  LD r1,r2,#RES_JOB_POST
  CALL @tj_hex32
  CALL @tj_nl
  LA r1,@msg_pass
  CALL @tj_puts
  MOVI r1,0
  JMP @nj_root_out
nj_root_fail:
  LA r1,@msg_fail
  CALL @tj_puts
  MOVI r1,1
nj_root_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

tj_nl:
  ST r15,r14,0
  ADDI r14,r14,9
  MOVI r1,10
  PUTC r1
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; Producer stage.  r12 = context.  Writes STREAM_TOTAL bytes of
; (offset & 0xFF) through fd 1, which is the ring write end.
nj_prod_stage:
  ST r15,r14,0
  ADDI r14,r14,24
  LD r1,r12,#NJ_C_TOTAL
  ST r1,r14,1
  ST r0,r14,2
  LD r1,r12,#NJ_C_SCRATCH
  ST r1,r14,3
nj_prod_loop:
  LD r1,r14,1
  LD r2,r14,2
  CMP r1,r2
  JMP[LE] @nj_prod_done
  SUB r1,r1,r2
  MOVI r3,64
  CMP r1,r3
  JMP[LE] @nj_prod_n
  ADD r1,r3,r0
nj_prod_n:
  ST r1,r14,6               ; n
  ST r0,r14,7               ; j
nj_prod_fill:
  LD r1,r14,7
  LD r2,r14,6
  CMP r1,r2
  JMP[GE] @nj_prod_fill_done
  LD r3,r14,2
  ADD r3,r3,r1
  MOVI r4,255
  BOOL.8 r3,r3,r4
  LD r5,r14,3
  ADD r5,r5,r1
  STB r3,r5,0
  ADDI r1,r1,1
  ST r1,r14,7
  JMP @nj_prod_fill
nj_prod_fill_done:
  ADD r1,r12,r0
  MOVI r2,1
  LD r3,r14,3
  LD r4,r14,6
  CALL @nj_fd_write
  CMP r1,r0
  JMP[LT] @nj_prod_bad
  LD r2,r14,2
  ADD r2,r2,r1
  ST r2,r14,2
  LD r2,r12,#NJ_C_DONE
  ADD r2,r2,r1
  ST r2,r12,#NJ_C_DONE
  JMP @nj_prod_loop
nj_prod_done:
  ADD r1,r12,r0
  MOVI r2,1
  CALL @nj_fd_close
  MOVI r1,0
  JMP @nj_prod_out
nj_prod_bad:
  MOVI r1,1
nj_prod_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; Consumer stage.  r12 = context.  Records the producer's partial progress
; before the first read (overlap witness), then validates bytes and hash.
nj_cons_stage:
  ST r15,r14,0
  ADDI r14,r14,32
  LD r1,r12,#NJ_C_TOTAL
  ST r1,r14,1               ; total
  ST r0,r14,2               ; count
  MOVI r1,5381
  ST r1,r14,3               ; hash
  LD r1,r12,#NJ_C_SCRATCH
  ST r1,r14,4               ; scratch
  ; Overlap witness: producer done > 0 and < total before first read.
  LD r1,r12,#NJ_C_PEER
  CMP r1,r0
  JMP[EQ] @nj_cons_read
  LD r2,r1,#NJ_C_DONE
  CMP r2,r0
  JMP[EQ] @nj_cons_read
  LD r3,r14,1
  CMP r2,r3
  JMP[GE] @nj_cons_read
  LD r4,r12,#NJ_C_WIT
  CMP r4,r0
  JMP[EQ] @nj_cons_read
  MOVI r5,1
  ST r5,r4,#RES_OVERLAP
nj_cons_read:
  ADD r1,r12,r0
  MOVI r2,0
  LD r3,r14,4
  MOVI r4,128
  CALL @nj_fd_read
  CMP r1,r0
  JMP[EQ] @nj_cons_done
  CMP r1,r0
  JMP[LT] @nj_cons_bad
  ST r1,r14,6               ; n
  ST r0,r14,7               ; index
nj_cons_byte:
  LD r1,r14,7
  LD r2,r14,6
  CMP r1,r2
  JMP[GE] @nj_cons_read
  LD r3,r14,4
  ADD r3,r3,r1
  LDB r4,r3,0
  LD r5,r14,2
  MOVI r6,255
  BOOL.8 r5,r5,r6
  CMP r4,r5
  JMP[NE] @nj_cons_bad
  LD r5,r14,3
  SHL r6,r5,5
  ADD r5,r5,r6
  ADD r5,r5,r4
  ST r5,r14,3
  LD r5,r14,2
  ADD r5,r5,r13
  ST r5,r14,2
  LD r5,r14,7
  ADD r5,r5,r13
  ST r5,r14,7
  JMP @nj_cons_byte
nj_cons_done:
  LD r1,r14,2
  ST r1,r12,#NJ_C_DONE
  LD r1,r14,3
  ST r1,r12,#NJ_C_HASH
  ADD r1,r12,r0
  MOVI r2,0
  CALL @nj_fd_close
  LD r1,r14,2
  LD r2,r14,1
  CMP r1,r2
  JMP[NE] @nj_cons_bad
  LD r1,r14,3
  LA r2,0xF8DFF505
  CMP r1,r2
  JMP[NE] @nj_cons_bad
  MOVI r1,0
  JMP @nj_cons_out
nj_cons_bad:
  MOVI r1,1
nj_cons_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; Background stage: sleeps two ticks, sets the shared marker, exits 42.
nj_bg_stage:
  ST r15,r14,0
  ADDI r14,r14,17
  MOVI r1,2
  SVC 24
  LD r1,r12,#NJ_C_WIT
  CMP r1,r0
  JMP[EQ] @nj_bg_done
  MOVI r2,1
  ST r2,r1,#RES_BGMARK
nj_bg_done:
  MOVI r1,42
  ADDI r14,r14,-17
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; Spawn descriptors.  The root gets code, its private stack, and the shared
; arena.  Workers are built inside their contexts by nj_spawn_worker.
desc_root:
.word @root_entry,#ROOT_STACK_TOP,2,1,4
.word #CODE_BASE,#CODE_WORDS,0,5
.word #ROOT_STACK,#ROOT_STACK_WORDS,0,3
.word #NJ_ARENA,#NJ_ARENA_WORDS,0,3
.word #STACK_POOL,#STACK_POOL_WORDS,0,3

; ---------------------------------------------------------------------------
msg_begin:
.str "NJ BEGIN\n"
msg_ring:
.str "RING "
msg_fds:
.str "FDS OK\n"
msg_bgstart:
.str "BG START "
msg_preblock:
.str "PREBLOCK 1\n"
msg_pipe:
.str "PIPE "
msg_overlap:
.str "OVERLAP 1\n"
msg_wblk:
.str "WBLK 1\n"
msg_bgwait:
.str "BG WAIT "
msg_bgreap:
.str "BG REAP "
msg_pass:
.str "NJ PASS\n"
msg_fail:
.str "NJ FAIL\n"
msg_bootfail:
.str "NJ BOOT FAIL\n"
