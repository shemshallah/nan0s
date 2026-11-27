; nancore.nas - per-core NaN runtime record and multicore ABI constants.
;
; The native substrate owns the record; NaN scheduler/ABI code reads/writes it
; through the fixed guest window.  No native scheduler policy lives here.

.equ NC_TABLE       0x3E000
.equ NC_STRIDE      0x100
.equ NC_MAX         8

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
.equ NC_RESERVED    20

; core states
.equ NC_OFF         0
.equ NC_RUN         1
.equ NC_KERNEL      2
.equ NC_HALT        3

; helper: r1=cpu -> r1=record base
nc_record:
  SHL r2,r1,8
  LA r3,#NC_TABLE
  ADD r1,r3,r2
  RET

; helper: r1=cpu r2=field -> r1=word address
nc_field:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r2,r0,#NC_TMP
  CALL @nc_record
  LD r2,r0,#NC_TMP
  ADD r1,r1,r2
  SUB r14,r14,r13
  LD r15,r14,0
  RET

.equ NC_TMP 0x3DF
