; nfs2.nas — path-addressed NaN file store (NPAF), raw NaN16, RAM only.
; Paths are absolute byte strings up to 31 chars. Files and directories live
; in a flat table keyed by full path; the arena stores packed bytes (4/word).
; API (r0=0, r13=1):
;   nfs_format                 -> reset the store
;   nfs_count                  -> r1=number of live entries
;   nfs_entry   r1=index       -> r1=entry or 0
;   nfs_find    r1=path        -> r1=entry or 0
;   nfs_create  r1=path r2=dir -> r1=entry or 0
;   nfs_delete  r1=path        -> r1=1 removed / 0 absent
;   nfs_write   r1=path r2=src r3=bytes -> r1=entry or 0
;   nfs_data    r1=path        -> r1=data word ptr r2=bytes r3=found
.equ NFS_BASE    2250000
.equ NFS_MAGIC   0x4E504146
.equ NFS_MAX     64
.equ NFS_ARENA   2251032
.equ NFS_CAP     400000
.equ NF_E_USED   0
.equ NF_E_DIR    1
.equ NF_E_SIZE   2
.equ NF_E_OFF    3
.equ NF_E_PLEN   4
.equ NF_E_PATH   5
.equ NF_E_SZ     16

.equ W_NF_PATH 0xF0532
.equ W_NF_SRC  0xF0533
.equ W_NF_SIZE 0xF0534
.equ W_NF_ENT  0xF0535
.equ W_NF_DIR  0xF0536
.equ W_NF_IDX  0xF0537
.equ NFS_DISK_LBA 2048
.equ NFS_HDR 11023000

nfs_format:
ST r15,r14,0
ADD r14,r14,r13
LA r1,#NFS_BASE
LA r2,0x4E504146
ST r2,r1,0
ST r0,r1,1
ST r0,r1,2
LA r2,#NFS_CAP
ST r2,r1,3
MOVI r2,#NFS_MAX
ST r2,r1,4
MOVI r2,1
ST r2,r1,5
MOVI r3,0
nfs_fmt_l:
MOVI r4,#NFS_MAX
CMP r3,r4
JMP[GE] @nfs_fmt_d
MOVI r4,#NF_E_SZ
MUL r4,r3,r4
LA r5,#NFS_BASE
ADDI r5,r5,8
ADD r4,r4,r5
ST r0,r4,#NF_E_USED
ADD r3,r3,r13
JMP @nfs_fmt_l
nfs_fmt_d:
SUB r14,r14,r13
LD r15,r14,0
RET

nfs_count:
LA r1,#NFS_BASE
LD r1,r1,1
RET

; nf2_streq: r1,r2 byte strings -> 1/0
nf2_streq:
nf2_se_l:
LDB r3,r1,0
LDB r4,r2,0
CMP r3,r4
JMP[NE] @nf2_se_n
CMP r3,r0
JMP[EQ] @nf2_se_y
ADD r1,r1,r13
ADD r2,r2,r13
JMP @nf2_se_l
nf2_se_y:
MOVI r1,1
RET
nf2_se_n:
MOVI r1,0
RET

; nf2_strcpy: r1=dst r2=src r3=max -> r1=len
nf2_strcpy:
ST r15,r14,0
ADD r14,r14,r13
MOVI r4,0
nf2_sc_l:
CMP r4,r3
JMP[GE] @nf2_sc_d
LDB r5,r2,0
CMP r5,r0
JMP[EQ] @nf2_sc_d
STB r5,r1,0
ADD r1,r1,r13
ADD r2,r2,r13
ADD r4,r4,r13
JMP @nf2_sc_l
nf2_sc_d:
STB r0,r1,0
ADD r1,r4,r0
SUB r14,r14,r13
LD r15,r14,0
RET

nfs_find:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_NF_PATH
ST r0,r0,#W_NF_IDX
nfs_f_l:
LD r2,r0,#W_NF_IDX
MOVI r3,#NFS_MAX
CMP r2,r3
JMP[GE] @nfs_f_n
MOVI r3,#NF_E_SZ
MUL r3,r2,r3
LA r4,#NFS_BASE
ADDI r4,r4,8
ADD r3,r3,r4
ST r3,r0,#W_NF_ENT
LD r4,r3,#NF_E_USED
CMP r4,r0
JMP[EQ] @nfs_f_nx
ADDI r1,r3,#NF_E_PATH
SHL r1,r1,2
LD r2,r0,#W_NF_PATH
CALL @nf2_streq
CMP r1,r0
JMP[EQ] @nfs_f_nx
LD r1,r0,#W_NF_ENT
JMP @nfs_f_d
nfs_f_nx:
LD r2,r0,#W_NF_IDX
ADD r2,r2,r13
ST r2,r0,#W_NF_IDX
JMP @nfs_f_l
nfs_f_n:
MOVI r1,0
nfs_f_d:
SUB r14,r14,r13
LD r15,r14,0
RET

