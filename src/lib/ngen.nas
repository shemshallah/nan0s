; ngen.nas - live generation publish/drain/start with epoch fences (F13e).
;
; Pure NaN.  A generation object is one sealed-in-memory record per agent.  It
; tracks the agent's accepting generation, every recent generation slot with
; its in-flight/accept/complete/abort counters, the publish/drain/start epoch
; fence, weight/KV root generation tags, and a deterministic trace chain.
;
; Semantics
; ---------
; * A generation is admitted only when it is the current accepting generation
;   and its slot is in state CURRENT.  enter returns the generation tag.
; * ngen_publish(agent,new,..) is atomic: it validates new == current+1, emits
;   publish, places the old generation in DRAINING (no new old-gen admissions),
;   emits drain, and creates the new CURRENT slot immediately, emitting start.
;   All three events carry one epoch.  Old in-flight requests finish through
;   ngen_exit; the new generation admits in parallel.
; * When the last old in-flight request exits, the slot becomes DRAINED and a
;   drained event is emitted.  From then on an old-generation enter fails with
;   NG_ESTALE.  While the slot is still draining it fails with NG_EDRAIN.
; * ngen_abort(agent,gen) is the forced path: it only accepts a DRAINING slot,
;   charges every in-flight request to the aborted counter, zeroes in-flight,
;   marks the slot ABORTED and emits abort+drained.  Current generations cannot
;   be aborted; publish/drain first.
; * ngen_drain(agent) freezes the current generation without starting a new
;   one.  ngen_start(agent,gen) starts the next generation from idle or after a
;   drained/aborted slot.  ngen_publish is the normal atomic composite.
; * ngen_fence(agent) returns the epoch only when the last transition has
;   completed publish -> drain -> start marking in that order.  It never
;   consumes the fence; repeated queries return the same epoch until the next
;   publish/drain resets the markers.
;
; Record (stride 128 words, 32 agents at 0x352000):
;   0 magic "NGEN"        1 version (1)
;   2 agent id            3 state (1 live)
;   4 current generation  5 epoch (last publish/drain/start transition)
;   6 weight root         7 weight root generation
;   8 KV root             9 KV root generation
;   10 trace head         11 trace events     12 trace wraps
;   13 total accepted     14 total completed  15 total aborted
;   16 total rejected     17 publishes        18 drains
;   19 starts             20 aborts           21 fences
;   22 last fence epoch   23 fence state (bit0 publish, bit1 drain, bit2 start)
;   24 total drained      25 last agent error 26..31 reserved
;   32 generation slots, 4 x 8 words:
;      +0 generation +1 state (1 current, 2 draining, 3 drained, 4 aborted)
;      +2 in-flight +3 accepted +4 completed +5 aborted
;      +6 start/drain epoch +7 creation epoch
;   64 trace ring, 8 x 6 words:
;      +0 kind +1 a +2 b +3 hash +4 seq +5 epoch
;   112..127 reserved
;
; Trace events: 1 publish(gen,epoch), 2 drain(gen,epoch), 3 start(gen,epoch),
; 4 accept(gen,cpu), 5 reject(gen,code), 6 complete(gen,inflight-left),
; 7 abort(gen,count), 8 drained(gen,epoch).  The hash is a deterministic
; xor/multiply chain over the previous head, kind, a, b and epoch.
;
; Per-CPU counters (64 CPUs at 0x353000, 4 words each): accepts, rejects,
; zero, zero.  Global last error is 0x353100.
;
; Return codes / errno:
;   0 OK, 1 stale generation, 2 bad argument, 3 no such agent,
;   4 generation is draining, 5 future generation, 6 busy ordering,
;   7 duplicate publish, 8 no slot space.
; ngen_enter returns the generation tag or 0; ngen_abort returns the number of
; aborted in-flight requests or 0; the status/slot/trace queries return 0/-1.
;
; ABI: r0=0, r13=1, r14=SP (grows up), r15=link.  r1..r12 are scratch.
;
; API:
;   ngen_init
;   ngen_create      r1=agent r2=weight root r3=KV root -> 0/2/3/6
;   ngen_start       r1=agent r2=gen -> epoch / 0
;   ngen_drain       r1=agent -> epoch / 0
;   ngen_publish     r1=agent r2=new gen r3=weight root r4=KV root
;                    -> epoch / 0
;   ngen_enter       r1=agent r2=gen r3=cpu -> gen / 0
;   ngen_exit        r1=agent r2=gen -> 0 / 0 (errno)
;   ngen_abort       r1=agent r2=gen -> aborted count / 0
;   ngen_roots       r1=agent r2=weight root r3=KV root -> 0/2/3
;   ngen_fence       r1=agent -> epoch / 0
;   ngen_status      r1=agent r2=out(32) -> 0/-1
;   ngen_slot        r1=agent r2=gen r3=out(8) -> 0/-1
;   ngen_trace       r1=agent r2=index r3=out(6) -> 0/-1
;   ngen_trace_head  r1=agent -> head / 0
;   ngen_cpu         r1=cpu r2=out(4) -> 0/-1
;   ngen_inflight    r1=agent r2=gen -> count / 0xFFFFFFFF
;   ngen_epoch       r1=agent -> epoch / 0xFFFFFFFF
;   ngen_errno       -> last error

.equ NG_TAB        0x352000
.equ NG_MAX        32
.equ NG_STRIDE     128
.equ NG_TOTAL      4096
.equ NG_CPUSTATS   0x353000
.equ NG_MAX_CPU    64
.equ NG_CPU_W      4
.equ NG_CPUTOTAL   256
.equ NG_ERRNO      0x353100

.equ NG_MAGIC      0x4E47454E       ; "NGEN"
.equ NG_VERSION    1
.equ NG_TRACE_SEED 0x4E475254       ; "NGRT"
.equ NG_MIX_C1     0x9E3779B9
.equ NG_MIX_C2     0x85EBCA6B
.equ NG_MIX_C3     0xC2B2AE35

