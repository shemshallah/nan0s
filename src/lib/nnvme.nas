; nnvme.nas - emulated NVMe namespace and queue pairs with model streaming (F11).
;
; Pure NaN.  This is a software storage boundary: no PCIe, no real device, no
; host call.  It implements the pieces a model loader needs and that a real
; NVMe driver would expose:
;
;   * a namespace with 64-bit LBAs and a 64-bit LBA count;
;   * an extent table mapping 64-bit LBA ranges to caller byte buffers, so an
;     LBA above 4 GiB (and a tensor byte offset above 4 GiB) is exercised
;     without allocating a 4 GiB guest buffer;
;   * queue pairs with submission entries (SQE), completion entries (CQE),
;     SQ/CQ doorbells, head/tail indices, phases and depth accounting;
;   * READ/WRITE/FLUSH/TRIM with exact byte transfer, plus a deterministic
;     zero-fill TRIM (real NVMe leaves trimmed contents undefined; the
;     emulator chooses zeros so a gate can prove exact bytes);
;   * a streaming tensor view read for a GGUF-style 64-bit byte range.
;
; Backing store.  Every extent resolves to a byte range inside the namespace
; backing descriptor [base, base+size).  The caller may build that descriptor
; from nmem/nheap or from a plain guest buffer; nnvme treats it as an opaque
; byte window.  Guest LDB/STB is 32-bit, so an extent's physical byte address
; and its length must fit the low 4 GiB window; LBA/capacity/offset arithmetic
; remains full 64-bit.
;
; An I/O must lie inside one registered extent (contiguous tensor blocks are
; the normal case).  Crossing an extent boundary returns NVME_ELBA.
;
; Context layouts
; ---------------
; Namespace (32 words, caller supplied):
;   +0 magic "NVMS" 0x4E564D53   +1 version 1
;   +2 nsid                      +3 lba_shift (9..16)
;   +4 lba_size                  +5 capacity_lo +6 capacity_hi (LBAs)
;   +7 flags (1 read-only)       +8 extent table word address
;   +9 extent capacity           +10 extent count
;   +11 backing base lo          +12 backing base hi
;   +13 backing size lo          +14 backing size hi
;   +15 generation
;   +16 reads  +17 writes  +18 trims  +19 flushes
;   +20 bytes_read lo  +21 hi
;   +22 bytes_written lo +23 hi
;   +24 bytes_trimmed lo +25 hi
;   +26 lba_errors  +27 ro_errors  +28 io_errors
;
; Extent (8 words):
;   +0 lba_lo +1 lba_hi +2 count_lo +3 count_hi +4 phys byte addr
;   +5 flags +6..7 reserved
;
; Controller (32 words, caller supplied):
;   +0 magic "NVMC" 0x4E564D43   +1 version 1
;   +2 namespace word address     +3 qpair table word address
;   +4 qpair capacity             +5 qpair count
;   +6 max depth                  +7 generation
;   +8 submitted +9 completed +10 errors +11 queue_full
;   +12 lba_errors +13 last_status +14 errno +15 state
;
; Queue pair (32 words, stride 32, table entry qid-1):
;   +0 magic "NVMQ" 0x4E564D51   +1 version 1
;   +2 qid +3 depth
;   +4 SQ word address +5 CQ word address
;   +6 sq_head +7 sq_tail +8 cq_head +9 cq_tail
;   +10 doorbell +11 phase +12 state
;   +13 submitted +14 completed +15 errors +16 full_errors
;   +17 bytes_read lo +18 hi
;   +19 bytes_written lo +20 hi
;   +21 bytes_trimmed lo +22 hi
;   +23 flushes
;
; SQE (16 words):
;   +0 opcode (1 read, 2 write, 3 flush, 4 trim)  +1 flags
;   +2 nsid +3 lba_lo +4 lba_hi +5 nlb_lo +6 nlb_hi
;   +7 data byte address +8..15 reserved
;
; CQE (8 words):
;   +0 status (0 ok, else NVME_E*) +1 qid +2 sq slot +3 command id
;   +4 result_lo +5 result_hi +6 nsid +7 phase
;
; Tensor view (16 words, GGUF-style 64-bit byte range):
;   +0 magic "NVTW" 0x4E565457   +1 version 1
;   +2 dtype +3 rank +4 flags
;   +5 offset_lo +6 offset_hi (byte offset in namespace)
;   +7 size_lo +8 size_hi
;   +9 block_bytes               +10..14 reserved
;   +15 generation
;
; API (r0=0, r13=1, r14=SP grows up, r15=link):
;   nnvme_ns_init     r1=ns r2=cfg -> 0/err
;   nnvme_ns_add_ext  r1=ns r2=lba_lo r3=lba_hi r4=count_lo r5=count_hi
;                     r6=phys -> 0/err
;   nnvme_ns_info     r1=ns r2=out(32) -> 0/err
;   nnvme_ns_stats    r1=ns r2=out(16) -> 0/err
;   nnvme_ctrl_init   r1=ctrl r2=cfg -> 0/err
;   nnvme_qpair_create r1=ctrl r2=qid r3=depth r4=sq r5=cq -> 0/err
;   nnvme_qpair_delete r1=ctrl r2=qid -> 0/err
;   nnvme_submit      r1=ctrl r2=qid r3=sqe -> slot+1 / 0 (see errno)
;   nnvme_sq_doorbell r1=ctrl r2=qid -> newly rung entries / 0 (errno)
;   nnvme_complete    r1=ctrl r2=qid -> reaped entries / 0 (errno)
;   nnvme_cqe         r1=ctrl r2=qid r3=index r4=out(8) -> 0/err
;   nnvme_cq_doorbell r1=ctrl r2=qid r3=count -> 0/err
;   nnvme_errno       r1=ctrl -> last error
;   nnvme_identify    r1=ctrl r2=nsid r3=out(16) -> 0/err
;   nnvme_view_read   r1=ctrl r2=nsid r3=view r4=index_lo r5=index_hi
;                     r6=count r7=dst_byte -> 0/err
;
; The library uses caller-supplied records and fixed single-core scratch at
; 0x7000.  It is not reentrant; serialize callers.

.include "n64.nas"

.equ NVME_NS_MAGIC    0x4E564D53       ; "NVMS"
.equ NVME_QP_MAGIC    0x4E564D51       ; "NVMQ"
.equ NVME_CTRL_MAGIC  0x4E564D43       ; "NVMC"
.equ NVME_VIEW_MAGIC  0x4E565457       ; "NVTW"
.equ NVME_VERSION     1

; Namespace fields.
.equ NV_NS_MAGIC      0
.equ NV_NS_VERSION    1
.equ NV_NS_ID         2
.equ NV_NS_SHIFT      3
.equ NV_NS_LBASZ      4
.equ NV_NS_CAP        5
.equ NV_NS_FLAGS      7
.equ NV_NS_EXT        8
.equ NV_NS_EXTCAP     9
.equ NV_NS_EXTN       10
.equ NV_NS_BASE       11
.equ NV_NS_SIZE       13
.equ NV_NS_GEN        15
.equ NV_NS_READS      16
.equ NV_NS_WRITES     17
.equ NV_NS_TRIMS      18
.equ NV_NS_FLUSHES    19
.equ NV_NS_BR         20
.equ NV_NS_BW         22
.equ NV_NS_BT         24
.equ NV_NS_LBAERR     26
.equ NV_NS_ROERR      27
.equ NV_NS_IOERR      28
.equ NV_NS_WORDS      32

; Extent fields.
.equ NV_E_LBA         0
.equ NV_E_CNT         2
.equ NV_E_PHYS        4
.equ NV_E_FLAGS       5
.equ NV_E_WORDS       8

; Controller fields.
.equ NV_C_MAGIC       0
.equ NV_C_VERSION     1
.equ NV_C_NS          2
.equ NV_C_QTAB        3
.equ NV_C_QCAP        4
.equ NV_C_QN          5
.equ NV_C_MAXD        6
.equ NV_C_GEN         7
.equ NV_C_SUB         8
.equ NV_C_DONE        9
.equ NV_C_ERR         10
.equ NV_C_QFULL       11
.equ NV_C_LBAERR      12
.equ NV_C_LAST        13
.equ NV_C_ERRNO       14
.equ NV_C_STATE       15

; Queue pair fields.
.equ NV_Q_MAGIC       0
.equ NV_Q_VERSION     1
.equ NV_Q_ID          2
.equ NV_Q_DEPTH       3
.equ NV_Q_SQ          4
.equ NV_Q_CQ          5
.equ NV_Q_SQH         6
.equ NV_Q_SQT         7
.equ NV_Q_CQH         8
.equ NV_Q_CQT         9
.equ NV_Q_DB          10
.equ NV_Q_PHASE       11
.equ NV_Q_STATE       12
.equ NV_Q_SUB         13
.equ NV_Q_DONE        14
.equ NV_Q_ERR         15
.equ NV_Q_FULL        16
.equ NV_Q_BR          17
.equ NV_Q_BW          19
.equ NV_Q_BT          21
.equ NV_Q_FLUSH       23
.equ NV_Q_RES         24
.equ NV_Q_WORDS       32

; SQE fields.
.equ NV_S_OP          0
.equ NV_S_FLAGS       1
.equ NV_S_NSID        2
.equ NV_S_LBA         3
.equ NV_S_NLB         5
.equ NV_S_DATA        7
.equ NV_S_WORDS       16

; CQE fields.
.equ NV_K_STATUS      0
.equ NV_K_QID         1
.equ NV_K_SLOT        2
.equ NV_K_CID         3
.equ NV_K_RES         4
.equ NV_K_NSID        6
.equ NV_K_PHASE       7
.equ NV_K_WORDS       8

