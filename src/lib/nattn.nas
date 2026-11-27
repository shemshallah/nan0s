; nattn.nas - one-head causal attention over nkv token views (F7b).
;
; Pure NaN.  A token view is a rank-1 f32 nkv view whose 3*dim elements are
; laid out as [x | v | ctx]:
;   +0..dim-1       x    input latent (owned by the caller)
;   +dim..2dim-1    v    V projection (f32)
;   +2dim..3dim-1   ctx  attention output (f32)
; Q and K are quantized for the attention cache and live in caller-supplied
; packed buffers:
;   q4buf: n_tokens * nblocks * 5 words   (Q4_0, scale q4scale)
;   q8buf: n_tokens * nblocks * 9 words   (Q8_0, scale q8scale)
; so one token's Q/K cache is 5/9 words per 32 values instead of 32 f32.
; The view must be slab-owned (nkv_slab_token_view) so its generation can be
; checked with nkv_view_check; nattn only consumes its metadata.
;
; Weights are native nq4.nas blocks (f32 scale, 32 weights/block):
;   Wq Q4_0 rows=dim cols=dim, Wk Q8_0, Wv Q4_0, Wo Q4_0.
; Row r occupies dim/32 consecutive blocks starting at r*nblocks.
;
; Attention:
;   q[t] = Wq*x[t], k[t] = Wk*x[t], v[t] = Wv*x[t]
;   RoPE on the f32 q,k, then quantize q->Q4_0 and k->Q8_0 (truncating)
;   score[t][s] = scale * fused_q4xq8_dot(qcache[t],kcache[s])
;   w[t][s] = exp(score-max)/sum(exp)          (f32, FEXP)
;   ctx[t] = sum_s w[t][s]*v[s]
;   logits = Wo * RMSNorm(x[last]+ctx[last])   (nattn_last_logits)
;
; nattn_qk_fused walks packed Q4_0 nibbles and Q8_0 signed bytes, accumulates
; the integer dot, and multiplies by scale4*scale8 once per block.  For
; power-of-two block scales and small payloads this is bit-identical to the
; nq4_dot32 oracle: every operation is exact in binary32.
;
; RoPE table layout: table[(pos*pairs + i)*2] = cos, +1 = sin, i=0..pairs-1,
; pairs = dim/2.  NaNVM1 has no FSIN/FCOS (spec/NANVM_SPEC.md), so the table
; is precomputed by the caller, exactly as llama.cpp precomputes RoPE tables.
; nattn_rope itself is an exact f32 rotation for any table values.
;
; Config (32 words):
;   +0 magic 0x5454414E ("NATT") +1 version 1
;   +2 n_tokens 1..8           +3 dim 32 or 64 (multiple of 32)
;   +4 flags: bit0 RoPE         +5 Wq blocks (Q4_0)
;   +6 Wk blocks (Q8_0)         +7 Wv blocks (Q4_0)
;   +8 Wo blocks (Q4_0)         +9 RoPE table (f32 cos/sin)
;   +10 attention scale bits    +11 RMSNorm weight ptr
;   +12 eps bits                +13 Q4 cache buffer
;   +14 Q8 cache buffer         +15 Q4 quant scale bits
;   +16 Q8 quant scale bits     +17..31 reserved
;
; API:
;   nattn_view_ptr r1=view -> r1=word address (0 on failure)
;   nattn_rope r1=vec r2=table r3=pos r4=pairs -> 0/-1
;   nattn_softmax r1=scores r2=n r3=out -> 0/-1
;   nattn_qk_fused r1=q4blocks r2=q8blocks r3=nblocks -> r1=f32 bits
;   nattn_quant_q4 r1=src r2=dst r3=cols r4=scale -> 0/-1
;   nattn_quant_q8 r1=src r2=dst r3=cols r4=scale -> 0/-1
;   nattn_matvec_q4 r1=w r2=rows r3=cols r4=x r5=out -> 0/-1
;   nattn_matvec_q8 r1=w r2=rows r3=cols r4=x r5=out -> 0/-1
;   nattn_forward r1=cfg r2=token views -> 0/-1
;   nattn_last_logits r1=cfg r2=token views r3=logits -> 0/-1
;
; Scratch 0x5600..0x57FF (below ngguf 0x5800, above nmodel 0x5400).
; nq4 scratch is 0x6000.  Requires r13=1, r14 soft stack, r0=0.

.include "nq4.nas"
.include "nkv.nas"

.equ NATT_MAGIC   0x5454414E
.equ NATT_VERSION 1

.equ NAT_CFG    0x5600
.equ NAT_VIEWS  0x5601
.equ NAT_N      0x5602
.equ NAT_DIM    0x5603
.equ NAT_FLAGS  0x5604
.equ NAT_WQ     0x5605
.equ NAT_WK     0x5606
.equ NAT_WV     0x5607
.equ NAT_WO     0x5608
.equ NAT_ROPE   0x5609
.equ NAT_SCALE  0x560A
.equ NAT_NW     0x560B
.equ NAT_EPS    0x560C
.equ NAT_NB     0x560D
.equ NAT_Q4B    0x560E
.equ NAT_Q8B    0x560F
.equ NAT_Q4S    0x5610
.equ NAT_Q8S    0x5611

.equ NAT_T      0x5612
.equ NAT_S      0x5613
.equ NAT_D      0x5614
.equ NAT_VP0    0x5615
.equ NAT_ROW    0x5616
.equ NAT_QP     0x5617
.equ NAT_VPT    0x5618
.equ NAT_TMP    0x5619
.equ NAT_ACC    0x561A
.equ NAT_CNT    0x561B
.equ NAT_KP     0x561C
.equ NAT_CP     0x561D
.equ NAT_WT     0x561E
.equ NAT_T2     0x561F

.equ NAT_FW     0x5630
.equ NAT_VP     0x563C
.equ NAT_MV     0x5640
.equ NAT_RP     0x564C
.equ NAT_QK     0x5654
.equ NAT_SM     0x5660
.equ NAT_QT     0x5668
.equ NAT_H      0x5670
.equ NAT_KSCR   0x56B0
.equ NAT_BYTES  0x56F0
.equ NAT_SCORES 0x5740

