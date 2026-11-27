; nkcas.nas - content-addressed store persistence and cold hydration (F13k).
;
; Pure NaN.  This is the F13k layer above nkvmerkle: a word-addressed
; content-addressed store keyed by the 64-bit node identity (hash_lo,hash_hi).
; A record carries the node length (used words), a deterministic checksum over
; the committed fields and payload, the payload itself, the ordered parent
; hashes and the generation tag.  A second put of the same key with identical
; fields is a dedup hit: it increments the persistent dedup counter and the
; exact avoided-byte counter and does not rewrite the record.  A second put
; with the same key and different fields is ECOLL and never aliases.
;
; Persistence and cold start
; --------------------------
; The store is a caller-supplied word region.  Its superblock and fixed-size
; 48-word records live in that region and survive a simulated process restart.
; A volatile directory in library scratch is the in-memory key registry; a cold
; restart clears only the directory and the volatile counters.  nkcas_mount
; validates the superblock and every live record checksum, then rebuilds the
; directory from the store.  Hydration by root hash walks the stored parent
; hashes, reconstructs the closure in parents-first order, and can:
;   * materialise the flat page/token view (nkcas_hydrate),
;   * build a self-contained inclusion proof from the store alone
;     (nkcas_proof) and verify it with the nkvmerkle verifier, which does not
;     read the node registry, or
;   * re-create public nkvmerkle nodes with nkm_add and then open/join an
;     nkvmerkle agent view by the same root hash (nkcas_registry_hydrate,
;     nkcas_agent_hydrate).
;
; Record identity and checksum
; ----------------------------
; The key is exactly (hash_lo,hash_hi), the nkvmerkle node hash.  The checksum
; is a deterministic two-lane-style 32-bit mix seeded with NKCS_CK_SEED over:
; hash_lo, hash_hi, used, generation, parent count, four ordered parent hash
; lo words, four ordered parent hash hi words, and the used payload words.  It
; excludes state, sequence and per-record dedup counters, so a dedup counter
; update does not require a rewrite.  The checksum catches a mutated payload,
; parent hash, generation, used count or key.  It is a corruption check, not a
; cryptographic MAC.
;
; Store superblock (32 words at the store base):
;   +0 magic "NKCS" 0x53434B4E   +1 version 1
;   +2 capacity records          +3 live records
;   +4 next sequence             +5 unique puts (lifetime)
;   +6 dedup hits (lifetime)     +7 bytes written (lifetime)
;   +8 bytes avoided (lifetime)  +9 successful mounts (lifetime)
;   +10 deletes (lifetime)       +11 store generation
;   +12 superblock checksum      +13..31 reserved
;
; Record (48 words = 192 bytes):
;   +0 magic "NKCR" 0x52434B4E  +1 version 1
;   +2 state (0 empty, 1 live)  +3 hash lo +4 hash hi
;   +5 used words (1..16)       +6 checksum
;   +7 generation tag           +8 parent count (0..4)
;   +9..12 parent hash lo       +13..16 parent hash hi
;   +17 owner agent             +18 flags (1 public)
;   +19 sequence                +20 dedup hits on this record
;   +21 record bytes (192)      +22..23 reserved
;   +24..39 payload (16 words; only used words are committed)
;   +40..47 reserved
;
; Volatile directory (64 entries x 4 words): {slot, hash lo, hash hi, checksum};
; entry count at NKCS_DIRN.  It is cleared on cold restart and rebuilt by mount.
;
; Volatile stats (64 words at NKCS_STATS):
;   +0 magic "NKCG" +1 version +2 store base +3 capacity +4 mounted
;   +5 live +6 puts +7 gets +8 deletes +9 dedup +10 bytes written
;   +11 bytes avoided +12 hydrates +13 hydrated nodes +14 hydrated tokens
;   +15 proofs +16 verifies +17 proof rejects +18 missing +19 corrupt
;   +20 collisions +21 mutations +22 no space +23 bad args +24 store errors
;   +25 cold restarts +26 trace head +27 trace events +28 trace wraps
;   +29 errors +30 last errno +31 ops +32 sequence +33 mounts
;   +34 hydrated agents +35..63 reserved
;
; Trace: 128 entries x 8 words {kind, seq, a, b, c, 0, hash lo, hash hi}.
; Kinds: 1 init, 2 put, 3 dedup, 4 get, 5 delete, 6 cold, 7 mount,
;        8 hydrate, 9 proof, 10 verify, 11 reject.
;
; Errors (nkcas_errno):
;   0 OK, 1 EBAD, 2 ENOENT, 3 ENOSPC, 4 ECORRUPT, 5 ECOLL, 6 EMISS,
;   7 EPROOF, 8 ESTORE, 9 EMUT.
;
; API (r0=0, r13=1, r14 grows up, r15 link):
;   nkcas_init       r1=store base r2=capacity (1..32) -> 0 / -1
;   nkcas_mount      r1=store base -> 0 / err
;   nkcas_cold_restart -> 0 (clears volatile directory/stats/trace only)
;   nkcas_put        r1=hash lo r2=hash hi r3=values r4=used r5=gen
;                    r6=parent array (4 lo then 4 hi) r7=parent count
;                    -> slot / NONE
;   nkcas_put_record r1=record(48) -> slot / NONE
;   nkcas_capture    r1=public nkvmerkle node index -> slot / NONE
;   nkcas_get        r1=hash lo r2=hash hi r3=out(48) -> 0 / err
;   nkcas_delete     r1=hash lo r2=hash hi -> 0 / err
;   nkcas_find       r1=hash lo r2=hash hi -> slot / NONE
;   nkcas_hydrate    r1=root lo r2=root hi r3=page out r4=token out
;                    -> token count / NONE.  Page out:
;                    +0 pages +1 tokens +2 nodes +3 root slot
;                    +4.. page entries {slot, hash lo, hash hi, used}
;   nkcas_proof      r1=root lo r2=root hi r3=target lo r4=target hi
;                    r5=token offset / NKCS_NONE r6=proof out
;                    -> depth / 0
;   nkcas_verify     r1=root lo r2=root hi r3=proof -> 1/0
;   nkcas_registry_hydrate r1=root lo r2=root hi r3=owner
;                    -> nkvmerkle root index / NONE
;   nkcas_agent_hydrate r1=cfg -> 1/0
;                    cfg: +0 ctx +1 ngen agent +2 gen +3 cpu +4 branch
;                         +5 nagent id +6 table +7 table cap +8 tokens/block
;                         +9 root lo +10 root hi +11 owner
;   nkcas_stats      r1=out(64) -> 0/-1
;   nkcas_trace      r1=index r2=out(8) -> 0/-1
;   nkcas_errno      -> last error
;
; Requires nagent_init and ngen_init before nkcas_agent_hydrate.  nkm_init must
; have been called for a cold registry before hydration into nkvmerkle.  The
; store region is plain caller memory; no NVMe/RDMA transport is implemented.

.include "nkvmerkle.nas"

.equ NKCS_DIR        0x366000
.equ NKCS_DIR_MAX    64
.equ NKCS_DIR_W      4
.equ NKCS_DIRWORDS   256
.equ NKCS_DIRN       0x366400
.equ NKCS_STATS      0x367000
.equ NKCS_SW         64
.equ NKCS_TRACE      0x367200
.equ NKCS_TRACE_N    128
.equ NKCS_TRACE_W    8
.equ NKCS_TRACE_TOTAL 1024
.equ NKCS_SCR        0x368000
.equ NKCS_TMP        0x368000
.equ NKCS_TMP2       0x368040
.equ NKCS_NI         0x368080
.equ NKCS_PATH       0x3680C0
.equ NKCS_LIST       0x368100
.equ NKCS_LISTN      0x368120
.equ NKCS_RECBUF     0x368200
.equ NKCS_BASE       0x368300
.equ NKCS_CAP        0x368301
.equ NKCS_MOUNTED    0x368302
.equ NKCS_DFS_DEPTH  0x368303
.equ NKCS_DFS_TARGET 0x368304
.equ NKCS_DFS_OK     0x368305

.equ NKCS_SB_MAGIC   0
.equ NKCS_SB_VERSION 1
.equ NKCS_SB_CAP     2
.equ NKCS_SB_COUNT   3
.equ NKCS_SB_SEQ     4
.equ NKCS_SB_PUTS    5
.equ NKCS_SB_DEDUP   6
.equ NKCS_SB_WRITTEN 7
.equ NKCS_SB_AVOID   8
.equ NKCS_SB_MOUNTS  9
.equ NKCS_SB_DELS    10
.equ NKCS_SB_GEN     11
.equ NKCS_SB_SUM     12
.equ NKCS_SB_WORDS   32

.equ NKCS_R_MAGIC    0
.equ NKCS_R_VERSION  1
.equ NKCS_R_STATE    2
.equ NKCS_R_HLO      3
.equ NKCS_R_HHI      4
.equ NKCS_R_USED     5
.equ NKCS_R_SUM      6
.equ NKCS_R_GEN      7
.equ NKCS_R_PCOUNT   8
.equ NKCS_R_PLO      9
.equ NKCS_R_PHI      13
.equ NKCS_R_OWNER    17
.equ NKCS_R_FLAGS    18
.equ NKCS_R_SEQ      19
.equ NKCS_R_DEDUP    20
.equ NKCS_R_SIZE     21
.equ NKCS_R_PAY      24
.equ NKCS_R_WORDS    48

.equ NKCS_D_SLOT     0
.equ NKCS_D_HLO      1
.equ NKCS_D_HHI      2
.equ NKCS_D_SUM      3

.equ NKCS_G_MAGIC    0
.equ NKCS_G_VERSION  1
.equ NKCS_G_BASE     2
.equ NKCS_G_CAP      3
.equ NKCS_G_MOUNTED  4
.equ NKCS_G_LIVE     5
.equ NKCS_G_PUTS     6
.equ NKCS_G_GETS     7
.equ NKCS_G_DELS     8
.equ NKCS_G_DEDUP    9
.equ NKCS_G_WRITTEN  10
.equ NKCS_G_AVOID    11
.equ NKCS_G_HYDRATES 12
.equ NKCS_G_HNODES   13
.equ NKCS_G_HTOKENS  14
.equ NKCS_G_PROOFS   15
.equ NKCS_G_VERIFIES 16
.equ NKCS_G_XPROOF   17
.equ NKCS_G_MISS     18
.equ NKCS_G_CORRUPT  19
.equ NKCS_G_COLL     20
.equ NKCS_G_MUT      21
.equ NKCS_G_NOSPC    22
.equ NKCS_G_BAD      23
.equ NKCS_G_STORE    24
.equ NKCS_G_COLD     25
.equ NKCS_G_THEAD    26
.equ NKCS_G_TEVENTS  27
.equ NKCS_G_TWRAPS   28
.equ NKCS_G_ERRORS   29
.equ NKCS_G_LERR     30
.equ NKCS_G_OPS      31
.equ NKCS_G_SEQ      32
.equ NKCS_G_MOUNTS   33
.equ NKCS_G_HAGENTS  34