; Record fields.
.equ NG_MAGIC_F    0
.equ NG_VERSION_F  1
.equ NG_AGENT_F    2
.equ NG_STATE_F    3
.equ NG_CUR_F      4
.equ NG_EPOCH_F    5
.equ NG_WROOT_F    6
.equ NG_WGEN_F     7
.equ NG_KVROOT_F   8
.equ NG_KVGEN_F    9
.equ NG_TRACE_F    10
.equ NG_TRACE_N    11
.equ NG_WRAPS_F    12
.equ NG_ACCEPTED_F 13
.equ NG_COMPLETED_F 14
.equ NG_ABORTED_F  15
.equ NG_REJECTED_F 16
.equ NG_PUBLISH_F  17
.equ NG_DRAINS_F   18
.equ NG_STARTS_F   19
.equ NG_ABORTS_F   20
.equ NG_FENCES_F   21
.equ NG_LASTFENCE_F 22
.equ NG_FENCE_F    23
.equ NG_DRAINED_F  24
.equ NG_LERR_F     25
.equ NG_SLOT_OFF   32
.equ NG_SLOT_W     8
.equ NG_NSLOT      4
.equ NG_TRACE_OFF  64
.equ NG_TRACE_W    6
.equ NG_NTRACE     8

; Slot fields (relative).
.equ NG_S_GEN      0
.equ NG_S_STATE    1
.equ NG_S_INFLIGHT 2
.equ NG_S_ACCEPTED 3
.equ NG_S_COMPLETED 4
.equ NG_S_ABORTED  5
.equ NG_S_EPOCH    6
.equ NG_S_ENTERED  7

; Slot states.
.equ NG_S_FREE     0
.equ NG_S_CURRENT  1
.equ NG_S_DRAINING 2
.equ NG_S_DRAINED  3
.equ NG_S_ABORTED_ST 4

; Record states.
.equ NG_LIVE       1

; Trace kinds.
.equ NG_T_PUBLISH  1
.equ NG_T_DRAIN    2
.equ NG_T_START    3
.equ NG_T_ACCEPT   4
.equ NG_T_REJECT   5
.equ NG_T_COMPLETE 6
.equ NG_T_ABORT    7
.equ NG_T_DRAINED  8

; Errors.
.equ NG_OK         0
.equ NG_ESTALE     1
.equ NG_EBAD       2
.equ NG_ENOENT     3
.equ NG_EDRAIN     4
.equ NG_EFUTURE    5
.equ NG_EBUSY      6
.equ NG_EDUP       7
.equ NG_ENOSPC     8

; ---------------------------------------------------------------------------
; ng_mix r1=hash r2=word -> r1.  Same deterministic 32-bit chain as nagent.
ng_mix:
  BOOL.6 r1,r1,r2
  LA r3,#NG_MIX_C1
  ADD r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  LA r3,#NG_MIX_C2
  MUL r1,r1,r3
  SHR r4,r1,15
  BOOL.6 r1,r1,r4
  LA r3,#NG_MIX_C3
  MUL r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  RET

; ng_rec r1=agent -> record address or 0.
ng_rec:
  CMP r1,r0
  JMP[EQ] @ng_rec_none
  MOVI r2,#NG_MAX
  CMP r1,r2
  JMP[GT] @ng_rec_none
  SUB r1,r1,r13
  MOVI r2,#NG_STRIDE
  MUL r1,r1,r2
  LA r2,#NG_TAB
  ADD r1,r1,r2
  RET
ng_rec_none:
  MOVI r1,0
  RET

; ng_live r1=agent -> live record or 0.
ng_live:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  CALL @ng_rec
  CMP r1,r0
  JMP[EQ] @ng_live_no
  ST r1,r14,2
  LD r2,r1,#NG_MAGIC_F
  LA r3,#NG_MAGIC
  CMP r2,r3
  JMP[NE] @ng_live_no
  LD r2,r1,#NG_VERSION_F
  MOVI r3,#NG_VERSION
  CMP r2,r3
  JMP[NE] @ng_live_no
  LD r2,r1,#NG_AGENT_F
  LD r3,r14,1
  CMP r2,r3
  JMP[NE] @ng_live_no
  LD r2,r1,#NG_STATE_F
  CMP r2,r13
  JMP[NE] @ng_live_no
  LD r1,r14,2
  JMP @ng_live_out
ng_live_no:
  MOVI r1,0
ng_live_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ng_slot r1=record r2=generation -> slot address (index = gen & 3).
ng_slot:
  MOVI r3,3
  BOOL.8 r2,r2,r3
  MOVI r3,#NG_SLOT_W
  MUL r2,r2,r3
  ADDI r2,r2,#NG_SLOT_OFF
  ADD r1,r1,r2
  RET

; ng_find r1=record r2=gen -> slot address or 0 when the tag does not match.
ng_find:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r2,r14,1
  CALL @ng_slot
  ST r1,r14,2
  LD r2,r1,#NG_S_GEN
  LD r3,r14,1
  CMP r2,r3
  JMP[NE] @ng_find_no
  LD r1,r14,2
  JMP @ng_find_out
ng_find_no:
  MOVI r1,0
ng_find_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ng_fail r1=record(or 0) r2=code -> 0.  Sets global and per-agent errno.
ng_fail:
  ST r2,r0,#NG_ERRNO
  CMP r1,r0
  JMP[EQ] @ng_fail_out
  ST r2,r1,#NG_LERR_F
ng_fail_out:
  MOVI r1,0
  RET

; ng_trace r1=record r2=kind r3=a r4=b r5=epoch -> new head.
ng_trace:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  LD r1,r1,#NG_TRACE_F
  LD r2,r14,2
  CALL @ng_mix
  LD r2,r14,3
  CALL @ng_mix
  LD r2,r14,4
  CALL @ng_mix
  LD r2,r14,5
  CALL @ng_mix
  CMP r1,r0
  JMP[NE] @ngt_head
  LA r1,#NG_TRACE_SEED
ngt_head:
  ST r1,r14,6
  LD r6,r14,1
  LD r7,r6,#NG_TRACE_N
  ST r7,r14,7
  MOVI r8,7
  BOOL.8 r8,r7,r8
  MOVI r9,#NG_TRACE_W
  MUL r8,r8,r9
  ADDI r8,r8,#NG_TRACE_OFF
  ADD r8,r6,r8
  LD r9,r14,2
  ST r9,r8,0
  LD r9,r14,3
  ST r9,r8,1
  LD r9,r14,4
  ST r9,r8,2
  LD r9,r14,6
  ST r9,r8,3
  ST r7,r8,4
  LD r9,r14,5
  ST r9,r8,5
  ST r1,r6,#NG_TRACE_F
  MOVI r9,#NG_NTRACE
  CMP r7,r9
  JMP[LT] @ngt_nowrap
  LD r9,r6,#NG_WRAPS_F
  ADDI r9,r9,1
  ST r9,r6,#NG_WRAPS_F
