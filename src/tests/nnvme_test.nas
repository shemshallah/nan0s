; nnvme_test.nas - F11 NVMe namespace/queue-pair and model-streaming proof.
;
; Pure NaN image.  Proves, deterministically:
;   * namespace geometry with 64-bit capacity and an extent table, including
;     rejection of overlap, out-of-range, zero-length and outside-backing
;     extents and of a 64-bit LBA wrap;
;   * a controller with a 4-entry queue pair, SQE/CQE rings, SQ/CQ doorbells,
;     head/tail wrap and exact queue-full behaviour;
;   * WRITE/READ/FLUSH/TRIM over a 512-byte LBA, exact source/destination
;     bytes, deterministic zero-fill trim and exact byte counters;
;   * a READ/WRITE at LBA 2^32 (4 GiB in LBA space) through a caller buffer;
;   * a GGUF-style tensor view at byte offset 2^41 (2 TiB) read through the
;     same 64-bit extent path;
;   * invalid LBA/size/address, bad namespace, bad opcode, read-only
;     namespace, stale ring indices and queue-full errors.
;
; Success prints exactly O.  A failed check prints F <hex id> and HALT.
;
; Guest map (word addresses):
;   0x0000 boot JMP
;   0x0400.. nnvme library and this test (ends below 0x4000)
;   0x6000 controller/namespace/queues/extents/SQE/CQE/view
;   0x7000 nnvme library scratch
;   0x7800 unrelated allocator scratch (untouched)
;   0x8F00 test stack
; Byte buffers: 0x10000, 0x12000, 0x14000, 0x16000.

.equ STK        0x8F00

.equ BUF0       0x10000
.equ BUF1       0x12000
.equ BUF2       0x14000
.equ BUF3       0x16000

.equ CTRL       0x6000
.equ NS         0x6040
.equ QTAB       0x6080
.equ EXT        0x6100
.equ SQE        0x6200
.equ CQE        0x6220
.equ CFG        0x6240
.equ STAT       0x6260
.equ VIEW       0x6280
.equ TMP        0x62C0
.equ SQ         0x6300
.equ CQ         0x6340

.equ SQE_OP     0x6200
.equ SQE_FLAGS  0x6201
.equ SQE_NSID   0x6202
.equ SQE_LBA    0x6203
.equ SQE_NLB    0x6205
.equ SQE_DATA   0x6207

.equ CQE_STATUS 0x6220
.equ CQE_QID    0x6221
.equ CQE_SLOT   0x6222
.equ CQE_CID    0x6223
.equ CQE_RES    0x6224
.equ CQE_NSID   0x6226
.equ CQE_PHASE  0x6227

.equ CFG_NSID   0x6240
.equ CFG_SHIFT  0x6241
.equ CFG_CAP    0x6242
.equ CFG_EXT    0x6244
.equ CFG_EXTCAP 0x6245
.equ CFG_BASE   0x6246
.equ CFG_SIZE   0x6248
.equ CFG_FLAGS  0x624A
.equ CFG_GEN    0x624B

.equ STAT_READS 0x6260
.equ STAT_WRITES 0x6261
.equ STAT_TRIMS 0x6262
.equ STAT_FLUSH 0x6263
.equ STAT_BR    0x6264
.equ STAT_BW    0x6266
.equ STAT_BT    0x6268

.equ VIEW_MAGIC 0x6280
.equ VIEW_VER   0x6281
.equ VIEW_DTYPE 0x6282
.equ VIEW_RANK  0x6283
.equ VIEW_FLAGS 0x6284
.equ VIEW_OFF   0x6285
.equ VIEW_SIZE  0x6287
.equ VIEW_BLK   0x6289
.equ VIEW_GEN   0x628F

.equ T_STAT     0x62C0
.equ T_RES      0x62C1
.equ T_RESH     0x62C2

.equ CTRL_CFG   0x62D0

; Controller config
.equ CCFG_NS    0x62D0
.equ CCFG_QTAB  0x62D1
.equ CCFG_QCAP  0x62D2
.equ CCFG_MAXD  0x62D3
.equ CCFG_GEN   0x62D4

.org 0
JMP @main
.org 0x400
.include "../lib/nnvme.nas"

main:
MOVI r0,0
MOVI r13,1
LA r14,#STK

