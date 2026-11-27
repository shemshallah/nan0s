; npaged.nas - per-agent paged KV block table + incremental decode (F13a).
;
; Pure NaN.  This is the long-context KV layer the (nattn)/(nkv)/(nmodel)
; directives ask for: attention state is not one contiguous slab but a
; per-agent table of logical KV blocks, each block backed by its own 2 MiB
; nheap allocation plus an nkv class-20 storage capability and per-token
; rank-1 f32 views.  Logical token -> (block, slot) is stable for the life of
; the context; a block may be remapped to a fresh 2 MiB page (copy + rebase)
; while the logical indices keep resolving, and the old page is returned to
; nheap.  Every block and every token record carries a generation, so a view
; or token resolved before a remap fails closed afterwards.
;
; Layout
; ------
; npaged context (24 words, caller supplied):
;   +0 magic 0x4741504E ("NPAG")  +1 version 1
;   +2 agent id                   +3 KV generation seed
;   +4 nheap context              +5 block table pointer
;   +6 table capacity (blocks)    +7 tokens per block
;   +8 dim (32..64, /32)          +9 nb = dim/32
;   +10 record stride in words    +11 used tokens
;   +12 token capacity            +13 live blocks
;   +14 allocations               +15 generation counter
;   +16 pressure threshold %      +17 nheap node
;   +18 evictions                 +19 remaps
;   +20 pressure flag             +21 current pressure %
;   +22..23 reserved
;
; Block table entry (16 words):
;   +0 state (0 free, 1 live)     +1 logical block
;   +2 base_lo +3 base_hi         +4 storage capability
;   +5 generation                 +6 tokens used in block
;   +7 reserved
;   +8 block bytes lo +9 hi       +10..15 reserved
;
; Token record inside a block (stride words, 8-word aligned):
;   +0 record magic 0x4345524E ("NREC")
;   +1 generation   +2 logical token   +3 flags
;   +4 .. +4+dim-1            x     (f32 input latent)
;   +4+dim .. +4+2dim-1       v     (f32 V projection)
;   +4+2dim ..                q4    (dim/32 Q4_0 blocks, 5 words each)
;   ...                       q8    (dim/32 Q8_0 blocks, 9 words each)
; stride = align8(4 + 2*dim + 14*nb).
;
; A block is 2 MiB (NP_BLOCK_BYTES) of nheap allocation.  Only
; tokens_per_block * stride * 4 bytes are used; the remainder is slack so a
; legal tokens_per_block must satisfy tokens_per_block*stride*4 <= 2 MiB.
; The 2 MiB unit is the nheap 2 MiB page class, so a block never splits a
; page and eviction/remap returns exactly one page to nheap.
;
; Direct record access and nattn views are 32-bit word addressed.  The page
; table stores the full 64-bit nheap base, but decode requires base_hi == 0
; (below 4 GiB of byte address) because nattn_view_ptr rejects a high word.
; That still covers 2048 blocks per table, i.e. 16.7M tokens at 8192
; tokens/block.  Lifting the 4 GiB view limit is an explicit frontier item.
;
; API (r0=0, r13=1, r14 grows up, r15 link):
;   npaged_init        r1=ctx r2=nheap ctx r3=table r4=table cap r5=cfg -> 0/-1
;                      cfg: +0 agent +1 gen +2 node +3 dim +4 tokens/block
;                           +5 pressure percent (0..100) +6 flags
;   npaged_append      r1=ctx r2=x ptr r3=position r4=nattn cfg -> token/-1
;                      computes q=Wq*x, k=Wk*x, v=Wv*x, RoPE at position,
;                      quantizes Q4/Q8 caches and writes the record.
;   npaged_prefill     r1=ctx r2=xs r3=count r4=position0 r5=cfg r6=logits
;                      -> last token/-1 (appends count tokens, then decodes
;                      attention for the last one).
;   npaged_decode      r1=ctx r2=x r3=position r4=cfg r5=logits -> token/-1
;                      (append one token + attention for it).
;   npaged_attention   r1=ctx r2=token r3=cfg r4=logits -> 0/-1
;   npaged_remap       r1=ctx r2=logical block -> new generation / 0
;                      (allocate a fresh 2 MiB page, copy used records, bump
;                      generation, release the old page to nheap).
;   npaged_evict_last  r1=ctx -> 0/-1 (truncate the tail block and free its
;                      page to nheap; earlier logical tokens stay stable).
;   npaged_trim        r1=ctx r2=count -> 0/-1 (truncate to count tokens;
;                      blocks above the target block are released to nheap,
;                      a partially trimmed target block bumps its generation
;                      and rewrites retained record headers.  This is the
;                      speculative-decoding rollback primitive.)
;   npaged_token_word  r1=ctx r2=token -> record word address / 0
;   npaged_token_gen   r1=ctx r2=token -> generation / 0
;   npaged_check       r1=ctx r2=token r3=generation -> 1 if live and equal
;   npaged_pressure    r1=ctx -> used*100/capacity, updates the flag
;   npaged_remaining   r1=ctx -> free token slots / -1
;   npaged_stats       r1=ctx r2=out(16) -> 0/-1
;                      out: used,cap,live,allocs,evicts,remaps,gen,pressure%,
;                           agent,blocktok,dim,stride,node,flag,tabcap,
;                           pressure threshold
;
; Attention reuses nattn's exact primitives: nattn_matvec_q4/q8, nattn_rope,
; nattn_quant_q4/q8, nattn_qk_fused, nattn_view_ptr and nat_rmsnorm.  The
; softmax is a local copy of nattn_softmax with a 512-entry window because
; nattn caps a single pass at 8 tokens; for n<=8 the arithmetic and the
; result bits are identical (same max/exp/sum/divide order).  The decode
; window is 512 tokens; a longer context needs chunked/online softmax.
;
; Scratch 0x4800..0x4CFF (nkv uses 0x5000, nattn 0x5600, nq4 0x6000).

.include "nattn.nas"

.equ NP_MAGIC       0x4741504E
.equ NP_VERSION     1
.equ NP_REC_MAGIC   0x4345524E
.equ NP_BLOCK_BYTES 0x200000
.equ NP_HDR         4
.equ NP_ENT         16
.equ NP_MAXDIM      64
.equ NP_MAXSC       512

; context fields
.equ NP_C_MAGIC     0
.equ NP_C_VERSION   1
.equ NP_C_AGENT     2
.equ NP_C_KVGEN     3
.equ NP_C_HEAP      4
.equ NP_C_TAB       5
.equ NP_C_TABCAP    6
.equ NP_C_BLOCKTOK  7
.equ NP_C_DIM       8
.equ NP_C_NB        9
.equ NP_C_STRIDE    10
.equ NP_C_USED      11
.equ NP_C_CAP       12
.equ NP_C_LIVE      13
.equ NP_C_ALLOCS    14
.equ NP_C_GEN       15
.equ NP_C_PRESS     16
.equ NP_C_NODE      17
.equ NP_C_EVICTS    18
.equ NP_C_REMAPS    19
.equ NP_C_FLAG      20
.equ NP_C_PRESSV    21

; entry fields
.equ NP_E_STATE     0
.equ NP_E_BLOCK     1
.equ NP_E_BASE      2
.equ NP_E_CAP       4
.equ NP_E_GEN       5
.equ NP_E_USED      6
.equ NP_E_BYTES     8

; init config fields
.equ NP_K_AGENT     0
.equ NP_K_GEN       1
.equ NP_K_NODE      2
.equ NP_K_DIM       3
.equ NP_K_BLOCKTOK  4
.equ NP_K_PRESS     5
.equ NP_K_FLAGS     6

