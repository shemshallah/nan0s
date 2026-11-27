; nkvmerkle.nas - Merkle multi-parent prefix DAG with root-only inclusion
; proofs (F13j).
;
; Pure NaN.  This is the F13j layer above the nkvdag content-hash DAG and the
; ngen live-generation model.  A KV prefix is a DAG of public Merkle nodes.  A
; node commits to its used content words, its ordered parent hashes, its used
; count and its generation tag.  A node may have up to four parents, so one
; node can merge two independent prefix roots into one root commitment.  The
; node hash is the identity: an equal hash with equal fields dedups to one
; header and one payload; an equal hash with different fields is a collision
; (ECOLL), not a silent alias.
;
; Node hash (documented deterministic mix)
; ----------------------------------------
; Two 32-bit lanes are seeded with NKM_SEED_LO/NKM_SEED_HI.  Each lane is mixed
; with, in this exact order:
;   domain constant NKM_DOMAIN
;   used count
;   generation tag
;   parent count
;   for each parent in order: parent hash lo (lane lo), parent hash hi (lane hi)
;   for each content word in used order: the word (both lanes)
;   final salt NKM_SALT (both lanes)
; The mix is XOR, add C1, xor-shift 16, multiply C2, xor-shift 15, multiply C3,
; xor-shift 16, all modulo 2^32.  It is a deterministic corruption/identity
; mix, not a cryptographic hash; the limits are stated in the spec.
;
; Nodes and references
; --------------------
; A public node is immutable and content-addressed.  A private node is a COW
; suffix page, owned by exactly one branch generation and not in the content
; index.  A private page becomes public only at seal.  Every node owns one
; reference to each parent; every branch page-table entry owns one reference to
; its node.  Releasing the last reference frees the node and recursively
; releases its parents, so closing the last branch of a merged DAG frees the
; whole graph exactly once.  A join acquires every node on a single-parent
; prefix chain; a multi-parent root is deliberately rejected at join time
; (proofs still verify it from the root hash).
;
; Root-only inclusion proofs
; --------------------------
; nkm_proof walks from a public root to a target public node and emits a
; self-contained proof: one entry per node on the path, target-to-root.  Each
; entry carries used, generation tag, ordered parent hashes and the used content
; words.  Verification recomputes every entry hash, checks that each child hash
; is one of the next entry's ordered parent hashes, and checks that the last
; entry hash equals the supplied root hash.  No node registry, node index or
; branch context is consulted.  A mutated content word, parent hash, generation
; tag or used count changes an entry hash and fails the chain.  A token proof
; additionally binds (offset, value) into the target page and rejects a mutated
; value or offset.
;
; Layout
; ------
; Node registry: 64 nodes x 56 words at 0x360000.
; Stats: 64 words at 0x363000.
; Trace: 128 entries x 8 words at 0x363200.
; DFS scratch: 0x362000..0x36206F.
; Scratch: 0x30000..0x3005F (ngen status/slot).
;
; Context (32 caller words):
;   +0 magic "NKMC"   +1 version 1
;   +2 ngen agent     +3 ngen generation
;   +4 branch id      +5 parent branch
;   +6 nagent id      +7 ngen epoch
;   +8 page table     +9 table capacity in blocks
;   +10 tokens/block  +11 used tokens
;   +12 live blocks   +13 COW page copies
;   +14 bytes/token   +15 page slots
;   +16 admitted      +17 last context error
;   +18 last ngen err +19 joins
;   +20 child forks   +21 prefix pages
;   +22 root hash lo  +23 root hash hi
;   +24 view opens    +25 view reads
;   +26 view writes   +27 dedup hits
;   +28 sealed flag   +29 root node index
;   +30 chain depth   +31 flags
;
; Page table entry (8 words):
;   +0 node index/NONE +1 map generation +2 flags (1 shared, 2 private)
;   +3 hash lo          +4 hash hi        +5 node index copy
;
; Node header (56 words):
;   +0 magic "NKMN"     +1 version 1      +2 kind (1 public, 2 private)
;   +3 refs             +4 state (1 live) +5 flags (1 public)
;   +6 hash lo          +7 hash hi        +8 used words
;   +9 slots (16)       +10 payload base  +11 dedup hits
;   +12 allocations     +13 joins         +14 leaves
;   +15 frees           +16 headers       +17 generation tag
;   +18 owner agent     +19 parent count
;   +20..23 parent node indices
;   +24..27 parent hash lo (ordered)
;   +28..31 parent hash hi (ordered)
;   +32 node index      +33 child refs held
;   +34 proofs served   +35 COW copies caused
;   +36 tokens copied   +37 lookups       +38 hits
;   +39..55 reserved
;
; Proof (caller buffer, 16 + depth*32 words):
;   +0 magic "NKMP" +1 version 1 +2 depth +3 mode (1 page, 2 token)
;   +4 token offset/NONE +5 token value
;   +6 root hash lo +7 root hash hi
;   +8 target hash lo +9 target hash hi
;   +10 target used +11 target gen +12 flags +13..15 reserved
;   entry (32 words), target first, root last:
;   +0 used +1 gen +2 parent count
;   +3..6 parent hash lo +7..10 parent hash hi
;   +11..26 content (16 words, unused slots zero)
;   +27 hash lo +28 hash hi +29 flags +30..31 reserved
;
; Stats (64 words):
;   +0 magic "NKMG" +1 version +2 live +3 public live
;   +4 public headers +5 public allocs +6 public frees +7 private allocs
;   +8 private frees +9 refs acquired +10 refs released +11 dedup hits
;   +12 join operations +13 join refs +14 leaves +15 COW copies
;   +16 tokens copied +17 node limit +18 buffer +19 max nodes
;   +20 trace head +21 trace events +22 trace wraps +23 errors
;   +24 last error +25 ops +26 cross-gen rejects +27 stale rejects
;   +28 shared-write rejects +29 collision rejects +30 duplicate rejects
;   +31 ref rejects +32 lookups +33 lookup hits +34 opens +35 closes
;   +36 seals +37 roots bound +38 merges +39 proofs generated
;   +40 proof verifies +41 proof rejects +42 proof malformed rejects
;   +43..63 reserved
;
; Trace entry (8 words): kind, seq, a, b, c, 0, hash, 0.
; Kinds: 1 open, 2 seal, 3 join, 4 new, 5 COW, 6 release/free, 7 close,
; 8 dedup, 9 reject, 10 publish, 11 merge, 12 proof, 13 verify.
;
; Return codes (nkm_errno):
;   0 OK, 1 EBAD, 2 ENOENT, 3 ENOSPC, 4 EGEN, 5 ESTALE, 6 ESHARED,
;   7 EBLK, 8 EDUP, 9 ECOLL, 10 EREF, 11 EPROOF.
;
; API (r0=0, r13=1, r14 grows up, r15 link):
;   nkm_init        r1=page buffer word base r2=node limit (1..64) -> 0/-1
;   nkm_open        r1=ctx r2=ngen agent r3=generation r4=cpu r5=branch
;                   r6=nagent id r7=table r8=cap r9=tokens/block -> 1/0
;   nkm_publish     r1=ctx r2=new generation -> epoch / 0
;   nkm_seal        r1=ctx -> 1/0
;   nkm_join        r1=ctx r2=root hash lo r3=root hash hi -> 1/0
;   nkm_merge_n     r1=ctx r2=values r3=used r4=parents ptr r5=count
;                   -> new root index / NONE (nkm_merge is an alias)
;   nkm_append      r1=ctx r2=value -> token index / -1
;   nkm_view_open   r1=ctx r2=token r3=mode r4=out -> 1/0
;   nkm_view_read   r1=ctx r2=view r3=out(2) -> 1/0
;   nkm_view_write  r1=ctx r2=view r3=value -> 1/0
;   nkm_close       r1=ctx -> 1/0
;   nkm_proof       r1=root idx r2=target idx r3=token off/NONE r4=proof -> 1/0
;   nkm_proof_verify r1=root lo r2=root hi r3=proof -> 1/0
;   nkm_node_info   r1=index r2=out(56) -> 0/-1
;   nkm_node_find   r1=hash lo r2=hash hi -> index / NONE
;   nkm_node_free   r1=index -> 1/0 (only at zero refs)
;   nkm_hash        r1=values r2=used r3=gen r4=parent idx ptr r5=count
;                   -> r1=lo r2=hi
;   nkm_stats       r1=out(64) -> 0/-1
;   nkm_ctx_info    r1=ctx r2=out(32) -> 0/-1
;   nkm_root_info   r1=ctx r2=out(8) -> 0/-1
;   nkm_trace       r1=index r2=out(8) -> 0/-1
;   nkm_trace_head  -> head / 0
;   nkm_errno       -> last error
;
; Requires nagent_init and ngen_init before nkm_open.  The page buffer is
; caller supplied.  Payloads are plain NaN words; the hash is identity and
; integrity, not a capability and not a cryptographic signature.

.include "nagent.nas"
.include "ngen.nas"

.equ NKM_NODES      0x360000
.equ NKM_MAXNODE    64
.equ NKM_NSTRIDE    56
.equ NKM_NTOTAL     3584
.equ NKM_STATS      0x363000
.equ NKM_SW         64
.equ NKM_TRACE      0x363200
.equ NKM_TRACE_N    128
.equ NKM_TRACE_W    8
.equ NKM_TRACE_TOTAL 1024
.equ NKM_SCR        0x30000
.equ NKM_SCR_STATUS 0x30000
.equ NKM_SCR_SLOT   0x30020

.equ NKM_DFS_TARGET 0x362000
.equ NKM_DFS_ID     0x362001
.equ NKM_DFS_DEPTH  0x362002
.equ NKM_PATH       0x362010
.equ NKM_SEEN       0x362030

.equ NKM_CMAGIC     0x434D4B4E       ; "NKMC"
.equ NKM_NMAGIC     0x4E4D4B4E       ; "NKMN"
.equ NKM_VMAGIC     0x564D4B4E       ; "NKMV"
.equ NKM_GMAGIC     0x474D4B4E       ; "NKMG"
.equ NKM_PMAGIC     0x504D4B4E       ; "NKMP"
.equ NKM_VERSION    1
.equ NKM_SLOTS      16
.equ NKM_PAGE_W     16
.equ NKM_BPT_BYTES  16
.equ NKM_NONE       0xFFFFFFFF
.equ NKM_PROOF_MAX  16
.equ NKM_PENTRY     16
.equ NKM_PESTRIDE   32
.equ NKM_SEED_LO    0x4E4B4D48       ; "NKMH"
.equ NKM_SEED_HI    0x4D45524B       ; "MERK"
.equ NKM_DOMAIN     0x4E4B4D44       ; "NKMD"
.equ NKM_SALT       0x4B564D52       ; "KVMR"
.equ NKM_MIX_C1     0x9E3779B9
.equ NKM_MIX_C2     0x85EBCA6B
.equ NKM_MIX_C3     0xC2B2AE35

; context fields
.equ NKM_C_MAGIC    0
.equ NKM_C_VERSION  1
.equ NKM_C_AGENT    2
.equ NKM_C_GEN      3
.equ NKM_C_BRANCH   4
.equ NKM_C_PARENT   5
.equ NKM_C_NAGENT   6
.equ NKM_C_EPOCH    7
.equ NKM_C_TAB      8
.equ NKM_C_TABCAP   9
.equ NKM_C_BLOCKTOK 10
.equ NKM_C_USED     11
.equ NKM_C_LIVE     12
.equ NKM_C_COPIES   13
.equ NKM_C_BPT      14
.equ NKM_C_SLOTS    15
.equ NKM_C_ADMIT    16
.equ NKM_C_ERR      17
.equ NKM_C_NGERR    18
.equ NKM_C_JOINS    19
.equ NKM_C_CHILDREN 20
.equ NKM_C_PREFIX   21
.equ NKM_C_HLO      22
.equ NKM_C_HHI      23
.equ NKM_C_VOPEN    24
.equ NKM_C_VREAD    25
.equ NKM_C_VWRITE   26
.equ NKM_C_DEDUP    27
.equ NKM_C_SEALED   28
.equ NKM_C_ROOT     29
.equ NKM_C_DEPTH    30
.equ NKM_C_FLAGS    31

; node fields
.equ NKM_N_MAGIC    0
.equ NKM_N_VERSION  1
.equ NKM_N_KIND     2
.equ NKM_N_REFS     3
.equ NKM_N_STATE    4
.equ NKM_N_FLAGS    5
.equ NKM_N_HLO      6
.equ NKM_N_HHI      7
.equ NKM_N_USED     8
.equ NKM_N_SLOTS    9
.equ NKM_N_PAY      10
.equ NKM_N_DEDUP    11
.equ NKM_N_ALLOCS   12
.equ NKM_N_JOINS    13
.equ NKM_N_LEAVES   14
.equ NKM_N_FREES    15
.equ NKM_N_HEADERS  16
.equ NKM_N_BGEN     17
.equ NKM_N_OWNER    18
.equ NKM_N_PCOUNT   19
.equ NKM_N_PIDX     20
.equ NKM_N_PHLO     24
.equ NKM_N_PHHI     28
.equ NKM_N_IDX      32
.equ NKM_N_CHILDREN 33
.equ NKM_N_PROOFS   34
.equ NKM_N_COPIES   35
.equ NKM_N_TCOPY    36
.equ NKM_N_LOOKUPS  37
.equ NKM_N_HITS     38

; entry fields
.equ NKM_E_NODE     0
.equ NKM_E_MAPGEN   1
.equ NKM_E_FLAGS    2
.equ NKM_E_HLO      3
.equ NKM_E_HHI      4
.equ NKM_E_IDX      5

; entry flags
.equ NKM_F_SHARED   1
.equ NKM_F_PRIVATE  2
.equ NKM_F_PUBLIC   1

; kinds
.equ NKM_K_PUBLIC   1
.equ NKM_K_PRIV     2

; stats fields
.equ NKM_G_MAGIC    0
.equ NKM_G_VERSION  1
.equ NKM_G_LIVE     2
.equ NKM_G_PUBLIVE  3
.equ NKM_G_PHEADERS 4
.equ NKM_G_PALLOC   5
.equ NKM_G_PFREE    6
.equ NKM_G_PRIVALLOC 7
.equ NKM_G_PRIVFREE 8
.equ NKM_G_REFS     9
.equ NKM_G_RELS     10
.equ NKM_G_DEDUP    11
.equ NKM_G_JOINOPS  12
.equ NKM_G_JOINREFS 13
.equ NKM_G_LEAVES   14
.equ NKM_G_COWS     15
.equ NKM_G_TCOPY    16
.equ NKM_G_LIMIT    17
.equ NKM_G_BUFFER   18
.equ NKM_G_MAXNODE  19
.equ NKM_G_THEAD    20
.equ NKM_G_TEVENTS  21
.equ NKM_G_TWRAPS   22
.equ NKM_G_ERRORS   23
.equ NKM_G_LERR     24
.equ NKM_G_OPS      25
.equ NKM_G_XGEN     26
.equ NKM_G_XSTALE   27
.equ NKM_G_XSHARED  28
.equ NKM_G_XCOLL    29
.equ NKM_G_XDUP     30
.equ NKM_G_XREF     31
.equ NKM_G_LOOKUPS  32
.equ NKM_G_HITS     33
.equ NKM_G_OPENS    34
.equ NKM_G_CLOSES   35
.equ NKM_G_SEALS    36
.equ NKM_G_ROOTS    37
.equ NKM_G_MERGES   38
.equ NKM_G_PROOFS   39
.equ NKM_G_VERIFIES 40
.equ NKM_G_XPROOF   41
.equ NKM_G_XBAD     42

