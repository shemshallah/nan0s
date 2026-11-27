; nreplay_test.nas - F8 deterministic RNG, trace replay, checkpoint replay.
;
; Proves (pure NaN, no host randomness):
;   * xorshift32 is exact for a fixed seed, differs for another seed, and
;     state save/restore resumes the same sequence;
;   * same seed -> same trace head; different seed -> different head;
;   * append -> seal -> verify via nantrace;
;   * checkpoint (RNG, head, index) -> suffix -> restore -> same suffix ->
;     identical head and identical nantrace chain;
;   * a mutated or omitted replay event diverges at the exact index, with an
;     expected/got record, and the engine then fails closed;
;   * a tampered sealed trace fails verification;
;   * step budget and tick deadline both fail closed.
;
; Success prints exactly O on COM1.  A failed check prints F <8 hex digits>.
;
; Guest map (word addresses):
;   0x2800 nreplay engine globals (in nreplay.nas)
;   0x3000 test data (traces, heads, checkpoint buffer)
;   0x7000 test stack
;   0x340000 nanobj table, 0x362000 nantrace scratch (in the libraries)

.equ STK       0x7000

.org 0
JMP @main
.org 0x400
.include "../lib/nreplay.nas"

main:
  MOVI r0,0
  MOVI r13,1
  LA r14,#STK
  CALL @nobj_init

; ---------------------------------------------------------------------------
; PRNG: 8 draws for seed1, then the same seed again must match exactly.
  LD r1,r0,@seed1
  CALL @nrng_init
  MOVI r6,0
rng_a_l:
  MOVI r7,#RNGN
  CMP r6,r7
  JMP[GE] @rng_a_d
  CALL @nrng_next
  LA r4,@rng1
  ADD r4,r4,r6
  ST r1,r4,0
  ADDI r6,r6,1
  JMP @rng_a_l
rng_a_d:
  LD r1,r0,@seed1
  CALL @nrng_init
  MOVI r6,0
rng_b_l:
  MOVI r7,#RNGN
  CMP r6,r7
  JMP[GE] @rng_b_d
  CALL @nrng_next
  LA r4,@rng1
  ADD r4,r4,r6
  LD r5,r4,0
  MOVI r3,0x11
  CALL @chk
  ADDI r6,r6,1
  JMP @rng_b_l
rng_b_d:

; State save after 3 draws, 4 more draws, restore, 4 draws must match.
  LD r1,r0,@seed1
  CALL @nrng_init
  CALL @nrng_next
  CALL @nrng_next
  CALL @nrng_next
  LA r1,@rstate
  CALL @nrng_state_save
  MOVI r6,0
rng_s1:
  MOVI r7,4
  CMP r6,r7
  JMP[GE] @rng_s1d
  CALL @nrng_next
  LA r4,@rng2
  ADD r4,r4,r6
  ST r1,r4,0
  ADDI r6,r6,1
  JMP @rng_s1
rng_s1d:
  LA r1,@rstate
  CALL @nrng_state_restore
  MOVI r6,0
rng_s2:
  MOVI r7,4
  CMP r6,r7
  JMP[GE] @rng_s2d
  CALL @nrng_next
  LA r4,@rng2
  ADD r4,r4,r6
  LD r5,r4,0
  MOVI r3,0x12
  CALL @chk
  ADDI r6,r6,1
  JMP @rng_s2
rng_s2d:

; Different seed must produce a different sequence (at least one draw).
  LD r1,r0,@seed2
  CALL @nrng_init
  MOVI r6,0
  MOVI r8,0
rng_c_l:
  MOVI r7,#RNGN
  CMP r6,r7
  JMP[GE] @rng_c_d
  CALL @nrng_next
  LA r4,@rng1
  ADD r4,r4,r6
  LD r5,r4,0
  CMP r1,r5
  JMP[EQ] @rng_c_same
  MOVI r8,1
rng_c_same:
  ADDI r6,r6,1
  JMP @rng_c_l
rng_c_d:
  MOVI r5,0
  ADD r1,r8,r0
  MOVI r5,0
  MOVI r3,0x13
  CALL @chkne

