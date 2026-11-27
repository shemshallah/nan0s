; nspectree.nas - tree speculation + batched paged verifier (F13c).
;
; Pure NaN.  A small draft tree (depth 2, two roots, two children per root =
; 6 candidates) is appended to ONE npaged context over the shared immutable
; nattn weight root.  Every candidate carries a per-branch causal mask: the
; mask is the exact ordered ancestor list (prefix tokens plus this branch's
; parent chain).  A single batched verifier call walks all 6 candidates and
; computes each candidate's logits with a masked version of the existing
; npaged/nattn attention arithmetic (same q4/q8 fused dot, same f32 softmax,
; same value accumulation order, same RMSNorm + Wo projection).
;
; Acceptance is the longest root-to-leaf path whose tokens equal the
; verifier's own deterministic samples.  The accepted path is promoted to the
; front of the paged token space (records are relocated only when the winning
; branch is not already the first DFS branch), then npaged_trim releases every
; scratch block/slot that is not on the accepted path.  Rejected candidates,
; their record generations and the promoted generation are reported.
;
; Exactness contract
; ------------------
; For a candidate whose ancestor path is the plain decode prefix plus the
; same tokens at the same RoPE positions, the mask order is 0,1,...,p and the
; mask attention performs exactly the same operations in exactly the same
; order as npaged_attention at token p.  Therefore an accepted branch's
; logits are bit-equal to sequential npaged_decode.  The draft tree only
; chooses candidates; it never changes the verifier arithmetic.  Verifier
; samples are drawn exactly once per emitted token from the same logits in
; the same order as plain decode, so ids and every pre-sample logits vector
; match bit-for-bit.
;
; Diagnostic flags (explicit, not a statistical draft model)
; ----------------------------------------------------------
;   bit0  anchor primary: root A = the verifier sample, child A0 = the
;         sampled next token (obtained by a draft-time root probe), so the
;         primary branch is a guaranteed depth-2 accept.  The real batched
;         verifier recomputes every candidate; the probe only chooses drafts.
;   bit1  anchor alternate: root A is deliberately one past the verifier
;         sample, root B = the verifier sample; the accepted B branch is
;         relocated from its DFS slot to the prefix, then trimmed.
;   bit2  force partial: with bit0, child A0 is deliberately wrong; the step
;         accepts depth 1 and appends the verifier's free token.
;   bit3  force no root: both roots are deliberately wrong; the step accepts
;         nothing, trims all candidates and falls back to two plain verifier
;         appends.
; The anchor modes are correctness diagnostics (like nspec's forced
; rejection), not an acceptance-rate or speedup claim.
;
; Draft model: a first-order vocab x vocab f32 score table, no KV, no
; attention, sampled with its own xorshift stream.  A real tree draft would
; be a second transformer; the mask/verify/promote/trim machinery is real.
;
; Context layout (768 caller words)
; ---------------------------------
;   +0 magic 0x5254534E "NSTR"   +1 version 1
;   +2 npaged ctx                +3 nattn cfg (immutable weight root)
;   +4 token table               +5 draft table
;   +6 vocab                     +7 dim
;   +8 verifier seed             +9 initial verifier seed
;   +10 draft seed               +11 initial draft seed
;   +12 temperature bits         +13 flags
;   +14 prompt length            +15 generated tokens
;   +16 accepted nodes           +17 rejected nodes
;   +18 trimmed nodes            +19 verifier passes
;   +20 tree steps               +21 drafts made
;   +22 trace buffer             +23 trace capacity
;   +24 trace events             +25 trace head
;   +26 last token               +27 depth (2)
;   +28 branch factor (2)        +29 promotions
;   +30 accepted-path generation +31 forced corrections
;   +32 last accepted length     +33 tree prefix (first candidate token)
;   +34..39 reserved
;   +40..103  current logits (64)      +104..167 scratch logits (64)
;   +168..551 candidate logits (6 x 64)
;   +552..623 candidate metadata (6 x 12)
;   +624..719 per-candidate causal masks (6 x 16)
;
; Candidate metadata (12 words):
;   +0 token +1 parent (0xFFFFFFFF root) +2 depth +3 record logical token
;   +4 generation before trim +5 record tag +6 accepted +7 RoPE position
;   +8..11 reserved
;
; Mask entry (16 words): +0 length, +1.. ancestor logical tokens in order.
;
; Init config (12 words)
;   +0 magic 0x4346544E "NTFC" +1 version 1
;   +2 vocab +3 temperature bits +4 flags
;   +5 verifier seed +6 draft seed
;   +7 token table +8 draft table
;   +9 trace buffer +10 trace capacity +11 reserved
;
; API (r0=0, r13=1, r14 grows up, r15 link):
;   nspectree_init           r1=ctx r2=npaged ctx r3=nattn cfg r4=init cfg
;                            -> 0/-1
;   nspectree_prefill        r1=ctx r2=xs r3=count r4=last_token -> 0/-1
;   nspectree_generate       r1=ctx r2=tokens_out r3=logits_out r4=count
;                            -> count/-1 (count must be even; one step emits
;                            exactly two plain-decode tokens)
;   nspectree_generate_plain r1=ctx r2=tokens_out r3=logits_out r4=count
;                            -> count/-1 (npaged_decode reference path)
;   nspectree_set_flags      r1=ctx r2=flags -> 0/-1
;   nspectree_flags          r1=ctx -> flags/-1
;   nspectree_cur_logits     r1=ctx -> 64 current logits / 0
;   nspectree_head           r1=ctx -> trace head / 0
;   nspectree_trace          r1=ctx r2=index r3=out(4) -> 0/-1
;   nspectree_stats          r1=ctx r2=out(24) -> 0/-1
;     out: prompt,generated,accepted,rejected,trimmed,passes,steps,drafts,
;          trace_events,head,vocab,dim,seed,draft_seed,flags,forced,
;          promotions,accepted_gen,last_len,depth,branch,np_used,last,0
;   nspectree_cand           r1=ctx r2=index r3=out(10) -> 0/-1
;     out: token,parent,depth,record,gen_before,tag,accepted,position,0,0
;   nspectree_mask_len       r1=ctx r2=candidate -> length/-1
;   nspectree_mask           r1=ctx r2=candidate r3=index -> token/-1
;   nspectree_branch_gen     r1=ctx r2=candidate -> generation before trim
;
; Events (4 words: kind, a, b, head):
;   1 prefill(count,last)      2 plain(pos,token)
;   3 draft(candidate,token)   4 verify(candidates,pass)
;   5 accept(candidate,token)  6 reject(candidate,token)
;   7 trim(dropped,used)       8 promote(length,generation)
;   9 emit(pos,token)
;
; Scratch 0x3C00..0x3F9F (nspec 0x4700, npaged 0x4800, nattn 0x5600).
; Requires r13=1, r14 soft stack, r0=0.

.include "nspec.nas"

.equ NT_MAGIC       0x5254534E
.equ NT_CFG_MAGIC   0x4346544E
.equ NT_TAG_BASE    0x4E540000
.equ NT_VERSION     1
.equ NT_DEPTH       2
.equ NT_BRANCH      2
.equ NT_NCAND       6
.equ NT_MASKMAX     16
.equ NT_MAXDIM      64
.equ NT_VMAX        64
.equ NT_NONE        0xFFFFFFFF
.equ NT_CTX_WORDS   768

; context
.equ NT_C_MAGIC     0
.equ NT_C_VERSION   1
.equ NT_C_NP        2
.equ NT_C_CFG       3
.equ NT_C_TOK       4
.equ NT_C_DRAFT     5
.equ NT_C_VOCAB     6
.equ NT_C_DIM       7
.equ NT_C_SEED      8
.equ NT_C_SEED0     9
.equ NT_C_DSEED     10
.equ NT_C_DSEED0    11
.equ NT_C_TEMP      12
.equ NT_C_FLAGS     13
.equ NT_C_PROMPT    14
.equ NT_C_GEN       15
.equ NT_C_ACC       16
.equ NT_C_REJ       17
.equ NT_C_TRIM      18
.equ NT_C_PASS      19
.equ NT_C_STEPS     20
.equ NT_C_DRAFTS    21
.equ NT_C_TRACE     22
.equ NT_C_TCAP      23
.equ NT_C_TN        24
.equ NT_C_HEAD      25
.equ NT_C_LAST      26
.equ NT_C_DEPTH     27
.equ NT_C_BRANCH    28
.equ NT_C_PROM      29
.equ NT_C_ACCGEN    30
.equ NT_C_FORCED    31
.equ NT_C_LASTLEN   32
.equ NT_C_TREEPRE   33
.equ NT_C_CUR       40
.equ NT_C_TMP       104
.equ NT_C_CLOG      168
.equ NT_C_CAND      552
.equ NT_C_MASKS     624

; init config
.equ NT_K_MAGIC     0
.equ NT_K_VERSION   1
.equ NT_K_VOCAB     2
.equ NT_K_TEMP      3
.equ NT_K_FLAGS     4
.equ NT_K_SEED      5
.equ NT_K_DSEED     6
.equ NT_K_TOK       7
.equ NT_K_DRAFT     8
.equ NT_K_TRACE     9
.equ NT_K_TCAP      10

; event kinds
.equ NT_E_PREFILL   1
.equ NT_E_PLAIN     2
.equ NT_E_DRAFT     3
.equ NT_E_VERIFY    4
.equ NT_E_ACCEPT    5
.equ NT_E_REJECT    6
.equ NT_E_TRIM      7
.equ NT_E_PROMOTE   8
.equ NT_E_EMIT      9

; scratch (below nspec 0x4700)
.equ NT_G           0x3C00
.equ NT_F           0x3C20
.equ NT_D           0x3C30
.equ NT_SC          0x3C40
.equ NT_CTXW        0x3E40
.equ NT_H           0x3E80
.equ NT_RMS         0x3EC0
.equ NT_MISC        0x3F40
.equ NT_E           0x3F80

; NT_G fields (build state), absolute scratch addresses
.equ NT_G_CTX       0x3C00
.equ NT_G_PREFIX    0x3C01
.equ NT_G_E1        0x3C02
.equ NT_G_E2        0x3C03
.equ NT_G_ROOTA     0x3C04
.equ NT_G_ROOTB     0x3C05
.equ NT_G_CA        0x3C06
.equ NT_G_CB        0x3C07
.equ NT_G_C4        0x3C08
.equ NT_G_C5        0x3C09
.equ NT_G_FLAGS     0x3C0A
.equ NT_G_I         0x3C0B
.equ NT_G_DIM       0x3C0C
.equ NT_G_VOC       0x3C0D
.equ NT_G_NP        0x3C0E
.equ NT_G_CFG       0x3C0F
.equ NT_G_TMP       0x3C10
.equ NT_G_POS       0x3C11
.equ NT_G_TOKEN     0x3C12
.equ NT_G_X         0x3C13

; NT_F fields (accept state), absolute scratch addresses
.equ NT_F_CTX       0x3C20
.equ NT_F_TOK       0x3C21
.equ NT_F_LOG       0x3C22
.equ NT_F_PREFIX    0x3C23
.equ NT_F_E1        0x3C24
.equ NT_F_E2        0x3C25
.equ NT_F_R         0x3C26
.equ NT_F_CHILD     0x3C27
.equ NT_F_LEN       0x3C28
.equ NT_F_FLAGS     0x3C29
.equ NT_F_DIM       0x3C2A
.equ NT_F_VOC       0x3C2B
.equ NT_F_T         0x3C2C
.equ NT_F_T2        0x3C2D
.equ NT_F_TMP       0x3C2E
.equ NT_F_GEN       0x3C2F

