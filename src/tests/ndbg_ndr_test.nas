; ndbg_ndr_test.nas - operands and seal in the 8-word NDR.
; The bad-op word has a/b/d fields 1/2/6, so w4..w6 must come from those regs.
.org 0
JMP @main
.include "../dbg/core.nas"
.include "../dbg/undo_stub.nas"

main:
  MOVI r13,1
  CALL @nd_reset
  MOVI r1,0x11
  MOVI r2,1
  ST r1,r2,@nd_regs
  MOVI r1,0x22
  MOVI r2,2
  ST r1,r2,@nd_regs
  MOVI r1,0x66
  MOVI r2,6
  ST r1,r2,@nd_regs
  MOVI r1,9001
  ST r1,r0,@nd_pc
  CALL @nd_step
  LD r1,r0,@nd_status
  MOVI r2,3
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,@nd_rec
  ADDI r1,r1,4
  LD r1,r1,0
  MOVI r2,0x11
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,@nd_rec
  ADDI r1,r1,5
  LD r1,r1,0
  MOVI r2,0x66
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,@nd_rec
  ADDI r1,r1,6
  LD r1,r1,0
  MOVI r2,0x22
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,@nd_rec
  ADDI r1,r1,7
  LD r1,r1,0
  CMP r1,r0
  JMP[EQ] @fail
  ; the 8-word ring must hold the same operands and seal
  LA r1,0x31000
  ADDI r1,r1,4
  LD r1,r1,0
  MOVI r2,0x11
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x31000
  ADDI r1,r1,5
  LD r1,r1,0
  MOVI r2,0x66
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x31000
  ADDI r1,r1,6
  LD r1,r1,0
  MOVI r2,0x22
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,@nd_rec
  ADDI r1,r1,7
  LD r2,r1,0
  LA r1,0x31000
  ADDI r1,r1,7
  LD r1,r1,0
  CMP r1,r2
  JMP[NE] @fail
  ; mirror w4: copy to scratch, BSWAPM in place, compare the payload
  LA r3,0x31804
  LD r1,r3,0
  LA r4,0x33000
  ST r1,r4,0
  BSWAPM r4,0
  LD r1,r4,0
  MOVI r2,0x11
  CMP r1,r2
  JMP[NE] @fail
  ; mirror seal
  MOVI r1,@nd_rec
  ADDI r1,r1,7
  LD r2,r1,0
  LA r3,0x31807
  LD r1,r3,0
  LA r4,0x33000
  ST r1,r4,0
  BSWAPM r4,0
  LD r1,r4,0
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,@s_ok
  CALL @nd_puts
  HALT
fail:
  MOVI r1,@s_bad
  CALL @nd_puts
  HALT

s_ok:
.str "NDR PASS\n"
s_bad:
.str "NDR FAIL\n"

.org 9000
.raw 0000_DEADBEEF_0000
.raw FFF8_7F123456_F8FF