; View fields.
.equ NV_V_MAGIC       0
.equ NV_V_VERSION     1
.equ NV_V_DTYPE       2
.equ NV_V_RANK        3
.equ NV_V_FLAGS       4
.equ NV_V_OFF         5
.equ NV_V_SIZE        7
.equ NV_V_BLOCK       9
.equ NV_V_GEN         15

; Opcodes and errors.
.equ NVME_OP_READ     1
.equ NVME_OP_WRITE    2
.equ NVME_OP_FLUSH    3
.equ NVME_OP_TRIM     4

.equ NVME_OK          0
.equ NVME_EBAD        1
.equ NVME_ELBA        2
.equ NVME_EQFULL      3
.equ NVME_ENOENT      4
.equ NVME_ESPACE      5
.equ NVME_ERO         6
.equ NVME_EIO         7
.equ NVME_EADDR       8

.equ NVME_NS_F_RO     1

; Fixed scratch.  Single-core emulation; see the header.
.equ NVX_NSINIT       0x7000
.equ NVX_EXT          0x7010
.equ NVX_CTRL         0x7020
.equ NVX_QP           0x7030
.equ NVX_SUB          0x7040
.equ NVX_DB           0x7050
.equ NVX_COMP         0x7060
.equ NVX_CQE          0x7070
.equ NVX_CQDB         0x7080
.equ NVX_IDENT        0x7090
.equ NVX_EXEC         0x70A0
.equ NVX_RD           0x70C0
.equ NVX_WR           0x70E0
.equ NVX_TR           0x7100
.equ NVX_LOOK         0x7120
.equ NVX_VIEW         0x7140

; ---------------------------------------------------------------------------
; nv_ns_ok r1=ns -> 1 if magic/version are live.
nv_ns_ok:
  CMP r1,r0
  JMP[EQ] @nv_nsok_no
  LD r2,r1,#NV_NS_MAGIC
  LA r3,#NVME_NS_MAGIC
  CMP r2,r3
  JMP[NE] @nv_nsok_no
  LD r2,r1,#NV_NS_VERSION
  MOVI r3,#NVME_VERSION
  CMP r2,r3
  JMP[NE] @nv_nsok_no
  MOVI r1,1
  RET
nv_nsok_no:
  MOVI r1,0
  RET

; nv_qp r1=ctrl r2=qid -> qpair address or 0.
nv_qp:
  CMP r1,r0
  JMP[EQ] @nv_qp_no
  LD r3,r1,#NV_C_MAGIC
  LA r4,#NVME_CTRL_MAGIC
  CMP r3,r4
  JMP[NE] @nv_qp_no
  CMP r2,r0
  JMP[EQ] @nv_qp_no
  LD r3,r1,#NV_C_QCAP
  CMP r2,r3
  JMP[GT] @nv_qp_no
  SUB r3,r2,r13
  SHL r3,r3,5
  LD r4,r1,#NV_C_QTAB
  ADD r3,r3,r4
  LD r4,r3,#NV_Q_MAGIC
  LA r5,#NVME_QP_MAGIC
  CMP r4,r5
  JMP[NE] @nv_qp_no
  LD r4,r3,#NV_Q_STATE
  CMP r4,r0
  JMP[EQ] @nv_qp_no
  ADD r1,r3,r0
  RET
nv_qp_no:
  MOVI r1,0
  RET

; nv_note r1=ctrl r2=code -> r1=code; ctrl.errno=code.
nv_note:
  ST r2,r1,#NV_C_ERRNO
  ADD r1,r2,r0
  RET

; nv_clear_err r1=ctrl.
nv_clear_err:
  ST r0,r1,#NV_C_ERRNO
  RET

; nv_bytes r1=ns r2=count_lo r3=count_hi -> r1=bytes_lo r2=bytes_hi.
nv_bytes:
  LD r4,r1,#NV_NS_LBASZ
  ADD r1,r4,r0
  JMP @n64_mul32

; nv_lookup r1=ns r2=lba_lo r3=lba_hi r4=count_lo r5=count_hi
;           -> r1=extent address or 0.  Requires count != 0 and the whole
;           range inside one extent and inside the namespace capacity.
nv_lookup:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_LOOK+0
  ST r2,r0,#NVX_LOOK+1
  ST r3,r0,#NVX_LOOK+2
  ST r4,r0,#NVX_LOOK+3
  ST r5,r0,#NVX_LOOK+4
  CMP r4,r0
  JMP[NE] @nv_lk_cnt
  CMP r5,r0
  JMP[EQ] @nv_lk_fail
nv_lk_cnt:
  LD r1,r0,#NVX_LOOK+1
  LD r2,r0,#NVX_LOOK+2
  LD r3,r0,#NVX_LOOK+3
  LD r4,r0,#NVX_LOOK+4
  CALL @n64_add
  ST r1,r0,#NVX_LOOK+5
  ST r2,r0,#NVX_LOOK+6
  ; a 64-bit wrap makes end < lba
  LD r3,r0,#NVX_LOOK+1
  LD r4,r0,#NVX_LOOK+2
  CALL @n64_cmp
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nv_lk_fail
  LD r3,r0,#NVX_LOOK+0
  LD r3,r3,#NV_NS_CAP
  LD r4,r0,#NVX_LOOK+0
  LD r4,r4,#NV_NS_CAP+1
  CALL @n64_cmp
  MOVI r5,1
  CMP r1,r5
  JMP[EQ] @nv_lk_fail
  MOVI r2,0
  ST r2,r0,#NVX_LOOK+7
nv_lk_loop:
  LD r2,r0,#NVX_LOOK+7
  LD r1,r0,#NVX_LOOK+0
  LD r3,r1,#NV_NS_EXTN
  CMP r2,r3
  JMP[GE] @nv_lk_fail
  SHL r3,r2,3
  LD r4,r1,#NV_NS_EXT
  ADD r3,r3,r4
  ST r3,r0,#NVX_LOOK+9
  LD r1,r3,0
  LD r2,r3,1
  LD r3,r3,2
  LD r4,r0,#NVX_LOOK+9
  LD r4,r4,3
  CALL @n64_add
  ST r1,r0,#NVX_LOOK+10
  ST r2,r0,#NVX_LOOK+11
  LD r3,r0,#NVX_LOOK+9
  LD r3,r3,0
  LD r4,r0,#NVX_LOOK+9
  LD r4,r4,1
  CALL @n64_cmp
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nv_lk_fail
  ; lba >= ext.lba ?
  LD r1,r0,#NVX_LOOK+1
  LD r2,r0,#NVX_LOOK+2
  LD r3,r0,#NVX_LOOK+9
  LD r3,r3,0
  LD r4,r0,#NVX_LOOK+9
  LD r4,r4,1
  CALL @n64_cmp
  LA r6,0xFFFFFFFF
  CMP r1,r6
  JMP[EQ] @nv_lk_next
  ; end <= ext_end ?
  LD r1,r0,#NVX_LOOK+5
  LD r2,r0,#NVX_LOOK+6
  LD r3,r0,#NVX_LOOK+10
  LD r4,r0,#NVX_LOOK+11
  CALL @n64_cmp
  MOVI r6,1
  CMP r1,r6
  JMP[EQ] @nv_lk_next
  LD r1,r0,#NVX_LOOK+9
  JMP @nv_lk_out
nv_lk_next:
  LD r2,r0,#NVX_LOOK+7
  ADDI r2,r2,1
  ST r2,r0,#NVX_LOOK+7
  JMP @nv_lk_loop
nv_lk_fail:
  MOVI r1,0
nv_lk_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nv_copy r1=from byte addr r2=to byte addr r3=count.  Leaf.
nv_copy:
  CMP r3,r0
  JMP[EQ] @nv_copy_done
nv_copy_l:
  LDB r4,r1,0
  STB r4,r2,0
  ADDI r1,r1,1
  ADDI r2,r2,1
  ADDI r3,r3,-1
  CMP r3,r0
  JMP[NE] @nv_copy_l
nv_copy_done:
  RET

; nv_zero r1=dst byte addr r2=count.  Leaf.
nv_zero:
  CMP r2,r0
  JMP[EQ] @nv_zero_done
nv_zero_l:
  STB r0,r1,0
  ADDI r1,r1,1
  ADDI r2,r2,-1
  CMP r2,r0
  JMP[NE] @nv_zero_l
nv_zero_done:
  RET

; nv_phys r1=ext r2=lba_lo r3=lba_hi -> r1=phys byte addr r3=0 ok / 1 fail.
; The caller puts lba_size in NVX_LOOK+16.  The extent start LBA is subtracted
; in 64-bit; the byte offset must fit 32 bits.
nv_phys:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_LOOK+12
  ST r2,r0,#NVX_LOOK+13
  ST r3,r0,#NVX_LOOK+14
  ; diff = lba - ext.lba
  ADD r1,r2,r0
  ADD r2,r3,r0
  LD r3,r0,#NVX_LOOK+12
  LD r3,r3,#NV_E_LBA
  LD r4,r0,#NVX_LOOK+12
  LD r4,r4,#NV_E_LBA+1
  CALL @n64_sub
  ST r1,r0,#NVX_LOOK+15
  CMP r2,r0
  JMP[NE] @nv_phys_fail
  ; off = diff * lba_size
  LD r1,r0,#NVX_LOOK+16
  LD r2,r0,#NVX_LOOK+15
  MOVI r3,0
  CALL @n64_mul32
  CMP r2,r0
  JMP[NE] @nv_phys_fail
  LD r3,r0,#NVX_LOOK+12
  LD r3,r3,#NV_E_PHYS
  ADD r1,r1,r3
  CMP r1,r3
  JMP[LT] @nv_phys_fail
  MOVI r3,0
  JMP @nv_phys_out
