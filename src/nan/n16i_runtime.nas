; n16i_runtime.nas - the first NaN guest: n16i over the scheduler image.
; Loaded at word 0; interprets the scheduler image at 0x800000.
.org 0
  MOVI r0,0
  MOVI r13,1
  LA r14,0x100000
  MOVI r1,0
  LA r2,0x800000
  LA r3,0xEFFFFF
  MOVI r4,78
  PUTC r4
  CALL @n16i_run
  HALT
.include "../tools/n16i.nas"