; NT_D fields (append/draft/probe state), absolute scratch addresses
.equ NT_D_CTX       0x3C30
.equ NT_D_CAND      0x3C31
.equ NT_D_TOKEN     0x3C32
.equ NT_D_POS       0x3C33
.equ NT_D_X         0x3C34
.equ NT_D_REC       0x3C35
.equ NT_D_GEN       0x3C36
.equ NT_D_PREV      0x3C38
.equ NT_D_PROBE     0x3C3C

; NT_MISC fields (masked attention + relocate), absolute scratch addresses
.equ NT_M_CTX       0x3F40
.equ NT_M_CAND      0x3F41
.equ NT_M_OUT       0x3F42
.equ NT_M_LEN       0x3F43
.equ NT_M_I         0x3F44
.equ NT_M_NP        0x3F45
.equ NT_M_CFG       0x3F46
.equ NT_M_DIM       0x3F47
.equ NT_M_NB        0x3F48
.equ NT_M_Q4T       0x3F49
.equ NT_M_REC       0x3F4A
.equ NT_M_MASK      0x3F4B
.equ NT_M_S         0x3F4C
.equ NT_M_V         0x3F4D
.equ NT_M_W         0x3F4E
.equ NT_M_RL        0x3F54
.equ NT_M_RCAND     0x3F55
.equ NT_M_RDST      0x3F56
.equ NT_M_RSRC      0x3F57
.equ NT_M_RDP       0x3F58
.equ NT_M_RGEN      0x3F59
.equ NT_M_RSTR      0x3F5A
.equ NT_M_RI        0x3F5B

; NT_E fields (generate state), absolute scratch addresses
.equ NT_E_CTX       0x3F80
.equ NT_E_TOK       0x3F81
.equ NT_E_LOG       0x3F82
.equ NT_E_CNT       0x3F83
.equ NT_E_OUT       0x3F84
.equ NT_E_NP        0x3F85
.equ NT_E_DIM       0x3F86
.equ NT_E_POS       0x3F87
.equ NT_E_BASE      0x3F88

; ---------------------------------------------------------------------------
; nt_event: r1=ctx r2=kind r3=a r4=b -> 0/-1.  Local hash chain.
nt_event:
  LD r5,r1,#NT_C_MAGIC
  LA r6,#NT_MAGIC
  CMP r5,r6
  JMP[NE] @ntev_bad
  LD r5,r1,#NT_C_HEAD
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
  ST r5,r1,#NT_C_HEAD
  LD r6,r1,#NT_C_TRACE
  CMP r6,r0
  JMP[EQ] @ntev_ok
  LD r7,r1,#NT_C_TN
  LD r8,r1,#NT_C_TCAP
  CMP r7,r8
  JMP[GE] @ntev_ok
  SHL r8,r7,2
  ADD r8,r6,r8
  ST r2,r8,0
  ST r3,r8,1
  ST r4,r8,2
  ST r5,r8,3
  ADD r7,r7,r13
  ST r7,r1,#NT_C_TN
ntev_ok:
  MOVI r1,0
  RET
ntev_bad:
  LA r1,0xFFFFFFFF
  RET

; ---------------------------------------------------------------------------
; nt_mask_one: r1=ctx r2=candidate -> 0/-1.
; Writes the candidate's ancestor list in increasing logical-token order:
; prefix 0..treepre-1, then parent record (if any), then the candidate itself.
nt_mask_one:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_MISC+40
  ST r2,r0,#NT_MISC+41
  CMP r1,r0
  JMP[EQ] @ntmo_bad
  LD r3,r1,#NT_C_TREEPRE
  ST r3,r0,#NT_MISC+42
  ; meta = ctx + CAND + cand*12
  MOVI r4,12
  MUL r4,r2,r4
  ADD r5,r1,r0
  LA r6,#NT_C_CAND
  ADD r5,r5,r6
  ADD r5,r5,r4
  ST r5,r0,#NT_MISC+43
  ; mask = ctx + MASKS + cand*16
  SHL r4,r2,4
  ADD r6,r1,r0
  LA r7,#NT_C_MASKS
  ADD r6,r6,r7
  ADD r6,r6,r4
  ST r6,r0,#NT_MISC+44
  ; length = prefix + 1 or +2
  MOVI r7,1
  LD r8,r5,1
  LA r9,0xFFFFFFFF
  CMP r8,r9
  JMP[EQ] @ntmo_len
  ADD r7,r7,r13
ntmo_len:
  ADD r7,r7,r3
  ST r7,r6,0
  ; prefix tokens
  MOVI r8,0
ntmo_p:
  LD r3,r0,#NT_MISC+42
  CMP r8,r3
  JMP[GE] @ntmo_pd
  ADD r9,r6,r8
  ADDI r9,r9,1
  ST r8,r9,0
  ADD r8,r8,r13
  JMP @ntmo_p
ntmo_pd:
  LD r6,r0,#NT_MISC+44
  LD r3,r0,#NT_MISC+42
  ADD r9,r6,r3
  ADDI r9,r9,1
  LD r5,r0,#NT_MISC+43
  ; parent
  LD r8,r5,1
  LA r10,0xFFFFFFFF
  CMP r8,r10
  JMP[EQ] @ntmo_own
  MOVI r10,12
  MUL r10,r8,r10
  LD r1,r0,#NT_MISC+40
  ADD r11,r1,r0
  LA r12,#NT_C_CAND
  ADD r11,r11,r12
  ADD r11,r11,r10
  LD r11,r11,3
  ST r11,r9,0
  ADD r9,r9,r13
  ADD r3,r3,r13
ntmo_own:
  LD r11,r5,3
  ST r11,r9,0
  MOVI r1,0
  JMP @ntmo_out
ntmo_bad:
  LA r1,0xFFFFFFFF
ntmo_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nt_append_cand: r1=ctx r2=cand r3=token r4=position -> 0/-1.
; Appends the candidate token to the shared paged context, records the
; logical record/generation in the candidate table, writes the branch/owner
; tag into the record flags word, and builds the candidate's causal mask.
; The caller must have set the candidate's parent field first.
nt_append_cand:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_D_CTX
  ST r2,r0,#NT_D_CAND
  ST r3,r0,#NT_D_TOKEN
  ST r4,r0,#NT_D_POS
  CMP r1,r0
  JMP[EQ] @ntac_bad
  LD r5,r1,#NT_C_MAGIC
  LA r6,#NT_MAGIC
  CMP r5,r6
  JMP[NE] @ntac_bad
  MOVI r5,6
  CMP r2,r5
  JMP[GE] @ntac_bad
  LD r5,r1,#NT_C_VOCAB
  CMP r3,r5
  JMP[GE] @ntac_bad
  ; x = token table + token*dim
  LD r1,r0,#NT_D_CTX
  LD r2,r1,#NT_C_TOK
  LD r3,r0,#NT_D_TOKEN
  LD r4,r1,#NT_C_DIM
  MUL r3,r3,r4
  ADD r2,r2,r3
  ST r2,r0,#NT_D_X
  ; npaged_append(np, x, pos, cfg)
  LD r1,r0,#NT_D_CTX
  LD r1,r1,#NT_C_NP
  LD r2,r0,#NT_D_X
  LD r3,r0,#NT_D_POS
  LD r4,r0,#NT_D_CTX
  LD r4,r4,#NT_C_CFG
  CALL @npaged_append
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntac_bad
  ST r1,r0,#NT_D_REC
  ; generation
  LD r1,r0,#NT_D_CTX
  LD r1,r1,#NT_C_NP
  LD r2,r0,#NT_D_REC
  CALL @npaged_token_gen
  CMP r1,r0
  JMP[EQ] @ntac_bad
  ST r1,r0,#NT_D_GEN
  ; meta
  LD r1,r0,#NT_D_CTX
  LD r2,r0,#NT_D_CAND
  MOVI r3,12
  MUL r3,r2,r3
  ADD r4,r1,r0
  LA r5,#NT_C_CAND
  ADD r4,r4,r5
  ADD r4,r4,r3
  LD r5,r0,#NT_D_TOKEN
  ST r5,r4,0
  LD r5,r0,#NT_D_POS
  ST r5,r4,7
  LD r5,r0,#NT_D_REC
  ST r5,r4,3
  LD r5,r0,#NT_D_GEN
  ST r5,r4,4
  LA r5,0x4E540000
  ADD r5,r5,r2
  ADD r5,r5,r13
  ST r5,r4,5
  ; record flags = tag
  LD r1,r0,#NT_D_CTX
  LD r1,r1,#NT_C_NP
  LD r2,r0,#NT_D_REC
  CALL @npaged_token_word
  CMP r1,r0
  JMP[EQ] @ntac_bad
  LD r5,r0,#NT_D_CAND
  LA r6,0x4E540000
  ADD r6,r6,r5
  ADD r6,r6,r13
  ST r6,r1,3
  ; mask
  LD r1,r0,#NT_D_CTX
  LD r2,r0,#NT_D_CAND
  CALL @nt_mask_one
  CMP r1,r0
  JMP[NE] @ntac_bad
  MOVI r1,0
  JMP @ntac_out
ntac_bad:
  LA r1,0xFFFFFFFF
ntac_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nt_draft: r1=ctx r2=prev token -> token/-1.  Draft-table row sample.
nt_draft:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_D_CTX
  ST r2,r0,#NT_D_PREV
  LD r3,r1,#NT_C_MAGIC
  LA r4,#NT_MAGIC
  CMP r3,r4
  JMP[NE] @ntdr_bad
  LD r3,r1,#NT_C_VOCAB
  CMP r2,r3
  JMP[GE] @ntdr_bad
  LD r4,r1,#NT_C_DRAFT
  CMP r4,r0
  JMP[EQ] @ntdr_bad
  MUL r2,r2,r3
  ADD r4,r4,r2
  ADD r1,r4,r0
  ADD r2,r3,r0
  LD r3,r0,#NT_D_CTX
  LD r3,r3,#NT_C_TEMP
  LD r4,r0,#NT_D_CTX
  LD r4,r4,#NT_C_DSEED
  CALL @ns_sample
  LA r3,0xFFFFFFFF
  CMP r1,r3
  JMP[EQ] @ntdr_bad
  LD r3,r0,#NT_D_CTX
  ST r2,r3,#NT_C_DSEED
  JMP @ntdr_out
ntdr_bad:
  LA r1,0xFFFFFFFF
ntdr_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nt_probe: r1=ctx r2=candidate r3=out logits -> sampled token/-1.
; Draft-time root probe: verifies one candidate's masked logits and draws the
; next verifier sample so an anchored child can be constructed.  This is not
; counted as a verifier pass; the batched verify recomputes the candidate.
nt_probe:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_D_PROBE
  ST r2,r0,#NT_D_PROBE+1
  ST r3,r0,#NT_D_PROBE+2
  CALL @nt_attn_mask
  CMP r1,r0
  JMP[NE] @ntpr_bad
  LD r1,r0,#NT_D_PROBE+2
  LD r2,r0,#NT_D_PROBE
  LD r2,r2,#NT_C_VOCAB
  LD r3,r0,#NT_D_PROBE
  LD r3,r3,#NT_C_TEMP
  LD r4,r0,#NT_D_PROBE
  LD r4,r4,#NT_C_SEED
  CALL @ns_sample
  LA r3,0xFFFFFFFF
  CMP r1,r3
  JMP[EQ] @ntpr_bad
  LD r3,r0,#NT_D_PROBE
  ST r2,r3,#NT_C_SEED
  JMP @ntpr_out
ntpr_bad:
  LA r1,0xFFFFFFFF
