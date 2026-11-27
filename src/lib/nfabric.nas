; nfabric.nas - emulated two-node loopback RDMA, remote KV and checkpoint
; transport (F11).
;
; Pure NaN.  This is an in-guest software fabric: two node records, queue
; pairs, memory regions with generation-tagged remote keys, posted receives
; and credits, send/recv/write/read work requests and completion queues.  It
; is not an InfiniBand/RoCE driver and makes no hardware claim.  The loopback
; exercises the semantics a real verbs layer must get right: FIFO ordering,
; credit exhaustion, stale rkey rejection, 64-bit remote offsets and exact
; byte equality.
;
; Transport is byte-addressed through LDB/STB.  A NaN word contributes its four
; payload bytes; the class heads are regenerated as data-class by STB.  This is
; the same byte contract ngguf/nkv use for tensor storage.
;
; Node record (64 words, caller supplied):
;   +0 magic "NFND" 0x4E464E44   +1 version 1
;   +2 node id                   +3 state (1 live)
;   +4 qpair table               +5 qpair capacity +6 qpair count
;   +7 MR table                  +8 MR capacity    +9 MR count
;   +10 sends +11 recvs +12 writes +13 reads +14 completions +15 errors
;   +16 stale keys +17 credits consumed
;   +18 bytes_sent lo +19 hi
;   +20 bytes_written lo +21 hi
;   +22 bytes_read lo +23 hi
;   +24 errno
;   +25 last checkpoint agent +26 agent generation +27 epoch
;
; QP (32 words, table entry qid-1):
;   +0 magic "NFQP" 0x4E465150   +1 version 1
;   +2 qid +3 state (1 init, 2 ready)
;   +4 local node +5 remote node +6 remote qid +7 depth
;   +8 RQ base +9 CQ base
;   +10 rq_head +11 rq_tail +12 cq_head +13 cq_tail
;   +14 credits-cache +15 phase
;   +16 sends +17 recvs +18 writes +19 reads +20 completions +21 errors
;   +22 stale keys +23..31 reserved
;
; RQ entry (4 words): +0 buffer byte addr +1 length +2 wr_id +3 status
; CQE (8 words): +0 status +1 opcode +2 qid +3 bytes_lo +4 bytes_hi
;                +5 wr_id +6 phase +7 reserved
; Opcodes: 1 send, 2 recv, 3 write, 4 read.
;
; MR (8 words): +0 live +1 base_lo +2 base_hi +3 size_lo +4 size_hi
;               +5 rights (1 read, 2 write) +6 key generation +7 key
; Remote key format: 0x52000000 | slot<<8 | generation.  A revoke bumps the
; generation and mints a new key; every older key fails the key-equality check.
;
; Fabric record (16 words): +0 "NFAB" 0x4E464142 +1 version +2 node0 +3 node1
;   +4 link +5 sends +6 recvs +7 writes +8 reads +9 stale +10 errors +11 errno
;
; API (r0=0, r13=1, r14=SP grows up, r15=link):
;   nfab_init        r1=fab r2=node0 r3=node1 -> 0/err
;   nfab_node_init   r1=node r2=id r3=qp table r4=qp cap r5=MR table
;                    r6=MR cap -> 0/err
;   nfab_mr_register r1=node r2=slot r3=base_lo r4=base_hi r5=size_lo
;                    r6=size_hi r7=rights -> rkey/0
;   nfab_mr_revoke   r1=node r2=slot -> new rkey/0
;   nfab_mr_key      r1=node r2=slot -> rkey/0
;   nfab_mr_info     r1=node r2=slot r3=out(8) -> 0/err
;   nfab_qp_create   r1=node r2=qid r3=remote node r4=remote qid r5=depth
;                    r6=rq r7=cq -> 0/err
;   nfab_qp_connect  r1=node r2=qid -> 0/err
;   nfab_recv_post   r1=node r2=qid r3=buf r4=len r5=wr_id -> 0/err
;   nfab_credits     r1=node r2=qid -> remote posted receives / 0 (errno)
;   nfab_send        r1=node r2=qid r3=buf r4=len r5=wr_id -> 0/err
;   nfab_write       r1=node r2=qid r3=buf r4=len r5=off_lo r6=off_hi
;                    r7=rkey r8=wr_id -> 0/err
;   nfab_read        r1=node r2=qid r3=buf r4=len r5=off_lo r6=off_hi
;                    r7=rkey r8=wr_id -> 0/err
;   nfab_poll        r1=node r2=qid r3=out(8) -> 1 got / 0 empty (errno)
;   nfab_cq_count    r1=node r2=qid -> outstanding CQEs
;   nfab_errno       r1=node -> last error
;   nfab_kv_put      r1=node r2=qid r3=slab cap r4=token r5=off_lo
;                    r6=off_hi r7=rkey r8=expected generation -> 0/err
;   nfab_kv_get      r1=node r2=qid r3=slab cap r4=token r5=off_lo
;                    r6=off_hi r7=rkey r8=expected generation -> 0/err
;   nfab_ck_seal     r1=blob r2=words -> hash/0
;   nfab_ck_verify   r1=blob r2=words -> 0/err
;   nfab_ck_send     r1=node r2=qid r3=blob r4=words r5=off_lo r6=off_hi
;                    r7=rkey r8=expected epoch -> 0/err
;   nfab_ck_recv     r1=node r2=qid r3=off_lo r4=off_hi r5=blob r6=words
;                    r7=rkey r8=expected epoch -> 0/err
;
; Checkpoint blobs are nagent-style "NAGC" records (48 + 8*cap_count words).
; The seal is the same 32-bit xor/multiply chain as nagent_ck_seal, so a blob
; produced by nagent_checkpoint verifies here and vice versa.
;
; Fixed single-core scratch at 0x7000; not reentrant.

.include "nkv.nas"

.equ NFAB_MAGIC      0x4E464142       ; "NFAB"
.equ NFAB_NODE_MAGIC 0x4E464E44       ; "NFND"
.equ NFAB_QP_MAGIC   0x4E465150       ; "NFQP"
.equ NFAB_VERSION    1
.equ NFAB_RKEY_TAG   0x52000000
.equ NFAB_RKEY_MASK  0xFF000000

; Node fields.
.equ NF_N_MAGIC      0
.equ NF_N_VERSION    1
.equ NF_N_ID         2
.equ NF_N_STATE      3
.equ NF_N_QPTAB      4
.equ NF_N_QPCAP      5
.equ NF_N_QPN        6
.equ NF_N_MRTAB      7
.equ NF_N_MRCAP      8
.equ NF_N_MRN        9
.equ NF_N_SENDS      10
.equ NF_N_RECVS      11
.equ NF_N_WRITES     12
.equ NF_N_READS      13
.equ NF_N_DONE       14
.equ NF_N_ERR        15
.equ NF_N_STALE      16
.equ NF_N_CRED      17
.equ NF_N_BSENT      18
.equ NF_N_BWRITE     20
.equ NF_N_BREAD      22
.equ NF_N_ERRNO      24
.equ NF_N_CKAGENT    25
.equ NF_N_CKAGEN     26
.equ NF_N_CKEPOCH    27
.equ NF_N_WORDS      64

; QP fields.
.equ NF_Q_MAGIC      0
.equ NF_Q_VERSION    1
.equ NF_Q_ID         2
.equ NF_Q_STATE      3
.equ NF_Q_NODE       4
.equ NF_Q_RNODE      5
.equ NF_Q_RQID       6
.equ NF_Q_DEPTH      7
.equ NF_Q_RQ         8
.equ NF_Q_CQ         9
.equ NF_Q_RQH        10
.equ NF_Q_RQT        11
.equ NF_Q_CQH        12
.equ NF_Q_CQT        13
.equ NF_Q_CRED       14
.equ NF_Q_PHASE      15
.equ NF_Q_SENDS      16
.equ NF_Q_RECVS      17
.equ NF_Q_WRITES     18
.equ NF_Q_READS      19
.equ NF_Q_DONE       20
.equ NF_Q_ERR        21
.equ NF_Q_STALE      22
.equ NF_Q_WORDS      32

; MR fields.
.equ NF_M_LIVE       0
.equ NF_M_BASE       1
.equ NF_M_SIZE       3
.equ NF_M_RIGHTS     5
.equ NF_M_GEN        6
.equ NF_M_KEY        7
.equ NF_M_WORDS      8

