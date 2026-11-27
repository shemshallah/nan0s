; nheap.nas - 64-bit per-NUMA page allocator with 4K/2M/1G free lists.
;
; All pointers/counts are (lo,hi) pairs.  The caller supplies the descriptor
; pool and the per-(node,size) list heads, so the allocator has no hidden
; fixed-size heap.  Lists are LIFO free extents; allocation searches for a
; fitting extent and splits it.  Free is push-only (no coalescing yet).
;
; Context (8 words):
;   +0 desc_base   +1 desc_capacity  +2 desc_used
;   +3 list_base   +4 list_entries   +5 node_count
;   +6 size_count  +7 reserved
;
; Descriptor (8 words):
;   +0 next  +1 base_lo +2 base_hi +3 count_lo +4 count_hi
;   +5..7 reserved
;
; size index: 0 = 4 KiB, 1 = 2 MiB, 2 = 1 GiB.
;
; API:
;   nheap_init  r1=ctx r2=desc_base r3=desc_capacity r4=list_base
;               r5=list_entries r6=node_count -> 0
;   nheap_add   r1=ctx r2=node r3=size r4=base_lo r5=base_hi
;               r6=count_lo r7=count_hi -> 0/-1
;   nheap_alloc r1=ctx r2=node r3=size r4=count_lo r5=count_hi
;               r6=out -> 0/-1; out[0]=base_lo out[1]=base_hi
;   nheap_free  r1=ctx r2=node r3=size r4=base_lo r5=base_hi
;               r6=count_lo r7=count_hi -> 0/-1
;   nheap_stats r1=ctx r2=node r3=size r4=out -> 0/-1
;               out[0..1]=free pages, out[2]=extents,
;               out[4..5]=free bytes

.include "n64.nas"

.equ NH_TMP 0x3B0

; r1=size index -> r1=page bytes lo r2=hi
nh_pagesize:
  CMP r1,r0
  JMP[EQ] @nh_ps4k
  MOVI r3,1
  CMP r1,r3
  JMP[EQ] @nh_ps2m
  LA r1,0x40000000
  MOVI r2,0
  RET
nh_ps2m:
  LA r1,0x200000
  MOVI r2,0
  RET
nh_ps4k:
  MOVI r1,0x1000
  MOVI r2,0
  RET

; r1=ctx r2=node r3=size -> r1=list head address
nh_list_addr:
  MOVI r4,3
  MUL r5,r2,r4
  ADD r5,r5,r3
  LD r6,r1,3
  ADD r1,r6,r5
  RET

; r1=ctx r2=index -> r1=descriptor address
nh_desc_addr:
  SHL r3,r2,3
  LD r4,r1,0
  ADD r1,r4,r3
  RET

nheap_init:
  ST r2,r1,0
  ST r3,r1,1
  ST r0,r1,2
  ST r4,r1,3
  ST r5,r1,4
  ST r6,r1,5
  MOVI r2,3
  ST r2,r1,6
  ST r0,r1,7
  MOVI r7,0
  LA r8,0xFFFFFFFF
nh_init_l:
  CMP r7,r5
  JMP[GE] @nh_init_done
  ADD r9,r4,r7
  ST r8,r9,0
  ADDI r7,r7,1
  JMP @nh_init_l
nh_init_done:
  MOVI r1,0
  RET

nheap_add:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NH_TMP+0
  ST r2,r0,#NH_TMP+1
  ST r3,r0,#NH_TMP+2
  ST r4,r0,#NH_TMP+3
  ST r5,r0,#NH_TMP+4
  ST r6,r0,#NH_TMP+5
  ST r7,r0,#NH_TMP+6

  LD r1,r0,#NH_TMP+0
  LD r2,r0,#NH_TMP+1
  LD r3,r1,5
  CMP r2,r3
  JMP[GE] @nh_add_fail
  LD r3,r0,#NH_TMP+2
  MOVI r4,3
  CMP r3,r4
  JMP[GE] @nh_add_fail
  LD r6,r0,#NH_TMP+5
  LD r7,r0,#NH_TMP+6
  CMP r6,r0
  JMP[NE] @nh_add_cnt_ok
  CMP r7,r0
  JMP[EQ] @nh_add_fail
