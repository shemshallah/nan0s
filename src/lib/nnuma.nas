; nnuma.nas - pure-NaN E820/SRAT/NUMA topology for the 64-bit frontier memory
; layer.
;
; The table is a synthetic guest-word image (the same words an ACPI/E820
; importer will fill).  Every address, size and total is a (lo,hi) pair of
; 32-bit words.  Physical limits are enforced at 52 bits (4 PiB), matching
; spec/MEMORY64.md.  Node ids are sparse; entries are sorted and validated.
;
; Table layout (all word offsets):
;   header +0 magic (0x4E554D41 "AMUN" little-endian), +1 version (1),
;          +2 range_count, +3 cpu_count, +4 node_count, +5..7 reserved 0.
;   range entries, 8 words, immediately after the header:
;          +0 base_lo +1 base_hi +2 size_lo +3 size_hi
;          +4 kind +5 node +6 flags +7 reserved
;   cpu entries, 4 words, after the ranges:
;          +0 apic_id +1 cpu_id +2 node +3 flags
;          cpu_id must equal the entry index; apic ids strictly ascending.
;   node entries, 4 words, after the cpus:
;          +0 node_id +1 mem_lo +2 mem_hi +3 cpu_count
;          node ids strictly ascending.
;
; Kinds: 0 RAM, 1 reserved, 2 ACPI reclaim, 3 ACPI NVS, 4 MMIO, 5 hole.
; Only kind 0 (RAM) is usable.  ACPI reclaim is deliberately not handed to
; the allocator: the policy that reclaims it belongs above this parser.
;
; Classes: 0 other, 1 RAM, 2 reserved, 3 ACPI, 4 MMIO, 5 hole.
;
; Context (8 words, caller supplied):
;   +0 table +1 range_count +2 cpu_count +3 node_count
;   +4 ranges_ptr +5 cpus_ptr +6 nodes_ptr +7 reserved 0
;
; API (r0=0, r13=1, r14 soft stack grows up, r15 link):
;   nnuma_init      r1=table r2=ctx -> 0/-1
;   nnuma_range_count r1=ctx -> count
;   nnuma_node_count  r1=ctx -> count
;   nnuma_node_range  r1=ctx -> r1=min node r2=max node
;   nnuma_kind_class  r1=kind -> class
;   nnuma_kind_usable r1=kind -> 1/0
;   nnuma_range_get   r1=ctx r2=index r3=out(8) -> 0/-1
;   nnuma_phys_node   r1=ctx r2=base_lo r3=base_hi r4=node_out -> 0/-1
;                     success only inside a usable RAM range.
;   nnuma_apic_node   r1=ctx r2=apic_id -> node or -1
;   nnuma_cpu_info    r1=ctx r2=apic_id r3=out(4) -> 0/-1
;   nnuma_node_total  r1=ctx r2=node r3=out(8) -> 0/-1
;                     out[0..1]=RAM bytes, out[2]=RAM range count,
;                     out[3]=CPU count, out[4..5]=declared bytes,
;                     out[6]=declared CPUs, out[7]=node id.
;   nnuma_verify      r1=ctx -> 0/-1 (declared totals == derived totals)
;   nnuma_heap_add    r1=ctx r2=nheap_ctx -> 0/-1
;                     Feeds each RAM range once: 1 GiB pages, then 2 MiB,
;                     then 4 KiB, per node.  Holes, reserved, ACPI and MMIO
;                     ranges are never added.  nheap_ctx node_count must be
;                     greater than every RAM node id.
;
; This library includes nheap.nas (which includes n64.nas); include nnuma.nas
; alone to get topology + allocator.

.include "nheap.nas"

.equ NN_MAGIC        0x4E554D41
.equ NN_VERSION      1
.equ NN_HDR          8
.equ NN_MAX_RANGES   256
.equ NN_MAX_CPUS     4096
.equ NN_MAX_NODES    64
.equ NN_PHYS_HI_MAX  0x00100000
.equ NN_KIND_RAM     0
.equ NN_KIND_RES     1
.equ NN_KIND_ACPI_R  2
.equ NN_KIND_ACPI_N  3
.equ NN_KIND_MMIO    4
.equ NN_KIND_HOLE    5