nv_phys_fail:
  MOVI r1,0
  MOVI r3,1
nv_phys_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nv_read_range r1=ctrl r2=ns r3=lba_lo r4=lba_hi r5=count_lo r6=count_hi
;              r7=dst -> r1=status r2=bytes_lo r3=bytes_hi.
nv_read_range:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_RD+0
  ST r2,r0,#NVX_RD+1
  ST r3,r0,#NVX_RD+2
  ST r4,r0,#NVX_RD+3
  ST r5,r0,#NVX_RD+4
  ST r6,r0,#NVX_RD+5
  ST r7,r0,#NVX_RD+6
  CMP r7,r0
  JMP[EQ] @nv_rd_addr
  ; lookup
  LD r1,r0,#NVX_RD+1
  LD r2,r0,#NVX_RD+2
  LD r3,r0,#NVX_RD+3
  LD r4,r0,#NVX_RD+4
  LD r5,r0,#NVX_RD+5
  CALL @nv_lookup
  CMP r1,r0
  JMP[EQ] @nv_rd_lba
  ST r1,r0,#NVX_RD+7
  ; nv_phys needs lba_size in NVX_LOOK+16
  LD r2,r0,#NVX_RD+1
  LD r2,r2,#NV_NS_LBASZ
  ST r2,r0,#NVX_LOOK+16
  LD r1,r0,#NVX_RD+7
  LD r2,r0,#NVX_RD+2
  LD r3,r0,#NVX_RD+3
  CALL @nv_phys
  CMP r3,r0
  JMP[NE] @nv_rd_lba
  ST r1,r0,#NVX_RD+8
  ST r2,r0,#NVX_RD+9
  ; bytes = count * lba_size
  LD r1,r0,#NVX_RD+1
  LD r2,r0,#NVX_RD+4
  LD r3,r0,#NVX_RD+5
  CALL @nv_bytes
  CMP r2,r0
  JMP[NE] @nv_rd_lba
  ST r1,r0,#NVX_RD+10
  ST r2,r0,#NVX_RD+11
  ; copy out then update stats
  LD r1,r0,#NVX_RD+8
  LD r2,r0,#NVX_RD+6
  LD r3,r0,#NVX_RD+10
  CALL @nv_copy
  LD r1,r0,#NVX_RD+1
  LD r2,r1,#NV_NS_READS
  ADDI r2,r2,1
  ST r2,r1,#NV_NS_READS
  LD r2,r1,#NV_NS_BR
  LD r3,r1,#NV_NS_BR+1
  LD r4,r0,#NVX_RD+10
  LD r5,r0,#NVX_RD+11
  ADD r2,r2,r4
  CMP r2,r4
  MOVI r6,0
  MOVI[LT] r6,1
  ADD r3,r3,r6
  ADD r3,r3,r5
  ST r2,r1,#NV_NS_BR
  ST r3,r1,#NV_NS_BR+1
  MOVI r1,0
  LD r2,r0,#NVX_RD+10
  LD r3,r0,#NVX_RD+11
  JMP @nv_rd_out
nv_rd_bad:
  MOVI r1,#NVME_EBAD
  JMP @nv_rd_out
nv_rd_addr:
  MOVI r1,#NVME_EADDR
  JMP @nv_rd_out
nv_rd_lba:
  MOVI r1,#NVME_ELBA
nv_rd_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nv_write_range r1=ctrl r2=ns r3=lba_lo r4=lba_hi r5=count_lo r6=count_hi
;               r7=src -> r1=status r2=bytes_lo r3=bytes_hi.
nv_write_range:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_WR+0
  ST r2,r0,#NVX_WR+1
  ST r3,r0,#NVX_WR+2
  ST r4,r0,#NVX_WR+3
  ST r5,r0,#NVX_WR+4
  ST r6,r0,#NVX_WR+5
  ST r7,r0,#NVX_WR+6
  CMP r7,r0
  JMP[EQ] @nv_wr_addr
  LD r1,r0,#NVX_WR+1
  LD r2,r1,#NV_NS_FLAGS
  MOVI r3,#NVME_NS_F_RO
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @nv_wr_ro
  LD r1,r0,#NVX_WR+1
  LD r2,r0,#NVX_WR+2
  LD r3,r0,#NVX_WR+3
  LD r4,r0,#NVX_WR+4
  LD r5,r0,#NVX_WR+5
  CALL @nv_lookup
  CMP r1,r0
  JMP[EQ] @nv_wr_lba
  ST r1,r0,#NVX_WR+7
  LD r2,r0,#NVX_WR+1
  LD r2,r2,#NV_NS_LBASZ
  ST r2,r0,#NVX_LOOK+16
  LD r1,r0,#NVX_WR+7
  LD r2,r0,#NVX_WR+2
  LD r3,r0,#NVX_WR+3
  CALL @nv_phys
  CMP r3,r0
  JMP[NE] @nv_wr_lba
  ST r1,r0,#NVX_WR+8
  LD r1,r0,#NVX_WR+1
  LD r2,r0,#NVX_WR+4
  LD r3,r0,#NVX_WR+5
  CALL @nv_bytes
  CMP r2,r0
  JMP[NE] @nv_wr_lba
  ST r1,r0,#NVX_WR+10
  ST r2,r0,#NVX_WR+11
  LD r1,r0,#NVX_WR+6
  LD r2,r0,#NVX_WR+8
  LD r3,r0,#NVX_WR+10
  CALL @nv_copy
  LD r1,r0,#NVX_WR+1
  LD r2,r1,#NV_NS_WRITES
  ADDI r2,r2,1
  ST r2,r1,#NV_NS_WRITES
  LD r2,r1,#NV_NS_BW
  LD r3,r1,#NV_NS_BW+1
  LD r4,r0,#NVX_WR+10
  LD r5,r0,#NVX_WR+11
  ADD r2,r2,r4
  CMP r2,r4
  MOVI r6,0
  MOVI[LT] r6,1
  ADD r3,r3,r6
  ADD r3,r3,r5
  ST r2,r1,#NV_NS_BW
  ST r3,r1,#NV_NS_BW+1
  MOVI r1,0
  LD r2,r0,#NVX_WR+10
  LD r3,r0,#NVX_WR+11
  JMP @nv_wr_out
nv_wr_bad:
  MOVI r1,#NVME_EBAD
  JMP @nv_wr_out
nv_wr_addr:
  MOVI r1,#NVME_EADDR
  JMP @nv_wr_out
nv_wr_ro:
  LD r1,r0,#NVX_WR+1
  LD r2,r1,#NV_NS_ROERR
  ADDI r2,r2,1
  ST r2,r1,#NV_NS_ROERR
  MOVI r1,#NVME_ERO
  JMP @nv_wr_out
nv_wr_lba:
  MOVI r1,#NVME_ELBA
nv_wr_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nv_trim_range r1=ctrl r2=ns r3=lba_lo r4=lba_hi r5=count_lo r6=count_hi
;              -> r1=status r2=bytes_lo r3=bytes_hi.
nv_trim_range:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_TR+0
  ST r2,r0,#NVX_TR+1
  ST r3,r0,#NVX_TR+2
  ST r4,r0,#NVX_TR+3
  ST r5,r0,#NVX_TR+4
  ST r6,r0,#NVX_TR+5
  LD r1,r0,#NVX_TR+1
  LD r2,r1,#NV_NS_FLAGS
  MOVI r3,#NVME_NS_F_RO
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @nv_tr_ro
  LD r1,r0,#NVX_TR+1
  LD r2,r0,#NVX_TR+2
  LD r3,r0,#NVX_TR+3
  LD r4,r0,#NVX_TR+4
  LD r5,r0,#NVX_TR+5
  CALL @nv_lookup
  CMP r1,r0
  JMP[EQ] @nv_tr_lba
  ST r1,r0,#NVX_TR+6
  LD r2,r0,#NVX_TR+1
  LD r2,r2,#NV_NS_LBASZ
  ST r2,r0,#NVX_LOOK+16
  LD r1,r0,#NVX_TR+6
  LD r2,r0,#NVX_TR+2
  LD r3,r0,#NVX_TR+3
  CALL @nv_phys
  CMP r3,r0
  JMP[NE] @nv_tr_lba
  ST r1,r0,#NVX_TR+8
  LD r1,r0,#NVX_TR+1
  LD r2,r0,#NVX_TR+4
  LD r3,r0,#NVX_TR+5
  CALL @nv_bytes
  CMP r2,r0
  JMP[NE] @nv_tr_lba
  ST r1,r0,#NVX_TR+10
  ST r2,r0,#NVX_TR+11
  LD r1,r0,#NVX_TR+8
  LD r2,r0,#NVX_TR+10
  CALL @nv_zero
  LD r1,r0,#NVX_TR+1
  LD r2,r1,#NV_NS_TRIMS
  ADDI r2,r2,1
  ST r2,r1,#NV_NS_TRIMS
  LD r2,r1,#NV_NS_BT
  LD r3,r1,#NV_NS_BT+1
  LD r4,r0,#NVX_TR+10
  LD r5,r0,#NVX_TR+11
  ADD r2,r2,r4
  CMP r2,r4
  MOVI r6,0
  MOVI[LT] r6,1
  ADD r3,r3,r6
  ADD r3,r3,r5
  ST r2,r1,#NV_NS_BT
  ST r3,r1,#NV_NS_BT+1
  MOVI r1,0
  LD r2,r0,#NVX_TR+10
  LD r3,r0,#NVX_TR+11
  JMP @nv_tr_out
