; nfs2 host test: format, write, find, read, list, delete.
.org 0
JMP @main
.include "../lib/nfs2.nas"
main:
MOVI r13,1
CALL @nfs_format
LA r1,@p1
SHL r1,r1,2
LA r2,@d1
MOVI r3,5
CALL @nfs_write
CMP r1,r0
JMP[EQ] @fail
LA r1,@p2
SHL r1,r1,2
LA r2,@d2
MOVI r3,3
CALL @nfs_write
CMP r1,r0
JMP[EQ] @fail
CALL @nfs_count
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LA r1,@p1
SHL r1,r1,2
CALL @nfs_data
CMP r3,r0
JMP[EQ] @fail
SHL r1,r1,2
MOVI r4,5
prt:
LDB r5,r1,0
ADD r0,r0,r0
ADD r5,r5,r0
PUTC r5
ADD r1,r1,r13
SUB r4,r4,r13
CMP r4,r0
JMP[NE] @prt
MOVI r1,10
PUTC r1
LA r1,@p1
SHL r1,r1,2
CALL @nfs_delete
CMP r1,r0
JMP[EQ] @fail
CALL @nfs_count
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
MOVI r1,79
PUTC r1
MOVI r1,75
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
p1:
.str "/hello.c"
p2:
.str "/dir/x"
d1:
.str "hello"
d2:
.str "abc"
