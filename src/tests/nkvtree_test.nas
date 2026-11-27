; nkvtree_test.nas - three-agent shared-prefix branch tree (F13h).
;
; Scenario (two close orders, each run twice from a cold init and compared
; word-for-word):
;   ngen agent 1 reaches generation 5.  The root tree agent opens at gen 5,
;   binds nsym weight root 15, appends a 10-token immutable prefix over two
;   pages (8 full + 2 partial), reads it, and seals both pages as SHARED
;   mirroring nsym roots 1/2.  child1 forks on ngen agent 2 at generation 2
;   and child2 forks on ngen agent 3 at generation 3; both are nagent_fork
;   child records (KV generation parent+1), share both prefix pages read-only
;   and acquire the same weight root.  The parent then publishes gen 6 and
;   keeps appending as an admitted DRAINING snapshot.  A new ctx opens at
;   gen 6 on the same branch and rejects the old gen-5 view; an open at the
;   old gen 5 fails ESTALE with ngen EDRAIN.
;   The parent appends a 2-token suffix (one boundary COW); child1 appends 7
;   divergent tokens (one boundary COW + one private page); child2 appends 6
;   (one boundary COW only).  The shared 8-token page is never copied; the
;   2-token boundary is copied exactly once per branch.  Sibling values are
;   isolated and the parent's prefix/suffix stays unchanged.
;   Close order A is child1, child2, parent; order B is child2, child1,
;   parent.  Both free every page and every nsym root exactly at refcount
;   zero; the parent close drains gen 5 and leaves gen 6 current.  Four cold
;   runs produce two identical 3344-word snapshots (A and B).
;
; Success prints exactly O.  A failed check prints F=actual,expected,diag.

.org 0
JMP @main

.org 0x10000
.include "../lib/nkvtree.nas"

main:
MOVI r13,1
MOVI r14,0x7000

; ---- close order A, cold run 1
CALL @cold
CALL @setup
MOVI r1,1
CALL @scenario
LA r1,@snapA1
CALL @snapshot

; ---- close order B, cold run 1
CALL @cold
CALL @setup
MOVI r1,2
CALL @scenario
LA r1,@snapB1
CALL @snapshot

; ---- close order A, cold run 2
CALL @cold
CALL @setup
MOVI r1,1
CALL @scenario
LA r1,@snapA2
CALL @snapshot

; ---- close order B, cold run 2
CALL @cold
CALL @setup
MOVI r1,2
CALL @scenario
LA r1,@snapB2
CALL @snapshot

; ---- deterministic rerun, both close orders
LA r1,@snapA1
LA r2,@snapA2
MOVI r3,3344
CALL @cmpbuf
MOVI r2,0
MOVI r3,900
CALL @chk
LA r1,@snapB1
LA r2,@snapB2
MOVI r3,3344
CALL @cmpbuf
MOVI r2,0
MOVI r3,901
CALL @chk

MOVI r1,79
PUTC r1
HALT

; ---------------------------------------------------------------------------
; cold - full cold init: objects, agents, nsym roots/ngen, tree registry.
cold:
ST r15,r14,0
ADDI r14,r14,16
CALL @nobj_init
CALL @nagent_init
CALL @nsym_init
LA r1,@pdata
MOVI r2,8
CALL @nkvt_init
MOVI r2,0
MOVI r3,1
CALL @chk
ADDI r14,r14,-16
LD r15,r14,0
RET

; setup - ngen agents 1..3, agent 1 at gen 5, shared weight root, parent agent.
setup:
ST r15,r14,0
ADDI r14,r14,16
MOVI r1,1
MOVI r2,0x1000
MOVI r3,0x2000
CALL @ngen_create
MOVI r2,0
MOVI r3,2
CALL @chk
MOVI r1,2
MOVI r2,0x1100
MOVI r3,0x2100
CALL @ngen_create
MOVI r2,0
MOVI r3,3
CALL @chk
MOVI r1,3
MOVI r2,0x1200
MOVI r3,0x2200
CALL @ngen_create
MOVI r2,0
MOVI r3,4
CALL @chk

; ngen agent 1: start/drain 1..4, then start 5 (epoch 9)
MOVI r1,1
MOVI r2,1
CALL @ngen_start
MOVI r2,1
MOVI r3,5
CALL @chk
MOVI r1,1
CALL @ngen_drain
MOVI r2,2
MOVI r3,6
CALL @chk
MOVI r1,1
MOVI r2,2
CALL @ngen_start
MOVI r2,3
MOVI r3,7
CALL @chk
MOVI r1,1
CALL @ngen_drain
MOVI r2,4
MOVI r3,8
CALL @chk
MOVI r1,1
MOVI r2,3
CALL @ngen_start
MOVI r2,5
MOVI r3,9
CALL @chk
MOVI r1,1
CALL @ngen_drain
MOVI r2,6
MOVI r3,10
CALL @chk
MOVI r1,1
MOVI r2,4
CALL @ngen_start
MOVI r2,7
MOVI r3,11
CALL @chk
MOVI r1,1
CALL @ngen_drain
MOVI r2,8
MOVI r3,12
CALL @chk
MOVI r1,1
MOVI r2,5
CALL @ngen_start
MOVI r2,9
MOVI r3,13
CALL @chk

; shared immutable weight root 15
MOVI r1,15
MOVI r2,0x5901
LA r3,@wpay
MOVI r4,4
CALL @nsym_root_create
MOVI r2,0
MOVI r3,14
CALL @chk
MOVI r1,15
MOVI r2,#NS_R_STATE
MOVI r3,1
MOVI r4,15
CALL @root_chk
MOVI r1,15
MOVI r2,#NS_R_REFS
MOVI r3,0
MOVI r4,16
CALL @root_chk

; root nagent record id 1
MOVI r1,0
MOVI r2,0
MOVI r3,0
CALL @nagent_create
MOVI r2,1
MOVI r3,17
CALL @chk

ADDI r14,r14,-16
LD r15,r14,0
RET

; ---------------------------------------------------------------------------
; scenario r1=close order (1 = child1 then child2, 2 = reverse)
scenario:
ST r15,r14,0
ADDI r14,r14,16
LA r2,@order
ST r1,r2,0
CALL @build
LA r2,@order
LD r1,r2,0
MOVI r2,1
CMP r1,r2
JMP[EQ] @sc_close12
CALL @close2
CALL @close1
JMP @sc_after
sc_close12:
CALL @close1
CALL @close2
sc_after:
CALL @close_both_checks
CALL @close_parent
CALL @final_checks
ADDI r14,r14,-16
LD r15,r14,0
RET

; ---------------------------------------------------------------------------
; build - common tree construction and append/isolation proof.
build:
ST r15,r14,0
ADDI r14,r14,16

; ---- open the parent tree agent at ngen agent 1 generation 5, branch 1
LA r1,@ctxP
MOVI r2,1
MOVI r3,5
MOVI r4,0
MOVI r5,1
MOVI r6,1
LA r7,@tabP
MOVI r8,16
MOVI r9,8
CALL @nkvt_open
MOVI r2,1
MOVI r3,20
CALL @chk
LA r1,@ctxP
MOVI r2,#NKT_C_GEN
MOVI r3,5
MOVI r4,21
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_ADMIT
MOVI r3,1
MOVI r4,22
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_USED
MOVI r3,0
MOVI r4,23
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_LIVE
MOVI r3,0
MOVI r4,24
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_BRANCH
MOVI r3,1
MOVI r4,25
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_NAGENT
MOVI r3,1
MOVI r4,26
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_TABCAP
MOVI r3,16
MOVI r4,27
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_BLOCKTOK
MOVI r3,8
MOVI r4,28
CALL @ctx_chk
MOVI r1,#NKT_G_OPENS
MOVI r2,1
MOVI r3,29
CALL @stats_chk

; ---- bind the shared weight root
LA r1,@ctxP
MOVI r2,15
CALL @nkvt_bind
MOVI r2,1
MOVI r3,30
CALL @chk
LA r1,@ctxP
MOVI r2,#NKT_C_WROOT
MOVI r3,15
MOVI r4,31
CALL @ctx_chk
MOVI r1,15
MOVI r2,#NS_R_STATE
MOVI r3,1
MOVI r4,32
CALL @root_chk
MOVI r1,15
MOVI r2,#NS_R_REFS
MOVI r3,1
MOVI r4,33
CALL @root_chk
MOVI r1,15
MOVI r2,#NS_R_ID
MOVI r3,0x5901
MOVI r4,34
CALL @root_chk
MOVI r1,#NKT_G_BINDS
MOVI r2,1
MOVI r3,35
CALL @stats_chk
MOVI r1,#NKT_G_RACQ
MOVI r2,1
MOVI r3,36
CALL @stats_chk
MOVI r1,1
MOVI r2,#NAG_WROOT_F
MOVI r3,15
MOVI r4,37
CALL @rec_chk
MOVI r1,1
MOVI r2,#NAG_KVGEN_F
MOVI r3,0
MOVI r4,38
CALL @rec_chk

