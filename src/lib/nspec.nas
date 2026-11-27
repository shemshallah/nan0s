; nspec.nas - deterministic speculative decoding with paged KV rollback (F13b).
;
; Pure NaN.  A small draft stream proposes K tokens; an exact verifier stream
; (the npaged/nattn path) appends each proposal to a paged KV context, computes
; the real logits, and accepts the longest prefix that matches the verifier's
; own deterministic sample.  On the first mismatch the draft record already
; appended at that position is rolled back with npaged_trim (block generation
; bump + record-header rewrite), then the verifier's token is appended at the
; same position and decoding continues.  The accepted/rejected/rollback
; counters and a hash-chained trace are recorded in the context.
;
; Simplification (explicit, not hidden)
; -------------------------------------
; The draft model is a first-order table, not a second transformer:
;   draft_scores[prev_token * vocab + candidate] is a tiny f32 logit table.
; The draft stream samples one token from that row with its own xorshift
; stream, then uses that token as the row for the next draft inside the same
; step.  It has no KV and no attention.  The verifier is exact: it reuses
; npaged_append + npaged_attention (nattn Q4xQ8 attention, RoPE, softmax,
; RMSNorm and the Wo projection) over the same immutable nattn cfg / weight
; root as the plain decode path.  A real deployment would replace the table
; with a small transformer sharing the weight root; the accept/reject and KV
; rollback machinery is already the real one.
;
; Determinism and exactness
; -------------------------
; Both plain and speculative generation sample exactly once per output token
; from the same logits vector with the same verifier xorshift stream and the
; same temperature.  Draft draws use a separate stream, so they cannot perturb
; verifier sampling.  The draft token is only accepted when it equals the
; verifier sample; hence every accepted token is a plain-decode token at the
; same position.  The verifier logits at position p depend only on the prefix
; tokens 0..p (causal attention), and the rollback leaves that prefix's record
; payload bit-identical (only the generation word changes).  Therefore
; speculative token ids, per-token pre-sample logits and the final next-token
; logits are bit-equal to plain decode for the same prompt and seed.
;
; The nreplay xorshift recurrence is reproduced locally as ns_xorshift because
; nreplay.nas includes nantrace/nanobj, which would duplicate the nanobj
; definitions already pulled in by npaged -> nattn -> nkv.  ns_xorshift is
; step-for-step identical to nrng_next (13/17/5, zero remaps to 0x9E3779B9)
; and the gate pins its exact seed-1 output.
;
; Context layout (160 words, caller supplied)
; -------------------------------------------
;   +0 magic 0x4350534E ("NSPC")  +1 version 1
;   +2 npaged ctx                 +3 nattn cfg (immutable weight root)
;   +4 draft score table          +5 token embedding table
;   +6 vocab (1..64)              +7 dim (32..64)
;   +8 draft K (1..8)             +9 temperature bits (0 = greedy)
;   +10 flags (bit0 = force reject next first draft)
;   +11 verifier xorshift state   +12 draft xorshift state
;   +13 prompt length             +14 generated tokens
;   +15 accepted drafts           +16 rejected drafts
;   +17 rollbacks                 +18 verifier passes
;   +19 drafts made               +20 speculative steps
;   +21 trace buffer              +22 trace capacity
;   +23 trace events              +24 trace head
;   +25 forced rejections         +26 last token id
;   +27 reserved
;   +28 initial verifier seed     +29 initial draft seed
;   +30..31 reserved
;   +32..95  current logits (64)  +96..159 scratch logits (64)
;
; Init config (13 words, caller supplied)
;   +0 magic 0x4643534E ("NSFC")  +1 version 1
;   +2 vocab  +3 K  +4 temp bits  +5 flags
;   +6 verifier seed  +7 draft seed
;   +8 draft score table  +9 token table
;   +10 trace buffer  +11 trace capacity
;   +12 nattn cfg (the immutable weight root shared with plain decode)
;
; API (r0=0, r13=1, r14 grows up, r15 link):
;   nspec_init           r1=ctx r2=npaged ctx r3=cfg -> 0/-1
;   nspec_prefill        r1=ctx r2=xs r3=count r4=last_token -> 0/-1
;   nspec_generate       r1=ctx r2=tokens_out r3=logits_out r4=count
;                        -> count/-1 (speculative)
;   nspec_generate_plain r1=ctx r2=tokens_out r3=logits_out r4=count
;                        -> count/-1 (npaged_decode reference path)
;   nspec_cur_logits     r1=ctx -> pointer to 64 current logits / 0
;   nspec_set_flags      r1=ctx r2=flags -> 0/-1
;   nspec_flags          r1=ctx -> flags / -1
;   nspec_head           r1=ctx -> trace head / 0
;   nspec_trace          r1=ctx r2=index r3=out(4) -> 0/-1
;   nspec_stats          r1=ctx r2=out(16) -> 0/-1
;                        out: prompt,generated,accepted,rejected,rollbacks,
;                             verifier_passes,drafts,steps,trace_events,head,
;                             vocab,K,seed,draft_seed,flags,forced_rejections
;
; Events (4 words: kind, a, b, head):
;   1 prefill(count,last)  2 plain(pos,token)  3 draft(pos,token)
;   4 accept(pos,token)    5 reject(pos,draft) 6 rollback(pos,oldgen,newgen)
;   7 emit(pos,token)
;
; Scratch 0x4700..0x47FF (below npaged 0x4800, nkv 0x5000, nattn 0x5600,
; nq4 0x6000).  Requires r13=1, r14 soft stack, r0=0.

.include "npaged.nas"

.equ NS_MAGIC      0x4350534E
.equ NS_CFG_MAGIC  0x4643534E
.equ NS_VERSION    1
.equ NS_VMAX       64
.equ NS_KMAX       8
.equ NS_XOR0       0x9E3779B9
.equ NS_HEAD0      0x811C9DC5