ntpr_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nt_attn_mask: r1=ctx r2=candidate r3=logits out -> 0/-1.
; Masked paged attention.  Same arithmetic and loop order as npaged_attention
; over the candidate's ordered ancestor list instead of 0..token.
nt_attn_mask:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_M_CTX
  ST r2,r0,#NT_M_CAND
  ST r3,r0,#NT_M_OUT
  CMP r1,r0
  JMP[EQ] @ntam_bad
  LD r5,r1,#NT_C_MAGIC
  LA r6,#NT_MAGIC
  CMP r5,r6
  JMP[NE] @ntam_bad
  LD r5,r1,#NT_C_NP
  ST r5,r0,#NT_M_NP
  LD r5,r1,#NT_C_CFG
  ST r5,r0,#NT_M_CFG
  LD r5,r1,#NT_C_DIM
  ST r5,r0,#NT_M_DIM
  SHR r5,r5,5
  ST r5,r0,#NT_M_NB
  ; mask address
  SHL r5,r2,4
  ADD r6,r1,r0
  LA r7,#NT_C_MASKS
  ADD r6,r6,r7
  ADD r6,r6,r5
  ST r6,r0,#NT_M_MASK
  LD r7,r6,0
  CMP r7,r0
  JMP[LE] @ntam_bad
  MOVI r8,16
  CMP r7,r8
  JMP[GT] @ntam_bad
  ST r7,r0,#NT_M_LEN
  ; candidate record token
  MOVI r8,12
  MUL r8,r2,r8
  ADD r8,r8,r1
  LA r9,#NT_C_CAND
  ADD r8,r8,r9
  LD r8,r8,3
  LD r1,r0,#NT_M_NP
  ADD r2,r8,r0
  CALL @np_record
  CMP r1,r0
  JMP[EQ] @ntam_bad
  ST r1,r0,#NT_M_REC
  ; q4_t = rec + HDR + 2*dim
  LD r5,r0,#NT_M_DIM
  SHL r6,r5,1
  ADD r6,r1,r6
  MOVI r7,#NP_HDR
  ADD r6,r6,r7
  ST r6,r0,#NT_M_Q4T
  ; score loop
  ST r0,r0,#NT_M_I
ntam_sc:
  LD r1,r0,#NT_M_I
  LD r2,r0,#NT_M_LEN
  CMP r1,r2
  JMP[GE] @ntam_smd
  LD r3,r0,#NT_M_MASK
  ADD r3,r3,r1
  ADDI r3,r3,1
  LD r3,r3,0
  ST r3,r0,#NT_M_S
  LD r1,r0,#NT_M_NP
  ADD r2,r3,r0
  CALL @np_record
  CMP r1,r0
  JMP[EQ] @ntam_bad
  ; q8_s = rec + HDR + 2*dim + nb*5
  LD r2,r0,#NT_M_DIM
  SHL r2,r2,1
  ADD r1,r1,r2
  MOVI r2,#NP_HDR
  ADD r1,r1,r2
  LD r2,r0,#NT_M_NB
  MOVI r3,5
  MUL r2,r2,r3
  ADD r1,r1,r2
  ADD r2,r1,r0
  LD r1,r0,#NT_M_Q4T
  LD r3,r0,#NT_M_NB
  CALL @nattn_qk_fused
  LD r2,r0,#NT_M_CFG
  LD r2,r2,10
  FMUL r1,r1,r2
  LA r2,#NT_SC
  LD r3,r0,#NT_M_I
  ADD r2,r2,r3
  ST r1,r2,0
  LD r1,r0,#NT_M_I
  ADD r1,r1,r13
  ST r1,r0,#NT_M_I
  JMP @ntam_sc
ntam_smd:
  LA r1,#NT_SC
  LD r2,r0,#NT_M_LEN
  LA r3,#NT_SC
  CALL @np_softmax
  CMP r1,r0
  JMP[NE] @ntam_bad
  ; zero context vector
  MOVI r3,0
ntam_z:
  LD r2,r0,#NT_M_DIM
  CMP r3,r2
  JMP[GE] @ntam_zd
  LA r1,#NT_CTXW
  ADD r1,r1,r3
  ST r0,r1,0
  ADD r3,r3,r13
  JMP @ntam_z
ntam_zd:
  ST r0,r0,#NT_M_I
ntam_as:
  LD r1,r0,#NT_M_I
  LD r2,r0,#NT_M_LEN
  CMP r1,r2
  JMP[GE] @ntam_asd
  LD r3,r0,#NT_M_MASK
  ADD r3,r3,r1
  ADDI r3,r3,1
  LD r3,r3,0
  ST r3,r0,#NT_M_S
  LD r1,r0,#NT_M_NP
  ADD r2,r3,r0
  CALL @np_record
  CMP r1,r0
  JMP[EQ] @ntam_bad
  ; v = rec + HDR + dim
  LD r2,r0,#NT_M_DIM
  ADD r1,r1,r2
  MOVI r2,#NP_HDR
  ADD r1,r1,r2
  ST r1,r0,#NT_M_V
  LA r2,#NT_SC
  LD r3,r0,#NT_M_I
  ADD r2,r2,r3
  LD r2,r2,0
  ST r2,r0,#NT_M_W
  MOVI r3,0
ntam_ad:
  LD r1,r0,#NT_M_DIM
  CMP r3,r1
  JMP[GE] @ntam_add
  LD r1,r0,#NT_M_V
  ADD r1,r1,r3
  LD r1,r1,0
  LD r2,r0,#NT_M_W
  FMUL r1,r1,r2
  LA r2,#NT_CTXW
  ADD r2,r2,r3
  LD r4,r2,0
  FADD r4,r4,r1
  ST r4,r2,0
  ADD r3,r3,r13
  JMP @ntam_ad
ntam_add:
  LD r1,r0,#NT_M_I
  ADD r1,r1,r13
  ST r1,r0,#NT_M_I
  JMP @ntam_as
ntam_asd:
  ; h = x_t + ctx
  MOVI r3,0
ntam_h:
  LD r2,r0,#NT_M_DIM
  CMP r3,r2
  JMP[GE] @ntam_hd
  LD r1,r0,#NT_M_REC
  MOVI r4,#NP_HDR
  ADD r1,r1,r4
  ADD r1,r1,r3
  LD r1,r1,0
  LA r2,#NT_CTXW
  ADD r2,r2,r3
  LD r2,r2,0
  FADD r1,r1,r2
  LA r2,#NT_H
  ADD r2,r2,r3
  ST r1,r2,0
  ADD r3,r3,r13
  JMP @ntam_h
ntam_hd:
  LA r1,#NT_H
  LD r2,r0,#NT_M_CFG
  LD r2,r2,11
  LD r3,r0,#NT_M_DIM
  LD r4,r0,#NT_M_CFG
  LD r4,r4,12
  LA r5,#NT_RMS
  CALL @nat_rmsnorm
  CMP r1,r0
  JMP[NE] @ntam_bad
  LD r1,r0,#NT_M_CFG
  LD r1,r1,8
  LD r2,r0,#NT_M_DIM
  ADD r3,r2,r0
  LA r4,#NT_RMS
  LD r5,r0,#NT_M_OUT
  CALL @nattn_matvec_q4
  CMP r1,r0
  JMP[NE] @ntam_bad
  MOVI r1,0
  JMP @ntam_out
ntam_bad:
  LA r1,0xFFFFFFFF
ntam_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nt_relocate: r1=ctx r2=candidate r3=dst logical token -> 0/-1.
; Copies the candidate record payload (x/v/q4/q8) into an earlier scratch
; slot and rewrites the destination header.  npaged_trim subsequently bumps
; the destination block generation and rewrites retained headers.  Used when
; the winning branch is not the first DFS branch.
nt_relocate:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_M_RL
  ST r2,r0,#NT_M_RCAND
  ST r3,r0,#NT_M_RDST
  CMP r1,r0
  JMP[EQ] @ntrl_bad
  LD r4,r1,#NT_C_MAGIC
  LA r5,#NT_MAGIC
  CMP r4,r5
  JMP[NE] @ntrl_bad
  LD r4,r1,#NT_C_NP
  ST r4,r0,#NT_MISC+30
  ; src record token
  MOVI r5,12
  MUL r5,r2,r5
  ADD r6,r1,r0
  LA r7,#NT_C_CAND
  ADD r6,r6,r7
  ADD r6,r6,r5
  ST r6,r0,#NT_MISC+31
  LD r2,r6,3
  LD r1,r0,#NT_MISC+30
  CALL @npaged_token_word
  CMP r1,r0
  JMP[EQ] @ntrl_bad
  ST r1,r0,#NT_M_RSRC
  ; dst record
  LD r1,r0,#NT_MISC+30
  LD r2,r0,#NT_M_RDST
  CALL @npaged_token_word
  CMP r1,r0
  JMP[EQ] @ntrl_bad
  ST r1,r0,#NT_M_RDP
  ; dst generation before overwrite
  LD r1,r0,#NT_MISC+30
  LD r2,r0,#NT_M_RDST
  CALL @npaged_token_gen
  CMP r1,r0
  JMP[EQ] @ntrl_bad
  ST r1,r0,#NT_M_RGEN
  ; copy payload words (stride-4)
  LD r1,r0,#NT_MISC+30
  LD r1,r1,#NP_C_STRIDE
  SUB r1,r1,r13
  SUB r1,r1,r13
  SUB r1,r1,r13
  SUB r1,r1,r13
  ST r1,r0,#NT_M_RSTR
  ST r0,r0,#NT_M_RI
ntrl_cp:
  LD r1,r0,#NT_M_RI
  LD r2,r0,#NT_M_RSTR
  CMP r1,r2
  JMP[GE] @ntrl_cpd
  MOVI r3,#NP_HDR
  ADD r3,r3,r1
  LD r4,r0,#NT_M_RSRC
  ADD r4,r4,r3
  LD r4,r4,0
  LD r5,r0,#NT_M_RDP
  ADD r5,r5,r3
  ST r4,r5,0
  LD r1,r0,#NT_M_RI
  ADD r1,r1,r13
  ST r1,r0,#NT_M_RI
  JMP @ntrl_cp
ntrl_cpd:
  ; header
  LD r1,r0,#NT_M_RDP
  LA r2,#NP_REC_MAGIC
  ST r2,r1,0
  LD r2,r0,#NT_M_RGEN
  ST r2,r1,1
  LD r2,r0,#NT_M_RDST
  ST r2,r1,2
  LD r3,r0,#NT_MISC+31
  LD r3,r3,5
  ST r3,r1,3
  MOVI r1,0
  JMP @ntrl_out
ntrl_bad:
  LA r1,0xFFFFFFFF