nfs_entry:
ST r15,r14,0
ADD r14,r14,r13
MOVI r2,#NFS_MAX
CMP r1,r2
JMP[GE] @nfs_e_n
MOVI r2,#NF_E_SZ
MUL r2,r1,r2
LA r3,#NFS_BASE
ADDI r3,r3,8
ADD r2,r2,r3
LD r3,r2,#NF_E_USED
CMP r3,r0
JMP[EQ] @nfs_e_n
ADD r1,r2,r0
JMP @nfs_e_d
nfs_e_n:
MOVI r1,0
nfs_e_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; nfs_create: r1=path r2=dir -> entry or 0
nfs_create:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_NF_PATH
ST r2,r0,#W_NF_DIR
CALL @nfs_find
CMP r1,r0
JMP[NE] @nfs_c_d
ST r0,r0,#W_NF_IDX
nfs_c_l:
LD r2,r0,#W_NF_IDX
MOVI r3,#NFS_MAX
CMP r2,r3
JMP[GE] @nfs_c_n
MOVI r3,#NF_E_SZ
MUL r3,r2,r3
LA r4,#NFS_BASE
ADDI r4,r4,8
ADD r3,r3,r4
ST r3,r0,#W_NF_ENT
LD r4,r3,#NF_E_USED
CMP r4,r0
JMP[EQ] @nfs_c_use
LD r2,r0,#W_NF_IDX
ADD r2,r2,r13
ST r2,r0,#W_NF_IDX
JMP @nfs_c_l
nfs_c_use:
MOVI r4,1
ST r4,r3,#NF_E_USED
LD r4,r0,#W_NF_DIR
ST r4,r3,#NF_E_DIR
ST r0,r3,#NF_E_SIZE
ST r0,r3,#NF_E_OFF
ADDI r1,r3,#NF_E_PATH
SHL r1,r1,2
LD r2,r0,#W_NF_PATH
MOVI r3,31
CALL @nf2_strcpy
LD r2,r0,#W_NF_ENT
ST r1,r2,#NF_E_PLEN
LA r3,#NFS_BASE
LD r4,r3,1
ADD r4,r4,r13
ST r4,r3,1
ADD r1,r2,r0
ST r1,r14,0
ADD r14,r14,r13
CALL @nfs_sync
SUB r14,r14,r13
LD r1,r14,0
JMP @nfs_c_d
nfs_c_n:
MOVI r1,0
nfs_c_d:
SUB r14,r14,r13
LD r15,r14,0
RET