; context
.equ NS_C_MAGIC    0
.equ NS_C_VERSION  1
.equ NS_C_NP       2
.equ NS_C_CFG      3
.equ NS_C_DRAFT    4
.equ NS_C_TOK      5
.equ NS_C_VOCAB    6
.equ NS_C_DIM      7
.equ NS_C_K        8
.equ NS_C_TEMP     9
.equ NS_C_FLAGS    10
.equ NS_C_SEED     11
.equ NS_C_DSEED    12
.equ NS_C_PROMPT   13
.equ NS_C_GEN      14
.equ NS_C_ACC      15
.equ NS_C_REJ      16
.equ NS_C_ROLL     17
.equ NS_C_PASS     18
.equ NS_C_DRAFTS   19
.equ NS_C_STEPS    20
.equ NS_C_TRACE    21
.equ NS_C_TCAP     22
.equ NS_C_TN       23
.equ NS_C_HEAD     24
.equ NS_C_FORCED   25
.equ NS_C_LAST     26
.equ NS_C_SEED0    28
.equ NS_C_DSEED0   29
.equ NS_C_CUR      32
.equ NS_C_TMP      96
.equ NS_CTX_WORDS  160

; init config
.equ NS_K_MAGIC    0
.equ NS_K_VERSION  1
.equ NS_K_VOCAB    2
.equ NS_K_K        3
.equ NS_K_TEMP     4
.equ NS_K_FLAGS    5
.equ NS_K_SEED     6
.equ NS_K_DSEED    7
.equ NS_K_DRAFT    8
.equ NS_K_TOK      9
.equ NS_K_TRACE    10
.equ NS_K_TCAP     11
.equ NS_K_WEIGHTS  12

; event kinds
.equ NS_E_PREFILL  1
.equ NS_E_PLAIN    2
.equ NS_E_DRAFT    3
.equ NS_E_ACCEPT   4
.equ NS_E_REJECT   5
.equ NS_E_ROLLBACK 6
.equ NS_E_EMIT     7

; scratch: generate state, sampler state, draft state, sampler weights
.equ NS_G          0x4700
.equ NS_F          0x4720
.equ NS_D          0x4730
.equ NS_W          0x4740

; nspec_generate scratch (absolute addresses inside NS_G)
.equ NS_G_CTX      0x4700
.equ NS_G_TOK      0x4701
.equ NS_G_LOG      0x4702
.equ NS_G_CNT      0x4703
.equ NS_G_OUT      0x4704
.equ NS_G_I        0x4705
.equ NS_G_POS      0x4706
.equ NS_G_EXP      0x4707
.equ NS_G_DRF      0x4708
.equ NS_G_PREV     0x4709
.equ NS_G_DIM      0x470A
.equ NS_G_VOC      0x470B
.equ NS_G_K        0x470C
.equ NS_G_NP       0x470D
.equ NS_G_CFG      0x470E
.equ NS_G_XP       0x470F
.equ NS_G_OLD      0x4710
.equ NS_G_TOKEN    0x4711
.equ NS_G_BASE     0x4712

; ---------------------------------------------------------------------------
; ns_xorshift: r1=seed -> next 32-bit value.  Same recurrence as nrng_next.
ns_xorshift:
  CMP r1,r0
  JMP[NE] @nsxs_go
  LA r1,#NS_XOR0
nsxs_go:
  SHL r2,r1,13
  BOOL.6 r1,r1,r2
  SHR r2,r1,17
  BOOL.6 r1,r1,r2
  SHL r2,r1,5
  BOOL.6 r1,r1,r2
  CMP r1,r0
  JMP[NE] @nsxs_done
  LA r1,#NS_XOR0
nsxs_done:
  RET

; ---------------------------------------------------------------------------
; ns_copy: r1=src r2=dst r3=words -> 0
ns_copy:
  MOVI r4,0
nscp_l:
  CMP r4,r3
  JMP[GE] @nscp_d
  ADD r5,r1,r4
  LD r5,r5,0
  ADD r6,r2,r4
  ST r5,r6,0
  ADD r4,r4,r13
  JMP @nscp_l
nscp_d:
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; ns_event: r1=ctx r2=kind r3=a r4=b -> 0/-1.
; Appends {kind,a,b,head} to the caller trace if there is room and updates
; the hash chain.  The event always advances the head even when the buffer is
; full, so a trace-capacity mistake cannot make two different runs look equal.
ns_event:
  LD r5,r1,#NS_C_MAGIC
  LA r6,#NS_MAGIC
  CMP r5,r6
  JMP[NE] @nsev_bad
  LD r5,r1,#NS_C_HEAD
  LA r6,0x9E3779B9
  ADD r6,r6,r2
  SHL r7,r5,6
  ADD r6,r6,r7
  SHR r7,r5,2
  ADD r6,r6,r7
  BOOL.6 r5,r5,r6
  LA r6,0x85EBCA6B
  ADD r6,r6,r3
  SHL r7,r5,6
  ADD r6,r6,r7
  SHR r7,r5,2
  ADD r6,r6,r7
  BOOL.6 r5,r5,r6
  LA r6,0xC2B2AE35
  ADD r6,r6,r4
  SHL r7,r5,6
  ADD r6,r6,r7
  SHR r7,r5,2
  ADD r6,r6,r7
  BOOL.6 r5,r5,r6
  ST r5,r1,#NS_C_HEAD
  LD r6,r1,#NS_C_TRACE
  CMP r6,r0
  JMP[EQ] @nsev_ok
  LD r7,r1,#NS_C_TN
  LD r8,r1,#NS_C_TCAP
  CMP r7,r8
  JMP[GE] @nsev_ok
  SHL r8,r7,2
  ADD r8,r6,r8
  ST r2,r8,0
  ST r3,r8,1
  ST r4,r8,2
  ST r5,r8,3
  ADD r7,r7,r13
  ST r7,r1,#NS_C_TN
nsev_ok:
  MOVI r1,0
  RET
nsev_bad:
  LA r1,0xFFFFFFFF
  RET

; ---------------------------------------------------------------------------
; ns_sample: r1=logits r2=n r3=temperature bits r4=seed
;            -> r1=index r2=next_seed
; Temperature sampling over all n logits with the nreplay xorshift draw.
; temp bits 0 is greedy and leaves the seed unchanged.  Ties choose the lower
; index.  No top-k/p filter is applied; this is the tiny-vocab prototype
; sampler and is used identically by plain and speculative paths.
ns_sample:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r5,#NS_F
  ST r1,r5,0
  ST r2,r5,1
  ST r3,r5,2
  ST r4,r5,3
  CMP r1,r0
  JMP[EQ] @nss_bad
  CMP r2,r0
  JMP[LE] @nss_bad
  MOVI r6,#NS_VMAX
  CMP r2,r6
  JMP[GT] @nss_bad
  CMP r3,r0
  JMP[EQ] @nss_greedy
  SHR r6,r3,31
  CMP r6,r0
  JMP[NE] @nss_bad

  ; max
  LD r8,r0,#NS_F+0
  LD r9,r0,#NS_F+1
  LD r10,r8,0
  MOVI r11,1