.equ NKCS_OK         0
.equ NKCS_EBAD       1
.equ NKCS_ENOENT     2
.equ NKCS_ENOSPC     3
.equ NKCS_ECORRUPT   4
.equ NKCS_ECOLL      5
.equ NKCS_EMISS      6
.equ NKCS_EPROOF     7
.equ NKCS_ESTORE     8
.equ NKCS_EMUT       9

.equ NKCS_NONE       0xFFFFFFFF
.equ NKCS_MAXREC     32
.equ NKCS_MAXNODE    32
.equ NKCS_PROOF_MAX  16
.equ NKCS_PENTRY     16
.equ NKCS_PAGEHDR    4
.equ NKCS_PESTRIDE   32
.equ NKCS_REC_BYTES  192
.equ NKCS_CK_SEED    0x43415331
.equ NKCS_MIX_C1     0x9E3779B9
.equ NKCS_MIX_C2     0x85EBCA6B
.equ NKCS_MIX_C3     0xC2B2AE35

.equ NKCS_SMAGIC     0x53434B4E       ; "NKCS"
.equ NKCS_RMAGIC     0x52434B4E       ; "NKCR"
.equ NKCS_GMAGIC     0x47434B4E       ; "NKCG"

.equ NKCS_T_INIT     1
.equ NKCS_T_PUT      2
.equ NKCS_T_DEDUP    3
.equ NKCS_T_GET      4
.equ NKCS_T_DEL      5
.equ NKCS_T_COLD     6
.equ NKCS_T_MOUNT    7
.equ NKCS_T_HYDRATE  8
.equ NKCS_T_PROOF    9
.equ NKCS_T_VERIFY   10
.equ NKCS_T_REJECT   11

; ---------------------------------------------------------------------------
; nkcas_mix r1=hash r2=word -> r1.
nkcas_mix:
  BOOL.6 r1,r1,r2
  LA r3,#NKCS_MIX_C1
  ADD r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  LA r3,#NKCS_MIX_C2
  MUL r1,r1,r3
  SHR r4,r1,15
  BOOL.6 r1,r1,r4
  LA r3,#NKCS_MIX_C3
  MUL r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  RET

; ---------------------------------------------------------------------------
; nkcas_recptr r1=slot -> record pointer / 0.
nkcas_recptr:
  MOVI r2,#NKCS_MAXREC
  CMP r1,r2
  JMP[GE] @nkcrp_bad
  SHL r2,r1,4
  MOVI r3,3
  MUL r2,r2,r3
  LA r3,#NKCS_BASE
  LD r3,r3,0
  CMP r3,r0
  JMP[EQ] @nkcrp_bad
  ADDI r3,r3,#NKCS_SB_WORDS
  ADD r1,r3,r2
  RET
nkcrp_bad:
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; nkcas_err r1=code -> 0.  Counts errors and traces a rejection.
nkcas_err:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  LA r3,#NKCS_STATS
  LD r4,r3,#NKCS_G_ERRORS
  ADD r4,r4,r13
  ST r4,r3,#NKCS_G_ERRORS
  LD r4,r3,#NKCS_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKCS_G_OPS
  LD r1,r14,1
  ST r1,r3,#NKCS_G_LERR
  MOVI r2,#NKCS_T_REJECT
  MOVI r3,0
  MOVI r4,0
  LD r5,r14,1
  CALL @nkcas_trace_add
  MOVI r1,0
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_trace_add r1=kind r2=a r3=b r4=c r5=aux.
nkcas_trace_add:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  LA r6,#NKCS_STATS
  LD r7,r6,#NKCS_G_THEAD
  MOVI r8,#NKCS_TRACE_N
  CMP r7,r8
  JMP[LT] @nkct_room
  ST r0,r6,#NKCS_G_THEAD
  MOVI r7,0
  LD r8,r6,#NKCS_G_TWRAPS
  ADD r8,r8,r13
  ST r8,r6,#NKCS_G_TWRAPS
nkct_room:
  SHL r8,r7,3
  LA r9,#NKCS_TRACE
  ADD r8,r9,r8
  ST r8,r14,6
  LD r9,r14,1
  ST r9,r8,0
  LD r9,r6,#NKCS_G_TEVENTS
  ADD r9,r9,r13
  ST r9,r6,#NKCS_G_TEVENTS
  ST r9,r8,1
  LD r9,r14,2
  ST r9,r8,2
  LD r9,r14,3
  ST r9,r8,3
  LD r9,r14,4
  ST r9,r8,4
  ST r0,r8,5
  LD r9,r14,5
  ST r9,r8,6
  ST r0,r8,7
  ADD r7,r7,r13
  ST r7,r6,#NKCS_G_THEAD
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_checksum r1=record -> checksum.
nkcas_checksum:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  LA r1,#NKCS_CK_SEED
  ST r1,r14,2
  MOVI r2,3
  ST r2,r14,3
  MOVI r2,17
  ST r2,r14,4
nkck_h:
  LD r2,r14,3
  LD r3,r14,4
  CMP r2,r3
  JMP[GE] @nkck_pay
  MOVI r3,6
  CMP r2,r3
  JMP[EQ] @nkck_hn
  LD r1,r14,1
  ADD r1,r1,r2
  LD r2,r1,0
  LD r1,r14,2
  CALL @nkcas_mix
  ST r1,r14,2
nkck_hn:
  LD r2,r14,3
  ADD r2,r2,r13
  ST r2,r14,3
  JMP @nkck_h
nkck_pay:
  LD r1,r14,1
  LD r2,r1,#NKCS_R_USED
  ST r2,r14,4
  ST r0,r14,3
nkck_p:
  LD r2,r14,3
  LD r3,r14,4
  CMP r2,r3
  JMP[GE] @nkck_done
  LD r1,r14,1
  ADDI r1,r1,#NKCS_R_PAY
  ADD r1,r1,r2
  LD r2,r1,0
  LD r1,r14,2
  CALL @nkcas_mix
  ST r1,r14,2
  LD r2,r14,3
  ADD r2,r2,r13
  ST r2,r14,3
  JMP @nkck_p
nkck_done:
  LD r1,r14,2
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_record_valid r1=record ptr -> 1/0.
nkcas_record_valid:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  CMP r1,r0
  JMP[EQ] @nkcrv_no
  LD r2,r1,#NKCS_R_MAGIC
  LA r3,#NKCS_RMAGIC
  CMP r2,r3
  JMP[NE] @nkcrv_no
  LD r2,r1,#NKCS_R_VERSION
  MOVI r3,#NKM_VERSION
  CMP r2,r3
  JMP[NE] @nkcrv_no
  LD r2,r1,#NKCS_R_STATE
  CMP r2,r13
  JMP[NE] @nkcrv_no
  LD r2,r1,#NKCS_R_USED
  CMP r2,r0
  JMP[EQ] @nkcrv_no
  MOVI r3,#NKM_SLOTS
  CMP r2,r3
  JMP[GT] @nkcrv_no
  LD r2,r1,#NKCS_R_PCOUNT
  MOVI r3,4
  CMP r2,r3
  JMP[GT] @nkcrv_no
  CALL @nkcas_checksum
  ST r1,r14,2
  LD r2,r14,1
  LD r2,r2,#NKCS_R_SUM
  CMP r1,r2
  JMP[NE] @nkcrv_no
  MOVI r1,1
  JMP @nkcrv_out
nkcrv_no:
  MOVI r1,0
nkcrv_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_sb_checksum r1=base -> checksum over superblock words 0..11.
nkcas_sb_checksum:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  LA r1,#NKCS_CK_SEED
  ST r1,r14,2
  ST r0,r14,3
nkcsb_l:
  LD r2,r14,3
  MOVI r3,12
  CMP r2,r3
  JMP[GE] @nkcsb_done
  LD r1,r14,1
  ADD r1,r1,r2
  LD r2,r1,0
  LD r1,r14,2
  CALL @nkcas_mix
  ST r1,r14,2
  LD r2,r14,3
  ADD r2,r2,r13
  ST r2,r14,3
  JMP @nkcsb_l
nkcsb_done:
  LD r1,r14,2
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nkcas_sb_seal -> 0/-1.
nkcas_sb_seal:
  ST r15,r14,0
  ADDI r14,r14,16
  LA r1,#NKCS_BASE
  LD r1,r1,0
  CALL @nkcas_sb_checksum
  LA r2,#NKCS_BASE
  LD r2,r2,0
  ST r1,r2,#NKCS_SB_SUM
  MOVI r1,0
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkcas_sb_verify r1=base -> 1/0.
nkcas_sb_verify:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  CALL @nkcas_sb_checksum
  ST r1,r14,2
  LD r2,r14,1
  LD r2,r2,#NKCS_SB_SUM
  CMP r1,r2
  JMP[NE] @nkcsbv_no
  MOVI r1,1
  JMP @nkcsbv_out
nkcsbv_no:
  MOVI r1,0
nkcsbv_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; Directory helpers.  Volatile only.
nkcas_dir_clear:
  LA r1,#NKCS_DIR
  MOVI r2,#NKCS_DIRWORDS
  BFILL r1,r0,r2
  LA r1,#NKCS_DIRN
  ST r0,r1,0
  RET

; nkcas_dir_add r1=slot -> 0/err.
nkcas_dir_add:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  LA r2,#NKCS_DIRN
  LD r3,r2,0
  MOVI r4,#NKCS_DIR_MAX
  CMP r3,r4
  JMP[GE] @nkcda_full
  SHL r4,r3,2
  LA r5,#NKCS_DIR
  ADD r4,r5,r4
  ST r1,r4,#NKCS_D_SLOT
  LD r5,r14,1
  CALL @nkcas_recptr
  ST r1,r14,2
  LD r2,r1,#NKCS_R_HLO
  ST r2,r4,#NKCS_D_HLO
  LD r2,r1,#NKCS_R_HHI
  ST r2,r4,#NKCS_D_HHI
  LD r2,r1,#NKCS_R_SUM
  ST r2,r4,#NKCS_D_SUM
  LA r2,#NKCS_DIRN
  LD r3,r2,0
  ADD r3,r3,r13
  ST r3,r2,0
  MOVI r1,0
  JMP @nkcda_out
nkcda_full:
  MOVI r1,#NKCS_ENOSPC
  CALL @nkcas_err
  MOVI r1,#NKCS_ENOSPC
nkcda_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nkcas_dir_del r1=slot -> 0/-1.
nkcas_dir_del:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  LA r2,#NKCS_DIRN
  LD r3,r2,0
  ST r3,r14,2
  ST r0,r14,3
nkcdd_l:
  LD r3,r14,3
  LD r4,r14,2
  CMP r3,r4
  JMP[GE] @nkcdd_no
  SHL r4,r3,2
  LA r5,#NKCS_DIR
  ADD r5,r5,r4
  LD r4,r5,#NKCS_D_SLOT
  LD r6,r14,1
  CMP r4,r6
  JMP[EQ] @nkcdd_found
  LD r3,r14,3
  ADD r3,r3,r13
  ST r3,r14,3
  JMP @nkcdd_l