; scratch
.equ NP_A    0x4800
.equ NP_R    0x4820
.equ NP_P    0x4840
.equ NP_AP   0x4860
.equ NP_CF   0x48A0
.equ NP_MS   0x48B0
.equ NP_PR   0x48C0
.equ NP_VW   0x4900
.equ NP_SH   0x4920
.equ NP_Q    0x4940
.equ NP_K    0x4980
.equ NP_CTX  0x49C0
.equ NP_H    0x4A00
.equ NP_RMS  0x4A40
.equ NP_SC   0x4B00
.equ NP_TP   0x4AC0

; ---------------------------------------------------------------------------
; np_entry: r1=ctx r2=block -> entry ptr or 0.  Leaf.
np_entry:
  LD r3,r1,#NP_C_TABCAP
  CMP r2,r3
  JMP[GE] @npe_bad
  SHL r3,r2,4
  LD r4,r1,#NP_C_TAB
  ADD r1,r4,r3
  RET
npe_bad:
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; np_cfgcheck: r1=ctx r2=nattn cfg -> 0/-1
np_cfgcheck:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r3,#NP_CF
  ST r1,r3,0
  ST r2,r3,1
  LD r4,r1,#NP_C_MAGIC
  LA r5,#NP_MAGIC
  CMP r4,r5
  JMP[NE] @npc_bad
  LD r4,r1,#NP_C_VERSION
  MOVI r5,#NP_VERSION
  CMP r4,r5
  JMP[NE] @npc_bad
  LD r4,r2,0
  LA r5,#NATT_MAGIC
  CMP r4,r5
  JMP[NE] @npc_bad
  LD r4,r2,1
  MOVI r5,#NATT_VERSION
  CMP r4,r5
  JMP[NE] @npc_bad
  LD r4,r2,3
  LD r5,r1,#NP_C_DIM
  CMP r4,r5
  JMP[NE] @npc_bad
  LD r4,r2,15
  CMP r4,r0
  JMP[EQ] @npc_bad
  LD r4,r2,16
  CMP r4,r0
  JMP[EQ] @npc_bad
  MOVI r1,0
  JMP @npc_out
npc_bad:
  LA r1,0xFFFFFFFF
npc_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; np_pagenew: r1=ctx -> 0/-1.  NP_P: +0 base_lo +1 base_hi +2 cap.
np_pagenew:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NP_P+8
  LD r1,r0,#NP_P+8
  LD r1,r1,#NP_C_HEAP
  LD r2,r0,#NP_P+8
  LD r2,r2,#NP_C_NODE
  MOVI r3,1
  MOVI r4,1
  MOVI r5,0
  LA r6,#NP_P
  CALL @nheap_alloc
  CMP r1,r0
  JMP[NE] @npp_bad
  LD r1,r0,#NP_P+0
  LD r2,r0,#NP_P+1
  LA r3,#NP_BLOCK_BYTES
  MOVI r4,0
  MOVI r5,3
  LD r6,r0,#NP_P+8
  LD r6,r6,#NP_C_NODE
  CALL @nkv_storage_create
  CMP r1,r0
  JMP[NE] @npp_ok
  ; storage cap creation failed: return the page to nheap
  LD r1,r0,#NP_P+8
  LD r1,r1,#NP_C_HEAP
  LD r2,r0,#NP_P+8
  LD r2,r2,#NP_C_NODE
  MOVI r3,1
  LD r4,r0,#NP_P+0
  LD r5,r0,#NP_P+1
  MOVI r6,1
  MOVI r7,0
  CALL @nheap_free
  JMP @npp_bad
npp_ok:
  ST r1,r0,#NP_P+2
  MOVI r1,0
  JMP @npp_out
npp_bad:
  LA r1,0xFFFFFFFF
npp_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; np_alloc_block: r1=ctx r2=block -> entry ptr or 0.
np_alloc_block:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NP_P+10
  ST r2,r0,#NP_P+11
  ADD r1,r1,r0
  ADD r3,r2,r0
  ; entry = np_entry(ctx, block)
  LD r1,r0,#NP_P+10
  LD r2,r0,#NP_P+11
  CALL @np_entry
  CMP r1,r0
  JMP[EQ] @npab_bad
  ST r1,r0,#NP_P+12
  LD r1,r0,#NP_P+10
  CALL @np_pagenew
  CMP r1,r0
  JMP[NE] @npab_bad

  ; generation = ++ctx->gen (skip 0)
  LD r1,r0,#NP_P+10
  LD r2,r1,#NP_C_GEN
  ADD r2,r2,r13
  CMP r2,r0
  JMP[NE] @npab_gen
  MOVI r2,1
npab_gen:
  ST r2,r1,#NP_C_GEN
  ST r2,r0,#NP_P+13

  ; zero the 16-word entry
  LD r6,r0,#NP_P+12
  MOVI r4,0
npab_z:
  MOVI r5,#NP_ENT
  CMP r4,r5
  JMP[GE] @npab_zd
  ADD r5,r6,r4
  ST r0,r5,0
  ADD r4,r4,r13
  JMP @npab_z
npab_zd:
  MOVI r1,1
  ST r1,r6,#NP_E_STATE
  LD r1,r0,#NP_P+11
  ST r1,r6,#NP_E_BLOCK
  LD r1,r0,#NP_P+0
  ST r1,r6,#NP_E_BASE
  LD r1,r0,#NP_P+1
  ST r1,r6,#NP_E_BASE+1
  LD r1,r0,#NP_P+2
  ST r1,r6,#NP_E_CAP
  LD r1,r0,#NP_P+13
  ST r1,r6,#NP_E_GEN
  ST r0,r6,#NP_E_USED
  ; bytes = tokens_per_block * stride * 4 (documented 32-bit)
  LD r1,r0,#NP_P+10
  LD r2,r1,#NP_C_BLOCKTOK
  LD r3,r1,#NP_C_STRIDE
  MUL r2,r2,r3
  SHL r2,r2,2
  ST r2,r6,#NP_E_BYTES
  ST r0,r6,#NP_E_BYTES+1
  LD r2,r1,#NP_C_LIVE
  ADD r2,r2,r13
  ST r2,r1,#NP_C_LIVE
  LD r2,r1,#NP_C_ALLOCS
  ADD r2,r2,r13
  ST r2,r1,#NP_C_ALLOCS
  ADD r1,r6,r0
  JMP @npab_out
npab_bad:
  MOVI r1,0
npab_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; np_record: r1=ctx r2=token -> r1=record word ptr r2=generation, or 0,0.
np_record:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r3,#NP_R
  ST r1,r3,0
  ST r2,r3,1
  LD r4,r1,#NP_C_MAGIC
  LA r5,#NP_MAGIC
  CMP r4,r5
  JMP[NE] @npr_bad
  LD r4,r1,#NP_C_VERSION
  MOVI r5,#NP_VERSION
  CMP r4,r5
  JMP[NE] @npr_bad
  LD r3,r1,#NP_C_USED
  CMP r2,r3
  JMP[GE] @npr_bad
  LD r3,r1,#NP_C_BLOCKTOK
  DIVU r4,r2,r3
  MODU r5,r2,r3
  ST r4,r0,#NP_R+2
  ST r5,r0,#NP_R+3
  LD r1,r0,#NP_R+0
  LD r2,r0,#NP_R+2
  CALL @np_entry
  CMP r1,r0
  JMP[EQ] @npr_bad
  ST r1,r0,#NP_R+4
  LD r3,r1,#NP_E_STATE
  MOVI r4,1
  CMP r3,r4
  JMP[NE] @npr_bad
  LD r3,r1,#NP_E_USED
  LD r4,r0,#NP_R+3
  CMP r4,r3
  JMP[GE] @npr_bad
  ; rec = (base_lo >> 2) + (base_hi << 30) + slot*stride
  LD r3,r1,#NP_E_BASE
  SHR r3,r3,2
  LD r4,r1,#NP_E_BASE+1
  SHL r4,r4,30
  ADD r3,r3,r4
  LD r4,r0,#NP_R+3
  LD r5,r0,#NP_R+0
  LD r5,r5,#NP_C_STRIDE
  MUL r4,r4,r5
  ADD r3,r3,r4
  ST r3,r0,#NP_R+5
  ; header must match block generation and logical token
  LD r4,r3,0
  LA r5,#NP_REC_MAGIC
  CMP r4,r5
  JMP[NE] @npr_bad
  LD r4,r3,1
  LD r5,r1,#NP_E_GEN
  CMP r4,r5
  JMP[NE] @npr_bad
  LD r4,r3,2
  LD r5,r0,#NP_R+1
  CMP r4,r5
  JMP[NE] @npr_bad
  LD r5,r0,#NP_R+4
  LD r5,r5,#NP_E_GEN
  ADD r1,r3,r0
  ADD r2,r5,r0
  JMP @npr_out