; ---------------------------------------------------------------------------
; Namespace: 512-byte LBA, capacity 2*2^32+0xFFFFFFFF LBAs, 32 KiB backing.
MOVI r1,1
LA r2,#CFG_NSID
ST r1,r2,0
MOVI r1,9
ST r1,r2,1
LA r1,0xFFFFFFFF
ST r1,r2,2
MOVI r1,2
ST r1,r2,3
LA r1,#EXT
ST r1,r2,4
MOVI r1,4
ST r1,r2,5
LA r1,#BUF0
ST r1,r2,6
MOVI r1,0
ST r1,r2,7
LA r1,0x8000
ST r1,r2,8
MOVI r1,0
ST r1,r2,9
MOVI r1,0
ST r1,r2,10
MOVI r1,7
ST r1,r2,11

LA r1,#NS
LA r2,#CFG
CALL @nnvme_ns_init
MOVI r5,0
MOVI r3,0x101
CALL @chk

; ext0: LBA 0..15 -> BUF0
LA r1,#NS
MOVI r2,0
MOVI r3,0
MOVI r4,16
MOVI r5,0
LA r6,#BUF0
CALL @nnvme_ns_add_ext
MOVI r5,0
MOVI r3,0x102
CALL @chk

; ext1: LBA 2^32..2^32+15 -> BUF1
LA r1,#NS
MOVI r2,0
MOVI r3,1
MOVI r4,16
MOVI r5,0
LA r6,#BUF1
CALL @nnvme_ns_add_ext
MOVI r5,0
MOVI r3,0x103
CALL @chk

; ext2: LBA 64..71 -> BUF2
LA r1,#NS
MOVI r2,64
MOVI r3,0
MOVI r4,8
MOVI r5,0
LA r6,#BUF2
CALL @nnvme_ns_add_ext
MOVI r5,0
MOVI r3,0x104
CALL @chk

; overlap with ext0 -> ESPACE
LA r1,#NS
MOVI r2,8
MOVI r3,0
MOVI r4,4
MOVI r5,0
LA r6,#BUF3
CALL @nnvme_ns_add_ext
MOVI r5,#NVME_ESPACE
MOVI r3,0x105
CALL @chk

; range past capacity -> ELBA
LA r1,#NS
LA r2,0xFFFFFFFF
MOVI r3,2
MOVI r4,2
MOVI r5,0
LA r6,#BUF3
CALL @nnvme_ns_add_ext
MOVI r5,#NVME_ELBA
MOVI r3,0x106
CALL @chk

; zero count -> EBAD
LA r1,#NS
MOVI r2,100
MOVI r3,0
MOVI r4,0
MOVI r5,0
LA r6,#BUF3
CALL @nnvme_ns_add_ext
MOVI r5,#NVME_EBAD
MOVI r3,0x107
CALL @chk

; physical range outside backing -> ELBA
LA r1,#NS
MOVI r2,100
MOVI r3,0
MOVI r4,8
MOVI r5,0
LA r6,0x20000
CALL @nnvme_ns_add_ext
MOVI r5,#NVME_ELBA
MOVI r3,0x108
CALL @chk

; 64-bit LBA wrap -> ELBA
LA r1,#NS
LA r2,0xFFFFFFFF
LA r3,0xFFFFFFFF
MOVI r4,2
MOVI r5,0
LA r6,#BUF3
CALL @nnvme_ns_add_ext
MOVI r5,#NVME_ELBA
MOVI r3,0x109
CALL @chk

; ---------------------------------------------------------------------------
; Controller and one 4-deep queue pair.
LA r1,#CTRL_CFG
LA r2,#NS
ST r2,r1,0
LA r2,#QTAB
ST r2,r1,1
MOVI r2,4
ST r2,r1,2
MOVI r2,8
ST r2,r1,3
MOVI r2,1
ST r2,r1,4
LA r1,#CTRL
LA r2,#CTRL_CFG
CALL @nnvme_ctrl_init
MOVI r5,0
MOVI r3,0x110
CALL @chk

LA r1,#CTRL
MOVI r2,1
MOVI r3,4
LA r4,#SQ
LA r5,#CQ
CALL @nnvme_qpair_create
MOVI r5,0
MOVI r3,0x111
CALL @chk

; duplicate qid is rejected
LA r1,#CTRL
MOVI r2,1
MOVI r3,4
LA r4,#SQ
LA r5,#CQ
CALL @nnvme_qpair_create
MOVI r5,#NVME_EBAD
MOVI r3,0x112
CALL @chk

