; nanproc_test.nas - self-checking gate for src/lib/nanproc.nas.
; Runs as a small NaN16 image: prints fixed decimal/hex report lines and halts.
; Primary target is the x86_64 S1 NaN image; the portable C core is the oracle.
; Memory: code/data low, NP table at 0x10000, heap fixtures at 0x30000+.
.equ NP_BASE 0x10000
.equ NP_VARS 0x1F00
.equ V_CHK 0x1F10
.equ V_T0 0x1F11
.equ V_T1 0x1F12
.equ V_T2 0x1F13
.equ V_T3 0x1F14
.equ V_T4 0x1F15
.equ V_T5 0x1F16
.equ V_T6 0x1F17
.equ V_T7 0x1F18
.equ V_T8 0x1F19
.equ V_T9 0x1F1A
.equ V_STAT 0x1F30
.equ STACK 0x7000
.equ HEAP0 0x30000
.equ HEAP2 0x33000
.equ HEAP3 0x34000
.equ HEAP4 0x35000
.equ CAPREG_BASE 0x400000
.equ IMAGE3 0x50000
.equ STACK3 0x3A000

main:
  MOVI r13,1
  MOVI r14,#STACK
  MOVI r1,@s_banner
  CALL @puts
  CALL @np_init
  CALL @np_counts
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  ST r3,r0,#V_T2
  ST r4,r0,#V_T3
  ST r5,r0,#V_T4
  LD r1,r0,#V_T0
  MOVI r2,0
  MOVI r10,0x101
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,0
  MOVI r10,0x102
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,0
  MOVI r10,0x103
  CALL @ex
  LD r1,r0,#V_T3
  MOVI r2,0
  MOVI r10,0x104
  CALL @ex
  LD r1,r0,#V_T4
  MOVI r2,0
  MOVI r10,0x105
  CALL @ex
  MOVI r1,@s_init
  CALL @puts
  LD r2,r0,#V_T0
  MOVI r1,@s_live
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_run
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_zomb
  CALL @pfield
  LD r2,r0,#V_T3
  MOVI r1,@s_spawn
  CALL @pfield
  LD r2,r0,#V_T4
  MOVI r1,@s_reapv
  CALL @pfield
  CALL @nl

; ---- process 1: init, root, running, one heap region ----
  MOVI r1,0
  MOVI r2,@s_name_init
  MOVI r3,0
  MOVI r4,0
  CALL @np_create
  ST r1,r0,#V_T0
  MOVI r2,1
  MOVI r10,0x110
  CALL @ex
  MOVI r1,1
  CALL @np_lookup
  CALL @exnz
  LD r2,r1,#NP_E_PPID
  ST r2,r0,#V_T1
  LD r2,r1,#NP_E_STATE
  ST r2,r0,#V_T2
  LD r1,r0,#V_T1
  MOVI r2,0
  MOVI r10,0x111
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,#NP_ST_READY
  MOVI r10,0x112
  CALL @ex
  CALL @np_counts
  ST r1,r0,#V_T3
  LD r1,r0,#V_T3
  MOVI r2,1
  MOVI r10,0x113
  CALL @ex
  MOVI r1,@s_create
  CALL @puts
  LD r2,r0,#V_T0
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_ppid
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_state
  CALL @pfield
  LD r2,r0,#V_T3
  MOVI r1,@s_livev
  CALL @pfield
  CALL @nl

  MOVI r1,1
  MOVI r2,#NP_ST_RUNNING
  CALL @np_set_state
  MOVI r2,0
  MOVI r10,0x114
  CALL @ex
  MOVI r1,1
  CALL @np_lookup
  LD r2,r1,#NP_E_STATE
  ST r2,r0,#V_T0
  CALL @np_counts
  ST r2,r0,#V_T1
  LD r1,r0,#V_T0
  MOVI r2,#NP_ST_RUNNING
  MOVI r10,0x115
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,1
  MOVI r10,0x116
  CALL @ex
  MOVI r1,@s_runline
  CALL @puts
  LD r2,r0,#V_T0
  MOVI r1,@s_state
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_runv
  CALL @pfield
  CALL @nl

  MOVI r1,1
  LA r2,#HEAP0
  MOVI r3,1024
  CALL @np_heap_set
  MOVI r2,0
  MOVI r10,0x117
  CALL @ex
  MOVI r1,1
  MOVI r2,100
  CALL @np_heap_used_set
  MOVI r2,0
  MOVI r10,0x118
  CALL @ex
  MOVI r1,1
  CALL @np_mem_stats
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  ST r3,r0,#V_T2
  ST r4,r0,#V_T3
  ST r5,r0,#V_T4
  LD r1,r0,#V_T0
  MOVI r2,100
  MOVI r10,0x119
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,1024
  MOVI r10,0x11A
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,1024
  MOVI r10,0x11B
  CALL @ex
  LD r1,r0,#V_T3
  MOVI r2,1
  MOVI r10,0x11C
  CALL @ex
  LD r1,r0,#V_T4
  MOVI r2,924
  MOVI r10,0x11D
  CALL @ex
  MOVI r1,@s_heap1
  CALL @puts
  LD r2,r0,#V_T0
  MOVI r1,@s_used
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_words
  CALL @pfield
  LD r2,r0,#V_T3
  MOVI r1,@s_regions
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_mem
  CALL @pfield
  LD r2,r0,#V_T4
  MOVI r1,@s_head
  CALL @pfield
  CALL @nl

