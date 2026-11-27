; nmoe.nas - deterministic top-k MoE routing, expert FFN and placement hints.
;
; Pure NaN.  The model is deliberately tiny and exact:
;   - a router Q4_0 matrix produces one f32 logit per expert;
;   - top-k (k=2 in the gate, configurable 1..8) is selected by repeated
;     max scan, ties keep the lower expert id (stable ordering);
;   - combine weights are the softmax over the *selected raw router logits*
;     (f32 FEXP, max-shifted), so equal logits give exactly 1/k;
;   - each expert is a two-layer Q4_0 FFN over 32-column blocks:
;         h = relu(W1_e * x)
;         y = W2_e * h
;     using nmodel's nmod_gemv_q4 (the nq4 block path);
;   - tokens are dispatched in ascending token order and, within a token,
;     in top-k rank order.  An expert has capacity
;         cap = ceil(tokens * topk * cap_num / (n_experts * cap_den))
;     (cap_num == 0 means capacity 0).  The first cap assignments to an
;     expert are accepted; later assignments are dropped.  A dropped expert
;     simply contributes nothing; no weight renormalization is performed.
;     This makes the output deterministic and the overflow policy explicit.
;
; Placement is a pure-NaN hint/accounting model, not an accelerator runtime.
; The placement table has two words per expert:
;   +0 numa node id   +1 flags (bit 0 = VRAM-resident hint)
; When flags bit 0 of the model config is set, each remote hop subtracts
; `remote_bias` from the router logit *for top-k selection only*.  The
; combine softmax still uses the raw router logits, so a placement hint can
; change which experts are selected without changing their gate weights.
; Local/remote/VRAM/DRAM selection counts and per-expert counters are always
; reported, even when the bias is disabled.
;
; Config (24 caller-supplied words):
;   +0 magic 0x454F4D4E ("NMOE" in little-endian bytes)
;   +1 version 1
;   +2 n_experts 1..8          +3 dim 1..32
;   +4 topk 1..n_experts       +5 router Q4_0 blocks (n_experts rows)
;   +6 W1 Q4_0 blocks          +7 W2 Q4_0 blocks
;   +8 hidden 1..32            +9 current NUMA node
;   +10 placement table        +11 flags (bit0 = remote bias)
;   +12 remote bias f32 bits   +13 capacity numerator
;   +14 capacity denominator   +15..23 reserved
;
; W1 layout: n_experts * hidden consecutive Q4 blocks (one block per row).
; W2 layout: n_experts * dim    consecutive Q4 blocks (one block per row).
; Rows are padded to 32 lanes; lanes >= dim/hidden are zero.
;
; Stats block (80 caller-supplied words):
;   +0 tokens +1 topk +2 capacity +3 n_experts
;   +4 assign_total +5 accept_total +6 drop_total
;   +7 tokens_with_a_drop +8 tokens_with_no_expert
;   +9 local_selected +10 remote_selected
;   +11 vram_selected +12 dram_selected
;   +13 max_accept +14 min_accept +15 accept_span
;   +16 model flags +17 cap_num +18 cap_den +19 remote bias bits
;   +20..23 reserved
;   +24..31 expert assign[0..7]
;   +32..39 expert accept[0..7]
;   +40..47 expert drop[0..7]
;   +48..55 expert local[0..7]
;   +56..63 expert remote[0..7]
;   +64..71 expert vram[0..7]
;   +72..79 expert dram[0..7]
;
; API:
;   nmoe_init    r1=cfg -> 0/-1
;   nmoe_router  r1=cfg r2=x r3=logits(nexp) r4=scores(nexp) -> 0/-1
;   nmoe_topk    r1=logits r2=n r3=k r4=ids r5=vals -> 0/-1
;   nmoe_softmax_sel r1=logits r2=ids r3=k r4=weights -> 0/-1
;   nmoe_route   r1=cfg r2=x r3=ids(k) r4=weights(k) -> 0/-1
;   nmoe_expert  r1=cfg r2=expert r3=x r4=out(dim) -> 0/-1
;   nmoe_forward r1=cfg r2=x rows r3=count r4=out rows r5=stats -> 0/-1
;
; Scratch 0x5900..0x5AFF (below nq4 0x6000).  nmodel scratch is 0x5400.
; ABI: r0=0, r13=1, r14 soft stack grows up, r15 link.  Requires nq4/nmodel.

.include "nmodel.nas"

.equ NMOE_MAGIC   0x454F4D4E
.equ NMOE_VERSION 1
.equ NMOE_MAX_EXP 8
.equ NMOE_MAX_K   8
.equ NMOE_MAX_DIM 32

.equ NMOE_C_MAGIC   0
.equ NMOE_C_VERSION 1
.equ NMOE_C_NEXP    2
.equ NMOE_C_DIM     3
.equ NMOE_C_TOPK    4
.equ NMOE_C_ROUTER  5
.equ NMOE_C_W1      6
.equ NMOE_C_W2      7
.equ NMOE_C_HIDDEN  8
.equ NMOE_C_NODE    9
.equ NMOE_C_PLACE   10
.equ NMOE_C_FLAGS   11
.equ NMOE_C_BIAS    12
.equ NMOE_C_CAPNUM  13
.equ NMOE_C_CAPDEN  14

.equ NMS_TOKENS   0
.equ NMS_TOPK     1
.equ NMS_CAP      2
.equ NMS_EXPERTS  3
.equ NMS_ASSIGN   4
.equ NMS_ACCEPT   5
.equ NMS_DROP     6
.equ NMS_TOKDROP  7
.equ NMS_TOKZERO  8
.equ NMS_LOCAL    9
.equ NMS_REMOTE   10
.equ NMS_VRAM     11
.equ NMS_DRAM     12
.equ NMS_MAXA     13
.equ NMS_MINA     14
.equ NMS_SPAN     15
.equ NMS_FLAGS    16
.equ NMS_CAPNUM   17
.equ NMS_CAPDEN   18
.equ NMS_BIAS     19
.equ NMS_EXP_ASSIGN 24
.equ NMS_EXP_ACCEPT 32
.equ NMS_EXP_DROP   40
.equ NMS_EXP_LOCAL  48
.equ NMS_EXP_REMOTE 56
.equ NMS_EXP_VRAM   64
.equ NMS_EXP_DRAM   72
.equ NMS_WORDS      80

