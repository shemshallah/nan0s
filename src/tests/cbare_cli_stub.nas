; cbare_cli_stub.nas - C-ABI POSIX table over the NaN filesystem.
; Placed above the C image at word 0x280000; the table is at 0x296400.
; Pointer rules: word pointers (int*) are shifted right 2; byte buffers
; (paths/names) are passed through.
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
; int cb_stat(const char *path, int *st)
cb_stat:
  MOVI r13,1
  ADDI r10,r14,-2
  LD r1,r10,0
  ADDI r10,r14,-1
  LD r2,r10,0
  SHR r2,r2,2
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @bare_fs_stat
  SUB r14,r14,r13
  LD r15,r14,0
  RET
; int cb_mkdir(const char *path)
cb_mkdir:
  MOVI r13,1
  ADDI r10,r14,-1
  LD r1,r10,0
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @bare_fs_mkdir
  SUB r14,r14,r13
  LD r15,r14,0
  RET
; int cb_rmdir(const char *path)
cb_rmdir:
  MOVI r13,1
  ADDI r10,r14,-1
  LD r1,r10,0
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @bare_fs_rmdir
  SUB r14,r14,r13
  LD r15,r14,0
  RET
; int cb_readdir(const char *path, int *idx, char *name, int max, int *type)
cb_readdir:
  MOVI r13,1
  ADDI r10,r14,-5
  LD r1,r10,0
  ADDI r10,r14,-4
  LD r2,r10,0
  SHR r2,r2,2
  ADDI r10,r14,-3
  LD r3,r10,0
  ADDI r10,r14,-2
  LD r4,r10,0
  ADDI r10,r14,-1
  LD r5,r10,0
  SHR r5,r5,2
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @bare_fs_readdir
  SUB r14,r14,r13
  LD r15,r14,0
  RET
; int cb_access(const char *path)
cb_access:
  MOVI r13,1
  ADDI r10,r14,-1
  LD r1,r10,0
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @bare_fs_access
  SUB r14,r14,r13
  LD r15,r14,0
  RET
; int cb_truncate(const char *path, int len)
cb_truncate:
  MOVI r13,1
  ADDI r10,r14,-2
  LD r1,r10,0
  ADDI r10,r14,-1
  LD r2,r10,0
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @bare_fs_truncate
  SUB r14,r14,r13
  LD r15,r14,0
  RET
.org 0x296400
cb_cli_table:
  .word @cb_load
  .word @cb_save
  .word @cb_remove
  .word @cb_size
  .word @cb_tick
  .word @cb_stat
  .word @cb_mkdir
  .word @cb_rmdir
  .word @cb_readdir
  .word @cb_access
  .word @cb_truncate
