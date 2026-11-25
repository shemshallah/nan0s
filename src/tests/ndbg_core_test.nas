; ndbg_core_test.nas - exercise the reusable step core on a real target.
; The target is the same shape as the proof target: a counted loop, a breakpoint
; site, a single step, then HALT. This isolates the engine from the type proof.
.org 0
JMP @main
.include "../dbg/core.nas"
.include "../dbg/undo_stub.nas"

main:
  MOVI r13,1
  CALL @nd_reset
  MOVI r1,@tgt_entry
  ST r1,r0,@nd_pc
  MOVI r1,1000
  CALL @nd_run
  LD r2,r0,@nd_status
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @fail
  MOVI r1,1
  LD r1,r1,@nd_regs
  MOVI r2,5
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,2
  LD r1,r1,@nd_regs
  MOVI r2,15
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,4
  LD r1,r1,@nd_regs
  MOVI r2,42
  CMP r1,r2
  JMP[NE] @fail
  ; packed flight entry: first fetch is MOVI (op 1) at 0x2000
  LA r1,0x32000
  LD r1,r1,0
  SHR r1,r1,16
  MOVI r2,1
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
.str "CORE PASS\n"
s_bad:
.str "CORE FAIL\n"

.org 8192
tgt_entry:
  MOVI r1,0
  MOVI r2,0
tgt_loop:
  ADD r1,r1,r13
  ADD r2,r2,r1
  MOVI r3,5
  CMP r1,r3
  JMP[LT] @tgt_loop
tgt_hit:
  MOVI r4,42
  HALT