; Scratch words.  The nheap scratch lives at 0x7800; test data starts at
; 0x9000.  This window is not part of any caller object.
.equ NN_TMP          0x8000

; ---------------------------------------------------------------------------
; helpers

; r1=ctx r2=node -> r1=node entry index or -1
nn_node_index:
  LD r3,r1,6
  LD r4,r1,3
  MOVI r5,0
nn_ni_loop:
  CMP r5,r4
  JMP[GE] @nn_ni_fail
  SHL r6,r5,2
  ADD r6,r3,r6
  LD r7,r6,0
  CMP r7,r2
  JMP[EQ] @nn_ni_found
  ADDI r5,r5,1
  JMP @nn_ni_loop
nn_ni_found:
  ADD r1,r5,r0
  RET
nn_ni_fail:
  LA r1,0xFFFFFFFF
  RET

; r1=size index (0=4K,1=2M,2=1G) -> r1=page size in bytes (fits 32 bits)
nn_class_align:
  CMP r1,r0
  JMP[EQ] @nn_ca_4k
  MOVI r2,1
  CMP r1,r2
  JMP[EQ] @nn_ca_2m
  LA r1,0x40000000
  RET
nn_ca_2m:
  LA r1,0x200000
  RET
nn_ca_4k:
  MOVI r1,0x1000
  RET

; r1=lo r2=hi r3=size index -> r1,r2 = value >> (12/21/30)
nn_q_class:
  CMP r3,r0
  JMP[EQ] @nn_q_4k
  MOVI r4,1
  CMP r3,r4
  JMP[EQ] @nn_q_2m
  SHR r4,r1,30
  SHL r5,r2,2
  BOOL.14 r1,r4,r5
  SHR r2,r2,30
  RET
nn_q_2m:
  SHR r4,r1,21
  SHL r5,r2,11
  BOOL.14 r1,r4,r5
  SHR r2,r2,21
  RET
nn_q_4k:
  SHR r4,r1,12
  SHL r5,r2,20
  BOOL.14 r1,r4,r5
  SHR r2,r2,12
  RET

; r1=lo r2=hi r3=size index -> r1,r2 = value << (12/21/30), low 64 bits
nn_shl_class:
  CMP r3,r0
  JMP[EQ] @nn_s_4k
  MOVI r4,1
  CMP r3,r4
  JMP[EQ] @nn_s_2m
  SHL r4,r1,30
  SHR r5,r1,2
  SHL r2,r2,30
  BOOL.14 r2,r2,r5
  ADD r1,r4,r0
  RET
nn_s_2m:
  SHL r4,r1,21
  SHR r5,r1,11
  SHL r2,r2,21
  BOOL.14 r2,r2,r5
  ADD r1,r4,r0
  RET
nn_s_4k:
  SHL r4,r1,12
  SHR r5,r1,20
  SHL r2,r2,12
  BOOL.14 r2,r2,r5
  ADD r1,r4,r0
  RET

