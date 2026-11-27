; nreplay.nas - deterministic RNG, trace replay and checkpoint replay (F8).
;
; This library is pure NaN and has no host randomness.  It layers a replay
; engine over a nantrace capability:
;
;   * xorshift32 PRNG with an explicit 32-bit state and caller save/restore;
;   * record mode: append observed events to a nantrace trace;
;   * replay mode: compare observed events against a sealed reference trace
;     (or an explicitly armed expectation) and append only on a match;
;   * a divergence record {index, expected hash, got hash};
;   * checkpoint replay: caller buffer holds RNG state, trace head, event
;     index, step/tick counters and budget/deadline; restore rewinds the
;     trace metadata and the same suffix must reproduce the same head;
;   * step/tick budget and absolute tick deadline, both fail-closed.
;
; Status codes (nr_status):
;   0 OK, 1 divergence, 2 step budget exceeded, 3 deadline missed,
;   4 trace/state error (sealed trace, bad header, failed verification).
; Once status is nonzero every mutating/observing entry point returns -1
; without appending.  nr_restore is only accepted from status 0.
;
; ABI (r0=0, r13=1, r14=SP grows up, r15=link):
;   nrng_init           r1=seed -> 0
;   nrng_next           -> next 32-bit value
;   nrng_state_save     r1=dst word -> state
;   nrng_state_restore  r1=src word -> restored state
;   nr_begin            r1=seed r2=trace cap -> 0 / -1
;   nr_event            r1=kind r2=a r3=b -> index / -1
;   nr_expect           r1=kind r2=a r3=b -> 0 / -1 (arms one expectation)
;   nr_observe          r1=kind r2=a r3=b -> index / -1
;   nr_ref              r1=sealed trace cap -> 0 / -1 (attach reference)
;   nr_limits           r1=step budget (0 unlimited) r2=tick deadline (0 none)
;   nr_cost             r1=steps r2=ticks -> 0 / -1 (explicit accounting)
;   nr_head             -> trace head
;   nr_index            -> next event index / event count
;   nr_status           -> status code
;   nr_div_index        -> divergence event index
;   nr_div_expected     -> expected event hash
;   nr_div_got          -> observed event hash
;   nr_head_check       r1=expected head -> 0 / -1 (mismatch is divergence)
;   nr_checkpoint       r1=caller buffer -> words (13) / 0
;   nr_restore          r1=caller buffer -> 0 / -1
;   nr_seal             -> head hash / -1
;   nr_verify           -> 0 / -1
;
; Engine globals occupy the reserved low block 0x2800..0x285F, so code/data
; that links this library must end below 0x2800.  The trace payload and
; storage objects are ordinary nanobj objects owned by nantrace.
;
; Checkpoint record (13 words, caller supplied):
;   0 magic "NRCP" (0x4E524350)  1 version (1)
;   2 RNG state                  3 trace head
;   4 event index                5 steps used
;   6 tick                       7 status (must be 0)
;   8 trace cap                  9 reference cap
;   10 step budget               11 tick deadline
;   12 seal over words 0..11

.include "nantrace.nas"

.equ NR_G_RNG       0x2800
.equ NR_G_TRACE     0x2801
.equ NR_G_REF       0x2802
.equ NR_G_INDEX     0x2803
.equ NR_G_HEAD      0x2804
.equ NR_G_STEPS     0x2805
.equ NR_G_BUDGET    0x2806
.equ NR_G_TICK      0x2807
.equ NR_G_DEADLINE  0x2808
.equ NR_G_STATUS    0x2809
.equ NR_G_DIVIDX    0x280A
.equ NR_G_DIVEXP    0x280B
.equ NR_G_DIVGOT    0x280C
.equ NR_G_EXPK      0x280D
.equ NR_G_EXPA      0x280E
.equ NR_G_EXPB      0x280F
.equ NR_G_EXPON     0x2810
.equ NR_G_REFSTOR   0x2811
.equ NR_G_REFCOUNT  0x2812
.equ NR_G_REFHEAD   0x2813
.equ NR_G_T0        0x2814
.equ NR_G_T1        0x2815
.equ NR_G_T2        0x2816
.equ NR_G_T3        0x2817
.equ NR_G_T4        0x2818
.equ NR_G_T5        0x2819
.equ NR_G_T6        0x281A
.equ NR_G_T7        0x281B
.equ NR_G_T8        0x281C
.equ NR_G_T9        0x281D
.equ NR_G_T10       0x281E
.equ NR_G_T11       0x281F
.equ NR_G_T12       0x2820
.equ NR_G_T13       0x2821
.equ NR_G_T14       0x2822
.equ NR_G_T15       0x2823
.equ NR_G_HDR       0x2840        ; 8-word trace header scratch
.equ NR_G_EVB       0x2850        ; 4-word reference event scratch

