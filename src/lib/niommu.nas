; niommu.nas - per-device/per-agent IOMMU domains for the accelerator boundary.
;
; This is the deterministic software policy layer that a native IOMMU driver
; would program.  It owns a fixed table of domains and, per domain, a shadow
; map of 64-bit IOVAs to 64-bit physical byte addresses with R/W/X rights.
; No device, page table or host pointer is required: naccel.nas consumes this
; translation API to model DMA rings, so the whole boundary is testable on the
; pure-NaN oracle.  This is an emulated boundary, not a claim of real GPU or
; IOMMU support.
;
; Domain table at guest word 0x360000: 8 records x 64 words.
;   +0 magic "NIOM" 0x4E494F4D   +1 version 1
;   +2 domain id 1..8            +3 device id
;   +4 state (1 live)            +5 domain generation
;   +6 invalidation epoch        +7 live map count
;   +8 fault count               +9 last fault code
;   +10 last fault iova lo       +11 last fault iova hi
;   +12 last fault epoch         +13..15 reserved
;   +16..31 four fault records, 4 words each:
;         +0 code +1 iova_lo +2 iova_hi +3 epoch
;
; Shadow map at guest word 0x361000: 8 domains x 32 entries x 12 words.
;   +0 state (1 live)  +1 map id 1..32
;   +2 iova_lo +3 iova_hi +4 size_lo +5 size_hi
;   +6 phys_lo +7 phys_hi
;   +8 rights (1 R, 2 W, 4 X)   +9 domain generation snapshot
;   +10 flags +11 reserved
;
; Contract:
;   * IOVA, physical and size are page aligned (4 KiB); size is nonzero.
;   * iova+size and phys+size are computed as 64-bit (lo,hi) adds.  A carry is
;     EOVER; it is never truncated.
;   * Ranges are half-open.  A live entry may not overlap another live entry in
;     the same domain (ESPACE).
;   * W|X is rejected with ERIGHT; rights must be a nonzero subset of 7.
;   * A translation request must be covered wholly by one live entry whose
;     generation matches the domain generation and whose rights are a superset
;     of the requested rights.  There is no implicit multi-entry walk.
;   * Every map, unmap, rebind, revoke and destroy bumps the domain
;     invalidation epoch.  Revoke and destroy bump the domain generation and
;     clear every map, so queued DMA with an old generation fails ESTALE.
;   * Faults (ENOENT/ERIGHT/ESTALE/EOVER) append a 4-word record to a 4-entry
;     ring and update the last-fault words.  NIOM_G_ERR holds the last code.
;
; API:
;   niom_init
;   niom_domain_create r1=device -> domain id / 0
;   niom_domain_destroy r1=domain -> 0/code
;   niom_domain_find r1=device -> domain id / 0
;   niom_map    r1=dom r2=iova_lo r3=iova_hi r4=size_lo r5=size_hi
;               r6=phys_lo r7=phys_hi r8=rights -> map id 1..32 / 0
;               (the exact rejection is NIOM_G_ERR / niom_errno)
;   niom_unmap  r1=dom r2=map id -> 0/code
;   niom_rebind r1=dom r2=map id r3=iova_lo r4=iova_hi r5=size_lo r6=size_hi
;               r7=phys_lo r8=phys_hi r9=rights -> 0/code
;   niom_translate r1=dom r2=generation r3=iova_lo r4=iova_hi
;               r5=len_lo r6=len_hi r7=rights r8=out(2 words) -> 0/code
;   niom_revoke r1=dom -> 0/code (new generation, all maps cleared)
;   niom_generation r1=dom -> generation / 0
;   niom_epoch  r1=dom -> invalidation epoch / 0
;   niom_fault_count r1=dom -> count / 0
;   niom_fault  r1=dom r2=slot(0..3) r3=out(4 words) -> 0/code
;   niom_errno  -> last error code
;
; ABI: r0=0, r13=1, r14=SP (grows up), r15=link.  Public routines use
; r1..r5 as scratch.  The table and NIOM_G_ERR (word 0x6E00) are reserved in
; an image that links this library.

.include "n64.nas"

.equ NIOM_DTAB       0x360000
.equ NIOM_MTAB       0x361000
.equ NIOM_MAX_DOM    8
.equ NIOM_MAX_MAP    32
.equ NIOM_DSTRIDE    64
.equ NIOM_MSTRIDE    12
.equ NIOM_PAGE       0x1000
.equ NIOM_MASK       0xFFF

.equ NIOM_MAGIC      0x4E494F4D       ; "NIOM"
.equ NIOM_VERSION    1

; Domain fields.
.equ NI_D_MAGIC      0
.equ NI_D_VER        1
.equ NI_D_ID         2
.equ NI_D_DEV        3
.equ NI_D_STATE      4
.equ NI_D_GEN        5
.equ NI_D_EPOCH      6
.equ NI_D_NMAP       7
.equ NI_D_FAULTS     8
.equ NI_D_LAST       9
.equ NI_D_LASTLO     10
.equ NI_D_LASTHI     11
.equ NI_D_LASTE      12
.equ NI_D_FLOG       16

