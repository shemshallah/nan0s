; ndbg_diff_debug.nas - run the same differential target through the NANDBG core.
.org 0
JMP @main
.include "../dbg/core.nas"
.include "../dbg/undo_stub.nas"

main:
  MOVI r13,1
  CALL @nd_reset
  MOVI r1,8192
  ST r1,r0,@nd_pc
  LA r1,0xFFFFFFFF
  ST r1,r0,@nd_brk
  LA r1,1000000
  CALL @nd_run
  LD r2,r0,@nd_status
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @dbg_fail
  HALT
dbg_fail:
  MOVI r1,@s_dbgfail
  CALL @nd_puts
  HALT
s_dbgfail:
.str "DBG FAIL\n"

.org 8192
.include "ndbg_diff_body.nas"