.equ NAT_MAX_T   8
.equ NAT_MAX_DIM 64

; ---------------------------------------------------------------------------
; nattn_view_ptr: r1=view -> r1=f32 word address, 0 on failure.
; Requires a rank-1 f32 view whose byte offset is 4-byte aligned and whose
; first element is below 4 GiB.  Later elements may cross 4 GiB; callers that
; consume bytes must range-check (nattn only reads below 4 GiB).
nattn_view_ptr:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NAT_VP+0
  LD r2,r1,0
  LA r3,#NKV_VIEW_MAGIC
  CMP r2,r3
  JMP[NE] @nat_vp_fail
  LD r2,r1,1
  MOVI r3,#NKV_VERSION
  CMP r2,r3
  JMP[NE] @nat_vp_fail
  LD r2,r1,#NKV_V_DTYPE
  MOVI r3,2
  CMP r2,r3
  JMP[NE] @nat_vp_fail
  LD r2,r1,#NKV_V_RANK
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nat_vp_fail
  LD r1,r0,#NAT_VP+0
  MOVI r2,0
  MOVI r3,0
  CALL @nkv_view_addr
  CMP r3,r0
  JMP[NE] @nat_vp_fail
  CMP r2,r0
  JMP[NE] @nat_vp_fail
  ST r1,r0,#NAT_VP+1
  MOVI r2,3
  BOOL.8 r1,r1,r2
  CMP r1,r0
  JMP[NE] @nat_vp_fail
  LD r1,r0,#NAT_VP+1
  SHR r1,r1,2
  JMP @nat_vp_out
nat_vp_fail:
  MOVI r1,0
nat_vp_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nattn_rope r1=vec r2=table r3=pos r4=pairs -> 0/-1
; y0 = x0*c - x1*s; y1 = x0*s + x1*c, pair i at vec[2i].
nattn_rope:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NAT_RP+0
  ST r2,r0,#NAT_RP+1
  ST r3,r0,#NAT_RP+2
  ST r4,r0,#NAT_RP+3
  CMP r4,r0
  JMP[LE] @nat_rp_bad
  MOVI r2,32
  CMP r4,r2
  JMP[GT] @nat_rp_bad
  LD r8,r0,#NAT_RP+0
  LD r9,r0,#NAT_RP+1
  LD r10,r0,#NAT_RP+2
  LD r11,r0,#NAT_RP+3
  MOVI r12,0
nat_rp_l:
  CMP r12,r11
  JMP[GE] @nat_rp_ok
  ; table index = (pos*pairs + i)*2
  MUL r5,r10,r11
  ADD r5,r5,r12
  SHL r5,r5,1
  ADD r5,r9,r5
  LD r1,r5,0                  ; c
  LD r2,r5,1                  ; s
  SHL r5,r12,1
  ADD r5,r8,r5
  LD r3,r5,0                  ; x0
  LD r4,r5,1                  ; x1
  FMUL r6,r3,r1               ; x0*c
  FMUL r7,r4,r2               ; x1*s
  FSUB r6,r6,r7               ; y0
  FMUL r7,r3,r2               ; x0*s
  FMUL r3,r4,r1               ; x1*c
  FADD r7,r7,r3               ; y1
  ST r6,r5,0
  ST r7,r5,1
  ADD r12,r12,r13
  JMP @nat_rp_l
nat_rp_ok:
  MOVI r1,0
  JMP @nat_rp_out
nat_rp_bad:
  LA r1,0xFFFFFFFF
nat_rp_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nattn_softmax r1=scores r2=n r3=out -> 0/-1
; max-shifted f32 softmax: out[i] = exp(scores[i]-max)/sum(exp(...)).
; Exact 1/n for equal scores and exact one-hot for a >=104 logit gap.
nattn_softmax:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NAT_SM+0
  ST r2,r0,#NAT_SM+1
  ST r3,r0,#NAT_SM+2
  CMP r2,r0
  JMP[LE] @nat_sm_bad
  MOVI r3,#NAT_MAX_T
  CMP r2,r3
  JMP[GT] @nat_sm_bad
  LD r8,r0,#NAT_SM+0
  LD r9,r0,#NAT_SM+2
  LD r10,r0,#NAT_SM+1

  ; max = scores[0]
  LD r11,r8,0
  MOVI r12,1
nat_sm_max:
  CMP r12,r10
  JMP[GE] @nat_sm_maxd
  ADD r1,r8,r12
  LD r1,r1,0
  FCMP r1,r11
  JMP[GT] @nat_sm_up
  ADD r12,r12,r13
  JMP @nat_sm_max
nat_sm_up:
  ADD r11,r1,r0
  ADD r12,r12,r13
  JMP @nat_sm_max
nat_sm_maxd:

  ; sum and exp
  MOVI r6,0
  MOVI r12,0
nat_sm_exp:
  CMP r12,r10
  JMP[GE] @nat_sm_expd
  ADD r1,r8,r12
  LD r1,r1,0
  FSUB r1,r1,r11
  FEXP r1,r1
  ADD r2,r9,r12
  ST r1,r2,0
  FADD r6,r6,r1
  ADD r12,r12,r13
  JMP @nat_sm_exp
nat_sm_expd:
  MOVI r12,0
nat_sm_div:
  CMP r12,r10
  JMP[GE] @nat_sm_ok
  ADD r2,r9,r12
  LD r1,r2,0
  FDIV r1,r1,r6
  ST r1,r2,0
  ADD r12,r12,r13
  JMP @nat_sm_div
nat_sm_ok:
  MOVI r1,0
  JMP @nat_sm_out
nat_sm_bad:
  LA r1,0xFFFFFFFF
nat_sm_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nattn_qk_fused r1=q4 blocks r2=q8 blocks r3=nblocks -> r1=f32 dot bits
; Accumulates the signed integer dot per 32-weight block, then multiplies by
; scale4*scale8 once.  Byte order is nq4's little-endian packed bytes.
nattn_qk_fused:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NAT_QK+0
  ST r2,r0,#NAT_QK+1
  ST r3,r0,#NAT_QK+2
  CMP r3,r0
  JMP[LE] @nat_qk_zero
  MOVI r1,0
  ST r1,r0,#NAT_QK+8          ; acc
  ST r0,r0,#NAT_QK+3          ; b