nss_max:
  CMP r11,r9
  JMP[GE] @nss_maxd
  ADD r12,r8,r11
  LD r12,r12,0
  FCMP r12,r10
  JMP[LE] @nss_maxn
  ADD r10,r12,r0
nss_maxn:
  ADD r11,r11,r13
  JMP @nss_max
nss_maxd:
  ; weights and sum
  MOVI r11,0
  MOVI r12,0
nss_w:
  CMP r11,r9
  JMP[GE] @nss_wd
  ADD r1,r8,r11
  LD r1,r1,0
  FSUB r1,r1,r10
  LD r2,r0,#NS_F+2
  FDIV r1,r1,r2
  FEXP r1,r1
  LA r2,#NS_W
  ADD r2,r2,r11
  ST r1,r2,0
  FADD r12,r12,r1
  ADD r11,r11,r13
  JMP @nss_w
nss_wd:
  ; next = xorshift(seed); threshold = (next>>8)/2^24 * sum
  LD r1,r0,#NS_F+3
  CALL @ns_xorshift
  ST r1,r0,#NS_F+4
  SHR r2,r1,8
  CVTIF r2,r2
  LA r3,0x33800000
  FMUL r2,r2,r3
  FMUL r2,r2,r12
  ST r2,r0,#NS_F+5
  MOVI r11,0
  MOVI r3,0
nss_pick:
  CMP r11,r9
  JMP[GE] @nss_last
  LA r4,#NS_W
  ADD r4,r4,r11
  LD r4,r4,0
  FADD r3,r3,r4
  LD r5,r0,#NS_F+5
  FCMP r3,r5
  JMP[GE] @nss_hit
  ADD r11,r11,r13
  JMP @nss_pick
nss_hit:
  ADD r1,r11,r0
  LD r2,r0,#NS_F+4
  JMP @nss_out
nss_last:
  ADDI r1,r9,-1
  LD r2,r0,#NS_F+4
  JMP @nss_out
nss_greedy:
  LD r8,r0,#NS_F+0
  LD r9,r0,#NS_F+1
  LD r10,r8,0
  MOVI r4,0
  MOVI r11,1
nss_gl:
  CMP r11,r9
  JMP[GE] @nss_gd
  ADD r5,r8,r11
  LD r5,r5,0
  FCMP r5,r10
  JMP[LE] @nss_gn
  ADD r10,r5,r0
  ADD r4,r11,r0
nss_gn:
  ADD r11,r11,r13
  JMP @nss_gl
nss_gd:
  ADD r1,r4,r0
  LD r2,r0,#NS_F+3
  JMP @nss_out
nss_bad:
  LA r1,0xFFFFFFFF
  MOVI r2,0
nss_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; ns_draft: r1=ctx r2=prev token -> r1=draft token
; Samples the draft table row for prev with the draft xorshift stream.
ns_draft:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r3,#NS_D
  ST r1,r3,0
  ST r2,r3,1
  LD r4,r1,#NS_C_MAGIC
  LA r5,#NS_MAGIC
  CMP r4,r5
  JMP[NE] @nsd_bad
  LD r4,r1,#NS_C_VOCAB
  CMP r2,r4
  JMP[GE] @nsd_bad
  ; row = draft table + prev*vocab
  LD r5,r1,#NS_C_DRAFT
  CMP r5,r0
  JMP[EQ] @nsd_bad
  MUL r2,r2,r4
  ADD r5,r5,r2
  ADD r1,r5,r0
  ADD r2,r4,r0
  LD r3,r0,#NS_D+0
  LD r3,r3,#NS_C_TEMP
  LD r4,r0,#NS_D+0
  LD r4,r4,#NS_C_DSEED
  CALL @ns_sample
  LA r3,0xFFFFFFFF
  CMP r1,r3
  JMP[EQ] @nsd_bad
  ST r2,r0,#NS_D+2
  LD r3,r0,#NS_D+0
  LD r4,r0,#NS_D+2
  ST r4,r3,#NS_C_DSEED
  JMP @nsd_out
nsd_bad:
  LA r1,0xFFFFFFFF
nsd_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nspec_init: r1=ctx r2=npaged ctx r3=cfg -> 0/-1
nspec_init:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r4,#NS_G
  ST r1,r4,0
  ST r2,r4,1
  ST r3,r4,2
  CMP r1,r0
  JMP[EQ] @nsi_bad
  CMP r2,r0
  JMP[EQ] @nsi_bad
  CMP r3,r0
  JMP[EQ] @nsi_bad
  LD r5,r3,#NS_K_MAGIC
  LA r6,#NS_CFG_MAGIC
  CMP r5,r6
  JMP[NE] @nsi_bad
  LD r5,r3,#NS_K_VERSION
  MOVI r6,#NS_VERSION
  CMP r5,r6
  JMP[NE] @nsi_bad
  ; npaged context must be live
  LD r5,r2,#NP_C_MAGIC
  LA r6,#NP_MAGIC
  CMP r5,r6
  JMP[NE] @nsi_bad
  LD r5,r2,#NP_C_VERSION
  MOVI r6,#NP_VERSION
  CMP r5,r6
  JMP[NE] @nsi_bad
  ; vocab and K
  LD r5,r3,#NS_K_VOCAB
  CMP r5,r0
  JMP[LE] @nsi_bad
  MOVI r6,#NS_VMAX
  CMP r5,r6
  JMP[GT] @nsi_bad
  LD r6,r3,#NS_K_K
  CMP r6,r0
  JMP[LE] @nsi_bad
  MOVI r7,#NS_KMAX
  CMP r6,r7
  JMP[GT] @nsi_bad
  ; temperature must be non-negative
  LD r6,r3,#NS_K_TEMP
  SHR r7,r6,31
  CMP r7,r0
  JMP[NE] @nsi_bad
  ; table pointers
  LD r6,r3,#NS_K_DRAFT
  CMP r6,r0
  JMP[EQ] @nsi_bad
  LD r6,r3,#NS_K_TOK
  CMP r6,r0
  JMP[EQ] @nsi_bad
  ; trace cap without buffer is rejected
  LD r6,r3,#NS_K_TCAP
  CMP r6,r0
  JMP[EQ] @nsi_trace_ok
  LD r7,r3,#NS_K_TRACE
  CMP r7,r0
  JMP[EQ] @nsi_bad
