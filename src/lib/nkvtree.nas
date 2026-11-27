; nkvtree.nas - three-agent shared-prefix branch tree with nsym roots (F13h).
;
; Pure NaN.  This is the F13h layer above nkv views, ngen live generations,
; nagent child records and nsym shared roots.  A tree agent is a KV branch
; context.  Its token space is a table of generation-tagged KV pages.  Pages
; that form an immutable prefix are marked SHARED and carry a reference count;
; the same count is mirrored by an nsym shared root whose payload is the
; page's eight token values.  A fork creates an nagent_fork-style child record
; with an advanced KV generation, starts an independent ngen generation for
; the child agent, and joins every shared prefix page read-only, without
; copying page payloads.  Each child then appends a divergent suffix.  The
; first append into the shared partial boundary page copy-on-writes exactly
; that page; later appends stay private.
;
; Why two siblings can fork one parent
; ------------------------------------
; Unlike the single-chain nkvgen fork, a tree fork does not publish on the
; parent's ngen agent.  The parent stays CURRENT while child1 starts on its own
; ngen agent (generation 2) and child2 on a third ngen agent (generation 3).
; The parent may later publish its own next generation and keep appending as an
; admitted DRAINING snapshot.  Numeric ngen generations are per-agent
; namespaces; shared prefix readability is established by the SHARED/refcount
; join, not by comparing generation numbers.  A view is still bound to one
; exact context generation and branch, so sibling and old-generation views are
; rejected before any payload word is exposed.
;
; Layout
; ------
; Page registry: 16 pages x 32 words at 0x359000.
; Stats: 48 words at 0x359800.
; Trace: 64 entries x 8 words at 0x359A00.
; Scratch: 0x30000..0x3005F (ngen status/slot and nkv shape).
;
; Context (32 caller words):
;   +0 magic "NKTC" 0x43544B4E    +1 version 1
;   +2 ngen agent                 +3 ngen generation
;   +4 branch id                  +5 parent branch
;   +6 nagent id                  +7 nagent KV generation
;   +8 page table (4 words/block) +9 table capacity in blocks
;   +10 tokens per block          +11 used tokens
;   +12 live blocks               +13 COW page copies
;   +14 bytes/token (16)          +15 page slots (max 16)
;   +16 admitted                  +17 last context error
;   +18 last ngen error           +19 fork joins
;   +20 child forks               +21 ngen epoch
;   +22 view opens                +23 views minted
;   +24 view reads                +25 view writes
;   +26 nagent record generation  +27 tree depth
;   +28 nsym weight root          +29 nsym KV root (prefix page root)
;   +30 prefix pages              +31 flags
;
; Page table entry (4 words):
;   +0 page pointer / 0           +1 map generation
;   +2 flags (1 shared)           +3 nsym root index / 0xFFFFFFFF
;
; Page header (32 words):
;   +0 magic "NKTP" 0x50544B4E    +1 version 1
;   +2 allocation generation      +3 refcount
;   +4 state (1 live)             +5 flags (1 shared immutable prefix)
;   +6 class-20 storage cap       +7 word base   +8 base_hi
;   +9 used tokens                +10 slots (<=16)
;   +11 allocations               +12 COW copies caused by this page
;   +13 tokens copied             +14 joins +15 leaves +16 frees
;   +17 owner ngen agent          +18 owner generation
;   +19 page index                +20 nsym root index / 0xFFFFFFFF
;   +21..31 reserved
;
; Page payload: 16 token records x 4 words = 64 words per page buffer slot.
; Token record: {logical token, value, tag 0xA5A5A5A5, generation}.  Page data
; is caller supplied to nkvt_init.  A token read is resolved through a real nkv
; rank-1 f32 view over the page's class-20 storage capability.
;
; View (32 caller words):
;   +0 magic "NKTV" 0x56544B4E    +1 version 1
;   +2 reader generation          +3 branch
;   +4 logical token              +5 page pointer
;   +6 page birth generation      +7 mode (1 read, 2 write)
;   +8..31 embedded nkv view
;
; Stats (48 words):
;   +0 magic "NKTG" +1 version +2 live +3 allocs +4 frees
;   +5 joins +6 leaves +7 copies +8 tokens copied +9 forks
;   +10 opens +11 seals +12 view opens +13 view reads +14 view writes
;   +15 errors +16 last error +17 ops +18 cross-gen rejects
;   +19 stale rejects +20 shared-write rejects +21 page limit
;   +22 buffer +23 max pages +24 trace head +25 trace events
;   +26 trace wraps +27 roots created +28 root acquires +29 root releases
;   +30 roots freed +31 mirror checks +32 mirror errors +33 closes
;   +34 cows +35 prefix pages +36 nagent forks +37 binds +38 publishes
;   +39..47 reserved
;
; Trace entry (8 words): kind, seq, a, b, c, 0, hash, 0.
; Kinds: 1 open, 2 seal, 3 fork, 4 COW, 5 close, 6 page free, 7 publish,
; 8 weight bind.
;
; Return codes (nkvt_errno):
;   0 OK, 1 EBAD, 2 ENOENT, 3 ENOSPC, 4 EGEN, 5 ESTALE, 6 ESHARED,
;   7 EBLK, 8 EDUP, 9 EMIRROR.
;
; API (r0=0, r13=1, r14 grows up, r15 link):
;   nkvt_init       r1=page buffer word base r2=page limit (1..16) -> 0/-1
;   nkvt_open       r1=ctx r2=ngen agent r3=generation r4=cpu r5=branch
;                   r6=nagent id r7=table r8=cap r9=slots -> 1/0
;   nkvt_bind       r1=ctx r2=nsym weight root -> 1/0
;   nkvt_seal_prefix r1=ctx -> 1/0
;   nkvt_fork       r1=parent r2=child r3=child ngen agent r4=child gen
;                   r5=child table r6=cap r7=child branch r8=cpu
;                   -> child nagent id / 0
;   nkvt_publish    r1=ctx r2=new generation -> epoch / 0
;   nkvt_append     r1=ctx r2=value -> token index / -1
;   nkvt_view_open  r1=ctx r2=token r3=mode r4=out -> 1/0
;   nkvt_view_read  r1=ctx r2=view r3=out(4) -> 1/0
;   nkvt_view_write r1=ctx r2=view r3=value -> 1/0
;   nkvt_close      r1=ctx -> 1/0
;   nkvt_page_info  r1=page index r2=out(32) -> 0/-1
;   nkvt_stats      r1=out(48) -> 0/-1
;   nkvt_ctx_info   r1=ctx r2=out(32) -> 0/-1
;   nkvt_trace      r1=index r2=out(8) -> 0/-1
;   nkvt_trace_head -> head / 0
;   nkvt_errno      -> last error
;
; Requires nobj_init, nagent_init and nsym_init (nsym_init also calls
; ngen_init) before nkvt_open.  The page buffer is caller supplied so the tree
; library has no hidden payload address.  Page roots use nsym root slot
; page index + 1 (slot 0 unused); nsym root slot 15 is reserved for the
; caller's weight root in this gate.

.include "nkv.nas"
.include "nagent.nas"
.include "nsym.nas"

.equ NKT_TAB        0x359000
.equ NKT_MAXPAGE    16
.equ NKT_PSTRIDE    32
.equ NKT_TABWORDS   512
.equ NKT_STATS      0x359800
.equ NKT_SW         48
.equ NKT_TRACE      0x359A00
.equ NKT_TRACE_N    64
.equ NKT_TRACE_W    8
.equ NKT_TRACE_TOTAL 512
.equ NKT_SCR        0x30000
.equ NKT_SCR_STATUS 0x30000
.equ NKT_SCR_SLOT   0x30020
.equ NKT_SCR_SHAPE  0x30028
.equ NKT_SCR_PAY    0x30040
.equ NKT_WEIGHT_ROOT 15

.equ NKT_MAGIC      0x43544B4E       ; "NKTC"
.equ NKT_PMAGIC     0x50544B4E       ; "NKTP"
.equ NKT_VMAGIC     0x56544B4E       ; "NKTV"
.equ NKT_GMAGIC     0x47544B4E       ; "NKTG"
.equ NKT_VERSION    1
.equ NKT_REC_TAG    0xA5A5A5A5
.equ NKT_SLOTS      16
.equ NKT_PAGE_W     64
.equ NKT_BPT_BYTES  16
.equ NKT_NONE       0xFFFFFFFF

; context fields
.equ NKT_C_MAGIC    0
.equ NKT_C_VERSION  1
.equ NKT_C_AGENT    2
.equ NKT_C_GEN      3
.equ NKT_C_BRANCH   4
.equ NKT_C_PARENT   5
.equ NKT_C_NAGENT   6
.equ NKT_C_NAGKVGEN 7
.equ NKT_C_TAB      8
.equ NKT_C_TABCAP   9
.equ NKT_C_BLOCKTOK 10
.equ NKT_C_USED     11
.equ NKT_C_LIVE     12
.equ NKT_C_COPIES   13
.equ NKT_C_BPT      14
.equ NKT_C_SLOTS    15
.equ NKT_C_ADMIT    16
.equ NKT_C_ERR      17
.equ NKT_C_NGERR    18
.equ NKT_C_JOINS    19
.equ NKT_C_CHILDREN 20
.equ NKT_C_EPOCH    21
.equ NKT_C_VOPEN    22
.equ NKT_C_VMINT    23
.equ NKT_C_VIEWREAD 24
.equ NKT_C_VIEWWRITE 25
.equ NKT_C_NAGGEN   26
.equ NKT_C_DEPTH    27
.equ NKT_C_WROOT    28
.equ NKT_C_KVROOT   29
.equ NKT_C_PREFIX   30
.equ NKT_C_FLAGS    31

; page fields
.equ NKT_P_MAGIC    0
.equ NKT_P_VERSION  1
.equ NKT_P_GEN      2
.equ NKT_P_REFS     3
.equ NKT_P_STATE    4
.equ NKT_P_FLAGS    5
.equ NKT_P_CAP      6
.equ NKT_P_BASE     7
.equ NKT_P_BASEHI   8
.equ NKT_P_USED     9
.equ NKT_P_SLOTS    10
.equ NKT_P_ALLOCS   11
.equ NKT_P_COPIES   12
.equ NKT_P_TCOPY    13
.equ NKT_P_JOINS    14
.equ NKT_P_LEAVES   15
.equ NKT_P_FREES    16
.equ NKT_P_OWNER    17
.equ NKT_P_OWNERGEN 18
.equ NKT_P_IDX      19
.equ NKT_P_ROOT     20