ngt_nowrap:
  ADDI r7,r7,1
  ST r7,r6,#NG_TRACE_N
  LD r1,r14,6
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ng_cpu_accept r1=cpu r2=1 accept / 0 reject -> 0.
ng_cpu_count:
  MOVI r3,#NG_MAX_CPU
  CMP r1,r3
  JMP[GE] @ngcc_out
  MOVI r3,#NG_CPU_W
  MUL r1,r1,r3
  LA r3,#NG_CPUSTATS
  ADD r1,r3,r1
  LD r3,r1,0
  ADDI r3,r3,1
  ST r3,r1,0
ngcc_out:
  MOVI r1,0
  RET

; ---------------------------------------------------------------------------
; ngen_init - clear the 32 records and the 64 per-CPU counters.
ngen_init:
  LA r1,#NG_TAB
  MOVI r2,#NG_TOTAL
ngi_l:
  CMP r2,r0
  JMP[EQ] @ngi_cpu
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @ngi_l
ngi_cpu:
  LA r1,#NG_CPUSTATS
  MOVI r2,#NG_CPUTOTAL
ngi_cl:
  CMP r2,r0
  JMP[EQ] @ngi_done
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @ngi_cl
ngi_done:
  ST r0,r0,#NG_ERRNO
  MOVI r1,0
  RET

; ngen_create r1=agent r2=weight root r3=KV root -> 0 / errno.
ngen_create:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @ng_rec
  CMP r1,r0
  JMP[EQ] @ngc_bad
  ST r1,r14,4
  LD r2,r1,#NG_MAGIC_F
  LA r3,#NG_MAGIC
  CMP r2,r3
  JMP[EQ] @ngc_dup
  ; clear the full record
  MOVI r2,#NG_STRIDE
ngc_clr:
  CMP r2,r0
  JMP[EQ] @ngc_init
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @ngc_clr
ngc_init:
  LD r1,r14,4
  LA r2,#NG_MAGIC
  ST r2,r1,#NG_MAGIC_F
  MOVI r2,#NG_VERSION
  ST r2,r1,#NG_VERSION_F
  LD r2,r14,1
  ST r2,r1,#NG_AGENT_F
  MOVI r2,#NG_LIVE
  ST r2,r1,#NG_STATE_F
  LA r2,#NG_TRACE_SEED
  ST r2,r1,#NG_TRACE_F
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @ngc_nw
  ST r2,r1,#NG_WROOT_F
  MOVI r3,1
  ST r3,r1,#NG_WGEN_F
ngc_nw:
  LD r2,r14,3
  CMP r2,r0
  JMP[EQ] @ngc_ok
  ST r2,r1,#NG_KVROOT_F
  MOVI r3,1
  ST r3,r1,#NG_KVGEN_F
ngc_ok:
  ST r0,r0,#NG_ERRNO
  MOVI r1,0
  JMP @ngc_out
ngc_dup:
  LD r1,r14,4
  MOVI r2,#NG_EBAD
  CALL @ng_fail
  JMP @ngc_out
ngc_bad:
  MOVI r1,0
  MOVI r2,#NG_EBAD
  CALL @ng_fail
ngc_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ng_slot_reset r1=slot r2=gen r3=state r4=epoch -> initializes the slot.
ng_slot_reset:
  ST r2,r1,#NG_S_GEN
  ST r3,r1,#NG_S_STATE
  ST r0,r1,#NG_S_INFLIGHT
  ST r0,r1,#NG_S_ACCEPTED
  ST r0,r1,#NG_S_COMPLETED
  ST r0,r1,#NG_S_ABORTED
  ST r4,r1,#NG_S_EPOCH
  ST r4,r1,#NG_S_ENTERED
  RET

; ngen_start r1=agent r2=gen -> epoch / 0.
ngen_start:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  CALL @ng_live
  CMP r1,r0
  JMP[EQ] @ngst_noent
  ST r1,r14,3
  LD r2,r1,#NG_CUR_F
  ST r2,r14,4
  LD r3,r14,2
  CMP r3,r0
  JMP[EQ] @ngst_bad
  CMP r2,r0
  JMP[NE] @ngst_next
  CMP r3,r13
  JMP[NE] @ngst_bad
  JMP @ngst_slot
ngst_next:
  ADDI r4,r2,1
  CMP r3,r4
  JMP[NE] @ngst_bad
  ; the previous current slot must have finished draining/aborting
  LD r1,r14,3
  LD r2,r14,4
  CALL @ng_find
  CMP r1,r0
  JMP[EQ] @ngst_busy
  ST r1,r14,5
  LD r2,r1,#NG_S_STATE
  MOVI r3,#NG_S_DRAINED
  CMP r2,r3
  JMP[EQ] @ngst_slot
  MOVI r3,#NG_S_ABORTED_ST
  CMP r2,r3
  JMP[EQ] @ngst_slot
  JMP @ngst_busy
ngst_slot:
  LD r1,r14,3
  LD r2,r14,2
  CALL @ng_slot
  ST r1,r14,6
  LD r2,r1,#NG_S_GEN
  CMP r2,r0
  JMP[EQ] @ngst_ready
  LD r3,r14,2
  CMP r2,r3
  JMP[EQ] @ngst_busy
  LD r3,r1,#NG_S_STATE
  MOVI r4,#NG_S_CURRENT
  CMP r3,r4
  JMP[EQ] @ngst_busy
  MOVI r4,#NG_S_DRAINING
  CMP r3,r4
  JMP[EQ] @ngst_busy
ngst_ready:
  LD r1,r14,3
  LD r2,r1,#NG_EPOCH_F
  ADDI r2,r2,1
  ST r2,r1,#NG_EPOCH_F
  ST r2,r14,7
  LD r3,r1,#NG_STARTS_F
  ADDI r3,r3,1
  ST r3,r1,#NG_STARTS_F
  LD r3,r14,2
  ST r3,r1,#NG_CUR_F
  MOVI r3,4
  ST r3,r1,#NG_FENCE_F
  LD r1,r14,6
  LD r2,r14,2
  MOVI r3,#NG_S_CURRENT
  LD r4,r14,7
  CALL @ng_slot_reset
  LD r1,r14,3
  LD r2,r14,2
  LD r3,r14,7
  CALL @ng_trace_ev
  LD r1,r14,7
  ST r0,r0,#NG_ERRNO
  JMP @ngst_out