; ---- process 2: shell child ----
  MOVI r1,1
  MOVI r2,@s_name_sh
  MOVI r3,0
  MOVI r4,0
  CALL @np_create
  ST r1,r0,#V_T0
  MOVI r2,2
  MOVI r10,0x120
  CALL @ex
  MOVI r1,2
  CALL @np_lookup
  CALL @exnz
  LD r2,r1,#NP_E_PPID
  ST r2,r0,#V_T1
  MOVI r1,1
  CALL @np_child_count
  ST r1,r0,#V_T2
  LD r1,r0,#V_T1
  MOVI r2,1
  MOVI r10,0x121
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,1
  MOVI r10,0x122
  CALL @ex
  MOVI r1,@s_create
  CALL @puts
  LD r2,r0,#V_T0
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_ppid
  CALL @pfield
  MOVI r2,#NP_ST_READY
  MOVI r1,@s_state
  CALL @pfield
  MOVI r2,2
  MOVI r1,@s_livev
  CALL @pfield
  CALL @nl
  MOVI r1,@s_child
  CALL @puts
  MOVI r2,1
  MOVI r1,@s_parent
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_count
  CALL @pfield
  CALL @nl

; ---- process 3: spawned tcl child with image, heap, stack, threads ----
  MOVI r1,1
  MOVI r2,@s_name_tcl
  LA r3,#IMAGE3
  MOVI r4,128
  CALL @np_spawn
  ST r1,r0,#V_T0
  MOVI r2,3
  MOVI r10,0x130
  CALL @ex
  MOVI r1,3
  CALL @np_lookup
  CALL @exnz
  LD r2,r1,#NP_E_PPID
  ST r2,r0,#V_T1
  LD r2,r1,#NP_E_NREG
  ST r2,r0,#V_T2
  LD r2,r1,#NP_E_MEM_WORDS
  ST r2,r0,#V_T3
  MOVI r1,1
  CALL @np_child_count
  ST r1,r0,#V_T4
  LD r1,r0,#V_T1
  MOVI r2,1
  MOVI r10,0x131
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,1
  MOVI r10,0x132
  CALL @ex
  LD r1,r0,#V_T3
  MOVI r2,128
  MOVI r10,0x133
  CALL @ex
  LD r1,r0,#V_T4
  MOVI r2,2
  MOVI r10,0x134
  CALL @ex
  MOVI r1,@s_spawnline
  CALL @puts
  LD r2,r0,#V_T0
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_ppid
  CALL @pfield
  LA r2,#IMAGE3
  MOVI r1,@s_image
  CALL @pfield
  MOVI r2,128
  MOVI r1,@s_words
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_nreg
  CALL @pfield
  CALL @nl
  MOVI r1,@s_child
  CALL @puts
  MOVI r2,1
  MOVI r1,@s_parent
  CALL @pfield
  LD r2,r0,#V_T4
  MOVI r1,@s_count
  CALL @pfield
  CALL @nl

  MOVI r1,3
  LA r2,#HEAP2
  MOVI r3,2048
  CALL @np_heap_set
  MOVI r2,0
  MOVI r10,0x135
  CALL @ex
  MOVI r1,3
  MOVI r2,100
  CALL @np_heap_used_set
  MOVI r2,0
  MOVI r10,0x136
  CALL @ex
  MOVI r1,3
  LA r2,#STACK3
  MOVI r3,64
  MOVI r4,#NP_K_STACK
  MOVI r5,#NP_PROT_RW
  CALL @np_region_add
  MOVI r2,0
  MOVI r10,0x137
  CALL @ex
  MOVI r1,3
  CALL @np_mem_stats
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  ST r3,r0,#V_T2
  ST r4,r0,#V_T3
  ST r5,r0,#V_T4
  LD r1,r0,#V_T0
  MOVI r2,100
  MOVI r10,0x138
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,2048
  MOVI r10,0x139
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,2240
  MOVI r10,0x13A
  CALL @ex
  LD r1,r0,#V_T3
  MOVI r2,3
  MOVI r10,0x13B
  CALL @ex
  LD r1,r0,#V_T4
  MOVI r2,1948
  MOVI r10,0x13C
  CALL @ex
  MOVI r1,@s_heap3
  CALL @puts
  LD r2,r0,#V_T0
  MOVI r1,@s_used
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_words
  CALL @pfield
  LD r2,r0,#V_T3
  MOVI r1,@s_regions
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_mem
  CALL @pfield
  LD r2,r0,#V_T4
  MOVI r1,@s_head
  CALL @pfield
  CALL @nl