nv_tr_ro:
  LD r1,r0,#NVX_TR+1
  LD r2,r1,#NV_NS_ROERR
  ADDI r2,r2,1
  ST r2,r1,#NV_NS_ROERR
  MOVI r1,#NVME_ERO
  JMP @nv_tr_out
nv_tr_lba:
  MOVI r1,#NVME_ELBA
nv_tr_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nnvme_ns_init r1=ns r2=cfg -> 0/err.
; cfg: +0 nsid +1 lba_shift +2 cap_lo +3 cap_hi +4 ext table +5 ext cap
;      +6 base_lo +7 base_hi +8 size_lo +9 size_hi +10 flags +11 generation
nnvme_ns_init:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_NSINIT+0
  ST r2,r0,#NVX_NSINIT+1
  CMP r1,r0
  JMP[EQ] @nv_nsi_bad
  CMP r2,r0
  JMP[EQ] @nv_nsi_bad
  LD r3,r2,0
  CMP r3,r0
  JMP[EQ] @nv_nsi_bad
  MOVI r4,255
  CMP r3,r4
  JMP[GT] @nv_nsi_bad
  LD r3,r2,1
  MOVI r4,9
  CMP r3,r4
  JMP[LT] @nv_nsi_bad
  MOVI r4,16
  CMP r3,r4
  JMP[GT] @nv_nsi_bad
  LD r3,r2,4
  CMP r3,r0
  JMP[EQ] @nv_nsi_bad
  LD r3,r2,5
  CMP r3,r0
  JMP[EQ] @nv_nsi_bad
  LD r3,r2,8
  LD r4,r2,9
  CMP r3,r0
  JMP[NE] @nv_nsi_size
  CMP r4,r0
  JMP[EQ] @nv_nsi_bad
nv_nsi_size:
  LD r3,r2,10
  MOVI r4,1
  CMP r3,r4
  JMP[GT] @nv_nsi_bad

  LD r1,r0,#NVX_NSINIT+0
  MOVI r2,#NV_NS_WORDS
  BFILL r1,r0,r2
  LA r3,#NVME_NS_MAGIC
  ST r3,r1,#NV_NS_MAGIC
  MOVI r3,#NVME_VERSION
  ST r3,r1,#NV_NS_VERSION
  LD r2,r0,#NVX_NSINIT+1
  LD r3,r2,0
  ST r3,r1,#NV_NS_ID
  LD r3,r2,1
  ST r3,r1,#NV_NS_SHIFT
  MOVI r4,1
  MOVI r5,9
  CMP r3,r5
  JMP[EQ] @nv_nsi_l9
  MOVI r5,10
  CMP r3,r5
  JMP[EQ] @nv_nsi_l10
  MOVI r5,11
  CMP r3,r5
  JMP[EQ] @nv_nsi_l11
  MOVI r5,12
  CMP r3,r5
  JMP[EQ] @nv_nsi_l12
  MOVI r5,13
  CMP r3,r5
  JMP[EQ] @nv_nsi_l13
  MOVI r5,14
  CMP r3,r5
  JMP[EQ] @nv_nsi_l14
  MOVI r5,15
  CMP r3,r5
  JMP[EQ] @nv_nsi_l15
  LA r4,0x10000
  JMP @nv_nsi_lset
nv_nsi_l15:
  LA r4,0x8000
  JMP @nv_nsi_lset
nv_nsi_l14:
  LA r4,0x4000
  JMP @nv_nsi_lset
nv_nsi_l13:
  LA r4,0x2000
  JMP @nv_nsi_lset
nv_nsi_l12:
  LA r4,0x1000
  JMP @nv_nsi_lset
nv_nsi_l11:
  LA r4,0x800
  JMP @nv_nsi_lset
nv_nsi_l10:
  LA r4,0x400
  JMP @nv_nsi_lset
nv_nsi_l9:
  LA r4,0x200
nv_nsi_lset:
  ST r4,r1,#NV_NS_LBASZ
  LD r3,r2,2
  ST r3,r1,#NV_NS_CAP
  LD r3,r2,3
  ST r3,r1,#NV_NS_CAP+1
  LD r3,r2,10
  ST r3,r1,#NV_NS_FLAGS
  LD r3,r2,4
  ST r3,r1,#NV_NS_EXT
  LD r3,r2,5
  ST r3,r1,#NV_NS_EXTCAP
  ST r0,r1,#NV_NS_EXTN
  LD r3,r2,6
  ST r3,r1,#NV_NS_BASE
  LD r3,r2,7
  ST r3,r1,#NV_NS_BASE+1
  LD r3,r2,8
  ST r3,r1,#NV_NS_SIZE
  LD r3,r2,9
  ST r3,r1,#NV_NS_SIZE+1
  LD r3,r2,11
  CMP r3,r0
  JMP[NE] @nv_nsi_gen
  MOVI r3,1
nv_nsi_gen:
  ST r3,r1,#NV_NS_GEN
  MOVI r1,0
  JMP @nv_nsi_out
nv_nsi_bad:
  MOVI r1,#NVME_EBAD
nv_nsi_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nnvme_ns_add_ext r1=ns r2=lba_lo r3=lba_hi r4=count_lo r5=count_hi
;                   r6=phys -> 0/err.
nnvme_ns_add_ext:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_EXT+0
  ST r6,r0,#NVX_EXT+1
  ST r2,r0,#NVX_EXT+2
  ST r3,r0,#NVX_EXT+3
  ST r4,r0,#NVX_EXT+4
  ST r5,r0,#NVX_EXT+5
  CALL @nv_ns_ok
  CMP r1,r0
  JMP[EQ] @nv_ext_bad
  LD r1,r0,#NVX_EXT+0
  LD r2,r0,#NVX_EXT+1
  CMP r2,r0
  JMP[EQ] @nv_ext_bad
  LD r1,r0,#NVX_EXT+0
  LD r2,r0,#NVX_EXT+4
  LD r3,r0,#NVX_EXT+5
  CMP r2,r0
  JMP[NE] @nv_ext_cnt
  CMP r3,r0
  JMP[EQ] @nv_ext_bad
nv_ext_cnt:
  LD r2,r1,#NV_NS_EXTN
  LD r3,r1,#NV_NS_EXTCAP
  CMP r2,r3
  JMP[GE] @nv_ext_full
  ; end = lba + count
  LD r1,r0,#NVX_EXT+2
  LD r2,r0,#NVX_EXT+3
  LD r3,r0,#NVX_EXT+4
  LD r4,r0,#NVX_EXT+5
  CALL @n64_add
  ST r1,r0,#NVX_EXT+6
  ST r2,r0,#NVX_EXT+7
  ; a 64-bit wrap makes end < lba
  LD r3,r0,#NVX_EXT+2
  LD r4,r0,#NVX_EXT+3
  CALL @n64_cmp
  LA r6,0xFFFFFFFF
  CMP r1,r6
  JMP[EQ] @nv_ext_lba
  ; end <= capacity
  LD r3,r0,#NVX_EXT+0
  LD r3,r3,#NV_NS_CAP
  LD r4,r0,#NVX_EXT+0
  LD r4,r4,#NV_NS_CAP+1
  CALL @n64_cmp
  MOVI r6,1
  CMP r1,r6
  JMP[EQ] @nv_ext_lba
  ; physical bytes = count * lba_size
  LD r1,r0,#NVX_EXT+0
  LD r2,r0,#NVX_EXT+4
  LD r3,r0,#NVX_EXT+5
  CALL @nv_bytes
  CMP r2,r0
  JMP[NE] @nv_ext_lba
  ST r1,r0,#NVX_EXT+8
  ; phys + bytes no 32-bit wrap
  LD r3,r0,#NVX_EXT+1
  ADD r4,r3,r1
  CMP r4,r3
  JMP[LT] @nv_ext_lba
  ST r4,r0,#NVX_EXT+9
  ; phys >= backing base
  LD r1,r0,#NVX_EXT+1
  MOVI r2,0
  LD r3,r0,#NVX_EXT+0
  LD r3,r3,#NV_NS_BASE
  LD r4,r0,#NVX_EXT+0
  LD r4,r4,#NV_NS_BASE+1
  CALL @n64_cmp
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nv_ext_lba
  ; phys_end <= base + size
  LD r1,r0,#NVX_EXT+0
  LD r1,r1,#NV_NS_BASE
  LD r2,r0,#NVX_EXT+0
  LD r2,r2,#NV_NS_BASE+1
  LD r3,r0,#NVX_EXT+0
  LD r3,r3,#NV_NS_SIZE
  LD r4,r0,#NVX_EXT+0
  LD r4,r4,#NV_NS_SIZE+1
  CALL @n64_add
  ST r1,r0,#NVX_EXT+12
  ST r2,r0,#NVX_EXT+13
  LD r1,r0,#NVX_EXT+9
  MOVI r2,0
  LD r3,r0,#NVX_EXT+12
  LD r4,r0,#NVX_EXT+13
  CALL @n64_cmp
  MOVI r6,1
  CMP r1,r6
  JMP[EQ] @nv_ext_lba
  ; overlap check
  MOVI r2,0
  ST r2,r0,#NVX_EXT+10
