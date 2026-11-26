; nixjobs_shell_test.nas - worker-safe command stages on SVC 9 jobs.
;
; Scenario A (foreground concurrent pipeline):
;   njs_cat  reads a 12288-byte synthetic buffer from its context and writes
;            fd 1, which is a shared 8 KiB ring write end.
;   njs_wc   reads fd 0 (the same ring read end), counts bytes/lines/words,
;            and writes "1024 2048 12288\n" to fd 1, a 256-byte capture ring.
; The producer is started alone and must block after filling the ring before
; the consumer exists.  The consumer records that the producer is partial
; before its first read, then drains it.
;
; Scenario B (background job):
;   njs_sleep is started with 64 ticks.  The parent proves it is running and
;   asleep (entered=1, finished=0, job state RUNNING), does scenario A, then
;   waits/reaps it and checks status 0 and finished=1.
;
; The synthetic buffer is "hello world\n" repeated 1024 times, hence:
;   lines=1024, words=2048, bytes=12288.

.org 0
JMP @njs_boot
.include "../lib/ncc.nas"
.include "../lib/nankernel.nas"
.include "../lib/nansched.nas"
.include "../lib/nixjobs.nas"
.include "../lib/nixjobs_sh.nas"

; Later .equ wins.
.equ NP_BASE      0x40000
.equ NP_VARS      0x69000
.equ NS_BASE      0x58000

.equ CODE_BASE      0
.equ CODE_WORDS     0x20000
.equ BOOTSTACK      0x7F000

.equ ROOT_STACK     0x2A000
.equ ROOT_STACK_WORDS 0x800
.equ ROOT_STACK_TOP 0x2A400

.equ ARENA          0x2C000
.equ ARENA_WORDS    0x2000
.equ PIPE_RING      0x2C000
.equ PIPE_CAP       8192
.equ PIPE_BUF       0x2C040
.equ CAP_RING       0x2C880
.equ CAP_CAP        256
.equ CAP_BUF        0x2C8A0
.equ CAT_CTX        0x2CA00
.equ WC_CTX         0x2CB00
.equ SLP_CTX        0x2CC00
.equ JOBTAB         0x2CD00
.equ RES            0x2CE00

.equ CAT_FD         0x2D000
.equ WC_FD          0x2D080
.equ SLP_FD         0x2D100
.equ WC_BUF         0x2D180
.equ CAP_OUT        0x2D1A0
.equ SYNTH          0x2D200
.equ SYNTH_BYTES    12288
.equ SYNTH_WORDS    0xC00

.equ CAT_STACK      0x2E000
.equ WC_STACK       0x2E800
.equ SLP_STACK      0x2F000
.equ STACK_WORDS    0x400
.equ STACK_POOL     0x2E000
.equ STACK_POOL_WORDS 0x1800

.equ RES_PREBLOCK   0
.equ RES_OVERLAP    1
.equ RES_CATDONE    2
.equ RES_WCBYTES    3
.equ RES_WCLINES    4
.equ RES_WCWORDS    5
.equ RES_WBLK       6
.equ RES_JOB        7
.equ RES_JOBSTATE   8
.equ RES_SLPENTER   9
.equ RES_SLPFIN     10
.equ RES_JOBWAIT    11
.equ RES_JOBPOST    12
.equ RES_SLPSTAT    13
.equ RES_JOBREAP    14
.equ RES_CAPLEN     15

.equ POLL_MAX       400000

; ---------------------------------------------------------------------------
njs_boot:
  MOVI r13,1
  LA r14,#BOOTSTACK
  CALL @nsch_init
  LA r1,@ns_svc
  CALL @nk_install_proc
  MOVI r1,0
  LA r2,@desc_root
  CALL @nsch_spawn_desc
  CMP r1,r0
  JMP[EQ] @njs_boot_fail
  SVC 0
  HALT
njs_boot_fail:
  LA r1,@msg_bootfail
  CALL @ts_puts
  HALT

; ---------------------------------------------------------------------------
ts_puts:
  ST r15,r14,0
  ADDI r14,r14,17
  SHL r1,r1,2
  ADD r2,r1,r0