; RQ and CQ fields.
.equ NF_R_BUF        0
.equ NF_R_LEN        1
.equ NF_R_WRID       2
.equ NF_R_STATUS     3
.equ NF_K_STATUS     0
.equ NF_K_OP         1
.equ NF_K_QID        2
.equ NF_K_BYTES      3
.equ NF_K_WRID       5
.equ NF_K_PHASE      6
.equ NF_K_WORDS      8

; Operations.
.equ NF_OP_SEND      1
.equ NF_OP_RECV      2
.equ NF_OP_WRITE     3
.equ NF_OP_READ      4

; Errors.
.equ NFAB_OK         0
.equ NFAB_EBAD       1
.equ NFAB_ENOENT     2
.equ NFAB_ECREDIT    3
.equ NFAB_ERIGHT     4
.equ NFAB_ESTALE     5
.equ NFAB_EBOUNDS    6
.equ NFAB_EQFULL     7
.equ NFAB_ENOSPC     8
.equ NFAB_ECK        9
.equ NFAB_EADDR      10

; Checkpoint constants, wire-compatible with nagent.nas.
.equ NFCK_MAGIC      0x4E414743       ; "NAGC"
.equ NFCK_VERSION    1
.equ NFCK_SEED       0x4E41474B       ; "NAGK"
.equ NFCK_MIX_C1     0x9E3779B9
.equ NFCK_MIX_C2     0x85EBCA6B
.equ NFCK_MIX_C3     0xC2B2AE35
.equ NFCK_HASH       20
.equ NFCK_EPOCH      19
.equ NFCK_AGENT      2
.equ NFCK_AGEN       3
.equ NFCK_CAPS       8

; Fixed scratch, 0x7000..0x719F.
.equ NFX_INIT        0x7000
.equ NFX_NODE        0x7010
.equ NFX_MR          0x7020
.equ NFX_MRKEY       0x7030
.equ NFX_QP          0x7040
.equ NFX_RECV        0x7050
.equ NFX_SEND        0x7060
.equ NFX_WR          0x7080
.equ NFX_RD          0x70A0
.equ NFX_POLL        0x70C0
.equ NFX_KV          0x70D0
.equ NFX_CK          0x70F0
.equ NFX_VERIFY      0x7120
.equ NFX_HASH        0x7140
.equ NFX_CQE         0x7160
.equ NFX_XFER        0x7180

; ---------------------------------------------------------------------------
; nf_node_ok r1=node -> 1/0.
nf_node_ok:
  CMP r1,r0
  JMP[EQ] @nf_nok_no
  LD r2,r1,#NF_N_MAGIC
  LA r3,#NFAB_NODE_MAGIC
  CMP r2,r3
  JMP[NE] @nf_nok_no
  LD r2,r1,#NF_N_VERSION
  MOVI r3,#NFAB_VERSION
  CMP r2,r3
  JMP[NE] @nf_nok_no
  LD r2,r1,#NF_N_STATE
  CMP r2,r0
  JMP[EQ] @nf_nok_no
  MOVI r1,1
  RET
nf_nok_no:
  MOVI r1,0
  RET

; nf_err r1=node r2=code -> r1=code; node.errno=code; counters.
nf_err:
  CMP r1,r0
  JMP[EQ] @nf_err_out
  ST r2,r1,#NF_N_ERRNO
  MOVI r3,#NFAB_ESTALE
  CMP r2,r3
  JMP[NE] @nf_err_gen
  LD r3,r1,#NF_N_STALE
  ADDI r3,r3,1
  ST r3,r1,#NF_N_STALE
  JMP @nf_err_out
nf_err_gen:
  LD r3,r1,#NF_N_ERR
  ADDI r3,r3,1
  ST r3,r1,#NF_N_ERR
nf_err_out:
  MOVI r1,0
  RET

; nf_ok r1=node -> 0.
nf_ok:
  ST r0,r1,#NF_N_ERRNO
  MOVI r1,0
  RET

; nf_qp r1=node r2=qid -> qp/0.
nf_qp:
  CMP r1,r0
  JMP[EQ] @nf_qp_no
  CMP r2,r0
  JMP[EQ] @nf_qp_no
  LD r3,r1,#NF_N_QPCAP
  CMP r2,r3
  JMP[GT] @nf_qp_no
  SUB r3,r2,r13
  SHL r3,r3,5
  LD r4,r1,#NF_N_QPTAB
  ADD r3,r3,r4
  LD r4,r3,#NF_Q_MAGIC
  LA r5,#NFAB_QP_MAGIC
  CMP r4,r5
  JMP[NE] @nf_qp_no
  LD r4,r3,#NF_Q_STATE
  CMP r4,r0
  JMP[EQ] @nf_qp_no
  ADD r1,r3,r0
  RET
nf_qp_no:
  MOVI r1,0
  RET

; nf_mr r1=node r2=slot -> mr/0.
nf_mr:
  CMP r1,r0
  JMP[EQ] @nf_mr_no
  CMP r2,r0
  JMP[EQ] @nf_mr_no
  LD r3,r1,#NF_N_MRCAP
  CMP r2,r3
  JMP[GT] @nf_mr_no
  SUB r3,r2,r13
  SHL r3,r3,3
  LD r4,r1,#NF_N_MRTAB
  ADD r3,r3,r4
  LD r4,r3,#NF_M_LIVE
  CMP r4,r0
  JMP[EQ] @nf_mr_no
  ADD r1,r3,r0
  RET
nf_mr_no:
  MOVI r1,0
  RET

; nf_rkey r1=node r2=rkey r3=need -> r1=mr r2=0 ok, or r1=0 r2=error.
nf_rkey:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_MRKEY+0
  ST r2,r0,#NFX_MRKEY+1
  ST r3,r0,#NFX_MRKEY+2
  ; tag
  SHR r4,r2,24
  LA r5,#NFAB_RKEY_TAG
  SHR r5,r5,24
  CMP r4,r5
  JMP[NE] @nf_rk_none
  ; slot = (key >> 8) & 0xFF
  SHR r4,r2,8
  MOVI r5,0xFF
  BOOL.8 r4,r4,r5
  CMP r4,r0
  JMP[EQ] @nf_rk_none
  LD r1,r0,#NFX_MRKEY+0
  ADD r2,r4,r0
  CALL @nf_mr
  CMP r1,r0
  JMP[EQ] @nf_rk_none
  ST r1,r0,#NFX_MRKEY+3
  LD r2,r1,#NF_M_KEY
  LD r3,r0,#NFX_MRKEY+1
  CMP r2,r3
  JMP[NE] @nf_rk_stale
  LD r2,r1,#NF_M_RIGHTS
  LD r3,r0,#NFX_MRKEY+2
  BOOL.8 r4,r2,r3
  CMP r4,r3
  JMP[NE] @nf_rk_right
  LD r1,r0,#NFX_MRKEY+3
  MOVI r2,0
  JMP @nf_rk_out
nf_rk_stale:
  MOVI r1,0
  MOVI r2,#NFAB_ESTALE
  JMP @nf_rk_out
nf_rk_right:
  MOVI r1,0
  MOVI r2,#NFAB_ERIGHT
  JMP @nf_rk_out
nf_rk_none:
  MOVI r1,0
  MOVI r2,#NFAB_ENOENT
nf_rk_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nf_cq_space r1=qp -> 1/0.
nf_cq_space:
  LD r2,r1,#NF_Q_CQT
  LD r3,r1,#NF_Q_CQH
  SUB r2,r2,r3
  LD r3,r1,#NF_Q_DEPTH
  CMP r2,r3
  MOVI r1,0
  MOVI[LT] r1,1
  RET

