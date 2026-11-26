; nantrace.nas - hash-chained event traces for deterministic AI runs (M2b).
;
; A trace is a metadata object over a storage BLOB.  Each event is four
; words {kind, a, b, hash}; hash = mix(previous_hash, kind, a, b).  Sealing
; marks the trace immutable.  Verification recomputes the chain, so tampering
; with any event or the head is detected.
;
; ABI:
;   ntrace_create r1=storage cap -> trace cap or 0
;   ntrace_append r1=trace r2=kind r3=a r4=b -> index or -1
;   ntrace_seal   r1=trace -> head hash or -1
;   ntrace_verify r1=trace -> 0/-1
;
; Trace payload (24 words):
;   0 storage cap, 1 capacity events, 2 count, 3 head hash, 4 sealed.
; Storage layout: count events of 4 words, contiguous.

.include "nanobj.nas"

.equ NTRACE_CLASS   12
.equ NTRACE_HDR     0x362000
.equ NTRACE_EV      0x362040
.equ TR_G_TRACE     0x3C0
.equ TR_G_STOR      0x3C1
.equ TR_G_KIND      0x3C2
.equ TR_G_A         0x3C3
.equ TR_G_B         0x3C4
.equ TR_G_COUNT     0x3C5
.equ TR_G_HEAD      0x3C6
.equ TR_G_SEALED    0x3C7
.equ TR_G_CAP       0x3C8
.equ TR_G_TMP       0x3C9
.equ TR_G_TMP2      0x3CA
.equ TR_G_CAPACITY  0x3CB
.equ TR_G_EXPECT    0x3CC

; nt_mix: r1=prev hash r2=value -> r1=mixed.  Leaf.
nt_mix:
  CMP r1,r0
  JMP[NE] @nt_mix_nz
  MOVI r1,0x9DC5
  MOVI r3,0x811C
  SHL r3,r3,16
  ADD r1,r1,r3
nt_mix_nz:
  BOOL.6 r1,r1,r2
  MOVI r3,0x0193
  MOVI r4,0x0100
  SHL r4,r4,16
  ADD r3,r3,r4
  MUL r1,r1,r3
  RET

; nt_hash_event: r1=prev r2=kind r3=a r4=b -> hash
nt_hash_event:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#TR_G_HEAD
  ST r2,r0,#TR_G_KIND
  ST r3,r0,#TR_G_A
  ST r4,r0,#TR_G_B
  LD r1,r0,#TR_G_HEAD
  LD r2,r0,#TR_G_KIND
  CALL @nt_mix
  ST r1,r0,#TR_G_HEAD
  LD r2,r0,#TR_G_A
  CALL @nt_mix
  ST r1,r0,#TR_G_HEAD
  LD r2,r0,#TR_G_B
  CALL @nt_mix
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ntrace_create: r1=storage -> trace cap or 0
ntrace_create:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#TR_G_STOR
  MOVI r2,3                    ; read | write
  CALL @nobj_check
  CMP r1,r0
  JMP[EQ] @ntr_cr_n
  LD r2,r1,4                   ; storage words
  SHR r2,r2,2                  ; capacity = words / 4 events
  CMP r2,r0
  JMP[EQ] @ntr_cr_n
  ST r2,r0,#TR_G_CAPACITY
  LA r3,#NTRACE_HDR
  ST r0,r3,0
  LD r4,r0,#TR_G_STOR
  ST r4,r3,0
  LD r4,r0,#TR_G_CAPACITY
  ST r4,r3,1
  ST r0,r3,2
  ST r0,r3,3
  ST r0,r3,4
  MOVI r1,#NTRACE_CLASS
  MOVI r2,24
  CALL @nobj_create
  CMP r1,r0
  JMP[EQ] @ntr_cr_n
  ST r1,r0,#TR_G_CAP
  ADD r1,r1,r0
  LA r2,#NTRACE_HDR
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_write
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @ntr_cr_bad
  LD r1,r0,#TR_G_CAP
  JMP @ntr_cr_d
ntr_cr_bad:
  LD r1,r0,#TR_G_CAP
  CALL @nobj_release
ntr_cr_n:
  MOVI r1,0