ts_puts_l:
  LDB r3,r2,0
  CMP r3,r0
  JMP[EQ] @ts_puts_d
  PUTC r3
  ADD r2,r2,r13
  JMP @ts_puts_l
ts_puts_d:
  ADDI r14,r14,-17
  LD r15,r14,0
  RET

ts_hex32:
  ST r15,r14,0
  ADDI r14,r14,17
  ST r1,r14,1
  MOVI r2,8
ts_hex_l:
  LD r1,r14,1
  SHR r3,r1,28
  MOVI r4,15
  BOOL.8 r3,r3,r4
  MOVI r4,10
  CMP r3,r4
  JMP[LT] @ts_hex_dig
  ADDI r3,r3,55
  JMP @ts_hex_put
ts_hex_dig:
  ADDI r3,r3,48
ts_hex_put:
  PUTC r3
  LD r1,r14,1
  SHL r1,r1,4
  ST r1,r14,1
  SUB r2,r2,r13
  CMP r2,r0
  JMP[NE] @ts_hex_l
  ADDI r14,r14,-17
  LD r15,r14,0
  RET

ts_nl:
  ST r15,r14,0
  ADDI r14,r14,9
  MOVI r1,10
  PUTC r1
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
root_entry:
  MOVI r13,1
  LA r14,#ROOT_STACK_TOP
  CALL @njs_root
  SVC 1
  HALT

njs_root:
  ST r15,r14,0
  ADDI r14,r14,32
  LA r1,@msg_begin
  CALL @ts_puts

  ; clear witness block
  LA r2,#RES
  MOVI r3,16
njs_zero:
  ST r0,r2,0
  ADD r2,r2,r13
  SUB r3,r3,r13
  CMP r3,r0
  JMP[NE] @njs_zero

  ; ring setup
  LA r1,#PIPE_RING
  MOVI r2,#PIPE_CAP
  LA r3,#PIPE_BUF
  SHL r3,r3,2
  CALL @nj_ring_init
  CMP r1,r0
  JMP[NE] @njs_fail
  LA r1,#CAP_RING
  MOVI r2,#CAP_CAP
  LA r3,#CAP_BUF
  SHL r3,r3,2
  CALL @nj_ring_init
  CMP r1,r0
  JMP[NE] @njs_fail
  LA r1,@msg_pipe
  CALL @ts_puts
  MOVI r1,#PIPE_CAP
  CALL @ts_hex32
  LA r1,@msg_cap
  CALL @ts_puts
  MOVI r1,#CAP_CAP
  CALL @ts_hex32
  CALL @ts_nl

  ; job table
  LA r1,#JOBTAB
  MOVI r2,8
  CALL @nj_job_init
  CMP r1,r0
  JMP[NE] @njs_fail

  ; synthetic buffer: "hello world\n" * 1024
  LA r4,#SYNTH
  SHL r4,r4,2
  LA r5,@synth_pat
  SHL r5,r5,2
  MOVI r6,1024
njs_fill_rep:
  MOVI r7,12
