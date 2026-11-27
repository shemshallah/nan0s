; nansched_mp_test.nas - F2 per-CPU NanCore scheduler proof.
;
; Simulates 2 and 4 logical CPUs with the real scheduler policy layer and the
; real NanCore record layout.  The atomic ops table is a single-thread shim
; with nansmp semantics (CAS, fetch-add, fence, trylock, unlock, ipi); the
; production binding to nsp_* is assembled in this image too.
;
; The gate emits exactly O.  A failure prints one diagnostic letter and halts.
;
; Guest map (word addresses):
;   0x7000   stack
;   0x20000  scheduler context (header + per-CPU stats)
;   0x20800  ops table
;   0x21000  task arena (16 words/task)
;   0x400000 NanCore records, 64 words/CPU
;
; TEST_CPUS is an nmk .equ override: the gate builds the same source with
; TEST_CPUS=2 and TEST_CPUS=4.

.equ TEST_CPUS 2
.equ CTX       0x20000
.equ OPS       0x20800
.equ ARENA     0x21000
.equ STACK     0x7000

.org 0
JMP @main
.include "../lib/nansmp.nas"
.include "../lib/nansched_mp.nas"
.include "../lib/nansched_nansmp.nas"

main:
MOVI r13,1
MOVI r14,#STACK

; ops table: six shim entry points
CALL @sim_ops

LA r1,#CTX
MOVI r2,#TEST_CPUS
LA r3,#ARENA
MOVI r4,16
MOVI r5,16
LA r6,#OPS
CALL @nsched_init
MOVI r2,0
MOVI r3,65
CALL @chk

; The production binding writes the six real nansmp entry points.  No port is
; executed here; every pointer is compared against the assembled symbol, then
; the single-thread shim is restored for the policy proof.
LA r1,#CTX
CALL @nsched_bind_nansmp
MOVI r2,0
MOVI r3,49
CALL @chk
LA r5,#OPS
LD r1,r5,#NSD_OP_CAS
LA r2,@nsp_cas
MOVI r3,50
CALL @chk
LD r1,r5,#NSD_OP_FADD
LA r2,@nsp_fetch_add
MOVI r3,51
CALL @chk
LD r1,r5,#NSD_OP_FENCE
LA r2,@nsp_fence
MOVI r3,52
CALL @chk
LD r1,r5,#NSD_OP_LOCK
LA r2,@nsp_trylock
MOVI r3,53
CALL @chk
LD r1,r5,#NSD_OP_UNLOCK
LA r2,@nsp_unlock
MOVI r3,54
CALL @chk
LD r1,r5,#NSD_OP_IPI
LA r2,@nsp_ipi
MOVI r3,55
CALL @chk
CALL @sim_ops

MOVI r1,#TEST_CPUS
MOVI r2,4
CMP r1,r2
JMP[EQ] @run4

; ---------------------------------------------------------------------------
; 2-CPU scenario: FIFO, two preemption hooks, steal, affinity, migration,
; budget exhaustion twice, one deadline miss, exact per-CPU stats.
run2:
; tasks 0..5
MOVI r2,0
MOVI r3,0
MOVI r4,3
MOVI r5,5
MOVI r6,100
CALL @task_add_h
MOVI r2,1
MOVI r3,0
MOVI r4,3
MOVI r5,7
MOVI r6,200
CALL @task_add_h
MOVI r2,2
MOVI r3,1
MOVI r4,3
MOVI r5,9
MOVI r6,300
CALL @task_add_h
MOVI r2,3
MOVI r3,0
MOVI r4,3
MOVI r5,11
MOVI r6,400
CALL @task_add_h
MOVI r2,4
MOVI r3,1
MOVI r4,2
MOVI r5,13
MOVI r6,500
CALL @task_add_h
MOVI r2,5
MOVI r3,1
MOVI r4,3
MOVI r5,2
MOVI r6,1
CALL @task_add_h
MOVI r2,6
MOVI r3,0
MOVI r4,1
MOVI r5,4
MOVI r6,700
CALL @task_add_h