npr_bad:
  MOVI r1,0
  MOVI r2,0
npr_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; np_record_view: r1=ctx r2=token r3=out view
;                 -> r1=record word ptr r2=generation, or 0,0.
; Resolves the token through a fresh rank-1 f32 nkv view over the block
; storage cap, and checks that nattn_view_ptr lands exactly on the record.
np_record_view:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r4,#NP_R
  ST r1,r4,8
  ST r2,r4,9
  ST r3,r4,10
  ADD r1,r1,r0
  CALL @np_record
  CMP r1,r0
  JMP[EQ] @npv_bad
  ST r1,r0,#NP_R+11
  ST r2,r0,#NP_R+12
  ; block and slot
  LD r1,r0,#NP_R+8
  LD r2,r0,#NP_R+9
  LD r3,r1,#NP_C_BLOCKTOK
  DIVU r4,r2,r3
  MODU r5,r2,r3
  ST r5,r0,#NP_R+13
  ADD r1,r1,r0
  ADD r2,r4,r0
  CALL @np_entry
  CMP r1,r0
  JMP[EQ] @npv_bad
  ST r1,r0,#NP_R+14
  ; shape[0] = 2*dim
  LD r2,r0,#NP_R+8
  LD r2,r2,#NP_C_DIM
  SHL r3,r2,1
  LA r4,#NP_SH
  ST r3,r4,0
  ; off = slot*stride*4 + 16
  LD r5,r0,#NP_R+13
  LD r3,r0,#NP_R+8
  LD r3,r3,#NP_C_STRIDE
  MUL r5,r5,r3
  SHL r5,r5,2
  MOVI r3,16
  ADD r5,r5,r3
  ; size = 2*dim*4
  SHL r6,r2,3
  LD r1,r0,#NP_R+14
  LD r1,r1,#NP_E_CAP
  ADD r2,r5,r0
  MOVI r3,0
  ADD r4,r6,r0
  MOVI r5,0
  MOVI r6,2
  MOVI r7,1
  LA r8,#NP_SH
  LD r9,r0,#NP_R+10
  CALL @nkv_view_create
  CMP r1,r0
  JMP[NE] @npv_bad
  LD r1,r0,#NP_R+10
  CALL @nattn_view_ptr
  CMP r1,r0
  JMP[EQ] @npv_bad
  LD r2,r0,#NP_R+11
  MOVI r3,#NP_HDR
  ADD r2,r2,r3
  CMP r1,r2
  JMP[NE] @npv_bad
  LD r1,r0,#NP_R+11
  LD r2,r0,#NP_R+12
  JMP @npv_out
npv_bad:
  MOVI r1,0
  MOVI r2,0
npv_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; np_softmax: r1=scores r2=n r3=out -> 0/-1
; Same max/exp/sum/divide order as nattn_softmax, window 512.
np_softmax:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r4,#NP_MS
  ST r1,r4,0
  ST r2,r4,1
  ST r3,r4,2
  CMP r2,r0
  JMP[LE] @nps_bad
  MOVI r3,#NP_MAXSC
  CMP r2,r3
  JMP[GT] @nps_bad
  LD r8,r0,#NP_MS+0
  LD r9,r0,#NP_MS+2
  LD r10,r0,#NP_MS+1
  LD r11,r8,0
  MOVI r12,1
nps_max:
  CMP r12,r10
  JMP[GE] @nps_maxd
  ADD r1,r8,r12
  LD r1,r1,0
  FCMP r1,r11
  JMP[GT] @nps_up
  ADD r12,r12,r13
  JMP @nps_max
nps_up:
  ADD r11,r1,r0
  ADD r12,r12,r13
  JMP @nps_max
nps_maxd:
  MOVI r6,0
  MOVI r12,0
nps_exp:
  CMP r12,r10
  JMP[GE] @nps_expd
  ADD r1,r8,r12
  LD r1,r1,0
  FSUB r1,r1,r11
  FEXP r1,r1
  ADD r2,r9,r12
  ST r1,r2,0
  FADD r6,r6,r1
  ADD r12,r12,r13
  JMP @nps_exp
nps_expd:
  MOVI r12,0
nps_div:
  CMP r12,r10
  JMP[GE] @nps_ok
  ADD r2,r9,r12
  LD r1,r2,0
  FDIV r1,r1,r6
  ST r1,r2,0
  ADD r12,r12,r13
  JMP @nps_div
nps_ok:
  MOVI r1,0
  JMP @nps_out
nps_bad:
  LA r1,0xFFFFFFFF
nps_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; npaged_init: r1=ctx r2=nheap r3=table r4=table cap r5=cfg -> 0/-1
npaged_init:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r6,#NP_TP
  ST r1,r6,0
  ST r2,r6,1
  ST r3,r6,2
  ST r4,r6,3
  ST r5,r6,4
  CMP r1,r0
  JMP[EQ] @npi_bad
  CMP r2,r0
  JMP[EQ] @npi_bad
  CMP r3,r0
  JMP[EQ] @npi_bad
  CMP r4,r0
  JMP[EQ] @npi_bad
  CMP r5,r0
  JMP[EQ] @npi_bad
  LD r6,r5,#NP_K_DIM
  MOVI r7,32
  CMP r6,r7
  JMP[LT] @npi_bad
  MOVI r7,#NP_MAXDIM
  CMP r6,r7
  JMP[GT] @npi_bad
  MOVI r7,31
  BOOL.8 r7,r6,r7
  CMP r7,r0
  JMP[NE] @npi_bad
  LD r8,r5,#NP_K_BLOCKTOK
  CMP r8,r0
  JMP[EQ] @npi_bad
  MOVI r7,8192
  CMP r8,r7
  JMP[GT] @npi_bad
  LD r9,r5,#NP_K_PRESS
  MOVI r7,100
  CMP r9,r7
  JMP[GT] @npi_bad
  ; nb = dim/32, stride = align8(4 + 2*dim + 14*nb)
  SHR r7,r6,5
  SHL r10,r6,1
  MOVI r11,14
  MUL r11,r11,r7
  ADD r10,r10,r11
  MOVI r11,#NP_HDR
  ADD r10,r10,r11
  ADDI r10,r10,7
  LA r11,0xFFFFFFF8
  BOOL.8 r10,r10,r11
  ; block bytes = tokens_per_block * stride * 4 <= 2 MiB
  MUL r11,r8,r10
  SHL r11,r11,2
  LA r12,#NP_BLOCK_BYTES
  CMP r11,r12
  JMP[GT] @npi_bad
  ; capacity = table cap * tokens/block
  MUL r11,r4,r8
  CMP r11,r0
  JMP[EQ] @npi_bad

  ; zero the 24-word context
  LD r1,r0,#NP_TP+0
  MOVI r2,24
  MOVI r3,0
