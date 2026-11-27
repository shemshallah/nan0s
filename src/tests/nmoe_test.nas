; nmoe_test.nas - hand-built 4-expert top-2 MoE (F13d).
;
; Router matrix (Q4_0, 4 rows, 32-lane padded) columns for the four input
; basis vectors are:
;   x=e0 -> logits [2,2,0,0]   x=2e0 -> [4,4,0,0]
;   x=e1 -> [0,0,2,2]          x=e2 -> [1,1,1,0]
; Top-2 with stable ties:
;   e0/e1 -> ids 0,1 weights 1/2,1/2
;   e1     -> ids 2,3 weights 1/2,1/2
;   e2     -> ids 0,1 (e2 has the same 1.0 logit but a higher id)
;
; Experts (Q4_0 FFN, 4 hidden lanes, 32-lane padded):
;   e0: W1=2I, W2=0.5I -> y=x
;   e1: W1=I,  W2=I    -> y=x
;   e2: W1=I,  W2=2I   -> y=2x
;   e3: W1=2I, W2=2I   -> y=4x
;
; Capacity factor 2 -> cap=4: all eight assignments accepted.
;   token 0 (e0,e1) -> x       token 1 -> 2x
;   token 2 (e2,e3) -> 0.5*2x+0.5*4x = 3x
;   token 3 (e0,e1) -> x
; Capacity factor 1 -> cap=2: e0/e1 fill on tokens 0 and 1; token 3's
; two assignments are dropped (combined output zero), token 2 still runs.
;
; Placement table: e0 node0 DRAM, e1 node1 VRAM, e2 node0 VRAM,
; e3 node1 DRAM; current node 0, remote bias 1.0.  The bias is selection-only:
; raw logits [1,1,1,0] become scores [1,0,1,0], so token 3 flips from
; (e0,e1) to (e0,e2) and outputs 0.5*x + 0.5*2x = 1.5x.  Combine weights
; remain the softmax of the selected *raw* logits, exactly 1/2 each.
;
; Success prints exactly O.
.org 0
JMP @main
.org 0x9000
cfg_np:
.word 0x454F4D4E,1,4,4,2,@rtr,@w1,@w2,4,0,@place,0
.word 0,2,1,0,0,0,0,0,0,0,0,0
cfg_pl:
.word 0x454F4D4E,1,4,4,2,@rtr,@w1,@w2,4,0,@place,1
.word 0x3F800000,2,1,0,0,0,0,0,0,0,0,0
cfg_cap1:
.word 0x454F4D4E,1,4,4,2,@rtr,@w1,@w2,4,0,@place,0
.word 0,1,1,0,0,0,0,0,0,0,0,0
cfg_bad:
.word 0x454F4D4F,1,4,4,2,@rtr,@w1,@w2,4,0,@place,0
.word 0,2,1,0,0,0,0,0,0,0,0,0
rtr:
.word 0x3F800000,0x8889888A,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x8889888A,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88898A88,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88888A88,0x88888888,0x88888888,0x88888888
w1:
.word 0x3F800000,0x8888888A,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88888A88,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x888A8888,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x8A888888,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88888889,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88888988,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88898888,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x89888888,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88888889,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88888988,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88898888,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x89888888,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x8888888A,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88888A88,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x888A8888,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x8A888888,0x88888888,0x88888888,0x88888888
w2:
.word 0x3F000000,0x88888889,0x88888888,0x88888888,0x88888888
.word 0x3F000000,0x88888988,0x88888888,0x88888888,0x88888888
.word 0x3F000000,0x88898888,0x88888888,0x88888888,0x88888888
.word 0x3F000000,0x89888888,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88888889,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88888988,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88898888,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x89888888,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x8888888A,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88888A88,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x888A8888,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x8A888888,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x8888888A,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88888A88,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x888A8888,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x8A888888,0x88888888,0x88888888,0x88888888
place:
.word 0,0,1,1,0,1,1,0
toks:
.word 0x3F800000,0,0,0
.word 0x40000000,0,0,0
.word 0,0x3F800000,0,0
.word 0,0,0x3F800000,0
tie1_logits:
.word 0x3F800000,0x3F800000,0x3F800000,0,0,0,0,0
tie2_logits:
.word 0,0x40000000,0x40000000,0,0,0,0,0
exp_router_t0:
.word 0x40000000,0x40000000,0,0,0,0,0,0
exp_router_t3:
.word 0x3F800000,0x3F800000,0x3F800000,0,0,0,0,0
exp_score_t3_pl:
.word 0x3F800000,0,0x3F800000,0xBF800000,0,0,0,0
exp_ids01:
.word 0,1
exp_ids23:
.word 2,3
exp_ids12:
.word 1,2
exp_ids02:
.word 0,2
exp_w_half:
.word 0x3F000000,0x3F000000
exp_e1:
.word 0x3F800000,0,0,0
exp_e2:
.word 0x40000000,0,0,0
exp_e3:
.word 0x40800000,0,0,0
exp_e0_t2:
.word 0,0x3F800000,0,0
exp_out_full:
.word 0x3F800000,0,0,0
.word 0x40000000,0,0,0
.word 0,0x40400000,0,0
.word 0,0,0x3F800000,0
exp_out_pl:
.word 0x3F800000,0,0,0
.word 0x40000000,0,0,0
.word 0,0x40400000,0,0
.word 0,0,0x3FC00000,0
exp_out_cap:
.word 0x3F800000,0,0,0
.word 0x40000000,0,0,0
.word 0,0x40400000,0,0
.word 0,0,0,0
exp_stats_full:
.word 4,2,4,4,8,8,0,0,0,4
.word 4,4,4,3,1,2,0,2,1,0
.word 0,0,0,0,3,3,1,1,0,0
.word 0,0,3,3,1,1,0,0,0,0
.word 0,0,0,0,0,0,0,0,3,0
.word 1,0,0,0,0,0,0,3,0,1
.word 0,0,0,0,0,3,1,0,0,0
.word 0,0,3,0,0,1,0,0,0,0
exp_stats_pl:
.word 4,2,4,4,8,8,0,0,0,5
.word 3,4,4,3,1,2,1,2,1,0x3F800000
.word 0,0,0,0,3,2,2,1,0,0
.word 0,0,3,2,2,1,0,0,0,0
.word 0,0,0,0,0,0,0,0,3,0
.word 2,0,0,0,0,0,0,2,0,1
.word 0,0,0,0,0,2,2,0,0,0
.word 0,0,3,0,0,1,0,0,0,0
exp_stats_cap:
.word 4,2,2,4,8,6,2,1,1,4
.word 4,4,4,2,1,1,0,1,1,0
.word 0,0,0,0,3,3,1,1,0,0
.word 0,0,2,2,1,1,0,0,0,0
.word 1,1,0,0,0,0,0,0,3,0
.word 1,0,0,0,0,0,0,3,0,1
.word 0,0,0,0,0,3,1,0,0,0
.word 0,0,3,0,0,1,0,0,0,0
logitsbuf:
.word 0,0,0,0,0,0,0,0
scoresbuf:
.word 0,0,0,0,0,0,0,0
idsbuf:
.word 0,0,0,0,0,0,0,0
wbuf:
.word 0,0,0,0,0,0,0,0
expertbuf:
.word 0,0,0,0,0,0,0,0
out_full_a:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
out_pl_a:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
out_cap_a:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
out_r2_a:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
stats_full_a:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
stats_pl_a:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
stats_cap_a:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
stats_r2_a:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
stagev:
.word 0
.org 0x10000
.include "../lib/nmoe.nas"
main:
MOVI r13,1
MOVI r14,0x7000

