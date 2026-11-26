; nanobj_persist_test.nas - M1c object snapshot save/load validation.
; Uses a RAM snapshot hook; the OS installs NPAF/ATA hooks in production.
; Prints NOBJ PERSIST PASS or NOBJ PERSIST FAIL on COM1, then HALT.

JMP @start

.include "../lib/nanobj.nas"

.equ NOBJ_SNAP 0x380000

start:
  MOVI r0,0
  MOVI r13,1
  LA r14,@stack
  CALL @nobj_init

  MOVI r1,7
  MOVI r2,2
  CALL @nobj_create
  CMP r1,r0
  JMP[EQ] @fail
  ST r1,r0,@cap

  LA r3,@wbuf
  MOVI r4,0x1111
  ST r4,r3,0
  MOVI r4,0x2222
  ST r4,r3,1
  LD r1,r0,@cap
  ADD r2,r3,r0
  MOVI r3,0
  MOVI r4,2
  CALL @nobj_write
  MOVI r5,2
  CMP r1,r5
  JMP[NE] @fail

  LA r1,@save_hook
  LA r2,@load_hook
  CALL @nobj_set_io
  LA r1,@snap_path
  SHL r1,r1,2
  CALL @nobj_save
  CMP r1,r0
  JMP[NE] @fail

  ; wipe the live table, then restore from the snapshot
  CALL @nobj_init
  LA r1,@snap_path
  SHL r1,r1,2
  CALL @nobj_load
  CMP r1,r0
  JMP[NE] @fail

  LD r1,r0,@cap
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

  ; corrupt the snapshot magic and require load to reject it
  LA r3,#NOBJ_SNAP
  MOVI r4,0xDEAD
  ST r4,r3,0
  LA r1,@snap_path
  SHL r1,r1,2
  CALL @nobj_load
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[NE] @fail

  LA r1,@passmsg
  CALL @puts
  HALT

fail:
  LA r1,@failmsg
  CALL @puts
  HALT

; save hook: r1=path r2=src r3=words -> 0.  RAM snapshot stub.
save_hook:
  LA r4,#NOBJ_SNAP
  MOVI r5,0
save_l:
  CMP r5,r3
  JMP[GE] @save_d
  LD r6,r2,0
  ST r6,r4,0
  ADD r2,r2,r13
  ADD r4,r4,r13
  ADD r5,r5,r13
  JMP @save_l
save_d:
  MOVI r1,0
  RET

; load hook: r1=path -> r1=src r2=words
load_hook:
  LA r1,#NOBJ_SNAP
  MOVI r2,#NOBJ_TOTAL
  RET

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
.str "NOBJ PERSIST PASS\n"
failmsg:
.str "NOBJ PERSIST FAIL\n"
snap_path:
.str "/nanobj"
cap:
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