; nf_push r1=node r2=qp r3=status r4=op r5=bytes_lo r6=bytes_hi r7=wr_id
;         -> 0/err.
nf_push:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_CQE+0
  ST r2,r0,#NFX_CQE+1
  ST r3,r0,#NFX_CQE+2
  ST r4,r0,#NFX_CQE+3
  ST r5,r0,#NFX_CQE+4
  ST r6,r0,#NFX_CQE+5
  ST r7,r0,#NFX_CQE+6
  LD r1,r0,#NFX_CQE+1
  CALL @nf_cq_space
  CMP r1,r0
  JMP[EQ] @nf_push_full
  LD r1,r0,#NFX_CQE+1
  LD r2,r1,#NF_Q_CQT
  LD r3,r1,#NF_Q_DEPTH
  MODU r4,r2,r3
  SHL r4,r4,3
  LD r5,r1,#NF_Q_CQ
  ADD r4,r4,r5
  LD r5,r0,#NFX_CQE+2
  ST r5,r4,#NF_K_STATUS
  LD r5,r0,#NFX_CQE+3
  ST r5,r4,#NF_K_OP
  LD r5,r1,#NF_Q_ID
  ST r5,r4,#NF_K_QID
  LD r5,r0,#NFX_CQE+4
  ST r5,r4,#NF_K_BYTES
  LD r5,r0,#NFX_CQE+5
  ST r5,r4,#NF_K_BYTES+1
  LD r5,r0,#NFX_CQE+6
  ST r5,r4,#NF_K_WRID
  LD r5,r1,#NF_Q_PHASE
  ST r5,r4,#NF_K_PHASE
  ST r0,r4,#NF_K_PHASE+1
  LD r2,r1,#NF_Q_CQT
  ADDI r2,r2,1
  ST r2,r1,#NF_Q_CQT
  LD r2,r1,#NF_Q_DONE
  ADDI r2,r2,1
  ST r2,r1,#NF_Q_DONE
  LD r1,r0,#NFX_CQE+0
  LD r2,r1,#NF_N_DONE
  ADDI r2,r2,1
  ST r2,r1,#NF_N_DONE
  MOVI r1,0
  JMP @nf_push_out
nf_push_full:
  LD r1,r0,#NFX_CQE+0
  MOVI r2,#NFAB_EQFULL
  CALL @nf_err
nf_push_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nf_copy r1=from r2=to r3=count.  Leaf.
nf_copy:
  CMP r3,r0
  JMP[EQ] @nf_copy_out
nf_copy_l:
  LDB r4,r1,0
  STB r4,r2,0
  ADDI r1,r1,1
  ADDI r2,r2,1
  ADDI r3,r3,-1
  CMP r3,r0
  JMP[NE] @nf_copy_l
nf_copy_out:
  RET

; nf_add_bytes r1=node r2=field r3=lo r4=hi.  Leaf-ish.
nf_add_bytes:
  ADD r2,r1,r2
  LD r5,r2,0
  LD r6,r2,1
  ADD r5,r5,r3
  CMP r5,r3
  MOVI r7,0
  MOVI[LT] r7,1
  ADD r6,r6,r4
  ADD r6,r6,r7
  ST r5,r2,0
  ST r6,r2,1
  RET

; ---------------------------------------------------------------------------
; nfab_init r1=fab r2=node0 r3=node1 -> 0/err.
nfab_init:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_INIT+0
  ST r2,r0,#NFX_INIT+1
  ST r3,r0,#NFX_INIT+2
  CMP r1,r0
  JMP[EQ] @nf_init_bad
  CMP r2,r0
  JMP[EQ] @nf_init_bad
  CMP r3,r0
  JMP[EQ] @nf_init_bad
  CMP r2,r3
  JMP[EQ] @nf_init_bad
  ADD r1,r2,r0
  CALL @nf_node_ok
  CMP r1,r0
  JMP[EQ] @nf_init_bad
  LD r1,r0,#NFX_INIT+2
  CALL @nf_node_ok
  CMP r1,r0
  JMP[EQ] @nf_init_bad
  LD r1,r0,#NFX_INIT+0
  MOVI r2,16
  BFILL r1,r0,r2
  LA r2,#NFAB_MAGIC
  ST r2,r1,0
  MOVI r2,#NFAB_VERSION
  ST r2,r1,1
  LD r2,r0,#NFX_INIT+1
  ST r2,r1,2
  LD r2,r0,#NFX_INIT+2
  ST r2,r1,3
  MOVI r2,1
  ST r2,r1,4
  MOVI r1,0
  JMP @nf_init_out
nf_init_bad:
  MOVI r1,#NFAB_EBAD
nf_init_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nfab_node_init r1=node r2=id r3=qptab r4=qcap r5=mrtab r6=mrcap -> 0/err.
nfab_node_init:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_NODE+0
  ST r2,r0,#NFX_NODE+1
  ST r3,r0,#NFX_NODE+2
  ST r4,r0,#NFX_NODE+3
  ST r5,r0,#NFX_NODE+4
  ST r6,r0,#NFX_NODE+5
  CMP r1,r0
  JMP[EQ] @nf_nd_bad
  CMP r3,r0
  JMP[EQ] @nf_nd_bad
  CMP r5,r0
  JMP[EQ] @nf_nd_bad
  CMP r4,r0
  JMP[EQ] @nf_nd_bad
  MOVI r7,32
  CMP r4,r7
  JMP[GT] @nf_nd_bad
  CMP r6,r0
  JMP[EQ] @nf_nd_bad
  CMP r6,r7
  JMP[GT] @nf_nd_bad
  LD r1,r0,#NFX_NODE+0
  MOVI r2,#NF_N_WORDS
  BFILL r1,r0,r2
  LA r2,#NFAB_NODE_MAGIC
  ST r2,r1,#NF_N_MAGIC
  MOVI r2,#NFAB_VERSION
  ST r2,r1,#NF_N_VERSION
  LD r2,r0,#NFX_NODE+1
  ST r2,r1,#NF_N_ID
  MOVI r2,1
  ST r2,r1,#NF_N_STATE
  LD r2,r0,#NFX_NODE+2
  ST r2,r1,#NF_N_QPTAB
  LD r2,r0,#NFX_NODE+3
  ST r2,r1,#NF_N_QPCAP
  LD r2,r0,#NFX_NODE+4
  ST r2,r1,#NF_N_MRTAB
  LD r2,r0,#NFX_NODE+5
  ST r2,r1,#NF_N_MRCAP
  MOVI r1,0
  JMP @nf_nd_out
nf_nd_bad:
  MOVI r1,#NFAB_EBAD
nf_nd_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nfab_mr_register r1=node r2=slot r3=base_lo r4=base_hi r5=size_lo
;                   r6=size_hi r7=rights -> rkey/0.
nfab_mr_register:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_MR+0
  ST r2,r0,#NFX_MR+1
  ST r3,r0,#NFX_MR+2
  ST r4,r0,#NFX_MR+3
  ST r5,r0,#NFX_MR+4
  ST r6,r0,#NFX_MR+5
  ST r7,r0,#NFX_MR+6
  ADD r1,r1,r0
  CALL @nf_node_ok
  CMP r1,r0
  JMP[EQ] @nf_mr_bad
  LD r1,r0,#NFX_MR+0
  LD r2,r0,#NFX_MR+1
  CMP r2,r0
  JMP[EQ] @nf_mr_bad
  LD r3,r1,#NF_N_MRCAP
  CMP r2,r3
  JMP[GT] @nf_mr_bad
  LD r3,r0,#NFX_MR+6
  CMP r3,r0
  JMP[EQ] @nf_mr_bad
  MOVI r4,3
  CMP r3,r4
  JMP[GT] @nf_mr_bad
  LD r3,r0,#NFX_MR+4
  LD r4,r0,#NFX_MR+5
  CMP r3,r0
  JMP[NE] @nf_mr_sz
  CMP r4,r0
  JMP[EQ] @nf_mr_bad
nf_mr_sz:
  ; base + size must not wrap
  LD r1,r0,#NFX_MR+2
  LD r2,r0,#NFX_MR+3
  LD r3,r0,#NFX_MR+4
  LD r4,r0,#NFX_MR+5
  CALL @n64_add
  ST r1,r0,#NFX_MR+7
  ST r2,r0,#NFX_MR+8
  LD r3,r0,#NFX_MR+2
  LD r4,r0,#NFX_MR+3
  CALL @n64_cmp
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nf_mr_bad
  ; slot free?
  LD r1,r0,#NFX_MR+0
  LD r2,r0,#NFX_MR+1
  CALL @nf_mr
  CMP r1,r0
  JMP[NE] @nf_mr_bad
  ; store
  LD r1,r0,#NFX_MR+0
  LD r2,r0,#NFX_MR+1
  SUB r3,r2,r13
  SHL r3,r3,3
  LD r4,r1,#NF_N_MRTAB
  ADD r3,r3,r4
  MOVI r4,1
  ST r4,r3,#NF_M_LIVE
  LD r4,r0,#NFX_MR+2
  ST r4,r3,#NF_M_BASE
  LD r4,r0,#NFX_MR+3
  ST r4,r3,#NF_M_BASE+1
  LD r4,r0,#NFX_MR+4
  ST r4,r3,#NF_M_SIZE
  LD r4,r0,#NFX_MR+5
  ST r4,r3,#NF_M_SIZE+1
  LD r4,r0,#NFX_MR+6
  ST r4,r3,#NF_M_RIGHTS
  MOVI r4,1
  ST r4,r3,#NF_M_GEN
  ; key = tag | slot<<8 | gen
  LA r5,#NFAB_RKEY_TAG
  LD r6,r0,#NFX_MR+1
  SHL r6,r6,8
  ADD r5,r5,r6
  ADD r5,r5,r4
  ST r5,r3,#NF_M_KEY
  LD r2,r1,#NF_N_MRN
  ADDI r2,r2,1
  ST r2,r1,#NF_N_MRN
  LD r1,r0,#NFX_MR+0
  LD r1,r1,#NF_N_MRTAB
  LD r2,r0,#NFX_MR+1
  SUB r2,r2,r13
  SHL r2,r2,3
  ADD r1,r1,r2
  LD r1,r1,#NF_M_KEY
  ST r1,r0,#NFX_MR+10
  LD r1,r0,#NFX_MR+0
  CALL @nf_ok
  LD r1,r0,#NFX_MR+10
  JMP @nf_mr_out
