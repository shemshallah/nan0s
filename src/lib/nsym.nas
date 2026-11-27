; nsym.nas - symbiotic multi-agent scheduling (F13f).
;
; Pure NaN.  Three cooperating pieces:
;
;   1. Shared immutable weight roots.  A root record holds a sealed payload,
;      a content hash and a reference count.  Agents join a root by acquiring a
;      reference; they never copy the payload.  The root is freed exactly when
;      the last reference is released.  There is no write API: the payload
;      and hash of a live root cannot change except by freeing it.
;
;   2. Per-agent generation slots.  Each agent owns one ngen record (agent ids
;      1..8 map to ngen agent ids 1..8).  Admission enters the agent's current
;      generation, completion/deadline/budget exit it, publish drains the old
;      generation and starts the next, and drain/start are exposed directly.
;      A generation transition on one agent cannot touch another agent's ngen
;      record or root reference.
;
;   3. A deterministic two-CPU weighted fair queue.  Each agent has a weight,
;      a virtual runtime in Q16 (vrt += 65536/weight per served tick), a
;      per-job reservation (reserve ticks delivered before the job's absolute
;      deadline), a total CPU budget and an absolute deadline.  Each dispatch
;      tick chooses up to two agents, one per CPU:
;        * first pass: reserved work (reserve_left > 0 and a deadline) is
;          ordered by earliest deadline, then vrt, then agent id;
;        * second pass: ordinary fair share is ordered by smallest vrt, then
;          agent id.
;      An agent is served at most once per tick, so on two CPUs a single
;      agent can hold at most 1/2 of the service even if its weight share is
;      larger.  Fairness is therefore stated for weight shares <= 1/2.
;
;   4. Accounting.  Served ticks, admissions, completions, budget denials,
;      deadline misses, reserve met/miss, maximum service gap, idle slots and
;      a deterministic trace/hash chain are exact.  Budget exhaustion parks the
;      pending job (it does not run again); a missed deadline parks it and
;      charges one deadline miss.  Parked jobs exit their ngen generation so a
;      later publish can drain cleanly.
;
; Layout
; ------
; Roots: 16 records, stride 32, at 0x354000 (512 words):
;   +0 magic "NSWR"      +1 state (1 live, 0 free)
;   +2 refs              +3 root id
;   +4 content hash      +5 immutable version (1)
;   +6 payload words     +7 created tick
;   +8 total acquires    +9 total releases
;   +10 peak refs       +11 verify calls
;   +12..15 reserved    +16..31 payload (16 words, immutable)
;
; Agents: 8 records, stride 128, at 0x355000 (1024 words):
;   +0 magic "NSYM"      +1 state (1 joined, 2 unjoined, 0 free)
;   +2 agent id          +3 weight
;   +4 reserve default   +5 reserve_left (current job copy)
;   +6 budget max        +7 budget left
;   +8 deadline          +9 vrt (Q16)
;   +10 remaining        +11 backlog (pending jobs)
;   +12 served           +13 admitted
;   +14 completed        +15 deadline misses
;   +16 budget denials   +17 reserve met
;   +18 reserve misses   +19 last service tick (0xFFFFFFFF = none)
;   +20 max service gap  +21 generation
;   +22 generation epoch +23 root index (0xFFFFFFFF = none)
;   +24 root id          +25 root hash
;   +26 root joins       +27 root leaves
;   +28 parked jobs      +29 last error
;   +30 dispatch events  +31 root acquire generation (immutable join epoch)
;   +32..63 four 8-word jobs
;   +64 ready since tick +65..127 reserved
;
; Job (8 words):
;   +0 job id +1 work +2 remaining +3 deadline +4 reserve +5 reserve_left
;   +6 state (0 free, 1 queued, 2 running, 3 done, 4 deadline miss,
;             5 budget parked)
;   +7 ngen generation tag
;
; Global (32 words at 0x356000):
;   +0 magic "NSYM" +1 version +2 tick +3 service +4 admits +5 completions
;   +6 deadline misses +7 budget denials +8 reserve misses
;   +9 roots created +10 root acquires +11 root releases +12 roots freed
;   +13 agent joins +14 agent leaves +15 publishes +16 drains +17 starts
;   +18 trace head +19 trace events +20 trace wraps +21 errno
;   +22 agents created +23 rounds +24 dispatches +25 idle slots
;   +26 max service gap +27 admitted work +28 reserve met
;   +29 stale admissions +30 parked jobs +31 rejected admissions
;
; Trace: 512 entries, 8 words each, at 0x356100:
;   tick, cpu, kind, agent, a, b, hash, seq.
;   cpu 0xFFFFFFFF means the event is not CPU-local.
;   Kinds: 1 root create, 2 agent join, 3 agent leave, 4 root free,
;   5 agent create, 6 admit, 7 dispatch, 8 complete, 9 deadline miss,
;   10 budget deny, 11 publish, 12 drain, 13 start, 14 reserve met,
;   15 stale admission.  The hash is the same xor/multiply chain shape as
;   nagent/ngen/nreplay with an NSYM seed.
;
; Return codes:
;   0 OK, 1 EBAD, 2 ENOENT, 3 EBUSY, 4 ENOROOT, 5 ENOAGENT,
;   6 ENOSPC, 7 EBUDGET, 8 EDEADLINE, 9 EJOINED, 10 ESTALE.
; Lookup/acquire/release return 0xFFFFFFFF on error; status queries return
; 0/-1; generation publish/drain/start return the ngen epoch or 0.
;
; ABI: r0=0, r13=1, r14=SP (grows up), r15=link.  r1..r12 are scratch.
;
; API:
;   nsym_init
;   nsym_root_create   r1=root r2=id r3=payload r4=words -> 0/errno
;   nsym_root_acquire  r1=root -> refs / 0xFFFFFFFF
;   nsym_root_release  r1=root -> refs / 0xFFFFFFFF (0 = freed)
;   nsym_root_verify   r1=root -> 0 / -1
;   nsym_root_status   r1=root r2=out(32) -> 0/-1
;   nsym_agent_create  r1=agent r2=weight r3=budget -> 0/errno
;   nsym_join          r1=agent r2=root -> 0/errno
;   nsym_leave         r1=agent -> 0/errno
;   nsym_publish       r1=agent r2=new gen r3=new root (0xFFFFFFFF=same)
;                      -> epoch / 0
;   nsym_start         r1=agent r2=gen -> epoch / 0
;   nsym_drain         r1=agent -> epoch / 0
;   nsym_admit         r1=agent r2=job id r3=work r4=deadline r5=reserve
;                      r6=cpu -> 0/errno
;   nsym_dispatch      -> 0 (one 2-CPU tick)
;   nsym_run           r1=ticks -> 0
;   nsym_agent_status  r1=agent r2=out(128) -> 0/-1
;   nsym_global        r1=out(32) -> 0
;   nsym_trace         r1=index r2=out(8) -> 0/-1
;   nsym_trace_head    -> head / 0
;   nsym_tick          -> tick
;   nsym_errno         -> last error

.include "ngen.nas"

.equ NS_ROOT_TAB    0x354000
.equ NS_MAX_ROOT    16
.equ NS_ROOT_STRIDE 32
.equ NS_ROOT_TOTAL  512
.equ NS_AGENT_TAB   0x355000
.equ NS_MAX_AGENT   8
.equ NS_AGENT_STRIDE 128
.equ NS_AGENT_TOTAL 1024
.equ NS_GLOBAL      0x356000
.equ NS_TRACE_TAB   0x356100
.equ NS_TRACE_N     512
.equ NS_TRACE_W     8
.equ NS_TRACE_TOTAL 4096

.equ NS_ROOT_MAGIC  0x5257534E       ; "NSWR" in memory order
.equ NS_AGENT_MAGIC 0x4D59534E       ; "NSYM" in memory order
.equ NS_VERSION     1
.equ NS_ROOT_SEED   0x5257534E
.equ NS_TRACE_SEED  0x4D595354       ; "NSTM"
.equ NS_MIX_C1      0x9E3779B9
.equ NS_MIX_C2      0x85EBCA6B
.equ NS_MIX_C3      0xC2B2AE35
.equ NS_Q16         65536
.equ NS_NONE        0xFFFFFFFF

; Root fields.
.equ NS_R_MAGIC   0
.equ NS_R_STATE   1
.equ NS_R_REFS    2
.equ NS_R_ID      3
.equ NS_R_HASH    4
.equ NS_R_VERSION 5
.equ NS_R_WORDS   6
.equ NS_R_CREATED 7
.equ NS_R_JOINS   8
.equ NS_R_LEAVES  9
.equ NS_R_PEAK    10
.equ NS_R_VERIFY  11
.equ NS_R_PAYLOAD 16