; identify sees the namespace and queue
LA r1,#CTRL
MOVI r2,1
LA r3,#STAT
CALL @nnvme_identify
MOVI r5,0
MOVI r3,0x113
CALL @chk
LD r1,r0,#STAT+0
MOVI r5,1
MOVI r3,0x114
CALL @chk
LD r1,r0,#STAT+3
MOVI r5,9
MOVI r3,0x115
CALL @chk
LD r1,r0,#STAT+4
LA r5,0x200
MOVI r3,0x116
CALL @chk
LD r1,r0,#STAT+5
MOVI r5,3
MOVI r3,0x117
CALL @chk
LD r1,r0,#STAT+10
MOVI r5,7
MOVI r3,0x118
CALL @chk
LD r1,r0,#STAT+11
MOVI r5,1
MOVI r3,0x119
CALL @chk

; namespace info copies the live record.
LA r1,#NS
LA r2,#TMP
CALL @nnvme_ns_info
MOVI r5,0
MOVI r3,0x11A
CALL @chk
LD r1,r0,#TMP+0
LA r5,#NVME_NS_MAGIC
MOVI r3,0x11B
CALL @chk
LD r1,r0,#TMP+10
MOVI r5,3
MOVI r3,0x11C
CALL @chk

; ---------------------------------------------------------------------------
; Fill BUF0 with 4096 pattern bytes (i*7+3 mod 256).
MOVI r6,0
fill0:
MOVI r2,7
MUL r3,r6,r2
ADDI r3,r3,3
MOVI r4,0xFF
BOOL.8 r3,r3,r4
LA r4,#BUF0
ADD r4,r4,r6
STB r3,r4,0
ADDI r6,r6,1
LA r2,0x1000
CMP r6,r2
JMP[LT] @fill0

; Queue four commands: WRITE, READ, FLUSH, TRIM.
MOVI r1,#NVME_OP_WRITE
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
MOVI r1,0
ST r1,r0,#SQE_LBA
MOVI r1,0
ST r1,r0,#SQE_LBA+1
MOVI r1,8
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
LA r1,#BUF0
ST r1,r0,#SQE_DATA
LA r1,#CTRL
MOVI r2,1
LA r3,#SQE
CALL @nnvme_submit
MOVI r5,1
MOVI r3,0x120
CALL @chk

MOVI r1,#NVME_OP_READ
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
MOVI r1,0
ST r1,r0,#SQE_LBA
MOVI r1,0
ST r1,r0,#SQE_LBA+1
MOVI r1,8
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
LA r1,#BUF2
ST r1,r0,#SQE_DATA
LA r1,#CTRL
MOVI r2,1
LA r3,#SQE
CALL @nnvme_submit
MOVI r5,2
MOVI r3,0x121
CALL @chk

MOVI r1,#NVME_OP_FLUSH
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
LA r1,#CTRL
MOVI r2,1
LA r3,#SQE
CALL @nnvme_submit
MOVI r5,3
MOVI r3,0x122
CALL @chk

MOVI r1,#NVME_OP_TRIM
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
MOVI r1,8
ST r1,r0,#SQE_LBA
MOVI r1,0
ST r1,r0,#SQE_LBA+1
MOVI r1,8
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
LA r1,#CTRL
MOVI r2,1
LA r3,#SQE
CALL @nnvme_submit
MOVI r5,4
MOVI r3,0x123
CALL @chk

; fifth submission hits queue full
MOVI r1,#NVME_OP_READ
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
MOVI r1,0
ST r1,r0,#SQE_LBA
MOVI r1,0
ST r1,r0,#SQE_LBA+1
MOVI r1,1
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
LA r1,#BUF3
ST r1,r0,#SQE_DATA
LA r1,#CTRL
MOVI r2,1
LA r3,#SQE
CALL @nnvme_submit
MOVI r5,0
MOVI r3,0x124
CALL @chk
LA r1,#CTRL
CALL @nnvme_errno
MOVI r5,#NVME_EQFULL
MOVI r3,0x125
CALL @chk

; doorbell rings four entries, complete reaps four
LA r1,#CTRL
MOVI r2,1
CALL @nnvme_sq_doorbell
MOVI r5,4
MOVI r3,0x126
CALL @chk
LA r1,#CTRL
MOVI r2,1
CALL @nnvme_complete
MOVI r5,4
MOVI r3,0x127
CALL @chk

