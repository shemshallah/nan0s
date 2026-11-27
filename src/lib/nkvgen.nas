; nkvgen.nas - generation-tagged KV pages/views + COW prefix fork (F13g).
;
; Pure NaN.  This is the F13g layer above nkv views and ngen live
; generations.  A KV branch is a context bound to one ngen generation.  Its
; token space is a table of KV pages; every page header, every token record,
; every context and every view carry a generation tag.  A page is either
; private to one branch or a shared, immutable prefix page with a reference
; count.  A fork publishes the next ngen generation and shares every prefix
; page read-only.  The first append into a shared page copies only that
; partial page (the divergence boundary) and leaves every full prefix page
; untouched; later appends go straight into the private copy.
;
; Why the parent can still read after the fork
; -------------------------------------------
; nkvgen_open enters the ngen generation with ngen_enter, exactly like an
; in-flight request.  ngen_publish then moves the parent to DRAINING and
; starts the child generation.  The parent's admitted read handle remains a
; legal old-generation in-flight snapshot; a *new* open at the parent
; generation fails closed with ngen's EDRAIN.  Child views carry the child
; generation, parent views carry the parent generation.  Presenting a view to
; a context of another generation is rejected by the view layer with
; NKG_EGEN; presenting an old view after its context has left the live state
; is rejected with NKG_ESTALE.
;
; Header / view generation rules
; ------------------------------
; * page.gen is the generation that allocated the page.
; * token record gen equals page.gen.
; * a private page is readable only when page.gen == ctx.gen.
; * a page marked SHARED is an immutable ancestor prefix page: a descendant
;   context (ctx.gen >= page.gen) may read it, but may not write it.  The
;   first append into a shared page copy-on-writes the page and gives the
;   copy the child generation.
; * a view stores the reader generation, the branch, the token and the page
;   birth generation.  nkvgen_view_read requires view.reader_gen == ctx.gen
;   and page.gen == view.page_gen at resolution time.
;
; Layout
; ------
; Context (32 caller words):
;   +0 magic "NKGC" 0x43474B4E   +1 version 1
;   +2 ngen agent                +3 ngen generation
;   +4 branch id                 +5 parent branch
;   +6 page table (4 words/block)+7 table capacity in blocks
;   +8 tokens per block          +9 used tokens
;   +10 live blocks              +11 COW page copies
;   +12 bytes/token (16)         +13 page slots (16)
;   +14 view opens               +15 admitted
;   +16 last context error       +17 last ngen error
;   +18 fork joins               +19 child forks
;   +20 ngen epoch               +21 flags
;   +22 views minted             +23..31 reserved
;
; Page table entry (4 words):
;   +0 page pointer (word address of the page header) / 0
;   +1 map generation            +2 flags (1 shared mapping)
;   +3 reserved
;
; Page header (32 words in the global registry):
;   +0 magic "NKGP" 0x50474B4E   +1 version 1
;   +2 generation                +3 refcount
;   +4 state (1 live)            +5 flags (1 shared immutable prefix)
;   +6 storage capability        +7 word base +8 base_hi
;   +9 used tokens               +10 slots (16)
;   +11 allocations              +12 COW copies made from this page
;   +13 tokens copied            +14 joins  +15 leaves +16 frees
;   +17 owner agent              +18 owner generation
;   +19 page index               +20..31 reserved
;
; Page payload: 16 tokens x 4 words = 64 words (256 bytes), page buffer base
; is supplied to nkvgen_init.  Token record:
;   +0 logical token +1 value +2 tag 0xA5A5A5A5 +3 generation.
; A per-token nkv rank-1 f32 view (4 elements) is minted over the page's
; class-20 storage capability; nkvgen wraps it with the generation metadata.
;
; View (32 caller words):
;   +0 magic "NKGV" 0x56474B4E   +1 version 1
;   +2 reader generation         +3 branch
;   +4 logical token             +5 page pointer
;   +6 page birth generation     +7 mode (1 read, 2 write)
;   +8..31 embedded nkv view (24 words)
;
; Global page registry: 16 pages x 32 words at 0x358000.
; Global stats (32 words at 0x358200):
;   +0 magic "NKGG" +1 version +2 live pages +3 allocations +4 frees
;   +5 joins +6 leaves +7 COW copies +8 tokens copied +9 forks
;   +10 view opens +11 view reads +12 view writes +13 errors
;   +14 last error +15 ops +16 cross-generation rejects
;   +17 stale rejects +18 shared-write rejects +19 page limit
;   +20 page buffer word base +21 max pages +22..31 reserved
;
; Return codes (nkvgen_errno):
;   0 OK, 1 EBAD, 2 ENOENT, 3 ENOSPC, 4 EGEN (cross-generation view),
;   5 ESTALE (old/draining generation), 6 ESHARED (write to immutable
;   shared page), 7 EBLK (block/page generation mismatch), 8 EDUP.
;
; API (r0=0, r13=1, r14 grows up, r15 link):
;   nkvgen_init       r1=page buffer word base r2=page limit (1..16) -> 0/-1
;   nkvgen_open       r1=ctx r2=agent r3=generation r4=cpu r5=branch
;                     r6=page table r7=table cap r8=tokens/block -> 1/0
;   nkvgen_fork       r1=parent ctx r2=child ctx r3=cpu r4=child table
;                     r5=table cap r6=child branch -> child generation / 0
;   nkvgen_append     r1=ctx r2=value -> token index / -1
;   nkvgen_view_open  r1=ctx r2=token r3=mode(1 read,2 write) r4=out view
;                     -> 1/0
;   nkvgen_view_read  r1=ctx r2=view r3=out(4) -> 1/0
;   nkvgen_view_write r1=ctx r2=view r3=value -> 1/0
;   nkvgen_close      r1=ctx -> 1/0 (releases pages and ngen admission)
;   nkvgen_page_info  r1=page index r2=out(32) -> 0/-1
;   nkvgen_stats      r1=out(32) -> 0/-1
;   nkvgen_ctx_info   r1=ctx r2=out(32) -> 0/-1
;   nkvgen_errno      -> last error
;
; Requires nobj_init before the first page allocation (nkv storage
; capabilities) and ngen_init before nkvgen_open.  The page buffer is caller
; supplied so the library has no hidden data address.  Low scratch
; 0x30000..0x3005F (status/slot/shape); nkv uses 0x5000, ngen uses 0x352000.

.include "ngen.nas"
.include "nkv.nas"

.equ NKG_TAB        0x358000
.equ NKG_MAXPAGE    16
.equ NKG_PSTRIDE    32
.equ NKG_TABWORDS   512
.equ NKG_STATS      0x358200
.equ NKG_SW         32
.equ NKG_SCR        0x30000
.equ NKG_SCR_STATUS 0x30000
.equ NKG_SCR_SLOT   0x30020
.equ NKG_SCR_SHAPE  0x30028

.equ NKG_MAGIC      0x43474B4E       ; "NKGC"
.equ NKG_PMAGIC     0x50474B4E       ; "NKGP"
.equ NKG_VMAGIC     0x56474B4E       ; "NKGV"
.equ NKG_GMAGIC     0x47474B4E       ; "NKGG"
.equ NKG_VERSION    1
.equ NKG_REC_TAG    0xA5A5A5A5
.equ NKG_SLOTS      16
.equ NKG_PAGE_W     64
.equ NKG_PAGE_B     256
.equ NKG_BPT_BYTES  16

