; nmem.nas - 64-bit NaN memory objects and capabilities.
;
; A memory object is a nanobj capability (class 20) whose payload is:
;   +0 base_lo +1 base_hi +2 size_lo +3 size_hi
;   +4 rights +5 node +6 flags +7 class
;
; Every size/offset is (lo,hi); a 2 TB object and a 1 TB view are normal.
; Views are new capabilities over base+offset/size; they share the same
; physical object policy but carry their own range.  No host pointer escapes.

.include "n64.nas"
.include "nanobj.nas"

.equ NMEM_CLASS   20
.equ NMEM_WORDS   8
.equ NM_DESC      0x3D4
.equ NM_CAP       0x3DC
.equ NM_OFF       0x3DD
.equ NM_LEN       0x3DF
.equ NM_VIEW      0x3E1
.equ NM_INFO      0x3E9

; nmem_create r1=base_lo r2=base_hi r3=size_lo r4=size_hi r5=rights r6=node
;             -> cap or 0
nmem_create:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r7,#NM_DESC
  ST r1,r7,0
  ST r2,r7,1
  ST r3,r7,2
  ST r4,r7,3
  ST r5,r7,4
  ST r6,r7,5
  ST r0,r7,6
  MOVI r1,#NMEM_CLASS
  ST r1,r7,7
  MOVI r1,#NMEM_CLASS
  MOVI r2,#NMEM_WORDS
  CALL @nobj_create
  CMP r1,r0
  JMP[EQ] @nmem_cr_fail
  ST r1,r0,#NM_CAP
  LA r2,#NM_DESC
  MOVI r3,0
  MOVI r4,#NMEM_WORDS
  CALL @nobj_write
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nmem_cr_fail
  LD r1,r0,#NM_CAP
  JMP @nmem_cr_out
nmem_cr_fail:
  MOVI r1,0
nmem_cr_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nmem_info r1=cap r2=dst(8 words) -> 0 or -1
nmem_info:
  MOVI r3,0
  MOVI r4,#NMEM_WORDS
  JMP @nobj_read

; nmem_check r1=cap r2=rights -> entry or 0
nmem_check:
  JMP @nobj_check

; nmem_grant r1=cap r2=rights -> cap or 0
nmem_grant:
  JMP @nobj_grant

; nmem_release r1=cap -> 0/-1
nmem_release:
  JMP @nobj_release

; nmem_view r1=cap r2=off_lo r3=off_hi r4=len_lo r5=len_hi -> cap or 0
nmem_view:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NM_CAP
  ST r2,r0,#NM_OFF
  ST r3,r0,#NM_OFF+1
  ST r4,r0,#NM_LEN
  ST r5,r0,#NM_LEN+1
  ; read the parent descriptor
  LD r1,r0,#NM_CAP
  LA r2,#NM_DESC
  MOVI r3,0
  MOVI r4,#NMEM_WORDS
  CALL @nobj_read
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nmem_v_fail
  ; end = off + len
  LD r1,r0,#NM_OFF
  LD r2,r0,#NM_OFF+1
  LD r3,r0,#NM_LEN
  LD r4,r0,#NM_LEN+1
  CALL @n64_add
  ; compare end to size (NM_DESC+2/3)
  LD r3,r0,#NM_DESC+2
  LD r4,r0,#NM_DESC+3
  CALL @n64_cmp
  CMP r1,r0
  JMP[GT] @nmem_v_fail
  ; new base = base + off
  LD r1,r0,#NM_DESC+0
  LD r2,r0,#NM_DESC+1
  LD r3,r0,#NM_OFF
  LD r4,r0,#NM_OFF+1
  CALL @n64_add
  LA r7,#NM_VIEW
  ST r1,r7,0
  ST r2,r7,1
  ; new size = len
  LD r1,r0,#NM_LEN
  LD r2,r0,#NM_LEN+1
  ST r1,r7,2
  ST r2,r7,3
  ; rights, node, flags, class
  LD r1,r0,#NM_DESC+4
  ST r1,r7,4
  LD r1,r0,#NM_DESC+5
  ST r1,r7,5
  LD r1,r0,#NM_DESC+6
  ST r1,r7,6
  MOVI r1,#NMEM_CLASS
  ST r1,r7,7
  MOVI r1,#NMEM_CLASS
  MOVI r2,#NMEM_WORDS
  CALL @nobj_create
  CMP r1,r0
  JMP[EQ] @nmem_v_fail
  ST r1,r0,#NM_CAP
  LA r2,#NM_VIEW
  MOVI r3,0
  MOVI r4,#NMEM_WORDS
  CALL @nobj_write
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nmem_v_fail
  LD r1,r0,#NM_CAP
  JMP @nmem_v_out
nmem_v_fail:
  MOVI r1,0
nmem_v_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