ntrl_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nt_build: r1=ctx -> 0/-1.  Appends the six-candidate draft tree.
nt_build:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_G_CTX
  CMP r1,r0
  JMP[EQ] @ntb_bad
  LD r5,r1,#NT_C_MAGIC
  LA r6,#NT_MAGIC
  CMP r5,r6
  JMP[NE] @ntb_bad
  ; prefix = np.used must equal prompt + generated
  LD r2,r1,#NT_C_NP
  ST r2,r0,#NT_G_NP
  LD r2,r2,#NP_C_USED
  ST r2,r0,#NT_G_PREFIX
  ST r2,r1,#NT_C_TREEPRE
  CMP r2,r0
  JMP[LE] @ntb_bad
  LD r3,r1,#NT_C_PROMPT
  LD r4,r1,#NT_C_GEN
  ADD r3,r3,r4
  CMP r2,r3
  JMP[NE] @ntb_bad
  ; prefix + depth <= maskmax
  LD r3,r1,#NT_C_DEPTH
  ADD r4,r2,r3
  MOVI r5,16
  CMP r4,r5
  JMP[GT] @ntb_bad
  ; constants
  LD r3,r1,#NT_C_DIM
  ST r3,r0,#NT_G_DIM
  LD r3,r1,#NT_C_VOCAB
  ST r3,r0,#NT_G_VOC
  LD r3,r1,#NT_C_CFG
  ST r3,r0,#NT_G_CFG
  LD r3,r1,#NT_C_FLAGS
  ST r3,r0,#NT_G_FLAGS
  ; e1 = sample(cur, vocab, temp, seed)
  LD r1,r0,#NT_G_CTX
  ADD r1,r1,r0
  LA r2,#NT_C_CUR
  ADD r1,r1,r2
  LD r2,r0,#NT_G_VOC
  LD r3,r0,#NT_G_CTX
  LD r3,r3,#NT_C_TEMP
  LD r4,r0,#NT_G_CTX
  LD r4,r4,#NT_C_SEED
  CALL @ns_sample
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @ntb_bad
  ST r1,r0,#NT_G_E1
  LD r3,r0,#NT_G_CTX
  ST r2,r3,#NT_C_SEED
  ; parent links: c0 root, c1/c2 -> c0, c3 root, c4/c5 -> c3
  LD r1,r0,#NT_G_CTX
  CALL @nt_parents
  CMP r1,r0
  JMP[NE] @ntb_bad
  ; choose roots
  LD r5,r0,#NT_G_FLAGS
  MOVI r6,8
  BOOL.8 r6,r5,r6
  CMP r6,r0
  JMP[NE] @ntb_zero
  MOVI r6,2
  BOOL.8 r6,r5,r6
  CMP r6,r0
  JMP[NE] @ntb_alt
  MOVI r6,1
  BOOL.8 r6,r5,r6
  CMP r6,r0
  JMP[NE] @ntb_prim
  ; natural draft roots
  LD r1,r0,#NT_G_CTX
  LD r2,r1,#NT_C_LAST
  CALL @nt_draft
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntb_bad
  ST r1,r0,#NT_G_ROOTA
  LD r1,r0,#NT_G_CTX
  LD r2,r1,#NT_C_LAST
  CALL @nt_draft
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntb_bad
  ST r1,r0,#NT_G_ROOTB
  CALL @nt_distinct
  JMP @ntb_roots
ntb_prim:
  LD r1,r0,#NT_G_E1
  ST r1,r0,#NT_G_ROOTA
  LD r1,r0,#NT_G_CTX
  LD r2,r1,#NT_C_LAST
  CALL @nt_draft
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntb_bad
  ST r1,r0,#NT_G_ROOTB
  CALL @nt_distinct
  JMP @ntb_roots
ntb_alt:
  LD r1,r0,#NT_G_E1
  ADD r1,r1,r13
  LD r2,r0,#NT_G_VOC
  CMP r1,r2
  JMP[LT] @ntb_altst
  MOVI r1,0
ntb_altst:
  ST r1,r0,#NT_G_ROOTA
  LD r1,r0,#NT_G_E1
  ST r1,r0,#NT_G_ROOTB
  LD r1,r0,#NT_G_CTX
  LD r2,r1,#NT_C_FORCED
  ADD r2,r2,r13
  ST r2,r1,#NT_C_FORCED
  JMP @ntb_roots
ntb_zero:
  LD r1,r0,#NT_G_E1
  ADD r1,r1,r13
  LD r2,r0,#NT_G_VOC
  CMP r1,r2
  JMP[LT] @ntb_z0
  MOVI r1,0
ntb_z0:
  ST r1,r0,#NT_G_ROOTA
  LD r1,r0,#NT_G_E1
  ADD r1,r1,r13
  ADD r1,r1,r13
  LD r2,r0,#NT_G_VOC
  CMP r1,r2
  JMP[LT] @ntb_z1
  MOVI r1,0
ntb_z1:
  ST r1,r0,#NT_G_ROOTB
  LD r1,r0,#NT_G_CTX
  LD r2,r1,#NT_C_FORCED
  ADD r2,r2,r13
  ADD r2,r2,r13
  ST r2,r1,#NT_C_FORCED
ntb_roots:
  ; append c0 root A at position prefix
  LD r1,r0,#NT_G_CTX
  MOVI r2,0
  LD r3,r0,#NT_G_ROOTA
  LD r4,r0,#NT_G_PREFIX
  CALL @nt_append_cand
  CMP r1,r0
  JMP[NE] @ntb_bad
  ; primary anchor probe for e2
  LD r5,r0,#NT_G_FLAGS
  MOVI r6,1
  BOOL.8 r6,r5,r6
  CMP r6,r0
  JMP[EQ] @ntb_no_probe0
  LD r1,r0,#NT_G_CTX
  MOVI r2,0
  LD r3,r0,#NT_G_CTX
  ADD r3,r3,r0
  LA r4,#NT_C_TMP
  ADD r3,r3,r4
  CALL @nt_probe
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntb_bad
  ST r1,r0,#NT_G_E2
ntb_no_probe0:
  ; child A0
  LD r5,r0,#NT_G_FLAGS
  MOVI r6,1
  BOOL.8 r6,r5,r6
  CMP r6,r0
  JMP[EQ] @ntb_ca_draft
  ; anchored: e2, or e2+1 in force-partial mode
  LD r1,r0,#NT_G_E2
  MOVI r6,4
  BOOL.8 r6,r5,r6
  CMP r6,r0
  JMP[EQ] @ntb_ca_set
  ADD r1,r1,r13
  LD r2,r0,#NT_G_VOC
  CMP r1,r2
  JMP[LT] @ntb_ca_force
  MOVI r1,0
ntb_ca_force:
  LD r3,r0,#NT_G_CTX
  LD r4,r3,#NT_C_FORCED
  ADD r4,r4,r13
  ST r4,r3,#NT_C_FORCED
  JMP @ntb_ca_set
ntb_ca_draft:
  LD r1,r0,#NT_G_CTX
  LD r2,r0,#NT_G_ROOTA
  CALL @nt_draft
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntb_bad
ntb_ca_set:
  ST r1,r0,#NT_G_CA
  ; child A1 = draft from root A, distinct from A0
  LD r1,r0,#NT_G_CTX
  LD r2,r0,#NT_G_ROOTA
  CALL @nt_draft
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntb_bad
  ST r1,r0,#NT_G_CB
  CALL @nt_child_distinct
  ; append c1 child A0, c2 child A1 at position prefix+1
  LD r1,r0,#NT_G_CTX
  MOVI r2,1
  LD r3,r0,#NT_G_CA
  LD r4,r0,#NT_G_PREFIX
  ADD r4,r4,r13
  CALL @nt_append_cand
  CMP r1,r0
  JMP[NE] @ntb_bad
  LD r1,r0,#NT_G_CTX
  MOVI r2,2
  LD r3,r0,#NT_G_CB
  LD r4,r0,#NT_G_PREFIX
  ADD r4,r4,r13
  CALL @nt_append_cand
  CMP r1,r0
  JMP[NE] @ntb_bad
  ; append c3 root B at position prefix
  LD r1,r0,#NT_G_CTX
  MOVI r2,3
  LD r3,r0,#NT_G_ROOTB
  LD r4,r0,#NT_G_PREFIX
  CALL @nt_append_cand
  CMP r1,r0
  JMP[NE] @ntb_bad
  ; alternate anchor probe for e2
  LD r5,r0,#NT_G_FLAGS
  MOVI r6,2
  BOOL.8 r6,r5,r6
  CMP r6,r0
  JMP[EQ] @ntb_no_probe3
  LD r1,r0,#NT_G_CTX
  MOVI r2,3
  LD r3,r0,#NT_G_CTX
  ADD r3,r3,r0
  LA r4,#NT_C_TMP
  ADD r3,r3,r4
  CALL @nt_probe
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntb_bad
  ST r1,r0,#NT_G_E2
ntb_no_probe3:
  ; child B0
  LD r5,r0,#NT_G_FLAGS
  MOVI r6,2
  BOOL.8 r6,r5,r6
  CMP r6,r0
  JMP[EQ] @ntb_c4_draft
  LD r1,r0,#NT_G_E2
  JMP @ntb_c4_set
ntb_c4_draft:
  LD r1,r0,#NT_G_CTX
  LD r2,r0,#NT_G_ROOTB
  CALL @nt_draft
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntb_bad
ntb_c4_set:
  ST r1,r0,#NT_G_C4
  ; child B1 distinct
  LD r1,r0,#NT_G_CTX
  LD r2,r0,#NT_G_ROOTB
  CALL @nt_draft
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntb_bad
  ST r1,r0,#NT_G_C5
  CALL @nt_child_distinct
  ; append c4, c5
  LD r1,r0,#NT_G_CTX
  MOVI r2,4
  LD r3,r0,#NT_G_C4
  LD r4,r0,#NT_G_PREFIX
  ADD r4,r4,r13
  CALL @nt_append_cand
  CMP r1,r0
  JMP[NE] @ntb_bad
  LD r1,r0,#NT_G_CTX
  MOVI r2,5
  LD r3,r0,#NT_G_C5
  LD r4,r0,#NT_G_PREFIX
  ADD r4,r4,r13
  CALL @nt_append_cand
  CMP r1,r0
  JMP[NE] @ntb_bad
  ; count drafts and emit draft events
  LD r1,r0,#NT_G_CTX
  LD r2,r1,#NT_C_DRAFTS
  MOVI r3,6
  ADD r2,r2,r3
  ST r2,r1,#NT_C_DRAFTS
  MOVI r4,0
  ST r4,r0,#NT_G_I
ntb_evl:
  LD r4,r0,#NT_G_I
  MOVI r5,6
  CMP r4,r5
  JMP[GE] @ntb_evd
  ; meta token
  MOVI r5,12
  MUL r5,r4,r5
  LD r1,r0,#NT_G_CTX
  ADD r6,r1,r0
  LA r7,#NT_C_CAND
  ADD r6,r6,r7
  ADD r6,r6,r5
  LD r5,r6,0
  MOVI r2,#NT_E_DRAFT
  ADD r3,r4,r0
  ADD r4,r5,r0
  CALL @nt_event
  LD r4,r0,#NT_G_I
  ADD r4,r4,r13
  ST r4,r0,#NT_G_I
  JMP @ntb_evl
ntb_evd:
  MOVI r1,0
  JMP @ntb_out
ntb_bad:
  LA r1,0xFFFFFFFF
ntb_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nt_parents: r1=ctx -> 0.  Fixed topology parent links.
nt_parents:
  ADD r2,r1,r0
  LA r3,#NT_C_CAND
  ADD r2,r2,r3
  LA r4,0xFFFFFFFF
  ST r4,r2,1
  ; c1 -> c0
  MOVI r3,12
  ADD r5,r2,r3
  ST r0,r5,1
  ADD r5,r5,r3
  ST r0,r5,1
  ; c3 root
  ADD r5,r5,r3
  ST r4,r5,1
  ; c4,c5 -> c3
  ADD r5,r5,r3
  MOVI r3,3
  ST r3,r5,1
  MOVI r3,12
  ADD r5,r5,r3
  MOVI r3,3
  ST r3,r5,1
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; nt_distinct: root A in NT_G_ROOTA, root B in NT_G_ROOTB -> 0.
; If B == A, advance B by one modulo vocab and count a forced correction.
nt_distinct:
  LD r1,r0,#NT_G_ROOTA
  LD r2,r0,#NT_G_ROOTB
  CMP r1,r2
  JMP[NE] @ntds_ok
  ADD r2,r2,r13
  LD r3,r0,#NT_G_VOC
  CMP r2,r3
  JMP[LT] @ntds_st
  MOVI r2,0
ntds_st:
  ST r2,r0,#NT_G_ROOTB
  LD r3,r0,#NT_G_CTX
  LD r4,r3,#NT_C_FORCED
  ADD r4,r4,r13
  ST r4,r3,#NT_C_FORCED
ntds_ok:
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; nt_child_distinct: CA in NT_G_CA, CB in NT_G_CB -> 0.  CB != CA.
nt_child_distinct:
  LD r1,r0,#NT_G_CA
  LD r2,r0,#NT_G_CB
  CMP r1,r2
  JMP[NE] @ntcd_ok
  ADD r2,r2,r13
  LD r3,r0,#NT_G_VOC
  CMP r2,r3
  JMP[LT] @ntcd_st
  MOVI r2,0