ngst_noent:
  MOVI r1,0
  MOVI r2,#NG_ENOENT
  CALL @ng_fail
  JMP @ngst_out
ngst_bad:
  LD r1,r14,3
  MOVI r2,#NG_EBAD
  CALL @ng_fail
  JMP @ngst_out
ngst_busy:
  LD r1,r14,3
  MOVI r2,#NG_EBUSY
  CALL @ng_fail
ngst_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ng_trace_ev r1=rec r2=a r3=b -> head; kind is r9?  No - explicit kind.
; Use ng_trace_ev as start event only; other emitters call ng_trace directly.
ng_trace_ev:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LD r5,r1,#NG_EPOCH_F
  MOVI r2,#NG_T_START
  LD r3,r14,2
  LD r4,r14,3
  CALL @ng_trace
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ngen_drain r1=agent -> epoch / 0.  Freeze the current generation; no new
; admissions until it completes/aborts and ngen_start begins the next one.
ngen_drain:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  CALL @ng_live
  CMP r1,r0
  JMP[EQ] @ngd_noent
  ST r1,r14,2
  LD r2,r1,#NG_CUR_F
  CMP r2,r0
  JMP[EQ] @ngd_bad
  ST r2,r14,3
  ADD r2,r2,r0
  CALL @ng_find
  CMP r1,r0
  JMP[EQ] @ngd_bad
  ST r1,r14,4
  LD r2,r1,#NG_S_STATE
  CMP r2,r13
  JMP[NE] @ngd_busy
  LD r1,r14,2
  LD r2,r1,#NG_EPOCH_F
  ADDI r2,r2,1
  ST r2,r1,#NG_EPOCH_F
  ST r2,r14,5
  LD r3,r1,#NG_DRAINS_F
  ADDI r3,r3,1
  ST r3,r1,#NG_DRAINS_F
  MOVI r3,2
  ST r3,r1,#NG_FENCE_F
  LD r1,r14,4
  MOVI r2,#NG_S_DRAINING
  ST r2,r1,#NG_S_STATE
  LD r2,r14,5
  ST r2,r1,#NG_S_EPOCH
  ; drain event
  LD r1,r14,2
  MOVI r2,#NG_T_DRAIN
  LD r3,r14,3
  LD r4,r14,5
  LD r5,r14,5
  CALL @ng_trace
  ; zero in-flight means the drain is already complete
  LD r1,r14,4
  LD r2,r1,#NG_S_INFLIGHT
  CMP r2,r0
  JMP[NE] @ngd_ok
  MOVI r2,#NG_S_DRAINED
  ST r2,r1,#NG_S_STATE
  LD r2,r14,2
  LD r3,r1,#NG_DRAINED_F
  ADDI r3,r3,1
  ST r3,r2,#NG_DRAINED_F
  MOVI r2,#NG_T_DRAINED
  LD r1,r14,2
  LD r3,r14,3
  LD r4,r14,5
  LD r5,r14,5
  CALL @ng_trace
ngd_ok:
  LD r1,r14,5
  ST r0,r0,#NG_ERRNO
  JMP @ngd_out
ngd_noent:
  MOVI r1,0
  MOVI r2,#NG_ENOENT
  CALL @ng_fail
  JMP @ngd_out
ngd_bad:
  LD r1,r14,2
  MOVI r2,#NG_EBAD
  CALL @ng_fail
  JMP @ngd_out
ngd_busy:
  LD r1,r14,2
  MOVI r2,#NG_EBUSY
  CALL @ng_fail
ngd_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ngen_publish r1=agent r2=new gen r3=weight root r4=KV root -> epoch / 0.
ngen_publish:
  ST r15,r14,0
  ADDI r14,r14,72
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  CALL @ng_live
  CMP r1,r0
  JMP[EQ] @ngp_noent
  ST r1,r14,5
  LD r2,r1,#NG_CUR_F
  ST r2,r14,6
  LD r3,r14,2
  CMP r3,r0
  JMP[EQ] @ngp_bad
  CMP r2,r0
  JMP[EQ] @ngp_bad
  CMP r3,r2
  JMP[EQ] @ngp_dup
  CMP r3,r2
  JMP[LT] @ngp_stale
  ADDI r4,r2,1
  CMP r3,r4
  JMP[NE] @ngp_future
  ; old current slot must be CURRENT
  LD r1,r14,5
  LD r2,r14,6
  CALL @ng_find
  CMP r1,r0
  JMP[EQ] @ngp_busy
  ST r1,r14,7
  LD r2,r1,#NG_S_STATE
  CMP r2,r13
  JMP[NE] @ngp_busy
  ; target slot must be free or a finished older generation
  LD r1,r14,5
  LD r2,r14,2
  CALL @ng_slot
  ST r1,r14,8
  LD r2,r1,#NG_S_GEN
  CMP r2,r0
  JMP[EQ] @ngp_epoch
  LD r3,r14,2
  CMP r2,r3
  JMP[EQ] @ngp_dup
  LD r3,r1,#NG_S_STATE
  MOVI r4,#NG_S_CURRENT
  CMP r3,r4
  JMP[EQ] @ngp_busy
  MOVI r4,#NG_S_DRAINING
  CMP r3,r4
  JMP[EQ] @ngp_busy
ngp_epoch:
  LD r1,r14,5
  LD r2,r1,#NG_EPOCH_F
  ADDI r2,r2,1
  ST r2,r1,#NG_EPOCH_F
  ST r2,r14,9
  LD r3,r1,#NG_PUBLISH_F
  ADDI r3,r3,1
  ST r3,r1,#NG_PUBLISH_F
  MOVI r3,1
  ST r3,r1,#NG_FENCE_F
  ; publish
  LD r1,r14,5
  MOVI r2,#NG_T_PUBLISH
  LD r3,r14,2
  LD r4,r14,9
  LD r5,r14,9
  CALL @ng_trace
  ; old slot -> draining
  LD r1,r14,7
  MOVI r2,#NG_S_DRAINING
  ST r2,r1,#NG_S_STATE
  LD r2,r14,9
  ST r2,r1,#NG_S_EPOCH
  LD r1,r14,5
  LD r2,r1,#NG_DRAINS_F
  ADDI r2,r2,1
  ST r2,r1,#NG_DRAINS_F
  MOVI r2,2
  LD r3,r1,#NG_FENCE_F
  BOOL.14 r3,r3,r2
  ST r3,r1,#NG_FENCE_F
  ; drain
  LD r1,r14,5
  MOVI r2,#NG_T_DRAIN
  LD r3,r14,6
  LD r4,r14,9
  LD r5,r14,9
  CALL @ng_trace
  ; auto-drain when there are no old in-flight requests
  LD r1,r14,7
  LD r2,r1,#NG_S_INFLIGHT
  CMP r2,r0
  JMP[NE] @ngp_new
  MOVI r2,#NG_S_DRAINED
  ST r2,r1,#NG_S_STATE
  LD r1,r14,5
  LD r2,r1,#NG_DRAINED_F
  ADDI r2,r2,1
  ST r2,r1,#NG_DRAINED_F
  MOVI r2,#NG_T_DRAINED
  LD r3,r14,6
  LD r4,r14,9
  LD r5,r14,9
  CALL @ng_trace