; ---------------------------------------------------------------------------
; Trace A: seed1, four events, seal, verify.
  CALL @new_trace
  ST r1,r0,@tA
  CMP r1,r0
  MOVI r5,0
  MOVI r3,0x20
  CALL @chkne
  LD r1,r0,@seed1
  LD r2,r0,@tA
  CALL @nr_begin
  MOVI r5,0
  MOVI r3,0x21
  CALL @chk
  CALL @fill4
  MOVI r5,0
  MOVI r3,0x22
  CALL @chk
  CALL @nr_head
  ST r1,r0,@headA
  CALL @nr_seal
  LD r5,r0,@headA
  MOVI r3,0x23
  CALL @chk
  CALL @nr_verify
  MOVI r5,0
  MOVI r3,0x24
  CALL @chk
  LD r1,r0,@tA
  CALL @ntrace_verify
  MOVI r5,0
  MOVI r3,0x25
  CALL @chk

; Trace B: same seed -> same head.
  CALL @new_trace
  ST r1,r0,@tB
  LD r1,r0,@seed1
  LD r2,r0,@tB
  CALL @nr_begin
  MOVI r5,0
  MOVI r3,0x26
  CALL @chk
  CALL @fill4
  MOVI r5,0
  MOVI r3,0x27
  CALL @chk
  CALL @nr_head
  ST r1,r0,@headB
  LD r5,r0,@headA
  MOVI r3,0x28
  CALL @chk
  CALL @nr_seal
  CALL @nr_verify
  MOVI r5,0
  MOVI r3,0x29
  CALL @chk

; Trace C: different seed -> different head.
  CALL @new_trace
  ST r1,r0,@tC
  LD r1,r0,@seed2
  LD r2,r0,@tC
  CALL @nr_begin
  MOVI r5,0
  MOVI r3,0x2A
  CALL @chk
  CALL @fill4
  MOVI r5,0
  MOVI r3,0x2B
  CALL @chk
  CALL @nr_head
  ST r1,r0,@headC
  LD r5,r0,@headA
  MOVI r3,0x2C
  CALL @chkne
  CALL @nr_seal
  CALL @nr_verify
  MOVI r5,0
  MOVI r3,0x2D
  CALL @chk

; ---------------------------------------------------------------------------
; Checkpoint replay: prefix 2, checkpoint, suffix 3, restore, replay suffix.
  CALL @new_trace
  ST r1,r0,@tP
  LD r1,r0,@seedP
  LD r2,r0,@tP
  CALL @nr_begin
  MOVI r5,0
  MOVI r3,0x30
  CALL @chk
  MOVI r1,10
  MOVI r2,100
  CALL @nr_limits
  MOVI r5,0
  MOVI r3,0x7C
  CALL @chk
  MOVI r1,0x10
  MOVI r2,0xAA
  MOVI r3,0xBB
  CALL @nr_event
  MOVI r5,0
  MOVI r3,0x31
  CALL @chk
  MOVI r1,0x11
  MOVI r2,0xCC
  MOVI r3,0xDD
  CALL @nr_event
  MOVI r5,1
  MOVI r3,0x32
  CALL @chk
  LA r1,@cp
  CALL @nr_checkpoint
  MOVI r5,#NR_CK_WORDS
  MOVI r3,0x33
  CALL @chk
  CALL @nr_head
  ST r1,r0,@cpHead
  CALL @nr_index
  MOVI r5,2
  MOVI r3,0x34
  CALL @chk
  MOVI r6,0
  ST r6,r0,@loopi
suf_l:
  LD r6,r0,@loopi
  MOVI r7,3
  CMP r6,r7
  JMP[GE] @suf_d
  ADDI r8,r6,0x20
  CALL @nrng_next
  ADD r9,r1,r0
  CALL @nrng_next
  ADD r10,r1,r0
  ADD r1,r8,r0
  ADD r2,r9,r0
  ADD r3,r10,r0
  CALL @nr_event
  LD r6,r0,@loopi
  ADDI r5,r6,2
  MOVI r3,0x35
  CALL @chk
  LD r6,r0,@loopi
  ADDI r6,r6,1
  ST r6,r0,@loopi
  JMP @suf_l