nat_qk_b:
  LD r1,r0,#NAT_QK+3
  LD r2,r0,#NAT_QK+2
  CMP r1,r2
  JMP[GE] @nat_qk_done
  MOVI r5,5
  MUL r3,r1,r5
  LD r4,r0,#NAT_QK+0
  ADD r3,r4,r3
  ST r3,r0,#NAT_QK+4
  MOVI r5,9
  MUL r3,r1,r5
  LD r4,r0,#NAT_QK+1
  ADD r3,r4,r3
  ST r3,r0,#NAT_QK+5
  LD r4,r0,#NAT_QK+4
  LD r4,r4,0
  ST r4,r0,#NAT_QK+9          ; s4
  LD r4,r0,#NAT_QK+5
  LD r4,r4,0
  ST r4,r0,#NAT_QK+10         ; s8
  ST r0,r0,#NAT_QK+7          ; isum
  ST r0,r0,#NAT_QK+6          ; j
nat_qk_j:
  LD r1,r0,#NAT_QK+6
  MOVI r2,32
  CMP r1,r2
  JMP[GE] @nat_qk_blk
  MOVI r2,16
  CMP r1,r2
  JMP[GE] @nat_qk_hi

  ; low nibble: byte index = j
  LD r3,r0,#NAT_QK+4
  SHR r4,r1,2
  ADDI r4,r4,1
  ADD r3,r3,r4
  LD r2,r3,0
  MOVI r4,3
  BOOL.8 r5,r1,r4
  ADD r1,r2,r0
  ADD r2,r5,r0
  CALL @nq_byte
  MOVI r2,15
  BOOL.8 r1,r1,r2
  JMP @nat_qk_have

nat_qk_hi:
  MOVI r2,16
  SUB r3,r1,r2
  LD r4,r0,#NAT_QK+4
  SHR r5,r3,2
  ADDI r5,r5,1
  ADD r4,r4,r5
  LD r2,r4,0
  MOVI r4,3
  BOOL.8 r5,r3,r4
  ADD r1,r2,r0
  ADD r2,r5,r0
  CALL @nq_byte
  SHR r1,r1,4

nat_qk_have:
  ADDI r1,r1,-8
  ST r1,r0,#NAT_QK+11         ; q4 value

  ; Q8 byte j
  LD r1,r0,#NAT_QK+6
  LD r3,r0,#NAT_QK+5
  SHR r4,r1,2
  ADDI r4,r4,1
  ADD r3,r3,r4
  LD r2,r3,0
  MOVI r4,3
  BOOL.8 r5,r1,r4
  ADD r1,r2,r0
  ADD r2,r5,r0
  CALL @nq_byte
  MOVI r2,128
  CMP r1,r2
  JMP[LT] @nat_qk_pos
  ADDI r1,r1,-256
nat_qk_pos:
  LD r2,r0,#NAT_QK+11
  MUL r1,r1,r2
  LD r2,r0,#NAT_QK+7
  ADD r2,r2,r1
  ST r2,r0,#NAT_QK+7
  LD r1,r0,#NAT_QK+6
  ADD r1,r1,r13
  ST r1,r0,#NAT_QK+6
  JMP @nat_qk_j

nat_qk_blk:
  LD r1,r0,#NAT_QK+7
  CVTIF r1,r1
  LD r2,r0,#NAT_QK+9
  LD r3,r0,#NAT_QK+10
  FMUL r2,r2,r3
  FMUL r1,r1,r2
  LD r2,r0,#NAT_QK+8
  FADD r1,r1,r2
  ST r1,r0,#NAT_QK+8
  LD r1,r0,#NAT_QK+3
  ADD r1,r1,r13
  ST r1,r0,#NAT_QK+3
  JMP @nat_qk_b
nat_qk_done:
  LD r1,r0,#NAT_QK+8
  JMP @nat_qk_out
nat_qk_zero:
  MOVI r1,0
nat_qk_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nattn_quant_q4 r1=src f32 r2=dst blocks r3=cols r4=scale bits -> 0/-1
; q = trunc(src/scale), clamp [-8,7], nibble = q+8.  Exact for integers.
nattn_quant_q4:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NAT_QT+0
  ST r2,r0,#NAT_QT+1
  ST r3,r0,#NAT_QT+2
  ST r4,r0,#NAT_QT+3
  CMP r3,r0
  JMP[LE] @nat_q4_bad
  MOVI r6,64
  CMP r3,r6
  JMP[GT] @nat_q4_bad
  MOVI r6,31
  BOOL.8 r6,r3,r6
  CMP r6,r0
  JMP[NE] @nat_q4_bad
  SHR r6,r3,5
  ST r6,r0,#NAT_QT+6
  ST r0,r0,#NAT_QT+4
nat_q4_b:
  LD r1,r0,#NAT_QT+4
  LD r2,r0,#NAT_QT+6
  CMP r1,r2
  JMP[GE] @nat_q4_ok
  ; dst[0] = scale; zero 16 byte slots
  LD r9,r0,#NAT_QT+1
  LD r7,r0,#NAT_QT+3
  ST r7,r9,0
  MOVI r5,0
  LA r6,#NAT_BYTES
nat_q4_zb:
  MOVI r8,16
  CMP r5,r8
  JMP[GE] @nat_q4_zd
  ADD r8,r6,r5
  ST r0,r8,0
  ADD r5,r5,r13
  JMP @nat_q4_zb
nat_q4_zd:
  ; clear the rest of the scratch so Q8 packing never sees stale bytes
  LA r6,#NAT_BYTES
  MOVI r5,0
nat_q4_zc:
  MOVI r8,80
  CMP r5,r8
  JMP[GE] @nat_q4_zcd
  ADD r8,r6,r5
  ST r0,r8,0
  ADD r5,r5,r13
  JMP @nat_q4_zc
nat_q4_zcd:
  ST r0,r0,#NAT_QT+5
