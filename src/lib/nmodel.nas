; nmodel.nas - tiny deterministic model runtime slice (F7).
;
; Provides:
;   - f32 RMSNorm (exact for binary-fraction inputs; eps is an f32 bit word);
;   - Q4_0/Q8_0 GEMV entry points over nq4.nas packed blocks;
;   - deterministic sampling: argmax, temperature/top-k with a local xorshift32
;     seeded explicitly by the caller (no nreplay dependency);
;   - nmod_forward: a tiny 1-layer model path that averages token embeddings,
;     RMSNorm, and projects with one Q4 GEMV.  Attention is intentionally not
;     in this slice; the context is a deterministic bag-of-token embeddings.
;
; Model descriptor (16 words, caller supplied):
;   +0 magic 0x4E4D4F44 ("NMOD") +1 version 1
;   +2 vocab (<=64) +3 dim (<=32) +4 embedding table ptr (f32 words)
;   +5 norm weight ptr +6 q4 output blocks ptr +7 rows (== vocab)
;   +8 eps bits +9 flags (1 = Q4 output) +10..15 reserved
;
; API:
;   nmod_rmsnorm r1=x r2=w r3=dim r4=eps_bits r5=out -> 0/-1
;   nmod_gemv_q4 r1=blocks r2=rows r3=acts r4=out -> 0/-1
;   nmod_gemv_q8 r1=blocks r2=rows r3=acts r4=out -> 0/-1
;   nmod_argmax r1=logits r2=n -> index or -1
;   nmod_sample r1=logits r2=n r3=temp_bits r4=topk r5=seed
;               -> r1=index r2=next_seed (or r1=-1)
;   nmod_xorshift r1=seed -> r1=next
;   nmod_forward r1=model r2=ids(word ptr) r3=count r4=logits out -> 0/-1
;
; Scratch at 0x5400 (ntok 0x5200, ngguf 0x5800).

.include "nq4.nas"

.equ NMD_MAGIC   0x4E4D4F44
.equ NMD_VERSION 1

.equ NMD        0x5400
.equ NMD_CTX    0x5400
.equ NMD_NORM   0x5420
.equ NMD_ACTS   0x5440
.equ NMD_TOPV   0x5460
.equ NMD_TOPI   0x54A0
.equ NMD_TMP    0x54E0

.equ NMD_MAX_DIM  32
.equ NMD_MAX_VOC  64

; ---------------------------------------------------------------------------
; nmod_rmsnorm r1=x r2=w r3=dim r4=eps bits r5=out -> 0/-1
nmod_rmsnorm:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NMD_TMP+0
  ST r2,r0,#NMD_TMP+1
  ST r3,r0,#NMD_TMP+2
  ST r4,r0,#NMD_TMP+3
  ST r5,r0,#NMD_TMP+4
  CMP r3,r0
  JMP[EQ] @nmod_rn_bad
  MOVI r2,#NMD_MAX_DIM
  CMP r3,r2
  JMP[GT] @nmod_rn_bad

  ; sum = sum(x*x)
  MOVI r1,0
  ST r1,r0,#NMD_TMP+5
  ST r0,r0,#NMD_TMP+6
nmod_rn_l1:
  LD r1,r0,#NMD_TMP+6
  LD r2,r0,#NMD_TMP+2
  CMP r1,r2
  JMP[GE] @nmod_rn_l1d
  LD r3,r0,#NMD_TMP+0
  ADD r3,r3,r1
  LD r3,r3,0
  FMUL r4,r3,r3
  LD r5,r0,#NMD_TMP+5
  FADD r5,r5,r4
  ST r5,r0,#NMD_TMP+5
  LD r1,r0,#NMD_TMP+6
  ADD r1,r1,r13
  ST r1,r0,#NMD_TMP+6
  JMP @nmod_rn_l1
nmod_rn_l1d:
  ; mean = sum/dim + eps
  LD r1,r0,#NMD_TMP+5
  LD r2,r0,#NMD_TMP+2
  CVTIF r2,r2
  FDIV r1,r1,r2
  LD r2,r0,#NMD_TMP+3
  FADD r1,r1,r2
  FSQRT r1,r1
  ST r1,r0,#NMD_TMP+7

  ; out[i] = (x[i]/rms)*w[i]
  ST r0,r0,#NMD_TMP+6
nmod_rn_l2:
  LD r1,r0,#NMD_TMP+6
  LD r2,r0,#NMD_TMP+2
  CMP r1,r2
  JMP[GE] @nmod_rn_ok
  LD r3,r0,#NMD_TMP+0
  ADD r3,r3,r1
  LD r3,r3,0
  LD r4,r0,#NMD_TMP+7
  FDIV r3,r3,r4
  LD r5,r0,#NMD_TMP+1
  ADD r5,r5,r1
  LD r5,r5,0
  FMUL r3,r3,r5
  LD r5,r0,#NMD_TMP+4
  ADD r5,r5,r1
  ST r3,r5,0
  LD r1,r0,#NMD_TMP+6
  ADD r1,r1,r13
  ST r1,r0,#NMD_TMP+6
  JMP @nmod_rn_l2