; Scratch windows.
.equ NMOE_TMP 0x5880
.equ NMOE_RTR 0x5900
.equ NMOE_TOP 0x5940
.equ NMOE_RTE 0x5980
.equ NMOE_EXP 0x59C0
.equ NMOE_FWD 0x5A80

; Router scratch.
.equ RTR_ACTS  0
.equ RTR_LOG   32
.equ RTR_SCORE 40
.equ RTR_CFG   48
.equ RTR_X     49
.equ RTR_LOGO  50
.equ RTR_SCO   51
.equ RTR_NEXP  52
.equ RTR_DIM   53
.equ RTR_FLAGS 54
.equ RTR_NODE  55
.equ RTR_PLACE 56
.equ RTR_BIAS  57

; Top-k / softmax scratch.
.equ TOP_LOG  0
.equ TOP_N    1
.equ TOP_K    2
.equ TOP_IDS  3
.equ TOP_VALS 4
.equ TOP_RANK 5
.equ TOP_CAND 6
.equ TOP_BEST 7
.equ TOP_BVAL 8
.equ TOP_SKIP 9
.equ TOP_MAX  10
.equ TOP_SUM  11

; route() scratch.
.equ RTE_CFG   0
.equ RTE_X     1
.equ RTE_IDS   2
.equ RTE_W     3
.equ RTE_LOG   8
.equ RTE_SCORE 16
.equ RTE_SIDS  24
.equ RTE_SVALS 32
.equ RTE_WTS   40
.equ RTE_N     48
.equ RTE_K     49

; expert() scratch.
.equ EXP_CFG   0
.equ EXP_E     1
.equ EXP_X     2
.equ EXP_OUT   3
.equ EXP_DIM   4
.equ EXP_HID   5
.equ EXP_H     8
.equ EXP_ACTS  40

; forward() scratch.
.equ F_CFG     0
.equ F_X       1
.equ F_COUNT   2
.equ F_OUT     3
.equ F_STATS   4
.equ F_CAP     5
.equ F_NEXP    6
.equ F_TOPK    7
.equ F_DIM     8
.equ F_T       9
.equ F_J       10
.equ F_E       11
.equ F_ROW     12
.equ F_OUTROW  13
.equ F_ANY     14
.equ F_TOKACC  15
.equ F_IDS     16
.equ F_W       24
.equ F_EXPOUT  32
.equ F_ACCEPT  64
.equ F_DROP    72
.equ F_ASSIGN  80
.equ F_LOCAL   88
.equ F_REMOTE  96
.equ F_VRAM    104
.equ F_DRAM    112
.equ F_TOKDROP 120
.equ F_TOKZERO 121

; ---------------------------------------------------------------------------
; nmoe_init r1=cfg -> 0/-1
nmoe_init:
  JMP @nmo_check

; r1=cfg -> 0/-1
nmo_check:
  CMP r1,r0
  JMP[EQ] @nmo_chk_bad
  LD r2,r1,#NMOE_C_MAGIC
  LA r3,#NMOE_MAGIC
  CMP r2,r3
  JMP[NE] @nmo_chk_bad
  LD r2,r1,#NMOE_C_VERSION
  MOVI r3,#NMOE_VERSION
  CMP r2,r3
  JMP[NE] @nmo_chk_bad
  LD r2,r1,#NMOE_C_NEXP
  CMP r2,r0
  JMP[LE] @nmo_chk_bad
  MOVI r3,#NMOE_MAX_EXP
  CMP r2,r3
  JMP[GT] @nmo_chk_bad
  LD r2,r1,#NMOE_C_DIM
  CMP r2,r0
  JMP[LE] @nmo_chk_bad
  MOVI r3,#NMOE_MAX_DIM
  CMP r2,r3
  JMP[GT] @nmo_chk_bad
  LD r2,r1,#NMOE_C_HIDDEN
  CMP r2,r0
  JMP[LE] @nmo_chk_bad
  MOVI r3,#NMOE_MAX_DIM
  CMP r2,r3
  JMP[GT] @nmo_chk_bad
  LD r2,r1,#NMOE_C_TOPK
  CMP r2,r0
  JMP[LE] @nmo_chk_bad
  LD r3,r1,#NMOE_C_NEXP
  CMP r2,r3
  JMP[GT] @nmo_chk_bad
  LD r2,r1,#NMOE_C_ROUTER
  CMP r2,r0
  JMP[EQ] @nmo_chk_bad
  LD r2,r1,#NMOE_C_W1
  CMP r2,r0
  JMP[EQ] @nmo_chk_bad
  LD r2,r1,#NMOE_C_W2
  CMP r2,r0
  JMP[EQ] @nmo_chk_bad
  LD r2,r1,#NMOE_C_PLACE
  CMP r2,r0
  JMP[EQ] @nmo_chk_bad
  LD r2,r1,#NMOE_C_CAPNUM
  MOVI r3,0xFFFF
  CMP r2,r3
  JMP[GT] @nmo_chk_bad
  LD r2,r1,#NMOE_C_CAPDEN
  CMP r2,r0
  JMP[LE] @nmo_chk_bad
  MOVI r3,0xFFFF
  CMP r2,r3
  JMP[GT] @nmo_chk_bad
  MOVI r1,0
  RET
nmo_chk_bad:
  LA r1,0xFFFFFFFF
  RET

; ---------------------------------------------------------------------------
; nmo_acts r1=src r2=dim r3=dst -> 0
; Copies dim words and zero-fills the remaining lanes to 32.
nmo_acts:
  ST r1,r0,#NMOE_TMP+0
  ST r2,r0,#NMOE_TMP+1
  ST r3,r0,#NMOE_TMP+2
  MOVI r4,32
  BFILL r3,r0,r4
  MOVI r5,0
