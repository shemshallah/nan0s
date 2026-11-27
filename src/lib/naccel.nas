; naccel.nas - accelerator boundary: DMA rings, software device model and
; VRAM/model placement with an explicit CPU fallback (F10).
;
; This is the NaN-side policy/driver model that sits on niommu.nas.  It is an
; emulated software boundary: no PCIe, GPU, firmware or native device is
; required.  The ring storage, descriptor array, VRAM bitmap and allocation
; records are all caller supplied, so nothing hides a fixed heap.
;
; DMA ring context (24 words):
;   +0 magic "NACC" 0x4E414343  +1 version 1
;   +2 descriptor base           +3 slot count (1..64)
;   +4 issued count              +5 reaped count
;   +6 pending count             +7 IOMMU domain
;   +8 domain generation at init +9 last fence sequence
;   +10 last completed fence     +11 error count
;   +12 last error               +13 reserved
;   +14 max copy bytes           +15..23 reserved
;
; DMA descriptor (16 words):
;   +0 state 0 free 1 queued 2 done 3 error 4 cancelled
;   +1 sequence 1..              +2 src iova_lo +3 src iova_hi
;   +4 dst iova_lo +5 dst iova_hi +6 len_lo +7 len_hi
;   +8 flags                     +9 op (1 copy, 2 gemv placeholder)
;   +10 domain                   +11 domain generation snapshot
;   +12 status                   +13 fence sequence
;   +14..15 reserved
;
; Flags: bit 0 FENCE, bit 1 GEMV.  A copy reads src through the domain with R
; and writes dst with W.  The GEMV placeholder reads len bytes and writes one
; little-endian 64-bit accumulator to dst:
;
;   acc = sum over b[i] of (3*b[i] + 1)
;
; That is an exact integer MAC placeholder through mapped IOVAs, not a tensor
; kernel.  Completion is in submission order; nacc_complete stops immediately
; after reaping a FENCE descriptor, so later work cannot pass an earlier fence.
;
; VRAM context (32 words):
;   +0 magic "VRA1" 0x56524131  +1 version 1
;   +2 bar_lo +3 bar_hi         +4 size_lo +5 size_hi
;   +6 granule                  +7 total units lo +8 total units hi
;   +9 bitmap                   +10 bitmap words
;   +11 used units lo +12 used units hi
;   +13 allocs +14 frees
;   +15 VRAM placements +16 host placements
;   +17 fallback: exhausted +18 fallback: unmapped BAR
;   +19 failures +20 policy +21 last error +22..31 reserved
;
; Allocation record / placement output (8 words):
;   +0 tier 0 host 1 VRAM       +1 offset_lo +2 offset_hi
;   +3 units_lo +4 units_hi     +5 bytes_lo +6 bytes_hi
;   +7 kind (1 weight, 2 KV, 3 activation)
;
; Placement policy: weights and KV try VRAM first (policy bits 1 and 2,
; default both); activations are host-only.  A successful VRAM allocation is
; validated through the IOMMU domain for the whole BAR allocation; if the BAR
; is unmapped or the domain generation is gone, the allocation is rolled back
; and the caller gets tier=host plus an explicit fallback counter.  If VRAM is
; exhausted the caller also gets tier=host; no request is silently truncated.
;
; API:
;   nacc_ring_init r1=ctx r2=desc r3=slots r4=dom -> 0/code
;   nacc_submit r1=ctx r2=src_lo r3=src_hi r4=dst_lo r5=dst_hi
;               r6=len_lo r7=len_hi r8=flags -> sequence / 0
;               (a rejection sets NA_LASTERR and returns 0)
;   nacc_cancel r1=ctx r2=seq -> 0/code
;   nacc_complete r1=ctx -> reaped count this call
;   nacc_fence r1=ctx -> 0/code (EBUSY while the last fence is not reaped)
;   nacc_result r1=ctx r2=seq r3=out(4 words) -> 0/code
;   nacc_counters r1=ctx r2=out(5 words) -> 0/code
;   nacc_vram_init r1=ctx r2=bar_lo r3=bar_hi r4=size_lo r5=size_hi
;                  r6=granule r7=bitmap r8=bitmap_words -> 0/code
;   nacc_vram_alloc r1=ctx r2=units_lo r3=units_hi r4=out(2) -> 0/code
;   nacc_vram_free r1=ctx r2=off_lo r3=off_hi r4=units_lo r5=units_hi
;                  -> 0/code
;   nacc_vram_place r1=ctx r2=kind r3=bytes_lo r4=bytes_hi r5=dom
;                  r6=out(8) -> 1 VRAM / 2 host / 0 error
;   nacc_vram_stats r1=ctx r2=out(24) -> 0/code
;               out[0..1] used units, [2..3] free units, [4..5] used bytes,
;               [6..7] free bytes, [8..15] counters/policy, [16..19] BAR/size,
;               [20..21] total units, [22] granule, [23] bitmap words
;
; ABI: r0=0, r13=1, r14=SP (grows up), r15=link.

.include "niommu.nas"

.equ NACC_MAGIC      0x4E414343       ; "NACC"
.equ NACC_VERSION    1
.equ NACC_MAXCOPY    0x10000         ; emulated copy cap: 64 KiB
.equ NACC_MAX_SLOTS  64

; Ring context fields.
.equ NA_MAGIC        0
.equ NA_VER          1
.equ NA_DESC         2
.equ NA_SLOTS        3
.equ NA_ISSUED       4
.equ NA_DONE         5
.equ NA_PENDING      6
.equ NA_DOM          7
.equ NA_GEN          8
.equ NA_FENCE        9
.equ NA_FENCED       10
.equ NA_ERRORS       11
.equ NA_LASTERR      12
.equ NA_MAXCOPY      14

; Descriptor fields.
.equ ND_STATE        0
.equ ND_SEQ          1
.equ ND_SLO          2
.equ ND_SHI          3
.equ ND_DLO          4
.equ ND_DHI          5
.equ ND_LLO          6
.equ ND_LHI          7
.equ ND_FLAGS        8
.equ ND_OP           9
.equ ND_DOM          10
.equ ND_GEN          11
.equ ND_STATUS       12
.equ ND_FENCE        13

; Descriptor states and flags/ops.
.equ NACC_FREE       0
.equ NACC_QUEUED     1
.equ NACC_DONE       2
.equ NACC_ERROR      3
.equ NACC_CANCELLED  4
.equ NACC_F_FENCE    1
.equ NACC_F_GEMV     2
.equ NACC_OP_COPY    1
.equ NACC_OP_GEMV    2