; proof fields
.equ NKM_P_MAGIC    0
.equ NKM_P_VERSION  1
.equ NKM_P_DEPTH    2
.equ NKM_P_MODE     3
.equ NKM_P_TOKOFF   4
.equ NKM_P_TOKVAL   5
.equ NKM_P_ROOTLO   6
.equ NKM_P_ROOTHI  7
.equ NKM_P_TARGLO   8
.equ NKM_P_TARGHI   9
.equ NKM_P_USED     10
.equ NKM_P_GEN      11
.equ NKM_P_FLAGS    12

.equ NKM_PE_USED    0
.equ NKM_PE_GEN     1
.equ NKM_PE_PCOUNT  2
.equ NKM_PE_PLO     3
.equ NKM_PE_PHI     7
.equ NKM_PE_CONTENT 11
.equ NKM_PE_HLO     27
.equ NKM_PE_HHI     28
.equ NKM_PE_FLAGS   29

; view fields
.equ NKM_V_MAGIC    0
.equ NKM_V_VERSION  1
.equ NKM_V_CTXGEN   2
.equ NKM_V_BRANCH   3
.equ NKM_V_TOKEN    4
.equ NKM_V_NODE     5
.equ NKM_V_BGEN     6
.equ NKM_V_MODE     7
.equ NKM_V_FLAGS    8
.equ NKM_V_OFF      9

; trace kinds
.equ NKM_T_OPEN     1
.equ NKM_T_SEAL     2
.equ NKM_T_JOIN     3
.equ NKM_T_NEW      4
.equ NKM_T_COW      5
.equ NKM_T_FREE     6
.equ NKM_T_CLOSE    7
.equ NKM_T_DEDUP    8
.equ NKM_T_REJECT   9
.equ NKM_T_PUBLISH  10
.equ NKM_T_MERGE    11
.equ NKM_T_PROOF    12
.equ NKM_T_VERIFY   13

; errors
.equ NKM_OK         0
.equ NKM_EBAD       1
.equ NKM_ENOENT     2
.equ NKM_ENOSPC     3
.equ NKM_EGEN       4
.equ NKM_ESTALE     5
.equ NKM_ESHARED    6
.equ NKM_EBLK       7
.equ NKM_EDUP       8
.equ NKM_ECOLL      9
.equ NKM_EREF       10
.equ NKM_EPROOF     11

; ---------------------------------------------------------------------------
; nkm_mix r1=hash r2=word -> r1.
nkm_mix:
  BOOL.6 r1,r1,r2
  LA r3,#NKM_MIX_C1
  ADD r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  LA r3,#NKM_MIX_C2
  MUL r1,r1,r3
  SHR r4,r1,15
  BOOL.6 r1,r1,r4
  LA r3,#NKM_MIX_C3
  MUL r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  RET

; ---------------------------------------------------------------------------
; nkm_hash_arrays r1=values r2=used r3=gen r4=pcount
;                 r5=parent lo array r6=parent hi array -> r1=lo r2=hi.
nkm_hash_arrays:
  ST r15,r14,0
  ADDI r14,r14,80
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  LA r7,#NKM_SEED_LO
  LA r8,#NKM_SEED_HI
  LA r9,#NKM_DOMAIN
  ADD r1,r7,r0
  ADD r2,r9,r0
  CALL @nkm_mix
  ST r1,r14,7
  ADD r1,r8,r0
  ADD r2,r9,r0
  CALL @nkm_mix
  ST r1,r14,8
  ; used
  LD r1,r14,7
  LD r2,r14,2
  CALL @nkm_mix
  ST r1,r14,7
  LD r1,r14,8
  LD r2,r14,2
  CALL @nkm_mix
  ST r1,r14,8
  ; generation tag
  LD r1,r14,7
  LD r2,r14,3
  CALL @nkm_mix
  ST r1,r14,7
  LD r1,r14,8
  LD r2,r14,3
  CALL @nkm_mix
  ST r1,r14,8
  ; parent count
  LD r1,r14,7
  LD r2,r14,4
  CALL @nkm_mix
  ST r1,r14,7
  LD r1,r14,8
  LD r2,r14,4
  CALL @nkm_mix
  ST r1,r14,8
  ; parent hashes, ordered, lo lane gets lo, hi lane gets hi
  ST r0,r14,9
nha_pl:
  LD r9,r14,9
  LD r4,r14,4
  CMP r9,r4
  JMP[GE] @nha_content
  LD r5,r14,5
  ADD r5,r5,r9
  LD r2,r5,0
  LD r1,r14,7
  CALL @nkm_mix
  ST r1,r14,7
  LD r6,r14,6
  ADD r6,r6,r9
  LD r2,r6,0
  LD r1,r14,8
  CALL @nkm_mix
  ST r1,r14,8
  LD r9,r14,9
  ADD r9,r9,r13
  ST r9,r14,9
  JMP @nha_pl
nha_content:
  ST r0,r14,9
nha_cl:
  LD r9,r14,9
  LD r2,r14,2
  CMP r9,r2
  JMP[GE] @nha_fin
  LD r5,r14,1
  ADD r5,r5,r9
  LD r3,r5,0
  LD r1,r14,7
  ADD r2,r3,r0
  CALL @nkm_mix
  ST r1,r14,7
  LD r1,r14,8
  ADD r2,r3,r0
  CALL @nkm_mix
  ST r1,r14,8
  LD r9,r14,9
  ADD r9,r9,r13
  ST r9,r14,9
  JMP @nha_cl
nha_fin:
  LA r3,#NKM_SALT
  LD r1,r14,7
  ADD r2,r3,r0
  CALL @nkm_mix
  ST r1,r14,7
  LD r1,r14,8
  ADD r2,r3,r0
  CALL @nkm_mix
  ST r1,r14,8
  LD r1,r14,7
  LD r2,r14,8
  ADDI r14,r14,-80
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_hash r1=values r2=used r3=gen r4=parent index ptr r5=count
;          -> r1=lo r2=hi.  Resolves parent hashes through the node registry.
nkm_hash:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  MOVI r6,#NKM_SLOTS
  CMP r2,r6
  JMP[GT] @nkh_bad
  MOVI r6,4
  CMP r5,r6
  JMP[GT] @nkh_bad
  ; resolve indices into local lo[4] at +32, hi[4] at +40
  ST r0,r14,6
nkh_l:
  LD r6,r14,6
  LD r5,r14,5
  CMP r6,r5
  JMP[GE] @nkh_done
  LD r4,r14,4
  CMP r4,r0
  JMP[EQ] @nkh_bad
  ADD r4,r4,r6
  LD r8,r4,0
  MOVI r7,#NKM_MAXNODE
  CMP r8,r7
  JMP[GE] @nkh_bad
  SHL r1,r8,6
  MOVI r7,8
  MUL r7,r8,r7
  SUB r1,r1,r7
  LA r7,#NKM_NODES
  ADD r1,r7,r1
  LD r7,r1,#NKM_N_STATE
  CMP r7,r13
  JMP[NE] @nkh_bad
  LD r7,r1,#NKM_N_HLO
  ADD r10,r14,r6
  ADDI r10,r10,32
  ST r7,r10,0
  LD r7,r1,#NKM_N_HHI
  ADD r10,r14,r6
  ADDI r10,r10,40
  ST r7,r10,0
  LD r6,r14,6
  ADD r6,r6,r13
  ST r6,r14,6
  JMP @nkh_l
nkh_done:
  LD r1,r14,1
  LD r2,r14,2
  LD r3,r14,3
  LD r4,r14,5
  ADD r5,r14,r0
  ADDI r5,r5,32
  ADD r6,r14,r0
  ADDI r6,r6,40
  CALL @nkm_hash_arrays
  JMP @nkh_out
nkh_bad:
  MOVI r1,0
  MOVI r2,0
nkh_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_same r1=node ptr r2=values r3=used r4=gen r5=pcount
;           r6=parent lo array r7=parent hi array -> 1/0.
nkm_same:
  LD r8,r1,#NKM_N_USED
  CMP r8,r3
  JMP[NE] @nks_no
  LD r8,r1,#NKM_N_BGEN
  CMP r8,r4
  JMP[NE] @nks_no
  LD r8,r1,#NKM_N_PCOUNT
  CMP r8,r5
  JMP[NE] @nks_no
  MOVI r8,0
nks_pl:
  CMP r8,r5
  JMP[GE] @nks_cont
  ADD r9,r1,r8
  LD r9,r9,#NKM_N_PHLO
  ADD r10,r6,r8
  LD r10,r10,0
  CMP r9,r10
  JMP[NE] @nks_no
  ADD r9,r1,r8
  LD r9,r9,#NKM_N_PHHI
  ADD r10,r7,r8
  LD r10,r10,0
  CMP r9,r10
  JMP[NE] @nks_no
  ADD r8,r8,r13
  JMP @nks_pl
nks_cont:
  LD r9,r1,#NKM_N_PAY
  MOVI r8,0
nks_cl:
  CMP r8,r3
  JMP[GE] @nks_yes
  ADD r10,r9,r8
  LD r10,r10,0
  ADD r11,r2,r8
  LD r11,r11,0
  CMP r10,r11
  JMP[NE] @nks_no
  ADD r8,r8,r13
  JMP @nks_cl
nks_yes:
  MOVI r1,1
  RET
nks_no:
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; nkm_trace_add r1=kind r2=a r3=b r4=c -> new head.
nkm_trace_add:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  LA r5,#NKM_STATS
  LD r6,r5,#NKM_G_THEAD
  LD r7,r5,#NKM_G_TEVENTS
  ST r6,r14,5
  ST r7,r14,6
  ADD r1,r6,r0
  LD r2,r14,1
  CALL @nkm_mix
  LD r2,r14,2
  CALL @nkm_mix
  LD r2,r14,3
  CALL @nkm_mix
  LD r2,r14,4
  CALL @nkm_mix
  ST r1,r14,7
  LD r2,r14,6
  MOVI r3,#NKM_TRACE_N
  MODU r2,r2,r3
  SHL r2,r2,3
  LA r3,#NKM_TRACE
  ADD r2,r3,r2
  LD r3,r14,1
  ST r3,r2,0
  LD r3,r14,6
  ST r3,r2,1
  LD r3,r14,2
  ST r3,r2,2
  LD r3,r14,3
  ST r3,r2,3
  LD r3,r14,4
  ST r3,r2,4
  ST r0,r2,5
  LD r3,r14,7
  ST r3,r2,6
  ST r0,r2,7
  LA r3,#NKM_STATS
  LD r1,r14,7
  ST r1,r3,#NKM_G_THEAD
  LD r2,r14,6
  ADD r2,r2,r13
  ST r2,r3,#NKM_G_TEVENTS
  MOVI r4,#NKM_TRACE_N
  CMP r2,r4
  JMP[LT] @nkmtr_out
  LD r4,r14,6
  MOVI r5,#NKM_TRACE_N
  MODU r4,r4,r5
  MOVI r5,#NKM_TRACE_N
  SUB r5,r5,r13
  CMP r4,r5
  JMP[NE] @nkmtr_out
  LD r4,r3,#NKM_G_TWRAPS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_TWRAPS
nkmtr_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_fail r1=ctx(or 0) r2=code -> 0.
nkm_fail:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  ST r2,r14,2
  LA r3,#NKM_STATS
  LD r4,r3,#NKM_G_ERRORS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_ERRORS
  ST r2,r3,#NKM_G_LERR
  LD r4,r3,#NKM_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_OPS
  MOVI r4,#NKM_EGEN
  CMP r2,r4
  JMP[NE] @nkmf_stale
  LD r4,r3,#NKM_G_XGEN
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_XGEN
  JMP @nkmf_ctx
nkmf_stale:
  MOVI r4,#NKM_ESTALE
  CMP r2,r4
  JMP[NE] @nkmf_shared
  LD r4,r3,#NKM_G_XSTALE
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_XSTALE
  JMP @nkmf_ctx
nkmf_shared:
  MOVI r4,#NKM_ESHARED
  CMP r2,r4
  JMP[NE] @nkmf_coll
  LD r4,r3,#NKM_G_XSHARED
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_XSHARED
  JMP @nkmf_ctx
nkmf_coll:
  MOVI r4,#NKM_ECOLL
  CMP r2,r4
  JMP[NE] @nkmf_dup
  LD r4,r3,#NKM_G_XCOLL
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_XCOLL
  JMP @nkmf_ctx
nkmf_dup:
  MOVI r4,#NKM_EDUP
  CMP r2,r4
  JMP[NE] @nkmf_ref
  LD r4,r3,#NKM_G_XDUP
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_XDUP
  JMP @nkmf_ctx
nkmf_ref:
  MOVI r4,#NKM_EREF
  CMP r2,r4
  JMP[NE] @nkmf_ctx
  LD r4,r3,#NKM_G_XREF
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_XREF
nkmf_ctx:
  LD r1,r14,1
  CMP r1,r0
  JMP[EQ] @nkmf_done
  LD r2,r14,2
  ST r2,r1,#NKM_C_ERR
nkmf_done:
  MOVI r1,0
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkm_pfail -> 0.  Proof verification has no context; it is a standalone
; root-only check, so only global counters and errno move.
nkm_pfail:
  LA r3,#NKM_STATS
  LD r4,r3,#NKM_G_ERRORS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_ERRORS
  MOVI r4,#NKM_EPROOF
  ST r4,r3,#NKM_G_LERR
  LD r4,r3,#NKM_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_OPS
  LD r4,r3,#NKM_G_XPROOF
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_XPROOF
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; nkm_nodeptr r1=index -> header or 0.
nkm_nodeptr:
  MOVI r2,#NKM_MAXNODE
  CMP r1,r2
  JMP[GE] @nkpt_bad
  SHL r2,r1,6
  MOVI r3,8
  MUL r3,r1,r3
  SUB r2,r2,r3
  LA r3,#NKM_NODES
  ADD r1,r3,r2
  RET
nkpt_bad:
  MOVI r1,0
  RET

; nkm_ctx_live r1=ctx -> 1/0.
nkm_ctx_live:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  LD r2,r1,#NKM_C_MAGIC
  LA r3,#NKM_CMAGIC
  CMP r2,r3
  JMP[NE] @nkmcl_no
  LD r2,r1,#NKM_C_VERSION
  MOVI r3,#NKM_VERSION
  CMP r2,r3
  JMP[NE] @nkmcl_no
  LD r2,r1,#NKM_C_ADMIT
  CMP r2,r0
  JMP[EQ] @nkmcl_no
  LD r2,r1,#NKM_C_AGENT
  LA r3,#NKM_SCR_STATUS
  MOVI r4,0
  ADD r1,r2,r0
  ADD r2,r3,r0
  CALL @ngen_status
  CMP r1,r0
  JMP[NE] @nkmcl_no
  LA r3,#NKM_SCR_STATUS
  LD r4,r3,3
  LD r5,r14,1
  LD r5,r5,#NKM_C_GEN
  CMP r4,r5
  JMP[EQ] @nkmcl_yes
  LD r1,r14,1
  LD r1,r1,#NKM_C_AGENT
  ADD r2,r5,r0
  LA r3,#NKM_SCR_SLOT
  CALL @ngen_slot
  CMP r1,r0
  JMP[NE] @nkmcl_no
  LA r3,#NKM_SCR_SLOT
  LD r4,r3,1
  MOVI r5,#NG_S_DRAINING
  CMP r4,r5
  JMP[NE] @nkmcl_no
nkmcl_yes:
  MOVI r1,1
  JMP @nkmcl_out
nkmcl_no:
  MOVI r1,0
