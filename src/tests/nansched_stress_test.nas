; nansched_stress_test.nas - 512-process + thread stress image.
;
; Uses the real nan0s kernel: nankernel owns SVC 4..8, nansched owns the
; process SVCs and the appended priority/count calls, and nansched's kentry
; wrapper routes SVC 13..19 to the nanthr cooperative thread path.
;
; Phase 1: root spawns 512 children (priorities 1..3), kills every seventh
; pid, waits all 512 and checks the status sum.
; Phase 2: the root creates four cooperative threads which contend on a
; mutex, increment a shared counter, broadcast a condition, exit and join.
;
; Quiet processes; the transcript is aggregate and deterministic.
;
; Memory map (word addresses):
;   0..0x1FFFF  image / code region
;   0x40000     nanproc table, 1024*96 (ends 0x58000)
;   0x58000     NS_BASE scheduler state (ends 0x68070)
;   0x69000     NP_VARS
;   0x70000     root data (0x2000 words)
;   0x7F000     boot stack
;   0x80000     child stacks, 512 * 0x40 (ends 0x88000)
;   0x88000     root stack (0x1000)
;   0x89000     thread stacks, 4 * 0x400 (0x2000)
;   0xA0000     nanthr TCB arena (kernel-only)
;   0xA4000     nanthr stack arena (kernel-only)
;   0x2F0000    nankernel stack / 0x2F1000 frame / 0x2F2000 hook

.org 0
JMP @stress_boot
.include "../lib/ncc.nas"
.include "../lib/nankernel.nas"
.include "../lib/nansched.nas"

; overrides (later .equ wins in nmk)
.equ NP_BASE      0x40000
.equ NP_VARS      0x69000
.equ NS_BASE      0x58000
.equ NP_MAX_PROCS 1024

.equ P_DATA       0x70000
.equ P_STACK      0x88000
.equ P_STACK_TOP  0x88400
.equ BOOTSTACK    0x7F000
.equ CHILD_STACK  0x80000
.equ CHILD_STRIDE 0x40
.equ T_STACK      0x89000
.equ T_STRIDE     0x400

.equ D_PIDS       0x0000
.equ D_DESC       0x1000
.equ D_CTR        0x1100
.equ D_DONE       0x1101
.equ D_MUTEX      0x1110
.equ D_COND       0x1120
.equ D_TIDS       0x1130
.equ D_JSUM       0x1140
.equ D_SUM        0x1141
.equ D_EXP        0x1142

.equ NPROC        512
.equ CODE_WORDS   0x20000

; ---------------------------------------------------------------------------
stress_boot:
  MOVI r13,1
  LA r14,#BOOTSTACK
  CALL @nsch_init
  LA r1,@ns_svc
  CALL @nk_install_proc
  MOVI r1,0
  LA r2,@desc_root
  CALL @nsch_spawn_desc
  CMP r1,r0
  JMP[EQ] @boot_fail
  SVC 0
  HALT
boot_fail:
  LA r1,@msg_bootfail
  CALL @sputs
  HALT

; ---------------------------------------------------------------------------
; sputs: r1 = word address of NUL-terminated bytes.
sputs:
  ST r15,r14,0
  ADDI r14,r14,9
  SHL r1,r1,2
  ADD r5,r1,r0
sputs_l:
  LDB r2,r5,0
  CMP r2,r0
  JMP[EQ] @sputs_d
  PUTC r2
  ADDI r5,r5,1
  JMP @sputs_l
sputs_d:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; sput_dec: r1 = 0..999999, no leading zeroes. Leaf.
sput_dec:
  ADD r6,r1,r0
  LA r2,100000
  MOVI r5,0
  MOVI r7,10
  MOVI r8,6
sput_d_l:
  DIVU r3,r6,r2
  CMP r3,r0
  JMP[NE] @sput_d_pr
  CMP r5,r0
  JMP[NE] @sput_d_pr
  MOVI r4,1
  CMP r2,r4
  JMP[NE] @sput_d_skip