; ---------------------------------------------------------------------------
; nnuma_init: validate the header, node, range and CPU entries.  The map must
; be sorted and non-overlapping.  On error the return value is -1 and the
; caller must discard the context (fields are stored as validation proceeds).
nnuma_init:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NN_TMP+0          ; table
  ST r2,r0,#NN_TMP+1          ; ctx

  LD r3,r1,0
  LA r4,#NN_MAGIC
  CMP r3,r4
  JMP[NE] @nn_init_fail
  LD r3,r1,1
  MOVI r4,#NN_VERSION
  CMP r3,r4
  JMP[NE] @nn_init_fail
  LD r3,r1,5
  CMP r3,r0
  JMP[NE] @nn_init_fail
  LD r3,r1,6
  CMP r3,r0
  JMP[NE] @nn_init_fail
  LD r3,r1,7
  CMP r3,r0
  JMP[NE] @nn_init_fail

  LD r4,r1,2               ; ranges
  LD r5,r1,3               ; cpus
  LD r6,r1,4               ; nodes
  MOVI r7,#NN_MAX_RANGES
  CMP r4,r7
  JMP[GT] @nn_init_fail
  MOVI r7,#NN_MAX_CPUS
  CMP r5,r7
  JMP[GT] @nn_init_fail
  MOVI r7,#NN_MAX_NODES
  CMP r6,r7
  JMP[GT] @nn_init_fail
  CMP r6,r0
  JMP[EQ] @nn_init_fail

  LD r2,r0,#NN_TMP+1
  LD r1,r0,#NN_TMP+0
  ST r1,r2,0
  ST r4,r2,1
  ST r5,r2,2
  ST r6,r2,3
  ADDI r7,r1,#NN_HDR
  ST r7,r2,4
  SHL r8,r4,3
  ADD r8,r7,r8
  ST r8,r2,5
  SHL r9,r5,2
  ADD r9,r8,r9
  ST r9,r2,6
  ST r0,r2,7

  ST r4,r0,#NN_TMP+2
  ST r5,r0,#NN_TMP+3
  ST r6,r0,#NN_TMP+4
  ST r7,r0,#NN_TMP+5
  ST r8,r0,#NN_TMP+6
  ST r9,r0,#NN_TMP+7

  ; --- node entries: sorted, unique, plausible declared totals -------------
  MOVI r7,0
  ST r7,r0,#NN_TMP+8
nn_node_val_loop:
  LD r7,r0,#NN_TMP+8
  LD r8,r0,#NN_TMP+4
  CMP r7,r8
  JMP[GE] @nn_node_val_done
  LD r9,r0,#NN_TMP+7
  SHL r10,r7,2
  ADD r9,r9,r10
  ST r9,r0,#NN_TMP+10
  LD r10,r9,0
  MOVI r11,#NN_MAX_NODES
  CMP r10,r11
  JMP[GE] @nn_init_fail
  CMP r7,r0
  JMP[EQ] @nn_node_asc_ok
  ADDI r10,r9,-4
  LD r10,r10,0
  LD r11,r9,0
  CMP r10,r11
  JMP[GE] @nn_init_fail
nn_node_asc_ok:
  LD r10,r9,2
  LA r11,#NN_PHYS_HI_MAX
  CMP r10,r11
  JMP[GE] @nn_init_fail
  LD r10,r9,3
  LD r11,r0,#NN_TMP+3
  CMP r10,r11
  JMP[GT] @nn_init_fail
  LD r7,r0,#NN_TMP+8
  ADDI r7,r7,1
  ST r7,r0,#NN_TMP+8
  JMP @nn_node_val_loop
nn_node_val_done:

  ; --- range entries -------------------------------------------------------
  MOVI r7,0
  ST r7,r0,#NN_TMP+8
  ST r0,r0,#NN_TMP+17
  ST r0,r0,#NN_TMP+18
nn_rng_val_loop:
  LD r7,r0,#NN_TMP+8
  LD r8,r0,#NN_TMP+2
  CMP r7,r8
  JMP[GE] @nn_rng_val_done
  LD r9,r0,#NN_TMP+5
  SHL r10,r7,3
  ADD r9,r9,r10
  ST r9,r0,#NN_TMP+10
  LD r1,r9,0
  ST r1,r0,#NN_TMP+11
  LD r1,r9,1
  ST r1,r0,#NN_TMP+12
  LD r1,r9,2
  ST r1,r0,#NN_TMP+13
  LD r1,r9,3
  ST r1,r0,#NN_TMP+14
  LD r5,r9,4
  ST r5,r0,#NN_TMP+20
  LD r6,r9,5
  ST r6,r0,#NN_TMP+19
  LD r10,r9,6
  CMP r10,r0
  JMP[NE] @nn_init_fail
  LD r10,r9,7
  CMP r10,r0
  JMP[NE] @nn_init_fail
  MOVI r10,#NN_KIND_HOLE
  CMP r5,r10
  JMP[GT] @nn_init_fail
  LD r10,r0,#NN_TMP+13
  LD r11,r0,#NN_TMP+14
  CMP r10,r0
  JMP[NE] @nn_rng_sz_ok
  CMP r11,r0
  JMP[EQ] @nn_init_fail