; ---- 10-token prefix: values 0x5000+token
LA r1,@ctxP
MOVI r2,0
MOVI r3,10
MOVI r4,0x5000
CALL @app_seq
MOVI r2,1
MOVI r3,39
CALL @chk
LA r1,@ctxP
MOVI r2,#NKT_C_USED
MOVI r3,10
MOVI r4,40
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_LIVE
MOVI r3,2
MOVI r4,41
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_COPIES
MOVI r3,0
MOVI r4,42
CALL @ctx_chk
MOVI r1,0
MOVI r2,#NKT_P_GEN
MOVI r3,5
MOVI r4,43
CALL @page_chk
MOVI r1,0
MOVI r2,#NKT_P_REFS
MOVI r3,1
MOVI r4,44
CALL @page_chk
MOVI r1,0
MOVI r2,#NKT_P_STATE
MOVI r3,1
MOVI r4,45
CALL @page_chk
MOVI r1,0
MOVI r2,#NKT_P_FLAGS
MOVI r3,0
MOVI r4,46
CALL @page_chk
MOVI r1,0
MOVI r2,#NKT_P_USED
MOVI r3,8
MOVI r4,47
CALL @page_chk
MOVI r1,0
MOVI r2,#NKT_P_ROOT
LA r3,#NKT_NONE
MOVI r4,48
CALL @page_chk
MOVI r1,1
MOVI r2,#NKT_P_GEN
MOVI r3,5
MOVI r4,49
CALL @page_chk
MOVI r1,1
MOVI r2,#NKT_P_REFS
MOVI r3,1
MOVI r4,50
CALL @page_chk
MOVI r1,1
MOVI r2,#NKT_P_USED
MOVI r3,2
MOVI r4,51
CALL @page_chk
MOVI r1,#NKT_G_ALLOCS
MOVI r2,2
MOVI r3,52
CALL @stats_chk
MOVI r1,#NKT_G_LIVE
MOVI r2,2
MOVI r3,53
CALL @stats_chk
MOVI r1,#NKT_G_JOINS
MOVI r2,0
MOVI r3,54
CALL @stats_chk
MOVI r1,#NKT_G_COPIES
MOVI r2,0
MOVI r3,55
CALL @stats_chk

; ---- parent reads its prefix, keeps one read and one write view
LA r1,@ctxP
MOVI r2,0
MOVI r3,10
MOVI r4,0x5000
MOVI r5,5
CALL @rd_range
MOVI r2,1
MOVI r3,56
CALL @chk
LA r1,@ctxP
MOVI r2,0
MOVI r3,1
LA r4,@viewP
CALL @nkvt_view_open
MOVI r2,1
MOVI r3,57
CALL @chk
LA r1,@ctxP
MOVI r2,0
MOVI r3,2
LA r4,@viewPW
CALL @nkvt_view_open
MOVI r2,1
MOVI r3,58
CALL @chk
LA r1,@viewP
MOVI r2,#NKT_V_CTXGEN
MOVI r3,5
MOVI r4,59
CALL @view_chk
LA r1,@viewP
MOVI r2,#NKT_V_BRANCH
MOVI r3,1
MOVI r4,60
CALL @view_chk
LA r1,@viewP
MOVI r2,#NKT_V_TOKEN
MOVI r3,0
MOVI r4,61
CALL @view_chk
LA r1,@viewP
MOVI r2,#NKT_V_MODE
MOVI r3,1
MOVI r4,62
CALL @view_chk
MOVI r1,#NKT_G_VOPEN
MOVI r2,12
MOVI r3,63
CALL @stats_chk

; ---- seal the immutable prefix and bind nsym roots 1/2
LA r1,@ctxP
CALL @nkvt_seal_prefix
MOVI r2,1
MOVI r3,64
CALL @chk
LA r1,@ctxP
MOVI r2,#NKT_C_PREFIX
MOVI r3,2
MOVI r4,65
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_KVROOT
MOVI r3,1
MOVI r4,66
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_NAGKVGEN
MOVI r3,1
MOVI r4,67
CALL @ctx_chk
MOVI r1,0
MOVI r2,#NKT_P_FLAGS
MOVI r3,1
MOVI r4,68
CALL @page_chk
MOVI r1,0
MOVI r2,#NKT_P_ROOT
MOVI r3,1
MOVI r4,69
CALL @page_chk
MOVI r1,1
MOVI r2,#NKT_P_FLAGS
MOVI r3,1
MOVI r4,70
CALL @page_chk
MOVI r1,1
MOVI r2,#NKT_P_ROOT
MOVI r3,2
MOVI r4,71
CALL @page_chk
MOVI r1,1
MOVI r2,#NS_R_STATE
MOVI r3,1
MOVI r4,72
CALL @root_chk
MOVI r1,1
MOVI r2,#NS_R_REFS
MOVI r3,1
MOVI r4,73
CALL @root_chk
MOVI r1,2
MOVI r2,#NS_R_STATE
MOVI r3,1
MOVI r4,74
CALL @root_chk
MOVI r1,2
MOVI r2,#NS_R_REFS
MOVI r3,1
MOVI r4,75
CALL @root_chk
MOVI r1,1
MOVI r2,#NS_R_ID
LA r3,0x4E4B5401
MOVI r4,76
CALL @root_chk
MOVI r1,2
MOVI r2,#NS_R_ID
LA r3,0x4E4B5402
MOVI r4,77
CALL @root_chk
MOVI r1,1
MOVI r2,#NAG_KVROOT_F
MOVI r3,1
MOVI r4,78
CALL @rec_chk
MOVI r1,1
MOVI r2,#NAG_KVGEN_F
MOVI r3,1
MOVI r4,79
CALL @rec_chk
MOVI r1,#NKT_G_SEALS
MOVI r2,1
MOVI r3,80
CALL @stats_chk
MOVI r1,#NKT_G_PREFIXP
MOVI r2,2
MOVI r3,81
CALL @stats_chk
MOVI r1,#NKT_G_RCREATE
MOVI r2,2
MOVI r3,82
CALL @stats_chk
MOVI r1,#NKT_G_RACQ
MOVI r2,3
MOVI r3,83
CALL @stats_chk

; ---- fork child1: ngen agent 2 generation 2, branch 2
LA r1,@ctxP
LA r2,@ctxC1
MOVI r3,2
MOVI r4,2
LA r5,@tabC1
MOVI r6,16
MOVI r7,2
MOVI r8,0
CALL @nkvt_fork
MOVI r2,2
MOVI r3,84
CALL @chk
LA r1,@ctxC1
MOVI r2,#NKT_C_AGENT
MOVI r3,2
MOVI r4,85
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_GEN
MOVI r3,2
MOVI r4,86
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_BRANCH
MOVI r3,2
MOVI r4,87
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_PARENT
MOVI r3,1
MOVI r4,88
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_NAGENT
MOVI r3,2
MOVI r4,89
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_NAGKVGEN
MOVI r3,2
MOVI r4,90
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_USED
MOVI r3,10
MOVI r4,91
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_LIVE
MOVI r3,2
MOVI r4,92
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_ADMIT
MOVI r3,1
MOVI r4,93
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_DEPTH
MOVI r3,1
MOVI r4,94
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_PREFIX
MOVI r3,2
MOVI r4,95
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_WROOT
MOVI r3,15
MOVI r4,96
CALL @ctx_chk
MOVI r1,0
MOVI r2,#NKT_P_REFS
MOVI r3,2
MOVI r4,97
CALL @page_chk
MOVI r1,0
MOVI r2,#NKT_P_JOINS
MOVI r3,1
MOVI r4,98
CALL @page_chk
MOVI r1,1
MOVI r2,#NKT_P_REFS
MOVI r3,2
MOVI r4,99
CALL @page_chk
MOVI r1,1
MOVI r2,#NS_R_REFS
MOVI r3,2
MOVI r4,100
CALL @root_chk
MOVI r1,2
MOVI r2,#NS_R_REFS
MOVI r3,2
MOVI r4,101
CALL @root_chk
MOVI r1,15
MOVI r2,#NS_R_REFS
MOVI r3,2
MOVI r4,102
CALL @root_chk
MOVI r1,#NKT_G_FORKS
MOVI r2,1
MOVI r3,103
CALL @stats_chk
MOVI r1,#NKT_G_JOINS
MOVI r2,2
MOVI r3,104
CALL @stats_chk
MOVI r1,#NKT_G_RACQ
MOVI r2,6
MOVI r3,105
CALL @stats_chk
MOVI r1,#NKT_G_NAGFORKS
MOVI r2,1
MOVI r3,106
CALL @stats_chk
MOVI r1,2
MOVI r2,#NAG_PARENT_F
MOVI r3,1
MOVI r4,107
CALL @rec_chk
MOVI r1,2
MOVI r2,#NAG_KVGEN_F
MOVI r3,2
MOVI r4,108
CALL @rec_chk
MOVI r1,2
MOVI r2,3
MOVI r3,2
MOVI r4,109
CALL @ngen_chk
MOVI r1,2
MOVI r2,2
MOVI r3,1
MOVI r4,1
MOVI r5,110
CALL @slot_chk
LA r1,@ctxP
MOVI r2,#NKT_C_CHILDREN
MOVI r3,1
MOVI r4,111
CALL @ctx_chk

