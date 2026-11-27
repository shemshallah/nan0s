; nnuma_test.nas - pure-NaN E820/SRAT/NUMA topology + nheap integration proof.
;
; Synthetic map (sorted, sparse node ids 0 and 2):
;   0x0000000000000000..0x0000000020000000 RAM       node 0 (512 MiB)
;   0x0000000020000000..0x0000000030000000 reserved  node 0
;   0x0000000030000000..0x0000000040000000 hole      node 0
;   0x0000000040000000..0x0000000080000000 RAM       node 0 (1 GiB)
;   0x00000000F0000000..0x00000000F1000000 MMIO      node 2
;   0x00000000F1000000..0x00000000F1100000 ACPI rec  node 2
;   0x00000000F1100000..0x00000000F1200000 ACPI NVS  node 2
;   0x0000000140000000..0x0000000340300000 RAM       node 2 (8 GiB + 3 MiB)
;
; The last range starts at 5 GiB (base_lo=0x40000000, base_hi=1) and ends at
; 13 GiB + 3 MiB (end_hi=3), so 64-bit bases and >4 GiB memory are exercised.
;
; Proof points: phys->node, APIC->node, sparse node count/range, declared
; totals, and a heap partition where node 0 gets 1 x 1 GiB + 256 x 2 MiB,
; node 2 gets 8 x 1 GiB + 1 x 2 MiB + 256 x 4 KiB.  Exhausting each class
; proves the 768 MiB reserved/hole span and the MMIO/ACPI spans were never
; added to (and therefore never allocated from) the heap.

.org 0
JMP @main
.include "../lib/nnuma.nas"

.equ TESTTMP 0x8800

main:
MOVI r13,1
MOVI r14,0x6000

; --- parse, validate, verify declared node totals --------------------------
LA r1,@map
LA r2,@ctx
CALL @nnuma_init
CALL @t_ok
LA r1,@ctx
CALL @nnuma_verify
CALL @t_ok

LA r1,@ctx
CALL @nnuma_node_count
MOVI r2,2
CALL @t_eq
LA r1,@ctx
CALL @nnuma_node_range
MOVI r3,0
MOVI r4,2
CALL @t_eq64
LA r1,@ctx
CALL @nnuma_range_count
MOVI r2,8
CALL @t_eq

; --- kind classification ---------------------------------------------------
MOVI r1,0
CALL @nnuma_kind_class
MOVI r2,1
CALL @t_eq
MOVI r1,1
CALL @nnuma_kind_class
MOVI r2,2
CALL @t_eq
MOVI r1,2
CALL @nnuma_kind_class
MOVI r2,3
CALL @t_eq
MOVI r1,3
CALL @nnuma_kind_class
MOVI r2,3
CALL @t_eq
MOVI r1,4
CALL @nnuma_kind_class
MOVI r2,4
CALL @t_eq
MOVI r1,5
CALL @nnuma_kind_class
MOVI r2,5
CALL @t_eq
MOVI r1,0
CALL @nnuma_kind_usable
MOVI r2,1
CALL @t_eq
MOVI r1,2
CALL @nnuma_kind_usable
MOVI r2,0
CALL @t_eq
MOVI r1,5
CALL @nnuma_kind_usable
MOVI r2,0
CALL @t_eq

; --- range entries: low RAM, reserved, hole, MMIO, ACPI, >4 GiB base ------
LA r1,@ctx
MOVI r2,0
LA r3,@rbuf
CALL @nnuma_range_get
CALL @t_ok
LA r5,@rbuf
LD r1,r5,0
LD r2,r5,1
MOVI r3,0
MOVI r4,0
CALL @t_eq64
LD r1,r5,2
LD r2,r5,3
LA r3,0x20000000
MOVI r4,0
CALL @t_eq64
LD r1,r5,4
MOVI r2,0
CALL @t_eq
LD r1,r5,5
MOVI r2,0
CALL @t_eq

LA r1,@ctx
MOVI r2,1
LA r3,@rbuf
CALL @nnuma_range_get
CALL @t_ok
LA r5,@rbuf
LD r1,r5,4
MOVI r2,1
CALL @t_eq

LA r1,@ctx
MOVI r2,2
LA r3,@rbuf
CALL @nnuma_range_get
CALL @t_ok
LA r5,@rbuf
LD r1,r5,4
MOVI r2,5
CALL @t_eq

LA r1,@ctx
MOVI r2,4
LA r3,@rbuf
CALL @nnuma_range_get
CALL @t_ok
LA r5,@rbuf
LD r1,r5,4
MOVI r2,4
CALL @t_eq

