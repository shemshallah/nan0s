; narena64.nas - 64-bit NaN-native bump arena, built for frontier-scale runs.
;
; All pointers/sizes are (lo,hi) pairs of 32-bit words.  The current NaN16
; core realises the low half; the ADDRH revision can realise the high half
; without changing this API.  Alignment is in words and is capped at 2^30
; (a 4 GiB alignment is already absurd); 16 words = 64 bytes for SIMD tiles.
;
; Context (8 words):
;   +0 base_lo  +1 base_hi
;   +2 size_lo  +3 size_hi
;   +4 off_lo   +5 off_hi
;   +6 reserved +7 reserved
;
;   nar64_init    r1=ctx r2=base_lo r3=base_hi r4=size_lo r5=size_hi
;   nar64_alloc   r1=ctx r2=need_lo r3=need_hi r4=align
;                 -> r1=ptr_lo r2=ptr_hi, or r1=0,r2=0
;   nar64_mark    r1=ctx -> r1=off_lo r2=off_hi
;   nar64_release r1=ctx r2=off_lo r3=off_hi
;   nar64_reset   r1=ctx
;   nar64_used    r1=ctx -> r1=off_lo r2=off_hi
;   nar64_capacity r1=ctx -> r1=size_lo r2=size_hi



nar64_init:
  ST r2,r1,0
  ST r3,r1,1
  ST r4,r1,2
  ST r5,r1,3
  ST r0,r1,4
  ST r0,r1,5
  ST r0,r1,6
  ST r0,r1,7
  RET

nar64_reset:
  ST r0,r1,4
  ST r0,r1,5
  RET

nar64_mark:
  ADD r2,r1,r0
  LD r1,r2,4
  LD r2,r2,5
  RET

nar64_used:
  ADD r2,r1,r0
  LD r1,r2,4
  LD r2,r2,5
  RET

nar64_capacity:
  ADD r2,r1,r0
  LD r1,r2,2
  LD r2,r2,3
  RET

nar64_release:
  ST r2,r1,4
  ST r3,r1,5
  RET

nar64_alloc:
  ST r15,r0,@n64a_ret
  ADD r10,r1,r0
  ADD r11,r2,r0
  ADD r12,r3,r0
  ADD r9,r4,r0
  CMP r9,r0
  JMP[NE] @n64a_a
  MOVI r9,1
n64a_a:
  ; aligned off
  LD r5,r10,4
  LD r6,r10,5
  ADD r1,r5,r0
  ADD r2,r6,r0
  ADD r3,r9,r0
  CALL @n64_alignup
  ADD r7,r1,r0
  ADD r8,r2,r0
  ; end = aligned + need
  ADD r3,r11,r0
  ADD r4,r12,r0
  CALL @n64_add
  ADD r5,r1,r0
  ADD r6,r2,r0
  ; compare end to size
  LD r3,r10,2
  LD r4,r10,3
  CALL @n64_cmp
  CMPS r1,r0
  JMP[GT] @n64a_full
  ; publish offset
  ST r5,r10,4
  ST r6,r10,5
  ; pointer = base + aligned
  LD r3,r10,0
  LD r4,r10,1
  ADD r1,r7,r0
  ADD r2,r8,r0
  CALL @n64_add
  LD r15,r0,@n64a_ret
  RET
n64a_full:
  MOVI r1,0
  MOVI r2,0
  LD r15,r0,@n64a_ret
  RET
n64a_ret:
  .word 0
