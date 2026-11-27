; nkvdag.nas - content-hash prefix-page DAG with dedup and late joins (F13i).
;
; Pure NaN.  This is the F13i layer above nkv-generation semantics and ngen
; live generations.  A KV branch is a context bound to one ngen generation
; and one nagent record.  Every immutable prefix page is hashed with a
; deterministic two-lane 32-bit mix (the pair is the 64-bit content key) and
; inserted into a content-addressed DAG node registry.  A node owns exactly
; one header; a second insertion of equal content increments the node's
; dedup counter and reference count and returns the same header.  A branch
; page table maps page indices to node headers, so three or more agents can
; share one immutable prefix without copying page headers or payloads.  A
; late agent joins by publishing the existing root hash; the join walks the
; prev-hash chain and acquires every node read-only.
;
; Divergent suffixes are private: the first append into a shared page
; copy-on-writes exactly that boundary page into a private node (not entered
; into the content index), and later appends stay private.  A private node is
; readable/writable only by the generation that created it.  A view is bound
; to reader generation and branch, so presenting it to another generation is
; EGEN, and writing a shared/refcounted page is ESHARED.
;
; Node identity and the chain
; ----------------------------
; The key is (hash_lo,hash_hi) over the page token values and token count.
; Token logical indices and birth generations are not in the hash, so the
; same values at the same count dedup across agents and generations.  Each
; immutable node stores prev = the previous immutable node in the sealing
; branch's chain; the last node's key is the branch root.  A join accepts the
; root key, walks prev down to NONE and installs the chain from oldest to
; newest.  Content-equal pages at different chain depths therefore share one
; node only when their prev chain agrees; this implementation rejects a
; dedup hit whose existing prev differs (ECOLL) rather than creating a
; multi-parent node.  The test exercises the valid case (same page at the
; same depth of two prefixes).
;
; Why close is safe
; -----------------
; A branch owns exactly one reference for every page-table entry.  A join or
; a content-dedup acquire adds one reference per node.  COW releases the
; shared boundary node after installing the private copy; close releases the
; remaining entries.  nkd_node_release frees a node only when refs reaches
; zero; a live node with refs == 0 cannot exist, and nkd_node_free rejects a
; node that still has references with EREF.  Orphan roots are therefore
; unreachable after the last close: nkd_join finds no node and fails ENOENT.
;
; Layout
; ------
; Node registry: 64 nodes x 32 words at 0x35C000.
; Stats: 64 words at 0x35D000.
; Trace: 128 entries x 8 words at 0x35D200.
; Scratch: 0x30000..0x3005F (ngen status/slot).
;
; Context (32 caller words):
;   +0 magic "NKDC" 0x43444B4E   +1 version 1
;   +2 ngen agent                +3 ngen generation
;   +4 branch id                 +5 parent branch
;   +6 nagent id                 +7 ngen epoch
;   +8 page table (8 words/block)+9 table capacity in blocks
;   +10 tokens per block         +11 used tokens
;   +12 live blocks              +13 COW page copies
;   +14 bytes/token (16)         +15 page slots (<=16)
;   +16 admitted                 +17 last context error
;   +18 last ngen error          +19 joins
;   +20 child forks              +21 prefix pages
;   +22 root hash lo             +23 root hash hi
;   +24 view opens               +25 view reads
;   +26 view writes              +27 dedup hits seen by this branch
;   +28 sealed flag              +29 root node index
;   +30 chain depth              +31 flags
;
; Page table entry (8 words):
;   +0 node index / NONE         +1 map generation
;   +2 flags (1 shared, 2 private)+3 content hash lo
;   +4 content hash hi           +5 node index copy
;   +6..7 reserved
;
; Node header (32 words):
;   +0 magic "NKDN" 0x4E444B4E   +1 version 1
;   +2 kind (1 immutable DAG, 2 private)
;   +3 refs                      +4 state (1 live)
;   +5 flags (1 immutable)       +6 hash lo +7 hash hi
;   +8 used tokens               +9 slots (16)
;   +10 payload word base        +11 dedup hits
;   +12 allocations              +13 joins
;   +14 leaves                   +15 frees
;   +16 headers (1 per header)   +17 birth generation
;   +18 owner agent              +19 prev node index / NONE
;   +20 node index               +21 COW copies caused by this page
;   +22 tokens copied            +23 lookups
;   +24 hits                     +25..31 reserved
;
; Payload: 16 token values, one word each, from the caller buffer supplied to
; nkd_init.  Hash and comparison cover only used values plus the used count.
;
; View (16 caller words):
;   +0 magic "NKDV" 0x56444B4E   +1 version 1
;   +2 reader generation         +3 branch
;   +4 logical token             +5 node index
;   +6 node birth generation     +7 mode (1 read, 2 write)
;   +8 entry flags               +9 token offset in page
;   +10..15 reserved
;
; Stats (64 words):
;   +0 magic "NKDG" +1 version +2 live nodes +3 live DAG nodes
;   +4 DAG headers +5 DAG allocs +6 DAG frees +7 private allocs
;   +8 private frees +9 refs acquired +10 refs released +11 dedup hits
;   +12 join operations +13 join refs +14 leaves +15 COW copies
;   +16 tokens copied +17 node limit +18 buffer +19 max nodes
;   +20 trace head +21 trace events +22 trace wraps +23 errors
;   +24 last error +25 ops +26 cross-gen rejects +27 stale rejects
;   +28 shared-write rejects +29 collision rejects +30 duplicate rejects
;   +31 ref rejects +32 lookups +33 lookup hits +34 opens +35 closes
;   +36 seals +37 roots bound +38..63 reserved
;
; Trace entry (8 words): kind, seq, a, b, c, 0, hash, 0.
; Kinds: 1 open, 2 seal, 3 join, 4 append-new, 5 COW, 6 release/free,
; 7 close, 8 duplicate/dedup, 9 reject.
;
; Return codes (nkd_errno):
;   0 OK, 1 EBAD, 2 ENOENT, 3 ENOSPC, 4 EGEN, 5 ESTALE, 6 ESHARED,
;   7 EBLK, 8 EDUP, 9 ECOLL, 10 EREF.
;
; API (r0=0, r13=1, r14 grows up, r15 link):
;   nkd_init        r1=page buffer word base r2=node limit (1..64) -> 0/-1
;   nkd_open        r1=ctx r2=ngen agent r3=generation r4=cpu r5=branch
;                   r6=nagent id r7=table r8=cap r9=tokens/block -> 1/0
;   nkd_publish     r1=ctx r2=new generation -> epoch / 0
;   nkd_seal        r1=ctx -> 1/0
;   nkd_join        r1=ctx r2=root hash lo r3=root hash hi -> 1/0
;   nkd_append      r1=ctx r2=value -> token index / -1
;   nkd_view_open   r1=ctx r2=token r3=mode r4=out -> 1/0
;   nkd_view_read   r1=ctx r2=view r3=out(2) -> 1/0
;   nkd_view_write  r1=ctx r2=view r3=value -> 1/0
;   nkd_close       r1=ctx -> 1/0
;   nkd_node_info   r1=node index r2=out(32) -> 0/-1
;   nkd_node_find   r1=hash lo r2=hash hi -> node index / NONE
;   nkd_node_free   r1=node index -> 1/0 (only at zero refs)
;   nkd_raw_add     r1=key lo r2=key hi r3=values r4=used -> index / -1
;   nkd_hash        r1=values r2=used -> r1=lo r2=hi
;   nkd_stats       r1=out(64) -> 0/-1
;   nkd_ctx_info    r1=ctx r2=out(32) -> 0/-1
;   nkd_trace       r1=index r2=out(8) -> 0/-1
;   nkd_trace_head  -> head / 0
;   nkd_errno       -> last error
;
; Requires nagent_init and ngen_init before nkd_open.  The page buffer is
; caller supplied.  No nkv/nheap objects are needed: payloads are plain NaN
; words and the hash is the identity, not a capability.

.include "nagent.nas"
.include "ngen.nas"

.equ NKD_NODES      0x35C000
.equ NKD_MAXNODE    64
.equ NKD_NSTRIDE    32
.equ NKD_NTOTAL     2048
.equ NKD_STATS      0x35D000
.equ NKD_SW         64
.equ NKD_TRACE      0x35D200
.equ NKD_TRACE_N    128
.equ NKD_TRACE_W    8
.equ NKD_TRACE_TOTAL 1024
.equ NKD_SCR        0x30000
.equ NKD_SCR_STATUS 0x30000
.equ NKD_SCR_SLOT   0x30020

.equ NKD_MAGIC      0x43444B4E       ; "NKDC"
.equ NKD_NMAGIC     0x4E444B4E       ; "NKDN"
.equ NKD_VMAGIC     0x56444B4E       ; "NKDV"
.equ NKD_GMAGIC     0x47444B4E       ; "NKDG"
.equ NKD_VERSION    1
.equ NKD_SLOTS      16
.equ NKD_PAGE_W     16
.equ NKD_BPT_BYTES  16
.equ NKD_NONE       0xFFFFFFFF
.equ NKD_SEED_LO    0x4E4B4448
.equ NKD_SEED_HI    0x44414731
.equ NKD_SALT       0x48474441
.equ NKD_MIX_C1     0x9E3779B9
.equ NKD_MIX_C2     0x85EBCA6B
.equ NKD_MIX_C3     0xC2B2AE35

; context fields
.equ NKD_C_MAGIC    0
.equ NKD_C_VERSION  1
.equ NKD_C_AGENT    2
.equ NKD_C_GEN      3
.equ NKD_C_BRANCH   4
.equ NKD_C_PARENT   5
.equ NKD_C_NAGENT   6
.equ NKD_C_EPOCH    7
.equ NKD_C_TAB      8
.equ NKD_C_TABCAP   9
.equ NKD_C_BLOCKTOK 10
.equ NKD_C_USED     11
.equ NKD_C_LIVE     12
.equ NKD_C_COPIES   13
.equ NKD_C_BPT      14
.equ NKD_C_SLOTS    15
.equ NKD_C_ADMIT    16
.equ NKD_C_ERR      17
.equ NKD_C_NGERR    18
.equ NKD_C_JOINS    19
.equ NKD_C_CHILDREN 20
.equ NKD_C_PREFIX   21
.equ NKD_C_HLO      22
.equ NKD_C_HHI      23
.equ NKD_C_VOPEN    24
.equ NKD_C_VREAD    25
.equ NKD_C_VWRITE   26
.equ NKD_C_DEDUP    27
.equ NKD_C_SEALED   28
.equ NKD_C_ROOT     29
.equ NKD_C_DEPTH    30
.equ NKD_C_FLAGS    31

; node fields
.equ NKD_N_MAGIC    0
.equ NKD_N_VERSION  1
.equ NKD_N_KIND     2
.equ NKD_N_REFS     3
.equ NKD_N_STATE    4
.equ NKD_N_FLAGS    5
.equ NKD_N_HLO      6
.equ NKD_N_HHI      7
.equ NKD_N_USED     8
.equ NKD_N_SLOTS    9
.equ NKD_N_PAY      10
.equ NKD_N_DEDUP    11
.equ NKD_N_ALLOCS   12
.equ NKD_N_JOINS    13
.equ NKD_N_LEAVES   14
.equ NKD_N_FREES    15
.equ NKD_N_HEADERS  16
.equ NKD_N_BGEN     17
.equ NKD_N_OWNER    18
.equ NKD_N_PREV     19
.equ NKD_N_IDX      20
.equ NKD_N_COPIES   21
.equ NKD_N_TCOPY    22
.equ NKD_N_LOOKUPS  23
.equ NKD_N_HITS     24