ntr_cr_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ntrace_append: r1=trace r2=kind r3=a r4=b -> index or -1
ntrace_append:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#TR_G_TRACE
  ST r2,r0,#TR_G_KIND
  ST r3,r0,#TR_G_A
  ST r4,r0,#TR_G_B
  ; read header
  LA r2,#NTRACE_HDR
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_read
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @ntr_ap_n
  LA r3,#NTRACE_HDR
  LD r4,r3,4
  CMP r4,r0
  JMP[NE] @ntr_ap_n               ; sealed
  LD r4,r3,2                      ; count
  LD r5,r3,1                      ; capacity
  CMP r4,r5
  JMP[GE] @ntr_ap_n
  ST r4,r0,#TR_G_COUNT
  LD r1,r3,3                      ; previous head
  LD r2,r0,#TR_G_KIND
  LD r3,r0,#TR_G_A
  LD r4,r0,#TR_G_B
  CALL @nt_hash_event
  ST r1,r0,#TR_G_HEAD
  ; event
  LA r2,#NTRACE_EV
  LD r3,r0,#TR_G_KIND
  ST r3,r2,0
  LD r3,r0,#TR_G_A
  ST r3,r2,1
  LD r3,r0,#TR_G_B
  ST r3,r2,2
  LD r3,r0,#TR_G_HEAD
  ST r3,r2,3
  ; write event at count*4
  LA r2,#NTRACE_HDR
  LD r1,r2,0                      ; storage cap
  LA r2,#NTRACE_EV
  LD r3,r0,#TR_G_COUNT
  SHL r3,r3,2
  MOVI r4,4
  CALL @nobj_write
  MOVI r5,4
  CMP r1,r5
  JMP[NE] @ntr_ap_n
  ; update header count/head
  LA r3,#NTRACE_HDR
  LD r4,r0,#TR_G_COUNT
  ADD r4,r4,r13
  ST r4,r3,2
  LD r4,r0,#TR_G_HEAD
  ST r4,r3,3
  LD r1,r0,#TR_G_TRACE
  ADD r2,r3,r0
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_write
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @ntr_ap_n
  LD r1,r0,#TR_G_COUNT
  JMP @ntr_ap_d
ntr_ap_n:
  LA r1,0xFFFFFFFF
ntr_ap_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ntrace_seal: r1=trace -> head hash or -1
ntrace_seal:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#TR_G_TRACE
  LA r2,#NTRACE_HDR
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_read
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @ntr_sl_n
  LA r3,#NTRACE_HDR
  MOVI r4,1
  ST r4,r3,4
  LD r1,r0,#TR_G_TRACE
  ADD r2,r3,r0
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_write
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @ntr_sl_n
  LA r3,#NTRACE_HDR
  LD r1,r3,3
  JMP @ntr_sl_d
ntr_sl_n:
  LA r1,0xFFFFFFFF
ntr_sl_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ntrace_verify: r1=trace -> 0/-1
ntrace_verify:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#TR_G_TRACE
  LA r2,#NTRACE_HDR
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_read
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @ntr_vf_n
  LA r3,#NTRACE_HDR
  LD r4,r3,2                      ; count
  ST r4,r0,#TR_G_COUNT
  LD r4,r3,3                      ; expected head
  ST r4,r0,#TR_G_EXPECT
  MOVI r4,0
  ST r4,r0,#TR_G_TMP              ; index
  MOVI r4,0
  ST r4,r0,#TR_G_CAP              ; current hash
ntr_vf_l:
  LD r4,r0,#TR_G_TMP
  LD r5,r0,#TR_G_COUNT
  CMP r4,r5
  JMP[GE] @ntr_vf_end
  ; read event at index*4
  LA r2,#NTRACE_HDR
  LD r1,r2,0                      ; storage cap
  LA r2,#NTRACE_EV
  LD r3,r0,#TR_G_TMP
  SHL r3,r3,2
  MOVI r4,4
  CALL @nobj_read
  MOVI r5,4
  CMP r1,r5
  JMP[NE] @ntr_vf_n
  LD r1,r0,#TR_G_CAP
  LA r3,#NTRACE_EV
  LD r2,r3,0
  LD r3,r3,1
  LA r4,#NTRACE_EV
  LD r4,r4,2
  CALL @nt_hash_event
  ST r1,r0,#TR_G_CAP
  LD r4,r0,#TR_G_TMP
  ADD r4,r4,r13
  ST r4,r0,#TR_G_TMP
  JMP @ntr_vf_l
ntr_vf_end:
  LD r1,r0,#TR_G_CAP
  LD r2,r0,#TR_G_EXPECT
  CMP r1,r2
  JMP[NE] @ntr_vf_n
  MOVI r1,0
  JMP @ntr_vf_d
ntr_vf_n:
  LA r1,0xFFFFFFFF
ntr_vf_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