nkcdd_found:
  LD r3,r14,3
  ST r3,r14,4
nkcdd_shift:
  LD r3,r14,4
  LD r4,r14,2
  SUB r4,r4,r13
  CMP r3,r4
  JMP[GE] @nkcdd_shrink
  SHL r4,r3,2
  LA r5,#NKCS_DIR
  ADD r6,r5,r4
  ADDI r5,r6,#NKCS_DIR_W
  LD r7,r5,0
  ST r7,r6,0
  LD r7,r5,1
  ST r7,r6,1
  LD r7,r5,2
  ST r7,r6,2
  LD r7,r5,3
  ST r7,r6,3
  LD r3,r14,4
  ADD r3,r3,r13
  ST r3,r14,4
  JMP @nkcdd_shift
nkcdd_shrink:
  LD r3,r14,2
  SUB r3,r3,r13
  ST r3,r14,2
  LA r2,#NKCS_DIRN
  ST r3,r2,0
  MOVI r1,0
  JMP @nkcdd_out
nkcdd_no:
  LA r1,#NKCS_NONE
nkcdd_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_find r1=hash lo r2=hash hi -> slot / NONE.
nkcas_find:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r1,r14,1
  ST r2,r14,2
  LA r3,#NKCS_MOUNTED
  LD r3,r3,0
  CMP r3,r0
  JMP[EQ] @nkcf_no
  LA r3,#NKCS_DIRN
  LD r3,r3,0
  ST r3,r14,3
  ST r0,r14,4
nkcf_l:
  LD r3,r14,4
  LD r4,r14,3
  CMP r3,r4
  JMP[GE] @nkcf_no
  SHL r4,r3,2
  LA r5,#NKCS_DIR
  ADD r5,r5,r4
  LD r4,r5,#NKCS_D_SLOT
  LA r6,#NKCS_NONE
  CMP r4,r6
  JMP[EQ] @nkcf_next
  LD r6,r5,#NKCS_D_HLO
  LD r7,r14,1
  CMP r6,r7
  JMP[NE] @nkcf_next
  LD r6,r5,#NKCS_D_HHI
  LD r7,r14,2
  CMP r6,r7
  JMP[NE] @nkcf_next
  ADD r1,r4,r0
  JMP @nkcf_out
nkcf_next:
  LD r3,r14,4
  ADD r3,r3,r13
  ST r3,r14,4
  JMP @nkcf_l
nkcf_no:
  LA r1,#NKCS_NONE
nkcf_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_record_same r1=slot r2=incoming record -> 1/0.
nkcas_record_same:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  CALL @nkcas_recptr
  CMP r1,r0
  JMP[EQ] @nkrs_no
  ST r1,r14,3
  LD r2,r14,2
  ; hash, used, gen, parent count
  MOVI r3,3
  ST r3,r14,4
nkrs_f:
  LD r3,r14,4
  MOVI r4,9
  CMP r3,r4
  JMP[GE] @nkrs_par
  LD r4,r14,3
  ADD r4,r4,r3
  LD r4,r4,0
  LD r5,r14,2
  ADD r5,r5,r3
  LD r5,r5,0
  CMP r4,r5
  JMP[NE] @nkrs_no
  LD r3,r14,4
  ADD r3,r3,r13
  ST r3,r14,4
  JMP @nkrs_f
nkrs_par:
  MOVI r3,9
  ST r3,r14,4
nkrs_p:
  LD r3,r14,4
  MOVI r4,17
  CMP r3,r4
  JMP[GE] @nkrs_pay
  LD r4,r14,3
  ADD r4,r4,r3
  LD r4,r4,0
  LD r5,r14,2
  ADD r5,r5,r3
  LD r5,r5,0
  CMP r4,r5
  JMP[NE] @nkrs_no
  LD r3,r14,4
  ADD r3,r3,r13
  ST r3,r14,4
  JMP @nkrs_p
nkrs_pay:
  MOVI r3,0
  ST r3,r14,4
nkrs_pl:
  LD r3,r14,4
  MOVI r4,#NKM_SLOTS
  CMP r3,r4
  JMP[GE] @nkrs_yes
  LD r4,r14,3
  ADDI r4,r4,#NKCS_R_PAY
  ADD r4,r4,r3
  LD r4,r4,0
  LD r5,r14,2
  ADDI r5,r5,#NKCS_R_PAY
  ADD r5,r5,r3
  LD r5,r5,0
  CMP r4,r5
  JMP[NE] @nkrs_no
  LD r3,r14,4
  ADD r3,r3,r13
  ST r3,r14,4
  JMP @nkrs_pl
nkrs_yes:
  MOVI r1,1
  JMP @nkrs_out
nkrs_no:
  MOVI r1,0
nkrs_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_init r1=store base r2=capacity -> 0/-1.
nkcas_init:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r1,r14,1
  ST r2,r14,2
  CMP r1,r0
  JMP[EQ] @nkcai_bad
  CMP r2,r0
  JMP[EQ] @nkcai_bad
  MOVI r3,#NKCS_MAXREC
  CMP r2,r3
  JMP[GT] @nkcai_bad
  LA r3,#NKCS_BASE
  ST r1,r3,0
  LA r3,#NKCS_CAP
  ST r2,r3,0
  ; zero store: superblock + capacity records
  MOVI r3,#NKCS_R_WORDS
  MUL r3,r2,r3
  ADDI r3,r3,#NKCS_SB_WORDS
  ST r3,r14,3
  LD r1,r14,1
  LD r3,r14,3
  BFILL r1,r0,r3
  ; zero volatile regions
  LA r1,#NKCS_DIR
  MOVI r2,#NKCS_DIRWORDS
  BFILL r1,r0,r2
  LA r1,#NKCS_DIRN
  ST r0,r1,0
  LA r1,#NKCS_STATS
  MOVI r2,#NKCS_SW
  BFILL r1,r0,r2
  LA r1,#NKCS_TRACE
  MOVI r2,#NKCS_TRACE_TOTAL
  BFILL r1,r0,r2
  ; superblock
  LD r1,r14,1
  LA r2,#NKCS_SMAGIC
  ST r2,r1,#NKCS_SB_MAGIC
  MOVI r2,#NKM_VERSION
  ST r2,r1,#NKCS_SB_VERSION
  LD r2,r14,2
  ST r2,r1,#NKCS_SB_CAP
  ST r0,r1,#NKCS_SB_COUNT
  ST r0,r1,#NKCS_SB_SEQ
  ST r0,r1,#NKCS_SB_PUTS
  ST r0,r1,#NKCS_SB_DEDUP
  ST r0,r1,#NKCS_SB_WRITTEN
  ST r0,r1,#NKCS_SB_AVOID
  ST r0,r1,#NKCS_SB_MOUNTS
  ST r0,r1,#NKCS_SB_DELS
  MOVI r2,1
  ST r2,r1,#NKCS_SB_GEN
  CALL @nkcas_sb_seal
  ; stats
  LA r1,#NKCS_STATS
  LA r2,#NKCS_GMAGIC
  ST r2,r1,#NKCS_G_MAGIC
  MOVI r2,#NKM_VERSION
  ST r2,r1,#NKCS_G_VERSION
  LD r2,r14,1
  ST r2,r1,#NKCS_G_BASE
  LD r2,r14,2
  ST r2,r1,#NKCS_G_CAP
  MOVI r2,1
  ST r2,r1,#NKCS_G_MOUNTED
  LA r1,#NKCS_MOUNTED
  ST r13,r1,0
  MOVI r1,#NKCS_T_INIT
  LD r2,r14,1
  LD r3,r14,2
  MOVI r4,0
  MOVI r5,0
  CALL @nkcas_trace_add
  MOVI r1,0
  JMP @nkcai_out
nkcai_bad:
  MOVI r1,#NKCS_EBAD
  CALL @nkcas_err
  LA r1,0xFFFFFFFF
nkcai_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_mount r1=store base -> 0/err.
nkcas_mount:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  CMP r1,r0
  JMP[EQ] @nkcam_bad
  ; clear volatile state first
  LA r2,#NKCS_DIR
  MOVI r3,#NKCS_DIRWORDS
  BFILL r2,r0,r3
  LA r2,#NKCS_DIRN
  ST r0,r2,0
  LA r2,#NKCS_STATS
  MOVI r3,#NKCS_SW
  BFILL r2,r0,r3
  LA r2,#NKCS_TRACE
  MOVI r3,#NKCS_TRACE_TOTAL
  BFILL r2,r0,r3
  LA r2,#NKCS_STATS
  LA r3,#NKCS_GMAGIC
  ST r3,r2,#NKCS_G_MAGIC
  MOVI r3,#NKM_VERSION
  ST r3,r2,#NKCS_G_VERSION
  LD r3,r14,1
  ST r3,r2,#NKCS_G_BASE
  LA r3,#NKCS_MOUNTED
  ST r0,r3,0
  ; superblock header
  LD r1,r14,1
  LD r2,r1,#NKCS_SB_MAGIC
  LA r3,#NKCS_SMAGIC
  CMP r2,r3
  JMP[NE] @nkcam_store
  LD r2,r1,#NKCS_SB_VERSION
  MOVI r3,#NKM_VERSION
  CMP r2,r3
  JMP[NE] @nkcam_store
  LD r2,r1,#NKCS_SB_CAP
  CMP r2,r0
  JMP[EQ] @nkcam_store
  MOVI r3,#NKCS_MAXREC
  CMP r2,r3
  JMP[GT] @nkcam_store
  ST r2,r14,2
  LD r1,r14,1
  CALL @nkcas_sb_verify
  CMP r1,r0
  JMP[EQ] @nkcam_store
  ; publish base/cap and scan records
  LD r1,r14,1
  LA r2,#NKCS_BASE
  ST r1,r2,0
  LD r1,r14,2
  LA r2,#NKCS_CAP
  ST r1,r2,0
  ST r0,r14,3
  ST r0,r14,4
nkcam_l:
  LD r3,r14,4
  LD r2,r14,2
  CMP r3,r2
  JMP[GE] @nkcam_count
  MOVI r1,0
  LD r1,r14,4
  CALL @nkcas_recptr
  ST r1,r14,5
  CMP r1,r0
  JMP[EQ] @nkcam_corrupt
  LD r2,r1,#NKCS_R_STATE
  CMP r2,r0
  JMP[EQ] @nkcam_next
  CMP r2,r13
  JMP[NE] @nkcam_corrupt
  LD r1,r14,5
  CALL @nkcas_record_valid
  CMP r1,r0
  JMP[EQ] @nkcam_corrupt
  LD r1,r14,4
  CALL @nkcas_dir_add
  CMP r1,r0
  JMP[NE] @nkcam_ret
  LD r3,r14,3
  ADD r3,r3,r13
  ST r3,r14,3