nkmcl_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkm_lookup r1=ctx r2=token -> r1=node idx r2=slot r3=entry or r1=NONE.
nkm_lookup:
  LD r3,r1,#NKM_C_USED
  CMP r2,r3
  JMP[GE] @nkml_bad
  LD r4,r1,#NKM_C_BLOCKTOK
  CMP r4,r0
  JMP[EQ] @nkml_bad
  DIVU r5,r2,r4
  MODU r6,r2,r4
  LD r7,r1,#NKM_C_TABCAP
  CMP r5,r7
  JMP[GE] @nkml_bad
  LD r8,r1,#NKM_C_TAB
  CMP r8,r0
  JMP[EQ] @nkml_bad
  SHL r9,r5,3
  ADD r8,r8,r9
  LD r9,r8,#NKM_E_NODE
  LA r10,#NKM_NONE
  CMP r9,r10
  JMP[EQ] @nkml_bad
  ADD r1,r9,r0
  ADD r2,r6,r0
  ADD r3,r8,r0
  RET
nkml_bad:
  LA r1,#NKM_NONE
  MOVI r2,0
  MOVI r3,0
  RET

; ---------------------------------------------------------------------------
; nkm_node_alloc r1=kind r2=birth gen r3=owner -> index / NONE.
nkm_node_alloc:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  MOVI r4,0
  ST r4,r14,4
  LA r5,#NKM_STATS
  LD r6,r5,#NKM_G_LIMIT
  LA r7,#NKM_NODES
nka_l:
  LD r4,r14,4
  CMP r4,r6
  JMP[GE] @nka_fail
  SHL r8,r4,6
  MOVI r9,8
  MUL r9,r4,r9
  SUB r8,r8,r9
  ADD r8,r7,r8
  LD r9,r8,#NKM_N_STATE
  CMP r9,r0
  JMP[EQ] @nka_found
  LD r4,r14,4
  ADD r4,r4,r13
  ST r4,r14,4
  JMP @nka_l
nka_found:
  ST r8,r14,5
  ST r4,r14,6
  ; clear header 56 words
  MOVI r9,#NKM_NSTRIDE
  ADD r10,r8,r0
nka_z:
  CMP r9,r0
  JMP[EQ] @nka_pay
  ST r0,r10,0
  ADD r10,r10,r13
  SUB r9,r9,r13
  JMP @nka_z
nka_pay:
  LA r5,#NKM_STATS
  LD r10,r5,#NKM_G_BUFFER
  LD r4,r14,6
  SHL r11,r4,4
  ADD r10,r10,r11
  ST r10,r14,7
  MOVI r9,#NKM_SLOTS
nka_pz:
  CMP r9,r0
  JMP[EQ] @nka_fill
  ST r0,r10,0
  ADD r10,r10,r13
  SUB r9,r9,r13
  JMP @nka_pz
nka_fill:
  LD r8,r14,5
  LA r9,#NKM_NMAGIC
  ST r9,r8,#NKM_N_MAGIC
  MOVI r9,#NKM_VERSION
  ST r9,r8,#NKM_N_VERSION
  LD r9,r14,1
  ST r9,r8,#NKM_N_KIND
  MOVI r9,1
  ST r9,r8,#NKM_N_REFS
  ST r9,r8,#NKM_N_STATE
  MOVI r9,#NKM_F_PUBLIC
  LD r10,r14,1
  MOVI r11,#NKM_K_PUBLIC
  CMP r10,r11
  JMP[EQ] @nka_flag
  MOVI r9,#NKM_F_PRIVATE
nka_flag:
  ST r9,r8,#NKM_N_FLAGS
  MOVI r9,#NKM_SLOTS
  ST r9,r8,#NKM_N_SLOTS
  LD r9,r14,7
  ST r9,r8,#NKM_N_PAY
  MOVI r9,1
  ST r9,r8,#NKM_N_ALLOCS
  LD r9,r14,2
  ST r9,r8,#NKM_N_BGEN
  LD r9,r14,3
  ST r9,r8,#NKM_N_OWNER
  LD r9,r14,6
  ST r9,r8,#NKM_N_IDX
  ; stats
  LA r5,#NKM_STATS
  LD r9,r5,#NKM_G_LIVE
  ADD r9,r9,r13
  ST r9,r5,#NKM_G_LIVE
  LD r9,r5,#NKM_G_REFS
  ADD r9,r9,r13
  ST r9,r5,#NKM_G_REFS
  LD r9,r5,#NKM_G_OPS
  ADD r9,r9,r13
  ST r9,r5,#NKM_G_OPS
  LD r10,r14,1
  MOVI r11,#NKM_K_PUBLIC
  CMP r10,r11
  JMP[NE] @nka_priv
  LD r9,r5,#NKM_G_PUBLIVE
  ADD r9,r9,r13
  ST r9,r5,#NKM_G_PUBLIVE
  LD r9,r5,#NKM_G_PHEADERS
  ADD r9,r9,r13
  ST r9,r5,#NKM_G_PHEADERS
  LD r9,r5,#NKM_G_PALLOC
  ADD r9,r9,r13
  ST r9,r5,#NKM_G_PALLOC
  MOVI r9,1
  ST r9,r8,#NKM_N_HEADERS
  JMP @nka_ok
nka_priv:
  LD r9,r5,#NKM_G_PRIVALLOC
  ADD r9,r9,r13
  ST r9,r5,#NKM_G_PRIVALLOC
nka_ok:
  LD r1,r14,6
  JMP @nka_out
nka_fail:
  LA r1,#NKM_NONE
nka_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_node_release r1=ctx(or 0) r2=index -> 1/0.  Recursively releases
; parent references when the last reference leaves.
nkm_node_release:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  LD r1,r14,2
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nknr_fail
  ST r1,r14,3
  LD r3,r1,#NKM_N_STATE
  MOVI r4,1
  CMP r3,r4
  JMP[NE] @nknr_fail
  LD r3,r1,#NKM_N_REFS
  CMP r3,r0
  JMP[EQ] @nknr_fail
  SUB r3,r3,r13
  ST r3,r1,#NKM_N_REFS
  LD r4,r1,#NKM_N_LEAVES
  ADD r4,r4,r13
  ST r4,r1,#NKM_N_LEAVES
  LA r5,#NKM_STATS
  LD r4,r5,#NKM_G_RELS
  ADD r4,r4,r13
  ST r4,r5,#NKM_G_RELS
  LD r4,r5,#NKM_G_LEAVES
  ADD r4,r4,r13
  ST r4,r5,#NKM_G_LEAVES
  LD r4,r5,#NKM_G_OPS
  ADD r4,r4,r13
  ST r4,r5,#NKM_G_OPS
  LD r3,r1,#NKM_N_REFS
  CMP r3,r0
  JMP[NE] @nknr_ok
  ; capture parent list before clearing
  LD r3,r1,#NKM_N_PCOUNT
  ST r3,r14,4
  MOVI r6,0
nknr_pc:
  CMP r6,r3
  JMP[GE] @nknr_captured
  ADD r7,r1,r6
  LD r7,r7,#NKM_N_PIDX
  ADD r8,r14,r6
  ADDI r8,r8,8
  ST r7,r8,0
  ADD r6,r6,r13
  JMP @nknr_pc
nknr_captured:
  ; free this node
  LD r3,r1,#NKM_N_KIND
  MOVI r4,#NKM_K_PUBLIC
  CMP r3,r4
  JMP[NE] @nknr_privfree
  LD r4,r5,#NKM_G_PUBLIVE
  SUB r4,r4,r13
  ST r4,r5,#NKM_G_PUBLIVE
  LD r4,r5,#NKM_G_PFREE
  ADD r4,r4,r13
  ST r4,r5,#NKM_G_PFREE
  JMP @nknr_freed
nknr_privfree:
  LD r4,r5,#NKM_G_PRIVFREE
  ADD r4,r4,r13
  ST r4,r5,#NKM_G_PRIVFREE
nknr_freed:
  LD r4,r5,#NKM_G_LIVE
  SUB r4,r4,r13
  ST r4,r5,#NKM_G_LIVE
  LD r4,r5,#NKM_G_OPS
  ADD r4,r4,r13
  ST r4,r5,#NKM_G_OPS
  ST r0,r1,#NKM_N_STATE
  ; clear payload
  LD r6,r1,#NKM_N_PAY
  MOVI r7,#NKM_SLOTS
nknr_cp:
  CMP r7,r0
  JMP[EQ] @nknr_trace
  ST r0,r6,0
  ADD r6,r6,r13
  SUB r7,r7,r13
  JMP @nknr_cp
nknr_trace:
  MOVI r1,#NKM_T_FREE
  LD r2,r14,3
  LD r3,r2,#NKM_N_IDX
  LD r4,r2,#NKM_N_BGEN
  MOVI r5,0
  ST r5,r14,5
  CALL @nkm_trace_add
  ; release each parent
  ST r0,r14,6
nknr_rel:
  LD r6,r14,6
  LD r3,r14,4
  CMP r6,r3
  JMP[GE] @nknr_ok
  ADD r7,r14,r6
  ADDI r7,r7,8
  LD r2,r7,0
  LD r1,r14,1
  CALL @nkm_node_release
  LD r6,r14,6
  ADD r6,r6,r13
  ST r6,r14,6
  JMP @nknr_rel
nknr_ok:
  MOVI r1,1
  JMP @nknr_out
nknr_fail:
  MOVI r1,0
nknr_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_init r1=buffer r2=limit (1..64) -> 0/-1.
nkm_init:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  CMP r1,r0
  JMP[EQ] @nkmi_bad
  CMP r2,r0
  JMP[EQ] @nkmi_bad
  MOVI r3,#NKM_MAXNODE
  CMP r2,r3
  JMP[GT] @nkmi_bad
  LA r1,#NKM_NODES
  MOVI r2,#NKM_NTOTAL
nkmi_n:
  CMP r2,r0
  JMP[EQ] @nkmi_s
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkmi_n
nkmi_s:
  LA r1,#NKM_STATS
  MOVI r2,#NKM_SW
nkmi_sl:
  CMP r2,r0
  JMP[EQ] @nkmi_tr
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkmi_sl
nkmi_tr:
  LA r1,#NKM_TRACE
  MOVI r2,#NKM_TRACE_TOTAL
nkmi_trl:
  CMP r2,r0
  JMP[EQ] @nkmi_buf
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkmi_trl
nkmi_buf:
  LA r1,#NKM_DFS_TARGET
  MOVI r2,112
nkmi_dfs:
  CMP r2,r0
  JMP[EQ] @nkmi_buf0
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkmi_dfs
nkmi_buf0:
  LD r1,r14,1
  LD r2,r14,2
  SHL r2,r2,4
nkmi_b:
  CMP r2,r0
  JMP[EQ] @nkmi_meta
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkmi_b
nkmi_meta:
  LA r1,#NKM_STATS
  LA r2,#NKM_GMAGIC
  ST r2,r1,#NKM_G_MAGIC
  MOVI r2,#NKM_VERSION
  ST r2,r1,#NKM_G_VERSION
  LD r2,r14,2
  ST r2,r1,#NKM_G_LIMIT
  MOVI r3,#NKM_MAXNODE
  ST r3,r1,#NKM_G_MAXNODE
  LD r2,r14,1
  ST r2,r1,#NKM_G_BUFFER
  MOVI r1,0
  JMP @nkmi_out
nkmi_bad:
  LA r1,0xFFFFFFFF
nkmi_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_find r1=hlo r2=hhi -> index / NONE.  Only public live nodes.
nkm_find:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  LA r3,#NKM_STATS
  LD r4,r3,#NKM_G_LOOKUPS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_LOOKUPS
  MOVI r5,0
  ST r5,r14,3
  LD r6,r3,#NKM_G_LIMIT
  LA r7,#NKM_NODES
nkmf_l:
  LD r5,r14,3
  CMP r5,r6
  JMP[GE] @nkmf_bad
  SHL r8,r5,6
  MOVI r9,8
  MUL r9,r5,r9
  SUB r8,r8,r9
  ADD r8,r7,r8
  LD r9,r8,#NKM_N_STATE
  CMP r9,r0
  JMP[EQ] @nkmf_next
  LD r9,r8,#NKM_N_KIND
  MOVI r10,#NKM_K_PUBLIC
  CMP r9,r10
  JMP[NE] @nkmf_next
  LD r9,r8,#NKM_N_HLO
  LD r10,r14,1
  CMP r9,r10
  JMP[NE] @nkmf_next
  LD r9,r8,#NKM_N_HHI
  LD r10,r14,2
  CMP r9,r10
  JMP[NE] @nkmf_next
  ST r5,r14,4
  LD r9,r8,#NKM_N_LOOKUPS
  ADD r9,r9,r13
  ST r9,r8,#NKM_N_LOOKUPS
  LD r9,r8,#NKM_N_HITS
  ADD r9,r9,r13
  ST r9,r8,#NKM_N_HITS
  LA r3,#NKM_STATS
  LD r4,r3,#NKM_G_HITS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_HITS
  LD r1,r14,4
  JMP @nkmf_out
nkmf_next:
  LD r5,r14,3
  ADD r5,r5,r13
  ST r5,r14,3
  JMP @nkmf_l
nkmf_bad:
  LA r1,#NKM_NONE
nkmf_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_add r1=values r2=used r3=gen r4=parent idx ptr r5=pcount r6=owner
;         -> node index / NONE.  Dedup by full node identity; collision when
;         the hash matches but a committed field differs.
nkm_add:
  ST r15,r14,0
  ADDI r14,r14,128
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  CMP r1,r0
  JMP[EQ] @nkma2_bad
  CMP r2,r0
  JMP[EQ] @nkma2_bad
  MOVI r7,#NKM_SLOTS
  CMP r2,r7
  JMP[GT] @nkma2_bad
  MOVI r7,4
  CMP r5,r7
  JMP[GT] @nkma2_bad
  ; resolve parent hashes into +32 lo[4], +40 hi[4]
  ST r0,r14,7
nkma2_rl:
  LD r7,r14,7
  LD r5,r14,5
  CMP r7,r5
  JMP[GE] @nkma2_rdone
  LD r4,r14,4
  ADD r4,r4,r7
  LD r1,r4,0
  MOVI r6,#NKM_MAXNODE
  CMP r1,r6
  JMP[GE] @nkma2_bad
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkma2_bad
  ST r1,r14,8
  LD r6,r1,#NKM_N_STATE
  CMP r6,r13
  JMP[NE] @nkma2_bad
  LD r6,r1,#NKM_N_KIND
  MOVI r9,#NKM_K_PUBLIC
  CMP r6,r9
  JMP[NE] @nkma2_bad
  LD r7,r14,7
  LD r6,r1,#NKM_N_HLO
  ADD r9,r14,r7
  ADDI r9,r9,32
  ST r6,r9,0
  LD r6,r1,#NKM_N_HHI
  ADD r9,r14,r7
  ADDI r9,r9,40
  ST r6,r9,0
  ; reject duplicate parent index (pairwise, ordered identity)
  ST r0,r14,9
nkma2_dl:
  LD r9,r14,9
  LD r5,r14,7
  CMP r9,r5
  JMP[GE] @nkma2_dnext
  LD r4,r14,4
  ADD r4,r4,r9
  LD r6,r4,0
  LD r4,r14,4
  ADD r4,r4,r7
  LD r10,r4,0
  CMP r6,r10
  JMP[NE] @nkma2_dinc
  ; same slot is fine; different slots with same index is a duplicate
  LD r9,r14,7
  LD r5,r14,9
  CMP r9,r5
  JMP[EQ] @nkma2_dinc
  JMP @nkma2_bad
nkma2_dinc:
  LD r9,r14,9
  ADD r9,r9,r13
  ST r9,r14,9
  JMP @nkma2_dl
