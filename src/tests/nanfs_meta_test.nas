; nanfs_meta_test.nas - POSIX metadata on the NaN filesystem.
; mkdir/stat/readdir/rmdir/access/truncate are NaN services in bare.nas.
.org 0
JMP @main
.include "../lib/ncc.nas"
.equ ST  0xF0760
.equ IDX 0xF0740
.equ TYP 0xF0741
.equ NAME 0xF0742
.equ CNT 0xF0743
main:
MOVI r13,1
; ---- mkdir /posix ----
LA r1,@dir
SHL r1,r1,2
CALL @bare_fs_mkdir
CMP r1,r0
JMP[NE] @fail
; ---- two files ----
LA r1,@pa
SHL r1,r1,2
LA r2,@hello
SHL r2,r2,2
MOVI r3,5
CALL @bare_fs_save
CMP r1,r0
JMP[EQ] @fail
LA r1,@pb
SHL r1,r1,2
LA r2,@world
SHL r2,r2,2
MOVI r3,5
CALL @bare_fs_save
CMP r1,r0
JMP[EQ] @fail
; ---- stat the directory ----
LA r1,@dir
SHL r1,r1,2
LA r2,#ST
CALL @bare_fs_stat
CMP r1,r0
JMP[NE] @fail
LD r2,r0,#ST
MOVI r3,1
CMP r2,r3
JMP[NE] @fail
; ---- stat the file ----
LA r1,@pa
SHL r1,r1,2
LA r2,#ST
CALL @bare_fs_stat
CMP r1,r0
JMP[NE] @fail
LD r2,r0,#ST
CMP r2,r0
JMP[NE] @fail
LA r2,#ST
ADD r2,r2,r13
LD r2,r2,0
MOVI r3,5
CMP r2,r3
JMP[NE] @fail
; ---- readdir /posix: exactly two entries ----
MOVI r2,0
ST r2,r0,#IDX
MOVI r2,0
ST r2,r0,#CNT
rd_loop:
LA r1,@dir
SHL r1,r1,2
LA r2,#IDX
LA r3,#NAME
MOVI r4,64
LA r5,#TYP
CALL @bare_fs_readdir
CMP r1,r0
JMP[EQ] @rd_done
LD r2,r0,#CNT
ADD r2,r2,r13
ST r2,r0,#CNT
JMP @rd_loop
rd_done:
LD r2,r0,#CNT
MOVI r3,2
CMP r2,r3
JMP[NE] @fail
; ---- rmdir must fail while non-empty ----
LA r1,@dir
SHL r1,r1,2
CALL @bare_fs_rmdir
CMP r1,r0
JMP[EQ] @fail
; ---- remove children, then rmdir ----
LA r1,@pa
SHL r1,r1,2
CALL @bare_fs_remove
CMP r1,r0
JMP[NE] @fail
LA r1,@pb
SHL r1,r1,2
CALL @bare_fs_remove
CMP r1,r0
JMP[NE] @fail
LA r1,@dir
SHL r1,r1,2
CALL @bare_fs_rmdir
CMP r1,r0
JMP[NE] @fail
LA r1,@dir
SHL r1,r1,2
CALL @bare_fs_access
CMP r1,r0
JMP[NE] @fail
; ---- truncate ----
LA r1,@t
SHL r1,r1,2
LA r2,@ten
SHL r2,r2,2
MOVI r3,10
CALL @bare_fs_save
CMP r1,r0
JMP[EQ] @fail
LA r1,@t
SHL r1,r1,2
MOVI r2,4
CALL @bare_fs_truncate
CMP r1,r0
JMP[NE] @fail
LA r1,@t
SHL r1,r1,2
LA r2,#ST
CALL @bare_fs_stat
CMP r1,r0
JMP[NE] @fail
LA r2,#ST
ADD r2,r2,r13
LD r2,r2,0
MOVI r3,4
CMP r2,r3
JMP[NE] @fail
LA r1,@t
SHL r1,r1,2
CALL @bare_fs_access
CMP r1,r0
JMP[EQ] @fail
LA r1,@t
SHL r1,r1,2
CALL @bare_fs_remove
CMP r1,r0
JMP[NE] @fail
LA r1,@t
SHL r1,r1,2
CALL @bare_fs_access
CMP r1,r0
JMP[NE] @fail
; ---- PASS ----
MOVI r1,80
PUTC r1
MOVI r1,65
PUTC r1
MOVI r1,83
PUTC r1
MOVI r1,83
PUTC r1
MOVI r1,10
PUTC r1
HALT
fail:
MOVI r1,70
PUTC r1
MOVI r1,65
PUTC r1
MOVI r1,73
PUTC r1
MOVI r1,76
PUTC r1
MOVI r1,10
PUTC r1
HALT
dir:
.str "/posix"
pa:
.str "/posix/a"
pb:
.str "/posix/b"
t:
.str "/t"
hello:
.str "hello"
world:
.str "world"
ten:
.str "0123456789"
