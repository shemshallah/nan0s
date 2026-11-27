; nkvgen_test.nas - generation-tagged KV pages/views + COW prefix fork.
;
; Scenario (run twice from a cold init and compared word-for-word):
;   ngen agent 1 reaches generation 5.  A parent KV branch enters gen 5 and
;   appends a 10-token prefix (2 pages of 8, the second partial).  Fork
;   publishes gen 6, shares both prefix pages read-only and admits the child
;   at gen 6.  Parent and child both read the prefix.  A parent view presented
;   to the child context and a child view presented to the parent context are
;   rejected with EGEN.  A new open at the old gen 5 is rejected with ESTALE
;   and ngen EDRAIN.  The child appends 7 divergent tokens: the first append
;   COW-copies only the 2-token partial boundary page (not the 8-token prefix
;   page), later appends stay private, and one new block is allocated.  The
;   parent still reads its 10 prefix tokens, unchanged.  The child reads its
;   copied 2-token boundary at gen 6 and its own 7-token suffix.  Writes to
;   shared prefix pages fail with ESHARED.  Child close leaves the parent
;   pages with refcount 1 and frees exactly the child's COW/new pages; parent
;   close frees the remaining two pages.  Page refcounts, join/leave/free
;   counters and the ngen DRAINING/DRAINED states are checked exactly.
;
; Success prints exactly O.  A failed check prints F=actual,expected,diag.

.org 0
JMP @main

.org 0x10000
.include "../lib/nkvgen.nas"

main:
MOVI r13,1
MOVI r14,0x7000

; ---- run 1
CALL @cold
CALL @setup_gen5
CALL @scenario
LA r1,@snapA
CALL @snapshot

; ---- run 2 (identical cold state)
CALL @cold
CALL @setup_gen5
CALL @scenario
LA r1,@snapB
CALL @snapshot

; ---- deterministic rerun
LA r1,@snapA
LA r2,@snapB
MOVI r3,1184
CALL @cmpbuf
MOVI r2,0
MOVI r3,999
CALL @chk

MOVI r1,79
PUTC r1
HALT

; ---------------------------------------------------------------------------
cold:
ST r15,r14,0
ADDI r14,r14,16
CALL @nobj_init
CALL @ngen_init
LA r1,@pdata
MOVI r2,8
CALL @nkvgen_init
ADDI r14,r14,-16
LD r15,r14,0
RET

; setup_gen5 - ngen agent 1: start/drain 1..4, then start 5 (epoch 9).
setup_gen5:
ST r15,r14,0
ADDI r14,r14,16
MOVI r1,1
MOVI r2,0x1000
MOVI r3,0x2000
CALL @ngen_create
MOVI r2,0
MOVI r3,40
CALL @chk
MOVI r1,1
MOVI r2,1
CALL @ngen_start
MOVI r2,1
MOVI r3,41
CALL @chk
MOVI r1,1
CALL @ngen_drain
MOVI r2,2
MOVI r3,42
CALL @chk
MOVI r1,1
MOVI r2,2
CALL @ngen_start
MOVI r2,3
MOVI r3,43
CALL @chk
MOVI r1,1
CALL @ngen_drain
MOVI r2,4
MOVI r3,44
CALL @chk
MOVI r1,1
MOVI r2,3
CALL @ngen_start
MOVI r2,5
MOVI r3,45
CALL @chk
MOVI r1,1
CALL @ngen_drain
MOVI r2,6
MOVI r3,46
CALL @chk
MOVI r1,1
MOVI r2,4
CALL @ngen_start
MOVI r2,7
MOVI r3,47
CALL @chk
MOVI r1,1
CALL @ngen_drain
MOVI r2,8
MOVI r3,48
CALL @chk
MOVI r1,1
MOVI r2,5
CALL @ngen_start
MOVI r2,9
MOVI r3,49
CALL @chk
MOVI r1,1
LA r2,@st
CALL @ngen_status
LA r1,@st
MOVI r2,3
MOVI r3,5
MOVI r4,50
CALL @chkrec
ADDI r14,r14,-16
LD r15,r14,0
RET