npi_zc:
  CMP r3,r2
  JMP[GE] @npi_zcd
  ADD r4,r1,r3
  ST r0,r4,0
  ADD r3,r3,r13
  JMP @npi_zc
npi_zcd:
  ; zero the table: tabcap * 16 words
  LD r1,r0,#NP_TP+2
  LD r2,r0,#NP_TP+3
  SHL r2,r2,4
  MOVI r3,0
npi_zt:
  CMP r3,r2
  JMP[GE] @npi_ztd
  ADD r4,r1,r3
  ST r0,r4,0
  ADD r3,r3,r13
  JMP @npi_zt
npi_ztd:

  LD r1,r0,#NP_TP+0
  LA r2,#NP_MAGIC
  ST r2,r1,#NP_C_MAGIC
  MOVI r2,#NP_VERSION
  ST r2,r1,#NP_C_VERSION
  LD r3,r0,#NP_TP+4
  LD r2,r3,#NP_K_AGENT
  ST r2,r1,#NP_C_AGENT
  LD r2,r3,#NP_K_GEN
  CMP r2,r0
  JMP[NE] @npi_g
  MOVI r2,1
npi_g:
  ST r2,r1,#NP_C_KVGEN
  LD r2,r0,#NP_TP+1
  ST r2,r1,#NP_C_HEAP
  LD r2,r0,#NP_TP+2
  ST r2,r1,#NP_C_TAB
  LD r2,r0,#NP_TP+3
  ST r2,r1,#NP_C_TABCAP
  LD r2,r3,#NP_K_BLOCKTOK
  ST r2,r1,#NP_C_BLOCKTOK
  LD r2,r3,#NP_K_DIM
  ST r2,r1,#NP_C_DIM
  SHR r2,r2,5
  ST r2,r1,#NP_C_NB
  LD r2,r3,#NP_K_DIM
  SHL r2,r2,1
  LD r4,r1,#NP_C_NB
  MOVI r5,14
  MUL r5,r5,r4
  ADD r2,r2,r5
  MOVI r5,#NP_HDR
  ADD r2,r2,r5
  ADDI r2,r2,7
  LA r5,0xFFFFFFF8
  BOOL.8 r2,r2,r5
  ST r2,r1,#NP_C_STRIDE
  ST r0,r1,#NP_C_USED
  LD r2,r0,#NP_TP+3
  LD r3,r1,#NP_C_BLOCKTOK
  MUL r2,r2,r3
  ST r2,r1,#NP_C_CAP
  ST r0,r1,#NP_C_LIVE
  ST r0,r1,#NP_C_ALLOCS
  ST r0,r1,#NP_C_EVICTS
  ST r0,r1,#NP_C_REMAPS
  ST r0,r1,#NP_C_FLAG
  LD r2,r0,#NP_TP+4
  LD r2,r2,#NP_K_PRESS
  ST r2,r1,#NP_C_PRESS
  LD r2,r0,#NP_TP+4
  LD r2,r2,#NP_K_NODE
  ST r2,r1,#NP_C_NODE
  MOVI r1,0
  JMP @npi_out
npi_bad:
  LA r1,0xFFFFFFFF
npi_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; np_set_pressure: r1=ctx r2=used -> percent; updates flag.
np_set_pressure:
  LA r3,#NP_PR
  ST r1,r3,0
  ST r2,r3,1
  LD r4,r1,#NP_C_PRESS
  ST r4,r3,2
  MOVI r4,100
  MUL r2,r2,r4
  LD r4,r1,#NP_C_CAP
  DIVU r2,r2,r4
  ST r2,r1,#NP_C_PRESSV
  LD r4,r0,#NP_PR+2
  CMP r2,r4
  JMP[LT] @npsp_low
  MOVI r3,1
  ST r3,r1,#NP_C_FLAG
  JMP @npsp_done
npsp_low:
  ST r0,r1,#NP_C_FLAG
npsp_done:
  ADD r1,r2,r0
  RET

; ---------------------------------------------------------------------------
; npaged_append: r1=ctx r2=x r3=position r4=nattn cfg -> token or -1
npaged_append:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r5,#NP_AP
  ST r1,r5,0
  ST r2,r5,1
  ST r3,r5,2
  ST r4,r5,3
  CMP r2,r0
  JMP[EQ] @npa_bad
  LD r1,r0,#NP_AP+0
  LD r2,r0,#NP_AP+3
  CALL @np_cfgcheck
  CMP r1,r0
  JMP[NE] @npa_bad
  LD r1,r0,#NP_AP+0
  LD r2,r1,#NP_C_USED
  LD r3,r1,#NP_C_CAP
  CMP r2,r3
  JMP[GE] @npa_bad
  ST r2,r0,#NP_AP+4          ; token = used
  ; block / slot
  LD r3,r1,#NP_C_BLOCKTOK
  DIVU r4,r2,r3
  MODU r5,r2,r3
  ST r4,r0,#NP_AP+5
  ST r5,r0,#NP_AP+6
  LD r1,r0,#NP_AP+0
  LD r2,r0,#NP_AP+5
  CALL @np_entry
  CMP r1,r0
  JMP[EQ] @npa_bad
  ST r1,r0,#NP_AP+7
  LD r2,r1,#NP_E_STATE
  CMP r2,r0
  JMP[NE] @npa_have
  LD r1,r0,#NP_AP+0
  LD r2,r0,#NP_AP+5
  CALL @np_alloc_block
  CMP r1,r0
  JMP[EQ] @npa_bad
  ST r1,r0,#NP_AP+7
npa_have:
  ; rec = base word + slot*stride
  LD r1,r0,#NP_AP+7
  LD r2,r1,#NP_E_BASE
  SHR r2,r2,2
  LD r3,r1,#NP_E_BASE+1
  SHL r3,r3,30
  ADD r2,r2,r3
  LD r3,r0,#NP_AP+6
  LD r4,r0,#NP_AP+0
  LD r4,r4,#NP_C_STRIDE
  MUL r3,r3,r4
  ADD r2,r2,r3
  ST r2,r0,#NP_AP+8          ; record ptr

  ; q = Wq*x
  LD r1,r0,#NP_AP+3
  LD r1,r1,5
  LD r2,r0,#NP_AP+0
  LD r2,r2,#NP_C_DIM
  ADD r3,r2,r0
  LD r4,r0,#NP_AP+1
  LA r5,#NP_Q
  CALL @nattn_matvec_q4
  CMP r1,r0
  JMP[NE] @npa_bad
  ; optional RoPE
  LD r1,r0,#NP_AP+3
  LD r1,r1,4
  MOVI r2,1
  BOOL.8 r1,r1,r2
  CMP r1,r0
  JMP[EQ] @npa_qrope
  LA r1,#NP_Q
  LD r2,r0,#NP_AP+3
  LD r2,r2,9
  CMP r2,r0
  JMP[EQ] @npa_bad
  LD r3,r0,#NP_AP+2
  LD r4,r0,#NP_AP+0
  LD r4,r4,#NP_C_DIM
  SHR r4,r4,1
  CALL @nattn_rope
  CMP r1,r0
  JMP[NE] @npa_bad