; page/entry flags
.equ NKT_F_SHARED   1

; stats fields
.equ NKT_G_MAGIC    0
.equ NKT_G_VERSION  1
.equ NKT_G_LIVE     2
.equ NKT_G_ALLOCS   3
.equ NKT_G_FREES    4
.equ NKT_G_JOINS    5
.equ NKT_G_LEAVES   6
.equ NKT_G_COPIES   7
.equ NKT_G_TCOPY    8
.equ NKT_G_FORKS    9
.equ NKT_G_OPENS    10
.equ NKT_G_SEALS    11
.equ NKT_G_VOPEN    12
.equ NKT_G_VREAD    13
.equ NKT_G_VWRITE   14
.equ NKT_G_ERRORS   15
.equ NKT_G_LERR     16
.equ NKT_G_OPS      17
.equ NKT_G_XGEN     18
.equ NKT_G_XSTALE   19
.equ NKT_G_XSHARED  20
.equ NKT_G_LIMIT    21
.equ NKT_G_BUFFER   22
.equ NKT_G_MAXPAGE  23
.equ NKT_G_THEAD    24
.equ NKT_G_TEVENTS  25
.equ NKT_G_TWRAPS   26
.equ NKT_G_RCREATE  27
.equ NKT_G_RACQ     28
.equ NKT_G_RREL     29
.equ NKT_G_RFREE    30
.equ NKT_G_MIRCHK   31
.equ NKT_G_MIRERR   32
.equ NKT_G_CLOSES   33
.equ NKT_G_COWS     34
.equ NKT_G_PREFIXP  35
.equ NKT_G_NAGFORKS 36
.equ NKT_G_BINDS    37
.equ NKT_G_PUBLISH  38

; view fields
.equ NKT_V_MAGIC    0
.equ NKT_V_VERSION  1
.equ NKT_V_CTXGEN   2
.equ NKT_V_BRANCH   3
.equ NKT_V_TOKEN    4
.equ NKT_V_PAGE     5
.equ NKT_V_PAGEGEN  6
.equ NKT_V_MODE     7
.equ NKT_V_NKV      8

; entry fields
.equ NKT_E_PAGE     0
.equ NKT_E_MAPGEN   1
.equ NKT_E_FLAGS    2
.equ NKT_E_ROOT     3

; trace kinds
.equ NKT_T_OPEN     1
.equ NKT_T_SEAL     2
.equ NKT_T_FORK     3
.equ NKT_T_COW      4
.equ NKT_T_CLOSE    5
.equ NKT_T_FREE     6
.equ NKT_T_PUBLISH  7
.equ NKT_T_BIND     8

; errors
.equ NKT_OK         0
.equ NKT_EBAD       1
.equ NKT_ENOENT     2
.equ NKT_ENOSPC     3
.equ NKT_EGEN       4
.equ NKT_ESTALE     5
.equ NKT_ESHARED    6
.equ NKT_EBLK       7
.equ NKT_EDUP       8
.equ NKT_EMIRROR    9

.equ NKT_MIX_C1     0x9E3779B9
.equ NKT_MIX_C2     0x85EBCA6B
.equ NKT_MIX_C3     0xC2B2AE35

; ---------------------------------------------------------------------------
; nkt_mix r1=hash r2=word -> r1.  Same deterministic chain as ngen/nagent.
nkt_mix:
  BOOL.6 r1,r1,r2
  LA r3,#NKT_MIX_C1
  ADD r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  LA r3,#NKT_MIX_C2
  MUL r1,r1,r3
  SHR r4,r1,15
  BOOL.6 r1,r1,r4
  LA r3,#NKT_MIX_C3
  MUL r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  RET

; nkt_trace r1=kind r2=a r3=b r4=c -> new head.
nkt_trace:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  LA r5,#NKT_STATS
  LD r6,r5,#NKT_G_THEAD
  LD r7,r5,#NKT_G_TEVENTS
  ST r6,r14,5
  ST r7,r14,6
  ; hash = mix(mix(mix(mix(head,kind),a),b),c)
  ADD r1,r6,r0
  LD r2,r14,1
  CALL @nkt_mix
  LD r2,r14,2
  CALL @nkt_mix
  LD r2,r14,3
  CALL @nkt_mix
  LD r2,r14,4
  CALL @nkt_mix
  ST r1,r14,7
  ; entry = trace + (seq mod 64) * 8
  LD r2,r14,6
  MOVI r3,#NKT_TRACE_N
  MODU r2,r2,r3
  SHL r2,r2,3
  LA r3,#NKT_TRACE
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
  ; head, event count, wrap count
  LA r3,#NKT_STATS
  LD r1,r14,7
  ST r1,r3,#NKT_G_THEAD
  LD r2,r14,6
  ADD r2,r2,r13
  ST r2,r3,#NKT_G_TEVENTS
  MOVI r4,#NKT_TRACE_N
  CMP r2,r4
  JMP[LT] @nktt_out
  ; wraps increments when the just-written slot was the last of a ring
  LD r4,r14,6
  MOVI r5,#NKT_TRACE_N
  MODU r4,r4,r5
  MOVI r5,#NKT_TRACE_N
  SUB r5,r5,r13
  CMP r4,r5
  JMP[NE] @nktt_out
  LD r4,r3,#NKT_G_TWRAPS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_TWRAPS
nktt_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkt_fail r1=ctx(or 0) r2=code -> 0.
nkt_fail:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  ST r2,r14,2
  LA r3,#NKT_STATS
  LD r4,r3,#NKT_G_ERRORS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_ERRORS
  ST r2,r3,#NKT_G_LERR
  LD r4,r3,#NKT_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_OPS
  MOVI r4,#NKT_EGEN
  CMP r2,r4
  JMP[NE] @nktf_stale
  LD r4,r3,#NKT_G_XGEN
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_XGEN
  JMP @nktf_ctx
nktf_stale:
  MOVI r4,#NKT_ESTALE
  CMP r2,r4
  JMP[NE] @nktf_shared
  LD r4,r3,#NKT_G_XSTALE
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_XSTALE
  JMP @nktf_ctx
nktf_shared:
  MOVI r4,#NKT_ESHARED
  CMP r2,r4
  JMP[NE] @nktf_ctx
  LD r4,r3,#NKT_G_XSHARED
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_XSHARED
nktf_ctx:
  LD r1,r14,1
  CMP r1,r0
  JMP[EQ] @nktf_done
  LD r2,r14,2
  ST r2,r1,#NKT_C_ERR
nktf_done:
  MOVI r1,0
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkt_pageptr r1=index -> page header or 0.
nkt_pageptr:
  MOVI r2,#NKT_MAXPAGE
  CMP r1,r2
  JMP[GE] @nktpage_bad
  SHL r1,r1,5
  LA r2,#NKT_TAB
  ADD r1,r2,r1
  RET
nktpage_bad:
  MOVI r1,0
  RET

; nkt_buf r1=page index -> payload word base or 0.
nkt_buf:
  LA r2,#NKT_STATS
  LD r2,r2,#NKT_G_BUFFER
  CMP r2,r0
  JMP[EQ] @nktbuf_bad
  SHL r1,r1,6
  ADD r1,r2,r1
  RET
nktbuf_bad:
  MOVI r1,0
  RET

; nkt_ctx_live r1=ctx -> 1 if admitted and its ngen generation is CURRENT or
; an admitted old generation still DRAINING; 0 otherwise.
nkt_ctx_live:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  LD r2,r1,#NKT_C_MAGIC
  LA r3,#NKT_MAGIC
  CMP r2,r3
  JMP[NE] @nktcl_no
  LD r2,r1,#NKT_C_VERSION
  MOVI r3,#NKT_VERSION
  CMP r2,r3
  JMP[NE] @nktcl_no
  LD r2,r1,#NKT_C_ADMIT
  CMP r2,r0
  JMP[EQ] @nktcl_no
  LD r2,r1,#NKT_C_AGENT
  LA r3,#NKT_SCR_STATUS
  MOVI r4,0
  ADD r1,r2,r0
  ADD r2,r3,r0
  CALL @ngen_status
  CMP r1,r0
  JMP[NE] @nktcl_no
  LA r3,#NKT_SCR_STATUS
  LD r4,r3,3
  LD r5,r14,1
  LD r5,r5,#NKT_C_GEN
  CMP r4,r5
  JMP[EQ] @nktcl_yes
  ; older generation: only a DRAINING admitted in-flight snapshot is live
  LD r1,r14,1
  LD r1,r1,#NKT_C_AGENT
  ADD r2,r5,r0
  LA r3,#NKT_SCR_SLOT
  CALL @ngen_slot
  CMP r1,r0
  JMP[NE] @nktcl_no
  LA r3,#NKT_SCR_SLOT
  LD r4,r3,1
  MOVI r5,#NG_S_DRAINING
  CMP r4,r5
  JMP[NE] @nktcl_no
nktcl_yes:
  MOVI r1,1
  JMP @nktcl_out
nktcl_no:
  MOVI r1,0
nktcl_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkt_lookup r1=ctx r2=token -> r1=page r2=slot r3=entry or r1=0.
nkt_lookup:
  LD r3,r1,#NKT_C_USED
  CMP r2,r3
  JMP[GE] @nktl_bad
  LD r4,r1,#NKT_C_BLOCKTOK
  CMP r4,r0
  JMP[EQ] @nktl_bad
  DIVU r5,r2,r4
  MODU r6,r2,r4
  LD r7,r1,#NKT_C_TABCAP
  CMP r5,r7
  JMP[GE] @nktl_bad
  LD r8,r1,#NKT_C_TAB
  CMP r8,r0
  JMP[EQ] @nktl_bad
  SHL r9,r5,2
  ADD r8,r8,r9
  LD r9,r8,#NKT_E_PAGE
  CMP r9,r0
  JMP[EQ] @nktl_bad
  ADD r1,r9,r0
  ADD r2,r6,r0
  ADD r3,r8,r0
  RET
nktl_bad:
  MOVI r1,0
  MOVI r2,0
  MOVI r3,0
  RET