; Codes.  The IOMMU code space (1..8) is reused on descriptors so a DMA fault
; is reported with the same exact code as the translation that caused it.
.equ NACC_OK         0
.equ NACC_EBAD       1
.equ NACC_ENOENT     2
.equ NACC_ERIGHT     3
.equ NACC_ESTALE     4
.equ NACC_EOVER      5
.equ NACC_ESPACE     6
.equ NACC_EFULL      7
.equ NACC_EALIGN     8
.equ NACC_ENOSPC     9
.equ NACC_EBUSY      10
.equ NACC_ECANCEL    11
.equ NACC_EIO        12

; VRAM context fields.
.equ NV_MAGIC        0
.equ NV_VER          1
.equ NV_BARLO        2
.equ NV_BARHI        3
.equ NV_SIZELO       4
.equ NV_SIZEHI       5
.equ NV_GRAN         6
.equ NV_UNITSLO      7
.equ NV_UNITSHI      8
.equ NV_BITMAP       9
.equ NV_BITWORDS     10
.equ NV_USEDLO       11
.equ NV_USEDHI       12
.equ NV_ALLOCS       13
.equ NV_FREES        14
.equ NV_VRAM_PLACE   15
.equ NV_HOST_PLACE   16
.equ NV_FB_EXH       17
.equ NV_FB_UNMAP     18
.equ NV_FAILS        19
.equ NV_POLICY       20
.equ NV_LAST         21

.equ NV_MAGICV       0x56524131       ; "VRA1"
.equ NV_VERSION      1
.equ NV_MAX_GRAN     0x40000000

.equ NACC_TIER_HOST  0
.equ NACC_TIER_VRAM  1
.equ NACC_KIND_WEIGHT 1
.equ NACC_KIND_KV    2
.equ NACC_KIND_ACT   3
.equ NACC_POL_WEIGHT 1
.equ NACC_POL_KV     2
.equ NACC_POL_DEFAULT 3

; ---------------------------------------------------------------------------
; nacc_valid r1=ctx -> ctx / 0.
nacc_valid:
  CMP r1,r0
  JMP[EQ] @nacc_v_none
  LD r2,r1,#NA_MAGIC
  LA r3,#NACC_MAGIC
  CMP r2,r3
  JMP[NE] @nacc_v_none
  RET
nacc_v_none:
  MOVI r1,0
  RET

; nacc_slot_addr r1=ctx r2=index -> descriptor address.
nacc_slot_addr:
  LD r3,r1,#NA_DESC
  SHL r2,r2,4
  ADD r1,r3,r2
  RET

; nacc_find r1=ctx r2=seq -> descriptor address / 0.
nacc_find:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  MOVI r3,0
  ST r3,r14,3
nacc_fd_loop:
  LD r3,r14,3
  LD r1,r14,1
  LD r4,r1,#NA_SLOTS
  CMP r3,r4
  JMP[GE] @nacc_fd_none
  LD r2,r14,3
  CALL @nacc_slot_addr
  ST r1,r14,4
  LD r2,r1,#ND_STATE
  CMP r2,r0
  JMP[EQ] @nacc_fd_next
  LD r2,r1,#ND_SEQ
  LD r3,r14,2
  CMP r2,r3
  JMP[EQ] @nacc_fd_found
nacc_fd_next:
  LD r3,r14,3
  ADDI r3,r3,1
  ST r3,r14,3
  JMP @nacc_fd_loop
nacc_fd_found:
  LD r1,r14,4
  JMP @nacc_fd_out
nacc_fd_none:
  MOVI r1,0
nacc_fd_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nacc_ring_init r1=ctx r2=desc r3=slots r4=dom -> 0/code.
nacc_ring_init:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  LD r2,r14,1
  CMP r2,r0
  JMP[EQ] @nacc_ri_bad
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @nacc_ri_bad
  LD r2,r14,3
  CMP r2,r0
  JMP[EQ] @nacc_ri_bad
  MOVI r3,#NACC_MAX_SLOTS
  CMP r2,r3
  JMP[GT] @nacc_ri_bad
  LD r1,r14,4
  CALL @niom_generation
  CMP r1,r0
  JMP[EQ] @nacc_ri_noent
  ST r1,r14,5
  ; clear descriptors: slots * 16 words
  LD r2,r14,3
  SHL r2,r2,4
  LD r1,r14,2
  BFILL r1,r0,r2
  ; clear and initialize the ring context
  LD r1,r14,1
  MOVI r2,24
  BFILL r1,r0,r2
  LD r1,r14,1
  LA r2,#NACC_MAGIC
  ST r2,r1,#NA_MAGIC
  MOVI r2,#NACC_VERSION
  ST r2,r1,#NA_VER
  LD r2,r14,2
  ST r2,r1,#NA_DESC
  LD r2,r14,3
  ST r2,r1,#NA_SLOTS
  LD r2,r14,4
  ST r2,r1,#NA_DOM
  LD r2,r14,5
  ST r2,r1,#NA_GEN
  LA r2,#NACC_MAXCOPY
  ST r2,r1,#NA_MAXCOPY
  MOVI r1,0
  JMP @nacc_ri_out
nacc_ri_bad:
  MOVI r1,#NACC_EBAD
  JMP @nacc_ri_out
nacc_ri_noent:
  MOVI r1,#NACC_ENOENT
nacc_ri_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nacc_submit r1=ctx r2=src_lo r3=src_hi r4=dst_lo r5=dst_hi
;              r6=len_lo r7=len_hi r8=flags -> seq / 0.
nacc_submit:
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
  LD r1,r14,1
  CALL @nacc_valid
  CMP r1,r0
  JMP[EQ] @nacc_sb_bad
  ; flags only bits 0..1
  LD r2,r14,8
  LA r3,0xFFFFFFFC
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @nacc_sb_bad
  ; length nonzero, high word zero, at most the emulated copy cap
  LD r2,r14,6
  LD r3,r14,7
  CMP r2,r0
  JMP[NE] @nacc_sb_lenok
  CMP r3,r0
  JMP[EQ] @nacc_sb_bad