; ---- region descriptors: heap then stack then out-of-range ----
  MOVI r1,3
  MOVI r2,1
  CALL @np_region_get
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  ST r3,r0,#V_T2
  ST r4,r0,#V_T3
  ST r5,r0,#V_T4
  LD r1,r0,#V_T0
  LA r2,#HEAP2
  MOVI r10,0x140
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,2048
  MOVI r10,0x141
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,#NP_K_HEAP
  MOVI r10,0x142
  CALL @ex
  LD r1,r0,#V_T3
  MOVI r2,#NP_PROT_RW
  MOVI r10,0x143
  CALL @ex
  LD r1,r0,#V_T4
  MOVI r2,1
  MOVI r10,0x144
  CALL @ex
  MOVI r1,@s_region
  CALL @puts
  MOVI r2,3
  MOVI r1,@s_pid
  CALL @pfield
  MOVI r2,1
  MOVI r1,@s_idx
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_base
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_n
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_kind
  CALL @pfield
  LD r2,r0,#V_T3
  MOVI r1,@s_prot
  CALL @pfield
  CALL @nl

  MOVI r1,3
  MOVI r2,2
  CALL @np_region_get
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  ST r3,r0,#V_T2
  ST r4,r0,#V_T3
  ST r5,r0,#V_T4
  LD r1,r0,#V_T0
  LA r2,#STACK3
  MOVI r10,0x145
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,64
  MOVI r10,0x146
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,#NP_K_STACK
  MOVI r10,0x147
  CALL @ex
  MOVI r1,@s_region
  CALL @puts
  MOVI r2,3
  MOVI r1,@s_pid
  CALL @pfield
  MOVI r2,2
  MOVI r1,@s_idx
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_base
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_n
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_kind
  CALL @pfield
  LD r2,r0,#V_T3
  MOVI r1,@s_prot
  CALL @pfield
  CALL @nl

  MOVI r1,3
  MOVI r2,3
  CALL @np_region_get
  ST r5,r0,#V_T4
  LD r1,r0,#V_T4
  MOVI r2,0
  MOVI r10,0x148
  CALL @ex
  MOVI r1,@s_region
  CALL @puts
  MOVI r2,3
  MOVI r1,@s_pid
  CALL @pfield
  MOVI r2,3
  MOVI r1,@s_idx
  CALL @pfield
  LD r2,r0,#V_T4
  MOVI r1,@s_found
  CALL @pfield
  CALL @nl

; ---- threads, steps, priority, state, stat block ----
  MOVI r1,3
  MOVI r2,201
  CALL @np_thread_add
  MOVI r2,0
  MOVI r10,0x150
  CALL @ex
  MOVI r1,3
  MOVI r2,202
  CALL @np_thread_add
  MOVI r2,0
  MOVI r10,0x151
  CALL @ex
  MOVI r1,3
  MOVI r2,201
  CALL @np_thread_add
  ST r1,r0,#V_T0
  LD r1,r0,#V_T0
  MOVI r2,3
  MOVI r10,0x152
  CALL @ex
  MOVI r1,3
  MOVI r2,1000
  CALL @np_add_steps
  MOVI r1,3
  MOVI r2,4000
  CALL @np_add_steps
  MOVI r1,3
  MOVI r2,5
  CALL @np_set_priority
  MOVI r2,0
  MOVI r10,0x153
  CALL @ex
  MOVI r1,3
  MOVI r2,#NP_ST_RUNNING
  CALL @np_set_state
  MOVI r2,0
  MOVI r10,0x1A0
  CALL @ex
  MOVI r1,3
  MOVI r2,#NP_ST_BLOCKED
  CALL @np_set_state
  MOVI r2,0
  MOVI r10,0x1A1
  CALL @ex
  MOVI r1,3
  MOVI r2,#NP_ST_RUNNING
  CALL @np_set_state
  ST r1,r0,#V_T1
  LD r1,r0,#V_T1
  MOVI r2,2
  MOVI r10,0x155
  CALL @ex
  MOVI r1,3
  MOVI r2,#V_STAT
  CALL @np_stat
  MOVI r2,0
  MOVI r10,0x156
  CALL @ex
  LD r1,r0,#V_STAT+#NP_S_PID
  MOVI r2,3
  MOVI r10,0x157
  CALL @ex
  LD r1,r0,#V_STAT+#NP_S_THREADS
  MOVI r2,2
  MOVI r10,0x158
  CALL @ex
  LD r1,r0,#V_STAT+#NP_S_STEPS
  MOVI r2,5000
  MOVI r10,0x159
  CALL @ex
  LD r1,r0,#V_STAT+#NP_S_NREG
  MOVI r2,3
  MOVI r10,0x15A
  CALL @ex
  LD r1,r0,#V_STAT+#NP_S_MEM_WORDS
  MOVI r2,2240
  MOVI r10,0x15B
  CALL @ex
  LD r1,r0,#V_STAT+#NP_S_PRIO
  MOVI r2,5
  MOVI r10,0x15C
  CALL @ex
  LD r1,r0,#V_STAT+#NP_S_STATE
  MOVI r2,#NP_ST_BLOCKED
  MOVI r10,0x15D
  CALL @ex
  MOVI r1,@s_threads
  CALL @puts
  MOVI r2,3
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_STAT+#NP_S_THREADS
  MOVI r1,@s_count
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_dup
  CALL @pfield
  CALL @nl
  MOVI r1,@s_attrs
  CALL @puts
  MOVI r2,3
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_STAT+#NP_S_STEPS
  MOVI r1,@s_steps
  CALL @pfield
  LD r2,r0,#V_STAT+#NP_S_PRIO
  MOVI r1,@s_prio
  CALL @pfield
  LD r2,r0,#V_STAT+#NP_S_STATE
  MOVI r1,@s_state
  CALL @pfield
  CALL @nl
  MOVI r1,@s_illegal
  CALL @puts
  MOVI r2,3
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_transition
  CALL @pfield
  CALL @nl