; ---- fork child2: ngen agent 3 generation 3, branch 3
LA r1,@ctxP
LA r2,@ctxC2
MOVI r3,3
MOVI r4,3
LA r5,@tabC2
MOVI r6,16
MOVI r7,3
MOVI r8,0
CALL @nkvt_fork
MOVI r2,3
MOVI r3,112
CALL @chk
LA r1,@ctxC2
MOVI r2,#NKT_C_AGENT
MOVI r3,3
MOVI r4,113
CALL @ctx_chk
LA r1,@ctxC2
MOVI r2,#NKT_C_GEN
MOVI r3,3
MOVI r4,114
CALL @ctx_chk
LA r1,@ctxC2
MOVI r2,#NKT_C_BRANCH
MOVI r3,3
MOVI r4,115
CALL @ctx_chk
LA r1,@ctxC2
MOVI r2,#NKT_C_PARENT
MOVI r3,1
MOVI r4,116
CALL @ctx_chk
LA r1,@ctxC2
MOVI r2,#NKT_C_NAGENT
MOVI r3,3
MOVI r4,117
CALL @ctx_chk
LA r1,@ctxC2
MOVI r2,#NKT_C_NAGKVGEN
MOVI r3,2
MOVI r4,118
CALL @ctx_chk
LA r1,@ctxC2
MOVI r2,#NKT_C_USED
MOVI r3,10
MOVI r4,119
CALL @ctx_chk
LA r1,@ctxC2
MOVI r2,#NKT_C_LIVE
MOVI r3,2
MOVI r4,120
CALL @ctx_chk
LA r1,@ctxC2
MOVI r2,#NKT_C_DEPTH
MOVI r3,1
MOVI r4,121
CALL @ctx_chk
LA r1,@ctxC2
MOVI r2,#NKT_C_WROOT
MOVI r3,15
MOVI r4,122
CALL @ctx_chk
MOVI r1,0
MOVI r2,#NKT_P_REFS
MOVI r3,3
MOVI r4,123
CALL @page_chk
MOVI r1,0
MOVI r2,#NKT_P_JOINS
MOVI r3,2
MOVI r4,124
CALL @page_chk
MOVI r1,1
MOVI r2,#NKT_P_REFS
MOVI r3,3
MOVI r4,125
CALL @page_chk
MOVI r1,1
MOVI r2,#NS_R_REFS
MOVI r3,3
MOVI r4,126
CALL @root_chk
MOVI r1,2
MOVI r2,#NS_R_REFS
MOVI r3,3
MOVI r4,127
CALL @root_chk
MOVI r1,15
MOVI r2,#NS_R_REFS
MOVI r3,3
MOVI r4,128
CALL @root_chk
MOVI r1,#NKT_G_FORKS
MOVI r2,2
MOVI r3,129
CALL @stats_chk
MOVI r1,#NKT_G_JOINS
MOVI r2,4
MOVI r3,130
CALL @stats_chk
MOVI r1,#NKT_G_RACQ
MOVI r2,9
MOVI r3,131
CALL @stats_chk
MOVI r1,#NKT_G_NAGFORKS
MOVI r2,2
MOVI r3,132
CALL @stats_chk
MOVI r1,3
MOVI r2,#NAG_PARENT_F
MOVI r3,1
MOVI r4,133
CALL @rec_chk
MOVI r1,3
MOVI r2,#NAG_KVGEN_F
MOVI r3,2
MOVI r4,134
CALL @rec_chk
MOVI r1,3
MOVI r2,3
MOVI r3,3
MOVI r4,135
CALL @ngen_chk
MOVI r1,3
MOVI r2,3
MOVI r3,1
MOVI r4,1
MOVI r5,136
CALL @slot_chk
LA r1,@ctxP
MOVI r2,#NKT_C_CHILDREN
MOVI r3,2
MOVI r4,137
CALL @ctx_chk

; ---- both children read the shared prefix
LA r1,@ctxC1
MOVI r2,0
MOVI r3,10
MOVI r4,0x5000
MOVI r5,5
CALL @rd_range
MOVI r2,1
MOVI r3,138
CALL @chk
LA r1,@ctxC2
MOVI r2,0
MOVI r3,10
MOVI r4,0x5000
MOVI r5,5
CALL @rd_range
MOVI r2,1
MOVI r3,139
CALL @chk
LA r1,@ctxC1
MOVI r2,0
MOVI r3,1
LA r4,@viewC1
CALL @nkvt_view_open
MOVI r2,1
MOVI r3,140
CALL @chk
LA r1,@ctxC2
MOVI r2,0
MOVI r3,1
LA r4,@viewC2
CALL @nkvt_view_open
MOVI r2,1
MOVI r3,141
CALL @chk
MOVI r1,#NKT_G_VOPEN
MOVI r2,34
MOVI r3,142
CALL @stats_chk

; ---- cross-generation view rejection
LA r1,@ctxC1
LA r2,@viewP
MOVI r3,#NKT_EGEN
CALL @read_fail
MOVI r2,1
MOVI r3,143
CALL @chk
LA r1,@ctxC2
LA r2,@viewC1
MOVI r3,#NKT_EGEN
CALL @read_fail
MOVI r2,1
MOVI r3,144
CALL @chk
LA r1,@ctxP
LA r2,@viewC2
MOVI r3,#NKT_EGEN
CALL @read_fail
MOVI r2,1
MOVI r3,145
CALL @chk
MOVI r1,#NKT_G_XGEN
MOVI r2,3
MOVI r3,146
CALL @stats_chk

; ---- shared prefix writes are rejected exactly
LA r1,@ctxP
LA r2,@viewPW
MOVI r3,#NKT_ESHARED
CALL @write_fail
MOVI r2,1
MOVI r3,147
CALL @chk
LA r1,@ctxC1
MOVI r2,0
MOVI r3,2
LA r4,@viewW1
CALL @nkvt_view_open
MOVI r2,1
MOVI r3,148
CALL @chk
LA r1,@ctxC1
LA r2,@viewW1
MOVI r3,#NKT_ESHARED
CALL @write_fail
MOVI r2,1
MOVI r3,149
CALL @chk
MOVI r1,#NKT_G_XSHARED
MOVI r2,2
MOVI r3,150
CALL @stats_chk
MOVI r1,#NKT_G_VOPEN
MOVI r2,35
MOVI r3,151
CALL @stats_chk

; ---- parent publishes gen 6; parent context stays an admitted gen-5 snapshot
LA r1,@ctxP
MOVI r2,6
CALL @nkvt_publish
MOVI r2,10
MOVI r3,152
CALL @chk
LA r1,@ctxP
MOVI r2,#NKT_C_EPOCH
MOVI r3,10
MOVI r4,153
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_GEN
MOVI r3,5
MOVI r4,154
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_ADMIT
MOVI r3,1
MOVI r4,155
CALL @ctx_chk
MOVI r1,1
MOVI r2,3
MOVI r3,6
MOVI r4,156
CALL @ngen_chk
MOVI r1,1
MOVI r2,5
MOVI r3,1
MOVI r4,#NG_S_DRAINING
MOVI r5,157
CALL @slot_chk
MOVI r1,1
MOVI r2,6
MOVI r3,1
MOVI r4,#NG_S_CURRENT
MOVI r5,158
CALL @slot_chk
MOVI r1,#NKT_G_PUBLISH
MOVI r2,1
MOVI r3,159
CALL @stats_chk