nacc_sb_lenok:
  CMP r3,r0
  JMP[NE] @nacc_sb_over
  LD r1,r14,1
  LD r3,r1,#NA_MAXCOPY
  CMP r2,r3
  JMP[GT] @nacc_sb_over
  ; the ring's captured domain generation must still be current
  LD r1,r14,1
  LD r1,r1,#NA_DOM
  CALL @niom_generation
  CMP r1,r0
  JMP[EQ] @nacc_sb_stale
  LD r2,r14,1
  LD r2,r2,#NA_GEN
  CMP r1,r2
  JMP[NE] @nacc_sb_stale
  ; a full ring has no unreaped slot, even if the head was cancelled
  LD r4,r14,1
  LD r4,r4,#NA_PENDING
  LD r5,r14,1
  LD r5,r5,#NA_SLOTS
  CMP r4,r5
  JMP[GE] @nacc_sb_nospc
  ; next slot = issued % slots
  LD r1,r14,1
  LD r4,r1,#NA_ISSUED
  LD r5,r1,#NA_SLOTS
  MODU r3,r4,r5
  ST r3,r14,9
  LD r2,r14,9
  CALL @nacc_slot_addr
  ST r1,r14,10
  LD r2,r1,#ND_STATE
  MOVI r3,#NACC_QUEUED
  CMP r2,r3
  JMP[EQ] @nacc_sb_nospc
  ; sequence = issued + 1
  LD r2,r14,1
  LD r4,r2,#NA_ISSUED
  ADDI r4,r4,1
  ST r4,r14,11
  LD r1,r14,10
  ST r4,r1,#ND_SEQ
  ST r13,r1,#ND_STATE
  LD r3,r14,2
  ST r3,r1,#ND_SLO
  LD r3,r14,3
  ST r3,r1,#ND_SHI
  LD r3,r14,4
  ST r3,r1,#ND_DLO
  LD r3,r14,5
  ST r3,r1,#ND_DHI
  LD r3,r14,6
  ST r3,r1,#ND_LLO
  LD r3,r14,7
  ST r3,r1,#ND_LHI
  LD r3,r14,8
  ST r3,r1,#ND_FLAGS
  MOVI r5,#NACC_OP_COPY
  MOVI r3,2
  LD r4,r14,8
  BOOL.8 r4,r4,r3
  CMP r4,r0
  JMP[EQ] @nacc_sb_opok
  MOVI r5,#NACC_OP_GEMV
nacc_sb_opok:
  ST r5,r1,#ND_OP
  LD r5,r14,1
  LD r5,r5,#NA_DOM
  ST r5,r1,#ND_DOM
  LD r5,r14,1
  LD r5,r5,#NA_GEN
  ST r5,r1,#ND_GEN
  ST r0,r1,#ND_STATUS
  ST r0,r1,#ND_FENCE
  ; fence flag
  MOVI r3,1
  LD r4,r14,8
  BOOL.8 r4,r4,r3
  CMP r4,r0
  JMP[EQ] @nacc_sb_nofence
  LD r4,r14,11
  ST r4,r1,#ND_FENCE
  LD r5,r14,1
  ST r4,r5,#NA_FENCE
nacc_sb_nofence:
  LD r5,r14,1
  LD r4,r5,#NA_ISSUED
  ADDI r4,r4,1
  ST r4,r5,#NA_ISSUED
  LD r4,r5,#NA_PENDING
  ADDI r4,r4,1
  ST r4,r5,#NA_PENDING
  LD r1,r14,11
  JMP @nacc_sb_out
nacc_sb_bad:
  MOVI r1,#NACC_EBAD
  JMP @nacc_sb_err
nacc_sb_over:
  MOVI r1,#NACC_EOVER
  JMP @nacc_sb_err
nacc_sb_stale:
  MOVI r1,#NACC_ESTALE
  JMP @nacc_sb_err
nacc_sb_nospc:
  MOVI r1,#NACC_ENOSPC
nacc_sb_err:
  LD r2,r14,1
  ST r1,r2,#NA_LASTERR
  MOVI r1,0
nacc_sb_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nacc_cancel r1=ctx r2=seq -> 0/code.
nacc_cancel:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  LD r1,r14,1
  CALL @nacc_valid
  CMP r1,r0
  JMP[EQ] @nacc_cn_bad
  LD r1,r14,1
  LD r2,r14,2
  CALL @nacc_find
  CMP r1,r0
  JMP[EQ] @nacc_cn_noent
  ST r1,r14,3
  LD r2,r1,#ND_STATE
  MOVI r3,#NACC_QUEUED
  CMP r2,r3
  JMP[NE] @nacc_cn_bad
  MOVI r2,#NACC_CANCELLED
  ST r2,r1,#ND_STATE
  MOVI r2,#NACC_ECANCEL
  ST r2,r1,#ND_STATUS
  MOVI r1,0
  JMP @nacc_cn_out
nacc_cn_bad:
  MOVI r1,#NACC_EBAD
  JMP @nacc_cn_out
nacc_cn_noent:
  MOVI r1,#NACC_ENOENT
nacc_cn_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nacc_exec r1=ctx r2=descriptor -> status.
; Translates through the IOMMU and performs the copy or GEMV placeholder.
nacc_exec:
  ST r15,r14,0
  ADDI r14,r14,160
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r2,#ND_OP
  ST r3,r14,3
  ; src translation: R over len
  LD r9,r14,2
  LD r1,r9,#ND_DOM
  LD r2,r9,#ND_GEN
  LD r3,r9,#ND_SLO
  LD r4,r9,#ND_SHI
  LD r5,r9,#ND_LLO
  LD r6,r9,#ND_LHI
  MOVI r7,#NIOM_R_READ
  ADDI r8,r14,40
  CALL @niom_translate
  CMP r1,r0
  JMP[NE] @nacc_ex_out
  ; dst translation: W over len (copy) or 8 bytes (GEMV)
  LD r9,r14,2
  LD r1,r9,#ND_DOM
  LD r2,r9,#ND_GEN
  LD r3,r9,#ND_DLO
  LD r4,r9,#ND_DHI
  LD r10,r14,3
  MOVI r11,#NACC_OP_GEMV
  CMP r10,r11
  JMP[EQ] @nacc_ex_gemvdst
  LD r5,r9,#ND_LLO
  LD r6,r9,#ND_LHI
  JMP @nacc_ex_dstlen
nacc_ex_gemvdst:
  MOVI r5,8
  MOVI r6,0
nacc_ex_dstlen:
  MOVI r7,#NIOM_R_WRITE
  ADDI r8,r14,42
  CALL @niom_translate
  CMP r1,r0
  JMP[NE] @nacc_ex_out
  ; physical byte addresses must fit the emulated 32-bit byte window
  LD r2,r14,41
  CMP r2,r0
  JMP[NE] @nacc_ex_eio
  LD r2,r14,43
  CMP r2,r0
  JMP[NE] @nacc_ex_eio
  LD r2,r14,2
  LD r8,r2,#ND_LLO
  LD r9,r14,40
  ADD r3,r9,r8
  CMP r3,r9
  JMP[LT] @nacc_ex_eio
  LD r10,r14,42
  ADD r3,r10,r8
  CMP r3,r10
  JMP[LT] @nacc_ex_eio
  LD r3,r14,3
  MOVI r4,#NACC_OP_GEMV
  CMP r3,r4
  JMP[EQ] @nacc_ex_gemv
  ; byte copy
  MOVI r6,0
  MOVI r7,0