; Agent fields.
.equ NS_A_MAGIC    0
.equ NS_A_STATE    1
.equ NS_A_ID       2
.equ NS_A_WEIGHT   3
.equ NS_A_RESERVE  4
.equ NS_A_RESLEFT  5
.equ NS_A_BMAX     6
.equ NS_A_BLEFT    7
.equ NS_A_DEADLINE 8
.equ NS_A_VRT      9
.equ NS_A_REMAIN   10
.equ NS_A_BACKLOG  11
.equ NS_A_SERVED   12
.equ NS_A_ADMITTED 13
.equ NS_A_COMPLETE 14
.equ NS_A_DM       15
.equ NS_A_BDENY    16
.equ NS_A_RMET     17
.equ NS_A_RMISS    18
.equ NS_A_LAST     19
.equ NS_A_MAXGAP   20
.equ NS_A_GEN      21
.equ NS_A_EPOCH    22
.equ NS_A_ROOT     23
.equ NS_A_ROOTID   24
.equ NS_A_ROOTHASH 25
.equ NS_A_RJOINS   26
.equ NS_A_RLEAVES  27
.equ NS_A_PARKED   28
.equ NS_A_LERR     29
.equ NS_A_DISP     30
.equ NS_A_JOINEP   31
.equ NS_A_JOBS     32
.equ NS_A_JOBW     8
.equ NS_A_NJOBS    4
.equ NS_A_READY    64

; Job fields.
.equ NS_J_ID      0
.equ NS_J_WORK    1
.equ NS_J_REM     2
.equ NS_J_DEAD    3
.equ NS_J_RES     4
.equ NS_J_RESLEFT 5
.equ NS_J_STATE   6
.equ NS_J_GEN     7

; Job states.
.equ NS_J_FREE    0
.equ NS_J_QUEUED  1
.equ NS_J_RUN     2
.equ NS_J_DONE    3
.equ NS_J_MISS    4
.equ NS_J_BUDGET  5

; Agent states.
.equ NS_ST_FREE    0
.equ NS_ST_JOINED  1
.equ NS_ST_UNJOIN  2

; Global fields.
.equ NS_G_MAGIC    0
.equ NS_G_VERSION  1
.equ NS_G_TICK     2
.equ NS_G_SERVICE  3
.equ NS_G_ADMITS   4
.equ NS_G_COMPLETE 5
.equ NS_G_DM       6
.equ NS_G_BUDGET   7
.equ NS_G_RMISS    8
.equ NS_G_RCREATE  9
.equ NS_G_RACQ     10
.equ NS_G_RREL     11
.equ NS_G_RFREE    12
.equ NS_G_JOIN     13
.equ NS_G_LEAVE    14
.equ NS_G_PUB      15
.equ NS_G_DRAIN    16
.equ NS_G_START    17
.equ NS_G_TRHEAD   18
.equ NS_G_TRN      19
.equ NS_G_TRW      20
.equ NS_G_ERRNO    21
.equ NS_G_AGENTS   22
.equ NS_G_ROUNDS   23
.equ NS_G_DISP     24
.equ NS_G_IDLE     25
.equ NS_G_MAXGAP   26
.equ NS_G_WORK     27
.equ NS_G_RMET     28
.equ NS_G_STALE    29
.equ NS_G_PARKED   30
.equ NS_G_REJECT   31

; Trace kinds.
.equ NS_T_RCREATE 1
.equ NS_T_JOIN    2
.equ NS_T_LEAVE   3
.equ NS_T_RFREE   4
.equ NS_T_ACREATE 5
.equ NS_T_ADMIT   6
.equ NS_T_DISP    7
.equ NS_T_COMPLETE 8
.equ NS_T_DM      9
.equ NS_T_BUDGET  10
.equ NS_T_PUBLISH 11
.equ NS_T_DRAIN   12
.equ NS_T_START   13
.equ NS_T_RMET    14
.equ NS_T_STALE   15

; Errors.
.equ NS_OK       0
.equ NS_EBAD     1
.equ NS_ENOENT   2
.equ NS_EBUSY    3
.equ NS_ENOROOT  4
.equ NS_ENOAGENT 5
.equ NS_ENOSPC   6
.equ NS_EBUDGET  7
.equ NS_EDEADLINE 8
.equ NS_EJOINED  9
.equ NS_ESTALE   10

; ---------------------------------------------------------------------------
; ns_mix r1=hash r2=word -> r1.  Deterministic 32-bit chain.
ns_mix:
  BOOL.6 r1,r1,r2
  LA r3,#NS_MIX_C1
  ADD r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  LA r3,#NS_MIX_C2
  MUL r1,r1,r3
  SHR r4,r1,15
  BOOL.6 r1,r1,r4
  LA r3,#NS_MIX_C3
  MUL r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  RET

; ns_fail r1=code -> 0.  Sets the global errno.
ns_fail:
  LA r2,#NS_GLOBAL
  ST r1,r2,#NS_G_ERRNO
  MOVI r1,0
  RET

; ns_ngmap r1=ngen errno -> r1=nsym errno.
ns_ngmap:
  CMP r1,r0
  JMP[EQ] @nsm_ok
  CMP r1,r13
  JMP[EQ] @nsm_stale
  MOVI r2,4
  CMP r1,r2
  JMP[EQ] @nsm_stale
  MOVI r2,5
  CMP r1,r2
  JMP[EQ] @nsm_stale
  MOVI r2,7
  CMP r1,r2
  JMP[EQ] @nsm_stale
  MOVI r2,6
  CMP r1,r2
  JMP[EQ] @nsm_busy
  MOVI r2,2
  CMP r1,r2
  JMP[EQ] @nsm_bad
  MOVI r2,3
  CMP r1,r2
  JMP[EQ] @nsm_noent
  MOVI r2,8
  CMP r1,r2
  JMP[EQ] @nsm_nospc
  JMP @nsm_bad
nsm_ok:
  MOVI r1,#NS_OK
  RET
nsm_stale:
  MOVI r1,#NS_ESTALE
  RET
nsm_busy:
  MOVI r1,#NS_EBUSY
  RET
nsm_bad:
  MOVI r1,#NS_EBAD
  RET
nsm_noent:
  MOVI r1,#NS_ENOENT
  RET
nsm_nospc:
  MOVI r1,#NS_ENOSPC
  RET

; ns_root_ptr r1=root index -> r1=record / 0.
ns_root_ptr:
  CMP r1,r0
  JMP[LT] @nrp_none
  MOVI r2,15
  CMP r1,r2
  JMP[GT] @nrp_none
  SHL r2,r1,5
  LA r3,#NS_ROOT_TAB
  ADD r1,r3,r2
  RET
nrp_none:
  MOVI r1,0
  RET

; ns_root_live r1=root index -> r1=record / 0.
ns_root_live:
  ST r15,r14,0
  ADDI r14,r14,16
  CALL @ns_root_ptr
  CMP r1,r0
  JMP[EQ] @nrl_out
  ST r1,r14,1
  LD r2,r1,#NS_R_MAGIC
  LA r3,#NS_ROOT_MAGIC
  CMP r2,r3
  JMP[NE] @nrl_no
  LD r2,r1,#NS_R_STATE
  CMP r2,r13
  JMP[NE] @nrl_no
  LD r1,r14,1
  JMP @nrl_out
nrl_no:
  MOVI r1,0
nrl_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ns_agent_ptr r1=agent id -> r1=record / 0.
ns_agent_ptr:
  CMP r1,r0
  JMP[LE] @nap_none
  MOVI r2,#NS_MAX_AGENT
  CMP r1,r2
  JMP[GT] @nap_none
  SUB r1,r1,r13
  SHL r2,r1,7
  LA r3,#NS_AGENT_TAB
  ADD r1,r3,r2
  RET
nap_none:
  MOVI r1,0
  RET

; ns_agent_rec r1=agent id -> r1=record / 0 (created, either state).
ns_agent_rec:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  CALL @ns_agent_ptr
  CMP r1,r0
  JMP[EQ] @nar_out
  ST r1,r14,2
  LD r2,r1,#NS_A_MAGIC
  LA r3,#NS_AGENT_MAGIC
  CMP r2,r3
  JMP[NE] @nar_no
  LD r2,r1,#NS_A_ID
  LD r3,r14,1
  CMP r2,r3
  JMP[NE] @nar_no
  LD r2,r1,#NS_A_STATE
  CMP r2,r0
  JMP[EQ] @nar_no
  LD r1,r14,2
  JMP @nar_out
nar_no:
  MOVI r1,0
nar_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ns_agent_joined r1=agent id -> r1=record / 0.
ns_agent_joined:
  ST r15,r14,0
  ADDI r14,r14,16
  CALL @ns_agent_rec
  CMP r1,r0
  JMP[EQ] @naj_out
  ST r1,r14,1
  LD r2,r1,#NS_A_STATE
  CMP r2,r13
  JMP[NE] @naj_no
  LD r2,r1,#NS_A_ROOT
  LA r3,#NS_NONE
  CMP r2,r3
  JMP[EQ] @naj_no
  LD r1,r14,1
  JMP @naj_out
naj_no:
  MOVI r1,0
naj_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ns_job r1=agent record r2=job index -> r1=job address.
ns_job:
  SHL r2,r2,3
  ADD r1,r1,r2
  ADDI r1,r1,#NS_A_JOBS
  RET

; ns_pending_job r1=agent record -> r1=job address / 0.
; Picks the pending job with the smallest job id (FIFO for monotonic ids).
ns_pending_job:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r0,r14,2           ; i
  ST r0,r14,3           ; best job
  ST r0,r14,4           ; best id