nmo_acts_l:
  LD r2,r0,#NMOE_TMP+1
  CMP r5,r2
  JMP[GE] @nmo_acts_ok
  LD r1,r0,#NMOE_TMP+0
  ADD r1,r1,r5
  LD r1,r1,0
  LD r3,r0,#NMOE_TMP+2
  ADD r3,r3,r5
  ST r1,r3,0
  ADD r5,r5,r13
  JMP @nmo_acts_l
nmo_acts_ok:
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; nmoe_router r1=cfg r2=x r3=logits r4=scores -> 0/-1
; scores = raw logits with the optional per-hop remote placement bias.
nmoe_router:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NMOE_RTR+#RTR_CFG
  ST r2,r0,#NMOE_RTR+#RTR_X
  ST r3,r0,#NMOE_RTR+#RTR_LOGO
  ST r4,r0,#NMOE_RTR+#RTR_SCO
  CMP r3,r0
  JMP[EQ] @nmo_rtr_bad
  CMP r4,r0
  JMP[EQ] @nmo_rtr_bad
  CALL @nmo_check
  CMP r1,r0
  JMP[NE] @nmo_rtr_bad

  LD r1,r0,#NMOE_RTR+#RTR_CFG
  LD r2,r1,#NMOE_C_NEXP
  ST r2,r0,#NMOE_RTR+#RTR_NEXP
  LD r2,r1,#NMOE_C_DIM
  ST r2,r0,#NMOE_RTR+#RTR_DIM
  LD r2,r1,#NMOE_C_FLAGS
  ST r2,r0,#NMOE_RTR+#RTR_FLAGS
  LD r2,r1,#NMOE_C_NODE
  ST r2,r0,#NMOE_RTR+#RTR_NODE
  LD r2,r1,#NMOE_C_PLACE
  ST r2,r0,#NMOE_RTR+#RTR_PLACE
  LD r2,r1,#NMOE_C_BIAS
  ST r2,r0,#NMOE_RTR+#RTR_BIAS

  LD r1,r0,#NMOE_RTR+#RTR_X
  LD r2,r0,#NMOE_RTR+#RTR_DIM
  LA r3,#NMOE_RTR+#RTR_ACTS
  CALL @nmo_acts

  LD r1,r0,#NMOE_RTR+#RTR_CFG
  LD r1,r1,#NMOE_C_ROUTER
  LD r2,r0,#NMOE_RTR+#RTR_NEXP
  LA r3,#NMOE_RTR+#RTR_ACTS
  LA r4,#NMOE_RTR+#RTR_LOG
  CALL @nmod_gemv_q4
  CMP r1,r0
  JMP[NE] @nmo_rtr_bad

  MOVI r5,0
nmo_rtr_bias_l:
  LD r1,r0,#NMOE_RTR+#RTR_NEXP
  CMP r5,r1
  JMP[GE] @nmo_rtr_bias_d
  LA r2,#NMOE_RTR+#RTR_LOG
  ADD r2,r2,r5
  LD r6,r2,0
  ADD r7,r6,r0
  LD r3,r0,#NMOE_RTR+#RTR_FLAGS
  MOVI r4,1
  BOOL.8 r3,r3,r4
  CMP r3,r0
  JMP[EQ] @nmo_rtr_store
  LD r3,r0,#NMOE_RTR+#RTR_PLACE
  SHL r4,r5,1
  ADD r3,r3,r4
  LD r3,r3,0
  LD r4,r0,#NMOE_RTR+#RTR_NODE
  SUB r8,r3,r4
  CMP r8,r0
  JMP[GE] @nmo_rtr_abs
  SUB r8,r0,r8
nmo_rtr_abs:
  CMP r8,r0
  JMP[EQ] @nmo_rtr_store
  CVTIF r8,r8
  LD r9,r0,#NMOE_RTR+#RTR_BIAS
  FMUL r8,r8,r9
  FSUB r7,r6,r8
nmo_rtr_store:
  LA r2,#NMOE_RTR+#RTR_SCORE
  ADD r2,r2,r5
  ST r7,r2,0
  ADD r5,r5,r13
  JMP @nmo_rtr_bias_l
nmo_rtr_bias_d:

  MOVI r5,0
nmo_rtr_copy_l:
  LD r1,r0,#NMOE_RTR+#RTR_NEXP
  CMP r5,r1
  JMP[GE] @nmo_rtr_ok
  LA r2,#NMOE_RTR+#RTR_LOG
  ADD r2,r2,r5
  LD r6,r2,0
  LD r3,r0,#NMOE_RTR+#RTR_LOGO
  ADD r3,r3,r5
  ST r6,r3,0
  LA r2,#NMOE_RTR+#RTR_SCORE
  ADD r2,r2,r5
  LD r7,r2,0
  LD r4,r0,#NMOE_RTR+#RTR_SCO
  ADD r4,r4,r5
  ST r7,r4,0
  ADD r5,r5,r13
  JMP @nmo_rtr_copy_l
nmo_rtr_ok:
  MOVI r1,0
  JMP @nmo_rtr_out
nmo_rtr_bad:
  LA r1,0xFFFFFFFF
nmo_rtr_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nmoe_topk r1=logits r2=n r3=k r4=ids r5=vals -> 0/-1
; Repeated max scan; ties keep the lowest candidate id not yet selected.
nmoe_topk:
  ST r1,r0,#NMOE_TOP+#TOP_LOG
  ST r2,r0,#NMOE_TOP+#TOP_N
  ST r3,r0,#NMOE_TOP+#TOP_K
  ST r4,r0,#NMOE_TOP+#TOP_IDS
  ST r5,r0,#NMOE_TOP+#TOP_VALS
  CMP r2,r0
  JMP[LE] @nmo_topk_bad
  MOVI r6,#NMOE_MAX_EXP
  CMP r2,r6
  JMP[GT] @nmo_topk_bad
  CMP r3,r0
  JMP[LE] @nmo_topk_bad
  CMP r3,r2
  JMP[GT] @nmo_topk_bad
  CMP r4,r0
  JMP[EQ] @nmo_topk_bad
  CMP r5,r0
  JMP[EQ] @nmo_topk_bad
  ST r0,r0,#NMOE_TOP+#TOP_RANK
