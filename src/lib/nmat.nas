; nmat.nas - NaN-native packed-i8 matrix kernels built on DP4B (op 0x4A).
;
; Packing: four signed i8 values per NaN payload, low byte first.  A is an
; M x (4*Kwords) row-major matrix, B is N x (4*Kwords) row-major, C is M x N.
; This is the quantized-inference layout: a dot product is one DP4B per four
; multiply-accumulates.  All code here is NaN16; the native core only supplies
; the DP4B primitive.
;
; Context (word addresses):
;   +0 A base      +1 B base      +2 C base
;   +3 M           +4 N           +5 Kwords (K/4)
;   +6 A stride    +7 B stride    +8 C stride (words)
;
; nmat_dot: r1=A, r2=B, r3=Kwords -> r1=int32 dot.  Preserves r10-r12.
; nmat_i8 : r1=ctx -> fills C.  Clobbers r1-r12; r13 must be 1.

nmat_dot:
  MOVI r4,0
nd_l:
  CMP r3,r0
  JMP[EQ] @nd_d
  LD r6,r1,0
  LD r7,r2,0
  DP4B r8,r6,r7
  ADD r4,r4,r8
  ADDI r1,r1,1
  ADDI r2,r2,1
  SUB r3,r3,r13
  JMP @nd_l
nd_d:
  ADD r1,r4,r0
  RET

nmat_i8:
  ST r15,r0,@ni_ret
  ADD r10,r1,r0          ; ctx
  MOVI r11,0             ; i
ni_i:
  LD r6,r10,3
  CMP r11,r6
  JMP[GE] @ni_done
  MOVI r12,0             ; j
ni_j:
  LD r7,r10,4
  CMP r12,r7
  JMP[GE] @ni_nexti
  ; A row pointer
  LD r3,r10,0
  LD r9,r10,6
  MUL r1,r11,r9
  ADD r1,r3,r1
  ; B row pointer
  LD r3,r10,1
  LD r9,r10,7
  MUL r2,r12,r9
  ADD r2,r3,r2
  ; Kwords
  LD r3,r10,5
  CALL @nmat_dot
  ; C[i*N + j] = r1
  LD r6,r10,4
  MUL r2,r11,r6
  ADD r2,r2,r12
  LD r3,r10,8
  MUL r2,r2,r3
  LD r3,r10,2
  ADD r3,r3,r2
  ST r1,r3,0
  ADD r12,r12,r13
  JMP @ni_j
ni_nexti:
  ADD r11,r11,r13
  JMP @ni_i
ni_done:
  LD r15,r0,@ni_ret
  RET
ni_ret:
  .word 0

; nmat_dot64: r1=A_lo r2=A_hi r3=B_lo r4=B_hi r5=Kwords
;              -> r1=sum_lo r2=sum_hi (signed 64-bit accumulation)
; The current core uses the low pointers; the ADDRH revision uses both.
; Each DP4B result is sign-extended before it is added to the 64-bit sum.
nmat_dot64:
  ADD r10,r1,r0
  ADD r11,r3,r0
  ADD r12,r5,r0
  MOVI r4,0
  MOVI r5,0
nd64_l:
  CMP r12,r0
  JMP[EQ] @nd64_d
  LD r6,r10,0
  LD r7,r11,0
  DP4B r8,r6,r7
  SAR r9,r8,31
  ADD r1,r4,r0
  ADD r4,r4,r8
  CMP r4,r1
  MOVI r7,0
  MOVI[LT] r7,1
  ADD r5,r5,r9
  ADD r5,r5,r7
  ADDI r10,r10,1
  ADDI r11,r11,1
  SUB r12,r12,r13
  JMP @nd64_l
nd64_d:
  ADD r1,r4,r0
  ADD r2,r5,r0
  RET
