; nkv.nas - 64-bit tensor views and per-agent KV slabs (F6).
;
; Pure NaN.  A view is metadata only: it shares a storage capability and
; records a 64-bit byte offset, a byte size, shape/strides and an element
; count.  No storage bytes are copied or renumbered, so a view may cross
; 4 GiB and a 2 TiB capability is normal.  A KV slab owns one
; nmem-compatible class-20 storage capability allocated from nheap, plus a
; 64-bit block table mapping logical token ranges to byte offsets.
;
; Storage capability contract (identical to nmem.nas):
;   class 20, 8-word payload
;   +0 base_lo +1 base_hi +2 size_lo +3 size_hi
;   +4 rights  +5 node    +6 flags   +7 class(20)
; nkv embeds small create/info helpers instead of including nmem.nas because
; both nmem.nas and nheap.nas inline n64.nas and nmk has no include guard.
;
; Tensor view (24 words, caller supplied):
;   +0 magic 0x4E4B5657 ("NKVW")  +1 version 1
;   +2 dtype (0 u8, 1 f16, 2 f32) +3 rank (1..3) +4 flags
;   +5 storage cap
;   +6 off_lo +7 off_hi            view byte offset inside storage
;   +8 size_lo +9 size_hi          view byte length
;   +10 count_lo +11 count_hi      product of shape[]
;   +12..15 shape[0..3]
;   +16..21 stride[0..2] as (lo,hi) byte strides
;   +22 generation (0 for a plain view, slab KV generation for a token view)
;   +23 owner cap  (0 for a plain view, slab cap for a token view)
;
; KV slab (class 21, 24-word payload):
;   +0 magic 0x4E4B5653 ("NKVS")  +1 version 1
;   +2 agent id                    +3 KV generation
;   +4 node                        +5 dtype
;   +6 layers +7 heads +8 dim
;   +9 bytes/token lo +10 hi
;   +11 capacity tokens            +12 used tokens
;   +13 block_tokens               +14 block_count +15 block_cap
;   +16 block table word address
;   +17 base storage cap
;   +18 base_off_lo +19 base_off_hi
;   +20 alloc bytes lo +21 hi
;   +22 page class (0 4K, 1 2M, 2 1G)
;   +23 flags
;
; Block table entry (8 words):
;   +0 token_start +1 token_count +2 off_lo +3 off_hi +4 flags +5..7 reserved
; A token address is base_cap.base + base_off + block.off
;   + (token - block.token_start) * bytes_per_token.
;
; nkv_create_cfg: caller fills 16 words:
;   +0 agent +1 generation +2 node +3 dtype +4 layers +5 heads +6 dim
;   +7 bytes/token lo +8 hi +9 capacity tokens +10 block_tokens
;   +11 page class +12 pages lo +13 pages hi +14 flags +15 reserved
;
; API:
;   nkv_storage_create r1=base_lo r2=base_hi r3=size_lo r4=size_hi
;                   r5=rights r6=node -> storage cap or 0
;   nkv_storage_info r1=cap r2=out(8) -> 0/-1
;   nkv_view_create r1=storage cap r2=off_lo r3=off_hi r4=size_lo
;                   r5=size_hi r6=dtype r7=rank r8=shape ptr
;                   r9=out view -> 0/-1
;   nkv_view_addr   r1=view r2=index_lo r3=index_hi
;                   -> r1=addr_lo r2=addr_hi r3=0/-1
;   nkv_slab_create r1=cfg r2=nheap ctx r3=block table r4=block cap
;                   -> slab cap or 0
;   nkv_slab_info   r1=slab cap r2=out(24) -> 0/-1
;   nkv_slab_append r1=slab cap -> token index or -1
;   nkv_slab_append_n r1=slab cap r2=count -> first token or -1
;   nkv_slab_used     r1=slab cap -> used tokens or -1
;   nkv_slab_capacity r1=slab cap -> capacity tokens or -1
;   nkv_slab_regen  r1=slab cap -> new KV generation or 0
;   nkv_slab_token_off r1=slab cap r2=token
;                   -> r1=off_lo r2=off_hi r3=len_lo r4=len_hi r5=0/-1
;   nkv_slab_token_addr r1=slab cap r2=token
;                   -> r1=addr_lo r2=addr_hi r3=len_lo r4=len_hi r5=0/-1
;   nkv_slab_read_token r1=slab cap r2=token r3=out(8) -> 0/-1
;                   out: addr_lo,addr_hi,len_lo,len_hi,base_cap,
;                        generation,agent,dtype
;   nkv_slab_token_view r1=slab cap r2=token r3=out view -> 0/-1
;   nkv_view_check  r1=view r2=slab cap -> 1 if owner and generation match
;
; Caller must call nobj_init and nheap_init (with its own descriptor pool)
; before creating caps.  The soft stack (r14) grows up, r13 must be 1,
; r0 must be 0.

.include "nanobj.nas"
.include "nheap.nas"

.equ NKV_VIEW_MAGIC   0x4E4B5657
.equ NKV_SLAB_MAGIC   0x4E4B5653
.equ NKV_VERSION      1
.equ NKV_CLASS_STOR   20
.equ NKV_CLASS_SLAB   21