npj_loop:
  LD r2,r14,2
  MOVI r3,#NS_A_NJOBS
  CMP r2,r3
  JMP[GE] @npj_done
  LD r1,r14,1
  CALL @ns_job
  ST r1,r14,5
  LD r2,r1,#NS_J_STATE
  CMP r2,r13
  JMP[EQ] @npj_take
  MOVI r3,#NS_J_RUN
  CMP r2,r3
  JMP[NE] @npj_next
npj_take:
  LD r2,r14,5
  LD r2,r2,#NS_J_ID
  ST r2,r14,6
  LD r3,r14,3
  CMP r3,r0
  JMP[EQ] @npj_set
  LD r3,r14,4
  CMP r2,r3
  JMP[GE] @npj_next
npj_set:
  LD r3,r14,5
  ST r3,r14,3
  ST r2,r14,4
npj_next:
  LD r2,r14,2
  ADDI r2,r2,1
  ST r2,r14,2
  JMP @npj_loop
npj_done:
  LD r1,r14,3
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ns_refresh r1=agent record -> 0.  Mirrors the earliest pending job's
; deadline/reserve into the agent status fields; clears them when idle.
ns_refresh:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  CALL @ns_pending_job
  CMP r1,r0
  JMP[NE] @nsrf_job
  LD r1,r14,1
  ST r0,r1,#NS_A_DEADLINE
  ST r0,r1,#NS_A_RESERVE
  ST r0,r1,#NS_A_RESLEFT
  JMP @nsrf_out
nsrf_job:
  ST r1,r14,2
  LD r1,r14,1
  LD r2,r14,2
  LD r2,r2,#NS_J_DEAD
  ST r2,r1,#NS_A_DEADLINE
  LD r2,r14,2
  LD r2,r2,#NS_J_RES
  ST r2,r1,#NS_A_RESERVE
  LD r2,r14,2
  LD r2,r2,#NS_J_RESLEFT
  ST r2,r1,#NS_A_RESLEFT
nsrf_out:
  MOVI r1,0
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ns_root_hash r1=root record -> r1=hash.
ns_root_hash:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  LA r1,#NS_ROOT_SEED
  LD r2,r14,1
  LD r2,r2,#NS_R_ID
  CALL @ns_mix
  LD r2,r14,1
  LD r2,r2,#NS_R_VERSION
  CALL @ns_mix
  LD r2,r14,1
  LD r2,r2,#NS_R_WORDS
  CALL @ns_mix
  ST r0,r14,2
nrh_loop:
  LD r2,r14,2
  LD r3,r14,1
  LD r3,r3,#NS_R_WORDS
  CMP r2,r3
  JMP[GE] @nrh_done
  LD r3,r14,1
  ADD r3,r3,r2
  ADDI r3,r3,#NS_R_PAYLOAD
  LD r2,r3,0
  CALL @ns_mix
  LD r2,r14,2
  ADDI r2,r2,1
  ST r2,r14,2
  JMP @nrh_loop
nrh_done:
  ST r1,r14,3
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ns_trace r1=kind r2=agent r3=cpu r4=a r5=b -> head.
ns_trace:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  LA r2,#NS_GLOBAL
  LD r1,r2,#NS_G_TRHEAD
  CALL @ns_mix
  LD r2,r14,1
  CALL @ns_mix
  LD r2,r14,2
  CALL @ns_mix
  LD r2,r14,4
  CALL @ns_mix
  LD r2,r14,5
  CALL @ns_mix
  LA r3,#NS_GLOBAL
  LD r2,r3,#NS_G_TICK
  CALL @ns_mix
  CMP r1,r0
  JMP[NE] @nst_head
  LA r1,#NS_TRACE_SEED
nst_head:
  ST r1,r14,6
  LA r6,#NS_GLOBAL
  LD r7,r6,#NS_G_TRN
  ST r7,r14,7
  MOVI r8,511
  BOOL.8 r8,r7,r8
  SHL r8,r8,3
  LA r9,#NS_TRACE_TAB
  ADD r8,r9,r8
  LD r9,r6,#NS_G_TICK
  ST r9,r8,0
  LD r9,r14,3
  ST r9,r8,1
  LD r9,r14,1
  ST r9,r8,2
  LD r9,r14,2
  ST r9,r8,3
  LD r9,r14,4
  ST r9,r8,4
  LD r9,r14,5
  ST r9,r8,5
  LD r9,r14,6
  ST r9,r8,6
  LD r9,r14,7
  ST r9,r8,7
  LD r9,r14,6
  ST r9,r6,#NS_G_TRHEAD
  LD r7,r14,7
  ADDI r7,r7,1
  ST r7,r6,#NS_G_TRN
  MOVI r9,#NS_TRACE_N
  CMP r7,r9
  JMP[LT] @nst_nowrap
  LD r9,r6,#NS_G_TRW
  ADDI r9,r9,1
  ST r9,r6,#NS_G_TRW
nst_nowrap:
  LD r1,r14,6
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsym_init - clear roots, agents, global state, trace and ngen.
nsym_init:
  ST r15,r14,0
  ADDI r14,r14,16
  LA r1,#NS_ROOT_TAB
  MOVI r2,#NS_ROOT_TOTAL
  BFILL r1,r0,r2
  LA r1,#NS_AGENT_TAB
  MOVI r2,#NS_AGENT_TOTAL
  BFILL r1,r0,r2
  LA r1,#NS_TRACE_TAB
  MOVI r2,#NS_TRACE_TOTAL
  BFILL r1,r0,r2
  LA r1,#NS_GLOBAL
  MOVI r2,32
  BFILL r1,r0,r2
  LA r2,#NS_GLOBAL
  LA r3,#NS_AGENT_MAGIC
  ST r3,r2,#NS_G_MAGIC
  MOVI r3,#NS_VERSION
  ST r3,r2,#NS_G_VERSION
  CALL @ngen_init
  MOVI r1,0
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsym_root_create r1=root r2=id r3=payload r4=words -> 0/errno.
nsym_root_create:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  CMP r2,r0
  JMP[EQ] @nrc_bad
  CMP r3,r0
  JMP[EQ] @nrc_bad
  CMP r4,r0
  JMP[LE] @nrc_bad
  MOVI r2,16
  CMP r4,r2
  JMP[GT] @nrc_bad
  LD r1,r14,1
  CALL @ns_root_ptr
  CMP r1,r0
  JMP[EQ] @nrc_bad
  ST r1,r14,5
  LD r2,r1,#NS_R_STATE
  CMP r2,r0
  JMP[NE] @nrc_busy
  MOVI r2,32
  BFILL r1,r0,r2
  LD r1,r14,5
  LA r2,#NS_ROOT_MAGIC
  ST r2,r1,#NS_R_MAGIC
  MOVI r2,#NS_VERSION
  ST r2,r1,#NS_R_VERSION
  ST r13,r1,#NS_R_STATE
  LD r2,r14,2
  ST r2,r1,#NS_R_ID
  LD r2,r14,4
  ST r2,r1,#NS_R_WORDS
  LA r2,#NS_GLOBAL
  LD r2,r2,#NS_G_TICK
  ST r2,r1,#NS_R_CREATED
  ; payload is copied once, at create; joins only bump refs
  LD r3,r14,3
  ADDI r4,r1,#NS_R_PAYLOAD
  LD r5,r14,4
  BCOPY r4,r3,r5
  LD r1,r14,5
  CALL @ns_root_hash
  LD r2,r14,5
  ST r1,r2,#NS_R_HASH
  LA r3,#NS_GLOBAL
  LD r4,r3,#NS_G_RCREATE
  ADDI r4,r4,1
  ST r4,r3,#NS_G_RCREATE
  MOVI r1,#NS_T_RCREATE
  MOVI r2,0
  LA r3,#NS_NONE
  LD r4,r14,1
  LD r5,r14,2
  CALL @ns_trace
  MOVI r1,0
  JMP @nrc_out
nrc_busy:
  MOVI r1,#NS_EBUSY
  CALL @ns_fail
  JMP @nrc_out
nrc_bad:
  MOVI r1,#NS_EBAD
  CALL @ns_fail
nrc_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; nsym_root_acquire r1=root -> refs / 0xFFFFFFFF.
nsym_root_acquire:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  CALL @ns_root_live
  CMP r1,r0
  JMP[EQ] @nra_bad
  ST r1,r14,2
  LD r2,r1,#NS_R_REFS
  ADDI r2,r2,1
  ST r2,r1,#NS_R_REFS
  LD r3,r1,#NS_R_JOINS
  ADDI r3,r3,1
  ST r3,r1,#NS_R_JOINS
  LD r3,r1,#NS_R_PEAK
  CMP r2,r3
  JMP[LE] @nra_nopeak
  ST r2,r1,#NS_R_PEAK
nra_nopeak:
  LA r3,#NS_GLOBAL
  LD r4,r3,#NS_G_RACQ
  ADDI r4,r4,1
  ST r4,r3,#NS_G_RACQ
  LD r1,r14,2
  LD r1,r1,#NS_R_REFS
  JMP @nra_out