nmod_rn_ok:
  MOVI r1,0
  JMP @nmod_rn_out
nmod_rn_bad:
  LA r1,0xFFFFFFFF
nmod_rn_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
nmod_gemv_q4:
  JMP @nq4_gemv
nmod_gemv_q8:
  JMP @nq8_gemv

; ---------------------------------------------------------------------------
; nmod_xorshift32: r1=seed -> r1=next (seed 0 maps to 0x12345678)
nmod_xorshift:
  CMP r1,r0
  JMP[NE] @nmod_xs_go
  LA r1,0x12345678
nmod_xs_go:
  ADD r2,r1,r0
  SHL r2,r2,13
  BOOL.6 r3,r1,r2
  ADD r2,r3,r0
  SHR r2,r2,17
  BOOL.6 r3,r3,r2
  ADD r2,r3,r0
  SHL r2,r2,5
  BOOL.6 r1,r3,r2
  RET

; ---------------------------------------------------------------------------
; nmod_argmax r1=logits r2=n -> index/-1
nmod_argmax:
  CMP r2,r0
  JMP[LE] @nmod_am_bad
  LD r3,r1,0
  MOVI r4,0
  MOVI r5,1
nmod_am_l:
  CMP r5,r2
  JMP[GE] @nmod_am_done
  ADD r6,r1,r5
  LD r6,r6,0
  FCMP r6,r3
  JMP[GT] @nmod_am_up
  ADD r5,r5,r13
  JMP @nmod_am_l
nmod_am_up:
  ADD r3,r6,r0
  ADD r4,r5,r0
  ADD r5,r5,r13
  JMP @nmod_am_l
nmod_am_done:
  ADD r1,r4,r0
  RET
nmod_am_bad:
  LA r1,0xFFFFFFFF
  RET

; ---------------------------------------------------------------------------
; nmod_sample r1=logits r2=n r3=temp bits r4=topk r5=seed
;             -> r1=index r2=next_seed
nmod_sample:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NMD_TMP+40
  ST r2,r0,#NMD_TMP+41
  ST r3,r0,#NMD_TMP+42
  ST r4,r0,#NMD_TMP+43
  ST r5,r0,#NMD_TMP+44
  CMP r2,r0
  JMP[LE] @nmod_sm_bad
  MOVI r6,#NMD_MAX_VOC
  CMP r2,r6
  JMP[GT] @nmod_sm_bad
  CMP r4,r0
  JMP[LE] @nmod_sm_bad
  CMP r4,r2
  JMP[LE] @nmod_sm_k
  ST r2,r0,#NMD_TMP+43
nmod_sm_k:

  ; top-k selection (ties keep the lower index)
  ST r0,r0,#NMD_TMP+45          ; rank
nmod_sm_rank:
  LD r1,r0,#NMD_TMP+45
  LD r2,r0,#NMD_TMP+43
  CMP r1,r2
  JMP[GE] @nmod_sm_rankd
  LA r3,0xFFFFFFFF              ; best index
  MOVI r4,0                     ; best bits
  MOVI r5,0                     ; candidate
nmod_sm_cand:
  LD r1,r0,#NMD_TMP+41
  CMP r5,r1
  JMP[GE] @nmod_sm_candd
  ; skip already selected
  MOVI r6,0
nmod_sm_skip:
  LD r1,r0,#NMD_TMP+45
  CMP r6,r1
  JMP[GE] @nmod_sm_use
  LA r7,#NMD_TOPI
  ADD r7,r7,r6
  LD r7,r7,0
  CMP r7,r5
  JMP[EQ] @nmod_sm_next
  ADD r6,r6,r13
  JMP @nmod_sm_skip
nmod_sm_use:
  LD r1,r0,#NMD_TMP+40
  ADD r1,r1,r5
  LD r7,r1,0
  LA r8,0xFFFFFFFF
  CMP r3,r8
  JMP[EQ] @nmod_sm_take
  FCMP r7,r4
  JMP[GT] @nmod_sm_take
  JMP @nmod_sm_next
nmod_sm_take:
  ADD r3,r5,r0
  ADD r4,r7,r0
nmod_sm_next:
  ADD r5,r5,r13
  JMP @nmod_sm_cand
nmod_sm_candd:
  ; store selected index/value
  LA r6,#NMD_TOPI
  LD r1,r0,#NMD_TMP+45
  ADD r6,r6,r1
  ST r3,r6,0
  LA r6,#NMD_TOPV
  ADD r6,r6,r1
  ST r4,r6,0
  LD r1,r0,#NMD_TMP+45
  ADD r1,r1,r13
  ST r1,r0,#NMD_TMP+45
  JMP @nmod_sm_rank