; tensor view fields
.equ NKV_V_MAGIC      0
.equ NKV_V_VERSION    1
.equ NKV_V_DTYPE      2
.equ NKV_V_RANK       3
.equ NKV_V_FLAGS      4
.equ NKV_V_STOR       5
.equ NKV_V_OFF        6
.equ NKV_V_SIZE       8
.equ NKV_V_COUNT      10
.equ NKV_V_SHAPE      12
.equ NKV_V_STRIDE     16
.equ NKV_V_GEN        22
.equ NKV_V_OWNER      23

; slab fields
.equ NKV_S_MAGIC      0
.equ NKV_S_VERSION    1
.equ NKV_S_AGENT      2
.equ NKV_S_GEN        3
.equ NKV_S_NODE       4
.equ NKV_S_DTYPE      5
.equ NKV_S_LAYERS     6
.equ NKV_S_HEADS      7
.equ NKV_S_DIM        8
.equ NKV_S_BPT        9
.equ NKV_S_CAPACITY   11
.equ NKV_S_USED       12
.equ NKV_S_BLOCKTOK   13
.equ NKV_S_NBLOCKS    14
.equ NKV_S_BLOCKCAP   15
.equ NKV_S_BLOCKTAB   16
.equ NKV_S_BASECAP    17
.equ NKV_S_BASEOFF    18
.equ NKV_S_ALLOC      20
.equ NKV_S_PAGECLASS  22
.equ NKV_S_FLAGS      23

; config fields
.equ NKV_C_AGENT      0
.equ NKV_C_GEN        1
.equ NKV_C_NODE       2
.equ NKV_C_DTYPE      3
.equ NKV_C_LAYERS     4
.equ NKV_C_HEADS      5
.equ NKV_C_DIM        6
.equ NKV_C_BPT        7
.equ NKV_C_CAPACITY   9
.equ NKV_C_BLOCKTOK   10
.equ NKV_C_PAGECLASS  11
.equ NKV_C_PAGES      12
.equ NKV_C_FLAGS      14

; Scratch.  All are below 0x7800 (nheap) and 0x9000 (test data).
.equ NKW  0x5000              ; view create/addr (128 words)
.equ NKI  0x5040              ; tiny storage helpers (64 words)
.equ NKS  0x5080              ; slab create (128 words)
.equ NKT  0x5100              ; token paths (128 words)

; ---------------------------------------------------------------------------
; r1=dtype -> r1=elem bytes (0 invalid)
nk_elem:
  CMP r1,r0
  JMP[EQ] @nk_e_1
  MOVI r2,1
  CMP r1,r2
  JMP[EQ] @nk_e_2
  MOVI r2,2
  CMP r1,r2
  JMP[EQ] @nk_e_4
  MOVI r1,0
  RET
nk_e_1:
  MOVI r1,1
  RET
nk_e_2:
  MOVI r1,2
  RET
nk_e_4:
  MOVI r1,4
  RET

; r1=page class -> r1=bytes
nk_pagesize:
  CMP r1,r0
  JMP[EQ] @nk_ps_4k
  MOVI r2,1
  CMP r1,r2
  JMP[EQ] @nk_ps_2m
  LA r1,0x40000000
  RET
nk_ps_2m:
  LA r1,0x200000
  RET
nk_ps_4k:
  MOVI r1,0x1000
  RET

; ---------------------------------------------------------------------------
; nk_storage_create: r1=base_lo r2=base_hi r3=size_lo r4=size_hi
;                    r5=rights r6=node -> class-20 cap or 0
nk_storage_create:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r7,#NKI+0
  ST r1,r7,0
  ST r2,r7,1
  ST r3,r7,2
  ST r4,r7,3
  ST r5,r7,4
  ST r6,r7,5
  ST r0,r7,6
  MOVI r1,#NKV_CLASS_STOR
  ST r1,r7,7
  MOVI r1,#NKV_CLASS_STOR
  MOVI r2,8
  CALL @nobj_create
  CMP r1,r0
  JMP[EQ] @nk_sc_fail
  ST r1,r0,#NKI+8
  ADD r1,r1,r0
  LA r2,#NKI+0
  MOVI r3,0
  MOVI r4,8
  CALL @nobj_write
  MOVI r5,8
  CMP r1,r5
  JMP[NE] @nk_sc_bad
  LD r1,r0,#NKI+8
  JMP @nk_sc_out
nk_sc_bad:
  LD r1,r0,#NKI+8
  CALL @nobj_release
nk_sc_fail:
  MOVI r1,0
nk_sc_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nk_storage_info: r1=cap r2=out(8) -> 0/-1
nk_storage_info:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NKI+9
  ST r2,r0,#NKI+34
  MOVI r2,#NOBJ_R_READ
  CALL @nobj_check
  CMP r1,r0
  JMP[EQ] @nk_si_fail
  LD r2,r1,3
  MOVI r3,#NKV_CLASS_STOR
  CMP r2,r3
  JMP[NE] @nk_si_fail
  LD r1,r0,#NKI+9
  LD r2,r0,#NKI+34
  MOVI r3,0
  MOVI r4,8
  CALL @nobj_read
  MOVI r5,8
  CMP r1,r5
  JMP[NE] @nk_si_fail
  MOVI r1,0
  JMP @nk_si_out
nk_si_fail:
  LA r1,0xFFFFFFFF
nk_si_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; Public storage-cap helpers (same class-20 contract as nmem.nas).
nkv_storage_create:
  JMP @nk_storage_create

nkv_storage_info:
  JMP @nk_storage_info

