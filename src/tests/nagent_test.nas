; nagent_test.nas - F5 AI-native agent ABI proof (pure NaN, nan_cli).
;
; Proves: create/grant/check/revoke (old generation fails, new works);
; checkpoint -> mutate -> restore of frame/caps/roots/trace; fork shares the
; immutable weight root but has independent KV/trace/id; migration CPU0->CPU1
; and node0->node1 with a destination-generation fence; tampered checkpoints,
; a resealed bad cap generation, a stale capability epoch and a tampered agent
; record are all rejected.
;
; Success prints exactly O.  A failed check prints its diagnostic byte and HALT.
;
; Guest map (word addresses):
;   0x6800  nagent destination generation tables (in nagent.nas)
;   0x7000  stack (256 words)
;   0x21000 checkpoint A
;   0x22000 checkpoint B (tamper tests)
;   0x348000 agent table (in nagent.nas)

.equ CKPT    0x21000
.equ CKPT2   0x22000
.equ CKWORDS 512
.equ STK     0x7000

.org 0
JMP @main
.include "../lib/nagent.nas"

main:
MOVI r13,1
LA r14,#STK
CALL @nagent_init
MOVI r2,0
MOVI r3,65
CALL @chk

; ---------------------------------------------------------------------------
; create agent A: cpu0, node0, slot7
MOVI r1,0
MOVI r2,0
MOVI r3,7
CALL @nagent_create
ST r1,r0,@idA
MOVI r2,1
MOVI r3,66
CALL @chk
LD r1,r0,@idA
CALL @nagent_record
ST r1,r0,@recA

LD r1,r0,@recA
MOVI r2,#NAG_ID_F
MOVI r3,1
MOVI r4,67
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_GEN_F
MOVI r3,1
MOVI r4,68
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_STATE_F
MOVI r3,1
MOVI r4,69
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_CPU_F
MOVI r3,0
MOVI r4,70
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_NODE_F
MOVI r3,0
MOVI r4,71
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_SLOT_F
MOVI r3,7
MOVI r4,72
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_CAPCOUNT_F
MOVI r3,0
MOVI r4,73
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_WROOT_F
MOVI r3,0
MOVI r4,74
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_KVROOT_F
MOVI r3,0
MOVI r4,75
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_TRACE_F
LA r3,#NAG_TRACE_SEED
MOVI r4,76
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_CAPEPOCH_F
MOVI r3,1
MOVI r4,77
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_MIG_F
MOVI r3,0
MOVI r4,78
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_CKEPOCH_F
MOVI r3,0
MOVI r4,79
CALL @chkrec
LD r1,r0,@recA
LD r5,r1,#NAG_FRAME_F
ADD r2,r1,r0
ADDI r2,r2,#NAG_FRAME_OFF
ADD r1,r5,r0
MOVI r3,80
CALL @chk
LD r1,r0,@idA
CALL @nagent_verify
MOVI r2,0
MOVI r3,81
CALL @chk

; ---------------------------------------------------------------------------
; grant weight (read|replace), KV and tool capabilities
LD r1,r0,@idA
MOVI r2,#NAG_CAP_WEIGHT
MOVI r3,17
MOVI r4,0x1001
CALL @nagent_cap_grant
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@wcap1
LD r1,r0,@idA
LD r2,r0,@wcap1
MOVI r3,#NAG_R_READ
CALL @nagent_cap_check
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@went1
; wrong rights rejected
LD r1,r0,@idA
LD r2,r0,@wcap1
MOVI r3,#NAG_R_WRITE
CALL @nagent_cap_check
MOVI r2,0
MOVI r3,82
CALL @chk
; entry generation/rights/kind/root
LD r1,r0,@went1
MOVI r2,#NAG_C_GEN
MOVI r3,1
MOVI r4,83
CALL @chkrec
LD r1,r0,@went1
MOVI r2,#NAG_C_RIGHTS
MOVI r3,17
MOVI r4,84
CALL @chkrec
LD r1,r0,@went1
MOVI r2,#NAG_C_KIND
MOVI r3,1
MOVI r4,85
CALL @chkrec
LD r1,r0,@went1
MOVI r2,#NAG_C_ROOT
MOVI r3,0x1001
MOVI r4,86
CALL @chkrec
; weight root is immutable: a different root is refused
LD r1,r0,@idA
MOVI r2,#NAG_CAP_WEIGHT
MOVI r3,17
MOVI r4,0x1002
CALL @nagent_cap_grant
MOVI r2,0
MOVI r3,87
CALL @chk
; KV root
LD r1,r0,@idA
MOVI r2,#NAG_CAP_KV
MOVI r3,3
MOVI r4,0x2001
CALL @nagent_cap_grant
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@kcap1
; tool cap
LD r1,r0,@idA
MOVI r2,#NAG_CAP_TOOL
MOVI r3,5
MOVI r4,0x3001
CALL @nagent_cap_grant
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@tcap1
LD r1,r0,@recA
MOVI r2,#NAG_WROOT_F
MOVI r3,0x1001
MOVI r4,88
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_KVROOT_F
MOVI r3,0x2001
MOVI r4,89
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_KVGEN_F
MOVI r3,1
MOVI r4,90
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_CAPCOUNT_F
MOVI r3,3
MOVI r4,91
CALL @chkrec

