; cbare_sqlite_stub.nas - C-ABI trampolines over the NaN16 file services.
; Assembled above the C image (word 0x280000); the call table is at
; word 0x296400.  TCC's C ABI places the last argument at SP-1.
.org 0x280000
.include "../lib/ncc.nas"
.org 0x296000
; int cb_load(const char *path, void *dst, int max)
cb_load:
  MOVI r13,1
  ADDI r10,r14,-3
  LD r1,r10,0
  ADDI r10,r14,-2
  LD r2,r10,0
  ADDI r10,r14,-1
  LD r3,r10,0
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @bare_fs_load
  SUB r14,r14,r13
  LD r15,r14,0
  RET
; int cb_save(const char *path, const void *src, int len)
cb_save:
  MOVI r13,1
  ADDI r10,r14,-3
  LD r1,r10,0
  ADDI r10,r14,-2
  LD r2,r10,0
  ADDI r10,r14,-1
  LD r3,r10,0
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @bare_fs_save
  SUB r14,r14,r13
  LD r15,r14,0
  RET
; int cb_remove(const char *path)
cb_remove:
  MOVI r13,1
  ADDI r10,r14,-1
  LD r1,r10,0
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @bare_fs_remove
  SUB r14,r14,r13
  LD r15,r14,0
  RET
; int cb_size(const char *path)
cb_size:
  MOVI r13,1
  ADDI r10,r14,-1
  LD r1,r10,0
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @bare_fs_size
  SUB r14,r14,r13
  LD r15,r14,0
  RET
; int cb_tick(void)
cb_tick:
  TICK r1
  RET
.org 0x296400
cb_sql_table:
  .word @cb_load
  .word @cb_save
  .word @cb_remove
  .word @cb_size
  .word @cb_tick