; ---------------------------------------------------------------------------
; nkv_view_create: r1=cap r2=off_lo r3=off_hi r4=size_lo r5=size_hi
;                  r6=dtype r7=rank r8=shape r9=out -> 0/-1
nkv_view_create:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NKW+0
  ST r2,r0,#NKW+1
  ST r3,r0,#NKW+2
  ST r4,r0,#NKW+3
  ST r5,r0,#NKW+4
  ST r6,r0,#NKW+5
  ST r7,r0,#NKW+6
  ST r8,r0,#NKW+7
  ST r9,r0,#NKW+8

  LD r1,r0,#NKW+6
  CMP r1,r0
  JMP[EQ] @nkv_vc_fail
  MOVI r2,3
  CMP r1,r2
  JMP[GT] @nkv_vc_fail
  LD r1,r0,#NKW+5
  CALL @nk_elem
  CMP r1,r0
  JMP[EQ] @nkv_vc_fail
  ST r1,r0,#NKW+9

  LD r1,r0,#NKW+3
  LD r2,r0,#NKW+4
  CMP r1,r0
  JMP[NE] @nkv_vc_sz
  CMP r2,r0
  JMP[EQ] @nkv_vc_fail
nkv_vc_sz:
  LD r1,r0,#NKW+0
  LA r2,#NKW+20
  CALL @nk_storage_info
  CMP r1,r0
  JMP[NE] @nkv_vc_fail

  ; end = off + size <= storage size
  LD r1,r0,#NKW+1
  LD r2,r0,#NKW+2
  LD r3,r0,#NKW+3
  LD r4,r0,#NKW+4
  CALL @n64_add
  LD r3,r0,#NKW+22
  LD r4,r0,#NKW+23
  CALL @n64_cmp
  CMP r1,r0
  JMP[EQ] @nkv_vc_bounds
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[NE] @nkv_vc_fail
nkv_vc_bounds:

  ; zero 24 output words
  LD r1,r0,#NKW+8
  MOVI r2,24
nkv_vc_zero:
  CMP r2,r0
  JMP[EQ] @nkv_vc_meta
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nkv_vc_zero

nkv_vc_meta:
  LD r4,r0,#NKW+8
  LA r1,#NKV_VIEW_MAGIC
  ST r1,r4,0
  MOVI r1,#NKV_VERSION
  ST r1,r4,1
  LD r1,r0,#NKW+5
  ST r1,r4,2
  LD r2,r0,#NKW+6
  ST r2,r4,3
  ST r0,r4,4
  LD r1,r0,#NKW+0
  ST r1,r4,5
  LD r1,r0,#NKW+1
  ST r1,r4,6
  LD r1,r0,#NKW+2
  ST r1,r4,7
  LD r1,r0,#NKW+3
  ST r1,r4,8
  LD r1,r0,#NKW+4
  ST r1,r4,9
  ST r0,r4,#NKV_V_GEN
  ST r0,r4,#NKV_V_OWNER

  ; copy shape[0..rank-1]
  MOVI r2,0
  LD r3,r0,#NKW+7
nkv_vc_shape:
  LD r5,r0,#NKW+6
  CMP r2,r5
  JMP[GE] @nkv_vc_strides
  LD r6,r3,0
  LD r5,r0,#NKW+8
  ADD r5,r5,r2
  ST r6,r5,#NKV_V_SHAPE
  ADD r3,r3,r13
  ADD r2,r2,r13
  JMP @nkv_vc_shape

  ; strides from the last axis backwards
nkv_vc_strides:
  LD r1,r0,#NKW+9
  ST r1,r0,#NKW+11
  ST r0,r0,#NKW+12
  LD r1,r0,#NKW+6
  SUB r1,r1,r13
  ST r1,r0,#NKW+10
nkv_vc_stride:
  LD r2,r0,#NKW+10
  LD r4,r0,#NKW+8
  SHL r5,r2,1
  ADD r5,r5,r4
  LD r1,r0,#NKW+11
  ST r1,r5,#NKV_V_STRIDE
  LD r1,r0,#NKW+12
  ST r1,r5,#NKV_V_STRIDE+1
  CMP r2,r0
  JMP[EQ] @nkv_vc_count
  ; accum *= shape[i+1]
  LD r3,r0,#NKW+7
  ADD r5,r2,r13
  ADD r3,r3,r5
  LD r6,r3,0
  ADD r1,r6,r0
  LD r2,r0,#NKW+11
  LD r3,r0,#NKW+12
  CALL @n64_mul32
  ST r1,r0,#NKW+11
  ST r2,r0,#NKW+12
  LD r2,r0,#NKW+10
  SUB r2,r2,r13
  ST r2,r0,#NKW+10
  JMP @nkv_vc_stride

  ; count = product(shape[0..rank-1])
nkv_vc_count:
  MOVI r1,1
  ST r1,r0,#NKW+11
  ST r0,r0,#NKW+12
  MOVI r1,0
  ST r1,r0,#NKW+10
nkv_vc_count_l:
  LD r2,r0,#NKW+10
  LD r5,r0,#NKW+6
  CMP r2,r5
  JMP[GE] @nkv_vc_count_d
  LD r3,r0,#NKW+7
  ADD r3,r3,r2
  LD r6,r3,0
  ADD r1,r6,r0
  LD r2,r0,#NKW+11
  LD r3,r0,#NKW+12
  CALL @n64_mul32
  ST r1,r0,#NKW+11
  ST r2,r0,#NKW+12
  LD r2,r0,#NKW+10
  ADD r2,r2,r13
  ST r2,r0,#NKW+10
  JMP @nkv_vc_count_l