; FIFO: push 0,1; pop 0; preempt; pop 1; preempt
LA r1,#CTX
MOVI r2,0
MOVI r3,0
CALL @nsched_push
MOVI r2,0
MOVI r3,66
CALL @chk
LA r1,#CTX
MOVI r2,0
MOVI r3,1
CALL @nsched_push
MOVI r2,0
MOVI r3,67
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_pop
MOVI r2,0
MOVI r3,68
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_preempt
MOVI r2,0
MOVI r3,69
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_pop
MOVI r2,1
MOVI r3,70
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_preempt
MOVI r2,1
MOVI r3,71
CALL @chk

; steal with empty owner CPU1; expect task 0 from CPU0
LA r1,#CTX
MOVI r2,1
CALL @nsched_steal
MOVI r2,0
MOVI r3,72
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_pop
MOVI r2,0
MOVI r3,73
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_preempt
MOVI r2,0
MOVI r3,74
CALL @chk

; affinity rejection: task6 only CPU0, task4 only CPU1
LA r1,#CTX
MOVI r2,1
MOVI r3,6
CALL @nsched_push
MOVI r2,#NSD_AFF
MOVI r3,75
CALL @chk
LA r1,#CTX
MOVI r2,0
MOVI r3,4
CALL @nsched_push
MOVI r2,#NSD_AFF
MOVI r3,76
CALL @chk
LA r1,#CTX
MOVI r2,0
MOVI r3,3
CALL @nsched_push
MOVI r2,0
MOVI r3,77
CALL @chk
LA r1,#CTX
MOVI r2,1
MOVI r3,4
CALL @nsched_push
MOVI r2,0
MOVI r3,78
CALL @chk

; migration request then migration task3 CPU0 -> CPU1; queue1 [0,4,3]
LA r1,#CTX
MOVI r2,3
MOVI r3,1
CALL @nsched_migrate_request
MOVI r2,0
MOVI r3,64
CALL @chk
LA r5,#ARENA
LD r1,r5,#NSD_T_FLAGS+48
MOVI r2,2
MOVI r3,63
CALL @chk
LA r1,#CTX
MOVI r2,3
MOVI r3,0
MOVI r4,1
CALL @nsched_migrate
MOVI r2,0
MOVI r3,33
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_peek
MOVI r2,1
MOVI r3,80
CALL @chk

; drain queue1 in FIFO order: 0, 4, 3 with a preemption between
LA r1,#CTX
MOVI r2,1
CALL @nsched_pop
MOVI r2,0
MOVI r3,81
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_preempt
MOVI r2,0
MOVI r3,82
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_pop
MOVI r2,4
MOVI r3,83
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_preempt
MOVI r2,4
MOVI r3,84
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_pop
MOVI r2,3
MOVI r3,85
CALL @chk

; budget: task1 on CPU0, seven ticks exhaust quantum 7
LA r1,#CTX
MOVI r2,0
CALL @nsched_pop
MOVI r2,1
MOVI r3,86
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_tick
MOVI r2,0
MOVI r3,87
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_tick
MOVI r2,0
MOVI r3,88
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_tick
MOVI r2,0
MOVI r3,89
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_tick
MOVI r2,0
MOVI r3,90
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_tick
MOVI r2,0
MOVI r3,97
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_tick
MOVI r2,0
MOVI r3,98
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_tick
MOVI r2,1
MOVI r3,99
CALL @chk

; deadline: task3 current on CPU1; deadline 2 is already in the past.
LA r1,#CTX
MOVI r2,3
MOVI r3,2
CALL @nsched_deadline
MOVI r2,0
MOVI r3,100
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_tick
MOVI r2,0
MOVI r3,101
CALL @chk
LA r1,#CTX
MOVI r2,3
MOVI r3,1
CALL @nsched_budget
MOVI r2,0
MOVI r3,102
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_tick
MOVI r2,1
MOVI r3,103
CALL @chk