; ---- a new context opens at gen 6 on the same branch and rejects gen-5 view
LA r1,@ctxX
MOVI r2,1
MOVI r3,6
MOVI r4,1
MOVI r5,1
MOVI r6,1
LA r7,@tabX
MOVI r8,16
MOVI r9,8
CALL @nkvt_open
MOVI r2,1
MOVI r3,160
CALL @chk
LA r1,@ctxX
MOVI r2,#NKT_C_GEN
MOVI r3,6
MOVI r4,161
CALL @ctx_chk
LA r1,@ctxX
MOVI r2,#NKT_C_BRANCH
MOVI r3,1
MOVI r4,162
CALL @ctx_chk
LA r1,@ctxX
MOVI r2,#NKT_C_USED
MOVI r3,0
MOVI r4,163
CALL @ctx_chk
LA r1,@ctxX
MOVI r2,#NKT_C_LIVE
MOVI r3,0
MOVI r4,164
CALL @ctx_chk
MOVI r1,#NKT_G_OPENS
MOVI r2,2
MOVI r3,165
CALL @stats_chk
LA r1,@ctxX
LA r2,@viewP
MOVI r3,#NKT_EGEN
CALL @read_fail
MOVI r2,1
MOVI r3,166
CALL @chk
MOVI r1,#NKT_G_XGEN
MOVI r2,4
MOVI r3,167
CALL @stats_chk

; ---- a fresh open at the old parent generation fails closed
LA r1,@ctxO
MOVI r2,1
MOVI r3,5
MOVI r4,2
MOVI r5,4
MOVI r6,1
LA r7,@tabO
MOVI r8,16
MOVI r9,8
CALL @nkvt_open
MOVI r2,0
MOVI r3,168
CALL @chk
CALL @nkvt_errno
MOVI r2,#NKT_ESTALE
MOVI r3,169
CALL @chk
LA r1,@ctxO
MOVI r2,#NKT_C_NGERR
MOVI r3,#NG_EDRAIN
MOVI r4,170
CALL @ctx_chk
MOVI r1,#NKT_G_XSTALE
MOVI r2,1
MOVI r3,171
CALL @stats_chk
MOVI r1,1
MOVI r2,5
MOVI r3,1
MOVI r4,#NG_S_DRAINING
MOVI r5,172
CALL @slot_chk

; ---- close the gen-6 scratch context (does not touch the parent snapshot)
LA r1,@ctxX
CALL @nkvt_close
MOVI r2,1
MOVI r3,173
CALL @chk
LA r1,@ctxX
MOVI r2,#NKT_C_ADMIT
MOVI r3,0
MOVI r4,174
CALL @ctx_chk
MOVI r1,#NKT_G_CLOSES
MOVI r2,1
MOVI r3,175
CALL @stats_chk
MOVI r1,1
MOVI r2,6
MOVI r3,2
MOVI r4,0
MOVI r5,176
CALL @slot_chk
LA r1,@ctxP
MOVI r2,#NKT_C_ADMIT
MOVI r3,1
MOVI r4,177
CALL @ctx_chk

; ---- parent appends its own 2-token suffix after the forks
LA r1,@ctxP
MOVI r2,10
MOVI r3,2
MOVI r4,0x6000
CALL @app_seq
MOVI r2,1
MOVI r3,178
CALL @chk
LA r1,@ctxP
MOVI r2,#NKT_C_USED
MOVI r3,12
MOVI r4,179
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_LIVE
MOVI r3,2
MOVI r4,180
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_COPIES
MOVI r3,1
MOVI r4,181
CALL @ctx_chk
MOVI r1,1
MOVI r2,#NKT_P_REFS
MOVI r3,2
MOVI r4,182
CALL @page_chk
MOVI r1,1
MOVI r2,#NKT_P_USED
MOVI r3,2
MOVI r4,183
CALL @page_chk
MOVI r1,2
MOVI r2,#NKT_P_GEN
MOVI r3,5
MOVI r4,184
CALL @page_chk
MOVI r1,2
MOVI r2,#NKT_P_STATE
MOVI r3,1
MOVI r4,185
CALL @page_chk
MOVI r1,2
MOVI r2,#NKT_P_REFS
MOVI r3,1
MOVI r4,186
CALL @page_chk
MOVI r1,2
MOVI r2,#NKT_P_FLAGS
MOVI r3,0
MOVI r4,187
CALL @page_chk
MOVI r1,2
MOVI r2,#NKT_P_USED
MOVI r3,4
MOVI r4,188
CALL @page_chk
MOVI r1,2
MOVI r2,#NS_R_REFS
MOVI r3,2
MOVI r4,189
CALL @root_chk
MOVI r1,1
MOVI r2,#NS_R_REFS
MOVI r3,3
MOVI r4,190
CALL @root_chk
MOVI r1,#NKT_G_COPIES
MOVI r2,1
MOVI r3,191
CALL @stats_chk
MOVI r1,#NKT_G_TCOPY
MOVI r2,2
MOVI r3,192
CALL @stats_chk
MOVI r1,#NKT_G_COWS
MOVI r2,1
MOVI r3,193
CALL @stats_chk
MOVI r1,#NKT_G_ALLOCS
MOVI r2,3
MOVI r3,194
CALL @stats_chk
MOVI r1,#NKT_G_LIVE
MOVI r2,3
MOVI r3,195
CALL @stats_chk
LA r1,@ctxP
MOVI r2,0
MOVI r3,8
MOVI r4,0x5000
MOVI r5,5
CALL @rd_range
MOVI r2,1
MOVI r3,196
CALL @chk
LA r1,@ctxP
MOVI r2,8
MOVI r3,2
MOVI r4,0x5000
MOVI r5,5
CALL @rd_range
MOVI r2,1
MOVI r3,396
CALL @chk
LA r1,@ctxP
MOVI r2,10
MOVI r3,2
MOVI r4,0x6000
MOVI r5,5
CALL @rd_range
MOVI r2,1
MOVI r3,397
CALL @chk

; ---- child1 appends 7 tokens: one boundary COW + one private page
LA r1,@ctxC1
MOVI r2,10
MOVI r3,7
MOVI r4,0x7000
CALL @app_seq
MOVI r2,1
MOVI r3,197
CALL @chk
LA r1,@ctxC1
MOVI r2,#NKT_C_USED
MOVI r3,17
MOVI r4,198
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_LIVE
MOVI r3,3
MOVI r4,199
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_COPIES
MOVI r3,1
MOVI r4,200
CALL @ctx_chk
MOVI r1,1
MOVI r2,#NKT_P_REFS
MOVI r3,1
MOVI r4,201
CALL @page_chk
MOVI r1,3
MOVI r2,#NKT_P_GEN
MOVI r3,2
MOVI r4,202
CALL @page_chk
MOVI r1,3
MOVI r2,#NKT_P_STATE
MOVI r3,1
MOVI r4,203
CALL @page_chk
MOVI r1,3
MOVI r2,#NKT_P_REFS
MOVI r3,1
MOVI r4,204
CALL @page_chk
MOVI r1,3
MOVI r2,#NKT_P_USED
MOVI r3,8
MOVI r4,205
CALL @page_chk
MOVI r1,4
MOVI r2,#NKT_P_GEN
MOVI r3,2
MOVI r4,206
CALL @page_chk
MOVI r1,4
MOVI r2,#NKT_P_USED
MOVI r3,1
MOVI r4,207
CALL @page_chk
MOVI r1,2
MOVI r2,#NS_R_REFS
MOVI r3,1
MOVI r4,208
CALL @root_chk
MOVI r1,#NKT_G_COPIES
MOVI r2,2
MOVI r3,209
CALL @stats_chk
MOVI r1,#NKT_G_TCOPY
MOVI r2,4
MOVI r3,210
CALL @stats_chk
MOVI r1,#NKT_G_ALLOCS
MOVI r2,5
MOVI r3,211
CALL @stats_chk
MOVI r1,#NKT_G_LIVE
MOVI r2,5
MOVI r3,212
CALL @stats_chk
LA r1,@ctxC1
MOVI r2,0
MOVI r3,8
MOVI r4,0x5000
MOVI r5,5
CALL @rd_range
MOVI r2,1
MOVI r3,213
CALL @chk
LA r1,@ctxC1
MOVI r2,8
MOVI r3,2
MOVI r4,0x5000
MOVI r5,2
CALL @rd_range
MOVI r2,1
MOVI r3,214
CALL @chk
LA r1,@ctxC1
MOVI r2,10
MOVI r3,7
MOVI r4,0x7000
MOVI r5,2
CALL @rd_range
MOVI r2,1
MOVI r3,398
CALL @chk