nkv_vc_count_d:
  LD r1,r0,#NKW+11
  LD r2,r0,#NKW+12
  CMP r1,r0
  JMP[NE] @nkv_vc_cnt_ok
  CMP r2,r0
  JMP[EQ] @nkv_vc_fail
nkv_vc_cnt_ok:
  LD r4,r0,#NKW+8
  LD r1,r0,#NKW+11
  ST r1,r4,#NKV_V_COUNT
  LD r1,r0,#NKW+12
  ST r1,r4,#NKV_V_COUNT+1

  ; count * elem <= size
  LD r1,r0,#NKW+9
  LD r2,r0,#NKW+11
  LD r3,r0,#NKW+12
  CALL @n64_mul32
  LD r3,r0,#NKW+3
  LD r4,r0,#NKW+4
  CALL @n64_cmp
  CMP r1,r0
  JMP[EQ] @nkv_vc_ok
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[NE] @nkv_vc_fail
nkv_vc_ok:
  MOVI r1,0
  JMP @nkv_vc_out
nkv_vc_fail:
  LA r1,0xFFFFFFFF
nkv_vc_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkv_view_addr: r1=view r2=index_lo r3=index_hi
;                -> r1=addr_lo r2=addr_hi r3=0/-1
nkv_view_addr:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NKW+0
  ST r2,r0,#NKW+1
  ST r3,r0,#NKW+2
  LD r4,r1,0
  LA r5,#NKV_VIEW_MAGIC
  CMP r4,r5
  JMP[NE] @nkv_va_fail
  LD r4,r1,1
  MOVI r5,#NKV_VERSION
  CMP r4,r5
  JMP[NE] @nkv_va_fail
  LD r1,r0,#NKW+0
  LD r1,r1,#NKV_V_DTYPE
  CALL @nk_elem
  CMP r1,r0
  JMP[EQ] @nkv_va_fail
  ST r1,r0,#NKW+3

  ; index must be < count
  LD r1,r0,#NKW+1
  LD r2,r0,#NKW+2
  LD r4,r0,#NKW+0
  LD r3,r4,#NKV_V_COUNT
  LD r4,r4,#NKV_V_COUNT+1
  CALL @n64_cmp
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[NE] @nkv_va_fail

  LD r1,r0,#NKW+3
  LD r2,r0,#NKW+1
  LD r3,r0,#NKW+2
  CALL @n64_mul32
  LD r3,r0,#NKW+0
  LD r3,r3,#NKV_V_OFF
  LD r4,r0,#NKW+0
  LD r4,r4,#NKV_V_OFF+1
  CALL @n64_add
  ST r1,r0,#NKW+4
  ST r2,r0,#NKW+5

  LD r1,r0,#NKW+0
  LD r1,r1,#NKV_V_STOR
  LA r2,#NKI+0
  CALL @nk_storage_info
  CMP r1,r0
  JMP[NE] @nkv_va_fail
  LD r1,r0,#NKW+4
  LD r2,r0,#NKW+5
  LD r3,r0,#NKI+0
  LD r4,r0,#NKI+1
  CALL @n64_add
  MOVI r3,0
  JMP @nkv_va_out
nkv_va_fail:
  MOVI r1,0
  MOVI r2,0
  LA r3,0xFFFFFFFF
nkv_va_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkv_slab_create: r1=cfg r2=nheap ctx r3=block table r4=block cap
;                  -> slab cap or 0
nkv_slab_create:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NKS+0
  ST r2,r0,#NKS+1
  ST r3,r0,#NKS+2
  ST r4,r0,#NKS+3

  ; config validation
  LD r1,r0,#NKS+0
  LD r2,r1,#NKV_C_BPT
  LD r3,r1,#NKV_C_BPT+1
  CMP r2,r0
  JMP[NE] @nkv_sc_bpt
  CMP r3,r0
  JMP[EQ] @nkv_sc_fail
nkv_sc_bpt:
  LD r2,r1,#NKV_C_CAPACITY
  CMP r2,r0
  JMP[EQ] @nkv_sc_fail
  LD r2,r1,#NKV_C_LAYERS
  CMP r2,r0
  JMP[EQ] @nkv_sc_fail
  LD r2,r1,#NKV_C_HEADS
  CMP r2,r0
  JMP[EQ] @nkv_sc_fail
  LD r2,r1,#NKV_C_DIM
  CMP r2,r0
  JMP[EQ] @nkv_sc_fail
  LD r2,r1,#NKV_C_BLOCKTOK
  CMP r2,r0
  JMP[EQ] @nkv_sc_fail
  LD r2,r1,#NKV_C_PAGECLASS
  MOVI r3,2
  CMP r2,r3
  JMP[GT] @nkv_sc_fail
  LD r2,r1,#NKV_C_PAGES
  LD r3,r1,#NKV_C_PAGES+1
  CMP r2,r0
  JMP[NE] @nkv_sc_pages
  CMP r3,r0
  JMP[EQ] @nkv_sc_fail