; exact completions: status 0, slots 0..3, bytes 4096/4096/0/4096
LA r1,#CTRL
MOVI r2,1
MOVI r3,0
LA r4,#CQE
CALL @nnvme_cqe
MOVI r5,0
MOVI r3,0x130
CALL @chk
LD r1,r0,#CQE_STATUS
MOVI r5,0
MOVI r3,0x131
CALL @chk
LD r1,r0,#CQE_SLOT
MOVI r5,0
MOVI r3,0x132
CALL @chk
LD r1,r0,#CQE_RES
LA r5,0x1000
MOVI r3,0x133
CALL @chk
LD r1,r0,#CQE_QID
MOVI r5,1
MOVI r3,0x134
CALL @chk

LA r1,#CTRL
MOVI r2,1
MOVI r3,1
LA r4,#CQE
CALL @nnvme_cqe
LD r1,r0,#CQE_SLOT
MOVI r5,1
MOVI r3,0x135
CALL @chk
LD r1,r0,#CQE_RES
LA r5,0x1000
MOVI r3,0x136
CALL @chk

LA r1,#CTRL
MOVI r2,1
MOVI r3,2
LA r4,#CQE
CALL @nnvme_cqe
LD r1,r0,#CQE_SLOT
MOVI r5,2
MOVI r3,0x137
CALL @chk
LD r1,r0,#CQE_RES
MOVI r5,0
MOVI r3,0x138
CALL @chk

LA r1,#CTRL
MOVI r2,1
MOVI r3,3
LA r4,#CQE
CALL @nnvme_cqe
LD r1,r0,#CQE_SLOT
MOVI r5,3
MOVI r3,0x139
CALL @chk
LD r1,r0,#CQE_RES
LA r5,0x1000
MOVI r3,0x13A
CALL @chk

; out-of-range CQE index fails
LA r1,#CTRL
MOVI r2,1
MOVI r3,4
LA r4,#CQE
CALL @nnvme_cqe
MOVI r5,#NVME_EBAD
MOVI r3,0x13B
CALL @chk

LA r1,#CTRL
MOVI r2,1
MOVI r3,4
CALL @nnvme_cq_doorbell
MOVI r5,0
MOVI r3,0x13C
CALL @chk

; ---------------------------------------------------------------------------
; Exact readback of the low 4096 bytes.
MOVI r6,0
cmpl0:
MOVI r2,7
MUL r3,r6,r2
ADDI r3,r3,3
MOVI r4,0xFF
BOOL.8 r3,r3,r4
LA r4,#BUF2
ADD r4,r4,r6
LDB r1,r4,0
CMP r1,r3
JMP[NE] @bad_low
ADDI r6,r6,1
LA r2,0x1000
CMP r6,r2
JMP[LT] @cmpl0

; Trimmed bytes 4096..8191 are exactly zero.
MOVI r6,0
cmpt0:
LA r4,#BUF0
ADD r4,r4,r6
ADDI r4,r4,0x1000
LDB r1,r4,0
CMP r1,r0
JMP[NE] @bad_trim
ADDI r6,r6,1
LA r2,0x1000
CMP r6,r2
JMP[LT] @cmpt0

; ---------------------------------------------------------------------------
; High path: LBA 2^32, 16 blocks, exact write/read and CQE wrap at slot 0.
MOVI r6,0
fill1:
MOVI r2,11
MUL r3,r6,r2
ADDI r3,r3,5
MOVI r4,0xFF
BOOL.8 r3,r3,r4
LA r4,#BUF1
ADD r4,r4,r6
STB r3,r4,0
ADDI r6,r6,1
LA r2,0x2000
CMP r6,r2
JMP[LT] @fill1

MOVI r1,#NVME_OP_WRITE
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
MOVI r1,0
ST r1,r0,#SQE_LBA
MOVI r1,1
ST r1,r0,#SQE_LBA+1
MOVI r1,16
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
LA r1,#BUF1
ST r1,r0,#SQE_DATA
CALL @one
ST r1,r0,#T_STAT
ST r2,r0,#T_RES
ST r3,r0,#T_RESH
LD r1,r0,#T_STAT
MOVI r5,0
MOVI r3,0x140
CALL @chk
LD r1,r0,#T_RES
LA r5,0x2000
MOVI r3,0x141
CALL @chk