nkma2_dnext:
  LD r7,r14,7
  ADD r7,r7,r13
  ST r7,r14,7
  JMP @nkma2_rl
nkma2_rdone:
  ; candidate hash
  LD r1,r14,1
  LD r2,r14,2
  LD r3,r14,3
  LD r4,r14,5
  ADD r5,r14,r0
  ADDI r5,r5,32
  ADD r6,r14,r0
  ADDI r6,r6,40
  CALL @nkm_hash_arrays
  ST r1,r14,10
  ST r2,r14,11
  ; scan for an equal hash
  MOVI r7,0
  ST r7,r14,12
  LA r8,#NKM_STATS
  LD r8,r8,#NKM_G_LIMIT
  LA r9,#NKM_NODES
nkma2_sl:
  LD r7,r14,12
  CMP r7,r8
  JMP[GE] @nkma2_new
  SHL r10,r7,6
  MOVI r11,8
  MUL r11,r7,r11
  SUB r10,r10,r11
  ADD r10,r9,r10
  LD r11,r10,#NKM_N_STATE
  CMP r11,r0
  JMP[EQ] @nkma2_snext
  LD r11,r10,#NKM_N_KIND
  MOVI r12,#NKM_K_PUBLIC
  CMP r11,r12
  JMP[NE] @nkma2_snext
  LD r11,r10,#NKM_N_HLO
  LD r12,r14,10
  CMP r11,r12
  JMP[NE] @nkma2_snext
  LD r11,r10,#NKM_N_HHI
  LD r12,r14,11
  CMP r11,r12
  JMP[NE] @nkma2_snext
  ; hash hit: identity must match exactly
  ST r10,r14,13
  ADD r1,r10,r0
  LD r2,r14,1
  LD r3,r14,2
  LD r4,r14,3
  LD r5,r14,5
  ADD r6,r14,r0
  ADDI r6,r6,32
  ADD r7,r14,r0
  ADDI r7,r7,40
  CALL @nkm_same
  CMP r1,r0
  JMP[EQ] @nkma2_coll
  ; dedup acquire
  LD r10,r14,13
  LD r6,r10,#NKM_N_REFS
  ADD r6,r6,r13
  ST r6,r10,#NKM_N_REFS
  LD r6,r10,#NKM_N_DEDUP
  ADD r6,r6,r13
  ST r6,r10,#NKM_N_DEDUP
  LA r5,#NKM_STATS
  LD r6,r5,#NKM_G_DEDUP
  ADD r6,r6,r13
  ST r6,r5,#NKM_G_DEDUP
  LD r6,r5,#NKM_G_REFS
  ADD r6,r6,r13
  ST r6,r5,#NKM_G_REFS
  LD r6,r5,#NKM_G_OPS
  ADD r6,r6,r13
  ST r6,r5,#NKM_G_OPS
  LD r1,r10,#NKM_N_IDX
  JMP @nkma2_out
nkma2_snext:
  LD r7,r14,12
  ADD r7,r7,r13
  ST r7,r14,12
  JMP @nkma2_sl
nkma2_new:
  MOVI r1,#NKM_K_PUBLIC
  LD r2,r14,3
  LD r3,r14,6
  CALL @nkm_node_alloc
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[EQ] @nkma2_nospc
  ST r1,r14,14
  CALL @nkm_nodeptr
  ST r1,r14,15
  ; copy used content
  LD r2,r1,#NKM_N_PAY
  LD r5,r14,1
  LD r3,r14,2
  MOVI r4,0
nkma2_cp:
  CMP r4,r3
  JMP[GE] @nkma2_cpd
  ADD r6,r5,r4
  LD r6,r6,0
  ADD r7,r2,r4
  ST r6,r7,0
  ADD r4,r4,r13
  JMP @nkma2_cp
nkma2_cpd:
  LD r2,r14,15
  LD r3,r14,2
  ST r3,r2,#NKM_N_USED
  LD r3,r14,3
  ST r3,r2,#NKM_N_BGEN
  LD r3,r14,5
  ST r3,r2,#NKM_N_PCOUNT
  LD r3,r14,10
  ST r3,r2,#NKM_N_HLO
  LD r3,r14,11
  ST r3,r2,#NKM_N_HHI
  ; copy parent indices and hashes, acquire parent refs
  MOVI r4,0
nkma2_pc:
  LD r5,r14,5
  CMP r4,r5
  JMP[GE] @nkma2_pdone
  LD r6,r14,4
  ADD r6,r6,r4
  LD r6,r6,0
  LD r2,r14,15
  ADD r7,r2,r4
  ST r6,r7,#NKM_N_PIDX
  ADD r8,r14,r4
  ADDI r8,r8,32
  LD r8,r8,0
  ADD r7,r2,r4
  ST r8,r7,#NKM_N_PHLO
  ADD r8,r14,r4
  ADDI r8,r8,40
  LD r8,r8,0
  ADD r7,r2,r4
  ST r8,r7,#NKM_N_PHHI
  ; parent acquire
  ADD r1,r6,r0
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkma2_bad
  LD r8,r1,#NKM_N_REFS
  ADD r8,r8,r13
  ST r8,r1,#NKM_N_REFS
  LD r8,r1,#NKM_N_CHILDREN
  ADD r8,r8,r13
  ST r8,r1,#NKM_N_CHILDREN
  LA r9,#NKM_STATS
  LD r8,r9,#NKM_G_REFS
  ADD r8,r8,r13
  ST r8,r9,#NKM_G_REFS
  ADD r4,r4,r13
  JMP @nkma2_pc
nkma2_pdone:
  LD r1,r14,14
  JMP @nkma2_out
nkma2_coll:
  MOVI r1,0
  MOVI r2,#NKM_ECOLL
  CALL @nkm_fail
  LA r1,#NKM_NONE
  JMP @nkma2_out
nkma2_nospc:
  MOVI r1,0
  MOVI r2,#NKM_ENOSPC
  CALL @nkm_fail
  LA r1,#NKM_NONE
  JMP @nkma2_out
nkma2_bad:
  MOVI r1,0
  MOVI r2,#NKM_EBAD
  CALL @nkm_fail
  LA r1,#NKM_NONE
nkma2_out:
  ADDI r14,r14,-128
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_open r1=ctx r2=agent r3=gen r4=cpu r5=branch r6=nagent
;          r7=table r8=cap r9=tokens/block -> 1/0
nkm_open:
  ST r15,r14,0
  ADDI r14,r14,80
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  ST r7,r14,7
  ST r8,r14,8
  ST r9,r14,9
  CMP r1,r0
  JMP[EQ] @nkmo_bad
  CMP r2,r0
  JMP[EQ] @nkmo_bad
  CMP r3,r0
  JMP[EQ] @nkmo_bad
  CMP r7,r0
  JMP[EQ] @nkmo_bad
  CMP r8,r0
  JMP[EQ] @nkmo_bad
  CMP r9,r0
  JMP[EQ] @nkmo_bad
  MOVI r10,#NKM_SLOTS
  CMP r9,r10
  JMP[GT] @nkmo_bad
  MOVI r10,32
  CMP r8,r10
  JMP[GT] @nkmo_bad
  MOVI r10,#NG_MAX_CPU
  CMP r4,r10
  JMP[GE] @nkmo_bad
  LD r10,r14,6
  CMP r10,r0
  JMP[EQ] @nkmo_clear
  ADD r1,r10,r0
  CALL @nagent_verify
  CMP r1,r0
  JMP[NE] @nkmo_bad
nkmo_clear:
  LD r1,r14,1
  MOVI r2,32
nkmo_z:
  CMP r2,r0
  JMP[EQ] @nkmo_fill
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkmo_z
nkmo_fill:
  LD r1,r14,1
  LA r2,#NKM_CMAGIC
  ST r2,r1,#NKM_C_MAGIC
  MOVI r2,#NKM_VERSION
  ST r2,r1,#NKM_C_VERSION
  LD r2,r14,2
  ST r2,r1,#NKM_C_AGENT
  LD r2,r14,3
  ST r2,r1,#NKM_C_GEN
  LD r2,r14,5
  ST r2,r1,#NKM_C_BRANCH
  LD r2,r14,6
  ST r2,r1,#NKM_C_NAGENT
  LD r2,r14,7
  ST r2,r1,#NKM_C_TAB
  LD r2,r14,8
  ST r2,r1,#NKM_C_TABCAP
  LD r2,r14,9
  ST r2,r1,#NKM_C_BLOCKTOK
  MOVI r2,#NKM_BPT_BYTES
  ST r2,r1,#NKM_C_BPT
  MOVI r2,#NKM_SLOTS
  ST r2,r1,#NKM_C_SLOTS
  LA r2,#NKM_NONE
  ST r2,r1,#NKM_C_ROOT
  LD r1,r14,2
  LD r2,r14,3
  LD r3,r14,4
  CALL @ngen_enter
  LD r4,r14,3
  CMP r1,r4
  JMP[EQ] @nkmo_admit
  LD r1,r14,1
  CALL @ngen_errno
  LD r2,r14,1
  ST r1,r2,#NKM_C_NGERR
  MOVI r2,#NKM_ESTALE
  CALL @nkm_fail
  JMP @nkmo_out
nkmo_admit:
  LD r1,r14,7
  LD r2,r14,8
  SHL r2,r2,3
nkmo_t:
  CMP r2,r0
  JMP[EQ] @nkmo_sent
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkmo_t
nkmo_sent:
  LD r1,r14,7
  LD r2,r14,8
  LA r3,#NKM_NONE
nkmo_sl:
  CMP r2,r0
  JMP[EQ] @nkmo_done
  ST r3,r1,#NKM_E_NODE
  ADDI r1,r1,8
  SUB r2,r2,r13
  JMP @nkmo_sl
nkmo_done:
  LD r1,r14,1
  MOVI r2,1
  ST r2,r1,#NKM_C_ADMIT
  LD r2,r14,2
  ADD r1,r2,r0
  CALL @ngen_epoch
  LD r2,r14,1
  ST r1,r2,#NKM_C_EPOCH
  LA r3,#NKM_STATS
  LD r4,r3,#NKM_G_OPENS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_OPENS
  LD r4,r3,#NKM_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_OPS
  LD r2,r14,5
  LD r3,r14,3
  MOVI r1,#NKM_T_OPEN
  MOVI r4,0
  CALL @nkm_trace_add
  MOVI r1,1
  JMP @nkmo_out
nkmo_bad:
  LD r1,r14,1
  MOVI r2,#NKM_EBAD
  CALL @nkm_fail
nkmo_out:
  ADDI r14,r14,-80
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_bind_root r1=ctx r2=root hash lo -> 1/0.
nkm_bind_root:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,#NKM_C_NAGENT
  CMP r3,r0
  JMP[EQ] @nkbr_ok
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @nkbr_ok
  ADD r1,r3,r0
  MOVI r2,0
  LD r3,r14,2
  CALL @nagent_roots
  CMP r1,r0
  JMP[NE] @nkbr_bad
  LA r3,#NKM_STATS
  LD r4,r3,#NKM_G_ROOTS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_ROOTS
  LD r4,r3,#NKM_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_OPS
  MOVI r1,1
  JMP @nkbr_out
nkbr_bad:
  MOVI r1,0
  JMP @nkbr_out
nkbr_ok:
  MOVI r1,1
nkbr_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_publish r1=ctx r2=new generation -> epoch / 0.
nkm_publish:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,#NKM_C_MAGIC
  LA r4,#NKM_CMAGIC
  CMP r3,r4
  JMP[NE] @nkmpub_bad
  LD r3,r1,#NKM_C_ADMIT
  CMP r3,r0
  JMP[EQ] @nkmpub_bad
  LD r1,r1,#NKM_C_AGENT
  LD r2,r14,2
  MOVI r3,0
  MOVI r4,0
  CALL @ngen_publish
  CMP r1,r0
  JMP[EQ] @nkmpub_stale
  ST r1,r14,3
  LD r2,r14,1
  ST r1,r2,#NKM_C_EPOCH
  LA r3,#NKM_STATS
  LD r4,r3,#NKM_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_OPS
  LD r2,r2,#NKM_C_BRANCH
  LD r3,r14,2
  MOVI r1,#NKM_T_PUBLISH
  MOVI r4,0
  CALL @nkm_trace_add
  LD r1,r14,3
  JMP @nkmpub_out
nkmpub_bad:
  LD r1,r14,1
  MOVI r2,#NKM_EBAD
  CALL @nkm_fail
  JMP @nkmpub_out
nkmpub_stale:
  LD r1,r14,1
  MOVI r2,#NKM_ESTALE
  CALL @nkm_fail
nkmpub_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_seal r1=ctx -> 1/0.
nkm_seal:
  ST r15,r14,0
  ADDI r14,r14,128
  ST r1,r14,1
  LD r2,r1,#NKM_C_MAGIC
  LA r3,#NKM_CMAGIC
  CMP r2,r3
  JMP[NE] @nkms_bad
  LD r2,r1,#NKM_C_ADMIT
  CMP r2,r0
  JMP[EQ] @nkms_bad
  LD r2,r1,#NKM_C_LIVE
  CMP r2,r0
  JMP[EQ] @nkms_bad
  LD r2,r1,#NKM_C_SEALED
  CMP r2,r0
  JMP[NE] @nkms_dup
  MOVI r4,0
  ST r4,r14,2
  LA r4,#NKM_NONE
  ST r4,r14,3
nkms_l:
  LD r4,r14,2
  LD r2,r14,1
  LD r2,r2,#NKM_C_LIVE
  CMP r4,r2
  JMP[GE] @nkms_done
  LD r1,r14,1
  LD r1,r1,#NKM_C_TAB
  SHL r5,r4,3
  ADD r1,r1,r5
  ST r1,r14,4
  LD r2,r1,#NKM_E_NODE
  LA r3,#NKM_NONE
  CMP r2,r3
  JMP[EQ] @nkms_bad
  ST r2,r14,5
  LD r1,r14,5
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkms_bad
  ST r1,r14,6
  LD r6,r1,#NKM_N_STATE
  MOVI r7,1
  CMP r6,r7
  JMP[NE] @nkms_bad
  LD r6,r1,#NKM_N_KIND
  MOVI r7,#NKM_K_PRIV
  CMP r6,r7
  JMP[NE] @nkms_shared
  ; candidate parent list: previous table node, at most one
  LD r6,r1,#NKM_N_USED
  ST r6,r14,7
  LD r7,r1,#NKM_N_PAY
  ST r7,r14,8
  MOVI r8,0
  ST r8,r14,9
  LD r4,r14,2
  CMP r4,r0
  JMP[EQ] @nkms_nopar
  ; prev entry must exist
  LD r1,r14,1
  LD r1,r1,#NKM_C_TAB
  LD r4,r14,2
  ADDI r4,r4,-1
  SHL r5,r4,3
  ADD r1,r1,r5
  LD r2,r1,#NKM_E_NODE
  LA r3,#NKM_NONE
  CMP r2,r3
  JMP[EQ] @nkms_bad
  ST r2,r14,10
  ST r13,r14,9
  JMP @nkms_hash
nkms_nopar:
  LA r7,#NKM_NONE
  ST r7,r14,10
