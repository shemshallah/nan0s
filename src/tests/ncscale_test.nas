; ncscale_test.nas - 4096-core x2APIC/topology/stack/online/ready proof.
;
; The topology table is built at word 0x100000 with 4096 APIC ids
; 0x10000000 + 2*i: every id is above 255, ids are sparse (odd ids absent),
; and ids with the same low byte exist at different high bits.  A second
; 4-entry table at 0x110000 proves the live count shrinks from the header.
;
; The test provides single-CPU stubs for the nansmp atomic seam.  They have
; the nansmp value semantics (fetch-add returns the old word, CAS returns the
; old word) and count calls, so the gate proves ncscale really publishes
; through nsp_fetch_add / nsp_cas / nsp_fence and never takes a spinlock.
.org 0
JMP @main
.include "../lib/ncscale.nas"

.equ T_SMALL 0x110000
.equ T_MAIN  0x100000
.equ T_FADD  0x3FE000
.equ T_CAS   0x3FE001
.equ T_FENCE 0x3FE002

main:
  MOVI r13,1
  MOVI r14,0x7000
  LA r1,0x3FE000
  ST r0,r1,0
  ST r0,r1,1
  ST r0,r1,2

; ---------------------------------------------------------------- bad inputs
  MOVI r1,0
  MOVI r2,0
  CALL @ncs_init
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

; before a successful init the public calls must fail closed
  LA r1,0x20
  CALL @ncs_unmap
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x20
  MOVI r2,0
  CALL @ncs_map
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x20
  CALL @ncs_index
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

  LA r1,0x110000
  MOVI r2,3
  MOVI r3,0x20
  MOVI r4,0x21
  MOVI r5,0x22
  MOVI r6,0x23
  CALL @bt_build

  LA r1,0x110000
  MOVI r2,0x1234
  ST r2,r1,0
  MOVI r1,0
  LA r2,0x110000
  CALL @ncs_init
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

  LA r1,0x110000
  LA r2,#NCS_MAGIC
  ST r2,r1,0
  MOVI r2,2
  ST r2,r1,1
  MOVI r1,0
  LA r2,0x110000
  CALL @ncs_init
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

  LA r1,0x110000
  MOVI r2,1
  ST r2,r1,1
  MOVI r2,1
  ST r2,r1,3
  MOVI r1,0
  LA r2,0x110000
  CALL @ncs_init
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

  LA r1,0x110000
  ST r0,r1,3
  ST r0,r1,2
  MOVI r1,0
  LA r2,0x110000
  CALL @ncs_init
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

  LA r1,0x110000
  MOVI r2,4097
  ST r2,r1,2
  MOVI r1,0
  LA r2,0x110000
  CALL @ncs_init
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

  LA r1,0x110000
  MOVI r2,2
  MOVI r3,0x20
  MOVI r4,0x20
  MOVI r5,0
  MOVI r6,0
  CALL @bt_build
  MOVI r1,0
  LA r2,0x110000
  CALL @ncs_init
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

  LA r1,0x110000
  MOVI r2,2
  MOVI r3,0x20
  LA r4,0xFFFFFFFF
  MOVI r5,0
  MOVI r6,0
  CALL @bt_build
  MOVI r1,0
  LA r2,0x110000
  CALL @ncs_init
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

; ------------------------------------------- dynamic count 3 (small table)
  LA r1,0x110000
  MOVI r2,3
  MOVI r3,0x20
  MOVI r4,0x21
  MOVI r5,0x100
  MOVI r6,0
  CALL @bt_build

  MOVI r1,2
  LA r2,0x110000
  CALL @ncs_init
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

  MOVI r1,4
  LA r2,0x110000
  CALL @ncs_init
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

  MOVI r1,0
  LA r2,0x110000
  CALL @ncs_init
  CMP r1,r0
  JMP[NE] @fail
  CALL @ncs_count
  MOVI r2,3
  CMP r1,r2
  JMP[NE] @fail
  CALL @ncs_map_count
  MOVI r2,3
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x100
  CALL @ncs_index
  MOVI r2,2
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,0
  CALL @ncs_apic
  MOVI r2,0x20
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,3
  CALL @ncs_online_set
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

; -------------------------------------------------- 4096-entry main table
  LA r1,0x100000
  LA r2,#NCS_MAGIC
  ST r2,r1,0
  MOVI r2,1
  ST r2,r1,1
  MOVI r2,4096
  ST r2,r1,2
  ST r0,r1,3
  MOVI r5,0
  LA r6,0x10000000
  LA r7,0x100004