nmo_topk_rank:
  LD r1,r0,#NMOE_TOP+#TOP_RANK
  LD r2,r0,#NMOE_TOP+#TOP_K
  CMP r1,r2
  JMP[GE] @nmo_topk_ok
  LA r3,0xFFFFFFFF
  ST r3,r0,#NMOE_TOP+#TOP_BEST
  ST r0,r0,#NMOE_TOP+#TOP_BVAL
  ST r0,r0,#NMOE_TOP+#TOP_CAND
nmo_topk_cand:
  LD r1,r0,#NMOE_TOP+#TOP_CAND
  LD r2,r0,#NMOE_TOP+#TOP_N
  CMP r1,r2
  JMP[GE] @nmo_topk_candd
  MOVI r3,0
  ST r3,r0,#NMOE_TOP+#TOP_SKIP
nmo_topk_skip:
  LD r3,r0,#NMOE_TOP+#TOP_SKIP
  LD r4,r0,#NMOE_TOP+#TOP_RANK
  CMP r3,r4
  JMP[GE] @nmo_topk_use
  LD r5,r0,#NMOE_TOP+#TOP_IDS
  ADD r5,r5,r3
  LD r5,r5,0
  LD r6,r0,#NMOE_TOP+#TOP_CAND
  CMP r5,r6
  JMP[EQ] @nmo_topk_next
  ADD r3,r3,r13
  ST r3,r0,#NMOE_TOP+#TOP_SKIP
  JMP @nmo_topk_skip
nmo_topk_use:
  LD r5,r0,#NMOE_TOP+#TOP_LOG
  LD r6,r0,#NMOE_TOP+#TOP_CAND
  ADD r5,r5,r6
  LD r5,r5,0
  LD r7,r0,#NMOE_TOP+#TOP_BEST
  LA r8,0xFFFFFFFF
  CMP r7,r8
  JMP[EQ] @nmo_topk_take
  LD r7,r0,#NMOE_TOP+#TOP_BVAL
  FCMP r5,r7
  JMP[GT] @nmo_topk_take
  JMP @nmo_topk_next
nmo_topk_take:
  LD r6,r0,#NMOE_TOP+#TOP_CAND
  ST r6,r0,#NMOE_TOP+#TOP_BEST
  ST r5,r0,#NMOE_TOP+#TOP_BVAL
nmo_topk_next:
  LD r1,r0,#NMOE_TOP+#TOP_CAND
  ADD r1,r1,r13
  ST r1,r0,#NMOE_TOP+#TOP_CAND
  JMP @nmo_topk_cand
nmo_topk_candd:
  LD r1,r0,#NMOE_TOP+#TOP_IDS
  LD r2,r0,#NMOE_TOP+#TOP_RANK
  ADD r1,r1,r2
  LD r3,r0,#NMOE_TOP+#TOP_BEST
  ST r3,r1,0
  LD r1,r0,#NMOE_TOP+#TOP_VALS
  ADD r1,r1,r2
  LD r3,r0,#NMOE_TOP+#TOP_BVAL
  ST r3,r1,0
  ADD r2,r2,r13
  ST r2,r0,#NMOE_TOP+#TOP_RANK
  JMP @nmo_topk_rank
nmo_topk_ok:
  MOVI r1,0
  RET
nmo_topk_bad:
  LA r1,0xFFFFFFFF
  RET

; ---------------------------------------------------------------------------
; nmoe_softmax_sel r1=logits r2=ids r3=k r4=weights -> 0/-1
; Max-shifted f32 softmax over the selected raw logits.
nmoe_softmax_sel:
  ST r1,r0,#NMOE_TOP+#TOP_LOG
  ST r2,r0,#NMOE_TOP+#TOP_IDS
  ST r3,r0,#NMOE_TOP+#TOP_K
  ST r4,r0,#NMOE_TOP+#TOP_VALS
  CMP r3,r0
  JMP[LE] @nmo_sm_bad
  MOVI r5,#NMOE_MAX_K
  CMP r3,r5
  JMP[GT] @nmo_sm_bad
  CMP r1,r0
  JMP[EQ] @nmo_sm_bad
  CMP r2,r0
  JMP[EQ] @nmo_sm_bad
  CMP r4,r0
  JMP[EQ] @nmo_sm_bad

  ADD r5,r2,r0
  LD r6,r5,0
  ADD r5,r1,r6
  LD r7,r5,0
  ST r7,r0,#NMOE_TOP+#TOP_MAX
  MOVI r8,1
nmo_sm_max_l:
  CMP r8,r3
  JMP[GE] @nmo_sm_max_d
  ADD r5,r2,r8
  LD r6,r5,0
  ADD r5,r1,r6
  LD r6,r5,0
  LD r7,r0,#NMOE_TOP+#TOP_MAX
  FCMP r6,r7
  JMP[LE] @nmo_sm_max_n
  ST r6,r0,#NMOE_TOP+#TOP_MAX
nmo_sm_max_n:
  ADD r8,r8,r13
  JMP @nmo_sm_max_l
nmo_sm_max_d:

  MOVI r8,0
  ST r0,r0,#NMOE_TOP+#TOP_SUM
nmo_sm_exp_l:
  CMP r8,r3
  JMP[GE] @nmo_sm_exp_d
  ADD r5,r2,r8
  LD r6,r5,0
  ADD r5,r1,r6
  LD r6,r5,0
  LD r7,r0,#NMOE_TOP+#TOP_MAX
  FSUB r6,r6,r7
  FEXP r6,r6
  LD r5,r0,#NMOE_TOP+#TOP_VALS
  ADD r5,r5,r8
  ST r6,r5,0
  LD r7,r0,#NMOE_TOP+#TOP_SUM
  FADD r7,r7,r6
  ST r7,r0,#NMOE_TOP+#TOP_SUM
  ADD r8,r8,r13
  JMP @nmo_sm_exp_l
nmo_sm_exp_d:

  MOVI r8,0