; ---------------------------------------------------------------------------
; descriptor validation
MOVI r1,1
CALL @mark
LA r1,@cfg_np
CALL @nmoe_init
CMP r1,r0
JMP[NE] @fail
LA r1,@cfg_bad
CALL @nmoe_init
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; router raw logits, token 0
MOVI r1,2
CALL @mark
LA r1,@cfg_np
LA r2,@toks
LA r3,@logitsbuf
LA r4,@scoresbuf
CALL @nmoe_router
CMP r1,r0
JMP[NE] @fail
LA r1,@logitsbuf
LA r2,@exp_router_t0
MOVI r3,8
CALL @cmplist
CMP r1,r0
JMP[NE] @fail
LA r1,@scoresbuf
LA r2,@exp_router_t0
MOVI r3,8
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

; router raw logits, token 3 (tie among e0,e1,e2)
MOVI r1,3
CALL @mark
LA r1,@cfg_np
LA r2,@toks
ADDI r2,r2,12
LA r3,@logitsbuf
LA r4,@scoresbuf
CALL @nmoe_router
CMP r1,r0
JMP[NE] @fail
LA r1,@logitsbuf
LA r2,@exp_router_t3
MOVI r3,8
CALL @cmplist
CMP r1,r0
JMP[NE] @fail
LA r1,@scoresbuf
LA r2,@exp_router_t3
MOVI r3,8
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

; placement scores, token 3: raw [1,1,1,0] -> [1,0,1,0]
MOVI r1,4
CALL @mark
LA r1,@cfg_pl
LA r2,@toks
ADDI r2,r2,12
LA r3,@logitsbuf
LA r4,@scoresbuf
CALL @nmoe_router
CMP r1,r0
JMP[NE] @fail
LA r1,@logitsbuf
LA r2,@exp_router_t3
MOVI r3,8
CALL @cmplist
CMP r1,r0
JMP[NE] @fail
LA r1,@scoresbuf
LA r2,@exp_score_t3_pl
MOVI r3,8
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; route(): exact top-2 ids and 1/2,1/2 weights
MOVI r1,5
CALL @mark
LA r1,@cfg_np
LA r2,@toks
LA r3,@idsbuf
LA r4,@wbuf
CALL @nmoe_route
CMP r1,r0
JMP[NE] @fail
LA r1,@idsbuf
LA r2,@exp_ids01
MOVI r3,2
CALL @cmplist
CMP r1,r0
JMP[NE] @fail
LA r1,@wbuf
LA r2,@exp_w_half
MOVI r3,2
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

MOVI r1,6
CALL @mark
LA r1,@cfg_np
LA r2,@toks
ADDI r2,r2,4
LA r3,@idsbuf
LA r4,@wbuf
CALL @nmoe_route
CMP r1,r0
JMP[NE] @fail
LA r1,@idsbuf
LA r2,@exp_ids01
MOVI r3,2
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

MOVI r1,7
CALL @mark
LA r1,@cfg_np
LA r2,@toks
ADDI r2,r2,8
LA r3,@idsbuf
LA r4,@wbuf
CALL @nmoe_route
CMP r1,r0
JMP[NE] @fail
LA r1,@idsbuf
LA r2,@exp_ids23
MOVI r3,2
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

MOVI r1,8
CALL @mark
LA r1,@cfg_np
LA r2,@toks
ADDI r2,r2,12
LA r3,@idsbuf
LA r4,@wbuf
CALL @nmoe_route
CMP r1,r0
JMP[NE] @fail
LA r1,@idsbuf
LA r2,@exp_ids01
MOVI r3,2
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

; placement flips token 3 from (e0,e1) to (e0,e2); weights stay 1/2,1/2
MOVI r1,9
CALL @mark
LA r1,@cfg_pl
LA r2,@toks
ADDI r2,r2,12
LA r3,@idsbuf
LA r4,@wbuf
CALL @nmoe_route
CMP r1,r0
JMP[NE] @fail
LA r1,@idsbuf
LA r2,@exp_ids02
MOVI r3,2
CALL @cmplist
CMP r1,r0
JMP[NE] @fail
LA r1,@wbuf
LA r2,@exp_w_half
MOVI r3,2
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; stable top-k tie-breaking
MOVI r1,10
CALL @mark
LA r1,@tie1_logits
MOVI r2,4
MOVI r3,2
LA r4,@idsbuf
LA r5,@wbuf
CALL @nmoe_topk
CMP r1,r0
JMP[NE] @fail
LA r1,@idsbuf
LA r2,@exp_ids01
MOVI r3,2
CALL @cmplist
CMP r1,r0
JMP[NE] @fail
LA r1,@tie2_logits
MOVI r2,4
MOVI r3,2
LA r4,@idsbuf
LA r5,@wbuf
CALL @nmoe_topk
CMP r1,r0
JMP[NE] @fail
LA r1,@idsbuf
LA r2,@exp_ids12
MOVI r3,2
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

; direct selected softmax: equal selected raw logits -> exactly 1/2,1/2
LA r1,@tie1_logits
LA r2,@exp_ids01
MOVI r3,2
LA r4,@wbuf
CALL @nmoe_softmax_sel
CMP r1,r0
JMP[NE] @fail
LA r1,@wbuf
LA r2,@exp_w_half
MOVI r3,2
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; direct expert FFN outputs
MOVI r1,11
CALL @mark
LA r1,@cfg_np
MOVI r2,0
LA r3,@toks
LA r4,@expertbuf
CALL @nmoe_expert
CMP r1,r0
JMP[NE] @fail
LA r1,@expertbuf
LA r2,@exp_e1
MOVI r3,4
CALL @cmplist
CMP r1,r0
JMP[NE] @fail
LA r1,@cfg_np
MOVI r2,1
LA r3,@toks
LA r4,@expertbuf
CALL @nmoe_expert
CMP r1,r0
JMP[NE] @fail
LA r1,@expertbuf
LA r2,@exp_e1
MOVI r3,4
CALL @cmplist
CMP r1,r0
JMP[NE] @fail
LA r1,@cfg_np
MOVI r2,2
LA r3,@toks
LA r4,@expertbuf
CALL @nmoe_expert
CMP r1,r0
JMP[NE] @fail
LA r1,@expertbuf
LA r2,@exp_e2
MOVI r3,4
CALL @cmplist
CMP r1,r0
JMP[NE] @fail
LA r1,@cfg_np
MOVI r2,3
LA r3,@toks
LA r4,@expertbuf
CALL @nmoe_expert
CMP r1,r0
JMP[NE] @fail
LA r1,@expertbuf
LA r2,@exp_e3
MOVI r3,4
CALL @cmplist
CMP r1,r0
JMP[NE] @fail
LA r1,@cfg_np
MOVI r2,0
LA r3,@toks
ADDI r3,r3,8
LA r4,@expertbuf
CALL @nmoe_expert
CMP r1,r0
JMP[NE] @fail
LA r1,@expertbuf
LA r2,@exp_e0_t2
MOVI r3,4
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; full capacity (factor 2): all assignments accepted
MOVI r1,12
CALL @mark
LA r1,@cfg_np
LA r2,@toks
MOVI r3,4
LA r4,@out_full_a
LA r5,@stats_full_a
CALL @nmoe_forward
CMP r1,r0
JMP[NE] @fail
LA r1,@out_full_a
LA r2,@exp_out_full
MOVI r3,16
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

MOVI r1,13
CALL @mark
LA r1,@stats_full_a
LA r2,@exp_stats_full
MOVI r3,80
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; placement-enabled run: token 3 flips to e0/e2, output 1.5*x
MOVI r1,14
CALL @mark
LA r1,@cfg_pl
LA r2,@toks
MOVI r3,4
LA r4,@out_pl_a
LA r5,@stats_pl_a
CALL @nmoe_forward
CMP r1,r0
JMP[NE] @fail
LA r1,@out_pl_a
LA r2,@exp_out_pl
MOVI r3,16
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

MOVI r1,15
CALL @mark
LA r1,@stats_pl_a
LA r2,@exp_stats_pl
MOVI r3,80
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; capacity factor 1: cap=2, token 3 overflows both experts, output zero
MOVI r1,16
CALL @mark
LA r1,@cfg_cap1
LA r2,@toks
MOVI r3,4
LA r4,@out_cap_a
LA r5,@stats_cap_a
CALL @nmoe_forward
CMP r1,r0
JMP[NE] @fail
LA r1,@out_cap_a
LA r2,@exp_out_cap
MOVI r3,16
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

MOVI r1,17
CALL @mark
LA r1,@stats_cap_a
LA r2,@exp_stats_cap
MOVI r3,80
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; deterministic rerun of the full-capacity path
MOVI r1,18
CALL @mark
LA r1,@cfg_np
LA r2,@toks
MOVI r3,4
LA r4,@out_r2_a
LA r5,@stats_r2_a
CALL @nmoe_forward
CMP r1,r0
JMP[NE] @fail
LA r1,@out_full_a
LA r2,@out_r2_a
MOVI r3,16
CALL @cmplist
CMP r1,r0
JMP[NE] @fail
LA r1,@stats_full_a
LA r2,@stats_r2_a
MOVI r3,80
CALL @cmplist
CMP r1,r0
JMP[NE] @fail

MOVI r1,79
PUTC r1
HALT

fail:
LA r2,@stagev
LD r1,r2,0
PUTC r1
MOVI r1,70
PUTC r1
HALT

mark:
LA r2,@stagev
ST r1,r2,0
RET

; cmplist r1=a r2=b r3=n -> 0/-1
cmplist:
MOVI r4,0
cmp_l:
CMP r4,r3
JMP[GE] @cmp_ok
ADD r5,r1,r4
LD r5,r5,0
ADD r6,r2,r4
LD r6,r6,0
CMP r5,r6
JMP[NE] @cmp_bad
ADD r4,r4,r13
JMP @cmp_l
cmp_ok:
MOVI r1,0
RET
cmp_bad:
LA r1,0xFFFFFFFF
RET