.equ NR_RNG_ZERO    0x9E3779B9
.equ NR_CK_MAGIC    0x4E524350    ; "NRCP"
.equ NR_CK_SEED     0x4E524353    ; "NRCS"
.equ NR_CK_VER      1
.equ NR_CK_WORDS    13
.equ NR_TEXT_WORDS  5             ; storage, capacity, count, head, sealed

; ---------------------------------------------------------------------------
; nrng_init: r1=seed -> 0.  A zero seed is mapped to a fixed nonzero state.
nrng_init:
  CMP r1,r0
  JMP[NE] @nrng_i_st
  LA r1,#NR_RNG_ZERO
nrng_i_st:
  ST r1,r0,#NR_G_RNG
  MOVI r1,0
  RET

; nrng_next -> next 32-bit xorshift32 value.  State is always nonzero.
nrng_next:
  LD r1,r0,#NR_G_RNG
  SHL r3,r1,13
  BOOL.6 r1,r1,r3              ; x ^= x << 13
  SHR r3,r1,17
  BOOL.6 r1,r1,r3              ; x ^= x >> 17
  SHL r3,r1,5
  BOOL.6 r1,r1,r3              ; x ^= x << 5
  CMP r1,r0
  JMP[NE] @nrng_n_st
  LA r1,#NR_RNG_ZERO
nrng_n_st:
  ST r1,r0,#NR_G_RNG
  RET

; nrng_state_save: r1=dst -> saved state.
nrng_state_save:
  LD r2,r0,#NR_G_RNG
  ST r2,r1,0
  ADD r1,r2,r0
  RET

; nrng_state_restore: r1=src -> restored state.
nrng_state_restore:
  LD r2,r1,0
  CMP r2,r0
  JMP[NE] @nrng_r_st
  LA r2,#NR_RNG_ZERO
nrng_r_st:
  ST r2,r0,#NR_G_RNG
  ADD r1,r2,r0
  RET

; ---------------------------------------------------------------------------
; nr_clear: zero the engine block 0x2800..0x285F.  Leaf.
nr_clear:
  LA r1,#NR_G_RNG
  MOVI r2,0x60
nr_cl_l:
  CMP r2,r0
  JMP[EQ] @nr_cl_d
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nr_cl_l
nr_cl_d:
  RET

; nr_guard -> 0 when status is OK, else -1.
nr_guard:
  LD r1,r0,#NR_G_STATUS
  CMP r1,r0
  JMP[EQ] @nr_g_ok
  LA r1,0xFFFFFFFF
  RET
nr_g_ok:
  MOVI r1,0
  RET

; nr_div: r1=expected hash r2=got hash -> -1.  Records divergence at the
; current event index and latches the engine.
nr_div:
  ST r1,r0,#NR_G_DIVEXP
  ST r2,r0,#NR_G_DIVGOT
  LD r3,r0,#NR_G_INDEX
  ST r3,r0,#NR_G_DIVIDX
  MOVI r3,1
  ST r3,r0,#NR_G_STATUS
  LA r1,0xFFFFFFFF
  RET

; nr_cost: r1=steps r2=ticks -> 0 / -1.  Charges then enforces both limits.
nr_cost:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  CALL @nr_guard
  CMP r1,r0
  JMP[NE] @nrc_out
  LD r3,r0,#NR_G_STEPS
  LD r4,r14,1
  ADD r3,r3,r4
  ST r3,r0,#NR_G_STEPS
  LD r4,r0,#NR_G_BUDGET
  CMP r4,r0
  JMP[EQ] @nrc_tick
  CMP r3,r4
  JMP[LE] @nrc_tick
  MOVI r3,2
  ST r3,r0,#NR_G_STATUS
  LA r1,0xFFFFFFFF
  JMP @nrc_out