nfs_delete:
ST r15,r14,0
ADD r14,r14,r13
CALL @nfs_find
CMP r1,r0
JMP[EQ] @nfs_d_n
ST r0,r1,#NF_E_USED
LA r2,#NFS_BASE
LD r3,r2,1
CMP r3,r0
JMP[EQ] @nfs_d_ok
SUB r3,r3,r13
ST r3,r2,1
nfs_d_ok:
MOVI r1,1
ST r1,r14,0
ADD r14,r14,r13
CALL @nfs_sync
SUB r14,r14,r13
LD r1,r14,0
JMP @nfs_d
nfs_d_n:
MOVI r1,0
nfs_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; nfs_write: r1=path r2=src word ptr r3=bytes -> entry or 0
nfs_write:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_NF_PATH
ST r2,r0,#W_NF_SRC
ST r3,r0,#W_NF_SIZE
MOVI r2,0
CALL @nfs_create
CMP r1,r0
JMP[EQ] @nfs_w_d
ST r1,r0,#W_NF_ENT
LA r2,#NFS_BASE
LD r3,r2,2
LD r4,r0,#W_NF_SIZE
ADDI r5,r4,3
SHR r5,r5,2
ADDI r5,r5,1
ADD r6,r3,r5
LA r7,#NFS_CAP
CMP r6,r7
JMP[LE] @nfs_w_room
MOVI r1,0
JMP @nfs_w_d
nfs_w_room:
ST r6,r2,2
LD r1,r0,#W_NF_ENT
ST r3,r1,#NF_E_OFF
ST r4,r1,#NF_E_SIZE
LA r1,#NFS_ARENA
ADD r1,r1,r3
SHL r1,r1,2
LD r2,r0,#W_NF_SRC
SHL r2,r2,2
LD r3,r0,#W_NF_SIZE
nfs_w_cp:
CMP r3,r0
JMP[EQ] @nfs_w_pad
LDB r4,r2,0
STB r4,r1,0
ADD r1,r1,r13
ADD r2,r2,r13
SUB r3,r3,r13
JMP @nfs_w_cp
nfs_w_pad:
STB r0,r1,0
ADD r1,r1,r13
STB r0,r1,0
ADD r1,r1,r13
STB r0,r1,0
ADD r1,r1,r13
STB r0,r1,0
LD r1,r0,#W_NF_ENT
ST r1,r14,0
ADD r14,r14,r13
CALL @nfs_sync
SUB r14,r14,r13
LD r1,r14,0
nfs_w_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; nfs_data: r1=path -> r1=data word ptr r2=size r3=found
nfs_data:
ST r15,r14,0
ADD r14,r14,r13
CALL @nfs_find
CMP r1,r0
JMP[EQ] @nfs_dd_n
LD r2,r1,#NF_E_SIZE
LD r3,r1,#NF_E_OFF
LA r1,#NFS_ARENA
ADD r1,r1,r3
MOVI r3,1
JMP @nfs_dd
nfs_dd_n:
MOVI r1,0
MOVI r2,0
MOVI r3,0
nfs_dd:
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- persistence over ATA primary master ---------------------------
; Snapshot: header sector (magic, word count) at LBA 4096, then the live
; NFS words (entries + arena) as consecutive sectors.
nfs_sync:
ST r15,r14,0
ADD r14,r14,r13
CALL @ata_present
CMP r1,r0
JMP[EQ] @nsy_d
LA r1,#NFS_HDR
LA r2,0x4E465359
ST r2,r1,0
LA r2,#NFS_BASE
LD r3,r2,2
ADDI r4,r3,1032
ST r4,r1,1
ST r0,r1,2
MOVI r1,#NFS_DISK_LBA
LA r2,#NFS_HDR
LA r4,@bare_table
LD r4,r4,7
CALLR r4
LA r1,#NFS_BASE
LD r2,r1,2
ADDI r2,r2,1032
ADDI r2,r2,127
SHR r2,r2,7
ST r2,r0,#W_DK_N
ST r0,r0,#W_DK_I
nsy_l:
LD r1,r0,#W_DK_I
LD r2,r0,#W_DK_N
CMP r1,r2
JMP[GE] @nsy_d
MOVI r3,#NFS_DISK_LBA+1
ADD r1,r1,r3
LA r2,#NFS_BASE
LD r3,r0,#W_DK_I
SHL r3,r3,7
ADD r2,r2,r3
LA r4,@bare_table
LD r4,r4,7
CALLR r4
LD r1,r0,#W_DK_I
ADD r1,r1,r13
ST r1,r0,#W_DK_I
JMP @nsy_l
nsy_d:
SUB r14,r14,r13
LD r15,r14,0
RET

nfs_load:
ST r15,r14,0
ADD r14,r14,r13
CALL @ata_present
CMP r1,r0
JMP[EQ] @nld_n
MOVI r1,#NFS_DISK_LBA
LA r2,#NFS_HDR
LA r4,@bare_table
LD r4,r4,6
CALLR r4
LA r1,#NFS_HDR
LD r2,r1,0
LA r3,0x4E465359
CMP r2,r3
JMP[NE] @nld_n
LD r2,r1,1
CMP r2,r0
JMP[EQ] @nld_n
LA r3,401032
CMP r2,r3
JMP[GT] @nld_n
ADDI r2,r2,127
SHR r2,r2,7
ST r2,r0,#W_DK_N
ST r0,r0,#W_DK_I
nld_l:
LD r1,r0,#W_DK_I
LD r2,r0,#W_DK_N
CMP r1,r2
JMP[GE] @nld_y
MOVI r3,#NFS_DISK_LBA+1
ADD r1,r1,r3
LA r2,#NFS_BASE
LD r3,r0,#W_DK_I
SHL r3,r3,7
ADD r2,r2,r3
LA r4,@bare_table
LD r4,r4,6
CALLR r4
LD r1,r0,#W_DK_I
ADD r1,r1,r13
ST r1,r0,#W_DK_I
JMP @nld_l
nld_y:
MOVI r1,1
JMP @nld_d
nld_n:
MOVI r1,0
nld_d:
SUB r14,r14,r13
LD r15,r14,0
RET
