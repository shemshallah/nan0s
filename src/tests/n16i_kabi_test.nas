; n16i_kabi_test.nas - n16i KABI/port/SVC/SVCRET proof.
.org 0
JMP @host
.org 0x1000
.include "../tools/n16i.nas"
host:
  MOVI r0,0
  MOVI r13,1
  LA r14,0x6000
  LA r1,0x4000
  MOVI r2,0
  LA r3,0x7FFF
  CALL @n16i_run
  MOVI r1,68
  PUTC r1
  HALT
.org 0x4000
guest_start:
  MOVI r1,71
  PUTC r1
  LA r1,0x4E01
  LA r2,@g_frame
  OUTL r2,r1
  LA r1,0x4E03
  LA r2,@g_stack
  OUTL r2,r1
  LA r1,0x4E00
  LA r2,@g_kentry
  OUTL r2,r1
  SVC 7
  MOVI r2,42
  CMP r1,r2
  JMP[NE] @g_fail
  MOVI r1,79
  PUTC r1
  HALT
g_fail:
  MOVI r1,70
  PUTC r1
  HALT
g_kentry:
  MOVI r1,75
  PUTC r1
  MOVI r1,0x4E01
  INL r10,r1
  LD r1,r10,20
  MOVI r2,7
  CMP r1,r2
  JMP[NE] @g_kfail
  MOVI r1,42
  ST r1,r10,21
  SVCRET
g_kfail:
  MOVI r1,75
  PUTC r1
  HALT
.org 0x5000
g_frame:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.org 0x5100
g_stack:
.word 0