; ---------------------------------------------------------------------------
; revoke the weight cap: generation 2, old handle dead
LD r1,r0,@idA
LD r2,r0,@wcap1
CALL @nagent_cap_revoke
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@wcap2
LD r2,r0,@wcap1
CMP r1,r2
JMP[EQ] @fail
SHR r1,r1,8
MOVI r3,0xFF
BOOL.8 r1,r1,r3
MOVI r2,2
MOVI r3,163
CALL @chk
; old fails
LD r1,r0,@idA
LD r2,r0,@wcap1
MOVI r3,#NAG_R_READ
CALL @nagent_cap_check
MOVI r2,0
MOVI r3,92
CALL @chk
; new works
LD r1,r0,@idA
LD r2,r0,@wcap2
MOVI r3,#NAG_R_READ
CALL @nagent_cap_check
CMP r1,r0
JMP[EQ] @fail
LD r1,r0,@recA
MOVI r2,#NAG_CAPEPOCH_F
MOVI r3,5
MOVI r4,93
CALL @chkrec

; ---------------------------------------------------------------------------
; sealed state: trap frame, trace, budget/deadline
LD r1,r0,@recA
LD r2,r1,#NAG_FRAME_F
MOVI r3,0xA1
ST r3,r2,0
MOVI r3,0xA2
ST r3,r2,1
MOVI r3,0xABCD
ST r3,r2,16
LD r1,r0,@idA
MOVI r2,1
MOVI r3,0x11
MOVI r4,0x22
CALL @nagent_trace_append
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@t1
LD r1,r0,@idA
MOVI r2,2
MOVI r3,0x33
MOVI r4,0x44
CALL @nagent_trace_append
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@t2
LD r2,r0,@t1
CMP r1,r2
JMP[EQ] @fail
LD r1,r0,@idA
MOVI r2,500
MOVI r3,900
CALL @nagent_budget_set
MOVI r2,0
MOVI r3,94
CALL @chk
LD r1,r0,@recA
MOVI r2,#NAG_BUDGET_F
MOVI r3,500
MOVI r4,95
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_DEADLINE_F
MOVI r3,900
MOVI r4,96
CALL @chkrec

; ---------------------------------------------------------------------------
; checkpoint A
LD r1,r0,@idA
LA r2,#CKPT
MOVI r3,#CKWORDS
CALL @nagent_checkpoint
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@ckepoch
MOVI r2,1
MOVI r3,97
CALL @chk
LA r1,#CKPT
LD r2,r1,#CK_HASH
ST r2,r0,@ckhash
LA r1,#CKPT
MOVI r2,#CK_AGENT
MOVI r3,1
MOVI r4,98
CALL @chkrec
LA r1,#CKPT
MOVI r2,#CK_CAPS
MOVI r3,3
MOVI r4,99
CALL @chkrec
LA r1,#CKPT
MOVI r2,#CK_CAPEPOCH
MOVI r3,5
MOVI r4,100
CALL @chkrec
LA r1,#CKPT
MOVI r2,#CK_WROOT
MOVI r3,0x1001
MOVI r4,101
CALL @chkrec
LA r1,#CKPT
MOVI r2,#CK_KVROOT
MOVI r3,0x2001
MOVI r4,102
CALL @chkrec
LA r1,#CKPT
MOVI r2,#CK_KVGEN
MOVI r3,1
MOVI r4,103
CALL @chkrec
LA r1,#CKPT
MOVI r2,#CK_BUDGET
MOVI r3,500
MOVI r4,104
CALL @chkrec
LA r1,#CKPT
MOVI r2,#CK_TRACE
LD r3,r0,@t2
MOVI r4,105
CALL @chkrec
LA r1,#CKPT
MOVI r2,#CK_FRAME
MOVI r3,0xA1
MOVI r4,106
CALL @chkrec