sput_d_pr:
  MOVI r5,1
  ADDI r3,r3,48
  PUTC r3
  ; r6 -= digit * r2
  DIVU r4,r6,r2
  MUL r4,r4,r2
  SUB r6,r6,r4
sput_d_skip:
  DIVU r2,r2,r7
  SUB r8,r8,r13
  CMP r8,r0
  JMP[NE] @sput_d_l
  RET

; ---------------------------------------------------------------------------
; root process
stress_root:
  MOVI r13,1
  LA r14,#P_STACK_TOP
  LA r12,#P_DATA
  LA r1,@msg_begin
  CALL @sputs

  ; ---- spawn NPROC children ----
  MOVI r6,0
spawn_loop:
  MOVI r2,#NPROC
  CMP r6,r2
  JMP[GE] @spawn_done
  ADDI r1,r12,#D_DESC
  LA r3,#CHILD_STACK
  MOVI r4,#CHILD_STRIDE
  MUL r5,r6,r4
  ADD r3,r3,r5
  ADDI r3,r3,0x20
  ; descriptor: entry, sp, prio, name, nreg, code region, stack region
  LA r5,@stress_child
  ST r5,r1,0
  ST r3,r1,1
  MOVI r5,3
  MODU r5,r6,r5
  ADD r5,r5,r13
  ST r5,r1,2
  ST r6,r1,3
  MOVI r5,2
  ST r5,r1,4
  ST r0,r1,5
  LA r5,#CODE_WORDS
  ST r5,r1,6
  ST r0,r1,7
  MOVI r5,5
  ST r5,r1,8
  ; stack base = CHILD_STACK + i*CHILD_STRIDE
  LA r3,#CHILD_STACK
  MOVI r4,#CHILD_STRIDE
  MUL r5,r6,r4
  ADD r3,r3,r5
  ST r3,r1,9
  MOVI r5,#CHILD_STRIDE
  ST r5,r1,10
  ST r0,r1,11
  MOVI r5,3
  ST r5,r1,12
  SVC 9
  CMP r1,r0
  JMP[EQ] @stress_fail
  ADD r2,r12,r6
  ST r1,r2,0
  ADD r6,r6,r13
  JMP @spawn_loop
spawn_done:
  LA r1,@msg_spawn
  CALL @sputs
  MOVI r1,#NPROC
  CALL @sput_dec
  MOVI r1,10
  PUTC r1

  ; ---- kill every seventh pid ----
  MOVI r6,0
  MOVI r7,0
kill_loop:
  MOVI r2,#NPROC
  CMP r6,r2
  JMP[GE] @kill_done
  ADD r3,r12,r6
  LD r1,r3,0
  MOVI r2,7
  MODU r3,r1,r2
  CMP r3,r0
  JMP[NE] @kill_next
  MOVI r2,15
  SVC 22
  ADD r7,r7,r13
kill_next:
  ADD r6,r6,r13
  JMP @kill_loop
kill_done:
  LA r1,@msg_kill
  CALL @sputs
  ADD r1,r7,r0
  CALL @sput_dec
  MOVI r1,10
  PUTC r1

  ; ---- wait all and sum statuses (children are most-recent-first, so wait
  ; in reverse spawn order: every wait finds the head of the child list) ----
  MOVI r6,#NPROC
  MOVI r9,#NPROC
  SUB r9,r9,r13
  MOVI r7,0
  MOVI r8,0
wait_loop:
  CMP r6,r0
  JMP[EQ] @wait_done
  ADD r3,r12,r9
  LD r1,r3,0
  ADD r10,r1,r0
  SVC 10
  ADD r7,r7,r1
  ; expected: killed pids are 128+15, others pid%100
  MOVI r2,7
  MODU r3,r10,r2
  CMP r3,r0
  JMP[NE] @wait_norm
  MOVI r3,143
  JMP @wait_add
wait_norm:
  MOVI r2,100
  MODU r3,r10,r2
wait_add:
  ADD r8,r8,r3
  SUB r6,r6,r13
  SUB r9,r9,r13
  JMP @wait_loop