; ---------------------------------------------------------------------------
scenario:
ST r15,r14,0
ADDI r14,r14,16

; ---- open the parent branch at gen 5
LA r1,@ctxP
MOVI r2,1
MOVI r3,5
MOVI r4,0
MOVI r5,1
LA r6,@tabP
MOVI r7,16
MOVI r8,8
CALL @nkvgen_open
MOVI r2,1
MOVI r3,1
CALL @chk
LA r1,@ctxP
LA r2,@ci
CALL @nkvgen_ctx_info
LA r1,@ci
MOVI r2,#NKG_C_GEN
MOVI r3,5
MOVI r4,2
CALL @chkrec
LA r1,@ci
MOVI r2,#NKG_C_ADMIT
MOVI r3,1
MOVI r4,3
CALL @chkrec
LA r1,@ci
MOVI r2,#NKG_C_USED
MOVI r3,0
MOVI r4,4
CALL @chkrec
LA r1,@ci
MOVI r2,#NKG_C_LIVE
MOVI r3,0
MOVI r4,5
CALL @chkrec

; ---- 10-token prefix: values 0x5000+token
LA r1,@ctxP
MOVI r2,0
MOVI r3,10
MOVI r4,0x5000
CALL @app_seq
MOVI r2,1
MOVI r3,6
CALL @chk
LA r1,@ctxP
LA r2,@ci
CALL @nkvgen_ctx_info
LA r1,@ci
MOVI r2,#NKG_C_USED
MOVI r3,10
MOVI r4,7
CALL @chkrec
LA r1,@ci
MOVI r2,#NKG_C_LIVE
MOVI r3,2
MOVI r4,8
CALL @chkrec
LA r1,@ci
MOVI r2,#NKG_C_COPIES
MOVI r3,0
MOVI r4,9
CALL @chkrec

MOVI r1,0
LA r2,@pi
CALL @nkvgen_page_info
MOVI r2,0
MOVI r3,10
CALL @chk
LA r1,@pi
MOVI r2,#NKG_P_GEN
MOVI r3,5
MOVI r4,11
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_REFS
MOVI r3,1
MOVI r4,12
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_STATE
MOVI r3,1
MOVI r4,13
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_FLAGS
MOVI r3,0
MOVI r4,14
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_USED
MOVI r3,8
MOVI r4,15
CALL @chkrec

MOVI r1,1
LA r2,@pi
CALL @nkvgen_page_info
MOVI r2,0
MOVI r3,16
CALL @chk
LA r1,@pi
MOVI r2,#NKG_P_GEN
MOVI r3,5
MOVI r4,17
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_REFS
MOVI r3,1
MOVI r4,18
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_USED
MOVI r3,2
MOVI r4,19
CALL @chkrec

; ---- same-generation parent reads
LA r1,@ctxP
MOVI r2,0
MOVI r3,10
MOVI r4,0x5000
MOVI r5,5
CALL @rd_range
MOVI r2,1
MOVI r3,20
CALL @chk

; ---- retain a parent read view and a parent write view
LA r1,@ctxP
MOVI r2,0
MOVI r3,1
LA r4,@viewP
CALL @nkvgen_view_open
MOVI r2,1
MOVI r3,21
CALL @chk
LA r1,@ctxP
MOVI r2,0
MOVI r3,2
LA r4,@viewW
CALL @nkvgen_view_open
MOVI r2,1
MOVI r3,22
CALL @chk

