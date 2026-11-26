; nantensor_test.nas - M1b tensor metadata/view and namespace self-test.
; Prints NTENSOR PASS or NTENSOR FAIL on COM1, then HALT.

JMP @start

.include "../lib/nantensor.nas"

start:
  MOVI r0,0
  MOVI r13,1
  LA r14,@stack
  CALL @nobj_init

  ; storage BLOB, 4 words
  MOVI r1,#NT_CLASS_BLOB
  MOVI r2,4
  CALL @nobj_create
  CMP r1,r0
  JMP[EQ] @fail
  ST r1,r0,@storage

  ; tensor dtype=0 rank=2 shape=[2,3] storage
  MOVI r1,0
  MOVI r2,2
  LA r3,@shape23
  LD r4,r0,@storage
  CALL @ntensor_create
  CMP r1,r0
  JMP[EQ] @fail
  ST r1,r0,@tensor
  ; shape metadata
  LD r1,r0,@tensor
  LA r2,@hdr
  CALL @ntensor_shape
  CMP r1,r0
  JMP[NE] @fail
  LA r3,@hdr
  LD r4,r3,0
  CMP r4,r0
  JMP[NE] @fail
  LD r4,r3,1
  MOVI r5,2
  CMP r4,r5
  JMP[NE] @fail
  LD r4,r3,21
  MOVI r5,6
  CMP r4,r5
  JMP[NE] @fail
  LD r4,r3,5
  MOVI r5,2
  CMP r4,r5
  JMP[NE] @fail
  LD r4,r3,6
  MOVI r5,3
  CMP r4,r5
  JMP[NE] @fail
  LD r4,r3,13
  MOVI r5,3
  CMP r4,r5
  JMP[NE] @fail
  LD r4,r3,14
  MOVI r5,1
  CMP r4,r5
  JMP[NE] @fail
  LD r4,r3,3
  LD r5,r0,@storage
  CMP r4,r5
  JMP[NE] @fail

  ; view offset 1 shape=[2,2]
  LD r1,r0,@tensor
  MOVI r2,1
  LA r3,@shape22
  MOVI r4,2
  CALL @ntensor_view
  CMP r1,r0
  JMP[EQ] @fail
  ST r1,r0,@view

  LD r1,r0,@view
  LA r2,@hdr
  CALL @ntensor_shape
  CMP r1,r0
  JMP[NE] @fail
  LA r3,@hdr
  LD r4,r3,21
  MOVI r5,4
  CMP r4,r5
  JMP[NE] @fail
  LD r4,r3,4
  MOVI r5,1
  CMP r4,r5
  JMP[NE] @fail
  LD r4,r3,2
  MOVI r5,#NT_FLAG_VIEW
  BOOL.8 r4,r4,r5
  CMP r4,r5
  JMP[NE] @fail
  LD r4,r3,3
  LD r5,r0,@storage
  CMP r4,r5
  JMP[NE] @fail

  ; namespace
  CALL @nns_create
  CMP r1,r0
  JMP[EQ] @fail
  ST r1,r0,@ns

  LD r1,r0,@ns
  LA r2,@name_model
  SHL r2,r2,2
  LD r3,r0,@tensor
  CALL @nns_set
  CMP r1,r0
  JMP[NE] @fail

  LD r1,r0,@ns
  LA r2,@name_model
  SHL r2,r2,2
  CALL @nns_get
  LD r3,r0,@tensor
  CMP r1,r3
  JMP[NE] @fail

  LD r1,r0,@ns
  LA r2,@name_missing
  SHL r2,r2,2
  CALL @nns_get
  CMP r1,r0
  JMP[NE] @fail

  LD r1,r0,@ns
  LA r2,@name_view
  SHL r2,r2,2
  LD r3,r0,@view
  CALL @nns_set
  CMP r1,r0
  JMP[NE] @fail
  LD r1,r0,@ns
  LA r2,@name_view
  SHL r2,r2,2
  CALL @nns_get
  LD r3,r0,@view
  CMP r1,r3
  JMP[NE] @fail

  ; tensor storage cap survives the view
  LD r1,r0,@view
  CALL @ntensor_storage
  LD r3,r0,@storage
  CMP r1,r3
  JMP[NE] @fail

  LA r1,@passmsg
  CALL @puts
  HALT

fail:
  LA r1,@failmsg
  CALL @puts
  HALT

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
.str "NTENSOR PASS\n"
failmsg:
.str "NTENSOR FAIL\n"
name_model:
.str "model"
name_view:
.str "view"
name_missing:
.str "missing"
shape23:
.word 2,3
shape22:
.word 2,2
storage:
.word 0
tensor:
.word 0
view:
.word 0
ns:
.word 0
hdr:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
stack:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