; entry fields
.equ NKD_E_NODE     0
.equ NKD_E_MAPGEN   1
.equ NKD_E_FLAGS    2
.equ NKD_E_HLO      3
.equ NKD_E_HHI      4
.equ NKD_E_IDX      5

; entry flags
.equ NKD_F_SHARED   1
.equ NKD_F_PRIVATE  2
.equ NKD_F_DAG      1

; kinds
.equ NKD_K_DAG      1
.equ NKD_K_PRIV     2

; stats fields
.equ NKD_G_MAGIC    0
.equ NKD_G_VERSION  1
.equ NKD_G_LIVE     2
.equ NKD_G_DAGLIVE  3
.equ NKD_G_DHEADERS 4
.equ NKD_G_DALLOC   5
.equ NKD_G_DFREE    6
.equ NKD_G_PALLOC   7
.equ NKD_G_PFREE    8
.equ NKD_G_REFS     9
.equ NKD_G_RELS     10
.equ NKD_G_DEDUP    11
.equ NKD_G_JOINOPS  12
.equ NKD_G_JOINREFS 13
.equ NKD_G_LEAVES   14
.equ NKD_G_COWS     15
.equ NKD_G_TCOPY    16
.equ NKD_G_LIMIT    17
.equ NKD_G_BUFFER   18
.equ NKD_G_MAXNODE  19
.equ NKD_G_THEAD    20
.equ NKD_G_TEVENTS  21
.equ NKD_G_TWRAPS   22
.equ NKD_G_ERRORS   23
.equ NKD_G_LERR     24
.equ NKD_G_OPS      25
.equ NKD_G_XGEN     26
.equ NKD_G_XSTALE   27
.equ NKD_G_XSHARED  28
.equ NKD_G_XCOLL    29
.equ NKD_G_XDUP     30
.equ NKD_G_XREF     31
.equ NKD_G_LOOKUPS  32
.equ NKD_G_HITS     33
.equ NKD_G_OPENS    34
.equ NKD_G_CLOSES   35
.equ NKD_G_SEALS    36
.equ NKD_G_ROOTS    37

; view fields
.equ NKD_V_MAGIC    0
.equ NKD_V_VERSION  1
.equ NKD_V_CTXGEN   2
.equ NKD_V_BRANCH   3
.equ NKD_V_TOKEN    4
.equ NKD_V_NODE     5
.equ NKD_V_BGEN     6
.equ NKD_V_MODE     7
.equ NKD_V_FLAGS    8
.equ NKD_V_OFF      9

; trace kinds
.equ NKD_T_OPEN     1
.equ NKD_T_SEAL     2
.equ NKD_T_JOIN     3
.equ NKD_T_NEW      4
.equ NKD_T_COW      5
.equ NKD_T_FREE     6
.equ NKD_T_CLOSE    7
.equ NKD_T_DEDUP    8
.equ NKD_T_REJECT   9
.equ NKD_T_PUBLISH  10

; errors
.equ NKD_OK         0
.equ NKD_EBAD       1
.equ NKD_ENOENT     2
.equ NKD_ENOSPC     3
.equ NKD_EGEN       4
.equ NKD_ESTALE     5
.equ NKD_ESHARED    6
.equ NKD_EBLK       7
.equ NKD_EDUP       8
.equ NKD_ECOLL      9
.equ NKD_EREF       10

; ---------------------------------------------------------------------------
; nkd_mix r1=hash r2=word -> r1.
nkd_mix:
  BOOL.6 r1,r1,r2
  LA r3,#NKD_MIX_C1
  ADD r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  LA r3,#NKD_MIX_C2
  MUL r1,r1,r3
  SHR r4,r1,15
  BOOL.6 r1,r1,r4
  LA r3,#NKD_MIX_C3
  MUL r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  RET

; nkd_hash r1=values r2=used -> r1=lo r2=hi.
nkd_hash:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  LA r1,#NKD_SEED_LO
  LD r2,r14,2
  CALL @nkd_mix
  ST r1,r14,3
  LA r1,#NKD_SEED_HI
  LD r2,r14,2
  CALL @nkd_mix
  ST r1,r14,4
  ST r0,r14,5
nh_loop:
  LD r5,r14,5
  LD r2,r14,2
  CMP r5,r2
  JMP[GE] @nh_done
  LD r3,r14,1
  ADD r3,r3,r5
  LD r3,r3,0
  ST r3,r14,6
  LD r1,r14,3
  LD r2,r14,6
  CALL @nkd_mix
  ST r1,r14,3
  LD r1,r14,4
  LD r2,r14,6
  CALL @nkd_mix
  ST r1,r14,4
  LD r5,r14,5
  ADD r5,r5,r13
  ST r5,r14,5
  JMP @nh_loop
nh_done:
  LD r1,r14,4
  LA r2,#NKD_SALT
  CALL @nkd_mix
  ST r1,r14,4
  LD r1,r14,3
  LD r2,r14,4
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; nkd_conteq r1=node r2=values r3=used -> 1/0.
nkd_conteq:
  LD r4,r1,#NKD_N_USED
  CMP r4,r3
  JMP[NE] @nce_no
  LD r5,r1,#NKD_N_PAY
  MOVI r6,0
nce_l:
  CMP r6,r3
  JMP[GE] @nce_yes
  ADD r7,r5,r6
  LD r7,r7,0
  ADD r8,r2,r6
  LD r8,r8,0
  CMP r7,r8
  JMP[NE] @nce_no
  ADD r6,r6,r13
  JMP @nce_l
nce_yes:
  MOVI r1,1
  RET
nce_no:
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; nkd_trace r1=kind r2=a r3=b r4=c -> new head.
nkd_trace_add:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  LA r5,#NKD_STATS
  LD r6,r5,#NKD_G_THEAD
  LD r7,r5,#NKD_G_TEVENTS
  ST r6,r14,5
  ST r7,r14,6
  ADD r1,r6,r0
  LD r2,r14,1
  CALL @nkd_mix
  LD r2,r14,2
  CALL @nkd_mix
  LD r2,r14,3
  CALL @nkd_mix
  LD r2,r14,4
  CALL @nkd_mix
  ST r1,r14,7
  LD r2,r14,6
  MOVI r3,#NKD_TRACE_N
  MODU r2,r2,r3
  SHL r2,r2,3
  LA r3,#NKD_TRACE
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
  LA r3,#NKD_STATS
  LD r1,r14,7
  ST r1,r3,#NKD_G_THEAD
  LD r2,r14,6
  ADD r2,r2,r13
  ST r2,r3,#NKD_G_TEVENTS
  MOVI r4,#NKD_TRACE_N
  CMP r2,r4
  JMP[LT] @nkdtr_out
  LD r4,r14,6
  MOVI r5,#NKD_TRACE_N
  MODU r4,r4,r5
  MOVI r5,#NKD_TRACE_N
  SUB r5,r5,r13
  CMP r4,r5
  JMP[NE] @nkdtr_out
  LD r4,r3,#NKD_G_TWRAPS
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_TWRAPS
nkdtr_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_fail r1=ctx(or 0) r2=code -> 0.
nkd_fail:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  ST r2,r14,2
  LA r3,#NKD_STATS
  LD r4,r3,#NKD_G_ERRORS
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_ERRORS
  ST r2,r3,#NKD_G_LERR
  LD r4,r3,#NKD_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_OPS
  MOVI r4,#NKD_EGEN
  CMP r2,r4
  JMP[NE] @nkdf_stale
  LD r4,r3,#NKD_G_XGEN
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_XGEN
  JMP @nkdf_ctx
nkdf_stale:
  MOVI r4,#NKD_ESTALE
  CMP r2,r4
  JMP[NE] @nkdf_shared
  LD r4,r3,#NKD_G_XSTALE
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_XSTALE
  JMP @nkdf_ctx
nkdf_shared:
  MOVI r4,#NKD_ESHARED
  CMP r2,r4
  JMP[NE] @nkdf_coll
  LD r4,r3,#NKD_G_XSHARED
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_XSHARED
  JMP @nkdf_ctx
nkdf_coll:
  MOVI r4,#NKD_ECOLL
  CMP r2,r4
  JMP[NE] @nkdf_dup
  LD r4,r3,#NKD_G_XCOLL
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_XCOLL
  JMP @nkdf_ctx
nkdf_dup:
  MOVI r4,#NKD_EDUP
  CMP r2,r4
  JMP[NE] @nkdf_ref
  LD r4,r3,#NKD_G_XDUP
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_XDUP
  JMP @nkdf_ctx
nkdf_ref:
  MOVI r4,#NKD_EREF
  CMP r2,r4
  JMP[NE] @nkdf_ctx
  LD r4,r3,#NKD_G_XREF
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_XREF
nkdf_ctx:
  LD r1,r14,1
  CMP r1,r0
  JMP[EQ] @nkdf_done
  LD r2,r14,2
  ST r2,r1,#NKD_C_ERR
nkdf_done:
  MOVI r1,0
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkd_nodeptr r1=index -> header or 0.
nkd_nodeptr:
  MOVI r2,#NKD_MAXNODE
  CMP r1,r2
  JMP[GE] @nkdnp_bad
  SHL r1,r1,5
  LA r2,#NKD_NODES
  ADD r1,r2,r1
  RET
nkdnp_bad:
  MOVI r1,0
  RET

; nkd_ctx_live r1=ctx -> 1/0.
nkd_ctx_live:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  LD r2,r1,#NKD_C_MAGIC
  LA r3,#NKD_MAGIC
  CMP r2,r3
  JMP[NE] @nkdcl_no
  LD r2,r1,#NKD_C_VERSION
  MOVI r3,#NKD_VERSION
  CMP r2,r3
  JMP[NE] @nkdcl_no
  LD r2,r1,#NKD_C_ADMIT
  CMP r2,r0
  JMP[EQ] @nkdcl_no
  LD r2,r1,#NKD_C_AGENT
  LA r3,#NKD_SCR_STATUS
  MOVI r4,0
  ADD r1,r2,r0
  ADD r2,r3,r0
  CALL @ngen_status
  CMP r1,r0
  JMP[NE] @nkdcl_no
  LA r3,#NKD_SCR_STATUS
  LD r4,r3,3
  LD r5,r14,1
  LD r5,r5,#NKD_C_GEN
  CMP r4,r5
  JMP[EQ] @nkdcl_yes
  LD r1,r14,1
  LD r1,r1,#NKD_C_AGENT
  ADD r2,r5,r0
  LA r3,#NKD_SCR_SLOT
  CALL @ngen_slot
  CMP r1,r0
  JMP[NE] @nkdcl_no
  LA r3,#NKD_SCR_SLOT
  LD r4,r3,1
  MOVI r5,#NG_S_DRAINING
  CMP r4,r5
  JMP[NE] @nkdcl_no
