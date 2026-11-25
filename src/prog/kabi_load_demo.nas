; kabi_load_demo.nas - load a program image into a fresh heap extent and spawn it.
;
; The parent holds a small in-memory image:
;   header { magic, entry_offset, code_words, data_words, scratch_words,
;            payload_ptr, reserved, reserved }
;   payload: code words followed by data words
; SVC 23 asks the kernel to allocate code+data from the nalloc heap, copy the
; image, build a three-region address space, and return a pid.  The child is
; position-independent: it prints 'L' and exits with status 30.  The parent
; waits, checks the status, and prints OK.  Expected serial text: LOK
;
; The image is loaded at a heap-derived base, not at its compile-time address,
; so this exercises relocation, allocation, region construction and spawn.

.equ FRAME0    0x1800
.equ FR_BASE   0x1800
.equ RT_BASE   0x1C00
.equ BOOTF     0x2100
.equ KSTACK    0x3000
.equ T_STATE   0x2000
.equ T_WAIT    0x2004
.equ T_CODE    0x2008
.equ T_DATA    0x200C
.equ CUR       0x2020
.equ DESCP     0x2021
.equ FP        0x2022
.equ NV_BASE   0x2060
.equ NV_END    0x2061
.equ NV_ROVER  0x2062
.equ HP        0x2064
.equ IB        0x2065
.equ CW        0x2066
.equ DW        0x2067
.equ LD_RET    0x2068
.equ PID1      0x4500
.equ IMG_HDR   0x5000
.equ PAYLOAD   0x5040
.equ PSTACK    0x63F0
.equ PARENT    0x4000
.equ SCR0      0x10000
.equ SCR1      0x18000

.org 0
boot:
  MOVI r13,1
  ; parent frame
  MOVI r1,#FRAME0
  MOVI r2,24
  MOVI r3,0
bz:
  ST r3,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP[NE] @bz
  MOVI r1,1
  ST r1,r0,#FRAME0+13
  MOVI r1,#PSTACK
  ST r1,r0,#FRAME0+14
  ST r1,r0,#FRAME0+22
  MOVI r1,@parent_entry
  ST r1,r0,#FRAME0+16

  ; parent regions: code RX, data+image RW, scratch RW
  MOVI r1,#PARENT
  ST r1,r0,#RT_BASE+0
  MOVI r1,0x400
  ST r1,r0,#RT_BASE+1
  ST r0,r0,#RT_BASE+2
  MOVI r1,5
  ST r1,r0,#RT_BASE+3
  MOVI r1,0x4400
  ST r1,r0,#RT_BASE+4
  MOVI r1,0x2000
  ST r1,r0,#RT_BASE+5
  ST r0,r0,#RT_BASE+6
  MOVI r1,3
  ST r1,r0,#RT_BASE+7
  MOVI r1,0
  MOVHI r1,1
  ST r1,r0,#RT_BASE+8
  MOVI r1,0x1000
  ST r1,r0,#RT_BASE+9
  ST r0,r0,#RT_BASE+10
  MOVI r1,3
  ST r1,r0,#RT_BASE+11
  ST r0,r0,#RT_BASE+12
  ST r0,r0,#RT_BASE+13
  ST r0,r0,#RT_BASE+14
  ST r0,r0,#RT_BASE+15

  ; process table
  MOVI r1,1
  ST r1,r0,#T_STATE
  ST r0,r0,#T_WAIT
  ST r0,r0,#T_CODE
  MOVI r1,0
  MOVHI r1,1
  ST r1,r0,#T_DATA
  ST r0,r0,#T_STATE+1
  ST r0,r0,#T_STATE+2
  ST r0,r0,#T_STATE+3
  ST r0,r0,#CUR

  ; image header
  MOVI r1,0x4D47
  MOVHI r1,0x4E49             ; "NIMG"
  ST r1,r0,#IMG_HDR+0
  ST r0,r0,#IMG_HDR+1         ; entry offset
  MOVI r1,6
  ST r1,r0,#IMG_HDR+2         ; code words
  MOVI r1,16
  ST r1,r0,#IMG_HDR+3         ; data words
  MOVI r1,0x1000
  ST r1,r0,#IMG_HDR+4         ; scratch words
  MOVI r1,#PAYLOAD
  ST r1,r0,#IMG_HDR+5
  ST r0,r0,#IMG_HDR+6
  ST r0,r0,#IMG_HDR+7

  ; nalloc heap for loaded extents
  MOVI r1,0
  MOVHI r1,4                  ; 0x40000
  MOVI r2,0x4000
  CALL @nal_init

  ; boot frame, kernel stack, entry
  MOVI r1,0x4E01
  MOVI r2,#BOOTF
  OUTL r2,r1
  MOVI r1,0x4E03
  MOVI r2,#KSTACK
  OUTL r2,r1
  MOVI r1,0x4E00
  MOVI r2,@kentry
  OUTL r2,r1
  SVC 7
  HALT