npa_qrope:
  ; q4 dst = rec + HDR + 2*dim; nattn_quant_q4 r1=src r2=dst r3=cols r4=scale
  LD r1,r0,#NP_AP+8
  MOVI r2,#NP_HDR
  ADD r1,r1,r2
  LD r2,r0,#NP_AP+0
  LD r3,r2,#NP_C_DIM
  ADD r1,r1,r3
  ADD r1,r1,r3
  ADD r4,r1,r0
  LA r1,#NP_Q
  LD r3,r0,#NP_AP+0
  LD r3,r3,#NP_C_DIM
  LD r5,r0,#NP_AP+3
  LD r5,r5,15
  ADD r2,r4,r0
  ADD r4,r5,r0
  CALL @nattn_quant_q4
  CMP r1,r0
  JMP[NE] @npa_bad

  ; k = Wk*x
  LD r1,r0,#NP_AP+3
  LD r1,r1,6
  LD r2,r0,#NP_AP+0
  LD r2,r2,#NP_C_DIM
  ADD r3,r2,r0
  LD r4,r0,#NP_AP+1
  LA r5,#NP_K
  CALL @nattn_matvec_q8
  CMP r1,r0
  JMP[NE] @npa_bad
  LD r1,r0,#NP_AP+3
  LD r1,r1,4
  MOVI r2,1
  BOOL.8 r1,r1,r2
  CMP r1,r0
  JMP[EQ] @npa_krope
  LA r1,#NP_K
  LD r2,r0,#NP_AP+3
  LD r2,r2,9
  LD r3,r0,#NP_AP+2
  LD r4,r0,#NP_AP+0
  LD r4,r4,#NP_C_DIM
  SHR r4,r4,1
  CALL @nattn_rope
  CMP r1,r0
  JMP[NE] @npa_bad
npa_krope:
  ; q8 dst = rec + HDR + 2*dim + nb*5
  LD r1,r0,#NP_AP+8
  MOVI r2,#NP_HDR
  ADD r1,r1,r2
  LD r2,r0,#NP_AP+0
  LD r3,r2,#NP_C_DIM
  SHL r4,r3,1
  ADD r1,r1,r4
  LD r4,r2,#NP_C_NB
  MOVI r5,5
  MUL r4,r4,r5
  ADD r1,r1,r4
  ADD r2,r1,r0
  LA r1,#NP_K
  LD r3,r0,#NP_AP+0
  LD r3,r3,#NP_C_DIM
  LD r4,r0,#NP_AP+3
  LD r4,r4,16
  CALL @nattn_quant_q8
  CMP r1,r0
  JMP[NE] @npa_bad

  ; v = Wv*x -> rec + HDR + dim
  LD r1,r0,#NP_AP+3
  LD r1,r1,7
  LD r2,r0,#NP_AP+0
  LD r2,r2,#NP_C_DIM
  ADD r3,r2,r0
  LD r4,r0,#NP_AP+1
  LD r5,r0,#NP_AP+8
  MOVI r6,#NP_HDR
  ADD r5,r5,r6
  ADD r5,r5,r2
  CALL @nattn_matvec_q4
  CMP r1,r0
  JMP[NE] @npa_bad

  ; copy x[dim]
  LD r6,r0,#NP_AP+8
  MOVI r7,#NP_HDR
  ADD r6,r6,r7
  LD r7,r0,#NP_AP+1
  LD r8,r0,#NP_AP+0
  LD r8,r8,#NP_C_DIM
  MOVI r9,0
npa_cx:
  CMP r9,r8
  JMP[GE] @npa_cxd
  ADD r1,r7,r9
  LD r1,r1,0
  ADD r2,r6,r9
  ST r1,r2,0
  ADD r9,r9,r13
  JMP @npa_cx
npa_cxd:
  ; record header
  LD r1,r0,#NP_AP+8
  LA r2,#NP_REC_MAGIC
  ST r2,r1,0
  LD r3,r0,#NP_AP+7
  LD r3,r3,#NP_E_GEN
  ST r3,r1,1
  LD r3,r0,#NP_AP+4
  ST r3,r1,2
  MOVI r3,1
  ST r3,r1,3

  ; block used += 1, ctx used += 1
  LD r1,r0,#NP_AP+7
  LD r2,r1,#NP_E_USED
  ADD r2,r2,r13
  ST r2,r1,#NP_E_USED
  LD r1,r0,#NP_AP+0
  LD r2,r0,#NP_AP+4
  ADD r2,r2,r13
  ST r2,r1,#NP_C_USED
  ADD r1,r1,r0
  ADD r2,r2,r0
  CALL @np_set_pressure
  LD r1,r0,#NP_AP+4
  JMP @npa_out
npa_bad:
  LA r1,0xFFFFFFFF
npa_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; npaged_prefill: r1=ctx r2=xs r3=count r4=position0 r5=cfg r6=logits
;                 -> last token or -1
npaged_prefill:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r7,#NP_TP+8
  ST r1,r7,0
  ST r2,r7,1
  ST r3,r7,2
  ST r4,r7,3
  ST r5,r7,4
  ST r6,r7,5
  CMP r3,r0
  JMP[LE] @npf_bad
  CMP r2,r0
  JMP[EQ] @npf_bad
  MOVI r8,0
  ST r8,r0,#NP_TP+8+6
npf_l:
  LD r8,r0,#NP_TP+8+6
  LD r9,r0,#NP_TP+8+2
  CMP r8,r9
  JMP[GE] @npf_d
  ; xptr = xs + i*dim
  LD r1,r0,#NP_TP+8+0
  LD r1,r1,#NP_C_DIM
  MUL r2,r8,r1
  LD r1,r0,#NP_TP+8+1
  ADD r2,r1,r2
  ; pos = position0 + i
  LD r3,r0,#NP_TP+8+3
  ADD r3,r3,r8
  LD r1,r0,#NP_TP+8+0
  LD r4,r0,#NP_TP+8+4
  CALL @npaged_append
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @npf_bad
  ST r1,r0,#NP_TP+8+7
  LD r8,r0,#NP_TP+8+6
  ADD r8,r8,r13
  ST r8,r0,#NP_TP+8+6
  JMP @npf_l
npf_d:
  LD r1,r0,#NP_TP+8+0
  LD r2,r0,#NP_TP+8+7
  LD r3,r0,#NP_TP+8+4
  LD r4,r0,#NP_TP+8+5
  CALL @npaged_attention
  CMP r1,r0
  JMP[NE] @npf_bad
  LD r1,r0,#NP_TP+8+7
  JMP @npf_out
npf_bad:
  LA r1,0xFFFFFFFF
npf_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; npaged_decode: r1=ctx r2=x r3=position r4=cfg r5=logits -> token or -1
npaged_decode:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r6,#NP_TP+16
  ST r1,r6,0
  ST r2,r6,1
  ST r3,r6,2
  ST r4,r6,3
  ST r5,r6,4
  CALL @npaged_append
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @npd_bad
  ST r1,r0,#NP_TP+16+5
  LD r1,r0,#NP_TP+16+0
  LD r2,r0,#NP_TP+16+5
  LD r3,r0,#NP_TP+16+3
  LD r4,r0,#NP_TP+16+4
  CALL @npaged_attention
  CMP r1,r0
  JMP[NE] @npd_bad
  LD r1,r0,#NP_TP+16+5
  JMP @npd_out
npd_bad:
  LA r1,0xFFFFFFFF
