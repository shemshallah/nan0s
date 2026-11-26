; memmap.nas - PMEM v1 boot memory-map consumer (raw NaN16).
;
; Contract: spec/MEMMAP.md; shared numeric constants: memmap_defs.nas.
; The map lives at guest word 0x3F800, below the default nanproc table:
;   +0 magic 0x4D454D50 ("PMEM"), +1 entry_count, +2 version 1, +3 flags,
;   +4 entries {base_word, nwords, kind, flags}.
;
; This library only reads the map.  Producers write it before guest entry.
; There are no compile-time RAM sizes here: every call takes the MEMQ word
; count and validates that the map (and each entry it returns) lies inside it.
;
; Public API (ABI conventions: r0=0, r13=1, r15=link; callees clobber r1..r12):
;   mm_valid  r1=mem_words -> r1=1 map present/valid, 0 absent/invalid
;   mm_count  r1=mem_words -> r1=entry count (1 for the legacy fallback)
;   mm_entry  r1=index, r2=mem_words
;             -> r1=base_word r2=nwords r3=kind r4=flags r5=1 valid/0 bad index
;   mm_top    r1=mem_words
;             -> r1=highest usable base r2=end (exclusive) r3=entry index
;                r4=1 map source / 0 legacy fallback
;
; Fallback: when there is no valid map, entry 0 is the legacy single usable
; range {0, mem_words, MM_K_RAM, 0}, and mm_top returns {0, mem_words, -1}.
; A valid map with no usable entry returns base=0, end=0, index=-1: the boot
; must fail rather than invent RAM across a hole.
;
; Functions reserve the same 9-word frame used by nanproc/nansched:
; [SP] link, [SP+1..8] locals, new SP = old SP+9.

.include "memmap_defs.nas"

.equ MM_FRAME      9
.equ MM_FRAME_NEG  -9

; ---------------------------------------------------------------------------
; mm_valid - is a well-formed PMEM v1 map present inside mem_words?
; Good map: magic, version, 1..MM_MAX entries and the whole entry array fits
; below mem_words.  A truncated/absent map is not repaired here; callers get
; the legacy fallback through mm_entry/mm_top.
mm_valid:
  ADD r2,r1,r0                 ; mem_words
  LA r3,#MM_BASE
  LA r4,#MM_HDR_WORDS
  ADD r4,r4,r3                 ; first entry address
  CMP r2,r4
  JMP[LT] @mmv_bad             ; header itself is outside guest memory
  LD r4,r3,0
  LA r5,#MM_MAGIC
  CMP r4,r5
  JMP[NE] @mmv_bad
  LD r4,r3,2
  LA r5,#MM_VERSION
  CMP r4,r5
  JMP[NE] @mmv_bad
  LD r4,r3,1                   ; entry count
  LA r5,#MM_MAX
  CMP r4,r5
  JMP[GT] @mmv_bad
  CMP r4,r0
  JMP[EQ] @mmv_bad             ; a zero-entry map is not usable
  SHL r4,r4,2                  ; count * MM_ENT_WORDS
  ADD r5,r3,r4
  LA r6,#MM_HDR_WORDS
  ADD r5,r5,r6                 ; end of entry array (exclusive)
  CMP r5,r2
  JMP[GT] @mmv_bad             ; entry array runs past MEMQ memory
  MOVI r1,1
  RET
mmv_bad:
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; mm_count - number of describable entries (legacy fallback is one range).
mm_count:
  ST r15,r14,0
  ADDI r14,r14,#MM_FRAME
  ST r1,r14,1                  ; mem_words
  CALL @mm_valid
  CMP r1,r0
  JMP[EQ] @mmc_fb
  LA r3,#MM_BASE
  LD r1,r3,1
  JMP @mmc_out
mmc_fb:
  MOVI r1,1
mmc_out:
  ADDI r14,r14,#MM_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; mm_entry - one entry by index, or the legacy fallback at index 0.
