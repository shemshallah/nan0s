; ndbg_guard_test.nas - containment and watchpoint tests for core.nas.
; 1. A target write below nd_wlo faults with MEMORY / RANGE.
; 2. A watched write stops before the store with INFO / WATCH, old/new in the
;    record; the old value is still in memory; a later step performs the write.
.org 0
JMP @main
.include "../dbg/core.nas"
.include "../dbg/undo_stub.nas"
.include "../dbg/ndr_stub.nas"

main:
  MOVI r13,1

  ; ---- guard: write to word 0x0100 must fault --------------------------------
  CALL @nd_reset
  MOVI r1,8192
  ST r1,r0,@nd_pc
  MOVI r1,8192
  ST r1,r0,@nd_wlo
  LA r1,0xFFFFFFFF
  ST r1,r0,@nd_whi
  LA r1,0xFFFFFFFF
  ST r1,r0,@nd_watch
  MOVI r1,1000
  CALL @nd_run
  LD r2,r0,@nd_status
  MOVI r3,3
  CMP r2,r3
  JMP[NE] @fail
  LD r2,r0,@nd_reason
  MOVI r3,0x40
  CMP r2,r3
  JMP[NE] @fail
  MOVI r1,@nd_rec
  LDN r2,r1,0
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @fail
  LD r2,r0,@nd_rec
  SHR r2,r2,24
  MOVI r3,0x40
  CMP r2,r3
  JMP[NE] @fail
  MOVI r1,@s_guard
  CALL @nd_puts

  ; ---- watch: a watched store stops before writing ---------------------------
  CALL @nd_reset
  MOVI r1,0xAAAA
  MOVI r2,0x3000
  ST r1,r2,0
  MOVI r1,0x3000
  ST r1,r0,@nd_watch
  MOVI r1,@t_watch
  ST r1,r0,@nd_pc
  MOVI r1,1000
  CALL @nd_run
  LD r2,r0,@nd_status
  MOVI r3,2
  CMP r2,r3
  JMP[NE] @fail
  LD r2,r0,@nd_reason
  MOVI r3,3
  CMP r2,r3
  JMP[NE] @fail
  MOVI r1,0x3000
  LD r2,r1,0
  MOVI r3,0xAAAA
  CMP r2,r3
  JMP[NE] @fail
  ; the record carries old=AAAA, new=5678
  MOVI r1,@nd_rec
  MOVI r2,2
  ADD r1,r1,r2
  LD r2,r1,0
  MOVI r3,0xAAAA
  CMP r2,r3
  JMP[NE] @fail
  MOVI r1,@nd_rec
  MOVI r2,3
  ADD r1,r1,r2
  LD r2,r1,0
  MOVI r3,0x5678
  CMP r2,r3
  JMP[NE] @fail

  ; clear the watch and step; the store must now happen
  LA r1,0xFFFFFFFF
  ST r1,r0,@nd_watch
  CALL @nd_step
  MOVI r1,0x3000
  LD r2,r1,0
  MOVI r3,0x5678
  CMP r2,r3
  JMP[NE] @fail
  MOVI r1,@s_watch
  CALL @nd_puts

  MOVI r1,@s_pass
  CALL @nd_puts
  HALT

fail:
  MOVI r1,@s_fail
  CALL @nd_puts
  HALT

s_guard:
.str "GUARD PASS\n"
s_watch:
.str "WATCH PASS\n"
s_pass:
.str "SAFE PASS\n"
s_fail:
.str "SAFE FAIL\n"

.org 8192
; write to a protected low word
t_guard:
  MOVI r1,0x1234
  MOVI r2,0x0100
  ST r1,r2,0
  HALT

; write to the watched word
t_watch:
  MOVI r1,0x5678
  MOVI r2,0x3000
  ST r1,r2,0
  HALT