nv_ext_ovl:
  LD r2,r0,#NVX_EXT+10
  LD r1,r0,#NVX_EXT+0
  LD r3,r1,#NV_NS_EXTN
  CMP r2,r3
  JMP[GE] @nv_ext_store
  SHL r3,r2,3
  LD r4,r1,#NV_NS_EXT
  ADD r3,r3,r4
  ST r3,r0,#NVX_EXT+11
  LD r1,r3,0
  LD r2,r3,1
  LD r3,r3,2
  LD r4,r0,#NVX_EXT+11
  LD r4,r4,3
  CALL @n64_add
  ST r1,r0,#NVX_EXT+12
  ST r2,r0,#NVX_EXT+13
  ; new_lba < ext_end ?
  LD r1,r0,#NVX_EXT+2
  LD r2,r0,#NVX_EXT+3
  LD r3,r0,#NVX_EXT+12
  LD r4,r0,#NVX_EXT+13
  CALL @n64_cmp
  MOVI r6,1
  CMP r1,r6
  JMP[EQ] @nv_ext_next
  ; ext_lba < new_end ?  (only reached when new_lba < ext_end)
  LD r1,r0,#NVX_EXT+11
  LD r1,r1,0
  LD r2,r0,#NVX_EXT+11
  LD r2,r2,1
  LD r3,r0,#NVX_EXT+6
  LD r4,r0,#NVX_EXT+7
  CALL @n64_cmp
  LA r6,0xFFFFFFFF
  CMP r1,r6
  JMP[EQ] @nv_ext_space
  JMP @nv_ext_next
nv_ext_next:
  LD r2,r0,#NVX_EXT+10
  ADDI r2,r2,1
  ST r2,r0,#NVX_EXT+10
  JMP @nv_ext_ovl

nv_ext_store:
  LD r1,r0,#NVX_EXT+0
  LD r2,r1,#NV_NS_EXTN
  SHL r3,r2,3
  LD r4,r1,#NV_NS_EXT
  ADD r3,r3,r4
  LD r4,r0,#NVX_EXT+2
  ST r4,r3,#NV_E_LBA
  LD r4,r0,#NVX_EXT+3
  ST r4,r3,#NV_E_LBA+1
  LD r4,r0,#NVX_EXT+4
  ST r4,r3,#NV_E_CNT
  LD r4,r0,#NVX_EXT+5
  ST r4,r3,#NV_E_CNT+1
  LD r4,r0,#NVX_EXT+1
  ST r4,r3,#NV_E_PHYS
  ST r0,r3,#NV_E_FLAGS
  ST r0,r3,#NV_E_FLAGS+1
  ST r0,r3,#NV_E_FLAGS+2
  ADDI r2,r2,1
  ST r2,r1,#NV_NS_EXTN
  MOVI r1,0
  JMP @nv_ext_out
nv_ext_full:
  MOVI r1,#NVME_ESPACE
  JMP @nv_ext_out
nv_ext_space:
  MOVI r1,#NVME_ESPACE
  JMP @nv_ext_out
nv_ext_lba:
  MOVI r1,#NVME_ELBA
  JMP @nv_ext_out
nv_ext_bad:
  MOVI r1,#NVME_EBAD
nv_ext_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nnvme_ns_info r1=ns r2=out(32) -> 0/err.
nnvme_ns_info:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_IDENT+0
  ST r2,r0,#NVX_IDENT+1
  CALL @nv_ns_ok
  CMP r1,r0
  JMP[EQ] @nv_info_bad
  LD r1,r0,#NVX_IDENT+0
  LD r2,r0,#NVX_IDENT+1
  MOVI r3,#NV_NS_WORDS
  BCOPY r2,r1,r3
  MOVI r1,0
  JMP @nv_info_out
nv_info_bad:
  MOVI r1,#NVME_EBAD
nv_info_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nnvme_ns_stats r1=ns r2=out(16) -> 0/err.
nnvme_ns_stats:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_IDENT+0
  ST r2,r0,#NVX_IDENT+1
  CALL @nv_ns_ok
  CMP r1,r0
  JMP[EQ] @nv_stats_bad
  LD r1,r0,#NVX_IDENT+0
  LD r2,r0,#NVX_IDENT+1
  LD r3,r1,#NV_NS_READS
  ST r3,r2,0
  LD r3,r1,#NV_NS_WRITES
  ST r3,r2,1
  LD r3,r1,#NV_NS_TRIMS
  ST r3,r2,2
  LD r3,r1,#NV_NS_FLUSHES
  ST r3,r2,3
  LD r3,r1,#NV_NS_BR
  ST r3,r2,4
  LD r3,r1,#NV_NS_BR+1
  ST r3,r2,5
  LD r3,r1,#NV_NS_BW
  ST r3,r2,6
  LD r3,r1,#NV_NS_BW+1
  ST r3,r2,7
  LD r3,r1,#NV_NS_BT
  ST r3,r2,8
  LD r3,r1,#NV_NS_BT+1
  ST r3,r2,9
  LD r3,r1,#NV_NS_LBAERR
  ST r3,r2,10
  LD r3,r1,#NV_NS_ROERR
  ST r3,r2,11
  LD r3,r1,#NV_NS_IOERR
  ST r3,r2,12
  LD r3,r1,#NV_NS_EXTN
  ST r3,r2,13
  LD r3,r1,#NV_NS_GEN
  ST r3,r2,14
  ST r0,r2,15
  MOVI r1,0
  JMP @nv_stats_out
nv_stats_bad:
  MOVI r1,#NVME_EBAD
nv_stats_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nnvme_ctrl_init r1=ctrl r2=cfg -> 0/err.
; cfg: +0 namespace +1 q table +2 q capacity +3 max depth +4 generation
nnvme_ctrl_init:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_CTRL+0
  ST r2,r0,#NVX_CTRL+1
  CMP r1,r0
  JMP[EQ] @nv_ctrl_bad
  CMP r2,r0
  JMP[EQ] @nv_ctrl_bad
  LD r3,r2,1
  CMP r3,r0
  JMP[EQ] @nv_ctrl_bad
  LD r3,r2,2
  CMP r3,r0
  JMP[EQ] @nv_ctrl_bad
  MOVI r4,64
  CMP r3,r4
  JMP[GT] @nv_ctrl_bad
  LD r3,r2,3
  CMP r3,r0
  JMP[EQ] @nv_ctrl_bad
  MOVI r4,64
  CMP r3,r4
  JMP[GT] @nv_ctrl_bad
  LD r1,r2,0
  CALL @nv_ns_ok
  CMP r1,r0
  JMP[EQ] @nv_ctrl_bad
  LD r1,r0,#NVX_CTRL+0
  MOVI r2,32
  BFILL r1,r0,r2
  LA r3,#NVME_CTRL_MAGIC
  ST r3,r1,#NV_C_MAGIC
  MOVI r3,#NVME_VERSION
  ST r3,r1,#NV_C_VERSION
  LD r2,r0,#NVX_CTRL+1
  LD r3,r2,0
  ST r3,r1,#NV_C_NS
  LD r3,r2,1
  ST r3,r1,#NV_C_QTAB
  LD r3,r2,2
  ST r3,r1,#NV_C_QCAP
  LD r3,r2,3
  ST r3,r1,#NV_C_MAXD
  LD r3,r2,4
  CMP r3,r0
  JMP[NE] @nv_ctrl_gen
  MOVI r3,1
nv_ctrl_gen:
  ST r3,r1,#NV_C_GEN
  MOVI r3,1
  ST r3,r1,#NV_C_STATE
  MOVI r1,0
  JMP @nv_ctrl_out
nv_ctrl_bad:
  MOVI r1,#NVME_EBAD
nv_ctrl_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nnvme_qpair_create r1=ctrl r2=qid r3=depth r4=sq r5=cq -> 0/err.
nnvme_qpair_create:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_QP+0
  ST r2,r0,#NVX_QP+1
  ST r3,r0,#NVX_QP+2
  ST r4,r0,#NVX_QP+3
  ST r5,r0,#NVX_QP+4
  CMP r1,r0
  JMP[EQ] @nv_qp_bad
  LD r6,r1,#NV_C_MAGIC
  LA r7,#NVME_CTRL_MAGIC
  CMP r6,r7
  JMP[NE] @nv_qp_bad
  LD r6,r0,#NVX_QP+1
  CMP r6,r0
  JMP[EQ] @nv_qp_bad
  LD r7,r0,#NVX_QP+0
  LD r7,r7,#NV_C_QCAP
  CMP r6,r7
  JMP[GT] @nv_qp_bad
  LD r6,r0,#NVX_QP+2
  CMP r6,r0
  JMP[EQ] @nv_qp_bad
  LD r7,r0,#NVX_QP+0
  LD r7,r7,#NV_C_MAXD
  CMP r6,r7
  JMP[GT] @nv_qp_bad
  LD r6,r0,#NVX_QP+3
  CMP r6,r0
  JMP[EQ] @nv_qp_bad
  LD r6,r0,#NVX_QP+4
  CMP r6,r0
  JMP[EQ] @nv_qp_bad
  ; qpair address
  LD r1,r0,#NVX_QP+1
  SUB r2,r1,r13
  SHL r2,r2,5
  LD r3,r0,#NVX_QP+0
  LD r3,r3,#NV_C_QTAB
  ADD r2,r2,r3
  ST r2,r0,#NVX_QP+5
  LD r3,r2,#NV_Q_MAGIC
  LA r4,#NVME_QP_MAGIC
  CMP r3,r4
  JMP[EQ] @nv_qp_bad
  MOVI r3,#NV_Q_WORDS
  BFILL r2,r0,r3
  LA r3,#NVME_QP_MAGIC
  ST r3,r2,#NV_Q_MAGIC
  MOVI r3,#NVME_VERSION
  ST r3,r2,#NV_Q_VERSION
  LD r3,r0,#NVX_QP+1
  ST r3,r2,#NV_Q_ID
  LD r3,r0,#NVX_QP+2
  ST r3,r2,#NV_Q_DEPTH
  LD r3,r0,#NVX_QP+3
  ST r3,r2,#NV_Q_SQ
  LD r3,r0,#NVX_QP+4
  ST r3,r2,#NV_Q_CQ
  MOVI r3,1
  ST r3,r2,#NV_Q_STATE
  LD r1,r0,#NVX_QP+0
  LD r3,r1,#NV_C_QN
  ADDI r3,r3,1
  ST r3,r1,#NV_C_QN
  MOVI r2,0
  CALL @nv_clear_err
  MOVI r1,0
  JMP @nv_qp_out