; Map fields.
.equ NI_M_STATE      0
.equ NI_M_ID         1
.equ NI_M_ILO        2
.equ NI_M_IHI        3
.equ NI_M_SLO        4
.equ NI_M_SHI        5
.equ NI_M_PLO        6
.equ NI_M_PHI        7
.equ NI_M_RIGHTS     8
.equ NI_M_GEN        9
.equ NI_M_FLAGS      10
.equ NI_M_RES        11

; Rights and state.
.equ NIOM_R_READ     1
.equ NIOM_R_WRITE    2
.equ NIOM_R_EXEC     4
.equ NIOM_R_ALL      7
.equ NI_LIVE         1

; Codes.
.equ NIOM_OK         0
.equ NIOM_EBAD       1
.equ NIOM_ENOENT     2
.equ NIOM_ERIGHT     3
.equ NIOM_ESTALE     4
.equ NIOM_EOVER      5
.equ NIOM_ESPACE     6
.equ NIOM_EFULL      7
.equ NIOM_EALIGN     8

.equ NIOM_G_ERR      0x6E00

; ---------------------------------------------------------------------------
; niom_drec r1=domain -> record address or 0.
niom_drec:
  CMP r1,r0
  JMP[EQ] @niom_drec_none
  MOVI r2,#NIOM_MAX_DOM
  CMP r1,r2
  JMP[GT] @niom_drec_none
  SUB r1,r1,r13
  SHL r1,r1,6
  LA r2,#NIOM_DTAB
  ADD r1,r1,r2
  RET
niom_drec_none:
  MOVI r1,0
  RET

; niom_mrec r1=domain r2=slot (0..31) -> entry address.
niom_mrec:
  SUB r1,r1,r13
  SHL r1,r1,5
  ADD r1,r1,r2
  MOVI r3,#NIOM_MSTRIDE
  MUL r1,r1,r3
  LA r3,#NIOM_MTAB
  ADD r1,r1,r3
  RET

; niom_lt64 r1=alo r2=ahi r3=blo r4=bhi -> 1 if a < b unsigned.
niom_lt64:
  CMP r2,r4
  JMP[LT] @niom_lt_yes
  JMP[GT] @niom_lt_no
  CMP r1,r3
  JMP[LT] @niom_lt_yes
niom_lt_no:
  MOVI r1,0
  RET
niom_lt_yes:
  MOVI r1,1
  RET

; niom_err r1=code -> code, NIOM_G_ERR=code.
niom_err:
  ST r1,r0,#NIOM_G_ERR
  RET

; ---------------------------------------------------------------------------
; niom_init -> 0.
niom_init:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r1,#NIOM_DTAB
  MOVI r2,512
  BFILL r1,r0,r2
  LA r1,#NIOM_MTAB
  MOVI r2,3072
  BFILL r1,r0,r2
  ST r0,r0,#NIOM_G_ERR
  MOVI r1,0
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; niom_fault_add r1=dom r2=code r3=iova_lo r4=iova_hi -> 0.
; Records the fault in the domain's 4-entry ring and bumps the counters.
niom_fault_add:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  CALL @niom_drec
  CMP r1,r0
  JMP[EQ] @niom_fa_out
  ST r1,r14,5
  LD r5,r1,#NI_D_FAULTS
  MOVI r6,3
  BOOL.8 r6,r5,r6
  ST r6,r14,6
  ADDI r7,r5,1
  ST r7,r1,#NI_D_FAULTS
  LD r2,r14,2
  ST r2,r1,#NI_D_LAST
  LD r2,r14,3
  ST r2,r1,#NI_D_LASTLO
  LD r2,r14,4
  ST r2,r1,#NI_D_LASTHI
  LD r2,r1,#NI_D_EPOCH
  ST r2,r1,#NI_D_LASTE
  LD r6,r14,6
  SHL r6,r6,2
  ADDI r6,r6,#NI_D_FLOG
  ADD r6,r1,r6
  LD r2,r14,2
  ST r2,r6,0
  LD r2,r14,3
  ST r2,r6,1
  LD r2,r14,4
  ST r2,r6,2
  LD r2,r1,#NI_D_EPOCH
  ST r2,r6,3
  LD r2,r14,2
  ST r2,r0,#NIOM_G_ERR
niom_fa_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; niom_domain_create r1=device -> id / 0.
niom_domain_create:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r0,r0,#NIOM_G_ERR
  MOVI r2,0
  ST r2,r14,2