nkv_sc_pages:
  LD r2,r0,#NKS+2
  CMP r2,r0
  JMP[EQ] @nkv_sc_fail
  LD r2,r0,#NKS+3
  CMP r2,r0
  JMP[EQ] @nkv_sc_fail

  ; alloc_bytes = page_size * pages
  LD r1,r0,#NKS+0
  LD r1,r1,#NKV_C_PAGECLASS
  CALL @nk_pagesize
  ST r1,r0,#NKS+6
  LD r1,r0,#NKS+6
  LD r2,r0,#NKS+0
  LD r2,r2,#NKV_C_PAGES
  LD r3,r0,#NKS+0
  LD r3,r3,#NKV_C_PAGES+1
  CALL @n64_mul32
  ST r1,r0,#NKS+7
  ST r2,r0,#NKS+8

  ; needed = capacity * bytes/token
  LD r1,r0,#NKS+0
  LD r1,r1,#NKV_C_CAPACITY
  LD r2,r0,#NKS+0
  LD r2,r2,#NKV_C_BPT
  LD r3,r0,#NKS+0
  LD r3,r3,#NKV_C_BPT+1
  CALL @n64_mul32
  ST r1,r0,#NKS+9
  ST r2,r0,#NKS+10
  LD r3,r0,#NKS+7
  LD r4,r0,#NKS+8
  CALL @n64_cmp
  CMP r1,r0
  JMP[EQ] @nkv_sc_fit
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[NE] @nkv_sc_fail
nkv_sc_fit:

  ; blocks = ceil(capacity / block_tokens)
  LD r1,r0,#NKS+0
  LD r1,r1,#NKV_C_CAPACITY
  LD r2,r0,#NKS+0
  LD r2,r2,#NKV_C_BLOCKTOK
  DIVU r3,r1,r2
  MODU r4,r1,r2
  CMP r4,r0
  JMP[EQ] @nkv_sc_noblk
  ADD r3,r3,r13
nkv_sc_noblk:
  ST r3,r0,#NKS+13
  LD r5,r0,#NKS+3
  CMP r3,r5
  JMP[GT] @nkv_sc_fail

  ; allocate backing pages from nheap
  LD r1,r0,#NKS+1
  LD r2,r0,#NKS+0
  LD r2,r2,#NKV_C_NODE
  LD r3,r0,#NKS+0
  LD r3,r3,#NKV_C_PAGECLASS
  LD r4,r0,#NKS+0
  LD r4,r4,#NKV_C_PAGES
  LD r5,r0,#NKS+0
  LD r5,r5,#NKV_C_PAGES+1
  LA r6,#NKS+4
  CALL @nheap_alloc
  CMP r1,r0
  JMP[NE] @nkv_sc_fail

  ; storage capability over the whole allocation
  LD r1,r0,#NKS+4
  LD r2,r0,#NKS+5
  LD r3,r0,#NKS+7
  LD r4,r0,#NKS+8
  MOVI r5,3
  LD r6,r0,#NKS+0
  LD r6,r6,#NKV_C_NODE
  CALL @nk_storage_create
  CMP r1,r0
  JMP[EQ] @nkv_sc_fail
  ST r1,r0,#NKS+11

  ; payload
  LA r7,#NKS+32
  LA r1,#NKV_SLAB_MAGIC
  ST r1,r7,#NKV_S_MAGIC
  MOVI r1,#NKV_VERSION
  ST r1,r7,#NKV_S_VERSION
  LD r2,r0,#NKS+0
  LD r1,r2,#NKV_C_AGENT
  ST r1,r7,#NKV_S_AGENT
  LD r1,r2,#NKV_C_GEN
  ST r1,r7,#NKV_S_GEN
  LD r1,r2,#NKV_C_NODE
  ST r1,r7,#NKV_S_NODE
  LD r1,r2,#NKV_C_DTYPE
  ST r1,r7,#NKV_S_DTYPE
  LD r1,r2,#NKV_C_LAYERS
  ST r1,r7,#NKV_S_LAYERS
  LD r1,r2,#NKV_C_HEADS
  ST r1,r7,#NKV_S_HEADS
  LD r1,r2,#NKV_C_DIM
  ST r1,r7,#NKV_S_DIM
  LD r1,r2,#NKV_C_BPT
  ST r1,r7,#NKV_S_BPT
  LD r1,r2,#NKV_C_BPT+1
  ST r1,r7,#NKV_S_BPT+1
  LD r1,r2,#NKV_C_CAPACITY
  ST r1,r7,#NKV_S_CAPACITY
  ST r0,r7,#NKV_S_USED
  LD r1,r2,#NKV_C_BLOCKTOK
  ST r1,r7,#NKV_S_BLOCKTOK
  LD r1,r0,#NKS+13
  ST r1,r7,#NKV_S_NBLOCKS
  LD r1,r0,#NKS+3
  ST r1,r7,#NKV_S_BLOCKCAP
  LD r1,r0,#NKS+2
  ST r1,r7,#NKV_S_BLOCKTAB
  LD r1,r0,#NKS+11
  ST r1,r7,#NKV_S_BASECAP
  ST r0,r7,#NKV_S_BASEOFF
  ST r0,r7,#NKV_S_BASEOFF+1
  LD r1,r0,#NKS+7
  ST r1,r7,#NKV_S_ALLOC
  LD r1,r0,#NKS+8
  ST r1,r7,#NKV_S_ALLOC+1
  LD r1,r2,#NKV_C_PAGECLASS
  ST r1,r7,#NKV_S_PAGECLASS
  LD r1,r2,#NKV_C_FLAGS
  ST r1,r7,#NKV_S_FLAGS

  ; block table: one entry per block_tokens, 64-bit running byte offset
  ST r0,r0,#NKS+14
  ST r0,r0,#NKS+15
  ST r0,r0,#NKS+16
  ST r0,r0,#NKS+17
nkv_sc_blk:
  LD r1,r0,#NKS+14
  LD r2,r0,#NKS+13
  CMP r1,r2
  JMP[GE] @nkv_sc_blk_d
  LD r1,r0,#NKS+0
  LD r1,r1,#NKV_C_CAPACITY
  LD r2,r0,#NKS+15
  SUB r1,r1,r2
  ST r1,r0,#NKS+18
  LD r2,r0,#NKS+0
  LD r2,r2,#NKV_C_BLOCKTOK
  ST r2,r0,#NKS+19
  LD r3,r0,#NKS+18
  CMP r3,r2
  JMP[GE] @nkv_sc_cnt
  ST r3,r0,#NKS+19
nkv_sc_cnt:
  LD r4,r0,#NKS+14
  SHL r4,r4,3
  LD r5,r0,#NKS+2
  ADD r5,r5,r4
  ST r5,r0,#NKS+20
  LD r6,r0,#NKS+15
  ST r6,r5,0
  LD r6,r0,#NKS+19
  ST r6,r5,1
  LD r6,r0,#NKS+16
  ST r6,r5,2
  LD r6,r0,#NKS+17
  ST r6,r5,3
  ST r0,r5,4
  ST r0,r5,5
  ST r0,r5,6
  ST r0,r5,7
  ; offset += count * bytes/token
  LD r1,r0,#NKS+19
  LD r2,r0,#NKS+0
  LD r2,r2,#NKV_C_BPT
  LD r3,r0,#NKS+0
  LD r3,r3,#NKV_C_BPT+1
  CALL @n64_mul32
  LD r3,r0,#NKS+16
  LD r4,r0,#NKS+17
  CALL @n64_add
  ST r1,r0,#NKS+16
  ST r2,r0,#NKS+17
  LD r1,r0,#NKS+15
  LD r2,r0,#NKS+19
  ADD r1,r1,r2
  ST r1,r0,#NKS+15
  LD r1,r0,#NKS+14
  ADD r1,r1,r13
  ST r1,r0,#NKS+14
  JMP @nkv_sc_blk
nkv_sc_blk_d:

  ; create the slab capability
  MOVI r1,#NKV_CLASS_SLAB
  MOVI r2,24
  CALL @nobj_create
  CMP r1,r0
  JMP[EQ] @nkv_sc_fail
  ST r1,r0,#NKS+12
  ADD r1,r1,r0
  LA r2,#NKS+32
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_write
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @nkv_sc_bad
  LD r1,r0,#NKS+12
  JMP @nkv_sc_out
nkv_sc_bad:
  LD r1,r0,#NKS+12
  CALL @nobj_release
nkv_sc_fail:
  MOVI r1,0
nkv_sc_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkv_slab_info: r1=cap r2=out(24) -> 0/-1
nkv_slab_info:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NKI+36
  ST r2,r0,#NKI+37
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_read
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @nkv_si_fail
  LD r1,r0,#NKI+37
  LD r2,r1,#NKV_S_MAGIC
  LA r3,#NKV_SLAB_MAGIC
  CMP r2,r3
  JMP[NE] @nkv_si_fail
  MOVI r1,0
  JMP @nkv_si_out
nkv_si_fail:
  LA r1,0xFFFFFFFF
nkv_si_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nkv_slab_used r1=cap -> used or -1
nkv_slab_used:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r2,#NKI+10
  CALL @nkv_slab_info
  CMP r1,r0
  JMP[NE] @nkv_su_fail
  LA r1,#NKI+10
  LD r1,r1,#NKV_S_USED
  JMP @nkv_su_out
nkv_su_fail:
  LA r1,0xFFFFFFFF
nkv_su_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nkv_slab_capacity r1=cap -> capacity or -1
nkv_slab_capacity:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r2,#NKI+10
  CALL @nkv_slab_info
  CMP r1,r0
  JMP[NE] @nkv_sq_fail
  LA r1,#NKI+10
  LD r1,r1,#NKV_S_CAPACITY
  JMP @nkv_sq_out
nkv_sq_fail:
  LA r1,0xFFFFFFFF
nkv_sq_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nkv_slab_append r1=cap -> token index or -1
nkv_slab_append:
  MOVI r2,1
  JMP @nkv_slab_append_n

; nkv_slab_append_n r1=cap r2=count -> first token or -1
nkv_slab_append_n:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NKT+0
  ST r2,r0,#NKT+1
  CMP r2,r0
  JMP[EQ] @nkv_ap_fail
  LD r1,r0,#NKT+0
  LA r2,#NKT+16
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_read
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @nkv_ap_fail
  LA r6,#NKT+16
  LD r1,r6,#NKV_S_MAGIC
  LA r2,#NKV_SLAB_MAGIC
  CMP r1,r2
  JMP[NE] @nkv_ap_fail
  LD r1,r6,#NKV_S_USED
  LD r2,r6,#NKV_S_CAPACITY
  CMP r1,r2
  JMP[GE] @nkv_ap_fail
  SUB r3,r2,r1
  LD r4,r0,#NKT+1
  CMP r4,r3
  JMP[GT] @nkv_ap_fail
  ST r1,r0,#NKT+2
  ADD r3,r1,r4
  ST r3,r6,#NKV_S_USED
  LD r1,r0,#NKT+0
  ADD r2,r6,r0
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_write
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @nkv_ap_fail
  LD r1,r0,#NKT+2
  JMP @nkv_ap_out
