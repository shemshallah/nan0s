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