niom_dc_loop:
  LD r2,r14,2
  MOVI r3,#NIOM_MAX_DOM
  CMP r2,r3
  JMP[GE] @niom_dc_full
  LD r1,r14,2
  ADDI r1,r1,1
  CALL @niom_drec
  ST r1,r14,3
  LD r3,r1,#NI_D_STATE
  CMP r3,r0
  JMP[EQ] @niom_dc_found
  LD r3,r14,2
  ADDI r3,r3,1
  ST r3,r14,2
  JMP @niom_dc_loop

niom_dc_full:
  MOVI r1,#NIOM_EFULL
  CALL @niom_err
  MOVI r1,0
  JMP @niom_dc_out

niom_dc_found:
  ; duplicate live device id is rejected
  MOVI r4,0
  ST r4,r14,4
niom_dc_dup:
  LD r4,r14,4
  MOVI r5,#NIOM_MAX_DOM
  CMP r4,r5
  JMP[GE] @niom_dc_init
  ADDI r1,r4,1
  CALL @niom_drec
  LD r5,r1,#NI_D_STATE
  CMP r5,r0
  JMP[EQ] @niom_dc_dup_next
  LD r5,r1,#NI_D_DEV
  LD r6,r14,1
  CMP r5,r6
  JMP[EQ] @niom_dc_dup_bad
niom_dc_dup_next:
  LD r4,r14,4
  ADDI r4,r4,1
  ST r4,r14,4
  JMP @niom_dc_dup
niom_dc_dup_bad:
  MOVI r1,#NIOM_EBAD
  CALL @niom_err
  MOVI r1,0
  JMP @niom_dc_out

niom_dc_init:
  LD r1,r14,3
  ; preserve the old generation/epoch so a reused slot never rewinds them
  LD r4,r1,#NI_D_GEN
  LD r5,r1,#NI_D_EPOCH
  ST r4,r14,5
  ST r5,r14,6
  MOVI r2,#NIOM_DSTRIDE
  BFILL r1,r0,r2
  LD r4,r14,5
  CMP r4,r0
  JMP[EQ] @niom_dc_gen1
  LA r5,0xFFFFFFFF
  CMP r4,r5
  JMP[EQ] @niom_dc_gen1
  ADDI r4,r4,1
  JMP @niom_dc_genok
niom_dc_gen1:
  MOVI r4,1
niom_dc_genok:
  LD r1,r14,3
  ST r4,r1,#NI_D_GEN
  LD r5,r14,6
  CMP r5,r0
  JMP[EQ] @niom_dc_e1
  ADDI r5,r5,1
  JMP @niom_dc_eok
niom_dc_e1:
  MOVI r5,1
niom_dc_eok:
  ST r5,r1,#NI_D_EPOCH
  LA r2,#NIOM_MAGIC
  ST r2,r1,#NI_D_MAGIC
  MOVI r2,#NIOM_VERSION
  ST r2,r1,#NI_D_VER
  LD r2,r14,2
  ADDI r2,r2,1
  ST r2,r1,#NI_D_ID
  LD r2,r14,1
  ST r2,r1,#NI_D_DEV
  ST r13,r1,#NI_D_STATE
  LD r1,r14,2
  ADDI r1,r1,1
  JMP @niom_dc_out
niom_dc_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; niom_domain_destroy r1=dom -> 0/code.  Clears maps, bumps generation.
niom_domain_destroy:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r0,r0,#NIOM_G_ERR
  CALL @niom_drec
  CMP r1,r0
  JMP[EQ] @niom_dd_bad
  ST r1,r14,2
  LD r2,r1,#NI_D_STATE
  CMP r2,r0
  JMP[EQ] @niom_dd_noent
  ; clear every entry in this domain
  MOVI r3,0
  ST r3,r14,3
niom_dd_clr:
  LD r3,r14,3
  MOVI r4,#NIOM_MAX_MAP
  CMP r3,r4
  JMP[GE] @niom_dd_cld
  LD r1,r14,1
  CALL @niom_mrec
  MOVI r2,#NIOM_MSTRIDE
  BFILL r1,r0,r2
  LD r3,r14,3
  ADDI r3,r3,1
  ST r3,r14,3
  JMP @niom_dd_clr
niom_dd_cld:
  LD r1,r14,2
  ST r0,r1,#NI_D_NMAP
  ST r0,r1,#NI_D_STATE
  LD r2,r1,#NI_D_GEN
  ADDI r2,r2,1
  CMP r2,r0
  JMP[NE] @niom_dd_genok
  MOVI r2,1
niom_dd_genok:
  ST r2,r1,#NI_D_GEN
  LD r2,r1,#NI_D_EPOCH
  ADDI r2,r2,1
  ST r2,r1,#NI_D_EPOCH
  MOVI r1,0
  JMP @niom_dd_out
niom_dd_bad:
  MOVI r1,#NIOM_EBAD
  JMP @niom_dd_err
niom_dd_noent:
  MOVI r1,#NIOM_ENOENT
niom_dd_err:
  CALL @niom_err
niom_dd_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; niom_domain_find r1=device -> id / 0.
niom_domain_find:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  MOVI r2,0
  ST r2,r14,2
