; kabi_proc_demo.nas - region-isolated SVC process on the frozen kernel ABI.
;
; One user process runs in two mapped regions:
;   0x0000..0x07FF  code, R|X
;   0x0800..0x0FFF  data and stack, R|W
; The kernel lives at 0x1000, outside the user map.  Its SVC handler grants a
; nalloc heap block through SVC 2 (region_map) and adds the returned span to
; the live region table.  The process writes to the grant, then deliberately
; touches the unmapped region table at 0x1900.  The kernel takes the fault,
; notes the isolation event, and resumes at a recovery label.
;
; Expected COM1/serial text:
;   MAPPED
;   FAULT
;   ISOLATED
;   OK
;
; Runs on the C oracle and the x86_64 S1 slice.  The heap is at word 0x10000.

.equ FRAME     0x1800
.equ RTAB      0x1900
.equ RT_NEXT   0x1A00
.equ NV_BASE   0x1A01
.equ NV_END    0x1A02
.equ NV_ROVER  0x1A03
.equ KSTACK    0x2000
.equ HEAP_BASE 0x40000
.equ HEAP_WORDS 0x4000

.org 0
JMP @boot

; ---- user code (mapped R|X) ----
boot:
  MOVI r13,1
  MOVI r14,0x0FF0
  ; MEMQ: discover word memory, then place the kernel heap above the image.
  MOVI r1,0x00FF
  MOVHI r1,0x4E4D             ; CPUID leaf 0x4E4D00FF, subleaf 1 = word count
  MOVI r2,1
  CPUID r3,r1,r2
  LA r4,0x48000
  CMP r3,r4
  JMP[LT] @ufail
  MOVI r1,0
  MOVHI r1,4                  ; heap base 0x40000
  MOVI r2,#HEAP_WORDS
  CALL @nal_init

  ; region 0: code base 0, 0x800 words, RAM, R|X
  ST r0,r0,#RTAB+0
  MOVI r1,0x800
  ST r1,r0,#RTAB+1
  ST r0,r0,#RTAB+2
  MOVI r1,5
  ST r1,r0,#RTAB+3
  ; region 1: data base 0x800, 0x800 words, RAM, R|W
  MOVI r1,0x800
  ST r1,r0,#RTAB+4
  MOVI r1,0x800
  ST r1,r0,#RTAB+5
  ST r0,r0,#RTAB+6
  MOVI r1,3
  ST r1,r0,#RTAB+7
  ; terminator
  ST r0,r0,#RTAB+8
  ST r0,r0,#RTAB+9
  ST r0,r0,#RTAB+10
  ST r0,r0,#RTAB+11
  MOVI r1,2
  ST r1,r0,#RT_NEXT

  ; control ports: frame, kernel stack, region table, then entry last
  MOVI r1,0x4E01
  MOVI r2,#FRAME
  OUTL r2,r1
  MOVI r1,0x4E03
  MOVI r2,#KSTACK
  OUTL r2,r1
  MOVI r1,0x4E04
  MOVI r2,#RTAB
  OUTL r2,r1
  MOVI r1,0x4E00
  MOVI r2,@kentry
  OUTL r2,r1

user:
  MOVI r1,16
  SVC 2                       ; r1 = nalloc grant, mapped R|W
  CMP r1,r0
  JMP[EQ] @ufail
  MOVI r2,0x5A5A
  ST r2,r1,0                  ; write inside the grant
  LD r3,r1,0
  MOVI r4,0x5A5A
  CMP r3,r4
  JMP[NE] @ufail
  LA r1,@s_mapped
  CALL @uputs

  MOVI r1,#RTAB               ; unmapped: kernel-only region table
  LD r2,r1,0
after_fault:
  LA r1,@s_isolated
  CALL @uputs

  SVC 0                       ; yield
  LA r1,@s_ok
  CALL @uputs
  HALT

ufail:
  LA r1,@s_fail
  CALL @uputs
  HALT

; user word-string printer: r1 = packed string
uputs:
  MOVI r4,255
upw:
  LD r2,r1,0
  MOVI r3,4
upt:
  BOOL.8 r5,r2,r4
  CMP r5,r0
  RET[EQ]
  PUTC r5
  SHR r2,r2,8
  SUB r3,r3,r13
  JMP[NE] @upt
  ADD r1,r1,r13
  JMP @upw

; ---- user data (mapped R|W) ----
.org 0x800
s_mapped:
.str "MAPPED\r\n"
s_isolated:
.str "ISOLATED\r\n"
s_ok:
.str "OK\r\n"
s_fail:
.str "FAIL\r\n"

; ---- kernel (not mapped to user) ----
.org 0x1000
kentry:
  MOVI r2,0
  LD r1,r0,#FRAME+19
  CMP r1,r2
  JMP[EQ] @ksvc
  MOVI r2,1
  CMP r1,r2
  JMP[EQ] @kirq
  ; fault: report isolation and resume at the user's recovery label
  JMP @kfault

ksvc:
  LD r1,r0,#FRAME+20
  MOVI r2,2
  CMP r1,r2
  JMP[EQ] @kmap
  ; yield and unknown calls: return 0 in frame[21]
  ST r0,r0,#FRAME+21
  SVCRET

kmap:
  LD r1,r0,#FRAME+1
  CALL @nal_alloc
  CMP r1,r0
  JMP[EQ] @kmap_fail
  ST r1,r0,#FRAME+21
  ; append {base, words, kind=RAM, prot=R|W}
  LD r2,r0,#RT_NEXT
  SHL r3,r2,2
  MOVI r4,#RTAB
  ADD r4,r4,r3
  ST r1,r4,0
  LD r5,r0,#FRAME+1
  ST r5,r4,1
  ST r0,r4,2
  MOVI r5,3
  ST r5,r4,3
  ADD r2,r2,r13
  ST r2,r0,#RT_NEXT
  ; terminate the enlarged table
  SHL r3,r2,2
  MOVI r4,#RTAB
  ADD r4,r4,r3
  ST r0,r4,0
  ST r0,r4,1
  ST r0,r4,2
  ST r0,r4,3
  SVCRET

kmap_fail:
  MOVI r1,-1
  ST r1,r0,#FRAME+21
  SVCRET

kfault:
  LA r1,@s_fault
  CALL @kputs
  LA r1,@after_fault
  ST r1,r0,#FRAME+16
  SVCRET

kirq:
  SVCRET

; kernel word-string printer
kputs:
  MOVI r4,255
kpw:
  LD r2,r1,0
  MOVI r3,4
kpt:
  BOOL.8 r5,r2,r4
  CMP r5,r0
  RET[EQ]
  PUTC r5
  SHR r2,r2,8
  SUB r3,r3,r13
  JMP[NE] @kpt
  ADD r1,r1,r13
  JMP @kpw

s_fault:
.str "FAULT\r\n"

; ---- nalloc ----
.include "../prog/nalloc.nas"