nkcam_next:
  LD r3,r14,4
  ADD r3,r3,r13
  ST r3,r14,4
  JMP @nkcam_l
nkcam_count:
  LD r1,r14,1
  LD r2,r1,#NKCS_SB_COUNT
  LD r3,r14,3
  CMP r2,r3
  JMP[NE] @nkcam_corrupt
  ; copy persistent counters into volatile stats
  LA r4,#NKCS_STATS
  LD r5,r1,#NKCS_SB_COUNT
  ST r5,r4,#NKCS_G_LIVE
  LD r5,r1,#NKCS_SB_SEQ
  ST r5,r4,#NKCS_G_SEQ
  LD r5,r1,#NKCS_SB_PUTS
  ST r5,r4,#NKCS_G_PUTS
  LD r5,r1,#NKCS_SB_DEDUP
  ST r5,r4,#NKCS_G_DEDUP
  LD r5,r1,#NKCS_SB_WRITTEN
  ST r5,r4,#NKCS_G_WRITTEN
  LD r5,r1,#NKCS_SB_AVOID
  ST r5,r4,#NKCS_G_AVOID
  LD r5,r1,#NKCS_SB_DELS
  ST r5,r4,#NKCS_G_DELS
  ; mount count
  LD r5,r1,#NKCS_SB_MOUNTS
  ADD r5,r5,r13
  ST r5,r1,#NKCS_SB_MOUNTS
  ST r5,r4,#NKCS_G_MOUNTS
  CALL @nkcas_sb_seal
  LA r2,#NKCS_MOUNTED
  ST r13,r2,0
  MOVI r1,#NKCS_T_MOUNT
  LD r2,r14,1
  LD r3,r14,2
  LD r4,r14,3
  MOVI r5,0
  CALL @nkcas_trace_add
  MOVI r1,0
  JMP @nkcam_out
nkcam_store:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_STORE
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_STORE
  MOVI r1,#NKCS_ESTORE
  CALL @nkcas_err
  MOVI r1,#NKCS_ESTORE
  JMP @nkcam_out
nkcam_corrupt:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_CORRUPT
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_CORRUPT
  MOVI r1,#NKCS_ECORRUPT
  CALL @nkcas_err
  MOVI r1,#NKCS_ECORRUPT
  JMP @nkcam_out
nkcam_bad:
  MOVI r1,#NKCS_EBAD
  CALL @nkcas_err
  MOVI r1,#NKCS_EBAD
nkcam_ret:
nkcam_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_cold_restart -> 0.  Clears only volatile directory, stats and trace.
nkcas_cold:
  ST r15,r14,0
  ADDI r14,r14,16
  LA r1,#NKCS_DIR
  MOVI r2,#NKCS_DIRWORDS
  BFILL r1,r0,r2
  LA r1,#NKCS_DIRN
  ST r0,r1,0
  LA r1,#NKCS_STATS
  MOVI r2,#NKCS_SW
  BFILL r1,r0,r2
  LA r1,#NKCS_TRACE
  MOVI r2,#NKCS_TRACE_TOTAL
  BFILL r1,r0,r2
  LA r1,#NKCS_BASE
  ST r0,r1,0
  LA r1,#NKCS_CAP
  ST r0,r1,0
  LA r1,#NKCS_MOUNTED
  ST r0,r1,0
  MOVI r1,0
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_put_record r1=record(48) -> slot / NONE.
nkcas_put_record:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  LA r2,#NKCS_MOUNTED
  LD r2,r2,0
  CMP r2,r0
  JMP[EQ] @nkcpr_bad
  LD r1,r14,1
  CMP r1,r0
  JMP[EQ] @nkcpr_bad
  LD r2,r1,#NKCS_R_MAGIC
  LA r3,#NKCS_RMAGIC
  CMP r2,r3
  JMP[NE] @nkcpr_bad
  LD r2,r1,#NKCS_R_VERSION
  MOVI r3,#NKM_VERSION
  CMP r2,r3
  JMP[NE] @nkcpr_bad
  LD r3,r1,#NKCS_R_USED
  CMP r3,r0
  JMP[EQ] @nkcpr_bad
  MOVI r4,#NKM_SLOTS
  CMP r3,r4
  JMP[GT] @nkcpr_bad
  LD r4,r1,#NKCS_R_PCOUNT
  MOVI r5,4
  CMP r4,r5
  JMP[GT] @nkcpr_bad
  ; incoming checksum must be valid
  CALL @nkcas_checksum
  ST r1,r14,2
  LD r2,r14,1
  LD r2,r2,#NKCS_R_SUM
  CMP r1,r2
  JMP[NE] @nkcpr_corrupt
  ; find key
  LD r4,r14,1
  LD r1,r4,#NKCS_R_HLO
  LD r2,r4,#NKCS_R_HHI
  CALL @nkcas_find
  LA r2,#NKCS_NONE
  CMP r1,r2
  JMP[EQ] @nkcpr_new
  ST r1,r14,3
  CALL @nkcas_recptr
  CMP r1,r0
  JMP[EQ] @nkcpr_corrupt
  ST r1,r14,4
  LD r1,r14,4
  CALL @nkcas_record_valid
  CMP r1,r0
  JMP[EQ] @nkcpr_corrupt
  LD r1,r14,3
  LD r2,r14,1
  CALL @nkcas_record_same
  CMP r1,r0
  JMP[EQ] @nkcpr_coll
  ; dedup: no rewrite
  LD r1,r14,4
  LD r2,r1,#NKCS_R_DEDUP
  ADD r2,r2,r13
  ST r2,r1,#NKCS_R_DEDUP
  LA r2,#NKCS_BASE
  LD r2,r2,0
  LD r3,r2,#NKCS_SB_DEDUP
  ADD r3,r3,r13
  ST r3,r2,#NKCS_SB_DEDUP
  LD r3,r2,#NKCS_SB_AVOID
  ADDI r3,r3,#NKCS_REC_BYTES
  ST r3,r2,#NKCS_SB_AVOID
  CALL @nkcas_sb_seal
  LA r3,#NKCS_STATS
  LD r4,r3,#NKCS_G_DEDUP
  ADD r4,r4,r13
  ST r4,r3,#NKCS_G_DEDUP
  LD r4,r3,#NKCS_G_AVOID
  ADDI r4,r4,#NKCS_REC_BYTES
  ST r4,r3,#NKCS_G_AVOID
  LD r4,r3,#NKCS_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKCS_G_OPS
  LD r1,r14,3
  ST r1,r14,5
  MOVI r1,#NKCS_T_DEDUP
  LD r2,r14,1
  LD r2,r2,#NKCS_R_HLO
  LD r3,r14,1
  LD r3,r3,#NKCS_R_HHI
  LD r4,r14,3
  MOVI r5,0
  CALL @nkcas_trace_add
  LD r1,r14,5
  JMP @nkcpr_out
nkcpr_new:
  ; find a free slot
  ST r0,r14,3
nkcpr_sl:
  LD r3,r14,3
  LA r2,#NKCS_CAP
  LD r2,r2,0
  CMP r3,r2
  JMP[GE] @nkcpr_full
  LD r1,r14,3
  CALL @nkcas_recptr
  CMP r1,r0
  JMP[EQ] @nkcpr_sbad
  LD r2,r1,#NKCS_R_STATE
  CMP r2,r0
  JMP[EQ] @nkcpr_have
  LD r3,r14,3
  ADD r3,r3,r13
  ST r3,r14,3
  JMP @nkcpr_sl
nkcpr_have:
  ST r1,r14,4
  ; copy record into the slot
  LD r1,r14,4
  LD r2,r14,1
  MOVI r3,#NKCS_R_WORDS
  BCOPY r1,r2,r3
  ; force live identity fields / new sequence
  LD r1,r14,4
  LA r2,#NKCS_RMAGIC
  ST r2,r1,#NKCS_R_MAGIC
  MOVI r2,#NKM_VERSION
  ST r2,r1,#NKCS_R_VERSION
  ST r13,r1,#NKCS_R_STATE
  ST r0,r1,#NKCS_R_DEDUP
  MOVI r2,#NKCS_REC_BYTES
  ST r2,r1,#NKCS_R_SIZE
  LA r2,#NKCS_BASE
  LD r2,r2,0
  LD r3,r2,#NKCS_SB_SEQ
  ST r3,r1,#NKCS_R_SEQ
  ; recompute checksum after the copy
  LD r1,r14,4
  CALL @nkcas_checksum
  LD r2,r14,4
  ST r1,r2,#NKCS_R_SUM
  ; directory
  LD r1,r14,3
  CALL @nkcas_dir_add
  CMP r1,r0
  JMP[NE] @nkcpr_out
  ; persistent counters
  LA r2,#NKCS_BASE
  LD r2,r2,0
  LD r3,r2,#NKCS_SB_COUNT
  ADD r3,r3,r13
  ST r3,r2,#NKCS_SB_COUNT
  LD r3,r2,#NKCS_SB_PUTS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_SB_PUTS
  LD r3,r2,#NKCS_SB_SEQ
  ADD r3,r3,r13
  ST r3,r2,#NKCS_SB_SEQ
  LD r3,r2,#NKCS_SB_WRITTEN
  ADDI r3,r3,#NKCS_REC_BYTES
  ST r3,r2,#NKCS_SB_WRITTEN
  CALL @nkcas_sb_seal
  ; volatile counters
  LA r3,#NKCS_STATS
  LD r4,r3,#NKCS_G_LIVE
  ADD r4,r4,r13
  ST r4,r3,#NKCS_G_LIVE
  LD r4,r3,#NKCS_G_PUTS
  ADD r4,r4,r13
  ST r4,r3,#NKCS_G_PUTS
  LD r4,r3,#NKCS_G_WRITTEN
  ADDI r4,r4,#NKCS_REC_BYTES
  ST r4,r3,#NKCS_G_WRITTEN
  LD r4,r3,#NKCS_G_SEQ
  ADD r4,r4,r13
  ST r4,r3,#NKCS_G_SEQ
  LD r4,r3,#NKCS_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKCS_G_OPS
  MOVI r1,#NKCS_T_PUT
  LD r2,r14,1
  LD r2,r2,#NKCS_R_HLO
  LD r3,r14,1
  LD r3,r3,#NKCS_R_HHI
  LD r4,r14,3
  MOVI r5,0
  CALL @nkcas_trace_add
  LD r1,r14,3
  JMP @nkcpr_out
nkcpr_full:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_NOSPC
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_NOSPC
  MOVI r1,#NKCS_ENOSPC
  CALL @nkcas_err
  LA r1,#NKCS_NONE
  JMP @nkcpr_out
nkcpr_coll:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_COLL
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_COLL
  MOVI r1,#NKCS_ECOLL
  CALL @nkcas_err
  LA r1,#NKCS_NONE
  JMP @nkcpr_out