LA r1,@ctx
MOVI r2,5
LA r3,@rbuf
CALL @nnuma_range_get
CALL @t_ok
LA r5,@rbuf
LD r1,r5,4
MOVI r2,2
CALL @t_eq

LA r1,@ctx
MOVI r2,6
LA r3,@rbuf
CALL @nnuma_range_get
CALL @t_ok
LA r5,@rbuf
LD r1,r5,4
MOVI r2,3
CALL @t_eq

; range 7: base 5 GiB, size 8 GiB + 3 MiB, node 2
LA r1,@ctx
MOVI r2,7
LA r3,@rbuf
CALL @nnuma_range_get
CALL @t_ok
LA r5,@rbuf
LD r1,r5,0
LD r2,r5,1
LA r3,0x40000000
MOVI r4,1
CALL @t_eq64
LD r1,r5,2
LD r2,r5,3
LA r3,0x00300000
MOVI r4,2
CALL @t_eq64
LD r1,r5,5
MOVI r2,2
CALL @t_eq

; --- physical address -> node (RAM only; holes/reserved/MMIO fail) ---------
MOVI r1,0
MOVI r2,0
MOVI r3,0
CALL @t_phys
LA r1,0x1FFFFFFF
MOVI r2,0
MOVI r3,0
CALL @t_phys
LA r1,0x40000000
MOVI r2,0
MOVI r3,0
CALL @t_phys
LA r1,0x7FFFFFFF
MOVI r2,0
MOVI r3,0
CALL @t_phys
LA r1,0x40000000
MOVI r2,1
MOVI r3,2
CALL @t_phys
LA r1,0x402FFFFF
MOVI r2,3
MOVI r3,2
CALL @t_phys

LA r1,0x20000000
MOVI r2,0
CALL @t_phys_fail
LA r1,0x30000000
MOVI r2,0
CALL @t_phys_fail
LA r1,0x3FFFFFFF
MOVI r2,0
CALL @t_phys_fail
LA r1,0x80000000
MOVI r2,0
CALL @t_phys_fail
LA r1,0xF0000000
MOVI r2,0
CALL @t_phys_fail
LA r1,0xF1000000
MOVI r2,0
CALL @t_phys_fail
LA r1,0xF1100000
MOVI r2,0
CALL @t_phys_fail
MOVI r1,0
MOVI r2,1
CALL @t_phys_fail
LA r1,0x40300000
MOVI r2,3
CALL @t_phys_fail

; --- APIC -> node ---------------------------------------------------------
MOVI r1,0
MOVI r2,0
CALL @t_apic
MOVI r1,2
MOVI r2,0
CALL @t_apic
MOVI r1,16
MOVI r2,2
CALL @t_apic
MOVI r1,18
MOVI r2,2
CALL @t_apic
LA r1,0x100
MOVI r2,2
CALL @t_apic
MOVI r1,1
CALL @t_apic_fail
LA r1,0x101
CALL @t_apic_fail

LA r1,@ctx
LA r2,0x100
LA r3,@cpubuf
CALL @nnuma_cpu_info
CALL @t_ok
LA r5,@cpubuf
LD r1,r5,0
LA r2,0x100
CALL @t_eq
LD r1,r5,1
MOVI r2,4
CALL @t_eq
LD r1,r5,2
MOVI r2,2
CALL @t_eq
LD r1,r5,3
MOVI r2,1
CALL @t_eq

; --- node totals: RAM only, 64-bit, declared == derived -------------------
LA r1,@ctx
MOVI r2,0
LA r3,@ntot
CALL @nnuma_node_total
CALL @t_ok
LA r5,@ntot
LD r1,r5,0
LD r2,r5,1
LA r3,0x60000000
MOVI r4,0
CALL @t_eq64
LD r1,r5,2
MOVI r2,2
CALL @t_eq
LD r1,r5,3
MOVI r2,2
CALL @t_eq
LD r1,r5,4
LD r2,r5,5
LA r3,0x60000000
MOVI r4,0
CALL @t_eq64
LD r1,r5,6
MOVI r2,2
CALL @t_eq
LD r1,r5,7
MOVI r2,0
CALL @t_eq

LA r1,@ctx
MOVI r2,2
LA r3,@ntot
CALL @nnuma_node_total
CALL @t_ok
LA r5,@ntot
LD r1,r5,0
LD r2,r5,1
LA r3,0x00300000
MOVI r4,2
CALL @t_eq64
LD r1,r5,2
MOVI r2,1
CALL @t_eq
LD r1,r5,3
MOVI r2,3
CALL @t_eq
LD r1,r5,4
LD r2,r5,5
LA r3,0x00300000
MOVI r4,2
CALL @t_eq64
LD r1,r5,6
MOVI r2,3
CALL @t_eq

