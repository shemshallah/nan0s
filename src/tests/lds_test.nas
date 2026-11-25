; lds_test.nas - high-data STS/LDS round trip in the 0xF0000 window.
.org 0
JMP @main
main:
  MOVI r13,1
  MOVI r1,0x1234
  STS r1,4
  LDS r2,4
  MOVI r3,0x1234
  CMP r2,r3
  JMP[NE] @fail
  MOVI r1,0xABCD
  STS r1,200
  LDS r2,200
  LA r3,0xABCD
  CMP r2,r3
  JMP[NE] @fail
  MOVI r1,76
  PUTC r1
  MOVI r1,68
  PUTC r1
  MOVI r1,83
  PUTC r1
  MOVI r1,32
  PUTC r1
  MOVI r1,79
  PUTC r1
  MOVI r1,75
  PUTC r1
  MOVI r1,10
  PUTC r1
  HALT
fail:
  MOVI r1,70
  PUTC r1
  MOVI r1,10
  PUTC r1
  HALT