; exact totals and per-CPU stats for N=2
LA r5,#CTX
LD r1,r5,#NSD_C_PUSHES
MOVI r2,4
MOVI r3,104
CALL @chk
LD r1,r5,#NSD_C_POPS
MOVI r2,7
MOVI r3,105
CALL @chk
LD r1,r5,#NSD_C_STEALS
MOVI r2,1
MOVI r3,106
CALL @chk
LD r1,r5,#NSD_C_MIGS
MOVI r2,1
MOVI r3,107
CALL @chk
LD r1,r5,#NSD_C_AFFREJ
MOVI r2,2
MOVI r3,108
CALL @chk
LD r1,r5,#NSD_C_BUDGET
MOVI r2,2
MOVI r3,109
CALL @chk
LD r1,r5,#NSD_C_DEADLINE
MOVI r2,1
MOVI r3,110
CALL @chk
LD r1,r5,#NSD_C_PREEMPT
MOVI r2,7
MOVI r3,111
CALL @chk
LD r1,r5,#NSD_C_IPIS
MOVI r2,1
MOVI r3,112
CALL @chk
LD r1,r5,#NSD_C_MIGREQ
MOVI r2,1
MOVI r3,64
CALL @chk
LD r1,r5,#NSD_C_EPOCH
MOVI r2,1
MOVI r3,113
CALL @chk
LD r1,r5,#NSD_C_TICK
MOVI r2,9
MOVI r3,114
CALL @chk

; CPU0 stats: push3 pop3 steal0/1 mig0/1 preempt3 ticks7
LD r1,r5,#NSD_C_STATS+0
MOVI r2,3
MOVI r3,115
CALL @chk
LD r1,r5,#NSD_C_STATS+1
MOVI r2,3
MOVI r3,116
CALL @chk
LD r1,r5,#NSD_C_STATS+3
MOVI r2,1
MOVI r3,117
CALL @chk
LD r1,r5,#NSD_C_STATS+5
MOVI r2,1
MOVI r3,118
CALL @chk
LD r1,r5,#NSD_C_STATS+6
MOVI r2,3
MOVI r3,119
CALL @chk
LD r1,r5,#NSD_C_STATS+7
MOVI r2,7
MOVI r3,120
CALL @chk
; CPU1 stats: push1 pop4 steal1/0 mig1/0 preempt4 ticks2
LD r1,r5,#NSD_C_STATS+8
MOVI r2,1
MOVI r3,121
CALL @chk
LD r1,r5,#NSD_C_STATS+9
MOVI r2,4
MOVI r3,122
CALL @chk
LD r1,r5,#NSD_C_STATS+10
MOVI r2,1
MOVI r3,65
CALL @chk
LD r1,r5,#NSD_C_STATS+12
MOVI r2,1
MOVI r3,66
CALL @chk
LD r1,r5,#NSD_C_STATS+14
MOVI r2,4
MOVI r3,67
CALL @chk
LD r1,r5,#NSD_C_STATS+15
MOVI r2,2
MOVI r3,68
CALL @chk

; queues: CPU0 [1], CPU1 [0,4,3]; no current task.
LA r1,#CTX
MOVI r2,0
CALL @nsched_qlen
MOVI r2,1
MOVI r3,69
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_qlen
MOVI r2,3
MOVI r3,70
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_peek
MOVI r2,1
MOVI r3,71
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_peek
MOVI r2,0
MOVI r3,72
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_current
MOVI r2,#NSD_NONE
MOVI r3,73
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_current
MOVI r2,#NSD_NONE
MOVI r3,74
CALL @chk

; task records: t1 budget 0, t3 budget 0 + deadline flag + epoch 1
LA r5,#ARENA
LD r1,r5,#NSD_T_BUDGET+16
MOVI r2,0
MOVI r3,75
CALL @chk
LD r1,r5,#NSD_T_BUDGET+48
MOVI r2,0
MOVI r3,76
CALL @chk
LD r1,r5,#NSD_T_FLAGS+48
MOVI r2,1
MOVI r3,77
CALL @chk
LD r1,r5,#NSD_T_EPOCH+48
MOVI r2,1
MOVI r3,78
CALL @chk