mt_loop:
  SHL r8,r5,1
  ADD r8,r6,r8
  ADD r9,r7,r5
  ST r8,r9,0
  ADDI r5,r5,1
  MOVI r9,4096
  CMP r5,r9
  JMP[LT] @mt_loop

  MOVI r1,4095
  LA r2,0x100000
  CALL @ncs_init
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x101003
  LA r2,0x10000000
  ST r2,r1,0
  MOVI r1,0
  LA r2,0x100000
  CALL @ncs_init
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x101003
  LA r2,0x10001FFE
  ST r2,r1,0
  MOVI r1,0
  LA r2,0x100000
  CALL @ncs_init
  CMP r1,r0
  JMP[NE] @fail
  CALL @ncs_count
  MOVI r2,4096
  CMP r1,r2
  JMP[NE] @fail
  CALL @ncs_map_count
  MOVI r2,4096
  CMP r1,r2
  JMP[NE] @fail
  CALL @ncs_online_count
  CMP r1,r0
  JMP[NE] @fail

; ------------------------------------------------------- APIC map coverage
  MOVI r1,0
  CALL @ncs_apic
  LA r2,0x10000000
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,1
  CALL @ncs_apic
  LA r2,0x10000002
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,4095
  CALL @ncs_apic
  LA r2,0x10001FFE
  CMP r1,r2
  JMP[NE] @fail

  LA r1,0x10000000
  CALL @ncs_index
  CMP r1,r0
  JMP[NE] @fail
  LA r1,0x10000002
  CALL @ncs_index
  MOVI r2,1
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x10001FFE
  CALL @ncs_index
  MOVI r2,4095
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x10000100
  CALL @ncs_index
  MOVI r2,128
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x10000001
  CALL @ncs_index
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x00000000
  CALL @ncs_index
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0xFFFFFFFF
  CALL @ncs_index
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

; ------------------------------------------------ all 4096 stack ranges
  MOVI r8,0
  LA r7,#NCS_STACKS
sl_loop:
  ADD r1,r8,r0
  CALL @ncs_stack_base
  CMP r1,r7
  JMP[NE] @fail
  ADD r1,r8,r0
  CALL @ncs_stack_top
  MOVI r2,#NCS_STACK_WORDS
  ADD r2,r7,r2
  CMP r1,r2
  JMP[NE] @fail
  MOVI r2,0x7FF
  BOOL.8 r3,r7,r2
  CMP r3,r0
  JMP[NE] @fail
  SHL r3,r7,3
  MOVI r2,0x3FFF
  BOOL.8 r3,r3,r2
  CMP r3,r0
  JMP[NE] @fail
  MOVI r2,#NCS_STACK_STRIDE
  ADD r7,r7,r2
  ADDI r8,r8,1
  MOVI r2,4096
  CMP r8,r2
  JMP[LT] @sl_loop
  LA r2,0x1800000
  CMP r7,r2
  JMP[NE] @fail

; ------------------------------------------------ guard words stay untouched
  MOVI r1,0
  CALL @ncs_stack_base
  ADD r6,r1,r0
  MOVI r2,0x1111
  ST r2,r6,0
  MOVI r2,0x7FF
  ADD r2,r6,r2
  MOVI r3,0x2222
  ST r3,r2,0
  MOVI r2,#NCS_STACK_WORDS
  ADD r2,r6,r2
  LD r3,r2,0
  CMP r3,r0
  JMP[NE] @fail
  MOVI r1,1
  CALL @ncs_stack_base
  LD r3,r1,0
  CMP r3,r0
  JMP[NE] @fail
  MOVI r1,4095
  CALL @ncs_stack_base
  ADD r6,r1,r0
  MOVI r2,0x7FF
  ADD r2,r6,r2
  MOVI r3,0x3333
  ST r3,r2,0
  MOVI r2,#NCS_STACK_WORDS
  ADD r2,r6,r2
  LD r3,r2,0
  CMP r3,r0
  JMP[NE] @fail