nn_rng_sz_ok:
  LD r10,r0,#NN_TMP+12
  LA r11,#NN_PHYS_HI_MAX
  CMP r10,r11
  JMP[GE] @nn_init_fail
  LD r10,r0,#NN_TMP+14
  CMP r10,r11
  JMP[GE] @nn_init_fail
  LD r1,r0,#NN_TMP+11
  LD r2,r0,#NN_TMP+12
  LD r3,r0,#NN_TMP+13
  LD r4,r0,#NN_TMP+14
  CALL @n64_add
  ST r1,r0,#NN_TMP+15
  ST r2,r0,#NN_TMP+16
  LA r11,#NN_PHYS_HI_MAX
  CMP r2,r11
  JMP[GE] @nn_init_fail
  LD r1,r0,#NN_TMP+1
  LD r2,r0,#NN_TMP+19
  CALL @nn_node_index
  LA r11,0xFFFFFFFF
  CMP r1,r11
  JMP[EQ] @nn_init_fail
  LD r7,r0,#NN_TMP+8
  CMP r7,r0
  JMP[EQ] @nn_rng_no_prev
  LD r1,r0,#NN_TMP+17
  LD r2,r0,#NN_TMP+18
  LD r3,r0,#NN_TMP+11
  LD r4,r0,#NN_TMP+12
  CALL @n64_cmp
  MOVI r5,1
  CMP r1,r5
  JMP[EQ] @nn_init_fail
nn_rng_no_prev:
  LD r1,r0,#NN_TMP+15
  ST r1,r0,#NN_TMP+17
  LD r1,r0,#NN_TMP+16
  ST r1,r0,#NN_TMP+18
  LD r7,r0,#NN_TMP+8
  ADDI r7,r7,1
  ST r7,r0,#NN_TMP+8
  JMP @nn_rng_val_loop
nn_rng_val_done:

  ; --- cpu entries: cpu_id==index, apic ids ascending, node present -------
  MOVI r7,0
  ST r7,r0,#NN_TMP+8
nn_cpu_val_loop:
  LD r7,r0,#NN_TMP+8
  LD r8,r0,#NN_TMP+3
  CMP r7,r8
  JMP[GE] @nn_cpu_val_done
  LD r9,r0,#NN_TMP+6
  SHL r10,r7,2
  ADD r9,r9,r10
  ST r9,r0,#NN_TMP+10
  LD r10,r9,0
  ST r10,r0,#NN_TMP+22
  LD r5,r9,1
  CMP r5,r7
  JMP[NE] @nn_init_fail
  LD r6,r9,2
  ST r6,r0,#NN_TMP+19
  CMP r7,r0
  JMP[EQ] @nn_cpu_asc_ok
  ADDI r10,r9,-4
  LD r10,r10,0
  LD r11,r0,#NN_TMP+22
  CMP r10,r11
  JMP[GE] @nn_init_fail
nn_cpu_asc_ok:
  LD r1,r0,#NN_TMP+1
  LD r2,r0,#NN_TMP+19
  CALL @nn_node_index
  LA r11,0xFFFFFFFF
  CMP r1,r11
  JMP[EQ] @nn_init_fail
  LD r10,r0,#NN_TMP+22
  ST r10,r0,#NN_TMP+21
  LD r7,r0,#NN_TMP+8
  ADDI r7,r7,1
  ST r7,r0,#NN_TMP+8
  JMP @nn_cpu_val_loop
nn_cpu_val_done:

  MOVI r1,0
  JMP @nn_init_out
nn_init_fail:
  LA r1,0xFFFFFFFF
nn_init_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; small queries

nnuma_range_count:
  LD r1,r1,1
  RET

nnuma_node_count:
  LD r1,r1,3
  RET

; r1=ctx -> r1=min node id r2=max node id
nnuma_node_range:
  LD r2,r1,6
  LD r3,r1,3
  LD r1,r2,0
  ADDI r4,r3,-1
  SHL r5,r4,2
  ADD r6,r2,r5
  LD r2,r6,0
  RET