niom_df_loop:
  LD r2,r14,2
  MOVI r3,#NIOM_MAX_DOM
  CMP r2,r3
  JMP[GE] @niom_df_none
  ADDI r1,r2,1
  CALL @niom_drec
  LD r3,r1,#NI_D_STATE
  CMP r3,r0
  JMP[EQ] @niom_df_next
  LD r3,r1,#NI_D_DEV
  LD r4,r14,1
  CMP r3,r4
  JMP[NE] @niom_df_next
  LD r1,r14,2
  ADDI r1,r1,1
  JMP @niom_df_out
niom_df_next:
  LD r2,r14,2
  ADDI r2,r2,1
  ST r2,r14,2
  JMP @niom_df_loop
niom_df_none:
  MOVI r1,0
niom_df_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; niom_map r1=dom r2..r8 -> map id / 0.
niom_map:
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
  ST r0,r0,#NIOM_G_ERR
  LD r1,r14,1
  CALL @niom_drec
  CMP r1,r0
  JMP[EQ] @niom_mp_bad
  ST r1,r14,9
  LD r2,r1,#NI_D_STATE
  CMP r2,r0
  JMP[EQ] @niom_mp_noent
  ; rights: nonzero subset of 7, no W|X
  LD r2,r14,8
  CMP r2,r0
  JMP[EQ] @niom_mp_bad
  LA r3,0xFFFFFFF8
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @niom_mp_bad
  MOVI r3,6
  BOOL.8 r4,r2,r3
  CMP r4,r3
  JMP[EQ] @niom_mp_wx
  ; alignment and nonzero size
  LD r2,r14,2
  MOVI r3,#NIOM_MASK
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @niom_mp_align
  LD r2,r14,4
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @niom_mp_align
  LD r2,r14,6
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @niom_mp_align
  LD r2,r14,4
  LD r3,r14,5
  CMP r2,r0
  JMP[NE] @niom_mp_szok
  CMP r3,r0
  JMP[EQ] @niom_mp_bad
niom_mp_szok:
  ; end = iova + size
  LD r1,r14,2
  LD r2,r14,3
  LD r3,r14,4
  LD r4,r14,5
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @niom_mp_over
  ST r1,r14,10
  ST r2,r14,11
  ; phys + size must also not wrap
  LD r1,r14,6
  LD r2,r14,7
  LD r3,r14,4
  LD r4,r14,5
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @niom_mp_over
  ; find a free slot
  MOVI r2,0
  ST r2,r14,12
niom_mp_slot:
  LD r2,r14,12
  MOVI r3,#NIOM_MAX_MAP
  CMP r2,r3
  JMP[GE] @niom_mp_full
  LD r1,r14,1
  CALL @niom_mrec
  ST r1,r14,13
  LD r3,r1,#NI_M_STATE
  CMP r3,r0
  JMP[EQ] @niom_mp_slot_ok
  LD r2,r14,12
  ADDI r2,r2,1
  ST r2,r14,12
  JMP @niom_mp_slot
niom_mp_full:
  MOVI r1,#NIOM_EFULL
  CALL @niom_err
  JMP @niom_mp_out

niom_mp_slot_ok:
  ; overlap scan against every live entry
  MOVI r2,0
  ST r2,r14,14
niom_mp_ovl:
  LD r2,r14,14
  MOVI r3,#NIOM_MAX_MAP
  CMP r2,r3
  JMP[GE] @niom_mp_store
  LD r3,r14,12
  CMP r2,r3
  JMP[EQ] @niom_mp_ovl_next
  LD r1,r14,1
  CALL @niom_mrec
  ST r1,r14,15
  LD r3,r1,#NI_M_STATE
  CMP r3,r0
  JMP[EQ] @niom_mp_ovl_next
  ; eend = elo + esize
  LD r1,r14,15
  LD r1,r1,#NI_M_ILO
  LD r3,r14,15
  LD r2,r3,#NI_M_IHI
  LD r3,r14,15
  LD r3,r3,#NI_M_SLO
  LD r4,r14,15
  LD r4,r4,#NI_M_SHI
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @niom_mp_space
  ST r1,r14,16
  ST r2,r14,17
  ; cand_lo < eend ?
  LD r1,r14,2
  LD r2,r14,3
  LD r3,r14,16
  LD r4,r14,17
  CALL @niom_lt64
  CMP r1,r0
  JMP[EQ] @niom_mp_ovl_next
  ; elo < cand_end ?
  LD r1,r14,15
  LD r1,r1,#NI_M_ILO
  LD r3,r14,15
  LD r2,r3,#NI_M_IHI
  LD r3,r14,10
  LD r4,r14,11
  CALL @niom_lt64
  CMP r1,r0
  JMP[EQ] @niom_mp_ovl_next
  JMP @niom_mp_space