ntcd_st:
  ST r2,r0,#NT_G_CB
  LD r3,r0,#NT_G_CTX
  LD r4,r3,#NT_C_FORCED
  ADD r4,r4,r13
  ST r4,r3,#NT_C_FORCED
ntcd_ok:
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; nt_verify: r1=ctx -> 0/-1.  ONE batched pass over all six candidates.
nt_verify:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_MISC+50
  CMP r1,r0
  JMP[EQ] @ntv_bad
  LD r2,r1,#NT_C_MAGIC
  LA r3,#NT_MAGIC
  CMP r2,r3
  JMP[NE] @ntv_bad
  LD r2,r1,#NT_C_PASS
  ADD r2,r2,r13
  ST r2,r1,#NT_C_PASS
  ST r0,r0,#NT_MISC+51
ntv_l:
  LD r1,r0,#NT_MISC+51
  MOVI r2,6
  CMP r1,r2
  JMP[GE] @ntv_d
  SHL r2,r1,6
  LD r3,r0,#NT_MISC+50
  ADD r3,r3,r0
  LA r4,#NT_C_CLOG
  ADD r3,r3,r4
  ADD r3,r3,r2
  LD r1,r0,#NT_MISC+50
  LD r2,r0,#NT_MISC+51
  CALL @nt_attn_mask
  CMP r1,r0
  JMP[NE] @ntv_bad
  LD r1,r0,#NT_MISC+51
  ADD r1,r1,r13
  ST r1,r0,#NT_MISC+51
  JMP @ntv_l
ntv_d:
  LD r1,r0,#NT_MISC+50
  MOVI r2,#NT_E_VERIFY
  MOVI r3,6
  LD r4,r1,#NT_C_PASS
  CALL @nt_event
  MOVI r1,0
  JMP @ntv_out
ntv_bad:
  LA r1,0xFFFFFFFF
ntv_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nt_accept: r1=ctx r2=tokens_out r3=logits_out -> 2/-1.
; Chooses the longest matching root-to-leaf path, promotes it to the prefix,
; trims every other candidate, appends free verifier tokens when the tree
; accepts fewer than two, and emits exactly two plain-decode tokens.
nt_accept:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_F_CTX
  ST r2,r0,#NT_F_TOK
  ST r3,r0,#NT_F_LOG
  CMP r1,r0
  JMP[EQ] @nta_bad
  LD r5,r1,#NT_C_MAGIC
  LA r6,#NT_MAGIC
  CMP r5,r6
  JMP[NE] @nta_bad
  CMP r2,r0
  JMP[EQ] @nta_bad
  CMP r3,r0
  JMP[EQ] @nta_bad
  LD r5,r1,#NT_C_NP
  LD r5,r5,#NP_C_USED
  SUB r5,r5,r0
  ADDI r5,r5,-6
  CMP r5,r0
  JMP[LT] @nta_bad
  ST r5,r0,#NT_F_PREFIX
  LD r5,r1,#NT_C_DIM
  ST r5,r0,#NT_F_DIM
  LD r5,r1,#NT_C_VOCAB
  ST r5,r0,#NT_F_VOC
  LD r5,r1,#NT_C_FLAGS
  ST r5,r0,#NT_F_FLAGS
  LD r5,r0,#NT_G_E1
  ST r5,r0,#NT_F_E1
  ; pre-sample logits for token 1 = cur
  LD r1,r0,#NT_F_CTX
  ADD r1,r1,r0
  LA r2,#NT_C_CUR
  ADD r1,r1,r2
  LD r2,r0,#NT_F_LOG
  LD r3,r0,#NT_F_DIM
  CALL @ns_copy
  ; find a root candidate matching e1
  LA r5,0xFFFFFFFF
  ST r5,r0,#NT_F_R
  ST r0,r0,#NT_F_T
nta_rl:
  LD r1,r0,#NT_F_T
  MOVI r2,6
  CMP r1,r2
  JMP[GE] @nta_rd
  MOVI r2,12
  MUL r2,r1,r2
  LD r3,r0,#NT_F_CTX
  ADD r3,r3,r0
  LA r4,#NT_C_CAND
  ADD r3,r3,r4
  ADD r3,r3,r2
  LD r4,r3,1
  LA r5,0xFFFFFFFF
  CMP r4,r5
  JMP[NE] @nta_rn
  LD r4,r3,0
  LD r5,r0,#NT_F_E1
  CMP r4,r5
  JMP[NE] @nta_rn
  LD r1,r0,#NT_F_T
  ST r1,r0,#NT_F_R
nta_rn:
  LD r1,r0,#NT_F_T
  ADD r1,r1,r13
  ST r1,r0,#NT_F_T
  JMP @nta_rl
nta_rd:
  LD r1,r0,#NT_F_R
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nta_none
  ; e2: reuse the probe sample for the anchored root, else sample its logits
  LD r1,r0,#NT_F_R
  LD r2,r0,#NT_F_FLAGS
  MOVI r3,1
  BOOL.8 r3,r2,r3
  CMP r3,r0
  JMP[EQ] @nta_e2tryalt
  CMP r1,r0
  JMP[EQ] @nta_e2probe
nta_e2tryalt:
  LD r2,r0,#NT_F_FLAGS
  MOVI r3,2
  BOOL.8 r3,r2,r3
  CMP r3,r0
  JMP[EQ] @nta_e2sample
  LD r2,r0,#NT_F_R
  MOVI r3,3
  CMP r2,r3
  JMP[EQ] @nta_e2probe
  JMP @nta_e2sample
nta_e2probe:
  LD r1,r0,#NT_G_E2
  ST r1,r0,#NT_F_E2
  JMP @nta_e2done
nta_e2sample:
  ; logits at root r
  LD r1,r0,#NT_F_R
  SHL r1,r1,6
  LD r2,r0,#NT_F_CTX
  ADD r2,r2,r0
  LA r3,#NT_C_CLOG
  ADD r2,r2,r3
  ADD r1,r2,r1
  LD r2,r0,#NT_F_VOC
  LD r3,r0,#NT_F_CTX
  LD r3,r3,#NT_C_TEMP
  LD r4,r0,#NT_F_CTX
  LD r4,r4,#NT_C_SEED
  CALL @ns_sample
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nta_bad
  ST r1,r0,#NT_F_E2
  LD r3,r0,#NT_F_CTX
  ST r2,r3,#NT_C_SEED
nta_e2done:
  ; find a child of r matching e2
  LA r5,0xFFFFFFFF
  ST r5,r0,#NT_F_CHILD
  ST r0,r0,#NT_F_T
nta_cl:
  LD r1,r0,#NT_F_T
  MOVI r2,6
  CMP r1,r2
  JMP[GE] @nta_cd
  MOVI r2,12
  MUL r2,r1,r2
  LD r3,r0,#NT_F_CTX
  ADD r3,r3,r0
  LA r4,#NT_C_CAND
  ADD r3,r3,r4
  ADD r3,r3,r2
  LD r4,r3,1
  LD r5,r0,#NT_F_R
  CMP r4,r5
  JMP[NE] @nta_cn
  LD r4,r3,0
  LD r5,r0,#NT_F_E2
  CMP r4,r5
  JMP[NE] @nta_cn
  LD r1,r0,#NT_F_T
  ST r1,r0,#NT_F_CHILD
nta_cn:
  LD r1,r0,#NT_F_T
  ADD r1,r1,r13
  ST r1,r0,#NT_F_T
  JMP @nta_cl
nta_cd:
  ; accept length
  MOVI r1,1
  LD r2,r0,#NT_F_CHILD
  LA r3,0xFFFFFFFF
  CMP r2,r3
  JMP[EQ] @nta_lenset
  MOVI r1,2
nta_lenset:
  ST r1,r0,#NT_F_LEN
  ; tokens_out = e1, e2
  LD r1,r0,#NT_F_TOK
  LD r2,r0,#NT_F_E1
  ST r2,r1,0
  LD r2,r0,#NT_F_E2
  ST r2,r1,1
  ; logits_out[1] = logits at the accepted root
  LD r1,r0,#NT_F_R
  SHL r1,r1,6
  LD r2,r0,#NT_F_CTX
  ADD r2,r2,r0
  LA r3,#NT_C_CLOG
  ADD r2,r2,r3
  ADD r1,r2,r1
  LD r2,r0,#NT_F_LOG
  LD r3,r0,#NT_F_DIM
  ADD r2,r2,r3
  LD r3,r0,#NT_F_DIM
  CALL @ns_copy
  ; promote accepted path records to prefix slots
  LD r1,r0,#NT_F_R
  CMP r1,r0
  JMP[NE] @nta_move_r
  LD r2,r0,#NT_F_LEN
  MOVI r3,2
  CMP r2,r3
  JMP[NE] @nta_trim
  LD r2,r0,#NT_F_CHILD
  MOVI r3,1
  CMP r2,r3
  JMP[EQ] @nta_trim
  ; r=0, child=2: move only the child
  LD r1,r0,#NT_F_CTX
  LD r2,r0,#NT_F_CHILD
  LD r3,r0,#NT_F_PREFIX
  ADD r3,r3,r13
  CALL @nt_relocate
  CMP r1,r0
  JMP[NE] @nta_bad
  JMP @nta_trim
nta_move_r:
  LD r1,r0,#NT_F_CTX
  LD r2,r0,#NT_F_R
  LD r3,r0,#NT_F_PREFIX
  CALL @nt_relocate
  CMP r1,r0
  JMP[NE] @nta_bad
  LD r2,r0,#NT_F_LEN
  MOVI r3,2
  CMP r2,r3
  JMP[NE] @nta_trim
  LD r1,r0,#NT_F_CTX
  LD r2,r0,#NT_F_CHILD
  LD r3,r0,#NT_F_PREFIX
  ADD r3,r3,r13
  CALL @nt_relocate
  CMP r1,r0
  JMP[NE] @nta_bad
nta_trim:
  ; trim to prefix + accepted length
  LD r1,r0,#NT_F_CTX
  LD r1,r1,#NT_C_NP
  LD r2,r0,#NT_F_PREFIX
  LD r3,r0,#NT_F_LEN
  ADD r2,r2,r3
  CALL @npaged_trim
  CMP r1,r0
  JMP[NE] @nta_bad
  ; counters + events
  LD r1,r0,#NT_F_CTX
  LD r2,r0,#NT_F_LEN
  LD r3,r1,#NT_C_ACC
  ADD r3,r3,r2
  ST r3,r1,#NT_C_ACC
  MOVI r3,6
  SUB r3,r3,r2
  LD r4,r1,#NT_C_REJ
  ADD r4,r4,r3
  ST r4,r1,#NT_C_REJ
  LD r4,r1,#NT_C_TRIM
  ADD r4,r4,r3
  ST r4,r1,#NT_C_TRIM
  ST r2,r1,#NT_C_LASTLEN
  ; trim event
  LD r1,r0,#NT_F_CTX
  MOVI r2,#NT_E_TRIM
  MOVI r3,6
  LD r4,r0,#NT_F_LEN
  SUB r3,r3,r4
  LD r4,r0,#NT_F_PREFIX
  ADD r4,r4,r4
  ; recompute used = prefix + len (avoid double-add mistake)
  LD r4,r0,#NT_F_PREFIX
  LD r5,r0,#NT_F_LEN
  ADD r4,r4,r5
  CALL @nt_event
  ; accept events and reject events
  ST r0,r0,#NT_F_T