; ---- child2 appends 6 tokens: one boundary COW only;
;      the old shared boundary page frees exactly here
LA r1,@ctxC2
MOVI r2,10
MOVI r3,6
MOVI r4,0x8000
CALL @app_seq
MOVI r2,1
MOVI r3,215
CALL @chk
LA r1,@ctxC2
MOVI r2,#NKT_C_USED
MOVI r3,16
MOVI r4,216
CALL @ctx_chk
LA r1,@ctxC2
MOVI r2,#NKT_C_LIVE
MOVI r3,2
MOVI r4,217
CALL @ctx_chk
LA r1,@ctxC2
MOVI r2,#NKT_C_COPIES
MOVI r3,1
MOVI r4,218
CALL @ctx_chk
MOVI r1,1
MOVI r2,#NKT_P_STATE
MOVI r3,0
MOVI r4,219
CALL @page_chk
MOVI r1,1
MOVI r2,#NKT_P_REFS
MOVI r3,0
MOVI r4,220
CALL @page_chk
MOVI r1,1
MOVI r2,#NKT_P_FREES
MOVI r3,1
MOVI r4,221
CALL @page_chk
MOVI r1,2
MOVI r2,#NS_R_STATE
MOVI r3,0
MOVI r4,222
CALL @root_chk
MOVI r1,2
MOVI r2,#NS_R_REFS
MOVI r3,0
MOVI r4,223
CALL @root_chk
MOVI r1,5
MOVI r2,#NKT_P_GEN
MOVI r3,3
MOVI r4,224
CALL @page_chk
MOVI r1,5
MOVI r2,#NKT_P_USED
MOVI r3,8
MOVI r4,225
CALL @page_chk
MOVI r1,6
MOVI r2,#NKT_P_STATE
MOVI r3,0
MOVI r4,226
CALL @page_chk
MOVI r1,6
MOVI r2,#NKT_P_REFS
MOVI r3,0
MOVI r4,227
CALL @page_chk
MOVI r1,#NKT_G_COPIES
MOVI r2,3
MOVI r3,228
CALL @stats_chk
MOVI r1,#NKT_G_TCOPY
MOVI r2,6
MOVI r3,229
CALL @stats_chk
MOVI r1,#NKT_G_ALLOCS
MOVI r2,6
MOVI r3,230
CALL @stats_chk
MOVI r1,#NKT_G_FREES
MOVI r2,1
MOVI r3,231
CALL @stats_chk
MOVI r1,#NKT_G_LIVE
MOVI r2,5
MOVI r3,232
CALL @stats_chk
LA r1,@ctxC2
MOVI r2,0
MOVI r3,8
MOVI r4,0x5000
MOVI r5,5
CALL @rd_range
MOVI r2,1
MOVI r3,233
CALL @chk
LA r1,@ctxC2
MOVI r2,8
MOVI r3,2
MOVI r4,0x5000
MOVI r5,3
CALL @rd_range
MOVI r2,1
MOVI r3,234
CALL @chk
LA r1,@ctxC2
MOVI r2,10
MOVI r3,6
MOVI r4,0x8000
MOVI r5,3
CALL @rd_range
MOVI r2,1
MOVI r3,399
CALL @chk

; ---- exact final page/root refcounts before any close
MOVI r1,0
MOVI r2,#NKT_P_REFS
MOVI r3,3
MOVI r4,235
CALL @page_chk
MOVI r1,0
MOVI r2,#NKT_P_FLAGS
MOVI r3,1
MOVI r4,236
CALL @page_chk
MOVI r1,0
MOVI r2,#NKT_P_USED
MOVI r3,8
MOVI r4,237
CALL @page_chk
MOVI r1,1
MOVI r2,#NS_R_REFS
MOVI r3,3
MOVI r4,238
CALL @root_chk
MOVI r1,15
MOVI r2,#NS_R_REFS
MOVI r3,3
MOVI r4,239
CALL @root_chk
MOVI r1,2
MOVI r2,#NKT_P_REFS
MOVI r3,1
MOVI r4,240
CALL @page_chk
MOVI r1,3
MOVI r2,#NKT_P_REFS
MOVI r3,1
MOVI r4,241
CALL @page_chk
MOVI r1,4
MOVI r2,#NKT_P_REFS
MOVI r3,1
MOVI r4,242
CALL @page_chk
MOVI r1,5
MOVI r2,#NKT_P_REFS
MOVI r3,1
MOVI r4,243
CALL @page_chk
MOVI r1,6
MOVI r2,#NKT_P_REFS
MOVI r3,0
MOVI r4,244
CALL @page_chk
MOVI r1,#NKT_G_MIRERR
MOVI r2,0
MOVI r3,245
CALL @stats_chk
LA r1,@ctxP
MOVI r2,#NKT_C_USED
MOVI r3,12
MOVI r4,246
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_USED
MOVI r3,17
MOVI r4,247
CALL @ctx_chk
LA r1,@ctxC2
MOVI r2,#NKT_C_USED
MOVI r3,16
MOVI r4,248
CALL @ctx_chk

; ---- sibling/parent value isolation and record generations
LA r1,@ctxP
MOVI r2,10
MOVI r3,0x600A
MOVI r4,5
CALL @rdok
MOVI r2,1
MOVI r3,249
CALL @chk
LA r1,@ctxC1
MOVI r2,10
MOVI r3,0x700A
MOVI r4,2
CALL @rdok
MOVI r2,1
MOVI r3,250
CALL @chk
LA r1,@ctxC2
MOVI r2,10
MOVI r3,0x800A
MOVI r4,3
CALL @rdok
MOVI r2,1
MOVI r3,251
CALL @chk
LA r1,@ctxP
MOVI r2,11
MOVI r3,0x600B
MOVI r4,5
CALL @rdok
MOVI r2,1
MOVI r3,252
CALL @chk
LA r1,@ctxC1
MOVI r2,16
MOVI r3,0x7010
MOVI r4,2
CALL @rdok
MOVI r2,1
MOVI r3,253
CALL @chk
LA r1,@ctxC2
MOVI r2,15
MOVI r3,0x800F
MOVI r4,3
CALL @rdok
MOVI r2,1
MOVI r3,254
CALL @chk
LA r1,@ctxC1
MOVI r2,8
MOVI r3,0x5008
MOVI r4,2
CALL @rdok
MOVI r2,1
MOVI r3,255
CALL @chk
LA r1,@ctxC2
MOVI r2,9
MOVI r3,0x5009
MOVI r4,3
CALL @rdok
MOVI r2,1
MOVI r3,256
CALL @chk

ADDI r14,r14,-16
LD r15,r14,0
RET

; ---------------------------------------------------------------------------
; close1 - close child1; order independent child-local checks.
close1:
ST r15,r14,0
ADDI r14,r14,16
LA r1,@ctxC1
CALL @nkvt_close
MOVI r2,1
MOVI r3,260
CALL @chk
LA r1,@ctxC1
MOVI r2,#NKT_C_ADMIT
MOVI r3,0
MOVI r4,261
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_LIVE
MOVI r3,0
MOVI r4,262
CALL @ctx_chk
LA r1,@ctxC1
MOVI r2,#NKT_C_USED
MOVI r3,0
MOVI r4,263
CALL @ctx_chk
MOVI r1,3
MOVI r2,#NKT_P_STATE
MOVI r3,0
MOVI r4,264
CALL @page_chk
MOVI r1,3
MOVI r2,#NKT_P_FREES
MOVI r3,1
MOVI r4,265
CALL @page_chk
MOVI r1,4
MOVI r2,#NKT_P_STATE
MOVI r3,0
MOVI r4,266
CALL @page_chk
MOVI r1,4
MOVI r2,#NKT_P_FREES
MOVI r3,1
MOVI r4,267
CALL @page_chk
MOVI r1,2
MOVI r2,3
MOVI r3,2
MOVI r4,268
CALL @ngen_chk
MOVI r1,2
MOVI r2,2
MOVI r3,2
MOVI r4,0
MOVI r5,269
CALL @slot_chk
MOVI r1,2
MOVI r2,2
MOVI r3,4
MOVI r4,1
MOVI r5,270
CALL @slot_chk
ADDI r14,r14,-16
LD r15,r14,0
RET

; close2 - close child2; order independent child-local checks.
close2:
ST r15,r14,0
ADDI r14,r14,16
LA r1,@ctxC2
CALL @nkvt_close
MOVI r2,1
MOVI r3,280
CALL @chk
LA r1,@ctxC2
MOVI r2,#NKT_C_ADMIT
MOVI r3,0
MOVI r4,281
CALL @ctx_chk
LA r1,@ctxC2
MOVI r2,#NKT_C_LIVE
MOVI r3,0
MOVI r4,282
CALL @ctx_chk
LA r1,@ctxC2
MOVI r2,#NKT_C_USED
MOVI r3,0
MOVI r4,283
CALL @ctx_chk
MOVI r1,5
MOVI r2,#NKT_P_STATE
MOVI r3,0
MOVI r4,284
CALL @page_chk
MOVI r1,5
MOVI r2,#NKT_P_FREES
MOVI r3,1
MOVI r4,285
CALL @page_chk
MOVI r1,6
MOVI r2,#NKT_P_STATE
MOVI r3,0
MOVI r4,286
CALL @page_chk
MOVI r1,6
MOVI r2,#NKT_P_FREES
MOVI r3,0
MOVI r4,287
CALL @page_chk
MOVI r1,3
MOVI r2,3
MOVI r3,3
MOVI r4,288
CALL @ngen_chk
MOVI r1,3
MOVI r2,3
MOVI r3,2
MOVI r4,0
MOVI r5,289
CALL @slot_chk
MOVI r1,3
MOVI r2,3
MOVI r3,4
MOVI r4,1
MOVI r5,290
CALL @slot_chk
ADDI r14,r14,-16
LD r15,r14,0
RET