suf_d:
  CALL @nr_head
  ST r1,r0,@headP
  CALL @nr_index
  MOVI r5,5
  MOVI r3,0x36
  CALL @chk
  MOVI r1,0
  MOVI r2,0
  CALL @nr_limits
  MOVI r5,0
  MOVI r3,0x7D
  CALL @chk
  LA r1,@cp
  CALL @nr_restore
  MOVI r5,0
  MOVI r3,0x37
  CALL @chk
  CALL @nr_index
  MOVI r5,2
  MOVI r3,0x38
  CALL @chk
  CALL @nr_head
  LD r5,r0,@cpHead
  MOVI r3,0x39
  CALL @chk
  MOVI r6,0
  ST r6,r0,@loopi
rep_l:
  LD r6,r0,@loopi
  MOVI r7,3
  CMP r6,r7
  JMP[GE] @rep_d
  ADDI r8,r6,0x20
  CALL @nrng_next
  ADD r9,r1,r0
  CALL @nrng_next
  ADD r10,r1,r0
  ADD r1,r8,r0
  ADD r2,r9,r0
  ADD r3,r10,r0
  CALL @nr_event
  LD r6,r0,@loopi
  ADDI r5,r6,2
  MOVI r3,0x3A
  CALL @chk
  LD r6,r0,@loopi
  ADDI r6,r6,1
  ST r6,r0,@loopi
  JMP @rep_l
rep_d:
  CALL @nr_head
  LD r5,r0,@headP
  MOVI r3,0x3B
  CALL @chk
  LD r1,r0,@headP
  CALL @nr_head_check
  MOVI r5,0
  MOVI r3,0x3C
  CALL @chk
  CALL @nr_verify
  MOVI r5,0
  MOVI r3,0x3D
  CALL @chk
  CALL @nr_seal
  CMP r1,r0
  MOVI r5,0
  MOVI r3,0x3E
  CALL @chkne
  CALL @nr_verify
  MOVI r5,0
  MOVI r3,0x3F
  CALL @chk

; Restore also reinstated the checkpoint budget (10) and step count (5).
; Two more steps fit; the next step must fail closed at status 2.
  MOVI r1,5
  MOVI r2,0
  CALL @nr_cost
  MOVI r5,0
  MOVI r3,0x7E
  CALL @chk
  MOVI r1,1
  MOVI r2,0
  CALL @nr_cost
  LA r5,0xFFFFFFFF
  MOVI r3,0x7F
  CALL @chk
  CALL @nr_status
  MOVI r5,2
  MOVI r3,0x80
  CALL @chk

; ---------------------------------------------------------------------------
; Reference trace: three fixed events, sealed.
  CALL @new_trace
  ST r1,r0,@tR
  LD r1,r0,@seed1
  LD r2,r0,@tR
  CALL @nr_begin
  MOVI r1,1
  MOVI r2,0x10
  LA r3,0x100
  CALL @nr_event
  MOVI r1,2
  MOVI r2,0x20
  LA r3,0x200
  CALL @nr_event
  MOVI r1,3
  MOVI r2,0x30
  LA r3,0x300
  CALL @nr_event
  MOVI r5,2
  MOVI r3,0x40
  CALL @chk
  CALL @nr_seal
  ST r1,r0,@headR
  CMP r1,r0
  MOVI r5,0
  MOVI r3,0x41
  CALL @chkne
  CALL @nr_verify
  MOVI r5,0
  MOVI r3,0x42
  CALL @chk

; Clean replay: head equals the reference head.
  CALL @new_trace
  ST r1,r0,@tClean
  LD r1,r0,@seed1
  LD r2,r0,@tClean
  CALL @nr_begin
  LD r1,r0,@tR
  CALL @nr_ref
  MOVI r5,0
  MOVI r3,0x43
  CALL @chk
  MOVI r1,1
  MOVI r2,0x10
  LA r3,0x100
  CALL @nr_observe
  MOVI r5,0
  MOVI r3,0x44
  CALL @chk
  MOVI r1,2
  MOVI r2,0x20
  LA r3,0x200
  CALL @nr_observe
  MOVI r5,1
  MOVI r3,0x45
  CALL @chk
  MOVI r1,3
  MOVI r2,0x30
  LA r3,0x300
  CALL @nr_observe
  MOVI r5,2
  MOVI r3,0x46
  CALL @chk
  CALL @nr_head
  LD r5,r0,@headR
  MOVI r3,0x47
  CALL @chk
  LD r1,r0,@headR
  CALL @nr_head_check
  MOVI r5,0
  MOVI r3,0x48
  CALL @chk
  CALL @nr_verify
  MOVI r5,0
  MOVI r3,0x49
  CALL @chk
  CALL @nr_seal
  CALL @nr_verify
  MOVI r5,0
  MOVI r3,0x4A
  CALL @chk