njs_fill_byte:
  LDB r8,r5,0
  STB r8,r4,0
  ADDI r4,r4,1
  ADDI r5,r5,1
  ADDI r7,r7,-1
  CMP r7,r0
  JMP[NE] @njs_fill_byte
  LA r5,@synth_pat
  SHL r5,r5,2
  ADDI r6,r6,-1
  CMP r6,r0
  JMP[NE] @njs_fill_rep

  ; ---- cat context ------------------------------------------------------
  LA r1,#CAT_CTX
  LA r2,@njs_cat
  LA r3,#CAT_STACK
  MOVI r4,#STACK_WORDS
  MOVI r5,2
  LA r6,#ARENA
  MOVI r7,#ARENA_WORDS
  MOVI r8,#CODE_BASE
  LA r9,#CODE_WORDS
  LA r10,#CAT_FD
  LA r11,#SYNTH
  SHL r11,r11,2
  MOVI r12,#SYNTH_BYTES
  CALL @nj_ctx_init
  CMP r1,r0
  JMP[EQ] @njs_fail
  LA r2,#PIPE_RING
  ST r2,r1,#NJ_C_RING
  LA r2,#RES
  ST r2,r1,#NJ_C_WIT
  LA r1,#CAT_CTX
  MOVI r2,1
  MOVI r3,#NJ_FD_RING
  LA r4,#PIPE_RING
  MOVI r5,1
  CALL @nj_fd_set
  CMP r1,r0
  JMP[NE] @njs_fail

  ; ---- wc context -------------------------------------------------------
  LA r1,#WC_CTX
  LA r2,@njs_wc
  LA r3,#WC_STACK
  MOVI r4,#STACK_WORDS
  MOVI r5,2
  LA r6,#ARENA
  MOVI r7,#ARENA_WORDS
  MOVI r8,#CODE_BASE
  LA r9,#CODE_WORDS
  LA r10,#WC_FD
  LA r11,#WC_BUF
  SHL r11,r11,2
  MOVI r12,128
  CALL @nj_ctx_init
  CMP r1,r0
  JMP[EQ] @njs_fail
  LA r2,#PIPE_RING
  ST r2,r1,#NJ_C_RING
  LA r2,#CAT_CTX
  ST r2,r1,#NJ_C_PEER
  LA r2,#RES
  ST r2,r1,#NJ_C_WIT
  LA r1,#WC_CTX
  MOVI r2,0
  MOVI r3,#NJ_FD_RING
  LA r4,#PIPE_RING
  MOVI r5,0
  CALL @nj_fd_set
  CMP r1,r0
  JMP[NE] @njs_fail
  LA r1,#WC_CTX
  MOVI r2,1
  MOVI r3,#NJ_FD_RING
  LA r4,#CAP_RING
  MOVI r5,1
  CALL @nj_fd_set
  CMP r1,r0
  JMP[NE] @njs_fail

  ; ---- sleep context ----------------------------------------------------
  LA r1,#SLP_CTX
  LA r2,@njs_sleep
  LA r3,#SLP_STACK
  MOVI r4,#STACK_WORDS
  MOVI r5,2
  LA r6,#ARENA
  MOVI r7,#ARENA_WORDS
  MOVI r8,#CODE_BASE
  LA r9,#CODE_WORDS
  LA r10,#SLP_FD
  MOVI r11,0
  MOVI r12,0
  CALL @nj_ctx_init
  CMP r1,r0
  JMP[EQ] @njs_fail
  MOVI r2,64
  ST r2,r1,#NJ_C_TICKS
  LA r2,#RES
  ST r2,r1,#NJ_C_WIT

  ; ---- Scenario B start: background sleep -------------------------------
  LA r1,#JOBTAB
  LA r2,#SLP_CTX
  CALL @nj_job_start
  CMP r1,r0
  JMP[EQ] @njs_fail
  LA r2,#RES
  ST r1,r2,#RES_JOB
  ; Wait until the child has entered njs_sleep (TMP1), but not finished.
  MOVI r6,0
njs_bg_poll:
  LA r2,#SLP_CTX
  LD r3,r2,#NJ_C_TMP1
  CMP r3,r0
  JMP[NE] @njs_bg_entered
  SVC 0
  ADDI r6,r6,1
  LA r7,#POLL_MAX
  CMP r6,r7
  JMP[LT] @njs_bg_poll
  JMP @njs_fail
njs_bg_entered:
  LA r2,#SLP_CTX
  LD r3,r2,#NJ_C_TMP0
  CMP r3,r0
  JMP[NE] @njs_fail
  LA r1,#JOBTAB
  LA r3,#RES
  LD r2,r3,#RES_JOB
  CALL @nj_job_state
  MOVI r4,1
  CMP r1,r4
  JMP[NE] @njs_fail
  LA r2,#RES
  MOVI r3,1
  ST r3,r2,#RES_JOBSTATE
  ST r3,r2,#RES_SLPENTER
  ST r0,r2,#RES_SLPFIN
  LA r1,@msg_brun
  CALL @ts_puts
  MOVI r1,1
  CALL @ts_hex32
  MOVI r1,32
  PUTC r1
  MOVI r1,1
  CALL @ts_hex32
  MOVI r1,32
  PUTC r1
  MOVI r1,0
  CALL @ts_hex32
  CALL @ts_nl

  ; ---- Scenario A: cat alone fills the pipe and blocks ------------------
  LA r1,#CAT_CTX
  CALL @nj_spawn_worker
  CMP r1,r0
  JMP[EQ] @njs_fail
  MOVI r6,0