nat_q4_j:
  LD r1,r0,#NAT_QT+5
  MOVI r2,32
  CMP r1,r2
  JMP[GE] @nat_q4_pack
  ; src address = src + b*32 + j
  LD r2,r0,#NAT_QT+4
  SHL r2,r2,5
  ADD r2,r2,r1
  LD r3,r0,#NAT_QT+0
  ADD r2,r3,r2
  LD r1,r2,0
  LD r2,r0,#NAT_QT+3
  FDIV r1,r1,r2
  CVTFI r1,r1
  ; clamp [-8,7]
  MOVI r2,8
  SUB r2,r0,r2
  CMPS r1,r2
  JMP[LT] @nat_q4_low
  MOVI r2,7
  CMPS r1,r2
  JMP[GT] @nat_q4_high
  JMP @nat_q4_clamped
nat_q4_low:
  MOVI r1,8
  SUB r1,r0,r1
  JMP @nat_q4_clamped
nat_q4_high:
  MOVI r1,7
nat_q4_clamped:
  ADDI r1,r1,8
  ; p = j & 15; shift = (j>=16)?4:0
  LD r3,r0,#NAT_QT+5
  MOVI r4,15
  BOOL.8 r4,r3,r4
  MOVI r5,15
  CMP r3,r5
  JMP[LE] @nat_q4_lo
  SHL r1,r1,4
nat_q4_lo:
  LA r5,#NAT_BYTES
  ADD r5,r5,r4
  LD r6,r5,0
  BOOL.14 r6,r6,r1
  ST r6,r5,0
  LD r1,r0,#NAT_QT+5
  ADD r1,r1,r13
  ST r1,r0,#NAT_QT+5
  JMP @nat_q4_j

nat_q4_pack:
  MOVI r5,0
nat_q4_pw:
  MOVI r6,4
  CMP r5,r6
  JMP[GE] @nat_q4_next
  ; word = b0 | b1<<8 | b2<<16 | b3<<24
  SHL r6,r5,2
  LA r7,#NAT_BYTES
  ADD r7,r7,r6
  LD r1,r7,0
  LD r2,r7,1
  SHL r2,r2,8
  BOOL.14 r1,r1,r2
  LD r2,r7,2
  SHL r2,r2,16
  BOOL.14 r1,r1,r2
  LD r2,r7,3
  SHL r2,r2,24
  BOOL.14 r1,r1,r2
  LD r8,r0,#NAT_QT+1
  ADDI r8,r8,1
  ADD r8,r8,r5
  ST r1,r8,0
  ADD r5,r5,r13
  JMP @nat_q4_pw
nat_q4_next:
  LD r9,r0,#NAT_QT+1
  ADDI r9,r9,5
  ST r9,r0,#NAT_QT+1
  LD r1,r0,#NAT_QT+4
  ADD r1,r1,r13
  ST r1,r0,#NAT_QT+4
  JMP @nat_q4_b
nat_q4_ok:
  MOVI r1,0
  JMP @nat_q4_out
nat_q4_bad:
  LA r1,0xFFFFFFFF
nat_q4_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nattn_quant_q8 r1=src f32 r2=dst blocks r3=cols r4=scale -> 0/-1
; q = trunc(src/scale), clamp [-128,127], stored as a signed byte.
nattn_quant_q8:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NAT_QT+0
  ST r2,r0,#NAT_QT+1
  ST r3,r0,#NAT_QT+2
  ST r4,r0,#NAT_QT+3
  CMP r3,r0
  JMP[LE] @nat_q8_bad
  MOVI r6,64
  CMP r3,r6
  JMP[GT] @nat_q8_bad
  MOVI r6,31
  BOOL.8 r6,r3,r6
  CMP r6,r0
  JMP[NE] @nat_q8_bad
  SHR r6,r3,5
  ST r6,r0,#NAT_QT+6
  ST r0,r0,#NAT_QT+4
nat_q8_b:
  LD r1,r0,#NAT_QT+4
  LD r2,r0,#NAT_QT+6
  CMP r1,r2
  JMP[GE] @nat_q8_ok
  LD r9,r0,#NAT_QT+1
  LD r7,r0,#NAT_QT+3
  ST r7,r9,0
  LA r6,#NAT_BYTES
  MOVI r5,0
nat_q8_zb:
  MOVI r8,80
  CMP r5,r8
  JMP[GE] @nat_q8_zd
  ADD r8,r6,r5
  ST r0,r8,0
  ADD r5,r5,r13
  JMP @nat_q8_zb
nat_q8_zd:
  ST r0,r0,#NAT_QT+5
nat_q8_j:
  LD r1,r0,#NAT_QT+5
  MOVI r2,32
  CMP r1,r2
  JMP[GE] @nat_q8_pack
  LD r2,r0,#NAT_QT+4
  SHL r2,r2,5
  ADD r2,r2,r1
  LD r3,r0,#NAT_QT+0
  ADD r2,r3,r2
  LD r1,r2,0
  LD r2,r0,#NAT_QT+3
  FDIV r1,r1,r2
  CVTFI r1,r1
  MOVI r2,128
  SUB r2,r0,r2
  CMPS r1,r2
  JMP[LT] @nat_q8_low
  MOVI r2,127
  CMPS r1,r2
  JMP[GT] @nat_q8_high
  JMP @nat_q8_clamped
nat_q8_low:
  MOVI r1,128
  SUB r1,r0,r1
  JMP @nat_q8_clamped
nat_q8_high:
  MOVI r1,127
nat_q8_clamped:
  MOVI r2,0xFF
  BOOL.8 r1,r1,r2
  LD r3,r0,#NAT_QT+5
  LA r5,#NAT_BYTES
  ADD r5,r5,r3
  ST r1,r5,0
  LD r1,r0,#NAT_QT+5
  ADD r1,r1,r13
  ST r1,r0,#NAT_QT+5
  JMP @nat_q8_j

nat_q8_pack:
  MOVI r5,0