nkms_hash:
  ; record dedup stats before the add
  LA r3,#NKM_STATS
  LD r4,r3,#NKM_G_DEDUP
  ST r4,r14,11
  ; candidate hash for diagnostics is nkm_add's job; call add
  LD r1,r14,8
  LD r2,r14,7
  LD r3,r14,1
  LD r3,r3,#NKM_C_GEN
  ADD r4,r14,r0
  ADDI r4,r4,16
  ; write parent index array at +16
  LD r5,r14,10
  ST r5,r14,16
  LD r5,r14,9
  LD r6,r14,1
  LD r6,r6,#NKM_C_AGENT
  CALL @nkm_add
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[EQ] @nkms_addfail
  ST r1,r14,12
  ; install entry
  LD r1,r14,4
  LD r3,r14,12
  ST r3,r1,#NKM_E_NODE
  LD r3,r14,1
  LD r3,r3,#NKM_C_GEN
  ST r3,r1,#NKM_E_MAPGEN
  MOVI r3,#NKM_F_SHARED
  ST r3,r1,#NKM_E_FLAGS
  LD r1,r14,12
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkms_bad
  ST r1,r14,6
  LD r2,r1,#NKM_N_HLO
  LD r3,r14,4
  ST r2,r3,#NKM_E_HLO
  LD r2,r1,#NKM_N_HHI
  ST r2,r3,#NKM_E_HHI
  LD r2,r1,#NKM_N_IDX
  ST r2,r3,#NKM_E_IDX
  ; dedup or new trace
  LA r3,#NKM_STATS
  LD r4,r3,#NKM_G_DEDUP
  LD r5,r14,11
  CMP r4,r5
  JMP[EQ] @nkms_trnew
  LD r2,r14,1
  LD r3,r2,#NKM_C_DEDUP
  ADD r3,r3,r13
  ST r3,r2,#NKM_C_DEDUP
  MOVI r1,#NKM_T_DEDUP
  LD r2,r14,1
  LD r2,r2,#NKM_C_BRANCH
  LD r3,r14,12
  LD r4,r14,7
  CALL @nkm_trace_add
  JMP @nkms_install
nkms_trnew:
  MOVI r1,#NKM_T_NEW
  LD r2,r14,1
  LD r2,r2,#NKM_C_BRANCH
  LD r3,r14,12
  LD r4,r14,7
  CALL @nkm_trace_add
nkms_install:
  LD r1,r14,1
  LD r2,r14,5
  CALL @nkm_node_release
  LD r2,r14,12
  ST r2,r14,3
  JMP @nkms_next
nkms_shared:
  ; already public: keep it as the chain tip
  LD r2,r14,5
  ST r2,r14,3
nkms_next:
  LD r4,r14,2
  ADD r4,r4,r13
  ST r4,r14,2
  JMP @nkms_l
nkms_done:
  LD r1,r14,1
  MOVI r2,1
  ST r2,r1,#NKM_C_SEALED
  LD r3,r14,3
  ST r3,r1,#NKM_C_ROOT
  LA r4,#NKM_NONE
  CMP r3,r4
  JMP[EQ] @nkms_bad
  LD r2,r1,#NKM_C_TAB
  LD r3,r1,#NKM_C_LIVE
  SUB r3,r3,r13
  SHL r3,r3,3
  ADD r2,r2,r3
  LD r1,r2,#NKM_E_NODE
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkms_bad
  LD r2,r1,#NKM_N_HLO
  LD r3,r1,#NKM_N_HHI
  LD r1,r14,1
  ST r2,r1,#NKM_C_HLO
  ST r3,r1,#NKM_C_HHI
  LD r4,r1,#NKM_C_LIVE
  ST r4,r1,#NKM_C_PREFIX
  ST r4,r1,#NKM_C_DEPTH
  ADD r2,r2,r0
  CALL @nkm_bind_root
  CMP r1,r0
  JMP[EQ] @nkms_bad
  LA r3,#NKM_STATS
  LD r4,r3,#NKM_G_SEALS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_SEALS
  LD r4,r3,#NKM_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_OPS
  LD r1,r14,1
  LD r2,r1,#NKM_C_BRANCH
  LD r3,r1,#NKM_C_PREFIX
  LD r4,r1,#NKM_C_HLO
  MOVI r1,#NKM_T_SEAL
  CALL @nkm_trace_add
  MOVI r1,1
  JMP @nkms_out
nkms_addfail:
  LD r1,r14,1
  CALL @nkm_errno
  LD r2,r14,1
  ST r1,r2,#NKM_C_ERR
  MOVI r1,0
  JMP @nkms_out
nkms_dup:
  LD r1,r14,1
  MOVI r2,#NKM_EDUP
  CALL @nkm_fail
  JMP @nkms_out
nkms_bad:
  LD r1,r14,1
  MOVI r2,#NKM_EBAD
  CALL @nkm_fail
nkms_out:
  ADDI r14,r14,-128
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_join r1=ctx r2=root lo r3=root hi -> 1/0.
; Single-parent prefix chains only; a multi-parent root is a valid proof root
; but is not materialized into one linear token table here.
nkm_join:
  ST r15,r14,0
  ADDI r14,r14,160
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LD r4,r1,#NKM_C_MAGIC
  LA r5,#NKM_CMAGIC
  CMP r4,r5
  JMP[NE] @nkmj_bad
  LD r4,r1,#NKM_C_ADMIT
  CMP r4,r0
  JMP[EQ] @nkmj_bad
  LD r4,r1,#NKM_C_USED
  CMP r4,r0
  JMP[NE] @nkmj_bad
  LD r4,r1,#NKM_C_LIVE
  CMP r4,r0
  JMP[NE] @nkmj_bad
  LD r1,r14,2
  LD r2,r14,3
  CALL @nkm_find
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[EQ] @nkmj_none
  ST r1,r14,4
  ; walk parent[0] chain into temp at +32
  MOVI r5,0
  ST r5,r14,5
  LD r6,r14,4
  ST r6,r14,6
nkmj_walk:
  LD r6,r14,6
  LA r7,#NKM_NONE
  CMP r6,r7
  JMP[EQ] @nkmj_walked
  LD r5,r14,5
  LD r4,r14,1
  LD r4,r4,#NKM_C_TABCAP
  CMP r5,r4
  JMP[GE] @nkmj_nospc
  MOVI r7,16
  CMP r5,r7
  JMP[GE] @nkmj_nospc
  ADD r1,r6,r0
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkmj_none
  ST r1,r14,7
  LD r2,r1,#NKM_N_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nkmj_none
  LD r2,r1,#NKM_N_KIND
  MOVI r3,#NKM_K_PUBLIC
  CMP r2,r3
  JMP[NE] @nkmj_none
  LD r2,r1,#NKM_N_PCOUNT
  MOVI r3,1
  CMP r2,r3
  JMP[GT] @nkmj_bad
  ; temp[count] = node index
  LD r5,r14,5
  ADD r6,r14,r5
  ADDI r6,r6,32
  LD r3,r1,#NKM_N_IDX
  ST r3,r6,0
  ADD r5,r5,r13
  ST r5,r14,5
  LD r2,r1,#NKM_N_PCOUNT
  CMP r2,r0
  JMP[EQ] @nkmj_walked
  LD r6,r1,#NKM_N_PIDX
  ST r6,r14,6
  JMP @nkmj_walk
nkmj_walked:
  LD r5,r14,5
  CMP r5,r0
  JMP[EQ] @nkmj_none
  ; install oldest..newest
  MOVI r6,0
  ST r6,r14,8
nkmj_inst:
  LD r6,r14,8
  LD r5,r14,5
  CMP r6,r5
  JMP[GE] @nkmj_installed
  SUB r7,r5,r13
  SUB r7,r7,r6
  ADD r7,r14,r7
  ADDI r7,r7,32
  LD r1,r7,0
  ST r1,r14,9
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkmj_none
  ST r1,r14,10
  LD r2,r1,#NKM_N_REFS
  ADD r2,r2,r13
  ST r2,r1,#NKM_N_REFS
  LD r2,r1,#NKM_N_JOINS
  ADD r2,r2,r13
  ST r2,r1,#NKM_N_JOINS
  LA r4,#NKM_STATS
  LD r3,r4,#NKM_G_REFS
  ADD r3,r3,r13
  ST r3,r4,#NKM_G_REFS
  LD r3,r4,#NKM_G_JOINREFS
  ADD r3,r3,r13
  ST r3,r4,#NKM_G_JOINREFS
  LD r3,r4,#NKM_G_OPS
  ADD r3,r3,r13
  ST r3,r4,#NKM_G_OPS
  LD r2,r14,1
  LD r2,r2,#NKM_C_TAB
  LD r3,r14,8
  SHL r3,r3,3
  ADD r2,r2,r3
  LD r3,r14,9
  ST r3,r2,#NKM_E_NODE
  LD r5,r14,1
  LD r5,r5,#NKM_C_GEN
  ST r5,r2,#NKM_E_MAPGEN
  MOVI r5,#NKM_F_SHARED
  ST r5,r2,#NKM_E_FLAGS
  LD r1,r14,10
  LD r5,r1,#NKM_N_HLO
  ST r5,r2,#NKM_E_HLO
  LD r5,r1,#NKM_N_HHI
  ST r5,r2,#NKM_E_HHI
  LD r5,r1,#NKM_N_IDX
  ST r5,r2,#NKM_E_IDX
  LD r5,r1,#NKM_N_USED
  LD r2,r14,1
  LD r3,r2,#NKM_C_USED
  ADD r3,r3,r5
  ST r3,r2,#NKM_C_USED
  LD r3,r2,#NKM_C_LIVE
  ADD r3,r3,r13
  ST r3,r2,#NKM_C_LIVE
  LD r6,r14,8
  ADD r6,r6,r13
  ST r6,r14,8
  JMP @nkmj_inst
nkmj_installed:
  LD r1,r14,1
  LD r2,r14,5
  ST r2,r1,#NKM_C_PREFIX
  ST r2,r1,#NKM_C_DEPTH
  LD r3,r14,4
  ST r3,r1,#NKM_C_ROOT
  LD r4,r14,2
  ST r4,r1,#NKM_C_HLO
  LD r4,r14,3
  ST r4,r1,#NKM_C_HHI
  LD r2,r1,#NKM_C_JOINS
  ADD r2,r2,r13
  ST r2,r1,#NKM_C_JOINS
  LA r4,#NKM_STATS
  LD r5,r4,#NKM_G_JOINOPS
  ADD r5,r5,r13
  ST r5,r4,#NKM_G_JOINOPS
  LD r5,r4,#NKM_G_OPS
  ADD r5,r5,r13
  ST r5,r4,#NKM_G_OPS
  LD r2,r14,2
  CALL @nkm_bind_root
  CMP r1,r0
  JMP[EQ] @nkmj_bad
  LD r1,r14,1
  LD r2,r1,#NKM_C_BRANCH
  LD r3,r14,2
  LD r4,r14,5
  MOVI r1,#NKM_T_JOIN
  CALL @nkm_trace_add
  MOVI r1,1
  JMP @nkmj_out
nkmj_bad:
  LD r1,r14,1
  MOVI r2,#NKM_EBAD
  CALL @nkm_fail
  JMP @nkmj_out
nkmj_none:
  LD r1,r14,1
  MOVI r2,#NKM_ENOENT
  CALL @nkm_fail
  JMP @nkmj_out
nkmj_nospc:
  LD r1,r14,1
  MOVI r2,#NKM_ENOSPC
  CALL @nkm_fail
nkmj_out:
  ADDI r14,r14,-160
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_cow r1=ctx r2=entry -> new private index / NONE.
nkm_cow:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  LD r6,r2,#NKM_E_NODE
  ST r6,r14,3
  ADD r1,r6,r0
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkmco_fail
  ST r1,r14,4
  LD r5,r1,#NKM_N_USED
  ST r5,r14,5
  LD r1,r14,1
  LD r2,r1,#NKM_C_GEN
  LD r3,r1,#NKM_C_AGENT
  MOVI r1,#NKM_K_PRIV
  CALL @nkm_node_alloc
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[EQ] @nkmco_fail
  ST r1,r14,6
  CALL @nkm_nodeptr
  ST r1,r14,7
  LD r4,r14,4
  LD r5,r4,#NKM_N_PAY
  LD r2,r14,7
  LD r6,r2,#NKM_N_PAY
  LD r3,r14,5
  MOVI r7,0
nkmco_cp:
  CMP r7,r3
  JMP[GE] @nkmco_cpd
  ADD r8,r5,r7
  LD r8,r8,0
  ADD r9,r6,r7
  ST r8,r9,0
  ADD r7,r7,r13
  JMP @nkmco_cp
nkmco_cpd:
  LD r2,r14,7
  LD r3,r14,5
  ST r3,r2,#NKM_N_USED
  LD r4,r14,4
  LD r5,r4,#NKM_N_COPIES
  ADD r5,r5,r13
  ST r5,r4,#NKM_N_COPIES
  LD r5,r4,#NKM_N_TCOPY
  ADD r5,r5,r3
  ST r5,r4,#NKM_N_TCOPY
  LA r5,#NKM_STATS
  LD r6,r5,#NKM_G_COWS
  ADD r6,r6,r13
  ST r6,r5,#NKM_G_COWS
  LD r6,r5,#NKM_G_TCOPY
  ADD r6,r6,r3
  ST r6,r5,#NKM_G_TCOPY
  LD r6,r5,#NKM_G_OPS
  ADD r6,r6,r13
  ST r6,r5,#NKM_G_OPS
  LD r1,r14,1
  LD r6,r1,#NKM_C_COPIES
  ADD r6,r6,r13
  ST r6,r1,#NKM_C_COPIES
  LD r2,r14,2
  LD r3,r14,6
  ST r3,r2,#NKM_E_NODE
  LD r3,r1,#NKM_C_GEN
  ST r3,r2,#NKM_E_MAPGEN
  MOVI r3,#NKM_F_PRIVATE
  ST r3,r2,#NKM_E_FLAGS
  ST r0,r2,#NKM_E_HLO
  ST r0,r2,#NKM_E_HHI
  LD r3,r14,6
  ST r3,r2,#NKM_E_IDX
  LD r2,r14,3
  CALL @nkm_node_release
  LD r1,r14,1
  LD r2,r1,#NKM_C_BRANCH
  LD r3,r14,3
  LD r4,r14,6
  MOVI r1,#NKM_T_COW
  CALL @nkm_trace_add
  LD r1,r14,6
  JMP @nkmco_out
nkmco_fail:
  LA r1,#NKM_NONE
nkmco_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_append r1=ctx r2=value -> token index / -1.
nkm_append:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,#NKM_C_MAGIC
  LA r4,#NKM_CMAGIC
  CMP r3,r4
  JMP[NE] @nkma_bad
  LD r3,r1,#NKM_C_ADMIT
  CMP r3,r0
  JMP[EQ] @nkma_stale
  CALL @nkm_ctx_live
  CMP r1,r0
  JMP[EQ] @nkma_stale
  LD r1,r14,1
  LD r3,r1,#NKM_C_USED
  ST r3,r14,3
  LD r4,r1,#NKM_C_BLOCKTOK
  LD r5,r1,#NKM_C_TABCAP
  MUL r5,r5,r4
  CMP r3,r5
  JMP[GE] @nkma_nospc
  DIVU r4,r3,r4
  ST r4,r14,4
  LD r5,r1,#NKM_C_BLOCKTOK
  MODU r6,r3,r5
  ST r6,r14,5
  LD r7,r1,#NKM_C_TAB
  SHL r8,r4,3
  ADD r7,r7,r8
  ST r7,r14,6
  LD r8,r7,#NKM_E_NODE
  LA r9,#NKM_NONE
  CMP r8,r9
  JMP[NE] @nkma_have
  LD r9,r1,#NKM_C_LIVE
  CMP r4,r9
  JMP[NE] @nkma_blk
  MOVI r1,#NKM_K_PRIV
  LD r2,r14,1
  LD r2,r2,#NKM_C_GEN
  LD r3,r14,1
  LD r3,r3,#NKM_C_AGENT
  CALL @nkm_node_alloc
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[EQ] @nkma_nospc
  ST r1,r14,7
  LD r7,r14,6
  ST r1,r7,#NKM_E_NODE
  LD r2,r14,1
  LD r2,r2,#NKM_C_GEN
  ST r2,r7,#NKM_E_MAPGEN
  MOVI r2,#NKM_F_PRIVATE
  ST r2,r7,#NKM_E_FLAGS
  ST r0,r7,#NKM_E_HLO
  ST r0,r7,#NKM_E_HHI
  LD r2,r14,7
  ST r2,r7,#NKM_E_IDX
  LD r3,r14,1
  LD r4,r3,#NKM_C_LIVE
  ADD r4,r4,r13
  ST r4,r3,#NKM_C_LIVE
  LD r2,r14,1
  LD r2,r2,#NKM_C_BRANCH
  LD r3,r14,7
  LD r4,r14,4
  MOVI r1,#NKM_T_NEW
  CALL @nkm_trace_add
  LD r8,r14,7
  JMP @nkma_have_alloc