nkcpr_corrupt:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_CORRUPT
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_CORRUPT
  MOVI r1,#NKCS_ECORRUPT
  CALL @nkcas_err
  LA r1,#NKCS_NONE
  JMP @nkcpr_out
nkcpr_sbad:
  MOVI r1,#NKCS_EBAD
  CALL @nkcas_err
  LA r1,#NKCS_NONE
  JMP @nkcpr_out
nkcpr_bad:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_BAD
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_BAD
  MOVI r1,#NKCS_EBAD
  CALL @nkcas_err
  LA r1,#NKCS_NONE
nkcpr_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_put r1=hlo r2=hhi r3=values r4=used r5=gen r6=parents r7=pcount
;          -> slot / NONE.
nkcas_put:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  ST r7,r14,7
  CMP r4,r0
  JMP[EQ] @nkcpu_bad
  MOVI r8,#NKM_SLOTS
  CMP r4,r8
  JMP[GT] @nkcpu_bad
  CMP r7,r0
  JMP[EQ] @nkcpu_pok
  MOVI r8,4
  CMP r7,r8
  JMP[GT] @nkcpu_bad
  CMP r6,r0
  JMP[EQ] @nkcpu_bad
nkcpu_pok:
  CMP r3,r0
  JMP[EQ] @nkcpu_bad
  ; build temporary record
  LA r1,#NKCS_TMP
  MOVI r2,#NKCS_R_WORDS
  BFILL r1,r0,r2
  LA r1,#NKCS_TMP
  LA r2,#NKCS_RMAGIC
  ST r2,r1,#NKCS_R_MAGIC
  MOVI r2,#NKM_VERSION
  ST r2,r1,#NKCS_R_VERSION
  ST r13,r1,#NKCS_R_STATE
  LD r2,r14,1
  ST r2,r1,#NKCS_R_HLO
  LD r2,r14,2
  ST r2,r1,#NKCS_R_HHI
  LD r2,r14,4
  ST r2,r1,#NKCS_R_USED
  LD r2,r14,5
  ST r2,r1,#NKCS_R_GEN
  LD r2,r14,7
  ST r2,r1,#NKCS_R_PCOUNT
  ST r13,r1,#NKCS_R_FLAGS
  MOVI r2,#NKCS_REC_BYTES
  ST r2,r1,#NKCS_R_SIZE
  ; copy parents (4 lo then 4 hi)
  ST r0,r14,8
nkcpu_pl:
  LD r2,r14,8
  LD r3,r14,7
  CMP r2,r3
  JMP[GE] @nkcpu_vals
  LD r1,r14,6
  ADD r1,r1,r2
  LD r3,r1,0
  LA r1,#NKCS_TMP
  ADD r1,r1,r2
  ST r3,r1,#NKCS_R_PLO
  LD r1,r14,6
  ADDI r1,r1,4
  ADD r1,r1,r2
  LD r3,r1,0
  LA r1,#NKCS_TMP
  ADD r1,r1,r2
  ST r3,r1,#NKCS_R_PHI
  LD r2,r14,8
  ADD r2,r2,r13
  ST r2,r14,8
  JMP @nkcpu_pl
nkcpu_vals:
  ST r0,r14,8
nkcpu_vl:
  LD r2,r14,8
  LD r3,r14,4
  CMP r2,r3
  JMP[GE] @nkcpu_seal
  LD r1,r14,3
  ADD r1,r1,r2
  LD r3,r1,0
  LA r1,#NKCS_TMP
  ADDI r1,r1,#NKCS_R_PAY
  ADD r1,r1,r2
  ST r3,r1,0
  LD r2,r14,8
  ADD r2,r2,r13
  ST r2,r14,8
  JMP @nkcpu_vl
nkcpu_seal:
  LA r1,#NKCS_TMP
  CALL @nkcas_checksum
  LA r2,#NKCS_TMP
  ST r1,r2,#NKCS_R_SUM
  LA r1,#NKCS_TMP
  CALL @nkcas_put_record
  JMP @nkcpu_out
nkcpu_bad:
  MOVI r1,#NKCS_EBAD
  CALL @nkcas_err
  LA r1,#NKCS_NONE
nkcpu_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_capture r1=public node index -> slot / NONE.
nkcas_capture:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  MOVI r2,#NKM_MAXNODE
  CMP r1,r2
  JMP[GE] @nkcc_bad
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkcc_bad
  ST r1,r14,2
  LD r2,r1,#NKM_N_STATE
  CMP r2,r13
  JMP[NE] @nkcc_bad
  LD r2,r1,#NKM_N_KIND
  MOVI r3,#NKM_K_PUBLIC
  CMP r2,r3
  JMP[NE] @nkcc_bad
  LA r3,#NKCS_TMP
  MOVI r4,#NKCS_R_WORDS
  BFILL r3,r0,r4
  LA r3,#NKCS_TMP
  LA r4,#NKCS_RMAGIC
  ST r4,r3,#NKCS_R_MAGIC
  MOVI r4,#NKM_VERSION
  ST r4,r3,#NKCS_R_VERSION
  ST r13,r3,#NKCS_R_STATE
  LD r4,r1,#NKM_N_HLO
  ST r4,r3,#NKCS_R_HLO
  LD r4,r1,#NKM_N_HHI
  ST r4,r3,#NKCS_R_HHI
  LD r4,r1,#NKM_N_USED
  ST r4,r3,#NKCS_R_USED
  LD r4,r1,#NKM_N_BGEN
  ST r4,r3,#NKCS_R_GEN
  LD r4,r1,#NKM_N_PCOUNT
  ST r4,r3,#NKCS_R_PCOUNT
  LD r4,r1,#NKM_N_OWNER
  ST r4,r3,#NKCS_R_OWNER
  MOVI r4,#NKCS_REC_BYTES
  ST r4,r3,#NKCS_R_SIZE
  ; parents
  ST r0,r14,3
nkcc_pl:
  LD r3,r14,3
  LD r1,r14,2
  LD r4,r1,#NKM_N_PCOUNT
  CMP r3,r4
  JMP[GE] @nkcc_pay
  ADD r4,r1,r3
  LD r4,r4,#NKM_N_PHLO
  LA r5,#NKCS_TMP
  ADD r5,r5,r3
  ST r4,r5,#NKCS_R_PLO
  ADD r4,r1,r3
  LD r4,r4,#NKM_N_PHHI
  LA r5,#NKCS_TMP
  ADD r5,r5,r3
  ST r4,r5,#NKCS_R_PHI
  LD r3,r14,3
  ADD r3,r3,r13
  ST r3,r14,3
  JMP @nkcc_pl
nkcc_pay:
  ; payload base = NKM stats buffer + index*16
  LA r4,#NKM_STATS
  LD r4,r4,#NKM_G_BUFFER
  LD r5,r14,1
  SHL r5,r5,4
  ADD r4,r4,r5
  ST r4,r14,4
  ST r0,r14,3
nkcc_vl:
  LD r3,r14,3
  LD r1,r14,2
  LD r4,r1,#NKM_N_USED
  CMP r3,r4
  JMP[GE] @nkcc_seal
  LD r4,r14,4
  ADD r4,r4,r3
  LD r4,r4,0
  LA r5,#NKCS_TMP
  ADDI r5,r5,#NKCS_R_PAY
  ADD r5,r5,r3
  ST r4,r5,0
  LD r3,r14,3
  ADD r3,r3,r13
  ST r3,r14,3
  JMP @nkcc_vl
nkcc_seal:
  LA r1,#NKCS_TMP
  CALL @nkcas_checksum
  LA r2,#NKCS_TMP
  ST r1,r2,#NKCS_R_SUM
  LA r1,#NKCS_TMP
  CALL @nkcas_put_record
  JMP @nkcc_out
nkcc_bad:
  MOVI r1,#NKCS_EBAD
  CALL @nkcas_err
  LA r1,#NKCS_NONE
nkcc_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_get r1=hlo r2=hhi r3=out(48) -> 0/err.
nkcas_get:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CMP r3,r0
  JMP[EQ] @nkcg_bad
  CALL @nkcas_find
  LA r2,#NKCS_NONE
  CMP r1,r2
  JMP[EQ] @nkcg_miss
  ST r1,r14,4
  CALL @nkcas_recptr
  CMP r1,r0
  JMP[EQ] @nkcg_corrupt
  ST r1,r14,5
  CALL @nkcas_record_valid
  CMP r1,r0
  JMP[EQ] @nkcg_corrupt
  LD r1,r14,3
  LD r2,r14,5
  MOVI r3,#NKCS_R_WORDS
  BCOPY r1,r2,r3
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_GETS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_GETS
  LD r3,r2,#NKCS_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_OPS
  MOVI r1,#NKCS_T_GET
  LD r2,r14,1
  LD r3,r14,2
  LD r4,r14,4
  MOVI r5,0
  CALL @nkcas_trace_add
  MOVI r1,0
  JMP @nkcg_out
nkcg_miss:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_MISS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_MISS
  MOVI r1,#NKCS_ENOENT
  CALL @nkcas_err
  MOVI r1,#NKCS_ENOENT
  JMP @nkcg_out
nkcg_corrupt:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_CORRUPT
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_CORRUPT
  MOVI r1,#NKCS_ECORRUPT
  CALL @nkcas_err
  MOVI r1,#NKCS_ECORRUPT
  JMP @nkcg_out
nkcg_bad:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_BAD
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_BAD
  MOVI r1,#NKCS_EBAD
  CALL @nkcas_err
  MOVI r1,#NKCS_EBAD
nkcg_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_delete r1=hlo r2=hhi -> 0/err.
nkcas_delete:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r1,r14,1
  ST r2,r14,2
  CALL @nkcas_find
  LA r2,#NKCS_NONE
  CMP r1,r2
  JMP[EQ] @nkcde_miss
  ST r1,r14,3
  CALL @nkcas_recptr
  CMP r1,r0
  JMP[EQ] @nkcde_corrupt
  ST r1,r14,4
  CALL @nkcas_record_valid
  CMP r1,r0
  JMP[EQ] @nkcde_corrupt
  LD r1,r14,4
  MOVI r2,#NKCS_R_WORDS
  BFILL r1,r0,r2
  LD r1,r14,3
  CALL @nkcas_dir_del
  LA r2,#NKCS_BASE
  LD r2,r2,0
  LD r3,r2,#NKCS_SB_COUNT
  SUB r3,r3,r13
  ST r3,r2,#NKCS_SB_COUNT
  LD r3,r2,#NKCS_SB_DELS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_SB_DELS
  CALL @nkcas_sb_seal
  LA r3,#NKCS_STATS
  LD r4,r3,#NKCS_G_LIVE
  SUB r4,r4,r13
  ST r4,r3,#NKCS_G_LIVE
  LD r4,r3,#NKCS_G_DELS
  ADD r4,r4,r13
  ST r4,r3,#NKCS_G_DELS
  LD r4,r3,#NKCS_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKCS_G_OPS
  MOVI r1,#NKCS_T_DEL
  LD r2,r14,1
  LD r3,r14,2
  LD r4,r14,3
  MOVI r5,0
  CALL @nkcas_trace_add
  MOVI r1,0
  JMP @nkcde_out