; Running-task migration smoke: pop t1 on CPU0, then migrate the live task.
LA r1,#CTX
MOVI r2,0
CALL @nsched_pop
MOVI r2,1
MOVI r3,56
CALL @chk
LA r1,#CTX
MOVI r2,1
MOVI r3,0
MOVI r4,1
CALL @nsched_migrate
MOVI r2,0
MOVI r3,57
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_current
MOVI r2,#NSD_NONE
MOVI r3,58
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_qlen
MOVI r2,0
MOVI r3,59
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_qlen
MOVI r2,4
MOVI r3,60
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_current
MOVI r2,#NSD_NONE
MOVI r3,61
CALL @chk
JMP @pass

; ---------------------------------------------------------------------------
; 4-CPU scenario: FIFO on CPU0, steal to CPU1, affinity, migration to CPU3,
; budget+deadline on CPU2, affinity setter, exact stats on all four CPUs.
run4:
MOVI r2,0
MOVI r3,0
MOVI r4,15
MOVI r5,5
MOVI r6,100
CALL @task_add_h
MOVI r2,1
MOVI r3,0
MOVI r4,15
MOVI r5,7
MOVI r6,200
CALL @task_add_h
MOVI r2,2
MOVI r3,1
MOVI r4,15
MOVI r5,9
MOVI r6,300
CALL @task_add_h
MOVI r2,3
MOVI r3,0
MOVI r4,9
MOVI r5,11
MOVI r6,400
CALL @task_add_h
MOVI r2,4
MOVI r3,3
MOVI r4,8
MOVI r5,13
MOVI r6,500
CALL @task_add_h
MOVI r2,5
MOVI r3,2
MOVI r4,15
MOVI r5,2
MOVI r6,1
CALL @task_add_h

; FIFO CPU0
LA r1,#CTX
MOVI r2,0
MOVI r3,0
CALL @nsched_push
MOVI r2,0
MOVI r3,80
CALL @chk
LA r1,#CTX
MOVI r2,0
MOVI r3,1
CALL @nsched_push
MOVI r2,0
MOVI r3,81
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_pop
MOVI r2,0
MOVI r3,82
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_preempt
MOVI r2,0
MOVI r3,83
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_pop
MOVI r2,1
MOVI r3,84
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_preempt
MOVI r2,1
MOVI r3,85
CALL @chk

; steal to empty CPU1
LA r1,#CTX
MOVI r2,1
CALL @nsched_steal
MOVI r2,0
MOVI r3,86
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_pop
MOVI r2,0
MOVI r3,87
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_preempt
MOVI r2,0
MOVI r3,88
CALL @chk

; affinity rejection: t3 only CPU0 pushed to CPU2; t4 only CPU3 to CPU1
LA r1,#CTX
MOVI r2,2
MOVI r3,3
CALL @nsched_push
MOVI r2,#NSD_AFF
MOVI r3,89
CALL @chk
LA r1,#CTX
MOVI r2,1
MOVI r3,4
CALL @nsched_push
MOVI r2,#NSD_AFF
MOVI r3,90
CALL @chk
LA r1,#CTX
MOVI r2,0
MOVI r3,3
CALL @nsched_push
MOVI r2,0
MOVI r3,97
CALL @chk
LA r1,#CTX
MOVI r2,3
MOVI r3,4
CALL @nsched_push
MOVI r2,0
MOVI r3,98
CALL @chk

; migrate t3 CPU0 -> CPU3; queue3 [4,3]
LA r1,#CTX
MOVI r2,3
MOVI r3,0
MOVI r4,3
CALL @nsched_migrate
MOVI r2,0
MOVI r3,99
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_peek
MOVI r2,1
MOVI r3,100
CALL @chk
LA r1,#CTX
MOVI r2,3
CALL @nsched_peek
MOVI r2,4
MOVI r3,101
CALL @chk
LA r1,#CTX
MOVI r2,3
CALL @nsched_pop
MOVI r2,4
MOVI r3,102
CALL @chk
LA r1,#CTX
MOVI r2,3
CALL @nsched_preempt
MOVI r2,4
MOVI r3,103
CALL @chk
LA r1,#CTX
MOVI r2,3
CALL @nsched_pop
MOVI r2,3
MOVI r3,104
CALL @chk