nkma_have:
  ST r8,r14,7
  ADD r1,r8,r0
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkma_blk
  ST r1,r14,8
  LD r2,r1,#NKM_N_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nkma_blk
  LD r4,r1,#NKM_N_FLAGS
  MOVI r5,#NKM_F_SHARED
  BOOL.8 r4,r4,r5
  CMP r4,r0
  JMP[NE] @nkma_cow
  LD r4,r1,#NKM_N_REFS
  MOVI r5,1
  CMP r4,r5
  JMP[GT] @nkma_cow
  LD r1,r14,1
  LD r2,r1,#NKM_C_GEN
  LD r3,r14,8
  LD r3,r3,#NKM_N_BGEN
  CMP r3,r2
  JMP[NE] @nkma_blk
  LD r8,r14,7
  JMP @nkma_have_alloc
nkma_cow:
  LD r1,r14,1
  LD r2,r14,6
  CALL @nkm_cow
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[EQ] @nkma_nospc
  ST r1,r14,7
  ST r1,r14,8
nkma_have_alloc:
  LD r1,r14,7
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkma_blk
  ST r1,r14,8
  ADD r8,r1,r0
  LD r3,r14,5
  LD r4,r8,#NKM_N_USED
  CMP r3,r4
  JMP[NE] @nkma_blk
  LD r5,r8,#NKM_N_SLOTS
  CMP r4,r5
  JMP[GE] @nkma_blk
  LD r6,r8,#NKM_N_PAY
  ADD r6,r6,r3
  LD r1,r14,2
  ST r1,r6,0
  LD r1,r8,#NKM_N_USED
  ADD r1,r1,r13
  ST r1,r8,#NKM_N_USED
  LD r1,r14,1
  LD r2,r1,#NKM_C_USED
  ADD r2,r2,r13
  ST r2,r1,#NKM_C_USED
  LA r3,#NKM_STATS
  LD r4,r3,#NKM_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_OPS
  LD r1,r14,3
  JMP @nkma_out
nkma_bad:
  LD r1,r14,1
  MOVI r2,#NKM_EBAD
  CALL @nkm_fail
  JMP @nkma_out
nkma_blk:
  LD r1,r14,1
  MOVI r2,#NKM_EBLK
  CALL @nkm_fail
  JMP @nkma_out
nkma_stale:
  LD r1,r14,1
  MOVI r2,#NKM_ESTALE
  CALL @nkm_fail
  JMP @nkma_out
nkma_nospc:
  LD r1,r14,1
  MOVI r2,#NKM_ENOSPC
  CALL @nkm_fail
nkma_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_view_open r1=ctx r2=token r3=mode r4=out -> 1/0.
nkm_view_open:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  LD r5,r1,#NKM_C_MAGIC
  LA r6,#NKM_CMAGIC
  CMP r5,r6
  JMP[NE] @nkmvo_bad
  CMP r4,r0
  JMP[EQ] @nkmvo_bad
  CMP r3,r0
  JMP[EQ] @nkmvo_bad
  MOVI r5,2
  CMP r3,r5
  JMP[GT] @nkmvo_bad
  CALL @nkm_ctx_live
  CMP r1,r0
  JMP[EQ] @nkmvo_stale
  LD r1,r14,1
  LD r2,r14,2
  CALL @nkm_lookup
  ST r1,r14,5
  ST r2,r14,6
  ST r3,r14,7
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[EQ] @nkmvo_none
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkmvo_none
  ST r1,r14,8
  LD r2,r1,#NKM_N_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nkmvo_none
  LD r2,r1,#NKM_N_BGEN
  LD r3,r14,1
  LD r3,r3,#NKM_C_GEN
  CMP r2,r3
  JMP[EQ] @nkmvo_genok
  LD r2,r1,#NKM_N_FLAGS
  MOVI r3,#NKM_F_SHARED
  BOOL.8 r2,r2,r3
  CMP r2,r0
  JMP[EQ] @nkmvo_blk
nkmvo_genok:
  LD r1,r14,4
  MOVI r2,16
nkmvo_z:
  CMP r2,r0
  JMP[EQ] @nkmvo_meta
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkmvo_z
nkmvo_meta:
  LD r1,r14,4
  LA r2,#NKM_VMAGIC
  ST r2,r1,#NKM_V_MAGIC
  MOVI r2,#NKM_VERSION
  ST r2,r1,#NKM_V_VERSION
  LD r3,r14,1
  LD r2,r3,#NKM_C_GEN
  ST r2,r1,#NKM_V_CTXGEN
  LD r2,r3,#NKM_C_BRANCH
  ST r2,r1,#NKM_V_BRANCH
  LD r2,r14,2
  ST r2,r1,#NKM_V_TOKEN
  LD r2,r14,5
  ST r2,r1,#NKM_V_NODE
  LD r2,r14,8
  LD r2,r2,#NKM_N_BGEN
  ST r2,r1,#NKM_V_BGEN
  LD r2,r14,3
  ST r2,r1,#NKM_V_MODE
  LD r2,r14,7
  ST r2,r1,#NKM_V_FLAGS
  LD r2,r14,6
  ST r2,r1,#NKM_V_OFF
  LD r2,r3,#NKM_C_VOPEN
  ADD r2,r2,r13
  ST r2,r3,#NKM_C_VOPEN
  LA r2,#NKM_STATS
  LD r4,r2,#NKM_G_OPS
  ADD r4,r4,r13
  ST r4,r2,#NKM_G_OPS
  MOVI r1,1
  JMP @nkmvo_out
nkmvo_bad:
  LD r1,r14,1
  MOVI r2,#NKM_EBAD
  CALL @nkm_fail
  JMP @nkmvo_out
nkmvo_stale:
  LD r1,r14,1
  MOVI r2,#NKM_ESTALE
  CALL @nkm_fail
  JMP @nkmvo_out
nkmvo_none:
  LD r1,r14,1
  MOVI r2,#NKM_ENOENT
  CALL @nkm_fail
  JMP @nkmvo_out
nkmvo_blk:
  LD r1,r14,1
  MOVI r2,#NKM_EBLK
  CALL @nkm_fail
nkmvo_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_view_read r1=ctx r2=view r3=out(2) -> 1/0.
nkm_view_read:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LD r4,r1,#NKM_C_MAGIC
  LA r5,#NKM_CMAGIC
  CMP r4,r5
  JMP[NE] @nkmvr_bad
  LD r4,r2,#NKM_V_MAGIC
  LA r5,#NKM_VMAGIC
  CMP r4,r5
  JMP[NE] @nkmvr_bad
  LD r4,r2,#NKM_V_VERSION
  MOVI r5,#NKM_VERSION
  CMP r4,r5
  JMP[NE] @nkmvr_bad
  CMP r3,r0
  JMP[EQ] @nkmvr_bad
  LD r4,r2,#NKM_V_CTXGEN
  LD r5,r1,#NKM_C_GEN
  CMP r4,r5
  JMP[NE] @nkmvr_gen
  LD r4,r2,#NKM_V_BRANCH
  LD r5,r1,#NKM_C_BRANCH
  CMP r4,r5
  JMP[NE] @nkmvr_gen
  LD r4,r2,#NKM_V_MODE
  MOVI r5,1
  BOOL.8 r4,r4,r5
  CMP r4,r0
  JMP[EQ] @nkmvr_bad
  CALL @nkm_ctx_live
  CMP r1,r0
  JMP[EQ] @nkmvr_stale
  LD r1,r14,1
  LD r2,r14,2
  LD r2,r2,#NKM_V_TOKEN
  CALL @nkm_lookup
  ST r1,r14,5
  ST r2,r14,6
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[EQ] @nkmvr_blk
  LD r4,r14,2
  LD r5,r4,#NKM_V_NODE
  LD r1,r14,5
  CMP r1,r5
  JMP[NE] @nkmvr_blk
  LD r5,r4,#NKM_V_OFF
  LD r2,r14,6
  CMP r2,r5
  JMP[NE] @nkmvr_blk
  LD r1,r14,5
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkmvr_blk
  ST r1,r14,4
  LD r2,r1,#NKM_N_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nkmvr_stale
  LD r2,r14,2
  LD r3,r2,#NKM_V_BGEN
  LD r4,r1,#NKM_N_BGEN
  CMP r3,r4
  JMP[NE] @nkmvr_blk
  LD r4,r2,#NKM_V_OFF
  LD r5,r1,#NKM_N_PAY
  ADD r5,r5,r4
  LD r6,r5,0
  LD r1,r14,3
  ST r6,r1,0
  LD r2,r14,4
  LD r2,r2,#NKM_N_BGEN
  ST r2,r1,1
  LD r1,r14,1
  LD r2,r1,#NKM_C_VREAD
  ADD r2,r2,r13
  ST r2,r1,#NKM_C_VREAD
  LA r2,#NKM_STATS
  LD r3,r2,#NKM_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKM_G_OPS
  MOVI r1,1
  JMP @nkmvr_out
nkmvr_gen:
  LD r1,r14,1
  MOVI r2,#NKM_EGEN
  CALL @nkm_fail
  JMP @nkmvr_out
nkmvr_stale:
  LD r1,r14,1
  MOVI r2,#NKM_ESTALE
  CALL @nkm_fail
  JMP @nkmvr_out
nkmvr_bad:
  LD r1,r14,1
  MOVI r2,#NKM_EBAD
  CALL @nkm_fail
  JMP @nkmvr_out
nkmvr_blk:
  LD r1,r14,1
  MOVI r2,#NKM_EBLK
  CALL @nkm_fail
nkmvr_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_view_write r1=ctx r2=view r3=value -> 1/0.
nkm_view_write:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LD r4,r1,#NKM_C_MAGIC
  LA r5,#NKM_CMAGIC
  CMP r4,r5
  JMP[NE] @nkmvw_bad
  LD r4,r2,#NKM_V_MAGIC
  LA r5,#NKM_VMAGIC
  CMP r4,r5
  JMP[NE] @nkmvw_bad
  LD r4,r2,#NKM_V_VERSION
  MOVI r5,#NKM_VERSION
  CMP r4,r5
  JMP[NE] @nkmvw_bad
  LD r4,r2,#NKM_V_CTXGEN
  LD r5,r1,#NKM_C_GEN
  CMP r4,r5
  JMP[NE] @nkmvw_gen
  LD r4,r2,#NKM_V_BRANCH
  LD r5,r1,#NKM_C_BRANCH
  CMP r4,r5
  JMP[NE] @nkmvw_gen
  LD r4,r2,#NKM_V_MODE
  MOVI r5,2
  BOOL.8 r4,r4,r5
  CMP r4,r0
  JMP[EQ] @nkmvw_bad
  CALL @nkm_ctx_live
  CMP r1,r0
  JMP[EQ] @nkmvw_stale
  LD r1,r14,1
  LD r2,r14,2
  LD r2,r2,#NKM_V_TOKEN
  CALL @nkm_lookup
  ST r1,r14,5
  ST r2,r14,6
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[EQ] @nkmvw_blk
  LD r4,r14,2
  LD r5,r4,#NKM_V_NODE
  LD r1,r14,5
  CMP r1,r5
  JMP[NE] @nkmvw_blk
  LD r5,r4,#NKM_V_OFF
  LD r2,r14,6
  CMP r2,r5
  JMP[NE] @nkmvw_blk
  LD r1,r14,5
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkmvw_blk
  ST r1,r14,4
  LD r2,r1,#NKM_N_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nkmvw_stale
  LD r2,r1,#NKM_N_FLAGS
  MOVI r3,#NKM_F_SHARED
  BOOL.8 r2,r2,r3
  CMP r2,r0
  JMP[NE] @nkmvw_shared
  LD r2,r1,#NKM_N_REFS
  MOVI r3,1
  CMP r2,r3
  JMP[GT] @nkmvw_shared
  LD r2,r1,#NKM_N_BGEN
  LD r3,r14,1
  LD r3,r3,#NKM_C_GEN
  CMP r2,r3
  JMP[NE] @nkmvw_blk
  LD r2,r14,2
  LD r2,r2,#NKM_V_BGEN
  LD r1,r14,4
  LD r3,r1,#NKM_N_BGEN
  CMP r2,r3
  JMP[NE] @nkmvw_blk
  LD r2,r14,2
  LD r2,r2,#NKM_V_OFF
  LD r3,r1,#NKM_N_PAY
  ADD r3,r3,r2
  LD r4,r14,3
  ST r4,r3,0
  LD r1,r14,1
  LD r2,r1,#NKM_C_VWRITE
  ADD r2,r2,r13
  ST r2,r1,#NKM_C_VWRITE
  LA r2,#NKM_STATS
  LD r3,r2,#NKM_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKM_G_OPS
  MOVI r1,1
  JMP @nkmvw_out
nkmvw_gen:
  LD r1,r14,1
  MOVI r2,#NKM_EGEN
  CALL @nkm_fail
  JMP @nkmvw_out
nkmvw_stale:
  LD r1,r14,1
  MOVI r2,#NKM_ESTALE
  CALL @nkm_fail
  JMP @nkmvw_out
nkmvw_shared:
  LD r1,r14,1
  MOVI r2,#NKM_ESHARED
  CALL @nkm_fail
  JMP @nkmvw_out
nkmvw_bad:
  LD r1,r14,1
  MOVI r2,#NKM_EBAD
  CALL @nkm_fail
  JMP @nkmvw_out
nkmvw_blk:
  LD r1,r14,1
  MOVI r2,#NKM_EBLK
  CALL @nkm_fail
nkmvw_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_close r1=ctx -> 1/0.
nkm_close:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  LD r2,r1,#NKM_C_MAGIC
  LA r3,#NKM_CMAGIC
  CMP r2,r3
  JMP[NE] @nkmc_bad
  LD r2,r1,#NKM_C_ADMIT
  CMP r2,r0
  JMP[EQ] @nkmc_bad
  LD r3,r1,#NKM_C_TAB
  LD r4,r1,#NKM_C_LIVE
  ST r4,r14,2
  MOVI r5,0
  ST r5,r14,3
nkmc_l:
  LD r5,r14,3
  LD r4,r14,2
  CMP r5,r4
  JMP[GE] @nkmc_rel_done
  SHL r6,r5,3
  ADD r7,r3,r6
  ST r7,r14,4
  LD r2,r7,#NKM_E_NODE
  LA r4,#NKM_NONE
  CMP r2,r4
  JMP[EQ] @nkmc_next
  LD r1,r14,1
  CALL @nkm_node_release
  LD r7,r14,4
  ST r0,r7,#NKM_E_NODE
  ST r0,r7,#NKM_E_MAPGEN
  ST r0,r7,#NKM_E_FLAGS
  ST r0,r7,#NKM_E_HLO
  ST r0,r7,#NKM_E_HHI
  ST r0,r7,#NKM_E_IDX
