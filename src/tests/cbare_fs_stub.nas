; cbare_fs_stub.nas - C-ABI trampolines over the NaN16 machine FS.
; Placed at word 0x10000; the call table lives at word 0x20400.
; TCC C ABI: at entry SP points past the pushed arguments, so the last
; argument is at SP-1 and earlier arguments below it.  The machine FS
; functions take arguments in r1..r3 and preserve the hardware link.
.org 0x10000
.include "../lib/ncc.nas"
.org 0x20000
; int cb_open(const char *path, int mode)
cb_open:
  MOVI r13,1
  ADDI r10,r14,-2
  LD r1,r10,0
  ADDI r10,r14,-1
  LD r2,r10,0
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @bare_fs_open
  SUB r14,r14,r13
  LD r15,r14,0
  RET
; int cb_write(int h, const void *buf, int len)
cb_write:
  MOVI r13,1
  ADDI r10,r14,-3
  LD r1,r10,0
  ADDI r10,r14,-2
  LD r2,r10,0
  ADDI r10,r14,-1
  LD r3,r10,0
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @bare_fs_write
  SUB r14,r14,r13
  LD r15,r14,0
  RET
; int cb_read(int h, void *buf, int len)
cb_read:
  MOVI r13,1
  ADDI r10,r14,-3
  LD r1,r10,0
  ADDI r10,r14,-2
  LD r2,r10,0
  ADDI r10,r14,-1
  LD r3,r10,0
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @bare_fs_read
  SUB r14,r14,r13
  LD r15,r14,0
  RET
; int cb_close(int h)
cb_close:
  MOVI r13,1
  ADDI r10,r14,-1
  LD r1,r10,0
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @bare_fs_close
  SUB r14,r14,r13
  LD r15,r14,0
  RET
; probe: int cb_add(int a, int b)
cb_add:
  ADDI r10,r14,-2
  LD r1,r10,0
  ADDI r10,r14,-1
  LD r2,r10,0
  ADD r1,r1,r2
  RET
.org 0x20400
cb_fs_table:
  .word @cb_open
  .word @cb_write
  .word @cb_read
  .word @cb_close
  .word @cb_add