LA r1,@ctx
MOVI r2,1
LA r3,@ntot
CALL @nnuma_node_total
CALL @t_fail

; --- heap integration -----------------------------------------------------
LA r1,@hctx
LA r2,@descs
MOVI r3,64
LA r4,@lists
MOVI r5,12
MOVI r6,4
CALL @nheap_init
LA r1,@ctx
LA r2,@hctx
CALL @nnuma_heap_add
CALL @t_ok

; node 0: 1 x 1 GiB, 256 x 2 MiB, no 4 KiB
MOVI r1,0
MOVI r2,2
MOVI r3,1
MOVI r4,1
LA r5,0x40000000
MOVI r6,0
CALL @t_stat
MOVI r1,0
MOVI r2,1
MOVI r3,256
MOVI r4,1
LA r5,0x20000000
MOVI r6,0
CALL @t_stat
MOVI r1,0
MOVI r2,0
MOVI r3,0
MOVI r4,0
MOVI r5,0
MOVI r6,0
CALL @t_stat

; node 2: 8 x 1 GiB, 1 x 2 MiB, 256 x 4 KiB
MOVI r1,2
MOVI r2,2
MOVI r3,8
MOVI r4,1
MOVI r5,0
MOVI r6,2
CALL @t_stat
MOVI r1,2
MOVI r2,1
MOVI r3,1
MOVI r4,1
LA r5,0x200000
MOVI r6,0
CALL @t_stat
MOVI r1,2
MOVI r2,0
MOVI r3,256
MOVI r4,1
LA r5,0x100000
MOVI r6,0
CALL @t_stat

; node 1 is structurally absent and has no heap pages
MOVI r1,1
MOVI r2,2
MOVI r3,0
MOVI r4,0
MOVI r5,0
MOVI r6,0
CALL @t_stat

; over-size requests must fail, not underflow an extent
MOVI r1,2
MOVI r2,2
MOVI r3,9
CALL @t_alloc_fail
MOVI r1,2
MOVI r2,0
MOVI r3,257
CALL @t_alloc_fail

; a heap with too few node slots must be rejected before any add
LA r1,@hctx2
LA r2,@descs2
MOVI r3,8
LA r4,@lists2
MOVI r5,6
MOVI r6,2
CALL @nheap_init
LA r1,@ctx
LA r2,@hctx2
CALL @nnuma_heap_add
CALL @t_fail
LA r5,@hctx2
LD r1,r5,2
MOVI r2,0
CALL @t_eq

; per-node allocations, including 64-bit bases above 4 GiB
MOVI r1,2
MOVI r2,2
MOVI r3,1
CALL @t_alloc
LA r3,0x40000000
MOVI r4,1
CALL @t_eq64
MOVI r1,2
MOVI r2,0
MOVI r3,1
CALL @t_alloc
LA r3,0x40200000
MOVI r4,3
CALL @t_eq64
MOVI r1,0
MOVI r2,1
MOVI r3,1
CALL @t_alloc
MOVI r3,0
MOVI r4,0
CALL @t_eq64
MOVI r1,1
MOVI r2,2
MOVI r3,1
CALL @t_alloc_fail

; node 2 after the two allocations: 7 x 1 GiB, 255 x 4 KiB
MOVI r1,2
MOVI r2,2
MOVI r3,7
MOVI r4,1
LA r5,0xC0000000
MOVI r6,1
CALL @t_stat
MOVI r1,2
MOVI r2,0
MOVI r3,255
MOVI r4,1
LA r5,0xFF000
MOVI r6,0
CALL @t_stat

; --- exhaust node 0's 2 MiB class: exactly 256 pages, then failure --------
MOVI r7,0
ST r7,r0,#TESTTMP+20
nn_ex_2m:
LD r7,r0,#TESTTMP+20
MOVI r8,255
CMP r7,r8
JMP[GE] @nn_ex_2m_done
MOVI r1,0
MOVI r2,1
MOVI r3,1
CALL @t_alloc
LA r5,@lastb
ST r1,r5,0
ST r2,r5,1
LD r7,r0,#TESTTMP+20
ADDI r7,r7,1
ST r7,r0,#TESTTMP+20
JMP @nn_ex_2m
nn_ex_2m_done:
LA r5,@lastb
LD r1,r5,0
LD r2,r5,1
LA r3,0x1FE00000
MOVI r4,0
CALL @t_eq64
MOVI r1,0
MOVI r2,1
MOVI r3,0
MOVI r4,0
MOVI r5,0
MOVI r6,0
CALL @t_stat
MOVI r1,0
MOVI r2,1
MOVI r3,1
CALL @t_alloc_fail