nacc_ex_copy:
  CMP r6,r8
  JMP[GE] @nacc_ex_ok
  ADD r3,r9,r6
  LDB r1,r3,0
  ADD r3,r10,r6
  STB r1,r3,0
  ADDI r6,r6,1
  JMP @nacc_ex_copy
nacc_ex_gemv:
  LD r6,r14,2
  LD r7,r6,#ND_LLO
  LD r8,r14,40
  ST r7,r14,20
  ST r8,r14,21
  MOVI r9,0
  MOVI r10,0
  MOVI r6,0
nacc_ex_gloop:
  LD r7,r14,20
  CMP r6,r7
  JMP[GE] @nacc_ex_gdone
  LD r8,r14,21
  ADD r3,r8,r6
  LDB r1,r3,0
  MOVI r2,3
  MUL r3,r1,r2
  ADDI r3,r3,1
  MOVI r4,0
  ADD r1,r9,r0
  ADD r2,r10,r0
  CALL @n64_add
  ADD r9,r1,r0
  ADD r10,r2,r0
  ADDI r6,r6,1
  JMP @nacc_ex_gloop
nacc_ex_gdone:
  LD r8,r14,42
  SHR r3,r8,2
  ST r9,r3,0
  ST r10,r3,1
  JMP @nacc_ex_ok
nacc_ex_eio:
  MOVI r1,#NACC_EIO
  JMP @nacc_ex_out
nacc_ex_ok:
  MOVI r1,0
nacc_ex_out:
  ADDI r14,r14,-160
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nacc_complete r1=ctx -> reaped count this call.
nacc_complete:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  LD r1,r14,1
  CALL @nacc_valid
  CMP r1,r0
  JMP[EQ] @nacc_cp_bad
  ST r0,r14,2
nacc_cp_loop:
  LD r1,r14,1
  LD r2,r1,#NA_PENDING
  CMP r2,r0
  JMP[EQ] @nacc_cp_done
  LD r4,r1,#NA_DONE
  LD r5,r1,#NA_SLOTS
  MODU r3,r4,r5
  ADD r2,r3,r0
  CALL @nacc_slot_addr
  ST r1,r14,3
  LD r2,r1,#ND_STATE
  MOVI r3,#NACC_QUEUED
  CMP r2,r3
  JMP[NE] @nacc_cp_notqueued
  ; execute queued work
  LD r1,r14,1
  LD r2,r14,3
  CALL @nacc_exec
  ST r1,r14,4
  LD r2,r14,3
  ST r1,r2,#ND_STATUS
  CMP r1,r0
  JMP[NE] @nacc_cp_err
  MOVI r3,#NACC_DONE
  ST r3,r2,#ND_STATE
  JMP @nacc_cp_adv
nacc_cp_err:
  MOVI r3,#NACC_ERROR
  ST r3,r2,#ND_STATE
  LD r3,r14,1
  LD r4,r3,#NA_ERRORS
  ADDI r4,r4,1
  ST r4,r3,#NA_ERRORS
  LD r4,r14,4
  ST r4,r3,#NA_LASTERR
  JMP @nacc_cp_adv
nacc_cp_notqueued:
  MOVI r3,#NACC_CANCELLED
  CMP r2,r3
  JMP[EQ] @nacc_cp_adv
  ; defensive: an unexpected live state at the reap head is an I/O error
  MOVI r3,#NACC_ERROR
  ST r3,r1,#ND_STATE
  MOVI r3,#NACC_EIO
  ST r3,r1,#ND_STATUS
  LD r3,r14,1
  LD r4,r3,#NA_ERRORS
  ADDI r4,r4,1
  ST r4,r3,#NA_ERRORS
  MOVI r4,#NACC_EIO
  ST r4,r3,#NA_LASTERR
nacc_cp_adv:
  LD r2,r14,3
  LD r3,r2,#ND_FENCE
  LD r1,r14,1
  LD r4,r1,#NA_DONE
  ADDI r4,r4,1
  ST r4,r1,#NA_DONE
  LD r4,r1,#NA_PENDING
  SUB r4,r4,r13
  ST r4,r1,#NA_PENDING
  LD r4,r14,2
  ADDI r4,r4,1
  ST r4,r14,2
  CMP r3,r0
  JMP[EQ] @nacc_cp_loop
  ST r3,r1,#NA_FENCED
  JMP @nacc_cp_done
nacc_cp_bad:
  MOVI r1,#NACC_EBAD
  JMP @nacc_cp_out
nacc_cp_done:
  LD r1,r14,2
nacc_cp_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nacc_fence r1=ctx -> 0/code.
nacc_fence:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @nacc_valid
  CMP r1,r0
  JMP[EQ] @nacc_fn_bad
  LD r2,r1,#NA_FENCE
  CMP r2,r0
  JMP[NE] @nacc_fn_have
  LD r2,r1,#NA_PENDING
  CMP r2,r0
  JMP[NE] @nacc_fn_busy
  MOVI r1,0
  JMP @nacc_fn_out
nacc_fn_have:
  LD r3,r1,#NA_FENCED
  CMP r3,r2
  JMP[LT] @nacc_fn_busy
  MOVI r1,0
  JMP @nacc_fn_out
nacc_fn_bad:
  MOVI r1,#NACC_EBAD
  JMP @nacc_fn_out
nacc_fn_busy:
  MOVI r1,#NACC_EBUSY
nacc_fn_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nacc_result r1=ctx r2=seq r3=out -> 0/code.
nacc_result:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LD r1,r14,1
  CALL @nacc_valid
  CMP r1,r0
  JMP[EQ] @nacc_rs_bad
  LD r2,r14,3
  CMP r2,r0
  JMP[EQ] @nacc_rs_bad
  LD r1,r14,1
  LD r2,r14,2
  CALL @nacc_find
  CMP r1,r0
  JMP[EQ] @nacc_rs_noent
  ST r1,r14,4
  LD r3,r14,3
  LD r2,r1,#ND_STATE
  ST r2,r3,0
  LD r2,r1,#ND_STATUS
  ST r2,r3,1
  LD r2,r1,#ND_FLAGS
  ST r2,r3,2
  LD r2,r1,#ND_FENCE
  ST r2,r3,3
  MOVI r1,0
  JMP @nacc_rs_out