nrc_tick:
  LD r3,r0,#NR_G_TICK
  LD r4,r14,2
  ADD r3,r3,r4
  ST r3,r0,#NR_G_TICK
  LD r4,r0,#NR_G_DEADLINE
  CMP r4,r0
  JMP[EQ] @nrc_ok
  CMP r3,r4
  JMP[LE] @nrc_ok
  MOVI r3,3
  ST r3,r0,#NR_G_STATUS
  LA r1,0xFFFFFFFF
  JMP @nrc_out
nrc_ok:
  MOVI r1,0
nrc_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nr_consume -> 0 / -1.  One event costs one step and one tick.
nr_consume:
  MOVI r1,1
  MOVI r2,1
  JMP @nr_cost

; ---------------------------------------------------------------------------
; nr_begin: r1=seed r2=trace cap -> 0 / -1.  Binds the engine at the trace's
; current count/head (so a resumed trace continues deterministically).
nr_begin:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r1,r14,1
  ST r2,r14,2
  CALL @nr_clear
  LD r1,r14,1
  ST r1,r0,#NR_G_T0           ; seed survives nested stack frames
  LD r1,r14,2
  ST r1,r0,#NR_G_T1           ; trace cap
  LD r1,r0,#NR_G_T1
  CMP r1,r0
  JMP[EQ] @nrb_bad
  LA r2,#NR_G_HDR
  MOVI r3,0
  MOVI r4,#NR_TEXT_WORDS
  CALL @nobj_read
  MOVI r5,#NR_TEXT_WORDS
  CMP r1,r5
  JMP[NE] @nrb_bad
  LA r3,#NR_G_HDR
  LD r4,r3,4
  CMP r4,r0
  JMP[NE] @nrb_bad           ; sealed trace cannot be appended
  LD r1,r0,#NR_G_T1
  ST r1,r0,#NR_G_TRACE
  LD r4,r3,2
  ST r4,r0,#NR_G_INDEX
  LD r4,r3,3
  ST r4,r0,#NR_G_HEAD
  LD r1,r0,#NR_G_T0
  CALL @nrng_init
  MOVI r1,0
  JMP @nrb_out
nrb_bad:
  LA r1,0xFFFFFFFF
nrb_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; nr_event: r1=kind r2=a r3=b -> index / -1.  Record-mode append.
nr_event:
  JMP @nr_append

; nr_append: internal append with guard, budget charge, header resync.
nr_append:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @nr_guard
  CMP r1,r0
  JMP[NE] @nra_out
  CALL @nr_consume
  CMP r1,r0
  JMP[NE] @nra_out
  LD r1,r0,#NR_G_TRACE
  CMP r1,r0
  JMP[EQ] @nra_bad
  LD r2,r14,1
  LD r3,r14,2
  LD r4,r14,3
  CALL @ntrace_append
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nra_bad
  ST r1,r0,#NR_G_T15
  LD r1,r0,#NR_G_TRACE
  LA r2,#NR_G_HDR
  MOVI r3,0
  MOVI r4,#NR_TEXT_WORDS
  CALL @nobj_read
  MOVI r5,#NR_TEXT_WORDS
  CMP r1,r5
  JMP[NE] @nra_bad
  LA r3,#NR_G_HDR
  LD r4,r3,2
  ST r4,r0,#NR_G_INDEX
  LD r4,r3,3
  ST r4,r0,#NR_G_HEAD
  LD r1,r0,#NR_G_T15
  JMP @nra_out
nra_bad:
  MOVI r3,4
  ST r3,r0,#NR_G_STATUS
  LA r1,0xFFFFFFFF
nra_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; nr_expect: r1=kind r2=a r3=b -> 0 / -1.  Arms exactly one expectation.
nr_expect:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @nr_guard
  CMP r1,r0
  JMP[NE] @nrx_out
  LD r4,r0,#NR_G_TRACE
  CMP r4,r0
  JMP[EQ] @nrx_bad
  LD r4,r0,#NR_G_EXPON
  CMP r4,r0
  JMP[NE] @nrx_bad
  LD r4,r14,1
  ST r4,r0,#NR_G_EXPK
  LD r4,r14,2
  ST r4,r0,#NR_G_EXPA
  LD r4,r14,3
  ST r4,r0,#NR_G_EXPB
  MOVI r4,1
  ST r4,r0,#NR_G_EXPON
  MOVI r1,0
  JMP @nrx_out