nta_evl:
  LD r1,r0,#NT_F_T
  MOVI r2,6
  CMP r1,r2
  JMP[GE] @nta_evd
  ; candidate token and meta pointer
  MOVI r2,12
  MUL r2,r1,r2
  LD r3,r0,#NT_F_CTX
  ADD r3,r3,r0
  LA r4,#NT_C_CAND
  ADD r3,r3,r4
  ADD r3,r3,r2
  LD r4,r3,0
  ; accepted if i==r or i==child
  LD r5,r0,#NT_F_R
  CMP r1,r5
  JMP[EQ] @nta_evacc
  LD r5,r0,#NT_F_CHILD
  CMP r1,r5
  JMP[EQ] @nta_evacc
  LD r1,r0,#NT_F_CTX
  MOVI r2,#NT_E_REJECT
  LD r3,r0,#NT_F_T
  ; token already in r4
  CALL @nt_event
  JMP @nta_evn
nta_evacc:
  LD r1,r0,#NT_F_CTX
  MOVI r2,#NT_E_ACCEPT
  LD r3,r0,#NT_F_T
  CALL @nt_event
nta_evn:
  LD r1,r0,#NT_F_T
  ADD r1,r1,r13
  ST r1,r0,#NT_F_T
  JMP @nta_evl
nta_evd:
  ; promotions and accepted generation
  LD r1,r0,#NT_F_CTX
  LD r2,r1,#NT_C_PROM
  ADD r2,r2,r13
  ST r2,r1,#NT_C_PROM
  LD r1,r0,#NT_F_CTX
  LD r1,r1,#NT_C_NP
  LD r2,r0,#NT_F_PREFIX
  LD r3,r0,#NT_F_LEN
  ADD r2,r2,r3
  ADDI r2,r2,-1
  CALL @npaged_token_gen
  ST r1,r0,#NT_F_GEN
  LD r2,r0,#NT_F_CTX
  ST r1,r2,#NT_C_ACCGEN
  ; promote event
  LD r1,r0,#NT_F_CTX
  MOVI r2,#NT_E_PROMOTE
  LD r3,r0,#NT_F_LEN
  LD r4,r0,#NT_F_GEN
  CALL @nt_event
  ; cur / free-token fallback
  LD r1,r0,#NT_F_LEN
  MOVI r2,2
  CMP r1,r2
  JMP[EQ] @nta_len2
  ; len == 1: append e2 free at prefix+1
  LD r1,r0,#NT_F_CTX
  LD r2,r1,#NT_C_TOK
  LD r3,r0,#NT_F_E2
  LD r4,r1,#NT_C_DIM
  MUL r3,r3,r4
  ADD r2,r2,r3
  LD r1,r0,#NT_F_CTX
  LD r1,r1,#NT_C_NP
  LD r3,r0,#NT_F_PREFIX
  ADD r3,r3,r13
  LD r4,r0,#NT_F_CTX
  LD r4,r4,#NT_C_CFG
  CALL @npaged_append
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nta_bad
  ST r1,r0,#NT_F_T2
nta_len1_att:
  ; the free token occupies prefix+1 by construction
  LD r1,r0,#NT_F_CTX
  LD r1,r1,#NT_C_NP
  LD r2,r0,#NT_F_PREFIX
  ADD r2,r2,r13
  LD r3,r0,#NT_F_CTX
  LD r3,r3,#NT_C_CFG
  LD r4,r0,#NT_F_CTX
  ADD r4,r4,r0
  LA r5,#NT_C_CUR
  ADD r4,r4,r5
  CALL @npaged_attention
  CMP r1,r0
  JMP[NE] @nta_bad
  JMP @nta_emit
nta_len2:
  ; cur = accepted child logits
  LD r1,r0,#NT_F_CHILD
  SHL r1,r1,6
  LD r2,r0,#NT_F_CTX
  ADD r2,r2,r0
  LA r3,#NT_C_CLOG
  ADD r2,r2,r3
  ADD r1,r2,r1
  LD r2,r0,#NT_F_CTX
  ADD r2,r2,r0
  LA r3,#NT_C_CUR
  ADD r2,r2,r3
  LD r3,r0,#NT_F_DIM
  CALL @ns_copy
  JMP @nta_emit
nta_emit:
  ; last = e2
  LD r1,r0,#NT_F_CTX
  LD r2,r0,#NT_F_E2
  ST r2,r1,#NT_C_LAST
  ; emit events
  LD r1,r0,#NT_F_CTX
  MOVI r2,#NT_E_EMIT
  LD r3,r0,#NT_F_PREFIX
  LD r4,r0,#NT_F_E1
  CALL @nt_event
  LD r1,r0,#NT_F_CTX
  MOVI r2,#NT_E_EMIT
  LD r3,r0,#NT_F_PREFIX
  ADD r3,r3,r13
  LD r4,r0,#NT_F_E2
  CALL @nt_event
  MOVI r1,2
  JMP @nta_out

; ---- no root matched: trim everything and fall back to two plain tokens ----
nta_none:
  ST r0,r0,#NT_F_LEN
  LD r1,r0,#NT_F_CTX
  LD r1,r1,#NT_C_NP
  LD r2,r0,#NT_F_PREFIX
  CALL @npaged_trim
  CMP r1,r0
  JMP[NE] @nta_bad
  ; counters
  LD r1,r0,#NT_F_CTX
  MOVI r2,6
  LD r3,r1,#NT_C_REJ
  ADD r3,r3,r2
  ST r3,r1,#NT_C_REJ
  LD r3,r1,#NT_C_TRIM
  ADD r3,r3,r2
  ST r3,r1,#NT_C_TRIM
  ST r0,r1,#NT_C_LASTLEN
  ST r0,r1,#NT_C_ACCGEN
  ; trim event
  LD r1,r0,#NT_F_CTX
  MOVI r2,#NT_E_TRIM
  MOVI r3,6
  LD r4,r0,#NT_F_PREFIX
  CALL @nt_event
  ; reject events
  ST r0,r0,#NT_F_T
nta_nrl:
  LD r1,r0,#NT_F_T
  MOVI r2,6
  CMP r1,r2
  JMP[GE] @nta_nrd
  MOVI r2,12
  MUL r2,r1,r2
  LD r3,r0,#NT_F_CTX
  ADD r3,r3,r0
  LA r4,#NT_C_CAND
  ADD r3,r3,r4
  ADD r3,r3,r2
  LD r4,r3,0
  LD r1,r0,#NT_F_CTX
  MOVI r2,#NT_E_REJECT
  LD r3,r0,#NT_F_T
  CALL @nt_event
  LD r1,r0,#NT_F_T
  ADD r1,r1,r13
  ST r1,r0,#NT_F_T
  JMP @nta_nrl
nta_nrd:
  ; append e1 at prefix
  LD r1,r0,#NT_F_CTX
  LD r2,r1,#NT_C_TOK
  LD r3,r0,#NT_F_E1
  LD r4,r1,#NT_C_DIM
  MUL r3,r3,r4
  ADD r2,r2,r3
  LD r1,r0,#NT_F_CTX
  LD r1,r1,#NT_C_NP
  LD r3,r0,#NT_F_PREFIX
  LD r4,r0,#NT_F_CTX
  LD r4,r4,#NT_C_CFG
  CALL @npaged_append
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nta_bad
  ST r1,r0,#NT_F_T
  ; attention -> TMP
  LD r1,r0,#NT_F_CTX
  LD r1,r1,#NT_C_NP
  LD r2,r0,#NT_F_T
  LD r3,r0,#NT_F_CTX
  LD r3,r3,#NT_C_CFG
  LD r4,r0,#NT_F_CTX
  ADD r4,r4,r0
  LA r5,#NT_C_TMP
  ADD r4,r4,r5
  CALL @npaged_attention
  CMP r1,r0
  JMP[NE] @nta_bad
  ; tokens_out[0]=e1
  LD r1,r0,#NT_F_TOK
  LD r2,r0,#NT_F_E1
  ST r2,r1,0
  ; sample e2 from TMP
  LD r1,r0,#NT_F_CTX
  ADD r1,r1,r0
  LA r2,#NT_C_TMP
  ADD r1,r1,r2
  LD r2,r0,#NT_F_VOC
  LD r3,r0,#NT_F_CTX
  LD r3,r3,#NT_C_TEMP
  LD r4,r0,#NT_F_CTX
  LD r4,r4,#NT_C_SEED
  CALL @ns_sample
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nta_bad
  ST r1,r0,#NT_F_E2
  LD r3,r0,#NT_F_CTX
  ST r2,r3,#NT_C_SEED
  ; logits_out[1] = TMP
  LD r1,r0,#NT_F_CTX
  ADD r1,r1,r0
  LA r2,#NT_C_TMP
  ADD r1,r1,r2
  LD r2,r0,#NT_F_LOG
  LD r3,r0,#NT_F_DIM
  ADD r2,r2,r3
  LD r3,r0,#NT_F_DIM
  CALL @ns_copy
  ; append e2 at prefix+1
  LD r1,r0,#NT_F_CTX
  LD r2,r1,#NT_C_TOK
  LD r3,r0,#NT_F_E2
  LD r4,r1,#NT_C_DIM
  MUL r3,r3,r4
  ADD r2,r2,r3
  LD r1,r0,#NT_F_CTX
  LD r1,r1,#NT_C_NP
  LD r3,r0,#NT_F_PREFIX
  ADD r3,r3,r13
  LD r4,r0,#NT_F_CTX
  LD r4,r4,#NT_C_CFG
  CALL @npaged_append
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nta_bad
  ST r1,r0,#NT_F_T2
  ; attention -> cur
  LD r1,r0,#NT_F_CTX
  LD r1,r1,#NT_C_NP
  LD r2,r0,#NT_F_T2
  LD r3,r0,#NT_F_CTX
  LD r3,r3,#NT_C_CFG
  LD r4,r0,#NT_F_CTX
  ADD r4,r4,r0
  LA r5,#NT_C_CUR
  ADD r4,r4,r5
  CALL @npaged_attention
  CMP r1,r0
  JMP[NE] @nta_bad
  ; tokens_out[1]=e2
  LD r1,r0,#NT_F_TOK
  LD r2,r0,#NT_F_E2
  ST r2,r1,1
  JMP @nta_emit
nta_bad:
  LA r1,0xFFFFFFFF
nta_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nspectree_init: r1=ctx r2=npaged ctx r3=nattn cfg r4=init cfg -> 0/-1
nspectree_init:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_E_CTX
  ST r2,r0,#NT_E_NP
  ST r3,r0,#NT_E_TOK
  ST r4,r0,#NT_E_LOG
  CMP r1,r0
  JMP[EQ] @nti_bad
  CMP r2,r0
  JMP[EQ] @nti_bad
  CMP r3,r0
  JMP[EQ] @nti_bad
  CMP r4,r0
  JMP[EQ] @nti_bad
  LD r5,r3,0
  LA r6,#NATT_MAGIC
  CMP r5,r6
  JMP[NE] @nti_bad
  LD r5,r3,1
  MOVI r6,#NATT_VERSION
  CMP r5,r6
  JMP[NE] @nti_bad
  LD r5,r2,#NP_C_MAGIC
  LA r6,#NP_MAGIC
  CMP r5,r6
  JMP[NE] @nti_bad
  LD r5,r2,#NP_C_VERSION
  MOVI r6,#NP_VERSION
  CMP r5,r6
  JMP[NE] @nti_bad
  LD r5,r4,#NT_K_MAGIC
  LA r6,#NT_CFG_MAGIC
  CMP r5,r6
  JMP[NE] @nti_bad
  LD r5,r4,#NT_K_VERSION
  MOVI r6,#NT_VERSION
  CMP r5,r6
  JMP[NE] @nti_bad
  LD r6,r4,#NT_K_VOCAB
  CMP r6,r0
  JMP[LE] @nti_bad
  MOVI r7,#NT_VMAX
  CMP r6,r7
  JMP[GT] @nti_bad
  LD r7,r4,#NT_K_TEMP
  SHR r8,r7,31
  CMP r8,r0
  JMP[NE] @nti_bad
  LD r7,r4,#NT_K_TOK
  CMP r7,r0
  JMP[EQ] @nti_bad
  LD r7,r4,#NT_K_DRAFT
  CMP r7,r0
  JMP[EQ] @nti_bad
  LD r7,r4,#NT_K_TCAP
  CMP r7,r0
  JMP[EQ] @nti_tok
  LD r8,r4,#NT_K_TRACE
  CMP r8,r0
  JMP[EQ] @nti_bad