nkdcl_yes:
  MOVI r1,1
  JMP @nkdcl_out
nkdcl_no:
  MOVI r1,0
nkdcl_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkd_lookup r1=ctx r2=token -> r1=node idx r2=slot r3=entry or r1=NONE.
nkd_lookup:
  LD r3,r1,#NKD_C_USED
  CMP r2,r3
  JMP[GE] @nkdl_bad
  LD r4,r1,#NKD_C_BLOCKTOK
  CMP r4,r0
  JMP[EQ] @nkdl_bad
  DIVU r5,r2,r4
  MODU r6,r2,r4
  LD r7,r1,#NKD_C_TABCAP
  CMP r5,r7
  JMP[GE] @nkdl_bad
  LD r8,r1,#NKD_C_TAB
  CMP r8,r0
  JMP[EQ] @nkdl_bad
  SHL r9,r5,3
  ADD r8,r8,r9
  LD r9,r8,#NKD_E_NODE
  LA r10,#NKD_NONE
  CMP r9,r10
  JMP[EQ] @nkdl_bad
  ADD r1,r9,r0
  ADD r2,r6,r0
  ADD r3,r8,r0
  RET
nkdl_bad:
  LA r1,#NKD_NONE
  MOVI r2,0
  MOVI r3,0
  RET

; ---------------------------------------------------------------------------
; nkd_node_alloc r1=kind r2=birth gen r3=owner -> index / NONE.
nkd_node_alloc:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  MOVI r4,0
  ST r4,r14,4
  LA r5,#NKD_STATS
  LD r6,r5,#NKD_G_LIMIT
  LA r7,#NKD_NODES
nkna_l:
  LD r4,r14,4
  CMP r4,r6
  JMP[GE] @nkna_fail
  SHL r8,r4,5
  ADD r8,r7,r8
  LD r9,r8,#NKD_N_STATE
  CMP r9,r0
  JMP[EQ] @nkna_found
  LD r4,r14,4
  ADD r4,r4,r13
  ST r4,r14,4
  JMP @nkna_l
nkna_found:
  ST r8,r14,5
  ST r4,r14,6
  ; clear header 32 words
  MOVI r9,#NKD_NSTRIDE
  ADD r10,r8,r0
nkna_z:
  CMP r9,r0
  JMP[EQ] @nkna_pay
  ST r0,r10,0
  ADD r10,r10,r13
  SUB r9,r9,r13
  JMP @nkna_z
nkna_pay:
  ; payload = buffer + index * 16
  LA r5,#NKD_STATS
  LD r10,r5,#NKD_G_BUFFER
  LD r4,r14,6
  SHL r11,r4,4
  ADD r10,r10,r11
  ST r10,r14,7
  MOVI r9,#NKD_SLOTS
nkna_pz:
  CMP r9,r0
  JMP[EQ] @nkna_fill
  ST r0,r10,0
  ADD r10,r10,r13
  SUB r9,r9,r13
  JMP @nkna_pz
nkna_fill:
  LD r8,r14,5
  LA r9,#NKD_NMAGIC
  ST r9,r8,#NKD_N_MAGIC
  MOVI r9,#NKD_VERSION
  ST r9,r8,#NKD_N_VERSION
  LD r9,r14,1
  ST r9,r8,#NKD_N_KIND
  MOVI r9,1
  ST r9,r8,#NKD_N_REFS
  ST r9,r8,#NKD_N_STATE
  MOVI r9,#NKD_F_DAG
  LD r10,r14,1
  MOVI r11,#NKD_K_DAG
  CMP r10,r11
  JMP[EQ] @nkna_flag
  MOVI r9,#NKD_F_PRIVATE
nkna_flag:
  ST r9,r8,#NKD_N_FLAGS
  MOVI r9,#NKD_SLOTS
  ST r9,r8,#NKD_N_SLOTS
  LD r9,r14,7
  ST r9,r8,#NKD_N_PAY
  MOVI r9,1
  ST r9,r8,#NKD_N_ALLOCS
  ST r9,r8,#NKD_N_HEADERS
  LD r9,r14,2
  ST r9,r8,#NKD_N_BGEN
  LD r9,r14,3
  ST r9,r8,#NKD_N_OWNER
  LA r9,#NKD_NONE
  ST r9,r8,#NKD_N_PREV
  LD r9,r14,6
  ST r9,r8,#NKD_N_IDX
  ; stats
  LA r5,#NKD_STATS
  LD r9,r5,#NKD_G_LIVE
  ADD r9,r9,r13
  ST r9,r5,#NKD_G_LIVE
  LD r9,r5,#NKD_G_REFS
  ADD r9,r9,r13
  ST r9,r5,#NKD_G_REFS
  LD r9,r5,#NKD_G_OPS
  ADD r9,r9,r13
  ST r9,r5,#NKD_G_OPS
  LD r10,r14,1
  MOVI r11,#NKD_K_DAG
  CMP r10,r11
  JMP[NE] @nkna_priv
  LD r9,r5,#NKD_G_DAGLIVE
  ADD r9,r9,r13
  ST r9,r5,#NKD_G_DAGLIVE
  LD r9,r5,#NKD_G_DHEADERS
  ADD r9,r9,r13
  ST r9,r5,#NKD_G_DHEADERS
  LD r9,r5,#NKD_G_DALLOC
  ADD r9,r9,r13
  ST r9,r5,#NKD_G_DALLOC
  JMP @nkna_ok
nkna_priv:
  LD r9,r5,#NKD_G_PALLOC
  ADD r9,r9,r13
  ST r9,r5,#NKD_G_PALLOC
nkna_ok:
  LD r1,r14,6
  JMP @nkna_out
nkna_fail:
  LA r1,#NKD_NONE
nkna_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_node_release r1=ctx(or 0) r2=index -> 1/0.
nkd_node_release:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  LD r1,r14,2
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nknr_fail
  ST r1,r14,3
  LD r3,r1,#NKD_N_STATE
  MOVI r4,1
  CMP r3,r4
  JMP[NE] @nknr_fail
  LD r3,r1,#NKD_N_REFS
  CMP r3,r0
  JMP[EQ] @nknr_fail
  SUB r3,r3,r13
  ST r3,r1,#NKD_N_REFS
  LD r4,r1,#NKD_N_LEAVES
  ADD r4,r4,r13
  ST r4,r1,#NKD_N_LEAVES
  LA r5,#NKD_STATS
  LD r4,r5,#NKD_G_RELS
  ADD r4,r4,r13
  ST r4,r5,#NKD_G_RELS
  LD r4,r5,#NKD_G_LEAVES
  ADD r4,r4,r13
  ST r4,r5,#NKD_G_LEAVES
  LD r4,r5,#NKD_G_OPS
  ADD r4,r4,r13
  ST r4,r5,#NKD_G_OPS
  LD r3,r1,#NKD_N_REFS
  CMP r3,r0
  JMP[NE] @nknr_ok
  ; free at zero refs
  LD r3,r1,#NKD_N_KIND
  MOVI r4,#NKD_K_DAG
  CMP r3,r4
  JMP[NE] @nknr_privfree
  LD r4,r5,#NKD_G_DAGLIVE
  SUB r4,r4,r13
  ST r4,r5,#NKD_G_DAGLIVE
  LD r4,r5,#NKD_G_DFREE
  ADD r4,r4,r13
  ST r4,r5,#NKD_G_DFREE
  JMP @nknr_freed
nknr_privfree:
  LD r4,r5,#NKD_G_PFREE
  ADD r4,r4,r13
  ST r4,r5,#NKD_G_PFREE
nknr_freed:
  LD r4,r5,#NKD_G_LIVE
  SUB r4,r4,r13
  ST r4,r5,#NKD_G_LIVE
  LD r4,r5,#NKD_G_OPS
  ADD r4,r4,r13
  ST r4,r5,#NKD_G_OPS
  ST r0,r1,#NKD_N_STATE
  ; clear payload
  LD r6,r1,#NKD_N_PAY
  MOVI r7,#NKD_SLOTS
nknr_cp:
  CMP r7,r0
  JMP[EQ] @nknr_trace
  ST r0,r6,0
  ADD r6,r6,r13
  SUB r7,r7,r13
  JMP @nknr_cp
nknr_trace:
  MOVI r1,#NKD_T_FREE
  LD r2,r14,3
  LD r3,r2,#NKD_N_IDX
  LD r4,r2,#NKD_N_BGEN
  MOVI r5,0
  ST r5,r14,4
  CALL @nkd_trace_add
nknr_ok:
  MOVI r1,1
  JMP @nknr_out
nknr_fail:
  MOVI r1,0
nknr_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_init r1=buffer r2=limit (1..64) -> 0/-1.
nkd_init:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  CMP r1,r0
  JMP[EQ] @nkdi_bad
  CMP r2,r0
  JMP[EQ] @nkdi_bad
  MOVI r3,#NKD_MAXNODE
  CMP r2,r3
  JMP[GT] @nkdi_bad
  LA r1,#NKD_NODES
  MOVI r2,#NKD_NTOTAL
nkdi_n:
  CMP r2,r0
  JMP[EQ] @nkdi_s
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkdi_n
nkdi_s:
  LA r1,#NKD_STATS
  MOVI r2,#NKD_SW
nkdi_sl:
  CMP r2,r0
  JMP[EQ] @nkdi_tr
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkdi_sl
nkdi_tr:
  LA r1,#NKD_TRACE
  MOVI r2,#NKD_TRACE_TOTAL
nkdi_trl:
  CMP r2,r0
  JMP[EQ] @nkdi_buf
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkdi_trl
nkdi_buf:
  LD r1,r14,1
  LD r2,r14,2
  SHL r2,r2,4
nkdi_b:
  CMP r2,r0
  JMP[EQ] @nkdi_meta
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkdi_b
nkdi_meta:
  LA r1,#NKD_STATS
  LA r2,#NKD_GMAGIC
  ST r2,r1,#NKD_G_MAGIC
  MOVI r2,#NKD_VERSION
  ST r2,r1,#NKD_G_VERSION
  LD r2,r14,2
  ST r2,r1,#NKD_G_LIMIT
  MOVI r3,#NKD_MAXNODE
  ST r3,r1,#NKD_G_MAXNODE
  LD r2,r14,1
  ST r2,r1,#NKD_G_BUFFER
  MOVI r1,0
  JMP @nkdi_out
nkdi_bad:
  LA r1,0xFFFFFFFF
nkdi_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_find r1=hlo r2=hhi -> index / NONE.  Only immutable DAG nodes.
nkd_find:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  LA r3,#NKD_STATS
  LD r4,r3,#NKD_G_LOOKUPS
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_LOOKUPS
  MOVI r5,0
  ST r5,r14,3
  LD r6,r3,#NKD_G_LIMIT
  LA r7,#NKD_NODES
