; nheap_test.nas - per-NUMA 4K/2M/1G allocator proof.
;
; Node 0 gets 1 TiB of 1 GiB pages, node 1 gets 512 GiB.  Allocate, split,
; free and reuse, check 64-bit bases, alignment, page counts and byte totals.
.org 0
JMP @main
.include "../lib/nheap.nas"

main:
MOVI r13,1
MOVI r14,0x7000
LA r1,@ctx
LA r2,@descs
MOVI r3,16
LA r4,@lists
MOVI r5,12
MOVI r6,4
CALL @nheap_init

; node0: base 1 TiB, 1024 x 1 GiB
LA r1,@ctx
MOVI r2,0
MOVI r3,2
MOVI r4,0
MOVI r5,0x100
MOVI r6,0x400
MOVI r7,0
CALL @nheap_add
CMP r1,r0
JMP[NE] @fail

; node1: base 2 TiB, 512 x 1 GiB
LA r1,@ctx
MOVI r2,1
MOVI r3,2
MOVI r4,0
MOVI r5,0x200
MOVI r6,0x200
MOVI r7,0
CALL @nheap_add
CMP r1,r0
JMP[NE] @fail

; node0 stats: 1024 pages, 1 extent, 1 TiB
LA r1,@ctx
MOVI r2,0
MOVI r3,2
LA r4,@stats
CALL @nheap_stats
CMP r1,r0
JMP[NE] @fail
LA r5,@stats
LD r1,r5,0
MOVI r2,0x400
CMP r1,r2
JMP[NE] @fail
LD r1,r5,1
CMP r1,r0
JMP[NE] @fail
LD r1,r5,2
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r5,4
CMP r1,r0
JMP[NE] @fail
LD r1,r5,5
MOVI r2,0x100
CMP r1,r2
JMP[NE] @fail

; alloc 2 x 1 GiB from node0 -> 1 TiB
LA r1,@ctx
MOVI r2,0
MOVI r3,2
MOVI r4,2
MOVI r5,0
LA r6,@out1
CALL @nheap_alloc
CMP r1,r0
JMP[NE] @fail
LA r5,@out1
LD r1,r5,0
CMP r1,r0
JMP[NE] @fail
LD r1,r5,1
MOVI r2,0x100
CMP r1,r2
JMP[NE] @fail

; next 1 GiB -> 1 TiB + 2 GiB
LA r1,@ctx
MOVI r2,0
MOVI r3,2
MOVI r4,1
MOVI r5,0
LA r6,@out2
CALL @nheap_alloc
CMP r1,r0
JMP[NE] @fail
LA r5,@out2
LD r1,r5,0
LA r2,0x80000000
CMP r1,r2
JMP[NE] @fail
LD r1,r5,1
MOVI r2,0x100
CMP r1,r2
JMP[NE] @fail

; alloc 1 GiB from node1 -> 2 TiB
LA r1,@ctx
MOVI r2,1
MOVI r3,2
MOVI r4,1
MOVI r5,0
LA r6,@out3
CALL @nheap_alloc
CMP r1,r0
JMP[NE] @fail
LA r5,@out3
LD r1,r5,0
CMP r1,r0
JMP[NE] @fail
LD r1,r5,1
MOVI r2,0x200
CMP r1,r2
JMP[NE] @fail

; free 1 GiB at 1 TiB, then reuse it
LA r1,@ctx
MOVI r2,0
MOVI r3,2
MOVI r4,0
MOVI r5,0x100
MOVI r6,1
MOVI r7,0
CALL @nheap_free
CMP r1,r0
JMP[NE] @fail

LA r1,@ctx
MOVI r2,0
MOVI r3,2
MOVI r4,1
MOVI r5,0
LA r6,@out4
CALL @nheap_alloc
CMP r1,r0
JMP[NE] @fail
LA r5,@out4
LD r1,r5,0
CMP r1,r0
JMP[NE] @fail
LD r1,r5,1
MOVI r2,0x100
CMP r1,r2
JMP[NE] @fail