; close_both_checks - after both children, the shared page/root is at 1.
close_both_checks:
ST r15,r14,0
ADDI r14,r14,16
MOVI r1,0
MOVI r2,#NKT_P_REFS
MOVI r3,1
MOVI r4,291
CALL @page_chk
MOVI r1,0
MOVI r2,#NKT_P_STATE
MOVI r3,1
MOVI r4,292
CALL @page_chk
MOVI r1,1
MOVI r2,#NS_R_REFS
MOVI r3,1
MOVI r4,293
CALL @root_chk
MOVI r1,1
MOVI r2,#NS_R_STATE
MOVI r3,1
MOVI r4,294
CALL @root_chk
MOVI r1,15
MOVI r2,#NS_R_REFS
MOVI r3,1
MOVI r4,295
CALL @root_chk
MOVI r1,#NKT_G_MIRERR
MOVI r2,0
MOVI r3,296
CALL @stats_chk
ADDI r14,r14,-16
LD r15,r14,0
RET

; close_parent - closes the root agent; frees the last prefix page and roots.
close_parent:
ST r15,r14,0
ADDI r14,r14,16
LA r1,@ctxP
CALL @nkvt_close
MOVI r2,1
MOVI r3,300
CALL @chk
LA r1,@ctxP
MOVI r2,#NKT_C_ADMIT
MOVI r3,0
MOVI r4,301
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_LIVE
MOVI r3,0
MOVI r4,302
CALL @ctx_chk
LA r1,@ctxP
MOVI r2,#NKT_C_USED
MOVI r3,0
MOVI r4,303
CALL @ctx_chk
MOVI r1,0
MOVI r2,#NKT_P_STATE
MOVI r3,0
MOVI r4,304
CALL @page_chk
MOVI r1,0
MOVI r2,#NKT_P_REFS
MOVI r3,0
MOVI r4,305
CALL @page_chk
MOVI r1,0
MOVI r2,#NKT_P_FREES
MOVI r3,1
MOVI r4,306
CALL @page_chk
MOVI r1,2
MOVI r2,#NKT_P_STATE
MOVI r3,0
MOVI r4,307
CALL @page_chk
MOVI r1,2
MOVI r2,#NKT_P_FREES
MOVI r3,1
MOVI r4,308
CALL @page_chk
MOVI r1,1
MOVI r2,#NS_R_STATE
MOVI r3,0
MOVI r4,309
CALL @root_chk
MOVI r1,1
MOVI r2,#NS_R_REFS
MOVI r3,0
MOVI r4,310
CALL @root_chk
MOVI r1,15
MOVI r2,#NS_R_STATE
MOVI r3,0
MOVI r4,311
CALL @root_chk
MOVI r1,15
MOVI r2,#NS_R_REFS
MOVI r3,0
MOVI r4,312
CALL @root_chk
MOVI r1,1
MOVI r2,3
MOVI r3,6
MOVI r4,313
CALL @ngen_chk
MOVI r1,1
MOVI r2,5
MOVI r3,1
MOVI r4,#NG_S_DRAINED
MOVI r5,314
CALL @slot_chk
MOVI r1,1
MOVI r2,6
MOVI r3,1
MOVI r4,#NG_S_CURRENT
MOVI r5,315
CALL @slot_chk
MOVI r1,1
MOVI r2,5
MOVI r3,2
MOVI r4,0
MOVI r5,316
CALL @slot_chk
MOVI r1,#NKT_G_CLOSES
MOVI r2,4
MOVI r3,317
CALL @stats_chk
ADDI r14,r14,-16
LD r15,r14,0
RET

; ---------------------------------------------------------------------------
; final_checks - exact totals after both close orders land in the same state.
final_checks:
ST r15,r14,0
ADDI r14,r14,16
; tree-generation trace is populated and its first entry is the parent open
MOVI r1,0
LA r2,@ntr
CALL @nkvt_trace
MOVI r2,0
MOVI r3,404
CALL @chk
LA r1,@ntr
MOVI r2,0
MOVI r3,#NKT_T_OPEN
MOVI r4,405
CALL @chkrec
LA r1,@ntr
MOVI r2,1
MOVI r3,0
MOVI r4,406
CALL @chkrec
LA r1,@ntr
MOVI r2,2
MOVI r3,1
MOVI r4,407
CALL @chkrec
LA r1,@ntr
MOVI r2,3
MOVI r3,5
MOVI r4,408
CALL @chkrec
MOVI r1,#NKT_G_TEVENTS
MOVI r2,20
MOVI r3,409
CALL @stats_chk
CALL @nkvt_trace_head
CMP r1,r0
JMP[NE] @tk_head_ok
MOVI r1,0
MOVI r2,1
MOVI r3,410
CALL @chk
tk_head_ok:
; old parent view after close is stale
LA r1,@ctxP
LA r2,@viewP
MOVI r3,#NKT_ESTALE
CALL @read_fail
MOVI r2,1
MOVI r3,320
CALL @chk
; page registry: all six allocated pages free, page 6+ untouched
MOVI r1,0
MOVI r2,#NKT_P_REFS
MOVI r3,0
MOVI r4,321
CALL @page_chk
MOVI r1,1
MOVI r2,#NKT_P_USED
MOVI r3,2
MOVI r4,322
CALL @page_chk
MOVI r1,1
MOVI r2,#NKT_P_COPIES
MOVI r3,3
MOVI r4,323
CALL @page_chk
MOVI r1,1
MOVI r2,#NKT_P_TCOPY
MOVI r3,6
MOVI r4,324
CALL @page_chk
MOVI r1,2
MOVI r2,#NKT_P_STATE
MOVI r3,0
MOVI r4,325
CALL @page_chk
MOVI r1,3
MOVI r2,#NKT_P_STATE
MOVI r3,0
MOVI r4,326
CALL @page_chk
MOVI r1,4
MOVI r2,#NKT_P_STATE
MOVI r3,0
MOVI r4,327
CALL @page_chk
MOVI r1,5
MOVI r2,#NKT_P_STATE
MOVI r3,0
MOVI r4,328
CALL @page_chk
MOVI r1,6
MOVI r2,#NKT_P_STATE
MOVI r3,0
MOVI r4,329
CALL @page_chk
MOVI r1,7
MOVI r2,#NKT_P_STATE
MOVI r3,0
MOVI r4,330
CALL @page_chk
MOVI r1,#NKT_G_LIVE
MOVI r2,0
MOVI r3,331
CALL @stats_chk
MOVI r1,#NKT_G_ALLOCS
MOVI r2,6
MOVI r3,332
CALL @stats_chk
MOVI r1,#NKT_G_FREES
MOVI r2,6
MOVI r3,333
CALL @stats_chk
MOVI r1,#NKT_G_JOINS
MOVI r2,4
MOVI r3,334
CALL @stats_chk
MOVI r1,#NKT_G_LEAVES
MOVI r2,10
MOVI r3,335
CALL @stats_chk
MOVI r1,#NKT_G_COPIES
MOVI r2,3
MOVI r3,336
CALL @stats_chk
MOVI r1,#NKT_G_TCOPY
MOVI r2,6
MOVI r3,337
CALL @stats_chk
MOVI r1,#NKT_G_FORKS
MOVI r2,2
MOVI r3,338
CALL @stats_chk
MOVI r1,#NKT_G_OPENS
MOVI r2,2
MOVI r3,339
CALL @stats_chk
MOVI r1,#NKT_G_SEALS
MOVI r2,1
MOVI r3,340
CALL @stats_chk
MOVI r1,#NKT_G_VOPEN
MOVI r2,88
MOVI r3,341
CALL @stats_chk
MOVI r1,#NKT_G_VREAD
MOVI r2,83
MOVI r3,342
CALL @stats_chk
MOVI r1,#NKT_G_VWRITE
MOVI r2,0
MOVI r3,343
CALL @stats_chk
MOVI r1,#NKT_G_XGEN
MOVI r2,4
MOVI r3,344
CALL @stats_chk
MOVI r1,#NKT_G_XSTALE
MOVI r2,2
MOVI r3,345
CALL @stats_chk
MOVI r1,#NKT_G_XSHARED
MOVI r2,2
MOVI r3,346
CALL @stats_chk
MOVI r1,#NKT_G_ERRORS
MOVI r2,8
MOVI r3,347
CALL @stats_chk
MOVI r1,#NKT_G_RCREATE
MOVI r2,2
MOVI r3,348
CALL @stats_chk
MOVI r1,#NKT_G_RACQ
MOVI r2,9
MOVI r3,349
CALL @stats_chk
MOVI r1,#NKT_G_RREL
MOVI r2,9
MOVI r3,350
CALL @stats_chk
MOVI r1,#NKT_G_RFREE
MOVI r2,3
MOVI r3,351
CALL @stats_chk
MOVI r1,#NKT_G_MIRERR
MOVI r2,0
MOVI r3,352
CALL @stats_chk
MOVI r1,#NKT_G_CLOSES
MOVI r2,4
MOVI r3,353
CALL @stats_chk
MOVI r1,#NKT_G_COWS
MOVI r2,3
MOVI r3,354
CALL @stats_chk
MOVI r1,#NKT_G_PREFIXP
MOVI r2,2
MOVI r3,355
CALL @stats_chk
MOVI r1,#NKT_G_NAGFORKS
MOVI r2,2
MOVI r3,356
CALL @stats_chk
MOVI r1,#NKT_G_BINDS
MOVI r2,1
MOVI r3,357
CALL @stats_chk
MOVI r1,#NKT_G_PUBLISH
MOVI r2,1
MOVI r3,358
CALL @stats_chk

