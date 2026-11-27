; n64.nas - shared 64-bit helpers for NaN-native frontier structures.
; Pointers/sizes are (lo,hi) pairs of 32-bit words. r13 must be 1.

; n64_add: r1=alo r2=ahi r3=blo r4=bhi -> r1=lo r2=hi r5=carry
n64_add:
  ADD r5,r1,r0
  ADD r1,r1,r3
  CMP r1,r5
  MOVI r5,0
  MOVI[LT] r5,1
  ADD r2,r2,r4
  ADD r2,r2,r5
  RET

; n64_sub: r1=alo r2=ahi r3=blo r4=bhi -> r1=lo r2=hi
n64_sub:
  CMP r1,r3
  MOVI r5,0
  MOVI[LT] r5,1
  SUB r1,r1,r3
  SUB r2,r2,r4
  SUB r2,r2,r5
  RET

; n64_cmp: r1=alo r2=ahi r3=blo r4=bhi -> r1=1 if a>b, -1 if a<b, 0 equal
n64_cmp:
  CMP r2,r4
  JMP[LT] @n64_less
  JMP[GT] @n64_greater
  CMP r1,r3
  JMP[LT] @n64_less
  JMP[GT] @n64_greater
  MOVI r1,0
  RET
n64_less:
  LA r1,0xFFFFFFFF
  RET
n64_greater:
  MOVI r1,1
  RET

; n64_alignup: r1=lo r2=hi r3=align -> r1=lo r2=hi (align power of two)
n64_alignup:
  ADD r4,r1,r3
  ADDI r4,r4,-1
  CMP r4,r1
  MOVI r5,0
  MOVI[LT] r5,1
  ADD r2,r2,r5
  SUB r6,r0,r3
  BOOL.8 r1,r4,r6
  RET

; n64_mul32: r1=u32 r2=lo r3=hi -> r1=lo r2=hi (low 64 bits of u * value)
n64_mul32:
  ADD r4,r1,r0
  ADD r5,r2,r0
  ADD r6,r3,r0
  MUL r1,r4,r5
  MULHU r2,r4,r5
  MUL r3,r4,r6
  ADD r2,r2,r3
  RET

; ---------------------------------------------------------------------------
; n64_f16_to_f32: r1=16-bit IEEE half bits -> r1=32-bit IEEE float bits.
; Every f16 value is exactly representable in f32, so this conversion rounds
; nothing.  Subnormals are normalized; Inf/NaN keep their payload.
n64_f16_to_f32:
  MOVI r2,0x8000
  BOOL.8 r3,r1,r2              ; sign
  MOVI r2,0x7C00
  BOOL.8 r4,r1,r2
  SHR r4,r4,10                 ; exponent 0..31
  MOVI r2,0x3FF
  BOOL.8 r5,r1,r2              ; mantissa
  CMP r4,r0
  JMP[EQ] @nq_f16_sub
  MOVI r2,31
  CMP r4,r2
  JMP[EQ] @nq_f16_special
  ADDI r4,r4,112
  SHL r4,r4,23
  SHL r5,r5,13
  JMP @nq_f16_build
nq_f16_special:
  MOVI r4,255
  SHL r4,r4,23
  SHL r5,r5,13
  JMP @nq_f16_build
nq_f16_sub:
  CMP r5,r0
  JMP[NE] @nq_f16_subnz
  MOVI r4,0
  JMP @nq_f16_build
nq_f16_subnz:
  ; k = floor(log2(mant)); f32 exp = 103+k; frac = (mant << (23-k)) & 0x7FFFFF
  MOVI r6,0
  ADD r7,r5,r0
nq_f16_norm:
  MOVI r2,1
  CMP r7,r2
  JMP[LE] @nq_f16_normd
  SHR r7,r7,1
  ADD r6,r6,r13
  JMP @nq_f16_norm
nq_f16_normd:
  ADDI r4,r6,103
  SHL r4,r4,23
  MOVI r2,23
  SUB r2,r2,r6
  ADD r7,r5,r0
nq_f16_shl:
  CMP r2,r0
  JMP[LE] @nq_f16_shld
  SHL r7,r7,1
  SUB r2,r2,r13
  JMP @nq_f16_shl
nq_f16_shld:
  LA r2,0x7FFFFF
  BOOL.8 r5,r7,r2
nq_f16_build:
  SHL r3,r3,16
  BOOL.14 r1,r4,r5
  BOOL.14 r1,r1,r3
  RET