; ---------------------------------------------------------------------------
; nkt_root_bind r1=page -> nsym root index / -1.  Creates and acquires the
; shared root exactly once; later calls return the existing binding.
nkt_root_bind:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  LD r2,r1,#NKT_P_ROOT
  LD r3,r14,1
  LD r3,r3,#NKT_P_STATE
  MOVI r4,1
  CMP r3,r4
  JMP[NE] @nkrb_bad
  LA r4,#NKT_NONE
  CMP r2,r4
  JMP[EQ] @nkrb_new
  ADD r1,r2,r0
  JMP @nkrb_out
nkrb_new:
  ; page-root slot = page index + 1; slot 0 is unused and slot 15 is
  ; reserved for weight roots
  LD r3,r14,1
  LD r3,r3,#NKT_P_IDX
  ADDI r3,r3,1
  ST r3,r14,2
  MOVI r4,#NKT_WEIGHT_ROOT
  CMP r3,r4
  JMP[GE] @nkrb_bad
  ; payload: eight token values, used, generation, page index, owner agent
  LA r4,#NKT_SCR_PAY
  MOVI r5,16
nkrb_z:
  CMP r5,r0
  JMP[EQ] @nkrb_fill
  ST r0,r4,0
  ADD r4,r4,r13
  SUB r5,r5,r13
  JMP @nkrb_z
nkrb_fill:
  LD r5,r14,1
  LD r6,r5,#NKT_P_BASE
  LA r7,#NKT_SCR_PAY
  MOVI r8,8
nkrb_cp:
  CMP r8,r0
  JMP[EQ] @nkrb_meta
  LD r9,r6,1
  ST r9,r7,0
  ADDI r6,r6,4
  ADD r7,r7,r13
  SUB r8,r8,r13
  JMP @nkrb_cp
nkrb_meta:
  LD r5,r14,1
  LA r7,#NKT_SCR_PAY
  LD r6,r5,#NKT_P_USED
  ST r6,r7,8
  LD r6,r5,#NKT_P_GEN
  ST r6,r7,9
  LD r6,r5,#NKT_P_IDX
  ST r6,r7,10
  LD r6,r5,#NKT_P_OWNER
  ST r6,r7,11
  ; nsym_root_create(root, id, payload, 12)
  LD r1,r14,2
  LD r2,r14,2
  LA r3,0x4E4B5400
  ADD r2,r2,r3
  LA r3,#NKT_SCR_PAY
  MOVI r4,12
  CALL @nsym_root_create
  CMP r1,r0
  JMP[NE] @nkrb_bad
  LD r5,r14,1
  LD r2,r14,2
  ST r2,r5,#NKT_P_ROOT
  ; acquire the root for the page's existing reference
  ADD r1,r2,r0
  CALL @nsym_root_acquire
  LA r3,#NKT_NONE
  CMP r1,r3
  JMP[EQ] @nkrb_bad
  LD r5,r14,1
  LD r3,r5,#NKT_P_REFS
  ST r1,r14,3
  LA r4,#NKT_STATS
  LD r6,r4,#NKT_G_MIRCHK
  ADD r6,r6,r13
  ST r6,r4,#NKT_G_MIRCHK
  CMP r1,r3
  JMP[EQ] @nkrb_stats
  LD r6,r4,#NKT_G_MIRERR
  ADD r6,r6,r13
  ST r6,r4,#NKT_G_MIRERR
nkrb_stats:
  LA r4,#NKT_STATS
  LD r6,r4,#NKT_G_RCREATE
  ADD r6,r6,r13
  ST r6,r4,#NKT_G_RCREATE
  LD r6,r4,#NKT_G_RACQ
  ADD r6,r6,r13
  ST r6,r4,#NKT_G_RACQ
  LD r6,r4,#NKT_G_OPS
  ADD r6,r6,r13
  ST r6,r4,#NKT_G_OPS
  LD r1,r14,2
  JMP @nkrb_out
nkrb_bad:
  LA r1,0xFFFFFFFF
nkrb_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkt_page_new r1=ctx r2=generation -> page header or 0.
nkt_page_new:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,17
  ST r2,r14,18
  MOVI r3,0
  LA r4,#NKT_STATS
  LD r5,r4,#NKT_G_LIMIT
  LA r7,#NKT_TAB
nktpn_l:
  CMP r3,r5
  JMP[GE] @nktpn_fail
  SHL r6,r3,5
  ADD r6,r7,r6
  LD r8,r6,#NKT_P_STATE
  CMP r8,r0
  JMP[EQ] @nktpn_found
  ADD r3,r3,r13
  JMP @nktpn_l
nktpn_found:
  ST r6,r14,19
  ST r3,r14,20
  MOVI r8,0
nktpn_z:
  MOVI r9,#NKT_PSTRIDE
  CMP r8,r9
  JMP[GE] @nktpn_zd
  ADD r9,r6,r8
  ST r0,r9,0
  ADD r8,r8,r13
  JMP @nktpn_z
nktpn_zd:
  LD r1,r14,20
  CALL @nkt_buf
  CMP r1,r0
  JMP[EQ] @nktpn_fail
  ST r1,r14,21
  ; class-20 storage over this page's byte range (slots * 16 bytes)
  ADD r1,r1,r0
  SHL r1,r1,2
  MOVI r2,0
  LD r5,r14,17
  LD r5,r5,#NKT_C_BLOCKTOK
  SHL r3,r5,4
  MOVI r4,0
  MOVI r5,3
  MOVI r6,0
  CALL @nkv_storage_create
  CMP r1,r0
  JMP[EQ] @nktpn_fail
  ST r1,r14,22
  LD r6,r14,19
  LA r8,#NKT_PMAGIC
  ST r8,r6,#NKT_P_MAGIC
  MOVI r8,#NKT_VERSION
  ST r8,r6,#NKT_P_VERSION
  LD r7,r14,18
  ST r7,r6,#NKT_P_GEN
  MOVI r8,1
  ST r8,r6,#NKT_P_REFS
  ST r8,r6,#NKT_P_STATE
  ST r0,r6,#NKT_P_FLAGS
  LD r8,r14,22
  ST r8,r6,#NKT_P_CAP
  LD r8,r14,21
  ST r8,r6,#NKT_P_BASE
  ST r0,r6,#NKT_P_BASEHI
  ST r0,r6,#NKT_P_USED
  LD r8,r14,17
  LD r8,r8,#NKT_C_BLOCKTOK
  ST r8,r6,#NKT_P_SLOTS
  MOVI r8,1
  ST r8,r6,#NKT_P_ALLOCS
  LD r8,r14,20
  ST r8,r6,#NKT_P_IDX
  LD r8,r14,17
  LD r9,r8,#NKT_C_AGENT
  ST r9,r6,#NKT_P_OWNER
  LD r9,r8,#NKT_C_GEN
  ST r9,r6,#NKT_P_OWNERGEN
  LA r9,#NKT_NONE
  ST r9,r6,#NKT_P_ROOT
  LA r8,#NKT_STATS
  LD r9,r8,#NKT_G_LIVE
  ADD r9,r9,r13
  ST r9,r8,#NKT_G_LIVE
  LD r9,r8,#NKT_G_ALLOCS
  ADD r9,r9,r13
  ST r9,r8,#NKT_G_ALLOCS
  LD r9,r8,#NKT_G_OPS
  ADD r9,r9,r13
  ST r9,r8,#NKT_G_OPS
  ADD r1,r6,r0
  JMP @nktpn_out
nktpn_fail:
  MOVI r1,0
nktpn_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkt_release r1=ctx r2=page -> 1/0.  One page reference leaves; the nsym
; mirror root is released by the same amount.  At zero both are freed.
nkt_release:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r2,#NKT_P_STATE
  MOVI r4,1
  CMP r3,r4
  JMP[NE] @nktrel_fail
  LD r3,r2,#NKT_P_REFS
  CMP r3,r0
  JMP[EQ] @nktrel_fail
  SUB r3,r3,r13
  ST r3,r2,#NKT_P_REFS
  LD r4,r2,#NKT_P_LEAVES
  ADD r4,r4,r13
  ST r4,r2,#NKT_P_LEAVES
  LA r5,#NKT_STATS
  LD r4,r5,#NKT_G_LEAVES
  ADD r4,r4,r13
  ST r4,r5,#NKT_G_LEAVES
  ; mirror the leave on the nsym shared root
  LD r4,r2,#NKT_P_ROOT
  LA r6,#NKT_NONE
  CMP r4,r6
  JMP[EQ] @nktrel_noroot
  ST r4,r14,3
  ADD r1,r4,r0
  CALL @nsym_root_release
  LA r4,#NKT_NONE
  CMP r1,r4
  JMP[EQ] @nktrel_mirbad
  LD r4,r14,2
  LD r5,r4,#NKT_P_REFS
  ST r1,r14,4
  LA r6,#NKT_STATS
  LD r7,r6,#NKT_G_RREL
  ADD r7,r7,r13
  ST r7,r6,#NKT_G_RREL
  LD r7,r6,#NKT_G_MIRCHK
  ADD r7,r7,r13
  ST r7,r6,#NKT_G_MIRCHK
  CMP r1,r5
  JMP[EQ] @nktrel_rmir_ok
  LD r7,r6,#NKT_G_MIRERR
  ADD r7,r7,r13
  ST r7,r6,#NKT_G_MIRERR
nktrel_rmir_ok:
  CMP r1,r0
  JMP[NE] @nktrel_noroot
  LD r7,r6,#NKT_G_RFREE
  ADD r7,r7,r13
  ST r7,r6,#NKT_G_RFREE
nktrel_noroot:
  LD r2,r14,2
  LD r3,r2,#NKT_P_REFS
  CMP r3,r0
  JMP[NE] @nktrel_ok
  LD r1,r2,#NKT_P_CAP
  CMP r1,r0
  JMP[EQ] @nktrel_nocap
  CALL @nobj_release
nktrel_nocap:
  LD r2,r14,2
  ST r0,r2,#NKT_P_STATE
  ST r0,r2,#NKT_P_CAP
  LD r4,r2,#NKT_P_FREES
  ADD r4,r4,r13
  ST r4,r2,#NKT_P_FREES
  LA r5,#NKT_STATS
  LD r4,r5,#NKT_G_FREES
  ADD r4,r4,r13
  ST r4,r5,#NKT_G_FREES
  LD r4,r5,#NKT_G_LIVE
  SUB r4,r4,r13
  ST r4,r5,#NKT_G_LIVE
  LD r4,r5,#NKT_G_OPS
  ADD r4,r4,r13
  ST r4,r5,#NKT_G_OPS
  ; tree trace: page free
  MOVI r1,#NKT_T_FREE
  LD r2,r2,#NKT_P_IDX
  LD r3,r14,2
  LD r3,r3,#NKT_P_GEN
  MOVI r4,0
  CALL @nkt_trace