nv_qp_bad:
  LD r1,r0,#NVX_QP+0
  MOVI r2,#NVME_EBAD
  CALL @nv_note
nv_qp_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nnvme_qpair_delete r1=ctrl r2=qid -> 0/err.
nnvme_qpair_delete:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_QP+0
  ST r2,r0,#NVX_QP+1
  CALL @nv_qp
  CMP r1,r0
  JMP[EQ] @nv_qpd_bad
  ST r0,r1,#NV_Q_STATE
  ST r0,r1,#NV_Q_MAGIC
  LD r1,r0,#NVX_QP+0
  LD r2,r1,#NV_C_QN
  ADDI r2,r2,-1
  ST r2,r1,#NV_C_QN
  MOVI r2,0
  CALL @nv_clear_err
  MOVI r1,0
  JMP @nv_qpd_out
nv_qpd_bad:
  LD r1,r0,#NVX_QP+0
  MOVI r2,#NVME_ENOENT
  CALL @nv_note
nv_qpd_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nnvme_submit r1=ctrl r2=qid r3=sqe -> slot+1 / 0 with errno.
nnvme_submit:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_SUB+0
  ST r2,r0,#NVX_SUB+1
  ST r3,r0,#NVX_SUB+2
  CALL @nv_qp
  CMP r1,r0
  JMP[EQ] @nv_sub_bad
  ST r1,r0,#NVX_SUB+3
  LD r2,r0,#NVX_SUB+2
  CMP r2,r0
  JMP[EQ] @nv_sub_bad
  LD r2,r1,#NV_Q_SQT
  LD r3,r1,#NV_Q_SQH
  SUB r4,r2,r3
  LD r5,r1,#NV_Q_DEPTH
  CMP r4,r5
  JMP[GE] @nv_sub_full
  ; slot = tail % depth
  MODU r4,r2,r5
  ST r4,r0,#NVX_SUB+4
  ; sq slot = sq + slot*16
  SHL r4,r4,4
  LD r6,r1,#NV_Q_SQ
  ADD r4,r4,r6
  ST r4,r0,#NVX_SUB+5
  ; copy 16 words from the caller SQE
  MOVI r7,0
nv_sub_copy:
  LD r8,r0,#NVX_SUB+2
  ADD r8,r8,r7
  LD r9,r8,0
  LD r10,r0,#NVX_SUB+5
  ADD r10,r10,r7
  ST r9,r10,0
  ADDI r7,r7,1
  MOVI r9,#NV_S_WORDS
  CMP r7,r9
  JMP[LT] @nv_sub_copy
  ; advance tail and counters
  LD r1,r0,#NVX_SUB+3
  LD r2,r1,#NV_Q_SQT
  ADDI r2,r2,1
  ST r2,r1,#NV_Q_SQT
  LD r2,r1,#NV_Q_SUB
  ADDI r2,r2,1
  ST r2,r1,#NV_Q_SUB
  LD r1,r0,#NVX_SUB+0
  LD r2,r1,#NV_C_SUB
  ADDI r2,r2,1
  ST r2,r1,#NV_C_SUB
  MOVI r2,0
  CALL @nv_clear_err
  LD r1,r0,#NVX_SUB+4
  ADDI r1,r1,1
  JMP @nv_sub_out
nv_sub_bad:
  LD r1,r0,#NVX_SUB+0
  MOVI r2,#NVME_ENOENT
  CALL @nv_note
  MOVI r1,0
  JMP @nv_sub_out
nv_sub_full:
  LD r1,r0,#NVX_SUB+0
  MOVI r2,#NVME_EQFULL
  CALL @nv_note
  LD r1,r0,#NVX_SUB+0
  LD r2,r1,#NV_C_QFULL
  ADDI r2,r2,1
  ST r2,r1,#NV_C_QFULL
  LD r1,r0,#NVX_SUB+3
  LD r2,r1,#NV_Q_FULL
  ADDI r2,r2,1
  ST r2,r1,#NV_Q_FULL
  MOVI r1,0
nv_sub_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nnvme_sq_doorbell r1=ctrl r2=qid -> newly rung / 0 (errno).
nnvme_sq_doorbell:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_DB+0
  ST r2,r0,#NVX_DB+1
  CALL @nv_qp
  CMP r1,r0
  JMP[EQ] @nv_db_bad
  LD r2,r1,#NV_Q_DB
  LD r3,r1,#NV_Q_SQT
  SUB r4,r3,r2
  ST r3,r1,#NV_Q_DB
  LD r1,r0,#NVX_DB+0
  MOVI r2,0
  CALL @nv_clear_err
  ADD r1,r4,r0
  JMP @nv_db_out
nv_db_bad:
  LD r1,r0,#NVX_DB+0
  MOVI r2,#NVME_ENOENT
  CALL @nv_note
  MOVI r1,0
nv_db_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nv_exec r1=ctrl r2=qp r3=sqe -> r1=status r2=res_lo r3=res_hi.
nv_exec:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_EXEC+0
  ST r2,r0,#NVX_EXEC+1
  ST r3,r0,#NVX_EXEC+2
  LD r4,r1,#NV_C_NS
  ST r4,r0,#NVX_EXEC+3
  LD r1,r0,#NVX_EXEC+3
  CALL @nv_ns_ok
  CMP r1,r0
  JMP[EQ] @nv_ex_bad
  LD r3,r0,#NVX_EXEC+2
  LD r4,r3,#NV_S_OP
  ST r4,r0,#NVX_EXEC+4
  LD r5,r3,#NV_S_NSID
  LD r6,r0,#NVX_EXEC+3
  LD r6,r6,#NV_NS_ID
  CMP r5,r6
  JMP[NE] @nv_ex_ns
  LD r5,r3,#NV_S_LBA
  ST r5,r0,#NVX_EXEC+6
  LD r5,r3,#NV_S_LBA+1
  ST r5,r0,#NVX_EXEC+7
  LD r5,r3,#NV_S_NLB
  ST r5,r0,#NVX_EXEC+8
  LD r5,r3,#NV_S_NLB+1
  ST r5,r0,#NVX_EXEC+9
  LD r5,r3,#NV_S_DATA
  ST r5,r0,#NVX_EXEC+10

  LD r4,r0,#NVX_EXEC+4
  MOVI r5,#NVME_OP_READ
  CMP r4,r5
  JMP[EQ] @nv_ex_read
  MOVI r5,#NVME_OP_WRITE
  CMP r4,r5
  JMP[EQ] @nv_ex_write
  MOVI r5,#NVME_OP_FLUSH
  CMP r4,r5
  JMP[EQ] @nv_ex_flush
  MOVI r5,#NVME_OP_TRIM
  CMP r4,r5
  JMP[EQ] @nv_ex_trim
  MOVI r1,#NVME_EBAD
  JMP @nv_ex_done

nv_ex_read:
  LD r1,r0,#NVX_EXEC+0
  LD r2,r0,#NVX_EXEC+3
  LD r3,r0,#NVX_EXEC+6
  LD r4,r0,#NVX_EXEC+7
  LD r5,r0,#NVX_EXEC+8
  LD r6,r0,#NVX_EXEC+9
  LD r7,r0,#NVX_EXEC+10
  CALL @nv_read_range
  JMP @nv_ex_done
nv_ex_write:
  LD r1,r0,#NVX_EXEC+0
  LD r2,r0,#NVX_EXEC+3
  LD r3,r0,#NVX_EXEC+6
  LD r4,r0,#NVX_EXEC+7
  LD r5,r0,#NVX_EXEC+8
  LD r6,r0,#NVX_EXEC+9
  LD r7,r0,#NVX_EXEC+10
  CALL @nv_write_range
  JMP @nv_ex_done
nv_ex_trim:
  LD r1,r0,#NVX_EXEC+0
  LD r2,r0,#NVX_EXEC+3
  LD r3,r0,#NVX_EXEC+6
  LD r4,r0,#NVX_EXEC+7
  LD r5,r0,#NVX_EXEC+8
  LD r6,r0,#NVX_EXEC+9
  CALL @nv_trim_range
  JMP @nv_ex_done
nv_ex_flush:
  LD r1,r0,#NVX_EXEC+3
  LD r2,r1,#NV_NS_FLUSHES
  ADDI r2,r2,1
  ST r2,r1,#NV_NS_FLUSHES
  MOVI r1,0
  MOVI r2,0
  MOVI r3,0
  JMP @nv_ex_done
nv_ex_ns:
  MOVI r1,#NVME_ENOENT
  JMP @nv_ex_done
nv_ex_bad:
  MOVI r1,#NVME_EBAD
nv_ex_done:
  CMP r1,r0
  JMP[EQ] @nv_ex_out
  ; error accounting on the namespace/controller
  LD r4,r0,#NVX_EXEC+3
  CMP r4,r0
  JMP[EQ] @nv_ex_out
  MOVI r5,#NVME_ELBA
  CMP r1,r5
  JMP[NE] @nv_ex_err2
  LD r5,r4,#NV_NS_LBAERR
  ADDI r5,r5,1
  ST r5,r4,#NV_NS_LBAERR
  LD r5,r0,#NVX_EXEC+0
  LD r6,r5,#NV_C_LBAERR
  ADDI r6,r6,1
  ST r6,r5,#NV_C_LBAERR
  JMP @nv_ex_out
