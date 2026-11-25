; cbare_stub.nas - minimal NaN16 machine-interface service table.
; C ABI: first argument word is just below SP at entry.  Use scratch r10.
.equ CB_W 0x00C00000
cb_putc:
  ADDI r10,r14,-1
  LD r1,r10,0
  PUTC r1
  MOVI r1,0
  RET
cb_tick:
  TICK r1
  RET
cb_table:
  .word 0x00C00000
  .word 0x00C00005
