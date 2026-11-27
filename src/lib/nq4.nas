; nq4.nas - packed Q4_0/Q8_0 blocks, exact dequant and dot/GEMV (F6).
;
; Layout (guest words, 32 weights per block).  The block stride is word
; aligned and the scale is f32 so the path is exact on the NaN FPU; a real
; GGUF loader will convert llama.cpp's f16 scale to f32 at import time.  This
; is a deliberate, documented simplification: f32 scale + integer payloads
; make every expected value hand-computable, and converting an f16 scale only
; rounds once at load, before any dot product.
;
; Q4_0 block (5 words = 20 payload bytes):
;   word 0   f32 scale bits
;   words 1..4  16 packed bytes, 4 bytes/word, little-endian byte order.
;     byte j (j=0..15) low nibble  = q[j]     (signed 4-bit, value-8)
;                      high nibble = q[16+j]  (signed 4-bit, value-8)
;   dequant(q[i]) = scale * (nibble - 8)
;
; Q8_0 block (9 words = 36 payload bytes):
;   word 0   f32 scale bits
;   words 1..8  32 signed bytes, 4 bytes/word, little-endian byte order.
;   dequant(q[i]) = scale * int8(q[i])
;
; A "block pointer" is a guest word address.  Q4 blocks advance by 5 words,
; Q8 blocks by 9.  Activations are an array of f32 bits, 1 word/element.
;
; API:
;   nq_f16_to_f32 r1=u16 -> r1=f32 bits (exact; subnormal/inf/NaN included)
;   nq4_dequant r1=block r2=index -> r1=f32 bits (NaN if index >= 32)
;   nq8_dequant r1=block r2=index -> r1=f32 bits (NaN if index >= 32)
;   nq4_dot32   r1=block r2=acts -> r1=f32 dot bits
;   nq8_dot32   r1=block r2=acts -> r1=f32 dot bits
;   nq4_gemv    r1=blocks r2=nblocks r3=acts r4=out -> 0/-1
;   nq8_gemv    r1=blocks r2=nblocks r3=acts r4=out -> 0/-1
;
; All arithmetic is IEEE f32.  Scales and activations in the gate are exact
; binary fractions and weights are small integers, so every product and sum
; is exactly representable; the expected bit patterns are fixed.

.include "n64.nas"

.equ NQ_TMP 0x6000

; r1=word r2=byte position 0..3 -> r1=byte
nq_byte:
  CMP r2,r0
  JMP[EQ] @nq_b0
  MOVI r3,1
  CMP r2,r3
  JMP[EQ] @nq_b1
  MOVI r3,2
  CMP r2,r3
  JMP[EQ] @nq_b2
  SHR r1,r1,24
  MOVI r2,0xFF
  BOOL.8 r1,r1,r2
  RET
nq_b0:
  MOVI r2,0xFF
  BOOL.8 r1,r1,r2
  RET
nq_b1:
  SHR r1,r1,8
  MOVI r2,0xFF
  BOOL.8 r1,r1,r2
  RET
nq_b2:
  SHR r1,r1,16
  MOVI r2,0xFF
  BOOL.8 r1,r1,r2
  RET


; ---------------------------------------------------------------------------
; nq_f16_to_f32: shared exact f16 -> f32 conversion (n64_f16_to_f32).
nq_f16_to_f32:
  JMP @n64_f16_to_f32

; r1=block r2=index -> r1=f32 dequant bits
nq4_dequant:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NQ_TMP+16
  ST r2,r0,#NQ_TMP+17
  MOVI r3,32
  CMP r2,r3
  JMP[GE] @nq4_d_bad
  ; byte index and nibble half
  MOVI r3,16
  CMP r2,r3
  JMP[GE] @nq4_d_hi
  ADD r4,r2,r0
  MOVI r5,0
  JMP @nq4_d_sel
nq4_d_hi:
  SUB r4,r2,r3
  MOVI r5,1
nq4_d_sel:
  ST r4,r0,#NQ_TMP+18
  ST r5,r0,#NQ_TMP+19
  ; packed word = block[1 + (byteidx >> 2)]
  SHR r6,r4,2
  ADDI r6,r6,1
  LD r7,r0,#NQ_TMP+16
  ADD r6,r7,r6
  LD r7,r6,0
  ; byte position = byteidx & 3
  MOVI r8,3
  BOOL.8 r2,r4,r8
  ADD r1,r7,r0
  CALL @nq_byte
  ST r1,r0,#NQ_TMP+20
  LD r2,r0,#NQ_TMP+19
  CMP r2,r0
  JMP[EQ] @nq4_d_low
  SHR r1,r1,4
nq4_d_low:
  MOVI r2,0x0F
  BOOL.8 r1,r1,r2
  ADDI r1,r1,-8
  CVTIF r1,r1
  LD r2,r0,#NQ_TMP+16
  LD r2,r2,0
  FMUL r1,r1,r2
  JMP @nq4_d_out
nq4_d_bad:
  LA r1,0x7FC00000
nq4_d_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=block r2=index -> r1=f32 dequant bits
nq8_dequant:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NQ_TMP+16
  ST r2,r0,#NQ_TMP+17
  MOVI r3,32
  CMP r2,r3
  JMP[GE] @nq8_d_bad
  MOVI r4,0
  ST r4,r0,#NQ_TMP+18
  ; packed word = block[1 + (index >> 2)]
  SHR r6,r2,2
  ADDI r6,r6,1
  LD r7,r0,#NQ_TMP+16
  ADD r6,r7,r6
  LD r7,r6,0
  MOVI r8,3
  BOOL.8 r2,r2,r8
  ADD r1,r7,r0
  CALL @nq_byte
  MOVI r2,128
  CMP r1,r2
  JMP[LT] @nq8_d_pos
  ADDI r1,r1,-256