; r1=kind -> class 0..5
nnuma_kind_class:
  CMP r1,r0
  JMP[EQ] @nn_kc_ram
  MOVI r2,1
  CMP r1,r2
  JMP[EQ] @nn_kc_res
  MOVI r2,2
  CMP r1,r2
  JMP[EQ] @nn_kc_acpi
  MOVI r2,3
  CMP r1,r2
  JMP[EQ] @nn_kc_acpi
  MOVI r2,4
  CMP r1,r2
  JMP[EQ] @nn_kc_mmio
  MOVI r2,5
  CMP r1,r2
  JMP[EQ] @nn_kc_hole
  MOVI r1,0
  RET
nn_kc_ram:
  MOVI r1,1
  RET
nn_kc_res:
  MOVI r1,2
  RET
nn_kc_acpi:
  MOVI r1,3
  RET
nn_kc_mmio:
  MOVI r1,4
  RET
nn_kc_hole:
  MOVI r1,5
  RET

; r1=kind -> 1 only for kind 0 RAM
nnuma_kind_usable:
  CMP r1,r0
  JMP[NE] @nn_ku_no
  MOVI r1,1
  RET
nn_ku_no:
  MOVI r1,0
  RET

; r1=ctx r2=index r3=out(8) -> 0/-1
nnuma_range_get:
  LD r4,r1,1
  CMP r2,r4
  JMP[GE] @nn_rg_fail
  LD r5,r1,4
  SHL r6,r2,3
  ADD r5,r5,r6
  MOVI r4,0
  MOVI r7,8
nn_rg_loop:
  LD r6,r5,0
  ST r6,r3,0
  ADDI r5,r5,1
  ADDI r3,r3,1
  ADDI r4,r4,1
  CMP r4,r7
  JMP[LT] @nn_rg_loop
  MOVI r1,0
  RET
nn_rg_fail:
  LA r1,0xFFFFFFFF
  RET

; r1=ctx r2=base_lo r3=base_hi r4=node_out -> 0/-1 (usable RAM only)
nnuma_phys_node:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NN_TMP+80
  ST r2,r0,#NN_TMP+81
  ST r3,r0,#NN_TMP+82
  ST r4,r0,#NN_TMP+83
  MOVI r7,0
  ST r7,r0,#NN_TMP+84
nn_p_loop:
  LD r7,r0,#NN_TMP+84
  LD r8,r0,#NN_TMP+80
  LD r8,r8,1
  CMP r7,r8
  JMP[GE] @nn_p_fail
  LD r9,r0,#NN_TMP+80
  LD r9,r9,4
  SHL r10,r7,3
  ADD r9,r9,r10
  ST r9,r0,#NN_TMP+85
  ; p vs base
  LD r1,r0,#NN_TMP+81
  LD r2,r0,#NN_TMP+82
  LD r3,r9,0
  LD r4,r9,1
  CALL @n64_cmp
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nn_p_fail
  ; end = base + size
  LD r9,r0,#NN_TMP+85
  LD r1,r9,0
  LD r2,r9,1
  LD r3,r9,2
  LD r4,r9,3
  CALL @n64_add
  ST r1,r0,#NN_TMP+86
  ST r2,r0,#NN_TMP+87
  ; p vs end
  LD r1,r0,#NN_TMP+81
  LD r2,r0,#NN_TMP+82
  LD r3,r0,#NN_TMP+86
  LD r4,r0,#NN_TMP+87
  CALL @n64_cmp
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[NE] @nn_p_next
  ; contained: RAM only
  LD r9,r0,#NN_TMP+85
  LD r1,r9,4
  CMP r1,r0
  JMP[NE] @nn_p_fail
  LD r1,r9,5
  LD r10,r0,#NN_TMP+83
  ST r1,r10,0
  MOVI r1,0
  JMP @nn_p_out
nn_p_next:
  LD r7,r0,#NN_TMP+84
  ADDI r7,r7,1
  ST r7,r0,#NN_TMP+84
  JMP @nn_p_loop