; nsym global exact
MOVI r1,#NS_G_RCREATE
MOVI r2,3
MOVI r3,359
CALL @nsg_chk
MOVI r1,#NS_G_RACQ
MOVI r2,9
MOVI r3,360
CALL @nsg_chk
MOVI r1,#NS_G_RREL
MOVI r2,9
MOVI r3,361
CALL @nsg_chk
MOVI r1,#NS_G_RFREE
MOVI r2,3
MOVI r3,362
CALL @nsg_chk
MOVI r1,#NS_G_TRN
MOVI r2,6
MOVI r3,363
CALL @nsg_chk
MOVI r1,1
MOVI r2,#NS_R_STATE
MOVI r3,0
MOVI r4,364
CALL @root_chk
MOVI r1,2
MOVI r2,#NS_R_STATE
MOVI r3,0
MOVI r4,365
CALL @root_chk
MOVI r1,15
MOVI r2,#NS_R_STATE
MOVI r3,0
MOVI r4,366
CALL @root_chk

; nagent records remain live with independent child KV generations
MOVI r1,1
MOVI r2,#NAG_STATE_F
MOVI r3,1
MOVI r4,367
CALL @rec_chk
MOVI r1,1
MOVI r2,#NAG_KVGEN_F
MOVI r3,1
MOVI r4,368
CALL @rec_chk
MOVI r1,2
MOVI r2,#NAG_STATE_F
MOVI r3,1
MOVI r4,369
CALL @rec_chk
MOVI r1,2
MOVI r2,#NAG_KVGEN_F
MOVI r3,2
MOVI r4,370
CALL @rec_chk
MOVI r1,3
MOVI r2,#NAG_STATE_F
MOVI r3,1
MOVI r4,371
CALL @rec_chk
MOVI r1,3
MOVI r2,#NAG_KVGEN_F
MOVI r3,2
MOVI r4,372
CALL @rec_chk

; ngen end state: agent1 current 6, children at 2 and 3
MOVI r1,1
MOVI r2,3
MOVI r3,6
MOVI r4,373
CALL @ngen_chk
MOVI r1,2
MOVI r2,3
MOVI r3,2
MOVI r4,374
CALL @ngen_chk
MOVI r1,3
MOVI r2,3
MOVI r3,3
MOVI r4,375
CALL @ngen_chk

ADDI r14,r14,-16
LD r15,r14,0
RET

; ---------------------------------------------------------------------------
; app_seq r1=ctx r2=first token r3=count r4=base value -> 1/0.
app_seq:
ST r15,r14,0
ADDI r14,r14,32
ST r1,r14,1
ST r2,r14,2
ST r3,r14,3
ST r4,r14,4
MOVI r5,0
ST r5,r14,5
as_l:
LD r5,r14,5
LD r3,r14,3
CMP r5,r3
JMP[GE] @as_ok
LD r2,r14,2
ADD r2,r2,r5
ST r2,r14,6
LD r4,r14,4
ADD r4,r4,r2
LD r1,r14,1
ADD r2,r4,r0
CALL @nkvt_append
LD r3,r14,6
CMP r1,r3
JMP[NE] @as_bad
LD r5,r14,5
ADD r5,r5,r13
ST r5,r14,5
JMP @as_l
as_ok:
MOVI r1,1
JMP @as_out
as_bad:
MOVI r1,0
as_out:
ADDI r14,r14,-32
LD r15,r14,0
RET

; rdok r1=ctx r2=token r3=value r4=record gen -> 1/0.
rdok:
ST r15,r14,0
ADDI r14,r14,40
ST r1,r14,1
ST r2,r14,2
ST r3,r14,3
ST r4,r14,4
LD r1,r14,1
LD r2,r14,2
MOVI r3,1
LA r4,@viewS
CALL @nkvt_view_open
CMP r1,r0
JMP[EQ] @rd_bad
LD r1,r14,1
LA r2,@viewS
LA r3,@out4
CALL @nkvt_view_read
CMP r1,r0
JMP[EQ] @rd_bad
LA r1,@out4
LD r2,r1,0
LD r3,r14,2
CMP r2,r3
JMP[NE] @rd_bad
LD r2,r1,1
LD r3,r14,3
CMP r2,r3
JMP[NE] @rd_bad
LD r2,r1,2
LA r3,#NKT_REC_TAG
CMP r2,r3
JMP[NE] @rd_bad
LD r2,r1,3
LD r3,r14,4
CMP r2,r3
JMP[NE] @rd_bad
MOVI r1,1
JMP @rd_out
rd_bad:
MOVI r1,0
rd_out:
ADDI r14,r14,-40
LD r15,r14,0
RET

; rd_range r1=ctx r2=first r3=count r4=base value r5=record gen -> 1/0.
rd_range:
ST r15,r14,0
ADDI r14,r14,40
ST r1,r14,1
ST r2,r14,2
ST r3,r14,3
ST r4,r14,4
ST r5,r14,5
MOVI r6,0
ST r6,r14,6
rr_l:
LD r6,r14,6
LD r3,r14,3
CMP r6,r3
JMP[GE] @rr_ok
LD r2,r14,2
ADD r2,r2,r6
ST r2,r14,7
LD r4,r14,4
ADD r4,r4,r2
LD r1,r14,1
ADD r3,r4,r0
LD r4,r14,5
CALL @rdok
CMP r1,r0
JMP[EQ] @rr_bad
LD r6,r14,6
ADD r6,r6,r13
ST r6,r14,6
JMP @rr_l
rr_ok:
MOVI r1,1
JMP @rr_out
rr_bad:
MOVI r1,0
rr_out:
ADDI r14,r14,-40
LD r15,r14,0
RET

; read_fail r1=ctx r2=view r3=expected errno -> 1 if read fails with errno.
read_fail:
ST r15,r14,0
ADDI r14,r14,24
ST r1,r14,1
ST r2,r14,2
ST r3,r14,3
LD r1,r14,1
LD r2,r14,2
LA r3,@out4
CALL @nkvt_view_read
CMP r1,r0
JMP[NE] @rf_bad
CALL @nkvt_errno
LD r2,r14,3
CMP r1,r2
JMP[NE] @rf_bad
MOVI r1,1
JMP @rf_out
rf_bad:
MOVI r1,0
rf_out:
ADDI r14,r14,-24
LD r15,r14,0
RET

; write_fail r1=ctx r2=view r3=expected errno -> 1 if write fails with errno.
write_fail:
ST r15,r14,0
ADDI r14,r14,24
ST r1,r14,1
ST r2,r14,2
ST r3,r14,3
LD r1,r14,1
LD r2,r14,2
MOVI r3,0xDEAD
CALL @nkvt_view_write
CMP r1,r0
JMP[NE] @wf_bad
CALL @nkvt_errno
LD r2,r14,3
CMP r1,r2
JMP[NE] @wf_bad
MOVI r1,1
JMP @wf_out
wf_bad:
MOVI r1,0
wf_out:
ADDI r14,r14,-24
LD r15,r14,0
RET

; ctx_chk r1=ctx r2=field r3=expected r4=diag.
ctx_chk:
ST r15,r14,0
ADDI r14,r14,24
ST r2,r14,1
ST r3,r14,2
ST r4,r14,3
LA r2,@ci
CALL @nkvt_ctx_info
MOVI r2,0
MOVI r3,900
CALL @chk
LA r1,@ci
LD r2,r14,1
LD r3,r14,2
LD r4,r14,3
CALL @chkrec
ADDI r14,r14,-24
LD r15,r14,0
RET