nkdf_l:
  LD r5,r14,3
  CMP r5,r6
  JMP[GE] @nkdf_bad
  SHL r8,r5,5
  ADD r8,r7,r8
  LD r9,r8,#NKD_N_STATE
  CMP r9,r0
  JMP[EQ] @nkdf_next
  LD r9,r8,#NKD_N_KIND
  MOVI r10,#NKD_K_DAG
  CMP r9,r10
  JMP[NE] @nkdf_next
  LD r9,r8,#NKD_N_HLO
  LD r10,r14,1
  CMP r9,r10
  JMP[NE] @nkdf_next
  LD r9,r8,#NKD_N_HHI
  LD r10,r14,2
  CMP r9,r10
  JMP[NE] @nkdf_next
  ; hit
  ST r5,r14,4
  LD r9,r8,#NKD_N_LOOKUPS
  ADD r9,r9,r13
  ST r9,r8,#NKD_N_LOOKUPS
  LD r9,r8,#NKD_N_HITS
  ADD r9,r9,r13
  ST r9,r8,#NKD_N_HITS
  LA r3,#NKD_STATS
  LD r4,r3,#NKD_G_HITS
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_HITS
  LD r1,r14,4
  JMP @nkdf_out
nkdf_next:
  LD r5,r14,3
  ADD r5,r5,r13
  ST r5,r14,3
  JMP @nkdf_l
nkdf_bad:
  LA r1,#NKD_NONE
nkdf_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_open r1=ctx r2=agent r3=gen r4=cpu r5=branch r6=nagent
;              r7=table r8=cap r9=tokens/block -> 1/0
nkd_open:
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
  JMP[EQ] @nkdo_bad
  CMP r2,r0
  JMP[EQ] @nkdo_bad
  CMP r3,r0
  JMP[EQ] @nkdo_bad
  CMP r7,r0
  JMP[EQ] @nkdo_bad
  CMP r8,r0
  JMP[EQ] @nkdo_bad
  CMP r9,r0
  JMP[EQ] @nkdo_bad
  MOVI r10,#NKD_SLOTS
  CMP r9,r10
  JMP[GT] @nkdo_bad
  MOVI r10,32
  CMP r8,r10
  JMP[GT] @nkdo_bad
  MOVI r10,#NG_MAX_CPU
  CMP r4,r10
  JMP[GE] @nkdo_bad
  ; optional nagent record must verify
  LD r10,r14,6
  CMP r10,r0
  JMP[EQ] @nkdo_clear
  ADD r1,r10,r0
  CALL @nagent_verify
  CMP r1,r0
  JMP[NE] @nkdo_bad
nkdo_clear:
  LD r1,r14,1
  MOVI r2,32
nkdo_z:
  CMP r2,r0
  JMP[EQ] @nkdo_fill
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkdo_z
nkdo_fill:
  LD r1,r14,1
  LA r2,#NKD_MAGIC
  ST r2,r1,#NKD_C_MAGIC
  MOVI r2,#NKD_VERSION
  ST r2,r1,#NKD_C_VERSION
  LD r2,r14,2
  ST r2,r1,#NKD_C_AGENT
  LD r2,r14,3
  ST r2,r1,#NKD_C_GEN
  LD r2,r14,5
  ST r2,r1,#NKD_C_BRANCH
  LD r2,r14,6
  ST r2,r1,#NKD_C_NAGENT
  LD r2,r14,7
  ST r2,r1,#NKD_C_TAB
  LD r2,r14,8
  ST r2,r1,#NKD_C_TABCAP
  LD r2,r14,9
  ST r2,r1,#NKD_C_BLOCKTOK
  MOVI r2,#NKD_BPT_BYTES
  ST r2,r1,#NKD_C_BPT
  MOVI r2,#NKD_SLOTS
  ST r2,r1,#NKD_C_SLOTS
  LA r2,#NKD_NONE
  ST r2,r1,#NKD_C_ROOT
  ; enter ngen
  LD r1,r14,2
  LD r2,r14,3
  LD r3,r14,4
  CALL @ngen_enter
  LD r4,r14,3
  CMP r1,r4
  JMP[EQ] @nkdo_admit
  LD r1,r14,1
  CALL @ngen_errno
  LD r2,r14,1
  ST r1,r2,#NKD_C_NGERR
  MOVI r2,#NKD_ESTALE
  CALL @nkd_fail
  JMP @nkdo_out
nkdo_admit:
  ; clear page table (cap * 8 words)
  LD r1,r14,7
  LD r2,r14,8
  SHL r2,r2,3
nkdo_t:
  CMP r2,r0
  JMP[EQ] @nkdo_sent
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkdo_t
nkdo_sent:
  ; empty page-table slots use NONE, because node index 0 is valid
  LD r1,r14,7
  LD r2,r14,8
  LA r3,#NKD_NONE
nkdo_sl:
  CMP r2,r0
  JMP[EQ] @nkdo_done
  ST r3,r1,#NKD_E_NODE
  ADDI r1,r1,8
  SUB r2,r2,r13
  JMP @nkdo_sl
nkdo_done:
  LD r1,r14,1
  MOVI r2,1
  ST r2,r1,#NKD_C_ADMIT
  LD r2,r14,2
  ADD r1,r2,r0
  CALL @ngen_epoch
  LD r2,r14,1
  ST r1,r2,#NKD_C_EPOCH
  LA r3,#NKD_STATS
  LD r4,r3,#NKD_G_OPENS
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_OPENS
  LD r4,r3,#NKD_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_OPS
  LD r2,r14,5
  LD r3,r14,3
  MOVI r1,#NKD_T_OPEN
  MOVI r4,0
  CALL @nkd_trace_add
  MOVI r1,1
  JMP @nkdo_out
nkdo_bad:
  LD r1,r14,1
  MOVI r2,#NKD_EBAD
  CALL @nkd_fail
nkdo_out:
  ADDI r14,r14,-80
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_bind_root r1=ctx r2=root hash lo -> 1/0.  Mirrors the content root in
; the branch's nagent record (KV root, immutable weight root ignored).
nkd_bind_root:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,#NKD_C_NAGENT
  CMP r3,r0
  JMP[EQ] @nkbr_ok
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @nkbr_ok
  ; nagent_roots(id, weight=0, kv=root_lo)
  ADD r1,r3,r0
  MOVI r2,0
  LD r3,r14,2
  CALL @nagent_roots
  CMP r1,r0
  JMP[NE] @nkbr_bad
  LA r3,#NKD_STATS
  LD r4,r3,#NKD_G_ROOTS
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_ROOTS
  LD r4,r3,#NKD_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_OPS
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
; nkd_publish r1=ctx r2=new generation -> epoch / 0.
nkd_publish:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,#NKD_C_MAGIC
  LA r4,#NKD_MAGIC
  CMP r3,r4
  JMP[NE] @nkdpub_bad
  LD r3,r1,#NKD_C_ADMIT
  CMP r3,r0
  JMP[EQ] @nkdpub_bad
  LD r1,r1,#NKD_C_AGENT
  LD r2,r14,2
  MOVI r3,0
  MOVI r4,0
  CALL @ngen_publish
  CMP r1,r0
  JMP[EQ] @nkdpub_stale
  ST r1,r14,3
  LD r2,r14,1
  ST r1,r2,#NKD_C_EPOCH
  LA r3,#NKD_STATS
  LD r4,r3,#NKD_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_OPS
  LD r2,r2,#NKD_C_BRANCH
  LD r3,r14,2
  MOVI r1,#NKD_T_PUBLISH
  MOVI r4,0
  CALL @nkd_trace_add
  LD r1,r14,3
  JMP @nkdpub_out
nkdpub_bad:
  LD r1,r14,1
  MOVI r2,#NKD_EBAD
  CALL @nkd_fail
  JMP @nkdpub_out
nkdpub_stale:
  LD r1,r14,1
  MOVI r2,#NKD_ESTALE
  CALL @nkd_fail
nkdpub_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_seal r1=ctx -> 1/0.
nkd_seal:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  LD r2,r1,#NKD_C_MAGIC
  LA r3,#NKD_MAGIC
  CMP r2,r3
  JMP[NE] @nkds_bad
  LD r2,r1,#NKD_C_ADMIT
  CMP r2,r0
  JMP[EQ] @nkds_bad
  LD r2,r1,#NKD_C_LIVE
  CMP r2,r0
  JMP[EQ] @nkds_bad
  LD r2,r1,#NKD_C_SEALED
  CMP r2,r0
  JMP[NE] @nkds_dup
  LA r2,#NKD_NONE
  ST r2,r14,2
  ST r0,r14,3
nkdse_l:
  LD r4,r14,3
  LD r2,r14,1
  LD r2,r2,#NKD_C_LIVE
  CMP r4,r2
  JMP[GE] @nkds_done
  LD r1,r14,1
  LD r1,r1,#NKD_C_TAB
  SHL r5,r4,3
  ADD r1,r1,r5
  ST r1,r14,4
  LD r2,r1,#NKD_E_NODE
  LA r3,#NKD_NONE
  CMP r2,r3
  JMP[EQ] @nkds_next
  ST r2,r14,5
  LD r1,r14,5
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkds_bad
  ST r1,r14,13
  LD r6,r1,#NKD_N_STATE
  MOVI r7,1
  CMP r6,r7
  JMP[NE] @nkds_bad
  LD r6,r1,#NKD_N_KIND
  MOVI r7,#NKD_K_PRIV
  CMP r6,r7
  JMP[NE] @nkds_shared
  ; hash private page content
  LD r1,r1,#NKD_N_PAY
  LD r2,r14,13
  LD r2,r2,#NKD_N_USED
  ST r2,r14,6
  CALL @nkd_hash
  ST r1,r14,7
  ST r2,r14,8
  ; search existing immutable node by key
  MOVI r9,0
  ST r9,r14,9
  LA r10,#NKD_STATS
  LD r10,r10,#NKD_G_LIMIT
  LA r11,#NKD_NODES
nkdse_search:
  LD r9,r14,9
  CMP r9,r10
  JMP[GE] @nkds_new
  SHL r12,r9,5
  ADD r12,r11,r12
  LD r6,r12,#NKD_N_STATE
  CMP r6,r0
  JMP[EQ] @nkdse_snext
  LD r6,r12,#NKD_N_KIND
  MOVI r7,#NKD_K_DAG
  CMP r6,r7
  JMP[NE] @nkdse_snext
  LD r6,r12,#NKD_N_HLO
  LD r7,r14,7
  CMP r6,r7
  JMP[NE] @nkdse_snext
  LD r6,r12,#NKD_N_HHI
  LD r7,r14,8
  CMP r6,r7
  JMP[NE] @nkdse_snext
  ; key hit: chain position and content must agree, then dedup
  ST r12,r14,10
  LD r6,r12,#NKD_N_PREV
  LD r7,r14,2
  CMP r6,r7
  JMP[NE] @nkds_coll
  MOVI r1,0
  ADD r1,r12,r0
  LD r2,r14,13
  LD r2,r2,#NKD_N_PAY
  LD r3,r14,6
  CALL @nkd_conteq
  CMP r1,r0
  JMP[EQ] @nkds_coll
  ; dedup acquire
  LD r12,r14,10
  LD r6,r12,#NKD_N_REFS
  ADD r6,r6,r13
  ST r6,r12,#NKD_N_REFS
  LD r6,r12,#NKD_N_DEDUP
  ADD r6,r6,r13
  ST r6,r12,#NKD_N_DEDUP
  LA r5,#NKD_STATS
  LD r6,r5,#NKD_G_DEDUP
  ADD r6,r6,r13
  ST r6,r5,#NKD_G_DEDUP
  LD r6,r5,#NKD_G_REFS
  ADD r6,r6,r13
  ST r6,r5,#NKD_G_REFS
  LD r6,r5,#NKD_G_OPS
  ADD r6,r6,r13
  ST r6,r5,#NKD_G_OPS
  LD r1,r14,1
  LD r2,r1,#NKD_C_DEDUP
  ADD r2,r2,r13
  ST r2,r1,#NKD_C_DEDUP
  ; install entry, release the private page
  LD r1,r14,4
  LD r12,r14,10
  LD r2,r12,#NKD_N_IDX
  ST r2,r1,#NKD_E_NODE
  LD r2,r14,1
  LD r2,r2,#NKD_C_GEN
  ST r2,r1,#NKD_E_MAPGEN
  MOVI r2,#NKD_F_SHARED
  ST r2,r1,#NKD_E_FLAGS
  LD r2,r12,#NKD_N_HLO
  ST r2,r1,#NKD_E_HLO
  LD r2,r12,#NKD_N_HHI
  ST r2,r1,#NKD_E_HHI
  LD r2,r12,#NKD_N_IDX
  ST r2,r1,#NKD_E_IDX
  MOVI r1,#NKD_T_DEDUP
  LD r2,r14,1
  LD r2,r2,#NKD_C_BRANCH
  LD r3,r14,10
  LD r3,r3,#NKD_N_IDX
  LD r4,r14,6
  CALL @nkd_trace_add
  LD r1,r14,1
  LD r2,r14,5
  CALL @nkd_node_release
  JMP @nkds_leaf
nkdse_snext:
  LD r9,r14,9
  ADD r9,r9,r13
  ST r9,r14,9
  JMP @nkdse_search
nkds_new:
  ; allocate immutable node
  MOVI r1,#NKD_K_DAG
  LD r2,r14,1
  LD r2,r2,#NKD_C_GEN
  LD r3,r14,1
  LD r3,r3,#NKD_C_AGENT
  CALL @nkd_node_alloc
  LA r2,#NKD_NONE
  CMP r1,r2
  JMP[EQ] @nkds_nospc
  ST r1,r14,11
  ; copy used values from the private page
  LD r1,r14,11
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkds_bad
  ST r1,r14,12
  LD r2,r14,12
  LD r2,r2,#NKD_N_PAY
  LD r5,r14,13
  LD r5,r5,#NKD_N_PAY
  LD r3,r14,6
  MOVI r4,0
nkds_cp:
  CMP r4,r3
  JMP[GE] @nkds_cpd
  ADD r6,r5,r4
  LD r6,r6,0
  ADD r7,r2,r4
  ST r6,r7,0
  ADD r4,r4,r13
  JMP @nkds_cp
nkds_cpd:
  LD r2,r14,12
  LD r3,r14,6
  ST r3,r2,#NKD_N_USED
  LD r3,r14,7
  ST r3,r2,#NKD_N_HLO
  LD r3,r14,8
  ST r3,r2,#NKD_N_HHI
  LD r3,r14,2
  ST r3,r2,#NKD_N_PREV
  ; install entry
  LD r1,r14,4
  LD r3,r14,11
  ST r3,r1,#NKD_E_NODE
  LD r3,r14,1
  LD r3,r3,#NKD_C_GEN
  ST r3,r1,#NKD_E_MAPGEN
  MOVI r3,#NKD_F_SHARED
  ST r3,r1,#NKD_E_FLAGS
  LD r3,r14,7
  ST r3,r1,#NKD_E_HLO
  LD r3,r14,8
  ST r3,r1,#NKD_E_HHI
  LD r3,r14,11
  ST r3,r1,#NKD_E_IDX
  MOVI r1,#NKD_T_NEW
  LD r2,r14,1
  LD r2,r2,#NKD_C_BRANCH
  LD r3,r14,11
  LD r4,r14,6
  CALL @nkd_trace_add
  ; release the private page
  LD r1,r14,1
  LD r2,r14,5
  CALL @nkd_node_release
  LD r2,r14,11
  JMP @nkds_leaf
nkds_shared:
  ; already immutable (should not happen before seal)
  LD r2,r14,5
  JMP @nkds_leaf
nkds_leaf:
  LD r3,r14,4
  LD r3,r3,#NKD_E_NODE
  ST r3,r14,2
  JMP @nkds_next
nkds_next:
  LD r4,r14,3
  ADD r4,r4,r13
  ST r4,r14,3
  JMP @nkdse_l
nkds_done:
  LD r1,r14,1
  MOVI r2,1
  ST r2,r1,#NKD_C_SEALED
  LD r3,r14,2
  ST r3,r1,#NKD_C_ROOT
  LA r4,#NKD_NONE
  CMP r3,r4
  JMP[EQ] @nkds_bad
  LD r5,r1,#NKD_C_TAB
  LD r6,r1,#NKD_C_LIVE
  SUB r6,r6,r13
  SHL r6,r6,3
  ADD r5,r5,r6
  LD r1,r5,#NKD_E_NODE
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkds_bad
  LD r2,r1,#NKD_N_HLO
  LD r3,r1,#NKD_N_HHI
  LD r1,r14,1
  ST r2,r1,#NKD_C_HLO
  ST r3,r1,#NKD_C_HHI
  LD r4,r1,#NKD_C_LIVE
  ST r4,r1,#NKD_C_PREFIX
  LD r4,r1,#NKD_C_LIVE
  ST r4,r1,#NKD_C_DEPTH
  ; bind nagent KV root
  ADD r2,r2,r0
  CALL @nkd_bind_root
  CMP r1,r0
  JMP[EQ] @nkds_bad
  LA r3,#NKD_STATS
  LD r4,r3,#NKD_G_SEALS
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_SEALS
  LD r4,r3,#NKD_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_OPS
  LD r1,r14,1
  LD r2,r1,#NKD_C_BRANCH
  LD r3,r1,#NKD_C_PREFIX
  LD r4,r1,#NKD_C_HLO
  MOVI r1,#NKD_T_SEAL
  CALL @nkd_trace_add
  MOVI r1,1
  JMP @nkds_out
nkds_dup:
  LD r1,r14,1
  MOVI r2,#NKD_EDUP
  CALL @nkd_fail
  JMP @nkds_out
nkds_coll:
  LD r1,r14,1
  MOVI r2,#NKD_ECOLL
  CALL @nkd_fail
  JMP @nkds_out
nkds_bad:
  LD r1,r14,1
  MOVI r2,#NKD_EBAD
  CALL @nkd_fail
  JMP @nkds_out
nkds_nospc:
  LD r1,r14,1
  MOVI r2,#NKD_ENOSPC
  CALL @nkd_fail
nkds_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_join r1=ctx r2=root hlo r3=root hhi -> 1/0.
nkd_join:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LD r4,r1,#NKD_C_MAGIC
  LA r5,#NKD_MAGIC
  CMP r4,r5
  JMP[NE] @nkdj_bad
  LD r4,r1,#NKD_C_ADMIT
  CMP r4,r0
  JMP[EQ] @nkdj_bad
  LD r4,r1,#NKD_C_USED
  CMP r4,r0
  JMP[NE] @nkdj_bad
  LD r4,r1,#NKD_C_LIVE
  CMP r4,r0
  JMP[NE] @nkdj_bad
  ; find root
  LD r1,r14,2
  LD r2,r14,3
  CALL @nkd_find
  LA r2,#NKD_NONE
  CMP r1,r2
  JMP[EQ] @nkdj_none
  ST r1,r14,4
  ; walk prev chain into temp (reverse order)
  MOVI r5,0
  ST r5,r14,5
  LD r6,r14,4
  ST r6,r14,6
nkdj_walk:
  LD r6,r14,6
  LA r7,#NKD_NONE
  CMP r6,r7
  JMP[EQ] @nkdj_walked
  LD r5,r14,5
  LD r4,r14,1
  LD r4,r4,#NKD_C_TABCAP
  CMP r5,r4
  JMP[GE] @nkdj_nospc
  ADD r1,r6,r0
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkdj_none
  ST r1,r14,7
  LD r2,r1,#NKD_N_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nkdj_none
  LD r2,r1,#NKD_N_KIND
  MOVI r3,#NKD_K_DAG
  CMP r2,r3
  JMP[NE] @nkdj_none
  ; temp[count] = node index
  LD r5,r14,5
  ADD r6,r14,r5
  ADDI r6,r6,32
  LD r3,r1,#NKD_N_IDX
  ST r3,r6,0
  ADD r5,r5,r13
  ST r5,r14,5
  LD r6,r1,#NKD_N_PREV
  ST r6,r14,6
  JMP @nkdj_walk
nkdj_walked:
  LD r5,r14,5
  CMP r5,r0
  JMP[EQ] @nkdj_none
  ; install oldest..newest
  MOVI r6,0
  ST r6,r14,8
nkdj_inst:
  LD r6,r14,8
  LD r5,r14,5
  CMP r6,r5
  JMP[GE] @nkdj_installed
  ; source temp index = count-1-pos
  SUB r7,r5,r13
  SUB r7,r7,r6
  ADD r7,r14,r7
  ADDI r7,r7,32
  LD r1,r7,0
  ST r1,r14,9
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkdj_none
  ST r1,r14,10
  ; refs++, joins++
  LD r2,r1,#NKD_N_REFS
  ADD r2,r2,r13
  ST r2,r1,#NKD_N_REFS
  LD r2,r1,#NKD_N_JOINS
  ADD r2,r2,r13
  ST r2,r1,#NKD_N_JOINS
  LA r4,#NKD_STATS
  LD r3,r4,#NKD_G_REFS
  ADD r3,r3,r13
  ST r3,r4,#NKD_G_REFS
  LD r3,r4,#NKD_G_JOINREFS
  ADD r3,r3,r13
  ST r3,r4,#NKD_G_JOINREFS
  LD r3,r4,#NKD_G_OPS
  ADD r3,r3,r13
  ST r3,r4,#NKD_G_OPS
  ; entry at position
  LD r2,r14,1
  LD r2,r2,#NKD_C_TAB
  LD r3,r14,8
  SHL r3,r3,3
  ADD r2,r2,r3
  LD r3,r14,9
  ST r3,r2,#NKD_E_NODE
  LD r5,r14,1
  LD r5,r5,#NKD_C_GEN
  ST r5,r2,#NKD_E_MAPGEN
  MOVI r5,#NKD_F_SHARED
  ST r5,r2,#NKD_E_FLAGS
  LD r1,r14,10
  LD r5,r1,#NKD_N_HLO
  ST r5,r2,#NKD_E_HLO
  LD r5,r1,#NKD_N_HHI
  ST r5,r2,#NKD_E_HHI
  LD r5,r1,#NKD_N_IDX
  ST r5,r2,#NKD_E_IDX
  LD r5,r1,#NKD_N_USED
  LD r2,r14,1
  LD r3,r2,#NKD_C_USED
  ADD r3,r3,r5
  ST r3,r2,#NKD_C_USED
  LD r3,r2,#NKD_C_LIVE
  ADD r3,r3,r13
  ST r3,r2,#NKD_C_LIVE
  LD r6,r14,8
  ADD r6,r6,r13
  ST r6,r14,8
  JMP @nkdj_inst
nkdj_installed:
  LD r1,r14,1
  LD r2,r14,5
  ST r2,r1,#NKD_C_PREFIX
  ST r2,r1,#NKD_C_DEPTH
  LD r3,r14,4
  ST r3,r1,#NKD_C_ROOT
  LD r4,r14,2
  ST r4,r1,#NKD_C_HLO
  LD r4,r14,3
  ST r4,r1,#NKD_C_HHI
  LD r2,r1,#NKD_C_JOINS
  ADD r2,r2,r13
  ST r2,r1,#NKD_C_JOINS
  LA r4,#NKD_STATS
  LD r5,r4,#NKD_G_JOINOPS
  ADD r5,r5,r13
  ST r5,r4,#NKD_G_JOINOPS
  LD r5,r4,#NKD_G_OPS
  ADD r5,r5,r13
  ST r5,r4,#NKD_G_OPS
  ; bind nagent KV root
  LD r2,r14,2
  CALL @nkd_bind_root
  CMP r1,r0
  JMP[EQ] @nkdj_bad
  ; trace join(branch, root lo, count, root hi)
  LD r1,r14,1
  LD r2,r1,#NKD_C_BRANCH
  LD r3,r14,2
  LD r4,r14,5
  MOVI r1,#NKD_T_JOIN
  CALL @nkd_trace_add
  MOVI r1,1
  JMP @nkdj_out
nkdj_bad:
  LD r1,r14,1
  MOVI r2,#NKD_EBAD
  CALL @nkd_fail
  JMP @nkdj_out
nkdj_none:
  LD r1,r14,1
  MOVI r2,#NKD_ENOENT
  CALL @nkd_fail
  JMP @nkdj_out
nkdj_nospc:
  LD r1,r14,1
  MOVI r2,#NKD_ENOSPC
  CALL @nkd_fail
nkdj_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_cow r1=ctx r2=entry -> new private index / NONE.
nkd_cow:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  LD r6,r2,#NKD_E_NODE
  ST r6,r14,3
  ADD r1,r6,r0
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkdco_fail
  ST r1,r14,4
  LD r5,r1,#NKD_N_USED
  ST r5,r14,5
  LD r1,r14,1
  LD r2,r1,#NKD_C_GEN
  LD r3,r1,#NKD_C_AGENT
  MOVI r1,#NKD_K_PRIV
  CALL @nkd_node_alloc
  LA r2,#NKD_NONE
  CMP r1,r2
  JMP[EQ] @nkdco_fail
  ST r1,r14,6
  CALL @nkd_nodeptr
  ST r1,r14,7
  ; copy used values
  LD r4,r14,4
  LD r5,r4,#NKD_N_PAY
  LD r2,r14,7
  LD r6,r2,#NKD_N_PAY
  LD r3,r14,5
  MOVI r7,0
nkdco_cp:
  CMP r7,r3
  JMP[GE] @nkdco_cpd
  ADD r8,r5,r7
  LD r8,r8,0
  ADD r9,r6,r7
  ST r8,r9,0
  ADD r7,r7,r13
  JMP @nkdco_cp
nkdco_cpd:
  LD r2,r14,7
  LD r3,r14,5
  ST r3,r2,#NKD_N_USED
  ; stats: old copies/token copies, global COW
  LD r4,r14,4
  LD r5,r4,#NKD_N_COPIES
  ADD r5,r5,r13
  ST r5,r4,#NKD_N_COPIES
  LD r5,r4,#NKD_N_TCOPY
  LD r3,r14,5
  ADD r5,r5,r3
  ST r5,r4,#NKD_N_TCOPY
  LA r5,#NKD_STATS
  LD r6,r5,#NKD_G_COWS
  ADD r6,r6,r13
  ST r6,r5,#NKD_G_COWS
  LD r6,r5,#NKD_G_TCOPY
  ADD r6,r6,r3
  ST r6,r5,#NKD_G_TCOPY
  LD r6,r5,#NKD_G_OPS
  ADD r6,r6,r13
  ST r6,r5,#NKD_G_OPS
  LD r1,r14,1
  LD r6,r1,#NKD_C_COPIES
  ADD r6,r6,r13
  ST r6,r1,#NKD_C_COPIES
  ; install new entry
  LD r2,r14,2
  LD r3,r14,6
  ST r3,r2,#NKD_E_NODE
  LD r3,r1,#NKD_C_GEN
  ST r3,r2,#NKD_E_MAPGEN
  MOVI r3,#NKD_F_PRIVATE
  ST r3,r2,#NKD_E_FLAGS
  ST r0,r2,#NKD_E_HLO
  ST r0,r2,#NKD_E_HHI
  LD r3,r14,6
  ST r3,r2,#NKD_E_IDX
  ; release the old shared node
  LD r2,r14,3
  CALL @nkd_node_release
  ; trace COW(branch, old index, new index)
  LD r1,r14,1
  LD r2,r1,#NKD_C_BRANCH
  LD r3,r14,3
  LD r4,r14,6
  MOVI r1,#NKD_T_COW
  CALL @nkd_trace_add
  LD r1,r14,6
  JMP @nkdco_out
nkdco_fail:
  LA r1,#NKD_NONE
nkdco_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_append r1=ctx r2=value -> token index / -1.
nkd_append:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,#NKD_C_MAGIC
  LA r4,#NKD_MAGIC
  CMP r3,r4
  JMP[NE] @nkda_bad
  LD r3,r1,#NKD_C_ADMIT
  CMP r3,r0
  JMP[EQ] @nkda_stale
  CALL @nkd_ctx_live
  CMP r1,r0
  JMP[EQ] @nkda_stale
  LD r1,r14,1
  LD r3,r1,#NKD_C_USED
  ST r3,r14,3
  LD r4,r1,#NKD_C_BLOCKTOK
  LD r5,r1,#NKD_C_TABCAP
  MUL r5,r5,r4
  CMP r3,r5
  JMP[GE] @nkda_nospc
  DIVU r4,r3,r4
  ST r4,r14,4
  LD r5,r1,#NKD_C_BLOCKTOK
  MODU r6,r3,r5
  ST r6,r14,5
  LD r7,r1,#NKD_C_TAB
  SHL r8,r4,3
  ADD r7,r7,r8
  ST r7,r14,6
  LD r8,r7,#NKD_E_NODE
  LA r9,#NKD_NONE
  CMP r8,r9
  JMP[NE] @nkda_have
  LD r9,r1,#NKD_C_LIVE
  CMP r4,r9
  JMP[NE] @nkda_blk
  ; new private page
  MOVI r1,#NKD_K_PRIV
  LD r2,r14,1
  LD r2,r2,#NKD_C_GEN
  LD r3,r14,1
  LD r3,r3,#NKD_C_AGENT
  CALL @nkd_node_alloc
  LA r2,#NKD_NONE
  CMP r1,r2
  JMP[EQ] @nkda_nospc
  ST r1,r14,7
  LD r7,r14,6
  ST r1,r7,#NKD_E_NODE
  LD r2,r14,1
  LD r2,r2,#NKD_C_GEN
  ST r2,r7,#NKD_E_MAPGEN
  MOVI r2,#NKD_F_PRIVATE
  ST r2,r7,#NKD_E_FLAGS
  ST r0,r7,#NKD_E_HLO
  ST r0,r7,#NKD_E_HHI
  LD r2,r14,7
  ST r2,r7,#NKD_E_IDX
  LD r3,r14,1
  LD r4,r3,#NKD_C_LIVE
  ADD r4,r4,r13
  ST r4,r3,#NKD_C_LIVE
  LD r2,r14,1
  LD r2,r2,#NKD_C_BRANCH
  LD r3,r14,7
  LD r4,r14,4
  MOVI r1,#NKD_T_NEW
  CALL @nkd_trace_add
  LD r8,r14,7
  JMP @nkda_have_alloc
nkda_have:
  ST r8,r14,7
  ADD r1,r8,r0
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkda_blk
  ST r1,r14,8
  LD r2,r1,#NKD_N_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nkda_blk
  ; shared or multi-referenced -> COW
  LD r4,r1,#NKD_N_FLAGS
  MOVI r5,#NKD_F_SHARED
  BOOL.8 r4,r4,r5
  CMP r4,r0
  JMP[NE] @nkda_cow
  LD r4,r1,#NKD_N_REFS
  MOVI r5,1
  CMP r4,r5
  JMP[GT] @nkda_cow
  ; private page must belong to this generation
  LD r1,r14,1
  LD r2,r1,#NKD_C_GEN
  LD r3,r14,8
  LD r3,r3,#NKD_N_BGEN
  CMP r3,r2
  JMP[NE] @nkda_blk
  LD r8,r14,7
  JMP @nkda_have_alloc
nkda_cow:
  LD r1,r14,1
  LD r2,r14,6
  CALL @nkd_cow
  LA r2,#NKD_NONE
  CMP r1,r2
  JMP[EQ] @nkda_nospc
  ST r1,r14,7
  ST r1,r14,8
nkda_have_alloc:
  LD r1,r14,7
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkda_blk
  ST r1,r14,8
  ADD r8,r1,r0
  LD r3,r14,5
  LD r4,r8,#NKD_N_USED
  CMP r3,r4
  JMP[NE] @nkda_blk
  LD r5,r8,#NKD_N_SLOTS
  CMP r4,r5
  JMP[GE] @nkda_blk
  LD r6,r8,#NKD_N_PAY
  ADD r6,r6,r3
  LD r1,r14,2
  ST r1,r6,0
  ; one word per token: the value, with the count in the node header.
  LD r1,r8,#NKD_N_USED
  ADD r1,r1,r13
  ST r1,r8,#NKD_N_USED
  LD r1,r14,1
  LD r2,r1,#NKD_C_USED
  ADD r2,r2,r13
  ST r2,r1,#NKD_C_USED
  LA r3,#NKD_STATS
  LD r4,r3,#NKD_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKD_G_OPS
  LD r1,r14,3
  JMP @nkda_out
nkda_bad:
  LD r1,r14,1
  MOVI r2,#NKD_EBAD
  CALL @nkd_fail
  JMP @nkda_out
nkda_blk:
  LD r1,r14,1
  MOVI r2,#NKD_EBLK
  CALL @nkd_fail
  JMP @nkda_out
nkda_stale:
  LD r1,r14,1
  MOVI r2,#NKD_ESTALE
  CALL @nkd_fail
  JMP @nkda_out
nkda_nospc:
  LD r1,r14,1
  MOVI r2,#NKD_ENOSPC
  CALL @nkd_fail
nkda_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_view_open r1=ctx r2=token r3=mode r4=out -> 1/0.
nkd_view_open:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  LD r5,r1,#NKD_C_MAGIC
  LA r6,#NKD_MAGIC
  CMP r5,r6
  JMP[NE] @nkdvo_bad
  CMP r4,r0
  JMP[EQ] @nkdvo_bad
  CMP r3,r0
  JMP[EQ] @nkdvo_bad
  MOVI r5,2
  CMP r3,r5
  JMP[GT] @nkdvo_bad
  CALL @nkd_ctx_live
  CMP r1,r0
  JMP[EQ] @nkdvo_stale
  LD r1,r14,1
  LD r2,r14,2
  CALL @nkd_lookup
  ST r1,r14,5
  ST r2,r14,6
  ST r3,r14,7
  LA r2,#NKD_NONE
  CMP r1,r2
  JMP[EQ] @nkdvo_none
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkdvo_none
  ST r1,r14,8
  LD r2,r1,#NKD_N_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nkdvo_none
  LD r2,r1,#NKD_N_BGEN
  LD r3,r14,1
  LD r3,r3,#NKD_C_GEN
  CMP r2,r3
  JMP[EQ] @nkdvo_genok
  LD r2,r1,#NKD_N_FLAGS
  MOVI r3,#NKD_F_SHARED
  BOOL.8 r2,r2,r3
  CMP r2,r0
  JMP[EQ] @nkdvo_blk
nkdvo_genok:
  LD r1,r14,4
  MOVI r2,16
nkdvo_z:
  CMP r2,r0
  JMP[EQ] @nkdvo_meta
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkdvo_z
nkdvo_meta:
  LD r1,r14,4
  LA r2,#NKD_VMAGIC
  ST r2,r1,#NKD_V_MAGIC
  MOVI r2,#NKD_VERSION
  ST r2,r1,#NKD_V_VERSION
  LD r3,r14,1
  LD r2,r3,#NKD_C_GEN
  ST r2,r1,#NKD_V_CTXGEN
  LD r2,r3,#NKD_C_BRANCH
  ST r2,r1,#NKD_V_BRANCH
  LD r2,r14,2
  ST r2,r1,#NKD_V_TOKEN
  LD r2,r14,5
  ST r2,r1,#NKD_V_NODE
  LD r2,r14,8
  LD r2,r2,#NKD_N_BGEN
  ST r2,r1,#NKD_V_BGEN
  LD r2,r14,3
  ST r2,r1,#NKD_V_MODE
  LD r2,r14,7
  ST r2,r1,#NKD_V_FLAGS
  LD r2,r14,6
  ST r2,r1,#NKD_V_OFF
  LD r2,r3,#NKD_C_VOPEN
  ADD r2,r2,r13
  ST r2,r3,#NKD_C_VOPEN
  LA r2,#NKD_STATS
  LD r4,r2,#NKD_G_OPS
  ADD r4,r4,r13
  ST r4,r2,#NKD_G_OPS
  MOVI r1,1
  JMP @nkdvo_out
nkdvo_bad:
  LD r1,r14,1
  MOVI r2,#NKD_EBAD
  CALL @nkd_fail
  JMP @nkdvo_out
nkdvo_stale:
  LD r1,r14,1
  MOVI r2,#NKD_ESTALE
  CALL @nkd_fail
  JMP @nkdvo_out
nkdvo_none:
  LD r1,r14,1
  MOVI r2,#NKD_ENOENT
  CALL @nkd_fail
  JMP @nkdvo_out
nkdvo_blk:
  LD r1,r14,1
  MOVI r2,#NKD_EBLK
  CALL @nkd_fail
nkdvo_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_view_read r1=ctx r2=view r3=out(2) -> 1/0.
nkd_view_read:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LD r4,r1,#NKD_C_MAGIC
  LA r5,#NKD_MAGIC
  CMP r4,r5
  JMP[NE] @nkdvr_bad
  LD r4,r2,#NKD_V_MAGIC
  LA r5,#NKD_VMAGIC
  CMP r4,r5
  JMP[NE] @nkdvr_bad
  LD r4,r2,#NKD_V_VERSION
  MOVI r5,#NKD_VERSION
  CMP r4,r5
  JMP[NE] @nkdvr_bad
  CMP r3,r0
  JMP[EQ] @nkdvr_bad
  LD r4,r2,#NKD_V_CTXGEN
  LD r5,r1,#NKD_C_GEN
  CMP r4,r5
  JMP[NE] @nkdvr_gen
  LD r4,r2,#NKD_V_BRANCH
  LD r5,r1,#NKD_C_BRANCH
  CMP r4,r5
  JMP[NE] @nkdvr_gen
  LD r4,r2,#NKD_V_MODE
  MOVI r5,1
  BOOL.8 r4,r4,r5
  CMP r4,r0
  JMP[EQ] @nkdvr_bad
  CALL @nkd_ctx_live
  CMP r1,r0
  JMP[EQ] @nkdvr_stale
  ; view node must still be the entry's node at that token
  LD r1,r14,1
  LD r2,r14,2
  LD r2,r2,#NKD_V_TOKEN
  CALL @nkd_lookup
  ST r1,r14,5
  ST r2,r14,6
  LA r2,#NKD_NONE
  CMP r1,r2
  JMP[EQ] @nkdvr_blk
  LD r4,r14,2
  LD r5,r4,#NKD_V_NODE
  LD r1,r14,5
  CMP r1,r5
  JMP[NE] @nkdvr_blk
  LD r5,r4,#NKD_V_OFF
  LD r2,r14,6
  CMP r2,r5
  JMP[NE] @nkdvr_blk
  ; node resolve
  LD r1,r14,5
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkdvr_blk
  ST r1,r14,4
  LD r2,r1,#NKD_N_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nkdvr_stale
  LD r2,r14,2
  LD r3,r2,#NKD_V_BGEN
  LD r4,r1,#NKD_N_BGEN
  CMP r3,r4
  JMP[NE] @nkdvr_blk
  LD r4,r2,#NKD_V_OFF
  LD r5,r1,#NKD_N_PAY
  ADD r5,r5,r4
  LD r6,r5,0
  LD r1,r14,3
  ST r6,r1,0
  LD r2,r14,4
  LD r2,r2,#NKD_N_BGEN
  ST r2,r1,1
  LD r1,r14,1
  LD r2,r1,#NKD_C_VREAD
  ADD r2,r2,r13
  ST r2,r1,#NKD_C_VREAD
  LA r2,#NKD_STATS
  LD r3,r2,#NKD_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKD_G_OPS
  MOVI r1,1
  JMP @nkdvr_out
nkdvr_gen:
  LD r1,r14,1
  MOVI r2,#NKD_EGEN
  CALL @nkd_fail
  JMP @nkdvr_out
nkdvr_stale:
  LD r1,r14,1
  MOVI r2,#NKD_ESTALE
  CALL @nkd_fail
  JMP @nkdvr_out
nkdvr_bad:
  LD r1,r14,1
  MOVI r2,#NKD_EBAD
  CALL @nkd_fail
  JMP @nkdvr_out
nkdvr_blk:
  LD r1,r14,1
  MOVI r2,#NKD_EBLK
  CALL @nkd_fail
nkdvr_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_view_write r1=ctx r2=view r3=value -> 1/0.
nkd_view_write:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LD r4,r1,#NKD_C_MAGIC
  LA r5,#NKD_MAGIC
  CMP r4,r5
  JMP[NE] @nkdvw_bad
  LD r4,r2,#NKD_V_MAGIC
  LA r5,#NKD_VMAGIC
  CMP r4,r5
  JMP[NE] @nkdvw_bad
  LD r4,r2,#NKD_V_VERSION
  MOVI r5,#NKD_VERSION
  CMP r4,r5
  JMP[NE] @nkdvw_bad
  LD r4,r2,#NKD_V_CTXGEN
  LD r5,r1,#NKD_C_GEN
  CMP r4,r5
  JMP[NE] @nkdvw_gen
  LD r4,r2,#NKD_V_BRANCH
  LD r5,r1,#NKD_C_BRANCH
  CMP r4,r5
  JMP[NE] @nkdvw_gen
  LD r4,r2,#NKD_V_MODE
  MOVI r5,2
  BOOL.8 r4,r4,r5
  CMP r4,r0
  JMP[EQ] @nkdvw_bad
  CALL @nkd_ctx_live
  CMP r1,r0
  JMP[EQ] @nkdvw_stale
  LD r1,r14,1
  LD r2,r14,2
  LD r2,r2,#NKD_V_TOKEN
  CALL @nkd_lookup
  ST r1,r14,5
  ST r2,r14,6
  LA r2,#NKD_NONE
  CMP r1,r2
  JMP[EQ] @nkdvw_blk
  LD r4,r14,2
  LD r5,r4,#NKD_V_NODE
  LD r1,r14,5
  CMP r1,r5
  JMP[NE] @nkdvw_blk
  LD r5,r4,#NKD_V_OFF
  LD r2,r14,6
  CMP r2,r5
  JMP[NE] @nkdvw_blk
  LD r1,r14,5
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkdvw_blk
  ST r1,r14,4
  LD r2,r1,#NKD_N_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nkdvw_stale
  ; shared/refcounted -> reject
  LD r2,r1,#NKD_N_FLAGS
  MOVI r3,#NKD_F_SHARED
  BOOL.8 r2,r2,r3
  CMP r2,r0
  JMP[NE] @nkdvw_shared
  LD r2,r1,#NKD_N_REFS
  MOVI r3,1
  CMP r2,r3
  JMP[GT] @nkdvw_shared
  ; private must match the reader generation
  LD r2,r1,#NKD_N_BGEN
  LD r3,r14,1
  LD r3,r3,#NKD_C_GEN
  CMP r2,r3
  JMP[NE] @nkdvw_blk
  LD r2,r14,2
  LD r2,r2,#NKD_V_BGEN
  LD r1,r14,4
  LD r3,r1,#NKD_N_BGEN
  CMP r2,r3
  JMP[NE] @nkdvw_blk
  LD r2,r14,2
  LD r2,r2,#NKD_V_OFF
  LD r3,r1,#NKD_N_PAY
  ADD r3,r3,r2
  LD r4,r14,3
  ST r4,r3,0
  LD r1,r14,1
  LD r2,r1,#NKD_C_VWRITE
  ADD r2,r2,r13
  ST r2,r1,#NKD_C_VWRITE
  LA r2,#NKD_STATS
  LD r3,r2,#NKD_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKD_G_OPS
  MOVI r1,1
  JMP @nkdvw_out
nkdvw_gen:
  LD r1,r14,1
  MOVI r2,#NKD_EGEN
  CALL @nkd_fail
  JMP @nkdvw_out
nkdvw_stale:
  LD r1,r14,1
  MOVI r2,#NKD_ESTALE
  CALL @nkd_fail
  JMP @nkdvw_out
nkdvw_shared:
  LD r1,r14,1
  MOVI r2,#NKD_ESHARED
  CALL @nkd_fail
  JMP @nkdvw_out
nkdvw_bad:
  LD r1,r14,1
  MOVI r2,#NKD_EBAD
  CALL @nkd_fail
  JMP @nkdvw_out
nkdvw_blk:
  LD r1,r14,1
  MOVI r2,#NKD_EBLK
  CALL @nkd_fail
nkdvw_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_close r1=ctx -> 1/0.
nkd_close:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  LD r2,r1,#NKD_C_MAGIC
  LA r3,#NKD_MAGIC
  CMP r2,r3
  JMP[NE] @nkdc_bad
  LD r2,r1,#NKD_C_ADMIT
  CMP r2,r0
  JMP[EQ] @nkdc_bad
  LD r3,r1,#NKD_C_TAB
  LD r4,r1,#NKD_C_LIVE
  ST r4,r14,2
  MOVI r5,0
  ST r5,r14,3
nkdc_l:
  LD r5,r14,3
  LD r4,r14,2
  CMP r5,r4
  JMP[GE] @nkdc_rel_done
  SHL r6,r5,3
  ADD r7,r3,r6
  ST r7,r14,4
  LD r2,r7,#NKD_E_NODE
  LA r4,#NKD_NONE
  CMP r2,r4
  JMP[EQ] @nkdc_next
  LD r1,r14,1
  CALL @nkd_node_release
  LD r7,r14,4
  ST r0,r7,#NKD_E_NODE
  ST r0,r7,#NKD_E_MAPGEN
  ST r0,r7,#NKD_E_FLAGS
  ST r0,r7,#NKD_E_HLO
  ST r0,r7,#NKD_E_HHI
  ST r0,r7,#NKD_E_IDX
nkdc_next:
  LD r5,r14,3
  ADD r5,r5,r13
  ST r5,r14,3
  LD r1,r14,1
  LD r3,r1,#NKD_C_TAB
  JMP @nkdc_l
nkdc_rel_done:
  LD r1,r14,1
  ST r0,r1,#NKD_C_LIVE
  ST r0,r1,#NKD_C_USED
  ST r0,r1,#NKD_C_ADMIT
  LD r2,r1,#NKD_C_BRANCH
  LD r3,r1,#NKD_C_GEN
  MOVI r1,#NKD_T_CLOSE
  MOVI r4,0
  CALL @nkd_trace_add
  LD r1,r14,1
  LD r2,r1,#NKD_C_AGENT
  LD r3,r1,#NKD_C_GEN
  ADD r1,r2,r0
  ADD r2,r3,r0
  CALL @ngen_exit
  CALL @ngen_errno
  CMP r1,r0
  JMP[NE] @nkdc_ngerr
  LA r2,#NKD_STATS
  LD r3,r2,#NKD_G_CLOSES
  ADD r3,r3,r13
  ST r3,r2,#NKD_G_CLOSES
  LD r3,r2,#NKD_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKD_G_OPS
  MOVI r1,1
  JMP @nkdc_out
nkdc_ngerr:
  LD r2,r14,1
  ST r1,r2,#NKD_C_NGERR
  MOVI r2,#NKD_ESTALE
  CALL @nkd_fail
  JMP @nkdc_out
nkdc_bad:
  LD r1,r14,1
  MOVI r2,#NKD_EBAD
  CALL @nkd_fail
nkdc_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_node_info r1=index r2=out(32) -> 0/-1.
nkd_node_info:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r2,r14,1
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkdni_bad
  LD r2,r14,1
  MOVI r3,0
nkdni_l:
  MOVI r4,#NKD_NSTRIDE
  CMP r3,r4
  JMP[GE] @nkdni_ok
  ADD r4,r1,r3
  LD r4,r4,0
  ADD r5,r2,r3
  ST r4,r5,0
  ADD r3,r3,r13
  JMP @nkdni_l
nkdni_ok:
  MOVI r1,0
  JMP @nkdni_out
nkdni_bad:
  LA r1,0xFFFFFFFF
nkdni_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkd_node_find r1=lo r2=hi -> index / NONE.
nkd_node_find:
  JMP @nkd_find

; nkd_hash_pub r1=values r2=used -> r1=lo r2=hi.
nkd_hash_pub:
  JMP @nkd_hash

; ---------------------------------------------------------------------------
; nkd_node_free r1=index -> 1/0.  Only an unreferenced live node may be freed;
; in normal operation release frees at zero, so this is a rejection API too.
nkd_node_free:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkdndf_bad
  ST r1,r14,2
  LD r2,r1,#NKD_N_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nkdndf_bad
  LD r2,r1,#NKD_N_REFS
  CMP r2,r0
  JMP[NE] @nkdndf_ref
  ; direct free without decrementing below zero
  LD r3,r1,#NKD_N_KIND
  LA r4,#NKD_STATS
  LD r5,r4,#NKD_G_LIVE
  SUB r5,r5,r13
  ST r5,r4,#NKD_G_LIVE
  LD r5,r4,#NKD_G_OPS
  ADD r5,r5,r13
  ST r5,r4,#NKD_G_OPS
  MOVI r6,#NKD_K_DAG
  CMP r3,r6
  JMP[NE] @nkdndf_p
  LD r5,r4,#NKD_G_DAGLIVE
  SUB r5,r5,r13
  ST r5,r4,#NKD_G_DAGLIVE
  LD r5,r4,#NKD_G_DFREE
  ADD r5,r5,r13
  ST r5,r4,#NKD_G_DFREE
  JMP @nkdndf_z
nkdndf_p:
  LD r5,r4,#NKD_G_PFREE
  ADD r5,r5,r13
  ST r5,r4,#NKD_G_PFREE
nkdndf_z:
  LD r2,r14,2
  ST r0,r2,#NKD_N_STATE
  MOVI r1,#NKD_T_FREE
  LD r2,r14,2
  LD r3,r2,#NKD_N_IDX
  LD r4,r2,#NKD_N_BGEN
  MOVI r5,0
  ST r5,r14,3
  CALL @nkd_trace_add
  MOVI r1,1
  JMP @nkdndf_out
nkdndf_ref:
  MOVI r1,0
  MOVI r2,#NKD_EREF
  CALL @nkd_fail
  JMP @nkdndf_out
nkdndf_bad:
  MOVI r1,0
  MOVI r2,#NKD_EBAD
  CALL @nkd_fail
nkdndf_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_raw_add r1=key lo r2=key hi r3=values r4=used -> index / NONE.
; Rejects a key that does not match the content (ECOLL) and a duplicate
; header insert for existing content (EDUP).  Success is the external import
; path: one new immutable node with prev NONE.
nkd_raw_add:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  CMP r3,r0
  JMP[EQ] @nkdra_bad
  CMP r4,r0
  JMP[EQ] @nkdra_bad
  MOVI r5,#NKD_SLOTS
  CMP r4,r5
  JMP[GT] @nkdra_bad
  ; recompute
  LD r1,r14,3
  LD r2,r14,4
  CALL @nkd_hash
  LD r3,r14,1
  CMP r1,r3
  JMP[NE] @nkdra_coll
  LD r3,r14,2
  CMP r2,r3
  JMP[NE] @nkdra_coll
  ST r1,r14,5
  ST r2,r14,6
  ; existing?
  LD r1,r14,5
  LD r2,r14,6
  CALL @nkd_find
  LA r2,#NKD_NONE
  CMP r1,r2
  JMP[EQ] @nkdra_new
  ST r1,r14,7
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkdra_bad
  LD r2,r14,3
  LD r3,r14,4
  CALL @nkd_conteq
  CMP r1,r0
  JMP[EQ] @nkdra_coll
  JMP @nkdra_dup
nkdra_new:
  MOVI r1,#NKD_K_DAG
  MOVI r2,0
  MOVI r3,0
  CALL @nkd_node_alloc
  LA r2,#NKD_NONE
  CMP r1,r2
  JMP[EQ] @nkdra_nospc
  ST r1,r14,8
  LD r1,r14,8
  CALL @nkd_nodeptr
  CMP r1,r0
  JMP[EQ] @nkdra_bad
  ST r1,r14,9
  LD r2,r1,#NKD_N_PAY
  LD r5,r14,3
  LD r3,r14,4
  MOVI r4,0
nkdra_cp:
  CMP r4,r3
  JMP[GE] @nkdra_cpd
  ADD r6,r5,r4
  LD r6,r6,0
  ADD r7,r2,r4
  ST r6,r7,0
  ADD r4,r4,r13
  JMP @nkdra_cp
nkdra_cpd:
  LD r2,r14,9
  LD r3,r14,4
  ST r3,r2,#NKD_N_USED
  LD r3,r14,5
  ST r3,r2,#NKD_N_HLO
  LD r3,r14,6
  ST r3,r2,#NKD_N_HHI
  LD r1,r14,8
  JMP @nkdra_out
nkdra_dup:
  MOVI r1,0
  MOVI r2,#NKD_EDUP
  CALL @nkd_fail
  JMP @nkdra_out
nkdra_coll:
  MOVI r1,0
  MOVI r2,#NKD_ECOLL
  CALL @nkd_fail
  JMP @nkdra_out
nkdra_bad:
  MOVI r1,0
  MOVI r2,#NKD_EBAD
  CALL @nkd_fail
  JMP @nkdra_out
nkdra_nospc:
  MOVI r1,0
  MOVI r2,#NKD_ENOSPC
  CALL @nkd_fail
nkdra_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkd_stats r1=out(64) -> 0/-1.
nkd_stats:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  CMP r1,r0
  JMP[EQ] @nkdst_bad
  LA r2,#NKD_STATS
  MOVI r3,#NKD_SW
nkdst_l:
  CMP r3,r0
  JMP[EQ] @nkdst_ok
  LD r4,r2,0
  ST r4,r1,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  SUB r3,r3,r13
  JMP @nkdst_l
nkdst_ok:
  MOVI r1,0
  JMP @nkdst_out
nkdst_bad:
  LA r1,0xFFFFFFFF
nkdst_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkd_ctx_info r1=ctx r2=out(32) -> 0/-1.
nkd_ctx_info:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r2,r14,1
  CMP r1,r0
  JMP[EQ] @nkdci_bad
  CMP r2,r0
  JMP[EQ] @nkdci_bad
  MOVI r3,0
nkdci_l:
  MOVI r4,32
  CMP r3,r4
  JMP[GE] @nkdci_ok
  ADD r5,r2,r3
  LD r5,r5,0
  ADD r6,r1,r3
  ST r5,r6,0
  ADD r3,r3,r13
  JMP @nkdci_l
nkdci_ok:
  MOVI r1,0
  JMP @nkdci_out
nkdci_bad:
  LA r1,0xFFFFFFFF
nkdci_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkd_trace r1=index r2=out(8) -> 0/-1.
nkd_trace:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r2,r14,1
  MOVI r3,#NKD_TRACE_N
  CMP r1,r3
  JMP[GE] @nkdtrg_bad
  CMP r2,r0
  JMP[EQ] @nkdtrg_bad
  SHL r1,r1,3
  LA r3,#NKD_TRACE
  ADD r1,r3,r1
  MOVI r3,0
nkdtrg_l:
  MOVI r4,#NKD_TRACE_W
  CMP r3,r4
  JMP[GE] @nkdtrg_ok
  ADD r4,r1,r3
  LD r4,r4,0
  ADD r5,r2,r3
  ST r4,r5,0
  ADD r3,r3,r13
  JMP @nkdtrg_l
nkdtrg_ok:
  MOVI r1,0
  JMP @nkdtrg_out
nkdtrg_bad:
  LA r1,0xFFFFFFFF
nkdtrg_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkd_trace_head -> head / 0.
nkd_trace_head:
  LA r1,#NKD_STATS
  LD r1,r1,#NKD_G_THEAD
  RET

; nkd_errno -> last error.
nkd_errno:
  LA r1,#NKD_STATS
  LD r1,r1,#NKD_G_LERR
  RET