; budget + deadline on CPU2: push/pop t5 (quantum 2, deadline 1)
LA r1,#CTX
MOVI r2,2
MOVI r3,5
CALL @nsched_push
MOVI r2,0
MOVI r3,105
CALL @chk
LA r1,#CTX
MOVI r2,2
CALL @nsched_pop
MOVI r2,5
MOVI r3,106
CALL @chk
LA r1,#CTX
MOVI r2,2
CALL @nsched_tick
MOVI r2,0
MOVI r3,107
CALL @chk
LA r1,#CTX
MOVI r2,2
CALL @nsched_tick
MOVI r2,1
MOVI r3,108
CALL @chk

; affinity setter: ready t5 on CPU2 may narrow to {0,1,2}; then t0 on CPU1
; may not be narrowed to {0} (would strand it) and is rejected.
LA r1,#CTX
MOVI r2,5
MOVI r3,7
CALL @nsched_affinity
MOVI r2,0
MOVI r3,109
CALL @chk
LA r1,#CTX
MOVI r2,0
MOVI r3,1
CALL @nsched_affinity
MOVI r2,#NSD_BUSY
MOVI r3,110
CALL @chk

; exact totals and stats for N=4
LA r5,#CTX
LD r1,r5,#NSD_C_PUSHES
MOVI r2,5
MOVI r3,111
CALL @chk
LD r1,r5,#NSD_C_POPS
MOVI r2,6
MOVI r3,112
CALL @chk
LD r1,r5,#NSD_C_STEALS
MOVI r2,1
MOVI r3,113
CALL @chk
LD r1,r5,#NSD_C_MIGS
MOVI r2,1
MOVI r3,114
CALL @chk
LD r1,r5,#NSD_C_AFFREJ
MOVI r2,2
MOVI r3,115
CALL @chk
LD r1,r5,#NSD_C_BUDGET
MOVI r2,1
MOVI r3,116
CALL @chk
LD r1,r5,#NSD_C_DEADLINE
MOVI r2,1
MOVI r3,117
CALL @chk
LD r1,r5,#NSD_C_PREEMPT
MOVI r2,5
MOVI r3,118
CALL @chk
LD r1,r5,#NSD_C_IPIS
MOVI r2,1
MOVI r3,119
CALL @chk
LD r1,r5,#NSD_C_EPOCH
MOVI r2,1
MOVI r3,120
CALL @chk
LD r1,r5,#NSD_C_TICK
MOVI r2,2
MOVI r3,121
CALL @chk

; CPU0: push3 pop2 steal_out1 mig_out1 preempt2 ticks0
LD r1,r5,#NSD_C_STATS+0
MOVI r2,3
MOVI r3,122
CALL @chk
LD r1,r5,#NSD_C_STATS+1
MOVI r2,2
MOVI r3,65
CALL @chk
LD r1,r5,#NSD_C_STATS+3
MOVI r2,1
MOVI r3,66
CALL @chk
LD r1,r5,#NSD_C_STATS+5
MOVI r2,1
MOVI r3,67
CALL @chk
LD r1,r5,#NSD_C_STATS+6
MOVI r2,2
MOVI r3,68
CALL @chk
; CPU1: push0 pop1 steal_in1 preempt1
LD r1,r5,#NSD_C_STATS+8
MOVI r2,0
MOVI r3,69
CALL @chk
LD r1,r5,#NSD_C_STATS+9
MOVI r2,1
MOVI r3,70
CALL @chk
LD r1,r5,#NSD_C_STATS+10
MOVI r2,1
MOVI r3,71
CALL @chk
LD r1,r5,#NSD_C_STATS+14
MOVI r2,1
MOVI r3,72
CALL @chk
; CPU2: push1 pop1 preempt1 ticks2
LD r1,r5,#NSD_C_STATS+16
MOVI r2,1
MOVI r3,73
CALL @chk
LD r1,r5,#NSD_C_STATS+17
MOVI r2,1
MOVI r3,74
CALL @chk
LD r1,r5,#NSD_C_STATS+22
MOVI r2,1
MOVI r3,75
CALL @chk
LD r1,r5,#NSD_C_STATS+23
MOVI r2,2
MOVI r3,76
CALL @chk
; CPU3: push1 pop2 mig_in1 preempt1
LD r1,r5,#NSD_C_STATS+24
MOVI r2,1
MOVI r3,77
CALL @chk
LD r1,r5,#NSD_C_STATS+25
MOVI r2,2
MOVI r3,78
CALL @chk
LD r1,r5,#NSD_C_STATS+28
MOVI r2,1
MOVI r3,79
CALL @chk
LD r1,r5,#NSD_C_STATS+30
MOVI r2,1
MOVI r3,80
CALL @chk

