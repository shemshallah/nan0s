; nmodel_test.nas - RMSNorm + Q4/Q8 GEMV + deterministic sampler + tiny model.
;
; Model: vocab 4, dim 4, embeddings, RMSNorm weight [0.5,0.25,0.125,0.0625],
; one Q4_0 output projection (4 rows x 32 weights).  Average embeddings ->
; RMSNorm -> Q4 GEMV.  All values are exact binary fractions.
;
; Prompt [1,2] -> context [2,2,2,2] -> norm [0.5,0.25,0.125,0.0625] ->
; logits [1.625, 1.0, -0.5, 0.0625] -> argmax 0.
; Prompt [0]   -> context [-2,-2,-2,-2] -> norm [-0.5,-0.25,-0.125,-0.0625] ->
; logits [-1.625, -1.0, 0.5, -0.0625] -> argmax 2.
;
; Sampler: temp 0 is greedy with the seed unchanged; temp>0 uses xorshift32
; seeded by the caller.  Exact seed-1 next value 0x00042021; seed 0x12345678
; next value 0x87985AA5 picks the second of two equal top-k candidates.
; Success prints exactly O.
.org 0
JMP @main
.org 0x4000
.include "../lib/nmodel.nas"

main:
MOVI r13,1
MOVI r14,0x7000

; ---------------------------------------------------------------------------
; RMSNorm([2,2,2,2], [0.5,0.25,0.125,0.0625], 0) exact
MOVI r1,0x31
CALL @stage
LA r1,@rmsx
LA r2,@nw
MOVI r3,4
MOVI r4,0
LA r5,@rmsout
CALL @nmod_rmsnorm
CMP r1,r0
JMP[NE] @fail
LA r6,@rmsout
LD r1,r6,0
LA r2,0x3F000000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
LA r2,0x3E800000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,2
LA r2,0x3E000000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,3
LA r2,0x3D800000
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; Q4_0 GEMV over four rows -> exact logits
MOVI r1,0x32
CALL @stage
LA r1,@q4
MOVI r2,4
LA r3,@acts1
LA r4,@logits
CALL @nmod_gemv_q4
CMP r1,r0
JMP[NE] @fail
LA r6,@logits
LD r1,r6,0
LA r2,0x3FD00000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
LA r2,0x3F800000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,2
LA r2,0xBF000000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,3
LA r2,0x3D800000
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; Q8_0 GEMV: 0.5 * 2 * 1.0 = 1.0
MOVI r1,0x33
CALL @stage
LA r1,@q8
MOVI r2,1
LA r3,@acts2
LA r4,@logits2
CALL @nmod_gemv_q8
CMP r1,r0
JMP[NE] @fail
LA r6,@logits2
LD r1,r6,0
LA r2,0x3F800000
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; forward prompt [1,2] -> exact logits and token 0
MOVI r1,0x34
CALL @stage
LA r1,@md
LA r2,@ids12
MOVI r3,2
LA r4,@flog
CALL @nmod_forward
CMP r1,r0
JMP[NE] @fail
LA r6,@flog
LD r1,r6,0
LA r2,0x3FD00000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
LA r2,0x3F800000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,2
LA r2,0xBF000000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,3
LA r2,0x3D800000
CMP r1,r2
JMP[NE] @fail
LA r1,@flog
MOVI r2,4
CALL @nmod_argmax
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; forward prompt [0] -> exact logits and token 2
MOVI r1,0x35
CALL @stage
LA r1,@md
LA r2,@ids0
MOVI r3,1
LA r4,@flog
CALL @nmod_forward
CMP r1,r0
JMP[NE] @fail
LA r6,@flog
LD r1,r6,0
LA r2,0xBFD00000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
LA r2,0xBF800000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,2
LA r2,0x3F000000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,3
LA r2,0xBD800000
CMP r1,r2
JMP[NE] @fail
LA r1,@flog
MOVI r2,4
CALL @nmod_argmax
MOVI r2,2
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; greedy: temp 0 returns argmax and leaves the seed unchanged
MOVI r1,0x36
CALL @stage
LA r1,@glog
MOVI r2,4
MOVI r3,0
MOVI r4,4
MOVI r5,1
CALL @nmod_sample
CMP r1,r0
JMP[NE] @fail
MOVI r3,1
CMP r2,r3
JMP[NE] @fail