; node0 now 1021 pages, 1 extent
LA r1,@ctx
MOVI r2,0
MOVI r3,2
LA r4,@stats
CALL @nheap_stats
CMP r1,r0
JMP[NE] @fail
LA r5,@stats
LD r1,r5,0
MOVI r2,1021
CMP r1,r2
JMP[NE] @fail
LD r1,r5,2
MOVI r2,1
CMP r1,r2
JMP[NE] @fail

; node1 now 511 pages
LA r1,@ctx
MOVI r2,1
MOVI r3,2
LA r4,@stats
CALL @nheap_stats
CMP r1,r0
JMP[NE] @fail
LA r5,@stats
LD r1,r5,0
MOVI r2,511
CMP r1,r2
JMP[NE] @fail

; 4 KiB class: base 4 GiB, 16 pages; alloc 2 then 1
LA r1,@ctx
MOVI r2,0
MOVI r3,0
MOVI r4,0
MOVI r5,1
MOVI r6,16
MOVI r7,0
CALL @nheap_add
CMP r1,r0
JMP[NE] @fail
LA r1,@ctx
MOVI r2,0
MOVI r3,0
MOVI r4,2
MOVI r5,0
LA r6,@out5
CALL @nheap_alloc
CMP r1,r0
JMP[NE] @fail
LA r5,@out5
LD r1,r5,0
CMP r1,r0
JMP[NE] @fail
LD r1,r5,1
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LA r1,@ctx
MOVI r2,0
MOVI r3,0
MOVI r4,1
MOVI r5,0
LA r6,@out6
CALL @nheap_alloc
CMP r1,r0
JMP[NE] @fail
LA r5,@out6
LD r1,r5,0
MOVI r2,0x2000
CMP r1,r2
JMP[NE] @fail
LD r1,r5,1
MOVI r2,1
CMP r1,r2
JMP[NE] @fail

; 2 MiB class: base 8 GiB, 8 pages; alloc 1
LA r1,@ctx
MOVI r2,0
MOVI r3,1
MOVI r4,0
MOVI r5,2
MOVI r6,8
MOVI r7,0
CALL @nheap_add
CMP r1,r0
JMP[NE] @fail
LA r1,@ctx
MOVI r2,0
MOVI r3,1
MOVI r4,1
MOVI r5,0
LA r6,@out7
CALL @nheap_alloc
CMP r1,r0
JMP[NE] @fail
LA r5,@out7
LD r1,r5,0
CMP r1,r0
JMP[NE] @fail
LD r1,r5,1
MOVI r2,2
CMP r1,r2
JMP[NE] @fail

; stats: 4 KiB=13 pages, 2 MiB=7 pages
LA r1,@ctx
MOVI r2,0
MOVI r3,0
LA r4,@stats
CALL @nheap_stats
CMP r1,r0
JMP[NE] @fail
LA r5,@stats
LD r1,r5,0
MOVI r2,13
CMP r1,r2
JMP[NE] @fail
LA r1,@ctx
MOVI r2,0
MOVI r3,1
LA r4,@stats
CALL @nheap_stats
CMP r1,r0
JMP[NE] @fail
LA r5,@stats
LD r1,r5,0
MOVI r2,7
CMP r1,r2
JMP[NE] @fail

; all returned bases are 1 GiB aligned
LA r7,0x3FFFFFFF
LA r4,@out1
LD r1,r4,0
BOOL.8 r2,r1,r7
CMP r2,r0
JMP[NE] @fail
LA r4,@out2
LD r1,r4,0
BOOL.8 r2,r1,r7
CMP r2,r0
JMP[NE] @fail
LA r4,@out3
LD r1,r4,0
BOOL.8 r2,r1,r7
CMP r2,r0
JMP[NE] @fail
LA r4,@out4
LD r1,r4,0
BOOL.8 r2,r1,r7
CMP r2,r0
JMP[NE] @fail

MOVI r1,79
PUTC r1
HALT

fail:
MOVI r1,70
PUTC r1
HALT

ctx:
.word 0,0,0,0,0,0,0,0
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
lists:
.word 0,0,0,0,0,0,0,0,0,0,0,0
out1:
.word 0,0
out2:
.word 0,0
out3:
.word 0,0
out4:
.word 0,0
out5:
.word 0,0
out6:
.word 0,0
out7:
.word 0,0
stats:
.word 0,0,0,0,0,0