ngp_new:
  ; new slot -> current
  LD r1,r14,8
  LD r2,r14,2
  MOVI r3,#NG_S_CURRENT
  LD r4,r14,9
  CALL @ng_slot_reset
  LD r1,r14,5
  LD r2,r14,2
  ST r2,r1,#NG_CUR_F
  LD r3,r1,#NG_STARTS_F
  ADDI r3,r3,1
  ST r3,r1,#NG_STARTS_F
  MOVI r3,4
  LD r4,r1,#NG_FENCE_F
  BOOL.14 r4,r4,r3
  ST r4,r1,#NG_FENCE_F
  ; start
  LD r1,r14,5
  MOVI r2,#NG_T_START
  LD r3,r14,2
  LD r4,r14,9
  LD r5,r14,9
  CALL @ng_trace
  ; roots: a changed root advances its generation tag
  LD r1,r14,5
  LD r2,r14,3
  CMP r2,r0
  JMP[EQ] @ngp_kv
  LD r3,r1,#NG_WROOT_F
  CMP r3,r0
  JMP[EQ] @ngp_wset
  CMP r3,r2
  JMP[EQ] @ngp_kv
  LD r3,r1,#NG_WGEN_F
  ADDI r3,r3,1
  ST r3,r1,#NG_WGEN_F
ngp_wset:
  LD r3,r1,#NG_WGEN_F
  CMP r3,r0
  JMP[NE] @ngp_wset2
  MOVI r3,1
  ST r3,r1,#NG_WGEN_F
ngp_wset2:
  ST r2,r1,#NG_WROOT_F
ngp_kv:
  LD r2,r14,4
  CMP r2,r0
  JMP[EQ] @ngp_ok
  LD r3,r1,#NG_KVROOT_F
  CMP r3,r0
  JMP[EQ] @ngp_kvset
  CMP r3,r2
  JMP[EQ] @ngp_ok
  LD r3,r1,#NG_KVGEN_F
  ADDI r3,r3,1
  ST r3,r1,#NG_KVGEN_F
ngp_kvset:
  LD r3,r1,#NG_KVGEN_F
  CMP r3,r0
  JMP[NE] @ngp_kvset2
  MOVI r3,1
  ST r3,r1,#NG_KVGEN_F
ngp_kvset2:
  ST r2,r1,#NG_KVROOT_F
ngp_ok:
  LD r1,r14,9
  ST r0,r0,#NG_ERRNO
  JMP @ngp_out
ngp_noent:
  MOVI r1,0
  MOVI r2,#NG_ENOENT
  CALL @ng_fail
  JMP @ngp_out
ngp_bad:
  LD r1,r14,5
  MOVI r2,#NG_EBAD
  CALL @ng_fail
  JMP @ngp_out
ngp_dup:
  LD r1,r14,5
  MOVI r2,#NG_EDUP
  CALL @ng_fail
  JMP @ngp_out
ngp_stale:
  LD r1,r14,5
  MOVI r2,#NG_ESTALE
  CALL @ng_fail
  JMP @ngp_out
ngp_future:
  LD r1,r14,5
  MOVI r2,#NG_EFUTURE
  CALL @ng_fail
  JMP @ngp_out
ngp_busy:
  LD r1,r14,5
  MOVI r2,#NG_EBUSY
  CALL @ng_fail
ngp_out:
  ADDI r14,r14,-72
  LD r15,r14,0
  RET

; ngen_enter r1=agent r2=gen r3=cpu -> gen / 0.
ngen_enter:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  MOVI r4,#NG_MAX_CPU
  CMP r3,r4
  JMP[GE] @nge_badarg
  CALL @ng_live
  CMP r1,r0
  JMP[EQ] @nge_noent
  ST r1,r14,4
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @nge_bad
  LD r3,r1,#NG_CUR_F
  ST r3,r14,5
  CMP r3,r0
  JMP[EQ] @nge_bad
  CMP r2,r3
  JMP[GT] @nge_future
  ; locate the slot and decide accept/drain/stale
  LD r1,r14,4
  LD r2,r14,2
  CALL @ng_find
  CMP r1,r0
  JMP[EQ] @nge_stale
  ST r1,r14,6
  LD r2,r1,#NG_S_STATE
  MOVI r3,#NG_S_CURRENT
  CMP r2,r3
  JMP[EQ] @nge_accept
  MOVI r3,#NG_S_DRAINING
  CMP r2,r3
  JMP[EQ] @nge_drain
  MOVI r3,#NG_S_DRAINED
  CMP r2,r3
  JMP[EQ] @nge_stale
  MOVI r3,#NG_S_ABORTED_ST
  CMP r2,r3
  JMP[EQ] @nge_stale
  JMP @nge_stale
nge_accept:
  LD r1,r14,6
  LD r2,r1,#NG_S_INFLIGHT
  ADDI r2,r2,1
  ST r2,r1,#NG_S_INFLIGHT
  LD r2,r1,#NG_S_ACCEPTED
  ADDI r2,r2,1
  ST r2,r1,#NG_S_ACCEPTED
  LD r1,r14,4
  LD r2,r1,#NG_ACCEPTED_F
  ADDI r2,r2,1
  ST r2,r1,#NG_ACCEPTED_F
  ; per-CPU accept
  LD r1,r14,3
  CALL @ng_cpu_count
  ; accept event
  LD r1,r14,4
  MOVI r2,#NG_T_ACCEPT
  LD r3,r14,2
  LD r4,r14,3
  LD r5,r1,#NG_EPOCH_F
  CALL @ng_trace
  LD r1,r14,2
  ST r0,r0,#NG_ERRNO
  JMP @nge_out
nge_drain:
  MOVI r2,#NG_EDRAIN
  JMP @nge_reject
