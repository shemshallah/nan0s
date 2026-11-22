; nten.nas - 64-bit NaN-native tensor descriptor/path arithmetic.
;
; Descriptor (10 words):
;   +0 base_lo  +1 base_hi
;   +2 rows     +3 cols
;   +4 s0_lo    +5 s0_hi      row stride in words
;   +6 s1_lo    +7 s1_hi      column stride in words
;   +8 elem_bytes +9 flags
;
;   nten_init r1=ctx r2=base_lo r3=base_hi r4=rows r5=cols
;             r6=s0_lo r7=s0_hi r8=s1_lo r9=s1_hi
;   nten_ptr  r1=ctx r2=i r3=j -> r1=ptr_lo r2=ptr_hi
;
; The current core dereferences the low half; the ADDRH revision consumes
; both.  Every offset is computed with 64-bit helpers, so a tensor may cross
; 4 GiB without changing this ABI.
.include "n64.nas"

nten_init:
  ST r2,r1,0
  ST r3,r1,1
  ST r4,r1,2
  ST r5,r1,3
  ST r6,r1,4
  ST r7,r1,5
  ST r8,r1,6
  ST r9,r1,7
  ST r0,r1,8
  ST r0,r1,9
  RET

nten_ptr:
  ST r15,r0,@nt_ret
  ADD r10,r1,r0
  ADD r11,r2,r0
  ADD r12,r3,r0
  ; i * s0
  ADD r1,r11,r0
  LD r2,r10,4
  LD r3,r10,5
  CALL @n64_mul32
  ADD r7,r1,r0
  ADD r8,r2,r0
  ; j * s1
  ADD r1,r12,r0
  LD r2,r10,6
  LD r3,r10,7
  CALL @n64_mul32
  ; offset = i*s0 + j*s1
  ADD r3,r1,r0
  ADD r4,r2,r0
  ADD r1,r7,r0
  ADD r2,r8,r0
  CALL @n64_add
  ; pointer = base + offset
  LD r3,r10,0
  LD r4,r10,1
  CALL @n64_add
  LD r15,r0,@nt_ret
  RET
nt_ret:
  .word 0