niom_mp_ovl_next:
  LD r2,r14,14
  ADDI r2,r2,1
  ST r2,r14,14
  JMP @niom_mp_ovl

niom_mp_store:
  LD r1,r14,13
  LD r2,r14,9
  LD r2,r2,#NI_D_GEN
  ST r2,r1,#NI_M_GEN
  LD r2,r14,2
  ST r2,r1,#NI_M_ILO
  LD r2,r14,3
  ST r2,r1,#NI_M_IHI
  LD r2,r14,4
  ST r2,r1,#NI_M_SLO
  LD r2,r14,5
  ST r2,r1,#NI_M_SHI
  LD r2,r14,6
  ST r2,r1,#NI_M_PLO
  LD r2,r14,7
  ST r2,r1,#NI_M_PHI
  LD r2,r14,8
  ST r2,r1,#NI_M_RIGHTS
  ST r0,r1,#NI_M_FLAGS
  ST r0,r1,#NI_M_RES
  ST r13,r1,#NI_M_STATE
  LD r2,r14,12
  ADDI r2,r2,1
  ST r2,r1,#NI_M_ID
  LD r2,r14,9
  LD r3,r2,#NI_D_NMAP
  ADDI r3,r3,1
  ST r3,r2,#NI_D_NMAP
  LD r3,r2,#NI_D_EPOCH
  ADDI r3,r3,1
  ST r3,r2,#NI_D_EPOCH
  LD r1,r14,12
  ADDI r1,r1,1
  JMP @niom_mp_out
niom_mp_bad:
  MOVI r1,#NIOM_EBAD
  JMP @niom_mp_err
niom_mp_noent:
  MOVI r1,#NIOM_ENOENT
  JMP @niom_mp_err
niom_mp_align:
  MOVI r1,#NIOM_EALIGN
  JMP @niom_mp_err
niom_mp_over:
  MOVI r1,#NIOM_EOVER
  JMP @niom_mp_err
niom_mp_space:
  MOVI r1,#NIOM_ESPACE
  JMP @niom_mp_err
niom_mp_wx:
  MOVI r1,#NIOM_ERIGHT
niom_mp_err:
  CALL @niom_err
  MOVI r1,0
niom_mp_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; niom_unmap r1=dom r2=map id -> 0/code.
niom_unmap:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  ST r0,r0,#NIOM_G_ERR
  LD r1,r14,1
  CALL @niom_drec
  CMP r1,r0
  JMP[EQ] @niom_um_bad
  ST r1,r14,3
  LD r2,r1,#NI_D_STATE
  CMP r2,r0
  JMP[EQ] @niom_um_noent
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @niom_um_bad
  MOVI r3,#NIOM_MAX_MAP
  CMP r2,r3
  JMP[GT] @niom_um_bad
  SUB r2,r2,r13
  ST r2,r14,4
  LD r1,r14,1
  CALL @niom_mrec
  ST r1,r14,5
  LD r2,r1,#NI_M_STATE
  CMP r2,r0
  JMP[EQ] @niom_um_noent
  MOVI r2,#NIOM_MSTRIDE
  BFILL r1,r0,r2
  LD r1,r14,3
  LD r2,r1,#NI_D_NMAP
  CMP r2,r0
  JMP[EQ] @niom_um_nmap_ok
  SUB r2,r2,r13
  ST r2,r1,#NI_D_NMAP
niom_um_nmap_ok:
  LD r2,r1,#NI_D_EPOCH
  ADDI r2,r2,1
  ST r2,r1,#NI_D_EPOCH
  MOVI r1,0
  JMP @niom_um_out
niom_um_bad:
  MOVI r1,#NIOM_EBAD
  JMP @niom_um_err
niom_um_noent:
  MOVI r1,#NIOM_ENOENT
niom_um_err:
  CALL @niom_err
niom_um_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; niom_rebind r1=dom r2=id r3..r9 -> 0/code.
niom_rebind:
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
  ST r9,r14,9
  ST r0,r0,#NIOM_G_ERR
  LD r1,r14,1
  CALL @niom_drec
  CMP r1,r0
  JMP[EQ] @niom_rb_bad
  ST r1,r14,10
  LD r2,r1,#NI_D_STATE
  CMP r2,r0
  JMP[EQ] @niom_rb_noent
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @niom_rb_bad
  MOVI r3,#NIOM_MAX_MAP
  CMP r2,r3
  JMP[GT] @niom_rb_bad
  SUB r2,r2,r13
  ST r2,r14,11
  LD r1,r14,1
  CALL @niom_mrec
  ST r1,r14,12
  LD r2,r1,#NI_M_STATE
  CMP r2,r0
  JMP[EQ] @niom_rb_noent
  ; new rights
  LD r2,r14,9
  CMP r2,r0
  JMP[EQ] @niom_rb_bad
  LA r3,0xFFFFFFF8
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @niom_rb_bad
  MOVI r3,6
  BOOL.8 r4,r2,r3
  CMP r4,r3
  JMP[EQ] @niom_rb_wx
  ; new alignment/size
  LD r2,r14,3
  MOVI r3,#NIOM_MASK
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @niom_rb_align
  LD r2,r14,5
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @niom_rb_align
  LD r2,r14,7
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @niom_rb_align
  LD r2,r14,5
  LD r3,r14,6
  CMP r2,r0
  JMP[NE] @niom_rb_szok
  CMP r3,r0
  JMP[EQ] @niom_rb_bad