; ---- process 4: exit, wait, reap, zombie cleanup ----
  MOVI r1,1
  MOVI r2,@s_name_crash
  MOVI r3,0
  MOVI r4,0
  CALL @np_create
  ST r1,r0,#V_T0
  MOVI r2,4
  MOVI r10,0x160
  CALL @ex
  MOVI r1,4
  LA r2,#HEAP3
  MOVI r3,256
  CALL @np_heap_set
  MOVI r2,0
  MOVI r10,0x161
  CALL @ex
  MOVI r1,1
  CALL @np_child_count
  ST r1,r0,#V_T1
  LD r1,r0,#V_T1
  MOVI r2,3
  MOVI r10,0x162
  CALL @ex
  MOVI r1,@s_create
  CALL @puts
  LD r2,r0,#V_T0
  MOVI r1,@s_pid
  CALL @pfield
  MOVI r2,1
  MOVI r1,@s_ppid
  CALL @pfield
  MOVI r2,#NP_ST_READY
  MOVI r1,@s_state
  CALL @pfield
  MOVI r2,4
  MOVI r1,@s_livev
  CALL @pfield
  CALL @nl
  MOVI r1,@s_child
  CALL @puts
  MOVI r2,1
  MOVI r1,@s_parent
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_count
  CALL @pfield
  CALL @nl

  MOVI r1,4
  MOVI r2,3
  CALL @np_exit
  CALL @exz
  MOVI r1,4
  CALL @np_lookup
  CALL @exnz
  LD r2,r1,#NP_E_STATE
  ST r2,r0,#V_T0
  LD r2,r1,#NP_E_STATUS
  ST r2,r0,#V_T1
  CALL @np_counts
  ST r3,r0,#V_T2
  ST r1,r0,#V_T3
  LD r1,r0,#V_T0
  MOVI r2,#NP_ST_ZOMBIE
  MOVI r10,0x163
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,3
  MOVI r10,0x164
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,1
  MOVI r10,0x165
  CALL @ex
  LD r1,r0,#V_T3
  MOVI r2,4
  MOVI r10,0x166
  CALL @ex
  MOVI r1,@s_exitline
  CALL @puts
  MOVI r2,4
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_state
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_status
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_zombies
  CALL @pfield
  LD r2,r0,#V_T3
  MOVI r1,@s_livev
  CALL @pfield
  CALL @nl

  MOVI r1,1
  MOVI r2,4
  CALL @np_wait
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  LD r1,r0,#V_T0
  MOVI r2,4
  MOVI r10,0x167
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,3
  MOVI r10,0x168
  CALL @ex
  MOVI r1,@s_wait
  CALL @puts
  MOVI r2,1
  MOVI r1,@s_parent
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_status
  CALL @pfield
  CALL @nl

  MOVI r1,1
  MOVI r2,2
  CALL @np_wait
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  LD r1,r0,#V_T0
  MOVI r2,0
  MOVI r10,0x169
  CALL @ex
  MOVI r1,@s_waitnone
  CALL @puts
  MOVI r2,1
  MOVI r1,@s_parent
  CALL @pfield
  MOVI r2,2
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_code
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_status
  CALL @pfield
  CALL @nl

  MOVI r1,4
  CALL @np_reap
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  LD r1,r0,#V_T0
  MOVI r2,0
  MOVI r10,0x16A
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,3
  MOVI r10,0x16B
  CALL @ex
  MOVI r1,4
  CALL @np_lookup
  ST r1,r0,#V_T0
  MOVI r1,1
  CALL @np_child_count
  ST r1,r0,#V_T1
  CALL @np_counts
  ST r1,r0,#V_T2
  ST r3,r0,#V_T3
  LD r1,r0,#V_T0
  MOVI r2,0
  MOVI r10,0x16C
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,2
  MOVI r10,0x16D
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,3
  MOVI r10,0x16E
  CALL @ex
  LD r1,r0,#V_T3
  MOVI r2,0
  MOVI r10,0x16F
  CALL @ex
  MOVI r1,@s_reap
  CALL @puts
  MOVI r2,4
  MOVI r1,@s_pid
  CALL @pfield
  MOVI r2,3
  MOVI r1,@s_status
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_livev
  CALL @pfield
  LD r2,r0,#V_T3
  MOVI r1,@s_zombies
  CALL @pfield
  CALL @nl
  MOVI r1,@s_cleanup
  CALL @puts
  MOVI r2,4
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_found
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_children
  CALL @pfield
  CALL @nl

  MOVI r1,4
  CALL @np_reap
  ST r1,r0,#V_T0
  LD r1,r0,#V_T0
  MOVI r2,1
  MOVI r10,0x170
  CALL @ex
  MOVI r1,@s_reapagain
  CALL @puts
  MOVI r2,4
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_code
  CALL @pfield
  CALL @nl

