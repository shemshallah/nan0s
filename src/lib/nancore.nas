; nancore.nas - per-core NaN runtime records for modern core counts.
;
; 4096 logical cores, 64-word records at 0x400000.  The native substrate owns
; the record; NaN scheduler/ABI code reads and writes it.  No scheduling policy
; lives in the native layer.

.equ NC_TABLE       0x400000
.equ NC_STRIDE      64
.equ NC_MAX         4096
.equ NC_ONLINE_BASE 0x440000
.equ NC_ONLINE_WORDS 128

; record fields (word offsets)
.equ NC_CPU         0
.equ NC_STATE       1
.equ NC_RBASE       2
.equ NC_XPC         3
.equ NC_FLAGS       4
.equ NC_FRAME       5
.equ NC_KENTRY      6
.equ NC_KFRAME      7
.equ NC_KIN         8
.equ NC_AGENT       9
.equ NC_GEN         10
.equ NC_BUDGET      11
.equ NC_DEADLINE    12
.equ NC_TRACE       13
.equ NC_QHEAD       14
.equ NC_QTAIL       15
.equ NC_BCACHE      16
.equ NC_BGEN        17
.equ NC_IPI         18
.equ NC_TIMER       19
.equ NC_APIC        20
.equ NC_NODE        21
.equ NC_FLAGS2      22
.equ NC_STACK       23
.equ NC_STACK_TOP   24
.equ NC_TICKS       25
.equ NC_PREEMPT     26
.equ NC_QCOUNT      27
.equ NC_STEAL_HEAD  28
.equ NC_STEAL_TAIL  29
.equ NC_CACHE_N     30
.equ NC_RESERVED    31

; core states
.equ NC_OFF         0
.equ NC_RUN         1
.equ NC_KERNEL      2
.equ NC_HALT        3
.equ NC_IDLE        4

; helper: r1=cpu -> r1=record base or 0
nc_record:
  LA r2,#NC_MAX
  CMP r1,r2
  JMP[GE] @nc_record_bad
  SHL r2,r1,6
  LA r3,#NC_TABLE
  ADD r1,r3,r2
  RET
nc_record_bad:
  MOVI r1,0
  RET

; helper: r1=cpu r2=field -> r1=word address or 0
nc_field:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r2,r0,#NC_TMP
  CALL @nc_record
  CMP r1,r0
  JMP[EQ] @nc_field_out
  LD r2,r0,#NC_TMP
  ADD r1,r1,r2
nc_field_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; online bitmap: r1=cpu -> bit in r2, word address in r3
nc_online_bit:
  MOVI r5,31
  BOOL.8 r2,r1,r5
  SHR r3,r1,5
  LA r4,#NC_ONLINE_BASE
  ADD r3,r3,r4
  MOVI r4,1
  MOVI r5,0
nc_ob_l:
  CMP r5,r2
  JMP[GE] @nc_ob_done
  SHL r4,r4,1
  ADD r5,r5,r13
  JMP @nc_ob_l
nc_ob_done:
  ADD r2,r4,r0
  RET

; nc_online_set r1=cpu -> 0
nc_online_set:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r14,1
  CALL @nc_online_bit
  LD r4,r3,0
  BOOL.14 r4,r4,r2
  ST r4,r3,0
  MOVI r1,0
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nc_online_clear r1=cpu -> 0
nc_online_clear:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r14,1
  CALL @nc_online_bit
  LA r5,0xFFFFFFFF
  BOOL.6 r2,r2,r5
  LD r4,r3,0
  BOOL.8 r4,r4,r2
  ST r4,r3,0
  MOVI r1,0
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nc_online_test r1=cpu -> 1 online / 0
nc_online_test:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r14,1
  CALL @nc_online_bit
  LD r4,r3,0
  BOOL.8 r4,r4,r2
  CMP r4,r0
  MOVI[NE] r1,1
  MOVI[EQ] r1,0
  SUB r14,r14,r13
  LD r15,r14,0
  RET

.equ NC_TMP 0x3DF