niom_rb_szok:
  LD r1,r14,3
  LD r2,r14,4
  LD r3,r14,5
  LD r4,r14,6
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @niom_rb_over
  ST r1,r14,13
  ST r2,r14,14
  LD r1,r14,7
  LD r2,r14,8
  LD r3,r14,5
  LD r4,r14,6
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @niom_rb_over
  ; overlap scan excluding this slot
  MOVI r2,0
  ST r2,r14,15
niom_rb_ovl:
  LD r2,r14,15
  MOVI r3,#NIOM_MAX_MAP
  CMP r2,r3
  JMP[GE] @niom_rb_store
  LD r3,r14,11
  CMP r2,r3
  JMP[EQ] @niom_rb_next
  LD r1,r14,1
  CALL @niom_mrec
  ST r1,r14,16
  LD r3,r1,#NI_M_STATE
  CMP r3,r0
  JMP[EQ] @niom_rb_next
  LD r1,r14,16
  LD r1,r1,#NI_M_ILO
  LD r3,r14,16
  LD r2,r3,#NI_M_IHI
  LD r3,r14,16
  LD r3,r3,#NI_M_SLO
  LD r4,r14,16
  LD r4,r4,#NI_M_SHI
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @niom_rb_space
  ST r1,r14,17
  ST r2,r14,18
  LD r1,r14,3
  LD r2,r14,4
  LD r3,r14,17
  LD r4,r14,18
  CALL @niom_lt64
  CMP r1,r0
  JMP[EQ] @niom_rb_next
  LD r1,r14,16
  LD r1,r1,#NI_M_ILO
  LD r3,r14,16
  LD r2,r3,#NI_M_IHI
  LD r3,r14,13
  LD r4,r14,14
  CALL @niom_lt64
  CMP r1,r0
  JMP[EQ] @niom_rb_next
  JMP @niom_rb_space
niom_rb_next:
  LD r2,r14,15
  ADDI r2,r2,1
  ST r2,r14,15
  JMP @niom_rb_ovl
niom_rb_store:
  LD r1,r14,12
  LD r2,r14,3
  ST r2,r1,#NI_M_ILO
  LD r2,r14,4
  ST r2,r1,#NI_M_IHI
  LD r2,r14,5
  ST r2,r1,#NI_M_SLO
  LD r2,r14,6
  ST r2,r1,#NI_M_SHI
  LD r2,r14,7
  ST r2,r1,#NI_M_PLO
  LD r2,r14,8
  ST r2,r1,#NI_M_PHI
  LD r2,r14,9
  ST r2,r1,#NI_M_RIGHTS
  LD r2,r14,10
  LD r2,r2,#NI_D_GEN
  ST r2,r1,#NI_M_GEN
  LD r2,r14,10
  LD r3,r2,#NI_D_EPOCH
  ADDI r3,r3,1
  ST r3,r2,#NI_D_EPOCH
  MOVI r1,0
  JMP @niom_rb_out
niom_rb_bad:
  MOVI r1,#NIOM_EBAD
  JMP @niom_rb_err
niom_rb_noent:
  MOVI r1,#NIOM_ENOENT
  JMP @niom_rb_err
niom_rb_align:
  MOVI r1,#NIOM_EALIGN
  JMP @niom_rb_err
niom_rb_over:
  MOVI r1,#NIOM_EOVER
  JMP @niom_rb_err
niom_rb_space:
  MOVI r1,#NIOM_ESPACE
  JMP @niom_rb_err
niom_rb_wx:
  MOVI r1,#NIOM_ERIGHT
niom_rb_err:
  CALL @niom_err
niom_rb_out:
  ADDI r14,r14,-112
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; niom_revoke r1=dom -> 0/code.
; Bumps the domain generation, clears every map and bumps the epoch.  A DMA
; descriptor that captured the old generation now fails ESTALE.
niom_revoke:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r0,r0,#NIOM_G_ERR
  CALL @niom_drec
  CMP r1,r0
  JMP[EQ] @niom_rv_bad
  ST r1,r14,2
  LD r2,r1,#NI_D_STATE
  CMP r2,r0
  JMP[EQ] @niom_rv_noent
  MOVI r3,0
  ST r3,r14,3