nsi_trace_ok:
  ; dim from the paged context
  LD r6,r2,#NP_C_DIM
  MOVI r7,32
  CMP r6,r7
  JMP[LT] @nsi_bad
  MOVI r7,#NP_MAXDIM
  CMP r6,r7
  JMP[GT] @nsi_bad
  MOVI r7,31
  BOOL.8 r7,r6,r7
  CMP r7,r0
  JMP[NE] @nsi_bad
  ; the shared nattn weight root must be a live cfg with the same dim
  LD r7,r3,#NS_K_WEIGHTS
  CMP r7,r0
  JMP[EQ] @nsi_bad
  LD r8,r7,0
  LA r9,#NATT_MAGIC
  CMP r8,r9
  JMP[NE] @nsi_bad
  LD r8,r7,1
  MOVI r9,#NATT_VERSION
  CMP r8,r9
  JMP[NE] @nsi_bad
  LD r8,r7,3
  CMP r8,r6
  JMP[NE] @nsi_bad
  LD r8,r7,15
  CMP r8,r0
  JMP[EQ] @nsi_bad
  LD r8,r7,16
  CMP r8,r0
  JMP[EQ] @nsi_bad
  ST r7,r0,#NS_G+3

  ; zero the context
  LD r1,r0,#NS_G+0
  MOVI r2,#NS_CTX_WORDS
  MOVI r3,0
nsi_z:
  CMP r3,r2
  JMP[GE] @nsi_zd
  ADD r4,r1,r3
  ST r0,r4,0
  ADD r3,r3,r13
  JMP @nsi_z
nsi_zd:

  LD r1,r0,#NS_G+0
  LA r2,#NS_MAGIC
  ST r2,r1,#NS_C_MAGIC
  MOVI r2,#NS_VERSION
  ST r2,r1,#NS_C_VERSION
  LD r3,r0,#NS_G+1
  ST r3,r1,#NS_C_NP
  LD r2,r0,#NS_G+3
  ST r2,r1,#NS_C_CFG
  LD r2,r0,#NS_G+2
  LD r4,r2,#NS_K_VOCAB
  ST r4,r1,#NS_C_VOCAB
  ST r6,r1,#NS_C_DIM
  LD r4,r2,#NS_K_K
  ST r4,r1,#NS_C_K
  LD r4,r2,#NS_K_TEMP
  ST r4,r1,#NS_C_TEMP
  LD r4,r2,#NS_K_FLAGS
  ST r4,r1,#NS_C_FLAGS
  LD r4,r2,#NS_K_DRAFT
  ST r4,r1,#NS_C_DRAFT
  LD r4,r2,#NS_K_TOK
  ST r4,r1,#NS_C_TOK
  LD r4,r2,#NS_K_TRACE
  ST r4,r1,#NS_C_TRACE
  LD r4,r2,#NS_K_TCAP
  ST r4,r1,#NS_C_TCAP
  ; seeds: map zero to the fixed nonzero state
  LD r4,r2,#NS_K_SEED
  CMP r4,r0
  JMP[NE] @nsi_seed
  LA r4,#NS_XOR0
nsi_seed:
  ST r4,r1,#NS_C_SEED
  ST r4,r1,#NS_C_SEED0
  LD r4,r2,#NS_K_DSEED
  CMP r4,r0
  JMP[NE] @nsi_dseed
  LA r4,#NS_XOR0
nsi_dseed:
  ST r4,r1,#NS_C_DSEED
  ST r4,r1,#NS_C_DSEED0
  LA r4,#NS_HEAD0
  ST r4,r1,#NS_C_HEAD
  MOVI r1,0
  JMP @nsi_out
nsi_bad:
  LA r1,0xFFFFFFFF
nsi_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nspec_prefill: r1=ctx r2=xs r3=count r4=last_token -> 0/-1
nspec_prefill:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r5,#NS_G
  ST r1,r5,0
  ST r2,r5,1
  ST r3,r5,2
  ST r4,r5,3
  CMP r1,r0
  JMP[EQ] @nsp_bad
  LD r5,r1,#NS_C_MAGIC
  LA r6,#NS_MAGIC
  CMP r5,r6
  JMP[NE] @nsp_bad
  CMP r2,r0
  JMP[EQ] @nsp_bad
  CMP r3,r0
  JMP[LE] @nsp_bad
  LD r5,r1,#NS_C_VOCAB
  CMP r4,r5
  JMP[GE] @nsp_bad
  ; prefill is only defined on a fresh paged context
  LD r5,r1,#NS_C_NP
  LD r5,r5,#NP_C_USED
  CMP r5,r0
  JMP[NE] @nsp_bad
  ; npaged_prefill(ctx, xs, count, 0, cfg, cur)
  LD r1,r0,#NS_G+0
  LD r1,r1,#NS_C_NP
  LD r2,r0,#NS_G+1
  LD r3,r0,#NS_G+2
  MOVI r4,0
  LD r5,r0,#NS_G+0
  LD r5,r5,#NS_C_CFG
  LD r6,r0,#NS_G+0
  ADD r6,r6,r0
  LA r7,#NS_C_CUR
  ADD r6,r6,r7
  CALL @npaged_prefill
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nsp_bad
  ; reset the sequence counters and streams
  LD r1,r0,#NS_G+0
  LD r2,r0,#NS_G+2
  ST r2,r1,#NS_C_PROMPT
  ST r0,r1,#NS_C_GEN
  ST r0,r1,#NS_C_ACC
  ST r0,r1,#NS_C_REJ
  ST r0,r1,#NS_C_ROLL
  ST r0,r1,#NS_C_PASS
  ST r0,r1,#NS_C_DRAFTS
  ST r0,r1,#NS_C_STEPS
  ST r0,r1,#NS_C_FLAGS
  ST r0,r1,#NS_C_FORCED
  ST r0,r1,#NS_C_TN
  LA r3,#NS_HEAD0
  ST r3,r1,#NS_C_HEAD
  LD r3,r1,#NS_C_SEED0
  ST r3,r1,#NS_C_SEED
  LD r3,r1,#NS_C_DSEED0
  ST r3,r1,#NS_C_DSEED
  LD r3,r0,#NS_G+3
  ST r3,r1,#NS_C_LAST
  ; event prefill(count,last)
  ADD r1,r1,r0
  MOVI r2,#NS_E_PREFILL
  LD r3,r0,#NS_G+2
  LD r4,r0,#NS_G+3
  CALL @ns_event
  MOVI r1,0
  JMP @nsp_out