; ---- fork: publishes gen 6 and joins both shared prefix pages
LA r1,@ctxP
LA r2,@ctxC
MOVI r3,1
LA r4,@tabC
MOVI r5,16
MOVI r6,2
CALL @nkvgen_fork
MOVI r2,6
MOVI r3,23
CALL @chk
LA r1,@ctxP
LA r2,@ci
CALL @nkvgen_ctx_info
LA r1,@ci
MOVI r2,#NKG_C_CHILDREN
MOVI r3,1
MOVI r4,24
CALL @chkrec
LA r1,@ctxC
LA r2,@ci
CALL @nkvgen_ctx_info
LA r1,@ci
MOVI r2,#NKG_C_GEN
MOVI r3,6
MOVI r4,25
CALL @chkrec
LA r1,@ci
MOVI r2,#NKG_C_ADMIT
MOVI r3,1
MOVI r4,26
CALL @chkrec
LA r1,@ci
MOVI r2,#NKG_C_USED
MOVI r3,10
MOVI r4,27
CALL @chkrec
LA r1,@ci
MOVI r2,#NKG_C_LIVE
MOVI r3,2
MOVI r4,28
CALL @chkrec

MOVI r1,0
LA r2,@pi
CALL @nkvgen_page_info
LA r1,@pi
MOVI r2,#NKG_P_REFS
MOVI r3,2
MOVI r4,29
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_FLAGS
MOVI r3,1
MOVI r4,30
CALL @chkrec
MOVI r1,1
LA r2,@pi
CALL @nkvgen_page_info
LA r1,@pi
MOVI r2,#NKG_P_REFS
MOVI r3,2
MOVI r4,31
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_FLAGS
MOVI r3,1
MOVI r4,32
CALL @chkrec

; ---- both branches read the shared prefix
LA r1,@ctxP
MOVI r2,0
MOVI r3,10
MOVI r4,0x5000
MOVI r5,5
CALL @rd_range
MOVI r2,1
MOVI r3,33
CALL @chk
LA r1,@ctxC
MOVI r2,0
MOVI r3,10
MOVI r4,0x5000
MOVI r5,5
CALL @rd_range
MOVI r2,1
MOVI r3,34
CALL @chk

; ---- retain a child read view
LA r1,@ctxC
MOVI r2,0
MOVI r3,1
LA r4,@viewC
CALL @nkvgen_view_open
MOVI r2,1
MOVI r3,35
CALL @chk

; ---- cross-generation views are rejected exactly
LA r1,@ctxC
LA r2,@viewP
MOVI r3,#NKG_EGEN
CALL @read_fail
MOVI r2,1
MOVI r3,36
CALL @chk
LA r1,@ctxP
LA r2,@viewC
MOVI r3,#NKG_EGEN
CALL @read_fail
MOVI r2,1
MOVI r3,37
CALL @chk

; ---- a new open at old gen 5 fails closed with ESTALE / ngen EDRAIN
LA r1,@ctxX
MOVI r2,1
MOVI r3,5
MOVI r4,2
MOVI r5,3
LA r6,@tabX
MOVI r7,16
MOVI r8,8
CALL @nkvgen_open
MOVI r2,0
MOVI r3,38
CALL @chk
CALL @nkvgen_errno
MOVI r2,#NKG_ESTALE
MOVI r3,39
CALL @chk
LA r1,@ctxX
MOVI r2,#NKG_C_NGERR
MOVI r3,#NG_EDRAIN
MOVI r4,40
CALL @chkrec
MOVI r1,1
MOVI r2,5
LA r3,@slot
CALL @ngen_slot
MOVI r2,0
MOVI r3,41
CALL @chk
LA r1,@slot
MOVI r2,1
MOVI r3,#NG_S_DRAINING
MOVI r4,42
CALL @chkrec