nkmc_next:
  LD r5,r14,3
  ADD r5,r5,r13
  ST r5,r14,3
  LD r1,r14,1
  LD r3,r1,#NKM_C_TAB
  JMP @nkmc_l
nkmc_rel_done:
  LD r1,r14,1
  ST r0,r1,#NKM_C_LIVE
  ST r0,r1,#NKM_C_USED
  ST r0,r1,#NKM_C_ADMIT
  LD r2,r1,#NKM_C_BRANCH
  LD r3,r1,#NKM_C_GEN
  MOVI r1,#NKM_T_CLOSE
  MOVI r4,0
  CALL @nkm_trace_add
  LD r1,r14,1
  LD r2,r1,#NKM_C_AGENT
  LD r3,r1,#NKM_C_GEN
  ADD r1,r2,r0
  ADD r2,r3,r0
  CALL @ngen_exit
  CALL @ngen_errno
  CMP r1,r0
  JMP[NE] @nkmc_ngerr
  LA r2,#NKM_STATS
  LD r3,r2,#NKM_G_CLOSES
  ADD r3,r3,r13
  ST r3,r2,#NKM_G_CLOSES
  LD r3,r2,#NKM_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKM_G_OPS
  MOVI r1,1
  JMP @nkmc_out
nkmc_ngerr:
  LD r2,r14,1
  ST r1,r2,#NKM_C_NGERR
  MOVI r2,#NKM_ESTALE
  CALL @nkm_fail
  JMP @nkmc_out
nkmc_bad:
  LD r1,r14,1
  MOVI r2,#NKM_EBAD
  CALL @nkm_fail
nkmc_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_merge_n r1=ctx r2=values r3=used r4=parents ptr r5=count
;             -> root node index / NONE.
nkm_merge_n:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  LD r6,r1,#NKM_C_MAGIC
  LA r7,#NKM_CMAGIC
  CMP r6,r7
  JMP[NE] @nkmm_bad
  LD r6,r1,#NKM_C_ADMIT
  CMP r6,r0
  JMP[EQ] @nkmm_bad
  CALL @nkm_ctx_live
  CMP r1,r0
  JMP[EQ] @nkmm_stale
  LD r1,r14,1
  LD r6,r1,#NKM_C_LIVE
  CMP r6,r0
  JMP[NE] @nkmm_bad
  LD r6,r1,#NKM_C_USED
  CMP r6,r0
  JMP[NE] @nkmm_bad
  LD r6,r1,#NKM_C_SEALED
  CMP r6,r0
  JMP[NE] @nkmm_bad
  LD r2,r14,3
  CMP r2,r0
  JMP[EQ] @nkmm_bad
  MOVI r6,#NKM_SLOTS
  CMP r2,r6
  JMP[GT] @nkmm_bad
  LD r5,r14,5
  CMP r5,r0
  JMP[EQ] @nkmm_bad
  MOVI r6,4
  CMP r5,r6
  JMP[GT] @nkmm_bad
  LD r4,r14,4
  CMP r4,r0
  JMP[EQ] @nkmm_bad
  ; each parent live public
  MOVI r6,0
  ST r6,r14,6
nkmm_pl:
  LD r6,r14,6
  LD r5,r14,5
  CMP r6,r5
  JMP[GE] @nkmm_add
  LD r4,r14,4
  ADD r4,r4,r6
  LD r1,r4,0
  MOVI r7,#NKM_MAXNODE
  CMP r1,r7
  JMP[GE] @nkmm_bad
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkmm_bad
  LD r7,r1,#NKM_N_STATE
  CMP r7,r13
  JMP[NE] @nkmm_bad
  LD r7,r1,#NKM_N_KIND
  MOVI r8,#NKM_K_PUBLIC
  CMP r7,r8
  JMP[NE] @nkmm_bad
  LD r6,r14,6
  ADD r6,r6,r13
  ST r6,r14,6
  JMP @nkmm_pl
nkmm_add:
  LD r1,r14,2
  LD r2,r14,3
  LD r3,r14,1
  LD r3,r3,#NKM_C_GEN
  LD r4,r14,4
  LD r5,r14,5
  LD r6,r14,1
  LD r6,r6,#NKM_C_AGENT
  CALL @nkm_add
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[EQ] @nkmm_addfail
  ST r1,r14,7
  ; install as table slot 0
  LD r1,r14,1
  LD r1,r1,#NKM_C_TAB
  LD r2,r14,7
  ST r2,r1,#NKM_E_NODE
  LD r2,r14,1
  LD r2,r2,#NKM_C_GEN
  ST r2,r1,#NKM_E_MAPGEN
  MOVI r2,#NKM_F_SHARED
  ST r2,r1,#NKM_E_FLAGS
  LD r1,r14,7
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkmm_bad
  ST r1,r14,8
  LD r2,r1,#NKM_N_HLO
  LD r3,r14,1
  LD r3,r3,#NKM_C_TAB
  ST r2,r3,#NKM_E_HLO
  LD r2,r1,#NKM_N_HHI
  ST r2,r3,#NKM_E_HHI
  LD r2,r1,#NKM_N_IDX
  ST r2,r3,#NKM_E_IDX
  LD r2,r14,1
  MOVI r3,1
  ST r3,r2,#NKM_C_LIVE
  LD r3,r14,3
  ST r3,r2,#NKM_C_USED
  LD r3,r14,7
  ST r3,r2,#NKM_C_ROOT
  LD r1,r14,8
  LD r3,r1,#NKM_N_HLO
  ST r3,r2,#NKM_C_HLO
  LD r3,r1,#NKM_N_HHI
  ST r3,r2,#NKM_C_HHI
  MOVI r3,1
  ST r3,r2,#NKM_C_SEALED
  ST r3,r2,#NKM_C_PREFIX
  ST r3,r2,#NKM_C_DEPTH
  LD r2,r1,#NKM_N_HLO
  LD r1,r14,1
  CALL @nkm_bind_root
  CMP r1,r0
  JMP[EQ] @nkmm_bad
  LA r3,#NKM_STATS
  LD r4,r3,#NKM_G_MERGES
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_MERGES
  LD r4,r3,#NKM_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_OPS
  LD r1,r14,1
  LD r2,r1,#NKM_C_BRANCH
  LD r3,r14,7
  LD r4,r14,5
  MOVI r1,#NKM_T_MERGE
  CALL @nkm_trace_add
  LD r1,r14,7
  JMP @nkmm_out
nkmm_addfail:
  LD r1,r14,1
  CALL @nkm_errno
  LD r2,r14,1
  ST r1,r2,#NKM_C_ERR
  LA r1,#NKM_NONE
  JMP @nkmm_out
nkmm_stale:
  LD r1,r14,1
  MOVI r2,#NKM_ESTALE
  CALL @nkm_fail
  LA r1,#NKM_NONE
  JMP @nkmm_out
nkmm_bad:
  LD r1,r14,1
  MOVI r2,#NKM_EBAD
  CALL @nkm_fail
  LA r1,#NKM_NONE
nkmm_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; nkm_merge r1=ctx r2=values r3=used r4=parents ptr r5=count.
nkm_merge:
  JMP @nkm_merge_n

; ---------------------------------------------------------------------------
; nkm_dfs r1=index -> 1 if target reached.  Path root..target in NKM_PATH.
nkm_dfs:
  ST r15,r14,0
  ADDI r14,r14,80
  ST r1,r14,1
  MOVI r2,#NKM_MAXNODE
  CMP r1,r2
  JMP[GE] @nkmdfs_no
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkmdfs_no
  ST r1,r14,2
  LD r2,r1,#NKM_N_STATE
  CMP r2,r13
  JMP[NE] @nkmdfs_no
  LD r2,r1,#NKM_N_KIND
  MOVI r3,#NKM_K_PUBLIC
  CMP r2,r3
  JMP[NE] @nkmdfs_no
  LD r1,r14,1
  LA r2,#NKM_SEEN
  ADD r2,r2,r1
  LD r3,r2,0
  LA r4,#NKM_DFS_ID
  LD r5,r4,0
  CMP r3,r5
  JMP[EQ] @nkmdfs_no
  ST r5,r2,0
  LA r3,#NKM_DFS_DEPTH
  LD r4,r3,0
  MOVI r5,#NKM_PROOF_MAX
  CMP r4,r5
  JMP[GE] @nkmdfs_no
  LD r1,r14,1
  LA r5,#NKM_PATH
  ADD r5,r5,r4
  ST r1,r5,0
  ADD r4,r4,r13
  ST r4,r3,0
  LA r5,#NKM_DFS_TARGET
  LD r5,r5,0
  LD r1,r14,1
  CMP r1,r5
  JMP[EQ] @nkmdfs_yes
  ; explore parents in order
  LD r2,r14,2
  LD r3,r2,#NKM_N_PCOUNT
  ST r3,r14,3
  MOVI r4,0
  ST r4,r14,4
nkmdfs_pl:
  LD r4,r14,4
  LD r3,r14,3
  CMP r4,r3
  JMP[GE] @nkmdfs_back
  LD r2,r14,2
  ADD r5,r2,r4
  LD r5,r5,#NKM_N_PIDX
  LA r6,#NKM_NONE
  CMP r5,r6
  JMP[EQ] @nkmdfs_pnext
  ADD r1,r5,r0
  CALL @nkm_dfs
  CMP r1,r0
  JMP[NE] @nkmdfs_keep
nkmdfs_pnext:
  LD r4,r14,4
  ADD r4,r4,r13
  ST r4,r14,4
  JMP @nkmdfs_pl
nkmdfs_back:
  LA r3,#NKM_DFS_DEPTH
  LD r4,r3,0
  SUB r4,r4,r13
  ST r4,r3,0
nkmdfs_no:
  MOVI r1,0
  JMP @nkmdfs_out
nkmdfs_keep:
  MOVI r1,1
  JMP @nkmdfs_out
nkmdfs_yes:
  MOVI r1,1
nkmdfs_out:
  ADDI r14,r14,-80
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_proof r1=root idx r2=target idx r3=token off/NONE r4=proof -> 1/0.
nkm_proof:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  CMP r4,r0
  JMP[EQ] @nkprf_bad
  LD r1,r14,1
  MOVI r2,#NKM_MAXNODE
  CMP r1,r2
  JMP[GE] @nkprf_bad
  LD r1,r14,2
  CMP r1,r2
  JMP[GE] @nkprf_bad
  LD r1,r14,1
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkmp_none
  ST r1,r14,5
  LD r2,r1,#NKM_N_STATE
  CMP r2,r13
  JMP[NE] @nkmp_none
  LD r2,r1,#NKM_N_KIND
  MOVI r3,#NKM_K_PUBLIC
  CMP r2,r3
  JMP[NE] @nkmp_none
  LD r1,r14,2
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkmp_none
  ST r1,r14,6
  LD r2,r1,#NKM_N_STATE
  CMP r2,r13
  JMP[NE] @nkmp_none
  LD r2,r1,#NKM_N_KIND
  MOVI r3,#NKM_K_PUBLIC
  CMP r2,r3
  JMP[NE] @nkmp_none
  ; mode / token range
  LD r3,r14,3
  LA r4,#NKM_NONE
  CMP r3,r4
  JMP[NE] @nkmp_tok
  MOVI r5,1
  ST r5,r14,7
  LA r5,#NKM_NONE
  ST r5,r14,8
  ST r0,r14,9
  JMP @nkmp_search
nkmp_tok:
  LD r1,r14,6
  LD r2,r1,#NKM_N_USED
  CMP r3,r2
  JMP[GE] @nkprf_bad
  MOVI r5,2
  ST r5,r14,7
  ST r3,r14,8
  LD r1,r1,#NKM_N_PAY
  ADD r1,r1,r3
  LD r1,r1,0
  ST r1,r14,9
nkmp_search:
  LA r1,#NKM_DFS_TARGET
  LD r2,r14,2
  ST r2,r1,0
  LA r1,#NKM_DFS_ID
  LD r2,r1,0
  ADD r2,r2,r13
  ST r2,r1,0
  LA r1,#NKM_DFS_DEPTH
  ST r0,r1,0
  LD r1,r14,1
  CALL @nkm_dfs
  CMP r1,r0
  JMP[EQ] @nkmp_none
  LA r1,#NKM_DFS_DEPTH
  LD r2,r1,0
  ST r2,r14,10
  ; header
  LD r1,r14,4
  MOVI r2,16
nkmp_hz:
  CMP r2,r0
  JMP[EQ] @nkmp_hfill
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkmp_hz
nkmp_hfill:
  LD r1,r14,4
  LA r2,#NKM_PMAGIC
  ST r2,r1,#NKM_P_MAGIC
  MOVI r2,#NKM_VERSION
  ST r2,r1,#NKM_P_VERSION
  LD r2,r14,10
  ST r2,r1,#NKM_P_DEPTH
  LD r2,r14,7
  ST r2,r1,#NKM_P_MODE
  LD r2,r14,8
  ST r2,r1,#NKM_P_TOKOFF
  LD r2,r14,9
  ST r2,r1,#NKM_P_TOKVAL
  LD r3,r14,5
  LD r2,r3,#NKM_N_HLO
  ST r2,r1,#NKM_P_ROOTLO
  LD r2,r3,#NKM_N_HHI
  ST r2,r1,#NKM_P_ROOTHI
  LD r3,r14,6
  LD r2,r3,#NKM_N_HLO
  ST r2,r1,#NKM_P_TARGLO
  LD r2,r3,#NKM_N_HHI
  ST r2,r1,#NKM_P_TARGHI
  LD r2,r3,#NKM_N_USED
  ST r2,r1,#NKM_P_USED
  LD r2,r3,#NKM_N_BGEN
  ST r2,r1,#NKM_P_GEN
  MOVI r2,1
  ST r2,r1,#NKM_P_FLAGS
  ; entries target..root
  MOVI r11,0
  ST r11,r14,11
nkmp_el:
  LD r11,r14,11
  LD r2,r14,10
  CMP r11,r2
  JMP[GE] @nkmp_done
  ; path index = depth-1-i
  SUB r2,r2,r13
  SUB r2,r2,r11
  LA r3,#NKM_PATH
  ADD r3,r3,r2
  LD r3,r3,0
  ST r3,r14,12
  ADD r1,r3,r0
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkprf_bad
  ST r1,r14,13
  ; entry address
  LD r1,r14,4
  SHL r2,r11,5
  ADDI r1,r1,#NKM_PENTRY
  ADD r1,r1,r2
  ST r1,r14,14
  ; zero 32 words
  MOVI r2,32
  ADD r3,r1,r0
nkmp_ez:
  CMP r2,r0
  JMP[EQ] @nkmp_efill
  ST r0,r3,0
  ADD r3,r3,r13
  SUB r2,r2,r13
  JMP @nkmp_ez
nkmp_efill:
  LD r1,r14,13
  LD r2,r1,#NKM_N_USED
  LD r3,r14,14
  ST r2,r3,#NKM_PE_USED
  LD r2,r1,#NKM_N_BGEN
  ST r2,r3,#NKM_PE_GEN
  LD r2,r1,#NKM_N_PCOUNT
  ST r2,r3,#NKM_PE_PCOUNT
  ; parent hashes
  MOVI r4,0
nkmp_ph:
  LD r2,r1,#NKM_N_PCOUNT
  CMP r4,r2
  JMP[GE] @nkmp_pc
  ADD r5,r1,r4
  LD r5,r5,#NKM_N_PHLO
  ADD r6,r3,r4
  ST r5,r6,#NKM_PE_PLO
  ADD r5,r1,r4
  LD r5,r5,#NKM_N_PHHI
  ADD r6,r3,r4
  ST r5,r6,#NKM_PE_PHI
  ADD r4,r4,r13
  JMP @nkmp_ph