nsp_bad:
  LA r1,0xFFFFFFFF
nsp_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nspec_generate: r1=ctx r2=tokens_out r3=logits_out r4=count -> count/-1
nspec_generate:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r5,#NS_G
  ST r1,r5,0
  ST r2,r5,1
  ST r3,r5,2
  ST r4,r5,3
  CMP r1,r0
  JMP[EQ] @nsg_bad
  CMP r2,r0
  JMP[EQ] @nsg_bad
  CMP r3,r0
  JMP[EQ] @nsg_bad
  CMP r4,r0
  JMP[LE] @nsg_bad
  LD r5,r1,#NS_C_MAGIC
  LA r6,#NS_MAGIC
  CMP r5,r6
  JMP[NE] @nsg_bad
  LD r5,r1,#NS_C_PROMPT
  CMP r5,r0
  JMP[EQ] @nsg_bad
  ; remaining capacity (npaged_remaining returns -1 on a bad context)
  LD r1,r0,#NS_G+0
  LD r1,r1,#NS_C_NP
  CALL @npaged_remaining
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nsg_bad
  LD r2,r0,#NS_G+3
  CMP r1,r2
  JMP[LT] @nsg_bad
  ; cache constants
  LD r1,r0,#NS_G+0
  LD r2,r1,#NS_C_NP
  ST r2,r0,#NS_G_NP
  LD r2,r1,#NS_C_CFG
  ST r2,r0,#NS_G_CFG
  LD r2,r1,#NS_C_VOCAB
  ST r2,r0,#NS_G_VOC
  LD r2,r1,#NS_C_DIM
  ST r2,r0,#NS_G_DIM
  LD r2,r1,#NS_C_K
  ST r2,r0,#NS_G_K
  ST r0,r0,#NS_G_OUT
  ; positions continue after any tokens generated by earlier calls
  LD r2,r1,#NS_C_PROMPT
  LD r3,r1,#NS_C_GEN
  ADD r2,r2,r3
  ST r2,r0,#NS_G_BASE
  ; forced rejection with a one-token vocabulary cannot mismatch
  LD r2,r1,#NS_C_FLAGS
  MOVI r3,1
  BOOL.8 r2,r2,r3
  CMP r2,r0
  JMP[EQ] @nsg_step
  LD r2,r1,#NS_C_VOCAB
  MOVI r3,2
  CMP r2,r3
  JMP[LT] @nsg_bad

nsg_step:
  LD r1,r0,#NS_G_OUT
  LD r2,r0,#NS_G_CNT
  CMP r1,r2
  JMP[GE] @nsg_done
  ST r0,r0,#NS_G_I
  LD r1,r0,#NS_G_CTX
  LD r2,r1,#NS_C_LAST
  ST r2,r0,#NS_G_PREV

nsg_inner:
  LD r1,r0,#NS_G_I
  LD r2,r0,#NS_G_K
  CMP r1,r2
  JMP[GE] @nsg_step_done
  LD r1,r0,#NS_G_OUT
  LD r2,r0,#NS_G_CNT
  CMP r1,r2
  JMP[GE] @nsg_step_done
  ; pos = prompt + generated_before_call + out
  LD r1,r0,#NS_G_BASE
  LD r3,r0,#NS_G_OUT
  ADD r2,r1,r3
  ST r2,r0,#NS_G_POS

  ; expected = sample(cur, vocab, temp, seed)
  LD r1,r0,#NS_G_CTX
  ADD r1,r1,r0
  LA r2,#NS_C_CUR
  ADD r1,r1,r2
  LD r2,r0,#NS_G_VOC
  LD r3,r0,#NS_G_CTX
  LD r3,r3,#NS_C_TEMP
  LD r4,r0,#NS_G_CTX
  LD r4,r4,#NS_C_SEED
  CALL @ns_sample
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nsg_bad
  ST r1,r0,#NS_G_EXP
  LD r3,r0,#NS_G_CTX
  ST r2,r3,#NS_C_SEED

  ; draft = ns_draft(ctx, prev)
  LD r1,r0,#NS_G_CTX
  LD r2,r0,#NS_G_PREV
  CALL @ns_draft
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nsg_bad
  ST r1,r0,#NS_G_DRF

  ; forced-rejection hook: only the first draft of a step, then clear bit 0
  LD r1,r0,#NS_G_CTX
  LD r1,r1,#NS_C_FLAGS
  MOVI r2,1
  BOOL.8 r2,r1,r2
  CMP r2,r0
  JMP[EQ] @nsg_noforce
  LD r2,r0,#NS_G_I
  CMP r2,r0
  JMP[NE] @nsg_noforce
  ; draft = (expected + 1) % vocab
  LD r1,r0,#NS_G_EXP
  ADD r1,r1,r13
  LD r2,r0,#NS_G_VOC
  CMP r1,r2
  JMP[LT] @nsg_fset
  MOVI r1,0
nsg_fset:
  ST r1,r0,#NS_G_DRF
  LD r1,r0,#NS_G_CTX
  LD r2,r1,#NS_C_FLAGS
  LA r3,0xFFFFFFFE
  BOOL.8 r2,r2,r3
  ST r2,r1,#NS_C_FLAGS
  LD r2,r1,#NS_C_FORCED
  ADD r2,r2,r13
  ST r2,r1,#NS_C_FORCED