nn_p_fail:
  LA r1,0xFFFFFFFF
nn_p_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=ctx r2=apic_id r3=out(4) -> 0/-1 (out: apic, cpu_id, node, flags)
nnuma_cpu_info:
  LD r4,r1,2
  LD r5,r1,5
  MOVI r6,0
nn_ci_loop:
  CMP r6,r4
  JMP[GE] @nn_ci_fail
  SHL r7,r6,2
  ADD r7,r5,r7
  LD r8,r7,0
  CMP r8,r2
  JMP[EQ] @nn_ci_found
  CMP r8,r2
  JMP[GT] @nn_ci_fail
  ADDI r6,r6,1
  JMP @nn_ci_loop
nn_ci_found:
  ST r8,r3,0
  LD r8,r7,1
  ST r8,r3,1
  LD r8,r7,2
  ST r8,r3,2
  LD r8,r7,3
  ST r8,r3,3
  MOVI r1,0
  RET
nn_ci_fail:
  LA r1,0xFFFFFFFF
  RET

; r1=ctx r2=apic_id -> node or -1
nnuma_apic_node:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r3,#NN_TMP+112
  CALL @nnuma_cpu_info
  CMP r1,r0
  JMP[NE] @nn_an_fail
  LA r3,#NN_TMP+112
  LD r1,r3,2
  JMP @nn_an_out
nn_an_fail:
  LA r1,0xFFFFFFFF
nn_an_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=ctx r2=node r3=out(8) -> 0/-1
nnuma_node_total:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NN_TMP+64
  ST r2,r0,#NN_TMP+65
  ST r3,r0,#NN_TMP+66
  CALL @nn_node_index
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nn_nt_fail
  SHL r4,r1,2
  LD r5,r0,#NN_TMP+64
  LD r5,r5,6
  ADD r5,r5,r4
  LD r6,r0,#NN_TMP+66
  LD r7,r5,0
  ST r7,r6,7
  LD r7,r5,1
  ST r7,r6,4
  LD r7,r5,2
  ST r7,r6,5
  LD r7,r5,3
  ST r7,r6,6
  ST r0,r6,0
  ST r0,r6,1
  ST r0,r6,2
  ST r0,r6,3
  ST r0,r0,#NN_TMP+69
  ST r0,r0,#NN_TMP+70
  ST r0,r0,#NN_TMP+71
  ST r0,r0,#NN_TMP+72

  MOVI r7,0
  ST r7,r0,#NN_TMP+67
nn_nt_rng:
  LD r7,r0,#NN_TMP+67
  LD r8,r0,#NN_TMP+64
  LD r8,r8,1
  CMP r7,r8
  JMP[GE] @nn_nt_rng_done
  LD r9,r0,#NN_TMP+64
  LD r9,r9,4
  SHL r10,r7,3
  ADD r9,r9,r10
  ST r9,r0,#NN_TMP+68
  LD r10,r9,5
  LD r11,r0,#NN_TMP+65
  CMP r10,r11
  JMP[NE] @nn_nt_rng_next
  LD r10,r9,4
  CMP r10,r0
  JMP[NE] @nn_nt_rng_next
  LD r1,r0,#NN_TMP+69
  LD r2,r0,#NN_TMP+70
  LD r3,r9,2
  LD r4,r9,3
  CALL @n64_add
  ST r1,r0,#NN_TMP+69
  ST r2,r0,#NN_TMP+70
  LD r7,r0,#NN_TMP+71
  ADDI r7,r7,1
  ST r7,r0,#NN_TMP+71
nn_nt_rng_next:
  LD r7,r0,#NN_TMP+67
  ADDI r7,r7,1
  ST r7,r0,#NN_TMP+67
  JMP @nn_nt_rng
nn_nt_rng_done:

  MOVI r7,0
  ST r7,r0,#NN_TMP+67