nacc_rs_bad:
  MOVI r1,#NACC_EBAD
  JMP @nacc_rs_out
nacc_rs_noent:
  MOVI r1,#NACC_ENOENT
nacc_rs_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nacc_counters r1=ctx r2=out(5) -> 0/code.
nacc_counters:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  LD r1,r14,1
  CALL @nacc_valid
  CMP r1,r0
  JMP[EQ] @nacc_ct_bad
  LD r7,r14,2
  CMP r7,r0
  JMP[EQ] @nacc_ct_bad
  LD r1,r14,1
  LD r2,r1,#NA_ISSUED
  ST r2,r7,0
  LD r2,r1,#NA_DONE
  ST r2,r7,1
  LD r2,r1,#NA_ERRORS
  ST r2,r7,2
  LD r2,r1,#NA_FENCED
  ST r2,r7,3
  LD r2,r1,#NA_PENDING
  ST r2,r7,4
  LD r2,r1,#NA_LASTERR
  ST r2,r7,5
  LD r2,r1,#NA_FENCE
  ST r2,r7,6
  MOVI r1,0
  JMP @nacc_ct_out
nacc_ct_bad:
  MOVI r1,#NACC_EBAD
nacc_ct_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nv_div64_32 r1=lo r2=hi r3=divisor -> r1=qlo r2=qhi r3=remainder.
; Restoring long division; the gate uses 64-bit VRAM sizes across 4 GiB.
nv_div64_32:
  ADD r4,r1,r0
  ADD r5,r2,r0
  MOVI r6,0
  MOVI r7,0
  MOVI r8,0
  MOVI r9,64
nv_div_loop:
  SHR r10,r5,31
  SHR r11,r4,31
  SHL r5,r5,1
  ADD r5,r5,r11
  SHL r4,r4,1
  SHL r8,r8,1
  ADD r8,r8,r10
  SHR r11,r6,31
  SHL r7,r7,1
  ADD r7,r7,r11
  SHL r6,r6,1
  CMP r8,r3
  JMP[LT] @nv_div_nosub
  SUB r8,r8,r3
  ADDI r6,r6,1
nv_div_nosub:
  ADDI r9,r9,-1
  CMP r9,r0
  JMP[NE] @nv_div_loop
  ADD r1,r6,r0
  ADD r2,r7,r0
  ADD r3,r8,r0
  RET

; nv_mask r1=bit 0..31 -> r1=1 << bit.
nv_mask:
  ADD r3,r1,r0
  MOVI r1,1
  MOVI r2,0
nv_msk_loop:
  CMP r2,r3
  JMP[GE] @nv_msk_out
  SHL r1,r1,1
  ADDI r2,r2,1
  JMP @nv_msk_loop
nv_msk_out:
  RET

; nv_find_run r1=ctx r2=units -> start index / -1.
; Bitmap only (units_hi must be zero); first fit, deterministic low address.
nv_find_run:
  LD r3,r1,#NV_UNITSHI
  CMP r3,r0
  JMP[NE] @nv_fr_none
  LD r4,r1,#NV_UNITSLO
  CMP r2,r0
  JMP[EQ] @nv_fr_none
  CMP r2,r4
  JMP[GT] @nv_fr_none
  LD r5,r1,#NV_BITMAP
  MOVI r6,0
  MOVI r7,0
  MOVI r8,0
  MOVI r9,0
  MOVI r10,1
  LD r11,r5,0
nv_fr_loop:
  CMP r6,r4
  JMP[GE] @nv_fr_none
  BOOL.8 r3,r11,r10
  CMP r3,r0
  JMP[NE] @nv_fr_used
  CMP r7,r0
  JMP[NE] @nv_fr_inc
  ADD r8,r6,r0
nv_fr_inc:
  ADDI r7,r7,1
  CMP r7,r2
  JMP[EQ] @nv_fr_found
  JMP @nv_fr_next
nv_fr_used:
  MOVI r7,0
nv_fr_next:
  ADDI r6,r6,1
  SHL r10,r10,1
  CMP r10,r0
  JMP[NE] @nv_fr_loop
  MOVI r10,1
  ADDI r9,r9,1
  CMP r6,r4
  JMP[GE] @nv_fr_none
  ADD r3,r5,r9
  LD r11,r3,0
  JMP @nv_fr_loop
nv_fr_found:
  ADD r1,r8,r0
  RET
nv_fr_none:
  LA r1,0xFFFFFFFF
  RET

; nv_all_set r1=bitmap r2=start r3=count -> 1 if every bit is set, else 0.
nv_all_set:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  MOVI r4,31
  BOOL.8 r2,r2,r4
  ADD r1,r2,r0
  CALL @nv_mask
  ST r1,r14,4
  LD r1,r14,1
  LD r2,r14,2
  SHR r2,r2,5
  ADD r1,r1,r2
  ST r1,r14,5
  LD r1,r14,1
  LD r3,r14,3
  MOVI r6,0
nv_as_loop:
  CMP r6,r3
  JMP[GE] @nv_as_yes
  LD r2,r14,5
  LD r7,r2,0
  LD r4,r14,4
  BOOL.8 r8,r7,r4
  CMP r8,r0
  JMP[EQ] @nv_as_no
  SHL r4,r4,1
  CMP r4,r0
  JMP[NE] @nv_as_keep
  MOVI r4,1
  LD r2,r14,5
  ADDI r2,r2,1
  ST r2,r14,5
nv_as_keep:
  ST r4,r14,4
  ADDI r6,r6,1
  JMP @nv_as_loop
nv_as_yes:
  MOVI r1,1
  JMP @nv_as_out
nv_as_no:
  MOVI r1,0
nv_as_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; nv_set_range r1=bitmap r2=start r3=count r4=value(0/1) -> 0.
nv_set_range:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  MOVI r5,31
  BOOL.8 r2,r2,r5
  ADD r1,r2,r0
  CALL @nv_mask
  ST r1,r14,5
  LD r1,r14,1
  LD r2,r14,2
  SHR r2,r2,5
  ADD r1,r1,r2
  ST r1,r14,6
  LD r2,r1,0
  ST r2,r14,7
  MOVI r6,0