nkv_ap_fail:
  LA r1,0xFFFFFFFF
nkv_ap_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nkv_slab_regen r1=cap -> new generation or 0
nkv_slab_regen:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NKI+9
  LA r2,#NKI+40
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_read
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @nkv_rg_fail
  LA r6,#NKI+40
  LD r1,r6,#NKV_S_MAGIC
  LA r2,#NKV_SLAB_MAGIC
  CMP r1,r2
  JMP[NE] @nkv_rg_fail
  LD r1,r6,#NKV_S_GEN
  ADD r1,r1,r13
  CMP r1,r0
  JMP[NE] @nkv_rg_gen
  MOVI r1,1
nkv_rg_gen:
  ST r1,r6,#NKV_S_GEN
  ST r1,r0,#NKI+36
  LD r1,r0,#NKI+9
  LA r2,#NKI+40
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_write
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @nkv_rg_fail
  LD r1,r0,#NKI+36
  JMP @nkv_rg_out
nkv_rg_fail:
  MOVI r1,0
nkv_rg_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nkv_slab_find_block: r1=payload r2=token
;                      -> r1=block index r2=entry ptr r3=rel, or r1=-1
nkv_slab_find_block:
  LD r3,r1,#NKV_S_NBLOCKS
  LD r4,r1,#NKV_S_BLOCKTAB
  MOVI r5,0
nkv_fb_loop:
  CMP r5,r3
  JMP[GE] @nkv_fb_fail
  SHL r6,r5,3
  ADD r6,r4,r6
  LD r7,r6,0
  CMP r2,r7
  JMP[LT] @nkv_fb_next
  LD r8,r6,1
  ADD r9,r7,r8
  CMP r2,r9
  JMP[GE] @nkv_fb_next
  SUB r3,r2,r7
  ADD r2,r6,r0
  ADD r1,r5,r0
  RET
nkv_fb_next:
  ADD r5,r5,r13
  JMP @nkv_fb_loop
nkv_fb_fail:
  LA r1,0xFFFFFFFF
  RET

; nkv_slab_token_off: r1=cap r2=token
;    -> r1=off_lo r2=off_hi r3=len_lo r4=len_hi r5=0/-1
nkv_slab_token_off:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NKT+0
  ST r2,r0,#NKT+1
  LD r1,r0,#NKT+0
  LA r2,#NKT+16
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_read
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @nkv_to_fail
  LA r6,#NKT+16
  LD r1,r6,#NKV_S_MAGIC
  LA r2,#NKV_SLAB_MAGIC
  CMP r1,r2
  JMP[NE] @nkv_to_fail
  LD r2,r0,#NKT+1
  LD r3,r6,#NKV_S_USED
  CMP r2,r3
  JMP[GE] @nkv_to_fail
  ADD r1,r6,r0
  CALL @nkv_slab_find_block
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nkv_to_fail
  ST r2,r0,#NKT+2
  ST r3,r0,#NKT+3

  ; delta = rel * bytes/token
  LD r1,r0,#NKT+3
  LA r2,#NKT+16
  LD r2,r2,#NKV_S_BPT
  LA r3,#NKT+16
  LD r3,r3,#NKV_S_BPT+1
  CALL @n64_mul32
  ST r1,r0,#NKT+4
  ST r2,r0,#NKT+5

  ; base_off + block.off
  LA r1,#NKT+16
  LD r1,r1,#NKV_S_BASEOFF
  LA r2,#NKT+16
  LD r2,r2,#NKV_S_BASEOFF+1
  LD r3,r0,#NKT+2
  LD r3,r3,2
  LD r4,r0,#NKT+2
  LD r4,r4,3
  CALL @n64_add
  LD r3,r0,#NKT+4
  LD r4,r0,#NKT+5
  CALL @n64_add
  ST r1,r0,#NKT+6
  ST r2,r0,#NKT+7

  LA r1,#NKT+16
  LD r1,r1,#NKV_S_BPT
  ST r1,r0,#NKT+8
  LA r1,#NKT+16
  LD r1,r1,#NKV_S_BPT+1
  ST r1,r0,#NKT+9
  LD r1,r0,#NKT+6
  LD r2,r0,#NKT+7
  LD r3,r0,#NKT+8
  LD r4,r0,#NKT+9
  MOVI r5,0
  JMP @nkv_to_out
nkv_to_fail:
  MOVI r1,0
  MOVI r2,0
  MOVI r3,0
  MOVI r4,0
  LA r5,0xFFFFFFFF
nkv_to_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nkv_slab_token_addr: r1=cap r2=token
;    -> r1=addr_lo r2=addr_hi r3=len_lo r4=len_hi r5=0/-1
nkv_slab_token_addr:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NKT+0
  ST r2,r0,#NKT+1
  LD r1,r0,#NKT+0
  LD r2,r0,#NKT+1
  CALL @nkv_slab_token_off
  CMP r5,r0
  JMP[NE] @nkv_ta_fail
  ST r1,r0,#NKT+10
  ST r2,r0,#NKT+11
  ST r3,r0,#NKT+12
  ST r4,r0,#NKT+13
  LA r1,#NKT+16
  LD r1,r1,#NKV_S_BASECAP
  LA r2,#NKI+0
  CALL @nk_storage_info
  CMP r1,r0
  JMP[NE] @nkv_ta_fail
  LD r1,r0,#NKT+10
  LD r2,r0,#NKT+11
  LD r3,r0,#NKI+0
  LD r4,r0,#NKI+1
  CALL @n64_add
  LD r3,r0,#NKT+12
  LD r4,r0,#NKT+13
  MOVI r5,0
  JMP @nkv_ta_out
