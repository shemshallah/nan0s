; nobs_test.nas - F12 observability/ops proof.
;
; Four logical CPUs, real NanCore records, the real nansched_mp policy over a
; single-thread nansmp shim, a synthetic two-node E820/SRAT map fed through
; nnuma into nheap, and the real nobs layer.
;
; Success prints exactly O.  A failed check prints its diagnostic byte and
; halts.

.equ TEST_CPUS 4
.equ STK       0x7000
.equ NC_TAB    0x400000

; Storage (word addresses).
.equ NUMACTX   0x14700
.equ HEAPCTX   0x12000
.equ HEAPDESC  0x12100
.equ HEAPLIST  0x12400
.equ NOBSCTX   0x12600
.equ CFG       0x12640
.equ CORES     0x13000
.equ MEMSTAT   0x13100
.equ QUOTAS    0x13200
.equ RING      0x14000
.equ COLD      0x14100
.equ HEALTH    0x14200
.equ SCHED     0x14300
.equ OPS       0x14400
.equ ARENA     0x14500
.equ OUT1      0x14600
.equ OUT2      0x14610
.equ OUT3      0x14620
.equ OUT4      0x14630
.equ COLDSPEC  0x14640
.equ QSPEC     0x14650
.equ QOUT      0x14660
.equ MSTAT     0x14680
.equ HSTAT     0x146A0
.equ NSTAT     0x146C0
.equ TMPOUT    0x146E0
.equ LAST      0x146F0

.org 0
JMP @main
.include "../lib/nobs.nas"

main:
MOVI r13,1
LA r14,#STK

; ---------------------------------------------------------------------------
; topology: node 0: 4 x 4 KiB at 1 MiB and 2 x 2 MiB at 2 MiB;
; node 1: 4 x 4 KiB at 16 MiB; plus a reserved and an MMIO range that must
; never reach nheap.  CPUs 0,1 -> node 0; CPUs 2,3 -> node 1.
LA r1,#HEAPCTX
LA r2,#HEAPDESC
MOVI r3,16
LA r4,#HEAPLIST
MOVI r5,12
MOVI r6,2
CALL @nheap_init
MOVI r2,0
MOVI r3,64
CALL @chk
LA r1,@numatab
LA r2,#NUMACTX
CALL @nnuma_init
MOVI r2,0
MOVI r3,65
CALL @chk
LA r1,#NUMACTX
CALL @nnuma_verify
MOVI r2,0
MOVI r3,66
CALL @chk
LA r1,#NUMACTX
LA r2,#HEAPCTX
CALL @nnuma_heap_add
MOVI r2,0
MOVI r3,67
CALL @chk
LA r1,#NUMACTX
CALL @nnuma_node_count
MOVI r2,2
MOVI r3,68
CALL @chk

; nobs config
LA r5,#CFG
MOVI r1,#TEST_CPUS
ST r1,r5,#NB_CFG_CPUS
MOVI r1,2
ST r1,r5,#NB_CFG_NODES
MOVI r1,3
ST r1,r5,#NB_CFG_CLASSES
LA r1,#HEAPCTX
ST r1,r5,#NB_CFG_HEAP
LA r1,#SCHED
ST r1,r5,#NB_CFG_SCHED
LA r1,#CORES
ST r1,r5,#NB_CFG_CORES
LA r1,#MEMSTAT
ST r1,r5,#NB_CFG_MEM
LA r1,#QUOTAS
ST r1,r5,#NB_CFG_QUOTAS
LA r1,#RING
ST r1,r5,#NB_CFG_RING
MOVI r1,8
ST r1,r5,#NB_CFG_RINGCAP
LA r1,#COLD
ST r1,r5,#NB_CFG_COLD
MOVI r1,8
ST r1,r5,#NB_CFG_COLDCAP
LA r1,#NOBSCTX
LA r2,#CFG
CALL @nobs_init
MOVI r2,0
MOVI r3,69
CALL @chk

; logical clock starts at 1000
LA r1,#NOBSCTX
MOVI r2,1000
CALL @nobs_tick
MOVI r2,1000
MOVI r3,70
CALL @chk

; ---------------------------------------------------------------------------
; scheduler init: 4 CPUs, 8 tasks, 16-word records, shim ops.
CALL @sim_ops
LA r1,#SCHED
MOVI r2,#TEST_CPUS
LA r3,#ARENA
MOVI r4,16
MOVI r5,8
LA r6,#OPS
CALL @nsched_init
MOVI r2,0
MOVI r3,71
CALL @chk