; ---- kill: signal death, zombie, wait-any, reap ----
  MOVI r1,2
  MOVI r2,15
  CALL @np_kill
  ST r1,r0,#V_T0
  LD r1,r0,#V_T0
  MOVI r2,0
  MOVI r10,0x171
  CALL @ex
  MOVI r1,2
  CALL @np_lookup
  CALL @exnz
  LD r2,r1,#NP_E_STATE
  ST r2,r0,#V_T1
  LD r2,r1,#NP_E_STATUS
  ST r2,r0,#V_T2
  CALL @np_counts
  ST r3,r0,#V_T3
  LD r1,r0,#V_T1
  MOVI r2,#NP_ST_ZOMBIE
  MOVI r10,0x172
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,143
  MOVI r10,0x173
  CALL @ex
  LD r1,r0,#V_T3
  MOVI r2,1
  MOVI r10,0x174
  CALL @ex
  MOVI r1,@s_kill
  CALL @puts
  MOVI r2,2
  MOVI r1,@s_pid
  CALL @pfield
  MOVI r2,15
  MOVI r1,@s_sig
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_status
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_state
  CALL @pfield
  LD r2,r0,#V_T3
  MOVI r1,@s_zombies
  CALL @pfield
  CALL @nl

  MOVI r1,1
  MOVI r2,0
  CALL @np_wait
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  LD r1,r0,#V_T0
  MOVI r2,2
  MOVI r10,0x175
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,143
  MOVI r10,0x176
  CALL @ex
  MOVI r1,@s_waitany
  CALL @puts
  MOVI r2,1
  MOVI r1,@s_parent
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_status
  CALL @pfield
  CALL @nl

  MOVI r1,2
  CALL @np_reap
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  LD r1,r0,#V_T0
  MOVI r2,0
  MOVI r10,0x177
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,143
  MOVI r10,0x178
  CALL @ex
  MOVI r1,2
  CALL @np_lookup
  ST r1,r0,#V_T0
  MOVI r1,1
  CALL @np_child_count
  ST r1,r0,#V_T1
  CALL @np_counts
  ST r1,r0,#V_T2
  ST r3,r0,#V_T3
  LD r1,r0,#V_T0
  MOVI r2,0
  MOVI r10,0x179
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,1
  MOVI r10,0x17A
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,2
  MOVI r10,0x17B
  CALL @ex
  LD r1,r0,#V_T3
  MOVI r2,0
  MOVI r10,0x17C
  CALL @ex
  MOVI r1,@s_cleanup
  CALL @puts
  MOVI r2,2
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_found
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_children
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_livev
  CALL @pfield
  LD r2,r0,#V_T3
  MOVI r1,@s_zombies
  CALL @pfield
  CALL @nl

  CALL @np_counts
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  ST r3,r0,#V_T2
  ST r4,r0,#V_T3
  ST r5,r0,#V_T4
  LD r1,r0,#V_T0
  MOVI r2,2
  MOVI r10,0x180
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,1
  MOVI r10,0x181
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,0
  MOVI r10,0x182
  CALL @ex
  LD r1,r0,#V_T3
  MOVI r2,4
  MOVI r10,0x183
  CALL @ex
  LD r1,r0,#V_T4
  MOVI r2,2
  MOVI r10,0x184
  CALL @ex
  MOVI r1,@s_stats
  CALL @puts
  LD r2,r0,#V_T0
  MOVI r1,@s_live
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_run
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_zomb
  CALL @pfield
  LD r2,r0,#V_T3
  MOVI r1,@s_spawn
  CALL @pfield
  LD r2,r0,#V_T4
  MOVI r1,@s_reapv
  CALL @pfield
  CALL @nl

; ---- final cleanup: kill the blocked tcl child, reap it ----
  MOVI r1,3
  MOVI r2,9
  CALL @np_kill
  MOVI r2,0
  MOVI r10,0x185
  CALL @ex
  MOVI r1,3
  CALL @np_lookup
  CALL @exnz
  LD r2,r1,#NP_E_STATE
  ST r2,r0,#V_T0
  LD r2,r1,#NP_E_STATUS
  ST r2,r0,#V_T1
  LD r1,r0,#V_T0
  MOVI r2,#NP_ST_ZOMBIE
  MOVI r10,0x186
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,137
  MOVI r10,0x187
  CALL @ex
  MOVI r1,@s_kill
  CALL @puts
  MOVI r2,3
  MOVI r1,@s_pid
  CALL @pfield
  MOVI r2,9
  MOVI r1,@s_sig
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_status
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_state
  CALL @pfield
  CALL @nl
  MOVI r1,3
  CALL @np_reap
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  LD r1,r0,#V_T0
  MOVI r2,0
  MOVI r10,0x188
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,137
  MOVI r10,0x189
  CALL @ex
  CALL @np_counts
  ST r1,r0,#V_T0
  LD r1,r0,#V_T0
  MOVI r2,1
  MOVI r10,0x18A
  CALL @ex
  MOVI r1,@s_reap
  CALL @puts
  MOVI r2,3
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_status
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_livev
  CALL @pfield
  CALL @nl