nq8_d_pos:
  CVTIF r1,r1
  LD r2,r0,#NQ_TMP+16
  LD r2,r2,0
  FMUL r1,r1,r2
  JMP @nq8_d_out
nq8_d_bad:
  LA r1,0x7FC00000
nq8_d_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=block r2=acts -> r1=f32 dot bits
nq4_dot32:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NQ_TMP+0
  ST r2,r0,#NQ_TMP+1
  ST r0,r0,#NQ_TMP+2
  MOVI r1,0
  ST r1,r0,#NQ_TMP+3
nq4_dot_l:
  LD r1,r0,#NQ_TMP+3
  MOVI r2,32
  CMP r1,r2
  JMP[GE] @nq4_dot_d
  LD r1,r0,#NQ_TMP+0
  LD r2,r0,#NQ_TMP+3
  CALL @nq4_dequant
  ST r1,r0,#NQ_TMP+4
  LD r1,r0,#NQ_TMP+1
  LD r2,r0,#NQ_TMP+3
  ADD r1,r1,r2
  LD r1,r1,0
  LD r2,r0,#NQ_TMP+4
  FMUL r1,r1,r2
  LD r2,r0,#NQ_TMP+2
  FADD r1,r1,r2
  ST r1,r0,#NQ_TMP+2
  LD r1,r0,#NQ_TMP+3
  ADD r1,r1,r13
  ST r1,r0,#NQ_TMP+3
  JMP @nq4_dot_l
nq4_dot_d:
  LD r1,r0,#NQ_TMP+2
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=block r2=acts -> r1=f32 dot bits
nq8_dot32:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NQ_TMP+0
  ST r2,r0,#NQ_TMP+1
  ST r0,r0,#NQ_TMP+2
  MOVI r1,0
  ST r1,r0,#NQ_TMP+3
nq8_dot_l:
  LD r1,r0,#NQ_TMP+3
  MOVI r2,32
  CMP r1,r2
  JMP[GE] @nq8_dot_d
  LD r1,r0,#NQ_TMP+0
  LD r2,r0,#NQ_TMP+3
  CALL @nq8_dequant
  ST r1,r0,#NQ_TMP+4
  LD r1,r0,#NQ_TMP+1
  LD r2,r0,#NQ_TMP+3
  ADD r1,r1,r2
  LD r1,r1,0
  LD r2,r0,#NQ_TMP+4
  FMUL r1,r1,r2
  LD r2,r0,#NQ_TMP+2
  FADD r1,r1,r2
  ST r1,r0,#NQ_TMP+2
  LD r1,r0,#NQ_TMP+3
  ADD r1,r1,r13
  ST r1,r0,#NQ_TMP+3
  JMP @nq8_dot_l
nq8_dot_d:
  LD r1,r0,#NQ_TMP+2
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=blocks r2=nblocks r3=acts r4=out -> 0/-1
nq4_gemv:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NQ_TMP+24
  ST r2,r0,#NQ_TMP+25
  ST r3,r0,#NQ_TMP+26
  ST r4,r0,#NQ_TMP+27
  CMP r2,r0
  JMP[EQ] @nq4_g_fail
  MOVI r1,0
  ST r1,r0,#NQ_TMP+28
nq4_g_l:
  LD r1,r0,#NQ_TMP+28
  LD r2,r0,#NQ_TMP+25
  CMP r1,r2
  JMP[GE] @nq4_g_ok
  LD r1,r0,#NQ_TMP+24
  LD r2,r0,#NQ_TMP+26
  CALL @nq4_dot32
  LD r2,r0,#NQ_TMP+27
  LD r3,r0,#NQ_TMP+28
  ADD r2,r2,r3
  ST r1,r2,0
  LD r1,r0,#NQ_TMP+24
  ADDI r1,r1,5
  ST r1,r0,#NQ_TMP+24
  LD r1,r0,#NQ_TMP+28
  ADD r1,r1,r13
  ST r1,r0,#NQ_TMP+28
  JMP @nq4_g_l
nq4_g_ok:
  MOVI r1,0
  JMP @nq4_g_out
nq4_g_fail:
  LA r1,0xFFFFFFFF
nq4_g_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=blocks r2=nblocks r3=acts r4=out -> 0/-1
nq8_gemv:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NQ_TMP+24
  ST r2,r0,#NQ_TMP+25
  ST r3,r0,#NQ_TMP+26
  ST r4,r0,#NQ_TMP+27
  CMP r2,r0
  JMP[EQ] @nq8_g_fail
  MOVI r1,0
  ST r1,r0,#NQ_TMP+28
nq8_g_l:
  LD r1,r0,#NQ_TMP+28
  LD r2,r0,#NQ_TMP+25
  CMP r1,r2
  JMP[GE] @nq8_g_ok
  LD r1,r0,#NQ_TMP+24
  LD r2,r0,#NQ_TMP+26
  CALL @nq8_dot32
  LD r2,r0,#NQ_TMP+27
  LD r3,r0,#NQ_TMP+28
  ADD r2,r2,r3
  ST r1,r2,0
  LD r1,r0,#NQ_TMP+24
  ADDI r1,r1,9
  ST r1,r0,#NQ_TMP+24
  LD r1,r0,#NQ_TMP+28
  ADD r1,r1,r13
  ST r1,r0,#NQ_TMP+28
  JMP @nq8_g_l
nq8_g_ok:
  MOVI r1,0
  JMP @nq8_g_out
nq8_g_fail:
  LA r1,0xFFFFFFFF
nq8_g_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