; tasks 0..4, affinity 15, quantum 5; deadlines 1000..5000.
MOVI r2,0
MOVI r3,0
MOVI r4,15
MOVI r5,5
MOVI r6,1000
CALL @task_add
MOVI r2,1
MOVI r3,0
MOVI r4,15
MOVI r5,5
MOVI r6,2000
CALL @task_add
MOVI r2,2
MOVI r3,0
MOVI r4,15
MOVI r5,5
MOVI r6,3000
CALL @task_add
MOVI r2,3
MOVI r3,3
MOVI r4,15
MOVI r5,5
MOVI r6,4000
CALL @task_add
MOVI r2,4
MOVI r3,0
MOVI r4,15
MOVI r5,5
MOVI r6,5000
CALL @task_add

; e1: push t0 CPU0
LA r1,#SCHED
MOVI r2,0
MOVI r3,0
CALL @nsched_push
MOVI r2,0
MOVI r3,72
CALL @chk
MOVI r2,#NB_K_PUSH
MOVI r3,0
MOVI r4,0
MOVI r5,0
MOVI r6,0
CALL @evt

; e2: push t1 CPU0
LA r1,#SCHED
MOVI r2,0
MOVI r3,1
CALL @nsched_push
MOVI r2,0
MOVI r3,73
CALL @chk
MOVI r2,#NB_K_PUSH
MOVI r3,0
MOVI r4,1
MOVI r5,0
MOVI r6,0
CALL @evt

; e3: pop t0 CPU0
LA r1,#SCHED
MOVI r2,0
CALL @nsched_pop
MOVI r2,0
MOVI r3,74
CALL @chk
MOVI r2,#NB_K_POP
MOVI r3,0
MOVI r4,0
MOVI r5,0
MOVI r6,0
CALL @evt

; e4: preempt t0 CPU0
LA r1,#SCHED
MOVI r2,0
CALL @nsched_preempt
MOVI r2,0
MOVI r3,75
CALL @chk
MOVI r2,#NB_K_PREEMPT
MOVI r3,0
MOVI r4,0
MOVI r5,0
MOVI r6,0
CALL @evt

; e5: steal t1 to CPU1 (CPU0 FIFO head is t1)
LA r1,#SCHED
MOVI r2,1
CALL @nsched_steal
MOVI r2,1
MOVI r3,76
CALL @chk
MOVI r2,#NB_K_STEAL
MOVI r3,1
MOVI r4,1
MOVI r5,0
MOVI r6,0
CALL @evt

; e6: pop t1 CPU1
LA r1,#SCHED
MOVI r2,1
CALL @nsched_pop
MOVI r2,1
MOVI r3,77
CALL @chk
MOVI r2,#NB_K_POP
MOVI r3,1
MOVI r4,1
MOVI r5,0
MOVI r6,0
CALL @evt

; e7: preempt t1 CPU1
LA r1,#SCHED
MOVI r2,1
CALL @nsched_preempt
MOVI r2,1
MOVI r3,78
CALL @chk
MOVI r2,#NB_K_PREEMPT
MOVI r3,1
MOVI r4,1
MOVI r5,0
MOVI r6,0
CALL @evt

; e8: migrate t1 CPU1 -> CPU2
LA r1,#SCHED
MOVI r2,1
MOVI r3,1
MOVI r4,2
CALL @nsched_migrate
MOVI r2,0
MOVI r3,79
CALL @chk
MOVI r2,#NB_K_MIG
MOVI r3,2
MOVI r4,1
MOVI r5,1
MOVI r6,0
CALL @evt

; e9: push t3 CPU3
LA r1,#SCHED
MOVI r2,3
MOVI r3,3
CALL @nsched_push
MOVI r2,0
MOVI r3,80
CALL @chk
MOVI r2,#NB_K_PUSH
MOVI r3,3
MOVI r4,3
MOVI r5,0
MOVI r6,0
CALL @evt

; e10: pop t3 CPU3
LA r1,#SCHED
MOVI r2,3
CALL @nsched_pop
MOVI r2,3
MOVI r3,81
CALL @chk
MOVI r2,#NB_K_POP
MOVI r3,3
MOVI r4,3
MOVI r5,0
MOVI r6,0
CALL @evt

; four accounting ticks, then the fifth exhausts the quantum (e11)
LA r1,#SCHED
MOVI r2,3
CALL @nsched_tick
MOVI r2,0
MOVI r3,82
CALL @chk
LA r1,#SCHED
MOVI r2,3
CALL @nsched_tick
MOVI r2,0
MOVI r3,83
CALL @chk
LA r1,#SCHED
MOVI r2,3
CALL @nsched_tick
MOVI r2,0
MOVI r3,84
CALL @chk
LA r1,#SCHED
MOVI r2,3
CALL @nsched_tick
MOVI r2,0
MOVI r3,85
CALL @chk
LA r1,#SCHED
MOVI r2,3
CALL @nsched_tick
MOVI r2,1
MOVI r3,86
CALL @chk
MOVI r2,#NB_K_BUDGET
MOVI r3,3
MOVI r4,3
MOVI r5,0
MOVI r6,0
CALL @evt