njs_cat_poll:
  LA r3,#PIPE_RING
  LD r4,r3,#NJ_R_WBLK
  CMP r4,r0
  JMP[NE] @njs_cat_poll_ok
  SVC 0
  ADDI r6,r6,1
  LA r7,#POLL_MAX
  CMP r6,r7
  JMP[LT] @njs_cat_poll
  JMP @njs_fail
njs_cat_poll_ok:
  LA r2,#RES
  MOVI r3,1
  ST r3,r2,#RES_PREBLOCK
  LA r3,#PIPE_RING
  LD r4,r3,#NJ_R_WBLK
  ST r4,r2,#RES_WBLK

  ; ---- Scenario A: consumer starts and drains ---------------------------
  LA r1,#WC_CTX
  CALL @nj_spawn_worker
  CMP r1,r0
  JMP[EQ] @njs_fail
  LA r1,#CAT_CTX
  CALL @nj_ctx_wait
  CMP r1,r0
  JMP[NE] @njs_fail
  LA r1,#WC_CTX
  CALL @nj_ctx_wait
  CMP r1,r0
  JMP[NE] @njs_fail

  ; capture wc output: exact "1024 2048 12288\n"
  LA r1,#CAP_RING
  LA r2,#CAP_OUT
  SHL r2,r2,2
  MOVI r3,64
  CALL @nj_ring_try_read
  MOVI r4,16
  CMP r1,r4
  JMP[NE] @njs_fail
  LA r2,#RES
  ST r1,r2,#RES_CAPLEN
  ; compare bytes
  LA r4,@cap_expected
  SHL r4,r4,2
  LA r5,#CAP_OUT
  SHL r5,r5,2
  MOVI r6,16
njs_cmp:
  LDB r7,r4,0
  LDB r8,r5,0
  CMP r7,r8
  JMP[NE] @njs_fail
  ADD r4,r4,r13
  ADD r5,r5,r13
  SUB r6,r6,r13
  CMP r6,r0
  JMP[NE] @njs_cmp
  ; no extra bytes
  LA r1,#CAP_RING
  LA r2,#CAP_OUT
  SHL r2,r2,2
  MOVI r3,64
  CALL @nj_ring_try_read
  CMP r1,r0
  JMP[NE] @njs_fail
  ; counts and overlap
  LA r2,#RES
  LA r3,#CAT_CTX
  LD r4,r3,#NJ_C_DONE
  ST r4,r2,#RES_CATDONE
  MOVI r5,#SYNTH_BYTES
  CMP r4,r5
  JMP[NE] @njs_fail
  LA r3,#WC_CTX
  LD r4,r3,#NJ_C_TOTAL
  ST r4,r2,#RES_WCBYTES
  CMP r4,r5
  JMP[NE] @njs_fail
  LD r4,r3,#NJ_C_TMP0
  ST r4,r2,#RES_WCLINES
  MOVI r5,1024
  CMP r4,r5
  JMP[NE] @njs_fail
  LD r4,r3,#NJ_C_TMP1
  ST r4,r2,#RES_WCWORDS
  MOVI r5,2048
  CMP r4,r5
  JMP[NE] @njs_fail
  LA r3,#WC_CTX
  LD r4,r3,#NJ_C_TMP3
  ST r4,r2,#RES_OVERLAP
  CMP r4,r13
  JMP[NE] @njs_fail
  LD r4,r2,#RES_PREBLOCK
  CMP r4,r13
  JMP[NE] @njs_fail

  ; ---- Scenario B finish: wait and reap the sleeping job ----------------
  LA r1,#JOBTAB
  LA r3,#RES
  LD r2,r3,#RES_JOB
  CALL @nj_job_wait
  LA r2,#RES
  ST r1,r2,#RES_SLPSTAT
  CMP r1,r0
  JMP[NE] @njs_fail
  LA r1,#JOBTAB
  LA r3,#RES
  LD r2,r3,#RES_JOB
  CALL @nj_job_state
  LA r2,#RES
  ST r1,r2,#RES_JOBWAIT
  MOVI r4,#NJ_J_WAITED
  CMP r1,r4
  JMP[NE] @njs_fail
  LA r2,#SLP_CTX
  LD r3,r2,#NJ_C_TMP0
  ST r3,r2,#NJ_C_DONE
  LA r2,#RES
  ST r3,r2,#RES_SLPFIN
  CMP r3,r13
  JMP[NE] @njs_fail
  LA r1,#JOBTAB
  LA r3,#RES
  LD r2,r3,#RES_JOB
  CALL @nj_job_reap
  LA r2,#RES
  ST r1,r2,#RES_JOBREAP
  CMP r1,r0
  JMP[NE] @njs_fail
  LA r1,#JOBTAB
  LA r3,#RES
  LD r2,r3,#RES_JOB
  CALL @nj_job_state
  LA r2,#RES
  ST r1,r2,#RES_JOBPOST
  CMP r1,r0
  JMP[NE] @njs_fail

  ; ---- transcript -------------------------------------------------------
  LA r1,@msg_preblock
  CALL @ts_puts
  LA r1,@msg_overlap
  CALL @ts_puts
  LA r1,@msg_awc
  CALL @ts_puts
  LA r2,#CAP_OUT
  SHL r2,r2,2
  MOVI r3,16