nkv_ta_fail:
  MOVI r1,0
  MOVI r2,0
  MOVI r3,0
  MOVI r4,0
  LA r5,0xFFFFFFFF
nkv_ta_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nkv_slab_read_token: r1=cap r2=token r3=out(8) -> 0/-1
nkv_slab_read_token:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NKT+0
  ST r2,r0,#NKT+1
  ST r3,r0,#NKT+40
  LD r1,r0,#NKT+0
  LD r2,r0,#NKT+1
  CALL @nkv_slab_token_addr
  CMP r5,r0
  JMP[NE] @nkv_rt_fail
  ST r1,r0,#NKT+10
  ST r2,r0,#NKT+11
  ST r3,r0,#NKT+12
  ST r4,r0,#NKT+13
  LD r1,r0,#NKT+0
  LA r2,#NKT+16
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_read
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @nkv_rt_fail
  LD r1,r0,#NKT+40
  LD r2,r0,#NKT+10
  ST r2,r1,0
  LD r2,r0,#NKT+11
  ST r2,r1,1
  LD r2,r0,#NKT+12
  ST r2,r1,2
  LD r2,r0,#NKT+13
  ST r2,r1,3
  LA r2,#NKT+16
  LD r2,r2,#NKV_S_BASECAP
  ST r2,r1,4
  LA r2,#NKT+16
  LD r2,r2,#NKV_S_GEN
  ST r2,r1,5
  LA r2,#NKT+16
  LD r2,r2,#NKV_S_AGENT
  ST r2,r1,6
  LA r2,#NKT+16
  LD r2,r2,#NKV_S_DTYPE
  ST r2,r1,7
  MOVI r1,0
  JMP @nkv_rt_out
nkv_rt_fail:
  LA r1,0xFFFFFFFF
nkv_rt_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nkv_slab_token_view: r1=cap r2=token r3=out view -> 0/-1
nkv_slab_token_view:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NKT+0
  ST r2,r0,#NKT+1
  ST r3,r0,#NKT+41
  LD r1,r0,#NKT+0
  LD r2,r0,#NKT+1
  CALL @nkv_slab_token_off
  CMP r5,r0
  JMP[NE] @nkv_tv_fail
  ST r1,r0,#NKT+10
  ST r2,r0,#NKT+11
  ST r3,r0,#NKT+12
  ST r4,r0,#NKT+13
  LD r1,r0,#NKT+13
  CMP r1,r0
  JMP[NE] @nkv_tv_fail
  LD r1,r0,#NKT+0
  LA r2,#NKT+16
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_read
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @nkv_tv_fail
  LA r1,#NKT+16
  LD r1,r1,#NKV_S_DTYPE
  CALL @nk_elem
  CMP r1,r0
  JMP[EQ] @nkv_tv_fail
  ST r1,r0,#NKT+14
  LD r2,r0,#NKT+14
  LD r1,r0,#NKT+12
  DIVU r1,r1,r2
  ST r1,r0,#NKT+15
  LA r1,#NKT+16
  LD r1,r1,#NKV_S_BASECAP
  LD r2,r0,#NKT+10
  LD r3,r0,#NKT+11
  LD r4,r0,#NKT+12
  LD r5,r0,#NKT+13
  LA r6,#NKT+16
  LD r6,r6,#NKV_S_DTYPE
  MOVI r7,1
  LA r8,#NKT+15
  LD r9,r0,#NKT+41
  CALL @nkv_view_create
  CMP r1,r0
  JMP[NE] @nkv_tv_fail
  LD r2,r0,#NKT+41
  LA r1,#NKT+16
  LD r1,r1,#NKV_S_GEN
  ST r1,r2,#NKV_V_GEN
  LD r1,r0,#NKT+0
  ST r1,r2,#NKV_V_OWNER
  MOVI r1,0
  JMP @nkv_tv_out
nkv_tv_fail:
  LA r1,0xFFFFFFFF
nkv_tv_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nkv_view_check: r1=view r2=slab cap -> 1/0
nkv_view_check:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NKT+0
  ST r2,r0,#NKT+1
  LD r4,r1,#NKV_V_MAGIC
  LA r5,#NKV_VIEW_MAGIC
  CMP r4,r5
  JMP[NE] @nkv_vk_no
  LD r4,r1,#NKV_V_OWNER
  LD r5,r0,#NKT+1
  CMP r4,r5
  JMP[NE] @nkv_vk_no
  LD r1,r0,#NKT+1
  LA r2,#NKT+16
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_read
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @nkv_vk_no
  LA r1,#NKT+16
  LD r1,r1,#NKV_S_MAGIC
  LA r2,#NKV_SLAB_MAGIC
  CMP r1,r2
  JMP[NE] @nkv_vk_no
  LA r1,#NKT+16
  LD r1,r1,#NKV_S_GEN
  LD r2,r0,#NKT+0
  LD r2,r2,#NKV_V_GEN
  CMP r1,r2
  JMP[NE] @nkv_vk_no
  MOVI r1,1
  JMP @nkv_vk_out
nkv_vk_no:
  MOVI r1,0
nkv_vk_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