niom_rv_clr:
  LD r3,r14,3
  MOVI r4,#NIOM_MAX_MAP
  CMP r3,r4
  JMP[GE] @niom_rv_cld
  LD r1,r14,1
  CALL @niom_mrec
  MOVI r2,#NIOM_MSTRIDE
  BFILL r1,r0,r2
  LD r3,r14,3
  ADDI r3,r3,1
  ST r3,r14,3
  JMP @niom_rv_clr
niom_rv_cld:
  LD r1,r14,2
  ST r0,r1,#NI_D_NMAP
  LD r2,r1,#NI_D_GEN
  ADDI r2,r2,1
  CMP r2,r0
  JMP[NE] @niom_rv_genok
  MOVI r2,1
niom_rv_genok:
  ST r2,r1,#NI_D_GEN
  LD r2,r1,#NI_D_EPOCH
  ADDI r2,r2,1
  ST r2,r1,#NI_D_EPOCH
  MOVI r1,0
  JMP @niom_rv_out
niom_rv_bad:
  MOVI r1,#NIOM_EBAD
  JMP @niom_rv_err
niom_rv_noent:
  MOVI r1,#NIOM_ENOENT
niom_rv_err:
  CALL @niom_err
niom_rv_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; niom_translate r1=dom r2=gen r3=iova_lo r4=iova_hi r5=len_lo r6=len_hi
;                 r7=rights r8=out -> 0/code; out[0..1]=phys_lo,phys_hi.
niom_translate:
  ST r15,r14,0
  ADDI r14,r14,128
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  ST r7,r14,7
  ST r8,r14,8
  ST r0,r0,#NIOM_G_ERR
  LD r1,r14,1
  CALL @niom_drec
  CMP r1,r0
  JMP[EQ] @niom_tr_bad
  ST r1,r14,9
  LD r2,r1,#NI_D_STATE
  CMP r2,r0
  JMP[EQ] @niom_tr_noent_nofault
  ; generation must match exactly
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @niom_tr_stale
  LD r3,r1,#NI_D_GEN
  CMP r2,r3
  JMP[NE] @niom_tr_stale
  ; len nonzero
  LD r2,r14,5
  LD r3,r14,6
  CMP r2,r0
  JMP[NE] @niom_tr_lenok
  CMP r3,r0
  JMP[EQ] @niom_tr_bad
niom_tr_lenok:
  ; rights valid
  LD r2,r14,7
  CMP r2,r0
  JMP[EQ] @niom_tr_bad
  LA r3,0xFFFFFFF8
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @niom_tr_bad
  ; out pointer
  LD r2,r14,8
  CMP r2,r0
  JMP[EQ] @niom_tr_bad
  ; end = iova + len
  LD r1,r14,3
  LD r2,r14,4
  LD r3,r14,5
  LD r4,r14,6
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @niom_tr_over
  ST r1,r14,10
  ST r2,r14,11
  ST r0,r14,16
  MOVI r2,0
  ST r2,r14,12
niom_tr_loop:
  LD r2,r14,12
  MOVI r3,#NIOM_MAX_MAP
  CMP r2,r3
  JMP[GE] @niom_tr_scan_done
  LD r1,r14,1
  CALL @niom_mrec
  ST r1,r14,13
  LD r3,r1,#NI_M_STATE
  CMP r3,r0
  JMP[EQ] @niom_tr_next
  LD r2,r14,9
  LD r3,r2,#NI_D_GEN
  LD r2,r14,13
  LD r4,r2,#NI_M_GEN
  CMP r3,r4
  JMP[NE] @niom_tr_next
  ; eend = elo + esize
  LD r1,r14,13
  LD r1,r1,#NI_M_ILO
  LD r3,r14,13
  LD r2,r3,#NI_M_IHI
  LD r3,r14,13
  LD r3,r3,#NI_M_SLO
  LD r4,r14,13
  LD r4,r4,#NI_M_SHI
  CALL @n64_add
  ST r1,r14,14
  ST r2,r14,15
  ; ilo >= elo ?
  LD r1,r14,3
  LD r2,r14,4
  LD r3,r14,13
  LD r3,r3,#NI_M_ILO
  LD r4,r14,13
  LD r4,r4,#NI_M_IHI
  CALL @niom_lt64
  CMP r1,r0
  JMP[NE] @niom_tr_next
  ; end <= eend ?
  LD r1,r14,14
  LD r2,r14,15
  LD r3,r14,10
  LD r4,r14,11
  CALL @niom_lt64
  CMP r1,r0
  JMP[NE] @niom_tr_next
  ; rights subset?
  LD r2,r14,13
  LD r2,r2,#NI_M_RIGHTS
  LD r3,r14,7
  BOOL.8 r4,r2,r3
  CMP r4,r3
  JMP[EQ] @niom_tr_hit
  MOVI r4,1
  ST r4,r14,16
  JMP @niom_tr_next