nh_add_cnt_ok:
  LD r1,r0,#NH_TMP+0
  LD r2,r1,2
  LD r3,r1,1
  CMP r2,r3
  JMP[GE] @nh_add_fail
  ST r2,r0,#NH_TMP+7
  ADDI r3,r2,1
  ST r3,r1,2

  CALL @nh_desc_addr
  ST r1,r0,#NH_TMP+8
  LD r1,r0,#NH_TMP+0
  LD r2,r0,#NH_TMP+1
  LD r3,r0,#NH_TMP+2
  CALL @nh_list_addr
  ST r1,r0,#NH_TMP+9
  LD r2,r1,0
  ST r2,r0,#NH_TMP+10

  LD r1,r0,#NH_TMP+8
  LD r2,r0,#NH_TMP+10
  ST r2,r1,0
  LD r2,r0,#NH_TMP+3
  ST r2,r1,1
  LD r2,r0,#NH_TMP+4
  ST r2,r1,2
  LD r2,r0,#NH_TMP+5
  ST r2,r1,3
  LD r2,r0,#NH_TMP+6
  ST r2,r1,4
  ST r0,r1,5
  ST r0,r1,6
  ST r0,r1,7

  LD r1,r0,#NH_TMP+9
  LD r2,r0,#NH_TMP+7
  ST r2,r1,0
  MOVI r1,0
  JMP @nh_add_done
nh_add_fail:
  LA r1,0xFFFFFFFF
nh_add_done:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

nheap_free:
  JMP @nheap_add

nheap_alloc:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NH_TMP+0
  ST r2,r0,#NH_TMP+1
  ST r3,r0,#NH_TMP+2
  ST r4,r0,#NH_TMP+3
  ST r5,r0,#NH_TMP+4
  ST r6,r0,#NH_TMP+5

  LD r1,r0,#NH_TMP+0
  LD r2,r0,#NH_TMP+1
  LD r3,r1,5
  CMP r2,r3
  JMP[GE] @nh_alloc_fail
  LD r3,r0,#NH_TMP+2
  MOVI r4,3
  CMP r3,r4
  JMP[GE] @nh_alloc_fail

  LD r1,r0,#NH_TMP+0
  LD r2,r0,#NH_TMP+1
  LD r3,r0,#NH_TMP+2
  CALL @nh_list_addr
  ST r1,r0,#NH_TMP+9
  LA r1,0xFFFFFFFF
  ST r1,r0,#NH_TMP+6
  LD r1,r0,#NH_TMP+9
  LD r2,r1,0
  ST r2,r0,#NH_TMP+7

nh_alloc_loop:
  LD r1,r0,#NH_TMP+7
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nh_alloc_fail

  LD r1,r0,#NH_TMP+0
  LD r2,r0,#NH_TMP+7
  CALL @nh_desc_addr
  ST r1,r0,#NH_TMP+8

  LD r3,r0,#NH_TMP+8
  LD r1,r3,3
  LD r2,r3,4
  LD r3,r0,#NH_TMP+3
  LD r4,r0,#NH_TMP+4
  CALL @n64_cmp
  CMP r1,r0
  JMP[LT] @nh_alloc_next

  LD r5,r0,#NH_TMP+5
  LD r1,r0,#NH_TMP+8
  LD r2,r1,1
  ST r2,r5,0
  LD r2,r1,2
  ST r2,r5,1

  LD r3,r0,#NH_TMP+8
  LD r1,r3,3
  LD r2,r3,4
  LD r3,r0,#NH_TMP+3
  LD r4,r0,#NH_TMP+4
  CALL @n64_cmp
  CMP r1,r0
  JMP[NE] @nh_alloc_partial

  LD r1,r0,#NH_TMP+8
  LD r2,r1,0
  ST r2,r0,#NH_TMP+12
  LD r1,r0,#NH_TMP+6
  LA r3,0xFFFFFFFF
  CMP r1,r3
  JMP[EQ] @nh_alloc_rm_head
  LD r1,r0,#NH_TMP+0
  LD r2,r0,#NH_TMP+6
  CALL @nh_desc_addr
  LD r3,r0,#NH_TMP+12
  ST r3,r1,0
  JMP @nh_alloc_ok
