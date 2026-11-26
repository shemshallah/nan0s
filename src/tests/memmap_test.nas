; memmap_test.nas - focused PMEM v1 consumer test (raw NaN16).
;
; Runs on the x86_64 S1 guest, where the C core has published the synthetic
; map at word 0x3F800.  It exercises mm_valid/mm_count/mm_entry/mm_top on the
; real map, then deliberately erases the magic and checks the legacy fallback
; {0, MEMQ_words, MM_K_RAM}, finally restoring the map.
;
; Results are stored at words 0x2000..0x200E for tools/memmap_gate.sh:
;   0x2000 mm_valid            0x2001 mm_count
;   0x2002 top base            0x2003 top end      0x2004 top index
;   0x2005 top map-source      0x2006 fallback base
;   0x2007 fallback end        0x2008 fallback index
;   0x2009 fallback source     0x200A fallback entry base
;   0x200B fallback entry words 0x200C fallback entry kind
;   0x200D fallback entry valid 0x200E restored valid
;
; No C: the CPUID MEMQ leaf supplies the word count.

.org 0
main:
  MOVI r13,1
  LA r1,0x4E4D00FF
  MOVI r2,1
  CPUID r3,r1,r2
  ADD r12,r3,r0

  ADD r1,r12,r0
  CALL @mm_valid
  LA r10,0x2000
  ST r1,r10,0

  ADD r1,r12,r0
  CALL @mm_count
  LA r10,0x2001
  ST r1,r10,0

  ADD r1,r12,r0
  CALL @mm_top
  LA r10,0x2002
  ST r1,r10,0
  ST r2,r10,1
  ST r3,r10,2
  ST r4,r10,3

  ; Legacy fallback: remove the magic, then re-run the consumers.
  LA r10,@t_magic
  LA r3,#MM_BASE
  LD r4,r3,0
  ST r4,r10,0
  ST r0,r3,0

  ADD r1,r12,r0
  CALL @mm_top
  LA r10,0x2006
  ST r1,r10,0
  ST r2,r10,1
  ST r3,r10,2
  ST r4,r10,3

  MOVI r1,0
  ADD r2,r12,r0
  CALL @mm_entry
  LA r10,0x200A
  ST r1,r10,0
  ST r2,r10,1
  ST r3,r10,2
  ST r5,r10,3

  LA r3,#MM_BASE
  LA r10,@t_magic
  LD r4,r10,0
  ST r4,r3,0

  ADD r1,r12,r0
  CALL @mm_valid
  LA r10,0x200E
  ST r1,r10,0
  HALT

t_magic:
  .word 0

.include "../lib/memmap.nas"