nf_mr_bad:
  LD r1,r0,#NFX_MR+0
  MOVI r2,#NFAB_EBAD
  CALL @nf_err
nf_mr_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nfab_mr_revoke r1=node r2=slot -> new key/0.
nfab_mr_revoke:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_MR+0
  ST r2,r0,#NFX_MR+1
  CALL @nf_mr
  CMP r1,r0
  JMP[EQ] @nf_mrv_bad
  ST r1,r0,#NFX_MR+2
  LD r2,r1,#NF_M_GEN
  ADDI r2,r2,1
  MOVI r3,255
  CMP r2,r3
  JMP[LE] @nf_mrv_gen
  MOVI r2,1
nf_mrv_gen:
  ST r2,r1,#NF_M_GEN
  LA r4,#NFAB_RKEY_TAG
  LD r5,r0,#NFX_MR+1
  SHL r5,r5,8
  ADD r4,r4,r5
  ADD r4,r4,r2
  ST r4,r1,#NF_M_KEY
  LD r1,r0,#NFX_MR+0
  CALL @nf_ok
  LD r1,r0,#NFX_MR+2
  LD r1,r1,#NF_M_KEY
  JMP @nf_mrv_out
nf_mrv_bad:
  LD r1,r0,#NFX_MR+0
  MOVI r2,#NFAB_ENOENT
  CALL @nf_err
nf_mrv_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nfab_mr_key r1=node r2=slot -> key/0.
nfab_mr_key:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_MR+0
  CALL @nf_mr
  CMP r1,r0
  JMP[EQ] @nf_mrk_bad
  LD r1,r1,#NF_M_KEY
  JMP @nf_mrk_out
nf_mrk_bad:
  LD r1,r0,#NFX_MR+0
  MOVI r2,#NFAB_ENOENT
  CALL @nf_err
nf_mrk_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nfab_mr_info r1=node r2=slot r3=out(8) -> 0/err.
nfab_mr_info:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_MR+0
  ST r3,r0,#NFX_MR+1
  CMP r3,r0
  JMP[EQ] @nf_mri_bad
  CALL @nf_mr
  CMP r1,r0
  JMP[EQ] @nf_mri_bad
  LD r2,r0,#NFX_MR+1
  MOVI r3,#NF_M_WORDS
  BCOPY r2,r1,r3
  LD r1,r0,#NFX_MR+0
  CALL @nf_ok
  JMP @nf_mri_out
nf_mri_bad:
  LD r1,r0,#NFX_MR+0
  MOVI r2,#NFAB_ENOENT
  CALL @nf_err
nf_mri_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nfab_qp_create r1=node r2=qid r3=remote node r4=remote qid r5=depth
;                  r6=rq r7=cq -> 0/err.
nfab_qp_create:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_QP+0
  ST r2,r0,#NFX_QP+1
  ST r3,r0,#NFX_QP+2
  ST r4,r0,#NFX_QP+3
  ST r5,r0,#NFX_QP+4
  ST r6,r0,#NFX_QP+5
  ST r7,r0,#NFX_QP+6
  ADD r1,r1,r0
  CALL @nf_node_ok
  CMP r1,r0
  JMP[EQ] @nf_qpc_bad
  LD r1,r0,#NFX_QP+0
  LD r2,r0,#NFX_QP+1
  CMP r2,r0
  JMP[EQ] @nf_qpc_bad
  LD r3,r1,#NF_N_QPCAP
  CMP r2,r3
  JMP[GT] @nf_qpc_bad
  LD r3,r0,#NFX_QP+4
  CMP r3,r0
  JMP[EQ] @nf_qpc_bad
  MOVI r4,32
  CMP r3,r4
  JMP[GT] @nf_qpc_bad
  LD r4,r0,#NFX_QP+5
  CMP r4,r0
  JMP[EQ] @nf_qpc_bad
  LD r4,r0,#NFX_QP+6
  CMP r4,r0
  JMP[EQ] @nf_qpc_bad
  LD r1,r0,#NFX_QP+2
  CALL @nf_node_ok
  CMP r1,r0
  JMP[EQ] @nf_qpc_bad
  LD r1,r0,#NFX_QP+2
  LD r2,r0,#NFX_QP+3
  CMP r2,r0
  JMP[EQ] @nf_qpc_bad
  LD r3,r1,#NF_N_QPCAP
  CMP r2,r3
  JMP[GT] @nf_qpc_bad
  ; slot free?
  LD r1,r0,#NFX_QP+0
  LD r2,r0,#NFX_QP+1
  CALL @nf_qp
  CMP r1,r0
  JMP[NE] @nf_qpc_bad
  LD r1,r0,#NFX_QP+0
  LD r2,r0,#NFX_QP+1
  SUB r3,r2,r13
  SHL r3,r3,5
  LD r4,r1,#NF_N_QPTAB
  ADD r3,r3,r4
  MOVI r4,#NF_Q_WORDS
  BFILL r3,r0,r4
  LA r4,#NFAB_QP_MAGIC
  ST r4,r3,#NF_Q_MAGIC
  MOVI r4,#NFAB_VERSION
  ST r4,r3,#NF_Q_VERSION
  LD r4,r0,#NFX_QP+1
  ST r4,r3,#NF_Q_ID
  MOVI r4,1
  ST r4,r3,#NF_Q_STATE
  LD r4,r0,#NFX_QP+0
  ST r4,r3,#NF_Q_NODE
  LD r4,r0,#NFX_QP+2
  ST r4,r3,#NF_Q_RNODE
  LD r4,r0,#NFX_QP+3
  ST r4,r3,#NF_Q_RQID
  LD r4,r0,#NFX_QP+4
  ST r4,r3,#NF_Q_DEPTH
  LD r4,r0,#NFX_QP+5
  ST r4,r3,#NF_Q_RQ
  LD r4,r0,#NFX_QP+6
  ST r4,r3,#NF_Q_CQ
  LD r2,r1,#NF_N_QPN
  ADDI r2,r2,1
  ST r2,r1,#NF_N_QPN
  CALL @nf_ok
  JMP @nf_qpc_out
nf_qpc_bad:
  LD r1,r0,#NFX_QP+0
  MOVI r2,#NFAB_EBAD
  CALL @nf_err
nf_qpc_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nfab_qp_connect r1=node r2=qid -> 0/err.
nfab_qp_connect:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_QP+0
  ST r2,r0,#NFX_QP+1
  CALL @nf_qp
  CMP r1,r0
  JMP[EQ] @nf_qpcx_bad
  ST r1,r0,#NFX_QP+2
  LD r2,r1,#NF_Q_RNODE
  LD r3,r1,#NF_Q_RQID
  ADD r1,r2,r0
  ADD r2,r3,r0
  CALL @nf_qp
  CMP r1,r0
  JMP[EQ] @nf_qpcx_bad
  LD r1,r0,#NFX_QP+2
  MOVI r2,2
  ST r2,r1,#NF_Q_STATE
  LD r1,r0,#NFX_QP+0
  CALL @nf_ok
  JMP @nf_qpcx_out
nf_qpcx_bad:
  LD r1,r0,#NFX_QP+0
  MOVI r2,#NFAB_ENOENT
  CALL @nf_err