MOVI r1,#NVME_OP_READ
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
MOVI r1,0
ST r1,r0,#SQE_LBA
MOVI r1,1
ST r1,r0,#SQE_LBA+1
MOVI r1,16
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
LA r1,#BUF3
ST r1,r0,#SQE_DATA
CALL @one
ST r1,r0,#T_STAT
ST r2,r0,#T_RES
ST r3,r0,#T_RESH
LD r1,r0,#T_STAT
MOVI r5,0
MOVI r3,0x142
CALL @chk
LD r1,r0,#T_RES
LA r5,0x2000
MOVI r3,0x143
CALL @chk
LD r1,r0,#T_STAT
MOVI r5,0
MOVI r3,0x144
CALL @chk

; exact high bytes
MOVI r6,0
cmph:
LA r4,#BUF1
ADD r4,r4,r6
LDB r1,r4,0
LA r4,#BUF3
ADD r4,r4,r6
LDB r2,r4,0
CMP r1,r2
JMP[NE] @bad_high
ADDI r6,r6,1
LA r2,0x2000
CMP r6,r2
JMP[LT] @cmph

; ---------------------------------------------------------------------------
; GGUF-style tensor view: byte offset 2^41 = LBA 2^32, 8192 bytes.
LA r1,#VIEW
LA r2,#NVME_VIEW_MAGIC
ST r2,r1,0
MOVI r2,#NVME_VERSION
ST r2,r1,1
MOVI r2,0
ST r2,r1,2
MOVI r2,1
ST r2,r1,3
MOVI r2,0
ST r2,r1,4
MOVI r2,0
ST r2,r1,5
MOVI r2,0x200
ST r2,r1,6
LA r2,0x2000
ST r2,r1,7
MOVI r2,0
ST r2,r1,8
LA r2,0x200
ST r2,r1,9
MOVI r2,3
ST r2,r1,15

LA r1,#CTRL
MOVI r2,1
LA r3,#VIEW
MOVI r4,0
MOVI r5,0
MOVI r6,16
LA r7,#BUF2
CALL @nnvme_view_read
MOVI r5,0
MOVI r3,0x150
CALL @chk

; view bytes equal BUF1
MOVI r6,0
cmpv:
LA r4,#BUF1
ADD r4,r4,r6
LDB r1,r4,0
LA r4,#BUF2
ADD r4,r4,r6
LDB r2,r4,0
CMP r1,r2
JMP[NE] @bad_view
ADDI r6,r6,1
LA r2,0x2000
CMP r6,r2
JMP[LT] @cmpv

; stats after 2 reads (12288), 2 writes (12288), 1 trim (4096), 1 flush
; and one streaming read (8192 => reads 3, bytes 20480).
LA r1,#NS
LA r2,#STAT
CALL @nnvme_ns_stats
MOVI r5,0
MOVI r3,0x158
CALL @chk
LD r1,r0,#STAT_READS
MOVI r5,3
MOVI r3,0x159
CALL @chk
LD r1,r0,#STAT_WRITES
MOVI r5,2
MOVI r3,0x15A
CALL @chk
LD r1,r0,#STAT_TRIMS
MOVI r5,1
MOVI r3,0x15B
CALL @chk
LD r1,r0,#STAT_FLUSH
MOVI r5,1
MOVI r3,0x15C
CALL @chk
LD r1,r0,#STAT_BR
LA r5,0x5000
MOVI r3,0x15D
CALL @chk
LD r1,r0,#STAT_BR+1
MOVI r5,0
MOVI r3,0x15E
CALL @chk
LD r1,r0,#STAT_BW
LA r5,0x3000
MOVI r3,0x15F
CALL @chk
LD r1,r0,#STAT_BT
LA r5,0x1000
MOVI r3,0x160
CALL @chk

; ---------------------------------------------------------------------------
; Error paths.  Each uses one queue slot and returns one CQE.
; 64-bit LBA wrap.
MOVI r1,#NVME_OP_READ
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
LA r1,0xFFFFFFF0
ST r1,r0,#SQE_LBA
LA r1,0xFFFFFFFF
ST r1,r0,#SQE_LBA+1
MOVI r1,0x20
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
LA r1,#BUF3
ST r1,r0,#SQE_DATA
CALL @one
MOVI r5,#NVME_ELBA
MOVI r3,0x170
CALL @chk