nra_bad:
  MOVI r1,#NS_ENOENT
  CALL @ns_fail
  LA r1,#NS_NONE
nra_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nsym_root_release r1=root -> refs / 0xFFFFFFFF (0 means freed).
nsym_root_release:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  CALL @ns_root_live
  CMP r1,r0
  JMP[EQ] @nrr_bad
  ST r1,r14,2
  LD r2,r1,#NS_R_REFS
  CMP r2,r0
  JMP[EQ] @nrr_bad
  SUB r2,r2,r13
  ST r2,r1,#NS_R_REFS
  LD r3,r1,#NS_R_LEAVES
  ADDI r3,r3,1
  ST r3,r1,#NS_R_LEAVES
  LA r3,#NS_GLOBAL
  LD r4,r3,#NS_G_RREL
  ADDI r4,r4,1
  ST r4,r3,#NS_G_RREL
  CMP r2,r0
  JMP[NE] @nrr_live
  ; last reference: trace and free the whole record
  LD r2,r14,2
  LD r2,r2,#NS_R_ID
  ST r2,r14,3
  LA r3,#NS_GLOBAL
  LD r4,r3,#NS_G_RFREE
  ADDI r4,r4,1
  ST r4,r3,#NS_G_RFREE
  MOVI r1,#NS_T_RFREE
  MOVI r2,0
  LA r3,#NS_NONE
  LD r4,r14,1
  LD r5,r14,3
  CALL @ns_trace
  LD r1,r14,2
  MOVI r2,32
  BFILL r1,r0,r2
  MOVI r1,0
  JMP @nrr_out
nrr_live:
  LD r1,r14,2
  LD r1,r1,#NS_R_REFS
  JMP @nrr_out
nrr_bad:
  MOVI r1,#NS_ENOENT
  CALL @ns_fail
  LA r1,#NS_NONE
nrr_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; nsym_root_verify r1=root -> 0 / -1.
nsym_root_verify:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  CALL @ns_root_live
  CMP r1,r0
  JMP[EQ] @nrv_bad
  ST r1,r14,2
  LD r2,r1,#NS_R_VERIFY
  ADDI r2,r2,1
  ST r2,r1,#NS_R_VERIFY
  CALL @ns_root_hash
  LD r2,r14,2
  LD r2,r2,#NS_R_HASH
  CMP r1,r2
  JMP[NE] @nrv_bad
  MOVI r1,0
  JMP @nrv_out
nrv_bad:
  MOVI r1,#NS_ENOENT
  CALL @ns_fail
  LA r1,#NS_NONE
nrv_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nsym_root_status r1=root r2=out(32) -> 0/-1.
nsym_root_status:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r2,r14,1
  CALL @ns_root_ptr
  CMP r1,r0
  JMP[EQ] @nrs_bad
  LD r2,r14,1
  MOVI r3,32
  BCOPY r2,r1,r3
  MOVI r1,0
  JMP @nrs_out
nrs_bad:
  LA r1,#NS_NONE
nrs_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsym_agent_create r1=agent r2=weight r3=budget -> 0/errno.
nsym_agent_create:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @ns_agent_ptr
  CMP r1,r0
  JMP[EQ] @nac_bad
  ST r1,r14,4
  LD r2,r1,#NS_A_MAGIC
  CMP r2,r0
  JMP[NE] @nac_busy
  LD r2,r14,2
  CMPS r2,r0
  JMP[LE] @nac_bad
  MOVI r3,255
  CMP r2,r3
  JMP[GT] @nac_bad
  LD r3,r14,3
  CMPS r3,r0
  JMP[LT] @nac_bad
  LD r1,r14,4
  MOVI r2,#NS_AGENT_STRIDE
  BFILL r1,r0,r2
  LD r1,r14,4
  LA r2,#NS_AGENT_MAGIC
  ST r2,r1,#NS_A_MAGIC
  MOVI r2,#NS_ST_UNJOIN
  ST r2,r1,#NS_A_STATE
  LD r2,r14,1
  ST r2,r1,#NS_A_ID
  LD r2,r14,2
  ST r2,r1,#NS_A_WEIGHT
  LD r3,r14,3
  ST r3,r1,#NS_A_BMAX
  ST r3,r1,#NS_A_BLEFT
  LA r2,#NS_NONE
  ST r2,r1,#NS_A_ROOT
  ST r2,r1,#NS_A_LAST
  LA r2,#NS_GLOBAL
  LD r3,r2,#NS_G_AGENTS
  ADDI r3,r3,1
  ST r3,r2,#NS_G_AGENTS
  MOVI r1,#NS_T_ACREATE
  MOVI r2,0
  LA r3,#NS_NONE
  LD r4,r14,1
  LD r5,r14,2
  CALL @ns_trace
  MOVI r1,0
  JMP @nac_out
nac_busy:
  MOVI r1,#NS_EBUSY
  CALL @ns_fail
  JMP @nac_out
nac_bad:
  MOVI r1,#NS_EBAD
  CALL @ns_fail
nac_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; nsym_join r1=agent r2=root -> 0/errno.
nsym_join:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  CALL @ns_agent_rec
  CMP r1,r0
  JMP[EQ] @nsj_noent
  ST r1,r14,3
  LD r2,r1,#NS_A_STATE
  MOVI r3,#NS_ST_UNJOIN
  CMP r2,r3
  JMP[NE] @nsj_busy
  LD r2,r1,#NS_A_JOINEP
  CMP r2,r0
  JMP[NE] @nsj_joined
  LD r2,r1,#NS_A_ROOT
  LA r3,#NS_NONE
  CMP r2,r3
  JMP[NE] @nsj_busy
  LD r1,r14,2
  CALL @ns_root_live
  CMP r1,r0
  JMP[EQ] @nsj_noroot
  ST r1,r14,4
  LD r1,r14,2
  CALL @nsym_root_acquire
  LA r3,#NS_NONE
  CMP r1,r3
  JMP[EQ] @nsj_noroot
  ST r1,r14,5
  ; cache root metadata (id/hash), never the payload
  LD r2,r14,4
  LD r3,r2,#NS_R_ID
  LD r1,r14,3
  ST r3,r1,#NS_A_ROOTID
  LD r3,r2,#NS_R_HASH
  ST r3,r1,#NS_A_ROOTHASH
  LD r3,r14,2
  ST r3,r1,#NS_A_ROOT
  LD r3,r14,5
  ST r3,r1,#NS_A_JOINEP
  ; create and start generation 1
  LD r1,r14,1
  LD r2,r14,4
  LD r2,r2,#NS_R_ID
  MOVI r3,0
  CALL @ngen_create
  CALL @ngen_errno
  CMP r1,r0
  JMP[NE] @nsj_ngfail
  LD r1,r14,1
  MOVI r2,1
  CALL @ngen_start
  ST r1,r14,6
  CMP r1,r0
  JMP[EQ] @nsj_ngfail
  LD r1,r14,3
  MOVI r2,#NS_ST_JOINED
  ST r2,r1,#NS_A_STATE
  MOVI r2,1
  ST r2,r1,#NS_A_GEN
  LD r3,r14,6
  ST r3,r1,#NS_A_EPOCH
  LD r3,r1,#NS_A_RJOINS
  ADDI r3,r3,1
  ST r3,r1,#NS_A_RJOINS
  LA r2,#NS_GLOBAL
  LD r3,r2,#NS_G_JOIN
  ADDI r3,r3,1
  ST r3,r2,#NS_G_JOIN
  MOVI r1,#NS_T_JOIN
  LD r2,r14,1
  LA r3,#NS_NONE
  LD r4,r14,2
  LD r5,r14,5
  CALL @ns_trace
  MOVI r1,0
  JMP @nsj_out
nsj_ngfail:
  LD r1,r14,2
  CALL @nsym_root_release
  ; undo the root metadata written before ngen_create/start
  LD r1,r14,3
  MOVI r2,#NS_ST_UNJOIN
  ST r2,r1,#NS_A_STATE
  LA r2,#NS_NONE
  ST r2,r1,#NS_A_ROOT
  ST r0,r1,#NS_A_ROOTID
  ST r0,r1,#NS_A_ROOTHASH
  ST r0,r1,#NS_A_RJOINS
  CALL @ngen_errno
  CALL @ns_ngmap
  CALL @ns_fail
  JMP @nsj_out
nsj_joined:
  MOVI r1,#NS_EJOINED
  CALL @ns_fail
  JMP @nsj_out
nsj_busy:
  MOVI r1,#NS_EBUSY
  CALL @ns_fail
  JMP @nsj_out
nsj_noent:
  MOVI r1,#NS_ENOAGENT
  CALL @ns_fail
  JMP @nsj_out
nsj_noroot:
  MOVI r1,#NS_ENOROOT
  CALL @ns_fail
nsj_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsym_admit r1=agent r2=id r3=work r4=deadline r5=reserve r6=cpu -> 0/errno.
nsym_admit:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  CALL @ns_agent_joined
  CMP r1,r0
  JMP[EQ] @nsa_noent
  ST r1,r14,7
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @nsa_bad
  LD r2,r14,3
  CMPS r2,r0
  JMP[LE] @nsa_bad
  LD r2,r14,5
  CMPS r2,r0
  JMP[LT] @nsa_bad
  LD r3,r14,3
  CMP r2,r3
  JMP[GT] @nsa_bad
  CMP r2,r0
  JMP[EQ] @nsa_res_ok
  LD r3,r14,4
  CMP r3,r0
  JMP[EQ] @nsa_bad