; ---------------------------------------------------------------------------
; mutate frame, COW KV root, trace and budget, then restore
LD r1,r0,@recA
LD r2,r1,#NAG_FRAME_F
MOVI r3,0xB1
ST r3,r2,0
MOVI r3,0x9999
ST r3,r2,16
LD r1,r0,@idA
MOVI r2,0
MOVI r3,0x2002
CALL @nagent_roots
MOVI r2,0
MOVI r3,107
CALL @chk
LD r1,r0,@idA
MOVI r2,9
MOVI r3,0x55
MOVI r4,0x66
CALL @nagent_trace_append
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@t3
LD r2,r0,@t2
CMP r1,r2
JMP[EQ] @fail
LD r1,r0,@idA
MOVI r2,999
MOVI r3,888
CALL @nagent_budget_set
LD r1,r0,@recA
MOVI r2,#NAG_KVROOT_F
MOVI r3,0x2002
MOVI r4,108
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_KVGEN_F
MOVI r3,2
MOVI r4,109
CALL @chkrec

LA r1,#CKPT
MOVI r2,#CKWORDS
CALL @nagent_restore
ST r1,r0,@idR
MOVI r2,1
MOVI r3,110
CALL @chk
; frame restored
LD r1,r0,@recA
LD r2,r1,#NAG_FRAME_F
LD r3,r2,0
MOVI r4,0xA1
CMP r3,r4
JMP[NE] @fail
LD r3,r2,16
MOVI r4,0xABCD
CMP r3,r4
JMP[NE] @fail
; roots restored
LD r1,r0,@recA
MOVI r2,#NAG_WROOT_F
MOVI r3,0x1001
MOVI r4,111
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_KVROOT_F
MOVI r3,0x2001
MOVI r4,112
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_KVGEN_F
MOVI r3,1
MOVI r4,113
CALL @chkrec
; trace restored
LD r1,r0,@recA
LD r2,r1,#NAG_TRACE_F
LD r3,r0,@t2
CMP r2,r3
JMP[NE] @fail
LD r1,r0,@recA
MOVI r2,#NAG_TRACEN_F
MOVI r3,2
MOVI r4,114
CALL @chkrec
; budget/deadline restored
LD r1,r0,@recA
MOVI r2,#NAG_BUDGET_F
MOVI r3,500
MOVI r4,115
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_DEADLINE_F
MOVI r3,900
MOVI r4,116
CALL @chkrec
; caps restored, handles still live
LD r1,r0,@recA
MOVI r2,#NAG_CAPCOUNT_F
MOVI r3,3
MOVI r4,117
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_CAPEPOCH_F
MOVI r3,5
MOVI r4,118
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_CKEPOCH_F
MOVI r3,1
MOVI r4,119
CALL @chkrec
LD r1,r0,@recA
LD r2,r1,#NAG_CKHASH_F
LD r3,r0,@ckhash
CMP r2,r3
JMP[NE] @fail
LD r1,r0,@idA
LD r2,r0,@wcap2
MOVI r3,#NAG_R_READ
CALL @nagent_cap_check
CMP r1,r0
JMP[EQ] @fail
LD r1,r0,@idA
LD r2,r0,@tcap1
MOVI r3,#NAG_R_EXEC
CALL @nagent_cap_check
CMP r1,r0
JMP[EQ] @fail
LD r1,r0,@idA
CALL @nagent_verify
MOVI r2,0
MOVI r3,120
CALL @chk