niom_tr_hit:
  ; tmp = iova - elo, then phys = ephys + tmp
  LD r1,r14,3
  LD r2,r14,4
  LD r3,r14,13
  LD r3,r3,#NI_M_ILO
  LD r4,r14,13
  LD r4,r4,#NI_M_IHI
  CALL @n64_sub
  ST r1,r14,17
  ST r2,r14,18
  LD r1,r14,13
  LD r1,r1,#NI_M_PLO
  LD r3,r14,13
  LD r2,r3,#NI_M_PHI
  LD r3,r14,17
  LD r4,r14,18
  CALL @n64_add
  LD r3,r14,8
  ST r1,r3,0
  ST r2,r3,1
  MOVI r1,0
  JMP @niom_tr_out
niom_tr_next:
  LD r2,r14,12
  ADDI r2,r2,1
  ST r2,r14,12
  JMP @niom_tr_loop
niom_tr_scan_done:
  LD r2,r14,16
  CMP r2,r0
  JMP[NE] @niom_tr_right
  MOVI r1,#NIOM_ENOENT
  JMP @niom_tr_fault
niom_tr_right:
  MOVI r1,#NIOM_ERIGHT
  JMP @niom_tr_fault
niom_tr_stale:
  MOVI r1,#NIOM_ESTALE
  JMP @niom_tr_fault
niom_tr_over:
  MOVI r1,#NIOM_EOVER
niom_tr_fault:
  ST r1,r14,19
  LD r1,r14,1
  LD r2,r14,19
  LD r3,r14,3
  LD r4,r14,4
  CALL @niom_fault_add
  LD r1,r14,19
  ST r1,r0,#NIOM_G_ERR
  JMP @niom_tr_out
niom_tr_bad:
  MOVI r1,#NIOM_EBAD
  ST r1,r0,#NIOM_G_ERR
  JMP @niom_tr_out
niom_tr_noent_nofault:
  MOVI r1,#NIOM_ENOENT
  ST r1,r0,#NIOM_G_ERR
niom_tr_out:
  ADDI r14,r14,-128
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; niom_generation r1=dom -> generation / 0.
niom_generation:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @niom_drec
  CMP r1,r0
  JMP[EQ] @niom_gen_none
  LD r2,r1,#NI_D_STATE
  CMP r2,r0
  JMP[EQ] @niom_gen_none
  LD r1,r1,#NI_D_GEN
  JMP @niom_gen_out
niom_gen_none:
  MOVI r1,0
niom_gen_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; niom_epoch r1=dom -> epoch / 0.
niom_epoch:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @niom_drec
  CMP r1,r0
  JMP[EQ] @niom_ep_none
  LD r2,r1,#NI_D_STATE
  CMP r2,r0
  JMP[EQ] @niom_ep_none
  LD r1,r1,#NI_D_EPOCH
  JMP @niom_ep_out
niom_ep_none:
  MOVI r1,0
niom_ep_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; niom_fault_count r1=dom -> count / 0.
niom_fault_count:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @niom_drec
  CMP r1,r0
  JMP[EQ] @niom_fc_none
  LD r2,r1,#NI_D_STATE
  CMP r2,r0
  JMP[EQ] @niom_fc_none
  LD r1,r1,#NI_D_FAULTS
  JMP @niom_fc_out
niom_fc_none:
  MOVI r1,0
niom_fc_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; niom_fault r1=dom r2=slot r3=out -> 0/code.
niom_fault:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r0,r0,#NIOM_G_ERR
  LD r1,r14,1
  CALL @niom_drec
  CMP r1,r0
  JMP[EQ] @niom_ft_bad
  ST r1,r14,4
  LD r2,r1,#NI_D_STATE
  CMP r2,r0
  JMP[EQ] @niom_ft_noent
  LD r2,r14,2
  MOVI r3,4
  CMP r2,r3
  JMP[GE] @niom_ft_bad
  LD r3,r1,#NI_D_FAULTS
  CMP r3,r0
  JMP[EQ] @niom_ft_noent
  MOVI r4,4
  CMP r3,r4
  JMP[GE] @niom_ft_have
  CMP r2,r3
  JMP[GE] @niom_ft_noent
niom_ft_have:
  LD r3,r14,3
  CMP r3,r0
  JMP[EQ] @niom_ft_bad
  SHL r2,r2,2
  ADDI r2,r2,#NI_D_FLOG
  ADD r2,r1,r2
  LD r4,r2,0
  ST r4,r3,0
  LD r4,r2,1
  ST r4,r3,1
  LD r4,r2,2
  ST r4,r3,2
  LD r4,r2,3
  ST r4,r3,3
  MOVI r1,0
  JMP @niom_ft_out
niom_ft_bad:
  MOVI r1,#NIOM_EBAD
  JMP @niom_ft_err
niom_ft_noent:
  MOVI r1,#NIOM_ENOENT
niom_ft_err:
  CALL @niom_err
niom_ft_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; niom_errno -> last error code.
niom_errno:
  LD r1,r0,#NIOM_G_ERR
  RET