nsa_res_ok:
  LD r2,r14,6
  MOVI r3,#NG_MAX_CPU
  CMP r2,r3
  JMP[GE] @nsa_bad
  ; budget gate
  LD r1,r14,7
  LD r2,r1,#NS_A_BLEFT
  CMP r2,r0
  JMP[GT] @nsa_have_budget
  LA r3,#NS_GLOBAL
  LD r4,r3,#NS_G_BUDGET
  ADDI r4,r4,1
  ST r4,r3,#NS_G_BUDGET
  LD r4,r3,#NS_G_REJECT
  ADDI r4,r4,1
  ST r4,r3,#NS_G_REJECT
  LD r4,r1,#NS_A_BDENY
  ADDI r4,r4,1
  ST r4,r1,#NS_A_BDENY
  MOVI r4,#NS_EBUDGET
  ST r4,r1,#NS_A_LERR
  MOVI r1,#NS_T_BUDGET
  LD r2,r14,1
  LD r3,r14,6
  LD r4,r14,2
  LD r5,r14,3
  CALL @ns_trace
  MOVI r1,#NS_EBUDGET
  CALL @ns_fail
  JMP @nsa_out
nsa_have_budget:
  ; First pass: a never-used slot.  Second pass: recycle the oldest
  ; done/missed/budget-parked slot so an agent can run more than four jobs
  ; over its lifetime while at most four are outstanding.
  ST r0,r14,8           ; slot index
  ST r0,r14,12          ; pass
nsa_slot:
  LD r2,r14,8
  MOVI r3,#NS_A_NJOBS
  CMP r2,r3
  JMP[LT] @nsa_slot_try
  LD r2,r14,12
  CMP r2,r0
  JMP[NE] @nsa_nospc
  MOVI r2,1
  ST r2,r14,12
  ST r0,r14,8
  JMP @nsa_slot
nsa_slot_try:
  LD r1,r14,7
  CALL @ns_job
  ST r1,r14,9
  LD r2,r1,#NS_J_STATE
  CMP r2,r0
  JMP[EQ] @nsa_got_slot
  LD r2,r14,12
  CMP r2,r0
  JMP[EQ] @nsa_slot_next
  LD r2,r1,#NS_J_STATE
  MOVI r3,#NS_J_DONE
  CMP r2,r3
  JMP[GE] @nsa_got_slot
nsa_slot_next:
  LD r2,r14,8
  ADDI r2,r2,1
  ST r2,r14,8
  JMP @nsa_slot
nsa_nospc:
  LA r3,#NS_GLOBAL
  LD r4,r3,#NS_G_REJECT
  ADDI r4,r4,1
  ST r4,r3,#NS_G_REJECT
  MOVI r1,#NS_ENOSPC
  CALL @ns_fail
  JMP @nsa_out
nsa_got_slot:
  ; enter the current ngen generation
  LD r1,r14,1
  LD r2,r14,7
  LD r2,r2,#NS_A_GEN
  LD r3,r14,6
  CALL @ngen_enter
  CMP r1,r0
  JMP[NE] @nsa_entered
  ; stale generation: no slot/counter mutation
  LA r3,#NS_GLOBAL
  LD r4,r3,#NS_G_STALE
  ADDI r4,r4,1
  ST r4,r3,#NS_G_STALE
  LD r4,r3,#NS_G_REJECT
  ADDI r4,r4,1
  ST r4,r3,#NS_G_REJECT
  LD r4,r14,7
  MOVI r2,#NS_ESTALE
  ST r2,r4,#NS_A_LERR
  MOVI r1,#NS_T_STALE
  LD r2,r14,1
  LD r3,r14,6
  LD r4,r14,2
  MOVI r5,0
  CALL @ns_trace
  MOVI r1,#NS_ESTALE
  CALL @ns_fail
  JMP @nsa_out
nsa_entered:
  ST r1,r14,10
  LD r1,r14,7
  LD r2,r1,#NS_A_BACKLOG
  ST r2,r14,11
  LD r2,r14,9
  LD r3,r14,2
  ST r3,r2,#NS_J_ID
  LD r3,r14,3
  ST r3,r2,#NS_J_WORK
  ST r3,r2,#NS_J_REM
  LD r3,r14,4
  ST r3,r2,#NS_J_DEAD
  LD r3,r14,5
  ST r3,r2,#NS_J_RES
  ST r3,r2,#NS_J_RESLEFT
  ST r13,r2,#NS_J_STATE
  LD r3,r14,10
  ST r3,r2,#NS_J_GEN
  ; agent counters
  LD r1,r14,7
  LD r2,r1,#NS_A_BACKLOG
  ADDI r2,r2,1
  ST r2,r1,#NS_A_BACKLOG
  LD r2,r1,#NS_A_ADMITTED
  ADDI r2,r2,1
  ST r2,r1,#NS_A_ADMITTED
  LD r2,r1,#NS_A_REMAIN
  LD r3,r14,3
  ADD r2,r2,r3
  ST r2,r1,#NS_A_REMAIN
  LD r2,r14,11
  CMP r2,r0
  JMP[NE] @nsa_no_ready
  LA r2,#NS_GLOBAL
  LD r3,r2,#NS_G_TICK
  ST r3,r1,#NS_A_READY
  LA r3,#NS_NONE
  ST r3,r1,#NS_A_LAST
nsa_no_ready:
  LD r1,r14,7
  CALL @ns_refresh
  LA r2,#NS_GLOBAL
  LD r3,r2,#NS_G_ADMITS
  ADDI r3,r3,1
  ST r3,r2,#NS_G_ADMITS
  LD r3,r2,#NS_G_WORK
  LD r4,r14,3
  ADD r3,r3,r4
  ST r3,r2,#NS_G_WORK
  MOVI r1,#NS_T_ADMIT
  LD r2,r14,1
  LD r3,r14,6
  LD r4,r14,2
  LD r5,r14,3
  CALL @ns_trace
  MOVI r1,0
  JMP @nsa_out
nsa_bad:
  MOVI r1,#NS_EBAD
  CALL @ns_fail
  JMP @nsa_out
nsa_noent:
  MOVI r1,#NS_ENOAGENT
  CALL @ns_fail
nsa_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; ns_pick_fair r1=exclude agent id (0xFFFF none) -> record / 0.
ns_pick_fair:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r0,r14,2           ; i
  ST r0,r14,3           ; best
  ST r0,r14,4           ; best vrt
  ST r0,r14,5           ; best id
npf_loop:
  LD r2,r14,2
  MOVI r3,#NS_MAX_AGENT
  CMP r2,r3
  JMP[GE] @npf_done
  LD r2,r14,2
  ADDI r2,r2,1
  ST r2,r14,6
  LD r1,r14,6
  CALL @ns_agent_joined
  CMP r1,r0
  JMP[EQ] @npf_next
  ST r1,r14,7
  LD r2,r1,#NS_A_ID
  LD r3,r14,1
  CMP r2,r3
  JMP[EQ] @npf_next
  LD r2,r1,#NS_A_BLEFT
  CMP r2,r0
  JMP[LE] @npf_next
  CALL @ns_pending_job
  CMP r1,r0
  JMP[EQ] @npf_next
  LD r1,r14,7
  LD r2,r1,#NS_A_VRT
  LD r3,r14,3
  CMP r3,r0
  JMP[EQ] @npf_take
  LD r3,r14,4
  CMP r2,r3
  JMP[LT] @npf_take
  JMP[GT] @npf_next
  LD r3,r1,#NS_A_ID
  LD r4,r14,5
  CMP r3,r4
  JMP[GE] @npf_next
npf_take:
  LD r1,r14,7
  ST r1,r14,3
  LD r2,r1,#NS_A_VRT
  ST r2,r14,4
  LD r2,r1,#NS_A_ID
  ST r2,r14,5
npf_next:
  LD r2,r14,2
  ADDI r2,r2,1
  ST r2,r14,2
  JMP @npf_loop
npf_done:
  LD r1,r14,3
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ns_pick_reserved r1=exclude agent id -> record / 0.
ns_pick_reserved:
  ST r15,r14,0
  ADDI r14,r14,80
  ST r1,r14,1
  ST r0,r14,2           ; i
  ST r0,r14,3           ; best
  ST r0,r14,4           ; best deadline
  ST r0,r14,5           ; best vrt
  ST r0,r14,6           ; best id