; Mutated replay: event 1 differs, divergence exactly at index 1.
  CALL @new_trace
  ST r1,r0,@tMut
  LD r1,r0,@seed1
  LD r2,r0,@tMut
  CALL @nr_begin
  LD r1,r0,@tR
  CALL @nr_ref
  MOVI r5,0
  MOVI r3,0x4B
  CALL @chk
  MOVI r1,1
  MOVI r2,0x10
  LA r3,0x100
  CALL @nr_observe
  MOVI r5,0
  MOVI r3,0x4C
  CALL @chk
  MOVI r1,2
  MOVI r2,0x20
  LA r3,0x201
  CALL @nr_observe
  LA r5,0xFFFFFFFF
  MOVI r3,0x4D
  CALL @chk
  CALL @nr_status
  MOVI r5,1
  MOVI r3,0x4E
  CALL @chk
  CALL @nr_div_index
  MOVI r5,1
  MOVI r3,0x4F
  CALL @chk
  CALL @nr_div_expected
  ST r1,r0,@divE
  CALL @nr_div_got
  ST r1,r0,@divG
  LD r5,r0,@divE
  MOVI r3,0x50
  CALL @chkne
  CALL @nr_index
  MOVI r5,1
  MOVI r3,0x51
  CALL @chk
  MOVI r1,9
  MOVI r2,9
  MOVI r3,9
  CALL @nr_event
  LA r5,0xFFFFFFFF
  MOVI r3,0x52
  CALL @chk
  CALL @nr_index
  MOVI r5,1
  MOVI r3,0x53
  CALL @chk

; Omitted replay: skip event 1, divergence exactly at index 1.
  CALL @new_trace
  ST r1,r0,@tOmit
  LD r1,r0,@seed1
  LD r2,r0,@tOmit
  CALL @nr_begin
  LD r1,r0,@tR
  CALL @nr_ref
  MOVI r5,0
  MOVI r3,0x54
  CALL @chk
  MOVI r1,1
  MOVI r2,0x10
  LA r3,0x100
  CALL @nr_observe
  MOVI r5,0
  MOVI r3,0x55
  CALL @chk
  MOVI r1,3
  MOVI r2,0x30
  LA r3,0x300
  CALL @nr_observe
  LA r5,0xFFFFFFFF
  MOVI r3,0x56
  CALL @chk
  CALL @nr_status
  MOVI r5,1
  MOVI r3,0x57
  CALL @chk
  CALL @nr_div_index
  MOVI r5,1
  MOVI r3,0x58
  CALL @chk
  CALL @nr_index
  MOVI r5,1
  MOVI r3,0x59
  CALL @chk

; Explicit expectation: first matches, second diverges at index 1.
  CALL @new_trace
  ST r1,r0,@tExp
  LD r1,r0,@seed1
  LD r2,r0,@tExp
  CALL @nr_begin
  MOVI r1,1
  MOVI r2,0x10
  LA r3,0x100
  CALL @nr_expect
  MOVI r5,0
  MOVI r3,0x5A
  CALL @chk
  MOVI r1,1
  MOVI r2,0x10
  LA r3,0x100
  CALL @nr_observe
  MOVI r5,0
  MOVI r3,0x5B
  CALL @chk
  MOVI r1,2
  MOVI r2,0x20
  LA r3,0x200
  CALL @nr_expect
  MOVI r5,0
  MOVI r3,0x5C
  CALL @chk
  MOVI r1,2
  MOVI r2,0x20
  LA r3,0x201
  CALL @nr_observe
  LA r5,0xFFFFFFFF
  MOVI r3,0x5D
  CALL @chk
  CALL @nr_div_index
  MOVI r5,1
  MOVI r3,0x5E
  CALL @chk
  CALL @nr_status
  MOVI r5,1
  MOVI r3,0x5F
  CALL @chk