; e12: deadline miss: pop t3, deadline 1, one tick
LA r1,#SCHED
MOVI r2,3
CALL @nsched_pop
MOVI r2,3
MOVI r3,87
CALL @chk
LA r1,#SCHED
MOVI r2,3
MOVI r3,1
CALL @nsched_deadline
MOVI r2,0
MOVI r3,88
CALL @chk
LA r1,#SCHED
MOVI r2,3
CALL @nsched_tick
MOVI r2,0
MOVI r3,89
CALL @chk
MOVI r2,#NB_K_DEADLINE
MOVI r3,3
MOVI r4,3
MOVI r5,0
MOVI r6,0
CALL @evt

; e13: push t4 CPU0
LA r1,#SCHED
MOVI r2,0
MOVI r3,4
CALL @nsched_push
MOVI r2,0
MOVI r3,90
CALL @chk
MOVI r2,#NB_K_PUSH
MOVI r3,0
MOVI r4,4
MOVI r5,0
MOVI r6,0
CALL @evt

; e14: migrate t4 CPU0 -> CPU1
LA r1,#SCHED
MOVI r2,4
MOVI r3,0
MOVI r4,1
CALL @nsched_migrate
MOVI r2,0
MOVI r3,91
CALL @chk
MOVI r2,#NB_K_MIG
MOVI r3,1
MOVI r4,4
MOVI r5,0
MOVI r6,0
CALL @evt

; e15: steal t0 to CPU3
LA r1,#SCHED
MOVI r2,3
CALL @nsched_steal
MOVI r2,0
MOVI r3,92
CALL @chk
MOVI r2,#NB_K_STEAL
MOVI r3,3
MOVI r4,0
MOVI r5,1
MOVI r6,0
CALL @evt

; e16: preempt t3 CPU3
LA r1,#SCHED
MOVI r2,3
CALL @nsched_preempt
MOVI r2,3
MOVI r3,93
CALL @chk
MOVI r2,#NB_K_PREEMPT
MOVI r3,3
MOVI r4,3
MOVI r5,0
MOVI r6,0
CALL @evt

; e17: pop t0 CPU3
LA r1,#SCHED
MOVI r2,3
CALL @nsched_pop
MOVI r2,0
MOVI r3,94
CALL @chk
MOVI r2,#NB_K_POP
MOVI r3,3
MOVI r4,0
MOVI r5,0
MOVI r6,0
CALL @evt

; e18: preempt t0 CPU3
LA r1,#SCHED
MOVI r2,3
CALL @nsched_preempt
MOVI r2,0
MOVI r3,95
CALL @chk
MOVI r2,#NB_K_PREEMPT
MOVI r3,3
MOVI r4,0
MOVI r5,0
MOVI r6,0
CALL @evt

; global scheduler totals
LA r5,#SCHED
LD r1,r5,#NSD_C_PUSHES
MOVI r2,4
MOVI r3,96
CALL @chk
LD r1,r5,#NSD_C_POPS
MOVI r2,5
MOVI r3,97
CALL @chk
LD r1,r5,#NSD_C_STEALS
MOVI r2,2
MOVI r3,98
CALL @chk
LD r1,r5,#NSD_C_MIGS
MOVI r2,2
MOVI r3,99
CALL @chk
LD r1,r5,#NSD_C_BUDGET
MOVI r2,1
MOVI r3,100
CALL @chk
LD r1,r5,#NSD_C_DEADLINE
MOVI r2,1
MOVI r3,101
CALL @chk
LD r1,r5,#NSD_C_PREEMPT
MOVI r2,5
MOVI r3,102
CALL @chk
LD r1,r5,#NSD_C_TICK
MOVI r2,6
MOVI r3,103
CALL @chk
LD r1,r5,#NSD_C_IPIS
MOVI r2,2
MOVI r3,104
CALL @chk

; explicit NanCore/Nobs events before sampling:
; CPU1 +2 IPIs, CPU2 +1 IPI and 3 faults, CPU3 budget/deadline misses.
LA r1,#NOBSCTX
MOVI r2,1
MOVI r3,3
MOVI r4,2
CALL @nobs_core_event
MOVI r2,0
MOVI r3,105
CALL @chk
LA r1,#NOBSCTX
MOVI r2,2
MOVI r3,3
MOVI r4,1
CALL @nobs_core_event
MOVI r2,0
MOVI r3,106
CALL @chk
LA r1,#NOBSCTX
MOVI r2,2
MOVI r3,0
MOVI r4,3
CALL @nobs_core_event
MOVI r2,0
MOVI r3,107
CALL @chk
LA r1,#NOBSCTX
MOVI r2,3
MOVI r3,1
MOVI r4,1
CALL @nobs_core_event
MOVI r2,0
MOVI r3,108
CALL @chk
LA r1,#NOBSCTX
MOVI r2,3
MOVI r3,2
MOVI r4,1
CALL @nobs_core_event
MOVI r2,0
MOVI r3,109
CALL @chk

