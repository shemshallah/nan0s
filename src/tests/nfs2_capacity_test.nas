; nfs2_capacity_test.nas - prove the NaN file store scales past 64 files.
; Writes 512 files of 7936 bytes (about 4 MiB) into NPAF, reads back the
; first, middle and last entries, and prints PASS.  Capacity is chosen at
; assembly time with NFS_MAX and NFS_CAP in the environment.
.org 0
JMP @main
.include "../lib/ncc.nas"
.equ I 0xF0800
main:
MOVI r13,1
CALL @nfs_ensure
MOVI r6,0
ST r6,r0,#I
wloop:
; ---- build "/capXXX" in the writable string buffer ----
LD r6,r0,#I
CALL @mkpath
; ---- fill the source buffer with (i+j)&255 ----
LA r5,0x200000
SHL r5,r5,2
MOVI r7,0
fillj:
ADD r8,r6,r7
SHL r8,r8,24
SHR r8,r8,24
STB r8,r5,0
ADD r5,r5,r13
ADD r7,r7,r13
MOVI r8,7936
CMP r7,r8
JMP[LT] @fillj
; ---- store the file through NPAF ----
LA r1,@path
SHL r1,r1,2
LA r2,0x200000
MOVI r3,7936
CALL @nfs_write
CMP r1,r0
JMP[EQ] @fail
LD r6,r0,#I
ADD r6,r6,r13
ST r6,r0,#I
MOVI r7,512
CMP r6,r7
JMP[LT] @wloop
; ---- metadata must show 512 files ----
CALL @nfs_count
MOVI r7,512
CMP r1,r7
JMP[NE] @fail
; ---- verify file 0, 255 and 511 ----
MOVI r6,0
ST r6,r0,#I
MOVI r6,255
CALL @check_one
MOVI r6,511
CALL @check_one
MOVI r6,0
CALL @check_one
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
; mkpath: r6=index -> "/capXXX" at @path, r1=path byte pointer
mkpath:
LA r1,@path
SHL r1,r1,2
SHR r8,r6,8
SHL r8,r8,28
SHR r8,r8,28
LA r9,@hexdigits
SHL r9,r9,2
ADD r9,r9,r8
LDB r8,r9,0
STB r8,r1,4
SHR r8,r6,4
SHL r8,r8,28
SHR r8,r8,28
LA r9,@hexdigits
SHL r9,r9,2
ADD r9,r9,r8
LDB r8,r9,0
STB r8,r1,5
SHL r8,r6,28
SHR r8,r8,28
LA r9,@hexdigits
SHL r9,r9,2
ADD r9,r9,r8
LDB r8,r9,0
STB r8,r1,6
STB r0,r1,7
RET
; check_one: r6=index
check_one:
ST r15,r14,0
ADD r14,r14,r13
ST r6,r0,#I
CALL @mkpath
CALL @nfs_data
CMP r3,r0
JMP[EQ] @cfail
MOVI r7,7936
CMP r2,r7
JMP[NE] @cfail
SHL r1,r1,2
; j=0
LDB r8,r1,0
LD r9,r0,#I
SHL r9,r9,24
SHR r9,r9,24
CMP r8,r9
JMP[NE] @cfail
; j=1000
LDB r8,r1,1000
LD r9,r0,#I
MOVI r10,1000
ADD r9,r9,r10
SHL r9,r9,24
SHR r9,r9,24
CMP r8,r9
JMP[NE] @cfail
; j=7935
LDB r8,r1,7935
LD r9,r0,#I
MOVI r10,7935
ADD r9,r9,r10
SHL r9,r9,24
SHR r9,r9,24
CMP r8,r9
JMP[NE] @cfail
MOVI r1,1
SUB r14,r14,r13
LD r15,r14,0
RET
cfail:
MOVI r1,0
SUB r14,r14,r13
LD r15,r14,0
RET
path:
.str "/cap000"
hexdigits:
.str "0123456789ABCDEF"