; --------------------------------------------------------- online/offline
  MOVI r1,0
  CALL @ncs_online_test
  CMP r1,r0
  JMP[NE] @fail
  CALL @ncs_ready_count
  CMP r1,r0
  JMP[NE] @fail

  MOVI r1,0
  CALL @ncs_online_set
  CMP r1,r0
  JMP[NE] @fail
  MOVI r1,0
  CALL @ncs_online_test
  MOVI r2,1
  CMP r1,r2
  JMP[NE] @fail
  CALL @ncs_online_count
  MOVI r2,1
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,0
  CALL @ncs_online_set
  CMP r1,r0
  JMP[NE] @fail
  CALL @ncs_online_count
  MOVI r2,1
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,0
  CALL @ncs_dispatch_ready
  CMP r1,r0
  JMP[NE] @fail

  MOVI r1,0
  CALL @ncs_ready_set
  CMP r1,r0
  JMP[NE] @fail
  MOVI r1,0
  CALL @ncs_ready_test
  MOVI r2,1
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,0
  CALL @ncs_dispatch_ready
  MOVI r2,1
  CMP r1,r2
  JMP[NE] @fail
  CALL @ncs_ready_count
  MOVI r2,1
  CMP r1,r2
  JMP[NE] @fail

  MOVI r1,4095
  CALL @ncs_online_set
  CMP r1,r0
  JMP[NE] @fail
  MOVI r1,4095
  CALL @ncs_ready_set
  CMP r1,r0
  JMP[NE] @fail
  MOVI r1,4095
  CALL @ncs_dispatch_ready
  MOVI r2,1
  CMP r1,r2
  JMP[NE] @fail
  CALL @ncs_online_count
  MOVI r2,2
  CMP r1,r2
  JMP[NE] @fail
  CALL @ncs_ready_count
  MOVI r2,2
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,100
  CALL @ncs_dispatch_ready
  CMP r1,r0
  JMP[NE] @fail

  MOVI r1,0
  CALL @ncs_online_clear
  CMP r1,r0
  JMP[NE] @fail
  MOVI r1,0
  CALL @ncs_online_test
  CMP r1,r0
  JMP[NE] @fail
  MOVI r1,0
  CALL @ncs_ready_test
  CMP r1,r0
  JMP[NE] @fail
  MOVI r1,0
  CALL @ncs_dispatch_ready
  CMP r1,r0
  JMP[NE] @fail
  CALL @ncs_online_count
  MOVI r2,1
  CMP r1,r2
  JMP[NE] @fail
  CALL @ncs_ready_count
  MOVI r2,1
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,0
  CALL @ncs_online_clear
  CMP r1,r0
  JMP[NE] @fail
  CALL @ncs_online_count
  MOVI r2,1
  CMP r1,r2
  JMP[NE] @fail

  MOVI r1,4096
  CALL @ncs_online_set
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,4096
  CALL @ncs_online_test
  CMP r1,r0
  JMP[NE] @fail
  MOVI r1,4096
  CALL @ncs_ready_set
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,4096
  CALL @ncs_dispatch_ready
  CMP r1,r0
  JMP[NE] @fail
  MOVI r1,4096
  CALL @ncs_stack_base
  CMP r1,r0
  JMP[NE] @fail
  MOVI r1,4096
  CALL @ncs_apic
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

  MOVI r1,4095
  CALL @ncs_online_clear
  CMP r1,r0
  JMP[NE] @fail
  CALL @ncs_online_count
  CMP r1,r0
  JMP[NE] @fail
  CALL @ncs_ready_count
  CMP r1,r0
  JMP[NE] @fail

; ------------------------------------------------------------ map / unmap
  LA r1,0x100000C8
  CALL @ncs_index
  MOVI r2,100
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x100000C8
  CALL @ncs_unmap
  CMP r1,r0
  JMP[NE] @fail
  LA r1,0x100000C8
  CALL @ncs_index
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,100
  CALL @ncs_apic
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x100000C8
  CALL @ncs_unmap
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

  LA r1,0x100000C8
  MOVI r2,100
  CALL @ncs_map
  CMP r1,r0
  JMP[NE] @fail
  LA r1,0x100000C8
  CALL @ncs_index
  MOVI r2,100
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x100000C8
  MOVI r2,101
  CALL @ncs_map
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x20000000
  MOVI r2,100
  CALL @ncs_map
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

  LA r1,0x100000C8
  CALL @ncs_unmap
  CMP r1,r0
  JMP[NE] @fail
  LA r1,0xFFFFFFFE
  MOVI r2,100
  CALL @ncs_map
  CMP r1,r0
  JMP[NE] @fail
  LA r1,0xFFFFFFFE
  CALL @ncs_index
  MOVI r2,100
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,100
  CALL @ncs_apic
  LA r2,0xFFFFFFFE
  CMP r1,r2
  JMP[NE] @fail

  LA r1,0x100000CC
  CALL @ncs_unmap
  CMP r1,r0
  JMP[NE] @fail
  LA r1,0xFFFFFFFF
  MOVI r2,102
  CALL @ncs_map
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0xF0000000
  MOVI r2,102
  CALL @ncs_map
  CMP r1,r0
  JMP[NE] @fail
  LA r1,0xF0000000
  CALL @ncs_index
  MOVI r2,102
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,102
  CALL @ncs_apic
  LA r2,0xF0000000
  CMP r1,r2
  JMP[NE] @fail

  MOVI r1,200
  CALL @ncs_online_set
  CMP r1,r0
  JMP[NE] @fail
  LA r1,0x10000190
  CALL @ncs_unmap
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,200
  CALL @ncs_online_clear
  CMP r1,r0
  JMP[NE] @fail
  LA r1,0x10000190
  CALL @ncs_unmap
  CMP r1,r0
  JMP[NE] @fail
  LA r1,0x10000190
  MOVI r2,200
  CALL @ncs_map
  CMP r1,r0
  JMP[NE] @fail
  CALL @ncs_map_count
  MOVI r2,4096
  CMP r1,r2
  JMP[NE] @fail

  MOVI r1,4095
  MOVI r2,7
  CALL @ncs_set_node
  CMP r1,r0
  JMP[NE] @fail
  MOVI r1,4095
  CALL @ncs_node
  MOVI r2,7
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,4096
  MOVI r2,7
  CALL @ncs_set_node
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail

; --------------------------------------- dynamic shrink to 4, x2APIC 0x100
  LA r1,0x110000
  MOVI r2,4
  MOVI r3,0x20
  MOVI r4,0x21
  MOVI r5,0x100
  LA r6,0xFFFFFFFE
  CALL @bt_build
  MOVI r1,4
  LA r2,0x110000
  CALL @ncs_init
  CMP r1,r0
  JMP[NE] @fail
  CALL @ncs_count
  MOVI r2,4
  CMP r1,r2
  JMP[NE] @fail
  CALL @ncs_map_count
  MOVI r2,4
  CMP r1,r2
  JMP[NE] @fail
  LA r1,0x100
  CALL @ncs_index
  MOVI r2,2
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,3
  CALL @ncs_apic
  LA r2,0xFFFFFFFE
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,3
  CALL @ncs_online_set
  CMP r1,r0
  JMP[NE] @fail
  MOVI r1,3
  CALL @ncs_ready_set
  CMP r1,r0
  JMP[NE] @fail
  MOVI r1,3
  CALL @ncs_dispatch_ready
  MOVI r2,1
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,4
  CALL @ncs_online_set
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,3
  CALL @ncs_stack_base
  LA r2,0x803000
  CMP r1,r2
  JMP[NE] @fail
  MOVI r1,4
  CALL @ncs_stack_base
  CMP r1,r0
  JMP[NE] @fail

; ------------------------------------------ atomic seam actually exercised
  LA r1,0x3FE000
  LD r2,r1,0
  CMP r2,r0
  JMP[EQ] @fail
  LA r1,0x3FE001
  LD r2,r1,0
  CMP r2,r0
  JMP[EQ] @fail
  LA r1,0x3FE002
  LD r2,r1,0
  CMP r2,r0
  JMP[EQ] @fail

  MOVI r1,79
  PUTC r1
  HALT

fail:
  MOVI r1,70
  PUTC r1
  HALT

; ---------------------------------------------------------------------------
; ---------------------------------------------------------------------------
; bt_build r1=addr r2=count r3..r6=apic[0..3] -> build a topology table header
bt_build:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  LA r7,#NCS_MAGIC
  ST r7,r1,0
  MOVI r7,1
  ST r7,r1,1
  ST r2,r1,2
  ST r0,r1,3
  CMP r2,r0
  JMP[EQ] @bt_out
  ST r3,r1,4
  MOVI r7,1
  CMP r2,r7
  JMP[EQ] @bt_out
  ST r4,r1,5
  MOVI r7,2
  CMP r2,r7
  JMP[EQ] @bt_out
  ST r5,r1,6
  MOVI r7,3
  CMP r2,r7
  JMP[EQ] @bt_out
  ST r6,r1,7
bt_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ------------------------------------------------- test nansmp atomic seam
; Single-CPU but value-correct: fetch-add returns the old word; CAS returns
; the old word and writes only on a match.  Calls are counted.
nsp_fetch_add:
  LD r3,r1,0
  ADD r4,r3,r2
  ST r4,r1,0
  LA r5,0x3FE000
  LD r4,r5,0
  ADDI r4,r4,1
  ST r4,r5,0
  ADD r1,r3,r0
  RET

nsp_cas:
  LD r4,r1,0
  CMP r4,r2
  JMP[NE] @stub_cas_no
  ST r3,r1,0
stub_cas_no:
  LA r5,0x3FE001
  LD r3,r5,0
  ADDI r3,r3,1
  ST r3,r5,0
  ADD r1,r4,r0
  RET

nsp_fence:
  LA r2,0x3FE002
  LD r3,r2,0
  ADDI r3,r3,1
  ST r3,r2,0
  MOVI r1,0
  RET