nkmp_pc:
  ; content
  LD r2,r1,#NKM_N_PAY
  MOVI r4,0
nkmp_cc:
  LD r5,r1,#NKM_N_USED
  CMP r4,r5
  JMP[GE] @nkmp_hs
  ADD r6,r2,r4
  LD r6,r6,0
  ADD r7,r3,r4
  ST r6,r7,#NKM_PE_CONTENT
  ADD r4,r4,r13
  JMP @nkmp_cc
nkmp_hs:
  LD r2,r1,#NKM_N_HLO
  ST r2,r3,#NKM_PE_HLO
  LD r2,r1,#NKM_N_HHI
  ST r2,r3,#NKM_PE_HHI
  MOVI r2,1
  ST r2,r3,#NKM_PE_FLAGS
  LD r11,r14,11
  ADD r11,r11,r13
  ST r11,r14,11
  JMP @nkmp_el
nkmp_done:
  LD r1,r14,6
  LD r2,r1,#NKM_N_PROOFS
  ADD r2,r2,r13
  ST r2,r1,#NKM_N_PROOFS
  LA r3,#NKM_STATS
  LD r4,r3,#NKM_G_PROOFS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_PROOFS
  LD r4,r3,#NKM_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_OPS
  LD r2,r14,2
  LD r3,r14,10
  LD r4,r14,8
  MOVI r1,#NKM_T_PROOF
  CALL @nkm_trace_add
  MOVI r1,1
  JMP @nkmp_out
nkprf_bad:
  MOVI r1,0
  MOVI r2,#NKM_EBAD
  CALL @nkm_fail
  MOVI r1,0
  JMP @nkmp_out
nkmp_none:
  MOVI r1,0
  MOVI r2,#NKM_ENOENT
  CALL @nkm_fail
nkmp_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_proof_verify r1=root lo r2=root hi r3=proof -> 1/0.
; No registry, node index or context is read: root hash plus proof only.
nkm_proof_verify:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CMP r3,r0
  JMP[EQ] @nkpv_bad
  LD r4,r3,#NKM_P_MAGIC
  LA r5,#NKM_PMAGIC
  CMP r4,r5
  JMP[NE] @nkpv_bad
  LD r4,r3,#NKM_P_VERSION
  MOVI r5,#NKM_VERSION
  CMP r4,r5
  JMP[NE] @nkpv_bad
  LD r4,r3,#NKM_P_DEPTH
  CMP r4,r0
  JMP[EQ] @nkpv_bad
  MOVI r5,#NKM_PROOF_MAX
  CMP r4,r5
  JMP[GT] @nkpv_bad
  ST r4,r14,4
  LD r4,r3,#NKM_P_MODE
  CMP r4,r0
  JMP[EQ] @nkpv_bad
  MOVI r5,2
  CMP r4,r5
  JMP[GT] @nkpv_bad
  ST r4,r14,5
  LD r4,r3,#NKM_P_ROOTLO
  LD r5,r14,1
  CMP r4,r5
  JMP[NE] @nkpv_bad
  LD r4,r3,#NKM_P_ROOTHI
  LD r5,r14,2
  CMP r4,r5
  JMP[NE] @nkpv_bad
  ; entry 0
  LD r3,r14,3
  ADDI r3,r3,#NKM_PENTRY
  ST r3,r14,6
  LD r4,r3,#NKM_PE_USED
  MOVI r5,#NKM_SLOTS
  CMP r4,r5
  JMP[GT] @nkpv_bad
  LD r4,r3,#NKM_PE_PCOUNT
  MOVI r5,4
  CMP r4,r5
  JMP[GT] @nkpv_bad
  ; recompute entry 0 hash
  LD r4,r14,6
  ADD r1,r4,r0
  ADDI r1,r1,#NKM_PE_CONTENT
  LD r2,r4,#NKM_PE_USED
  LD r3,r4,#NKM_PE_GEN
  LD r7,r4,#NKM_PE_PCOUNT
  ADD r5,r4,r0
  ADDI r5,r5,#NKM_PE_PLO
  ADD r6,r4,r0
  ADDI r6,r6,#NKM_PE_PHI
  ADD r4,r7,r0
  CALL @nkm_hash_arrays
  ST r1,r14,7
  ST r2,r14,8
  ; target hash and fields must agree with entry 0
  LD r3,r14,3
  LD r4,r14,6
  LD r5,r4,#NKM_PE_USED
  LD r6,r3,#NKM_P_USED
  CMP r5,r6
  JMP[NE] @nkpv_bad
  LD r5,r4,#NKM_PE_GEN
  LD r6,r3,#NKM_P_GEN
  CMP r5,r6
  JMP[NE] @nkpv_bad
  LD r5,r3,#NKM_P_TARGLO
  LD r6,r14,7
  CMP r5,r6
  JMP[NE] @nkpv_bad
  LD r5,r3,#NKM_P_TARGHI
  LD r6,r14,8
  CMP r5,r6
  JMP[NE] @nkpv_bad
  ; token mode binds offset and value to the target content
  LD r5,r14,5
  MOVI r6,2
  CMP r5,r6
  JMP[NE] @nkpv_page
  LD r5,r3,#NKM_P_TOKOFF
  LD r6,r4,#NKM_PE_USED
  CMP r5,r6
  JMP[GE] @nkpv_bad
  ADD r6,r4,r5
  LD r6,r6,#NKM_PE_CONTENT
  LD r7,r3,#NKM_P_TOKVAL
  CMP r6,r7
  JMP[NE] @nkpv_bad
  JMP @nkpv_chain
nkpv_page:
  LD r5,r3,#NKM_P_TOKOFF
  LA r6,#NKM_NONE
  CMP r5,r6
  JMP[NE] @nkpv_bad
nkpv_chain:
  ; walk entries 1..depth-1: child hash must be in previous entry parents
  LD r4,r14,4
  MOVI r5,1
  ST r5,r14,9
  LD r6,r14,7
  ST r6,r14,10
  LD r6,r14,8
  ST r6,r14,11
nkpv_l:
  LD r5,r14,9
  LD r4,r14,4
  CMP r5,r4
  JMP[GE] @nkpv_final
  ; entry i address
  LD r3,r14,3
  SHL r6,r5,5
  ADDI r3,r3,#NKM_PENTRY
  ADD r3,r3,r6
  ST r3,r14,6
  LD r4,r3,#NKM_PE_USED
  MOVI r6,#NKM_SLOTS
  CMP r4,r6
  JMP[GT] @nkpv_bad
  LD r4,r3,#NKM_PE_PCOUNT
  MOVI r6,4
  CMP r4,r6
  JMP[GT] @nkpv_bad
  ; hash entry i
  LD r4,r14,6
  ADD r1,r4,r0
  ADDI r1,r1,#NKM_PE_CONTENT
  LD r2,r4,#NKM_PE_USED
  LD r3,r4,#NKM_PE_GEN
  LD r7,r4,#NKM_PE_PCOUNT
  ADD r5,r4,r0
  ADDI r5,r5,#NKM_PE_PLO
  ADD r6,r4,r0
  ADDI r6,r6,#NKM_PE_PHI
  ADD r4,r7,r0
  CALL @nkm_hash_arrays
  ST r1,r14,12
  ST r2,r14,13
  ; entry i's ordered parents must contain the previous (child) hash
  LD r3,r14,6
  LD r4,r3,#NKM_PE_PCOUNT
  MOVI r5,0
nkpv_pl:
  CMP r5,r4
  JMP[GE] @nkpv_bad
  ADD r6,r3,r5
  LD r6,r6,#NKM_PE_PLO
  LD r7,r14,10
  CMP r6,r7
  JMP[NE] @nkpv_pnext
  ADD r6,r3,r5
  LD r6,r6,#NKM_PE_PHI
  LD r7,r14,11
  CMP r6,r7
  JMP[EQ] @nkpv_found
nkpv_pnext:
  ADD r5,r5,r13
  JMP @nkpv_pl
nkpv_found:
  LD r5,r14,12
  ST r5,r14,10
  LD r5,r14,13
  ST r5,r14,11
  LD r5,r14,9
  ADD r5,r5,r13
  ST r5,r14,9
  JMP @nkpv_l
nkpv_final:
  ; final child hash == supplied root
  LD r5,r14,10
  LD r6,r14,1
  CMP r5,r6
  JMP[NE] @nkpv_bad
  LD r5,r14,11
  LD r6,r14,2
  CMP r5,r6
  JMP[NE] @nkpv_bad
  LA r3,#NKM_STATS
  LD r4,r3,#NKM_G_VERIFIES
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_VERIFIES
  LD r4,r3,#NKM_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKM_G_OPS
  MOVI r1,1
  JMP @nkpv_out
nkpv_bad:
  CALL @nkm_pfail
nkpv_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_node_info r1=index r2=out(56) -> 0/-1.
nkm_node_info:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r2,r14,1
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkmni_bad
  LD r2,r14,1
  MOVI r3,0
nkmni_l:
  MOVI r4,#NKM_NSTRIDE
  CMP r3,r4
  JMP[GE] @nkmni_ok
  ADD r4,r1,r3
  LD r4,r4,0
  ADD r5,r2,r3
  ST r4,r5,0
  ADD r3,r3,r13
  JMP @nkmni_l
nkmni_ok:
  MOVI r1,0
  JMP @nkmni_out
nkmni_bad:
  LA r1,0xFFFFFFFF
nkmni_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkm_node_find r1=lo r2=hi -> index / NONE.
nkm_node_find:
  JMP @nkm_find

; ---------------------------------------------------------------------------
; nkm_node_free r1=index -> 1/0.  Only an unreferenced live node may be freed;
; normal reclamation happens at the last release.
nkm_node_free:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  CALL @nkm_nodeptr
  CMP r1,r0
  JMP[EQ] @nkmndf_bad
  ST r1,r14,2
  LD r2,r1,#NKM_N_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nkmndf_bad
  LD r2,r1,#NKM_N_REFS
  CMP r2,r0
  JMP[NE] @nkmndf_ref
  LD r3,r1,#NKM_N_KIND
  LA r4,#NKM_STATS
  LD r5,r4,#NKM_G_LIVE
  SUB r5,r5,r13
  ST r5,r4,#NKM_G_LIVE
  LD r5,r4,#NKM_G_OPS
  ADD r5,r5,r13
  ST r5,r4,#NKM_G_OPS
  MOVI r6,#NKM_K_PUBLIC
  CMP r3,r6
  JMP[NE] @nkmndf_p
  LD r5,r4,#NKM_G_PUBLIVE
  SUB r5,r5,r13
  ST r5,r4,#NKM_G_PUBLIVE
  LD r5,r4,#NKM_G_PFREE
  ADD r5,r5,r13
  ST r5,r4,#NKM_G_PFREE
  JMP @nkmndf_z
nkmndf_p:
  LD r5,r4,#NKM_G_PRIVFREE
  ADD r5,r5,r13
  ST r5,r4,#NKM_G_PRIVFREE
nkmndf_z:
  LD r2,r14,2
  ST r0,r2,#NKM_N_STATE
  MOVI r1,#NKM_T_FREE
  LD r2,r14,2
  LD r3,r2,#NKM_N_IDX
  LD r4,r2,#NKM_N_BGEN
  MOVI r5,0
  ST r5,r14,3
  CALL @nkm_trace_add
  MOVI r1,1
  JMP @nkmndf_out
nkmndf_ref:
  MOVI r1,0
  MOVI r2,#NKM_EREF
  CALL @nkm_fail
  JMP @nkmndf_out
nkmndf_bad:
  MOVI r1,0
  MOVI r2,#NKM_EBAD
  CALL @nkm_fail
nkmndf_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkm_stats r1=out(64) -> 0/-1.
nkm_stats:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  CMP r1,r0
  JMP[EQ] @nkmst_bad
  LA r2,#NKM_STATS
  MOVI r3,#NKM_SW
nkmst_l:
  CMP r3,r0
  JMP[EQ] @nkmst_ok
  LD r4,r2,0
  ST r4,r1,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  SUB r3,r3,r13
  JMP @nkmst_l
nkmst_ok:
  MOVI r1,0
  JMP @nkmst_out
nkmst_bad:
  LA r1,0xFFFFFFFF
nkmst_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkm_ctx_info r1=ctx r2=out(32) -> 0/-1.
nkm_ctx_info:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  CMP r1,r0
  JMP[EQ] @nkmci_bad
  CMP r2,r0
  JMP[EQ] @nkmci_bad
  MOVI r3,0
nkmci_l:
  MOVI r4,32
  CMP r3,r4
  JMP[GE] @nkmci_ok
  ADD r5,r1,r3
  LD r5,r5,0
  ADD r6,r2,r3
  ST r5,r6,0
  ADD r3,r3,r13
  JMP @nkmci_l
nkmci_ok:
  MOVI r1,0
  JMP @nkmci_out
nkmci_bad:
  LA r1,0xFFFFFFFF
nkmci_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nkm_root_info r1=ctx r2=out(8) -> 0/-1.
nkm_root_info:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,#NKM_C_MAGIC
  LA r4,#NKM_CMAGIC
  CMP r3,r4
  JMP[NE] @nkmri_bad
  CMP r2,r0
  JMP[EQ] @nkmri_bad
  ADD r3,r2,r0
  LD r4,r14,1
  LD r4,r4,#NKM_C_HLO
  ST r4,r3,0
  LD r4,r14,1
  LD r4,r4,#NKM_C_HHI
  ST r4,r3,1
  LD r4,r14,1
  LD r4,r4,#NKM_C_ROOT
  ST r4,r3,2
  LD r4,r14,1
  LD r4,r4,#NKM_C_USED
  ST r4,r3,3
  LD r4,r14,1
  LD r4,r4,#NKM_C_LIVE
  ST r4,r3,4
  LD r4,r14,1
  LD r4,r4,#NKM_C_GEN
  ST r4,r3,5
  LD r4,r14,1
  LD r4,r4,#NKM_C_EPOCH
  ST r4,r3,6
  LD r4,r14,1
  LD r4,r4,#NKM_C_SEALED
  ST r4,r3,7
  MOVI r1,0
  JMP @nkmri_out
nkmri_bad:
  LA r1,0xFFFFFFFF
nkmri_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nkm_trace r1=index r2=out(8) -> 0/-1.
nkm_trace:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r2,r14,1
  MOVI r3,#NKM_TRACE_N
  CMP r1,r3
  JMP[GE] @nkmtrg_bad
  CMP r2,r0
  JMP[EQ] @nkmtrg_bad
  SHL r1,r1,3
  LA r3,#NKM_TRACE
  ADD r1,r3,r1
  MOVI r3,0
nkmtrg_l:
  MOVI r4,#NKM_TRACE_W
  CMP r3,r4
  JMP[GE] @nkmtrg_ok
  ADD r4,r1,r3
  LD r4,r4,0
  ADD r5,r2,r3
  ST r4,r5,0
  ADD r3,r3,r13
  JMP @nkmtrg_l
nkmtrg_ok:
  MOVI r1,0
  JMP @nkmtrg_out
nkmtrg_bad:
  LA r1,0xFFFFFFFF
nkmtrg_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkm_trace_head -> head / 0.
nkm_trace_head:
  LA r1,#NKM_STATS
  LD r1,r1,#NKM_G_THEAD
  RET

; nkm_errno -> last error.
nkm_errno:
  LA r1,#NKM_STATS
  LD r1,r1,#NKM_G_LERR
  RET