nti_tok:
  LD r7,r3,15
  CMP r7,r0
  JMP[EQ] @nti_bad
  LD r7,r3,16
  CMP r7,r0
  JMP[EQ] @nti_bad
  LD r7,r2,#NP_C_DIM
  LD r8,r3,3
  CMP r7,r8
  JMP[NE] @nti_bad
  LD r8,r2,#NP_C_NB
  ; zero 768 context words
  LD r1,r0,#NT_E_CTX
  MOVI r2,#NT_CTX_WORDS
  MOVI r3,0
nti_z:
  CMP r3,r2
  JMP[GE] @nti_zd
  ADD r4,r1,r3
  ST r0,r4,0
  ADD r3,r3,r13
  JMP @nti_z
nti_zd:
  LD r1,r0,#NT_E_CTX
  LA r2,#NT_MAGIC
  ST r2,r1,#NT_C_MAGIC
  MOVI r2,#NT_VERSION
  ST r2,r1,#NT_C_VERSION
  LD r2,r0,#NT_E_NP
  ST r2,r1,#NT_C_NP
  LD r2,r0,#NT_E_TOK
  ST r2,r1,#NT_C_CFG
  LD r4,r0,#NT_E_LOG
  LD r2,r4,#NT_K_TOK
  ST r2,r1,#NT_C_TOK
  LD r2,r4,#NT_K_DRAFT
  ST r2,r1,#NT_C_DRAFT
  LD r2,r4,#NT_K_VOCAB
  ST r2,r1,#NT_C_VOCAB
  LD r2,r0,#NT_E_NP
  LD r3,r2,#NP_C_DIM
  ST r3,r1,#NT_C_DIM
  ST r0,r1,#NT_C_LAST
  LD r2,r4,#NT_K_TEMP
  ST r2,r1,#NT_C_TEMP
  LD r2,r4,#NT_K_FLAGS
  ST r2,r1,#NT_C_FLAGS
  LD r2,r4,#NT_K_TRACE
  ST r2,r1,#NT_C_TRACE
  LD r2,r4,#NT_K_TCAP
  ST r2,r1,#NT_C_TCAP
  MOVI r2,#NT_DEPTH
  ST r2,r1,#NT_C_DEPTH
  MOVI r2,#NT_BRANCH
  ST r2,r1,#NT_C_BRANCH
  ; seeds
  LD r2,r4,#NT_K_SEED
  CMP r2,r0
  JMP[NE] @nti_seed
  LA r2,#NS_XOR0
nti_seed:
  ST r2,r1,#NT_C_SEED
  ST r2,r1,#NT_C_SEED0
  LD r2,r4,#NT_K_DSEED
  CMP r2,r0
  JMP[NE] @nti_dseed
  LA r2,#NS_XOR0
nti_dseed:
  ST r2,r1,#NT_C_DSEED
  ST r2,r1,#NT_C_DSEED0
  LA r2,#NS_HEAD0
  ST r2,r1,#NT_C_HEAD
  MOVI r1,0
  JMP @nti_out
nti_bad:
  LA r1,0xFFFFFFFF
nti_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nspectree_prefill: r1=ctx r2=xs r3=count r4=last_token -> 0/-1
nspectree_prefill:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_E_CTX
  ST r2,r0,#NT_E_TOK
  ST r3,r0,#NT_E_CNT
  ST r4,r0,#NT_E_OUT
  CMP r1,r0
  JMP[EQ] @ntp_bad
  LD r5,r1,#NT_C_MAGIC
  LA r6,#NT_MAGIC
  CMP r5,r6
  JMP[NE] @ntp_bad
  CMP r2,r0
  JMP[EQ] @ntp_bad
  CMP r3,r0
  JMP[LE] @ntp_bad
  LD r5,r1,#NT_C_VOCAB
  CMP r4,r5
  JMP[GE] @ntp_bad
  LD r5,r1,#NT_C_NP
  LD r5,r5,#NP_C_USED
  CMP r5,r0
  JMP[NE] @ntp_bad
  ; npaged_prefill(np, xs, count, 0, cfg, cur)
  LD r1,r0,#NT_E_CTX
  LD r1,r1,#NT_C_NP
  LD r2,r0,#NT_E_TOK
  LD r3,r0,#NT_E_CNT
  MOVI r4,0
  LD r5,r0,#NT_E_CTX
  LD r5,r5,#NT_C_CFG
  LD r6,r0,#NT_E_CTX
  ADD r6,r6,r0
  LA r7,#NT_C_CUR
  ADD r6,r6,r7
  CALL @npaged_prefill
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntp_bad
  LD r1,r0,#NT_E_CTX
  LD r2,r0,#NT_E_CNT
  ST r2,r1,#NT_C_PROMPT
  ST r0,r1,#NT_C_GEN
  ST r0,r1,#NT_C_ACC
  ST r0,r1,#NT_C_REJ
  ST r0,r1,#NT_C_TRIM
  ST r0,r1,#NT_C_PASS
  ST r0,r1,#NT_C_STEPS
  ST r0,r1,#NT_C_DRAFTS
  ST r0,r1,#NT_C_FLAGS
  ST r0,r1,#NT_C_FORCED
  ST r0,r1,#NT_C_PROM
  ST r0,r1,#NT_C_ACCGEN
  ST r0,r1,#NT_C_LASTLEN
  ST r0,r1,#NT_C_TN
  ST r0,r1,#NT_C_LAST
  LA r3,#NS_HEAD0
  ST r3,r1,#NT_C_HEAD
  LD r3,r1,#NT_C_SEED0
  ST r3,r1,#NT_C_SEED
  LD r3,r1,#NT_C_DSEED0
  ST r3,r1,#NT_C_DSEED
  LD r3,r0,#NT_E_OUT
  ST r3,r1,#NT_C_LAST
  ; event prefill
  ADD r1,r1,r0
  MOVI r2,#NT_E_PREFILL
  LD r3,r0,#NT_E_CNT
  LD r4,r0,#NT_E_OUT
  CALL @nt_event
  MOVI r1,0
  JMP @ntp_out
ntp_bad:
  LA r1,0xFFFFFFFF
ntp_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nspectree_generate: r1=ctx r2=tokens_out r3=logits_out r4=count
;                     -> count/-1.  count must be positive and even.
nspectree_generate:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_E_CTX
  ST r2,r0,#NT_E_TOK
  ST r3,r0,#NT_E_LOG
  ST r4,r0,#NT_E_CNT
  CMP r1,r0
  JMP[EQ] @ntg_bad
  CMP r2,r0
  JMP[EQ] @ntg_bad
  CMP r3,r0
  JMP[EQ] @ntg_bad
  CMP r4,r0
  JMP[LE] @ntg_bad
  MOVI r5,1
  BOOL.8 r5,r4,r5
  CMP r5,r0
  JMP[NE] @ntg_bad
  LD r5,r1,#NT_C_MAGIC
  LA r6,#NT_MAGIC
  CMP r5,r6
  JMP[NE] @ntg_bad
  LD r5,r1,#NT_C_PROMPT
  CMP r5,r0
  JMP[EQ] @ntg_bad
  LD r1,r0,#NT_E_CTX
  LD r1,r1,#NT_C_NP
  CALL @npaged_remaining
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntg_bad
  LD r2,r0,#NT_E_CNT
  ADD r2,r2,r0
  ADDI r2,r2,4
  CMP r1,r2
  JMP[LT] @ntg_bad
  LD r1,r0,#NT_E_CTX
  LD r2,r1,#NT_C_DIM
  ST r2,r0,#NT_E_DIM
  LD r2,r1,#NT_C_NP
  ST r2,r0,#NT_E_NP
  ST r0,r0,#NT_E_OUT
ntg_l:
  LD r1,r0,#NT_E_OUT
  LD r2,r0,#NT_E_CNT
  CMP r1,r2
  JMP[GE] @ntg_done
  LD r1,r0,#NT_E_NP
  CALL @npaged_remaining
  MOVI r2,6
  CMP r1,r2
  JMP[LT] @ntg_bad
  LD r1,r0,#NT_E_CTX
  CALL @nt_build
  CMP r1,r0
  JMP[NE] @ntg_bad
  LD r1,r0,#NT_E_CTX
  CALL @nt_verify
  CMP r1,r0
  JMP[NE] @ntg_bad
  ; out pointers
  LD r1,r0,#NT_E_OUT
  LD r2,r0,#NT_E_TOK
  ADD r2,r2,r1
  LD r3,r0,#NT_E_OUT
  LD r4,r0,#NT_E_DIM
  MUL r3,r3,r4
  LD r4,r0,#NT_E_LOG
  ADD r3,r4,r3
  LD r1,r0,#NT_E_CTX
  CALL @nt_accept
  MOVI r2,2
  CMP r1,r2
  JMP[NE] @ntg_bad
  LD r1,r0,#NT_E_OUT
  ADD r1,r1,r13
  ADD r1,r1,r13
  ST r1,r0,#NT_E_OUT
  LD r1,r0,#NT_E_CTX
  LD r2,r1,#NT_C_GEN
  ADD r2,r2,r13
  ADD r2,r2,r13
  ST r2,r1,#NT_C_GEN
  LD r2,r1,#NT_C_STEPS
  ADD r2,r2,r13
  ST r2,r1,#NT_C_STEPS
  JMP @ntg_l
ntg_done:
  LD r1,r0,#NT_E_CNT
  JMP @ntg_out
ntg_bad:
  LA r1,0xFFFFFFFF
ntg_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nspectree_generate_plain: r1=ctx r2=tokens_out r3=logits_out r4=count
;                           -> count/-1
nspectree_generate_plain:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_E_CTX
  ST r2,r0,#NT_E_TOK
  ST r3,r0,#NT_E_LOG
  ST r4,r0,#NT_E_CNT
  CMP r1,r0
  JMP[EQ] @ntpl_bad
  CMP r2,r0
  JMP[EQ] @ntpl_bad
  CMP r3,r0
  JMP[EQ] @ntpl_bad
  CMP r4,r0
  JMP[LE] @ntpl_bad
  LD r5,r1,#NT_C_MAGIC
  LA r6,#NT_MAGIC
  CMP r5,r6
  JMP[NE] @ntpl_bad
  LD r5,r1,#NT_C_PROMPT
  CMP r5,r0
  JMP[EQ] @ntpl_bad
  LD r1,r0,#NT_E_CTX
  LD r1,r1,#NT_C_NP
  CALL @npaged_remaining
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntpl_bad
  LD r2,r0,#NT_E_CNT
  CMP r1,r2
  JMP[LT] @ntpl_bad
  LD r1,r0,#NT_E_CTX
  LD r2,r1,#NT_C_DIM
  ST r2,r0,#NT_E_DIM
  LD r2,r1,#NT_C_NP
  ST r2,r0,#NT_E_NP
  ; base = prompt + generated
  LD r2,r1,#NT_C_PROMPT
  LD r3,r1,#NT_C_GEN
  ADD r2,r2,r3
  ST r2,r0,#NT_E_BASE
  ST r0,r0,#NT_E_OUT