; ---- orphan/reparent and region release: root 5, child 6 ----
  MOVI r1,0
  MOVI r2,@s_name_orphan
  MOVI r3,0
  MOVI r4,0
  CALL @np_create
  ST r1,r0,#V_T0
  MOVI r2,5
  MOVI r10,0x190
  CALL @ex
  MOVI r1,5
  MOVI r2,@s_name_kid
  MOVI r3,0
  MOVI r4,0
  CALL @np_create
  ST r1,r0,#V_T1
  MOVI r2,6
  MOVI r10,0x191
  CALL @ex
  MOVI r1,6
  LA r2,#HEAP4
  MOVI r3,64
  CALL @np_heap_set
  MOVI r2,0
  MOVI r10,0x192
  CALL @ex
  MOVI r1,6
  CALL @np_region_clear
  MOVI r2,0
  MOVI r10,0x193
  CALL @ex
  MOVI r1,6
  CALL @np_mem_stats
  ST r1,r0,#V_T0
  ST r3,r0,#V_T1
  ST r4,r0,#V_T2
  LD r1,r0,#V_T0
  MOVI r2,0
  MOVI r10,0x194
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,0
  MOVI r10,0x195
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,0
  MOVI r10,0x196
  CALL @ex
  MOVI r1,@s_clear
  CALL @puts
  MOVI r2,6
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_nreg
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_mem
  CALL @pfield
  CALL @nl
  MOVI r1,5
  CALL @np_child_count
  ST r1,r0,#V_T0
  LD r1,r0,#V_T0
  MOVI r2,1
  MOVI r10,0x197
  CALL @ex
  MOVI r1,5
  MOVI r2,11
  CALL @np_exit
  MOVI r2,0
  MOVI r10,0x198
  CALL @ex
  MOVI r1,5
  CALL @np_lookup
  CALL @exnz
  LD r2,r1,#NP_E_STATE
  ST r2,r0,#V_T0
  LD r2,r1,#NP_E_STATUS
  ST r2,r0,#V_T1
  LD r1,r0,#V_T0
  MOVI r2,#NP_ST_DEAD
  MOVI r10,0x199
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,11
  MOVI r10,0x19A
  CALL @ex
  MOVI r1,6
  CALL @np_lookup
  CALL @exnz
  LD r2,r1,#NP_E_PPID
  ST r2,r0,#V_T2
  LD r2,r1,#NP_E_STATE
  ST r2,r0,#V_T3
  LD r1,r0,#V_T2
  MOVI r2,1
  MOVI r10,0x19B
  CALL @ex
  LD r1,r0,#V_T3
  MOVI r2,#NP_ST_READY
  MOVI r10,0x19C
  CALL @ex
  MOVI r1,1
  CALL @np_child_count
  ST r1,r0,#V_T4
  MOVI r1,5
  CALL @np_child_count
  ST r1,r0,#V_T5
  LD r1,r0,#V_T4
  MOVI r2,1
  MOVI r10,0x19D
  CALL @ex
  LD r1,r0,#V_T5
  MOVI r2,0
  MOVI r10,0x19E
  CALL @ex
  MOVI r1,@s_orphan
  CALL @puts
  MOVI r2,5
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_state
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_status
  CALL @pfield
  MOVI r2,6
  MOVI r1,@s_kid
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_kidppid
  CALL @pfield
  LD r2,r0,#V_T4
  MOVI r1,@s_initchildren
  CALL @pfield
  CALL @nl
  MOVI r1,5
  CALL @np_reap
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  LD r1,r0,#V_T0
  MOVI r2,0
  MOVI r10,0x19F
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,11
  MOVI r10,0x1A2
  CALL @ex
  CALL @np_counts
  ST r1,r0,#V_T2
  ST r3,r0,#V_T3
  MOVI r1,@s_reap
  CALL @puts
  MOVI r2,5
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_status
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_livev
  CALL @pfield
  LD r2,r0,#V_T3
  MOVI r1,@s_zombies
  CALL @pfield
  CALL @nl

  MOVI r1,6
  MOVI r2,2
  CALL @np_kill
  MOVI r2,0
  MOVI r10,0x1A3
  CALL @ex
  MOVI r1,6
  CALL @np_lookup
  CALL @exnz
  LD r2,r1,#NP_E_STATE
  ST r2,r0,#V_T0
  LD r2,r1,#NP_E_STATUS
  ST r2,r0,#V_T1
  LD r1,r0,#V_T0
  MOVI r2,#NP_ST_ZOMBIE
  MOVI r10,0x1A4
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,130
  MOVI r10,0x1A5
  CALL @ex
  MOVI r1,@s_kill
  CALL @puts
  MOVI r2,6
  MOVI r1,@s_pid
  CALL @pfield
  MOVI r2,2
  MOVI r1,@s_sig
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_status
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_state
  CALL @pfield
  CALL @nl
  MOVI r1,1
  MOVI r2,0
  CALL @np_wait
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  LD r1,r0,#V_T0
  MOVI r2,6
  MOVI r10,0x1A6
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,130
  MOVI r10,0x1A7
  CALL @ex
  MOVI r1,@s_waitany
  CALL @puts
  MOVI r2,1
  MOVI r1,@s_parent
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_status
  CALL @pfield
  CALL @nl
  MOVI r1,6
  CALL @np_reap
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  ST r2,r0,#V_T5
  LD r1,r0,#V_T0
  MOVI r2,0
  MOVI r10,0x1A8
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,130
  MOVI r10,0x1A9
  CALL @ex

; ---- capacity: 64 process slots, 8 regions, 16 threads ----
  ST r0,r0,#V_T0
cap_create:
  LD r5,r0,#V_T0
  MOVI r6,63
  CMP r5,r6
  JMP[GE] @cap_create_done
  MOVI r7,7
  ADD r2,r5,r7
  ST r2,r0,#V_T1
  MOVI r1,0
  MOVI r2,@s_name_cap
  MOVI r3,0
  MOVI r4,0
  CALL @np_create
  ST r1,r0,#V_T2
  LD r2,r0,#V_T1
  MOVI r10,0x1B0
  CALL @ex
  LD r5,r0,#V_T0
  ADD r5,r5,r13
  ST r5,r0,#V_T0
  JMP @cap_create