nsg_noforce:
  ; drafts made++
  LD r1,r0,#NS_G_CTX
  LD r2,r1,#NS_C_DRAFTS
  ADD r2,r2,r13
  ST r2,r1,#NS_C_DRAFTS
  ; event draft(pos, token)
  ADD r1,r1,r0
  MOVI r2,#NS_E_DRAFT
  LD r3,r0,#NS_G_POS
  LD r4,r0,#NS_G_DRF
  CALL @ns_event

  ; xptr = token table + draft*dim
  LD r1,r0,#NS_G_CTX
  LD r2,r1,#NS_C_TOK
  LD r3,r0,#NS_G_DRF
  LD r4,r0,#NS_G_DIM
  MUL r3,r3,r4
  ADD r2,r2,r3
  ST r2,r0,#NS_G_XP

  ; append the draft at pos
  LD r1,r0,#NS_G_NP
  LD r2,r0,#NS_G_XP
  LD r3,r0,#NS_G_POS
  LD r4,r0,#NS_G_CFG
  CALL @npaged_append
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nsg_bad
  ST r1,r0,#NS_G_TOKEN
  ; verifier pass++
  LD r1,r0,#NS_G_CTX
  LD r2,r1,#NS_C_PASS
  ADD r2,r2,r13
  ST r2,r1,#NS_C_PASS
  ; attention at the draft position -> scratch logits
  LD r1,r0,#NS_G_NP
  LD r2,r0,#NS_G_TOKEN
  LD r3,r0,#NS_G_CFG
  LD r4,r0,#NS_G_CTX
  ADD r4,r4,r0
  LA r5,#NS_C_TMP
  ADD r4,r4,r5
  CALL @npaged_attention
  CMP r1,r0
  JMP[NE] @nsg_bad

  ; accept iff draft == expected
  LD r1,r0,#NS_G_DRF
  LD r2,r0,#NS_G_EXP
  CMP r1,r2
  JMP[NE] @nsg_reject

  ; accepted: record logits_out[out] = cur, token = draft, cur = tmp
  LD r1,r0,#NS_G_LOG
  LD r2,r0,#NS_G_OUT
  LD r3,r0,#NS_G_DIM
  MUL r2,r2,r3
  ADD r2,r1,r2
  LD r1,r0,#NS_G_CTX
  ADD r1,r1,r0
  LA r3,#NS_C_CUR
  ADD r1,r1,r3
  LD r3,r0,#NS_G_DIM
  CALL @ns_copy
  LD r1,r0,#NS_G_TOK
  LD r2,r0,#NS_G_OUT
  ADD r2,r1,r2
  LD r1,r0,#NS_G_DRF
  ST r1,r2,0
  LD r1,r0,#NS_G_CTX
  ADD r1,r1,r0
  LA r2,#NS_C_TMP
  ADD r1,r1,r2
  LD r2,r0,#NS_G_CTX
  ADD r2,r2,r0
  LA r3,#NS_C_CUR
  ADD r2,r2,r3
  LD r3,r0,#NS_G_DIM
  CALL @ns_copy
  LD r1,r0,#NS_G_CTX
  LD r2,r1,#NS_C_ACC
  ADD r2,r2,r13
  ST r2,r1,#NS_C_ACC
  LD r2,r0,#NS_G_DRF
  ST r2,r0,#NS_G_PREV
  ST r2,r1,#NS_C_LAST
  LD r2,r0,#NS_G_OUT
  ADD r2,r2,r13
  ST r2,r0,#NS_G_OUT
  LD r2,r0,#NS_G_I
  ADD r2,r2,r13
  ST r2,r0,#NS_G_I
  ; event accept(pos, token)
  ADD r1,r1,r0
  MOVI r2,#NS_E_ACCEPT
  LD r3,r0,#NS_G_POS
  LD r4,r0,#NS_G_DRF
  CALL @ns_event
  JMP @nsg_inner

nsg_reject:
  ; event reject(pos, draft)
  LD r1,r0,#NS_G_CTX
  ADD r1,r1,r0
  MOVI r2,#NS_E_REJECT
  LD r3,r0,#NS_G_POS
  LD r4,r0,#NS_G_DRF
  CALL @ns_event
  ; old generation of the last accepted token at pos-1
  LD r1,r0,#NS_G_NP
  LD r2,r0,#NS_G_POS
  ADDI r2,r2,-1
  CALL @npaged_token_gen
  ST r1,r0,#NS_G_OLD
  ; roll the paged KV back to pos (drop the rejected draft)
  LD r1,r0,#NS_G_NP
  LD r2,r0,#NS_G_POS
  CALL @npaged_trim
  CMP r1,r0
  JMP[NE] @nsg_bad
  LD r1,r0,#NS_G_CTX
  LD r2,r1,#NS_C_ROLL
  ADD r2,r2,r13
  ST r2,r1,#NS_C_ROLL
  LD r2,r1,#NS_C_REJ
  ADD r2,r2,r13
  ST r2,r1,#NS_C_REJ
  ; event rollback(pos, oldgen); the test also reads the new generation
  LD r1,r0,#NS_G_CTX
  ADD r1,r1,r0
  MOVI r2,#NS_E_ROLLBACK
  LD r3,r0,#NS_G_POS
  LD r4,r0,#NS_G_OLD
  CALL @ns_event
  ; record logits_out[out] = cur (pre-draft logits), token = expected
  LD r1,r0,#NS_G_LOG
  LD r2,r0,#NS_G_OUT
  LD r3,r0,#NS_G_DIM
  MUL r2,r2,r3
  ADD r2,r1,r2
  LD r1,r0,#NS_G_CTX
  ADD r1,r1,r0
  LA r3,#NS_C_CUR
  ADD r1,r1,r3
  LD r3,r0,#NS_G_DIM
  CALL @ns_copy
  LD r1,r0,#NS_G_TOK
  LD r2,r0,#NS_G_OUT
  ADD r2,r1,r2
  LD r1,r0,#NS_G_EXP
  ST r1,r2,0
  ; append the verifier token at pos and compute its logits into cur
  LD r1,r0,#NS_G_CTX
  LD r2,r1,#NS_C_TOK
  LD r3,r0,#NS_G_EXP
  LD r4,r0,#NS_G_DIM
  MUL r3,r3,r4
  ADD r2,r2,r3
  ST r2,r0,#NS_G_XP
  LD r1,r0,#NS_G_NP
  LD r2,r0,#NS_G_XP
  LD r3,r0,#NS_G_POS
  LD r4,r0,#NS_G_CFG
  CALL @npaged_append
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nsg_bad
  ST r1,r0,#NS_G_TOKEN
  LD r1,r0,#NS_G_CTX
  LD r2,r1,#NS_C_PASS
  ADD r2,r2,r13
  ST r2,r1,#NS_C_PASS
  LD r1,r0,#NS_G_NP
  LD r2,r0,#NS_G_TOKEN
  LD r3,r0,#NS_G_CFG
  LD r4,r0,#NS_G_CTX
  ADD r4,r4,r0
  LA r5,#NS_C_CUR
  ADD r4,r4,r5
  CALL @npaged_attention
  CMP r1,r0
  JMP[NE] @nsg_bad
  ; prev/last = expected, out++
  LD r1,r0,#NS_G_CTX
  LD r2,r0,#NS_G_EXP
  ST r2,r0,#NS_G_PREV
  ST r2,r1,#NS_C_LAST
  LD r2,r0,#NS_G_OUT
  ADD r2,r2,r13
  ST r2,r0,#NS_G_OUT
  ; event emit(pos, expected)
  ADD r1,r1,r0
  MOVI r2,#NS_E_EMIT
  LD r3,r0,#NS_G_POS
  LD r4,r0,#NS_G_EXP
  CALL @ns_event
  ; the step ends at the first rejection
  JMP @nsg_step_done