nf_qpcx_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nfab_recv_post r1=node r2=qid r3=buf r4=len r5=wr_id -> 0/err.
nfab_recv_post:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_RECV+0
  ST r2,r0,#NFX_RECV+1
  ST r3,r0,#NFX_RECV+2
  ST r4,r0,#NFX_RECV+3
  ST r5,r0,#NFX_RECV+4
  CALL @nf_qp
  CMP r1,r0
  JMP[EQ] @nf_rp_bad
  ST r1,r0,#NFX_RECV+5
  LD r2,r1,#NF_Q_STATE
  MOVI r3,2
  CMP r2,r3
  JMP[NE] @nf_rp_bad
  LD r2,r0,#NFX_RECV+2
  CMP r2,r0
  JMP[EQ] @nf_rp_bad
  LD r2,r0,#NFX_RECV+3
  CMP r2,r0
  JMP[EQ] @nf_rp_bad
  LD r2,r1,#NF_Q_RQT
  LD r3,r1,#NF_Q_RQH
  SUB r2,r2,r3
  LD r3,r1,#NF_Q_DEPTH
  CMP r2,r3
  JMP[GE] @nf_rp_full
  LD r2,r1,#NF_Q_RQT
  MODU r3,r2,r3
  SHL r3,r3,2
  LD r4,r1,#NF_Q_RQ
  ADD r3,r3,r4
  LD r4,r0,#NFX_RECV+2
  ST r4,r3,#NF_R_BUF
  LD r4,r0,#NFX_RECV+3
  ST r4,r3,#NF_R_LEN
  LD r4,r0,#NFX_RECV+4
  ST r4,r3,#NF_R_WRID
  ST r0,r3,#NF_R_STATUS
  LD r2,r1,#NF_Q_RQT
  ADDI r2,r2,1
  ST r2,r1,#NF_Q_RQT
  LD r1,r0,#NFX_RECV+0
  CALL @nf_ok
  JMP @nf_rp_out
nf_rp_full:
  LD r1,r0,#NFX_RECV+0
  MOVI r2,#NFAB_ENOSPC
  CALL @nf_err
  JMP @nf_rp_out
nf_rp_bad:
  LD r1,r0,#NFX_RECV+0
  MOVI r2,#NFAB_EBAD
  CALL @nf_err
nf_rp_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nfab_credits r1=node r2=qid -> remote posted receives.
nfab_credits:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_RECV+0
  CALL @nf_qp
  CMP r1,r0
  JMP[EQ] @nf_cr_bad
  LD r2,r1,#NF_Q_RNODE
  LD r3,r1,#NF_Q_RQID
  ADD r1,r2,r0
  ADD r2,r3,r0
  CALL @nf_qp
  CMP r1,r0
  JMP[EQ] @nf_cr_bad
  LD r2,r1,#NF_Q_RQT
  LD r3,r1,#NF_Q_RQH
  SUB r1,r2,r3
  JMP @nf_cr_out
nf_cr_bad:
  MOVI r1,0
nf_cr_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nfab_send r1=node r2=qid r3=buf r4=len r5=wr_id -> 0/err.
nfab_send:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_SEND+0
  ST r2,r0,#NFX_SEND+1
  ST r3,r0,#NFX_SEND+2
  ST r4,r0,#NFX_SEND+3
  ST r5,r0,#NFX_SEND+4
  CALL @nf_qp
  CMP r1,r0
  JMP[EQ] @nf_sd_bad
  ST r1,r0,#NFX_SEND+5
  LD r2,r1,#NF_Q_STATE
  MOVI r3,2
  CMP r2,r3
  JMP[NE] @nf_sd_bad
  LD r2,r0,#NFX_SEND+2
  CMP r2,r0
  JMP[EQ] @nf_sd_bad
  LD r2,r0,#NFX_SEND+3
  CMP r2,r0
  JMP[EQ] @nf_sd_bad
  ; remote queue pair
  LD r1,r0,#NFX_SEND+5
  LD r2,r1,#NF_Q_RNODE
  LD r3,r1,#NF_Q_RQID
  ADD r1,r2,r0
  ADD r2,r3,r0
  CALL @nf_qp
  CMP r1,r0
  JMP[EQ] @nf_sd_bad
  ST r1,r0,#NFX_SEND+6
  LD r2,r1,#NF_Q_STATE
  MOVI r3,2
  CMP r2,r3
  JMP[NE] @nf_sd_bad
  ; credit
  LD r2,r1,#NF_Q_RQT
  LD r3,r1,#NF_Q_RQH
  CMP r2,r3
  JMP[EQ] @nf_sd_credit
  ; RQ entry
  SUB r2,r2,r3
  LD r3,r1,#NF_Q_RQH
  LD r4,r1,#NF_Q_DEPTH
  MODU r5,r3,r4
  SHL r5,r5,2
  LD r6,r1,#NF_Q_RQ
  ADD r5,r5,r6
  ST r5,r0,#NFX_SEND+7
  LD r6,r5,#NF_R_LEN
  LD r7,r0,#NFX_SEND+3
  CMP r6,r7
  JMP[LT] @nf_sd_space
  ; CQ space on both ends
  LD r1,r0,#NFX_SEND+5
  CALL @nf_cq_space
  CMP r1,r0
  JMP[EQ] @nf_sd_full
  LD r1,r0,#NFX_SEND+6
  CALL @nf_cq_space
  CMP r1,r0
  JMP[EQ] @nf_sd_full
  ; copy payload
  LD r1,r0,#NFX_SEND+2
  LD r2,r0,#NFX_SEND+7
  LD r2,r2,#NF_R_BUF
  LD r3,r0,#NFX_SEND+3
  CALL @nf_copy
  ; local send CQE
  LD r1,r0,#NFX_SEND+0
  LD r2,r0,#NFX_SEND+5
  MOVI r3,0
  MOVI r4,#NF_OP_SEND
  LD r5,r0,#NFX_SEND+3
  MOVI r6,0
  LD r7,r0,#NFX_SEND+4
  CALL @nf_push
  ; remote recv CQE
  LD r1,r0,#NFX_SEND+6
  LD r1,r1,#NF_Q_NODE
  LD r2,r0,#NFX_SEND+6
  MOVI r3,0
  MOVI r4,#NF_OP_RECV
  LD r5,r0,#NFX_SEND+3
  MOVI r6,0
  LD r7,r0,#NFX_SEND+7
  LD r7,r7,#NF_R_WRID
  CALL @nf_push
  ; consume the posted receive
  LD r1,r0,#NFX_SEND+6
  LD r2,r1,#NF_Q_RQH
  ADDI r2,r2,1
  ST r2,r1,#NF_Q_RQH
  ; counters
  LD r1,r0,#NFX_SEND+0
  LD r2,r1,#NF_N_SENDS
  ADDI r2,r2,1
  ST r2,r1,#NF_N_SENDS
  MOVI r2,#NF_N_BSENT
  LD r3,r0,#NFX_SEND+3
  MOVI r4,0
  CALL @nf_add_bytes
  LD r1,r0,#NFX_SEND+6
  LD r1,r1,#NF_Q_NODE
  LD r2,r1,#NF_N_RECVS
  ADDI r2,r2,1
  ST r2,r1,#NF_N_RECVS
  LD r1,r0,#NFX_SEND+6
  LD r2,r1,#NF_Q_RECVS
  ADDI r2,r2,1
  ST r2,r1,#NF_Q_RECVS
  LD r1,r0,#NFX_SEND+0
  CALL @nf_ok
  JMP @nf_sd_out
nf_sd_credit:
  LD r1,r0,#NFX_SEND+0
  MOVI r2,#NFAB_ECREDIT
  CALL @nf_err
  JMP @nf_sd_out
nf_sd_space:
  LD r1,r0,#NFX_SEND+0
  MOVI r2,#NFAB_ENOSPC
  CALL @nf_err
  JMP @nf_sd_out
nf_sd_full:
  LD r1,r0,#NFX_SEND+0
  MOVI r2,#NFAB_EQFULL
  CALL @nf_err
  JMP @nf_sd_out
nf_sd_bad:
  LD r1,r0,#NFX_SEND+0
  MOVI r2,#NFAB_EBAD
  CALL @nf_err