; page_chk r1=index r2=field r3=expected r4=diag.
page_chk:
ST r15,r14,0
ADDI r14,r14,24
ST r2,r14,1
ST r3,r14,2
ST r4,r14,3
LA r2,@pi
CALL @nkvt_page_info
MOVI r2,0
MOVI r3,901
CALL @chk
LA r1,@pi
LD r2,r14,1
LD r3,r14,2
LD r4,r14,3
CALL @chkrec
ADDI r14,r14,-24
LD r15,r14,0
RET

; root_chk r1=root r2=field r3=expected r4=diag.
root_chk:
ST r15,r14,0
ADDI r14,r14,24
ST r2,r14,1
ST r3,r14,2
ST r4,r14,3
LA r2,@nsst
CALL @nsym_root_status
MOVI r2,0
MOVI r3,902
CALL @chk
LA r1,@nsst
LD r2,r14,1
LD r3,r14,2
LD r4,r14,3
CALL @chkrec
ADDI r14,r14,-24
LD r15,r14,0
RET

; rec_chk r1=id r2=field r3=expected r4=diag.
rec_chk:
ST r15,r14,0
ADDI r14,r14,32
ST r2,r14,1
ST r3,r14,2
ST r4,r14,3
CALL @nagent_record
CMP r1,r0
JMP[NE] @rc_have
MOVI r1,0
MOVI r2,1
MOVI r3,903
CALL @chk
rc_have:
ST r1,r14,4
LD r2,r14,1
ADD r1,r1,r2
LD r1,r1,0
LD r2,r14,2
LD r3,r14,3
CALL @chk
ADDI r14,r14,-32
LD r15,r14,0
RET

; stats_chk r1=field r2=expected r3=diag.
stats_chk:
ST r15,r14,0
ADDI r14,r14,24
ST r1,r14,1
ST r2,r14,2
ST r3,r14,3
LA r1,@stats
CALL @nkvt_stats
LA r1,@stats
LD r2,r14,1
LD r3,r14,2
LD r4,r14,3
CALL @chkrec
ADDI r14,r14,-24
LD r15,r14,0
RET

; nsg_chk r1=field r2=expected r3=diag.
nsg_chk:
ST r15,r14,0
ADDI r14,r14,24
ST r1,r14,1
ST r2,r14,2
ST r3,r14,3
LA r1,@nsg
CALL @nsym_global
LA r1,@nsg
LD r2,r14,1
LD r3,r14,2
LD r4,r14,3
CALL @chkrec
ADDI r14,r14,-24
LD r15,r14,0
RET

; ngen_chk r1=agent r2=field r3=expected r4=diag.
ngen_chk:
ST r15,r14,0
ADDI r14,r14,24
ST r2,r14,1
ST r3,r14,2
ST r4,r14,3
LA r2,@st
CALL @ngen_status
LA r1,@st
LD r2,r14,1
LD r3,r14,2
LD r4,r14,3
CALL @chkrec
ADDI r14,r14,-24
LD r15,r14,0
RET

; slot_chk r1=agent r2=gen r3=field r4=expected r5=diag.
slot_chk:
ST r15,r14,0
ADDI r14,r14,32
ST r3,r14,1
ST r4,r14,2
ST r5,r14,3
LA r3,@slot
CALL @ngen_slot
LA r1,@slot
LD r2,r14,1
LD r3,r14,2
LD r4,r14,3
CALL @chkrec
ADDI r14,r14,-32
LD r15,r14,0
RET

; view_chk r1=view base r2=field r3=expected r4=diag.
view_chk:
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

; snapshot r1=out(3344): 5 contexts, page registry, stats, payload buffers,
; nsym roots, nsym global, 3 nagent records, 3 ngen statuses, trace ring.
snapshot:
ST r15,r14,0
ADDI r14,r14,24
ST r1,r14,1
; five contexts (160 words)
LA r2,@ctxP
LD r1,r14,1
MOVI r3,160
CALL @copyw
; page registry (512)
LA r2,#NKT_TAB
LD r1,r14,1
ADDI r1,r1,160
MOVI r3,512
CALL @copyw
; stats (48)
LA r2,#NKT_STATS
LD r1,r14,1
ADDI r1,r1,672
MOVI r3,48
CALL @copyw
; page payload buffers (512)
LA r2,@pdata
LD r1,r14,1
ADDI r1,r1,720
MOVI r3,512
CALL @copyw
; nsym root table (512)
LA r2,#NS_ROOT_TAB
LD r1,r14,1
ADDI r1,r1,1232
MOVI r3,512
CALL @copyw
; nsym global (32)
LA r2,#NS_GLOBAL
LD r1,r14,1
ADDI r1,r1,1744
MOVI r3,32
CALL @copyw
; nagent records 1..3 (960)
LA r2,#NAG_TAB
LD r1,r14,1
ADDI r1,r1,1776
MOVI r3,960
CALL @copyw
; ngen status agents 1..3 (96)
MOVI r1,1
LD r2,r14,1
ADDI r2,r2,2736
CALL @ngen_status
MOVI r1,2
LD r2,r14,1
ADDI r2,r2,2768
CALL @ngen_status
MOVI r1,3
LD r2,r14,1
ADDI r2,r2,2800
CALL @ngen_status
; trace ring (512)
LA r2,#NKT_TRACE
LD r1,r14,1
ADDI r1,r1,2832
MOVI r3,512
CALL @copyw
ADDI r14,r14,-24
LD r15,r14,0
RET

; copyw r1=dst r2=src r3=words.
copyw:
CMP r3,r0
JMP[EQ] @cw_ok
LD r4,r2,0
ST r4,r1,0
ADD r1,r1,r13
ADD r2,r2,r13
SUB r3,r3,r13
JMP @copyw
cw_ok:
RET

; cmpbuf r1=a r2=b r3=words -> 0 equal / 1 different.
cmpbuf:
CMP r3,r0
JMP[EQ] @cb_ok
LD r4,r1,0
LD r5,r2,0
CMP r4,r5
JMP[NE] @cb_bad
ADD r1,r1,r13
ADD r2,r2,r13
SUB r3,r3,r13
JMP @cmpbuf
cb_bad:
MOVI r1,1
RET
cb_ok:
MOVI r1,0
RET

; chkrec r1=base r2=offset r3=expected r4=diag.
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

; chk r1=actual r2=expected r3=diag.  Failure prints F=actual,expected,diag.
chk:
CMP r1,r2
JMP[EQ] @chk_ok
ST r15,r14,0
ADDI r14,r14,24
ST r1,r14,1
ST r2,r14,2
ST r3,r14,3
LD r1,r14,1
CALL @putdec3
MOVI r1,44
PUTC r1
LD r1,r14,2
CALL @putdec3
MOVI r1,44
PUTC r1
LD r1,r14,3
CALL @putdec3
MOVI r1,10
PUTC r1
HALT
chk_ok:
MOVI r1,0
RET

; putdec3 r1=0..999 -> three decimal digits.
putdec3:
ST r15,r14,0
ADDI r14,r14,16
ST r1,r14,1
MOVI r2,100
DIVU r3,r1,r2
MOVI r4,48
ADD r3,r3,r4
PUTC r3
LD r1,r14,1
MOVI r2,100
MODU r1,r1,r2
MOVI r2,10
DIVU r3,r1,r2
ADD r3,r3,r4
PUTC r3
MODU r1,r1,r2
ADD r1,r1,r4
PUTC r1
ADDI r14,r14,-16
LD r15,r14,0
RET

; ---------------------------------------------------------------------------
.org 0x24000
ctxP:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ctxC1:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ctxC2:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ctxX:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ctxO:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tabP:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tabC1:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tabC2:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tabX:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tabO:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
viewP:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
viewPW:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
viewC1:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
viewC2:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
viewW1:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
viewS:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
out4:
.word 0,0,0,0
order:
.word 0
wpay:
.word 0x1111,0x2222,0x3333,0x4444
ci:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
pi:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
st:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
slot:
.word 0,0,0,0,0,0,0,0
stats:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
nsst:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ntr:
.word 0,0,0,0,0,0,0,0
nsg:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

.org 0x28000
pdata:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

.org 0x40000
snapA1:
.word 0,0,0,0,0,0,0,0

.org 0x50000
snapB1:
.word 0,0,0,0,0,0,0,0

.org 0x60000
snapA2:
.word 0,0,0,0,0,0,0,0

.org 0x70000
snapB2:
.word 0,0,0,0,0,0,0,0