cap_create_done:
  CALL @np_counts
  ST r1,r0,#V_T0
  LD r1,r0,#V_T0
  MOVI r2,64
  MOVI r10,0x1B1
  CALL @ex
  MOVI r1,0
  MOVI r2,@s_name_cap
  MOVI r3,0
  MOVI r4,0
  CALL @np_create
  ST r1,r0,#V_T1
  LD r1,r0,#V_T1
  MOVI r2,0
  MOVI r10,0x1B2
  CALL @ex
  ST r0,r0,#V_T3
cap_reg:
  LD r5,r0,#V_T3
  MOVI r6,8
  CMP r5,r6
  JMP[GE] @cap_reg_done
  MOVI r1,7
  LA r2,#CAPREG_BASE
  LD r5,r0,#V_T3
  SHL r5,r5,12
  ADD r2,r2,r5
  MOVI r3,16
  MOVI r4,#NP_K_SHARED
  MOVI r5,#NP_PROT_R
  CALL @np_region_add
  MOVI r2,0
  MOVI r10,0x1B3
  CALL @ex
  LD r5,r0,#V_T3
  ADD r5,r5,r13
  ST r5,r0,#V_T3
  JMP @cap_reg
cap_reg_done:
  MOVI r1,7
  LA r2,#CAPREG_BASE
  MOVI r3,16
  MOVI r4,#NP_K_SHARED
  MOVI r5,#NP_PROT_R
  CALL @np_region_add
  MOVI r2,2
  MOVI r10,0x1B4
  CALL @ex
  MOVI r1,7
  MOVI r2,#V_STAT
  CALL @np_stat
  LD r1,r0,#V_STAT+#NP_S_NREG
  MOVI r2,8
  MOVI r10,0x1B5
  CALL @ex
  ST r0,r0,#V_T3
cap_thread:
  LD r5,r0,#V_T3
  MOVI r6,16
  CMP r5,r6
  JMP[GE] @cap_thread_done
  MOVI r1,7
  MOVI r2,1000
  ADD r2,r2,r5
  CALL @np_thread_add
  MOVI r2,0
  MOVI r10,0x1B6
  CALL @ex
  LD r5,r0,#V_T3
  ADD r5,r5,r13
  ST r5,r0,#V_T3
  JMP @cap_thread
cap_thread_done:
  MOVI r1,7
  MOVI r2,1016
  CALL @np_thread_add
  MOVI r2,2
  MOVI r10,0x1B7
  CALL @ex
  MOVI r1,7
  MOVI r2,#V_STAT
  CALL @np_stat
  LD r1,r0,#V_STAT+#NP_S_THREADS
  MOVI r2,16
  MOVI r10,0x1B8
  CALL @ex
  MOVI r1,@s_capacity
  CALL @puts
  LD r2,r0,#V_T0
  MOVI r1,@s_procs
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_overflow
  CALL @pfield
  MOVI r2,8
  MOVI r1,@s_regions
  CALL @pfield
  MOVI r2,16
  MOVI r1,@s_threadsv
  CALL @pfield
  CALL @nl
  ST r0,r0,#V_T3
cap_reap:
  LD r5,r0,#V_T3
  MOVI r6,63
  CMP r5,r6
  JMP[GE] @cap_reap_done
  MOVI r7,7
  ADD r7,r7,r5
  ST r7,r0,#V_T2
  ADD r1,r7,r0
  MOVI r2,0
  CALL @np_exit
  MOVI r2,0
  MOVI r10,0x1B9
  CALL @ex
  LD r1,r0,#V_T2
  CALL @np_reap
  ST r1,r0,#V_T4
  ST r2,r0,#V_T6
  LD r1,r0,#V_T4
  MOVI r2,0
  MOVI r10,0x1BA
  CALL @ex
  LD r1,r0,#V_T6
  MOVI r2,0
  MOVI r10,0x1BB
  CALL @ex
  LD r5,r0,#V_T3
  ADD r5,r5,r13
  ST r5,r0,#V_T3
  JMP @cap_reap
cap_reap_done:
  CALL @np_counts
  ST r1,r0,#V_T0
  ST r2,r0,#V_T1
  ST r3,r0,#V_T2
  ST r4,r0,#V_T3
  ST r5,r0,#V_T4
  LD r1,r0,#V_T0
  MOVI r2,1
  MOVI r10,0x1AA
  CALL @ex
  LD r1,r0,#V_T1
  MOVI r2,1
  MOVI r10,0x1AB
  CALL @ex
  LD r1,r0,#V_T2
  MOVI r2,0
  MOVI r10,0x1AC
  CALL @ex
  LD r1,r0,#V_T3
  MOVI r2,69
  MOVI r10,0x1AD
  CALL @ex
  LD r1,r0,#V_T4
  MOVI r2,68
  MOVI r10,0x1AE
  CALL @ex
  MOVI r1,@s_reap
  CALL @puts
  MOVI r2,6
  MOVI r1,@s_pid
  CALL @pfield
  LD r2,r0,#V_T5
  MOVI r1,@s_status
  CALL @pfield
  LD r2,r0,#V_T0
  MOVI r1,@s_livev
  CALL @pfield
  CALL @nl
  MOVI r1,@s_final
  CALL @puts
  LD r2,r0,#V_T0
  MOVI r1,@s_live
  CALL @pfield
  LD r2,r0,#V_T1
  MOVI r1,@s_run
  CALL @pfield
  LD r2,r0,#V_T2
  MOVI r1,@s_zomb
  CALL @pfield
  LD r2,r0,#V_T3
  MOVI r1,@s_spawn
  CALL @pfield
  LD r2,r0,#V_T4
  MOVI r1,@s_reapv
  CALL @pfield
  CALL @nl

  MOVI r1,@s_pass
  CALL @puts
  LD r1,r0,#V_CHK
  CALL @puthex
  MOVI r1,@s_nl
  CALL @puts
  HALT