nn_nt_cpu:
  LD r7,r0,#NN_TMP+67
  LD r8,r0,#NN_TMP+64
  LD r8,r8,2
  CMP r7,r8
  JMP[GE] @nn_nt_cpu_done
  LD r9,r0,#NN_TMP+64
  LD r9,r9,5
  SHL r10,r7,2
  ADD r9,r9,r10
  LD r10,r9,2
  LD r11,r0,#NN_TMP+65
  CMP r10,r11
  JMP[NE] @nn_nt_cpu_next
  LD r7,r0,#NN_TMP+72
  ADDI r7,r7,1
  ST r7,r0,#NN_TMP+72
nn_nt_cpu_next:
  LD r7,r0,#NN_TMP+67
  ADDI r7,r7,1
  ST r7,r0,#NN_TMP+67
  JMP @nn_nt_cpu
nn_nt_cpu_done:
  LD r6,r0,#NN_TMP+66
  LD r1,r0,#NN_TMP+69
  ST r1,r6,0
  LD r1,r0,#NN_TMP+70
  ST r1,r6,1
  LD r1,r0,#NN_TMP+71
  ST r1,r6,2
  LD r1,r0,#NN_TMP+72
  ST r1,r6,3
  MOVI r1,0
  JMP @nn_nt_out
nn_nt_fail:
  LA r1,0xFFFFFFFF
nn_nt_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=ctx -> 0/-1: every declared node total and CPU count matches derivation.
nnuma_verify:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NN_TMP+96
  MOVI r7,0
  ST r7,r0,#NN_TMP+97
nn_v_loop:
  LD r7,r0,#NN_TMP+97
  LD r8,r0,#NN_TMP+96
  LD r8,r8,3
  CMP r7,r8
  JMP[GE] @nn_v_ok
  LD r9,r0,#NN_TMP+96
  LD r9,r9,6
  SHL r10,r7,2
  ADD r9,r9,r10
  ST r9,r0,#NN_TMP+98
  LD r2,r9,0
  LD r1,r0,#NN_TMP+96
  LA r3,#NN_TMP+99
  CALL @nnuma_node_total
  CMP r1,r0
  JMP[NE] @nn_v_fail
  LD r9,r0,#NN_TMP+98
  LD r1,r0,#NN_TMP+99
  LD r2,r9,1
  CMP r1,r2
  JMP[NE] @nn_v_fail
  LD r1,r0,#NN_TMP+100
  LD r2,r9,2
  CMP r1,r2
  JMP[NE] @nn_v_fail
  LD r1,r0,#NN_TMP+102
  LD r2,r9,3
  CMP r1,r2
  JMP[NE] @nn_v_fail
  LD r7,r0,#NN_TMP+97
  ADDI r7,r7,1
  ST r7,r0,#NN_TMP+97
  JMP @nn_v_loop
nn_v_ok:
  MOVI r1,0
  JMP @nn_v_out
nn_v_fail:
  LA r1,0xFFFFFFFF
nn_v_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=ctx r2=nheap_ctx -> 0/-1.  One disjoint partition per RAM range:
; full 1 GiB pages first, then 2 MiB, then 4 KiB.  Unaligned prefix and the
; sub-4 KiB tail are left out.  Non-RAM kinds never reach nheap_add.
nnuma_heap_add:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NN_TMP+32
  ST r2,r0,#NN_TMP+33
  LD r3,r2,5
  ST r3,r0,#NN_TMP+49

  ; pre-scan: a too-small heap must not get a partial map
  MOVI r7,0
  ST r7,r0,#NN_TMP+35
nn_ha_pre:
  LD r7,r0,#NN_TMP+35
  LD r8,r0,#NN_TMP+32
  LD r8,r8,1
  CMP r7,r8
  JMP[GE] @nn_ha_pre_ok
  LD r9,r0,#NN_TMP+32
  LD r9,r9,4
  SHL r10,r7,3
  ADD r9,r9,r10
  LD r10,r9,4
  CMP r10,r0
  JMP[NE] @nn_ha_pre_next
  LD r10,r9,5
  LD r11,r0,#NN_TMP+49
  CMP r10,r11
  JMP[GE] @nn_ha_fail