; ---- kernel ----
.org 0x1000
kentry:
  MOVI r1,0x4E01
  INL r2,r1
  ST r2,r0,#FP
  LD r3,r2,19
  CMP r3,r0
  JMP[EQ] @ksvc
  MOVI r4,1
  CMP r3,r4
  JMP[EQ] @kirq
  HALT

ksvc:
  LD r3,r2,20
  CMP r3,r0
  JMP[EQ] @kyield
  MOVI r4,7
  CMP r3,r4
  JMP[EQ] @kstart
  MOVI r4,1
  CMP r3,r4
  JMP[EQ] @kexit
  MOVI r4,10
  CMP r3,r4
  JMP[EQ] @kwait
  MOVI r4,23
  CMP r3,r4
  JMP[EQ] @kload
  MOVI r3,-1
  ST r3,r2,21
  SVCRET

kstart:
  MOVI r1,0x4E02
  MOVI r2,8
  OUTL r2,r1
  JMP @pick_next
kyield:
  ST r0,r2,21
  JMP @pick_next
kirq:
  JMP @pick_next
kexit:
  CALL @do_exit
  JMP @pick_next
kwait:
  CALL @do_wait
  HALT
kload:
  CALL @do_load
  LD r2,r0,#FP
  ST r1,r2,21
  SVCRET

; load the image pointed to by frame[1] -> pid in r1
do_load:
  ST r15,r0,#LD_RET
  LD r1,r0,#FP
  LD r1,r1,1
  ST r1,r0,#HP
  LD r2,r1,0
  MOVI r3,0x4D47
  MOVHI r3,0x4E49
  CMP r2,r3
  JMP[NE] @ld_fail
  LD r2,r1,2
  ST r2,r0,#CW
  LD r3,r1,3
  ST r3,r0,#DW
  ADD r1,r2,r3
  CALL @nal_alloc
  CMP r1,r0
  JMP[EQ] @ld_fail
  ST r1,r0,#IB
  ; copy code: payload -> base
  LD r4,r0,#HP
  LD r4,r4,5
  LD r2,r0,#CW
  ADD r5,r1,r0
  BCOPY r5,r4,r2
  ; copy data: payload+code -> base+code
  LD r4,r0,#HP
  LD r4,r4,5
  LD r2,r0,#CW
  ADD r4,r4,r2
  LD r5,r0,#IB
  ADD r5,r5,r2
  LD r3,r0,#DW
  BCOPY r5,r4,r3

  ; find a free slot
  MOVI r1,1
ld_slot:
  MOVI r2,#T_STATE
  ADD r2,r2,r1
  LD r3,r2,0
  CMP r3,r0
  JMP[EQ] @ld_found
  ADD r1,r1,r13
  MOVI r2,4
  CMP r1,r2
  JMP[LT] @ld_slot
  MOVI r1,0
  RET
ld_found:
  MOVI r3,1
  ST r3,r2,0
  SHL r4,r1,8
  MOVI r9,#FR_BASE
  ADD r9,r9,r4
  MOVI r10,#RT_BASE
  ADD r10,r10,r4
  ; zero frame
  ADD r5,r9,r0
  MOVI r7,24
  MOVI r8,0
ld_zf:
  ST r8,r5,0
  ADD r5,r5,r13
  SUB r7,r7,r13
  JMP[NE] @ld_zf
  ; entry and stack
  LD r2,r0,#IB
  LD r3,r0,#HP
  LD r3,r3,1                  ; entry offset
  ADD r2,r2,r3
  ST r2,r9,16
  LD r2,r0,#IB
  LD r3,r0,#CW
  ADD r2,r2,r3                ; data base
  LD r3,r0,#DW
  ADD r2,r2,r3
  SUB r2,r2,r13               ; stack top
  ST r2,r9,14
  ST r2,r9,22
  MOVI r2,1
  ST r2,r9,13
  ; code region
  LD r2,r0,#IB
  ST r2,r10,0
  LD r3,r0,#CW
  ST r3,r10,1
  ST r0,r10,2
  MOVI r2,5
  ST r2,r10,3
  ; data region
  LD r2,r0,#IB
  LD r3,r0,#CW
  ADD r2,r2,r3
  ST r2,r10,4
  LD r3,r0,#DW
  ST r3,r10,5
  ST r0,r10,6
  MOVI r2,3
  ST r2,r10,7
  ; scratch region: 0x10000 + slot*0x8000
  SHL r4,r1,15
  MOVI r2,0
  MOVHI r2,1
  ADD r2,r2,r4
  ST r2,r10,8
  MOVI r3,0x1000
  ST r3,r10,9
  ST r0,r10,10
  MOVI r3,3
  ST r3,r10,11
  ST r0,r10,12
  ST r0,r10,13
  ST r0,r10,14
  ST r0,r10,15
  ; per-process data window
  MOVI r3,#T_DATA
  ADD r3,r3,r1
  ST r2,r3,0
  ADD r1,r1,r13
  LD r15,r0,#LD_RET
  RET
