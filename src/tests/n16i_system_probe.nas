; n16i_system_probe.nas - custom NaN ABI guest for the 64-bit n16i runtime.
.org 0
  MOVI r1,71
  PUTC r1
  LA r1,0x4E01
  LA r2,@p_frame
  OUTL r2,r1
  LA r1,0x4E03
  LA r2,@p_stack
  OUTL r2,r1
  LA r1,0x4E00
  LA r2,@p_kentry
  OUTL r2,r1
  SVC 7
  MOVI r2,42
  CMP r1,r2
  JMP[NE] @p_fail
  MOVI r1,79
  PUTC r1
  HALT
p_fail:
  MOVI r1,70
  PUTC r1
  HALT
p_kentry:
  MOVI r1,75
  PUTC r1
  MOVI r1,0x4E01
  INL r10,r1
  LD r1,r10,20
  MOVI r2,7
  CMP r1,r2
  JMP[NE] @p_kfail
  MOVI r1,42
  ST r1,r10,21
  SVCRET
p_kfail:
  MOVI r1,88
  PUTC r1
  HALT
.org 0x1000
p_frame:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.org 0x2000
p_stack:
.word 0