nge_stale:
  MOVI r2,#NG_ESTALE
  JMP @nge_reject
nge_future:
  MOVI r2,#NG_EFUTURE
  JMP @nge_reject
nge_bad:
  MOVI r2,#NG_EBAD
nge_reject:
  ; rec is at local 4, generation at 2, cpu at 3
  LD r1,r14,4
  LD r3,r1,#NG_REJECTED_F
  ADDI r3,r3,1
  ST r3,r1,#NG_REJECTED_F
  ST r2,r1,#NG_LERR_F
  ST r2,r0,#NG_ERRNO
  ; per-CPU reject (only when cpu is in range; checked at entry)
  ST r2,r14,7
  LD r1,r14,3
  MOVI r3,#NG_MAX_CPU
  CMP r1,r3
  JMP[GE] @nge_revt
  MOVI r3,#NG_CPU_W
  MUL r1,r1,r3
  LA r3,#NG_CPUSTATS
  ADD r1,r3,r1
  LD r3,r1,1
  ADDI r3,r3,1
  ST r3,r1,1
nge_revt:
  LD r1,r14,4
  MOVI r2,#NG_T_REJECT
  LD r3,r14,2
  LD r4,r14,7
  LD r5,r1,#NG_EPOCH_F
  CALL @ng_trace
  MOVI r1,0
  JMP @nge_out
nge_badarg:
  MOVI r1,0
  MOVI r2,#NG_EBAD
  CALL @ng_fail
  JMP @nge_out
nge_noent:
  MOVI r1,0
  MOVI r2,#NG_ENOENT
  CALL @ng_fail
nge_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ngen_exit r1=agent r2=gen -> 0 / 0 (errno).
ngen_exit:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  CALL @ng_live
  CMP r1,r0
  JMP[EQ] @ngx_noent
  ST r1,r14,3
  LD r2,r14,2
  CALL @ng_find
  CMP r1,r0
  JMP[EQ] @ngx_stale
  ST r1,r14,4
  LD r2,r1,#NG_S_STATE
  MOVI r3,#NG_S_DRAINED
  CMP r2,r3
  JMP[EQ] @ngx_stale
  MOVI r3,#NG_S_ABORTED_ST
  CMP r2,r3
  JMP[EQ] @ngx_stale
  MOVI r3,#NG_S_CURRENT
  CMP r2,r3
  JMP[EQ] @ngx_do
  MOVI r3,#NG_S_DRAINING
  CMP r2,r3
  JMP[NE] @ngx_bad
ngx_do:
  LD r1,r14,4
  LD r2,r1,#NG_S_INFLIGHT
  CMP r2,r0
  JMP[EQ] @ngx_bad
  SUB r2,r2,r13
  ST r2,r1,#NG_S_INFLIGHT
  LD r3,r1,#NG_S_COMPLETED
  ADDI r3,r3,1
  ST r3,r1,#NG_S_COMPLETED
  LD r1,r14,3
  LD r2,r1,#NG_COMPLETED_F
  ADDI r2,r2,1
  ST r2,r1,#NG_COMPLETED_F
  ; complete event
  LD r1,r14,4
  LD r5,r1,#NG_S_INFLIGHT
  ST r5,r14,5
  LD r1,r14,3
  MOVI r2,#NG_T_COMPLETE
  LD r3,r14,2
  LD r4,r14,5
  LD r5,r1,#NG_EPOCH_F
  CALL @ng_trace
  ; last draining request completes -> drained
  LD r1,r14,4
  LD r2,r1,#NG_S_STATE
  MOVI r3,#NG_S_DRAINING
  CMP r2,r3
  JMP[NE] @ngx_ok
  LD r2,r1,#NG_S_INFLIGHT
  CMP r2,r0
  JMP[NE] @ngx_ok
  MOVI r2,#NG_S_DRAINED
  ST r2,r1,#NG_S_STATE
  LD r1,r14,3
  LD r2,r1,#NG_DRAINED_F
  ADDI r2,r2,1
  ST r2,r1,#NG_DRAINED_F
  LD r3,r1,#NG_EPOCH_F
  LD r4,r14,2
  MOVI r2,#NG_T_DRAINED
  LD r5,r1,#NG_EPOCH_F
  CALL @ng_trace
ngx_ok:
  ST r0,r0,#NG_ERRNO
  MOVI r1,0
  JMP @ngx_out
ngx_noent:
  MOVI r1,0
  MOVI r2,#NG_ENOENT
  CALL @ng_fail
  JMP @ngx_out
ngx_stale:
  LD r1,r14,3
  MOVI r2,#NG_ESTALE
  CALL @ng_fail
  JMP @ngx_out
ngx_bad:
  LD r1,r14,3
  MOVI r2,#NG_EBAD
  CALL @ng_fail
ngx_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ngen_abort r1=agent r2=gen -> aborted count / 0.
ngen_abort:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  CALL @ng_live
  CMP r1,r0
  JMP[EQ] @nga_noent
  ST r1,r14,3
  LD r2,r14,2
  CALL @ng_find
  CMP r1,r0
  JMP[EQ] @nga_stale
  ST r1,r14,4
  LD r2,r1,#NG_S_STATE
  MOVI r3,#NG_S_DRAINING
  CMP r2,r3
  JMP[NE] @nga_busy
  LD r2,r1,#NG_S_INFLIGHT
  CMP r2,r0
  JMP[EQ] @nga_busy
  ST r2,r14,5
  ST r0,r1,#NG_S_INFLIGHT
  LD r3,r1,#NG_S_ABORTED
  ADD r3,r3,r2
  ST r3,r1,#NG_S_ABORTED
  MOVI r3,#NG_S_ABORTED_ST
  ST r3,r1,#NG_S_STATE
  LD r1,r14,3
  LD r3,r14,5
  LD r2,r1,#NG_ABORTED_F
  ADD r2,r2,r3
  ST r2,r1,#NG_ABORTED_F
  LD r2,r1,#NG_ABORTS_F
  ADDI r2,r2,1
  ST r2,r1,#NG_ABORTS_F
  LD r2,r1,#NG_DRAINED_F
  ADDI r2,r2,1
  ST r2,r1,#NG_DRAINED_F
  ; abort event
  LD r1,r14,3
  MOVI r2,#NG_T_ABORT
  LD r3,r14,2
  LD r4,r14,5
  LD r5,r1,#NG_EPOCH_F
  CALL @ng_trace
  ; drained event
  LD r1,r14,3
  MOVI r2,#NG_T_DRAINED
  LD r3,r14,2
  LD r4,r1,#NG_EPOCH_F
  LD r5,r1,#NG_EPOCH_F
  CALL @ng_trace
  LD r1,r14,5
  ST r0,r0,#NG_ERRNO
  JMP @nga_out