nat_q8_pw:
  MOVI r6,8
  CMP r5,r6
  JMP[GE] @nat_q8_next
  SHL r6,r5,2
  LA r7,#NAT_BYTES
  ADD r7,r7,r6
  LD r1,r7,0
  LD r2,r7,1
  SHL r2,r2,8
  BOOL.14 r1,r1,r2
  LD r2,r7,2
  SHL r2,r2,16
  BOOL.14 r1,r1,r2
  LD r2,r7,3
  SHL r2,r2,24
  BOOL.14 r1,r1,r2
  LD r8,r0,#NAT_QT+1
  ADDI r8,r8,1
  ADD r8,r8,r5
  ST r1,r8,0
  ADD r5,r5,r13
  JMP @nat_q8_pw
nat_q8_next:
  LD r9,r0,#NAT_QT+1
  ADDI r9,r9,9
  ST r9,r0,#NAT_QT+1
  LD r1,r0,#NAT_QT+4
  ADD r1,r1,r13
  ST r1,r0,#NAT_QT+4
  JMP @nat_q8_b
nat_q8_ok:
  MOVI r1,0
  JMP @nat_q8_out
nat_q8_bad:
  LA r1,0xFFFFFFFF
nat_q8_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nattn_matvec_q4 r1=w r2=rows r3=cols r4=x r5=out -> 0/-1
nattn_matvec_q4:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NAT_MV+0
  ST r2,r0,#NAT_MV+1
  ST r3,r0,#NAT_MV+2
  ST r4,r0,#NAT_MV+3
  ST r5,r0,#NAT_MV+4
  CMP r2,r0
  JMP[LE] @nat_mv4_bad
  CMP r3,r0
  JMP[LE] @nat_mv4_bad
  MOVI r6,64
  CMP r3,r6
  JMP[GT] @nat_mv4_bad
  MOVI r6,31
  BOOL.8 r6,r3,r6
  CMP r6,r0
  JMP[NE] @nat_mv4_bad
  SHR r6,r3,5
  ST r6,r0,#NAT_MV+5
  ST r0,r0,#NAT_MV+6
nat_mv4_row:
  LD r1,r0,#NAT_MV+6
  LD r2,r0,#NAT_MV+1
  CMP r1,r2
  JMP[GE] @nat_mv4_ok
  MOVI r2,0
  ST r2,r0,#NAT_MV+8
  ST r0,r0,#NAT_MV+7
nat_mv4_blk:
  LD r1,r0,#NAT_MV+7
  LD r2,r0,#NAT_MV+5
  CMP r1,r2
  JMP[GE] @nat_mv4_rowd
  ; block = w + (r*nblocks + b)*5
  LD r2,r0,#NAT_MV+6
  LD r5,r0,#NAT_MV+5
  MUL r2,r2,r5
  ADD r2,r2,r1
  MOVI r5,5
  MUL r2,r2,r5
  LD r3,r0,#NAT_MV+0
  ADD r3,r3,r2
  ; acts = x + b*32
  SHL r2,r1,5
  LD r4,r0,#NAT_MV+3
  ADD r2,r4,r2
  ADD r1,r3,r0
  CALL @nq4_dot32
  LD r2,r0,#NAT_MV+8
  FADD r1,r1,r2
  ST r1,r0,#NAT_MV+8
  LD r1,r0,#NAT_MV+7
  ADD r1,r1,r13
  ST r1,r0,#NAT_MV+7
  JMP @nat_mv4_blk
nat_mv4_rowd:
  LD r1,r0,#NAT_MV+4
  LD r2,r0,#NAT_MV+6
  ADD r1,r1,r2
  LD r2,r0,#NAT_MV+8
  ST r2,r1,0
  LD r1,r0,#NAT_MV+6
  ADD r1,r1,r13
  ST r1,r0,#NAT_MV+6
  JMP @nat_mv4_row
nat_mv4_ok:
  MOVI r1,0
  JMP @nat_mv4_out
nat_mv4_bad:
  LA r1,0xFFFFFFFF
nat_mv4_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nattn_matvec_q8 r1=w r2=rows r3=cols r4=x r5=out -> 0/-1
nattn_matvec_q8:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NAT_MV+0
  ST r2,r0,#NAT_MV+1
  ST r3,r0,#NAT_MV+2
  ST r4,r0,#NAT_MV+3
  ST r5,r0,#NAT_MV+4
  CMP r2,r0
  JMP[LE] @nat_mv8_bad
  CMP r3,r0
  JMP[LE] @nat_mv8_bad
  MOVI r6,64
  CMP r3,r6
  JMP[GT] @nat_mv8_bad
  MOVI r6,31
  BOOL.8 r6,r3,r6
  CMP r6,r0
  JMP[NE] @nat_mv8_bad
  SHR r6,r3,5
  ST r6,r0,#NAT_MV+5
  ST r0,r0,#NAT_MV+6
nat_mv8_row:
  LD r1,r0,#NAT_MV+6
  LD r2,r0,#NAT_MV+1
  CMP r1,r2
  JMP[GE] @nat_mv8_ok
  MOVI r2,0
  ST r2,r0,#NAT_MV+8
  ST r0,r0,#NAT_MV+7
nat_mv8_blk:
  LD r1,r0,#NAT_MV+7
  LD r2,r0,#NAT_MV+5
  CMP r1,r2
  JMP[GE] @nat_mv8_rowd
  LD r2,r0,#NAT_MV+6
  LD r5,r0,#NAT_MV+5
  MUL r2,r2,r5
  ADD r2,r2,r1
  MOVI r5,9
  MUL r2,r2,r5
  LD r3,r0,#NAT_MV+0
  ADD r3,r3,r2
  SHL r2,r1,5
  LD r4,r0,#NAT_MV+3
  ADD r2,r4,r2
  ADD r1,r3,r0
  CALL @nq8_dot32
  LD r2,r0,#NAT_MV+8
  FADD r1,r1,r2
  ST r1,r0,#NAT_MV+8
  LD r1,r0,#NAT_MV+7
  ADD r1,r1,r13
  ST r1,r0,#NAT_MV+7
  JMP @nat_mv8_blk