nmod_sm_rankd:

  ; temperature 0 (or negative -> reject) is greedy; seed is unchanged
  LD r1,r0,#NMD_TMP+42
  CMP r1,r0
  JMP[EQ] @nmod_sm_greedy
  SHR r1,r1,31
  CMP r1,r0
  JMP[NE] @nmod_sm_bad

  ; weights[j] = exp((logit[j]-max)/temp)
  LA r1,#NMD_TOPV
  LD r2,r1,0
  ST r2,r0,#NMD_TMP+46         ; max
  MOVI r1,0
  ST r1,r0,#NMD_TMP+47         ; sum
  ST r0,r0,#NMD_TMP+48         ; j
nmod_sm_w:
  LD r1,r0,#NMD_TMP+48
  LD r2,r0,#NMD_TMP+43
  CMP r1,r2
  JMP[GE] @nmod_sm_wd
  LA r3,#NMD_TOPV
  ADD r3,r3,r1
  LD r4,r3,0
  LD r5,r0,#NMD_TMP+46
  FSUB r4,r4,r5
  LD r5,r0,#NMD_TMP+42
  FDIV r4,r4,r5
  FEXP r4,r4
  ST r4,r3,0
  LD r5,r0,#NMD_TMP+47
  FADD r5,r5,r4
  ST r5,r0,#NMD_TMP+47
  LD r1,r0,#NMD_TMP+48
  ADD r1,r1,r13
  ST r1,r0,#NMD_TMP+48
  JMP @nmod_sm_w
nmod_sm_wd:
  ; next = xorshift(seed); u24 = next>>8; threshold = (u24/2^24)*sum
  LD r1,r0,#NMD_TMP+44
  CALL @nmod_xorshift
  ST r1,r0,#NMD_TMP+49
  SHR r2,r1,8
  CVTIF r2,r2
  LA r3,0x33800000
  FMUL r2,r2,r3
  LD r3,r0,#NMD_TMP+47
  FMUL r2,r2,r3
  ST r2,r0,#NMD_TMP+50

  ; cumulative selection
  MOVI r1,0
  ST r1,r0,#NMD_TMP+51         ; acc
  ST r0,r0,#NMD_TMP+48
nmod_sm_pick:
  LD r1,r0,#NMD_TMP+48
  LD r2,r0,#NMD_TMP+43
  CMP r1,r2
  JMP[GE] @nmod_sm_last
  LA r3,#NMD_TOPV
  ADD r3,r3,r1
  LD r4,r3,0
  LD r5,r0,#NMD_TMP+51
  FADD r5,r5,r4
  ST r5,r0,#NMD_TMP+51
  LD r6,r0,#NMD_TMP+50
  FCMP r5,r6
  JMP[GE] @nmod_sm_hit
  LD r1,r0,#NMD_TMP+48
  ADD r1,r1,r13
  ST r1,r0,#NMD_TMP+48
  JMP @nmod_sm_pick
nmod_sm_hit:
  LA r2,#NMD_TOPI
  ADD r2,r2,r1
  LD r1,r2,0
  LD r2,r0,#NMD_TMP+49
  JMP @nmod_sm_out
nmod_sm_last:
  LD r1,r0,#NMD_TMP+43
  ADDI r1,r1,-1
  LA r2,#NMD_TOPI
  ADD r2,r2,r1
  LD r1,r2,0
  LD r2,r0,#NMD_TMP+49
  JMP @nmod_sm_out
nmod_sm_greedy:
  LA r2,#NMD_TOPI
  LD r1,r2,0
  LD r2,r0,#NMD_TMP+44
  JMP @nmod_sm_out
nmod_sm_bad:
  LA r1,0xFFFFFFFF
  MOVI r2,0
nmod_sm_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nmod_forward r1=model r2=ids r3=count r4=logits -> 0/-1
nmod_forward:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NMD_TMP+60
  ST r2,r0,#NMD_TMP+61
  ST r3,r0,#NMD_TMP+62
  ST r4,r0,#NMD_TMP+63
  LD r5,r1,0
  LA r6,#NMD_MAGIC
  CMP r5,r6
  JMP[NE] @nmod_fw_bad
  LD r5,r1,1
  MOVI r6,#NMD_VERSION
  CMP r5,r6
  JMP[NE] @nmod_fw_bad
  LD r5,r1,2
  ST r5,r0,#NMD_TMP+64
  CMP r5,r0
  JMP[EQ] @nmod_fw_bad
  MOVI r6,#NMD_MAX_VOC
  CMP r5,r6
  JMP[GT] @nmod_fw_bad
  LD r5,r1,3
  ST r5,r0,#NMD_TMP+65
  CMP r5,r0
  JMP[EQ] @nmod_fw_bad
  MOVI r6,#NMD_MAX_DIM
  CMP r5,r6
  JMP[GT] @nmod_fw_bad
  LD r5,r1,7
  LD r6,r0,#NMD_TMP+64
  CMP r5,r6
  JMP[NE] @nmod_fw_bad
  LD r3,r0,#NMD_TMP+62
  CMP r3,r0
  JMP[LE] @nmod_fw_bad

  ; zero ctx[0..dim-1]
  LA r1,#NMD_CTX
  LD r2,r0,#NMD_TMP+65