nn_ha_pre_next:
  LD r7,r0,#NN_TMP+35
  ADDI r7,r7,1
  ST r7,r0,#NN_TMP+35
  JMP @nn_ha_pre
nn_ha_pre_ok:

  MOVI r7,0
  ST r7,r0,#NN_TMP+35
nn_ha_rng:
  LD r7,r0,#NN_TMP+35
  LD r8,r0,#NN_TMP+32
  LD r8,r8,1
  CMP r7,r8
  JMP[GE] @nn_ha_ok
  LD r9,r0,#NN_TMP+32
  LD r9,r9,4
  SHL r10,r7,3
  ADD r9,r9,r10
  ST r9,r0,#NN_TMP+50
  LD r10,r9,4
  CMP r10,r0
  JMP[NE] @nn_ha_rng_next
  LD r10,r9,5
  ST r10,r0,#NN_TMP+41
  LD r1,r9,0
  LD r2,r9,1
  LD r3,r9,2
  LD r4,r9,3
  CALL @n64_add
  ST r1,r0,#NN_TMP+39
  ST r2,r0,#NN_TMP+40
  LD r5,r0,#NN_TMP+50
  LD r1,r5,0
  ST r1,r0,#NN_TMP+37
  LD r1,r5,1
  ST r1,r0,#NN_TMP+38
  MOVI r7,2
  ST r7,r0,#NN_TMP+42
nn_ha_class:
  LD r7,r0,#NN_TMP+42
  LA r8,0xFFFFFFFF
  CMP r7,r8
  JMP[EQ] @nn_ha_rng_next
  LD r1,r0,#NN_TMP+42
  CALL @nn_class_align
  ADD r4,r1,r0
  LD r1,r0,#NN_TMP+37
  LD r2,r0,#NN_TMP+38
  ADD r3,r4,r0
  CALL @n64_alignup
  ST r1,r0,#NN_TMP+45
  ST r2,r0,#NN_TMP+46
  LD r3,r0,#NN_TMP+39
  LD r4,r0,#NN_TMP+40
  CALL @n64_cmp
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[NE] @nn_ha_class_next
  LD r1,r0,#NN_TMP+39
  LD r2,r0,#NN_TMP+40
  LD r3,r0,#NN_TMP+45
  LD r4,r0,#NN_TMP+46
  CALL @n64_sub
  LD r3,r0,#NN_TMP+42
  CALL @nn_q_class
  ST r1,r0,#NN_TMP+47
  ST r2,r0,#NN_TMP+48
  CMP r1,r0
  JMP[NE] @nn_ha_have
  CMP r2,r0
  JMP[EQ] @nn_ha_class_next
nn_ha_have:
  LD r1,r0,#NN_TMP+33
  LD r2,r0,#NN_TMP+41
  LD r3,r0,#NN_TMP+42
  LD r4,r0,#NN_TMP+45
  LD r5,r0,#NN_TMP+46
  LD r6,r0,#NN_TMP+47
  LD r7,r0,#NN_TMP+48
  CALL @nheap_add
  CMP r1,r0
  JMP[NE] @nn_ha_fail
  LD r1,r0,#NN_TMP+47
  LD r2,r0,#NN_TMP+48
  LD r3,r0,#NN_TMP+42
  CALL @nn_shl_class
  ADD r3,r1,r0
  ADD r4,r2,r0
  LD r1,r0,#NN_TMP+45
  LD r2,r0,#NN_TMP+46
  CALL @n64_add
  ST r1,r0,#NN_TMP+37
  ST r2,r0,#NN_TMP+38
nn_ha_class_next:
  LD r7,r0,#NN_TMP+42
  ADDI r7,r7,-1
  ST r7,r0,#NN_TMP+42
  JMP @nn_ha_class
nn_ha_rng_next:
  LD r7,r0,#NN_TMP+35
  ADDI r7,r7,1
  ST r7,r0,#NN_TMP+35
  JMP @nn_ha_rng
nn_ha_ok:
  MOVI r1,0
  JMP @nn_ha_out
nn_ha_fail:
  LA r1,0xFFFFFFFF
nn_ha_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