; ---------------------------------------------------------------------------
; Tampered sealed trace: verification must fail.
  CALL @new_trace
  ST r1,r0,@tTam
  LD r1,r0,@laststor
  ST r1,r0,@sTam
  LD r1,r0,@seed1
  LD r2,r0,@tTam
  CALL @nr_begin
  MOVI r1,1
  MOVI r2,1
  MOVI r3,1
  CALL @nr_event
  MOVI r1,2
  MOVI r2,2
  MOVI r3,2
  CALL @nr_event
  MOVI r5,1
  MOVI r3,0x60
  CALL @chk
  CALL @nr_seal
  CMP r1,r0
  MOVI r5,0
  MOVI r3,0x61
  CALL @chkne
  CALL @nr_verify
  MOVI r5,0
  MOVI r3,0x62
  CALL @chk
  MOVI r1,0xBAD
  ST r1,r0,@evil
  LD r1,r0,@sTam
  LA r2,@evil
  MOVI r3,0
  MOVI r4,1
  CALL @nobj_write
  MOVI r5,1
  MOVI r3,0x63
  CALL @chk
  CALL @nr_verify
  LA r5,0xFFFFFFFF
  MOVI r3,0x64
  CALL @chk
  CALL @nr_status
  MOVI r5,4
  MOVI r3,0x65
  CALL @chk
  LD r1,r0,@tTam
  CALL @ntrace_verify
  LA r5,0xFFFFFFFF
  MOVI r3,0x66
  CALL @chk

; ---------------------------------------------------------------------------
; Step budget: two events fit, the third fails closed.
  CALL @new_trace
  ST r1,r0,@tBud
  LD r1,r0,@seed1
  LD r2,r0,@tBud
  CALL @nr_begin
  MOVI r1,2
  MOVI r2,0
  CALL @nr_limits
  MOVI r5,0
  MOVI r3,0x70
  CALL @chk
  MOVI r1,1
  MOVI r2,7
  MOVI r3,7
  CALL @nr_event
  MOVI r5,0
  MOVI r3,0x71
  CALL @chk
  MOVI r1,2
  MOVI r2,8
  MOVI r3,8
  CALL @nr_event
  MOVI r5,1
  MOVI r3,0x72
  CALL @chk
  MOVI r1,3
  MOVI r2,9
  MOVI r3,9
  CALL @nr_event
  LA r5,0xFFFFFFFF
  MOVI r3,0x73
  CALL @chk
  CALL @nr_status
  MOVI r5,2
  MOVI r3,0x74
  CALL @chk
  CALL @nr_index
  MOVI r5,2
  MOVI r3,0x75
  CALL @chk
  MOVI r1,4
  MOVI r2,10
  MOVI r3,10
  CALL @nr_event
  LA r5,0xFFFFFFFF
  MOVI r3,0x76
  CALL @chk

; Deadline: an explicit tick charge reaches the deadline, the next event fails.
  CALL @new_trace
  ST r1,r0,@tDl
  LD r1,r0,@seed1
  LD r2,r0,@tDl
  CALL @nr_begin
  MOVI r1,0
  MOVI r2,2
  CALL @nr_limits
  MOVI r5,0
  MOVI r3,0x77
  CALL @chk
  MOVI r1,0
  MOVI r2,2
  CALL @nr_cost
  MOVI r5,0
  MOVI r3,0x78
  CALL @chk
  MOVI r1,1
  MOVI r2,7
  MOVI r3,7
  CALL @nr_event
  LA r5,0xFFFFFFFF
  MOVI r3,0x79
  CALL @chk
  CALL @nr_status
  MOVI r5,3
  MOVI r3,0x7A
  CALL @chk
  CALL @nr_index
  MOVI r5,0
  MOVI r3,0x7B
  CALL @chk

; ---------------------------------------------------------------------------
; All checks passed: exactly O.
  MOVI r1,79
  PUTC r1
  HALT