nv_ex_err2:
  MOVI r5,#NVME_ERO
  CMP r1,r5
  JMP[EQ] @nv_ex_out
  LD r5,r4,#NV_NS_IOERR
  ADDI r5,r5,1
  ST r5,r4,#NV_NS_IOERR
nv_ex_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nnvme_complete r1=ctrl r2=qid -> reaped entries / 0 (errno).
nnvme_complete:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_COMP+0
  ST r2,r0,#NVX_COMP+1
  CALL @nv_qp
  CMP r1,r0
  JMP[EQ] @nv_cmp_bad
  ST r1,r0,#NVX_COMP+2
  MOVI r2,0
  ST r2,r0,#NVX_COMP+3
nv_cmp_loop:
  LD r1,r0,#NVX_COMP+2
  LD r2,r1,#NV_Q_SQH
  LD r3,r1,#NV_Q_DB
  CMP r2,r3
  JMP[GE] @nv_cmp_done
  ; CQ space?
  LD r3,r1,#NV_Q_CQT
  LD r4,r1,#NV_Q_CQH
  SUB r3,r3,r4
  LD r4,r1,#NV_Q_DEPTH
  CMP r3,r4
  JMP[GE] @nv_cmp_full
  ; slot = sq_head % depth
  LD r2,r1,#NV_Q_SQH
  MODU r5,r2,r4
  ST r5,r0,#NVX_COMP+4
  ; sqe
  SHL r6,r5,4
  LD r7,r1,#NV_Q_SQ
  ADD r6,r6,r7
  ST r6,r0,#NVX_COMP+5
  ; execute
  LD r1,r0,#NVX_COMP+0
  LD r2,r0,#NVX_COMP+2
  LD r3,r0,#NVX_COMP+5
  CALL @nv_exec
  ST r1,r0,#NVX_COMP+6
  ST r2,r0,#NVX_COMP+7
  ST r3,r0,#NVX_COMP+8
  ; cqe slot = cq_tail % depth
  LD r1,r0,#NVX_COMP+2
  LD r2,r1,#NV_Q_CQT
  LD r3,r1,#NV_Q_DEPTH
  MODU r4,r2,r3
  SHL r4,r4,3
  LD r5,r1,#NV_Q_CQ
  ADD r4,r4,r5
  ST r4,r0,#NVX_COMP+9
  LD r5,r0,#NVX_COMP+6
  ST r5,r4,#NV_K_STATUS
  LD r5,r1,#NV_Q_ID
  ST r5,r4,#NV_K_QID
  LD r5,r0,#NVX_COMP+4
  ST r5,r4,#NV_K_SLOT
  ST r5,r4,#NV_K_CID
  LD r5,r0,#NVX_COMP+7
  ST r5,r4,#NV_K_RES
  LD r5,r0,#NVX_COMP+8
  ST r5,r4,#NV_K_RES+1
  LD r5,r0,#NVX_COMP+5
  LD r5,r5,#NV_S_NSID
  ST r5,r4,#NV_K_NSID
  LD r5,r1,#NV_Q_PHASE
  ST r5,r4,#NV_K_PHASE
  ; advance
  LD r2,r1,#NV_Q_SQH
  ADDI r2,r2,1
  ST r2,r1,#NV_Q_SQH
  LD r2,r1,#NV_Q_CQT
  ADDI r2,r2,1
  ST r2,r1,#NV_Q_CQT
  LD r2,r1,#NV_Q_DONE
  ADDI r2,r2,1
  ST r2,r1,#NV_Q_DONE
  LD r2,r0,#NVX_COMP+3
  ADDI r2,r2,1
  ST r2,r0,#NVX_COMP+3
  LD r2,r0,#NVX_COMP+0
  LD r3,r2,#NV_C_DONE
  ADDI r3,r3,1
  ST r3,r2,#NV_C_DONE
  ; error counter and per-op bytes
  LD r3,r0,#NVX_COMP+6
  CMP r3,r0
  JMP[NE] @nv_cmp_err
  ; successful: add result bytes to qpair counter by opcode
  LD r3,r0,#NVX_COMP+5
  LD r4,r3,#NV_S_OP
  MOVI r5,#NVME_OP_READ
  CMP r4,r5
  JMP[EQ] @nv_cmp_br
  MOVI r5,#NVME_OP_WRITE
  CMP r4,r5
  JMP[EQ] @nv_cmp_bw
  MOVI r5,#NVME_OP_TRIM
  CMP r4,r5
  JMP[EQ] @nv_cmp_bt
  JMP @nv_cmp_loop
nv_cmp_br:
  LD r1,r0,#NVX_COMP+2
  LD r5,r0,#NVX_COMP+7
  LD r6,r1,#NV_Q_BR
  ADD r6,r6,r5
  ST r6,r1,#NV_Q_BR
  LD r6,r1,#NV_Q_BR+1
  LD r5,r0,#NVX_COMP+8
  ADD r6,r6,r5
  ST r6,r1,#NV_Q_BR+1
  JMP @nv_cmp_loop
nv_cmp_bw:
  LD r1,r0,#NVX_COMP+2
  LD r5,r0,#NVX_COMP+7
  LD r6,r1,#NV_Q_BW
  ADD r6,r6,r5
  ST r6,r1,#NV_Q_BW
  LD r6,r1,#NV_Q_BW+1
  LD r5,r0,#NVX_COMP+8
  ADD r6,r6,r5
  ST r6,r1,#NV_Q_BW+1
  JMP @nv_cmp_loop
nv_cmp_bt:
  LD r1,r0,#NVX_COMP+2
  LD r5,r0,#NVX_COMP+7
  LD r6,r1,#NV_Q_BT
  ADD r6,r6,r5
  ST r6,r1,#NV_Q_BT
  LD r6,r1,#NV_Q_BT+1
  LD r5,r0,#NVX_COMP+8
  ADD r6,r6,r5
  ST r6,r1,#NV_Q_BT+1
  JMP @nv_cmp_loop
nv_cmp_err:
  LD r2,r0,#NVX_COMP+0
  LD r3,r2,#NV_C_ERR
  ADDI r3,r3,1
  ST r3,r2,#NV_C_ERR
  LD r2,r0,#NVX_COMP+2
  LD r3,r2,#NV_Q_ERR
  ADDI r3,r3,1
  ST r3,r2,#NV_Q_ERR
  JMP @nv_cmp_loop
nv_cmp_full:
  LD r1,r0,#NVX_COMP+0
  MOVI r2,#NVME_EQFULL
  CALL @nv_note
  JMP @nv_cmp_out
nv_cmp_bad:
  LD r1,r0,#NVX_COMP+0
  MOVI r2,#NVME_ENOENT
  CALL @nv_note
  MOVI r2,0
  ST r2,r0,#NVX_COMP+3
  JMP @nv_cmp_out
nv_cmp_done:
  LD r1,r0,#NVX_COMP+0
  MOVI r2,0
  CALL @nv_clear_err
nv_cmp_out:
  LD r1,r0,#NVX_COMP+3
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nnvme_cqe r1=ctrl r2=qid r3=index r4=out(8) -> 0/err.
nnvme_cqe:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_CQE+0
  ST r2,r0,#NVX_CQE+1
  ST r3,r0,#NVX_CQE+2
  ST r4,r0,#NVX_CQE+3
  CALL @nv_qp
  CMP r1,r0
  JMP[EQ] @nv_cqe_bad
  ST r1,r0,#NVX_CQE+4
  LD r2,r1,#NV_Q_CQT
  LD r3,r1,#NV_Q_CQH
  SUB r2,r2,r3
  LD r4,r0,#NVX_CQE+2
  CMP r4,r2
  JMP[GE] @nv_cqe_bad
  ADD r2,r3,r4
  LD r3,r1,#NV_Q_DEPTH
  MODU r2,r2,r3
  SHL r2,r2,3
  LD r3,r1,#NV_Q_CQ
  ADD r2,r2,r3
  LD r3,r0,#NVX_CQE+3
  MOVI r4,#NV_K_WORDS
  BCOPY r3,r2,r4
  LD r1,r0,#NVX_CQE+0
  MOVI r2,0
  CALL @nv_clear_err
  MOVI r1,0
  JMP @nv_cqe_out
nv_cqe_bad:
  LD r1,r0,#NVX_CQE+0
  MOVI r2,#NVME_EBAD
  CALL @nv_note
nv_cqe_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nnvme_cq_doorbell r1=ctrl r2=qid r3=count -> 0/err.
nnvme_cq_doorbell:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_CQDB+0
  ST r2,r0,#NVX_CQDB+1
  ST r3,r0,#NVX_CQDB+2
  CALL @nv_qp
  CMP r1,r0
  JMP[EQ] @nv_cqdb_bad
  ST r1,r0,#NVX_CQDB+3
  LD r2,r1,#NV_Q_CQT
  LD r3,r1,#NV_Q_CQH
  SUB r2,r2,r3
  LD r4,r0,#NVX_CQDB+2
  CMP r4,r2
  JMP[GT] @nv_cqdb_bad
  ADD r3,r3,r4
  ST r3,r1,#NV_Q_CQH
  LD r1,r0,#NVX_CQDB+0
  MOVI r2,0
  CALL @nv_clear_err
  MOVI r1,0
  JMP @nv_cqdb_out
nv_cqdb_bad:
  LD r1,r0,#NVX_CQDB+0
  MOVI r2,#NVME_EBAD
  CALL @nv_note