; ---- child first append COWs only the 2-token partial boundary page
LA r1,@ctxC
MOVI r2,0x700A
CALL @nkvgen_append
MOVI r2,10
MOVI r3,43
CALL @chk
LA r1,@stats
CALL @nkvgen_stats
LA r1,@stats
MOVI r2,#NKG_G_COPIES
MOVI r3,1
MOVI r4,44
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_TCOPY
MOVI r3,2
MOVI r4,45
CALL @chkrec
LA r1,@ctxC
LA r2,@ci
CALL @nkvgen_ctx_info
LA r1,@ci
MOVI r2,#NKG_C_COPIES
MOVI r3,1
MOVI r4,46
CALL @chkrec
MOVI r1,2
LA r2,@pi
CALL @nkvgen_page_info
LA r1,@pi
MOVI r2,#NKG_P_GEN
MOVI r3,6
MOVI r4,47
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_USED
MOVI r3,3
MOVI r4,48
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_REFS
MOVI r3,1
MOVI r4,49
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_STATE
MOVI r3,1
MOVI r4,50
CALL @chkrec
; the shared ancestor page now has refcount 1 and records the copy
MOVI r1,1
LA r2,@pi
CALL @nkvgen_page_info
LA r1,@pi
MOVI r2,#NKG_P_REFS
MOVI r3,1
MOVI r4,51
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_USED
MOVI r3,2
MOVI r4,52
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_COPIES
MOVI r3,1
MOVI r4,53
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_TCOPY
MOVI r3,2
MOVI r4,54
CALL @chkrec

; ---- fill the private boundary page, then allocate a new child block
LA r1,@ctxC
MOVI r2,11
MOVI r3,6
MOVI r4,0x7000
CALL @app_seq
MOVI r2,1
MOVI r3,55
CALL @chk
LA r1,@ctxC
LA r2,@ci
CALL @nkvgen_ctx_info
LA r1,@ci
MOVI r2,#NKG_C_USED
MOVI r3,17
MOVI r4,56
CALL @chkrec
LA r1,@ci
MOVI r2,#NKG_C_LIVE
MOVI r3,3
MOVI r4,57
CALL @chkrec
MOVI r1,2
LA r2,@pi
CALL @nkvgen_page_info
LA r1,@pi
MOVI r2,#NKG_P_USED
MOVI r3,8
MOVI r4,58
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_COPIES
MOVI r3,0
MOVI r4,59
CALL @chkrec
MOVI r1,3
LA r2,@pi
CALL @nkvgen_page_info
LA r1,@pi
MOVI r2,#NKG_P_GEN
MOVI r3,6
MOVI r4,60
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_USED
MOVI r3,1
MOVI r4,61
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_REFS
MOVI r3,1
MOVI r4,62
CALL @chkrec

; ---- parent prefix and suffix are unchanged
LA r1,@ctxP
LA r2,@ci
CALL @nkvgen_ctx_info
LA r1,@ci
MOVI r2,#NKG_C_USED
MOVI r3,10
MOVI r4,63
CALL @chkrec
LA r1,@ci
MOVI r2,#NKG_C_LIVE
MOVI r3,2
MOVI r4,64
CALL @chkrec
LA r1,@ci
MOVI r2,#NKG_C_COPIES
MOVI r3,0
MOVI r4,65
CALL @chkrec
MOVI r1,1
LA r2,@pi
CALL @nkvgen_page_info
LA r1,@pi
MOVI r2,#NKG_P_USED
MOVI r3,2
MOVI r4,66
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_GEN
MOVI r3,5
MOVI r4,67
CALL @chkrec
LA r1,@ctxP
MOVI r2,0
MOVI r3,10
MOVI r4,0x5000
MOVI r5,5
CALL @rd_range
MOVI r2,1
MOVI r3,68
CALL @chk

; ---- child sees shared page 0 at gen 5, copied boundary at gen 6,
;      and its own divergent suffix at gen 6
LA r1,@ctxC
MOVI r2,0
MOVI r3,8
MOVI r4,0x5000
MOVI r5,5
CALL @rd_range
MOVI r2,1
MOVI r3,69
CALL @chk
LA r1,@ctxC
MOVI r2,8
MOVI r3,2
MOVI r4,0x5000
MOVI r5,6
CALL @rd_range
MOVI r2,1
MOVI r3,70
CALL @chk
LA r1,@ctxC
MOVI r2,10
MOVI r3,7
MOVI r4,0x7000
MOVI r5,6
CALL @rd_range
MOVI r2,1
MOVI r3,71
CALL @chk