nmo_sm_div_l:
  CMP r8,r3
  JMP[GE] @nmo_sm_ok
  LD r5,r0,#NMOE_TOP+#TOP_VALS
  ADD r5,r5,r8
  LD r6,r5,0
  LD r7,r0,#NMOE_TOP+#TOP_SUM
  FDIV r6,r6,r7
  ST r6,r5,0
  ADD r8,r8,r13
  JMP @nmo_sm_div_l
nmo_sm_ok:
  MOVI r1,0
  RET
nmo_sm_bad:
  LA r1,0xFFFFFFFF
  RET

; ---------------------------------------------------------------------------
; nmoe_route r1=cfg r2=x r3=ids(k) r4=weights(k) -> 0/-1
nmoe_route:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NMOE_RTE+#RTE_CFG
  ST r2,r0,#NMOE_RTE+#RTE_X
  ST r3,r0,#NMOE_RTE+#RTE_IDS
  ST r4,r0,#NMOE_RTE+#RTE_W
  CMP r2,r0
  JMP[EQ] @nmo_rt_bad
  CMP r3,r0
  JMP[EQ] @nmo_rt_bad
  CMP r4,r0
  JMP[EQ] @nmo_rt_bad
  LD r1,r0,#NMOE_RTE+#RTE_CFG
  LD r2,r0,#NMOE_RTE+#RTE_X
  LA r3,#NMOE_RTE+#RTE_LOG
  LA r4,#NMOE_RTE+#RTE_SCORE
  CALL @nmoe_router
  CMP r1,r0
  JMP[NE] @nmo_rt_bad
  LD r1,r0,#NMOE_RTE+#RTE_CFG
  LD r2,r1,#NMOE_C_NEXP
  ST r2,r0,#NMOE_RTE+#RTE_N
  LD r2,r1,#NMOE_C_TOPK
  ST r2,r0,#NMOE_RTE+#RTE_K
  LA r1,#NMOE_RTE+#RTE_SCORE
  LD r2,r0,#NMOE_RTE+#RTE_N
  LD r3,r0,#NMOE_RTE+#RTE_K
  LA r4,#NMOE_RTE+#RTE_SIDS
  LA r5,#NMOE_RTE+#RTE_SVALS
  CALL @nmoe_topk
  CMP r1,r0
  JMP[NE] @nmo_rt_bad
  LA r1,#NMOE_RTE+#RTE_LOG
  LA r2,#NMOE_RTE+#RTE_SIDS
  LD r3,r0,#NMOE_RTE+#RTE_K
  LA r4,#NMOE_RTE+#RTE_WTS
  CALL @nmoe_softmax_sel
  CMP r1,r0
  JMP[NE] @nmo_rt_bad
  MOVI r5,0
nmo_rt_copy_l:
  LD r1,r0,#NMOE_RTE+#RTE_K
  CMP r5,r1
  JMP[GE] @nmo_rt_ok
  LA r2,#NMOE_RTE+#RTE_SIDS
  ADD r2,r2,r5
  LD r6,r2,0
  LD r3,r0,#NMOE_RTE+#RTE_IDS
  ADD r3,r3,r5
  ST r6,r3,0
  LA r2,#NMOE_RTE+#RTE_WTS
  ADD r2,r2,r5
  LD r7,r2,0
  LD r4,r0,#NMOE_RTE+#RTE_W
  ADD r4,r4,r5
  ST r7,r4,0
  ADD r5,r5,r13
  JMP @nmo_rt_copy_l
nmo_rt_ok:
  MOVI r1,0
  JMP @nmo_rt_out
nmo_rt_bad:
  LA r1,0xFFFFFFFF
nmo_rt_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nmoe_expert r1=cfg r2=expert r3=x r4=out(dim) -> 0/-1
; h = relu(W1_e * x); y = W2_e * h.  Q4_0 rows are 32-lane padded.
nmoe_expert:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NMOE_EXP+#EXP_CFG
  ST r2,r0,#NMOE_EXP+#EXP_E
  ST r3,r0,#NMOE_EXP+#EXP_X
  ST r4,r0,#NMOE_EXP+#EXP_OUT
  CMP r3,r0
  JMP[EQ] @nmo_exp_bad
  CMP r4,r0
  JMP[EQ] @nmo_exp_bad
  CALL @nmo_check
  CMP r1,r0
  JMP[NE] @nmo_exp_bad
  LD r1,r0,#NMOE_EXP+#EXP_CFG
  LD r2,r0,#NMOE_EXP+#EXP_E
  LD r3,r1,#NMOE_C_NEXP
  CMP r2,r3
  JMP[GE] @nmo_exp_bad
  LD r2,r1,#NMOE_C_DIM
  ST r2,r0,#NMOE_EXP+#EXP_DIM
  LD r2,r1,#NMOE_C_HIDDEN
  ST r2,r0,#NMOE_EXP+#EXP_HID

  LD r1,r0,#NMOE_EXP+#EXP_X
  LD r2,r0,#NMOE_EXP+#EXP_DIM
  LA r3,#NMOE_EXP+#EXP_ACTS
  CALL @nmo_acts
  LA r1,#NMOE_EXP+#EXP_H
  MOVI r2,32
  BFILL r1,r0,r2

  ; W1 block pointer = w1 + expert*hidden*5
  LD r1,r0,#NMOE_EXP+#EXP_CFG
  LD r1,r1,#NMOE_C_W1
  LD r2,r0,#NMOE_EXP+#EXP_E
  LD r3,r0,#NMOE_EXP+#EXP_HID
  MUL r2,r2,r3
  MOVI r4,5
  MUL r2,r2,r4
  ADD r1,r1,r2
  LD r2,r0,#NMOE_EXP+#EXP_HID
  LA r3,#NMOE_EXP+#EXP_ACTS
  LA r4,#NMOE_EXP+#EXP_H
  CALL @nmod_gemv_q4
  CMP r1,r0
  JMP[NE] @nmo_exp_bad

  MOVI r5,0