nmod_fw_z:
  CMP r2,r0
  JMP[EQ] @nmod_fw_zd
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nmod_fw_z
nmod_fw_zd:
  ; zero acts[0..31]
  LA r1,#NMD_ACTS
  MOVI r2,#NMD_MAX_DIM
nmod_fw_za:
  CMP r2,r0
  JMP[EQ] @nmod_fw_zad
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nmod_fw_za
nmod_fw_zad:

  ; sum token embeddings
  ST r0,r0,#NMD_TMP+66
nmod_fw_tok:
  LD r1,r0,#NMD_TMP+66
  LD r2,r0,#NMD_TMP+62
  CMP r1,r2
  JMP[GE] @nmod_fw_tokd
  LD r3,r0,#NMD_TMP+61
  ADD r3,r3,r1
  LD r3,r3,0
  LD r4,r0,#NMD_TMP+64
  CMP r3,r4
  JMP[GE] @nmod_fw_bad
  LD r4,r0,#NMD_TMP+65
  MUL r3,r3,r4
  LD r5,r0,#NMD_TMP+60
  LD r5,r5,4
  ADD r5,r5,r3
  MOVI r6,0
nmod_fw_dim:
  LD r3,r0,#NMD_TMP+65
  CMP r6,r3
  JMP[GE] @nmod_fw_tokn
  ADD r7,r5,r6
  LD r7,r7,0
  LA r8,#NMD_CTX
  ADD r8,r8,r6
  LD r9,r8,0
  FADD r9,r9,r7
  ST r9,r8,0
  ADD r6,r6,r13
  JMP @nmod_fw_dim
nmod_fw_tokn:
  LD r1,r0,#NMD_TMP+66
  ADD r1,r1,r13
  ST r1,r0,#NMD_TMP+66
  JMP @nmod_fw_tok
nmod_fw_tokd:

  ; ctx /= count
  LD r1,r0,#NMD_TMP+62
  CVTIF r1,r1
  ST r1,r0,#NMD_TMP+67
  MOVI r6,0
nmod_fw_div:
  LD r1,r0,#NMD_TMP+65
  CMP r6,r1
  JMP[GE] @nmod_fw_divd
  LA r2,#NMD_CTX
  ADD r2,r2,r6
  LD r3,r2,0
  LD r4,r0,#NMD_TMP+67
  FDIV r3,r3,r4
  ST r3,r2,0
  ADD r6,r6,r13
  JMP @nmod_fw_div
nmod_fw_divd:

  ; RMSNorm(ctx, norm, dim, eps) -> NMD_NORM
  LD r1,r0,#NMD_TMP+60
  LD r1,r1,5
  ST r1,r0,#NMD_TMP+68
  LA r1,#NMD_CTX
  LD r2,r0,#NMD_TMP+68
  LD r3,r0,#NMD_TMP+65
  LD r4,r0,#NMD_TMP+60
  LD r4,r4,8
  LA r5,#NMD_NORM
  CALL @nmod_rmsnorm
  CMP r1,r0
  JMP[NE] @nmod_fw_bad

  ; acts[0..dim-1] = norm
  MOVI r6,0
nmod_fw_cp:
  LD r1,r0,#NMD_TMP+65
  CMP r6,r1
  JMP[GE] @nmod_fw_cpd
  LA r2,#NMD_NORM
  ADD r2,r2,r6
  LD r3,r2,0
  LA r2,#NMD_ACTS
  ADD r2,r2,r6
  ST r3,r2,0
  ADD r6,r6,r13
  JMP @nmod_fw_cp
nmod_fw_cpd:

  ; Q4 projection
  LD r1,r0,#NMD_TMP+60
  LD r1,r1,6
  LD r2,r0,#NMD_TMP+64
  LA r3,#NMD_ACTS
  LD r4,r0,#NMD_TMP+63
  CALL @nq4_gemv
  CMP r1,r0
  JMP[NE] @nmod_fw_bad
  MOVI r1,0
  JMP @nmod_fw_out
nmod_fw_bad:
  LA r1,0xFFFFFFFF
nmod_fw_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