nktrel_ok:
  MOVI r1,1
  JMP @nktrel_out
nktrel_mirbad:
  LA r6,#NKT_STATS
  LD r7,r6,#NKT_G_MIRERR
  ADD r7,r7,r13
  ST r7,r6,#NKT_G_MIRERR
  JMP @nktrel_noroot
nktrel_fail:
  MOVI r1,0
nktrel_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkt_cow r1=ctx r2=old shared page -> new private page or 0.
nkt_cow:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  LD r2,r1,#NKT_C_GEN
  CALL @nkt_page_new
  CMP r1,r0
  JMP[EQ] @nktcow_fail
  ST r1,r14,3
  LD r4,r14,2
  LD r5,r4,#NKT_P_BASE
  LD r6,r1,#NKT_P_BASE
  LD r7,r4,#NKT_P_USED
  ST r7,r14,4
  SHL r8,r7,2
  MOVI r9,0
nktcow_cp:
  CMP r9,r8
  JMP[GE] @nktcow_cpd
  ADD r1,r5,r9
  LD r1,r1,0
  ADD r2,r6,r9
  ST r1,r2,0
  ADD r9,r9,r13
  JMP @nktcow_cp
nktcow_cpd:
  LD r3,r14,3
  LD r7,r3,#NKT_P_GEN
  LD r8,r14,4
  MOVI r9,0
nktcow_g:
  CMP r9,r8
  JMP[GE] @nktcow_gd
  SHL r1,r9,2
  ADD r1,r6,r1
  ST r7,r1,3
  ADD r9,r9,r13
  JMP @nktcow_g
nktcow_gd:
  LD r3,r14,3
  LD r7,r14,4
  ST r7,r3,#NKT_P_USED
  LD r4,r14,2
  LD r7,r4,#NKT_P_COPIES
  ADD r7,r7,r13
  ST r7,r4,#NKT_P_COPIES
  LD r7,r14,4
  LD r8,r4,#NKT_P_TCOPY
  ADD r8,r8,r7
  ST r8,r4,#NKT_P_TCOPY
  LA r8,#NKT_STATS
  LD r9,r8,#NKT_G_COPIES
  ADD r9,r9,r13
  ST r9,r8,#NKT_G_COPIES
  LD r9,r8,#NKT_G_TCOPY
  ADD r9,r9,r7
  ST r9,r8,#NKT_G_TCOPY
  LD r9,r8,#NKT_G_COWS
  ADD r9,r9,r13
  ST r9,r8,#NKT_G_COWS
  LD r9,r8,#NKT_G_OPS
  ADD r9,r9,r13
  ST r9,r8,#NKT_G_OPS
  LD r1,r14,1
  LD r9,r1,#NKT_C_COPIES
  ADD r9,r9,r13
  ST r9,r1,#NKT_C_COPIES
  ; trace COW(branch, old index, new index)
  LD r4,r14,2
  LD r2,r4,#NKT_P_IDX
  LD r3,r14,3
  LD r3,r3,#NKT_P_IDX
  LD r4,r1,#NKT_C_BRANCH
  MOVI r1,#NKT_T_COW
  CALL @nkt_trace
  ; leave the shared ancestor page (and its nsym root)
  LD r1,r14,1
  LD r2,r14,2
  CALL @nkt_release
  LD r1,r14,3
  JMP @nktcow_out
nktcow_fail:
  MOVI r1,0
nktcow_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvt_init r1=page buffer word base r2=page limit (1..16) -> 0/-1
nkvt_init:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  CMP r1,r0
  JMP[EQ] @nkti_bad
  CMP r2,r0
  JMP[EQ] @nkti_bad
  MOVI r3,#NKT_MAXPAGE
  CMP r2,r3
  JMP[GT] @nkti_bad
  LA r1,#NKT_TAB
  MOVI r2,#NKT_TABWORDS
nkti_t:
  CMP r2,r0
  JMP[EQ] @nkti_s
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkti_t
nkti_s:
  LA r1,#NKT_STATS
  MOVI r2,#NKT_SW
nkti_sl:
  CMP r2,r0
  JMP[EQ] @nkti_tr
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkti_sl
nkti_tr:
  LA r1,#NKT_TRACE
  MOVI r2,#NKT_TRACE_TOTAL
nkti_trl:
  CMP r2,r0
  JMP[EQ] @nkti_buf
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkti_trl
nkti_buf:
  LD r1,r14,1
  LD r2,r14,2
  SHL r2,r2,6
nkti_b:
  CMP r2,r0
  JMP[EQ] @nkti_meta
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkti_b
nkti_meta:
  LA r1,#NKT_STATS
  LA r2,#NKT_GMAGIC
  ST r2,r1,#NKT_G_MAGIC
  MOVI r2,#NKT_VERSION
  ST r2,r1,#NKT_G_VERSION
  LD r2,r14,2
  ST r2,r1,#NKT_G_LIMIT
  MOVI r3,#NKT_MAXPAGE
  ST r3,r1,#NKT_G_MAXPAGE
  LD r2,r14,1
  ST r2,r1,#NKT_G_BUFFER
  MOVI r1,0
  JMP @nkti_out
nkti_bad:
  LA r1,0xFFFFFFFF
nkti_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvt_open r1=ctx r2=agent r3=gen r4=cpu r5=branch r6=nagent id
;              r7=table r8=cap r9=tokens/block -> 1/0
nkvt_open:
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
  JMP[EQ] @nkto_bad
  CMP r2,r0
  JMP[EQ] @nkto_bad
  CMP r3,r0
  JMP[EQ] @nkto_bad
  CMP r7,r0
  JMP[EQ] @nkto_bad
  CMP r8,r0
  JMP[EQ] @nkto_bad
  CMP r9,r0
  JMP[EQ] @nkto_bad
  MOVI r10,#NKT_SLOTS
  CMP r9,r10
  JMP[GT] @nkto_bad
  MOVI r10,#NG_MAX_CPU
  CMP r4,r10
  JMP[GE] @nkto_bad
  LD r1,r14,1
  MOVI r2,32
nkto_z:
  CMP r2,r0
  JMP[EQ] @nkto_fill
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkto_z
nkto_fill:
  LD r1,r14,1
  LA r2,#NKT_MAGIC
  ST r2,r1,#NKT_C_MAGIC
  MOVI r2,#NKT_VERSION
  ST r2,r1,#NKT_C_VERSION
  LD r2,r14,2
  ST r2,r1,#NKT_C_AGENT
  LD r2,r14,3
  ST r2,r1,#NKT_C_GEN
  LD r2,r14,5
  ST r2,r1,#NKT_C_BRANCH
  LD r2,r14,6
  ST r2,r1,#NKT_C_NAGENT
  LD r2,r14,7
  ST r2,r1,#NKT_C_TAB
  LD r2,r14,8
  ST r2,r1,#NKT_C_TABCAP
  LD r2,r14,9
  ST r2,r1,#NKT_C_BLOCKTOK
  MOVI r2,#NKT_BPT_BYTES
  ST r2,r1,#NKT_C_BPT
  MOVI r2,#NKT_SLOTS
  ST r2,r1,#NKT_C_SLOTS
  LD r1,r14,2
  LD r2,r14,3
  LD r3,r14,4
  CALL @ngen_enter
  LD r4,r14,3
  CMP r1,r4
  JMP[EQ] @nkto_admit
  LD r1,r14,1
  CALL @ngen_errno
  LD r2,r14,1
  ST r1,r2,#NKT_C_NGERR
  MOVI r2,#NKT_ESTALE
  CALL @nkt_fail
  JMP @nkto_out
nkto_admit:
  LD r1,r14,7
  LD r2,r14,8
  SHL r2,r2,2
nkto_t:
  CMP r2,r0
  JMP[EQ] @nkto_done
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkto_t
nkto_done:
  LD r1,r14,1
  MOVI r2,1
  ST r2,r1,#NKT_C_ADMIT
  LD r2,r14,2
  ADD r1,r2,r0
  CALL @ngen_epoch
  LD r2,r14,1
  ST r1,r2,#NKT_C_EPOCH
  LA r3,#NKT_STATS
  LD r4,r3,#NKT_G_OPENS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_OPENS
  LD r4,r3,#NKT_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_OPS
  ; trace open(branch, generation)
  LD r2,r14,5
  LD r3,r14,3
  MOVI r1,#NKT_T_OPEN
  MOVI r4,0
  CALL @nkt_trace
  MOVI r1,1
  JMP @nkto_out
nkto_bad:
  LD r1,r14,1
  MOVI r2,#NKT_EBAD
  CALL @nkt_fail
nkto_out:
  ADDI r14,r14,-80
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvt_bind r1=ctx r2=nsym weight root -> 1/0
nkvt_bind:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,#NKT_C_MAGIC
  LA r4,#NKT_MAGIC
  CMP r3,r4
  JMP[NE] @nktbind_bad
  LD r3,r1,#NKT_C_ADMIT
  CMP r3,r0
  JMP[EQ] @nktbind_bad
  LD r3,r1,#NKT_C_NAGENT
  CMP r3,r0
  JMP[EQ] @nktbind_bad
  LD r3,r14,2
  CMP r3,r0
  JMP[EQ] @nktbind_bad
  ; nagent weight root: immutable once set
  LD r1,r1,#NKT_C_NAGENT
  LD r2,r14,2
  MOVI r3,0
  CALL @nagent_roots
  CMP r1,r0
  JMP[NE] @nktbind_bad
  LD r1,r14,2
  CALL @nsym_root_acquire
  LA r3,#NKT_NONE
  CMP r1,r3
  JMP[EQ] @nktbind_bad
  ST r1,r14,3
  LD r1,r14,1
  LD r2,r14,2
  ST r2,r1,#NKT_C_WROOT
  LA r3,#NKT_STATS
  LD r4,r3,#NKT_G_RACQ
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_RACQ
  LD r4,r3,#NKT_G_BINDS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_BINDS
  LD r4,r3,#NKT_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_OPS
  ; trace bind(branch, root)
  LD r2,r1,#NKT_C_BRANCH
  LD r3,r14,2
  MOVI r1,#NKT_T_BIND
  MOVI r4,0
  CALL @nkt_trace
  MOVI r1,1
  JMP @nktb_out