nf_sd_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nfab_write r1=node r2=qid r3=buf r4=len r5=off_lo r6=off_hi r7=rkey
;            r8=wr_id -> 0/err.
nfab_write:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_WR+0
  ST r2,r0,#NFX_WR+1
  ST r3,r0,#NFX_WR+2
  ST r4,r0,#NFX_WR+3
  ST r5,r0,#NFX_WR+4
  ST r6,r0,#NFX_WR+5
  ST r7,r0,#NFX_WR+6
  ST r8,r0,#NFX_WR+7
  CALL @nf_qp
  CMP r1,r0
  JMP[EQ] @nf_wr_bad
  ST r1,r0,#NFX_WR+8
  LD r2,r1,#NF_Q_STATE
  MOVI r3,2
  CMP r2,r3
  JMP[NE] @nf_wr_bad
  LD r2,r0,#NFX_WR+2
  CMP r2,r0
  JMP[EQ] @nf_wr_bad
  LD r2,r0,#NFX_WR+3
  CMP r2,r0
  JMP[EQ] @nf_wr_bad
  ; remote key with write right
  LD r1,r0,#NFX_WR+8
  LD r1,r1,#NF_Q_RNODE
  LD r2,r0,#NFX_WR+6
  MOVI r3,2
  CALL @nf_rkey
  CMP r1,r0
  JMP[EQ] @nf_wr_key
  ST r1,r0,#NFX_WR+9
  ; bounds: off + len <= size
  LD r1,r0,#NFX_WR+4
  LD r2,r0,#NFX_WR+5
  LD r3,r0,#NFX_WR+3
  MOVI r4,0
  CALL @n64_add
  ST r1,r0,#NFX_WR+10
  ST r2,r0,#NFX_WR+11
  LD r3,r0,#NFX_WR+4
  LD r4,r0,#NFX_WR+5
  CALL @n64_cmp
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nf_wr_bounds
  LD r1,r0,#NFX_WR+10
  LD r2,r0,#NFX_WR+11
  LD r3,r0,#NFX_WR+9
  LD r3,r3,#NF_M_SIZE
  LD r4,r0,#NFX_WR+9
  LD r4,r4,#NF_M_SIZE+1
  CALL @n64_cmp
  MOVI r5,1
  CMP r1,r5
  JMP[EQ] @nf_wr_bounds
  ; effective = base + off
  LD r1,r0,#NFX_WR+9
  LD r1,r1,#NF_M_BASE
  LD r2,r0,#NFX_WR+9
  LD r2,r2,#NF_M_BASE+1
  LD r3,r0,#NFX_WR+4
  LD r4,r0,#NFX_WR+5
  CALL @n64_add
  CMP r2,r0
  JMP[NE] @nf_wr_addr
  ST r1,r0,#NFX_WR+12
  LD r3,r0,#NFX_WR+3
  ADD r4,r1,r3
  CMP r4,r1
  JMP[LT] @nf_wr_addr
  ; CQ space
  LD r1,r0,#NFX_WR+8
  CALL @nf_cq_space
  CMP r1,r0
  JMP[EQ] @nf_wr_full
  ; copy local -> remote
  LD r1,r0,#NFX_WR+2
  LD r2,r0,#NFX_WR+12
  LD r3,r0,#NFX_WR+3
  CALL @nf_copy
  ; completion
  LD r1,r0,#NFX_WR+0
  LD r2,r0,#NFX_WR+8
  MOVI r3,0
  MOVI r4,#NF_OP_WRITE
  LD r5,r0,#NFX_WR+3
  MOVI r6,0
  LD r7,r0,#NFX_WR+7
  CALL @nf_push
  ; counters
  LD r1,r0,#NFX_WR+0
  LD r2,r1,#NF_N_WRITES
  ADDI r2,r2,1
  ST r2,r1,#NF_N_WRITES
  MOVI r2,#NF_N_BWRITE
  LD r3,r0,#NFX_WR+3
  MOVI r4,0
  CALL @nf_add_bytes
  LD r1,r0,#NFX_WR+8
  LD r2,r1,#NF_Q_WRITES
  ADDI r2,r2,1
  ST r2,r1,#NF_Q_WRITES
  LD r1,r0,#NFX_WR+0
  CALL @nf_ok
  JMP @nf_wr_out
nf_wr_key:
  LD r1,r0,#NFX_WR+0
  CALL @nf_err
  JMP @nf_wr_out
nf_wr_bounds:
  LD r1,r0,#NFX_WR+0
  MOVI r2,#NFAB_EBOUNDS
  CALL @nf_err
  JMP @nf_wr_out
nf_wr_addr:
  LD r1,r0,#NFX_WR+0
  MOVI r2,#NFAB_EADDR
  CALL @nf_err
  JMP @nf_wr_out
nf_wr_full:
  LD r1,r0,#NFX_WR+0
  MOVI r2,#NFAB_EQFULL
  CALL @nf_err
  JMP @nf_wr_out
nf_wr_bad:
  LD r1,r0,#NFX_WR+0
  MOVI r2,#NFAB_EBAD
  CALL @nf_err
nf_wr_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nfab_read r1=node r2=qid r3=buf r4=len r5=off_lo r6=off_hi r7=rkey
;           r8=wr_id -> 0/err.
nfab_read:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_RD+0
  ST r2,r0,#NFX_RD+1
  ST r3,r0,#NFX_RD+2
  ST r4,r0,#NFX_RD+3
  ST r5,r0,#NFX_RD+4
  ST r6,r0,#NFX_RD+5
  ST r7,r0,#NFX_RD+6
  ST r8,r0,#NFX_RD+7
  CALL @nf_qp
  CMP r1,r0
  JMP[EQ] @nf_rd_bad
  ST r1,r0,#NFX_RD+8
  LD r2,r1,#NF_Q_STATE
  MOVI r3,2
  CMP r2,r3
  JMP[NE] @nf_rd_bad
  LD r2,r0,#NFX_RD+2
  CMP r2,r0
  JMP[EQ] @nf_rd_bad
  LD r2,r0,#NFX_RD+3
  CMP r2,r0
  JMP[EQ] @nf_rd_bad
  LD r1,r0,#NFX_RD+8
  LD r1,r1,#NF_Q_RNODE
  LD r2,r0,#NFX_RD+6
  MOVI r3,1
  CALL @nf_rkey
  CMP r1,r0
  JMP[EQ] @nf_rd_key
  ST r1,r0,#NFX_RD+9
  ; bounds
  LD r1,r0,#NFX_RD+4
  LD r2,r0,#NFX_RD+5
  LD r3,r0,#NFX_RD+3
  MOVI r4,0
  CALL @n64_add
  ST r1,r0,#NFX_RD+10
  ST r2,r0,#NFX_RD+11
  LD r3,r0,#NFX_RD+4
  LD r4,r0,#NFX_RD+5
  CALL @n64_cmp
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nf_rd_bounds
  LD r1,r0,#NFX_RD+10
  LD r2,r0,#NFX_RD+11
  LD r3,r0,#NFX_RD+9
  LD r3,r3,#NF_M_SIZE
  LD r4,r0,#NFX_RD+9
  LD r4,r4,#NF_M_SIZE+1
  CALL @n64_cmp
  MOVI r5,1
  CMP r1,r5
  JMP[EQ] @nf_rd_bounds
  LD r1,r0,#NFX_RD+9
  LD r1,r1,#NF_M_BASE
  LD r2,r0,#NFX_RD+9
  LD r2,r2,#NF_M_BASE+1
  LD r3,r0,#NFX_RD+4
  LD r4,r0,#NFX_RD+5
  CALL @n64_add
  CMP r2,r0
  JMP[NE] @nf_rd_addr
  ST r1,r0,#NFX_RD+12
  LD r3,r0,#NFX_RD+3
  ADD r4,r1,r3
  CMP r4,r1
  JMP[LT] @nf_rd_addr
  LD r1,r0,#NFX_RD+8
  CALL @nf_cq_space
  CMP r1,r0
  JMP[EQ] @nf_rd_full
  ; copy remote -> local
  LD r1,r0,#NFX_RD+12
  LD r2,r0,#NFX_RD+2
  LD r3,r0,#NFX_RD+3
  CALL @nf_copy
  LD r1,r0,#NFX_RD+0
  LD r2,r0,#NFX_RD+8
  MOVI r3,0
  MOVI r4,#NF_OP_READ
  LD r5,r0,#NFX_RD+3
  MOVI r6,0
  LD r7,r0,#NFX_RD+7
  CALL @nf_push
  LD r1,r0,#NFX_RD+0
  LD r2,r1,#NF_N_READS
  ADDI r2,r2,1
  ST r2,r1,#NF_N_READS
  MOVI r2,#NF_N_BREAD
  LD r3,r0,#NFX_RD+3
  MOVI r4,0
  CALL @nf_add_bytes
  LD r1,r0,#NFX_RD+8
  LD r2,r1,#NF_Q_READS
  ADDI r2,r2,1
  ST r2,r1,#NF_Q_READS
  LD r1,r0,#NFX_RD+0
  CALL @nf_ok
  JMP @nf_rd_out
