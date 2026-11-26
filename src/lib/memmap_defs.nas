; memmap_defs.nas - shared PMEM v1 boot-memory-map constants.
; Contract: spec/MEMMAP.md.  This file only defines numbers; it emits no code.
;
; The map lives at guest word 0x3F800 (above the 64K cart code, GUI stacks and
; runtime pointer words, below the default nanproc table):
;   +0 magic, +1 count, +2 version, +3 flags, +4 entries {base,nwords,kind,flags}
; All addresses are guest word indices, not physical bytes.
;
; Include this file from producers and consumers; use LA for MM_BASE because
; 0x3F800 does not fit a 16-bit immediate.

.equ MM_BASE      0x3F800
.equ MM_MAGIC     0x4D454D50          ; "PMEM"
.equ MM_VERSION   1
.equ MM_MAX       64
.equ MM_HDR_WORDS 4
.equ MM_ENT_WORDS 4

.equ MM_F_E820    1                   ; source flags in header[3]
.equ MM_F_SYNTH   2

.equ MM_K_RAM     1                   ; usable RAM
.equ MM_K_RESERVED 2                  ; firmware/reserved
.equ MM_K_ACPI    3                   ; ACPI reclaim or NVS
.equ MM_K_DEVICE  4                   ; MMIO / device hole
.equ MM_K_VRAM    5                   ; VRAM / DEV window

; Entry field offsets from an entry base word.
.equ MM_E_BASE    0
.equ MM_E_WORDS   1
.equ MM_E_KIND    2
.equ MM_E_FLAGS   3