nkcde_miss:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_MISS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_MISS
  MOVI r1,#NKCS_ENOENT
  CALL @nkcas_err
  MOVI r1,#NKCS_ENOENT
  JMP @nkcde_out
nkcde_corrupt:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_CORRUPT
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_CORRUPT
  MOVI r1,#NKCS_ECORRUPT
  CALL @nkcas_err
  MOVI r1,#NKCS_ECORRUPT
nkcde_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_walk r1=slot r2=list r3=count ptr r4=depth -> 0/err.
; Parents-first unique closure.  A missing parent is EMISS; a cycle hits the
; depth bound and fails EMISS.
nkcas_walk:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  MOVI r5,#NKCS_MAXNODE
  CMP r4,r5
  JMP[GE] @nkcw_miss
  LD r1,r14,1
  CALL @nkcas_recptr
  CMP r1,r0
  JMP[EQ] @nkcw_corrupt
  ST r1,r14,5
  CALL @nkcas_record_valid
  CMP r1,r0
  JMP[EQ] @nkcw_corrupt
  ; already listed?
  LD r2,r14,3
  LD r2,r2,0
  ST r2,r14,6
  ST r0,r14,7
nkcw_seen:
  LD r3,r14,7
  LD r4,r14,6
  CMP r3,r4
  JMP[GE] @nkcw_parents
  LD r2,r14,2
  ADD r2,r2,r3
  LD r2,r2,0
  LD r5,r14,1
  CMP r2,r5
  JMP[EQ] @nkcw_ok
  LD r3,r14,7
  ADD r3,r3,r13
  ST r3,r14,7
  JMP @nkcw_seen
nkcw_parents:
  ST r0,r14,7
nkcw_pl:
  LD r3,r14,7
  LD r1,r14,5
  LD r4,r1,#NKCS_R_PCOUNT
  CMP r3,r4
  JMP[GE] @nkcw_append
  ADD r2,r1,r3
  LD r1,r2,#NKCS_R_PLO
  LD r2,r14,5
  ADD r2,r2,r3
  LD r2,r2,#NKCS_R_PHI
  CALL @nkcas_find
  LA r2,#NKCS_NONE
  CMP r1,r2
  JMP[EQ] @nkcw_miss
  LD r2,r14,2
  LD r3,r14,3
  LD r4,r14,4
  ADD r4,r4,r13
  CALL @nkcas_walk
  CMP r1,r0
  JMP[NE] @nkcw_out
  LD r3,r14,7
  ADD r3,r3,r13
  ST r3,r14,7
  JMP @nkcw_pl
nkcw_append:
  LD r2,r14,3
  LD r2,r2,0
  LD r3,r14,2
  LD r4,r14,1
  ADD r3,r3,r2
  ST r4,r3,0
  ADD r2,r2,r13
  LD r3,r14,3
  ST r2,r3,0
  MOVI r1,0
  JMP @nkcw_out
nkcw_ok:
  MOVI r1,0
  JMP @nkcw_out
nkcw_miss:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_MISS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_MISS
  MOVI r1,#NKCS_EMISS
  CALL @nkcas_err
  MOVI r1,#NKCS_EMISS
  JMP @nkcw_out
nkcw_corrupt:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_CORRUPT
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_CORRUPT
  MOVI r1,#NKCS_ECORRUPT
  CALL @nkcas_err
  MOVI r1,#NKCS_ECORRUPT
nkcw_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_hydrate r1=root lo r2=root hi r3=page out r4=token out
;                -> token count / NONE.
nkcas_hydrate:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  CMP r3,r0
  JMP[EQ] @nkch_bad
  CALL @nkcas_find
  LA r2,#NKCS_NONE
  CMP r1,r2
  JMP[EQ] @nkch_miss
  ST r1,r14,5
  LA r2,#NKCS_LIST
  MOVI r3,#NKCS_MAXNODE
  BFILL r2,r0,r3
  LA r2,#NKCS_LISTN
  ST r0,r2,0
  LD r1,r14,5
  LA r2,#NKCS_LIST
  LA r3,#NKCS_LISTN
  MOVI r4,0
  CALL @nkcas_walk
  CMP r1,r0
  JMP[NE] @nkch_err
  LA r2,#NKCS_LISTN
  LD r2,r2,0
  ST r2,r14,6
  CMP r2,r0
  JMP[EQ] @nkch_miss
  ; fill page header
  LD r1,r14,3
  MOVI r2,132
  BFILL r1,r0,r2
  LD r1,r14,3
  LD r2,r14,6
  ST r2,r1,0
  ST r0,r1,1
  ST r0,r1,2
  LD r2,r14,5
  ST r2,r1,3
  ; pages/tokens
  ST r0,r14,7          ; index
  ST r0,r14,8          ; token running offset
nkch_l:
  LD r2,r14,7
  LD r3,r14,6
  CMP r2,r3
  JMP[GE] @nkch_done
  LA r4,#NKCS_LIST
  ADD r4,r4,r2
  LD r1,r4,0
  ST r1,r14,9
  CALL @nkcas_recptr
  CMP r1,r0
  JMP[EQ] @nkch_corrupt
  ST r1,r14,10
  CALL @nkcas_record_valid
  CMP r1,r0
  JMP[EQ] @nkch_corrupt
  ; page entry at out + 4 + i*4
  LD r1,r14,3
  LD r2,r14,7
  SHL r2,r2,2
  ADDI r1,r1,#NKCS_PAGEHDR
  ADD r1,r1,r2
  LD r2,r14,9
  ST r2,r1,0
  LD r3,r14,10
  LD r4,r3,#NKCS_R_HLO
  ST r4,r1,1
  LD r4,r3,#NKCS_R_HHI
  ST r4,r1,2
  LD r4,r3,#NKCS_R_USED
  ST r4,r1,3
  ; copy payload to token out
  LD r4,r14,4
  CMP r4,r0
  JMP[EQ] @nkch_count
  LD r5,r14,8
  ADD r4,r4,r5
  LD r2,r14,10
  ADDI r2,r2,#NKCS_R_PAY
  LD r5,r14,10
  LD r5,r5,#NKCS_R_USED
  BCOPY r4,r2,r5
nkch_count:
  LD r3,r14,10
  LD r4,r3,#NKCS_R_USED
  LD r5,r14,8
  ADD r5,r5,r4
  ST r5,r14,8
  LD r2,r14,7
  ADD r2,r2,r13
  ST r2,r14,7
  JMP @nkch_l
nkch_done:
  LD r1,r14,3
  LD r2,r14,6
  ST r2,r1,0
  LD r2,r14,8
  ST r2,r1,1
  LD r3,r14,6
  ST r3,r1,2
  LD r3,r14,5
  ST r3,r1,3
  ; stats
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_HYDRATES
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_HYDRATES
  LD r3,r2,#NKCS_G_HNODES
  LD r4,r14,6
  ADD r3,r3,r4
  ST r3,r2,#NKCS_G_HNODES
  LD r3,r2,#NKCS_G_HTOKENS
  LD r4,r14,8
  ADD r3,r3,r4
  ST r3,r2,#NKCS_G_HTOKENS
  LD r3,r2,#NKCS_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_OPS
  MOVI r1,#NKCS_T_HYDRATE
  LD r2,r14,1
  LD r3,r14,2
  LD r4,r14,6
  LD r5,r14,8
  CALL @nkcas_trace_add
  LD r1,r14,8
  JMP @nkch_out
nkch_miss:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_MISS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_MISS
  MOVI r1,#NKCS_ENOENT
  CALL @nkcas_err
  LA r1,#NKCS_NONE
  JMP @nkch_out
nkch_corrupt:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_CORRUPT
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_CORRUPT
  MOVI r1,#NKCS_ECORRUPT
  CALL @nkcas_err
  LA r1,#NKCS_NONE
  JMP @nkch_out
nkch_err:
  LA r1,#NKCS_NONE
  JMP @nkch_out
nkch_bad:
  MOVI r1,#NKCS_EBAD
  CALL @nkcas_err
  LA r1,#NKCS_NONE
nkch_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_dfs r1=slot r2=depth -> 1/0.  Path root..target in NKCS_PATH.
nkcas_dfs:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  CALL @nkcas_recptr
  CMP r1,r0
  JMP[EQ] @nkcdfs_corrupt
  ST r1,r14,3
  CALL @nkcas_record_valid
  CMP r1,r0
  JMP[EQ] @nkcdfs_corrupt
  LD r1,r14,1
  LA r2,#NKCS_DFS_TARGET
  LD r2,r2,0
  CMP r1,r2
  JMP[NE] @nkcdfs_deeper
  LA r2,#NKCS_PATH
  LD r3,r14,2
  ADD r2,r2,r3
  ST r1,r2,0
  ADD r3,r3,r13
  LA r2,#NKCS_DFS_DEPTH
  ST r3,r2,0
  MOVI r1,1
  JMP @nkcdfs_out
nkcdfs_deeper:
  LD r2,r14,2
  MOVI r3,#NKCS_PROOF_MAX-1
  CMP r2,r3
  JMP[GE] @nkcdfs_no
  LA r3,#NKCS_PATH
  ADD r3,r3,r2
  ST r1,r3,0
  ST r0,r14,4
nkcdfs_pl:
  LD r3,r14,4
  LD r1,r14,3
  LD r2,r1,#NKCS_R_PCOUNT
  CMP r3,r2
  JMP[GE] @nkcdfs_no
  ADD r1,r1,r3
  LD r1,r1,#NKCS_R_PLO
  LD r2,r14,3
  ADD r2,r2,r3
  LD r2,r2,#NKCS_R_PHI
  CALL @nkcas_find
  LA r2,#NKCS_NONE
  CMP r1,r2
  JMP[EQ] @nkcdfs_miss
  LD r2,r14,2
  ADD r2,r2,r13
  CALL @nkcas_dfs
  CMP r1,r0
  JMP[NE] @nkcdfs_out
  LD r3,r14,4
  ADD r3,r3,r13
  ST r3,r14,4
  JMP @nkcdfs_pl
nkcdfs_no:
  MOVI r1,0
  JMP @nkcdfs_out
nkcdfs_miss:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_MISS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_MISS
  MOVI r1,#NKCS_EMISS
  CALL @nkcas_err
  MOVI r1,0
  JMP @nkcdfs_out
nkcdfs_corrupt:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_CORRUPT
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_CORRUPT
  MOVI r1,#NKCS_ECORRUPT
  CALL @nkcas_err
  MOVI r1,0