nrx_bad:
  LA r1,0xFFFFFFFF
nrx_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nr_observe: r1=kind r2=a r3=b -> index / -1.  Compare against an armed
; expectation, else the sealed reference event at the current index, then
; append on an exact match.  Any mismatch or missing expectation latches a
; divergence record at the current index.
nr_observe:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r0,#NR_G_T2
  ST r2,r0,#NR_G_T3
  ST r3,r0,#NR_G_T4
  CALL @nr_guard
  CMP r1,r0
  JMP[NE] @nob_out
  LD r4,r0,#NR_G_EXPON
  CMP r4,r0
  JMP[EQ] @nob_ref
  ; explicit expectation: expected hash from current head
  LD r1,r0,#NR_G_HEAD
  LD r2,r0,#NR_G_EXPK
  LD r3,r0,#NR_G_EXPA
  LD r4,r0,#NR_G_EXPB
  CALL @nt_hash_event
  ST r1,r0,#NR_G_T5
  LD r5,r0,#NR_G_T2
  LD r6,r0,#NR_G_EXPK
  CMP r5,r6
  JMP[NE] @nob_mis
  LD r5,r0,#NR_G_T3
  LD r6,r0,#NR_G_EXPA
  CMP r5,r6
  JMP[NE] @nob_mis
  LD r5,r0,#NR_G_T4
  LD r6,r0,#NR_G_EXPB
  CMP r5,r6
  JMP[NE] @nob_mis
  JMP @nob_append
nob_ref:
  LD r4,r0,#NR_G_REF
  CMP r4,r0
  JMP[EQ] @nob_noexp
  LD r5,r0,#NR_G_INDEX
  LD r6,r0,#NR_G_REFCOUNT
  CMP r5,r6
  JMP[GE] @nob_missing
  LD r1,r0,#NR_G_REFSTOR
  LA r2,#NR_G_EVB
  LD r3,r0,#NR_G_INDEX
  SHL r3,r3,2
  MOVI r4,4
  CALL @nobj_read
  MOVI r5,4
  CMP r1,r5
  JMP[NE] @nob_state
  LA r5,#NR_G_EVB
  LD r6,r5,0
  ST r6,r0,#NR_G_T6
  LD r6,r5,1
  ST r6,r0,#NR_G_T7
  LD r6,r5,2
  ST r6,r0,#NR_G_T8
  LD r6,r5,3
  ST r6,r0,#NR_G_T5
  LD r6,r0,#NR_G_T2
  LD r7,r0,#NR_G_T6
  CMP r6,r7
  JMP[NE] @nob_mis
  LD r6,r0,#NR_G_T3
  LD r7,r0,#NR_G_T7
  CMP r6,r7
  JMP[NE] @nob_mis
  LD r6,r0,#NR_G_T4
  LD r7,r0,#NR_G_T8
  CMP r6,r7
  JMP[NE] @nob_mis
  JMP @nob_append
nob_append:
  LD r1,r0,#NR_G_T2
  LD r2,r0,#NR_G_T3
  LD r3,r0,#NR_G_T4
  CALL @nr_append
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nob_out
  ST r0,r0,#NR_G_EXPON
  JMP @nob_out
nob_mis:
  LD r1,r0,#NR_G_HEAD
  LD r2,r0,#NR_G_T2
  LD r3,r0,#NR_G_T3
  LD r4,r0,#NR_G_T4
  CALL @nt_hash_event
  ADD r3,r1,r0
  LD r1,r0,#NR_G_T5
  ADD r2,r3,r0
  CALL @nr_div
  JMP @nob_out
nob_missing:
  LD r1,r0,#NR_G_HEAD
  LD r2,r0,#NR_G_T2
  LD r3,r0,#NR_G_T3
  LD r4,r0,#NR_G_T4
  CALL @nt_hash_event
  ADD r2,r1,r0
  MOVI r1,0
  CALL @nr_div
  JMP @nob_out
nob_noexp:
  LD r1,r0,#NR_G_HEAD
  LD r2,r0,#NR_G_T2
  LD r3,r0,#NR_G_T3
  LD r4,r0,#NR_G_T4
  CALL @nt_hash_event
  ADD r2,r1,r0
  MOVI r1,0
  CALL @nr_div
  JMP @nob_out