; context fields
.equ NKG_C_MAGIC    0
.equ NKG_C_VERSION  1
.equ NKG_C_AGENT    2
.equ NKG_C_GEN      3
.equ NKG_C_BRANCH   4
.equ NKG_C_PARENT   5
.equ NKG_C_TAB      6
.equ NKG_C_TABCAP   7
.equ NKG_C_BLOCKTOK 8
.equ NKG_C_USED     9
.equ NKG_C_LIVE     10
.equ NKG_C_COPIES   11
.equ NKG_C_BPT      12
.equ NKG_C_SLOTS    13
.equ NKG_C_VOPEN    14
.equ NKG_C_ADMIT    15
.equ NKG_C_ERR      16
.equ NKG_C_NGERR    17
.equ NKG_C_JOINS    18
.equ NKG_C_CHILDREN 19
.equ NKG_C_EPOCH    20
.equ NKG_C_FLAGS    21
.equ NKG_C_VMINT    22
.equ NKG_C_VIEWREAD 23
.equ NKG_C_VIEWWRITE 24

; page fields
.equ NKG_P_MAGIC    0
.equ NKG_P_VERSION  1
.equ NKG_P_GEN      2
.equ NKG_P_REFS     3
.equ NKG_P_STATE    4
.equ NKG_P_FLAGS    5
.equ NKG_P_CAP      6
.equ NKG_P_BASE     7
.equ NKG_P_BASEHI   8
.equ NKG_P_USED     9
.equ NKG_P_SLOTS    10
.equ NKG_P_ALLOCS   11
.equ NKG_P_COPIES   12
.equ NKG_P_TCOPY    13
.equ NKG_P_JOINS    14
.equ NKG_P_LEAVES   15
.equ NKG_P_FREES    16
.equ NKG_P_OWNER    17
.equ NKG_P_OWNERGEN 18
.equ NKG_P_IDX      19

; page flags
.equ NKG_F_SHARED   1

; stats fields
.equ NKG_G_MAGIC    0
.equ NKG_G_VERSION  1
.equ NKG_G_LIVE     2
.equ NKG_G_ALLOCS   3
.equ NKG_G_FREES    4
.equ NKG_G_JOINS    5
.equ NKG_G_LEAVES   6
.equ NKG_G_COPIES   7
.equ NKG_G_TCOPY    8
.equ NKG_G_FORKS    9
.equ NKG_G_VOPEN    10
.equ NKG_G_VREAD    11
.equ NKG_G_VWRITE   12
.equ NKG_G_ERRORS   13
.equ NKG_G_LERR     14
.equ NKG_G_OPS      15
.equ NKG_G_XGEN     16
.equ NKG_G_XSTALE   17
.equ NKG_G_XSHARED  18
.equ NKG_G_LIMIT    19
.equ NKG_G_BUFFER   20
.equ NKG_G_MAXPAGE  21

; view fields
.equ NKG_V_MAGIC    0
.equ NKG_V_VERSION  1
.equ NKG_V_CTXGEN   2
.equ NKG_V_BRANCH   3
.equ NKG_V_TOKEN    4
.equ NKG_V_PAGE     5
.equ NKG_V_PAGEGEN  6
.equ NKG_V_MODE     7
.equ NKG_V_NKV      8

; entry fields
.equ NKG_E_PAGE     0
.equ NKG_E_MAPGEN   1
.equ NKG_E_FLAGS    2

; errors
.equ NKG_OK         0
.equ NKG_EBAD       1
.equ NKG_ENOENT     2
.equ NKG_ENOSPC     3
.equ NKG_EGEN       4
.equ NKG_ESTALE     5
.equ NKG_ESHARED    6
.equ NKG_EBLK       7
.equ NKG_EDUP       8

; ---------------------------------------------------------------------------
; nkg_fail r1=ctx(or 0) r2=code -> 0.  Charges the global/context counters.
nkg_fail:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  ST r2,r14,2
  LA r3,#NKG_STATS
  LD r4,r3,#NKG_G_ERRORS
  ADD r4,r4,r13
  ST r4,r3,#NKG_G_ERRORS
  ST r2,r3,#NKG_G_LERR
  LD r4,r3,#NKG_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKG_G_OPS
  MOVI r4,#NKG_EGEN
  CMP r2,r4
  JMP[NE] @nkgf_stale
  LD r4,r3,#NKG_G_XGEN
  ADD r4,r4,r13
  ST r4,r3,#NKG_G_XGEN
  JMP @nkgf_ctx
nkgf_stale:
  MOVI r4,#NKG_ESTALE
  CMP r2,r4
  JMP[NE] @nkgf_shared
  LD r4,r3,#NKG_G_XSTALE
  ADD r4,r4,r13
  ST r4,r3,#NKG_G_XSTALE
  JMP @nkgf_ctx
nkgf_shared:
  MOVI r4,#NKG_ESHARED
  CMP r2,r4
  JMP[NE] @nkgf_ctx
  LD r4,r3,#NKG_G_XSHARED
  ADD r4,r4,r13
  ST r4,r3,#NKG_G_XSHARED
nkgf_ctx:
  LD r1,r14,1
  CMP r1,r0
  JMP[EQ] @nkgf_done
  LD r2,r14,2
  ST r2,r1,#NKG_C_ERR
nkgf_done:
  MOVI r1,0
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkg_pageptr r1=index -> page header or 0.
nkg_pageptr:
  MOVI r2,#NKG_MAXPAGE
  CMP r1,r2
  JMP[GE] @nkgp_bad
  SHL r1,r1,5
  LA r2,#NKG_TAB
  ADD r1,r2,r1
  RET
nkgp_bad:
  MOVI r1,0
  RET

; nkg_buf r1=page index -> payload word base or 0.
nkg_buf:
  LA r2,#NKG_STATS
  LD r2,r2,#NKG_G_BUFFER
  CMP r2,r0
  JMP[EQ] @nkgb_bad
  SHL r1,r1,6
  ADD r1,r2,r1
  RET
nkgb_bad:
  MOVI r1,0
  RET

; nkg_ctx_live r1=ctx -> 1 if admitted and its ngen generation is CURRENT or
; an admitted old generation still DRAINING; 0 otherwise.
nkg_ctx_live:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  LD r2,r1,#NKG_C_MAGIC
  LA r3,#NKG_MAGIC
  CMP r2,r3
  JMP[NE] @nkgcl_no
  LD r2,r1,#NKG_C_VERSION
  MOVI r3,#NKG_VERSION
  CMP r2,r3
  JMP[NE] @nkgcl_no
  LD r2,r1,#NKG_C_ADMIT
  CMP r2,r0
  JMP[EQ] @nkgcl_no
  LD r2,r1,#NKG_C_AGENT
  LA r3,#NKG_SCR_STATUS
  MOVI r4,0
  ADD r1,r2,r0
  ADD r2,r3,r0
  CALL @ngen_status
  CMP r1,r0
  JMP[NE] @nkgcl_no
  LA r3,#NKG_SCR_STATUS
  LD r4,r3,3
  LD r5,r14,1
  LD r5,r5,#NKG_C_GEN
  CMP r4,r5
  JMP[EQ] @nkgcl_yes
  ; older generation: only a DRAINING admitted in-flight snapshot is live
  LD r1,r14,1
  LD r1,r1,#NKG_C_AGENT
  ADD r2,r5,r0
  LA r3,#NKG_SCR_SLOT
  CALL @ngen_slot
  CMP r1,r0
  JMP[NE] @nkgcl_no
  LA r3,#NKG_SCR_SLOT
  LD r4,r3,1
  MOVI r5,#NG_S_DRAINING
  CMP r4,r5
  JMP[NE] @nkgcl_no