; past namespace capacity.
MOVI r1,#NVME_OP_READ
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
LA r1,0xFFFFFFFF
ST r1,r0,#SQE_LBA
MOVI r1,2
ST r1,r0,#SQE_LBA+1
MOVI r1,2
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
LA r1,#BUF3
ST r1,r0,#SQE_DATA
CALL @one
MOVI r5,#NVME_ELBA
MOVI r3,0x171
CALL @chk

; data address zero.
MOVI r1,#NVME_OP_READ
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
MOVI r1,0
ST r1,r0,#SQE_LBA
MOVI r1,0
ST r1,r0,#SQE_LBA+1
MOVI r1,1
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
MOVI r1,0
ST r1,r0,#SQE_DATA
CALL @one
MOVI r5,#NVME_EADDR
MOVI r3,0x172
CALL @chk

; zero block count.
MOVI r1,#NVME_OP_READ
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
MOVI r1,0
ST r1,r0,#SQE_LBA
MOVI r1,0
ST r1,r0,#SQE_LBA+1
MOVI r1,0
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
LA r1,#BUF3
ST r1,r0,#SQE_DATA
CALL @one
MOVI r5,#NVME_ELBA
MOVI r3,0x173
CALL @chk

; range crossing an extent boundary.
MOVI r1,#NVME_OP_READ
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
MOVI r1,8
ST r1,r0,#SQE_LBA
MOVI r1,0
ST r1,r0,#SQE_LBA+1
MOVI r1,16
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
LA r1,#BUF3
ST r1,r0,#SQE_DATA
CALL @one
MOVI r5,#NVME_ELBA
MOVI r3,0x174
CALL @chk

; bad namespace id.
MOVI r1,#NVME_OP_WRITE
ST r1,r0,#SQE_OP
MOVI r1,9
ST r1,r0,#SQE_NSID
MOVI r1,0
ST r1,r0,#SQE_LBA
MOVI r1,0
ST r1,r0,#SQE_LBA+1
MOVI r1,1
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
LA r1,#BUF0
ST r1,r0,#SQE_DATA
CALL @one
MOVI r5,#NVME_ENOENT
MOVI r3,0x175
CALL @chk

; bad opcode.
MOVI r1,9
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
MOVI r1,0
ST r1,r0,#SQE_LBA
MOVI r1,0
ST r1,r0,#SQE_LBA+1
MOVI r1,1
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
LA r1,#BUF0
ST r1,r0,#SQE_DATA
CALL @one
MOVI r5,#NVME_EBAD
MOVI r3,0x176
CALL @chk

; read-only namespace rejects write and trim.
MOVI r1,1
ST r1,r0,#NS+7
MOVI r1,#NVME_OP_WRITE
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
MOVI r1,0
ST r1,r0,#SQE_LBA
MOVI r1,0
ST r1,r0,#SQE_LBA+1
MOVI r1,1
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
LA r1,#BUF0
ST r1,r0,#SQE_DATA
CALL @one
MOVI r5,#NVME_ERO
MOVI r3,0x177
CALL @chk

MOVI r1,#NVME_OP_TRIM
ST r1,r0,#SQE_OP
MOVI r1,1
ST r1,r0,#SQE_NSID
MOVI r1,0
ST r1,r0,#SQE_LBA
MOVI r1,0
ST r1,r0,#SQE_LBA+1
MOVI r1,1
ST r1,r0,#SQE_NLB
MOVI r1,0
ST r1,r0,#SQE_NLB+1
CALL @one
MOVI r5,#NVME_ERO
MOVI r3,0x178
CALL @chk
MOVI r1,0
ST r1,r0,#NS+7

; failed commands did not change the successful byte counters.
LA r1,#NS
LA r2,#STAT
CALL @nnvme_ns_stats
LD r1,r0,#STAT_READS
MOVI r5,3
MOVI r3,0x179
CALL @chk
LD r1,r0,#STAT_WRITES
MOVI r5,2
MOVI r3,0x17A
CALL @chk
LD r1,r0,#STAT_BR
LA r5,0x5000
MOVI r3,0x17B
CALL @chk
LD r1,r0,#STAT_BT
LA r5,0x1000
MOVI r3,0x17C
CALL @chk