nmo_exp_relu_l:
  LD r1,r0,#NMOE_EXP+#EXP_HID
  CMP r5,r1
  JMP[GE] @nmo_exp_relu_d
  LA r2,#NMOE_EXP+#EXP_H
  ADD r2,r2,r5
  LD r3,r2,0
  FCMP r3,r0
  JMP[GE] @nmo_exp_relu_n
  ST r0,r2,0
nmo_exp_relu_n:
  ADD r5,r5,r13
  JMP @nmo_exp_relu_l
nmo_exp_relu_d:

  ; W2 block pointer = w2 + expert*dim*5
  LD r1,r0,#NMOE_EXP+#EXP_CFG
  LD r1,r1,#NMOE_C_W2
  LD r2,r0,#NMOE_EXP+#EXP_E
  LD r3,r0,#NMOE_EXP+#EXP_DIM
  MUL r2,r2,r3
  MOVI r4,5
  MUL r2,r2,r4
  ADD r1,r1,r2
  LD r2,r0,#NMOE_EXP+#EXP_DIM
  LA r3,#NMOE_EXP+#EXP_H
  LD r4,r0,#NMOE_EXP+#EXP_OUT
  CALL @nmod_gemv_q4
  CMP r1,r0
  JMP[NE] @nmo_exp_bad
  MOVI r1,0
  JMP @nmo_exp_out
nmo_exp_bad:
  LA r1,0xFFFFFFFF
nmo_exp_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nmoe_forward r1=cfg r2=x rows r3=count r4=out rows r5=stats -> 0/-1
nmoe_forward:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NMOE_FWD+#F_CFG
  ST r2,r0,#NMOE_FWD+#F_X
  ST r3,r0,#NMOE_FWD+#F_COUNT
  ST r4,r0,#NMOE_FWD+#F_OUT
  ST r5,r0,#NMOE_FWD+#F_STATS
  CMP r2,r0
  JMP[EQ] @nmo_fw_bad
  CMP r3,r0
  JMP[LE] @nmo_fw_bad
  MOVI r6,64
  CMP r3,r6
  JMP[GT] @nmo_fw_bad
  CMP r4,r0
  JMP[EQ] @nmo_fw_bad
  CMP r5,r0
  JMP[EQ] @nmo_fw_bad
  CALL @nmo_check
  CMP r1,r0
  JMP[NE] @nmo_fw_bad

  LD r1,r0,#NMOE_FWD+#F_CFG
  LD r2,r1,#NMOE_C_NEXP
  ST r2,r0,#NMOE_FWD+#F_NEXP
  LD r2,r1,#NMOE_C_TOPK
  ST r2,r0,#NMOE_FWD+#F_TOPK
  LD r2,r1,#NMOE_C_DIM
  ST r2,r0,#NMOE_FWD+#F_DIM

  ; stats and counters start clean
  LD r1,r0,#NMOE_FWD+#F_STATS
  MOVI r2,#NMS_WORDS
  BFILL r1,r0,r2
  LA r1,#NMOE_FWD+#F_ACCEPT
  MOVI r2,8
  BFILL r1,r0,r2
  LA r1,#NMOE_FWD+#F_DROP
  MOVI r2,8
  BFILL r1,r0,r2
  LA r1,#NMOE_FWD+#F_ASSIGN
  MOVI r2,8
  BFILL r1,r0,r2
  LA r1,#NMOE_FWD+#F_LOCAL
  MOVI r2,8
  BFILL r1,r0,r2
  LA r1,#NMOE_FWD+#F_REMOTE
  MOVI r2,8
  BFILL r1,r0,r2
  LA r1,#NMOE_FWD+#F_VRAM
  MOVI r2,8
  BFILL r1,r0,r2
  LA r1,#NMOE_FWD+#F_DRAM
  MOVI r2,8
  BFILL r1,r0,r2
  ST r0,r0,#NMOE_FWD+#F_TOKDROP
  ST r0,r0,#NMOE_FWD+#F_TOKZERO

  ; capacity = ceil(count*topk*cap_num / (n_experts*cap_den))
  LD r1,r0,#NMOE_FWD+#F_COUNT
  LD r2,r0,#NMOE_FWD+#F_TOPK
  MUL r1,r1,r2
  LD r2,r0,#NMOE_FWD+#F_CFG
  LD r2,r2,#NMOE_C_CAPNUM
  MUL r1,r1,r2
  LD r2,r0,#NMOE_FWD+#F_NEXP
  LD r3,r0,#NMOE_FWD+#F_CFG
  LD r3,r3,#NMOE_C_CAPDEN
  MUL r2,r2,r3
  CMP r1,r0
  JMP[EQ] @nmo_fw_cap0
  ADD r1,r1,r2
  ADDI r1,r1,-1
  DIVU r1,r1,r2
  JMP @nmo_fw_capd
nmo_fw_cap0:
  MOVI r1,0
nmo_fw_capd:
  ST r1,r0,#NMOE_FWD+#F_CAP

  ST r0,r0,#NMOE_FWD+#F_T
nmo_fw_tok_l:
  LD r1,r0,#NMOE_FWD+#F_T
  LD r2,r0,#NMOE_FWD+#F_COUNT
  CMP r1,r2
  JMP[GE] @nmo_fw_tok_d
  LD r3,r0,#NMOE_FWD+#F_DIM
  MUL r4,r1,r3
  LD r5,r0,#NMOE_FWD+#F_X
  ADD r5,r5,r4
  ST r5,r0,#NMOE_FWD+#F_ROW
  LD r5,r0,#NMOE_FWD+#F_OUT
  ADD r5,r5,r4
  ST r5,r0,#NMOE_FWD+#F_OUTROW
  LD r1,r0,#NMOE_FWD+#F_OUTROW
  LD r2,r0,#NMOE_FWD+#F_DIM
  BFILL r1,r0,r2

  LD r1,r0,#NMOE_FWD+#F_CFG
  LD r2,r0,#NMOE_FWD+#F_ROW
  LA r3,#NMOE_FWD+#F_IDS
  LA r4,#NMOE_FWD+#F_W
  CALL @nmoe_route
  CMP r1,r0
  JMP[NE] @nmo_fw_bad
  ST r0,r0,#NMOE_FWD+#F_ANY
  ST r0,r0,#NMOE_FWD+#F_TOKACC
  ST r0,r0,#NMOE_FWD+#F_J