; --- exhaust node 2's 1 GiB class: exactly 8 pages, then failure ----------
MOVI r7,0
ST r7,r0,#TESTTMP+20
nn_ex_1g:
LD r7,r0,#TESTTMP+20
MOVI r8,7
CMP r7,r8
JMP[GE] @nn_ex_1g_done
MOVI r1,2
MOVI r2,2
MOVI r3,1
CALL @t_alloc
LA r5,@lastb
ST r1,r5,0
ST r2,r5,1
LD r7,r0,#TESTTMP+20
ADDI r7,r7,1
ST r7,r0,#TESTTMP+20
JMP @nn_ex_1g
nn_ex_1g_done:
LA r5,@lastb
LD r1,r5,0
LD r2,r5,1
MOVI r3,0
MOVI r4,3
CALL @t_eq64
MOVI r1,2
MOVI r2,2
MOVI r3,0
MOVI r4,0
MOVI r5,0
MOVI r6,0
CALL @t_stat
MOVI r1,2
MOVI r2,2
MOVI r3,1
CALL @t_alloc_fail

; --- exhaust node 2's 4 KiB class: exactly 256 pages, then failure --------
MOVI r7,0
ST r7,r0,#TESTTMP+20
nn_ex_4k:
LD r7,r0,#TESTTMP+20
MOVI r8,255
CMP r7,r8
JMP[GE] @nn_ex_4k_done
MOVI r1,2
MOVI r2,0
MOVI r3,1
CALL @t_alloc
LA r5,@lastb
ST r1,r5,0
ST r2,r5,1
LD r7,r0,#TESTTMP+20
ADDI r7,r7,1
ST r7,r0,#TESTTMP+20
JMP @nn_ex_4k
nn_ex_4k_done:
LA r5,@lastb
LD r1,r5,0
LD r2,r5,1
LA r3,0x402FF000
MOVI r4,3
CALL @t_eq64
MOVI r1,2
MOVI r2,0
MOVI r3,0
MOVI r4,0
MOVI r5,0
MOVI r6,0
CALL @t_stat
MOVI r1,2
MOVI r2,0
MOVI r3,1
CALL @t_alloc_fail

; untouched classes: node 0 still has its 1 GiB page, node 2 its 2 MiB page
MOVI r1,0
MOVI r2,2
MOVI r3,1
MOVI r4,1
LA r5,0x40000000
MOVI r6,0
CALL @t_stat
MOVI r1,2
MOVI r2,1
MOVI r3,1
MOVI r4,1
LA r5,0x200000
MOVI r6,0
CALL @t_stat

; bad magic must fail
LA r1,@badmap
LA r2,@ctx2
CALL @nnuma_init
CALL @t_fail

MOVI r1,79
PUTC r1
HALT

fail:
MOVI r1,70
PUTC r1
HALT

; ---------------------------------------------------------------------------
; test helpers
t_ok:
  CMP r1,r0
  JMP[NE] @fail
  RET

t_fail:
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  RET

t_eq:
  CMP r1,r2
  JMP[NE] @fail
  RET

t_eq64:
  CMP r1,r3
  JMP[NE] @fail
  CMP r2,r4
  JMP[NE] @fail
  RET