npr_loop:
  LD r2,r14,2
  MOVI r3,#NS_MAX_AGENT
  CMP r2,r3
  JMP[GE] @npr_done
  LD r2,r14,2
  ADDI r2,r2,1
  ST r2,r14,7
  LD r1,r14,7
  CALL @ns_agent_joined
  CMP r1,r0
  JMP[EQ] @npr_next
  ST r1,r14,8
  LD r2,r1,#NS_A_ID
  LD r3,r14,1
  CMP r2,r3
  JMP[EQ] @npr_next
  LD r2,r1,#NS_A_BLEFT
  CMP r2,r0
  JMP[LE] @npr_next
  CALL @ns_pending_job
  CMP r1,r0
  JMP[EQ] @npr_next
  ST r1,r14,9
  LD r2,r1,#NS_J_RESLEFT
  CMP r2,r0
  JMP[LE] @npr_next
  LD r2,r1,#NS_J_DEAD
  CMP r2,r0
  JMP[EQ] @npr_next
  LD r3,r14,3
  CMP r3,r0
  JMP[EQ] @npr_take
  LD r3,r14,4
  CMP r2,r3
  JMP[LT] @npr_take
  JMP[GT] @npr_next
  LD r1,r14,8
  LD r3,r1,#NS_A_VRT
  LD r4,r14,5
  CMP r3,r4
  JMP[LT] @npr_take
  JMP[GT] @npr_next
  LD r3,r1,#NS_A_ID
  LD r4,r14,6
  CMP r3,r4
  JMP[GE] @npr_next
npr_take:
  LD r1,r14,8
  ST r1,r14,3
  LD r2,r14,9
  LD r2,r2,#NS_J_DEAD
  ST r2,r14,4
  LD r1,r14,8
  LD r2,r1,#NS_A_VRT
  ST r2,r14,5
  LD r2,r1,#NS_A_ID
  ST r2,r14,6
npr_next:
  LD r2,r14,2
  ADDI r2,r2,1
  ST r2,r14,2
  JMP @npr_loop
npr_done:
  LD r1,r14,3
  ADDI r14,r14,-80
  LD r15,r14,0
  RET

; ns_pick r1=exclude -> record / 0.
ns_pick:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  CALL @ns_pick_reserved
  CMP r1,r0
  JMP[NE] @npk_out
  LD r1,r14,1
  CALL @ns_pick_fair
npk_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; ns_mark_deadline r1=agent rec r2=job r3=tick -> 0.
ns_mark_deadline:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r2,#NS_J_REM
  ST r3,r14,3
  MOVI r4,#NS_J_MISS
  ST r4,r2,#NS_J_STATE
  LD r4,r1,#NS_A_BACKLOG
  CMP r4,r0
  JMP[EQ] @nmd_nob
  SUB r4,r4,r13
  ST r4,r1,#NS_A_BACKLOG
nmd_nob:
  LD r4,r1,#NS_A_DM
  ADDI r4,r4,1
  ST r4,r1,#NS_A_DM
  LD r4,r1,#NS_A_PARKED
  ADDI r4,r4,1
  ST r4,r1,#NS_A_PARKED
  LD r5,r1,#NS_A_REMAIN
  LD r3,r14,3
  SUB r5,r5,r3
  ST r5,r1,#NS_A_REMAIN
  LD r4,r2,#NS_J_RESLEFT
  CMP r4,r0
  JMP[EQ] @nmd_nores
  LD r4,r1,#NS_A_RMISS
  ADDI r4,r4,1
  ST r4,r1,#NS_A_RMISS
  LA r4,#NS_GLOBAL
  LD r5,r4,#NS_G_RMISS
  ADDI r5,r5,1
  ST r5,r4,#NS_G_RMISS
nmd_nores:
  LA r4,#NS_GLOBAL
  LD r5,r4,#NS_G_DM
  ADDI r5,r5,1
  ST r5,r4,#NS_G_DM
  LD r5,r4,#NS_G_PARKED
  ADDI r5,r5,1
  ST r5,r4,#NS_G_PARKED
  ; exit the generation
  LD r1,r14,1
  LD r1,r1,#NS_A_ID
  LD r2,r14,2
  LD r2,r2,#NS_J_GEN
  CALL @ngen_exit
  ; trace deadline miss; the sweep is not CPU-local
  MOVI r1,#NS_T_DM
  LD r2,r14,1
  LD r2,r2,#NS_A_ID
  LA r3,#NS_NONE
  LD r4,r14,2
  LD r4,r4,#NS_J_ID
  LD r5,r14,3
  CALL @ns_trace
  LD r1,r14,1
  CALL @ns_refresh
  LD r1,r14,1
  LD r2,r1,#NS_A_BACKLOG
  CMP r2,r0
  JMP[NE] @nmd_out
  LA r2,#NS_NONE
  ST r2,r1,#NS_A_LAST
nmd_out:
  MOVI r1,0
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ns_deadline_sweep r1=tick -> 0.
ns_deadline_sweep:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r0,r14,2
nds_agent:
  LD r2,r14,2
  MOVI r3,#NS_MAX_AGENT
  CMP r2,r3
  JMP[GE] @nds_done
  LD r2,r14,2
  ADDI r2,r2,1
  ST r2,r14,3
  LD r1,r14,3
  CALL @ns_agent_joined
  CMP r1,r0
  JMP[EQ] @nds_next
  ST r1,r14,4
nds_job:
  LD r1,r14,4
  CALL @ns_pending_job
  CMP r1,r0
  JMP[EQ] @nds_next
  ST r1,r14,5
  LD r2,r1,#NS_J_DEAD
  CMP r2,r0
  JMP[EQ] @nds_next
  LD r3,r14,1
  CMP r3,r2
  JMP[LT] @nds_next
  LD r1,r14,4
  LD r2,r14,5
  LD r3,r14,1
  CALL @ns_mark_deadline
  JMP @nds_job
nds_next:
  LD r2,r14,2
  ADDI r2,r2,1
  ST r2,r14,2
  JMP @nds_agent
nds_done:
  MOVI r1,0
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; ns_service r1=agent rec r2=cpu r3=tick -> 0.
ns_service:
  ST r15,r14,0
  ADDI r14,r14,128
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @ns_pending_job
  CMP r1,r0
  JMP[EQ] @nsv_out
  ST r1,r14,4
  ; queued -> running
  LD r2,r1,#NS_J_STATE
  CMP r2,r13
  JMP[NE] @nsv_gap
  MOVI r2,#NS_J_RUN
  ST r2,r1,#NS_J_STATE
nsv_gap:
  LD r1,r14,1
  LD r2,r1,#NS_A_LAST
  LA r3,#NS_NONE
  CMP r2,r3
  JMP[EQ] @nsv_first
  LD r3,r14,3
  SUB r3,r3,r2
  JMP @nsv_gapdone
nsv_first:
  LD r3,r14,3
  LD r2,r1,#NS_A_READY
  SUB r3,r3,r2
nsv_gapdone:
  ST r3,r14,5
  LD r2,r1,#NS_A_MAXGAP
  CMP r3,r2
  JMP[LE] @nsv_nogap
  ST r3,r1,#NS_A_MAXGAP
nsv_nogap:
  LA r2,#NS_GLOBAL
  LD r4,r2,#NS_G_MAXGAP
  CMP r3,r4
  JMP[LE] @nsv_nogmg
  ST r3,r2,#NS_G_MAXGAP
nsv_nogmg:
  LD r3,r14,3
  ST r3,r1,#NS_A_LAST
  ; remaining--, budget--, served++
  LD r2,r14,4
  LD r3,r2,#NS_J_REM
  SUB r3,r3,r13
  ST r3,r2,#NS_J_REM
  ST r3,r14,6
  LD r3,r1,#NS_A_BLEFT
  CMP r3,r0
  JMP[EQ] @nsv_no_budget_dec
  SUB r3,r3,r13
  ST r3,r1,#NS_A_BLEFT
nsv_no_budget_dec:
  ST r3,r14,7
  LD r4,r1,#NS_A_SERVED
  ADDI r4,r4,1
  ST r4,r1,#NS_A_SERVED
  LD r4,r1,#NS_A_DISP
  ADDI r4,r4,1
  ST r4,r1,#NS_A_DISP
  LD r4,r1,#NS_A_REMAIN
  CMP r4,r0
  JMP[EQ] @nsv_norem
  SUB r4,r4,r13
  ST r4,r1,#NS_A_REMAIN
nsv_norem:
  LA r2,#NS_GLOBAL
  LD r4,r2,#NS_G_SERVICE
  ADDI r4,r4,1
  ST r4,r2,#NS_G_SERVICE
  LD r4,r2,#NS_G_DISP
  ADDI r4,r4,1
  ST r4,r2,#NS_G_DISP
  ; virtual runtime += 65536 / weight
  LD r2,r14,1
  LD r3,r2,#NS_A_WEIGHT
  LA r4,#NS_Q16
  DIVU r4,r4,r3
  LD r5,r2,#NS_A_VRT
  ADD r5,r5,r4
  ST r5,r2,#NS_A_VRT
  ; reservation accounting
  LD r2,r14,4
  LD r3,r2,#NS_J_RESLEFT
  CMP r3,r0
  JMP[EQ] @nsv_nores
  SUB r3,r3,r13
  ST r3,r2,#NS_J_RESLEFT
  CMP r3,r0
  JMP[NE] @nsv_nores
  LD r1,r14,1
  LD r3,r1,#NS_A_RMET
  ADDI r3,r3,1
  ST r3,r1,#NS_A_RMET
  LA r4,#NS_GLOBAL
  LD r5,r4,#NS_G_RMET
  ADDI r5,r5,1
  ST r5,r4,#NS_G_RMET
  MOVI r1,#NS_T_RMET
  LD r2,r14,1
  LD r2,r2,#NS_A_ID
  LD r3,r14,2
  LD r4,r14,4
  LD r4,r4,#NS_J_ID
  LD r5,r14,4
  LD r5,r5,#NS_J_RES
  CALL @ns_trace