ntpl_l:
  LD r1,r0,#NT_E_OUT
  LD r2,r0,#NT_E_CNT
  CMP r1,r2
  JMP[GE] @ntpl_done
  LD r1,r0,#NT_E_BASE
  LD r3,r0,#NT_E_OUT
  ADD r2,r1,r3
  ST r2,r0,#NT_E_POS
  ; sample cur
  LD r1,r0,#NT_E_CTX
  ADD r1,r1,r0
  LA r2,#NT_C_CUR
  ADD r1,r1,r2
  LD r2,r0,#NT_E_CTX
  LD r2,r2,#NT_C_VOCAB
  LD r3,r0,#NT_E_CTX
  LD r3,r3,#NT_C_TEMP
  LD r4,r0,#NT_E_CTX
  LD r4,r4,#NT_C_SEED
  CALL @ns_sample
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @ntpl_bad
  ST r1,r0,#NT_E_OUT+20
  LD r3,r0,#NT_E_CTX
  ST r2,r3,#NT_C_SEED
  ; logits_out[out] = cur
  LD r1,r0,#NT_E_LOG
  LD r2,r0,#NT_E_OUT
  LD r3,r0,#NT_E_DIM
  MUL r2,r2,r3
  ADD r2,r1,r2
  LD r1,r0,#NT_E_CTX
  ADD r1,r1,r0
  LA r3,#NT_C_CUR
  ADD r1,r1,r3
  LD r3,r0,#NT_E_DIM
  CALL @ns_copy
  ; tokens_out[out] = token
  LD r1,r0,#NT_E_TOK
  LD r2,r0,#NT_E_OUT
  ADD r2,r1,r2
  LD r1,r0,#NT_E_OUT+20
  ST r1,r2,0
  ; x = token table + token*dim
  LD r1,r0,#NT_E_CTX
  LD r2,r1,#NT_C_TOK
  LD r3,r0,#NT_E_OUT+20
  LD r4,r1,#NT_C_DIM
  MUL r3,r3,r4
  ADD r2,r2,r3
  ; npaged_decode(np,x,pos,cfg,tmp)
  LD r1,r0,#NT_E_NP
  LD r3,r0,#NT_E_POS
  LD r4,r0,#NT_E_CTX
  LD r4,r4,#NT_C_CFG
  LD r5,r0,#NT_E_CTX
  ADD r5,r5,r0
  LA r6,#NT_C_TMP
  ADD r5,r5,r6
  CALL @npaged_decode
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntpl_bad
  ; pass++
  LD r1,r0,#NT_E_CTX
  LD r2,r1,#NT_C_PASS
  ADD r2,r2,r13
  ST r2,r1,#NT_C_PASS
  ; cur = tmp
  LD r1,r0,#NT_E_CTX
  ADD r1,r1,r0
  LA r2,#NT_C_TMP
  ADD r1,r1,r2
  LD r2,r0,#NT_E_CTX
  ADD r2,r2,r0
  LA r3,#NT_C_CUR
  ADD r2,r2,r3
  LD r3,r0,#NT_E_DIM
  CALL @ns_copy
  ; last = token
  LD r1,r0,#NT_E_CTX
  LD r2,r0,#NT_E_OUT+20
  ST r2,r1,#NT_C_LAST
  ; event plain(pos,token)
  ADD r1,r1,r0
  MOVI r2,#NT_E_PLAIN
  LD r3,r0,#NT_E_POS
  LD r4,r0,#NT_E_OUT+20
  CALL @nt_event
  LD r1,r0,#NT_E_OUT
  ADD r1,r1,r13
  ST r1,r0,#NT_E_OUT
  JMP @ntpl_l
ntpl_done:
  LD r1,r0,#NT_E_CTX
  LD r2,r1,#NT_C_GEN
  LD r3,r0,#NT_E_CNT
  ADD r2,r2,r3
  ST r2,r1,#NT_C_GEN
  LD r2,r1,#NT_C_STEPS
  LD r3,r0,#NT_E_CNT
  ADD r2,r2,r3
  ST r2,r1,#NT_C_STEPS
  LD r1,r0,#NT_E_CNT
  JMP @ntpl_out
ntpl_bad:
  LA r1,0xFFFFFFFF
ntpl_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nspectree_cur_logits: r1=ctx -> 64 current logits / 0
nspectree_cur_logits:
  LD r2,r1,#NT_C_MAGIC
  LA r3,#NT_MAGIC
  CMP r2,r3
  JMP[NE] @ntcl_bad
  ADD r1,r1,r0
  LA r2,#NT_C_CUR
  ADD r1,r1,r2
  RET
ntcl_bad:
  MOVI r1,0
  RET

; nspectree_set_flags: r1=ctx r2=flags -> 0/-1
nspectree_set_flags:
  LD r3,r1,#NT_C_MAGIC
  LA r4,#NT_MAGIC
  CMP r3,r4
  JMP[NE] @ntsf_bad
  ST r2,r1,#NT_C_FLAGS
  MOVI r1,0
  RET
ntsf_bad:
  LA r1,0xFFFFFFFF
  RET

; nspectree_flags: r1=ctx -> flags/-1
nspectree_flags:
  LD r2,r1,#NT_C_MAGIC
  LA r3,#NT_MAGIC
  CMP r2,r3
  JMP[NE] @ntfl_bad
  LD r1,r1,#NT_C_FLAGS
  RET
ntfl_bad:
  LA r1,0xFFFFFFFF
  RET

; nspectree_head: r1=ctx -> head/0
nspectree_head:
  LD r2,r1,#NT_C_MAGIC
  LA r3,#NT_MAGIC
  CMP r2,r3
  JMP[NE] @nthd_bad
  LD r1,r1,#NT_C_HEAD
  RET
nthd_bad:
  MOVI r1,0
  RET

; nspectree_trace: r1=ctx r2=index r3=out(4) -> 0/-1
nspectree_trace:
  LD r4,r1,#NT_C_MAGIC
  LA r5,#NT_MAGIC
  CMP r4,r5
  JMP[NE] @nttr_bad
  CMP r3,r0
  JMP[EQ] @nttr_bad
  LD r4,r1,#NT_C_TN
  CMP r2,r4
  JMP[GE] @nttr_bad
  LD r5,r1,#NT_C_TRACE
  CMP r5,r0
  JMP[EQ] @nttr_bad
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
nttr_bad:
  LA r1,0xFFFFFFFF
  RET

; ---------------------------------------------------------------------------
; nspectree_stats: r1=ctx r2=out(24) -> 0/-1
nspectree_stats:
  LD r3,r1,#NT_C_MAGIC
  LA r4,#NT_MAGIC
  CMP r3,r4
  JMP[NE] @ntst_bad
  CMP r2,r0
  JMP[EQ] @ntst_bad
  LD r3,r1,#NT_C_PROMPT
  ST r3,r2,0
  LD r3,r1,#NT_C_GEN
  ST r3,r2,1
  LD r3,r1,#NT_C_ACC
  ST r3,r2,2
  LD r3,r1,#NT_C_REJ
  ST r3,r2,3
  LD r3,r1,#NT_C_TRIM
  ST r3,r2,4
  LD r3,r1,#NT_C_PASS
  ST r3,r2,5
  LD r3,r1,#NT_C_STEPS
  ST r3,r2,6
  LD r3,r1,#NT_C_DRAFTS
  ST r3,r2,7
  LD r3,r1,#NT_C_TN
  ST r3,r2,8
  LD r3,r1,#NT_C_HEAD
  ST r3,r2,9
  LD r3,r1,#NT_C_VOCAB
  ST r3,r2,10
  LD r3,r1,#NT_C_DIM
  ST r3,r2,11
  LD r3,r1,#NT_C_SEED
  ST r3,r2,12
  LD r3,r1,#NT_C_DSEED
  ST r3,r2,13
  LD r3,r1,#NT_C_FLAGS
  ST r3,r2,14
  LD r3,r1,#NT_C_FORCED
  ST r3,r2,15
  LD r3,r1,#NT_C_PROM
  ST r3,r2,16
  LD r3,r1,#NT_C_ACCGEN
  ST r3,r2,17
  LD r3,r1,#NT_C_LASTLEN
  ST r3,r2,18
  LD r3,r1,#NT_C_DEPTH
  ST r3,r2,19
  LD r3,r1,#NT_C_BRANCH
  ST r3,r2,20
  LD r3,r1,#NT_C_NP
  LD r3,r3,#NP_C_USED
  ST r3,r2,21
  LD r3,r1,#NT_C_LAST
  ST r3,r2,22
  ST r0,r2,23
  MOVI r1,0
  RET
ntst_bad:
  LA r1,0xFFFFFFFF
  RET

; ---------------------------------------------------------------------------
; nspectree_cand: r1=ctx r2=index r3=out(10) -> 0/-1
nspectree_cand:
  LD r4,r1,#NT_C_MAGIC
  LA r5,#NT_MAGIC
  CMP r4,r5
  JMP[NE] @ntca_bad
  CMP r3,r0
  JMP[EQ] @ntca_bad
  MOVI r4,6
  CMP r2,r4
  JMP[GE] @ntca_bad
  MOVI r4,12
  MUL r4,r2,r4
  ADD r5,r1,r0
  LA r6,#NT_C_CAND
  ADD r5,r5,r6
  ADD r5,r5,r4
  LD r4,r5,0
  ST r4,r3,0
  LD r4,r5,1
  ST r4,r3,1
  LD r4,r5,2
  ST r4,r3,2
  LD r4,r5,3
  ST r4,r3,3
  LD r4,r5,4
  ST r4,r3,4
  LD r4,r5,5
  ST r4,r3,5
  LD r4,r5,6
  ST r4,r3,6
  LD r4,r5,7
  ST r4,r3,7
  ST r0,r3,8
  ST r0,r3,9
  MOVI r1,0
  RET
ntca_bad:
  LA r1,0xFFFFFFFF
  RET

; nspectree_mask_len: r1=ctx r2=candidate -> len/-1
nspectree_mask_len:
  LD r3,r1,#NT_C_MAGIC
  LA r4,#NT_MAGIC
  CMP r3,r4
  JMP[NE] @ntml_bad
  MOVI r3,6
  CMP r2,r3
  JMP[GE] @ntml_bad
  SHL r3,r2,4
  ADD r4,r1,r0
  LA r5,#NT_C_MASKS
  ADD r4,r4,r5
  ADD r4,r4,r3
  LD r1,r4,0
  RET
ntml_bad:
  LA r1,0xFFFFFFFF
  RET

; nspectree_mask: r1=ctx r2=candidate r3=index -> token/-1
nspectree_mask:
  LD r4,r1,#NT_C_MAGIC
  LA r5,#NT_MAGIC
  CMP r4,r5
  JMP[NE] @ntmk_bad
  MOVI r4,6
  CMP r2,r4
  JMP[GE] @ntmk_bad
  SHL r4,r2,4
  ADD r5,r1,r0
  LA r6,#NT_C_MASKS
  ADD r5,r5,r6
  ADD r5,r5,r4
  LD r4,r5,0
  CMP r3,r4
  JMP[GE] @ntmk_bad
  ADD r5,r5,r3
  ADDI r5,r5,1
  LD r1,r5,0
  RET
ntmk_bad:
  LA r1,0xFFFFFFFF
  RET

; nspectree_branch_gen: r1=ctx r2=candidate -> generation before trim / 0
nspectree_branch_gen:
  LD r3,r1,#NT_C_MAGIC
  LA r4,#NT_MAGIC
  CMP r3,r4
  JMP[NE] @ntbg_bad
  MOVI r3,6
  CMP r2,r3
  JMP[GE] @ntbg_bad
  MOVI r3,12
  MUL r3,r2,r3
  ADD r4,r1,r0
  LA r5,#NT_C_CAND
  ADD r4,r4,r5
  ADD r4,r4,r3
  LD r1,r4,4
  RET
ntbg_bad:
  MOVI r1,0
  RET