nga_noent:
  MOVI r1,0
  MOVI r2,#NG_ENOENT
  CALL @ng_fail
  JMP @nga_out
nga_stale:
  LD r1,r14,3
  MOVI r2,#NG_ESTALE
  CALL @ng_fail
  JMP @nga_out
nga_busy:
  LD r1,r14,3
  MOVI r2,#NG_EBUSY
  CALL @ng_fail
nga_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ngen_roots r1=agent r2=weight root r3=KV root -> 0 / errno.
ngen_roots:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @ng_live
  CMP r1,r0
  JMP[EQ] @ngr_noent
  ST r1,r14,4
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @ngr_kv
  LD r3,r1,#NG_WROOT_F
  CMP r3,r0
  JMP[EQ] @ngr_wset
  CMP r3,r2
  JMP[EQ] @ngr_kv
  LD r3,r1,#NG_WGEN_F
  ADDI r3,r3,1
  ST r3,r1,#NG_WGEN_F
ngr_wset:
  LD r3,r1,#NG_WGEN_F
  CMP r3,r0
  JMP[NE] @ngr_wset2
  MOVI r3,1
  ST r3,r1,#NG_WGEN_F
ngr_wset2:
  ST r2,r1,#NG_WROOT_F
ngr_kv:
  LD r1,r14,4
  LD r2,r14,3
  CMP r2,r0
  JMP[EQ] @ngr_ok
  LD r3,r1,#NG_KVROOT_F
  CMP r3,r0
  JMP[EQ] @ngr_kvset
  CMP r3,r2
  JMP[EQ] @ngr_ok
  LD r3,r1,#NG_KVGEN_F
  ADDI r3,r3,1
  ST r3,r1,#NG_KVGEN_F
ngr_kvset:
  LD r3,r1,#NG_KVGEN_F
  CMP r3,r0
  JMP[NE] @ngr_kvset2
  MOVI r3,1
  ST r3,r1,#NG_KVGEN_F
ngr_kvset2:
  ST r2,r1,#NG_KVROOT_F
ngr_ok:
  ST r0,r0,#NG_ERRNO
  MOVI r1,0
  JMP @ngr_out
ngr_noent:
  MOVI r1,0
  MOVI r2,#NG_ENOENT
  CALL @ng_fail
ngr_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ngen_fence r1=agent -> epoch / 0.  Valid only after publish+drain+start.
ngen_fence:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  CALL @ng_live
  CMP r1,r0
  JMP[EQ] @ngf_noent
  ST r1,r14,2
  LD r2,r1,#NG_FENCE_F
  MOVI r3,7
  CMP r2,r3
  JMP[NE] @ngf_none
  LD r2,r1,#NG_FENCES_F
  ADDI r2,r2,1
  ST r2,r1,#NG_FENCES_F
  LD r2,r1,#NG_EPOCH_F
  ST r2,r1,#NG_LASTFENCE_F
  MOVI r3,0
  ST r3,r0,#NG_ERRNO
  ADD r1,r2,r0
  JMP @ngf_out
ngf_none:
  LD r1,r14,2
  MOVI r2,#NG_EBUSY
  CALL @ng_fail
  JMP @ngf_out
ngf_noent:
  MOVI r1,0
  MOVI r2,#NG_ENOENT
  CALL @ng_fail
ngf_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ngen_status r1=agent r2=out(32) -> 0/-1.
ngen_status:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  CALL @ng_live
  CMP r1,r0
  JMP[EQ] @ngs_bad
  ST r1,r14,3
  LD r2,r14,2
  LA r3,#NG_MAGIC
  ST r3,r2,0
  MOVI r3,#NG_VERSION
  ST r3,r2,1
  LD r3,r1,#NG_AGENT_F
  ST r3,r2,2
  LD r3,r1,#NG_CUR_F
  ST r3,r2,3
  LD r3,r1,#NG_EPOCH_F
  ST r3,r2,4
  LD r3,r1,#NG_STATE_F
  ST r3,r2,5
  ; slot summary
  MOVI r3,0
  ST r3,r14,4           ; total inflight
  ST r3,r14,5           ; slots used
  ST r3,r14,6           ; draining
  ST r3,r14,7           ; drained
  ST r3,r14,8           ; aborted
  ST r3,r14,9           ; accepting
  MOVI r3,0
  ST r3,r14,10          ; slot index
ngs_loop:
  LD r3,r14,10
  MOVI r4,#NG_NSLOT
  CMP r3,r4
  JMP[GE] @ngs_summary
  MOVI r4,#NG_SLOT_W
  MUL r3,r3,r4
  ADDI r3,r3,#NG_SLOT_OFF
  LD r4,r14,3
  ADD r3,r4,r3
  LD r4,r3,#NG_S_GEN
  CMP r4,r0
  JMP[EQ] @ngs_next
  LD r5,r14,5
  ADDI r5,r5,1
  ST r5,r14,5
  LD r5,r3,#NG_S_INFLIGHT
  LD r6,r14,4
  ADD r6,r6,r5
  ST r6,r14,4
  LD r5,r3,#NG_S_STATE
  CMP r5,r13
  JMP[NE] @ngs_notcur
  MOVI r6,1
  ST r6,r14,9
  JMP @ngs_next
ngs_notcur:
  MOVI r6,#NG_S_DRAINING
  CMP r5,r6
  JMP[NE] @ngs_notdrain
  LD r6,r14,6
  ADDI r6,r6,1
  ST r6,r14,6
  JMP @ngs_next
ngs_notdrain:
  MOVI r6,#NG_S_DRAINED
  CMP r5,r6
  JMP[NE] @ngs_notdrained
  LD r6,r14,7
  ADDI r6,r6,1
  ST r6,r14,7
  JMP @ngs_next
ngs_notdrained:
  MOVI r6,#NG_S_ABORTED_ST
  CMP r5,r6
  JMP[NE] @ngs_next
  LD r6,r14,8
  ADDI r6,r6,1
  ST r6,r14,8
ngs_next:
  LD r3,r14,10
  ADDI r3,r3,1
  ST r3,r14,10
  JMP @ngs_loop