; ---- helpers -------------------------------------------------------------
puts:
  MOVI r4,255
pw:
  LD r2,r1,0
  MOVI r3,4
pt1:
  BOOL.8 r5,r2,r4
  CMP r5,r0
  RET[EQ]
  PUTC r5
  SHR r2,r2,8
  SUB r3,r3,r13
  JMP[NE] @pt1
  ADD r1,r1,r13
  JMP @pw

puthex:
  MOVI r3,8
  MOVI r4,10
  MOVI r7,7
ph1:
  SHR r2,r1,28
  SHL r1,r1,4
  MOVI r6,48
  ADD r6,r6,r2
  CMP r2,r4
  ADD[GE] r6,r6,r7
  PUTC r6
  SUB r3,r3,r13
  JMP[NE] @ph1
  RET

pfield:
  ST r15,r14,0
  ADDI r14,r14,#NP_FRAME
  ST r2,r14,1
  CALL @puts
  LD r1,r14,1
  CALL @puthex
  ADDI r14,r14,#NP_FRAME_NEG
  LD r15,r14,0
  RET

nl:
  MOVI r1,10
  PUTC r1
  RET

ex:
  CMP r1,r2
  JMP[NE] @ex_bad
  LD r3,r0,#V_CHK
  ADD r3,r3,r13
  ST r3,r0,#V_CHK
  RET
ex_bad:
  MOVI r11,2
  CALL @fail

exnz:
  CMP r1,r0
  JMP[EQ] @exnz_bad
  LD r3,r0,#V_CHK
  ADD r3,r3,r13
  ST r3,r0,#V_CHK
  RET
exnz_bad:
  MOVI r11,0
  CALL @fail

exz:
  CMP r1,r0
  JMP[NE] @exz_bad
  LD r3,r0,#V_CHK
  ADD r3,r3,r13
  ST r3,r0,#V_CHK
  RET
exz_bad:
  MOVI r11,0
  CALL @fail

; fail: r10=tag r11=count of scratch words to print. Never returns.
fail:
  MOVI r1,@s_fail
  CALL @puts
  BOOL.12 r1,r10,r10
  CALL @puthex
  MOVI r9,0
fl1:
  CMP r9,r11
  JMP[GE] @fl2
  MOVI r1,32
  PUTC r1
  MOVI r5,#V_T0
  ADD r5,r5,r9
  LD r1,r5,0
  CALL @puthex
  ADD r9,r9,r13
  JMP @fl1
fl2:
  CALL @nl
  HALT

s_banner:
.str "nanproc test\n"
s_name_init:
.str "init"
s_name_sh:
.str "sh"
s_name_tcl:
.str "tcl"
s_name_crash:
.str "crash"
s_name_orphan:
.str "orphan"
s_name_kid:
.str "kid"
s_name_cap:
.str "cap"
s_pass:
.str "PASS checks="
s_fail:
.str "FAIL tag="
s_init:
.str "init"
s_live:
.str " live="
s_run:
.str " run="
s_zomb:
.str " zomb="
s_spawn:
.str " spawn="
s_reap:
.str "reap"
s_reapv:
.str " reap="
s_create:
.str "create"
s_spawnline:
.str "spawn-stub"
s_heap1:
.str "heap"
s_heap3:
.str "heap"
s_child:
.str "child"
s_runline:
.str "run"
s_region:
.str "region"
s_threads:
.str "threads"
s_attrs:
.str "attrs"
s_illegal:
.str "illegal"
s_exitline:
.str "exit"
s_wait:
.str "wait"
s_waitnone:
.str "wait-none"
s_waitany:
.str "wait-any"
s_cleanup:
.str "cleanup"
s_reapagain:
.str "reap-again"
s_kill:
.str "kill"
s_stats:
.str "stats"
s_capacity:
.str "capacity"
s_procs:
.str " procs="
s_overflow:
.str " overflow="
s_threadsv:
.str " threads="
s_clear:
.str "clear"
s_orphan:
.str "orphan"
s_final:
.str "final"
s_kid:
.str " kid="
s_kidppid:
.str " kidppid="
s_initchildren:
.str " initchildren="
s_pid:
.str " pid="
s_ppid:
.str " ppid="
s_state:
.str " state="
s_livev:
.str " live="
s_parent:
.str " parent="
s_count:
.str " count="
s_image:
.str " image="
s_words:
.str " words="
s_nreg:
.str " nreg="
s_used:
.str " used="
s_regions:
.str " regions="
s_mem:
.str " mem="
s_head:
.str " head="
s_idx:
.str " idx="
s_base:
.str " base="
s_n:
.str " n="
s_kind:
.str " kind="
s_prot:
.str " prot="
s_found:
.str " found="
s_dup:
.str " dup="
s_steps:
.str " steps="
s_prio:
.str " prio="
s_transition:
.str " transition="
s_status:
.str " status="
s_zombies:
.str " zombies="
s_code:
.str " code="
s_children:
.str " children="
s_sig:
.str " sig="
s_runv:
.str " run="
s_nl:
.str "\n"

.include "../lib/nanproc.nas"