; ---------------------------------------------------------------------------
; new_trace: storage BLOB (24 words = 6 events) + trace cap.
; -> r1=trace cap or 0, laststor=storage cap.
new_trace:
  ST r15,r14,0
  ADDI r14,r14,16
  MOVI r1,2
  MOVI r2,24
  CALL @nobj_create
  CMP r1,r0
  JMP[EQ] @ntr_bad
  ST r1,r0,@laststor
  CALL @ntrace_create
  CMP r1,r0
  JMP[EQ] @ntr_bad
  JMP @ntr_out
ntr_bad:
  MOVI r1,0
ntr_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; fill4: four events kind=1..4, a/b from the current RNG -> 0 / -1.
fill4:
  ST r15,r14,0
  ADDI r14,r14,40
  MOVI r6,0
  ST r6,r14,1
f4_l:
  LD r6,r14,1
  MOVI r7,4
  CMP r6,r7
  JMP[GE] @f4_ok
  ADDI r8,r6,1
  CALL @nrng_next
  ADD r9,r1,r0
  CALL @nrng_next
  ADD r10,r1,r0
  ADD r1,r8,r0
  ADD r2,r9,r0
  ADD r3,r10,r0
  CALL @nr_event
  LD r6,r14,1
  CMP r1,r6
  JMP[NE] @f4_bad
  ADDI r6,r6,1
  ST r6,r14,1
  JMP @f4_l
f4_ok:
  MOVI r1,0
  JMP @f4_out
f4_bad:
  LA r1,0xFFFFFFFF
f4_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; chk r1=actual r5=expected r3=diagnostic -> 0 / HALT.
chk:
  CMP r1,r5
  JMP[EQ] @chk_ok
  ADD r1,r3,r0
  JMP @failcode
chk_ok:
  MOVI r1,0
  RET

; chkne r1=a r5=b r3=diagnostic -> 0 / HALT.  Fails when a == b.
chkne:
  CMP r1,r5
  JMP[NE] @chkne_ok
  ADD r1,r3,r0
  JMP @failcode
chkne_ok:
  MOVI r1,0
  RET

failcode:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  MOVI r1,70
  PUTC r1
  MOVI r1,32
  PUTC r1
  LD r1,r14,1
  CALL @puthex4
  MOVI r1,10
  PUTC r1
  HALT

; puthex4: r1=value -> four uppercase hex digits (low 16 bits, high first).
puthex4:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  LD r1,r14,1
  SHR r1,r1,12
  MOVI r2,0xF
  BOOL.8 r1,r1,r2
  CALL @putnib
  LD r1,r14,1
  SHR r1,r1,8
  MOVI r2,0xF
  BOOL.8 r1,r1,r2
  CALL @putnib
  LD r1,r14,1
  SHR r1,r1,4
  MOVI r2,0xF
  BOOL.8 r1,r1,r2
  CALL @putnib
  LD r1,r14,1
  MOVI r2,0xF
  BOOL.8 r1,r1,r2
  CALL @putnib
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

putnib:
  MOVI r2,9
  CMP r1,r2
  JMP[GT] @pn_a
  ADDI r1,r1,48
  PUTC r1
  RET
pn_a:
  ADDI r1,r1,55
  PUTC r1
  RET

; ---------------------------------------------------------------------------
.org 0x3000
seed1:
.word 0x12345678
seed2:
.word 0x0BADC0DE
seedP:
.word 0x00C0FFEE
.equ RNGN 8
rng1:
.word 0,0,0,0,0,0,0,0
rng2:
.word 0,0,0,0
rstate:
.word 0
loopi:
.word 0
laststor:
.word 0
tA:
.word 0
tB:
.word 0
tC:
.word 0
tP:
.word 0
tR:
.word 0
tClean:
.word 0
tMut:
.word 0
tOmit:
.word 0
tExp:
.word 0
tTam:
.word 0
tBud:
.word 0
tDl:
.word 0
sTam:
.word 0
headA:
.word 0
headB:
.word 0
headC:
.word 0
headP:
.word 0
cpHead:
.word 0
headR:
.word 0
divE:
.word 0
divG:
.word 0
evil:
.word 0
cp:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0

.org 0x7000
stack:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
