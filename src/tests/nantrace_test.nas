; nantrace_test.nas - M2b hash-chained trace seal/verify/tamper test.
; Prints NTRACE PASS or NTRACE FAIL on COM1, then HALT.

JMP @start

.include "../lib/nantrace.nas"

start:
  MOVI r0,0
  MOVI r13,1
  LA r14,@stack
  CALL @nobj_init

  ; storage BLOB, 16 words = 4 events
  MOVI r1,2
  MOVI r2,16
  CALL @nobj_create
  CMP r1,r0
  JMP[EQ] @fail
  ST r1,r0,@storage

  LD r1,r0,@storage
  CALL @ntrace_create
  CMP r1,r0
  JMP[EQ] @fail
  ST r1,r0,@trace

  ; append three events
  LD r1,r0,@trace
  MOVI r2,1
  MOVI r3,0x1111
  MOVI r4,0xAAAA
  CALL @ntrace_append
  CMP r1,r0
  JMP[NE] @fail
  LD r1,r0,@trace
  MOVI r2,2
  MOVI r3,0x2222
  MOVI r4,0xBBBB
  CALL @ntrace_append
  MOVI r5,1
  CMP r1,r5
  JMP[NE] @fail
  LD r1,r0,@trace
  MOVI r2,3
  MOVI r3,0x3333
  MOVI r4,0xCCCC
  CALL @ntrace_append
  MOVI r5,2
  CMP r1,r5
  JMP[NE] @fail

  ; seal and verify
  LD r1,r0,@trace
  CALL @ntrace_seal
  CMP r1,r0
  JMP[EQ] @fail
  ST r1,r0,@head
  LD r1,r0,@trace
  CALL @ntrace_verify
  CMP r1,r0
  JMP[NE] @fail

  ; tamper event 1 kind, verification must fail
  MOVI r1,0xBAD
  ST r1,r0,@evil
  LD r1,r0,@storage
  LA r2,@evil
  MOVI r3,4
  MOVI r4,1
  CALL @nobj_write
  MOVI r5,1
  CMP r1,r5
  JMP[NE] @fail
  LD r1,r0,@trace
  CALL @ntrace_verify
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
.str "NTRACE PASS\n"
failmsg:
.str "NTRACE FAIL\n"
storage:
.word 0
trace:
.word 0
head:
.word 0
evil:
.word 0
stack:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