nsv_nores:
  ; dispatch trace
  MOVI r1,#NS_T_DISP
  LD r2,r14,1
  LD r2,r2,#NS_A_ID
  LD r3,r14,2
  LD r4,r14,4
  LD r4,r4,#NS_J_ID
  LD r5,r14,6
  CALL @ns_trace
  ; completion / budget park
  LD r2,r14,6
  CMP r2,r0
  JMP[EQ] @nsv_complete
  LD r2,r14,7
  CMP r2,r0
  JMP[EQ] @nsv_budget
  JMP @nsv_out
nsv_complete:
  LD r1,r14,1
  LD r2,r14,4
  MOVI r3,#NS_J_DONE
  ST r3,r2,#NS_J_STATE
  LD r3,r1,#NS_A_BACKLOG
  CMP r3,r0
  JMP[EQ] @nsv_cnob
  SUB r3,r3,r13
  ST r3,r1,#NS_A_BACKLOG
nsv_cnob:
  LD r3,r1,#NS_A_COMPLETE
  ADDI r3,r3,1
  ST r3,r1,#NS_A_COMPLETE
  LA r3,#NS_GLOBAL
  LD r4,r3,#NS_G_COMPLETE
  ADDI r4,r4,1
  ST r4,r3,#NS_G_COMPLETE
  LD r1,r14,1
  LD r1,r1,#NS_A_ID
  LD r2,r14,4
  LD r2,r2,#NS_J_GEN
  CALL @ngen_exit
  MOVI r1,#NS_T_COMPLETE
  LD r2,r14,1
  LD r2,r2,#NS_A_ID
  LD r3,r14,2
  LD r4,r14,4
  LD r4,r4,#NS_J_ID
  MOVI r5,0
  CALL @ns_trace
  LD r1,r14,1
  CALL @ns_refresh
  LD r1,r14,1
  LD r2,r1,#NS_A_BACKLOG
  CMP r2,r0
  JMP[NE] @nsv_out
  LA r2,#NS_NONE
  ST r2,r1,#NS_A_LAST
  JMP @nsv_out
nsv_budget:
  LD r1,r14,1
  LD r2,r14,4
  MOVI r3,#NS_J_BUDGET
  ST r3,r2,#NS_J_STATE
  LD r3,r1,#NS_A_BACKLOG
  CMP r3,r0
  JMP[EQ] @nsv_bnob
  SUB r3,r3,r13
  ST r3,r1,#NS_A_BACKLOG
nsv_bnob:
  LD r3,r1,#NS_A_BDENY
  ADDI r3,r3,1
  ST r3,r1,#NS_A_BDENY
  LD r3,r1,#NS_A_PARKED
  ADDI r3,r3,1
  ST r3,r1,#NS_A_PARKED
  LD r3,r1,#NS_A_REMAIN
  LD r4,r14,6
  SUB r3,r3,r4
  ST r3,r1,#NS_A_REMAIN
  LD r3,r2,#NS_J_RESLEFT
  CMP r3,r0
  JMP[EQ] @nsv_bnores
  LD r3,r1,#NS_A_RMISS
  ADDI r3,r3,1
  ST r3,r1,#NS_A_RMISS
  LA r3,#NS_GLOBAL
  LD r4,r3,#NS_G_RMISS
  ADDI r4,r4,1
  ST r4,r3,#NS_G_RMISS
nsv_bnores:
  LA r3,#NS_GLOBAL
  LD r4,r3,#NS_G_BUDGET
  ADDI r4,r4,1
  ST r4,r3,#NS_G_BUDGET
  LD r4,r3,#NS_G_PARKED
  ADDI r4,r4,1
  ST r4,r3,#NS_G_PARKED
  LD r1,r14,1
  LD r1,r1,#NS_A_ID
  LD r2,r14,4
  LD r2,r2,#NS_J_GEN
  CALL @ngen_exit
  MOVI r1,#NS_T_BUDGET
  LD r2,r14,1
  LD r2,r2,#NS_A_ID
  LD r3,r14,2
  LD r4,r14,4
  LD r4,r4,#NS_J_ID
  LD r5,r14,6
  CALL @ns_trace
  LD r1,r14,1
  CALL @ns_refresh
  LD r1,r14,1
  LD r2,r1,#NS_A_BACKLOG
  CMP r2,r0
  JMP[NE] @nsv_out
  LA r2,#NS_NONE
  ST r2,r1,#NS_A_LAST
nsv_out:
  MOVI r1,0
  ADDI r14,r14,-128
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsym_dispatch - one 2-CPU scheduling tick.
nsym_dispatch:
  ST r15,r14,0
  ADDI r14,r14,64
  LA r2,#NS_GLOBAL
  LD r1,r2,#NS_G_TICK
  ST r1,r14,1
  ; CPU0
  MOVI r1,0xFFFF
  CALL @ns_pick
  ST r1,r14,2
  CMP r1,r0
  JMP[EQ] @nsd_idle0
  LD r1,r14,2
  MOVI r2,0
  LD r3,r14,1
  CALL @ns_service
  LD r1,r14,2
  LD r1,r1,#NS_A_ID
  ST r1,r14,3
  JMP @nsd_cpu1
nsd_idle0:
  LA r2,#NS_GLOBAL
  LD r3,r2,#NS_G_IDLE
  ADDI r3,r3,1
  ST r3,r2,#NS_G_IDLE
  MOVI r1,0xFFFF
  ST r1,r14,3
nsd_cpu1:
  LD r1,r14,3
  CALL @ns_pick
  ST r1,r14,4
  CMP r1,r0
  JMP[EQ] @nsd_idle1
  LD r1,r14,4
  MOVI r2,1
  LD r3,r14,1
  CALL @ns_service
  JMP @nsd_sweep
nsd_idle1:
  LA r2,#NS_GLOBAL
  LD r3,r2,#NS_G_IDLE
  ADDI r3,r3,1
  ST r3,r2,#NS_G_IDLE
nsd_sweep:
  LD r1,r14,1
  CALL @ns_deadline_sweep
  LA r2,#NS_GLOBAL
  LD r3,r14,1
  ADDI r3,r3,1
  ST r3,r2,#NS_G_TICK
  LD r3,r2,#NS_G_ROUNDS
  ADDI r3,r3,1
  ST r3,r2,#NS_G_ROUNDS
  MOVI r1,0
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; nsym_run r1=ticks -> 0.
nsym_run:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
nsr_loop:
  LD r2,r14,1
  CMP r2,r0
  JMP[EQ] @nsr_done
  CALL @nsym_dispatch
  LD r2,r14,1
  SUB r2,r2,r13
  ST r2,r14,1
  JMP @nsr_loop
nsr_done:
  MOVI r1,0
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsym_publish r1=agent r2=new gen r3=new root -> epoch / 0.
nsym_publish:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @ns_agent_joined
  CMP r1,r0
  JMP[EQ] @nsp_noent
  ST r1,r14,4
  LD r1,r1,#NS_A_ROOT
  ST r1,r14,5
  ST r0,r14,6           ; acquired new root flag
  ST r0,r14,7           ; new root refs
  LD r2,r14,3
  LA r3,#NS_NONE
  CMP r2,r3
  JMP[EQ] @nsp_do
  LD r3,r14,5
  CMP r2,r3
  JMP[EQ] @nsp_do
  ADD r1,r2,r0
  CALL @ns_root_live
  CMP r1,r0
  JMP[EQ] @nsp_noroot
  LD r1,r14,3
  CALL @nsym_root_acquire
  LA r3,#NS_NONE
  CMP r1,r3
  JMP[EQ] @nsp_noroot
  ST r1,r14,7
  ST r13,r14,6
nsp_do:
  ; root id argument: new root id when changing, else cached old id
  LD r3,r14,4
  LD r3,r3,#NS_A_ROOTID
  LD r2,r14,3
  LA r4,#NS_NONE
  CMP r2,r4
  JMP[EQ] @nsp_call
  LD r4,r14,5
  CMP r2,r4
  JMP[EQ] @nsp_call
  ADD r1,r2,r0
  CALL @ns_root_live
  LD r3,r1,#NS_R_ID