npd_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; npaged_attention: r1=ctx r2=token r3=cfg r4=logits -> 0/-1
npaged_attention:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r5,#NP_A
  ST r1,r5,0
  ST r2,r5,1
  ST r3,r5,2
  ST r4,r5,3
  LD r1,r0,#NP_A+0
  LD r2,r0,#NP_A+2
  CALL @np_cfgcheck
  CMP r1,r0
  JMP[NE] @npat_bad
  LD r1,r0,#NP_A+2
  LD r2,r1,8
  CMP r2,r0
  JMP[EQ] @npat_bad
  LD r2,r1,11
  CMP r2,r0
  JMP[EQ] @npat_bad
  LD r1,r0,#NP_A+0
  LD r2,r0,#NP_A+1
  LD r3,r1,#NP_C_USED
  CMP r2,r3
  JMP[GE] @npat_bad
  MOVI r3,#NP_MAXSC
  CMP r2,r3
  JMP[GE] @npat_bad

  ; rec_t via a paged view
  LD r1,r0,#NP_A+0
  LD r2,r0,#NP_A+1
  LA r3,#NP_VW
  CALL @np_record_view
  CMP r1,r0
  JMP[EQ] @npat_bad
  ST r1,r0,#NP_A+4
  ; q4_t = rec_t + HDR + 2*dim
  LD r1,r0,#NP_A+4
  MOVI r2,#NP_HDR
  ADD r1,r1,r2
  LD r2,r0,#NP_A+0
  LD r2,r2,#NP_C_DIM
  SHL r3,r2,1
  ADD r1,r1,r3
  ST r1,r0,#NP_A+5

  ; scores for s = 0..token
  MOVI r1,0
  ST r1,r0,#NP_A+6
npat_sc:
  LD r1,r0,#NP_A+6
  LD r2,r0,#NP_A+1
  CMP r1,r2
  JMP[GT] @npat_scd
  LD r1,r0,#NP_A+0
  LD r2,r0,#NP_A+6
  LA r3,#NP_VW
  CALL @np_record_view
  CMP r1,r0
  JMP[EQ] @npat_bad
  MOVI r2,#NP_HDR
  ADD r1,r1,r2
  LD r2,r0,#NP_A+0
  LD r2,r2,#NP_C_DIM
  SHL r3,r2,1
  ADD r1,r1,r3
  LD r2,r0,#NP_A+0
  LD r2,r2,#NP_C_NB
  MOVI r3,5
  MUL r2,r2,r3
  ADD r1,r1,r2
  ; q8_s in r2
  ADD r2,r1,r0
  LD r1,r0,#NP_A+5
  LD r3,r0,#NP_A+0
  LD r3,r3,#NP_C_NB
  CALL @nattn_qk_fused
  LD r2,r0,#NP_A+2
  LD r2,r2,10
  FMUL r1,r1,r2
  LA r2,#NP_SC
  LD r3,r0,#NP_A+6
  ADD r2,r2,r3
  ST r1,r2,0
  LD r1,r0,#NP_A+6
  ADD r1,r1,r13
  ST r1,r0,#NP_A+6
  JMP @npat_sc
npat_scd:
  LA r1,#NP_SC
  LD r2,r0,#NP_A+1
  ADD r2,r2,r13
  LA r3,#NP_SC
  CALL @np_softmax
  CMP r1,r0
  JMP[NE] @npat_bad

  ; zero ctx vector
  LA r1,#NP_CTX
  LD r2,r0,#NP_A+0
  LD r2,r2,#NP_C_DIM
  MOVI r3,0
npat_z:
  CMP r3,r2
  JMP[GE] @npat_zd
  ADD r4,r1,r3
  ST r0,r4,0
  ADD r3,r3,r13
  JMP @npat_z
npat_zd:
  MOVI r1,0
  ST r1,r0,#NP_A+6
npat_as:
  LD r1,r0,#NP_A+6
  LD r2,r0,#NP_A+1
  CMP r1,r2
  JMP[GT] @npat_asd
  LD r1,r0,#NP_A+0
  LD r2,r0,#NP_A+6
  LA r3,#NP_VW
  CALL @np_record_view
  CMP r1,r0
  JMP[EQ] @npat_bad
  MOVI r2,#NP_HDR
  ADD r1,r1,r2
  LD r2,r0,#NP_A+0
  LD r2,r2,#NP_C_DIM
  ADD r1,r1,r2
  ST r1,r0,#NP_A+7          ; v ptr
  LA r1,#NP_SC
  LD r2,r0,#NP_A+6
  ADD r1,r1,r2
  LD r1,r1,0
  ST r1,r0,#NP_A+8          ; w
  MOVI r2,0
npat_ad:
  LD r3,r0,#NP_A+0
  LD r3,r3,#NP_C_DIM
  CMP r2,r3
  JMP[GE] @npat_add
  LD r4,r0,#NP_A+7
  ADD r4,r4,r2
  LD r4,r4,0
  LD r5,r0,#NP_A+8
  FMUL r4,r4,r5
  LA r5,#NP_CTX
  ADD r5,r5,r2
  LD r6,r5,0
  FADD r6,r6,r4
  ST r6,r5,0
  ADD r2,r2,r13
  JMP @npat_ad
npat_add:
  LD r1,r0,#NP_A+6
  ADD r1,r1,r13
  ST r1,r0,#NP_A+6
  JMP @npat_as
npat_asd:
  ; h = x_t + ctx
  LD r6,r0,#NP_A+4
  MOVI r7,#NP_HDR
  ADD r6,r6,r7
  MOVI r2,0
npat_h:
  LD r3,r0,#NP_A+0
  LD r3,r3,#NP_C_DIM
  CMP r2,r3
  JMP[GE] @npat_hd
  ADD r4,r6,r2
  LD r4,r4,0
  LA r5,#NP_CTX
  ADD r5,r5,r2
  LD r5,r5,0
  FADD r4,r4,r5
  LA r5,#NP_H
  ADD r5,r5,r2
  ST r4,r5,0
  ADD r2,r2,r13
  JMP @npat_h
npat_hd:
  LA r1,#NP_H
  LD r2,r0,#NP_A+2
  LD r2,r2,11
  LD r3,r0,#NP_A+0
  LD r3,r3,#NP_C_DIM
  LD r4,r0,#NP_A+2
  LD r4,r4,12
  LA r5,#NP_RMS
  CALL @nat_rmsnorm
  CMP r1,r0
  JMP[NE] @npat_bad
  LD r1,r0,#NP_A+2
  LD r1,r1,8
  LD r2,r0,#NP_A+0
  LD r2,r2,#NP_C_DIM
  ADD r3,r2,r0
  LA r4,#NP_RMS
  LD r5,r0,#NP_A+3
  CALL @nattn_matvec_q4
  CMP r1,r0
  JMP[NE] @npat_bad
  MOVI r1,0
  JMP @npat_out
npat_bad:
  LA r1,0xFFFFFFFF
npat_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; npaged_remap: r1=ctx r2=block -> new generation or 0
npaged_remap:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r3,#NP_TP+24
  ST r1,r3,0
  ST r2,r3,1
  CALL @np_entry
  CMP r1,r0
  JMP[EQ] @npm_bad
  ST r1,r0,#NP_TP+24+2
  LD r2,r1,#NP_E_STATE
  MOVI r3,1
  CMP r2,r3
  JMP[NE] @npm_bad
  LD r2,r1,#NP_E_USED
  CMP r2,r0
  JMP[EQ] @npm_bad
  ST r2,r0,#NP_TP+24+3
  ; new page
  LD r1,r0,#NP_TP+24+0
  CALL @np_pagenew
  CMP r1,r0
  JMP[NE] @npm_bad
  ; new generation
  LD r1,r0,#NP_TP+24+0
  LD r2,r1,#NP_C_GEN
  ADD r2,r2,r13
  CMP r2,r0
  JMP[NE] @npm_gen
  MOVI r2,1