nv_sr_loop:
  LD r3,r14,3
  CMP r6,r3
  JMP[GE] @nv_sr_done
  LD r4,r14,4
  LD r7,r14,7
  LD r5,r14,5
  CMP r4,r0
  JMP[EQ] @nv_sr_clear
  BOOL.14 r8,r7,r5
  JMP @nv_sr_store
nv_sr_clear:
  BOOL.3 r9,r5
  BOOL.8 r8,r7,r9
nv_sr_store:
  LD r2,r14,6
  ST r8,r2,0
  ST r8,r14,7
  SHL r5,r5,1
  CMP r5,r0
  JMP[NE] @nv_sr_keep
  MOVI r5,1
  LD r2,r14,6
  ADDI r2,r2,1
  ST r2,r14,6
  LD r7,r2,0
  ST r7,r14,7
nv_sr_keep:
  ST r5,r14,5
  ADDI r6,r6,1
  JMP @nv_sr_loop
nv_sr_done:
  MOVI r1,0
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nacc_vram_init r1=ctx r2=bar_lo r3=bar_hi r4=size_lo r5=size_hi
;                r6=granule r7=bitmap r8=bitmap_words -> 0/code.
nacc_vram_init:
  ST r15,r14,0
  ADDI r14,r14,112
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  ST r7,r14,7
  ST r8,r14,8
  LD r2,r14,1
  CMP r2,r0
  JMP[EQ] @nacc_vi_bad
  LD r2,r14,7
  CMP r2,r0
  JMP[EQ] @nacc_vi_bad
  ; granule: nonzero power of two in [4 KiB, 1 GiB]
  LD r3,r14,6
  CMP r3,r0
  JMP[EQ] @nacc_vi_bad
  SUB r4,r3,r13
  BOOL.8 r5,r3,r4
  CMP r5,r0
  JMP[NE] @nacc_vi_bad
  MOVI r4,0x1000
  CMP r3,r4
  JMP[LT] @nacc_vi_bad
  LA r4,#NV_MAX_GRAN
  CMP r3,r4
  JMP[GT] @nacc_vi_bad
  ; size nonzero and granule aligned
  LD r4,r14,4
  LD r5,r14,5
  CMP r4,r0
  JMP[NE] @nacc_vi_szok
  CMP r5,r0
  JMP[EQ] @nacc_vi_bad
nacc_vi_szok:
  LD r3,r14,6
  SUB r6,r3,r13
  BOOL.8 r7,r4,r6
  CMP r7,r0
  JMP[NE] @nacc_vi_align
  ; units = size / granule
  LD r1,r14,4
  LD r2,r14,5
  LD r3,r14,6
  CALL @nv_div64_32
  CMP r3,r0
  JMP[NE] @nacc_vi_align
  CMP r2,r0
  JMP[NE] @nacc_vi_space
  ST r1,r14,9
  ST r2,r14,10
  ; bitmap words needed = ceil(units / 32)
  SHR r4,r1,5
  MOVI r5,31
  BOOL.8 r5,r1,r5
  CMP r5,r0
  JMP[EQ] @nacc_vi_needok
  ADDI r4,r4,1
nacc_vi_needok:
  LD r5,r14,8
  CMP r4,r5
  JMP[GT] @nacc_vi_space
  ; clear bitmap and context, then publish
  LD r1,r14,7
  LD r2,r14,8
  BFILL r1,r0,r2
  LD r1,r14,1
  MOVI r2,32
  BFILL r1,r0,r2
  LD r1,r14,1
  LA r2,#NV_MAGICV
  ST r2,r1,#NV_MAGIC
  MOVI r2,#NV_VERSION
  ST r2,r1,#NV_VER
  LD r2,r14,2
  ST r2,r1,#NV_BARLO
  LD r2,r14,3
  ST r2,r1,#NV_BARHI
  LD r2,r14,4
  ST r2,r1,#NV_SIZELO
  LD r2,r14,5
  ST r2,r1,#NV_SIZEHI
  LD r2,r14,6
  ST r2,r1,#NV_GRAN
  LD r2,r14,7
  ST r2,r1,#NV_BITMAP
  LD r2,r14,8
  ST r2,r1,#NV_BITWORDS
  LD r2,r14,9
  ST r2,r1,#NV_UNITSLO
  LD r2,r14,10
  ST r2,r1,#NV_UNITSHI
  MOVI r2,#NACC_POL_DEFAULT
  ST r2,r1,#NV_POLICY
  MOVI r1,0
  JMP @nacc_vi_out
nacc_vi_bad:
  MOVI r1,#NACC_EBAD
  JMP @nacc_vi_out
nacc_vi_align:
  MOVI r1,#NACC_EALIGN
  JMP @nacc_vi_out
nacc_vi_space:
  MOVI r1,#NACC_ESPACE
nacc_vi_out:
  ADDI r14,r14,-112
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nacc_vram_alloc r1=ctx r2=units_lo r3=units_hi r4=out -> 0/code.
nacc_vram_alloc:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  LD r1,r14,1
  LD r2,r1,#NV_MAGIC
  LA r3,#NV_MAGICV
  CMP r2,r3
  JMP[NE] @nacc_va_bad
  LD r2,r14,4
  CMP r2,r0
  JMP[EQ] @nacc_va_bad
  LD r2,r14,2
  LD r3,r14,3
  CMP r2,r0
  JMP[NE] @nacc_va_nz
  CMP r3,r0
  JMP[EQ] @nacc_va_bad
nacc_va_nz:
  CMP r3,r0
  JMP[NE] @nacc_va_full
  LD r1,r14,1
  LD r4,r1,#NV_UNITSHI
  CMP r4,r0
  JMP[NE] @nacc_va_full
  LD r4,r1,#NV_UNITSLO
  CMP r2,r4
  JMP[GT] @nacc_va_full
  ADD r2,r2,r0
  CALL @nv_find_run
  LA r3,0xFFFFFFFF
  CMP r1,r3
  JMP[EQ] @nacc_va_full
  ST r1,r14,5
  ; set the bits, then account
  LD r1,r14,1
  LD r1,r1,#NV_BITMAP
  LD r2,r14,5
  LD r3,r14,2
  MOVI r4,1
  CALL @nv_set_range
  LD r6,r14,1
  LD r1,r6,#NV_USEDLO
  LD r2,r6,#NV_USEDHI
  LD r3,r14,2
  MOVI r4,0
  CALL @n64_add
  LD r3,r14,1
  ST r1,r3,#NV_USEDLO
  ST r2,r3,#NV_USEDHI
  ; offset = start * granule (multiplier is the u32 granule)
  LD r1,r14,1
  LD r1,r1,#NV_GRAN
  LD r2,r14,5
  MOVI r3,0
  CALL @n64_mul32
  LD r3,r14,4
  ST r1,r3,0
  ST r2,r3,1
  LD r1,r14,1
  LD r2,r1,#NV_ALLOCS
  ADDI r2,r2,1
  ST r2,r1,#NV_ALLOCS
  MOVI r1,0
  JMP @nacc_va_out