nsp_call:
  LD r1,r14,1
  LD r2,r14,2
  MOVI r4,0
  CALL @ngen_publish
  ST r1,r14,8
  CALL @ngen_errno
  CMP r1,r0
  JMP[NE] @nsp_ngfail
  LD r1,r14,8
  CMP r1,r0
  JMP[EQ] @nsp_ngfail
  ; commit the new root reference
  LD r2,r14,6
  CMP r2,r0
  JMP[EQ] @nsp_commit
  LD r2,r14,3
  ADD r1,r2,r0
  CALL @ns_root_live
  ST r1,r14,9
  LD r2,r1,#NS_R_ID
  ST r2,r14,10
  LD r2,r1,#NS_R_HASH
  ST r2,r14,11
  LD r1,r14,4
  LD r2,r14,3
  ST r2,r1,#NS_A_ROOT
  LD r2,r14,10
  ST r2,r1,#NS_A_ROOTID
  LD r2,r14,11
  ST r2,r1,#NS_A_ROOTHASH
  LD r3,r1,#NS_A_RJOINS
  ADDI r3,r3,1
  ST r3,r1,#NS_A_RJOINS
  LD r3,r1,#NS_A_RLEAVES
  ADDI r3,r3,1
  ST r3,r1,#NS_A_RLEAVES
  LD r2,r14,5
  ST r2,r14,12
  LD r1,r14,5
  CALL @nsym_root_release
nsp_commit:
  LD r1,r14,4
  LD r2,r14,2
  ST r2,r1,#NS_A_GEN
  LD r3,r14,8
  ST r3,r1,#NS_A_EPOCH
  LA r2,#NS_GLOBAL
  LD r3,r2,#NS_G_PUB
  ADDI r3,r3,1
  ST r3,r2,#NS_G_PUB
  MOVI r1,#NS_T_PUBLISH
  LD r2,r14,1
  LA r3,#NS_NONE
  LD r4,r14,2
  LD r5,r14,8
  CALL @ns_trace
  LD r1,r14,8
  JMP @nsp_out
nsp_ngfail:
  LD r2,r14,6
  CMP r2,r0
  JMP[EQ] @nsp_map
  LD r1,r14,3
  CALL @nsym_root_release
nsp_map:
  CALL @ngen_errno
  CALL @ns_ngmap
  CALL @ns_fail
  JMP @nsp_out
nsp_noroot:
  MOVI r1,#NS_ENOROOT
  CALL @ns_fail
  JMP @nsp_out
nsp_noent:
  MOVI r1,#NS_ENOAGENT
  CALL @ns_fail
nsp_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; nsym_start r1=agent r2=gen -> epoch / 0.
nsym_start:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  CALL @ns_agent_joined
  CMP r1,r0
  JMP[EQ] @nss_noent
  ST r1,r14,3
  LD r1,r14,1
  LD r2,r14,2
  CALL @ngen_start
  ST r1,r14,4
  CALL @ngen_errno
  CMP r1,r0
  JMP[NE] @nss_fail
  LD r1,r14,4
  CMP r1,r0
  JMP[EQ] @nss_fail
  LD r2,r14,3
  LD r3,r14,2
  ST r3,r2,#NS_A_GEN
  LD r3,r14,4
  ST r3,r2,#NS_A_EPOCH
  LA r2,#NS_GLOBAL
  LD r3,r2,#NS_G_START
  ADDI r3,r3,1
  ST r3,r2,#NS_G_START
  MOVI r1,#NS_T_START
  LD r2,r14,1
  LA r3,#NS_NONE
  LD r4,r14,2
  LD r5,r14,4
  CALL @ns_trace
  LD r1,r14,4
  JMP @nss_out
nss_fail:
  CALL @ngen_errno
  CALL @ns_ngmap
  CALL @ns_fail
  JMP @nss_out
nss_noent:
  MOVI r1,#NS_ENOAGENT
  CALL @ns_fail
nss_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; nsym_drain r1=agent -> epoch / 0.
nsym_drain:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  CALL @ns_agent_joined
  CMP r1,r0
  JMP[EQ] @nsd_noent
  ST r1,r14,2
  LD r1,r14,1
  CALL @ngen_drain
  ST r1,r14,3
  CALL @ngen_errno
  CMP r1,r0
  JMP[NE] @nsdd_fail
  LD r1,r14,3
  CMP r1,r0
  JMP[EQ] @nsdd_fail
  LD r2,r14,2
  LD r3,r14,3
  ST r3,r2,#NS_A_EPOCH
  LA r2,#NS_GLOBAL
  LD r4,r2,#NS_G_DRAIN
  ADDI r4,r4,1
  ST r4,r2,#NS_G_DRAIN
  MOVI r1,#NS_T_DRAIN
  LD r2,r14,1
  LA r3,#NS_NONE
  ; a=generation, b=epoch
  LD r4,r14,2
  LD r4,r4,#NS_A_GEN
  LD r5,r14,3
  CALL @ns_trace
  LD r1,r14,3
  JMP @nsdd_out
nsdd_fail:
  CALL @ngen_errno
  CALL @ns_ngmap
  CALL @ns_fail
  JMP @nsdd_out
nsd_noent:
  MOVI r1,#NS_ENOAGENT
  CALL @ns_fail
nsdd_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; nsym_leave r1=agent -> 0/errno.
nsym_leave:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  CALL @ns_agent_joined
  CMP r1,r0
  JMP[EQ] @nsl_noent
  ST r1,r14,2
  CALL @ns_pending_job
  CMP r1,r0
  JMP[NE] @nsl_busy
  ; ngen_status buffer at +16 (32 words), plus locals below it
  LD r1,r14,1
  ADDI r2,r14,16
  CALL @ngen_status
  CMP r1,r0
  JMP[NE] @nsl_busy
  LD r2,r14,22
  CMP r2,r0
  JMP[NE] @nsl_busy
  LD r2,r14,24
  CMP r2,r0
  JMP[EQ] @nsl_flip
  ; freeze the current generation if it is still accepting
  LD r1,r14,1
  CALL @ngen_drain
  ST r1,r14,3
  CALL @ngen_errno
  CMP r1,r0
  JMP[NE] @nsl_busy
  LD r2,r14,2
  LD r3,r14,3
  ST r3,r2,#NS_A_EPOCH
  LA r2,#NS_GLOBAL
  LD r3,r2,#NS_G_DRAIN
  ADDI r3,r3,1
  ST r3,r2,#NS_G_DRAIN
nsl_flip:
  LD r1,r14,2
  LD r2,r1,#NS_A_ROOT
  ST r2,r14,4
  LD r2,r1,#NS_A_GEN
  ST r2,r14,5
  MOVI r2,#NS_ST_UNJOIN
  ST r2,r1,#NS_A_STATE
  LA r2,#NS_NONE
  ST r2,r1,#NS_A_ROOT
  ST r0,r1,#NS_A_ROOTID
  ST r0,r1,#NS_A_ROOTHASH
  LD r2,r1,#NS_A_RLEAVES
  ADDI r2,r2,1
  ST r2,r1,#NS_A_RLEAVES
  LA r2,#NS_GLOBAL
  LD r3,r2,#NS_G_LEAVE
  ADDI r3,r3,1
  ST r3,r2,#NS_G_LEAVE
  MOVI r1,#NS_T_LEAVE
  LD r2,r14,1
  LA r3,#NS_NONE
  LD r4,r14,4
  LD r5,r14,5
  CALL @ns_trace
  LD r1,r14,4
  CALL @nsym_root_release
  MOVI r1,0
  JMP @nsl_out
nsl_busy:
  MOVI r1,#NS_EBUSY
  CALL @ns_fail
  JMP @nsl_out
nsl_noent:
  MOVI r1,#NS_ENOAGENT
  CALL @ns_fail
nsl_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsym_agent_status r1=agent r2=out(128) -> 0/-1.
nsym_agent_status:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r2,r14,1
  CALL @ns_agent_rec
  CMP r1,r0
  JMP[EQ] @nas_bad
  LD r2,r14,1
  MOVI r3,#NS_AGENT_STRIDE
  BCOPY r2,r1,r3
  MOVI r1,0
  JMP @nas_out
nas_bad:
  LA r1,#NS_NONE
nas_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nsym_global r1=out(32) -> 0.
nsym_global:
  LA r2,#NS_GLOBAL
  MOVI r3,32
  BCOPY r1,r2,r3
  MOVI r1,0
  RET

; nsym_trace r1=index r2=out(8) -> 0/-1.
nsym_trace:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  CMP r1,r0
  JMP[LT] @nstt_bad
  LA r2,#NS_GLOBAL
  LD r3,r2,#NS_G_TRN
  LD r1,r14,1
  CMP r1,r3
  JMP[GE] @nstt_bad
  SUB r3,r3,r1
  MOVI r4,#NS_TRACE_N
  CMP r3,r4
  JMP[GT] @nstt_bad
  MOVI r4,511
  BOOL.8 r3,r1,r4
  SHL r3,r3,3
  LA r4,#NS_TRACE_TAB
  ADD r3,r4,r3
  LD r2,r14,2
  MOVI r4,8
  BCOPY r2,r3,r4
  MOVI r1,0
  JMP @nstt_out
nstt_bad:
  LA r1,#NS_NONE
nstt_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nsym_trace_head -> head / 0.
nsym_trace_head:
  LA r2,#NS_GLOBAL
  LD r1,r2,#NS_G_TRHEAD
  RET

; nsym_tick -> tick.
nsym_tick:
  LA r2,#NS_GLOBAL
  LD r1,r2,#NS_G_TICK
  RET

; nsym_errno -> last error.
nsym_errno:
  LA r2,#NS_GLOBAL
  LD r1,r2,#NS_G_ERRNO
  RET