wait_done:
  ST r7,r12,#D_SUM
  ST r8,r12,#D_EXP
  LA r1,@msg_wait
  CALL @sputs
  MOVI r1,#NPROC
  CALL @sput_dec
  MOVI r1,10
  PUTC r1
  LA r1,@msg_sum
  CALL @sputs
  LD r1,r12,#D_SUM
  CALL @sput_dec
  MOVI r1,10
  PUTC r1
  LD r7,r12,#D_SUM
  LD r8,r12,#D_EXP
  CMP r7,r8
  JMP[NE] @stress_fail
  LA r1,@msg_statusok
  CALL @sputs

  ; ---- process count / limit ----
  SVC 27
  ADD r9,r1,r0
  SVC 28
  ADD r10,r1,r0
  LA r1,@msg_count
  CALL @sputs
  ADD r1,r9,r0
  CALL @sput_dec
  LA r1,@msg_limit
  CALL @sputs
  ADD r1,r10,r0
  CALL @sput_dec
  MOVI r1,10
  PUTC r1
  MOVI r2,1
  CMP r9,r2
  JMP[NE] @stress_fail
  MOVI r2,1024
  CMP r10,r2
  JMP[NE] @stress_fail

  ; ---- setpriority/getpriority ----
  MOVI r1,1
  MOVI r2,2
  SVC 25
  CMP r1,r0
  JMP[NE] @stress_fail
  MOVI r1,1
  SVC 26
  MOVI r2,2
  CMP r1,r2
  JMP[NE] @stress_fail
  LA r1,@msg_prio
  CALL @sputs
  MOVI r1,2
  CALL @sput_dec
  MOVI r1,10
  PUTC r1
  MOVI r1,1
  MOVI r2,0
  SVC 25

  ; ---- threads ----
  ST r0,r12,#D_CTR
  ST r0,r12,#D_DONE
  ST r0,r12,#D_JSUM
  ; mutex init (op 3), cond init (op 3)
  MOVI r1,3
  ADDI r2,r12,#D_MUTEX
  SVC 16
  MOVI r1,3
  ADDI r2,r12,#D_COND
  SVC 17
  ; main owns the mutex while creating workers
  MOVI r1,0
  ADDI r2,r12,#D_MUTEX
  SVC 16
  MOVI r6,0
thr_create:
  MOVI r2,4
  CMP r6,r2
  JMP[GE] @thr_created
  LA r1,@stress_worker
  LA r3,#T_STACK
  MOVI r4,#T_STRIDE
  MUL r5,r6,r4
  ADD r3,r3,r5
  ADDI r3,r3,0x300
  ADD r2,r3,r0
  ADD r3,r6,r0
  SVC 13
  CMP r1,r0
  JMP[EQ] @stress_fail
  ADDI r2,r12,#D_TIDS
  ADD r2,r2,r6
  ST r1,r2,0
  ADD r6,r6,r13
  JMP @thr_create
thr_created:
  ; wait for done==4 using cond_wait while owning the mutex
thr_wait:
  LD r1,r12,#D_DONE
  MOVI r2,4
  CMP r1,r2
  JMP[GE] @thr_join
  MOVI r1,0
  ADDI r2,r12,#D_COND
  ADDI r3,r12,#D_MUTEX
  SVC 17
  JMP @thr_wait
thr_join:
  MOVI r1,1
  ADDI r2,r12,#D_MUTEX
  SVC 16
  MOVI r6,0
  MOVI r7,0
thr_join_l:
  MOVI r2,4
  CMP r6,r2
  JMP[GE] @thr_report
  ADDI r2,r12,#D_TIDS
  ADD r2,r2,r6
  LD r1,r2,0
  SVC 14
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @stress_fail
  ADD r7,r7,r1
  ADD r6,r6,r13
  JMP @thr_join_l