nat_mv8_rowd:
  LD r1,r0,#NAT_MV+4
  LD r2,r0,#NAT_MV+6
  ADD r1,r1,r2
  LD r2,r0,#NAT_MV+8
  ST r2,r1,0
  LD r1,r0,#NAT_MV+6
  ADD r1,r1,r13
  ST r1,r0,#NAT_MV+6
  JMP @nat_mv8_row
nat_mv8_ok:
  MOVI r1,0
  JMP @nat_mv8_out
nat_mv8_bad:
  LA r1,0xFFFFFFFF
nat_mv8_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nat_cfg r1=cfg -> 0/-1; fills the NAT_* persistent fields.
nat_cfg:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NAT_TMP
  LD r2,r1,0
  LA r3,#NATT_MAGIC
  CMP r2,r3
  JMP[NE] @nat_cfg_bad
  LD r2,r1,1
  MOVI r3,#NATT_VERSION
  CMP r2,r3
  JMP[NE] @nat_cfg_bad
  LD r2,r1,2
  CMP r2,r0
  JMP[LE] @nat_cfg_bad
  MOVI r3,#NAT_MAX_T
  CMP r2,r3
  JMP[GT] @nat_cfg_bad
  ST r2,r0,#NAT_N
  LD r2,r1,3
  MOVI r3,32
  CMP r2,r3
  JMP[LT] @nat_cfg_bad
  MOVI r3,#NAT_MAX_DIM
  CMP r2,r3
  JMP[GT] @nat_cfg_bad
  MOVI r3,31
  BOOL.8 r3,r2,r3
  CMP r3,r0
  JMP[NE] @nat_cfg_bad
  ST r2,r0,#NAT_DIM
  SHR r2,r2,5
  ST r2,r0,#NAT_NB
  LD r2,r1,4
  ST r2,r0,#NAT_FLAGS
  LD r2,r1,5
  CMP r2,r0
  JMP[EQ] @nat_cfg_bad
  ST r2,r0,#NAT_WQ
  LD r2,r1,6
  CMP r2,r0
  JMP[EQ] @nat_cfg_bad
  ST r2,r0,#NAT_WK
  LD r2,r1,7
  CMP r2,r0
  JMP[EQ] @nat_cfg_bad
  ST r2,r0,#NAT_WV
  LD r2,r1,8
  CMP r2,r0
  JMP[EQ] @nat_cfg_bad
  ST r2,r0,#NAT_WO
  LD r2,r1,9
  ST r2,r0,#NAT_ROPE
  LD r3,r1,4
  MOVI r4,1
  BOOL.8 r3,r3,r4
  CMP r3,r0
  JMP[EQ] @nat_cfg_norope
  CMP r2,r0
  JMP[EQ] @nat_cfg_bad
nat_cfg_norope:
  LD r2,r1,10
  ST r2,r0,#NAT_SCALE
  LD r2,r1,11
  CMP r2,r0
  JMP[EQ] @nat_cfg_bad
  ST r2,r0,#NAT_NW
  LD r2,r1,12
  ST r2,r0,#NAT_EPS
  LD r2,r1,13
  CMP r2,r0
  JMP[EQ] @nat_cfg_bad
  ST r2,r0,#NAT_Q4B
  LD r2,r1,14
  CMP r2,r0
  JMP[EQ] @nat_cfg_bad
  ST r2,r0,#NAT_Q8B
  LD r2,r1,15
  ST r2,r0,#NAT_Q4S
  LD r2,r1,16
  ST r2,r0,#NAT_Q8S
  MOVI r1,0
  JMP @nat_cfg_out
nat_cfg_bad:
  LA r1,0xFFFFFFFF
nat_cfg_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nattn_forward r1=cfg r2=token views -> 0/-1
nattn_forward:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NAT_FW+0
  ST r2,r0,#NAT_FW+1
  CALL @nat_cfg
  CMP r1,r0
  JMP[NE] @nat_fw_bad
  LD r1,r0,#NAT_FW+1
  CMP r1,r0
  JMP[EQ] @nat_fw_bad

  ; ---- pass 1: project and quantize Q/K, project V
  ST r0,r0,#NAT_T
nat_fw_p1:
  LD r1,r0,#NAT_T
  LD r2,r0,#NAT_N
  CMP r1,r2
  JMP[GE] @nat_fw_p1d
  ; view address = views + t*24
  MOVI r4,24
  MUL r3,r1,r4
  LD r2,r0,#NAT_FW+1
  ADD r3,r2,r3
  ST r3,r0,#NAT_TMP
  ADD r1,r3,r0
  CALL @nattn_view_ptr
  CMP r1,r0
  JMP[EQ] @nat_fw_bad
  ST r1,r0,#NAT_VP0
  ; count >= 3*dim
  LD r2,r0,#NAT_TMP
  LD r3,r2,#NKV_V_COUNT
  LD r4,r2,#NKV_V_COUNT+1
  CMP r4,r0
  JMP[NE] @nat_fw_bad
  LD r5,r0,#NAT_DIM
  MOVI r4,3
  MUL r5,r5,r4
  CMP r3,r5
  JMP[LT] @nat_fw_bad

  ; q = Wq*x -> NAT_H
  LD r1,r0,#NAT_WQ
  LD r2,r0,#NAT_DIM
  ADD r3,r2,r0
  LD r4,r0,#NAT_VP0
  LA r5,#NAT_H
  CALL @nattn_matvec_q4
  CMP r1,r0
  JMP[NE] @nat_fw_bad
  ; RoPE q
  LD r1,r0,#NAT_FLAGS
  MOVI r2,1
  BOOL.8 r1,r1,r2
  CMP r1,r0
  JMP[EQ] @nat_fw_qrope_d
  LA r1,#NAT_H
  LD r2,r0,#NAT_ROPE
  LD r3,r0,#NAT_T
  LD r4,r0,#NAT_DIM
  SHR r4,r4,1
  CALL @nattn_rope
  CMP r1,r0
  JMP[NE] @nat_fw_bad
