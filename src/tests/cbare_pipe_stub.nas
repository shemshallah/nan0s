; cbare_pipe_stub.nas - C-ABI table over the NaN16 byte-pipe primitive.
; Placed above the C image at word 0x280000; the table is at 0x296400
; (guest C byte address 0xA59000).  All pipe storage and byte movement is
; in ../lib/nanpipe.nas; these wrappers only translate the TCC C ABI.
;
; The TCC NaN16 ABI reserves r12 as the C frame pointer.  np_write uses r12
; as a capacity scratch register, so every wrapper saves/restores it around
; the primitive call; the C caller also expects r13=1 and r15 preserved.
.org 0x280000
.include "../lib/ncc.nas"
.include "../lib/nanpipe.nas"
.org 0x296000
; int np_c_open(void)
np_c_open:
  MOVI r13,1
  ST r15,r14,0
  ST r12,r14,1
  ADDI r14,r14,2
  CALL @np_open
  ADDI r14,r14,-2
  LD r15,r14,0
  LD r12,r14,1
  RET
; int np_c_write(int id, const void *src, int len)
np_c_write:
  MOVI r13,1
  ADDI r10,r14,-3
  LD r1,r10,0
  ADDI r10,r14,-2
  LD r2,r10,0
  ADDI r10,r14,-1
  LD r3,r10,0
  ST r15,r14,0
  ST r12,r14,1
  ADDI r14,r14,2
  CALL @np_write
  ADDI r14,r14,-2
  LD r15,r14,0
  LD r12,r14,1
  RET
; int np_c_read(int id, void *dst, int len)
np_c_read:
  MOVI r13,1
  ADDI r10,r14,-3
  LD r1,r10,0
  ADDI r10,r14,-2
  LD r2,r10,0
  ADDI r10,r14,-1
  LD r3,r10,0
  ST r15,r14,0
  ST r12,r14,1
  ADDI r14,r14,2
  CALL @np_read
  ADDI r14,r14,-2
  LD r15,r14,0
  LD r12,r14,1
  RET
; int np_c_close(int id)
np_c_close:
  MOVI r13,1
  ADDI r10,r14,-1
  LD r1,r10,0
  ST r15,r14,0
  ST r12,r14,1
  ADDI r14,r14,2
  CALL @np_close
  ADDI r14,r14,-2
  LD r15,r14,0
  LD r12,r14,1
  RET
.org 0x296400
np_c_table:
  .word @np_c_open
  .word @np_c_write
  .word @np_c_read
  .word @np_close