nf_rd_key:
  LD r1,r0,#NFX_RD+0
  CALL @nf_err
  JMP @nf_rd_out
nf_rd_bounds:
  LD r1,r0,#NFX_RD+0
  MOVI r2,#NFAB_EBOUNDS
  CALL @nf_err
  JMP @nf_rd_out
nf_rd_addr:
  LD r1,r0,#NFX_RD+0
  MOVI r2,#NFAB_EADDR
  CALL @nf_err
  JMP @nf_rd_out
nf_rd_full:
  LD r1,r0,#NFX_RD+0
  MOVI r2,#NFAB_EQFULL
  CALL @nf_err
  JMP @nf_rd_out
nf_rd_bad:
  LD r1,r0,#NFX_RD+0
  MOVI r2,#NFAB_EBAD
  CALL @nf_err
nf_rd_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nfab_poll r1=node r2=qid r3=out(8) -> 1 got / 0 empty.
nfab_poll:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_POLL+0
  ST r3,r0,#NFX_POLL+1
  CMP r3,r0
  JMP[EQ] @nf_po_bad
  CALL @nf_qp
  CMP r1,r0
  JMP[EQ] @nf_po_bad
  ST r1,r0,#NFX_POLL+2
  LD r2,r1,#NF_Q_CQH
  LD r3,r1,#NF_Q_CQT
  CMP r2,r3
  JMP[EQ] @nf_po_empty
  LD r5,r1,#NF_Q_DEPTH
  MODU r4,r2,r5
  SHL r4,r4,3
  LD r5,r1,#NF_Q_CQ
  ADD r4,r4,r5
  LD r5,r0,#NFX_POLL+1
  MOVI r6,#NF_K_WORDS
  BCOPY r5,r4,r6
  LD r2,r1,#NF_Q_CQH
  ADDI r2,r2,1
  ST r2,r1,#NF_Q_CQH
  LD r1,r0,#NFX_POLL+0
  CALL @nf_ok
  MOVI r1,1
  JMP @nf_po_out
nf_po_empty:
  LD r1,r0,#NFX_POLL+0
  CALL @nf_ok
  MOVI r1,0
  JMP @nf_po_out
nf_po_bad:
  LD r1,r0,#NFX_POLL+0
  MOVI r2,#NFAB_EBAD
  CALL @nf_err
  MOVI r1,0
nf_po_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nfab_cq_count r1=node r2=qid -> outstanding CQEs.
nfab_cq_count:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_POLL+0
  CALL @nf_qp
  CMP r1,r0
  JMP[EQ] @nf_cc_bad
  LD r2,r1,#NF_Q_CQT
  LD r3,r1,#NF_Q_CQH
  SUB r1,r2,r3
  JMP @nf_cc_out
nf_cc_bad:
  MOVI r1,0
nf_cc_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nfab_errno r1=node -> errno.
nfab_errno:
  CMP r1,r0
  JMP[EQ] @nf_en_bad
  LD r1,r1,#NF_N_ERRNO
  RET
nf_en_bad:
  MOVI r1,#NFAB_EBAD
  RET

; ---------------------------------------------------------------------------
; nfab_kv_put r1=node r2=qid r3=slab r4=token r5=off_lo r6=off_hi
;             r7=rkey r8=expected generation -> 0/err.
nfab_kv_put:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_KV+0
  ST r2,r0,#NFX_KV+1
  ST r3,r0,#NFX_KV+2
  ST r4,r0,#NFX_KV+3
  ST r5,r0,#NFX_KV+4
  ST r6,r0,#NFX_KV+5
  ST r7,r0,#NFX_KV+6
  ST r8,r0,#NFX_KV+7
  ; local token -> NFX_KV+8..15
  LD r1,r0,#NFX_KV+2
  LD r2,r0,#NFX_KV+3
  LA r3,#NFX_KV+8
  CALL @nkv_slab_read_token
  CMP r1,r0
  JMP[NE] @nf_kvp_bad
  LD r1,r0,#NFX_KV+8
  LD r2,r0,#NFX_KV+9
  LD r3,r0,#NFX_KV+10
  LD r4,r0,#NFX_KV+11
  ; generation at +13
  LD r5,r0,#NFX_KV+13
  LD r6,r0,#NFX_KV+7
  CMP r5,r6
  JMP[NE] @nf_kvp_stale
  CMP r2,r0
  JMP[NE] @nf_kvp_addr
  ; nfab_write(node,qid,addr,len,off_lo,off_hi,rkey,token)
  LD r1,r0,#NFX_KV+0
  LD r2,r0,#NFX_KV+1
  LD r3,r0,#NFX_KV+8
  LD r4,r0,#NFX_KV+10
  LD r5,r0,#NFX_KV+4
  LD r6,r0,#NFX_KV+5
  LD r7,r0,#NFX_KV+6
  LD r8,r0,#NFX_KV+3
  CALL @nfab_write
  JMP @nf_kvp_out
nf_kvp_bad:
  LD r1,r0,#NFX_KV+0
  MOVI r2,#NFAB_ENOENT
  CALL @nf_err
  JMP @nf_kvp_out
nf_kvp_stale:
  LD r1,r0,#NFX_KV+0
  MOVI r2,#NFAB_ESTALE
  CALL @nf_err
  JMP @nf_kvp_out
nf_kvp_addr:
  LD r1,r0,#NFX_KV+0
  MOVI r2,#NFAB_EADDR
  CALL @nf_err
nf_kvp_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nfab_kv_get r1=node r2=qid r3=slab r4=token r5=off_lo r6=off_hi
;             r7=rkey r8=expected generation -> 0/err.
nfab_kv_get:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_KV+0
  ST r2,r0,#NFX_KV+1
  ST r3,r0,#NFX_KV+2
  ST r4,r0,#NFX_KV+3
  ST r5,r0,#NFX_KV+4
  ST r6,r0,#NFX_KV+5
  ST r7,r0,#NFX_KV+6
  ST r8,r0,#NFX_KV+7
  LD r1,r0,#NFX_KV+2
  LD r2,r0,#NFX_KV+3
  LA r3,#NFX_KV+8
  CALL @nkv_slab_read_token
  CMP r1,r0
  JMP[NE] @nf_kvg_bad
  LD r1,r0,#NFX_KV+8
  LD r2,r0,#NFX_KV+9
  LD r3,r0,#NFX_KV+10
  LD r4,r0,#NFX_KV+11
  LD r5,r0,#NFX_KV+13
  LD r6,r0,#NFX_KV+7
  CMP r5,r6
  JMP[NE] @nf_kvg_stale
  CMP r2,r0
  JMP[NE] @nf_kvg_addr
  ; nfab_read(node,qid,dst_addr,len,off_lo,off_hi,rkey,token)
  LD r1,r0,#NFX_KV+0
  LD r2,r0,#NFX_KV+1
  LD r3,r0,#NFX_KV+8
  LD r4,r0,#NFX_KV+10
  LD r5,r0,#NFX_KV+4
  LD r6,r0,#NFX_KV+5
  LD r7,r0,#NFX_KV+6
  LD r8,r0,#NFX_KV+3
  CALL @nfab_read
  JMP @nf_kvg_out
nf_kvg_bad:
  LD r1,r0,#NFX_KV+0
  MOVI r2,#NFAB_ENOENT
  CALL @nf_err
  JMP @nf_kvg_out
nf_kvg_stale:
  LD r1,r0,#NFX_KV+0
  MOVI r2,#NFAB_ESTALE
  CALL @nf_err
  JMP @nf_kvg_out
nf_kvg_addr:
  LD r1,r0,#NFX_KV+0
  MOVI r2,#NFAB_EADDR
  CALL @nf_err
nf_kvg_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nf_mix r1=hash r2=word -> r1.  32-bit xor/multiply chain (nagent-compatible).
nf_mix:
  BOOL.6 r1,r1,r2
  LA r3,#NFCK_MIX_C1
  ADD r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  LA r3,#NFCK_MIX_C2
  MUL r1,r1,r3
  SHR r4,r1,15
  BOOL.6 r1,r1,r4
  LA r3,#NFCK_MIX_C3
  MUL r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  RET