nkgcl_yes:
  MOVI r1,1
  JMP @nkgcl_out
nkgcl_no:
  MOVI r1,0
nkgcl_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkg_lookup r1=ctx r2=token -> r1=page r2=slot r3=entry or r1=0.
nkg_lookup:
  LD r3,r1,#NKG_C_USED
  CMP r2,r3
  JMP[GE] @nkgl_bad
  LD r4,r1,#NKG_C_BLOCKTOK
  CMP r4,r0
  JMP[EQ] @nkgl_bad
  DIVU r5,r2,r4
  MODU r6,r2,r4
  LD r7,r1,#NKG_C_TABCAP
  CMP r5,r7
  JMP[GE] @nkgl_bad
  LD r8,r1,#NKG_C_TAB
  CMP r8,r0
  JMP[EQ] @nkgl_bad
  SHL r9,r5,2
  ADD r8,r8,r9
  LD r9,r8,#NKG_E_PAGE
  CMP r9,r0
  JMP[EQ] @nkgl_bad
  ADD r1,r9,r0
  ADD r2,r6,r0
  ADD r3,r8,r0
  RET
nkgl_bad:
  MOVI r1,0
  MOVI r2,0
  MOVI r3,0
  RET

; ---------------------------------------------------------------------------
; nkvgen_init r1=page buffer word base r2=page limit (1..16) -> 0/-1
nkvgen_init:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  CMP r1,r0
  JMP[EQ] @nkgi_bad
  CMP r2,r0
  JMP[EQ] @nkgi_bad
  MOVI r3,#NKG_MAXPAGE
  CMP r2,r3
  JMP[GT] @nkgi_bad
  ; zero the 16-page registry
  LA r1,#NKG_TAB
  MOVI r2,#NKG_TABWORDS
nkgi_t:
  CMP r2,r0
  JMP[EQ] @nkgi_s
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkgi_t
nkgi_s:
  ; zero stats
  LA r1,#NKG_STATS
  MOVI r2,#NKG_SW
nkgi_sl:
  CMP r2,r0
  JMP[EQ] @nkgi_buf
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkgi_sl
nkgi_buf:
  ; zero the payload buffers
  LD r1,r14,1
  LD r2,r14,2
  SHL r2,r2,6
nkgi_b:
  CMP r2,r0
  JMP[EQ] @nkgi_meta
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkgi_b
nkgi_meta:
  LA r1,#NKG_STATS
  LA r2,#NKG_GMAGIC
  ST r2,r1,#NKG_G_MAGIC
  MOVI r2,#NKG_VERSION
  ST r2,r1,#NKG_G_VERSION
  LD r2,r14,2
  ST r2,r1,#NKG_G_LIMIT
  MOVI r3,#NKG_MAXPAGE
  ST r3,r1,#NKG_G_MAXPAGE
  LD r2,r14,1
  ST r2,r1,#NKG_G_BUFFER
  MOVI r1,0
  JMP @nkgi_out
nkgi_bad:
  LA r1,0xFFFFFFFF
nkgi_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvgen_page_new r1=ctx r2=generation -> page header or 0.
nkvgen_page_new:
  ST r15,r14,0
  ADDI r14,r14,48
  ; locals live at offset 17+ so the 1-word nkv/nanobj nested frames
  ; (which write just above our frame base) cannot clobber them
  ST r1,r14,17
  ST r2,r14,18
  ; scan within the configured page limit
  MOVI r3,0
  LA r4,#NKG_STATS
  LD r5,r4,#NKG_G_LIMIT
  LA r7,#NKG_TAB
nkpn_l:
  CMP r3,r5
  JMP[GE] @nkpn_fail
  SHL r6,r3,5
  ADD r6,r7,r6
  LD r8,r6,#NKG_P_STATE
  CMP r8,r0
  JMP[EQ] @nkpn_found
  ADD r3,r3,r13
  JMP @nkpn_l
nkpn_found:
  ST r6,r14,19
  ST r3,r14,20
  ; zero the 32-word header
  MOVI r8,0
nkpn_z:
  MOVI r9,#NKG_PSTRIDE
  CMP r8,r9
  JMP[GE] @nkpn_zd
  ADD r9,r6,r8
  ST r0,r9,0
  ADD r8,r8,r13
  JMP @nkpn_z
nkpn_zd:
  LD r1,r14,20
  CALL @nkg_buf
  CMP r1,r0
  JMP[EQ] @nkpn_fail
  ST r1,r14,21
  ; class-20 storage capability over the page buffer (byte address)
  ADD r1,r1,r0
  SHL r1,r1,2
  MOVI r2,0
  MOVI r3,#NKG_PAGE_B
  MOVI r4,0
  MOVI r5,3
  MOVI r6,0
  CALL @nkv_storage_create
  CMP r1,r0
  JMP[EQ] @nkpn_fail
  ST r1,r14,22
  ; fill the header
  LD r6,r14,19
  LA r8,#NKG_PMAGIC
  ST r8,r6,#NKG_P_MAGIC
  MOVI r8,#NKG_VERSION
  ST r8,r6,#NKG_P_VERSION
  LD r7,r14,18
  ST r7,r6,#NKG_P_GEN
  MOVI r8,1
  ST r8,r6,#NKG_P_REFS
  ST r8,r6,#NKG_P_STATE
  ST r0,r6,#NKG_P_FLAGS
  LD r8,r14,22
  ST r8,r6,#NKG_P_CAP
  LD r8,r14,21
  ST r8,r6,#NKG_P_BASE
  ST r0,r6,#NKG_P_BASEHI
  ST r0,r6,#NKG_P_USED
  MOVI r8,#NKG_SLOTS
  ST r8,r6,#NKG_P_SLOTS
  MOVI r8,1
  ST r8,r6,#NKG_P_ALLOCS
  LD r8,r14,20
  ST r8,r6,#NKG_P_IDX
  LD r8,r14,17
  LD r9,r8,#NKG_C_AGENT
  ST r9,r6,#NKG_P_OWNER
  LD r9,r8,#NKG_C_GEN
  ST r9,r6,#NKG_P_OWNERGEN
  ; stats
  LA r8,#NKG_STATS
  LD r9,r8,#NKG_G_LIVE
  ADD r9,r9,r13
  ST r9,r8,#NKG_G_LIVE
  LD r9,r8,#NKG_G_ALLOCS
  ADD r9,r9,r13
  ST r9,r8,#NKG_G_ALLOCS
  LD r9,r8,#NKG_G_OPS
  ADD r9,r9,r13
  ST r9,r8,#NKG_G_OPS
  ADD r1,r6,r0
  JMP @nkpn_out
nkpn_fail:
  MOVI r1,0
nkpn_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkg_release r1=ctx r2=page -> 1/0.  One reference leaves; at zero the
; storage capability is released and the page is marked free.
nkg_release:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r2,#NKG_P_STATE
  MOVI r4,1
  CMP r3,r4
  JMP[NE] @nkrel_fail
  LD r3,r2,#NKG_P_REFS
  CMP r3,r0
  JMP[EQ] @nkrel_fail
  SUB r3,r3,r13
  ST r3,r2,#NKG_P_REFS
  LD r4,r2,#NKG_P_LEAVES
  ADD r4,r4,r13
  ST r4,r2,#NKG_P_LEAVES
  LA r5,#NKG_STATS
  LD r4,r5,#NKG_G_LEAVES
  ADD r4,r4,r13
  ST r4,r5,#NKG_G_LEAVES
  CMP r3,r0
  JMP[NE] @nkrel_ok
  LD r1,r2,#NKG_P_CAP
  CMP r1,r0
  JMP[EQ] @nkrel_nocap
  CALL @nobj_release
