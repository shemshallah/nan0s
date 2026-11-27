; ncscale.nas - pure-NaN 4096-core topology and x2APIC scale layer.
;
; This is the F4 layer above the per-core NanCore record (nancore.nas).  It
; fills the same record table at 0x400000, owns the online/ready bitmaps and
; the APIC<->logical mapping, and lays out one 16 KiB stack per logical core.
;
; Scale contract
; --------------
; - 4096 logical cores maximum, logical index 0..4095.  The live count is
;   taken from the topology table header and every public index is bounds
;   checked against it, so a 2/4-core machine pays only for 2/4 records even
;   though the address space is fixed.
; - x2APIC ids are full 32-bit values.  0xFFFFFFFF is reserved ("no APIC")
;   and is never a valid table entry.  0xFFFFFFFE is a legal id and is used
;   by the gate to prove there is no 8-bit/16-bit truncation.
; - APIC -> logical is an 8192-slot open-addressed hash (<=50% load at 4096
;   cores); logical -> APIC is the record word NR_APIC.  Sparse ids and ids
;   above 255 are ordinary values.
; - online and dispatch-ready state is two 4096-bit bitmaps plus one 32-bit
;   per-core flags word.  Set and clear are nansmp CAS loops (fetch-add is
;   used only for the counters; adding an already-set bit would carry into
;   the next core's bit), test is a plain load.  There is NO global lock and
;   no lock on the dispatch path: ncs_dispatch_ready is one record lookup and
;   one word load.  ncs_index is a read-only hash probe.
; - map/unmap are hotplug operations, not dispatch operations.  They require
;   the logical core to be offline, and they publish through nsp_fence.
;
; Topology table (all word addresses, caller supplied):
;   +0 magic 0x4E435331 ("NCS1")
;   +1 version 1
;   +2 count 1..4096
;   +3 flags, must be 0
;   +4 .. +4+count-1   APIC id of logical core 0..count-1
;   ncs_init(count, table): count==0 adopts the header count; a nonzero
;   count must match it.  Duplicate/reserved APIC ids are rejected.
;
; Address space (word indices; one NaN word is 8 bytes):
;   0x3FF000  this library's 16-word context
;   0x400000  4096 x 64-word NanCore records (nancore.nas layout)
;   0x440000  4096-bit online bitmap (128 words)
;   0x440080  4096-bit dispatch-ready bitmap (128 words)
;   0x441000  8192 x 2-word APIC hash slots (16 KiB)
;   0x800000  per-core stack arena: 4096 x 0x1000 words
;             [base, base+0x800)  16 KiB stack (0x800 NaN words)
;             [base+0x800, base+0x1000) 16 KiB guard
;   The last stack top is 0x17FF800; the arena ends at 0x1800000.
;
; ABI: r0=0, r13=1, r14=SP (grows up), r15=link.  Arguments r1..r3, result
; r1.  Public routines preserve r6..r12, r13 and r14; r1..r5 and flags are
; scratch.  Non-leaf routines use the nansmp 9-word frame.
;
; Atomic seam: ncscale calls nsp_fetch_add / nsp_cas / nsp_fence from
; nansmp.nas.  The S1 product includes nansmp.nas.  The pure-NaN gate links
; single-CPU stubs with identical value semantics and counts the calls.  No
; spinlock is referenced anywhere in this file.

.equ NCS_MAGIC        0x4E435331
.equ NCS_VER          1
.equ NCS_MAX          4096

.equ NCS_REC_BASE     0x400000
.equ NCS_REC_STRIDE   64
.equ NCS_ONLINE       0x440000
.equ NCS_ONLINE_WORDS 128
.equ NCS_READY        0x440080
.equ NCS_MAP          0x441000
.equ NCS_MAP_SLOTS    8192
.equ NCS_STACKS       0x800000
.equ NCS_STACK_BYTES  0x4000
.equ NCS_STACK_WORDS  0x800
.equ NCS_GUARD_WORDS  0x800
.equ NCS_STACK_STRIDE 0x1000
.equ NCS_CTX          0x3FF000
.equ NCS_CTX_MAGIC    0x4E435343

; context words
.equ NCS_C_MAGIC      0
.equ NCS_C_COUNT      1
.equ NCS_C_TABLE      2
.equ NCS_C_ONLINE_N   3
.equ NCS_C_READY_N    4
.equ NCS_C_MAP_N      5
.equ NCS_C_STACKS     6
.equ NCS_C_STACK_W    7
.equ NCS_C_STRIDE     8
.equ NCS_C_STATE      9
.equ NCS_C_FLAGS      10

; NanCore record fields used here (see nancore.nas)
.equ NR_CPU           0
.equ NR_STATE         1
.equ NR_APIC          20
.equ NR_NODE          21
.equ NR_FLAGS         22
.equ NR_STACK         23
.equ NR_TOP           24

; dispatch flags (record word NR_FLAGS)
.equ NCS_F_ONLINE     1
.equ NCS_F_READY      2
.equ NCS_F_ALL        3

; record states
.equ NCS_OFF          0
.equ NCS_IDLE         4

; hash slot state word
.equ NCS_SLOT_USED    0x80000000
.equ NCS_SLOT_TOMB    0x40000000
.equ NCS_SLOT_INDEX   0x7FFFFFFF

; ---------------------------------------------------------------------------
; small helpers

; r1=addr r2=count -> r1/r2 scratch
ncs_zero_words:
  CMP r2,r0
  JMP[EQ] @ncs_zw_out
ncs_zw_loop:
  ST r0,r1,0
  ADDI r1,r1,1
  ADDI r2,r2,-1
  CMP r2,r0
  JMP[NE] @ncs_zw_loop
ncs_zw_out:
  RET

; r1=addr r2=count r3=stride -> zero every stride-th word
ncs_zero_stride:
  CMP r2,r0
  JMP[EQ] @ncs_zs_out
ncs_zs_loop:
  ST r0,r1,0
  ADD r1,r1,r3
  ADDI r2,r2,-1
  CMP r2,r0
  JMP[NE] @ncs_zs_loop
ncs_zs_out:
  RET

; r1=logical index -> r1=record address or 0 (bounds against live count)
ncs_rec:
  LA r2,#NCS_CTX
  LD r3,r2,0
  LA r4,#NCS_CTX_MAGIC
  CMP r3,r4
  JMP[NE] @ncs_rec_bad
  LD r3,r2,1
  CMP r1,r3
  JMP[GE] @ncs_rec_bad
  SHL r1,r1,6
  LA r2,#NCS_REC_BASE
  ADD r1,r2,r1
  RET
ncs_rec_bad:
  MOVI r1,0
  RET

; r1=apic -> r1=hash slot 0..8191
ncs_hash:
  LA r2,0x9E3779B1
  MUL r1,r1,r2
  SHR r2,r1,16
  BOOL.6 r1,r1,r2
  MOVI r2,0x1FFF
  BOOL.8 r1,r1,r2
  RET

; r1=apic -> r1=slot address of the occupied entry or 0
ncs_findslot:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ncs_fs_bad
  CALL @ncs_hash
  ST r1,r14,3
  LA r2,#NCS_MAP
  ST r2,r14,2
  ST r0,r14,4
ncs_fs_loop:
  LD r5,r14,4
  MOVI r2,#NCS_MAP_SLOTS
  CMP r5,r2
  JMP[GE] @ncs_fs_bad
  LD r2,r14,2
  LD r3,r14,3
  SHL r3,r3,1
  ADD r2,r2,r3
  ST r2,r14,5
  LD r3,r2,1
  CMP r3,r0
  JMP[EQ] @ncs_fs_bad
  LA r4,0x40000000
  CMP r3,r4
  JMP[EQ] @ncs_fs_next
  LD r4,r2,0
  LD r1,r14,1
  CMP r4,r1
  JMP[EQ] @ncs_fs_found
ncs_fs_next:
  LD r3,r14,3
  ADDI r3,r3,1
  MOVI r4,0x1FFF
  BOOL.8 r3,r3,r4
  ST r3,r14,3
  LD r5,r14,4
  ADDI r5,r5,1
  ST r5,r14,4
  JMP @ncs_fs_loop
ncs_fs_found:
  LD r1,r14,5
  JMP @ncs_fs_out
ncs_fs_bad:
  MOVI r1,0
ncs_fs_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; r1=apic -> r1=logical index or 0xFFFFFFFF (read-only; no lock)
ncs_lookup:
  ST r15,r14,0
  ADDI r14,r14,9
  CALL @ncs_findslot
  CMP r1,r0
  JMP[EQ] @ncs_lk_none
  LD r2,r1,1
  LA r3,0x7FFFFFFF
  BOOL.8 r1,r2,r3
  JMP @ncs_lk_out
ncs_lk_none:
  LA r1,0xFFFFFFFF
ncs_lk_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; r1=apic r2=logical index -> 0/-1 (caller has checked uniqueness)
ncs_insert:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  ST r2,r14,2
  CALL @ncs_hash
  ST r1,r14,3
  LA r2,#NCS_MAP
  ST r2,r14,4
  ST r0,r14,5
ncs_ins_loop:
  LD r3,r14,5
  MOVI r4,#NCS_MAP_SLOTS
  CMP r3,r4
  JMP[GE] @ncs_ins_fail
  LD r2,r14,4
  LD r3,r14,3
  SHL r3,r3,1
  ADD r2,r2,r3
  ST r2,r14,6
  LD r3,r2,1
  CMP r3,r0
  JMP[EQ] @ncs_ins_place
  LA r4,0x40000000
  CMP r3,r4
  JMP[EQ] @ncs_ins_place
  LD r3,r14,3
  ADDI r3,r3,1
  MOVI r4,0x1FFF
  BOOL.8 r3,r3,r4
  ST r3,r14,3
  LD r5,r14,5
  ADDI r5,r5,1
  ST r5,r14,5
  JMP @ncs_ins_loop
ncs_ins_place:
  LD r1,r14,6
  LD r2,r14,1
  ST r2,r1,0              ; key first
  CALL @nsp_fence
  LD r1,r14,6
  LD r2,r14,2
  LA r3,0x80000000
  BOOL.14 r3,r3,r2
  ST r3,r1,1              ; publish occupied state
  MOVI r1,0
  JMP @ncs_ins_out
ncs_ins_fail:
  LA r1,0xFFFFFFFF
ncs_ins_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; r1=index r2=bitmap base -> r1=word address r2=one-bit mask
ncs_bit:
  ADD r3,r1,r0
  SHR r4,r3,5
  ADD r1,r2,r4
  MOVI r5,31
  BOOL.8 r4,r3,r5
  LA r5,@ncs_mask_tab
  ADD r5,r5,r4
  LD r2,r5,0
  RET

; r1=addr r2=bits -> r1=old; atomic OR through a nansmp CAS loop.
; A fetch-add is NOT used here: setting an already-set bit would carry into
; the next core's bit (1+1=2), so bitmap publication must be a real OR.
ncs_atom_or:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,0
  ST r3,r14,3
ncs_ao_loop:
  LD r1,r14,1
  LD r2,r14,3
  LD r3,r14,2
  BOOL.14 r4,r2,r3
  ST r4,r14,4
  ADD r2,r2,r0
  ADD r3,r4,r0
  CALL @nsp_cas
  LD r4,r14,3
  CMP r1,r4
  JMP[EQ] @ncs_ao_done
  ST r1,r14,3
  JMP @ncs_ao_loop
ncs_ao_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; r1=addr r2=bits -> r1=old; atomic AND-NOT through a nansmp CAS loop
ncs_atom_andnot:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r1,0
  ST r3,r14,3
ncs_an_loop:
  LD r1,r14,1
  LD r2,r14,3
  LD r3,r14,2
  BOOL.3 r3,r3,r0
  LD r4,r14,3
  BOOL.8 r4,r4,r3
  ST r4,r14,4
  ADD r3,r4,r0
  CALL @nsp_cas
  LD r4,r14,3
  CMP r1,r4
  JMP[EQ] @ncs_an_done
  ST r1,r14,3
  JMP @ncs_an_loop
ncs_an_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; ncs_init r1=expected count (0 = take header count) r2=table -> 0/-1
ncs_init:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  ST r2,r14,2
  LA r3,#NCS_CTX
  ST r0,r3,0
  ST r0,r3,1
  ST r0,r3,3
  ST r0,r3,4
  ST r0,r3,5
  ST r0,r3,10
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @ncs_ni_fail
  LD r4,r2,0
  LA r5,#NCS_MAGIC
  CMP r4,r5
  JMP[NE] @ncs_ni_fail
  LD r4,r2,1
  MOVI r5,#NCS_VER
  CMP r4,r5
  JMP[NE] @ncs_ni_fail
  LD r4,r2,3
  CMP r4,r0
  JMP[NE] @ncs_ni_fail
  LD r4,r2,2
  ST r4,r14,3
  CMP r4,r0
  JMP[EQ] @ncs_ni_fail
  MOVI r5,#NCS_MAX
  CMP r4,r5
  JMP[GT] @ncs_ni_fail
  LD r1,r14,1
  CMP r1,r0
  JMP[EQ] @ncs_ni_count_ok
  CMP r1,r4
  JMP[NE] @ncs_ni_fail
ncs_ni_count_ok:
  LA r3,#NCS_CTX
  LD r4,r14,3
  ST r4,r3,1
  LA r5,#NCS_STACKS
  ST r5,r3,6
  MOVI r5,#NCS_STACK_WORDS
  ST r5,r3,7
  MOVI r5,#NCS_STACK_STRIDE
  ST r5,r3,8
  ST r0,r3,9
  LA r1,#NCS_ONLINE
  MOVI r2,#NCS_ONLINE_WORDS
  CALL @ncs_zero_words
  LA r1,#NCS_READY
  MOVI r2,#NCS_ONLINE_WORDS
  CALL @ncs_zero_words
  LA r1,#NCS_MAP
  ADDI r1,r1,1
  MOVI r2,#NCS_MAP_SLOTS
  MOVI r3,2
  CALL @ncs_zero_stride
  LD r4,r14,3
  MOVI r5,#NCS_REC_STRIDE
  MUL r2,r4,r5
  LA r1,#NCS_REC_BASE
  CALL @ncs_zero_words

  ST r0,r14,4
ncs_ni_fill:
  LD r5,r14,4
  LD r4,r14,3
  CMP r5,r4
  JMP[GE] @ncs_ni_filled
  SHL r3,r5,6
  LA r2,#NCS_REC_BASE
  ADD r3,r2,r3
  ST r3,r14,5
  LD r1,r14,2
  ADDI r1,r1,4
  ADD r1,r1,r5
  LD r1,r1,0
  ST r1,r14,6
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ncs_ni_fail
  CALL @ncs_lookup
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @ncs_ni_fail
  LD r3,r14,5
  LD r2,r14,4
  ST r2,r3,0
  ST r0,r3,1
  LD r2,r14,6
  ST r2,r3,20
  ST r0,r3,21
  ST r0,r3,22
  LD r1,r14,4
  SHL r1,r1,12
  LA r2,#NCS_STACKS
  ADD r1,r2,r1
  ST r1,r3,23
  MOVI r2,#NCS_STACK_WORDS
  ADD r2,r1,r2
  ST r2,r3,24
  LD r1,r14,6
  LD r2,r14,4
  CALL @ncs_insert
  CMP r1,r0
  JMP[NE] @ncs_ni_fail
  LA r3,#NCS_CTX
  LD r4,r3,5
  ADDI r4,r4,1
  ST r4,r3,5
  LD r5,r14,4
  ADDI r5,r5,1
  ST r5,r14,4
  JMP @ncs_ni_fill
ncs_ni_filled:
  CALL @nsp_fence
  LA r3,#NCS_CTX
  LA r4,#NCS_CTX_MAGIC
  ST r4,r3,0
  MOVI r1,0
  JMP @ncs_ni_out
ncs_ni_fail:
  LA r1,0xFFFFFFFF
ncs_ni_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; counts

ncs_count:
  LA r1,#NCS_CTX
  LD r2,r1,0
  LA r3,#NCS_CTX_MAGIC
  CMP r2,r3
  JMP[NE] @ncs_cnt_bad
  LD r1,r1,1
  RET
ncs_cnt_bad:
  MOVI r1,0
  RET

ncs_online_count:
  LA r1,#NCS_CTX
  LD r2,r1,0
  LA r3,#NCS_CTX_MAGIC
  CMP r2,r3
  JMP[NE] @ncs_on_bad
  LD r1,r1,3
  RET
ncs_on_bad:
  MOVI r1,0
  RET

ncs_ready_count:
  LA r1,#NCS_CTX
  LD r2,r1,0
  LA r3,#NCS_CTX_MAGIC
  CMP r2,r3
  JMP[NE] @ncs_rn_bad
  LD r1,r1,4
  RET
ncs_rn_bad:
  MOVI r1,0
  RET

ncs_map_count:
  LA r1,#NCS_CTX
  LD r2,r1,0
  LA r3,#NCS_CTX_MAGIC
  CMP r2,r3
  JMP[NE] @ncs_mn_bad
  LD r1,r1,5
  RET
ncs_mn_bad:
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; APIC <-> logical mapping

; r1=apic -> r1=logical index or 0xFFFFFFFF
ncs_index:
  LA r2,#NCS_CTX
  LD r3,r2,0
  LA r4,#NCS_CTX_MAGIC
  CMP r3,r4
  JMP[NE] @ncs_ix_bad
  JMP @ncs_lookup
ncs_ix_bad:
  LA r1,0xFFFFFFFF
  RET

; r1=logical index -> r1=APIC id or 0xFFFFFFFF
ncs_apic:
  ST r15,r14,0
  ADDI r14,r14,9
  CALL @ncs_rec
  CMP r1,r0
  JMP[EQ] @ncs_ap_bad
  LD r2,r1,20
  ADD r1,r2,r0
  JMP @ncs_ap_out
ncs_ap_bad:
  LA r1,0xFFFFFFFF
ncs_ap_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; r1=apic r2=index -> 0/-1
ncs_map:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  ST r2,r14,2
  ADD r1,r2,r0
  CALL @ncs_rec
  CMP r1,r0
  JMP[EQ] @ncs_map_fail
  ST r1,r14,3
  LD r2,r1,20
  LA r3,0xFFFFFFFF
  CMP r2,r3
  JMP[NE] @ncs_map_fail
  LD r1,r14,1
  CMP r1,r3
  JMP[EQ] @ncs_map_fail
  CALL @ncs_lookup
  LA r3,0xFFFFFFFF
  CMP r1,r3
  JMP[NE] @ncs_map_fail
  LD r1,r14,1
  LD r2,r14,2
  CALL @ncs_insert
  CMP r1,r0
  JMP[NE] @ncs_map_fail
  LD r3,r14,3
  LD r2,r14,1
  ST r2,r3,20
  ST r0,r3,22
  ST r0,r3,1
  LA r3,#NCS_CTX
  LD r4,r3,5
  ADDI r4,r4,1
  ST r4,r3,5
  MOVI r1,0
  JMP @ncs_map_out
ncs_map_fail:
  LA r1,0xFFFFFFFF
ncs_map_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; r1=apic -> 0/-1; core must be offline
ncs_unmap:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  LA r3,#NCS_CTX
  LD r4,r3,0
  LA r5,#NCS_CTX_MAGIC
  CMP r4,r5
  JMP[NE] @ncs_unmap_fail
  CALL @ncs_findslot
  CMP r1,r0
  JMP[EQ] @ncs_unmap_fail
  ST r1,r14,2
  LD r2,r1,1
  LA r3,0x7FFFFFFF
  BOOL.8 r2,r2,r3
  ST r2,r14,3
  ADD r1,r2,r0
  CALL @ncs_online_test
  CMP r1,r0
  JMP[NE] @ncs_unmap_fail
  LD r1,r14,2
  LA r2,0x40000000
  ST r2,r1,1
  LA r3,#NCS_CTX
  LD r4,r3,5
  CMP r4,r0
  JMP[EQ] @ncs_unmap_nocount
  ADDI r4,r4,-1
  ST r4,r3,5
ncs_unmap_nocount:
  LD r1,r14,3
  CALL @ncs_rec
  CMP r1,r0
  JMP[EQ] @ncs_unmap_ok
  LA r2,0xFFFFFFFF
  ST r2,r1,20
  ST r0,r1,22
  ST r0,r1,1
ncs_unmap_ok:
  CALL @nsp_fence
  MOVI r1,0
  JMP @ncs_unmap_out
ncs_unmap_fail:
  LA r1,0xFFFFFFFF
ncs_unmap_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; online bitmap

; r1=index -> 1/0
ncs_online_test:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  CALL @ncs_rec
  CMP r1,r0
  JMP[EQ] @ncs_ot_no
  LD r1,r14,1
  LA r2,#NCS_ONLINE
  CALL @ncs_bit
  LD r3,r1,0
  BOOL.8 r3,r3,r2
  CMP r3,r0
  MOVI[NE] r1,1
  MOVI[EQ] r1,0
  JMP @ncs_ot_out
ncs_ot_no:
  MOVI r1,0
ncs_ot_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; r1=index -> 0/-1 (mapped core only; idempotent)
ncs_online_set:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  CALL @ncs_rec
  CMP r1,r0
  JMP[EQ] @ncs_os_fail
  ST r1,r14,4
  LD r2,r1,20
  LA r3,0xFFFFFFFF
  CMP r2,r3
  JMP[EQ] @ncs_os_fail
  LD r1,r14,1
  LA r2,#NCS_ONLINE
  CALL @ncs_bit
  ST r1,r14,2
  ST r2,r14,3
  CALL @ncs_atom_or
  ST r1,r14,5
  LD r2,r14,3
  BOOL.8 r3,r1,r2
  CMP r3,r0
  JMP[NE] @ncs_os_counted
  LA r1,#NCS_CTX
  ADDI r1,r1,#NCS_C_ONLINE_N
  MOVI r2,1
  CALL @nsp_fetch_add
ncs_os_counted:
  LD r1,r14,4
  ADDI r1,r1,#NR_FLAGS
  MOVI r2,#NCS_F_ONLINE
  CALL @ncs_atom_or
  LD r1,r14,4
  LD r2,r1,1
  CMP r2,r0
  JMP[NE] @ncs_os_state_ok
  MOVI r2,#NCS_IDLE
  ST r2,r1,1
ncs_os_state_ok:
  MOVI r1,0
  JMP @ncs_os_out
ncs_os_fail:
  LA r1,0xFFFFFFFF
ncs_os_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; r1=index -> 0/-1 (clears ready too; idempotent)
ncs_online_clear:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  CALL @ncs_rec
  CMP r1,r0
  JMP[EQ] @ncs_oc_fail
  ST r1,r14,4
  LD r1,r14,1
  CALL @ncs_ready_clear
  LD r1,r14,1
  LA r2,#NCS_ONLINE
  CALL @ncs_bit
  ST r1,r14,2
  ST r2,r14,3
  CALL @ncs_atom_andnot
  ST r1,r14,5
  LD r2,r14,3
  BOOL.8 r3,r1,r2
  CMP r3,r0
  JMP[EQ] @ncs_oc_nocount
  LA r1,#NCS_CTX
  ADDI r1,r1,#NCS_C_ONLINE_N
  LA r2,0xFFFFFFFF
  CALL @nsp_fetch_add
ncs_oc_nocount:
  LD r1,r14,4
  ADDI r1,r1,#NR_FLAGS
  MOVI r2,#NCS_F_ALL
  CALL @ncs_atom_andnot
  LD r1,r14,4
  ST r0,r1,1
  MOVI r1,0
  JMP @ncs_oc_out
ncs_oc_fail:
  LA r1,0xFFFFFFFF
ncs_oc_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; dispatch-ready bitmap and per-core flag

; r1=index -> 1/0
ncs_ready_test:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  CALL @ncs_rec
  CMP r1,r0
  JMP[EQ] @ncs_rt_no
  LD r1,r14,1
  LA r2,#NCS_READY
  CALL @ncs_bit
  LD r3,r1,0
  BOOL.8 r3,r3,r2
  CMP r3,r0
  MOVI[NE] r1,1
  MOVI[EQ] r1,0
  JMP @ncs_rt_out
ncs_rt_no:
  MOVI r1,0
ncs_rt_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; r1=index -> 0/-1 (core must be online; idempotent)
ncs_ready_set:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  CALL @ncs_rec
  CMP r1,r0
  JMP[EQ] @ncs_rs_fail
  ST r1,r14,4
  LD r1,r14,1
  CALL @ncs_online_test
  CMP r1,r0
  JMP[EQ] @ncs_rs_fail
  LD r1,r14,1
  LA r2,#NCS_READY
  CALL @ncs_bit
  ST r1,r14,2
  ST r2,r14,3
  CALL @ncs_atom_or
  ST r1,r14,5
  LD r2,r14,3
  BOOL.8 r3,r1,r2
  CMP r3,r0
  JMP[NE] @ncs_rs_counted
  LA r1,#NCS_CTX
  ADDI r1,r1,#NCS_C_READY_N
  MOVI r2,1
  CALL @nsp_fetch_add
ncs_rs_counted:
  LD r1,r14,4
  ADDI r1,r1,#NR_FLAGS
  MOVI r2,#NCS_F_READY
  CALL @ncs_atom_or
  MOVI r1,0
  JMP @ncs_rs_out
ncs_rs_fail:
  LA r1,0xFFFFFFFF
ncs_rs_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; r1=index -> 0/-1 (idempotent)
ncs_ready_clear:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  CALL @ncs_rec
  CMP r1,r0
  JMP[EQ] @ncs_rc_fail
  ST r1,r14,4
  LD r1,r14,1
  LA r2,#NCS_READY
  CALL @ncs_bit
  ST r1,r14,2
  ST r2,r14,3
  CALL @ncs_atom_andnot
  ST r1,r14,5
  LD r2,r14,3
  BOOL.8 r3,r1,r2
  CMP r3,r0
  JMP[EQ] @ncs_rc_nocount
  LA r1,#NCS_CTX
  ADDI r1,r1,#NCS_C_READY_N
  LA r2,0xFFFFFFFF
  CALL @nsp_fetch_add
ncs_rc_nocount:
  LD r1,r14,4
  ADDI r1,r1,#NR_FLAGS
  MOVI r2,#NCS_F_READY
  CALL @ncs_atom_andnot
  MOVI r1,0
  JMP @ncs_rc_out
ncs_rc_fail:
  LA r1,0xFFFFFFFF
ncs_rc_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; r1=index -> 1 if this core may take a dispatch right now.
; ONE record lookup, ONE word load, no bitmap scan, no lock, no atomic.
ncs_dispatch_ready:
  ST r15,r14,0
  ADDI r14,r14,9
  CALL @ncs_rec
  CMP r1,r0
  JMP[EQ] @ncs_dr_no
  LD r2,r1,22
  MOVI r3,#NCS_F_ALL
  BOOL.8 r2,r2,r3
  CMP r2,r3
  MOVI[NE] r1,0
  MOVI[EQ] r1,1
  JMP @ncs_dr_out
ncs_dr_no:
  MOVI r1,0
ncs_dr_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; per-core stacks and NUMA hint

; r1=index -> r1=stack base or 0
ncs_stack_base:
  ST r15,r14,0
  ADDI r14,r14,9
  CALL @ncs_rec
  CMP r1,r0
  JMP[EQ] @ncs_sb_zero
  LD r2,r1,23
  ADD r1,r2,r0
  JMP @ncs_sb_out
ncs_sb_zero:
  MOVI r1,0
ncs_sb_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; r1=index -> r1=stack top (exclusive) or 0
ncs_stack_top:
  ST r15,r14,0
  ADDI r14,r14,9
  CALL @ncs_rec
  CMP r1,r0
  JMP[EQ] @ncs_st_zero
  LD r2,r1,24
  ADD r1,r2,r0
  JMP @ncs_st_out
ncs_st_zero:
  MOVI r1,0
ncs_st_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; r1=index r2=node -> 0/-1
ncs_set_node:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r2,r14,1
  CALL @ncs_rec
  CMP r1,r0
  JMP[EQ] @ncs_sn_fail
  LD r2,r14,1
  ST r2,r1,21
  MOVI r1,0
  JMP @ncs_sn_out
ncs_sn_fail:
  LA r1,0xFFFFFFFF
ncs_sn_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; r1=index -> r1=node or 0xFFFFFFFF
ncs_node:
  ST r15,r14,0
  ADDI r14,r14,9
  CALL @ncs_rec
  CMP r1,r0
  JMP[EQ] @ncs_nd_bad
  LD r2,r1,21
  ADD r1,r2,r0
  JMP @ncs_nd_out
ncs_nd_bad:
  LA r1,0xFFFFFFFF
ncs_nd_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; one-bit masks for bit 0..31
ncs_mask_tab:
.word 0x00000001, 0x00000002, 0x00000004, 0x00000008
.word 0x00000010, 0x00000020, 0x00000040, 0x00000080
.word 0x00000100, 0x00000200, 0x00000400, 0x00000800
.word 0x00001000, 0x00002000, 0x00004000, 0x00008000
.word 0x00010000, 0x00020000, 0x00040000, 0x00080000
.word 0x00100000, 0x00200000, 0x00400000, 0x00800000
.word 0x01000000, 0x02000000, 0x04000000, 0x08000000
.word 0x10000000, 0x20000000, 0x40000000, 0x80000000