nsg_step_done:
  LD r1,r0,#NS_G_CTX
  LD r2,r1,#NS_C_STEPS
  ADD r2,r2,r13
  ST r2,r1,#NS_C_STEPS
  JMP @nsg_step

nsg_done:
  LD r1,r0,#NS_G_CTX
  LD r2,r1,#NS_C_GEN
  LD r3,r0,#NS_G_CNT
  ADD r2,r2,r3
  ST r2,r1,#NS_C_GEN
  LD r1,r0,#NS_G_CNT
  JMP @nsg_out
nsg_bad:
  LA r1,0xFFFFFFFF
nsg_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nspec_generate_plain: r1=ctx r2=tokens_out r3=logits_out r4=count
;                       -> count/-1
; The reference path: one npaged_decode per token, same sampler and seed.
nspec_generate_plain:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r5,#NS_G
  ST r1,r5,0
  ST r2,r5,1
  ST r3,r5,2
  ST r4,r5,3
  CMP r1,r0
  JMP[EQ] @nsplain_bad
  CMP r2,r0
  JMP[EQ] @nsplain_bad
  CMP r3,r0
  JMP[EQ] @nsplain_bad
  CMP r4,r0
  JMP[LE] @nsplain_bad
  LD r5,r1,#NS_C_MAGIC
  LA r6,#NS_MAGIC
  CMP r5,r6
  JMP[NE] @nsplain_bad
  LD r5,r1,#NS_C_PROMPT
  CMP r5,r0
  JMP[EQ] @nsplain_bad
  LD r1,r0,#NS_G+0
  LD r1,r1,#NS_C_NP
  CALL @npaged_remaining
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nsplain_bad
  LD r2,r0,#NS_G+3
  CMP r1,r2
  JMP[LT] @nsplain_bad
  LD r1,r0,#NS_G+0
  LD r2,r1,#NS_C_NP
  ST r2,r0,#NS_G_NP
  LD r2,r1,#NS_C_CFG
  ST r2,r0,#NS_G_CFG
  LD r2,r1,#NS_C_VOCAB
  ST r2,r0,#NS_G_VOC
  LD r2,r1,#NS_C_DIM
  ST r2,r0,#NS_G_DIM
  ST r0,r0,#NS_G_OUT
  ; positions continue after any tokens generated by earlier calls
  LD r2,r1,#NS_C_PROMPT
  LD r3,r1,#NS_C_GEN
  ADD r2,r2,r3
  ST r2,r0,#NS_G_BASE
nsplain_l:
  LD r1,r0,#NS_G_OUT
  LD r2,r0,#NS_G_CNT
  CMP r1,r2
  JMP[GE] @nsplain_done
  ; pos = prompt + generated_before_call + out
  LD r1,r0,#NS_G_BASE
  LD r3,r0,#NS_G_OUT
  ADD r2,r1,r3
  ST r2,r0,#NS_G_POS
  ; expected = sample(cur, vocab, temp, seed)
  LD r1,r0,#NS_G_CTX
  ADD r1,r1,r0
  LA r2,#NS_C_CUR
  ADD r1,r1,r2
  LD r2,r0,#NS_G_VOC
  LD r3,r0,#NS_G_CTX
  LD r3,r3,#NS_C_TEMP
  LD r4,r0,#NS_G_CTX
  LD r4,r4,#NS_C_SEED
  CALL @ns_sample
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nsplain_bad
  ST r1,r0,#NS_G_EXP
  LD r3,r0,#NS_G_CTX
  ST r2,r3,#NS_C_SEED
  ; logits_out[out] = cur
  LD r1,r0,#NS_G_LOG
  LD r2,r0,#NS_G_OUT
  LD r3,r0,#NS_G_DIM
  MUL r2,r2,r3
  ADD r2,r1,r2
  LD r1,r0,#NS_G_CTX
  ADD r1,r1,r0
  LA r3,#NS_C_CUR
  ADD r1,r1,r3
  LD r3,r0,#NS_G_DIM
  CALL @ns_copy
  ; tokens_out[out] = expected
  LD r1,r0,#NS_G_TOK
  LD r2,r0,#NS_G_OUT
  ADD r2,r1,r2
  LD r1,r0,#NS_G_EXP
  ST r1,r2,0
  ; xptr = token table + expected*dim
  LD r1,r0,#NS_G_CTX
  LD r2,r1,#NS_C_TOK
  LD r3,r0,#NS_G_EXP
  LD r4,r0,#NS_G_DIM
  MUL r3,r3,r4
  ADD r2,r2,r3
  ST r2,r0,#NS_G_XP
  ; npaged_decode(np, xptr, pos, cfg, tmp)
  LD r1,r0,#NS_G_NP
  LD r2,r0,#NS_G_XP
  LD r3,r0,#NS_G_POS
  LD r4,r0,#NS_G_CFG
  LD r5,r0,#NS_G_CTX
  ADD r5,r5,r0
  LA r6,#NS_C_TMP
  ADD r5,r5,r6
  CALL @npaged_decode
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nsplain_bad
  ST r1,r0,#NS_G_TOKEN
  ; pass++, cur = tmp
  LD r1,r0,#NS_G_CTX
  LD r2,r1,#NS_C_PASS
  ADD r2,r2,r13
  ST r2,r1,#NS_C_PASS
  LD r1,r0,#NS_G_CTX
  ADD r1,r1,r0
  LA r2,#NS_C_TMP
  ADD r1,r1,r2
  LD r2,r0,#NS_G_CTX
  ADD r2,r2,r0
  LA r3,#NS_C_CUR
  ADD r2,r2,r3
  LD r3,r0,#NS_G_DIM
  CALL @ns_copy
  LD r1,r0,#NS_G_CTX
  LD r2,r0,#NS_G_EXP
  ST r2,r1,#NS_C_LAST
  ; event plain(pos, token)
  ADD r1,r1,r0
  MOVI r2,#NS_E_PLAIN
  LD r3,r0,#NS_G_POS
  LD r4,r0,#NS_G_EXP
  CALL @ns_event
  LD r2,r0,#NS_G_OUT
  ADD r2,r2,r13
  ST r2,r0,#NS_G_OUT
  JMP @nsplain_l