ld_fail:
  MOVI r1,0
  LD r15,r0,#LD_RET
  RET

; current process exits with frame[1]
do_exit:
  LD r2,r0,#FP
  LD r1,r2,1
  LD r5,r0,#CUR
  MOVI r3,#T_STATE
  ADD r3,r3,r5
  MOVI r4,3
  ST r4,r3,0
  MOVI r3,#T_CODE
  ADD r3,r3,r5
  ST r1,r3,0
  MOVI r6,0
ew_loop:
  MOVI r3,#T_STATE
  ADD r3,r3,r6
  LD r4,r3,0
  MOVI r7,2
  CMP r4,r7
  JMP[NE] @ew_next
  MOVI r3,#T_WAIT
  ADD r3,r3,r6
  LD r7,r3,0
  ADD r8,r5,r13
  CMP r7,r8
  JMP[NE] @ew_next
  MOVI r4,1
  MOVI r3,#T_STATE
  ADD r3,r3,r6
  ST r4,r3,0
  MOVI r3,#T_WAIT
  ADD r3,r3,r6
  ST r0,r3,0
  SHL r4,r6,8
  MOVI r3,#FR_BASE
  ADD r3,r3,r4
  ST r1,r3,21
ew_next:
  ADD r6,r6,r13
  MOVI r3,4
  CMP r6,r3
  JMP[LT] @ew_loop
  RET

do_wait:
  LD r2,r0,#FP
  LD r1,r2,1
  SUB r9,r1,r13
  MOVI r3,#T_STATE
  ADD r3,r3,r9
  LD r4,r3,0
  MOVI r5,3
  CMP r4,r5
  JMP[EQ] @w_ready
  LD r6,r0,#CUR
  MOVI r3,#T_WAIT
  ADD r3,r3,r6
  ST r1,r3,0
  MOVI r3,#T_STATE
  ADD r3,r3,r6
  MOVI r4,2
  ST r4,r3,0
  JMP @pick_next
w_ready:
  MOVI r3,#T_CODE
  ADD r3,r3,r9
  LD r4,r3,0
  ST r4,r2,21
  SVCRET

pick_next:
  LD r1,r0,#CUR
  MOVI r2,0
pn_loop:
  ADD r1,r1,r13
  MOVI r3,4
  CMP r1,r3
  JMP[LT] @pn_ok
  MOVI r1,0
pn_ok:
  MOVI r3,#T_STATE
  ADD r3,r3,r1
  LD r4,r3,0
  MOVI r5,1
  CMP r4,r5
  JMP[EQ] @switch_to
  ADD r2,r2,r13
  MOVI r3,4
  CMP r2,r3
  JMP[LT] @pn_loop
  HALT

switch_to:
  ST r1,r0,#CUR
  SHL r2,r1,8
  MOVI r3,#FR_BASE
  ADD r3,r3,r2
  MOVI r4,0x4E01
  OUTL r3,r4
  MOVI r3,#RT_BASE
  ADD r3,r3,r2
  MOVI r4,0x4E04
  OUTL r3,r4
  MOVI r3,#T_DATA
  ADD r3,r3,r1
  LD r2,r3,0
  MOVI r4,0x4E07
  OUTL r2,r4
  SVCRET

; ---- parent ----
.org 0x4000
parent_entry:
  MOVI r13,1
  MOVI r14,#PSTACK
  MOVI r1,#IMG_HDR
  SVC 23
  CMP r1,r0
  JMP[EQ] @bad
  ST r1,r0,#PID1
  LD r1,r0,#PID1
  SVC 10
  MOVI r2,30
  CMP r1,r2
  JMP[NE] @bad
  MOVI r1,79
  PUTC r1
  MOVI r1,75
  PUTC r1
  MOVI r1,10
  PUTC r1
  MOVI r1,0
  SVC 1
  HALT
bad:
  MOVI r1,66
  PUTC r1
  MOVI r1,65
  PUTC r1
  MOVI r1,68
  PUTC r1
  MOVI r1,10
  PUTC r1
  MOVI r1,1
  SVC 1
  HALT

.org 0x4400
pdata:
.str ""

; ---- loaded image payload: 6 code words + 16 data words ----
.org 0x5040
child_code:
  MOVI r13,1
  MOVI r1,76
  PUTC r1
  MOVI r1,30
  SVC 1
  HALT
  .word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

; ---- nalloc ----
.include "../prog/nalloc.nas"