nacc_va_bad:
  MOVI r1,#NACC_EBAD
  JMP @nacc_va_out
nacc_va_full:
  LD r1,r14,1
  LD r2,r1,#NV_FAILS
  ADDI r2,r2,1
  ST r2,r1,#NV_FAILS
  MOVI r2,#NACC_ENOSPC
  ST r2,r1,#NV_LAST
  MOVI r1,#NACC_ENOSPC
nacc_va_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nacc_vram_free r1=ctx r2=off_lo r3=off_hi r4=units_lo r5=units_hi
;                 -> 0/code.
nacc_vram_free:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  LD r1,r14,1
  LD r2,r1,#NV_MAGIC
  LA r3,#NV_MAGICV
  CMP r2,r3
  JMP[NE] @nacc_vf_bad
  LD r2,r14,4
  LD r3,r14,5
  CMP r2,r0
  JMP[NE] @nacc_vf_nz
  CMP r3,r0
  JMP[EQ] @nacc_vf_bad
nacc_vf_nz:
  CMP r3,r0
  JMP[NE] @nacc_vf_align
  LD r1,r14,1
  LD r4,r1,#NV_GRAN
  SUB r5,r4,r13
  LD r2,r14,2
  BOOL.8 r6,r2,r5
  CMP r6,r0
  JMP[NE] @nacc_vf_align
  ; start = offset / granule
  LD r1,r14,2
  LD r2,r14,3
  LD r3,r14,1
  LD r3,r3,#NV_GRAN
  CALL @nv_div64_32
  CMP r3,r0
  JMP[NE] @nacc_vf_align
  CMP r2,r0
  JMP[NE] @nacc_vf_space
  ST r1,r14,6
  ; end = start + units
  LD r2,r14,4
  ADD r3,r1,r2
  CMP r3,r1
  JMP[LT] @nacc_vf_space
  LD r4,r14,1
  LD r5,r4,#NV_UNITSLO
  CMP r3,r5
  JMP[GT] @nacc_vf_space
  ; every bit must be set
  LD r1,r14,1
  LD r1,r1,#NV_BITMAP
  LD r2,r14,6
  LD r3,r14,4
  CALL @nv_all_set
  CMP r1,r0
  JMP[EQ] @nacc_vf_noent
  LD r1,r14,1
  LD r1,r1,#NV_BITMAP
  LD r2,r14,6
  LD r3,r14,4
  MOVI r4,0
  CALL @nv_set_range
  LD r6,r14,1
  LD r1,r6,#NV_USEDLO
  LD r2,r6,#NV_USEDHI
  LD r3,r14,4
  MOVI r4,0
  CALL @n64_sub
  LD r3,r14,1
  ST r1,r3,#NV_USEDLO
  ST r2,r3,#NV_USEDHI
  LD r2,r3,#NV_FREES
  ADDI r2,r2,1
  ST r2,r3,#NV_FREES
  MOVI r1,0
  JMP @nacc_vf_out
nacc_vf_bad:
  MOVI r1,#NACC_EBAD
  JMP @nacc_vf_out
nacc_vf_align:
  MOVI r1,#NACC_EALIGN
  JMP @nacc_vf_out
nacc_vf_space:
  MOVI r1,#NACC_ESPACE
  JMP @nacc_vf_out
nacc_vf_noent:
  MOVI r1,#NACC_ENOENT
nacc_vf_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nacc_vram_place r1=ctx r2=kind r3=bytes_lo r4=bytes_hi r5=dom r6=out
;                  -> 1 VRAM / 2 host / 0 error.
nacc_vram_place:
  ST r15,r14,0
  ADDI r14,r14,160
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  LD r1,r14,1
  LD r2,r1,#NV_MAGIC
  LA r3,#NV_MAGICV
  CMP r2,r3
  JMP[NE] @nacc_vp_bad
  LD r2,r14,6
  CMP r2,r0
  JMP[EQ] @nacc_vp_bad
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @nacc_vp_bad
  MOVI r3,#NACC_KIND_ACT
  CMP r2,r3
  JMP[GT] @nacc_vp_bad
  LD r2,r14,3
  LD r3,r14,4
  CMP r2,r0
  JMP[NE] @nacc_vp_bytes
  CMP r3,r0
  JMP[EQ] @nacc_vp_bad
nacc_vp_bytes:
  ; units = ceil(bytes / granule)
  LD r1,r14,3
  LD r2,r14,4
  LD r3,r14,1
  LD r3,r3,#NV_GRAN
  CALL @nv_div64_32
  CMP r3,r0
  JMP[EQ] @nacc_vp_norem
  ADDI r1,r1,1
  CMP r1,r0
  JMP[NE] @nacc_vp_norem
  ADDI r2,r2,1
nacc_vp_norem:
  ST r1,r14,7
  ST r2,r14,8
  ; policy: activations host-only; weights/KV prefer VRAM
  LD r2,r14,2
  MOVI r3,#NACC_KIND_ACT
  CMP r2,r3
  JMP[EQ] @nacc_vp_host
  LD r1,r14,1
  LD r3,r1,#NV_POLICY
  MOVI r4,#NACC_KIND_WEIGHT
  CMP r2,r4
  JMP[EQ] @nacc_vp_polw
  MOVI r4,#NACC_KIND_KV
  CMP r2,r4
  JMP[EQ] @nacc_vp_polk
  JMP @nacc_vp_bad
nacc_vp_polw:
  MOVI r4,#NACC_POL_WEIGHT
  BOOL.8 r5,r3,r4
  CMP r5,r0
  JMP[EQ] @nacc_vp_host
  JMP @nacc_vp_try
nacc_vp_polk:
  MOVI r4,#NACC_POL_KV
  BOOL.8 r5,r3,r4
  CMP r5,r0
  JMP[EQ] @nacc_vp_host