thr_report:
  ST r7,r12,#D_JSUM
  LA r1,@msg_threads
  CALL @sputs
  MOVI r1,4
  CALL @sput_dec
  MOVI r1,10
  PUTC r1
  LA r1,@msg_mutex
  CALL @sputs
  LD r1,r12,#D_CTR
  CALL @sput_dec
  MOVI r1,10
  PUTC r1
  LA r1,@msg_cond
  CALL @sputs
  LD r1,r12,#D_DONE
  CALL @sput_dec
  MOVI r1,10
  PUTC r1
  LA r1,@msg_join
  CALL @sputs
  LD r1,r12,#D_JSUM
  CALL @sput_dec
  MOVI r1,10
  PUTC r1
  ; verify
  LD r1,r12,#D_CTR
  MOVI r2,200
  CMP r1,r2
  JMP[NE] @stress_fail
  LD r1,r12,#D_DONE
  MOVI r2,4
  CMP r1,r2
  JMP[NE] @stress_fail
  LD r7,r12,#D_JSUM
  MOVI r2,2806
  CMP r7,r2
  JMP[NE] @stress_fail
  LA r1,@msg_pass
  CALL @sputs
  MOVI r1,0
  SVC 1
  HALT

stress_fail:
  LA r1,@msg_fail
  CALL @sputs
  MOVI r1,1
  SVC 1
  HALT

; ---------------------------------------------------------------------------
; one of 512 quiet children
stress_child:
  MOVI r13,1
  SVC 20
  ADD r6,r1,r0
  MOVI r2,7
  MODU r3,r6,r2
  CMP r3,r0
  JMP[EQ] @child_victim
  MOVI r2,5
  MODU r3,r6,r2
  CMP r3,r0
  JMP[NE] @child_exit
  MOVI r1,2
  SVC 24
child_exit:
  MOVI r2,100
  MODU r1,r6,r2
  SVC 1
  HALT
child_victim:
  SVC 0
  JMP @child_victim

; ---------------------------------------------------------------------------
; cooperative worker thread.  r1 = worker id.
stress_worker:
  MOVI r13,1
  LA r12,#P_DATA
  ADD r9,r1,r0
  MOVI r8,50
worker_loop:
  MOVI r1,0
  ADDI r2,r12,#D_MUTEX
  SVC 16
  LD r3,r12,#D_CTR
  ADD r3,r3,r13
  ST r3,r12,#D_CTR
  SVC 0
  MOVI r1,1
  ADDI r2,r12,#D_MUTEX
  SVC 16
  SUB r8,r8,r13
  CMP r8,r0
  JMP[NE] @worker_loop
  ; final critical section: done++, broadcast
  MOVI r1,0
  ADDI r2,r12,#D_MUTEX
  SVC 16
  LD r3,r12,#D_DONE
  ADD r3,r3,r13
  ST r3,r12,#D_DONE
  MOVI r1,2
  ADDI r2,r12,#D_COND
  SVC 17
  MOVI r1,1
  ADDI r2,r12,#D_MUTEX
  SVC 16
  MOVI r1,700
  ADD r1,r1,r9
  SVC 15
  HALT

; ---------------------------------------------------------------------------
desc_root:
.word @stress_root,#P_STACK_TOP,0,1,4
.word 0,#CODE_WORDS,0,5
.word #P_DATA,0x2000,0,3
.word #P_STACK,0x1000,0,3
.word #T_STACK,0x2000,0,3

msg_begin:
.str "SCHED STRESS BEGIN\n"
msg_spawn:
.str "SPAWN "
msg_kill:
.str "KILL "
msg_wait:
.str "WAIT "
msg_sum:
.str "SUM "
msg_statusok:
.str "STATUS OK\n"
msg_count:
.str "COUNT "
msg_limit:
.str " LIMIT "
msg_prio:
.str "PRIO "
msg_threads:
.str "THREADS "
msg_mutex:
.str "MUTEX "
msg_cond:
.str "COND "
msg_join:
.str "JOIN "
msg_pass:
.str "SCHED STRESS PASS\n"
msg_fail:
.str "SCHED STRESS FAIL\n"
msg_bootfail:
.str "BOOT FAIL\n"