nkcdfs_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_proof r1=root lo r2=root hi r3=target lo r4=target hi
;             r5=token offset / NONE r6=proof out -> depth / 0.
nkcas_proof:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  CMP r6,r0
  JMP[EQ] @nkcprf_bad
  LD r1,r14,1
  LD r2,r14,2
  CALL @nkcas_find
  LA r2,#NKCS_NONE
  CMP r1,r2
  JMP[EQ] @nkcprf_miss
  ST r1,r14,7
  LD r1,r14,3
  LD r2,r14,4
  CALL @nkcas_find
  LA r2,#NKCS_NONE
  CMP r1,r2
  JMP[EQ] @nkcprf_miss
  ST r1,r14,8
  ; target record for header
  CALL @nkcas_recptr
  CMP r1,r0
  JMP[EQ] @nkcprf_corrupt
  ST r1,r14,9
  CALL @nkcas_record_valid
  CMP r1,r0
  JMP[EQ] @nkcprf_corrupt
  LD r1,r14,9
  LD r2,r1,#NKCS_R_USED
  ST r2,r14,10
  LD r2,r1,#NKCS_R_GEN
  ST r2,r14,11
  ; token pre-check
  MOVI r4,1
  ST r4,r14,12
  LA r4,#NKCS_NONE
  ST r4,r14,13
  ST r0,r14,14
  LD r3,r14,5
  CMP r3,r4
  JMP[EQ] @nkcprf_dfs
  MOVI r4,2
  ST r4,r14,12
  LD r4,r14,10
  CMP r3,r4
  JMP[GE] @nkcprf_bad
  ST r3,r14,13
  LD r1,r14,9
  ADDI r1,r1,#NKCS_R_PAY
  ADD r1,r1,r3
  LD r1,r1,0
  ST r1,r14,14
nkcprf_dfs:
  LA r1,#NKCS_DFS_TARGET
  LD r2,r14,8
  ST r2,r1,0
  LA r1,#NKCS_DFS_DEPTH
  ST r0,r1,0
  LA r1,#NKCS_DFS_OK
  ST r0,r1,0
  LA r1,#NKCS_PATH
  MOVI r2,#NKCS_PROOF_MAX
  BFILL r1,r0,r2
  LD r1,r14,7
  MOVI r2,0
  CALL @nkcas_dfs
  CMP r1,r0
  JMP[EQ] @nkcprf_chain
  LA r1,#NKCS_DFS_DEPTH
  LD r1,r1,0
  ST r1,r14,15
  ; header
  LD r1,r14,6
  MOVI r2,#NKCS_PENTRY
  BFILL r1,r0,r2
  LD r1,r14,6
  LA r2,#NKM_PMAGIC
  ST r2,r1,#NKM_P_MAGIC
  MOVI r2,#NKM_VERSION
  ST r2,r1,#NKM_P_VERSION
  LD r2,r14,15
  ST r2,r1,#NKM_P_DEPTH
  LD r2,r14,12
  ST r2,r1,#NKM_P_MODE
  LD r2,r14,13
  ST r2,r1,#NKM_P_TOKOFF
  LD r2,r14,14
  ST r2,r1,#NKM_P_TOKVAL
  LD r2,r14,1
  ST r2,r1,#NKM_P_ROOTLO
  LD r2,r14,2
  ST r2,r1,#NKM_P_ROOTHI
  LD r2,r14,3
  ST r2,r1,#NKM_P_TARGLO
  LD r2,r14,4
  ST r2,r1,#NKM_P_TARGHI
  LD r2,r14,10
  ST r2,r1,#NKM_P_USED
  LD r2,r14,11
  ST r2,r1,#NKM_P_GEN
  MOVI r2,1
  ST r2,r1,#NKM_P_FLAGS
  ; entries target..root
  ST r0,r14,16
nkcprf_el:
  LD r2,r14,16
  LD r3,r14,15
  CMP r2,r3
  JMP[GE] @nkcprf_done
  SUB r3,r3,r13
  SUB r3,r3,r2
  LA r4,#NKCS_PATH
  ADD r4,r4,r3
  LD r4,r4,0
  ST r4,r14,17
  ADD r1,r4,r0
  CALL @nkcas_recptr
  CMP r1,r0
  JMP[EQ] @nkcprf_corrupt
  ST r1,r14,18
  CALL @nkcas_record_valid
  CMP r1,r0
  JMP[EQ] @nkcprf_corrupt
  ; entry address = out + 16 + i*32
  LD r2,r14,16
  SHL r2,r2,5
  LD r1,r14,6
  ADDI r1,r1,#NKM_PENTRY
  ADD r1,r1,r2
  ST r1,r14,19
  MOVI r2,#NKM_PESTRIDE
  BFILL r1,r0,r2
  LD r1,r14,18
  LD r3,r14,19
  LD r2,r1,#NKCS_R_USED
  ST r2,r3,#NKM_PE_USED
  LD r2,r1,#NKCS_R_GEN
  ST r2,r3,#NKM_PE_GEN
  LD r2,r1,#NKCS_R_PCOUNT
  ST r2,r3,#NKM_PE_PCOUNT
  ST r0,r14,20
nkcprf_ph:
  LD r2,r14,20
  LD r1,r14,18
  LD r3,r1,#NKCS_R_PCOUNT
  CMP r2,r3
  JMP[GE] @nkcprf_pc
  ADD r4,r1,r2
  LD r4,r4,#NKCS_R_PLO
  LD r5,r14,19
  ADD r5,r5,r2
  ST r4,r5,#NKM_PE_PLO
  LD r1,r14,18
  ADD r4,r1,r2
  LD r4,r4,#NKCS_R_PHI
  ADD r5,r5,r0
  ST r4,r5,#NKM_PE_PHI
  LD r2,r14,20
  ADD r2,r2,r13
  ST r2,r14,20
  JMP @nkcprf_ph
nkcprf_pc:
  LD r2,r14,18
  ADDI r2,r2,#NKCS_R_PAY
  LD r4,r14,19
  MOVI r5,#NKM_PESTRIDE
  ST r0,r14,20
nkcprf_cc:
  LD r3,r14,20
  LD r1,r14,18
  LD r1,r1,#NKCS_R_USED
  CMP r3,r1
  JMP[GE] @nkcprf_hs
  ADD r1,r2,r3
  LD r1,r1,0
  ADD r6,r4,r3
  ST r1,r6,#NKM_PE_CONTENT
  LD r3,r14,20
  ADD r3,r3,r13
  ST r3,r14,20
  JMP @nkcprf_cc
nkcprf_hs:
  LD r1,r14,18
  LD r2,r1,#NKCS_R_HLO
  LD r3,r14,19
  ST r2,r3,#NKM_PE_HLO
  LD r2,r1,#NKCS_R_HHI
  ST r2,r3,#NKM_PE_HHI
  MOVI r2,1
  ST r2,r3,#NKM_PE_FLAGS
  LD r2,r14,16
  ADD r2,r2,r13
  ST r2,r14,16
  JMP @nkcprf_el
nkcprf_done:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_PROOFS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_PROOFS
  LD r3,r2,#NKCS_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_OPS
  MOVI r1,#NKCS_T_PROOF
  LD r2,r14,1
  LD r3,r14,2
  LD r4,r14,15
  LD r5,r14,13
  CALL @nkcas_trace_add
  LD r1,r14,15
  JMP @nkcprf_out
nkcprf_miss:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_MISS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_MISS
  MOVI r1,#NKCS_ENOENT
  CALL @nkcas_err
  MOVI r1,0
  JMP @nkcprf_out
nkcprf_chain:
  MOVI r1,#NKCS_EMISS
  CALL @nkcas_err
  MOVI r1,0
  JMP @nkcprf_out
nkcprf_corrupt:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_CORRUPT
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_CORRUPT
  MOVI r1,#NKCS_ECORRUPT
  CALL @nkcas_err
nkcprf_bad:
  MOVI r1,#NKCS_EBAD
  CALL @nkcas_err
  MOVI r1,0
nkcprf_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_verify r1=root lo r2=root hi r3=proof -> 1/0.
nkcas_verify:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @nkm_proof_verify
  CMP r1,r0
  JMP[EQ] @nkcv_bad
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_VERIFIES
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_VERIFIES
  LD r3,r2,#NKCS_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_OPS
  MOVI r1,#NKCS_T_VERIFY
  LD r2,r14,1
  LD r3,r14,2
  MOVI r4,0
  MOVI r5,0
  CALL @nkcas_trace_add
  MOVI r1,1
  JMP @nkcv_out
nkcv_bad:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_XPROOF
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_XPROOF
  LD r3,r2,#NKCS_G_ERRORS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_ERRORS
  LD r3,r2,#NKCS_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_OPS
  MOVI r3,#NKCS_EPROOF
  ST r3,r2,#NKCS_G_LERR
  MOVI r1,#NKCS_T_REJECT
  LD r2,r14,1
  LD r3,r14,2
  MOVI r4,0
  MOVI r5,#NKCS_EPROOF
  CALL @nkcas_trace_add
  MOVI r1,0
nkcv_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_node_match r1=node index r2=record -> 1/0.
nkcas_node_match:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  MOVI r3,#NKM_MAXNODE
  CMP r1,r3
  JMP[GE] @nkcnm_no
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkcnm_no
  ST r1,r14,3
  LD r2,r1,#NKM_N_STATE
  CMP r2,r13
  JMP[NE] @nkcnm_no
  LD r2,r1,#NKM_N_KIND
  MOVI r3,#NKM_K_PUBLIC
  CMP r2,r3
  JMP[NE] @nkcnm_no
  LD r2,r14,2
  LD r3,r14,3
  LD r2,r2,#NKCS_R_HLO
  LD r3,r3,#NKM_N_HLO
  CMP r2,r3
  JMP[NE] @nkcnm_no
  LD r2,r14,2
  LD r3,r14,3
  LD r2,r2,#NKCS_R_HHI
  LD r3,r3,#NKM_N_HHI
  CMP r2,r3
  JMP[NE] @nkcnm_no
  LD r2,r14,2
  LD r3,r14,3
  LD r2,r2,#NKCS_R_USED
  LD r3,r3,#NKM_N_USED
  CMP r2,r3
  JMP[NE] @nkcnm_no
  LD r2,r14,2
  LD r3,r14,3
  LD r2,r2,#NKCS_R_GEN
  LD r3,r3,#NKM_N_BGEN
  CMP r2,r3
  JMP[NE] @nkcnm_no
  LD r2,r14,2
  LD r3,r14,3
  LD r2,r2,#NKCS_R_PCOUNT
  LD r3,r3,#NKM_N_PCOUNT
  CMP r2,r3
  JMP[NE] @nkcnm_no
  ST r0,r14,4
nkcnm_pl:
  LD r2,r14,4
  LD r3,r14,2
  LD r3,r3,#NKCS_R_PCOUNT
  CMP r2,r3
  JMP[GE] @nkcnm_pay
  LD r3,r14,2
  ADD r3,r3,r2
  LD r3,r3,#NKCS_R_PLO
  LD r4,r14,3
  ADD r4,r4,r2
  LD r4,r4,#NKM_N_PHLO
  CMP r3,r4
  JMP[NE] @nkcnm_no
  LD r3,r14,2
  ADD r3,r3,r2
  LD r3,r3,#NKCS_R_PHI
  LD r4,r14,3
  ADD r4,r4,r2
  LD r4,r4,#NKM_N_PHHI
  CMP r3,r4
  JMP[NE] @nkcnm_no
  LD r2,r14,4
  ADD r2,r2,r13
  ST r2,r14,4
  JMP @nkcnm_pl