; bad qid fails closed with ENOENT.
LA r1,#CTRL
MOVI r2,9
LA r3,#SQE
CALL @nnvme_submit
MOVI r5,0
MOVI r3,0x180
CALL @chk
LA r1,#CTRL
CALL @nnvme_errno
MOVI r5,#NVME_ENOENT
MOVI r3,0x181
CALL @chk

; CQ doorbell cannot overrun the produced entries.
LA r1,#CTRL
MOVI r2,1
MOVI r3,1
CALL @nnvme_cq_doorbell
MOVI r5,#NVME_EBAD
MOVI r3,0x182
CALL @chk

; delete and recreate the queue pair.
LA r1,#CTRL
MOVI r2,1
CALL @nnvme_qpair_delete
MOVI r5,0
MOVI r3,0x183
CALL @chk
LA r1,#CTRL
MOVI r2,1
MOVI r3,4
LA r4,#SQ
LA r5,#CQ
CALL @nnvme_qpair_create
MOVI r5,0
MOVI r3,0x184
CALL @chk

; ---------------------------------------------------------------------------
MOVI r1,79
PUTC r1
HALT

; ---------------------------------------------------------------------------
; one: submit the prepared SQE, doorbell, complete, read CQE 0, advance CQ.
; Returns r1=status r2=result_lo r3=result_hi, or status 0xFFFF on a ring
; bookkeeping failure.
one:
ST r15,r14,0
ADD r14,r14,r13
LA r1,#CTRL
MOVI r2,1
LA r3,#SQE
CALL @nnvme_submit
CMP r1,r0
JMP[EQ] @one_fail
LA r1,#CTRL
MOVI r2,1
CALL @nnvme_sq_doorbell
MOVI r5,1
CMP r1,r5
JMP[NE] @one_fail
LA r1,#CTRL
MOVI r2,1
CALL @nnvme_complete
MOVI r5,1
CMP r1,r5
JMP[NE] @one_fail
LA r1,#CTRL
MOVI r2,1
MOVI r3,0
LA r4,#CQE
CALL @nnvme_cqe
CMP r1,r0
JMP[NE] @one_fail
LA r1,#CTRL
MOVI r2,1
MOVI r3,1
CALL @nnvme_cq_doorbell
CMP r1,r0
JMP[NE] @one_fail
LD r1,r0,#CQE_STATUS
LD r2,r0,#CQE_RES
LD r3,r0,#CQE_RES+1
JMP @one_out
one_fail:
MOVI r1,0xFFFF
MOVI r2,0
MOVI r3,0
one_out:
SUB r14,r14,r13
LD r15,r14,0
RET

; chk r1 actual r5 expected r3 diagnostic.
chk:
CMP r1,r5
JMP[EQ] @chk_ok
ADD r1,r3,r0
JMP @failcode
chk_ok:
MOVI r1,0
RET

failcode:
ST r15,r14,0
ADDI r14,r14,24
ST r1,r14,1
MOVI r1,70
PUTC r1
MOVI r1,32
PUTC r1
LD r1,r14,1
CALL @t_puthex4
MOVI r1,10
PUTC r1
HALT

bad_low:
MOVI r3,0x1A0
JMP @failcode
bad_trim:
MOVI r3,0x1A1
JMP @failcode
bad_high:
MOVI r3,0x1A2
JMP @failcode
bad_view:
MOVI r3,0x1A3
JMP @failcode

t_puthex4:
ST r15,r14,0
ADDI r14,r14,16
ST r1,r14,1
LD r1,r14,1
SHR r1,r1,12
MOVI r2,0xF
BOOL.8 r1,r1,r2
CALL @t_putnib
LD r1,r14,1
SHR r1,r1,8
MOVI r2,0xF
BOOL.8 r1,r1,r2
CALL @t_putnib
LD r1,r14,1
SHR r1,r1,4
MOVI r2,0xF
BOOL.8 r1,r1,r2
CALL @t_putnib
LD r1,r14,1
MOVI r2,0xF
BOOL.8 r1,r1,r2
CALL @t_putnib
ADDI r14,r14,-16
LD r15,r14,0
RET

t_putnib:
MOVI r2,10
CMP r1,r2
JMP[LT] @t_pn_l
ADDI r1,r1,55
JMP @t_pn_o
t_pn_l:
ADDI r1,r1,48
t_pn_o:
PUTC r1
RET