; sample all four CPUs
MOVI r8,0
MOVI r9,110
CALL @sample4
; nobs_core_get copies the CPU3 record out.
LA r1,#NOBSCTX
MOVI r2,3
LA r3,#MSTAT
CALL @nobs_core_get
MOVI r2,0
MOVI r3,236
CALL @chk
LA r5,#MSTAT
LD r1,r5,#NB_C_QDEPTH
MOVI r2,2
MOVI r3,237
CALL @chk

; CPU0: ticks0 tasks1 sout2 mout1 q0
LA r5,#CORES
LD r1,r5,#NB_C_TICKS+0
MOVI r2,0
MOVI r3,111
CALL @chk
LD r1,r5,#NB_C_TASKS+0
MOVI r2,1
MOVI r3,112
CALL @chk
LD r1,r5,#NB_C_STEAL_OUT+0
MOVI r2,2
MOVI r3,113
CALL @chk
LD r1,r5,#NB_C_MIG_OUT+0
MOVI r2,1
MOVI r3,114
CALL @chk
LD r1,r5,#NB_C_QDEPTH+0
MOVI r2,0
MOVI r3,115
CALL @chk
; CPU1: tasks1 sin1 min1 ipis2 q1
LD r1,r5,#NB_C_TASKS+16
MOVI r2,1
MOVI r3,116
CALL @chk
LD r1,r5,#NB_C_STEAL_IN+16
MOVI r2,1
MOVI r3,117
CALL @chk
LD r1,r5,#NB_C_MIG_IN+16
MOVI r2,1
MOVI r3,118
CALL @chk
LD r1,r5,#NB_C_IPIS+16
MOVI r2,2
MOVI r3,119
CALL @chk
LD r1,r5,#NB_C_QDEPTH+16
MOVI r2,1
MOVI r3,120
CALL @chk
; CPU2: faults3 ipis1 min1 q1
LD r1,r5,#NB_C_FAULTS+32
MOVI r2,3
MOVI r3,121
CALL @chk
LD r1,r5,#NB_C_IPIS+32
MOVI r2,1
MOVI r3,122
CALL @chk
LD r1,r5,#NB_C_MIG_IN+32
MOVI r2,1
MOVI r3,123
CALL @chk
LD r1,r5,#NB_C_QDEPTH+32
MOVI r2,1
MOVI r3,124
CALL @chk
; CPU3: ticks6 tasks2 sin1 preempt3 budget1 deadline1 q2
LD r1,r5,#NB_C_TICKS+48
MOVI r2,6
MOVI r3,125
CALL @chk
LD r1,r5,#NB_C_TASKS+48
MOVI r2,3
MOVI r3,126
CALL @chk
LD r1,r5,#NB_C_STEAL_IN+48
MOVI r2,1
MOVI r3,127
CALL @chk
LD r1,r5,#NB_C_PREEMPT+48
MOVI r2,3
MOVI r3,128
CALL @chk
LD r1,r5,#NB_C_BUDGET+48
MOVI r2,1
MOVI r3,129
CALL @chk
LD r1,r5,#NB_C_DEADLINE+48
MOVI r2,1
MOVI r3,130
CALL @chk
LD r1,r5,#NB_C_QDEPTH+48
MOVI r2,2
MOVI r3,131
CALL @chk

; NanCore publication: CPU3 NC_TICKS == 6, NC_QCOUNT == 2, CPU1 NC_IPI == 2.
LA r5,#NC_TAB
LD r1,r5,#NC_TICKS+192
MOVI r2,6
MOVI r3,132
CALL @chk
LD r1,r5,#NC_QCOUNT+192
MOVI r2,2
MOVI r3,133
CALL @chk
LD r1,r5,#NC_IPI+64
MOVI r2,2
MOVI r3,134
CALL @chk

; ---------------------------------------------------------------------------
; memory: node0 4K 4 pages + 2M 2 pages; node1 4K 4 pages.
; A1 node0/4K 2 pages -> out1
LA r1,#NOBSCTX
MOVI r2,0
MOVI r3,0
MOVI r4,2
MOVI r5,0
LA r6,#OUT1
CALL @nobs_mem_alloc
MOVI r2,0
MOVI r3,135
CALL @chk
; A2 node1/4K 1 page
LA r1,#NOBSCTX
MOVI r2,1
MOVI r3,0
MOVI r4,1
MOVI r5,0
LA r6,#OUT2
CALL @nobs_mem_alloc
MOVI r2,0
MOVI r3,136
CALL @chk
; A3 node0/2M 1 page
LA r1,#NOBSCTX
MOVI r2,0
MOVI r3,1
MOVI r4,1
MOVI r5,0
LA r6,#OUT3
CALL @nobs_mem_alloc
MOVI r2,0
MOVI r3,137
CALL @chk
; mark A1 cold
LA r5,#COLDSPEC
MOVI r1,2
ST r1,r5,0
ST r0,r5,1
LA r1,#OUT1
LD r2,r1,0
ST r2,r5,2
LD r2,r1,1
ST r2,r5,3
LA r1,#NOBSCTX
MOVI r2,0
MOVI r3,0
LA r4,#COLDSPEC
CALL @nobs_mem_cold
MOVI r2,0
MOVI r3,138
CALL @chk
; A4 node0/4K remaining 2 pages
LA r1,#NOBSCTX
MOVI r2,0
MOVI r3,0
MOVI r4,2
MOVI r5,0
LA r6,#OUT4
CALL @nobs_mem_alloc
MOVI r2,0
MOVI r3,139
CALL @chk

; pressure 2 pages: heap empty, evict the cold extent, retry succeeds.
LA r1,#NOBSCTX
MOVI r2,1
CALL @nobs_tick
LA r1,#NOBSCTX
MOVI r2,0
MOVI r3,0
MOVI r4,2
MOVI r5,0
CALL @nobs_mem_pressure
MOVI r2,0
MOVI r3,140
CALL @chk

; pressure 1 page: no cold pages -> OOM deny.
LA r1,#NOBSCTX
MOVI r2,1
CALL @nobs_tick
LA r1,#NOBSCTX
MOVI r2,0
MOVI r3,0
MOVI r4,1
MOVI r5,0
CALL @nobs_mem_pressure
MOVI r2,1
MOVI r3,141
CALL @chk

; free the 2M page (A3) to exercise frees/bytes
LA r1,#NOBSCTX
MOVI r2,0
MOVI r3,1
LA r4,#OUT3
LD r4,r4,0
LA r5,#OUT3
LD r5,r5,1
MOVI r6,1
MOVI r7,0
CALL @nobs_mem_free
MOVI r2,0
MOVI r3,142
CALL @chk

; node0 4K stats: allocs3 live4 bytes4000 evp2 evb2000 oom1 deny1 hw4 evicts1
LA r1,#NOBSCTX
MOVI r2,0
MOVI r3,0
LA r4,#MSTAT
CALL @nobs_mem_stats
MOVI r2,0
MOVI r3,143
CALL @chk
LA r5,#MSTAT
LD r1,r5,#NB_M_ALLOCS
MOVI r2,3
MOVI r3,144
CALL @chk
LD r1,r5,#NB_M_FREES
MOVI r2,0
MOVI r3,145
CALL @chk
LD r1,r5,#NB_M_LIVE_LO
MOVI r2,4
MOVI r3,146
CALL @chk
LD r1,r5,#NB_M_LIVE_HI
MOVI r2,0
MOVI r3,147
CALL @chk
LD r1,r5,#NB_M_BYTES_LO
MOVI r2,0x4000
MOVI r3,148
CALL @chk
LD r1,r5,#NB_M_EVP_LO
MOVI r2,2
MOVI r3,149
CALL @chk
LD r1,r5,#NB_M_EVB_LO
MOVI r2,0x2000
MOVI r3,150
CALL @chk
LD r1,r5,#NB_M_OOM
MOVI r2,1
MOVI r3,151
CALL @chk
LD r1,r5,#NB_M_DENY
MOVI r2,1
MOVI r3,152
CALL @chk
LD r1,r5,#NB_M_HW_LO
MOVI r2,4
MOVI r3,153
CALL @chk
LD r1,r5,#NB_M_EVICTS
MOVI r2,1
MOVI r3,154
CALL @chk
; node0 2M: allocs1 frees1 live0 bytes0
LA r1,#NOBSCTX
MOVI r2,0
MOVI r3,1
LA r4,#MSTAT
CALL @nobs_mem_stats
MOVI r2,0
MOVI r3,155
CALL @chk
LA r5,#MSTAT
LD r1,r5,#NB_M_ALLOCS
MOVI r2,1
MOVI r3,156
CALL @chk
LD r1,r5,#NB_M_FREES
MOVI r2,1
MOVI r3,157
CALL @chk
LD r1,r5,#NB_M_LIVE_LO
MOVI r2,0
MOVI r3,158
CALL @chk
LD r1,r5,#NB_M_BYTES_LO
MOVI r2,0
MOVI r3,159
CALL @chk
; node1 4K: allocs1 live1 bytes1000
LA r1,#NOBSCTX
MOVI r2,1
MOVI r3,0
LA r4,#MSTAT
CALL @nobs_mem_stats
MOVI r2,0
MOVI r3,160
CALL @chk
LA r5,#MSTAT
LD r1,r5,#NB_M_ALLOCS
MOVI r2,1
MOVI r3,161
CALL @chk
LD r1,r5,#NB_M_LIVE_LO
MOVI r2,1
MOVI r3,162
CALL @chk
LD r1,r5,#NB_M_BYTES_LO
MOVI r2,0x1000
MOVI r3,163
CALL @chk

; nheap free-page cross-check: node0/4K 0, node0/2M 2, node1/4K 3.
LA r1,#HEAPCTX
MOVI r2,0
MOVI r3,0
LA r4,#NSTAT
CALL @nheap_stats
MOVI r2,0
MOVI r3,164
CALL @chk
LA r5,#NSTAT
LD r1,r5,0
MOVI r2,0
MOVI r3,165
CALL @chk
LA r1,#HEAPCTX
MOVI r2,0
MOVI r3,1
LA r4,#NSTAT
CALL @nheap_stats
MOVI r2,0
MOVI r3,166
CALL @chk
LA r5,#NSTAT
LD r1,r5,0
MOVI r2,2
MOVI r3,167
CALL @chk
LA r1,#HEAPCTX
MOVI r2,1
MOVI r3,0
LA r4,#NSTAT
CALL @nheap_stats
MOVI r2,0
MOVI r3,168
CALL @chk
LA r5,#NSTAT
LD r1,r5,0
MOVI r2,3
MOVI r3,169
CALL @chk

; ---------------------------------------------------------------------------
; quota: agent 1, steps10 ticks5 mem64 KV3.
LA r5,#QSPEC
MOVI r1,10
ST r1,r5,0
MOVI r1,5
ST r1,r5,1
MOVI r1,64
ST r1,r5,2
ST r0,r5,3
MOVI r1,3
ST r1,r5,4
ST r0,r5,5
LA r1,#NOBSCTX
MOVI r2,1
LA r3,#QSPEC
CALL @nobs_quota_set
MOVI r2,0
MOVI r3,170
CALL @chk

; steps 4 admit, 7 deny (e21)
LA r1,#NOBSCTX
MOVI r2,1
MOVI r3,0
MOVI r4,4
MOVI r5,0
CALL @nobs_quota_account
MOVI r2,0
MOVI r3,171
CALL @chk
LA r1,#NOBSCTX
MOVI r2,1
CALL @nobs_tick
LA r1,#NOBSCTX
MOVI r2,1
MOVI r3,0
MOVI r4,7
MOVI r5,0
CALL @nobs_quota_account
MOVI r2,1
MOVI r3,172
CALL @chk

; ticks 3 admit, 3 deny (e22)
LA r1,#NOBSCTX
MOVI r2,1
MOVI r3,1
MOVI r4,3
MOVI r5,0
CALL @nobs_quota_account
MOVI r2,0
MOVI r3,173
CALL @chk
LA r1,#NOBSCTX
MOVI r2,1
CALL @nobs_tick
LA r1,#NOBSCTX
MOVI r2,1
MOVI r3,1
MOVI r4,3
MOVI r5,0
CALL @nobs_quota_account
MOVI r2,1
MOVI r3,174
CALL @chk

; memory 32 admit; check 32 fits, 33 denies; 40 deny (e23)
LA r1,#NOBSCTX
MOVI r2,1
MOVI r3,2
MOVI r4,32
MOVI r5,0
CALL @nobs_quota_account
MOVI r2,0
MOVI r3,175
CALL @chk
LA r1,#NOBSCTX
MOVI r2,1
MOVI r3,2
MOVI r4,32
MOVI r5,0
CALL @nobs_quota_check
MOVI r2,0
MOVI r3,176
CALL @chk
LA r1,#NOBSCTX
MOVI r2,1
MOVI r3,2
MOVI r4,33
MOVI r5,0
CALL @nobs_quota_check
MOVI r2,1
MOVI r3,177
CALL @chk
LA r1,#NOBSCTX
MOVI r2,1
CALL @nobs_tick
LA r1,#NOBSCTX
MOVI r2,1
MOVI r3,2
MOVI r4,40
MOVI r5,0
CALL @nobs_quota_account
MOVI r2,1
MOVI r3,178
CALL @chk

; KV 2 admit, 2 deny (e24)
LA r1,#NOBSCTX
MOVI r2,1
MOVI r3,3
MOVI r4,2
MOVI r5,0
CALL @nobs_quota_account
MOVI r2,0
MOVI r3,179
CALL @chk
LA r1,#NOBSCTX
MOVI r2,1
CALL @nobs_tick
LA r1,#NOBSCTX
MOVI r2,1
MOVI r3,3
MOVI r4,2
MOVI r5,0
CALL @nobs_quota_account
MOVI r2,1
MOVI r3,180
CALL @chk

; quota record exact and denied count 4
LA r1,#NOBSCTX
MOVI r2,1
LA r3,#QOUT
CALL @nobs_quota_get
MOVI r2,0
MOVI r3,181
CALL @chk
LA r5,#QOUT
LD r1,r5,#NB_Q_ACTIVE
MOVI r2,1
MOVI r3,182
CALL @chk
LD r1,r5,#NB_Q_USEDSTEP
MOVI r2,4
MOVI r3,183
CALL @chk
LD r1,r5,#NB_Q_USEDTICK
MOVI r2,3
MOVI r3,184
CALL @chk
LD r1,r5,#NB_Q_USEDMEM_LO
MOVI r2,32
MOVI r3,185
CALL @chk
LD r1,r5,#NB_Q_USEDKV
MOVI r2,2
MOVI r3,186
CALL @chk
LD r1,r5,#NB_Q_DENIED
MOVI r2,4
MOVI r3,187
CALL @chk