ngs_summary:
  LD r1,r14,3
  LD r2,r14,2
  LD r3,r14,4
  ST r3,r2,6
  LD r3,r14,5
  ST r3,r2,7
  LD r3,r14,9
  ST r3,r2,8
  LD r3,r14,6
  ST r3,r2,9
  LD r3,r14,7
  ST r3,r2,10
  LD r3,r14,8
  ST r3,r2,11
  LD r3,r1,#NG_ACCEPTED_F
  ST r3,r2,12
  LD r3,r1,#NG_COMPLETED_F
  ST r3,r2,13
  LD r3,r1,#NG_ABORTED_F
  ST r3,r2,14
  LD r3,r1,#NG_REJECTED_F
  ST r3,r2,15
  LD r3,r1,#NG_PUBLISH_F
  ST r3,r2,16
  LD r3,r1,#NG_DRAINS_F
  ST r3,r2,17
  LD r3,r1,#NG_STARTS_F
  ST r3,r2,18
  LD r3,r1,#NG_ABORTS_F
  ST r3,r2,19
  LD r3,r1,#NG_FENCES_F
  ST r3,r2,20
  LD r3,r1,#NG_LASTFENCE_F
  ST r3,r2,21
  LD r3,r1,#NG_FENCE_F
  ST r3,r2,22
  LD r3,r1,#NG_DRAINED_F
  ST r3,r2,23
  LD r3,r1,#NG_WROOT_F
  ST r3,r2,24
  LD r3,r1,#NG_WGEN_F
  ST r3,r2,25
  LD r3,r1,#NG_KVROOT_F
  ST r3,r2,26
  LD r3,r1,#NG_KVGEN_F
  ST r3,r2,27
  LD r3,r1,#NG_TRACE_F
  ST r3,r2,28
  LD r3,r1,#NG_TRACE_N
  ST r3,r2,29
  LD r3,r1,#NG_WRAPS_F
  ST r3,r2,30
  LD r3,r1,#NG_LERR_F
  ST r3,r2,31
  MOVI r1,0
  JMP @ngs_out
ngs_bad:
  LA r1,0xFFFFFFFF
ngs_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ngen_slot r1=agent r2=gen r3=out(8) -> 0/-1.
ngen_slot:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @ng_live
  CMP r1,r0
  JMP[EQ] @ngsl_bad
  LD r2,r14,2
  CALL @ng_find
  CMP r1,r0
  JMP[EQ] @ngsl_bad
  LD r2,r14,3
  LD r3,r1,#NG_S_GEN
  ST r3,r2,0
  LD r3,r1,#NG_S_STATE
  ST r3,r2,1
  LD r3,r1,#NG_S_INFLIGHT
  ST r3,r2,2
  LD r3,r1,#NG_S_ACCEPTED
  ST r3,r2,3
  LD r3,r1,#NG_S_COMPLETED
  ST r3,r2,4
  LD r3,r1,#NG_S_ABORTED
  ST r3,r2,5
  LD r3,r1,#NG_S_EPOCH
  ST r3,r2,6
  LD r3,r1,#NG_S_ENTERED
  ST r3,r2,7
  MOVI r1,0
  JMP @ngsl_out
ngsl_bad:
  LA r1,0xFFFFFFFF
ngsl_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ngen_trace r1=agent r2=index r3=out(6) -> 0/-1.
ngen_trace:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @ng_live
  CMP r1,r0
  JMP[EQ] @ngtr_bad
  ST r1,r14,4
  LD r2,r1,#NG_TRACE_N
  LD r3,r14,2
  CMP r3,r2
  JMP[GE] @ngtr_bad
  SUB r2,r2,r3
  MOVI r4,#NG_NTRACE
  CMP r2,r4
  JMP[GT] @ngtr_bad
  MOVI r2,7
  LD r3,r14,2
  BOOL.8 r2,r3,r2
  MOVI r4,#NG_TRACE_W
  MUL r2,r2,r4
  ADDI r2,r2,#NG_TRACE_OFF
  LD r1,r14,4
  ADD r1,r1,r2
  ST r1,r14,5
  LD r2,r14,3
  MOVI r3,6
ngtr_copy:
  CMP r3,r0
  JMP[EQ] @ngtr_ok
  LD r4,r1,0
  ST r4,r2,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  SUB r3,r3,r13
  JMP @ngtr_copy
ngtr_ok:
  MOVI r1,0
  JMP @ngtr_out
ngtr_bad:
  LA r1,0xFFFFFFFF
ngtr_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; ngen_trace_head r1=agent -> head / 0.
ngen_trace_head:
  ST r15,r14,0
  ADDI r14,r14,16
  CALL @ng_live
  CMP r1,r0
  JMP[EQ] @ngth_out
  LD r1,r1,#NG_TRACE_F
ngth_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ngen_cpu r1=cpu r2=out(4) -> 0/-1.
ngen_cpu:
  MOVI r3,#NG_MAX_CPU
  CMP r1,r3
  JMP[GE] @ngcp_bad
  MOVI r3,#NG_CPU_W
  MUL r1,r1,r3
  LA r3,#NG_CPUSTATS
  ADD r1,r3,r1
  LD r3,r1,0
  ST r3,r2,0
  LD r3,r1,1
  ST r3,r2,1
  LD r3,r1,2
  ST r3,r2,2
  LD r3,r1,3
  ST r3,r2,3
  MOVI r1,0
  RET
ngcp_bad:
  LA r1,0xFFFFFFFF
  RET

; ngen_inflight r1=agent r2=gen -> count / 0xFFFFFFFF.
ngen_inflight:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r2,r14,1
  CALL @ng_live
  CMP r1,r0
  JMP[EQ] @ngif_bad
  LD r2,r14,1
  CALL @ng_find
  CMP r1,r0
  JMP[EQ] @ngif_bad
  LD r1,r1,#NG_S_INFLIGHT
  JMP @ngif_out
ngif_bad:
  LA r1,0xFFFFFFFF
ngif_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ngen_epoch r1=agent -> epoch / 0xFFFFFFFF.
ngen_epoch:
  ST r15,r14,0
  ADDI r14,r14,16
  CALL @ng_live
  CMP r1,r0
  JMP[EQ] @ngep_bad
  LD r1,r1,#NG_EPOCH_F
  JMP @ngep_out
ngep_bad:
  LA r1,0xFFFFFFFF
ngep_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ngen_errno -> last error.
ngen_errno:
  LD r1,r0,#NG_ERRNO
  RET