npm_gen:
  ST r2,r1,#NP_C_GEN
  ST r2,r0,#NP_TP+24+4
  ; copy used records
  LD r3,r0,#NP_TP+24+2
  LD r4,r3,#NP_E_BASE
  SHR r4,r4,2
  LD r5,r3,#NP_E_BASE+1
  SHL r5,r5,30
  ADD r4,r4,r5
  ST r4,r0,#NP_TP+24+5      ; old word base
  LD r4,r0,#NP_P+0
  SHR r4,r4,2
  LD r5,r0,#NP_P+1
  SHL r5,r5,30
  ADD r4,r4,r5
  ST r4,r0,#NP_TP+24+6      ; new word base
  LD r5,r0,#NP_TP+24+3
  LD r6,r0,#NP_TP+24+0
  LD r6,r6,#NP_C_STRIDE
  MUL r5,r5,r6
  ST r5,r0,#NP_TP+24+7      ; words to copy
  MOVI r6,0
npm_cp:
  CMP r6,r5
  JMP[GE] @npm_cpd
  LD r7,r0,#NP_TP+24+5
  ADD r7,r7,r6
  LD r7,r7,0
  LD r8,r0,#NP_TP+24+6
  ADD r8,r8,r6
  ST r7,r8,0
  ADD r6,r6,r13
  JMP @npm_cp
npm_cpd:
  ; rewrite generation in each copied record header
  LD r6,r0,#NP_TP+24+6
  MOVI r7,0
npm_hd:
  LD r8,r0,#NP_TP+24+3
  CMP r7,r8
  JMP[GE] @npm_hdd
  ADD r8,r6,r0
  LD r9,r0,#NP_TP+24+4
  ADD r8,r8,r13
  ST r9,r8,0
  LD r9,r0,#NP_TP+24+0
  LD r9,r9,#NP_C_STRIDE
  ADD r6,r6,r9
  ADD r7,r7,r13
  JMP @npm_hd
npm_hdd:
  ; release the old storage cap and return the page to nheap
  LD r1,r0,#NP_TP+24+2
  LD r1,r1,#NP_E_CAP
  CALL @nobj_release
  LD r1,r0,#NP_TP+24+0
  LD r1,r1,#NP_C_HEAP
  LD r2,r0,#NP_TP+24+0
  LD r2,r2,#NP_C_NODE
  MOVI r3,1
  LD r4,r0,#NP_TP+24+2
  LD r4,r4,#NP_E_BASE
  LD r5,r0,#NP_TP+24+2
  LD r5,r5,#NP_E_BASE+1
  MOVI r6,1
  MOVI r7,0
  CALL @nheap_free
  ; update entry
  LD r1,r0,#NP_TP+24+2
  LD r2,r0,#NP_P+0
  ST r2,r1,#NP_E_BASE
  LD r2,r0,#NP_P+1
  ST r2,r1,#NP_E_BASE+1
  LD r2,r0,#NP_P+2
  ST r2,r1,#NP_E_CAP
  LD r2,r0,#NP_TP+24+4
  ST r2,r1,#NP_E_GEN
  LD r1,r0,#NP_TP+24+0
  LD r2,r1,#NP_C_REMAPS
  ADD r2,r2,r13
  ST r2,r1,#NP_C_REMAPS
  LD r1,r0,#NP_TP+24+4
  JMP @npm_out
npm_bad:
  MOVI r1,0
npm_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; npaged_evict_last: r1=ctx -> 0/-1
npaged_evict_last:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r2,#NP_TP+32
  ST r1,r2,0
  LD r2,r1,#NP_C_USED
  CMP r2,r0
  JMP[EQ] @npel_bad
  ; block = (used-1)/tokens_per_block
  ADDI r2,r2,-1
  LD r3,r1,#NP_C_BLOCKTOK
  DIVU r2,r2,r3
  ST r2,r0,#NP_TP+32+1
  CALL @np_entry
  CMP r1,r0
  JMP[EQ] @npel_bad
  ST r1,r0,#NP_TP+32+2
  LD r2,r1,#NP_E_USED
  CMP r2,r0
  JMP[EQ] @npel_bad
  ST r2,r0,#NP_TP+32+3
  ; release cap, free page
  LD r1,r1,#NP_E_CAP
  CALL @nobj_release
  LD r1,r0,#NP_TP+32+0
  LD r1,r1,#NP_C_HEAP
  LD r2,r0,#NP_TP+32+0
  LD r2,r2,#NP_C_NODE
  MOVI r3,1
  LD r4,r0,#NP_TP+32+2
  LD r4,r4,#NP_E_BASE
  LD r5,r0,#NP_TP+32+2
  LD r5,r5,#NP_E_BASE+1
  MOVI r6,1
  MOVI r7,0
  CALL @nheap_free
  LD r1,r0,#NP_TP+32+2
  ST r0,r1,#NP_E_STATE
  ST r0,r1,#NP_E_USED
  LD r1,r0,#NP_TP+32+0
  LD r2,r1,#NP_C_LIVE
  SUB r2,r2,r13
  ST r2,r1,#NP_C_LIVE
  LD r2,r1,#NP_C_EVICTS
  ADD r2,r2,r13
  ST r2,r1,#NP_C_EVICTS
  LD r2,r1,#NP_C_USED
  LD r3,r0,#NP_TP+32+3
  SUB r2,r2,r3
  ST r2,r1,#NP_C_USED
  ADD r1,r1,r0
  CALL @np_set_pressure
  MOVI r1,0
  JMP @npel_out
npel_bad:
  LA r1,0xFFFFFFFF
npel_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; npaged_trim: r1=ctx r2=count -> 0/-1
; Truncate the live token space to count <= used.  Every live block strictly
; above the target block is released to nheap (cap released first, evicts
; incremented).  If count is inside a block and that block loses records, the
; context generation is bumped, the block entry generation is repointed and
; the retained record headers are rewritten.  A previously resolved view or
; token generation therefore fails closed, while logical indices below count
; keep resolving and the copied record payload (x/v/q4/q8) is untouched.
npaged_trim:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r3,#NP_TP+48
  ST r1,r3,0
  ST r2,r3,1
  LD r4,r1,#NP_C_MAGIC
  LA r5,#NP_MAGIC
  CMP r4,r5
  JMP[NE] @npt_bad
  LD r4,r1,#NP_C_VERSION
  MOVI r5,#NP_VERSION
  CMP r4,r5
  JMP[NE] @npt_bad
  LD r4,r1,#NP_C_USED
  CMP r2,r4
  JMP[GT] @npt_bad
  CMP r2,r0
  JMP[LT] @npt_bad
  CMP r2,r4
  JMP[EQ] @npt_ok

  ; target block and first block to free
  MOVI r5,0
  ST r5,r0,#NP_TP+48+3      ; target valid flag
  ST r5,r0,#NP_TP+48+4      ; first free block
  CMP r2,r0
  JMP[EQ] @npt_tgt_done
  ADDI r4,r2,-1
  LD r5,r1,#NP_C_BLOCKTOK
  DIVU r5,r4,r5
  ST r5,r0,#NP_TP+48+2      ; target block
  MOVI r6,1
  ST r6,r0,#NP_TP+48+3
  ADD r6,r5,r13
  ST r6,r0,#NP_TP+48+4
npt_tgt_done:

  ; free live blocks from tabcap-1 down to first_free
  LD r5,r1,#NP_C_TABCAP
  ADDI r5,r5,-1
  ST r5,r0,#NP_TP+48+5      ; block cursor
npt_free_l:
  LD r5,r0,#NP_TP+48+5
  LD r6,r0,#NP_TP+48+4
  CMP r5,r6
  JMP[LT] @npt_free_d
  LD r1,r0,#NP_TP+48+0
  ADD r2,r5,r0
  CALL @np_entry
  CMP r1,r0
  JMP[EQ] @npt_free_n
  ST r1,r0,#NP_TP+48+6      ; entry
  LD r2,r1,#NP_E_STATE
  CMP r2,r0
  JMP[EQ] @npt_free_n
  LD r1,r1,#NP_E_CAP
  CALL @nobj_release
  LD r1,r0,#NP_TP+48+0
  LD r1,r1,#NP_C_HEAP
  LD r2,r0,#NP_TP+48+0
  LD r2,r2,#NP_C_NODE
  MOVI r3,1
  LD r4,r0,#NP_TP+48+6
  LD r4,r4,#NP_E_BASE
  LD r5,r0,#NP_TP+48+6
  LD r5,r5,#NP_E_BASE+1
  MOVI r6,1
  MOVI r7,0
  CALL @nheap_free
  LD r1,r0,#NP_TP+48+6
  ST r0,r1,#NP_E_STATE
  ST r0,r1,#NP_E_USED
  ST r0,r1,#NP_E_CAP
  ST r0,r1,#NP_E_GEN
  LD r1,r0,#NP_TP+48+0
  LD r2,r1,#NP_C_LIVE
  SUB r2,r2,r13
  ST r2,r1,#NP_C_LIVE
  LD r2,r1,#NP_C_EVICTS
  ADD r2,r2,r13
  ST r2,r1,#NP_C_EVICTS
npt_free_n:
  LD r5,r0,#NP_TP+48+5
  CMP r5,r0
  JMP[EQ] @npt_free_d
  ADDI r5,r5,-1
  ST r5,r0,#NP_TP+48+5
  JMP @npt_free_l
npt_free_d:

  ; trim the target block (if count > 0)
  LD r5,r0,#NP_TP+48+3
  CMP r5,r0
  JMP[EQ] @npt_setused
  LD r1,r0,#NP_TP+48+0
  LD r2,r0,#NP_TP+48+2
  CALL @np_entry
  CMP r1,r0
  JMP[EQ] @npt_bad
  ST r1,r0,#NP_TP+48+6
  ; keep = count - target*blocktok
  LD r2,r0,#NP_TP+48+1
  LD r3,r0,#NP_TP+48+0
  LD r3,r3,#NP_C_BLOCKTOK
  LD r4,r0,#NP_TP+48+2
  MUL r4,r4,r3
  SUB r2,r2,r4
  ST r2,r0,#NP_TP+48+7      ; keep
  LD r3,r1,#NP_E_USED
  CMP r2,r3
  JMP[GE] @npt_setblock
  ; bump the context generation and the target block generation
  LD r1,r0,#NP_TP+48+0
  LD r2,r1,#NP_C_GEN
  ADD r2,r2,r13
  CMP r2,r0
  JMP[NE] @npt_gen
  MOVI r2,1
npt_gen:
  ST r2,r1,#NP_C_GEN
  LD r1,r0,#NP_TP+48+6
  ST r2,r1,#NP_E_GEN
  ; rewrite generation word in each retained record
  LD r2,r1,#NP_E_BASE
  SHR r2,r2,2
  LD r3,r1,#NP_E_BASE+1
  SHL r3,r3,30
  ADD r2,r2,r3
  ST r2,r0,#NP_TP+48+8      ; record word base
  ST r0,r0,#NP_TP+48+9      ; slot
npt_hd:
  LD r3,r0,#NP_TP+48+9
  LD r4,r0,#NP_TP+48+7
  CMP r3,r4
  JMP[GE] @npt_hdd
  LD r5,r0,#NP_TP+48+0
  LD r5,r5,#NP_C_STRIDE
  MUL r6,r3,r5
  LD r7,r0,#NP_TP+48+8
  ADD r7,r7,r6
  ADD r7,r7,r13
  LD r8,r0,#NP_TP+48+6
  LD r8,r8,#NP_E_GEN
  ST r8,r7,0
  LD r3,r0,#NP_TP+48+9
  ADD r3,r3,r13
  ST r3,r0,#NP_TP+48+9
  JMP @npt_hd
npt_hdd:
npt_setblock:
  LD r1,r0,#NP_TP+48+6
  LD r2,r0,#NP_TP+48+7
  ST r2,r1,#NP_E_USED

npt_setused:
  LD r1,r0,#NP_TP+48+0
  LD r2,r0,#NP_TP+48+1
  ST r2,r1,#NP_C_USED
  ADD r1,r1,r0
  CALL @np_set_pressure
npt_ok:
  MOVI r1,0
  JMP @npt_out
npt_bad:
  LA r1,0xFFFFFFFF
npt_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; npaged_token_word: r1=ctx r2=token -> record word address or 0
npaged_token_word:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @np_record
  ADD r1,r1,r0
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; npaged_token_gen: r1=ctx r2=token -> generation or 0
npaged_token_gen:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @np_record
  CMP r1,r0
  JMP[EQ] @nptg_zero
  ADD r1,r2,r0
  JMP @nptg_out
nptg_zero:
  MOVI r1,0
nptg_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; npaged_check: r1=ctx r2=token r3=generation -> 1/0
npaged_check:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r3,r0,#NP_TP+40
  CALL @np_record
  CMP r1,r0
  JMP[EQ] @nptc_no
  LD r3,r0,#NP_TP+40
  CMP r2,r3
  JMP[NE] @nptc_no
  MOVI r1,1
  JMP @nptc_out
nptc_no:
  MOVI r1,0
nptc_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; npaged_pressure: r1=ctx -> percent or -1
npaged_pressure:
  ST r15,r14,0
  ADD r14,r14,r13
  LD r2,r1,#NP_C_MAGIC
  LA r3,#NP_MAGIC
  CMP r2,r3
  JMP[NE] @nppr_bad
  LD r2,r1,#NP_C_USED
  CALL @np_set_pressure
  JMP @nppr_out
nppr_bad:
  LA r1,0xFFFFFFFF
nppr_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; npaged_remaining: r1=ctx -> free token slots or -1
npaged_remaining:
  LD r2,r1,#NP_C_MAGIC
  LA r3,#NP_MAGIC
  CMP r2,r3
  JMP[NE] @nprem_bad
  LD r2,r1,#NP_C_CAP
  LD r3,r1,#NP_C_USED
  SUB r1,r2,r3
  RET
nprem_bad:
  LA r1,0xFFFFFFFF
  RET

; ---------------------------------------------------------------------------
; npaged_stats: r1=ctx r2=out(16) -> 0/-1
npaged_stats:
  LD r3,r1,#NP_C_MAGIC
  LA r4,#NP_MAGIC
  CMP r3,r4
  JMP[NE] @npst_bad
  LD r3,r1,#NP_C_USED
  ST r3,r2,0
  LD r3,r1,#NP_C_CAP
  ST r3,r2,1
  LD r3,r1,#NP_C_LIVE
  ST r3,r2,2
  LD r3,r1,#NP_C_ALLOCS
  ST r3,r2,3
  LD r3,r1,#NP_C_EVICTS
  ST r3,r2,4
  LD r3,r1,#NP_C_REMAPS
  ST r3,r2,5
  LD r3,r1,#NP_C_GEN
  ST r3,r2,6
  LD r3,r1,#NP_C_PRESSV
  ST r3,r2,7
  LD r3,r1,#NP_C_AGENT
  ST r3,r2,8
  LD r3,r1,#NP_C_BLOCKTOK
  ST r3,r2,9
  LD r3,r1,#NP_C_DIM
  ST r3,r2,10
  LD r3,r1,#NP_C_STRIDE
  ST r3,r2,11
  LD r3,r1,#NP_C_NODE
  ST r3,r2,12
  LD r3,r1,#NP_C_FLAG
  ST r3,r2,13
  LD r3,r1,#NP_C_TABCAP
  ST r3,r2,14
  LD r3,r1,#NP_C_PRESS
  ST r3,r2,15
  MOVI r1,0
  RET
npst_bad:
  LA r1,0xFFFFFFFF
  RET