; ---------------------------------------------------------------------------
; trace ring: cap 8, total 24, wraps 16, count 8, oldest valid index 16.
LA r1,#NOBSCTX
LD r1,r1,#NB_RINGTOTAL
MOVI r2,24
MOVI r3,188
CALL @chk
LA r1,#NOBSCTX
LD r1,r1,#NB_RINGWRAPS
MOVI r2,16
MOVI r3,189
CALL @chk
LA r1,#NOBSCTX
LD r1,r1,#NB_RINGCOUNT
MOVI r2,8
MOVI r3,190
CALL @chk
; overwritten indices fail closed
LA r1,#NOBSCTX
MOVI r2,0
LA r3,#LAST
CALL @nobs_trace_at
LA r2,0xFFFFFFFF
MOVI r3,191
CALL @chk
LA r1,#NOBSCTX
MOVI r2,15
LA r3,#LAST
CALL @nobs_trace_at
LA r2,0xFFFFFFFF
MOVI r3,192
CALL @chk
; index 16: POP cpu3 id0 seq16
LA r1,#NOBSCTX
MOVI r2,16
LA r3,#LAST
CALL @nobs_trace_at
MOVI r2,0
MOVI r3,193
CALL @chk
LA r5,#LAST
LD r1,r5,#NB_T_SEQ
MOVI r2,16
MOVI r3,194
CALL @chk
LD r1,r5,#NB_T_CPU
MOVI r2,3
MOVI r3,195
CALL @chk
LD r1,r5,#NB_T_KIND
MOVI r2,#NB_K_POP
MOVI r3,196
CALL @chk
LD r1,r5,#NB_T_ID
MOVI r2,0
MOVI r3,197
CALL @chk
; snapshot of the live window
LA r1,#NOBSCTX
LA r2,#HEALTH
MOVI r3,8
CALL @nobs_trace_snapshot
MOVI r2,8
MOVI r3,198
CALL @chk
LA r5,#HEALTH
LD r1,r5,#NB_T_KIND+56
MOVI r2,#NB_K_QUOTA
MOVI r3,199
CALL @chk
LD r1,r5,#NB_T_A+56
MOVI r2,3
MOVI r3,200
CALL @chk
LD r1,r5,#NB_T_B+56
MOVI r2,2
MOVI r3,201
CALL @chk
LD r1,r5,#NB_T_TICK+56
MOVI r2,1024
MOVI r3,202
CALL @chk
LD r1,r5,#NB_T_SEQ+56
MOVI r2,23
MOVI r3,203
CALL @chk
; last entry is the same one
LA r1,#NOBSCTX
LA r2,#OUT1
CALL @nobs_trace_last
MOVI r2,0
MOVI r3,204
CALL @chk
LA r5,#OUT1
LD r1,r5,#NB_T_KIND
MOVI r2,#NB_K_QUOTA
MOVI r3,205
CALL @chk

; deterministic hash: exact value for the last entry (seq 23).
LA r5,#HEALTH
LD r1,r5,#NB_T_HASH+56
LA r2,0x7CCD2B3F
MOVI r3,206
CALL @chk