nh_alloc_rm_head:
  LD r1,r0,#NH_TMP+9
  LD r2,r0,#NH_TMP+12
  ST r2,r1,0
  JMP @nh_alloc_ok

nh_alloc_partial:
  LD r1,r0,#NH_TMP+2
  CALL @nh_pagesize
  ST r1,r0,#NH_TMP+13
  LD r1,r0,#NH_TMP+3
  LD r2,r0,#NH_TMP+13
  MOVI r3,0
  CALL @n64_mul32
  ST r1,r0,#NH_TMP+10
  ST r2,r0,#NH_TMP+11

  LD r1,r0,#NH_TMP+8
  LD r1,r1,1
  LD r2,r0,#NH_TMP+8
  LD r2,r2,2
  LD r3,r0,#NH_TMP+10
  LD r4,r0,#NH_TMP+11
  CALL @n64_add
  LD r3,r0,#NH_TMP+8
  ST r1,r3,1
  ST r2,r3,2

  LD r1,r0,#NH_TMP+8
  LD r1,r1,3
  LD r2,r0,#NH_TMP+8
  LD r2,r2,4
  LD r3,r0,#NH_TMP+3
  LD r4,r0,#NH_TMP+4
  CALL @n64_sub
  LD r3,r0,#NH_TMP+8
  ST r1,r3,3
  ST r2,r3,4
  JMP @nh_alloc_ok

nh_alloc_next:
  LD r1,r0,#NH_TMP+7
  ST r1,r0,#NH_TMP+6
  LD r1,r0,#NH_TMP+8
  LD r2,r1,0
  ST r2,r0,#NH_TMP+7
  JMP @nh_alloc_loop

nh_alloc_fail:
  LA r1,0xFFFFFFFF
  JMP @nh_alloc_done
nh_alloc_ok:
  MOVI r1,0
nh_alloc_done:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

nheap_stats:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NH_TMP+0
  ST r2,r0,#NH_TMP+1
  ST r3,r0,#NH_TMP+2
  ST r4,r0,#NH_TMP+3

  LD r1,r0,#NH_TMP+0
  LD r2,r0,#NH_TMP+1
  LD r3,r0,#NH_TMP+2
  CALL @nh_list_addr
  LD r6,r1,0

  MOVI r10,0
  MOVI r11,0
  MOVI r12,0
nh_stat_loop:
  LA r1,0xFFFFFFFF
  CMP r6,r1
  JMP[EQ] @nh_stat_done
  LD r1,r0,#NH_TMP+0
  ADD r2,r6,r0
  CALL @nh_desc_addr
  ST r1,r0,#NH_TMP+4
  LD r3,r1,3
  LD r4,r1,4
  ADD r1,r10,r0
  ADD r2,r11,r0
  CALL @n64_add
  ADD r10,r1,r0
  ADD r11,r2,r0
  ADDI r12,r12,1
  LD r1,r0,#NH_TMP+4
  LD r6,r1,0
  JMP @nh_stat_loop

nh_stat_done:
  LD r5,r0,#NH_TMP+3
  ST r10,r5,0
  ST r11,r5,1
  ST r12,r5,2
  ST r0,r5,3
  CMP r11,r0
  JMP[NE] @nh_stat_fail
  LD r1,r0,#NH_TMP+2
  CALL @nh_pagesize
  ADD r3,r2,r0
  ADD r2,r1,r0
  ADD r1,r10,r0
  CALL @n64_mul32
  LD r5,r0,#NH_TMP+3
  ST r1,r5,4
  ST r2,r5,5
  MOVI r1,0
  JMP @nh_stat_out
nh_stat_fail:
  LA r1,0xFFFFFFFF
nh_stat_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