; ---------------------------------------------------------------------------
; seeded top-k
MOVI r1,0x37
CALL @stage
MOVI r1,1
CALL @nmod_xorshift
LA r2,0x00042021
CMP r1,r2
JMP[NE] @fail
LA r1,0x12345678
CALL @nmod_xorshift
LA r2,0x87985AA5
CMP r1,r2
JMP[NE] @fail
; topk 1, temp 0.5, seed 1 -> token 0, next seed 0x00042021
LA r1,@glog
MOVI r2,4
LA r3,0x3F000000
MOVI r4,1
MOVI r5,1
CALL @nmod_sample
CMP r1,r0
JMP[NE] @fail
LA r3,0x00042021
CMP r2,r3
JMP[NE] @fail
MOVI r1,0x61
CALL @stage
; equal logits, topk 2, temp 1, seed 1 -> index 0, next 0x42021
LA r1,@eqlog
MOVI r2,4
LA r3,0x3F800000
MOVI r4,2
MOVI r5,1
CALL @nmod_sample
CMP r1,r0
JMP[NE] @fail
LA r3,0x00042021
CMP r2,r3
JMP[NE] @fail
MOVI r1,0x62
CALL @stage
; same input, seed 0x12345678 -> index 1, next 0x87985AA5
LA r1,@eqlog
MOVI r2,4
LA r3,0x3F800000
MOVI r4,2
LA r5,0x12345678
CALL @nmod_sample
MOVI r6,1
CMP r1,r6
JMP[NE] @fail
LA r3,0x87985AA5
CMP r2,r3
JMP[NE] @fail
MOVI r1,0x63
CALL @stage
; seed 0 maps to 0x12345678 deterministically
LA r1,@eqlog
MOVI r2,4
LA r3,0x3F800000
MOVI r4,2
MOVI r5,0
CALL @nmod_sample
MOVI r6,1
CMP r1,r6
JMP[NE] @fail
LA r3,0x87985AA5
CMP r2,r3
JMP[NE] @fail
; same seed twice -> identical pick and next seed
LA r1,@eqlog
MOVI r2,4
LA r3,0x3F800000
MOVI r4,2
MOVI r5,1
CALL @nmod_sample
ST r1,r0,@SAV1
ST r2,r0,@SAV2
LA r1,@eqlog
MOVI r2,4
LA r3,0x3F800000
MOVI r4,2
MOVI r5,1
CALL @nmod_sample
LD r3,r0,@SAV1
CMP r1,r3
JMP[NE] @fail
LD r3,r0,@SAV2
CMP r2,r3
JMP[NE] @fail
; topk 2 over a dominant logit always selects index 0
LA r1,@domlog
MOVI r2,4
LA r3,0x3F800000
MOVI r4,2
LA r5,0x12345678
CALL @nmod_sample
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; deterministic rerun: [1,2] twice gives identical four logits
MOVI r1,0x38
CALL @stage
LA r1,@md
LA r2,@ids12
MOVI r3,2
LA r4,@flog
CALL @nmod_forward
CMP r1,r0
JMP[NE] @fail
LA r1,@md
LA r2,@ids12
MOVI r3,2
LA r4,@flog2
CALL @nmod_forward
CMP r1,r0
JMP[NE] @fail
LA r6,@flog
LA r7,@flog2
MOVI r8,0
nmod_cmp_l:
  MOVI r2,4
  CMP r8,r2
  JMP[GE] @nmod_cmp_d
  ADD r1,r6,r8
  LD r1,r1,0
  ADD r2,r7,r8
  LD r2,r2,0
  CMP r1,r2
  JMP[NE] @fail
  ADD r8,r8,r13
  JMP @nmod_cmp_l
nmod_cmp_d:

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

stage:
LA r2,@stagev
ST r1,r2,0
RET

; ---------------------------------------------------------------------------
.org 0x9000
rmsx:
.word 0x40000000,0x40000000,0x40000000,0x40000000
emb:
.word 0xC0000000,0xC0000000,0xC0000000,0xC0000000
.word 0x40000000,0x40000000,0x40000000,0x40000000
.word 0x40000000,0x40000000,0x40000000,0x40000000
.word 0,0,0,0
nw:
.word 0x3F000000,0x3E800000,0x3E000000,0x3D800000
q4:
.word 0x3F800000,0x0C0B0A09,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x8888880A,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x88888807,0x88888888,0x88888888,0x88888888
.word 0x3F800000,0x09888888,0x88888888,0x88888888,0x88888888
q8:
.word 0x3F000000,0x00000002,0,0,0,0,0,0,0
acts1:
.word 0x3F000000,0x3E800000,0x3E000000,0x3D800000
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0
acts2:
.word 0x3F800000
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
md:
.word 0x4E4D4F44,1,4,4,@emb,@nw,@q4,4,0,1,0,0,0,0,0,0
ids12:
.word 1,2
ids0:
.word 0
eqlog:
.word 0,0,0,0
glog:
.word 0x3FD00000,0x3F800000,0xBF000000,0x3D800000
domlog:
.word 0,0xC2C80000,0xC2C80000,0xC2C80000
rmsout:
.word 0,0,0,0
logits:
.word 0,0,0,0
logits2:
.word 0
flog:
.word 0,0,0,0
flog2:
.word 0,0,0,0
SAV1:
.word 0
SAV2:
.word 0
stagev:
.word 0