; r1=lo r2=hi r3=want node
t_phys:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#TESTTMP+0
  ST r2,r0,#TESTTMP+1
  ST r3,r0,#TESTTMP+2
  LA r1,@ctx
  LD r2,r0,#TESTTMP+0
  LD r3,r0,#TESTTMP+1
  LA r4,@pbuf
  CALL @nnuma_phys_node
  CALL @t_ok
  LA r5,@pbuf
  LD r1,r5,0
  LD r2,r0,#TESTTMP+2
  CALL @t_eq
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=lo r2=hi
t_phys_fail:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#TESTTMP+0
  ST r2,r0,#TESTTMP+1
  LA r1,@ctx
  LD r2,r0,#TESTTMP+0
  LD r3,r0,#TESTTMP+1
  LA r4,@pbuf
  CALL @nnuma_phys_node
  CALL @t_fail
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=apic r2=want node
t_apic:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#TESTTMP+0
  ST r2,r0,#TESTTMP+1
  LA r1,@ctx
  LD r2,r0,#TESTTMP+0
  CALL @nnuma_apic_node
  LD r2,r0,#TESTTMP+1
  CALL @t_eq
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=apic
t_apic_fail:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#TESTTMP+0
  LA r1,@ctx
  LD r2,r0,#TESTTMP+0
  CALL @nnuma_apic_node
  CALL @t_fail
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=node r2=size r3=pages r4=extents r5=bytes_lo r6=bytes_hi
t_stat:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#TESTTMP+8
  ST r2,r0,#TESTTMP+9
  ST r3,r0,#TESTTMP+10
  ST r4,r0,#TESTTMP+11
  ST r5,r0,#TESTTMP+12
  ST r6,r0,#TESTTMP+13
  LA r1,@hctx
  LD r2,r0,#TESTTMP+8
  LD r3,r0,#TESTTMP+9
  LA r4,@statsbuf
  CALL @nheap_stats
  CALL @t_ok
  LA r5,@statsbuf
  LD r1,r5,0
  LD r2,r0,#TESTTMP+10
  CALL @t_eq
  LD r1,r5,2
  LD r2,r0,#TESTTMP+11
  CALL @t_eq
  LD r1,r5,4
  LD r2,r0,#TESTTMP+12
  CALL @t_eq
  LD r1,r5,5
  LD r2,r0,#TESTTMP+13
  CALL @t_eq
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=node r2=size r3=count -> r1=base_lo r2=base_hi
t_alloc:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#TESTTMP+16
  ST r2,r0,#TESTTMP+17
  ST r3,r0,#TESTTMP+18
  LA r1,@hctx
  LD r2,r0,#TESTTMP+16
  LD r3,r0,#TESTTMP+17
  LD r4,r0,#TESTTMP+18
  MOVI r5,0
  LA r6,@abuf
  CALL @nheap_alloc
  CALL @t_ok
  LA r5,@abuf
  LD r1,r5,0
  LD r2,r5,1
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=node r2=size r3=count
t_alloc_fail:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#TESTTMP+16
  ST r2,r0,#TESTTMP+17
  ST r3,r0,#TESTTMP+18
  LA r1,@hctx
  LD r2,r0,#TESTTMP+16
  LD r3,r0,#TESTTMP+17
  LD r4,r0,#TESTTMP+18
  MOVI r5,0
  LA r6,@abuf
  CALL @nheap_alloc
  CALL @t_fail
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
.org 0x9000
ctx:
.word 0,0,0,0,0,0,0,0
ctx2:
.word 0,0,0,0,0,0,0,0
hctx:
.word 0,0,0,0,0,0,0,0
hctx2:
.word 0,0,0,0,0,0,0,0
rbuf:
.word 0,0,0,0,0,0,0,0
pbuf:
.word 0,0
cpubuf:
.word 0,0,0,0
ntot:
.word 0,0,0,0,0,0,0,0
statsbuf:
.word 0,0,0,0,0,0
abuf:
.word 0,0
lastb:
.word 0,0
descs:
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
descs2:
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
lists:
.word 0,0,0,0,0,0,0,0,0,0,0,0
lists2:
.word 0,0,0,0,0,0

map:
.word 0x4E554D41, 1, 8, 5, 2, 0, 0, 0
; range 0: RAM node 0, 0 .. 512 MiB
.word 0,0, 0x20000000,0, 0,0, 0,0
; range 1: reserved node 0, 512 MiB .. 768 MiB
.word 0x20000000,0, 0x10000000,0, 1,0, 0,0
; range 2: hole node 0, 768 MiB .. 1 GiB
.word 0x30000000,0, 0x10000000,0, 5,0, 0,0
; range 3: RAM node 0, 1 GiB .. 2 GiB
.word 0x40000000,0, 0x40000000,0, 0,0, 0,0
; range 4: MMIO node 2, 3.75 GiB .. 3.765625 GiB
.word 0xF0000000,0, 0x01000000,0, 4,2, 0,0
; range 5: ACPI reclaim node 2, 1 MiB
.word 0xF1000000,0, 0x00100000,0, 2,2, 0,0
; range 6: ACPI NVS node 2, 1 MiB
.word 0xF1100000,0, 0x00100000,0, 3,2, 0,0
; range 7: RAM node 2, base 5 GiB, size 8 GiB + 3 MiB
.word 0x40000000,1, 0x00300000,2, 0,2, 0,0
; CPU entries: apic, cpu, node, flags
.word 0,0,0,1
.word 2,1,0,1
.word 16,2,2,1
.word 18,3,2,0
.word 256,4,2,1
; Node entries: node, RAM bytes, CPU count
.word 0,0x60000000,0,2
.word 2,0x00300000,2,3

badmap:
.word 0,1,0,0,0,0,0,0