; nf_ck_hash r1=blob r2=total -> r1=hash.
nf_ck_hash:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_HASH+0
  ST r2,r0,#NFX_HASH+1
  LA r1,#NFCK_SEED
  LD r2,r0,#NFX_HASH+1
  CALL @nf_mix
  ST r1,r0,#NFX_HASH+2
  MOVI r2,0
  ST r2,r0,#NFX_HASH+3
nf_h_l:
  LD r2,r0,#NFX_HASH+3
  LD r3,r0,#NFX_HASH+1
  CMP r2,r3
  JMP[GE] @nf_h_done
  MOVI r3,#NFCK_HASH
  CMP r2,r3
  JMP[EQ] @nf_h_skip
  LD r4,r0,#NFX_HASH+0
  ADD r4,r4,r2
  LD r2,r4,0
  LD r1,r0,#NFX_HASH+2
  CALL @nf_mix
  ST r1,r0,#NFX_HASH+2
nf_h_skip:
  LD r2,r0,#NFX_HASH+3
  ADDI r2,r2,1
  ST r2,r0,#NFX_HASH+3
  JMP @nf_h_l
nf_h_done:
  LD r1,r0,#NFX_HASH+2
  CMP r1,r0
  JMP[NE] @nf_h_out
  LA r1,#NFCK_SEED
nf_h_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nfab_ck_seal r1=blob r2=words -> hash/0.
nfab_ck_seal:
  JMP @nf_ck_hash

; nfab_ck_verify r1=blob r2=words -> 0/err.
nfab_ck_verify:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_VERIFY+0
  ST r2,r0,#NFX_VERIFY+1
  CMP r1,r0
  JMP[EQ] @nf_v_bad
  MOVI r3,48
  CMP r2,r3
  JMP[LT] @nf_v_bad
  LD r3,r1,0
  LA r4,#NFCK_MAGIC
  CMP r3,r4
  JMP[NE] @nf_v_bad
  LD r3,r1,1
  MOVI r4,#NFCK_VERSION
  CMP r3,r4
  JMP[NE] @nf_v_bad
  LD r3,r1,23
  CMP r3,r2
  JMP[NE] @nf_v_bad
  LD r3,r1,#NFCK_CAPS
  MOVI r4,32
  CMP r3,r4
  JMP[GT] @nf_v_bad
  SHL r3,r3,3
  ADDI r3,r3,48
  CMP r3,r2
  JMP[NE] @nf_v_bad
  LD r1,r0,#NFX_VERIFY+0
  LD r2,r0,#NFX_VERIFY+1
  CALL @nfab_ck_seal
  LD r2,r0,#NFX_VERIFY+0
  LD r3,r2,#NFCK_HASH
  CMP r1,r3
  JMP[NE] @nf_v_bad
  MOVI r1,0
  JMP @nf_v_out
nf_v_bad:
  MOVI r1,#NFAB_ECK
nf_v_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nfab_ck_send r1=node r2=qid r3=blob r4=words r5=off_lo r6=off_hi
;              r7=rkey r8=epoch -> 0/err.
nfab_ck_send:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_CK+0
  ST r2,r0,#NFX_CK+1
  ST r3,r0,#NFX_CK+2
  ST r4,r0,#NFX_CK+3
  ST r5,r0,#NFX_CK+4
  ST r6,r0,#NFX_CK+5
  ST r7,r0,#NFX_CK+6
  ST r8,r0,#NFX_CK+7
  LD r1,r0,#NFX_CK+2
  LD r2,r0,#NFX_CK+3
  CALL @nfab_ck_verify
  CMP r1,r0
  JMP[NE] @nf_cks_bad
  LD r3,r0,#NFX_CK+2
  LD r4,r3,#NFCK_EPOCH
  LD r5,r0,#NFX_CK+7
  CMP r4,r5
  JMP[NE] @nf_cks_stale
  ; rollback: same agent id+generation must advance the epoch
  LD r1,r0,#NFX_CK+0
  LD r2,r3,#NFCK_AGENT
  LD r3,r3,#NFCK_AGEN
  LD r4,r1,#NF_N_CKAGENT
  LD r5,r1,#NF_N_CKAGEN
  CMP r2,r4
  JMP[NE] @nf_cks_write
  CMP r3,r5
  JMP[NE] @nf_cks_write
  LD r4,r1,#NF_N_CKEPOCH
  LD r5,r0,#NFX_CK+7
  CMP r5,r4
  JMP[LE] @nf_cks_stale
nf_cks_write:
  LD r1,r0,#NFX_CK+0
  LD r2,r0,#NFX_CK+1
  LD r3,r0,#NFX_CK+2
  SHL r3,r3,2
  LD r4,r0,#NFX_CK+3
  SHL r4,r4,2
  LD r5,r0,#NFX_CK+4
  LD r6,r0,#NFX_CK+5
  LD r7,r0,#NFX_CK+6
  LD r8,r0,#NFX_CK+7
  CALL @nfab_write
  CMP r1,r0
  JMP[NE] @nf_cks_out
  ; remember the shipped checkpoint
  LD r1,r0,#NFX_CK+0
  LD r2,r0,#NFX_CK+2
  LD r3,r2,#NFCK_AGENT
  ST r3,r1,#NF_N_CKAGENT
  LD r3,r2,#NFCK_AGEN
  ST r3,r1,#NF_N_CKAGEN
  LD r3,r2,#NFCK_EPOCH
  ST r3,r1,#NF_N_CKEPOCH
  MOVI r1,0
  JMP @nf_cks_out
nf_cks_bad:
  LD r1,r0,#NFX_CK+0
  MOVI r2,#NFAB_ECK
  CALL @nf_err
  JMP @nf_cks_out
nf_cks_stale:
  LD r1,r0,#NFX_CK+0
  MOVI r2,#NFAB_ESTALE
  CALL @nf_err
nf_cks_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nfab_ck_recv r1=node r2=qid r3=off_lo r4=off_hi r5=blob r6=words
;              r7=rkey r8=epoch -> 0/err.
nfab_ck_recv:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NFX_CK+0
  ST r2,r0,#NFX_CK+1
  ST r3,r0,#NFX_CK+4
  ST r4,r0,#NFX_CK+5
  ST r5,r0,#NFX_CK+2
  ST r6,r0,#NFX_CK+3
  ST r7,r0,#NFX_CK+6
  ST r8,r0,#NFX_CK+7
  ; read the record
  LD r1,r0,#NFX_CK+0
  LD r2,r0,#NFX_CK+1
  LD r3,r0,#NFX_CK+2
  SHL r3,r3,2
  LD r4,r0,#NFX_CK+3
  SHL r4,r4,2
  LD r5,r0,#NFX_CK+4
  LD r6,r0,#NFX_CK+5
  LD r7,r0,#NFX_CK+6
  LD r8,r0,#NFX_CK+7
  CALL @nfab_read
  CMP r1,r0
  JMP[NE] @nf_ckr_out
  LD r1,r0,#NFX_CK+2
  LD r2,r0,#NFX_CK+3
  CALL @nfab_ck_verify
  CMP r1,r0
  JMP[NE] @nf_ckr_bad
  LD r3,r0,#NFX_CK+2
  LD r3,r3,#NFCK_EPOCH
  LD r4,r0,#NFX_CK+7
  CMP r3,r4
  JMP[NE] @nf_ckr_stale
  LD r1,r0,#NFX_CK+0
  LD r2,r0,#NFX_CK+2
  LD r3,r2,#NFCK_AGENT
  LD r4,r2,#NFCK_AGEN
  LD r5,r1,#NF_N_CKAGENT
  LD r6,r1,#NF_N_CKAGEN
  CMP r3,r5
  JMP[NE] @nf_ckr_accept
  CMP r4,r6
  JMP[NE] @nf_ckr_accept
  LD r5,r1,#NF_N_CKEPOCH
  LD r6,r0,#NFX_CK+7
  CMP r6,r5
  JMP[LE] @nf_ckr_stale
nf_ckr_accept:
  ST r3,r1,#NF_N_CKAGENT
  ST r4,r1,#NF_N_CKAGEN
  LD r3,r0,#NFX_CK+7
  ST r3,r1,#NF_N_CKEPOCH
  CALL @nf_ok
  JMP @nf_ckr_out
nf_ckr_bad:
  LD r1,r0,#NFX_CK+0
  MOVI r2,#NFAB_ECK
  CALL @nf_err
  JMP @nf_ckr_out
nf_ckr_stale:
  LD r1,r0,#NFX_CK+0
  MOVI r2,#NFAB_ESTALE
  CALL @nf_err
nf_ckr_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