njs_pr_cap:
  LDB r4,r2,0
  PUTC r4
  ADD r2,r2,r13
  SUB r3,r3,r13
  CMP r3,r0
  JMP[NE] @njs_pr_cap
  LA r1,@msg_abytes
  CALL @ts_puts
  LA r2,#RES
  LD r1,r2,#RES_CATDONE
  CALL @ts_hex32
  CALL @ts_nl
  LA r1,@msg_awblk
  CALL @ts_puts
  LA r1,@msg_bwait
  CALL @ts_puts
  LA r2,#RES
  LD r1,r2,#RES_SLPSTAT
  CALL @ts_hex32
  MOVI r1,32
  PUTC r1
  LA r2,#RES
  LD r1,r2,#RES_JOBWAIT
  CALL @ts_hex32
  CALL @ts_nl
  LA r1,@msg_breap
  CALL @ts_puts
  LA r2,#RES
  LD r1,r2,#RES_JOBREAP
  CALL @ts_hex32
  MOVI r1,32
  PUTC r1
  LA r2,#RES
  LD r1,r2,#RES_JOBPOST
  CALL @ts_hex32
  CALL @ts_nl
  LA r1,@msg_bdone
  CALL @ts_puts
  LA r2,#RES
  LD r1,r2,#RES_SLPFIN
  CALL @ts_hex32
  CALL @ts_nl
  LA r1,@msg_pass
  CALL @ts_puts
  MOVI r1,0
  JMP @njs_root_out
njs_fail:
  LA r1,@msg_fail
  CALL @ts_puts
  MOVI r1,1
njs_root_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
desc_root:
.word @root_entry,#ROOT_STACK_TOP,2,1,4
.word #CODE_BASE,#CODE_WORDS,0,5
.word #ROOT_STACK,#ROOT_STACK_WORDS,0,3
.word #ARENA,#ARENA_WORDS,0,3
.word #STACK_POOL,#STACK_POOL_WORDS,0,3

synth_pat:
.str "hello world\n"
cap_expected:
.str "1024 2048 12288\n"

msg_begin:
.str "NJS BEGIN\n"
msg_pipe:
.str "PIPE "
msg_cap:
.str " CAP "
msg_brun:
.str "B RUN "
msg_preblock:
.str "A PREBLOCK 1\n"
msg_overlap:
.str "A OVERLAP 1\n"
msg_awc:
.str "A WC "
msg_abytes:
.str "A BYTES "
msg_awblk:
.str "A WBLK 1\n"
msg_bwait:
.str "B WAIT "
msg_breap:
.str "B REAP "
msg_bdone:
.str "B DONE "
msg_pass:
.str "NJS PASS\n"
msg_fail:
.str "NJS FAIL\n"
msg_bootfail:
.str "NJS BOOT FAIL\n"