nkrel_nocap:
  LD r2,r14,2
  ST r0,r2,#NKG_P_STATE
  ST r0,r2,#NKG_P_CAP
  LD r4,r2,#NKG_P_FREES
  ADD r4,r4,r13
  ST r4,r2,#NKG_P_FREES
  LA r5,#NKG_STATS
  LD r4,r5,#NKG_G_FREES
  ADD r4,r4,r13
  ST r4,r5,#NKG_G_FREES
  LD r4,r5,#NKG_G_LIVE
  SUB r4,r4,r13
  ST r4,r5,#NKG_G_LIVE
nkrel_ok:
  MOVI r1,1
  JMP @nkrel_out
nkrel_fail:
  MOVI r1,0
nkrel_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkg_cow r1=ctx r2=old shared page -> new private page or 0.
nkg_cow:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  LD r2,r1,#NKG_C_GEN
  CALL @nkvgen_page_new
  CMP r1,r0
  JMP[EQ] @nkcow_fail
  ST r1,r14,3
  ; copy the used records of exactly this page (the divergence boundary)
  LD r4,r14,2
  LD r5,r4,#NKG_P_BASE
  LD r6,r1,#NKG_P_BASE
  LD r7,r4,#NKG_P_USED
  ST r7,r14,4
  SHL r8,r7,2
  MOVI r9,0
nkcow_cp:
  CMP r9,r8
  JMP[GE] @nkcow_cpd
  ADD r1,r5,r9
  LD r1,r1,0
  ADD r2,r6,r9
  ST r1,r2,0
  ADD r9,r9,r13
  JMP @nkcow_cp
nkcow_cpd:
  ; copied records belong to the child generation
  LD r3,r14,3
  LD r7,r3,#NKG_P_GEN
  LD r8,r14,4
  MOVI r9,0
nkcow_g:
  CMP r9,r8
  JMP[GE] @nkcow_gd
  SHL r1,r9,2
  ADD r1,r6,r1
  ST r7,r1,3
  ADD r9,r9,r13
  JMP @nkcow_g
nkcow_gd:
  LD r3,r14,3
  LD r7,r14,4
  ST r7,r3,#NKG_P_USED
  ; the shared ancestor page records the copy it caused; the private copy
  ; starts with a zero copy count of its own
  LD r4,r14,2
  LD r7,r4,#NKG_P_COPIES
  ADD r7,r7,r13
  ST r7,r4,#NKG_P_COPIES
  LD r7,r14,4
  LD r8,r4,#NKG_P_TCOPY
  ADD r8,r8,r7
  ST r8,r4,#NKG_P_TCOPY
  ; global/context copy accounting
  LA r8,#NKG_STATS
  LD r9,r8,#NKG_G_COPIES
  ADD r9,r9,r13
  ST r9,r8,#NKG_G_COPIES
  LD r9,r8,#NKG_G_TCOPY
  ADD r9,r9,r7
  ST r9,r8,#NKG_G_TCOPY
  LD r9,r8,#NKG_G_OPS
  ADD r9,r9,r13
  ST r9,r8,#NKG_G_OPS
  LD r1,r14,1
  LD r9,r1,#NKG_C_COPIES
  ADD r9,r9,r13
  ST r9,r1,#NKG_C_COPIES
  ; leave the shared ancestor page
  LD r1,r14,1
  LD r2,r14,2
  CALL @nkg_release
  LD r1,r14,3
  JMP @nkcow_out
nkcow_fail:
  MOVI r1,0
nkcow_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvgen_open r1=ctx r2=agent r3=generation r4=cpu r5=branch
;              r6=page table r7=table cap r8=tokens/block -> 1/0
nkvgen_open:
  ST r15,r14,0
  ADDI r14,r14,72
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  ST r7,r14,7
  ST r8,r14,8
  CMP r1,r0
  JMP[EQ] @nko_bad
  CMP r2,r0
  JMP[EQ] @nko_bad
  CMP r3,r0
  JMP[EQ] @nko_bad
  CMP r6,r0
  JMP[EQ] @nko_bad
  CMP r7,r0
  JMP[EQ] @nko_bad
  CMP r8,r0
  JMP[EQ] @nko_bad
  MOVI r9,#NKG_SLOTS
  CMP r8,r9
  JMP[GT] @nko_bad
  MOVI r9,#NG_MAX_CPU
  CMP r4,r9
  JMP[GE] @nko_bad
  ; clear the context
  LD r1,r14,1
  MOVI r2,32
nko_z:
  CMP r2,r0
  JMP[EQ] @nko_fill
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nko_z
nko_fill:
  LD r1,r14,1
  LA r2,#NKG_MAGIC
  ST r2,r1,#NKG_C_MAGIC
  MOVI r2,#NKG_VERSION
  ST r2,r1,#NKG_C_VERSION
  LD r2,r14,2
  ST r2,r1,#NKG_C_AGENT
  LD r2,r14,3
  ST r2,r1,#NKG_C_GEN
  LD r2,r14,5
  ST r2,r1,#NKG_C_BRANCH
  LD r2,r14,6
  ST r2,r1,#NKG_C_TAB
  LD r2,r14,7
  ST r2,r1,#NKG_C_TABCAP
  LD r2,r14,8
  ST r2,r1,#NKG_C_BLOCKTOK
  MOVI r2,#NKG_BPT_BYTES
  ST r2,r1,#NKG_C_BPT
  MOVI r2,#NKG_SLOTS
  ST r2,r1,#NKG_C_SLOTS
  ; ngen admission: this is the in-flight snapshot the fork drains
  LD r1,r14,2
  LD r2,r14,3
  LD r3,r14,4
  CALL @ngen_enter
  LD r4,r14,3
  CMP r1,r4
  JMP[EQ] @nko_admit
  LD r1,r14,1
  CALL @ngen_errno
  LD r2,r14,1
  ST r1,r2,#NKG_C_NGERR
  MOVI r2,#NKG_ESTALE
  CALL @nkg_fail
  JMP @nko_out
nko_admit:
  ; clear the caller page table (4 words per block)
  LD r1,r14,6
  LD r2,r14,7
  SHL r2,r2,2
nko_t:
  CMP r2,r0
  JMP[EQ] @nko_done
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nko_t
nko_done:
  LD r1,r14,1
  MOVI r2,1
  ST r2,r1,#NKG_C_ADMIT
  LD r2,r14,2
  ADD r1,r2,r0
  CALL @ngen_epoch
  LD r2,r14,1
  ST r1,r2,#NKG_C_EPOCH
  LA r3,#NKG_STATS
  LD r4,r3,#NKG_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKG_G_OPS
  MOVI r1,1
  JMP @nko_out
nko_bad:
  LD r1,r14,1
  MOVI r2,#NKG_EBAD
  CALL @nkg_fail
nko_out:
  ADDI r14,r14,-72
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvgen_fork r1=parent r2=child r3=cpu r4=child table r5=tabcap r6=branch
;               -> child generation / 0
nkvgen_fork:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  CMP r1,r0
  JMP[EQ] @nkf_bad
  CMP r2,r0
  JMP[EQ] @nkf_bad
  CMP r1,r2
  JMP[EQ] @nkf_bad
  CMP r4,r0
  JMP[EQ] @nkf_bad
  CMP r5,r0
  JMP[EQ] @nkf_bad
  ; parent must be admitted and its generation must be current
  LD r1,r14,1
  CALL @nkg_ctx_live
  CMP r1,r0
  JMP[EQ] @nkf_stale
  LD r1,r14,1
  LD r1,r1,#NKG_C_AGENT
  LA r2,#NKG_SCR_STATUS
  CALL @ngen_status
  CMP r1,r0
  JMP[NE] @nkf_stale
  LA r3,#NKG_SCR_STATUS
  LD r4,r3,3
  LD r5,r14,1
  LD r5,r5,#NKG_C_GEN
  CMP r4,r5
  JMP[NE] @nkf_stale
  ; child table must hold every parent block
  LD r5,r14,1
  LD r5,r5,#NKG_C_LIVE
  LD r6,r14,5
  CMP r5,r6
  JMP[GT] @nkf_nospc
  ; publish the next ngen generation; the parent enters DRAINING
  LD r5,r14,1
  LD r5,r5,#NKG_C_GEN
  ADD r2,r5,r13
  ST r2,r14,7
  LA r3,#NKG_SCR_STATUS
  LD r3,r3,24
  LA r4,#NKG_SCR_STATUS
  LD r4,r4,26
  LD r1,r14,1
  LD r1,r1,#NKG_C_AGENT
  CALL @ngen_publish
  CMP r1,r0
  JMP[EQ] @nkf_stale
  ST r1,r14,8
  ; child admission at the new generation
  LD r1,r14,1
  LD r1,r1,#NKG_C_AGENT
  LD r2,r14,7
  LD r3,r14,3
  CALL @ngen_enter
  LD r4,r14,7
  CMP r1,r4
  JMP[NE] @nkf_stale
  ; initialize the child context
  LD r1,r14,2
  MOVI r2,32
nkf_z:
  CMP r2,r0
  JMP[EQ] @nkf_fill
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkf_z
nkf_fill:
  LD r1,r14,2
  LA r2,#NKG_MAGIC
  ST r2,r1,#NKG_C_MAGIC
  MOVI r2,#NKG_VERSION
  ST r2,r1,#NKG_C_VERSION
  LD r3,r14,1
  LD r2,r3,#NKG_C_AGENT
  ST r2,r1,#NKG_C_AGENT
  LD r2,r14,7
  ST r2,r1,#NKG_C_GEN
  LD r2,r14,6
  ST r2,r1,#NKG_C_BRANCH
  LD r2,r3,#NKG_C_BRANCH
  ST r2,r1,#NKG_C_PARENT
  LD r2,r14,4
  ST r2,r1,#NKG_C_TAB
  LD r2,r14,5
  ST r2,r1,#NKG_C_TABCAP
  LD r2,r3,#NKG_C_BLOCKTOK
  ST r2,r1,#NKG_C_BLOCKTOK
  LD r2,r3,#NKG_C_BPT
  ST r2,r1,#NKG_C_BPT
  LD r2,r3,#NKG_C_SLOTS
  ST r2,r1,#NKG_C_SLOTS
  LD r2,r3,#NKG_C_USED
  ST r2,r1,#NKG_C_USED
  MOVI r2,1
  ST r2,r1,#NKG_C_ADMIT
  LD r2,r14,8
  ST r2,r1,#NKG_C_EPOCH
  ; share every live prefix page read-only
  LD r3,r14,1
  LD r3,r3,#NKG_C_TAB
  LD r4,r14,4
  LD r5,r14,1
  LD r5,r5,#NKG_C_LIVE
  MOVI r6,0
nkf_share:
  CMP r6,r5
  JMP[GE] @nkf_shared_done
  SHL r7,r6,2
  ADD r8,r3,r7
  ADD r9,r4,r7
  LD r1,r8,#NKG_E_PAGE
  CMP r1,r0
  JMP[EQ] @nkf_share_next
  ST r1,r9,#NKG_E_PAGE
  LD r2,r14,7
  ST r2,r9,#NKG_E_MAPGEN
  MOVI r2,1
  ST r2,r9,#NKG_E_FLAGS
  LD r2,r1,#NKG_P_REFS
  ADD r2,r2,r13
  ST r2,r1,#NKG_P_REFS
  LD r2,r1,#NKG_P_JOINS
  ADD r2,r2,r13
  ST r2,r1,#NKG_P_JOINS
  LD r2,r1,#NKG_P_FLAGS
  MOVI r7,1
  BOOL.14 r2,r2,r7
  ST r2,r1,#NKG_P_FLAGS
  LA r2,#NKG_STATS
  LD r7,r2,#NKG_G_JOINS
  ADD r7,r7,r13
  ST r7,r2,#NKG_G_JOINS
  LD r7,r2,#NKG_G_OPS
  ADD r7,r7,r13
  ST r7,r2,#NKG_G_OPS
nkf_share_next:
  ADD r6,r6,r13
  JMP @nkf_share
nkf_shared_done:
  LD r1,r14,2
  LD r2,r14,1
  LD r2,r2,#NKG_C_LIVE
  ST r2,r1,#NKG_C_LIVE
  LD r2,r14,1
  LD r3,r2,#NKG_C_JOINS
  LD r4,r2,#NKG_C_LIVE
  ADD r3,r3,r4
  ST r3,r2,#NKG_C_JOINS
  LD r3,r2,#NKG_C_CHILDREN
  ADD r3,r3,r13
  ST r3,r2,#NKG_C_CHILDREN
  LA r3,#NKG_STATS
  LD r4,r3,#NKG_G_FORKS
  ADD r4,r4,r13
  ST r4,r3,#NKG_G_FORKS
  LD r4,r3,#NKG_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKG_G_OPS
  LD r1,r14,7
  JMP @nkf_out
nkf_bad:
  LD r1,r14,1
  MOVI r2,#NKG_EBAD
  CALL @nkg_fail
  JMP @nkf_out
nkf_stale:
  LD r1,r14,1
  MOVI r2,#NKG_ESTALE
  CALL @nkg_fail
  JMP @nkf_out
nkf_nospc:
  LD r1,r14,1
  MOVI r2,#NKG_ENOSPC
  CALL @nkg_fail
nkf_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvgen_append r1=ctx r2=value -> token index / -1
nkvgen_append:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,#NKG_C_MAGIC
  LA r4,#NKG_MAGIC
  CMP r3,r4
  JMP[NE] @nka_bad
  LD r3,r1,#NKG_C_VERSION
  MOVI r4,#NKG_VERSION
  CMP r3,r4
  JMP[NE] @nka_bad
  LD r3,r1,#NKG_C_ADMIT
  CMP r3,r0
  JMP[EQ] @nka_stale
  CALL @nkg_ctx_live
  CMP r1,r0
  JMP[EQ] @nka_stale
  ; used < tabcap * tokens/block
  LD r1,r14,1
  LD r3,r1,#NKG_C_USED
  ST r3,r14,3
  LD r4,r1,#NKG_C_BLOCKTOK
  LD r5,r1,#NKG_C_TABCAP
  MUL r5,r5,r4
  CMP r3,r5
  JMP[GE] @nka_nospc
  DIVU r4,r3,r4
  ST r4,r14,4
  LD r5,r1,#NKG_C_BLOCKTOK
  MODU r6,r3,r5
  ST r6,r14,5
  ; entry = table + block*4
  LD r7,r1,#NKG_C_TAB
  SHL r8,r4,2
  ADD r7,r7,r8
  ST r7,r14,6
  LD r8,r7,#NKG_E_PAGE
  CMP r8,r0
  JMP[NE] @nka_have
  ; only the next sequential block may be allocated
  LD r9,r1,#NKG_C_LIVE
  CMP r4,r9
  JMP[NE] @nka_blk
  ADD r1,r1,r0
  LD r2,r1,#NKG_C_GEN
  CALL @nkvgen_page_new
  CMP r1,r0
  JMP[EQ] @nka_nospc
  LD r7,r14,6
  ST r1,r7,#NKG_E_PAGE
  LD r2,r14,1
  LD r2,r2,#NKG_C_GEN
  ST r2,r7,#NKG_E_MAPGEN
  ST r0,r7,#NKG_E_FLAGS
  LD r2,r14,1
  LD r3,r2,#NKG_C_LIVE
  ADD r3,r3,r13
  ST r3,r2,#NKG_C_LIVE
  ADD r8,r1,r0
  JMP @nka_have
nka_have:
  ST r8,r14,7
  ; page must be live, not from a future generation
  LD r2,r8,#NKG_P_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @nka_blk
  LD r1,r14,1
  LD r2,r1,#NKG_C_GEN
  LD r3,r8,#NKG_P_GEN
  CMP r3,r2
  JMP[GT] @nka_blk
  ; shared/ancestor page: copy exactly this partial page before writing
  LD r4,r8,#NKG_P_FLAGS
  MOVI r5,#NKG_F_SHARED
  BOOL.8 r4,r4,r5
  CMP r4,r0
  JMP[NE] @nka_cow
  LD r4,r8,#NKG_P_REFS
  MOVI r5,1
  CMP r4,r5
  JMP[GT] @nka_cow
  CMP r3,r2
  JMP[NE] @nka_blk
  JMP @nka_write
nka_cow:
  LD r1,r14,1
  ADD r2,r8,r0
  CALL @nkg_cow
  CMP r1,r0
  JMP[EQ] @nka_nospc
  ST r1,r14,7
  LD r7,r14,6
  ST r1,r7,#NKG_E_PAGE
  LD r2,r14,1
  LD r2,r2,#NKG_C_GEN
  ST r2,r7,#NKG_E_MAPGEN
  ST r0,r7,#NKG_E_FLAGS
nka_write:
  LD r8,r14,7
  LD r3,r14,5
  LD r4,r8,#NKG_P_USED
  CMP r3,r4
  JMP[NE] @nka_blk
  LD r5,r8,#NKG_P_SLOTS
  CMP r4,r5
  JMP[GE] @nka_blk
  ; record = page base + slot*4
  LD r6,r8,#NKG_P_BASE
  SHL r3,r3,2
  ADD r6,r6,r3
  LD r1,r14,3
  ST r1,r6,0
  LD r1,r14,2
  ST r1,r6,1
  LA r1,#NKG_REC_TAG
  ST r1,r6,2
  LD r1,r8,#NKG_P_GEN
  ST r1,r6,3
  LD r1,r8,#NKG_P_USED
  ADD r1,r1,r13
  ST r1,r8,#NKG_P_USED
  LD r1,r14,1
  LD r2,r1,#NKG_C_USED
  ADD r2,r2,r13
  ST r2,r1,#NKG_C_USED
  LA r3,#NKG_STATS
  LD r4,r3,#NKG_G_OPS
  ADD r4,r4,r13
  ST r4,r3,#NKG_G_OPS
  LD r1,r14,3
  JMP @nka_out
nka_bad:
  LD r1,r14,1
  MOVI r2,#NKG_EBAD
  CALL @nkg_fail
  JMP @nka_out
nka_blk:
  LD r1,r14,1
  MOVI r2,#NKG_EBLK
  CALL @nkg_fail
  JMP @nka_out
nka_stale:
  LD r1,r14,1
  MOVI r2,#NKG_ESTALE
  CALL @nkg_fail
  JMP @nka_out
nka_nospc:
  LD r1,r14,1
  MOVI r2,#NKG_ENOSPC
  CALL @nkg_fail
nka_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvgen_view_open r1=ctx r2=token r3=mode r4=out -> 1/0
nkvgen_view_open:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,17
  ST r2,r14,18
  ST r3,r14,19
  ST r4,r14,20
  LD r5,r1,#NKG_C_MAGIC
  LA r6,#NKG_MAGIC
  CMP r5,r6
  JMP[NE] @nkv_bad
  LD r5,r1,#NKG_C_VERSION
  MOVI r6,#NKG_VERSION
  CMP r5,r6
  JMP[NE] @nkv_bad
  CMP r4,r0
  JMP[EQ] @nkv_bad
  CMP r3,r0
  JMP[EQ] @nkv_bad
  MOVI r5,2
  CMP r3,r5
  JMP[GT] @nkv_bad
  CALL @nkg_ctx_live
  CMP r1,r0
  JMP[EQ] @nkv_stale
  LD r1,r14,17
  LD r2,r14,18
  CALL @nkg_lookup
  CMP r1,r0
  JMP[EQ] @nkv_none
  ST r1,r14,21
  ST r2,r14,22
  ST r3,r14,23
  ; private pages must match the reader generation; shared ancestor pages
  ; may be read by descendants
  LD r1,r14,17
  LD r2,r1,#NKG_C_GEN
  LD r1,r14,21
  LD r3,r1,#NKG_P_STATE
  MOVI r4,1
  CMP r3,r4
  JMP[NE] @nkv_blk
  LD r3,r1,#NKG_P_GEN
  CMP r3,r2
  JMP[GT] @nkv_blk
  CMP r3,r2
  JMP[EQ] @nkv_okgen
  LD r3,r1,#NKG_P_FLAGS
  MOVI r4,#NKG_F_SHARED
  BOOL.8 r3,r3,r4
  CMP r3,r0
  JMP[EQ] @nkv_blk
nkv_okgen:
  ; zero the 32-word wrapper
  LD r1,r14,20
  MOVI r2,32
nkv_z:
  CMP r2,r0
  JMP[EQ] @nkv_meta
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkv_z
nkv_meta:
  ; mint the embedded nkv rank-1 f32 view over this token record
  LA r1,#NKG_SCR_SHAPE
  MOVI r2,4
  ST r2,r1,0
  LD r4,r14,21
  LD r1,r4,#NKG_P_CAP
  LD r2,r14,22
  SHL r2,r2,4
  MOVI r3,0
  MOVI r4,#NKG_BPT_BYTES
  MOVI r5,0
  MOVI r6,2
  MOVI r7,1
  LA r8,#NKG_SCR_SHAPE
  LD r9,r14,20
  ADDI r9,r9,#NKG_V_NKV
  CALL @nkv_view_create
  CMP r1,r0
  JMP[NE] @nkv_blk
  ; wrapper metadata (locals are above the nkv nested-frame window)
  LD r1,r14,20
  LA r2,#NKG_VMAGIC
  ST r2,r1,#NKG_V_MAGIC
  MOVI r2,#NKG_VERSION
  ST r2,r1,#NKG_V_VERSION
  LD r3,r14,17
  LD r2,r3,#NKG_C_GEN
  ST r2,r1,#NKG_V_CTXGEN
  LD r2,r3,#NKG_C_BRANCH
  ST r2,r1,#NKG_V_BRANCH
  LD r2,r14,18
  ST r2,r1,#NKG_V_TOKEN
  LD r4,r14,21
  ST r4,r1,#NKG_V_PAGE
  LD r2,r4,#NKG_P_GEN
  ST r2,r1,#NKG_V_PAGEGEN
  LD r2,r14,19
  ST r2,r1,#NKG_V_MODE
  LD r2,r3,#NKG_C_VOPEN
  ADD r2,r2,r13
  ST r2,r3,#NKG_C_VOPEN
  LD r2,r3,#NKG_C_VMINT
  ADD r2,r2,r13
  ST r2,r3,#NKG_C_VMINT
  LA r2,#NKG_STATS
  LD r4,r2,#NKG_G_VOPEN
  ADD r4,r4,r13
  ST r4,r2,#NKG_G_VOPEN
  LD r4,r2,#NKG_G_OPS
  ADD r4,r4,r13
  ST r4,r2,#NKG_G_OPS
  MOVI r1,1
  JMP @nkv_out
nkv_bad:
  LD r1,r14,17
  MOVI r2,#NKG_EBAD
  CALL @nkg_fail
  JMP @nkv_out
nkv_stale:
  LD r1,r14,17
  MOVI r2,#NKG_ESTALE
  CALL @nkg_fail
  JMP @nkv_out
nkv_none:
  LD r1,r14,17
  MOVI r2,#NKG_ENOENT
  CALL @nkg_fail
  JMP @nkv_out
nkv_blk:
  LD r1,r14,17
  MOVI r2,#NKG_EBLK
  CALL @nkg_fail
nkv_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvgen_view_read r1=ctx r2=view r3=out(4) -> 1/0
nkvgen_view_read:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,17
  ST r2,r14,18
  ST r3,r14,19
  LD r4,r1,#NKG_C_MAGIC
  LA r5,#NKG_MAGIC
  CMP r4,r5
  JMP[NE] @nkr_bad
  LD r4,r2,#NKG_V_MAGIC
  LA r5,#NKG_VMAGIC
  CMP r4,r5
  JMP[NE] @nkr_bad
  LD r4,r2,#NKG_V_VERSION
  MOVI r5,#NKG_VERSION
  CMP r4,r5
  JMP[NE] @nkr_bad
  CMP r3,r0
  JMP[EQ] @nkr_bad
  ; cross-generation view: exact EGEN
  LD r4,r2,#NKG_V_CTXGEN
  LD r5,r1,#NKG_C_GEN
  CMP r4,r5
  JMP[NE] @nkr_gen
  LD r4,r2,#NKG_V_BRANCH
  LD r5,r1,#NKG_C_BRANCH
  CMP r4,r5
  JMP[NE] @nkr_gen
  LD r4,r2,#NKG_V_MODE
  MOVI r5,1
  BOOL.8 r4,r4,r5
  CMP r4,r0
  JMP[EQ] @nkr_bad
  ; the context's ngen generation must still be live
  CALL @nkg_ctx_live
  CMP r1,r0
  JMP[EQ] @nkr_stale
  LD r2,r14,18
  LD r1,r2,#NKG_V_PAGE
  ST r1,r14,20
  LD r3,r1,#NKG_P_STATE
  MOVI r4,1
  CMP r3,r4
  JMP[NE] @nkr_stale
  LD r3,r1,#NKG_P_GEN
  LD r4,r2,#NKG_V_PAGEGEN
  CMP r3,r4
  JMP[NE] @nkr_blk
  ; resolve through the embedded nkv view
  LD r1,r14,18
  ADDI r1,r1,#NKG_V_NKV
  MOVI r2,0
  MOVI r3,0
  CALL @nkv_view_addr
  CMP r3,r0
  JMP[NE] @nkr_blk
  CMP r2,r0
  JMP[NE] @nkr_blk
  SHR r5,r1,2
  ST r5,r14,21
  ; validate the record before exposing it
  LD r6,r5,0
  LD r7,r14,18
  LD r7,r7,#NKG_V_TOKEN
  CMP r6,r7
  JMP[NE] @nkr_blk
  LD r6,r5,2
  LA r7,#NKG_REC_TAG
  CMP r6,r7
  JMP[NE] @nkr_blk
  LD r6,r5,3
  LD r7,r14,20
  LD r7,r7,#NKG_P_GEN
  CMP r6,r7
  JMP[NE] @nkr_blk
  ; copy the record
  LD r1,r14,19
  LD r2,r14,21
  MOVI r3,4
nkr_cp:
  CMP r3,r0
  JMP[EQ] @nkr_done
  LD r4,r2,0
  ST r4,r1,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  SUB r3,r3,r13
  JMP @nkr_cp
nkr_done:
  LD r1,r14,17
  LD r2,r1,#NKG_C_VIEWREAD
  ADD r2,r2,r13
  ST r2,r1,#NKG_C_VIEWREAD
  LA r2,#NKG_STATS
  LD r3,r2,#NKG_G_VREAD
  ADD r3,r3,r13
  ST r3,r2,#NKG_G_VREAD
  LD r3,r2,#NKG_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKG_G_OPS
  MOVI r1,1
  JMP @nkr_out
nkr_gen:
  LD r1,r14,17
  MOVI r2,#NKG_EGEN
  CALL @nkg_fail
  JMP @nkr_out
nkr_stale:
  LD r1,r14,17
  MOVI r2,#NKG_ESTALE
  CALL @nkg_fail
  JMP @nkr_out
nkr_bad:
  LD r1,r14,17
  MOVI r2,#NKG_EBAD
  CALL @nkg_fail
  JMP @nkr_out
nkr_blk:
  LD r1,r14,17
  MOVI r2,#NKG_EBLK
  CALL @nkg_fail
nkr_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvgen_view_write r1=ctx r2=view r3=value -> 1/0
nkvgen_view_write:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,17
  ST r2,r14,18
  ST r3,r14,19
  LD r4,r1,#NKG_C_MAGIC
  LA r5,#NKG_MAGIC
  CMP r4,r5
  JMP[NE] @nkw_bad
  LD r4,r2,#NKG_V_MAGIC
  LA r5,#NKG_VMAGIC
  CMP r4,r5
  JMP[NE] @nkw_bad
  LD r4,r2,#NKG_V_VERSION
  MOVI r5,#NKG_VERSION
  CMP r4,r5
  JMP[NE] @nkw_bad
  LD r4,r2,#NKG_V_CTXGEN
  LD r5,r1,#NKG_C_GEN
  CMP r4,r5
  JMP[NE] @nkw_gen
  LD r4,r2,#NKG_V_BRANCH
  LD r5,r1,#NKG_C_BRANCH
  CMP r4,r5
  JMP[NE] @nkw_gen
  LD r4,r2,#NKG_V_MODE
  MOVI r5,2
  BOOL.8 r4,r4,r5
  CMP r4,r0
  JMP[EQ] @nkw_bad
  CALL @nkg_ctx_live
  CMP r1,r0
  JMP[EQ] @nkw_stale
  LD r2,r14,18
  LD r1,r2,#NKG_V_PAGE
  ST r1,r14,20
  LD r3,r1,#NKG_P_STATE
  MOVI r4,1
  CMP r3,r4
  JMP[NE] @nkw_stale
  ; immutable shared prefix pages reject writes exactly
  LD r3,r1,#NKG_P_FLAGS
  MOVI r4,#NKG_F_SHARED
  BOOL.8 r3,r3,r4
  CMP r3,r0
  JMP[NE] @nkw_shared
  LD r3,r1,#NKG_P_REFS
  MOVI r4,1
  CMP r3,r4
  JMP[GT] @nkw_shared
  ; private page must belong to this generation
  LD r3,r1,#NKG_P_GEN
  LD r4,r2,#NKG_V_PAGEGEN
  CMP r3,r4
  JMP[NE] @nkw_blk
  LD r5,r14,17
  LD r5,r5,#NKG_C_GEN
  CMP r3,r5
  JMP[NE] @nkw_blk
  LD r1,r14,18
  ADDI r1,r1,#NKG_V_NKV
  MOVI r2,0
  MOVI r3,0
  CALL @nkv_view_addr
  CMP r3,r0
  JMP[NE] @nkw_blk
  CMP r2,r0
  JMP[NE] @nkw_blk
  SHR r5,r1,2
  LD r6,r5,0
  LD r7,r14,18
  LD r7,r7,#NKG_V_TOKEN
  CMP r6,r7
  JMP[NE] @nkw_blk
  LD r6,r5,2
  LA r7,#NKG_REC_TAG
  CMP r6,r7
  JMP[NE] @nkw_blk
  LD r6,r5,3
  LD r7,r14,20
  LD r7,r7,#NKG_P_GEN
  CMP r6,r7
  JMP[NE] @nkw_blk
  LD r6,r14,19
  ST r6,r5,1
  LD r1,r14,17
  LD r2,r1,#NKG_C_VIEWWRITE
  ADD r2,r2,r13
  ST r2,r1,#NKG_C_VIEWWRITE
  LA r2,#NKG_STATS
  LD r3,r2,#NKG_G_VWRITE
  ADD r3,r3,r13
  ST r3,r2,#NKG_G_VWRITE
  LD r3,r2,#NKG_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKG_G_OPS
  MOVI r1,1
  JMP @nkw_out
nkw_gen:
  LD r1,r14,17
  MOVI r2,#NKG_EGEN
  CALL @nkg_fail
  JMP @nkw_out
nkw_stale:
  LD r1,r14,17
  MOVI r2,#NKG_ESTALE
  CALL @nkg_fail
  JMP @nkw_out
nkw_shared:
  LD r1,r14,17
  MOVI r2,#NKG_ESHARED
  CALL @nkg_fail
  JMP @nkw_out
nkw_bad:
  LD r1,r14,17
  MOVI r2,#NKG_EBAD
  CALL @nkg_fail
  JMP @nkw_out
nkw_blk:
  LD r1,r14,17
  MOVI r2,#NKG_EBLK
  CALL @nkg_fail
nkw_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvgen_close r1=ctx -> 1/0
nkvgen_close:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  LD r2,r1,#NKG_C_MAGIC
  LA r3,#NKG_MAGIC
  CMP r2,r3
  JMP[NE] @nkc_bad
  LD r2,r1,#NKG_C_ADMIT
  CMP r2,r0
  JMP[EQ] @nkc_bad
  ; release every live block in ascending order
  LD r3,r1,#NKG_C_TAB
  LD r4,r1,#NKG_C_LIVE
  ST r4,r14,2
  MOVI r5,0
  ST r5,r14,3
nkc_l:
  LD r5,r14,3
  LD r4,r14,2
  CMP r5,r4
  JMP[GE] @nkc_rel_done
  SHL r6,r5,2
  ADD r7,r3,r6
  ST r7,r14,4
  LD r2,r7,#NKG_E_PAGE
  CMP r2,r0
  JMP[EQ] @nkc_next
  LD r1,r14,1
  CALL @nkg_release
  LD r7,r14,4
  ST r0,r7,#NKG_E_PAGE
  ST r0,r7,#NKG_E_MAPGEN
  ST r0,r7,#NKG_E_FLAGS
nkc_next:
  LD r5,r14,3
  ADD r5,r5,r13
  ST r5,r14,3
  LD r3,r14,1
  LD r3,r3,#NKG_C_TAB
  JMP @nkc_l
nkc_rel_done:
  LD r1,r14,1
  ST r0,r1,#NKG_C_LIVE
  ST r0,r1,#NKG_C_ADMIT
  ST r0,r1,#NKG_C_USED
  ; leave the ngen generation (parent DRAINING -> DRAINED)
  LD r2,r1,#NKG_C_AGENT
  LD r3,r1,#NKG_C_GEN
  ADD r1,r2,r0
  ADD r2,r3,r0
  CALL @ngen_exit
  CALL @ngen_errno
  CMP r1,r0
  JMP[NE] @nkc_ngerr
  LA r2,#NKG_STATS
  LD r3,r2,#NKG_G_OPS
  ADD r3,r3,r13
  ST r3,r2,#NKG_G_OPS
  MOVI r1,1
  JMP @nkc_out
nkc_ngerr:
  LD r2,r14,1
  ST r1,r2,#NKG_C_NGERR
  MOVI r2,#NKG_ESTALE
  CALL @nkg_fail
  JMP @nkc_out
nkc_bad:
  LD r1,r14,1
  MOVI r2,#NKG_EBAD
  CALL @nkg_fail
nkc_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkvgen_page_info r1=page index r2=out(16) -> 0/-1
nkvgen_page_info:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r2,r14,1
  CALL @nkg_pageptr
  CMP r1,r0
  JMP[EQ] @nkpi_bad
  LD r2,r14,1
  MOVI r3,0
nkpi_l:
  MOVI r4,#NKG_PSTRIDE
  CMP r3,r4
  JMP[GE] @nkpi_ok
  ADD r4,r1,r3
  LD r4,r4,0
  ADD r5,r2,r3
  ST r4,r5,0
  ADD r3,r3,r13
  JMP @nkpi_l
nkpi_ok:
  MOVI r1,0
  JMP @nkpi_out
nkpi_bad:
  LA r1,0xFFFFFFFF
nkpi_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkvgen_stats r1=out(32) -> 0/-1
nkvgen_stats:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  LA r1,#NKG_STATS
  LD r2,r14,1
  MOVI r3,0
nkgst_l:
  MOVI r4,#NKG_SW
  CMP r3,r4
  JMP[GE] @nkgst_ok
  ADD r4,r1,r3
  LD r4,r4,0
  ADD r5,r2,r3
  ST r4,r5,0
  ADD r3,r3,r13
  JMP @nkgst_l
nkgst_ok:
  MOVI r1,0
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nkvgen_ctx_info r1=ctx r2=out(32) -> 0/-1
nkvgen_ctx_info:
  LD r3,r1,#NKG_C_MAGIC
  LA r4,#NKG_MAGIC
  CMP r3,r4
  JMP[NE] @nkci_bad
  MOVI r3,0
nkci_l:
  MOVI r4,32
  CMP r3,r4
  JMP[GE] @nkci_ok
  ADD r4,r1,r3
  LD r4,r4,0
  ADD r5,r2,r3
  ST r4,r5,0
  ADD r3,r3,r13
  JMP @nkci_l
nkci_ok:
  MOVI r1,0
  RET
nkci_bad:
  LA r1,0xFFFFFFFF
  RET

; nkvgen_errno -> last error.
nkvgen_errno:
  LA r1,#NKG_STATS
  LD r1,r1,#NKG_G_LERR
  RET
