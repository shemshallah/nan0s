; nanthr.nas - NaN kernel thread subsystem (TCB, scheduler, sync, TLS).
;
; User side calls the frozen SVC gate: opcode 0x4E, syscall number in imm16,
; arguments in r1..r3, result in r1 (r4 and flags are clobbered).  The kernel
; side entry points take a 24-word trap frame exactly as specified in
; spec/THREADS.md.  Every production stub below executes a raw 0x4E SVC word.
;
; The cooperative mock is a NaN-only test harness.  It is installed explicitly
; with nthr_mock_install(); it enters the same kernel-side dispatch through a
; function pointer instead of the S1 trap gate, so the scheduler, queues,
; mutex/cond/TLS code and the user stubs are the exact code the kernel runs.
; No host C implements any thread policy.  When S1 exists the trap vector
; calls nthr_syscall_dispatch(frame) and the mock is not installed.
;
; ABI: r0=0 r13=1 r14=SP (grows up) r15=link.  r2..r12 survive a syscall;
; r1 is the result and r4 is clobbered.  All internal routines preserve r0=0.

; ---------------------------------------------------------------- constants
.equ NT_ST_FREE     0
.equ NT_ST_READY    1
.equ NT_ST_RUNNING  2
.equ NT_ST_BLOCKED  3
.equ NT_ST_ZOMBIE   4

.equ NT_SVC_YIELD   0
.equ NT_SVC_TIME    11
.equ NT_SVC_CREATE  13
.equ NT_SVC_JOIN    14
.equ NT_SVC_EXIT    15
.equ NT_SVC_MUTEX   16
.equ NT_SVC_COND    17
.equ NT_SVC_TLS     18
.equ NT_SVC_DETACH  19      ; append-only extension: thread_detach

.equ NT_MX_LOCK     0
.equ NT_MX_UNLOCK   1
.equ NT_MX_TRYLOCK  2
.equ NT_MX_INIT     3
.equ NT_CD_WAIT     0
.equ NT_CD_SIGNAL   1
.equ NT_CD_BCAST    2
.equ NT_CD_INIT     3
.equ NT_TLS_GET     0
.equ NT_TLS_SET     1
.equ NT_TLS_KEY     2
.equ NT_TLS_FREE    3

; TCB frame [0..23] is the trap frame: r0..r15, pc, flags/k, addrh, cause,
; syscall/imm, status, sp, reserved.  Metadata follows at word 24.
.equ NT_T_STATE     24
.equ NT_T_TID       25
.equ NT_T_STACK     26
.equ NT_T_SWORDS    27
.equ NT_T_JOINER    28
.equ NT_T_DETACH    29
.equ NT_T_EXIT      30
.equ NT_T_NEXT      31      ; ready-queue link
.equ NT_T_WAITNEXT  32      ; mutex/cond wait-queue link
.equ NT_T_ARG       33
.equ NT_T_ENTRY     34
.equ NT_T_WAITMUTEX 35
.equ NT_T_AUX       36
.equ NT_T_TLS       37      ; 16 TLS values: 37..52
.equ NT_T_LINK      53      ; saved user r15 for the mock syscall return
.equ NT_T_SIZE      56

.equ NT_M_OWNER     0
.equ NT_M_HEAD      1
.equ NT_M_TAIL      2
.equ NT_M_COUNT     3
.equ NT_C_HEAD      0
.equ NT_C_TAIL      1

.equ NT_TLS_KEYS    16

; scheduler globals (g-word offsets from nthr_globals)
.equ NT_G_CUR       0
.equ NT_G_HEAD      1
.equ NT_G_TAIL      2
.equ NT_G_NEXT_TID  3
.equ NT_G_TICKS     4
.equ NT_G_SLICE     5
.equ NT_G_QUANTUM   6
.equ NT_G_PENDING   7
.equ NT_G_TRAP      8
.equ NT_G_STACK_NEXT 9
.equ NT_G_STACK_SIZE 10
.equ NT_G_STACK_LIMIT 11
.equ NT_G_TCB_BASE  12
.equ NT_G_TCB_COUNT 13
.equ NT_G_NEXT      14
.equ NT_G_A         15
.equ NT_G_B         16
.equ NT_G_C         17
.equ NT_G_D         18
.equ NT_G_E         19
.equ NT_G_FRAME     20
.equ NT_G_FENCE     21
.equ NT_G_TLS_BASE  22      ; 16 key words: 22..37
.equ NT_G_KSTACK    38      ; mock/trap kernel stack base
.equ NT_G_STACK_FREE 39     ; LIFO list of free stack regions
.equ NT_G_KFRAME    40      ; S1 trap-frame pointer while inside dispatch
.equ NT_G_OLDCUR    41      ; current TCB before a frame-mode switch
.equ NT_NGLOB       42

.equ NT_QUANTUM     8
.equ NT_STACK_MAGIC 0x4E544847

; ---------------------------------------------------------------- user stubs
; The mock path saves the user's r15 in NT_T_LINK and returns through
; nthr_sysret, so no user stack word is used by the switch machinery.  r4 is
; the only scratch register; production leaves r0=0 and executes SVC imm.
nthr_yield:
LA r0,@nthr_globals
LD r4,r0,#NT_G_CUR
ST r15,r4,#NT_T_LINK
LD r0,r0,#NT_G_TRAP
MOVI r4,0
CMP r0,r4
JMP[NE] @nthr_yield_mock
SVC 0
RET
nthr_yield_mock:
MOVI r4,#NT_SVC_YIELD
CALLR r0
RET

nthr_create:
LA r0,@nthr_globals
LD r4,r0,#NT_G_CUR
ST r15,r4,#NT_T_LINK
LD r0,r0,#NT_G_TRAP
MOVI r4,0
CMP r0,r4
JMP[NE] @nthr_create_mock
SVC 13
RET
nthr_create_mock:
MOVI r4,#NT_SVC_CREATE
CALLR r0
RET

nthr_join:
LA r0,@nthr_globals
LD r4,r0,#NT_G_CUR
ST r15,r4,#NT_T_LINK
LD r0,r0,#NT_G_TRAP
MOVI r4,0
CMP r0,r4
JMP[NE] @nthr_join_mock
SVC 14
RET
nthr_join_mock:
MOVI r4,#NT_SVC_JOIN
CALLR r0
RET

nthr_exit:
LA r0,@nthr_globals
LD r4,r0,#NT_G_CUR
ST r15,r4,#NT_T_LINK
LD r0,r0,#NT_G_TRAP
MOVI r4,0
CMP r0,r4
JMP[NE] @nthr_exit_mock
SVC 15
RET
nthr_exit_mock:
MOVI r4,#NT_SVC_EXIT
CALLR r0
RET

nthr_mutex:
LA r0,@nthr_globals
LD r4,r0,#NT_G_CUR
ST r15,r4,#NT_T_LINK
LD r0,r0,#NT_G_TRAP
MOVI r4,0
CMP r0,r4
JMP[NE] @nthr_mutex_mock
SVC 16
RET
nthr_mutex_mock:
MOVI r4,#NT_SVC_MUTEX
CALLR r0
RET

nthr_cond:
LA r0,@nthr_globals
LD r4,r0,#NT_G_CUR
ST r15,r4,#NT_T_LINK
LD r0,r0,#NT_G_TRAP
MOVI r4,0
CMP r0,r4
JMP[NE] @nthr_cond_mock
SVC 17
RET
nthr_cond_mock:
MOVI r4,#NT_SVC_COND
CALLR r0
RET

nthr_tls:
LA r0,@nthr_globals
LD r4,r0,#NT_G_CUR
ST r15,r4,#NT_T_LINK
LD r0,r0,#NT_G_TRAP
MOVI r4,0
CMP r0,r4
JMP[NE] @nthr_tls_mock
SVC 18
RET
nthr_tls_mock:
MOVI r4,#NT_SVC_TLS
CALLR r0
RET

nthr_detach:
LA r0,@nthr_globals
LD r4,r0,#NT_G_CUR
ST r15,r4,#NT_T_LINK
LD r0,r0,#NT_G_TRAP
MOVI r4,0
CMP r0,r4
JMP[NE] @nthr_detach_mock
SVC 19
RET
nthr_detach_mock:
MOVI r4,#NT_SVC_DETACH
CALLR r0
RET

; ---- convenience wrappers (same SVC numbers) -----------------------
nthr_lock:                    ; r1=mutex -> r1=0/1/-1
ADD r2,r1,r0
MOVI r1,#NT_MX_LOCK
JMP @nthr_mutex

nthr_unlock:                  ; r1=mutex -> r1=0/-1
ADD r2,r1,r0
MOVI r1,#NT_MX_UNLOCK
JMP @nthr_mutex

nthr_trylock:                 ; r1=mutex -> r1=0/1/-1
ADD r2,r1,r0
MOVI r1,#NT_MX_TRYLOCK
JMP @nthr_mutex

nthr_mutex_init:              ; r1=mutex
ADD r2,r1,r0
MOVI r1,#NT_MX_INIT
JMP @nthr_mutex

nthr_cond_wait:               ; r1=cond r2=mutex
ADD r3,r2,r0
ADD r2,r1,r0
MOVI r1,#NT_CD_WAIT
JMP @nthr_cond

nthr_cond_signal:             ; r1=cond
ADD r2,r1,r0
MOVI r1,#NT_CD_SIGNAL
MOVI r3,0
JMP @nthr_cond

nthr_cond_broadcast:          ; r1=cond
ADD r2,r1,r0
MOVI r1,#NT_CD_BCAST
MOVI r3,0
JMP @nthr_cond

nthr_cond_init:               ; r1=cond
ADD r2,r1,r0
MOVI r1,#NT_CD_INIT
MOVI r3,0
JMP @nthr_cond

nthr_tls_get:                 ; r1=key -> r1=value
ADD r2,r1,r0
MOVI r1,#NT_TLS_GET
MOVI r3,0
JMP @nthr_tls

nthr_tls_set:                 ; r1=key r2=value -> r1=0
ADD r3,r2,r0
ADD r2,r1,r0
MOVI r1,#NT_TLS_SET
JMP @nthr_tls

nthr_tls_key_create:          ; -> r1=key or -1
MOVI r1,#NT_TLS_KEY
MOVI r2,0
MOVI r3,0
JMP @nthr_tls

nthr_tls_key_free:            ; r1=key
ADD r2,r1,r0
MOVI r1,#NT_TLS_FREE
MOVI r3,0
JMP @nthr_tls

; ---------------------------------------------------------------- new thread
nthr_tramp:
CALLR r2                     ; r2=entry, r1=arg
CALL @nthr_exit              ; r1=return value
HALT

; syscall return used by the cooperative mock: restore the user's r15 from
; the TCB and return to the instruction after the stub call.
nthr_sysret:
LA r0,@nthr_globals
LD r0,r0,#NT_G_CUR
LD r15,r0,#NT_T_LINK
MOVI r0,0
RET

; ---------------------------------------------------------------- S1 entry
; nthr_syscall_dispatch(frame): called by the SVC vector with r1 pointing at
; the 24-word trap frame.  The frame is copied into the current TCB, the
; common dispatcher runs, and nthr_restore copies the selected TCB frame
; back over the vector's frame.  r1=1 means the vector should SVCRET with the
; (possibly replaced) frame; 0 means the same frame is still current.
nthr_syscall_dispatch:
ST r15,r14,0
ADD r14,r14,r13
LA r2,@nthr_globals
ST r1,r2,#NT_G_KFRAME
LD r3,r2,#NT_G_CUR
ST r3,r2,#NT_G_OLDCUR
MOVI r4,#NT_ST_RUNNING
ST r4,r3,#NT_T_STATE
MOVI r4,24
BCOPY r3,r1,r4
LD r4,r3,20
JMP @nthr_dispatch

; ---------------------------------------------------------------- mock entry
; r0 is the installed mock pointer at entry; r1..r3 are syscall arguments,
; r4 is the syscall number, r14/r15 are the thread's live stack/link.  Save
; the trap frame, then run the same kernel dispatch as the S1 vector.
nthr_mock_entry:
LA r0,@nthr_globals
LD r0,r0,#NT_G_CUR
ST r1,r0,1
ST r2,r0,2
ST r3,r0,3
ST r4,r0,4
ST r5,r0,5
ST r6,r0,6
ST r7,r0,7
ST r8,r0,8
ST r9,r0,9
ST r10,r0,10
ST r11,r0,11
ST r12,r0,12
ST r13,r0,13
ST r14,r0,14
ST r15,r0,15
LA r1,@nthr_sysret
ST r1,r0,16
ST r14,r0,22
ST r4,r0,19
ST r4,r0,20
MOVI r1,0
ST r1,r0,0
ST r1,r0,17
ST r1,r0,18
ST r1,r0,21
ST r1,r0,23
LA r1,@nthr_globals
LD r1,r1,#NT_G_KSTACK
ADD r14,r1,r0
MOVI r0,0
nthr_dispatch:
MOVI r1,#NT_SVC_YIELD
CMP r4,r1
JMP[EQ] @nthr_md_yield
MOVI r1,#NT_SVC_CREATE
CMP r4,r1
JMP[EQ] @nthr_md_create
MOVI r1,#NT_SVC_JOIN
CMP r4,r1
JMP[EQ] @nthr_md_join
MOVI r1,#NT_SVC_EXIT
CMP r4,r1
JMP[EQ] @nthr_md_exit
MOVI r1,#NT_SVC_MUTEX
CMP r4,r1
JMP[EQ] @nthr_md_mutex
MOVI r1,#NT_SVC_COND
CMP r4,r1
JMP[EQ] @nthr_md_cond
MOVI r1,#NT_SVC_TLS
CMP r4,r1
JMP[EQ] @nthr_md_tls
MOVI r1,#NT_SVC_DETACH
CMP r4,r1
JMP[EQ] @nthr_md_detach
; unknown syscall: return -1
LA r1,0xFFFFFFFF
LA r6,@nthr_globals
LD r6,r6,#NT_G_CUR
ST r1,r6,1
JMP @nthr_resched

nthr_md_yield:
LA r6,@nthr_globals
LD r6,r6,#NT_G_CUR
ST r0,r6,1
MOVI r3,#NT_ST_READY
ST r3,r6,#NT_T_STATE
ADD r2,r6,r0
CALL @nthr_enqueue
JMP @nthr_resched

nthr_md_create:
LA r6,@nthr_globals
LD r6,r6,#NT_G_CUR
LD r1,r6,1
LD r2,r6,2
LD r3,r6,3
CALL @nthr_do_create
LA r6,@nthr_globals
LD r6,r6,#NT_G_CUR
ST r1,r6,1
JMP @nthr_resched

nthr_md_join:
LA r6,@nthr_globals
LD r6,r6,#NT_G_CUR
LD r1,r6,1
CALL @nthr_do_join
JMP @nthr_resched

nthr_md_exit:
LA r6,@nthr_globals
LD r6,r6,#NT_G_CUR
LD r1,r6,1
CALL @nthr_do_exit
JMP @nthr_resched

nthr_md_mutex:
LA r6,@nthr_globals
LD r6,r6,#NT_G_CUR
LD r1,r6,1
LD r2,r6,2
CALL @nthr_do_mutex
LA r6,@nthr_globals
LD r6,r6,#NT_G_CUR
ST r1,r6,1
JMP @nthr_resched

nthr_md_cond:
LA r6,@nthr_globals
LD r6,r6,#NT_G_CUR
LD r1,r6,1
LD r2,r6,2
LD r3,r6,3
CALL @nthr_do_cond
LA r6,@nthr_globals
LD r6,r6,#NT_G_CUR
ST r1,r6,1
JMP @nthr_resched

nthr_md_tls:
LA r6,@nthr_globals
LD r6,r6,#NT_G_CUR
LD r1,r6,1
LD r2,r6,2
LD r3,r6,3
CALL @nthr_do_tls
LA r6,@nthr_globals
LD r6,r6,#NT_G_CUR
ST r1,r6,1
JMP @nthr_resched

nthr_md_detach:
LA r6,@nthr_globals
LD r6,r6,#NT_G_CUR
LD r1,r6,1
CALL @nthr_do_detach
LA r6,@nthr_globals
LD r6,r6,#NT_G_CUR
ST r1,r6,1
JMP @nthr_resched

; ---------------------------------------------------------------- scheduler
nthr_resched:
LA r1,@nthr_globals
LD r2,r1,#NT_G_CUR
LD r3,r2,#NT_T_STATE
MOVI r4,#NT_ST_RUNNING
CMP r3,r4
JMP[NE] @nthr_resched_pick
ST r2,r1,#NT_G_NEXT
JMP @nthr_restore
nthr_resched_pick:
CALL @nthr_pick
JMP @nthr_restore

; pick the ready-queue head, mark it running and make it current
nthr_pick:
LA r1,@nthr_globals
LD r2,r1,#NT_G_HEAD
CMP r2,r0
JMP[EQ] @nthr_pick_empty
LD r3,r2,#NT_T_NEXT
ST r3,r1,#NT_G_HEAD
CMP r3,r0
JMP[NE] @nthr_pick_pop
ST r0,r1,#NT_G_TAIL
nthr_pick_pop:
ST r0,r2,#NT_T_NEXT
MOVI r3,#NT_ST_RUNNING
ST r3,r2,#NT_T_STATE
ST r2,r1,#NT_G_CUR
ST r2,r1,#NT_G_NEXT
ST r0,r1,#NT_G_PENDING
LD r3,r1,#NT_G_QUANTUM
ST r3,r1,#NT_G_SLICE
RET
nthr_pick_empty:
LD r2,r1,#NT_G_CUR
LD r3,r2,#NT_T_STATE
MOVI r4,#NT_ST_RUNNING
CMP r3,r4
JMP[EQ] @nthr_pick_same
JMP @nthr_dead
nthr_pick_same:
ST r2,r1,#NT_G_NEXT
RET

; append tcb r2 to the ready queue
nthr_enqueue:
LA r1,@nthr_globals
ST r0,r2,#NT_T_NEXT
LD r3,r1,#NT_G_TAIL
CMP r3,r0
JMP[EQ] @nthr_enq_empty
ST r2,r3,#NT_T_NEXT
ST r2,r1,#NT_G_TAIL
RET
nthr_enq_empty:
ST r2,r1,#NT_G_HEAD
ST r2,r1,#NT_G_TAIL
RET

; restore the frame selected by NT_G_NEXT.  [16] is the resume pc; r0 is
; rebuilt as the constant zero after the last use of a base register.
nthr_restore:
LA r0,@nthr_globals
LD r1,r0,#NT_G_KFRAME
MOVI r5,0
CMP r1,r5
JMP[NE] @nthr_restore_frame
LD r0,r0,#NT_G_NEXT
BOOL.8 r0,r0,r0
JMP[EQ] @nthr_dead
LD r1,r0,1
LD r2,r0,2
LD r3,r0,3
LD r4,r0,4
LD r5,r0,5
LD r6,r0,6
LD r7,r0,7
LD r8,r0,8
LD r9,r0,9
LD r10,r0,10
LD r11,r0,11
LD r12,r0,12
LD r13,r0,13
LD r14,r0,14
LD r15,r0,16
MOVI r0,0
RET
nthr_restore_frame:
LD r2,r0,#NT_G_NEXT
MOVI r3,24
BCOPY r1,r2,r3
; Production SVC return: SVCRET reads frame[21], while the dispatcher keeps
; the syscall result in r1 (TCB frame[1]).  Mirror it for the S1 vector.
LD r3,r2,1
ST r3,r1,21
LD r4,r0,#NT_G_OLDCUR
CMP r2,r4
MOVI r1,0
MOVI[NE] r1,1
MOVI r5,0
ST r5,r0,#NT_G_KFRAME
SUB r14,r14,r13
LD r15,r14,0
MOVI r0,0
RET

nthr_dead:
MOVI r1,33
PUTC r1
MOVI r1,68
PUTC r1
MOVI r1,10
PUTC r1
HALT

; ---------------------------------------------------------------- wait queues
; r1 = address of a {head,tail} pair, r2 = tcb.  Uses NT_T_WAITNEXT.
nthr_q_append:
LD r3,r1,0
CMP r3,r0
JMP[EQ] @nthr_qa_empty
LD r4,r1,1
ST r2,r4,#NT_T_WAITNEXT
ST r2,r1,1
ST r0,r2,#NT_T_WAITNEXT
RET
nthr_qa_empty:
ST r2,r1,0
ST r2,r1,1
ST r0,r2,#NT_T_WAITNEXT
RET

; r1 = address of a {head,tail} pair -> r1 = tcb or 0
nthr_q_pop:
LD r2,r1,0
CMP r2,r0
JMP[EQ] @nthr_qp_none
LD r3,r2,#NT_T_WAITNEXT
ST r3,r1,0
CMP r3,r0
JMP[NE] @nthr_qp_have
ST r0,r1,1
nthr_qp_have:
ST r0,r2,#NT_T_WAITNEXT
ADD r1,r2,r0
RET
nthr_qp_none:
MOVI r1,0
RET

; ---------------------------------------------------------------- create/exit
nthr_do_create:
; r1=entry r2=stack base or 0 r3=arg -> r1=tid or 0
ST r15,r14,0
ADD r14,r14,r13
LA r6,@nthr_globals
ST r1,r6,#NT_G_A
ST r2,r6,#NT_G_B
ST r3,r6,#NT_G_C
LD r7,r6,#NT_G_TCB_BASE
LD r8,r6,#NT_G_TCB_COUNT
MOVI r9,#NT_T_SIZE
MOVI r10,0
nthr_dc_scan:
CMP r10,r8
JMP[GE] @nthr_dc_fail
LD r11,r7,#NT_T_STATE
CMP r11,r0
JMP[EQ] @nthr_dc_found
ADD r7,r7,r9
ADD r10,r10,r13
JMP @nthr_dc_scan
nthr_dc_found:
ST r7,r6,#NT_G_D
LD r2,r6,#NT_G_B
CMP r2,r0
JMP[NE] @nthr_dc_stack
CALL @nthr_stack_alloc
CMP r1,r0
JMP[EQ] @nthr_dc_fail
ADD r2,r1,r0
nthr_dc_stack:
LA r6,@nthr_globals
ST r2,r6,#NT_G_E
LD r7,r6,#NT_G_D
MOVI r8,#NT_T_SIZE
BFILL r7,r0,r8
LD r9,r6,#NT_G_NEXT_TID
ADD r10,r9,r13
ST r10,r6,#NT_G_NEXT_TID
ST r9,r7,#NT_T_TID
MOVI r10,#NT_ST_READY
ST r10,r7,#NT_T_STATE
LD r2,r6,#NT_G_E
ST r2,r7,#NT_T_STACK
LD r10,r6,#NT_G_STACK_SIZE
ST r10,r7,#NT_T_SWORDS
LD r10,r6,#NT_G_B
CMP r10,r0
JMP[NE] @nthr_dc_provided
MOVI r10,1
ST r10,r7,#NT_T_AUX
nthr_dc_provided:
LD r1,r6,#NT_G_A
ST r1,r7,#NT_T_ENTRY
LD r3,r6,#NT_G_C
ST r3,r7,#NT_T_ARG
; initial trap frame: r1=arg, r2=entry, sp=stack, pc=tramp
ST r3,r7,1
ST r1,r7,2
ST r2,r7,14
ST r2,r7,22
MOVI r10,1
ST r10,r7,13
LA r10,@nthr_tramp
ST r10,r7,15
ST r10,r7,16
ADD r2,r7,r0
CALL @nthr_enqueue
LA r6,@nthr_globals
LD r7,r6,#NT_G_D
LD r1,r7,#NT_T_TID
JMP @nthr_dc_done
nthr_dc_fail:
MOVI r1,0
nthr_dc_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; allocate one stack region: guard, stack[0..size-1], guard.  r1 = base or 0
nthr_stack_alloc:
LA r6,@nthr_globals
LD r2,r6,#NT_G_STACK_SIZE
LD r1,r6,#NT_G_STACK_FREE
CMP r1,r0
JMP[EQ] @nthr_sa_bump
LD r9,r1,0
ST r9,r6,#NT_G_STACK_FREE
ADD r7,r1,r13
ADD r8,r7,r2
LA r5,#NT_STACK_MAGIC
ST r5,r1,0
ST r5,r8,0
ADD r1,r7,r0
RET
nthr_sa_bump:
LD r1,r6,#NT_G_STACK_NEXT
LD r3,r6,#NT_G_STACK_LIMIT
ADD r4,r1,r2
ADD r4,r4,r13
CMP r4,r3
JMP[GT] @nthr_sa_fail
LA r5,#NT_STACK_MAGIC
ST r5,r1,0
ADD r7,r1,r13
ADD r8,r7,r2
ST r5,r8,0
ADD r9,r8,r13
ST r9,r6,#NT_G_STACK_NEXT
ADD r1,r7,r0
RET
nthr_sa_fail:
MOVI r1,0
RET

; r1=tcb -> return its kernel-allocated stack region to the free list
nthr_stack_free:
ADD r2,r1,r0
LD r3,r2,#NT_T_AUX
CMP r3,r0
RET[EQ]
LD r4,r2,#NT_T_STACK
CMP r4,r0
RET[EQ]
SUB r5,r4,r13
LA r6,@nthr_globals
LD r7,r6,#NT_G_STACK_FREE
ST r7,r5,0
ST r5,r6,#NT_G_STACK_FREE
ST r0,r2,#NT_T_STACK
ST r0,r2,#NT_T_AUX
RET

nthr_do_exit:
; r1=exit code
ST r15,r14,0
ADD r14,r14,r13
LA r6,@nthr_globals
LD r2,r6,#NT_G_CUR
ST r1,r2,#NT_T_EXIT
LD r3,r2,#NT_T_JOINER
CMP r3,r0
JMP[EQ] @nthr_ex_nojoin
ST r1,r3,1
ST r0,r3,#NT_T_JOINER
MOVI r4,#NT_ST_READY
ST r4,r3,#NT_T_STATE
ADD r2,r3,r0
CALL @nthr_enqueue
LA r6,@nthr_globals
LD r2,r6,#NT_G_CUR
JMP @nthr_ex_free
nthr_ex_nojoin:
LD r3,r2,#NT_T_DETACH
CMP r3,r0
JMP[NE] @nthr_ex_free
MOVI r3,#NT_ST_ZOMBIE
ST r3,r2,#NT_T_STATE
JMP @nthr_ex_done
nthr_ex_free:
ST r2,r6,#NT_G_E
ADD r1,r2,r0
CALL @nthr_stack_free
LA r6,@nthr_globals
LD r2,r6,#NT_G_E
MOVI r3,#NT_ST_FREE
ST r3,r2,#NT_T_STATE
ST r0,r2,#NT_T_TID
nthr_ex_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; r1=tid -> r1=tcb or 0; skips FREE slots
nthr_find:
LA r2,@nthr_globals
LD r3,r2,#NT_G_TCB_BASE
LD r4,r2,#NT_G_TCB_COUNT
MOVI r5,#NT_T_SIZE
MOVI r6,0
nthr_f_loop:
CMP r6,r4
JMP[GE] @nthr_f_none
LD r7,r3,#NT_T_STATE
CMP r7,r0
JMP[EQ] @nthr_f_next
LD r7,r3,#NT_T_TID
CMP r7,r1
JMP[EQ] @nthr_f_ok
nthr_f_next:
ADD r3,r3,r5
ADD r6,r6,r13
JMP @nthr_f_loop
nthr_f_ok:
ADD r1,r3,r0
RET
nthr_f_none:
MOVI r1,0
RET

nthr_do_join:
; r1=tid
ST r15,r14,0
ADD r14,r14,r13
LA r6,@nthr_globals
LD r2,r6,#NT_G_CUR
LD r3,r2,#NT_T_TID
CMP r1,r3
JMP[EQ] @nthr_j_err
ST r1,r6,#NT_G_A
CALL @nthr_find
CMP r1,r0
JMP[EQ] @nthr_j_err
ADD r3,r1,r0
LA r6,@nthr_globals
LD r4,r3,#NT_T_DETACH
CMP r4,r0
JMP[NE] @nthr_j_err
LD r5,r3,#NT_T_STATE
MOVI r7,#NT_ST_ZOMBIE
CMP r5,r7
JMP[EQ] @nthr_j_reap
LD r2,r6,#NT_G_CUR
ST r2,r3,#NT_T_JOINER
MOVI r4,#NT_ST_BLOCKED
ST r4,r2,#NT_T_STATE
JMP @nthr_j_done
nthr_j_reap:
LD r1,r3,#NT_T_EXIT
ST r1,r6,#NT_G_E
ST r3,r6,#NT_G_D
ADD r1,r3,r0
CALL @nthr_stack_free
LA r6,@nthr_globals
LD r3,r6,#NT_G_D
LD r1,r6,#NT_G_E
MOVI r4,#NT_ST_FREE
ST r4,r3,#NT_T_STATE
ST r0,r3,#NT_T_TID
LD r2,r6,#NT_G_CUR
ST r1,r2,1
JMP @nthr_j_done
nthr_j_err:
LA r1,0xFFFFFFFF
LA r6,@nthr_globals
LD r2,r6,#NT_G_CUR
ST r1,r2,1
nthr_j_done:
SUB r14,r14,r13
LD r15,r14,0
RET

nthr_do_detach:
; r1=tid -> r1=0/-1
ST r15,r14,0
ADD r14,r14,r13
LA r6,@nthr_globals
ST r1,r6,#NT_G_A
CALL @nthr_find
CMP r1,r0
JMP[EQ] @nthr_det_err
ADD r3,r1,r0
LA r6,@nthr_globals
LD r4,r3,#NT_T_STATE
MOVI r5,#NT_ST_ZOMBIE
CMP r4,r5
JMP[EQ] @nthr_det_free
MOVI r4,1
ST r4,r3,#NT_T_DETACH
MOVI r1,0
JMP @nthr_det_done
nthr_det_free:
ST r3,r6,#NT_G_D
ADD r1,r3,r0
CALL @nthr_stack_free
LA r6,@nthr_globals
LD r3,r6,#NT_G_D
MOVI r4,#NT_ST_FREE
ST r4,r3,#NT_T_STATE
ST r0,r3,#NT_T_TID
MOVI r1,0
JMP @nthr_det_done
nthr_det_err:
LA r1,0xFFFFFFFF
nthr_det_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; ---------------------------------------------------------------- mutex
nthr_do_mutex:
; r1=op r2=addr -> r1=result
LA r6,@nthr_globals
ST r1,r6,#NT_G_A
ST r2,r6,#NT_G_B
CMP r1,r0
JMP[EQ] @nthr_mx_lock
MOVI r3,#NT_MX_UNLOCK
CMP r1,r3
JMP[EQ] @nthr_mx_unlock
MOVI r3,#NT_MX_TRYLOCK
CMP r1,r3
JMP[EQ] @nthr_mx_trylock
MOVI r3,#NT_MX_INIT
CMP r1,r3
JMP[EQ] @nthr_mx_init
JMP @nthr_mx_err

nthr_mx_init:
LD r2,r6,#NT_G_B
CMP r2,r0
JMP[EQ] @nthr_mx_err
MOVI r3,4
BFILL r2,r0,r3
MOVI r1,0
RET

nthr_mx_lock:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r6,#NT_G_B
CMP r2,r0
JMP[EQ] @nthr_mx_err
LD r3,r2,#NT_M_OWNER
CMP r3,r0
JMP[NE] @nthr_mx_l_owned
JMP @nthr_mx_l_acquire
nthr_mx_l_owned:
LD r4,r6,#NT_G_CUR
LD r5,r4,#NT_T_TID
CMP r3,r5
JMP[EQ] @nthr_mx_l_rec
JMP @nthr_mx_l_block
nthr_mx_l_acquire:
LD r4,r6,#NT_G_CUR
LD r5,r4,#NT_T_TID
ADD r1,r2,r0
MOVI r2,0
ADD r3,r5,r0
CALL @nthr_atomic_cas
CMP r1,r0
JMP[NE] @nthr_mx_l_block
LA r6,@nthr_globals
LD r2,r6,#NT_G_B
MOVI r3,1
ST r3,r2,#NT_M_COUNT
MOVI r1,0
JMP @nthr_mx_done
nthr_mx_l_rec:
LD r7,r2,#NT_M_COUNT
ADD r7,r7,r13
ST r7,r2,#NT_M_COUNT
MOVI r1,0
JMP @nthr_mx_done
nthr_mx_l_block:
LA r6,@nthr_globals
LD r2,r6,#NT_G_B
LD r4,r6,#NT_G_CUR
ST r0,r4,1
ADD r1,r2,r13
ADD r2,r4,r0
CALL @nthr_q_append
LA r6,@nthr_globals
LD r4,r6,#NT_G_CUR
MOVI r3,#NT_ST_BLOCKED
ST r3,r4,#NT_T_STATE
MOVI r1,0
JMP @nthr_mx_done

nthr_mx_trylock:
ST r15,r14,0
ADD r14,r14,r13
LD r2,r6,#NT_G_B
CMP r2,r0
JMP[EQ] @nthr_mx_err
LD r3,r2,#NT_M_OWNER
CMP r3,r0
JMP[NE] @nthr_mx_t_owned
JMP @nthr_mx_t_acquire
nthr_mx_t_owned:
LD r4,r6,#NT_G_CUR
LD r5,r4,#NT_T_TID
CMP r3,r5
JMP[EQ] @nthr_mx_l_rec
MOVI r1,1
RET
nthr_mx_t_acquire:
LD r4,r6,#NT_G_CUR
LD r5,r4,#NT_T_TID
ADD r1,r2,r0
MOVI r2,0
ADD r3,r5,r0
CALL @nthr_atomic_cas
CMP r1,r0
JMP[NE] @nthr_mx_t_busy
LA r6,@nthr_globals
LD r2,r6,#NT_G_B
MOVI r3,1
ST r3,r2,#NT_M_COUNT
MOVI r1,0
JMP @nthr_mx_done
nthr_mx_t_busy:
MOVI r1,1
nthr_mx_done:
SUB r14,r14,r13
LD r15,r14,0
RET

nthr_mx_unlock:
LD r2,r6,#NT_G_B
CMP r2,r0
JMP[EQ] @nthr_mx_err
LD r4,r6,#NT_G_CUR
LD r5,r4,#NT_T_TID
LD r3,r2,#NT_M_OWNER
CMP r3,r5
JMP[NE] @nthr_mx_err
ADD r1,r2,r0
JMP @nthr_mx_release

; r1=mutex addr, caller owns it -> r1=0/-1.  Decrements recursion; when the
; count reaches zero transfers ownership to the first waiter, or frees it.
nthr_mx_release:
ST r15,r14,0
ADD r14,r14,r13
LA r6,@nthr_globals
ST r1,r6,#NT_G_E
ADD r2,r1,r0
LD r7,r2,#NT_M_COUNT
CMP r7,r0
JMP[EQ] @nthr_mxr_err
LD r4,r2,#NT_M_OWNER
SUB r7,r7,r13
CMP r7,r0
JMP[NE] @nthr_mxr_dec
ST r0,r2,#NT_M_COUNT
ST r0,r2,#NT_M_OWNER
ADD r1,r2,r13
CALL @nthr_q_pop
CMP r1,r0
JMP[EQ] @nthr_mxr_ok
ADD r3,r1,r0
LD r5,r3,#NT_T_TID
LA r6,@nthr_globals
LD r2,r6,#NT_G_E
ST r5,r2,#NT_M_OWNER
MOVI r5,1
ST r5,r2,#NT_M_COUNT
ST r0,r3,1
MOVI r5,#NT_ST_READY
ST r5,r3,#NT_T_STATE
ADD r2,r3,r0
CALL @nthr_enqueue
nthr_mxr_ok:
MOVI r1,0
JMP @nthr_mxr_done
nthr_mxr_dec:
ST r7,r2,#NT_M_COUNT
MOVI r1,0
JMP @nthr_mxr_done
nthr_mxr_err:
LA r1,0xFFFFFFFF
nthr_mxr_done:
SUB r14,r14,r13
LD r15,r14,0
RET
nthr_mx_err:
LA r1,0xFFFFFFFF
RET

; ---------------------------------------------------------------- cond
nthr_do_cond:
; r1=op r2=cond addr r3=mutex addr -> r1=result
ST r15,r14,0
ADD r14,r14,r13
LA r6,@nthr_globals
ST r1,r6,#NT_G_A
ST r2,r6,#NT_G_B
ST r3,r6,#NT_G_C
CMP r1,r0
JMP[EQ] @nthr_cd_wait
MOVI r4,#NT_CD_SIGNAL
CMP r1,r4
JMP[EQ] @nthr_cd_signal
MOVI r4,#NT_CD_BCAST
CMP r1,r4
JMP[EQ] @nthr_cd_bcast
MOVI r4,#NT_CD_INIT
CMP r1,r4
JMP[EQ] @nthr_cd_init
JMP @nthr_cd_err

nthr_cd_init:
LD r2,r6,#NT_G_B
CMP r2,r0
JMP[EQ] @nthr_cd_err
MOVI r3,2
BFILL r2,r0,r3
MOVI r1,0
JMP @nthr_cd_done

nthr_cd_wait:
LD r2,r6,#NT_G_B
LD r3,r6,#NT_G_C
CMP r2,r0
JMP[EQ] @nthr_cd_err
CMP r3,r0
JMP[EQ] @nthr_cd_err
LD r4,r6,#NT_G_CUR
LD r5,r4,#NT_T_TID
LD r7,r3,#NT_M_OWNER
CMP r7,r5
JMP[NE] @nthr_cd_err
LD r7,r3,#NT_M_COUNT
CMP r7,r13
JMP[NE] @nthr_cd_err
ST r3,r4,#NT_T_WAITMUTEX
ST r0,r4,1
ADD r1,r2,r0
ADD r2,r4,r0
CALL @nthr_q_append
LA r6,@nthr_globals
LD r4,r6,#NT_G_CUR
MOVI r7,#NT_ST_BLOCKED
ST r7,r4,#NT_T_STATE
LD r1,r6,#NT_G_C
CALL @nthr_mx_release
MOVI r1,0
JMP @nthr_cd_done

nthr_cd_signal:
LD r1,r6,#NT_G_B
CMP r1,r0
JMP[EQ] @nthr_cd_err
CALL @nthr_cond_wake_one
MOVI r1,0
JMP @nthr_cd_done

nthr_cd_bcast:
LD r2,r6,#NT_G_B
CMP r2,r0
JMP[EQ] @nthr_cd_err
nthr_cd_b_loop:
ADD r1,r2,r0
CALL @nthr_cond_wake_one
CMP r1,r0
JMP[EQ] @nthr_cd_b_done
LA r6,@nthr_globals
LD r2,r6,#NT_G_B
JMP @nthr_cd_b_loop
nthr_cd_b_done:
MOVI r1,0
JMP @nthr_cd_done

; r1=cond addr -> r1=1 woke one, 0 empty.  A waiter that had released a
; mutex is moved to that mutex's wait queue (or granted it when free), so it
; resumes owning the mutex exactly as pthread_cond_wait requires.
nthr_cond_wake_one:
ST r15,r14,0
ADD r14,r14,r13
LA r6,@nthr_globals
ST r1,r6,#NT_G_D
CALL @nthr_q_pop
CMP r1,r0
JMP[EQ] @nthr_cw_none
ADD r2,r1,r0
ST r0,r2,1
LD r4,r2,#NT_T_WAITMUTEX
ST r0,r2,#NT_T_WAITMUTEX
CMP r4,r0
JMP[EQ] @nthr_cw_wake
LD r5,r4,#NT_M_OWNER
CMP r5,r0
JMP[NE] @nthr_cw_requeue
LD r5,r2,#NT_T_TID
ST r5,r4,#NT_M_OWNER
MOVI r5,1
ST r5,r4,#NT_M_COUNT
nthr_cw_wake:
MOVI r5,#NT_ST_READY
ST r5,r2,#NT_T_STATE
CALL @nthr_enqueue
MOVI r1,1
JMP @nthr_cw_done
nthr_cw_requeue:
ADD r1,r4,r13
CALL @nthr_q_append
MOVI r1,1
JMP @nthr_cw_done
nthr_cw_none:
MOVI r1,0
nthr_cw_done:
SUB r14,r14,r13
LD r15,r14,0
RET
nthr_cd_err:
LA r1,0xFFFFFFFF
nthr_cd_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; ---------------------------------------------------------------- TLS
nthr_do_tls:
; r1=op r2=key r3=value -> r1=result
LA r6,@nthr_globals
ST r1,r6,#NT_G_A
ST r2,r6,#NT_G_B
ST r3,r6,#NT_G_C
CMP r1,r0
JMP[EQ] @nthr_tls_get_h
MOVI r4,#NT_TLS_SET
CMP r1,r4
JMP[EQ] @nthr_tls_set_h
MOVI r4,#NT_TLS_KEY
CMP r1,r4
JMP[EQ] @nthr_tls_key_h
MOVI r4,#NT_TLS_FREE
CMP r1,r4
JMP[EQ] @nthr_tls_free_h
JMP @nthr_tls_err
nthr_tls_get_h:
LD r2,r6,#NT_G_B
MOVI r4,#NT_TLS_KEYS
CMP r2,r4
JMP[GE] @nthr_tls_err
LD r4,r6,#NT_G_CUR
MOVI r5,#NT_T_TLS
ADD r4,r4,r5
ADD r4,r4,r2
LD r1,r4,0
RET
nthr_tls_set_h:
LD r2,r6,#NT_G_B
MOVI r4,#NT_TLS_KEYS
CMP r2,r4
JMP[GE] @nthr_tls_err
LD r4,r6,#NT_G_CUR
MOVI r5,#NT_T_TLS
ADD r4,r4,r5
ADD r4,r4,r2
LD r3,r6,#NT_G_C
ST r3,r4,0
MOVI r1,0
RET
nthr_tls_key_h:
MOVI r4,#NT_G_TLS_BASE
ADD r4,r6,r4
MOVI r5,0
nthr_tls_key_loop:
MOVI r7,#NT_TLS_KEYS
CMP r5,r7
JMP[GE] @nthr_tls_err
LD r7,r4,0
CMP r7,r0
JMP[EQ] @nthr_tls_key_free
ADD r4,r4,r13
ADD r5,r5,r13
JMP @nthr_tls_key_loop
nthr_tls_key_free:
MOVI r7,1
ST r7,r4,0
ADD r1,r5,r0
RET
nthr_tls_free_h:
LD r2,r6,#NT_G_B
MOVI r4,#NT_TLS_KEYS
CMP r2,r4
JMP[GE] @nthr_tls_err
MOVI r4,#NT_G_TLS_BASE
ADD r4,r6,r4
ADD r4,r4,r2
ST r0,r4,0
MOVI r1,0
RET
nthr_tls_err:
LA r1,0xFFFFFFFF
RET

; ---------------------------------------------------------------- kernel init
; r1=tcb base r2=tcb count r3=stack arena base r4=arena words r5=stack size
; -> r1=0 ok, -1 bad.  Slot 0 is the boot/main thread (tid 1, running).
nthr_init:
LA r6,@nthr_globals
ST r1,r6,#NT_G_TCB_BASE
ST r2,r6,#NT_G_TCB_COUNT
ST r3,r6,#NT_G_STACK_NEXT
ST r5,r6,#NT_G_STACK_SIZE
ADD r7,r3,r4
ST r7,r6,#NT_G_STACK_LIMIT
ST r0,r6,#NT_G_HEAD
ST r0,r6,#NT_G_TAIL
ST r0,r6,#NT_G_PENDING
ST r0,r6,#NT_G_TRAP
ST r0,r6,#NT_G_FENCE
ST r0,r6,#NT_G_STACK_FREE
MOVI r8,2
CMP r2,r8
JMP[LT] @nthr_init_bad
MOVI r8,#NT_T_SIZE
MUL r8,r2,r8
BFILL r1,r0,r8
; main TCB
MOVI r8,#NT_ST_RUNNING
ST r8,r1,#NT_T_STATE
MOVI r8,1
ST r8,r1,#NT_T_TID
ST r1,r6,#NT_G_CUR
ST r1,r6,#NT_G_NEXT
MOVI r8,2
ST r8,r6,#NT_G_NEXT_TID
MOVI r8,#NT_QUANTUM
ST r8,r6,#NT_G_QUANTUM
ST r8,r6,#NT_G_SLICE
MOVI r8,1
ST r8,r1,#NT_T_DETACH
LA r8,@nthr_kstack
ST r8,r6,#NT_G_KSTACK
; TLS key table
MOVI r9,#NT_G_TLS_BASE
ADD r8,r6,r9
MOVI r9,#NT_TLS_KEYS
BFILL r8,r0,r9
MOVI r1,0
RET
nthr_init_bad:
LA r1,0xFFFFFFFF
RET

nthr_mock_install:
LA r1,@nthr_globals
LA r2,@nthr_mock_entry
ST r2,r1,#NT_G_TRAP
MOVI r1,0
RET

nthr_mock_uninstall:
LA r1,@nthr_globals
ST r0,r1,#NT_G_TRAP
MOVI r1,0
RET

nthr_self:
LA r1,@nthr_globals
LD r1,r1,#NT_G_CUR
LD r1,r1,#NT_T_TID
RET

; ---------------------------------------------------------------- atomics/fence
; Cooperative mock: the scheduler runs one thread at a time, so these plain
; accesses are sequentially consistent.  On SMP the bodies are the single
; replacement point for the S1 0x41-0x44 atomic family; no policy lives here.
nthr_atomic_load:
LD r1,r1,0
RET

nthr_atomic_store:
ST r2,r1,0
ADD r1,r2,r0
RET

nthr_atomic_exch:
LD r3,r1,0
ST r2,r1,0
ADD r1,r3,r0
RET

; r1=addr r2=expected r3=new -> r1=old value; success iff old==expected
nthr_atomic_cas:
ADD r4,r1,r0
LD r1,r4,0
CMP r1,r2
JMP[NE] @nthr_cas_done
ST r3,r4,0
nthr_cas_done:
RET

; optional kernel fence hook: NT_G_FENCE points at the S1 fence sequence
nthr_fence:
ST r15,r14,0
ADD r14,r14,r13
LA r2,@nthr_globals
LD r3,r2,#NT_G_FENCE
CMP r3,r0
JMP[EQ] @nthr_fence_done
CALLR r3
nthr_fence_done:
MOVI r1,0
SUB r14,r14,r13
LD r15,r14,0
MOVI r0,0
RET

; ---------------------------------------------------------------- preemption
; nthr_tick: timer entry calls this once per 100 Hz tick; returns 0.
nthr_tick:
LA r6,@nthr_globals
LD r2,r6,#NT_G_TICKS
ADD r2,r2,r13
ST r2,r6,#NT_G_TICKS
LD r3,r6,#NT_G_SLICE
CMP r3,r0
JMP[EQ] @nthr_tk_pending
SUB r3,r3,r13
ST r3,r6,#NT_G_SLICE
CMP r3,r0
JMP[NE] @nthr_tk_done
nthr_tk_pending:
MOVI r4,1
ST r4,r6,#NT_G_PENDING
nthr_tk_done:
MOVI r1,0
RET

; nthr_preempt(frame): timer-vector hook.  r1 points at the 24-word trap
; frame.  If the slice expired and another thread is ready, swap the current
; TCB frame into the TCB, put the current thread at the ready-queue tail,
; select the next thread, and copy its frame over the supplied one.  Return
; 1 means the vector must SVCRET with the replaced frame; 0 means unchanged.
nthr_preempt:
ST r15,r14,0
ADD r14,r14,r13
LA r6,@nthr_globals
ST r1,r6,#NT_G_FRAME
CALL @nthr_tick
LA r6,@nthr_globals
LD r2,r6,#NT_G_PENDING
CMP r2,r0
JMP[EQ] @nthr_pr_no
LD r3,r6,#NT_G_HEAD
CMP r3,r0
JMP[EQ] @nthr_pr_clear
LD r4,r6,#NT_G_CUR
LD r5,r4,#NT_T_STATE
MOVI r7,#NT_ST_RUNNING
CMP r5,r7
JMP[NE] @nthr_pr_no
LD r3,r6,#NT_G_FRAME
ADD r2,r4,r0
ADD r1,r3,r0
MOVI r8,24
BCOPY r2,r1,r8
MOVI r7,#NT_ST_READY
ST r7,r4,#NT_T_STATE
ADD r2,r4,r0
CALL @nthr_enqueue
CALL @nthr_pick
LA r6,@nthr_globals
LD r4,r6,#NT_G_NEXT
LD r3,r6,#NT_G_FRAME
ADD r2,r3,r0
ADD r1,r4,r0
MOVI r8,24
BCOPY r2,r1,r8
ST r0,r6,#NT_G_PENDING
MOVI r1,1
JMP @nthr_pr_done
nthr_pr_clear:
ST r0,r6,#NT_G_PENDING
LD r2,r6,#NT_G_QUANTUM
ST r2,r6,#NT_G_SLICE
nthr_pr_no:
MOVI r1,0
nthr_pr_done:
SUB r14,r14,r13
LD r15,r14,0
MOVI r0,0
RET

; ---------------------------------------------------------------- data
nthr_globals:
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0
nthr_kstack:
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0