; ---------------------------------------------------------------------------
; fork A to B on cpu1/node0
LD r1,r0,@idA
MOVI r2,1
MOVI r3,0
CALL @nagent_fork
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@idB
LD r2,r0,@idA
CMP r1,r2
JMP[EQ] @fail
LD r1,r0,@idB
CALL @nagent_record
ST r1,r0,@recB
LD r1,r0,@recB
MOVI r2,#NAG_PARENT_F
LD r3,r0,@idA
MOVI r4,121
CALL @chkrec
LD r1,r0,@recB
MOVI r2,#NAG_WROOT_F
MOVI r3,0x1001
MOVI r4,122
CALL @chkrec
LD r1,r0,@recB
MOVI r2,#NAG_KVGEN_F
MOVI r3,2
MOVI r4,123
CALL @chkrec
; child KV root differs from parent
LD r1,r0,@recB
LD r2,r1,#NAG_KVROOT_F
LD r1,r0,@recA
LD r3,r1,#NAG_KVROOT_F
CMP r2,r3
JMP[EQ] @fail
; child carries the parent trace head and frame
LD r1,r0,@recB
LD r2,r1,#NAG_TRACE_F
LD r3,r0,@t2
CMP r2,r3
JMP[NE] @fail
LD r1,r0,@recB
MOVI r2,#NAG_TRACEN_F
MOVI r3,2
MOVI r4,124
CALL @chkrec
LD r1,r0,@recB
MOVI r2,#NAG_CAPCOUNT_F
MOVI r3,3
MOVI r4,125
CALL @chkrec
LD r1,r0,@recB
MOVI r2,#NAG_CKEPOCH_F
MOVI r3,0
MOVI r4,126
CALL @chkrec
LD r1,r0,@recB
MOVI r2,#NAG_MIG_F
MOVI r3,0
MOVI r4,127
CALL @chkrec
LD r1,r0,@recB
MOVI r2,#NAG_FRAME_F
LD r3,r1,#NAG_FRAME_F
LD r3,r3,0
MOVI r4,0xA1
CMP r3,r4
JMP[NE] @fail
; child cap generations are parent+1; child handles work
LD r1,r0,@idB
MOVI r2,1
CALL @capent
ST r1,r0,@tmp
LD r1,r0,@tmp
MOVI r2,#NAG_C_GEN
MOVI r3,3
MOVI r4,128
CALL @chkrec
LD r1,r0,@idB
MOVI r2,1
CALL @capent
LD r1,r1,#NAG_C_HANDLE
ST r1,r0,@tmp
LD r1,r0,@idB
LD r2,r0,@tmp
MOVI r3,#NAG_R_READ
CALL @nagent_cap_check
CMP r1,r0
JMP[EQ] @fail
LD r1,r0,@idB
MOVI r2,2
CALL @capent
LD r1,r1,#NAG_C_HANDLE
ST r1,r0,@tmp
LD r1,r0,@idB
LD r2,r0,@tmp
MOVI r3,#NAG_R_READ
CALL @nagent_cap_check
CMP r1,r0
JMP[EQ] @fail
LD r1,r0,@idB
MOVI r2,3
CALL @capent
LD r1,r1,#NAG_C_HANDLE
ST r1,r0,@tmp
LD r1,r0,@idB
LD r2,r0,@tmp
MOVI r3,#NAG_R_EXEC
CALL @nagent_cap_check
CMP r1,r0
JMP[EQ] @fail
; a parent handle does not work on the child
LD r1,r0,@idB
LD r2,r0,@wcap2
MOVI r3,#NAG_R_READ
CALL @nagent_cap_check
MOVI r2,0
MOVI r3,129
CALL @chk
; child trace is independent
LD r1,r0,@idB
MOVI r2,7
MOVI r3,1
MOVI r4,2
CALL @nagent_trace_append
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@tb
LD r2,r0,@t2
CMP r1,r2
JMP[EQ] @fail
LD r1,r0,@recA
LD r2,r1,#NAG_TRACE_F
LD r3,r0,@t2
CMP r2,r3
JMP[NE] @fail
LD r1,r0,@recA
MOVI r2,#NAG_WROOT_F
MOVI r3,0x1001
MOVI r4,130
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_KVROOT_F
MOVI r3,0x2001
MOVI r4,131
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_CAPCOUNT_F
MOVI r3,3
MOVI r4,132
CALL @chkrec

; ---------------------------------------------------------------------------
; migrate A CPU0->CPU1, then node0->node1, preserving caps/roots/trace
LD r1,r0,@idA
MOVI r2,1
MOVI r3,0
MOVI r4,1
MOVI r5,1
CALL @nagent_migrate
MOVI r2,0
MOVI r3,133
CALL @chk
LD r1,r0,@recA
MOVI r2,#NAG_CPU_F
MOVI r3,1
MOVI r4,134
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_NODE_F
MOVI r3,0
MOVI r4,135
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_MIG_F
MOVI r3,1
MOVI r4,136
CALL @chkrec
LD r1,r0,@idA
LD r2,r0,@wcap2
MOVI r3,#NAG_R_READ
CALL @nagent_cap_check
CMP r1,r0
JMP[EQ] @fail
LD r1,r0,@recA
MOVI r2,#NAG_WROOT_F
MOVI r3,0x1001
MOVI r4,137
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_KVROOT_F
MOVI r3,0x2001
MOVI r4,138
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_KVGEN_F
MOVI r3,1
MOVI r4,139
CALL @chkrec
LD r1,r0,@recA
LD r2,r1,#NAG_TRACE_F
LD r3,r0,@t2
CMP r2,r3
JMP[NE] @fail
LD r1,r0,@recA
MOVI r2,#NAG_BUDGET_F
MOVI r3,500
MOVI r4,140
CALL @chkrec

