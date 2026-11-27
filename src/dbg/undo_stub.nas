; undo_stub.nas - no-op undo recording hooks for standalone core builds.
; alone use these stubs so scalar execution still assembles and runs unchanged.
nd_usave:
  RET
nd_uwr:
  RET
nd_ubulk:
  RET

; standalone PUTC hook: no debug capture, pass through to the host serial
nd_putc_cap:
  LD r4,r5,@nd_regs
  PUTC r4
  JMP @nd_loop