nob_state:
  MOVI r3,4
  ST r3,r0,#NR_G_STATUS
  LA r1,0xFFFFFFFF
nob_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nr_ref: r1=sealed trace cap -> 0 / -1.  Verifies the chain before binding.
nr_ref:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r0,#NR_G_T9
  CMP r1,r0
  JMP[EQ] @nrf_bad
  LA r2,#NR_G_HDR
  MOVI r3,0
  MOVI r4,#NR_TEXT_WORDS
  CALL @nobj_read
  MOVI r5,#NR_TEXT_WORDS
  CMP r1,r5
  JMP[NE] @nrf_bad
  LA r3,#NR_G_HDR
  LD r4,r3,4
  CMP r4,r13
  JMP[NE] @nrf_bad
  LD r1,r0,#NR_G_T9
  CALL @ntrace_verify
  CMP r1,r0
  JMP[NE] @nrf_bad
  LD r4,r0,#NR_G_T9
  ST r4,r0,#NR_G_REF
  LA r3,#NR_G_HDR
  LD r4,r3,0
  ST r4,r0,#NR_G_REFSTOR
  LD r4,r3,2
  ST r4,r0,#NR_G_REFCOUNT
  LD r4,r3,3
  ST r4,r0,#NR_G_REFHEAD
  MOVI r1,0
  JMP @nrf_out
nrf_bad:
  LA r1,0xFFFFFFFF
nrf_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nr_limits: r1=step budget (0 unlimited) r2=absolute tick deadline (0 none).
nr_limits:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  CALL @nr_guard
  CMP r1,r0
  JMP[NE] @nrl_out
  LD r3,r0,#NR_G_TRACE
  CMP r3,r0
  JMP[EQ] @nrl_bad
  LD r3,r14,1
  ST r3,r0,#NR_G_BUDGET
  LD r3,r14,2
  ST r3,r0,#NR_G_DEADLINE
  MOVI r1,0
  JMP @nrl_out
nrl_bad:
  LA r1,0xFFFFFFFF
nrl_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; getters (leaves)
nr_head:
  LD r1,r0,#NR_G_HEAD
  RET
nr_index:
  LD r1,r0,#NR_G_INDEX
  RET
nr_status:
  LD r1,r0,#NR_G_STATUS
  RET
nr_div_index:
  LD r1,r0,#NR_G_DIVIDX
  RET
nr_div_expected:
  LD r1,r0,#NR_G_DIVEXP
  RET
nr_div_got:
  LD r1,r0,#NR_G_DIVGOT
  RET

; nr_head_check: r1=expected head -> 0 / -1.  A mismatch is a divergence at
; the current event index.
nr_head_check:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  CALL @nr_guard
  CMP r1,r0
  JMP[NE] @nhc_out
  LD r1,r14,1
  LD r2,r0,#NR_G_HEAD
  CMP r1,r2
  JMP[EQ] @nhc_ok
  CALL @nr_div
  JMP @nhc_out
nhc_ok:
  MOVI r1,0
nhc_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nr_ck_hash: r1=checkpoint buffer -> seal over words 0..11.
nr_ck_hash:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  LA r2,#NR_CK_SEED
  ST r2,r14,2
  MOVI r2,0
  ST r2,r14,3
nck_l:
  LD r2,r14,3
  MOVI r3,12
  CMP r2,r3
  JMP[GE] @nck_done
  LD r4,r14,1
  ADD r4,r4,r2
  LD r2,r4,0
  LD r1,r14,2
  CALL @nt_mix
  ST r1,r14,2
  LD r2,r14,3
  ADDI r2,r2,1
  ST r2,r14,3
  JMP @nck_l
nck_done:
  LD r1,r14,2
  CMP r1,r0
  JMP[NE] @nck_out
  LA r1,#NR_CK_SEED
nck_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nr_checkpoint: r1=caller buffer -> 13 / 0.  Only from a clean, in-sync,
; unsealed trace with no armed expectation.
nr_checkpoint:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r0,#NR_G_T10
  CALL @nr_guard
  CMP r1,r0
  JMP[NE] @ncp_out
  LD r3,r0,#NR_G_EXPON
  CMP r3,r0
  JMP[NE] @ncp_fail
  LD r3,r0,#NR_G_TRACE
  CMP r3,r0
  JMP[EQ] @ncp_fail
  LD r1,r0,#NR_G_TRACE
  LA r2,#NR_G_HDR
  MOVI r3,0
  MOVI r4,#NR_TEXT_WORDS
  CALL @nobj_read
  MOVI r5,#NR_TEXT_WORDS
  CMP r1,r5
  JMP[NE] @ncp_fail
  LA r3,#NR_G_HDR
  LD r4,r3,4
  CMP r4,r0
  JMP[NE] @ncp_fail
  LD r4,r3,2
  LD r5,r0,#NR_G_INDEX
  CMP r4,r5
  JMP[NE] @ncp_fail
  LD r4,r3,3
  LD r5,r0,#NR_G_HEAD
  CMP r4,r5
  JMP[NE] @ncp_fail
  LD r6,r0,#NR_G_T10
  LA r7,#NR_CK_MAGIC
  ST r7,r6,0
  MOVI r7,#NR_CK_VER
  ST r7,r6,1
  LD r7,r0,#NR_G_RNG
  ST r7,r6,2
  LD r7,r0,#NR_G_HEAD
  ST r7,r6,3
  LD r7,r0,#NR_G_INDEX
  ST r7,r6,4
  LD r7,r0,#NR_G_STEPS
  ST r7,r6,5
  LD r7,r0,#NR_G_TICK
  ST r7,r6,6
  ST r0,r6,7
  LD r7,r0,#NR_G_TRACE
  ST r7,r6,8
  LD r7,r0,#NR_G_REF
  ST r7,r6,9
  LD r7,r0,#NR_G_BUDGET
  ST r7,r6,10
  LD r7,r0,#NR_G_DEADLINE
  ST r7,r6,11
  LD r1,r0,#NR_G_T10
  CALL @nr_ck_hash
  LD r6,r0,#NR_G_T10
  ST r1,r6,12
  MOVI r1,#NR_CK_WORDS
  JMP @ncp_out
ncp_fail:
  MOVI r1,0
ncp_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nr_restore: r1=caller buffer -> 0 / -1.  Validates the seal and the bound
; trace, rewinds trace metadata to the checkpoint index/head, restores the
; RNG and counters.  The caller must replay the same suffix; nr_head_check
; proves the identical head.
nr_restore:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r0,#NR_G_T11
  CALL @nr_guard
  CMP r1,r0
  JMP[NE] @nrs_out
  LD r6,r0,#NR_G_T11
  LD r7,r6,0
  LA r3,#NR_CK_MAGIC
  CMP r7,r3
  JMP[NE] @nrs_bad
  LD r7,r6,1
  MOVI r3,#NR_CK_VER
  CMP r7,r3
  JMP[NE] @nrs_bad
  LD r7,r6,12
  ST r7,r0,#NR_G_T12
  LD r1,r0,#NR_G_T11
  CALL @nr_ck_hash
  LD r7,r0,#NR_G_T12
  CMP r1,r7
  JMP[NE] @nrs_bad
  LD r6,r0,#NR_G_T11
  LD r7,r6,7
  CMP r7,r0
  JMP[NE] @nrs_bad
  LD r7,r6,8
  LD r8,r0,#NR_G_TRACE
  CMP r7,r8
  JMP[NE] @nrs_bad
  CMP r8,r0
  JMP[EQ] @nrs_bad
  LD r7,r6,9
  LD r8,r0,#NR_G_REF
  CMP r7,r8
  JMP[NE] @nrs_bad
  LD r7,r6,4
  ST r7,r0,#NR_G_T13
  LD r7,r6,3
  ST r7,r0,#NR_G_T14
  LD r1,r0,#NR_G_TRACE
  LA r2,#NR_G_HDR
  MOVI r3,0
  MOVI r4,#NR_TEXT_WORDS
  CALL @nobj_read
  MOVI r5,#NR_TEXT_WORDS
  CMP r1,r5
  JMP[NE] @nrs_bad
  LA r3,#NR_G_HDR
  LD r4,r3,4
  CMP r4,r0
  JMP[NE] @nrs_bad
  LD r4,r3,2
  LD r5,r0,#NR_G_INDEX
  CMP r4,r5
  JMP[NE] @nrs_bad
  LD r4,r3,3
  LD r5,r0,#NR_G_HEAD
  CMP r4,r5
  JMP[NE] @nrs_bad
  LD r4,r3,2
  LD r5,r0,#NR_G_T13
  CMP r5,r4
  JMP[GT] @nrs_bad
  LD r5,r0,#NR_G_T13
  ST r5,r3,2
  LD r5,r0,#NR_G_T14
  ST r5,r3,3
  LD r1,r0,#NR_G_TRACE
  LA r2,#NR_G_HDR
  MOVI r3,0
  MOVI r4,#NR_TEXT_WORDS
  CALL @nobj_write
  MOVI r5,#NR_TEXT_WORDS
  CMP r1,r5
  JMP[NE] @nrs_bad
  LD r6,r0,#NR_G_T11
  LD r7,r6,2
  ST r7,r0,#NR_G_RNG
  LD r7,r0,#NR_G_T14
  ST r7,r0,#NR_G_HEAD
  LD r7,r0,#NR_G_T13
  ST r7,r0,#NR_G_INDEX
  LD r7,r6,5
  ST r7,r0,#NR_G_STEPS
  LD r7,r6,6
  ST r7,r0,#NR_G_TICK
  LD r7,r6,10
  ST r7,r0,#NR_G_BUDGET
  LD r7,r6,11
  ST r7,r0,#NR_G_DEADLINE
  ST r0,r0,#NR_G_STATUS
  ST r0,r0,#NR_G_EXPON
  ST r0,r0,#NR_G_DIVIDX
  ST r0,r0,#NR_G_DIVEXP
  ST r0,r0,#NR_G_DIVGOT
  MOVI r1,0
  JMP @nrs_out
nrs_bad:
  LA r1,0xFFFFFFFF
nrs_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nr_seal: -> head / -1.  Requires an in-sync, unsealed trace.
nr_seal:
  ST r15,r14,0
  ADDI r14,r14,24
  CALL @nr_guard
  CMP r1,r0
  JMP[NE] @nsl_out
  LD r3,r0,#NR_G_TRACE
  CMP r3,r0
  JMP[EQ] @nsl_bad
  LD r1,r0,#NR_G_TRACE
  LA r2,#NR_G_HDR
  MOVI r3,0
  MOVI r4,#NR_TEXT_WORDS
  CALL @nobj_read
  MOVI r5,#NR_TEXT_WORDS
  CMP r1,r5
  JMP[NE] @nsl_bad
  LA r3,#NR_G_HDR
  LD r4,r3,4
  CMP r4,r0
  JMP[NE] @nsl_bad
  LD r4,r3,2
  LD r5,r0,#NR_G_INDEX
  CMP r4,r5
  JMP[NE] @nsl_bad
  LD r4,r3,3
  LD r5,r0,#NR_G_HEAD
  CMP r4,r5
  JMP[NE] @nsl_bad
  LD r1,r0,#NR_G_TRACE
  CALL @ntrace_seal
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @nsl_bad
  JMP @nsl_out
nsl_bad:
  MOVI r3,4
  ST r3,r0,#NR_G_STATUS
  LA r1,0xFFFFFFFF
nsl_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nr_verify: -> 0 / -1.  Checks engine/header agreement then the hash chain.
nr_verify:
  ST r15,r14,0
  ADDI r14,r14,24
  CALL @nr_guard
  CMP r1,r0
  JMP[NE] @nvy_out
  LD r3,r0,#NR_G_TRACE
  CMP r3,r0
  JMP[EQ] @nvy_bad
  LD r1,r0,#NR_G_TRACE
  LA r2,#NR_G_HDR
  MOVI r3,0
  MOVI r4,#NR_TEXT_WORDS
  CALL @nobj_read
  MOVI r5,#NR_TEXT_WORDS
  CMP r1,r5
  JMP[NE] @nvy_bad
  LA r3,#NR_G_HDR
  LD r4,r3,2
  LD r5,r0,#NR_G_INDEX
  CMP r4,r5
  JMP[NE] @nvy_bad
  LD r4,r3,3
  LD r5,r0,#NR_G_HEAD
  CMP r4,r5
  JMP[NE] @nvy_bad
  LD r1,r0,#NR_G_TRACE
  CALL @ntrace_verify
  CMP r1,r0
  JMP[NE] @nvy_bad
  MOVI r1,0
  JMP @nvy_out
nvy_bad:
  MOVI r3,4
  ST r3,r0,#NR_G_STATUS
  LA r1,0xFFFFFFFF
nvy_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET
