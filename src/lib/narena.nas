; narena.nas - NaN-native bump arena for inference activations/KV blocks.
; No freelist, no host code.  The caller owns the region; the context is
; four caller words: [base_word, size_words, offset_words, reserved].
;
;   nar_init    r1=ctx r2=base_word r3=size_words
;   nar_alloc   r1=ctx r2=words r3=align_words -> r1=ptr or 0
;   nar_mark    r1=ctx -> r1=offset_words
;   nar_release r1=ctx r2=offset_words
;   nar_reset   r1=ctx
;   nar_used    r1=ctx -> r1=words used
;   nar_capacity r1=ctx -> r1=words
;
; Alignment is in words and must be a power of two (0 and 1 mean 1 word).
; A 64-byte SIMD alignment is therefore r3=16.  r13 must be 1.

nar_init:
  ST r2,r1,0
  ST r3,r1,1
  ST r0,r1,2
  RET

nar_reset:
  ST r0,r1,2
  RET

nar_mark:
  LD r1,r1,2
  RET

nar_release:
  ST r2,r1,2
  RET

nar_used:
  LD r1,r1,2
  RET

nar_capacity:
  LD r1,r1,1
  RET

nar_alloc:
  CMP r3,r0
  JMP[NE] @na_al
  MOVI r3,1
na_al:
  LD r4,r1,0          ; base
  LD r5,r1,2          ; offset
  ADD r6,r5,r3
  SUB r6,r6,r13
  SUB r7,r0,r3        ; mask = -align
  BOOL.8 r6,r6,r7     ; aligned offset
  ADD r8,r6,r2        ; end
  LD r9,r1,1          ; capacity
  CMP r8,r9
  JMP[GT] @na_full
  ST r8,r1,2
  ADD r1,r4,r6
  RET
na_full:
  MOVI r1,0
  RET