; ---- shared prefix pages reject writes exactly
LA r1,@ctxC
MOVI r2,0
MOVI r3,2
LA r4,@viewW2
CALL @nkvgen_view_open
MOVI r2,1
MOVI r3,72
CALL @chk
LA r1,@ctxP
LA r2,@viewW
MOVI r3,#NKG_ESHARED
CALL @write_fail
MOVI r2,1
MOVI r3,73
CALL @chk
LA r1,@ctxC
LA r2,@viewW2
MOVI r3,#NKG_ESHARED
CALL @write_fail
MOVI r2,1
MOVI r3,74
CALL @chk

; ---- child close: exactly the child's COW copy and new block are freed
LA r1,@ctxC
CALL @nkvgen_close
MOVI r2,1
MOVI r3,75
CALL @chk
LA r1,@ctxC
LA r2,@ci
CALL @nkvgen_ctx_info
LA r1,@ci
MOVI r2,#NKG_C_ADMIT
MOVI r3,0
MOVI r4,76
CALL @chkrec
LA r1,@stats
CALL @nkvgen_stats
LA r1,@stats
MOVI r2,#NKG_G_LIVE
MOVI r3,2
MOVI r4,77
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_ALLOCS
MOVI r3,4
MOVI r4,78
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_FREES
MOVI r3,2
MOVI r4,79
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_JOINS
MOVI r3,2
MOVI r4,80
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_LEAVES
MOVI r3,4
MOVI r4,81
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_COPIES
MOVI r3,1
MOVI r4,82
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_TCOPY
MOVI r3,2
MOVI r4,83
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_FORKS
MOVI r3,1
MOVI r4,84
CALL @chkrec
MOVI r1,0
LA r2,@pi
CALL @nkvgen_page_info
LA r1,@pi
MOVI r2,#NKG_P_REFS
MOVI r3,1
MOVI r4,85
CALL @chkrec
MOVI r1,1
LA r2,@pi
CALL @nkvgen_page_info
LA r1,@pi
MOVI r2,#NKG_P_REFS
MOVI r3,1
MOVI r4,86
CALL @chkrec
MOVI r1,2
LA r2,@pi
CALL @nkvgen_page_info
LA r1,@pi
MOVI r2,#NKG_P_STATE
MOVI r3,0
MOVI r4,87
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_FREES
MOVI r3,1
MOVI r4,88
CALL @chkrec
MOVI r1,3
LA r2,@pi
CALL @nkvgen_page_info
LA r1,@pi
MOVI r2,#NKG_P_STATE
MOVI r3,0
MOVI r4,89
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_FREES
MOVI r3,1
MOVI r4,90
CALL @chkrec

; ---- parent still reads its whole prefix after the child exits
LA r1,@ctxP
MOVI r2,0
MOVI r3,10
MOVI r4,0x5000
MOVI r5,5
CALL @rd_range
MOVI r2,1
MOVI r3,91
CALL @chk

; ---- parent close frees the two remaining shared prefix pages
LA r1,@ctxP
CALL @nkvgen_close
MOVI r2,1
MOVI r3,92
CALL @chk
LA r1,@stats
CALL @nkvgen_stats
LA r1,@stats
MOVI r2,#NKG_G_LIVE
MOVI r3,0
MOVI r4,93
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_ALLOCS
MOVI r3,4
MOVI r4,94
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_FREES
MOVI r3,4
MOVI r4,95
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_JOINS
MOVI r3,2
MOVI r4,96
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_LEAVES
MOVI r3,6
MOVI r4,97
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_COPIES
MOVI r3,1
MOVI r4,98
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_TCOPY
MOVI r3,2
MOVI r4,99
CALL @chkrec
MOVI r1,0
LA r2,@pi
CALL @nkvgen_page_info
LA r1,@pi
MOVI r2,#NKG_P_REFS
MOVI r3,0
MOVI r4,100
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_STATE
MOVI r3,0
MOVI r4,101
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_FREES
MOVI r3,1
MOVI r4,102
CALL @chkrec
MOVI r1,1
LA r2,@pi
CALL @nkvgen_page_info
LA r1,@pi
MOVI r2,#NKG_P_REFS
MOVI r3,0
MOVI r4,103
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_STATE
MOVI r3,0
MOVI r4,104
CALL @chkrec
LA r1,@pi
MOVI r2,#NKG_P_FREES
MOVI r3,1
MOVI r4,105
CALL @chkrec