nsplain_done:
  LD r1,r0,#NS_G_CTX
  LD r2,r1,#NS_C_GEN
  LD r3,r0,#NS_G_CNT
  ADD r2,r2,r3
  ST r2,r1,#NS_C_GEN
  LD r2,r1,#NS_C_STEPS
  LD r3,r0,#NS_G_CNT
  ADD r2,r2,r3
  ST r2,r1,#NS_C_STEPS
  LD r1,r0,#NS_G_CNT
  JMP @nsplain_out
nsplain_bad:
  LA r1,0xFFFFFFFF
nsplain_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nspec_cur_logits: r1=ctx -> pointer to 64 current logits / 0
nspec_cur_logits:
  LD r2,r1,#NS_C_MAGIC
  LA r3,#NS_MAGIC
  CMP r2,r3
  JMP[NE] @nscu_bad
  ADD r1,r1,r0
  LA r2,#NS_C_CUR
  ADD r1,r1,r2
  RET
nscu_bad:
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; nspec_set_flags: r1=ctx r2=flags -> 0/-1
nspec_set_flags:
  LD r3,r1,#NS_C_MAGIC
  LA r4,#NS_MAGIC
  CMP r3,r4
  JMP[NE] @nssf_bad
  ST r2,r1,#NS_C_FLAGS
  MOVI r1,0
  RET
nssf_bad:
  LA r1,0xFFFFFFFF
  RET

; nspec_flags: r1=ctx -> flags / -1
nspec_flags:
  LD r2,r1,#NS_C_MAGIC
  LA r3,#NS_MAGIC
  CMP r2,r3
  JMP[NE] @nsfl_bad
  LD r1,r1,#NS_C_FLAGS
  RET
nsfl_bad:
  LA r1,0xFFFFFFFF
  RET

; nspec_head: r1=ctx -> head / 0
nspec_head:
  LD r2,r1,#NS_C_MAGIC
  LA r3,#NS_MAGIC
  CMP r2,r3
  JMP[NE] @nsh_bad
  LD r1,r1,#NS_C_HEAD
  RET
nsh_bad:
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; nspec_trace: r1=ctx r2=index r3=out(4) -> 0/-1
nspec_trace:
  LD r4,r1,#NS_C_MAGIC
  LA r5,#NS_MAGIC
  CMP r4,r5
  JMP[NE] @nst_bad
  CMP r3,r0
  JMP[EQ] @nst_bad
  LD r4,r1,#NS_C_TN
  CMP r2,r4
  JMP[GE] @nst_bad
  LD r5,r1,#NS_C_TRACE
  CMP r5,r0
  JMP[EQ] @nst_bad
  SHL r4,r2,2
  ADD r5,r5,r4
  LD r4,r5,0
  ST r4,r3,0
  LD r4,r5,1
  ST r4,r3,1
  LD r4,r5,2
  ST r4,r3,2
  LD r4,r5,3
  ST r4,r3,3
  MOVI r1,0
  RET
nst_bad:
  LA r1,0xFFFFFFFF
  RET

; ---------------------------------------------------------------------------
; nspec_stats: r1=ctx r2=out(16) -> 0/-1
nspec_stats:
  LD r3,r1,#NS_C_MAGIC
  LA r4,#NS_MAGIC
  CMP r3,r4
  JMP[NE] @nsst_bad
  CMP r2,r0
  JMP[EQ] @nsst_bad
  LD r3,r1,#NS_C_PROMPT
  ST r3,r2,0
  LD r3,r1,#NS_C_GEN
  ST r3,r2,1
  LD r3,r1,#NS_C_ACC
  ST r3,r2,2
  LD r3,r1,#NS_C_REJ
  ST r3,r2,3
  LD r3,r1,#NS_C_ROLL
  ST r3,r2,4
  LD r3,r1,#NS_C_PASS
  ST r3,r2,5
  LD r3,r1,#NS_C_DRAFTS
  ST r3,r2,6
  LD r3,r1,#NS_C_STEPS
  ST r3,r2,7
  LD r3,r1,#NS_C_TN
  ST r3,r2,8
  LD r3,r1,#NS_C_HEAD
  ST r3,r2,9
  LD r3,r1,#NS_C_VOCAB
  ST r3,r2,10
  LD r3,r1,#NS_C_K
  ST r3,r2,11
  LD r3,r1,#NS_C_SEED
  ST r3,r2,12
  LD r3,r1,#NS_C_DSEED
  ST r3,r2,13
  LD r3,r1,#NS_C_FLAGS
  ST r3,r2,14
  LD r3,r1,#NS_C_FORCED
  ST r3,r2,15
  MOVI r1,0
  RET
nsst_bad:
  LA r1,0xFFFFFFFF
  RET