; queues: [1], [0], [5], [4]; CPU3 current is task 3.
LA r1,#CTX
MOVI r2,0
CALL @nsched_peek
MOVI r2,1
MOVI r3,81
CALL @chk
LA r1,#CTX
MOVI r2,1
CALL @nsched_peek
MOVI r2,0
MOVI r3,82
CALL @chk
LA r1,#CTX
MOVI r2,2
CALL @nsched_peek
MOVI r2,5
MOVI r3,83
CALL @chk
LA r1,#CTX
MOVI r2,3
CALL @nsched_peek
MOVI r2,4
MOVI r3,84
CALL @chk
LA r1,#CTX
MOVI r2,0
CALL @nsched_current
MOVI r2,#NSD_NONE
MOVI r3,85
CALL @chk
LA r1,#CTX
MOVI r2,3
CALL @nsched_current
MOVI r2,3
MOVI r3,86
CALL @chk

; task records: t5 budget 0 + deadline flag + affinity 7; t3 epoch 1
LA r5,#ARENA
LD r1,r5,#NSD_T_BUDGET+80
MOVI r2,0
MOVI r3,87
CALL @chk
LD r1,r5,#NSD_T_FLAGS+80
MOVI r2,1
MOVI r3,88
CALL @chk
LD r1,r5,#NSD_T_AFF+80
MOVI r2,7
MOVI r3,89
CALL @chk
LD r1,r5,#NSD_T_EPOCH+48
MOVI r2,1
MOVI r3,90
CALL @chk

pass:
MOVI r1,79
PUTC r1
HALT

; ---------------------------------------------------------------------------
; chk: r1 actual, r2 expected, r3 diagnostic char.
chk:
  CMP r1,r2
  JMP[EQ] @chk_ok
  ADD r1,r3,r0
  PUTC r1
  MOVI r1,10
  PUTC r1
  HALT
chk_ok:
  MOVI r1,0
  RET

; task_add_h: r2=id r3=home r4=aff r5=budget r6=deadline.
task_add_h:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r1,#CTX
  CALL @nsched_task_add
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; Single-thread shim with nansmp value semantics.
sim_ops:
  LA r3,#OPS
  LA r4,@sim_cas
  ST r4,r3,#NSD_OP_CAS
  LA r4,@sim_fadd
  ST r4,r3,#NSD_OP_FADD
  LA r4,@sim_fence
  ST r4,r3,#NSD_OP_FENCE
  LA r4,@sim_lock
  ST r4,r3,#NSD_OP_LOCK
  LA r4,@sim_unlock
  ST r4,r3,#NSD_OP_UNLOCK
  LA r4,@sim_ipi
  ST r4,r3,#NSD_OP_IPI
  RET

sim_cas:
  LD r4,r1,0
  CMP r4,r2
  JMP[NE] @sim_cas_out
  ST r3,r1,0
sim_cas_out:
  ADD r1,r4,r0
  RET

sim_fadd:
  LD r4,r1,0
  ADD r5,r4,r2
  ST r5,r1,0
  ADD r1,r4,r0
  RET

sim_fence:
  MOVI r1,0
  RET

sim_lock:
  LD r2,r1,0
  CMP r2,r0
  JMP[NE] @sim_lock_busy
  MOVI r2,1
  ST r2,r1,0
  MOVI r1,0
  RET
sim_lock_busy:
  MOVI r1,1
  RET

sim_unlock:
  ST r0,r1,0
  MOVI r1,0
  RET

sim_ipi:
  MOVI r1,0
  RET
