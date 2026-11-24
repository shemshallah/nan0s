; nfs2_extra_test.nas - stat/readdir/rename/truncate checks for NPAF.
; Oracle gate today; the same image is ISA-neutral for the x86_64 S1.
.equ STACK 0x7000
.org 0
JMP @main

ata_present:
MOVI r1,0
RET
bare_table:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

main:
MOVI r13,1
MOVI r14,#STACK
CALL @nfs_format
LA r1,@s_d
SHL r1,r1,2
MOVI r2,1
CALL @nfs_create
CMP r1,r0
JMP[EQ] @bad1
LA r1,@s_d
SHL r1,r1,2
CALL @nfs_is_dir
CMP r1,r13
JMP[NE] @bad2
LA r1,@s_da
SHL r1,r1,2
LA r2,@s_hi
SHR r2,r2,2
MOVI r3,2
CALL @nfs_write
CMP r1,r0
JMP[EQ] @bad3
LA r1,@s_db
SHL r1,r1,2
LA r2,@s_yo
SHR r2,r2,2
MOVI r3,2
CALL @nfs_write
CMP r1,r0
JMP[EQ] @bad4
LA r1,@s_d
SHL r1,r1,2
MOVI r2,0
CALL @nfs_readdir
CMP r1,r0
JMP[EQ] @bad5
MOVI r4,2
CMP r3,r4
JMP[NE] @bad6
LA r1,@s_d
SHL r1,r1,2
MOVI r2,1
CALL @nfs_readdir
CMP r1,r0
JMP[EQ] @bad7
LA r1,@s_d
SHL r1,r1,2
MOVI r2,2
CALL @nfs_readdir
CMP r1,r0
JMP[NE] @bad8
LA r1,@s_da
SHL r1,r1,2
CALL @nfs_stat
CMP r3,r13
JMP[NE] @bad9
MOVI r4,2
CMP r1,r4
JMP[NE] @bad10
LA r1,@s_da
SHL r1,r1,2
LA r2,@s_dc
SHL r2,r2,2
CALL @nfs_rename
CMP r1,r13
JMP[NE] @bad11
LA r1,@s_da
SHL r1,r1,2
CALL @nfs_stat
CMP r3,r0
JMP[NE] @bad12
LA r1,@s_dc
SHL r1,r1,2
CALL @nfs_stat
CMP r3,r13
JMP[NE] @bad13
MOVI r4,2
CMP r1,r4
JMP[NE] @bad13
LA r1,@s_dc
SHL r1,r1,2
CALL @nfs_truncate
CMP r1,r13
JMP[NE] @bad14
LA r1,@s_dc
SHL r1,r1,2
CALL @nfs_stat
CMP r1,r0
JMP[NE] @bad15
LA r1,@s_c_pass
CALL @puts_nfs
HALT

bad1:
MOVI r10,1
LA r1,@s_b1
JMP @fail
bad2:
MOVI r10,2
LA r1,@s_b2
JMP @fail
bad3:
MOVI r10,3
LA r1,@s_b3
JMP @fail
bad4:
MOVI r10,4
LA r1,@s_b4
JMP @fail
bad5:
MOVI r10,5
LA r1,@s_b5
JMP @fail
bad6:
MOVI r10,6
LA r1,@s_b6
JMP @fail
bad7:
MOVI r10,7
LA r1,@s_b7
JMP @fail
bad8:
MOVI r10,8
LA r1,@s_b8
JMP @fail
bad9:
MOVI r10,9
LA r1,@s_b9
JMP @fail
bad10:
MOVI r10,10
LA r1,@s_b10
JMP @fail
bad11:
MOVI r10,11
LA r1,@s_b11
JMP @fail
bad12:
MOVI r10,12
LA r1,@s_b12
JMP @fail
bad13:
MOVI r10,13
LA r1,@s_b13
JMP @fail
bad14:
MOVI r10,14
LA r1,@s_b14
JMP @fail
bad15:
MOVI r10,15
LA r1,@s_b15
fail:
MOVI r1,48
ADD r1,r1,r10
PUTC r1
MOVI r1,32
PUTC r1
CALL @puts_nfs
LA r1,@s_fail
CALL @puts_nfs
HALT

puts_nfs:
SHL r1,r1,2
pn_loop:
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @pn_d
PUTC r2
ADD r1,r1,r13
JMP @pn_loop
pn_d:
RET

s_d:
.str "/d"
s_da:
.str "/d/a"
s_db:
.str "/d/b"
s_dc:
.str "/d/c"
s_hi:
.str "hi"
s_yo:
.str "yo"
s_c_pass:
.str "NFS2 EXTRA PASS\n"
s_fail:
.str "FAIL\n"
s_b1:
.str "create-d\n"
s_b2:
.str "isdir-d\n"
s_b3:
.str "write-a\n"
s_b4:
.str "write-b\n"
s_b5:
.str "readdir0\n"
s_b6:
.str "readdir-size\n"
s_b7:
.str "readdir1\n"
s_b8:
.str "readdir2\n"
s_b9:
.str "stat-found\n"
s_b10:
.str "stat-size\n"
s_b11:
.str "rename\n"
s_b12:
.str "old-gone\n"
s_b13:
.str "new-found\n"
s_b14:
.str "truncate\n"
s_b15:
.str "trunc-size\n"

.include "../lib/nfs2.nas"
