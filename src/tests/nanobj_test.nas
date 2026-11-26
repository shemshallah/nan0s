; nanobj_test.nas - M1a typed object/capability self-test.
; Prints NOBJ PASS or NOBJ FAIL on COM1, then HALT.

JMP @start

.include "../lib/nanobj.nas"

start:
  MOVI r0,0
  MOVI r13,1
  LA r14,@stack
  CALL @nobj_init

  ; create class 7, two-word payload
  MOVI r1,7
  MOVI r2,2
  CALL @nobj_create
  CMP r1,r0
  JMP[EQ] @fail
  ST r1,r0,@cap1

  ; write 0x1111, 0x2222
  LA r3,@wbuf
  MOVI r4,0x1111
  ST r4,r3,0
  MOVI r4,0x2222
  ST r4,r3,1
  LD r1,r0,@cap1
  ADD r2,r3,r0
  MOVI r3,0
  MOVI r4,2
  CALL @nobj_write
  MOVI r5,2
  CMP r1,r5
  JMP[NE] @fail

  ; read back
  LD r1,r0,@cap1
  LA r2,@rbuf
  MOVI r3,0
  MOVI r4,2
  CALL @nobj_read
  MOVI r5,2
  CMP r1,r5
  JMP[NE] @fail
  LA r3,@rbuf
  LD r4,r3,0
  MOVI r5,0x1111
  CMP r4,r5
  JMP[NE] @fail
  LD r4,r3,1
  MOVI r5,0x2222
  CMP r4,r5
  JMP[NE] @fail

  ; grant read-only
  LD r1,r0,@cap1
  MOVI r2,#NOBJ_R_READ
  CALL @nobj_grant
  CMP r1,r0
  JMP[EQ] @fail
  ST r1,r0,@capro

  ; write through read-only must fail
  LD r1,r0,@capro
  LA r2,@wbuf
  MOVI r3,0
  MOVI r4,1
  CALL @nobj_write
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[NE] @fail

  ; read through read-only works
  LD r1,r0,@capro
  LA r2,@rbuf
  MOVI r3,0
  MOVI r4,1
  CALL @nobj_read
  MOVI r5,1
  CMP r1,r5
  JMP[NE] @fail

  ; forged generation must fail
  LD r1,r0,@cap1
  MOVI r2,0x100
  ADD r1,r1,r2
  LA r2,@rbuf
  MOVI r3,0
  MOVI r4,1
  CALL @nobj_read
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[NE] @fail

  ; release both capabilities; the first table entry must become free
  LD r1,r0,@capro
  CALL @nobj_release
  CMP r1,r0
  JMP[NE] @fail
  LD r1,r0,@cap1
  CALL @nobj_release
  CMP r1,r0
  JMP[NE] @fail
  LA r3,#NOBJ_TAB
  LD r4,r3,0
  CMP r4,r0
  JMP[NE] @fail

  LA r1,@passmsg
  CALL @puts
  HALT

fail:
  LA r1,@failmsg
  CALL @puts
  HALT

; r1 = packed .str word address
puts:
  SHL r1,r1,2
puts_l:
  LDB r2,r1,0
  CMP r2,r0
  JMP[EQ] @puts_d
  PUTC r2
  ADD r1,r1,r13
  JMP @puts_l
puts_d:
  RET

passmsg:
.str "NOBJ PASS\n"
failmsg:
.str "NOBJ FAIL\n"

cap1:
.word 0
capro:
.word 0
wbuf:
.word 0,0
rbuf:
.word 0,0
stack:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