LD r1,r0,@idA
MOVI r2,1
MOVI r3,1
MOVI r4,1
MOVI r5,1
CALL @nagent_migrate
MOVI r2,0
MOVI r3,141
CALL @chk
LD r1,r0,@recA
MOVI r2,#NAG_CPU_F
MOVI r3,1
MOVI r4,142
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_NODE_F
MOVI r3,1
MOVI r4,143
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_MIG_F
MOVI r3,2
MOVI r4,144
CALL @chkrec
; stale destination generation is rejected and state is unchanged
LD r1,r0,@idA
MOVI r2,1
MOVI r3,0
MOVI r4,0
MOVI r5,1
CALL @nagent_migrate
MOVI r2,1
MOVI r3,145
CALL @chk
LD r1,r0,@recA
MOVI r2,#NAG_CPU_F
MOVI r3,1
MOVI r4,146
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_NODE_F
MOVI r3,1
MOVI r4,147
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_MIG_F
MOVI r3,2
MOVI r4,148
CALL @chkrec
; publish destination generation 2 and retry
MOVI r1,1
MOVI r2,2
MOVI r3,1
MOVI r4,2
CALL @nagent_dest_set
MOVI r2,0
MOVI r3,149
CALL @chk
LD r1,r0,@idA
MOVI r2,1
MOVI r3,1
MOVI r4,1
MOVI r5,1
CALL @nagent_migrate
MOVI r2,1
MOVI r3,150
CALL @chk
LD r1,r0,@idA
MOVI r2,1
MOVI r3,0
MOVI r4,2
MOVI r5,1
CALL @nagent_migrate
MOVI r2,0
MOVI r3,151
CALL @chk
LD r1,r0,@recA
MOVI r2,#NAG_CPU_F
MOVI r3,1
MOVI r4,152
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_NODE_F
MOVI r3,0
MOVI r4,153
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_MIG_F
MOVI r3,3
MOVI r4,154
CALL @chkrec
; node1 generation 2 is accepted too
LD r1,r0,@idA
MOVI r2,1
MOVI r3,1
MOVI r4,2
MOVI r5,2
CALL @nagent_migrate
MOVI r2,0
MOVI r3,155
CALL @chk
LD r1,r0,@recA
MOVI r2,#NAG_NODE_F
MOVI r3,1
MOVI r4,156
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_MIG_F
MOVI r3,4
MOVI r4,157
CALL @chkrec
; migrate back to cpu0/node0 with their generation 1
LD r1,r0,@idA
MOVI r2,0
MOVI r3,0
MOVI r4,1
MOVI r5,1
CALL @nagent_migrate
MOVI r2,0
MOVI r3,158
CALL @chk
LD r1,r0,@recA
MOVI r2,#NAG_CPU_F
MOVI r3,0
MOVI r4,159
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_NODE_F
MOVI r3,0
MOVI r4,160
CALL @chkrec
LD r1,r0,@recA
MOVI r2,#NAG_MIG_F
MOVI r3,5
MOVI r4,161
CALL @chkrec
LD r1,r0,@idA
LD r2,r0,@wcap2
MOVI r3,#NAG_R_READ
CALL @nagent_cap_check
CMP r1,r0
JMP[EQ] @fail

; ---------------------------------------------------------------------------
; tampered checkpoint frame: hash rejects, agent unchanged
LD r1,r0,@idA
LA r2,#CKPT2
MOVI r3,#CKWORDS
CALL @nagent_checkpoint
CMP r1,r0
JMP[EQ] @fail
LA r2,#CKPT2
MOVI r3,0xBAD
ST r3,r2,#CK_FRAME
LA r1,#CKPT2
MOVI r2,#CKWORDS
CALL @nagent_restore
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@recA
LD r2,r1,#NAG_FRAME_F
LD r2,r2,0
MOVI r3,0xA1
CMP r2,r3
JMP[NE] @fail
LD r1,r0,@recA
MOVI r2,#NAG_CKEPOCH_F
MOVI r3,2
MOVI r4,157
CALL @chkrec