; ---------------------------------------------------------------------------
; health snapshot exact totals.
LA r1,#NOBSCTX
LA r2,#HSTAT
CALL @nobs_health
MOVI r2,0
MOVI r3,207
CALL @chk
LA r5,#HSTAT
LD r1,r5,#NB_H_MAGIC
LA r2,#NB_HMAGIC
MOVI r3,208
CALL @chk
LD r1,r5,#NB_H_VERSION
MOVI r2,1
MOVI r3,209
CALL @chk
LD r1,r5,#NB_H_CPUS
MOVI r2,4
MOVI r3,210
CALL @chk
LD r1,r5,#NB_H_NODES
MOVI r2,2
MOVI r3,211
CALL @chk
LD r1,r5,#NB_H_CLASSES
MOVI r2,3
MOVI r3,212
CALL @chk
LD r1,r5,#NB_H_TICK
MOVI r2,1024
MOVI r3,213
CALL @chk
LD r1,r5,#NB_H_TICKS
MOVI r2,6
MOVI r3,214
CALL @chk
LD r1,r5,#NB_H_TASKS
MOVI r2,5
MOVI r3,215
CALL @chk
LD r1,r5,#NB_H_STEALS
MOVI r2,2
MOVI r3,216
CALL @chk
LD r1,r5,#NB_H_MIGS
MOVI r2,2
MOVI r3,217
CALL @chk
LD r1,r5,#NB_H_FAULTS
MOVI r2,3
MOVI r3,218
CALL @chk
LD r1,r5,#NB_H_IPIS
MOVI r2,3
MOVI r3,219
CALL @chk
LD r1,r5,#NB_H_BUDGET
MOVI r2,1
MOVI r3,220
CALL @chk
LD r1,r5,#NB_H_DEADLINE
MOVI r2,1
MOVI r3,221
CALL @chk
LD r1,r5,#NB_H_QDEPTH
MOVI r2,4
MOVI r3,222
CALL @chk
LD r1,r5,#NB_H_ALLOCS
MOVI r2,5
MOVI r3,223
CALL @chk
LD r1,r5,#NB_H_FREES
MOVI r2,1
MOVI r3,224
CALL @chk
LD r1,r5,#NB_H_LIVEP_LO
MOVI r2,5
MOVI r3,225
CALL @chk
LD r1,r5,#NB_H_LIVEB_LO
MOVI r2,0x5000
MOVI r3,226
CALL @chk
LD r1,r5,#NB_H_OOM
MOVI r2,1
MOVI r3,227
CALL @chk
LD r1,r5,#NB_H_EVICTS
MOVI r2,1
MOVI r3,228
CALL @chk
LD r1,r5,#NB_H_EVP_LO
MOVI r2,2
MOVI r3,229
CALL @chk
LD r1,r5,#NB_H_QDENY
MOVI r2,4
MOVI r3,230
CALL @chk
LD r1,r5,#NB_H_RINGTOTAL
MOVI r2,24
MOVI r3,231
CALL @chk
LD r1,r5,#NB_H_RINGWRAPS
MOVI r2,16
MOVI r3,232
CALL @chk
LD r1,r5,#NB_H_STATUS
MOVI r2,2
MOVI r3,233
CALL @chk
LD r1,r5,#NB_H_SAMPLES
MOVI r2,4
MOVI r3,234
CALL @chk
LD r1,r5,#NB_H_RINGCOUNT
MOVI r2,8
MOVI r3,235
CALL @chk

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

; evt: advance the logical clock and append a trace event.
; r2 kind r3 cpu r4 id r5 a r6 b
evt:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r2,r14,1
  ST r3,r14,2
  ST r4,r14,3
  ST r5,r14,4
  ST r6,r14,5
  LA r1,#NOBSCTX
  MOVI r2,1
  CALL @nobs_tick
  LA r1,#NOBSCTX
  LD r2,r14,1
  LD r3,r14,2
  LD r4,r14,3
  LD r5,r14,4
  LD r6,r14,5
  CALL @nobs_trace
  CMP r1,r0
  JMP[EQ] @evt_fail
  ADDI r14,r14,-24
  LD r15,r14,0
  RET
evt_fail:
  MOVI r1,70
  PUTC r1
  MOVI r1,10
  PUTC r1
  HALT

; task_add: r2 id r3 home r4 affinity r5 budget r6 deadline.
task_add:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r1,#SCHED
  CALL @nsched_task_add
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; sample4: sample CPUs 0..3.
sample4:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r8,0
sample4_loop:
  MOVI r10,4
  CMP r8,r10
  JMP[GE] @sample4_done
  LA r1,#NOBSCTX
  ADD r2,r8,r0
  CALL @nobs_core_sample
  CMP r1,r0
  JMP[NE] @sample4_fail
  ADDI r8,r8,1
  JMP @sample4_loop
sample4_done:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
sample4_fail:
  MOVI r1,83
  PUTC r1
  HALT

; ---------------------------------------------------------------------------
; Single-thread nansmp shim.
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

; ---------------------------------------------------------------------------
; topology image: 5 ranges, 4 cpus, 2 nodes.
numatab:
.word 0x4E554D41,1,5,4,2,0,0,0
; range 0: node0 1 MiB..1 MiB+16 KiB RAM (4 x 4K)
.word 0x100000,0,0x4000,0,0,0,0,0
; range 1: node0 2 MiB..6 MiB RAM (2 x 2M)
.word 0x200000,0,0x400000,0,0,0,0,0
; range 2: node1 16 MiB..16 MiB+16 KiB RAM (4 x 4K)
.word 0x1000000,0,0x4000,0,0,1,0,0
; range 3: node1 reserved 32 MiB..32 MiB+16 KiB
.word 0x2000000,0,0x4000,0,1,1,0,0
; range 4: node0 MMIO 48 MiB..48 MiB+4 KiB
.word 0x3000000,0,0x1000,0,4,0,0,0
; cpus: apic, cpu_id, node, flags
.word 0,0,0,0
.word 1,1,0,0
.word 2,2,1,0
.word 3,3,1,0
; nodes: id, declared mem lo/hi, declared cpu count
.word 0,0x404000,0,2
.word 1,0x4000,0,2