nmo_fw_j_l:
  LD r1,r0,#NMOE_FWD+#F_J
  LD r2,r0,#NMOE_FWD+#F_TOPK
  CMP r1,r2
  JMP[GE] @nmo_fw_j_d
  LA r3,#NMOE_FWD+#F_IDS
  ADD r3,r3,r1
  LD r4,r3,0
  ST r4,r0,#NMOE_FWD+#F_E

  ; assign[e]++
  LA r5,#NMOE_FWD+#F_ASSIGN
  ADD r5,r5,r4
  LD r6,r5,0
  ADD r6,r6,r13
  ST r6,r5,0

  ; placement accounting
  LD r5,r0,#NMOE_FWD+#F_CFG
  LD r5,r5,#NMOE_C_PLACE
  SHL r6,r4,1
  ADD r5,r5,r6
  LD r6,r5,0
  LD r7,r5,1
  LD r8,r0,#NMOE_FWD+#F_CFG
  LD r8,r8,#NMOE_C_NODE
  CMP r6,r8
  JMP[NE] @nmo_fw_remote
  LA r9,#NMOE_FWD+#F_LOCAL
  ADD r9,r9,r4
  LD r10,r9,0
  ADD r10,r10,r13
  ST r10,r9,0
  JMP @nmo_fw_node_d
nmo_fw_remote:
  LA r9,#NMOE_FWD+#F_REMOTE
  ADD r9,r9,r4
  LD r10,r9,0
  ADD r10,r10,r13
  ST r10,r9,0
nmo_fw_node_d:
  MOVI r8,1
  BOOL.8 r8,r7,r8
  CMP r8,r0
  JMP[EQ] @nmo_fw_dram
  LA r9,#NMOE_FWD+#F_VRAM
  ADD r9,r9,r4
  LD r10,r9,0
  ADD r10,r10,r13
  ST r10,r9,0
  JMP @nmo_fw_place_d
nmo_fw_dram:
  LA r9,#NMOE_FWD+#F_DRAM
  ADD r9,r9,r4
  LD r10,r9,0
  ADD r10,r10,r13
  ST r10,r9,0
nmo_fw_place_d:

  ; capacity check
  LD r4,r0,#NMOE_FWD+#F_E
  LA r5,#NMOE_FWD+#F_ACCEPT
  ADD r5,r5,r4
  LD r6,r5,0
  LD r7,r0,#NMOE_FWD+#F_CAP
  CMP r6,r7
  JMP[GE] @nmo_fw_drop
  ADD r6,r6,r13
  ST r6,r5,0
  LD r6,r0,#NMOE_FWD+#F_TOKACC
  ADD r6,r6,r13
  ST r6,r0,#NMOE_FWD+#F_TOKACC

  LD r1,r0,#NMOE_FWD+#F_CFG
  LD r2,r0,#NMOE_FWD+#F_E
  LD r3,r0,#NMOE_FWD+#F_ROW
  LA r4,#NMOE_FWD+#F_EXPOUT
  CALL @nmoe_expert
  CMP r1,r0
  JMP[NE] @nmo_fw_bad
  LD r1,r0,#NMOE_FWD+#F_J
  LA r2,#NMOE_FWD+#F_W
  ADD r2,r2,r1
  LD r2,r2,0
  LA r3,#NMOE_FWD+#F_EXPOUT
  LD r4,r0,#NMOE_FWD+#F_DIM
  LD r5,r0,#NMOE_FWD+#F_OUTROW
  MOVI r6,0
nmo_fw_add_l:
  CMP r6,r4
  JMP[GE] @nmo_fw_add_d
  ADD r7,r3,r6
  LD r7,r7,0
  FMUL r7,r7,r2
  ADD r8,r5,r6
  LD r9,r8,0
  FADD r9,r9,r7
  ST r9,r8,0
  ADD r6,r6,r13
  JMP @nmo_fw_add_l
nmo_fw_add_d:
  JMP @nmo_fw_j_n

nmo_fw_drop:
  LD r4,r0,#NMOE_FWD+#F_E
  LA r5,#NMOE_FWD+#F_DROP
  ADD r5,r5,r4
  LD r6,r5,0
  ADD r6,r6,r13
  ST r6,r5,0
  MOVI r6,1
  ST r6,r0,#NMOE_FWD+#F_ANY
nmo_fw_j_n:
  LD r1,r0,#NMOE_FWD+#F_J
  ADD r1,r1,r13
  ST r1,r0,#NMOE_FWD+#F_J
  JMP @nmo_fw_j_l
nmo_fw_j_d:
  LD r1,r0,#NMOE_FWD+#F_ANY
  CMP r1,r0
  JMP[EQ] @nmo_fw_noany
  LD r1,r0,#NMOE_FWD+#F_TOKDROP
  ADD r1,r1,r13
  ST r1,r0,#NMOE_FWD+#F_TOKDROP
  LD r1,r0,#NMOE_FWD+#F_TOKACC
  CMP r1,r0
  JMP[NE] @nmo_fw_noany
  LD r1,r0,#NMOE_FWD+#F_TOKZERO
  ADD r1,r1,r13
  ST r1,r0,#NMOE_FWD+#F_TOKZERO
nmo_fw_noany:
  LD r1,r0,#NMOE_FWD+#F_T
  ADD r1,r1,r13
  ST r1,r0,#NMOE_FWD+#F_T
  JMP @nmo_fw_tok_l