nat_fw_qrope_d:
  ; quantize q -> Q4 cache at q4buf + t*nb*5
  LD r2,r0,#NAT_Q4B
  LD r3,r0,#NAT_NB
  MOVI r5,5
  MUL r3,r3,r5
  LD r4,r0,#NAT_T
  MUL r3,r3,r4
  ADD r2,r2,r3
  LA r1,#NAT_H
  LD r3,r0,#NAT_DIM
  LD r4,r0,#NAT_Q4S
  CALL @nattn_quant_q4
  CMP r1,r0
  JMP[NE] @nat_fw_bad

  ; k = Wk*x -> NAT_KSCR
  LD r1,r0,#NAT_WK
  LD r2,r0,#NAT_DIM
  ADD r3,r2,r0
  LD r4,r0,#NAT_VP0
  LA r5,#NAT_KSCR
  CALL @nattn_matvec_q8
  CMP r1,r0
  JMP[NE] @nat_fw_bad
  LD r1,r0,#NAT_FLAGS
  MOVI r2,1
  BOOL.8 r1,r1,r2
  CMP r1,r0
  JMP[EQ] @nat_fw_krope_d
  LA r1,#NAT_KSCR
  LD r2,r0,#NAT_ROPE
  LD r3,r0,#NAT_T
  LD r4,r0,#NAT_DIM
  SHR r4,r4,1
  CALL @nattn_rope
  CMP r1,r0
  JMP[NE] @nat_fw_bad
nat_fw_krope_d:
  LD r2,r0,#NAT_Q8B
  LD r3,r0,#NAT_NB
  MOVI r5,9
  MUL r3,r3,r5
  LD r4,r0,#NAT_T
  MUL r3,r3,r4
  ADD r2,r2,r3
  LA r1,#NAT_KSCR
  LD r3,r0,#NAT_DIM
  LD r4,r0,#NAT_Q8S
  CALL @nattn_quant_q8
  CMP r1,r0
  JMP[NE] @nat_fw_bad

  ; v = Wv*x -> view + dim
  LD r1,r0,#NAT_WV
  LD r2,r0,#NAT_DIM
  ADD r3,r2,r0
  LD r4,r0,#NAT_VP0
  ADD r5,r4,r2
  CALL @nattn_matvec_q4
  CMP r1,r0
  JMP[NE] @nat_fw_bad

  LD r1,r0,#NAT_T
  ADD r1,r1,r13
  ST r1,r0,#NAT_T
  JMP @nat_fw_p1
nat_fw_p1d:

  ; ---- pass 2: scores, softmax, context
  ST r0,r0,#NAT_T
nat_fw_p2:
  LD r1,r0,#NAT_T
  LD r2,r0,#NAT_N
  CMP r1,r2
  JMP[GE] @nat_fw_ok
  ; row = NAT_SCORES + t*NAT_MAX_T
  MOVI r4,#NAT_MAX_T
  MUL r3,r1,r4
  LA r4,#NAT_SCORES
  ADD r3,r4,r3
  ST r3,r0,#NAT_ROW
  ; token t view, q cache pointer
  MOVI r4,24
  MUL r3,r1,r4
  LD r2,r0,#NAT_FW+1
  ADD r3,r2,r3
  ADD r1,r3,r0
  CALL @nattn_view_ptr
  CMP r1,r0
  JMP[EQ] @nat_fw_bad
  ST r1,r0,#NAT_VP0
  LD r2,r0,#NAT_Q4B
  LD r3,r0,#NAT_NB
  MOVI r5,5
  MUL r3,r3,r5
  LD r4,r0,#NAT_T
  MUL r3,r3,r4
  ADD r2,r2,r3
  ST r2,r0,#NAT_QP

  ST r0,r0,#NAT_S
nat_fw_sc:
  LD r1,r0,#NAT_S
  LD r2,r0,#NAT_T
  CMP r1,r2
  JMP[GT] @nat_fw_smd
  ; token s view -> v address
  MOVI r4,24
  MUL r3,r1,r4
  LD r2,r0,#NAT_FW+1
  ADD r3,r2,r3
  ADD r1,r3,r0
  CALL @nattn_view_ptr
  CMP r1,r0
  JMP[EQ] @nat_fw_bad
  ST r1,r0,#NAT_TMP
  ; k cache pointer for token s
  LD r2,r0,#NAT_Q8B
  LD r3,r0,#NAT_NB
  MOVI r5,9
  MUL r3,r3,r5
  LD r4,r0,#NAT_S
  MUL r3,r3,r4
  ADD r2,r2,r3
  ; fused(q[t], k[s])
  LD r1,r0,#NAT_QP
  LD r3,r0,#NAT_NB
  CALL @nattn_qk_fused
  LD r2,r0,#NAT_SCALE
  FMUL r1,r1,r2
  LD r2,r0,#NAT_ROW
  LD r3,r0,#NAT_S
  ADD r2,r2,r3
  ST r1,r2,0
  LD r1,r0,#NAT_S
  ADD r1,r1,r13
  ST r1,r0,#NAT_S
  JMP @nat_fw_sc
nat_fw_smd:
  ; softmax over t+1 scores in place
  LD r1,r0,#NAT_ROW
  LD r2,r0,#NAT_T
  ADD r2,r2,r13
  ADD r3,r1,r0
  CALL @nattn_softmax
  CMP r1,r0
  JMP[NE] @nat_fw_bad

  ; zero ctx (view t + 2*dim)
  LD r1,r0,#NAT_VP0
  LD r2,r0,#NAT_DIM
  SHL r3,r2,1
  ADD r1,r1,r3
  ST r1,r0,#NAT_CP
  MOVI r2,0
nat_fw_zc:
  LD r3,r0,#NAT_DIM
  CMP r2,r3
  JMP[GE] @nat_fw_zcd
  ST r0,r1,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  JMP @nat_fw_zc
nat_fw_zcd:
  ST r0,r0,#NAT_S
nat_fw_as:
  LD r1,r0,#NAT_S
  LD r2,r0,#NAT_T
  CMP r1,r2
  JMP[GT] @nat_fw_asd
  LD r2,r0,#NAT_ROW
  ADD r2,r2,r1
  LD r2,r2,0
  ST r2,r0,#NAT_WT
  ; token s view -> v address
  MOVI r4,24
  MUL r3,r1,r4
  LD r2,r0,#NAT_FW+1
  ADD r3,r2,r3
  ADD r1,r3,r0
  CALL @nattn_view_ptr
  CMP r1,r0
  JMP[EQ] @nat_fw_bad
  LD r2,r0,#NAT_DIM
  ADD r1,r1,r2
  ST r1,r0,#NAT_KP
  LD r1,r0,#NAT_CP
  ST r1,r0,#NAT_TMP
  MOVI r2,0