nv_cqdb_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nnvme_errno r1=ctrl -> errno.
nnvme_errno:
  CMP r1,r0
  JMP[EQ] @nv_errno_no
  LD r1,r1,#NV_C_ERRNO
  RET
nv_errno_no:
  MOVI r1,#NVME_EBAD
  RET

; nnvme_identify r1=ctrl r2=nsid r3=out(16) -> 0/err.
nnvme_identify:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_IDENT+0
  ST r2,r0,#NVX_IDENT+1
  ST r3,r0,#NVX_IDENT+2
  CMP r1,r0
  JMP[EQ] @nv_id_bad
  CMP r3,r0
  JMP[EQ] @nv_id_bad
  LD r4,r1,#NV_C_MAGIC
  LA r5,#NVME_CTRL_MAGIC
  CMP r4,r5
  JMP[NE] @nv_id_bad
  LD r4,r1,#NV_C_NS
  ADD r1,r4,r0
  CALL @nv_ns_ok
  CMP r1,r0
  JMP[EQ] @nv_id_bad
  LD r1,r0,#NVX_IDENT+0
  LD r2,r1,#NV_C_NS
  LD r3,r0,#NVX_IDENT+1
  LD r4,r2,#NV_NS_ID
  CMP r3,r4
  JMP[NE] @nv_id_ns
  LD r5,r0,#NVX_IDENT+2
  ST r4,r5,0
  LD r4,r2,#NV_NS_CAP
  ST r4,r5,1
  LD r4,r2,#NV_NS_CAP+1
  ST r4,r5,2
  LD r4,r2,#NV_NS_SHIFT
  ST r4,r5,3
  LD r4,r2,#NV_NS_LBASZ
  ST r4,r5,4
  LD r4,r2,#NV_NS_EXTN
  ST r4,r5,5
  LD r4,r2,#NV_NS_EXTCAP
  ST r4,r5,6
  LD r4,r2,#NV_NS_SIZE
  ST r4,r5,7
  LD r4,r2,#NV_NS_SIZE+1
  ST r4,r5,8
  LD r4,r2,#NV_NS_FLAGS
  ST r4,r5,9
  LD r4,r2,#NV_NS_GEN
  ST r4,r5,10
  LD r4,r1,#NV_C_QN
  ST r4,r5,11
  LD r4,r1,#NV_C_MAXD
  ST r4,r5,12
  MOVI r4,#NVME_VERSION
  ST r4,r5,13
  ST r0,r5,14
  ST r0,r5,15
  MOVI r2,0
  CALL @nv_clear_err
  MOVI r1,0
  JMP @nv_id_out
nv_id_ns:
  MOVI r1,#NVME_ENOENT
  JMP @nv_id_out
nv_id_bad:
  MOVI r1,#NVME_EBAD
nv_id_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nv_div64_32 r1=lo r2=hi r3=div -> r1=qlo r2=qhi r3=rem.  Leaf.
; div must be nonzero and <= 2^31 (lba_size is 512..65536).
nv_div64_32:
  DIVU r8,r2,r3
  MODU r7,r2,r3
  MOVI r6,0
  MOVI r9,0
nv_div_l:
  MOVI r10,31
  CMP r9,r10
  JMP[GT] @nv_div_done
  SHR r10,r1,31
  SHL r1,r1,1
  SHL r7,r7,1
  ADD r7,r7,r10
  SHL r6,r6,1
  CMP r7,r3
  JMP[LT] @nv_div_nosub
  SUB r7,r7,r3
  ADDI r6,r6,1
nv_div_nosub:
  ADDI r9,r9,1
  JMP @nv_div_l
nv_div_done:
  ADD r1,r6,r0
  ADD r2,r8,r0
  ADD r3,r7,r0
  RET

; nnvme_view_read r1=ctrl r2=nsid r3=view r4=index_lo r5=index_hi
;                  r6=count r7=dst -> 0/err.
nnvme_view_read:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NVX_VIEW+0
  ST r2,r0,#NVX_VIEW+1
  ST r3,r0,#NVX_VIEW+2
  ST r4,r0,#NVX_VIEW+3
  ST r5,r0,#NVX_VIEW+4
  ST r6,r0,#NVX_VIEW+5
  ST r7,r0,#NVX_VIEW+6
  CMP r1,r0
  JMP[EQ] @nv_vw_bad
  CMP r3,r0
  JMP[EQ] @nv_vw_bad
  CMP r7,r0
  JMP[EQ] @nv_vw_bad
  LD r2,r3,#NV_V_MAGIC
  LA r4,#NVME_VIEW_MAGIC
  CMP r2,r4
  JMP[NE] @nv_vw_bad
  LD r2,r3,#NV_V_VERSION
  MOVI r4,#NVME_VERSION
  CMP r2,r4
  JMP[NE] @nv_vw_bad
  LD r2,r3,#NV_V_BLOCK
  CMP r2,r0
  JMP[EQ] @nv_vw_bad
  LA r4,0x10000
  CMP r2,r4
  JMP[GT] @nv_vw_bad
  LD r4,r0,#NVX_VIEW+2
  LD r4,r4,#NV_V_OFF
  ST r4,r0,#NVX_VIEW+17
  LD r5,r0,#NVX_VIEW+2
  LD r5,r5,#NV_V_OFF+1
  ST r5,r0,#NVX_VIEW+18
  ; start = view.off + index * block_bytes
  LD r1,r0,#NVX_VIEW+2
  LD r1,r1,#NV_V_BLOCK
  LD r2,r0,#NVX_VIEW+3
  LD r3,r0,#NVX_VIEW+4
  CALL @n64_mul32
  ; r1/r2 = scaled index
  LD r3,r0,#NVX_VIEW+17
  LD r4,r0,#NVX_VIEW+18
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @nv_vw_bad
  ST r1,r0,#NVX_VIEW+7
  ST r2,r0,#NVX_VIEW+8
  ; bytes = count * block_bytes
  LD r1,r0,#NVX_VIEW+2
  LD r1,r1,#NV_V_BLOCK
  LD r2,r0,#NVX_VIEW+5
  MOVI r3,0
  CALL @n64_mul32
  ST r1,r0,#NVX_VIEW+9
  ST r2,r0,#NVX_VIEW+10
  ; start+bytes <= view.off+view.size
  LD r1,r0,#NVX_VIEW+7
  LD r2,r0,#NVX_VIEW+8
  LD r3,r0,#NVX_VIEW+9
  LD r4,r0,#NVX_VIEW+10
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @nv_vw_bad
  ST r1,r0,#NVX_VIEW+11
  ST r2,r0,#NVX_VIEW+12
  LD r1,r0,#NVX_VIEW+2
  LD r1,r1,#NV_V_OFF
  LD r2,r0,#NVX_VIEW+2
  LD r2,r2,#NV_V_OFF+1
  LD r3,r0,#NVX_VIEW+2
  LD r3,r3,#NV_V_SIZE
  LD r4,r0,#NVX_VIEW+2
  LD r4,r4,#NV_V_SIZE+1
  CALL @n64_add
  ADD r3,r1,r0
  ADD r4,r2,r0
  LD r1,r0,#NVX_VIEW+11
  LD r2,r0,#NVX_VIEW+12
  CALL @n64_cmp
  MOVI r5,1
  CMP r1,r5
  JMP[EQ] @nv_vw_bad
  ; alignment: start and bytes multiples of lba_size
  LD r1,r0,#NVX_VIEW+0
  LD r1,r1,#NV_C_NS
  LD r2,r1,#NV_NS_LBASZ
  ADDI r3,r2,-1
  LD r4,r0,#NVX_VIEW+7
  BOOL.8 r5,r4,r3
  CMP r5,r0
  JMP[NE] @nv_vw_bad
  LD r4,r0,#NVX_VIEW+9
  BOOL.8 r5,r4,r3
  CMP r5,r0
  JMP[NE] @nv_vw_bad
  ; lba = start / lba_size; count_lba = bytes / lba_size
  LD r1,r0,#NVX_VIEW+7
  LD r2,r0,#NVX_VIEW+8
  LD r3,r0,#NVX_VIEW+0
  LD r3,r3,#NV_C_NS
  LD r3,r3,#NV_NS_LBASZ
  CALL @nv_div64_32
  ST r1,r0,#NVX_VIEW+13
  ST r2,r0,#NVX_VIEW+14
  LD r1,r0,#NVX_VIEW+9
  LD r2,r0,#NVX_VIEW+10
  LD r3,r0,#NVX_VIEW+0
  LD r3,r3,#NV_C_NS
  LD r3,r3,#NV_NS_LBASZ
  CALL @nv_div64_32
  ST r1,r0,#NVX_VIEW+15
  ST r2,r0,#NVX_VIEW+16
  ; read via the normal extent path
  LD r1,r0,#NVX_VIEW+0
  LD r2,r0,#NVX_VIEW+0
  LD r2,r2,#NV_C_NS
  LD r3,r0,#NVX_VIEW+13
  LD r4,r0,#NVX_VIEW+14
  LD r5,r0,#NVX_VIEW+15
  LD r6,r0,#NVX_VIEW+16
  LD r7,r0,#NVX_VIEW+6
  CALL @nv_read_range
  CMP r1,r0
  JMP[NE] @nv_vw_out
  LD r1,r0,#NVX_VIEW+0
  MOVI r2,0
  CALL @nv_clear_err
  MOVI r1,0
  JMP @nv_vw_out
nv_vw_bad:
  LD r1,r0,#NVX_VIEW+0
  MOVI r2,#NVME_EBAD
  CALL @nv_note
  MOVI r1,#NVME_EBAD
nv_vw_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