nmo_fw_tok_d:

  ; header fields
  LD r1,r0,#NMOE_FWD+#F_STATS
  LD r2,r0,#NMOE_FWD+#F_COUNT
  ST r2,r1,#NMS_TOKENS
  LD r2,r0,#NMOE_FWD+#F_TOPK
  ST r2,r1,#NMS_TOPK
  LD r2,r0,#NMOE_FWD+#F_CAP
  ST r2,r1,#NMS_CAP
  LD r2,r0,#NMOE_FWD+#F_NEXP
  ST r2,r1,#NMS_EXPERTS
  LD r2,r0,#NMOE_FWD+#F_TOKDROP
  ST r2,r1,#NMS_TOKDROP
  LD r2,r0,#NMOE_FWD+#F_TOKZERO
  ST r2,r1,#NMS_TOKZERO
  LD r2,r0,#NMOE_FWD+#F_COUNT
  LD r3,r0,#NMOE_FWD+#F_TOPK
  MUL r2,r2,r3
  ST r2,r1,#NMS_ASSIGN
  LD r2,r0,#NMOE_FWD+#F_CFG
  LD r3,r2,#NMOE_C_FLAGS
  ST r3,r1,#NMS_FLAGS
  LD r3,r2,#NMOE_C_CAPNUM
  ST r3,r1,#NMS_CAPNUM
  LD r3,r2,#NMOE_C_CAPDEN
  ST r3,r1,#NMS_CAPDEN
  LD r3,r2,#NMOE_C_BIAS
  ST r3,r1,#NMS_BIAS

  ; totals
  MOVI r2,0
  MOVI r3,0
  MOVI r4,0
  MOVI r5,0
  MOVI r6,0
  MOVI r7,0
  MOVI r8,0
nmo_fw_sum_l:
  LD r9,r0,#NMOE_FWD+#F_NEXP
  CMP r8,r9
  JMP[GE] @nmo_fw_sum_d
  LA r10,#NMOE_FWD+#F_ACCEPT
  ADD r10,r10,r8
  LD r11,r10,0
  ADD r2,r2,r11
  LA r10,#NMOE_FWD+#F_DROP
  ADD r10,r10,r8
  LD r11,r10,0
  ADD r3,r3,r11
  LA r10,#NMOE_FWD+#F_LOCAL
  ADD r10,r10,r8
  LD r11,r10,0
  ADD r4,r4,r11
  LA r10,#NMOE_FWD+#F_REMOTE
  ADD r10,r10,r8
  LD r11,r10,0
  ADD r5,r5,r11
  LA r10,#NMOE_FWD+#F_VRAM
  ADD r10,r10,r8
  LD r11,r10,0
  ADD r6,r6,r11
  LA r10,#NMOE_FWD+#F_DRAM
  ADD r10,r10,r8
  LD r11,r10,0
  ADD r7,r7,r11
  ADD r8,r8,r13
  JMP @nmo_fw_sum_l
nmo_fw_sum_d:
  ST r2,r1,#NMS_ACCEPT
  ST r3,r1,#NMS_DROP
  ST r4,r1,#NMS_LOCAL
  ST r5,r1,#NMS_REMOTE
  ST r6,r1,#NMS_VRAM
  ST r7,r1,#NMS_DRAM

  ; per-expert arrays
  MOVI r8,0
nmo_fw_cp_l:
  LD r9,r0,#NMOE_FWD+#F_NEXP
  CMP r8,r9
  JMP[GE] @nmo_fw_cp_d
  LA r10,#NMOE_FWD+#F_ASSIGN
  ADD r10,r10,r8
  LD r11,r10,0
  ADDI r10,r1,#NMS_EXP_ASSIGN
  ADD r10,r10,r8
  ST r11,r10,0
  LA r10,#NMOE_FWD+#F_ACCEPT
  ADD r10,r10,r8
  LD r11,r10,0
  ADDI r10,r1,#NMS_EXP_ACCEPT
  ADD r10,r10,r8
  ST r11,r10,0
  LA r10,#NMOE_FWD+#F_DROP
  ADD r10,r10,r8
  LD r11,r10,0
  ADDI r10,r1,#NMS_EXP_DROP
  ADD r10,r10,r8
  ST r11,r10,0
  LA r10,#NMOE_FWD+#F_LOCAL
  ADD r10,r10,r8
  LD r11,r10,0
  ADDI r10,r1,#NMS_EXP_LOCAL
  ADD r10,r10,r8
  ST r11,r10,0
  LA r10,#NMOE_FWD+#F_REMOTE
  ADD r10,r10,r8
  LD r11,r10,0
  ADDI r10,r1,#NMS_EXP_REMOTE
  ADD r10,r10,r8
  ST r11,r10,0
  LA r10,#NMOE_FWD+#F_VRAM
  ADD r10,r10,r8
  LD r11,r10,0
  ADDI r10,r1,#NMS_EXP_VRAM
  ADD r10,r10,r8
  ST r11,r10,0
  LA r10,#NMOE_FWD+#F_DRAM
  ADD r10,r10,r8
  LD r11,r10,0
  ADDI r10,r1,#NMS_EXP_DRAM
  ADD r10,r10,r8
  ST r11,r10,0
  ADD r8,r8,r13
  JMP @nmo_fw_cp_l
nmo_fw_cp_d:

  ; max/min accept
  MOVI r2,0
  LA r3,0xFFFFFFFF
  MOVI r8,0
nmo_fw_mm_l:
  LD r9,r0,#NMOE_FWD+#F_NEXP
  CMP r8,r9
  JMP[GE] @nmo_fw_mm_d
  LA r10,#NMOE_FWD+#F_ACCEPT
  ADD r10,r10,r8
  LD r11,r10,0
  CMP r11,r2
  JMP[LE] @nmo_fw_mm_min
  ADD r2,r11,r0
nmo_fw_mm_min:
  CMP r11,r3
  JMP[GE] @nmo_fw_mm_n
  ADD r3,r11,r0
nmo_fw_mm_n:
  ADD r8,r8,r13
  JMP @nmo_fw_mm_l
nmo_fw_mm_d:
  LD r1,r0,#NMOE_FWD+#F_STATS
  ST r2,r1,#NMS_MAXA
  ST r3,r1,#NMS_MINA
  SUB r4,r2,r3
  ST r4,r1,#NMS_SPAN
  MOVI r1,0
  JMP @nmo_fw_out
nmo_fw_bad:
  LA r1,0xFFFFFFFF
nmo_fw_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