nkcnm_pay:
  LA r4,#NKM_STATS
  LD r4,r4,#NKM_G_BUFFER
  LD r5,r14,1
  SHL r5,r5,4
  ADD r4,r4,r5
  ST r4,r14,5
  ST r0,r14,4
nkcnm_vl:
  LD r2,r14,4
  LD r3,r14,2
  LD r3,r3,#NKCS_R_USED
  CMP r2,r3
  JMP[GE] @nkcnm_yes
  LD r3,r14,2
  ADDI r3,r3,#NKCS_R_PAY
  ADD r3,r3,r2
  LD r3,r3,0
  LD r4,r14,5
  ADD r4,r4,r2
  LD r4,r4,0
  CMP r3,r4
  JMP[NE] @nkcnm_no
  LD r2,r14,4
  ADD r2,r2,r13
  ST r2,r14,4
  JMP @nkcnm_vl
nkcnm_yes:
  MOVI r1,1
  JMP @nkcnm_out
nkcnm_no:
  MOVI r1,0
nkcnm_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_registry_hydrate r1=root lo r2=root hi r3=owner
;                        -> nkvmerkle root index / NONE.
nkcas_registry_hydrate:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LD r1,r14,1
  LD r2,r14,2
  CALL @nkcas_find
  LA r2,#NKCS_NONE
  CMP r1,r2
  JMP[EQ] @nkcrg_miss
  ST r1,r14,4
  LA r1,#NKCS_LIST
  MOVI r2,#NKCS_MAXNODE
  BFILL r1,r0,r2
  LA r1,#NKCS_LISTN
  ST r0,r1,0
  LD r1,r14,4
  LA r2,#NKCS_LIST
  LA r3,#NKCS_LISTN
  MOVI r4,0
  CALL @nkcas_walk
  CMP r1,r0
  JMP[NE] @nkcrg_fail
  LA r1,#NKCS_LISTN
  LD r1,r1,0
  ST r1,r14,5
  LA r1,#NKCS_NONE
  ST r1,r14,6
  ST r0,r14,7
nkcrg_l:
  LD r1,r14,7
  LD r2,r14,5
  CMP r1,r2
  JMP[GE] @nkcrg_done
  LA r2,#NKCS_LIST
  ADD r2,r2,r1
  LD r2,r2,0
  ST r2,r14,8
  LD r1,r14,8
  CALL @nkcas_recptr
  CMP r1,r0
  JMP[EQ] @nkcrg_corrupt
  ST r1,r14,9
  CALL @nkcas_record_valid
  CMP r1,r0
  JMP[EQ] @nkcrg_corrupt
  LD r1,r14,9
  LD r2,r1,#NKCS_R_HLO
  LD r3,r1,#NKCS_R_HHI
  ST r2,r14,10
  ST r3,r14,11
  ADD r1,r2,r0
  ADD r2,r3,r0
  CALL @nkm_find
  LA r3,#NKM_NONE
  CMP r1,r3
  JMP[NE] @nkcrg_have
  ; build ordered parent index table
  LA r2,#NKCS_TMP2
  MOVI r3,4
  BFILL r2,r0,r3
  ST r0,r14,12
nkcrg_pl:
  LD r2,r14,12
  LD r1,r14,9
  LD r3,r1,#NKCS_R_PCOUNT
  CMP r2,r3
  JMP[GE] @nkcrg_add
  ADD r1,r1,r2
  LD r1,r1,#NKCS_R_PLO
  LD r3,r14,9
  ADD r3,r3,r2
  LD r3,r3,#NKCS_R_PHI
  ADD r1,r1,r0
  ADD r2,r3,r0
  CALL @nkm_find
  LA r3,#NKM_NONE
  CMP r1,r3
  JMP[EQ] @nkcrg_emiss
  LD r2,r14,12
  LA r3,#NKCS_TMP2
  ADD r3,r3,r2
  ST r1,r3,0
  LD r2,r14,12
  ADD r2,r2,r13
  ST r2,r14,12
  JMP @nkcrg_pl
nkcrg_add:
  LD r1,r14,9
  ADDI r1,r1,#NKCS_R_PAY
  LD r2,r14,9
  LD r2,r2,#NKCS_R_USED
  LD r3,r14,9
  LD r3,r3,#NKCS_R_GEN
  LA r4,#NKCS_TMP2
  LD r5,r14,9
  LD r5,r5,#NKCS_R_PCOUNT
  LD r6,r14,3
  CALL @nkm_add
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[EQ] @nkcrg_addfail
nkcrg_have:
  ST r1,r14,13
  LD r1,r14,13
  LD r2,r14,9
  CALL @nkcas_node_match
  CMP r1,r0
  JMP[EQ] @nkcrg_mut
  LD r1,r14,7
  LD r2,r14,5
  SUB r2,r2,r13
  CMP r1,r2
  JMP[NE] @nkcrg_next
  LD r2,r14,13
  ST r2,r14,6
nkcrg_next:
  LD r1,r14,7
  ADD r1,r1,r13
  ST r1,r14,7
  JMP @nkcrg_l
nkcrg_done:
  LD r1,r14,6
  JMP @nkcrg_out
nkcrg_miss:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_MISS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_MISS
  MOVI r1,#NKCS_ENOENT
  CALL @nkcas_err
  LA r1,#NKCS_NONE
  JMP @nkcrg_out
nkcrg_emiss:
  MOVI r1,#NKCS_EMISS
  CALL @nkcas_err
  LA r1,#NKCS_NONE
  JMP @nkcrg_out
nkcrg_mut:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_MUT
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_MUT
  MOVI r1,#NKCS_EMUT
  CALL @nkcas_err
  LA r1,#NKCS_NONE
  JMP @nkcrg_out
nkcrg_corrupt:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_CORRUPT
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_CORRUPT
  MOVI r1,#NKCS_ECORRUPT
  CALL @nkcas_err
  LA r1,#NKCS_NONE
  JMP @nkcrg_out
nkcrg_addfail:
  CALL @nkm_errno
  MOVI r2,#NKM_ECOLL
  CMP r1,r2
  JMP[EQ] @nkcrg_coll
  MOVI r2,#NKM_ENOSPC
  CMP r1,r2
  JMP[EQ] @nkcrg_nospc
  JMP @nkcrg_mut
nkcrg_coll:
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_COLL
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_COLL
  MOVI r1,#NKCS_ECOLL
  CALL @nkcas_err
  LA r1,#NKCS_NONE
  JMP @nkcrg_out
nkcrg_nospc:
  MOVI r1,#NKCS_ENOSPC
  CALL @nkcas_err
  LA r1,#NKCS_NONE
  JMP @nkcrg_out
nkcrg_fail:
  LA r1,#NKCS_NONE
nkcrg_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_agent_hydrate r1=cfg -> 1/0.
nkcas_agent_hydrate:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  CMP r1,r0
  JMP[EQ] @nkca_bad
  LD r1,r14,1
  LD r2,r1,9
  LD r3,r1,10
  LD r4,r1,11
  ST r2,r14,2
  ST r3,r14,3
  ADD r1,r2,r0
  ADD r2,r3,r0
  ADD r3,r4,r0
  CALL @nkcas_registry_hydrate
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[EQ] @nkca_fail
  ST r1,r14,4
  LD r1,r14,1
  ADD r10,r1,r0
  LD r1,r10,0
  LD r2,r10,1
  LD r3,r10,2
  LD r4,r10,3
  LD r5,r10,4
  LD r6,r10,5
  LD r7,r10,6
  LD r8,r10,7
  LD r9,r10,8
  CALL @nkm_open
  CMP r1,r0
  JMP[EQ] @nkca_fail
  LD r1,r14,1
  LD r1,r1,0
  LD r2,r14,2
  LD r3,r14,3
  CALL @nkm_join
  CMP r1,r0
  JMP[EQ] @nkca_close
  ; verify bound root
  LD r1,r14,1
  LD r1,r1,0
  LA r2,#NKCS_NI
  CALL @nkm_ctx_info
  LA r1,#NKCS_NI
  LD r2,r1,#NKM_C_HLO
  LD r3,r14,2
  CMP r2,r3
  JMP[NE] @nkca_close
  LD r2,r1,#NKM_C_HHI
  LD r3,r14,3
  CMP r2,r3
  JMP[NE] @nkca_close
  LA r2,#NKCS_STATS
  LD r3,r2,#NKCS_G_HAGENTS
  ADD r3,r3,r13
  ST r3,r2,#NKCS_G_HAGENTS
  MOVI r1,1
  JMP @nkca_out
nkca_close:
  LD r1,r14,1
  LD r1,r1,0
  CALL @nkm_close
nkca_fail:
  MOVI r1,#NKCS_EBAD
  CALL @nkcas_err
  MOVI r1,0
  JMP @nkca_out
nkca_bad:
  MOVI r1,#NKCS_EBAD
  CALL @nkcas_err
  MOVI r1,0
nkca_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkcas_stats r1=out(64) -> 0/-1.
nkcas_stats:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  CMP r1,r0
  JMP[EQ] @nkcst_bad
  LA r2,#NKCS_STATS
  MOVI r3,#NKCS_SW
nkcst_l:
  CMP r3,r0
  JMP[EQ] @nkcst_ok
  LD r4,r2,0
  ST r4,r1,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  SUB r3,r3,r13
  JMP @nkcst_l
nkcst_ok:
  MOVI r1,0
  JMP @nkcst_out
nkcst_bad:
  LA r1,0xFFFFFFFF
nkcst_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkcas_trace r1=index r2=out(8) -> 0/-1.
nkcas_trace:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r2,r14,1
  MOVI r3,#NKCS_TRACE_N
  CMP r1,r3
  JMP[GE] @nkctr_bad
  CMP r2,r0
  JMP[EQ] @nkctr_bad
  SHL r1,r1,3
  LA r3,#NKCS_TRACE
  ADD r1,r3,r1
  MOVI r3,0
nkctr_l:
  MOVI r4,#NKCS_TRACE_W
  CMP r3,r4
  JMP[GE] @nkctr_ok
  ADD r4,r1,r3
  LD r4,r4,0
  ADD r5,r2,r3
  ST r4,r5,0
  ADD r3,r3,r13
  JMP @nkctr_l
nkctr_ok:
  MOVI r1,0
  JMP @nkctr_out
nkctr_bad:
  LA r1,0xFFFFFFFF
nkctr_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkcas_errno -> last error.
nkcas_errno:
  LA r1,#NKCS_STATS
  LD r1,r1,#NKCS_G_LERR
  RET