; ---- an old view after close is rejected as stale
LA r1,@ctxP
LA r2,@viewP
MOVI r3,#NKG_ESTALE
CALL @read_fail
MOVI r2,1
MOVI r3,106
CALL @chk

; ---- exact error classes and ngen end state
LA r1,@stats
CALL @nkvgen_stats
LA r1,@stats
MOVI r2,#NKG_G_XGEN
MOVI r3,2
MOVI r4,107
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_XSTALE
MOVI r3,2
MOVI r4,108
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_XSHARED
MOVI r3,2
MOVI r4,109
CALL @chkrec
LA r1,@stats
MOVI r2,#NKG_G_ERRORS
MOVI r3,6
MOVI r4,110
CALL @chkrec
MOVI r1,1
LA r2,@st
CALL @ngen_status
LA r1,@st
MOVI r2,3
MOVI r3,6
MOVI r4,111
CALL @chkrec
MOVI r1,1
MOVI r2,5
LA r3,@slot
CALL @ngen_slot
MOVI r2,0
MOVI r3,112
CALL @chk
LA r1,@slot
MOVI r2,1
MOVI r3,#NG_S_DRAINED
MOVI r4,113
CALL @chkrec

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
CALL @nkvgen_append
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
; open through the view layer
LD r1,r14,1
LD r2,r14,2
MOVI r3,1
LA r4,@viewS
CALL @nkvgen_view_open
CMP r1,r0
JMP[EQ] @rd_bad
; read and validate the record
LD r1,r14,1
LA r2,@viewS
LA r3,@out4
CALL @nkvgen_view_read
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
LA r3,#NKG_REC_TAG
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
CALL @nkvgen_view_read
CMP r1,r0
JMP[NE] @rf_bad
CALL @nkvgen_errno
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
CALL @nkvgen_view_write
CMP r1,r0
JMP[NE] @wf_bad
CALL @nkvgen_errno
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

; snapshot r1=out(1184): contexts, page registry, stats, page buffers,
; then ngen status.
snapshot:
ST r15,r14,0
ADDI r14,r14,24
ST r1,r14,1
; three contexts (96 words)
LA r2,@ctxP
LD r1,r14,1
MOVI r3,96
CALL @copyw
; page registry (512 words)
LA r2,#NKG_TAB
LD r1,r14,1
ADDI r1,r1,96
MOVI r3,512
CALL @copyw
; stats (32 words)
LA r2,#NKG_STATS
LD r1,r14,1
ADDI r1,r1,608
MOVI r3,32
CALL @copyw
; page payload buffers (512 words)
LA r2,@pdata
LD r1,r14,1
ADDI r1,r1,640
MOVI r3,512
CALL @copyw
; ngen status (32 words)
MOVI r1,1
LD r2,r14,1
ADDI r2,r2,1152
CALL @ngen_status
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
MOVI r1,70
PUTC r1
MOVI r1,61
PUTC r1
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
.org 0x20000
ctxP:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ctxC:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ctxX:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tabP:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tabC:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tabX:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
viewP:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
viewC:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
viewW:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
viewW2:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
viewS:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
out4:
.word 0,0,0,0
ci:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
pi:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
st:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
stats:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
slot:
.word 0,0,0,0,0,0,0,0

.org 0x28000
pdata:
.word 0,0,0,0,0,0,0,0

.org 0x29000
snapA:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

.org 0x2A000
snapB:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