nat_fw_ad:
  LD r3,r0,#NAT_DIM
  CMP r2,r3
  JMP[GE] @nat_fw_add
  LD r4,r0,#NAT_KP
  ADD r4,r4,r2
  LD r4,r4,0
  LD r5,r0,#NAT_WT
  FMUL r4,r4,r5
  LD r5,r0,#NAT_TMP
  LD r6,r5,0
  FADD r6,r6,r4
  ST r6,r5,0
  ADD r5,r5,r13
  ST r5,r0,#NAT_TMP
  ADD r2,r2,r13
  JMP @nat_fw_ad
nat_fw_add:
  LD r1,r0,#NAT_S
  ADD r1,r1,r13
  ST r1,r0,#NAT_S
  JMP @nat_fw_as
nat_fw_asd:
  LD r1,r0,#NAT_T
  ADD r1,r1,r13
  ST r1,r0,#NAT_T
  JMP @nat_fw_p2
nat_fw_ok:
  MOVI r1,0
  JMP @nat_fw_out
nat_fw_bad:
  LA r1,0xFFFFFFFF
nat_fw_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nat_rmsnorm r1=x r2=w r3=dim r4=eps r5=out -> 0/-1
nat_rmsnorm:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NAT_MV+0
  ST r2,r0,#NAT_MV+1
  ST r3,r0,#NAT_MV+2
  ST r4,r0,#NAT_MV+3
  ST r5,r0,#NAT_MV+4
  CMP r3,r0
  JMP[LE] @nat_rn_bad
  MOVI r6,#NAT_MAX_DIM
  CMP r3,r6
  JMP[GT] @nat_rn_bad
  MOVI r6,0
  ST r6,r0,#NAT_MV+5
  MOVI r7,0
nat_rn_l1:
  CMP r7,r3
  JMP[GE] @nat_rn_l1d
  ADD r1,r1,r7
  LD r1,r1,0
  FMUL r1,r1,r1
  LD r2,r0,#NAT_MV+5
  FADD r2,r2,r1
  ST r2,r0,#NAT_MV+5
  ADD r7,r7,r13
  LD r1,r0,#NAT_MV+0
  LD r3,r0,#NAT_MV+2
  JMP @nat_rn_l1
nat_rn_l1d:
  LD r1,r0,#NAT_MV+5
  LD r2,r0,#NAT_MV+2
  CVTIF r2,r2
  FDIV r1,r1,r2
  LD r2,r0,#NAT_MV+3
  FADD r1,r1,r2
  FSQRT r1,r1
  ST r1,r0,#NAT_MV+6
  MOVI r7,0
nat_rn_l2:
  LD r3,r0,#NAT_MV+2
  CMP r7,r3
  JMP[GE] @nat_rn_ok
  LD r1,r0,#NAT_MV+0
  ADD r1,r1,r7
  LD r1,r1,0
  LD r2,r0,#NAT_MV+6
  FDIV r1,r1,r2
  LD r4,r0,#NAT_MV+1
  ADD r4,r4,r7
  LD r4,r4,0
  FMUL r1,r1,r4
  LD r5,r0,#NAT_MV+4
  ADD r5,r5,r7
  ST r1,r5,0
  ADD r7,r7,r13
  JMP @nat_rn_l2
nat_rn_ok:
  MOVI r1,0
  JMP @nat_rn_out
nat_rn_bad:
  LA r1,0xFFFFFFFF
nat_rn_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nattn_last_logits r1=cfg r2=views r3=logits -> 0/-1
nattn_last_logits:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NAT_FW+0
  ST r2,r0,#NAT_FW+1
  ST r3,r0,#NAT_FW+2
  CALL @nat_cfg
  CMP r1,r0
  JMP[NE] @nat_ll_bad
  LD r1,r0,#NAT_FW+1
  CMP r1,r0
  JMP[EQ] @nat_ll_bad
  ; t = n-1; view -> ptr
  LD r1,r0,#NAT_N
  ADDI r1,r1,-1
  ST r1,r0,#NAT_T
  MOVI r4,24
  MUL r3,r1,r4
  LD r2,r0,#NAT_FW+1
  ADD r3,r2,r3
  ADD r1,r3,r0
  CALL @nattn_view_ptr
  CMP r1,r0
  JMP[EQ] @nat_ll_bad
  ST r1,r0,#NAT_VP0
  ; h = x + ctx (ctx at +2*dim)
  LD r2,r0,#NAT_DIM
  SHL r3,r2,1
  ADD r3,r1,r3
  MOVI r4,0
nat_ll_l:
  LD r5,r0,#NAT_DIM
  CMP r4,r5
  JMP[GE] @nat_ll_ld
  ADD r5,r1,r4
  LD r5,r5,0
  ADD r6,r3,r4
  LD r6,r6,0
  FADD r5,r5,r6
  LA r6,#NAT_H
  ADD r6,r6,r4
  ST r5,r6,0
  ADD r4,r4,r13
  JMP @nat_ll_l
nat_ll_ld:
  LA r1,#NAT_H
  LD r2,r0,#NAT_NW
  LD r3,r0,#NAT_DIM
  LD r4,r0,#NAT_EPS
  LA r5,#NAT_H
  CALL @nat_rmsnorm
  CMP r1,r0
  JMP[NE] @nat_ll_bad
  LD r1,r0,#NAT_WO
  LD r2,r0,#NAT_DIM
  ADD r3,r2,r0
  LA r4,#NAT_H
  LD r5,r0,#NAT_FW+2
  CALL @nattn_matvec_q4
  CMP r1,r0
  JMP[NE] @nat_ll_bad
  MOVI r1,0
  JMP @nat_ll_out
nat_ll_bad:
  LA r1,0xFFFFFFFF
nat_ll_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