mm_entry:
  ST r15,r14,0
  ADDI r14,r14,#MM_FRAME
  ST r1,r14,1                  ; index
  ST r2,r14,2                  ; mem_words
  ADD r1,r2,r0
  CALL @mm_valid
  CMP r1,r0
  JMP[EQ] @mme_fb
  LA r3,#MM_BASE
  LD r4,r3,1                   ; count
  LD r5,r14,1
  CMP r5,r4
  JMP[GE] @mme_none
  SHL r6,r5,2
  ADD r6,r6,r3
  LA r4,#MM_HDR_WORDS
  ADD r6,r6,r4                 ; entry address
  LD r1,r6,#MM_E_BASE
  LD r2,r6,#MM_E_WORDS
  LD r3,r6,#MM_E_KIND
  LD r4,r6,#MM_E_FLAGS
  MOVI r5,1
  JMP @mme_out
mme_fb:
  LD r5,r14,1
  CMP r5,r0
  JMP[NE] @mme_none
  MOVI r1,0
  LD r2,r14,2
  MOVI r3,#MM_K_RAM
  MOVI r4,0
  MOVI r5,1
  JMP @mme_out
mme_none:
  MOVI r1,0
  MOVI r2,0
  MOVI r3,0
  MOVI r4,0
  MOVI r5,0
mme_out:
  ADDI r14,r14,#MM_FRAME_NEG
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; mm_top - highest usable (MM_K_RAM, non-empty) entry, clipped to mem_words.
; Returns r4=1 for a real map, r4=0 for the legacy fallback.  Entries from a
; producer must not overlap; this scanner only trusts kind and length.
mm_top:
  ST r15,r14,0
  ADDI r14,r14,#MM_FRAME
  ST r1,r14,1                  ; mem_words
  ST r0,r14,3                  ; best base
  ST r0,r14,4                  ; best end
  LA r2,0xFFFFFFFF
  ST r2,r14,5                  ; best index (-1)
  CALL @mm_valid
  CMP r1,r0
  JMP[EQ] @mmt_fb
  ST r0,r14,6                  ; i = 0
  LA r3,#MM_BASE
  LD r4,r3,1
  ST r4,r14,7                  ; count
  LD r5,r14,1
  ST r5,r14,8                  ; mem_words limit
mmt_loop:
  LD r6,r14,6
  LD r4,r14,7
  CMP r6,r4
  JMP[GE] @mmt_done
  LA r3,#MM_BASE
  SHL r7,r6,2
  ADD r7,r7,r3
  LA r4,#MM_HDR_WORDS
  ADD r7,r7,r4                 ; entry address
  LD r8,r7,#MM_E_BASE
  LD r9,r7,#MM_E_WORDS
  LD r10,r7,#MM_E_KIND
  MOVI r4,#MM_K_RAM
  CMP r10,r4
  JMP[NE] @mmt_next
  CMP r9,r0
  JMP[EQ] @mmt_next
  LD r10,r14,8
  CMP r8,r10
  JMP[GE] @mmt_next
  ADD r9,r9,r8                 ; end = base + nwords
  CMP r9,r10
  JMP[LE] @mmt_clamped
  ADD r9,r10,r0                ; clamp to MEMQ memory
mmt_clamped:
  CMP r9,r8
  JMP[LE] @mmt_next
  LD r10,r14,4
  CMP r9,r10
  JMP[LE] @mmt_next            ; not higher than the best so far
  ST r8,r14,3
  ST r9,r14,4
  ST r6,r14,5
mmt_next:
  ADD r6,r6,r13
  ST r6,r14,6
  JMP @mmt_loop
mmt_done:
  LD r1,r14,3
  LD r2,r14,4
  LD r3,r14,5
  MOVI r4,1
  JMP @mmt_out
mmt_fb:
  MOVI r1,0
  LD r2,r14,1
  LA r3,0xFFFFFFFF
  MOVI r4,0
mmt_out:
  ADDI r14,r14,#MM_FRAME_NEG
  LD r15,r14,0
  RET