nktbind_bad:
  LD r1,r14,1
  MOVI r2,#NKT_EBAD
  CALL @nkt_fail
nktb_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvt_seal_prefix r1=ctx -> 1/0.  Marks every live page immutable and binds
; one nsym root per page.  Binds the first root as the nagent KV root.
nkvt_seal_prefix:
  ST r15,r14,0
  ADDI r14,r14,56
  ST r1,r14,1
  LD r2,r1,#NKT_C_MAGIC
  LA r3,#NKT_MAGIC
  CMP r2,r3
  JMP[NE] @nkts_bad
  LD r2,r1,#NKT_C_ADMIT
  CMP r2,r0
  JMP[EQ] @nkts_bad
  LD r2,r1,#NKT_C_PREFIX
  CMP r2,r0
  JMP[NE] @nkts_ok
  LD r3,r1,#NKT_C_TAB
  LD r4,r1,#NKT_C_LIVE
  ST r4,r14,2
  MOVI r5,0
  ST r5,r14,3
  LA r5,#NKT_NONE
  ST r5,r14,4
nkts_l:
  LD r5,r14,3
  LD r4,r14,2
  CMP r5,r4
  JMP[GE] @nkts_done
  LD r1,r14,1
  LD r3,r1,#NKT_C_TAB
  SHL r6,r5,2
  ADD r7,r3,r6
  ST r7,r14,5
  LD r1,r7,#NKT_E_PAGE
  CMP r1,r0
  JMP[EQ] @nkts_next
  ; mark shared and bind/acquire the page root
  LD r2,r1,#NKT_P_FLAGS
  MOVI r8,#NKT_F_SHARED
  BOOL.14 r2,r2,r8
  ST r2,r1,#NKT_P_FLAGS
  CALL @nkt_root_bind
  LA r2,#NKT_NONE
  CMP r1,r2
  JMP[EQ] @nkts_bad
  LD r7,r14,5
  ST r1,r7,#NKT_E_ROOT
  MOVI r2,1
  ST r2,r7,#NKT_E_FLAGS
  LD r8,r14,4
  LA r9,#NKT_NONE
  CMP r8,r9
  JMP[NE] @nkts_next
  ST r1,r14,4
nkts_next:
  LD r5,r14,3
  ADD r5,r5,r13
  ST r5,r14,3
  LD r3,r14,1
  LD r3,r3,#NKT_C_TAB
  JMP @nkts_l
nkts_done:
  LD r1,r14,1
  LD r2,r14,2
  ST r2,r1,#NKT_C_PREFIX
  ; bind the first prefix page root as the nagent KV root
  LD r3,r14,4
  LA r4,#NKT_NONE
  CMP r3,r4
  JMP[EQ] @nkts_stats
  LD r2,r1,#NKT_C_NAGENT
  CMP r2,r0
  JMP[EQ] @nkts_stats
  ST r3,r1,#NKT_C_KVROOT
  ST r3,r14,6
  ADD r1,r2,r0
  MOVI r2,0
  LD r3,r14,6
  CALL @nagent_roots
  CMP r1,r0
  JMP[NE] @nkts_bad
  LD r1,r14,1
  LD r1,r1,#NKT_C_NAGENT
  CALL @nagent_record
  LD r2,r1,#NAG_KVGEN_F
  LD r1,r14,1
  ST r2,r1,#NKT_C_NAGKVGEN
nkts_stats:
  LA r3,#NKT_STATS
  LD r4,r3,#NKT_G_SEALS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_SEALS
  LD r4,r3,#NKT_G_PREFIXP
  LD r5,r14,2
  ADD r4,r4,r5
  ST r4,r3,#NKT_G_PREFIXP
  LD r4,r3,#NKT_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_OPS
  ; trace seal(branch, page count)
  LD r1,r14,1
  LD r2,r1,#NKT_C_BRANCH
  LD r3,r14,2
  MOVI r1,#NKT_T_SEAL
  MOVI r4,0
  CALL @nkt_trace
nkts_ok:
  MOVI r1,1
  JMP @nkts_out
nkts_bad:
  LD r1,r14,1
  MOVI r2,#NKT_EBAD
  CALL @nkt_fail
nkts_out:
  ADDI r14,r14,-56
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvt_fork r1=parent r2=child r3=child agent r4=child gen r5=child table
;              r6=cap r7=child branch r8=cpu -> child nagent id / 0
nkvt_fork:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  ST r7,r14,7
  ST r8,r14,8
  CMP r1,r0
  JMP[EQ] @nktf_bad
  CMP r2,r0
  JMP[EQ] @nktf_bad
  CMP r1,r2
  JMP[EQ] @nktf_bad
  CMP r3,r0
  JMP[EQ] @nktf_bad
  CMP r4,r0
  JMP[EQ] @nktf_bad
  CMP r5,r0
  JMP[EQ] @nktf_bad
  CMP r6,r0
  JMP[EQ] @nktf_bad
  ; parent must be admitted and current
  LD r1,r14,1
  CALL @nkt_ctx_live
  CMP r1,r0
  JMP[EQ] @nktfork_stale
  LD r1,r14,1
  LD r1,r1,#NKT_C_AGENT
  LA r2,#NKT_SCR_STATUS
  CALL @ngen_status
  CMP r1,r0
  JMP[NE] @nktfork_stale
  LA r3,#NKT_SCR_STATUS
  LD r4,r3,3
  LD r5,r14,1
  LD r5,r5,#NKT_C_GEN
  CMP r4,r5
  JMP[NE] @nktfork_stale
  LD r5,r14,1
  LD r5,r5,#NKT_C_LIVE
  LD r6,r14,6
  CMP r5,r6
  JMP[GT] @nktf_nospc
  ; child ngen agent: start 1, then publish up to the requested generation
  LD r1,r14,3
  MOVI r2,1
  CALL @ngen_start
  CMP r1,r0
  JMP[EQ] @nktfork_stale
  MOVI r5,2
  ST r5,r14,9
nktf_pub:
  LD r5,r14,9
  LD r4,r14,4
  CMP r5,r4
  JMP[GT] @nktf_enter
  LD r1,r14,3
  ADD r2,r5,r0
  MOVI r3,0
  MOVI r4,0
  CALL @ngen_publish
  CMP r1,r0
  JMP[EQ] @nktfork_stale
  LD r5,r14,9
  ADD r5,r5,r13
  ST r5,r14,9
  JMP @nktf_pub
nktf_enter:
  LD r1,r14,3
  LD r2,r14,4
  LD r3,r14,8
  CALL @ngen_enter
  LD r4,r14,4
  CMP r1,r4
  JMP[NE] @nktfork_stale
  ST r1,r14,10
  ; nagent_fork-style child record
  LD r1,r14,1
  LD r1,r1,#NKT_C_NAGENT
  LD r2,r14,8
  MOVI r3,0
  CALL @nagent_fork
  CMP r1,r0
  JMP[EQ] @nktfork_stale
  ST r1,r14,11
  LD r1,r14,11
  CALL @nagent_record
  CMP r1,r0
  JMP[EQ] @nktfork_stale
  ST r1,r14,12
  LD r2,r1,#NAG_KVGEN_F
  ST r2,r14,13
  LD r1,r14,1
  LD r1,r1,#NKT_C_NAGENT
  CALL @nagent_record
  LD r2,r1,#NAG_KVGEN_F
  ADD r2,r2,r13
  LD r3,r14,13
  CMP r3,r2
  JMP[NE] @nktfork_stale
  ; initialize the child context
  LD r1,r14,2
  MOVI r2,32
nktf_z:
  CMP r2,r0
  JMP[EQ] @nktf_fill
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nktf_z
nktf_fill:
  LD r1,r14,2
  LA r2,#NKT_MAGIC
  ST r2,r1,#NKT_C_MAGIC
  MOVI r2,#NKT_VERSION
  ST r2,r1,#NKT_C_VERSION
  LD r3,r14,1
  LD r2,r14,3
  ST r2,r1,#NKT_C_AGENT
  LD r2,r14,4
  ST r2,r1,#NKT_C_GEN
  LD r2,r14,7
  ST r2,r1,#NKT_C_BRANCH
  LD r2,r3,#NKT_C_BRANCH
  ST r2,r1,#NKT_C_PARENT
  LD r2,r14,11
  ST r2,r1,#NKT_C_NAGENT
  LD r2,r14,13
  ST r2,r1,#NKT_C_NAGKVGEN
  LD r2,r14,5
  ST r2,r1,#NKT_C_TAB
  LD r2,r14,6
  ST r2,r1,#NKT_C_TABCAP
  LD r2,r3,#NKT_C_BLOCKTOK
  ST r2,r1,#NKT_C_BLOCKTOK
  LD r2,r3,#NKT_C_BPT
  ST r2,r1,#NKT_C_BPT
  LD r2,r3,#NKT_C_SLOTS
  ST r2,r1,#NKT_C_SLOTS
  LD r2,r3,#NKT_C_USED
  ST r2,r1,#NKT_C_USED
  MOVI r2,1
  ST r2,r1,#NKT_C_ADMIT
  LD r2,r14,10
  ST r2,r1,#NKT_C_EPOCH
  LD r2,r3,#NKT_C_DEPTH
  ADD r2,r2,r13
  ST r2,r1,#NKT_C_DEPTH
  LD r2,r3,#NKT_C_WROOT
  ST r2,r1,#NKT_C_WROOT
  LD r2,r3,#NKT_C_LIVE
  ST r2,r1,#NKT_C_PREFIX
  ST r2,r14,14
  ; acquire the shared weight root for the child
  LD r2,r3,#NKT_C_WROOT
  CMP r2,r0
  JMP[EQ] @nktf_share
  ADD r1,r2,r0
  CALL @nsym_root_acquire
  LA r3,#NKT_NONE
  CMP r1,r3
  JMP[EQ] @nktfork_stale
  LA r3,#NKT_STATS
  LD r4,r3,#NKT_G_RACQ
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_RACQ
  LD r4,r3,#NKT_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_OPS
nktf_share:
  ST r0,r14,18
nktf_sl:
  LD r6,r14,18
  LD r5,r14,14
  CMP r6,r5
  JMP[GE] @nktf_sdone
  LD r3,r14,1
  LD r3,r3,#NKT_C_TAB
  SHL r7,r6,2
  ADD r8,r3,r7
  LD r1,r8,#NKT_E_PAGE
  CMP r1,r0
  JMP[EQ] @nktf_snext
  ; ensure a mirror root and acquire it for this child join
  CALL @nkt_root_bind
  LA r2,#NKT_NONE
  CMP r1,r2
  JMP[EQ] @nktfork_stale
  LD r6,r14,18
  ST r1,r14,15
  LD r9,r14,5
  SHL r7,r6,2
  ADD r9,r9,r7
  ST r1,r9,#NKT_E_ROOT
  ADD r1,r1,r0
  CALL @nsym_root_acquire
  LA r3,#NKT_NONE
  CMP r1,r3
  JMP[EQ] @nktfork_stale
  ST r1,r14,17
  ; page.refs++, page.joins++, entry page/mapgen/flags
  LD r6,r14,18
  LD r8,r14,1
  LD r8,r8,#NKT_C_TAB
  SHL r7,r6,2
  ADD r8,r8,r7
  LD r1,r8,#NKT_E_PAGE
  LD r2,r1,#NKT_P_REFS
  ADD r2,r2,r13
  ST r2,r1,#NKT_P_REFS
  LD r2,r1,#NKT_P_JOINS
  ADD r2,r2,r13
  ST r2,r1,#NKT_P_JOINS
  LD r2,r1,#NKT_P_FLAGS
  MOVI r3,#NKT_F_SHARED
  BOOL.14 r2,r2,r3
  ST r2,r1,#NKT_P_FLAGS
  LD r9,r14,5
  SHL r7,r6,2
  ADD r9,r9,r7
  ST r1,r9,#NKT_E_PAGE
  LD r2,r14,4
  ST r2,r9,#NKT_E_MAPGEN
  MOVI r2,1
  ST r2,r9,#NKT_E_FLAGS
  LD r2,r14,15
  ST r2,r9,#NKT_E_ROOT
  ; mirror check page.refs == root.refs
  LD r3,r14,17
  LD r2,r1,#NKT_P_REFS
  LA r4,#NKT_STATS
  LD r7,r4,#NKT_G_MIRCHK
  ADD r7,r7,r13
  ST r7,r4,#NKT_G_MIRCHK
  CMP r3,r2
  JMP[EQ] @nktf_smir_ok
  LD r7,r4,#NKT_G_MIRERR
  ADD r7,r7,r13
  ST r7,r4,#NKT_G_MIRERR
nktf_smir_ok:
  LA r4,#NKT_STATS
  LD r7,r4,#NKT_G_JOINS
  ADD r7,r7,r13
  ST r7,r4,#NKT_G_JOINS
  LD r7,r4,#NKT_G_RACQ
  ADD r7,r7,r13
  ST r7,r4,#NKT_G_RACQ
  LD r7,r4,#NKT_G_OPS
  ADD r7,r7,r13
  ST r7,r4,#NKT_G_OPS
nktf_snext:
  LD r6,r14,18
  ADD r6,r6,r13
  ST r6,r14,18
  JMP @nktf_sl
nktf_sdone:
  LD r1,r14,2
  LD r2,r14,14
  ST r2,r1,#NKT_C_LIVE
  LD r2,r14,1
  LD r3,r2,#NKT_C_JOINS
  LD r4,r2,#NKT_C_LIVE
  ADD r3,r3,r4
  ST r3,r2,#NKT_C_JOINS
  LD r3,r2,#NKT_C_CHILDREN
  ADD r3,r3,r13
  ST r3,r2,#NKT_C_CHILDREN
  LA r3,#NKT_STATS
  LD r4,r3,#NKT_G_FORKS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_FORKS
  LD r4,r3,#NKT_G_NAGFORKS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_NAGFORKS
  LD r4,r3,#NKT_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_OPS
  ; trace fork(parent branch, child branch, child gen)
  LD r1,r14,1
  LD r2,r1,#NKT_C_BRANCH
  LD r3,r14,7
  LD r4,r14,4
  MOVI r1,#NKT_T_FORK
  CALL @nkt_trace
  LD r1,r14,11
  JMP @nktf_out
nktf_bad:
  LD r1,r14,1
  MOVI r2,#NKT_EBAD
  CALL @nkt_fail
  JMP @nktf_out
nktfork_stale:
  LD r1,r14,1
  MOVI r2,#NKT_ESTALE
  CALL @nkt_fail
  JMP @nktf_out
nktf_nospc:
  LD r1,r14,1
  MOVI r2,#NKT_ENOSPC
  CALL @nkt_fail
nktf_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvt_publish r1=ctx r2=new generation -> epoch / 0
nkvt_publish:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,#NKT_C_MAGIC
  LA r4,#NKT_MAGIC
  CMP r3,r4
  JMP[NE] @nktpub_bad
  LD r3,r1,#NKT_C_ADMIT
  CMP r3,r0
  JMP[EQ] @nktpub_bad
  LD r1,r1,#NKT_C_AGENT
  LD r2,r14,2
  MOVI r3,0
  MOVI r4,0
  CALL @ngen_publish
  CMP r1,r0
  JMP[EQ] @nktp_stale
  ST r1,r14,3
  LD r2,r14,1
  ST r1,r2,#NKT_C_EPOCH
  LA r3,#NKT_STATS
  LD r4,r3,#NKT_G_PUBLISH
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_PUBLISH
  LD r4,r3,#NKT_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_OPS
  ; trace publish(branch, new gen)
  LD r2,r2,#NKT_C_BRANCH
  LD r3,r14,2
  MOVI r1,#NKT_T_PUBLISH
  MOVI r4,0
  CALL @nkt_trace
  LD r1,r14,3
  JMP @nktp_out
nktpub_bad:
  LD r1,r14,1
  MOVI r2,#NKT_EBAD
  CALL @nkt_fail
  JMP @nktp_out
nktp_stale:
  LD r1,r14,1
  MOVI r2,#NKT_ESTALE
  CALL @nkt_fail
nktp_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvt_append r1=ctx r2=value -> token index / -1
nkvt_append:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,#NKT_C_MAGIC
  LA r4,#NKT_MAGIC
  CMP r3,r4
  JMP[NE] @nkta_bad
  LD r3,r1,#NKT_C_VERSION
  MOVI r4,#NKT_VERSION
  CMP r3,r4
  JMP[NE] @nkta_bad
  LD r3,r1,#NKT_C_ADMIT
  CMP r3,r0
  JMP[EQ] @nkta_stale
  CALL @nkt_ctx_live
  CMP r1,r0
  JMP[EQ] @nkta_stale
  LD r1,r14,1
  LD r3,r1,#NKT_C_USED
  ST r3,r14,3
  LD r4,r1,#NKT_C_BLOCKTOK
  LD r5,r1,#NKT_C_TABCAP
  MUL r5,r5,r4
  CMP r3,r5
  JMP[GE] @nkta_nospc
  DIVU r4,r3,r4
  ST r4,r14,4
  LD r5,r1,#NKT_C_BLOCKTOK
  MODU r6,r3,r5
  ST r6,r14,5
  LD r7,r1,#NKT_C_TAB
  SHL r8,r4,2
  ADD r7,r7,r8
  ST r7,r14,6
  LD r8,r7,#NKT_E_PAGE
  CMP r8,r0
  JMP[NE] @nkta_have
  LD r9,r1,#NKT_C_LIVE
  CMP r4,r9
  JMP[NE] @nkta_blk
  ADD r1,r1,r0
  LD r2,r1,#NKT_C_GEN
  CALL @nkt_page_new
  CMP r1,r0
  JMP[EQ] @nkta_nospc
  LD r7,r14,6
  ST r1,r7,#NKT_E_PAGE
  LD r2,r14,1
  LD r2,r2,#NKT_C_GEN
  ST r2,r7,#NKT_E_MAPGEN
  ST r0,r7,#NKT_E_FLAGS
  LD r2,r14,1
  LD r3,r2,#NKT_C_LIVE
  ADD r3,r3,r13
  ST r3,r2,#NKT_C_LIVE
  ADD r8,r1,r0
  JMP @nkta_have
nkta_have:
  ST r8,r14,7
  LD r2,r8,#NKT_P_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nkta_blk
  ; shared/refcounted page: COW exactly this page before writing
  LD r4,r8,#NKT_P_FLAGS
  MOVI r5,#NKT_F_SHARED
  BOOL.8 r4,r4,r5
  CMP r4,r0
  JMP[NE] @nkta_cow
  LD r4,r8,#NKT_P_REFS
  MOVI r5,1
  CMP r4,r5
  JMP[GT] @nkta_cow
  ; private page must belong to this generation
  LD r1,r14,1
  LD r2,r1,#NKT_C_GEN
  LD r3,r8,#NKT_P_GEN
  CMP r3,r2
  JMP[NE] @nkta_blk
  JMP @nkta_write
nkta_cow:
  LD r1,r14,1
  ADD r2,r8,r0
  CALL @nkt_cow
  CMP r1,r0
  JMP[EQ] @nkta_nospc
  ST r1,r14,7
  LD r7,r14,6
  ST r1,r7,#NKT_E_PAGE
  LD r2,r14,1
  LD r2,r2,#NKT_C_GEN
  ST r2,r7,#NKT_E_MAPGEN
  ST r0,r7,#NKT_E_FLAGS
nkta_write:
  LD r8,r14,7
  LD r3,r14,5
  LD r4,r8,#NKT_P_USED
  CMP r3,r4
  JMP[NE] @nkta_blk
  LD r5,r8,#NKT_P_SLOTS
  CMP r4,r5
  JMP[GE] @nkta_blk
  LD r6,r8,#NKT_P_BASE
  SHL r3,r3,2
  ADD r6,r6,r3
  LD r1,r14,3
  ST r1,r6,0
  LD r1,r14,2
  ST r1,r6,1
  LA r1,#NKT_REC_TAG
  ST r1,r6,2
  LD r1,r8,#NKT_P_GEN
  ST r1,r6,3
  LD r1,r8,#NKT_P_USED
  ADD r1,r1,r13
  ST r1,r8,#NKT_P_USED
  LD r1,r14,1
  LD r2,r1,#NKT_C_USED
  ADD r2,r2,r13
  ST r2,r1,#NKT_C_USED
  LA r3,#NKT_STATS
  LD r4,r3,#NKT_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKT_G_OPS
  LD r1,r14,3
  JMP @nkta_out
nkta_bad:
  LD r1,r14,1
  MOVI r2,#NKT_EBAD
  CALL @nkt_fail
  JMP @nkta_out
nkta_blk:
  LD r1,r14,1
  MOVI r2,#NKT_EBLK
  CALL @nkt_fail
  JMP @nkta_out
nkta_stale:
  LD r1,r14,1
  MOVI r2,#NKT_ESTALE
  CALL @nkt_fail
  JMP @nkta_out
nkta_nospc:
  LD r1,r14,1
  MOVI r2,#NKT_ENOSPC
  CALL @nkt_fail
nkta_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvt_view_open r1=ctx r2=token r3=mode r4=out -> 1/0
nkvt_view_open:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,17
  ST r2,r14,18
  ST r3,r14,19
  ST r4,r14,20
  LD r5,r1,#NKT_C_MAGIC
  LA r6,#NKT_MAGIC
  CMP r5,r6
  JMP[NE] @nktv_bad
  LD r5,r1,#NKT_C_VERSION
  MOVI r6,#NKT_VERSION
  CMP r5,r6
  JMP[NE] @nktv_bad
  CMP r4,r0
  JMP[EQ] @nktv_bad
  CMP r3,r0
  JMP[EQ] @nktv_bad
  MOVI r5,2
  CMP r3,r5
  JMP[GT] @nktv_bad
  CALL @nkt_ctx_live
  CMP r1,r0
  JMP[EQ] @nktv_stale
  LD r1,r14,17
  LD r2,r14,18
  CALL @nkt_lookup
  CMP r1,r0
  JMP[EQ] @nktv_none
  ST r1,r14,21
  ST r2,r14,22
  ST r3,r14,23
  ; private page must match the reader generation; a shared ancestor page
  ; may be read by a descendant (SHARED flag is the authority)
  LD r1,r14,17
  LD r2,r1,#NKT_C_GEN
  LD r1,r14,21
  LD r3,r1,#NKT_P_STATE
  MOVI r4,1
  CMP r3,r4
  JMP[NE] @nktv_blk
  LD r3,r1,#NKT_P_GEN
  CMP r3,r2
  JMP[EQ] @nktv_okgen
  LD r3,r1,#NKT_P_FLAGS
  MOVI r4,#NKT_F_SHARED
  BOOL.8 r3,r3,r4
  CMP r3,r0
  JMP[EQ] @nktv_blk
nktv_okgen:
  LD r1,r14,20
  MOVI r2,32
nktv_z:
  CMP r2,r0
  JMP[EQ] @nktv_meta
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nktv_z
nktv_meta:
  LA r1,#NKT_SCR_SHAPE
  MOVI r2,4
  ST r2,r1,0
  LD r4,r14,21
  LD r1,r4,#NKT_P_CAP
  LD r2,r14,22
  SHL r2,r2,4
  MOVI r3,0
  MOVI r4,#NKT_BPT_BYTES
  MOVI r5,0
  MOVI r6,2
  MOVI r7,1
  LA r8,#NKT_SCR_SHAPE
  LD r9,r14,20
  ADDI r9,r9,#NKT_V_NKV
  CALL @nkv_view_create
  CMP r1,r0
  JMP[NE] @nktv_blk
  LD r1,r14,20
  LA r2,#NKT_VMAGIC
  ST r2,r1,#NKT_V_MAGIC
  MOVI r2,#NKT_VERSION
  ST r2,r1,#NKT_V_VERSION
  LD r3,r14,17
  LD r2,r3,#NKT_C_GEN
  ST r2,r1,#NKT_V_CTXGEN
  LD r2,r3,#NKT_C_BRANCH
  ST r2,r1,#NKT_V_BRANCH
  LD r2,r14,18
  ST r2,r1,#NKT_V_TOKEN
  LD r4,r14,21
  ST r4,r1,#NKT_V_PAGE
  LD r2,r4,#NKT_P_GEN
  ST r2,r1,#NKT_V_PAGEGEN
  LD r2,r14,19
  ST r2,r1,#NKT_V_MODE
  LD r2,r3,#NKT_C_VOPEN
  ADD r2,r2,r13
  ST r2,r3,#NKT_C_VOPEN
  LD r2,r3,#NKT_C_VMINT
  ADD r2,r2,r13
  ST r2,r3,#NKT_C_VMINT
  LA r2,#NKT_STATS
  LD r4,r2,#NKT_G_VOPEN
  ADD r4,r4,r13
  ST r4,r2,#NKT_G_VOPEN
  LD r4,r2,#NKT_G_OPS
  ADD r4,r4,r13
  ST r4,r2,#NKT_G_OPS
  MOVI r1,1
  JMP @nktv_out
nktv_bad:
  LD r1,r14,17
  MOVI r2,#NKT_EBAD
  CALL @nkt_fail
  JMP @nktv_out
nktv_stale:
  LD r1,r14,17
  MOVI r2,#NKT_ESTALE
  CALL @nkt_fail
  JMP @nktv_out
nktv_none:
  LD r1,r14,17
  MOVI r2,#NKT_ENOENT
  CALL @nkt_fail
  JMP @nktv_out
nktv_blk:
  LD r1,r14,17
  MOVI r2,#NKT_EBLK
  CALL @nkt_fail
nktv_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvt_view_read r1=ctx r2=view r3=out(4) -> 1/0
nkvt_view_read:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,17
  ST r2,r14,18
  ST r3,r14,19
  LD r4,r1,#NKT_C_MAGIC
  LA r5,#NKT_MAGIC
  CMP r4,r5
  JMP[NE] @nktr_bad
  LD r4,r2,#NKT_V_MAGIC
  LA r5,#NKT_VMAGIC
  CMP r4,r5
  JMP[NE] @nktr_bad
  LD r4,r2,#NKT_V_VERSION
  MOVI r5,#NKT_VERSION
  CMP r4,r5
  JMP[NE] @nktr_bad
  CMP r3,r0
  JMP[EQ] @nktr_bad
  LD r4,r2,#NKT_V_CTXGEN
  LD r5,r1,#NKT_C_GEN
  CMP r4,r5
  JMP[NE] @nktr_gen
  LD r4,r2,#NKT_V_BRANCH
  LD r5,r1,#NKT_C_BRANCH
  CMP r4,r5
  JMP[NE] @nktr_gen
  LD r4,r2,#NKT_V_MODE
  MOVI r5,1
  BOOL.8 r4,r4,r5
  CMP r4,r0
  JMP[EQ] @nktr_bad
  CALL @nkt_ctx_live
  CMP r1,r0
  JMP[EQ] @nktr_stale
  LD r2,r14,18
  LD r1,r2,#NKT_V_PAGE
  ST r1,r14,20
  LD r3,r1,#NKT_P_STATE
  MOVI r4,1
  CMP r3,r4
  JMP[NE] @nktr_stale
  LD r3,r1,#NKT_P_GEN
  LD r4,r2,#NKT_V_PAGEGEN
  CMP r3,r4
  JMP[NE] @nktr_blk
  LD r1,r14,18
  ADDI r1,r1,#NKT_V_NKV
  MOVI r2,0
  MOVI r3,0
  CALL @nkv_view_addr
  CMP r3,r0
  JMP[NE] @nktr_blk
  CMP r2,r0
  JMP[NE] @nktr_blk
  SHR r5,r1,2
  ST r5,r14,21
  LD r6,r5,0
  LD r7,r14,18
  LD r7,r7,#NKT_V_TOKEN
  CMP r6,r7
  JMP[NE] @nktr_blk
  LD r6,r5,2
  LA r7,#NKT_REC_TAG
  CMP r6,r7
  JMP[NE] @nktr_blk
  LD r6,r5,3
  LD r7,r14,20
  LD r7,r7,#NKT_P_GEN
  CMP r6,r7
  JMP[NE] @nktr_blk
  LD r1,r14,19
  LD r2,r14,21
  MOVI r3,4
nktr_cp:
  CMP r3,r0
  JMP[EQ] @nktr_done
  LD r4,r2,0
  ST r4,r1,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  SUB r3,r3,r13
  JMP @nktr_cp
nktr_done:
  LD r1,r14,17
  LD r2,r1,#NKT_C_VIEWREAD
  ADD r2,r2,r13
  ST r2,r1,#NKT_C_VIEWREAD
  LA r2,#NKT_STATS
  LD r3,r2,#NKT_G_VREAD
  ADD r3,r3,r13
  ST r3,r2,#NKT_G_VREAD
  LD r3,r2,#NKT_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKT_G_OPS
  MOVI r1,1
  JMP @nktr_out
nktr_gen:
  LD r1,r14,17
  MOVI r2,#NKT_EGEN
  CALL @nkt_fail
  JMP @nktr_out
nktr_stale:
  LD r1,r14,17
  MOVI r2,#NKT_ESTALE
  CALL @nkt_fail
  JMP @nktr_out
nktr_bad:
  LD r1,r14,17
  MOVI r2,#NKT_EBAD
  CALL @nkt_fail
  JMP @nktr_out
nktr_blk:
  LD r1,r14,17
  MOVI r2,#NKT_EBLK
  CALL @nkt_fail
nktr_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvt_view_write r1=ctx r2=view r3=value -> 1/0
nkvt_view_write:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,17
  ST r2,r14,18
  ST r3,r14,19
  LD r4,r1,#NKT_C_MAGIC
  LA r5,#NKT_MAGIC
  CMP r4,r5
  JMP[NE] @nktw_bad
  LD r4,r2,#NKT_V_MAGIC
  LA r5,#NKT_VMAGIC
  CMP r4,r5
  JMP[NE] @nktw_bad
  LD r4,r2,#NKT_V_VERSION
  MOVI r5,#NKT_VERSION
  CMP r4,r5
  JMP[NE] @nktw_bad
  LD r4,r2,#NKT_V_CTXGEN
  LD r5,r1,#NKT_C_GEN
  CMP r4,r5
  JMP[NE] @nktw_gen
  LD r4,r2,#NKT_V_BRANCH
  LD r5,r1,#NKT_C_BRANCH
  CMP r4,r5
  JMP[NE] @nktw_gen
  LD r4,r2,#NKT_V_MODE
  MOVI r5,2
  BOOL.8 r4,r4,r5
  CMP r4,r0
  JMP[EQ] @nktw_bad
  CALL @nkt_ctx_live
  CMP r1,r0
  JMP[EQ] @nktw_stale
  LD r2,r14,18
  LD r1,r2,#NKT_V_PAGE
  ST r1,r14,20
  LD r3,r1,#NKT_P_STATE
  MOVI r4,1
  CMP r3,r4
  JMP[NE] @nktw_stale
  LD r3,r1,#NKT_P_FLAGS
  MOVI r4,#NKT_F_SHARED
  BOOL.8 r3,r3,r4
  CMP r3,r0
  JMP[NE] @nktw_shared
  LD r3,r1,#NKT_P_REFS
  MOVI r4,1
  CMP r3,r4
  JMP[GT] @nktw_shared
  LD r3,r1,#NKT_P_GEN
  LD r4,r2,#NKT_V_PAGEGEN
  CMP r3,r4
  JMP[NE] @nktw_blk
  LD r5,r14,17
  LD r5,r5,#NKT_C_GEN
  CMP r3,r5
  JMP[NE] @nktw_blk
  LD r1,r14,18
  ADDI r1,r1,#NKT_V_NKV
  MOVI r2,0
  MOVI r3,0
  CALL @nkv_view_addr
  CMP r3,r0
  JMP[NE] @nktw_blk
  CMP r2,r0
  JMP[NE] @nktw_blk
  SHR r5,r1,2
  LD r6,r5,0
  LD r7,r14,18
  LD r7,r7,#NKT_V_TOKEN
  CMP r6,r7
  JMP[NE] @nktw_blk
  LD r6,r5,2
  LA r7,#NKT_REC_TAG
  CMP r6,r7
  JMP[NE] @nktw_blk
  LD r6,r5,3
  LD r7,r14,20
  LD r7,r7,#NKT_P_GEN
  CMP r6,r7
  JMP[NE] @nktw_blk
  LD r6,r14,19
  ST r6,r5,1
  LD r1,r14,17
  LD r2,r1,#NKT_C_VIEWWRITE
  ADD r2,r2,r13
  ST r2,r1,#NKT_C_VIEWWRITE
  LA r2,#NKT_STATS
  LD r3,r2,#NKT_G_VWRITE
  ADD r3,r3,r13
  ST r3,r2,#NKT_G_VWRITE
  LD r3,r2,#NKT_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKT_G_OPS
  MOVI r1,1
  JMP @nktw_out
nktw_gen:
  LD r1,r14,17
  MOVI r2,#NKT_EGEN
  CALL @nkt_fail
  JMP @nktw_out
nktw_stale:
  LD r1,r14,17
  MOVI r2,#NKT_ESTALE
  CALL @nkt_fail
  JMP @nktw_out
nktw_shared:
  LD r1,r14,17
  MOVI r2,#NKT_ESHARED
  CALL @nkt_fail
  JMP @nktw_out
nktw_bad:
  LD r1,r14,17
  MOVI r2,#NKT_EBAD
  CALL @nkt_fail
  JMP @nktw_out
nktw_blk:
  LD r1,r14,17
  MOVI r2,#NKT_EBLK
  CALL @nkt_fail
nktw_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvt_close r1=ctx -> 1/0
nkvt_close:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  LD r2,r1,#NKT_C_MAGIC
  LA r3,#NKT_MAGIC
  CMP r2,r3
  JMP[NE] @nktc_bad
  LD r2,r1,#NKT_C_ADMIT
  CMP r2,r0
  JMP[EQ] @nktc_bad
  LD r3,r1,#NKT_C_TAB
  LD r4,r1,#NKT_C_LIVE
  ST r4,r14,2
  MOVI r5,0
  ST r5,r14,3
nktc_l:
  LD r5,r14,3
  LD r4,r14,2
  CMP r5,r4
  JMP[GE] @nktc_rel_done
  SHL r6,r5,2
  ADD r7,r3,r6
  ST r7,r14,4
  LD r2,r7,#NKT_E_PAGE
  CMP r2,r0
  JMP[EQ] @nktc_next
  LD r1,r14,1
  CALL @nkt_release
  LD r7,r14,4
  ST r0,r7,#NKT_E_PAGE
  ST r0,r7,#NKT_E_MAPGEN
  ST r0,r7,#NKT_E_FLAGS
  ST r0,r7,#NKT_E_ROOT
nktc_next:
  LD r5,r14,3
  ADD r5,r5,r13
  ST r5,r14,3
  LD r1,r14,1
  LD r3,r1,#NKT_C_TAB
  JMP @nktc_l
nktc_rel_done:
  ; release the shared weight root reference
  LD r1,r14,1
  LD r2,r1,#NKT_C_WROOT
  CMP r2,r0
  JMP[EQ] @nktc_nw
  ST r2,r14,5
  ADD r1,r2,r0
  CALL @nsym_root_release
  LA r3,#NKT_NONE
  CMP r1,r3
  JMP[EQ] @nktc_mirbad
  ST r1,r14,6
  LA r4,#NKT_STATS
  LD r5,r4,#NKT_G_RREL
  ADD r5,r5,r13
  ST r5,r4,#NKT_G_RREL
  CMP r1,r0
  JMP[NE] @nktc_nw
  LD r5,r4,#NKT_G_RFREE
  ADD r5,r5,r13
  ST r5,r4,#NKT_G_RFREE
  JMP @nktc_nw
nktc_mirbad:
  LA r4,#NKT_STATS
  LD r5,r4,#NKT_G_MIRERR
  ADD r5,r5,r13
  ST r5,r4,#NKT_G_MIRERR
nktc_nw:
  LD r1,r14,1
  ST r0,r1,#NKT_C_WROOT
  ST r0,r1,#NKT_C_LIVE
  ST r0,r1,#NKT_C_ADMIT
  ST r0,r1,#NKT_C_USED
  ; trace close(branch, generation)
  LD r2,r1,#NKT_C_BRANCH
  LD r3,r1,#NKT_C_GEN
  MOVI r1,#NKT_T_CLOSE
  MOVI r4,0
  CALL @nkt_trace
  LD r1,r14,1
  LD r2,r1,#NKT_C_AGENT
  LD r3,r1,#NKT_C_GEN
  ADD r1,r2,r0
  ADD r2,r3,r0
  CALL @ngen_exit
  CALL @ngen_errno
  CMP r1,r0
  JMP[NE] @nktc_ngerr
  LA r2,#NKT_STATS
  LD r3,r2,#NKT_G_CLOSES
  ADD r3,r3,r13
  ST r3,r2,#NKT_G_CLOSES
  LD r3,r2,#NKT_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKT_G_OPS
  MOVI r1,1
  JMP @nktc_out
nktc_ngerr:
  LD r2,r14,1
  ST r1,r2,#NKT_C_NGERR
  MOVI r2,#NKT_ESTALE
  CALL @nkt_fail
  JMP @nktc_out
nktc_bad:
  LD r1,r14,1
  MOVI r2,#NKT_EBAD
  CALL @nkt_fail
nktc_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvt_page_info r1=page index r2=out(32) -> 0/-1
nkvt_page_info:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r2,r14,1
  CALL @nkt_pageptr
  CMP r1,r0
  JMP[EQ] @nktpi_bad
  LD r2,r14,1
  MOVI r3,0
nktpi_l:
  MOVI r4,#NKT_PSTRIDE
  CMP r3,r4
  JMP[GE] @nktpi_ok
  ADD r4,r1,r3
  LD r4,r4,0
  ADD r5,r2,r3
  ST r4,r5,0
  ADD r3,r3,r13
  JMP @nktpi_l
nktpi_ok:
  MOVI r1,0
  JMP @nktpi_out
nktpi_bad:
  LA r1,0xFFFFFFFF
nktpi_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkvt_stats r1=out(48) -> 0/-1
nkvt_stats:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  LA r1,#NKT_STATS
  LD r2,r14,1
  MOVI r3,0
nktst_l:
  MOVI r4,#NKT_SW
  CMP r3,r4
  JMP[GE] @nktst_ok
  ADD r4,r1,r3
  LD r4,r4,0
  ADD r5,r2,r3
  ST r4,r5,0
  ADD r3,r3,r13
  JMP @nktst_l
nktst_ok:
  MOVI r1,0
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkvt_ctx_info r1=ctx r2=out(32) -> 0/-1
nkvt_ctx_info:
  LD r3,r1,#NKT_C_MAGIC
  LA r4,#NKT_MAGIC
  CMP r3,r4
  JMP[NE] @nktci_bad
  MOVI r3,0
nktci_l:
  MOVI r4,32
  CMP r3,r4
  JMP[GE] @nktci_ok
  ADD r4,r1,r3
  LD r4,r4,0
  ADD r5,r2,r3
  ST r4,r5,0
  ADD r3,r3,r13
  JMP @nktci_l
nktci_ok:
  MOVI r1,0
  RET
nktci_bad:
  LA r1,0xFFFFFFFF
  RET

; nkvt_trace r1=index r2=out(8) -> 0/-1
nkvt_trace:
  MOVI r3,#NKT_TRACE_N
  CMP r1,r3
  JMP[GE] @nkttr_bad
  SHL r1,r1,3
  LA r3,#NKT_TRACE
  ADD r1,r3,r1
  MOVI r4,0
nkttr_l:
  MOVI r5,#NKT_TRACE_W
  CMP r4,r5
  JMP[GE] @nkttr_ok
  ADD r5,r1,r4
  LD r5,r5,0
  ADD r6,r2,r4
  ST r5,r6,0
  ADD r4,r4,r13
  JMP @nkttr_l
nkttr_ok:
  MOVI r1,0
  RET
nkttr_bad:
  LA r1,0xFFFFFFFF
  RET

; nkvt_trace_head -> head / 0
nkvt_trace_head:
  LA r1,#NKT_STATS
  LD r1,r1,#NKT_G_THEAD
  RET

; nkvt_errno -> last error.
nkvt_errno:
  LA r1,#NKT_STATS
  LD r1,r1,#NKT_G_LERR
  RET