; resealed checkpoint with a bad capability generation: the per-cap check
; still rejects it
LD r1,r0,@idA
LA r2,#CKPT2
MOVI r3,#CKWORDS
CALL @nagent_checkpoint
CMP r1,r0
JMP[EQ] @fail
LA r2,#CKPT2
MOVI r3,0
ST r3,r2,#CK_CAPS_OFF+2
LA r1,#CKPT2
MOVI r2,#CKWORDS
CALL @nagent_ck_seal
CMP r1,r0
JMP[EQ] @fail
LA r1,#CKPT2
MOVI r2,#CKWORDS
CALL @nagent_restore
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@recA
MOVI r2,#NAG_CAPCOUNT_F
MOVI r3,3
MOVI r4,158
CALL @chkrec
LD r1,r0,@recA
LD r2,r1,#NAG_TRACE_F
LD r3,r0,@t2
CMP r2,r3
JMP[NE] @fail

; ---------------------------------------------------------------------------
; tampered live record: seal rejects, then repair
LD r1,r0,@recA
LD r2,r1,#NAG_CAPBASE_F
MOVI r3,99
ST r3,r2,#NAG_C_GEN
LD r1,r0,@idA
CALL @nagent_verify
CMP r1,r0
JMP[EQ] @fail
LD r1,r0,@recA
LD r2,r1,#NAG_CAPBASE_F
MOVI r3,2
ST r3,r2,#NAG_C_GEN
LD r1,r0,@idA
CALL @nagent_verify
MOVI r2,0
MOVI r3,159
CALL @chk

; ---------------------------------------------------------------------------
; stale capability epoch: checkpoint, revoke, restore must fail
LD r1,r0,@idA
LA r2,#CKPT2
MOVI r3,#CKWORDS
CALL @nagent_checkpoint
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@ckstale
LD r1,r0,@idA
LD r2,r0,@wcap2
CALL @nagent_cap_revoke
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@wcap3
LA r1,#CKPT2
MOVI r2,#CKWORDS
CALL @nagent_restore
MOVI r2,0
MOVI r3,164
CALL @chk
; old capability is dead, the new generation works
LD r1,r0,@idA
LD r2,r0,@wcap2
MOVI r3,#NAG_R_READ
CALL @nagent_cap_check
MOVI r2,0
MOVI r3,161
CALL @chk
LD r1,r0,@idA
LD r2,r0,@wcap3
MOVI r3,#NAG_R_READ
CALL @nagent_cap_check
CMP r1,r0
JMP[EQ] @fail
; failed restore left the agent alone
LD r1,r0,@recA
LD r2,r1,#NAG_TRACE_F
LD r3,r0,@t2
CMP r2,r3
JMP[NE] @fail
LD r1,r0,@recA
LD r2,r1,#NAG_FRAME_F
LD r2,r2,0
MOVI r3,0xA1
CMP r2,r3
JMP[NE] @fail
LD r1,r0,@recA
MOVI r2,#NAG_CAPCOUNT_F
MOVI r3,3
MOVI r4,162
CALL @chkrec

; ---------------------------------------------------------------------------
pass:
  MOVI r1,79
  PUTC r1
  HALT

fail:
  MOVI r1,70
  PUTC r1
  MOVI r1,10
  PUTC r1
  HALT

; chk r1=actual r2=expected r3=diagnostic byte.
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

; chkrec r1=base r2=word offset r3=expected r4=diagnostic.
chkrec:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r4,r14,1
  ADD r5,r1,r2
  LD r1,r5,0
  ADD r2,r3,r0
  LD r3,r14,1
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; capent r1=id r2=index -> capability entry pointer.
capent:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r2,r14,1
  CALL @nagent_record
  LD r3,r1,#NAG_CAPBASE_F
  LD r2,r14,1
  SUB r2,r2,r13
  MOVI r4,8
  MUL r2,r2,r4
  ADD r1,r3,r2
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

idA:
.word 0
idB:
.word 0
idR:
.word 0
recA:
.word 0
recB:
.word 0
wcap1:
.word 0
wcap2:
.word 0
wcap3:
.word 0
kcap1:
.word 0
tcap1:
.word 0
went1:
.word 0
t1:
.word 0
t2:
.word 0
t3:
.word 0
tb:
.word 0
tmp:
.word 0
ckhash:
.word 0
ckepoch:
.word 0
ckstale:
.word 0

.org 0x7000
stack:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