nacc_vp_try:
  ; requests outside the bitmap model fall back explicitly
  LD r2,r14,8
  CMP r2,r0
  JMP[NE] @nacc_vp_exh
  LD r1,r14,1
  LD r3,r1,#NV_UNITSHI
  CMP r3,r0
  JMP[NE] @nacc_vp_exh
  LD r3,r1,#NV_UNITSLO
  LD r2,r14,7
  CMP r2,r3
  JMP[GT] @nacc_vp_exh
  ; allocate, then validate the BAR through the IOMMU
  LD r1,r14,1
  LD r2,r14,7
  LD r3,r14,8
  ADDI r4,r14,20
  CALL @nacc_vram_alloc
  CMP r1,r0
  JMP[NE] @nacc_vp_exh
  LD r6,r14,1
  LD r1,r6,#NV_BARLO
  LD r2,r6,#NV_BARHI
  LD r3,r14,20
  LD r4,r14,21
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @nacc_vp_unmap
  ST r1,r14,12
  ST r2,r14,13
  LD r1,r14,5
  CALL @niom_generation
  CMP r1,r0
  JMP[EQ] @nacc_vp_unmap
  ST r1,r14,14
  LD r1,r14,5
  LD r2,r14,14
  LD r3,r14,12
  LD r4,r14,13
  LD r5,r14,3
  LD r6,r14,4
  MOVI r7,#NIOM_R_WRITE
  ADDI r8,r14,30
  CALL @niom_translate
  CMP r1,r0
  JMP[NE] @nacc_vp_unmap
  ; VRAM placement record
  LD r1,r14,6
  MOVI r2,#NACC_TIER_VRAM
  ST r2,r1,0
  LD r2,r14,20
  ST r2,r1,1
  LD r2,r14,21
  ST r2,r1,2
  LD r2,r14,7
  ST r2,r1,3
  LD r2,r14,8
  ST r2,r1,4
  LD r2,r14,3
  ST r2,r1,5
  LD r2,r14,4
  ST r2,r1,6
  LD r2,r14,2
  ST r2,r1,7
  LD r1,r14,1
  LD r2,r1,#NV_VRAM_PLACE
  ADDI r2,r2,1
  ST r2,r1,#NV_VRAM_PLACE
  MOVI r1,1
  JMP @nacc_vp_out
nacc_vp_exh:
  LD r1,r14,1
  LD r2,r1,#NV_FB_EXH
  ADDI r2,r2,1
  ST r2,r1,#NV_FB_EXH
  JMP @nacc_vp_host
nacc_vp_unmap:
  ; roll the failed allocation back before falling back to the CPU
  LD r1,r14,1
  LD r2,r14,20
  LD r3,r14,21
  LD r4,r14,7
  LD r5,r14,8
  CALL @nacc_vram_free
  LD r1,r14,1
  LD r2,r1,#NV_FB_UNMAP
  ADDI r2,r2,1
  ST r2,r1,#NV_FB_UNMAP
nacc_vp_host:
  LD r1,r14,6
  ST r0,r1,0
  ST r0,r1,1
  ST r0,r1,2
  ST r0,r1,3
  ST r0,r1,4
  LD r2,r14,3
  ST r2,r1,5
  LD r2,r14,4
  ST r2,r1,6
  LD r2,r14,2
  ST r2,r1,7
  LD r1,r14,1
  LD r2,r1,#NV_HOST_PLACE
  ADDI r2,r2,1
  ST r2,r1,#NV_HOST_PLACE
  MOVI r1,2
  JMP @nacc_vp_out
nacc_vp_bad:
  MOVI r1,0
nacc_vp_out:
  ADDI r14,r14,-160
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nacc_vram_stats r1=ctx r2=out(24) -> 0/code.
nacc_vram_stats:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  LD r1,r14,1
  LD r2,r1,#NV_MAGIC
  LA r3,#NV_MAGICV
  CMP r2,r3
  JMP[NE] @nacc_vs_bad
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @nacc_vs_bad
  LD r1,r14,1
  LD r2,r14,2
  MOVI r3,24
  BFILL r2,r0,r3
  LD r5,r14,2
  LD r2,r1,#NV_USEDLO
  ST r2,r5,0
  LD r2,r1,#NV_USEDHI
  ST r2,r5,1
  ; free units = total - used
  LD r6,r14,1
  LD r1,r6,#NV_UNITSLO
  LD r2,r6,#NV_UNITSHI
  LD r3,r6,#NV_USEDLO
  LD r4,r6,#NV_USEDHI
  CALL @n64_sub
  LD r6,r14,2
  ST r1,r6,2
  ST r2,r6,3
  ; used bytes = used * granule
  LD r4,r14,1
  LD r8,r4,#NV_GRAN
  ADD r1,r8,r0
  LD r2,r4,#NV_USEDLO
  LD r3,r4,#NV_USEDHI
  CALL @n64_mul32
  LD r6,r14,2
  ST r1,r6,4
  ST r2,r6,5
  ; free units = total - used, then free bytes = free * granule
  LD r4,r14,1
  LD r1,r4,#NV_UNITSLO
  LD r2,r4,#NV_UNITSHI
  LD r3,r4,#NV_USEDLO
  LD r4,r4,#NV_USEDHI
  CALL @n64_sub
  LD r5,r14,1
  LD r5,r5,#NV_GRAN
  ADD r3,r2,r0
  ADD r2,r1,r0
  ADD r1,r5,r0
  CALL @n64_mul32
  LD r6,r14,2
  ST r1,r6,6
  ST r2,r6,7
  LD r1,r14,1
  LD r2,r1,#NV_ALLOCS
  ST r2,r6,8
  LD r2,r1,#NV_FREES
  ST r2,r6,9
  LD r2,r1,#NV_VRAM_PLACE
  ST r2,r6,10
  LD r2,r1,#NV_HOST_PLACE
  ST r2,r6,11
  LD r2,r1,#NV_FB_EXH
  ST r2,r6,12
  LD r2,r1,#NV_FB_UNMAP
  ST r2,r6,13
  LD r2,r1,#NV_FAILS
  ST r2,r6,14
  LD r2,r1,#NV_POLICY
  ST r2,r6,15
  LD r2,r1,#NV_BARLO
  ST r2,r6,16
  LD r2,r1,#NV_BARHI
  ST r2,r6,17
  LD r2,r1,#NV_SIZELO
  ST r2,r6,18
  LD r2,r1,#NV_SIZEHI
  ST r2,r6,19
  LD r2,r1,#NV_UNITSLO
  ST r2,r6,20
  LD r2,r1,#NV_UNITSHI
  ST r2,r6,21
  LD r2,r1,#NV_GRAN
  ST r2,r6,22
  LD r2,r1,#NV_BITWORDS
  ST r2,r6,23
  MOVI r1,0
  JMP @nacc_vs_out
nacc_vs_bad:
  MOVI r1,#NACC_EBAD
nacc_vs_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET
