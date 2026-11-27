; nobs.nas - pure-NaN observability and operations layer (F12).
;
; Nobs is the ops plane above nancore, nansched_mp, nheap and nnuma:
;
;   * per-core statistics sampled from the NanCore record (ticks, queue
;     depth, IPIs, state) plus nansched_mp per-CPU counters (tasks run,
;     steals, migrations, preemptions, ticks), with fault and miss counters
;     accumulated by explicit accounting calls;
;   * per-(NUMA node, page class) allocator statistics backed by nheap:
;     allocation/free calls, live pages/bytes, high water, OOM events,
;     eviction extents/pages/bytes;
;   * per-agent quotas for CPU steps, CPU ticks, memory bytes and KV tokens,
;     with set/check/account, deny-on-exceed and a trace event per denial;
;   * a bounded scheduler trace ring with tick, cpu, kind, id, a, b, a
;     deterministic 32-bit hash and a logical sequence number.  When the
;     ring is full the oldest entry is overwritten (ring_total keeps the
;     logical history, so overwritten queries fail closed);
;   * a health snapshot with magic/version and exact totals;
;   * a memory-pressure path that first retries with cold-page eviction and
;     otherwise denies with an OOM event.
;
; Layouts are caller supplied, like nheap.  Context (32 words):
;   +0 magic "NOBS"  +1 version  +2 cpus  +3 nodes  +4 classes
;   +5 tick  +6 heap ctx  +7 sched ctx  +8 core stats base
;   +9 mem stats base  +10 quota base  +11 ring base  +12 ring cap
;   +13 ring head  +14 ring count  +15 ring total  +16 ring wraps
;   +17 quota denials  +18 OOM events  +19 eviction extents
;   +20 eviction pages  +21 cold base  +22 cold cap  +23 cold count
;   +24 cold search head  +25 health status  +26 samples
;   +27 last trace hash  +28..31 reserved.
;
; Config (16 words):
;   +0 cpus +1 nodes +2 classes +3 heap ctx (0 allowed)
;   +4 sched ctx (0 allowed) +5 core stats +6 mem stats +7 quota base
;   +8 ring base +9 ring cap +10 cold base +11 cold cap +12..15 reserved.
;
; Per-core stats (16 words): ticks, tasks run, steals in, steals out,
;   migrations in, migrations out, faults, IPIs, queue depth, budget misses,
;   deadline misses, state, timer, preemptions, events, reserved.
;
; Per-(node,class) stats (16 words): allocs, frees, live pages (lo,hi),
;   live bytes (lo,hi), evicted pages (lo,hi), evicted bytes (lo,hi),
;   OOM events, denied pressure requests, high-water pages (lo,hi),
;   eviction extents, reserved.
;
; Quota record (16 words, 32 agents, index agent-1): active, agent id,
;   max steps, used steps, max ticks, used ticks, max mem (lo,hi),
;   used mem (lo,hi), max KV tokens, used KV tokens, denied, flags,
;   2 reserved.  A zero limit is unlimited.
;
; Trace entry (8 words): tick, cpu, kind, id, a, b, hash, seq.
;   cpu 0xFFFFFFFF means the event is not CPU-local.
;
; Health snapshot (32 words): magic "NOBH", version, cpus, nodes, classes,
;   tick, total ticks/tasks/steals/migrations/faults/IPIs/budget misses/
;   deadline misses/queue depth, allocs, frees, live pages (lo,hi),
;   live bytes (lo,hi), OOM events, eviction extents, evicted pages (lo,hi),
;   quota denials, ring total, ring wraps, status, samples, ring count,
;   reserved.  Status: 0 healthy, 1 degraded (misses/eviction/quota deny),
;   2 OOM.
;
; ABI: r0=0, r13=1, r14=SP (grows up), r15=link.  Public routines preserve
; r6..r12 and return in r1.
;
; API:
;   nobs_init          r1=ctx r2=config -> 0/-1
;   nobs_tick          r1=ctx r2=delta -> new tick
;   nobs_core_sample   r1=ctx r2=cpu -> 0/-1
;   nobs_core_event    r1=ctx r2=cpu r3=kind r4=amount -> 0/-1
;                      kind 0 fault, 1 budget miss, 2 deadline miss,
;                      3 IPI, 4 timer, 5 generic event
;   nobs_core_get      r1=ctx r2=cpu r3=out(16) -> 0/-1
;   nobs_mem_alloc     r1=ctx r2=node r3=class r4=pages_lo r5=pages_hi
;                      r6=out(2) -> 0/-1
;   nobs_mem_free      r1=ctx r2=node r3=class r4=base_lo r5=base_hi
;                      r6=pages_lo r7=pages_hi -> 0/-1
;   nobs_mem_cold      r1=ctx r2=node r3=class r4=spec -> 0/-1
;                      spec: pages_lo, pages_hi, base_lo, base_hi
;   nobs_mem_pressure  r1=ctx r2=node r3=class r4=pages_lo r5=pages_hi
;                      -> 0 satisfied / 1 OOM deny / 3 bad
;   nobs_mem_stats     r1=ctx r2=node r3=class r4=out(16) -> 0/-1
;   nobs_quota_set     r1=ctx r2=agent r3=spec(6) -> 0/-1
;                      spec: max steps, max ticks, max mem lo, max mem hi,
;                      max KV tokens, flags
;   nobs_quota_check   r1=ctx r2=agent r3=kind r4=lo r5=hi -> 0/1/3
;   nobs_quota_account r1=ctx r2=agent r3=kind r4=lo r5=hi -> 0/1/3
;   nobs_quota_get     r1=ctx r2=agent r3=out(16) -> 0/-1
;   nobs_trace         r1=ctx r2=kind r3=cpu r4=id r5=a r6=b -> hash/0
;   nobs_trace_at      r1=ctx r2=index r3=out(8) -> 0/-1
;   nobs_trace_snapshot r1=ctx r2=out r3=max -> entries copied
;   nobs_trace_last    r1=ctx r2=out(8) -> 0/-1
;   nobs_health        r1=ctx r2=out(32) -> 0/-1

.include "nansched_mp.nas"
.include "nnuma.nas"

; NanCore fields used here but not declared by nansched_mp.nas.
.equ NC_STATE       1
.equ NC_IPI         18
.equ NC_TIMER       19
.equ NC_TICKS       25

.equ NB_MAGIC       0x53424F4E       ; "NOBS"
.equ NB_VERSION     1
.equ NB_HMAGIC      0x48424F4E       ; "NOBH"
.equ NB_MAXCPU      4096
.equ NB_MAXNODE     64
.equ NB_CLASSES     3
.equ NB_MAXAGENT    32

.equ NB_FRAME       64
.equ NB_FN          -64

; Context fields.
.equ NB_MAGIC_F     0
.equ NB_VERSION_F   1
.equ NB_CPUS        2
.equ NB_NODES       3
.equ NB_CLASSES_F   4
.equ NB_TICK        5
.equ NB_HEAP        6
.equ NB_SCHED       7
.equ NB_CORES       8
.equ NB_MEM         9
.equ NB_QUOTAS      10
.equ NB_RING        11
.equ NB_RINGCAP     12
.equ NB_RINGHEAD    13
.equ NB_RINGCOUNT   14
.equ NB_RINGTOTAL   15
.equ NB_RINGWRAPS   16
.equ NB_QDENY       17
.equ NB_OOMTOT      18
.equ NB_EVICTTOT    19
.equ NB_EVICTPAGES  20
.equ NB_COLD        21
.equ NB_COLDCAP     22
.equ NB_COLDCOUNT   23
.equ NB_COLDHEAD    24
.equ NB_STATUS      25
.equ NB_SAMPLES     26
.equ NB_LASTHASH    27

; Config fields.
.equ NB_CFG_CPUS    0
.equ NB_CFG_NODES   1
.equ NB_CFG_CLASSES 2
.equ NB_CFG_HEAP    3
.equ NB_CFG_SCHED   4
.equ NB_CFG_CORES   5
.equ NB_CFG_MEM     6
.equ NB_CFG_QUOTAS  7
.equ NB_CFG_RING    8
.equ NB_CFG_RINGCAP 9
.equ NB_CFG_COLD    10
.equ NB_CFG_COLDCAP 11

; Per-core fields.
.equ NB_C_TICKS     0
.equ NB_C_TASKS     1
.equ NB_C_STEAL_IN  2
.equ NB_C_STEAL_OUT 3
.equ NB_C_MIG_IN    4
.equ NB_C_MIG_OUT   5
.equ NB_C_FAULTS    6
.equ NB_C_IPIS      7
.equ NB_C_QDEPTH    8
.equ NB_C_BUDGET    9
.equ NB_C_DEADLINE  10
.equ NB_C_STATE     11
.equ NB_C_TIMER     12
.equ NB_C_PREEMPT   13
.equ NB_C_EVENTS    14
.equ NB_C_RES       15
.equ NB_CORE_WORDS  16

; Per-(node,class) fields.
.equ NB_M_ALLOCS    0
.equ NB_M_FREES     1
.equ NB_M_LIVE_LO   2
.equ NB_M_LIVE_HI   3
.equ NB_M_BYTES_LO  4
.equ NB_M_BYTES_HI  5
.equ NB_M_EVP_LO    6
.equ NB_M_EVP_HI    7
.equ NB_M_EVB_LO    8
.equ NB_M_EVB_HI    9
.equ NB_M_OOM       10
.equ NB_M_DENY      11
.equ NB_M_HW_LO     12
.equ NB_M_HW_HI     13
.equ NB_M_EVICTS    14
.equ NB_M_RES       15
.equ NB_MEM_WORDS   16

; Quota fields.
.equ NB_Q_ACTIVE    0
.equ NB_Q_ID        1
.equ NB_Q_MAXSTEP   2
.equ NB_Q_USEDSTEP  3
.equ NB_Q_MAXTICK   4
.equ NB_Q_USEDTICK  5
.equ NB_Q_MAXMEM_LO 6
.equ NB_Q_MAXMEM_HI 7
.equ NB_Q_USEDMEM_LO 8
.equ NB_Q_USEDMEM_HI 9
.equ NB_Q_MAXKV     10
.equ NB_Q_USEDKV    11
.equ NB_Q_DENIED    12
.equ NB_Q_FLAGS     13
.equ NB_Q_RES1      14
.equ NB_Q_RES2      15
.equ NB_QUOTA_WORDS 16

.equ NB_QK_STEPS    0
.equ NB_QK_TICKS    1
.equ NB_QK_MEM      2
.equ NB_QK_KV       3

; Trace entry fields.
.equ NB_T_TICK      0
.equ NB_T_CPU       1
.equ NB_T_KIND      2
.equ NB_T_ID        3
.equ NB_T_A         4
.equ NB_T_B         5
.equ NB_T_HASH      6
.equ NB_T_SEQ       7
.equ NB_TRACE_WORDS 8

; Event kinds.
.equ NB_K_PUSH      1
.equ NB_K_POP       2
.equ NB_K_STEAL     3
.equ NB_K_MIG       4
.equ NB_K_PREEMPT   5
.equ NB_K_TICK      6
.equ NB_K_FAULT     7
.equ NB_K_IPI       8
.equ NB_K_BUDGET    9
.equ NB_K_DEADLINE  10
.equ NB_K_QUOTA     11
.equ NB_K_OOM       12
.equ NB_K_EVICT     13
.equ NB_K_SNAPSHOT  14
.equ NB_K_PRESSURE  15

; Cold ledger fields.
.equ NB_CO_NODE     0
.equ NB_CO_CLASS    1
.equ NB_CO_PAGES_LO 2
.equ NB_CO_PAGES_HI 3
.equ NB_CO_BASE_LO  4
.equ NB_CO_BASE_HI  5
.equ NB_CO_STATE    6
.equ NB_CO_RES      7
.equ NB_COLD_WORDS  8

; Health fields.
.equ NB_H_MAGIC     0
.equ NB_H_VERSION   1
.equ NB_H_CPUS      2
.equ NB_H_NODES     3
.equ NB_H_CLASSES   4
.equ NB_H_TICK      5
.equ NB_H_TICKS     6
.equ NB_H_TASKS     7
.equ NB_H_STEALS    8
.equ NB_H_MIGS      9
.equ NB_H_FAULTS    10
.equ NB_H_IPIS      11
.equ NB_H_BUDGET    12
.equ NB_H_DEADLINE  13
.equ NB_H_QDEPTH    14
.equ NB_H_ALLOCS    15
.equ NB_H_FREES     16
.equ NB_H_LIVEP_LO  17
.equ NB_H_LIVEP_HI  18
.equ NB_H_LIVEB_LO  19
.equ NB_H_LIVEB_HI  20
.equ NB_H_OOM       21
.equ NB_H_EVICTS    22
.equ NB_H_EVP_LO    23
.equ NB_H_EVP_HI    24
.equ NB_H_QDENY     25
.equ NB_H_RINGTOTAL 26
.equ NB_H_RINGWRAPS 27
.equ NB_H_STATUS    28
.equ NB_H_SAMPLES   29
.equ NB_H_RINGCOUNT 30
.equ NB_H_WORDS     32

; Hash constants.
.equ NB_HASH_SEED   0x4E424853     ; "NBHS"
.equ NB_C1          0x9E3779B9
.equ NB_C2          0x85EBCA6B
.equ NB_C3          0xC2B2AE35

; ---------------------------------------------------------------------------
; Leaf helpers.

; nb_ok r1=ctx -> 0 / -1.
nb_ok:
  CMP r1,r0
  JMP[EQ] @nb_ok_bad
  LD r2,r1,#NB_MAGIC_F
  LA r3,#NB_MAGIC
  CMP r2,r3
  JMP[NE] @nb_ok_bad
  LD r2,r1,#NB_VERSION_F
  MOVI r3,#NB_VERSION
  CMP r2,r3
  JMP[NE] @nb_ok_bad
  MOVI r1,0
  RET
nb_ok_bad:
  LA r1,0xFFFFFFFF
  RET

; nb_zero r1=addr r2=words -> 0.
nb_zero:
  CMP r2,r0
  JMP[EQ] @nb_zero_done
nb_zero_l:
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  CMP r2,r0
  JMP[NE] @nb_zero_l
nb_zero_done:
  MOVI r1,0
  RET

; nb_copy r1=src r2=dst r3=words -> 0.
nb_copy:
  CMP r3,r0
  JMP[EQ] @nb_copy_done
nb_copy_l:
  LD r4,r1,0
  ST r4,r2,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  SUB r3,r3,r13
  CMP r3,r0
  JMP[NE] @nb_copy_l
nb_copy_done:
  MOVI r1,0
  RET

; nb_core_addr r1=ctx r2=cpu -> core stats address.
nb_core_addr:
  SHL r3,r2,4
  LD r4,r1,#NB_CORES
  ADD r1,r4,r3
  RET

; nb_mem_addr r1=ctx r2=node r3=class -> mem stats address.
nb_mem_addr:
  LD r4,r1,#NB_CLASSES_F
  MUL r5,r2,r4
  ADD r5,r5,r3
  SHL r5,r5,4
  LD r4,r1,#NB_MEM
  ADD r1,r4,r5
  RET

; nb_quota_addr r1=ctx r2=agent -> quota record address.
nb_quota_addr:
  SUB r2,r2,r13
  SHL r2,r2,4
  LD r3,r1,#NB_QUOTAS
  ADD r1,r3,r2
  RET

; nb_cold_addr r1=ctx r2=index -> cold entry address.
nb_cold_addr:
  SHL r2,r2,3
  LD r3,r1,#NB_COLD
  ADD r1,r3,r2
  RET

; nb_class_bytes r1=class -> bytes per page (32-bit) or 0.
nb_class_bytes:
  CMP r1,r0
  JMP[EQ] @nb_cb_4k
  MOVI r2,1
  CMP r1,r2
  JMP[EQ] @nb_cb_2m
  MOVI r2,2
  CMP r1,r2
  JMP[EQ] @nb_cb_1g
  MOVI r1,0
  RET
nb_cb_4k:
  MOVI r1,0x1000
  RET
nb_cb_2m:
  LA r1,0x200000
  RET
nb_cb_1g:
  LA r1,0x40000000
  RET

; nb_mix r1=hash r2=word -> hash.
nb_mix:
  BOOL.6 r1,r1,r2
  LA r3,#NB_C1
  ADD r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  LA r3,#NB_C2
  MUL r1,r1,r3
  SHR r4,r1,15
  BOOL.6 r1,r1,r4
  LA r3,#NB_C3
  MUL r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  RET

; nb_cold_find r1=ctx r2=node r3=class -> index or -1.
nb_cold_find:
  LD r4,r1,#NB_COLDCAP
  LD r5,r1,#NB_COLDHEAD
  MOVI r6,0
nb_cf_loop:
  CMP r6,r4
  JMP[GE] @nb_cf_none
  ADD r7,r5,r6
  MOD r7,r7,r4
  SHL r8,r7,3
  LD r9,r1,#NB_COLD
  ADD r9,r9,r8
  LD r10,r9,#NB_CO_STATE
  CMP r10,r13
  JMP[NE] @nb_cf_next
  LD r10,r9,#NB_CO_NODE
  CMP r10,r2
  JMP[NE] @nb_cf_next
  LD r10,r9,#NB_CO_CLASS
  CMP r10,r3
  JMP[NE] @nb_cf_next
  ADD r1,r7,r0
  RET
nb_cf_next:
  ADDI r6,r6,1
  JMP @nb_cf_loop
nb_cf_none:
  LA r1,0xFFFFFFFF
  RET

; ---------------------------------------------------------------------------
; nb_core_sums r1=ctx r2=out -> 0.  out[0..8] = ticks, tasks, steals,
; migrations, faults, IPIs, budget misses, deadline misses, queue depth.
nb_core_sums:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  LD r1,r14,9
  MOVI r2,9
  CALL @nb_zero
  MOVI r8,0
  ST r8,r14,10
nb_csum_loop:
  LD r8,r14,10
  LD r6,r14,8
  LD r7,r6,#NB_CPUS
  CMP r8,r7
  JMP[GE] @nb_csum_done
  ADD r1,r6,r0
  ADD r2,r8,r0
  CALL @nb_core_addr
  ADD r10,r1,r0
  LD r7,r14,9
  LD r9,r10,#NB_C_TICKS
  LD r11,r7,0
  ADD r11,r11,r9
  ST r11,r7,0
  LD r9,r10,#NB_C_TASKS
  LD r11,r7,1
  ADD r11,r11,r9
  ST r11,r7,1
  LD r9,r10,#NB_C_STEAL_IN
  LD r11,r7,2
  ADD r11,r11,r9
  ST r11,r7,2
  LD r9,r10,#NB_C_MIG_IN
  LD r11,r7,3
  ADD r11,r11,r9
  ST r11,r7,3
  LD r9,r10,#NB_C_FAULTS
  LD r11,r7,4
  ADD r11,r11,r9
  ST r11,r7,4
  LD r9,r10,#NB_C_IPIS
  LD r11,r7,5
  ADD r11,r11,r9
  ST r11,r7,5
  LD r9,r10,#NB_C_BUDGET
  LD r11,r7,6
  ADD r11,r11,r9
  ST r11,r7,6
  LD r9,r10,#NB_C_DEADLINE
  LD r11,r7,7
  ADD r11,r11,r9
  ST r11,r7,7
  LD r9,r10,#NB_C_QDEPTH
  LD r11,r7,8
  ADD r11,r11,r9
  ST r11,r7,8
  LD r8,r14,10
  ADDI r8,r8,1
  ST r8,r14,10
  JMP @nb_csum_loop
nb_csum_done:
  MOVI r1,0
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nb_mem_sums r1=ctx r2=out -> 0.  out[0]=allocs out[1]=frees
; out[2..3]=live pages out[4..5]=live bytes out[6]=OOM out[7]=eviction
; extents out[8..9]=evicted pages.
nb_mem_sums:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  LD r1,r14,9
  MOVI r2,10
  CALL @nb_zero
  MOVI r8,0
  ST r8,r14,10
nb_msum_node:
  LD r8,r14,10
  LD r6,r14,8
  LD r7,r6,#NB_NODES
  CMP r8,r7
  JMP[GE] @nb_msum_done
  MOVI r9,0
  ST r9,r14,11
nb_msum_cls:
  LD r9,r14,11
  LD r6,r14,8
  LD r7,r6,#NB_CLASSES_F
  CMP r9,r7
  JMP[GE] @nb_msum_next
  ADD r1,r6,r0
  ADD r2,r8,r0
  ADD r3,r9,r0
  CALL @nb_mem_addr
  ADD r10,r1,r0
  LD r7,r14,9
  LD r9,r10,#NB_M_ALLOCS
  LD r11,r7,0
  ADD r11,r11,r9
  ST r11,r7,0
  LD r9,r10,#NB_M_FREES
  LD r11,r7,1
  ADD r11,r11,r9
  ST r11,r7,1
  LD r1,r7,2
  LD r2,r7,3
  LD r3,r10,#NB_M_LIVE_LO
  LD r4,r10,#NB_M_LIVE_HI
  CALL @n64_add
  ST r1,r7,2
  ST r2,r7,3
  LD r1,r7,4
  LD r2,r7,5
  LD r3,r10,#NB_M_BYTES_LO
  LD r4,r10,#NB_M_BYTES_HI
  CALL @n64_add
  ST r1,r7,4
  ST r2,r7,5
  LD r9,r10,#NB_M_OOM
  LD r11,r7,6
  ADD r11,r11,r9
  ST r11,r7,6
  LD r9,r10,#NB_M_EVICTS
  LD r11,r7,7
  ADD r11,r11,r9
  ST r11,r7,7
  LD r1,r7,8
  LD r2,r7,9
  LD r3,r10,#NB_M_EVP_LO
  LD r4,r10,#NB_M_EVP_HI
  CALL @n64_add
  ST r1,r7,8
  ST r2,r7,9
  LD r9,r14,11
  ADDI r9,r9,1
  ST r9,r14,11
  JMP @nb_msum_cls
nb_msum_next:
  LD r8,r14,10
  ADDI r8,r8,1
  ST r8,r14,10
  JMP @nb_msum_node
nb_msum_done:
  MOVI r1,0
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nb_mem_remove_live r1=ctx r2=node r3=class r4=pages_lo r5=pages_hi.
nb_mem_remove_live:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  ST r5,r14,12
  CALL @nb_mem_addr
  ST r1,r14,13
  LD r1,r14,10
  CALL @nb_class_bytes
  ST r1,r14,14
  LD r1,r14,14
  LD r2,r14,11
  LD r3,r14,12
  CALL @n64_mul32
  ST r1,r14,15
  ST r2,r14,16
  LD r6,r14,13
  LD r1,r6,#NB_M_LIVE_LO
  LD r2,r6,#NB_M_LIVE_HI
  LD r3,r14,11
  LD r4,r14,12
  CALL @n64_sub
  LD r6,r14,13
  ST r1,r6,#NB_M_LIVE_LO
  ST r2,r6,#NB_M_LIVE_HI
  LD r1,r6,#NB_M_BYTES_LO
  LD r2,r6,#NB_M_BYTES_HI
  LD r3,r14,15
  LD r4,r14,16
  CALL @n64_sub
  LD r6,r14,13
  ST r1,r6,#NB_M_BYTES_LO
  ST r2,r6,#NB_M_BYTES_HI
  MOVI r1,0
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nb_mem_account_alloc r1=ctx r2=node r3=class r4=pages_lo r5=pages_hi.
nb_mem_account_alloc:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  ST r5,r14,12
  CALL @nb_mem_addr
  ST r1,r14,13
  LD r6,r1,#NB_M_ALLOCS
  ADDI r6,r6,1
  ST r6,r1,#NB_M_ALLOCS
  LD r6,r14,13
  LD r1,r6,#NB_M_LIVE_LO
  LD r2,r6,#NB_M_LIVE_HI
  LD r3,r14,11
  LD r4,r14,12
  CALL @n64_add
  LD r6,r14,13
  ST r1,r6,#NB_M_LIVE_LO
  ST r2,r6,#NB_M_LIVE_HI
  LD r1,r14,10
  CALL @nb_class_bytes
  ST r1,r14,14
  LD r2,r14,11
  LD r3,r14,12
  CALL @n64_mul32
  ST r1,r14,15
  ST r2,r14,16
  LD r6,r14,13
  LD r1,r6,#NB_M_BYTES_LO
  LD r2,r6,#NB_M_BYTES_HI
  LD r3,r14,15
  LD r4,r14,16
  CALL @n64_add
  LD r6,r14,13
  ST r1,r6,#NB_M_BYTES_LO
  ST r2,r6,#NB_M_BYTES_HI
  LD r1,r6,#NB_M_LIVE_LO
  LD r2,r6,#NB_M_LIVE_HI
  LD r3,r6,#NB_M_HW_LO
  LD r4,r6,#NB_M_HW_HI
  CALL @n64_cmp
  CMP r1,r13
  JMP[NE] @nb_maa_done
  LD r6,r14,13
  LD r1,r6,#NB_M_LIVE_LO
  LD r2,r6,#NB_M_LIVE_HI
  ST r1,r6,#NB_M_HW_LO
  ST r2,r6,#NB_M_HW_HI
nb_maa_done:
  MOVI r1,0
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nb_mem_account_free r1=ctx r2=node r3=class r4=pages_lo r5=pages_hi.
nb_mem_account_free:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  ST r5,r14,12
  CALL @nb_mem_addr
  LD r6,r1,#NB_M_FREES
  ADDI r6,r6,1
  ST r6,r1,#NB_M_FREES
  LD r1,r14,8
  LD r2,r14,9
  LD r3,r14,10
  LD r4,r14,11
  LD r5,r14,12
  CALL @nb_mem_remove_live
  MOVI r1,0
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nb_mem_account_evict r1=ctx r2=node r3=class r4=pages_lo r5=pages_hi.
nb_mem_account_evict:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  ST r5,r14,12
  CALL @nb_mem_addr
  ST r1,r14,13
  LD r6,r14,13
  LD r1,r6,#NB_M_EVP_LO
  LD r2,r6,#NB_M_EVP_HI
  LD r3,r14,11
  LD r4,r14,12
  CALL @n64_add
  LD r6,r14,13
  ST r1,r6,#NB_M_EVP_LO
  ST r2,r6,#NB_M_EVP_HI
  LD r1,r14,10
  CALL @nb_class_bytes
  ST r1,r14,14
  LD r2,r14,11
  LD r3,r14,12
  CALL @n64_mul32
  ST r1,r14,15
  ST r2,r14,16
  LD r6,r14,13
  LD r1,r6,#NB_M_EVB_LO
  LD r2,r6,#NB_M_EVB_HI
  LD r3,r14,15
  LD r4,r14,16
  CALL @n64_add
  LD r6,r14,13
  ST r1,r6,#NB_M_EVB_LO
  ST r2,r6,#NB_M_EVB_HI
  LD r6,r6,#NB_M_EVICTS
  ADDI r6,r6,1
  LD r7,r14,13
  ST r6,r7,#NB_M_EVICTS
  LD r1,r14,8
  LD r2,r14,9
  LD r3,r14,10
  LD r4,r14,11
  LD r5,r14,12
  CALL @nb_mem_remove_live
  LD r1,r14,8
  LD r6,r1,#NB_EVICTTOT
  ADDI r6,r6,1
  ST r6,r1,#NB_EVICTTOT
  MOVI r1,0
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nb_mem_oom r1=ctx r2=node r3=class r4=pages_lo -> 0.
nb_mem_oom:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  CALL @nb_mem_addr
  LD r6,r1,#NB_M_OOM
  ADDI r6,r6,1
  ST r6,r1,#NB_M_OOM
  LD r1,r14,8
  LD r6,r1,#NB_OOMTOT
  ADDI r6,r6,1
  ST r6,r1,#NB_OOMTOT
  LD r1,r14,8
  MOVI r2,#NB_K_OOM
  LA r3,0xFFFFFFFF
  LD r4,r14,9
  LD r5,r14,10
  LD r6,r14,11
  CALL @nobs_trace
  MOVI r1,0
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nobs_init r1=ctx r2=config -> 0/-1.
nobs_init:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  CMP r1,r0
  JMP[EQ] @nb_init_bad
  CMP r2,r0
  JMP[EQ] @nb_init_bad
  LD r6,r2,#NB_CFG_CPUS
  CMP r6,r0
  JMP[EQ] @nb_init_bad
  MOVI r7,#NB_MAXCPU
  CMP r6,r7
  JMP[GT] @nb_init_bad
  LD r6,r2,#NB_CFG_NODES
  CMP r6,r0
  JMP[EQ] @nb_init_bad
  MOVI r7,#NB_MAXNODE
  CMP r6,r7
  JMP[GT] @nb_init_bad
  LD r6,r2,#NB_CFG_CLASSES
  MOVI r7,#NB_CLASSES
  CMP r6,r7
  JMP[NE] @nb_init_bad
  LD r6,r2,#NB_CFG_CORES
  CMP r6,r0
  JMP[EQ] @nb_init_bad
  LD r6,r2,#NB_CFG_MEM
  CMP r6,r0
  JMP[EQ] @nb_init_bad
  LD r6,r2,#NB_CFG_QUOTAS
  CMP r6,r0
  JMP[EQ] @nb_init_bad
  LD r6,r2,#NB_CFG_RING
  CMP r6,r0
  JMP[EQ] @nb_init_bad
  LD r6,r2,#NB_CFG_RINGCAP
  CMP r6,r0
  JMP[EQ] @nb_init_bad
  MOVI r7,32768
  CMP r6,r7
  JMP[GT] @nb_init_bad
  LD r6,r2,#NB_CFG_COLD
  CMP r6,r0
  JMP[EQ] @nb_init_bad
  LD r6,r2,#NB_CFG_COLDCAP
  CMP r6,r0
  JMP[EQ] @nb_init_bad
  MOVI r7,32768
  CMP r6,r7
  JMP[GT] @nb_init_bad
  LD r1,r14,8
  MOVI r2,32
  CALL @nb_zero
  LD r1,r14,8
  LD r2,r14,9
  LD r6,r2,#NB_CFG_CPUS
  ST r6,r1,#NB_CPUS
  LD r6,r2,#NB_CFG_NODES
  ST r6,r1,#NB_NODES
  LD r6,r2,#NB_CFG_CLASSES
  ST r6,r1,#NB_CLASSES_F
  LD r6,r2,#NB_CFG_HEAP
  ST r6,r1,#NB_HEAP
  LD r6,r2,#NB_CFG_SCHED
  ST r6,r1,#NB_SCHED
  LD r6,r2,#NB_CFG_CORES
  ST r6,r1,#NB_CORES
  LD r6,r2,#NB_CFG_MEM
  ST r6,r1,#NB_MEM
  LD r6,r2,#NB_CFG_QUOTAS
  ST r6,r1,#NB_QUOTAS
  LD r6,r2,#NB_CFG_RING
  ST r6,r1,#NB_RING
  LD r6,r2,#NB_CFG_RINGCAP
  ST r6,r1,#NB_RINGCAP
  LD r6,r2,#NB_CFG_COLD
  ST r6,r1,#NB_COLD
  LD r6,r2,#NB_CFG_COLDCAP
  ST r6,r1,#NB_COLDCAP
  LA r6,#NB_MAGIC
  ST r6,r1,#NB_MAGIC_F
  MOVI r6,#NB_VERSION
  ST r6,r1,#NB_VERSION_F
  LD r1,r14,8
  LD r1,r1,#NB_CORES
  LD r2,r14,9
  LD r2,r2,#NB_CFG_CPUS
  SHL r2,r2,4
  CALL @nb_zero
  LD r1,r14,8
  LD r1,r1,#NB_MEM
  LD r2,r14,9
  LD r2,r2,#NB_CFG_NODES
  MOVI r6,3
  MUL r2,r2,r6
  SHL r2,r2,4
  CALL @nb_zero
  LD r1,r14,8
  LD r1,r1,#NB_QUOTAS
  MOVI r2,#NB_MAXAGENT
  SHL r2,r2,4
  CALL @nb_zero
  LD r1,r14,8
  LD r1,r1,#NB_RING
  LD r2,r14,9
  LD r2,r2,#NB_CFG_RINGCAP
  SHL r2,r2,3
  CALL @nb_zero
  LD r1,r14,8
  LD r1,r1,#NB_COLD
  LD r2,r14,9
  LD r2,r2,#NB_CFG_COLDCAP
  SHL r2,r2,3
  CALL @nb_zero
  MOVI r1,0
  JMP @nb_init_out
nb_init_bad:
  LA r1,0xFFFFFFFF
nb_init_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nobs_tick r1=ctx r2=delta -> new tick.
nobs_tick:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r1,r14,8
  ST r2,r14,9
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_tick_out
  LD r1,r14,8
  LD r6,r1,#NB_TICK
  LD r2,r14,9
  ADD r6,r6,r2
  ST r6,r1,#NB_TICK
  ADD r1,r6,r0
nb_tick_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nobs_core_sample r1=ctx r2=cpu -> 0/-1.
nobs_core_sample:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_cs_bad
  LD r6,r14,8
  LD r7,r14,9
  LD r8,r6,#NB_CPUS
  CMP r7,r8
  JMP[GE] @nb_cs_bad
  ADD r1,r6,r0
  ADD r2,r7,r0
  CALL @nb_core_addr
  ST r1,r14,10
  LD r7,r14,9
  SHL r8,r7,6
  LA r9,#NC_TABLE
  ADD r8,r9,r8
  ST r8,r14,11
  LD r9,r8,#NC_STATE
  ST r9,r1,#NB_C_STATE
  LD r9,r8,#NC_QCOUNT
  ST r9,r1,#NB_C_QDEPTH
  LD r9,r8,#NC_IPI
  ST r9,r1,#NB_C_IPIS
  LD r9,r8,#NC_TIMER
  ST r9,r1,#NB_C_TIMER
  LD r9,r8,#NC_PREEMPT
  ST r9,r1,#NB_C_PREEMPT
  LD r6,r14,8
  LD r6,r6,#NB_SCHED
  CMP r6,r0
  JMP[EQ] @nb_cs_nosched
  LD r7,r14,9
  SHL r7,r7,3
  ADD r6,r6,r7
  ADDI r6,r6,#NSD_C_STATS
  ST r6,r14,12
  LD r7,r14,10
  LD r8,r6,#NSD_S_TICKS
  ST r8,r7,#NB_C_TICKS
  LD r8,r6,#NSD_S_POP
  ST r8,r7,#NB_C_TASKS
  LD r8,r6,#NSD_S_STEAL_IN
  ST r8,r7,#NB_C_STEAL_IN
  LD r8,r6,#NSD_S_STEAL_OUT
  ST r8,r7,#NB_C_STEAL_OUT
  LD r8,r6,#NSD_S_MIG_IN
  ST r8,r7,#NB_C_MIG_IN
  LD r8,r6,#NSD_S_MIG_OUT
  ST r8,r7,#NB_C_MIG_OUT
  LD r8,r6,#NSD_S_PREEMPT
  ST r8,r7,#NB_C_PREEMPT
  LD r8,r14,11
  LD r9,r6,#NSD_S_TICKS
  ST r9,r8,#NC_TICKS
  LD r9,r6,#NSD_S_PREEMPT
  ST r9,r8,#NC_PREEMPT
  JMP @nb_cs_done
nb_cs_nosched:
  LD r7,r14,10
  LD r8,r14,11
  LD r9,r8,#NC_TICKS
  ST r9,r7,#NB_C_TICKS
nb_cs_done:
  LD r1,r14,8
  LD r6,r1,#NB_SAMPLES
  ADDI r6,r6,1
  ST r6,r1,#NB_SAMPLES
  MOVI r1,0
  JMP @nb_cs_out
nb_cs_bad:
  LA r1,0xFFFFFFFF
nb_cs_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nobs_core_event r1=ctx r2=cpu r3=kind r4=amount -> 0/-1.
nobs_core_event:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_ce_bad
  LD r6,r14,8
  LD r7,r14,9
  LD r8,r6,#NB_CPUS
  CMP r7,r8
  JMP[GE] @nb_ce_bad
  LD r6,r14,10
  MOVI r7,5
  CMP r6,r7
  JMP[GT] @nb_ce_bad
  LD r1,r14,8
  LD r2,r14,9
  CALL @nb_core_addr
  ADD r9,r1,r0
  LD r6,r14,10
  LD r7,r14,11
  CMP r6,r0
  JMP[EQ] @nb_ce_fault
  CMP r6,r13
  JMP[EQ] @nb_ce_budget
  MOVI r8,2
  CMP r6,r8
  JMP[EQ] @nb_ce_deadline
  MOVI r8,3
  CMP r6,r8
  JMP[EQ] @nb_ce_ipi
  MOVI r8,4
  CMP r6,r8
  JMP[EQ] @nb_ce_timer
  LD r8,r9,#NB_C_EVENTS
  ADD r8,r8,r7
  ST r8,r9,#NB_C_EVENTS
  JMP @nb_ce_ok
nb_ce_fault:
  LD r8,r9,#NB_C_FAULTS
  ADD r8,r8,r7
  ST r8,r9,#NB_C_FAULTS
  JMP @nb_ce_ok
nb_ce_budget:
  LD r8,r9,#NB_C_BUDGET
  ADD r8,r8,r7
  ST r8,r9,#NB_C_BUDGET
  JMP @nb_ce_ok
nb_ce_deadline:
  LD r8,r9,#NB_C_DEADLINE
  ADD r8,r8,r7
  ST r8,r9,#NB_C_DEADLINE
  JMP @nb_ce_ok
nb_ce_ipi:
  LD r8,r14,9
  SHL r8,r8,6
  LA r10,#NC_TABLE
  ADD r8,r10,r8
  LD r10,r8,#NC_IPI
  ADD r10,r10,r7
  ST r10,r8,#NC_IPI
  ST r10,r9,#NB_C_IPIS
  JMP @nb_ce_ok
nb_ce_timer:
  LD r8,r14,9
  SHL r8,r8,6
  LA r10,#NC_TABLE
  ADD r8,r10,r8
  LD r10,r8,#NC_TIMER
  ADD r10,r10,r7
  ST r10,r8,#NC_TIMER
  ST r10,r9,#NB_C_TIMER
nb_ce_ok:
  MOVI r1,0
  JMP @nb_ce_out
nb_ce_bad:
  LA r1,0xFFFFFFFF
nb_ce_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nobs_core_get r1=ctx r2=cpu r3=out(16) -> 0/-1.
nobs_core_get:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_cg_bad
  LD r6,r14,8
  LD r7,r14,9
  LD r8,r6,#NB_CPUS
  CMP r7,r8
  JMP[GE] @nb_cg_bad
  LD r3,r14,10
  CMP r3,r0
  JMP[EQ] @nb_cg_bad
  ADD r1,r6,r0
  ADD r2,r7,r0
  CALL @nb_core_addr
  ADD r1,r1,r0
  LD r2,r14,10
  MOVI r3,#NB_CORE_WORDS
  CALL @nb_copy
  MOVI r1,0
  JMP @nb_cg_out
nb_cg_bad:
  LA r1,0xFFFFFFFF
nb_cg_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nobs_mem_alloc r1=ctx r2=node r3=class r4=pages_lo r5=pages_hi r6=out.
nobs_mem_alloc:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  ST r5,r14,12
  ST r6,r14,13
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_ma_bad
  LD r6,r14,8
  LD r7,r14,9
  LD r8,r6,#NB_NODES
  CMP r7,r8
  JMP[GE] @nb_ma_bad
  LD r7,r14,10
  LD r8,r6,#NB_CLASSES_F
  CMP r7,r8
  JMP[GE] @nb_ma_bad
  LD r6,r6,#NB_HEAP
  CMP r6,r0
  JMP[EQ] @nb_ma_bad
  LD r7,r14,13
  CMP r7,r0
  JMP[EQ] @nb_ma_bad
  ADD r1,r6,r0
  LD r2,r14,9
  LD r3,r14,10
  LD r4,r14,11
  LD r5,r14,12
  LD r6,r14,13
  CALL @nheap_alloc
  CMP r1,r0
  JMP[NE] @nb_ma_oom
  LD r1,r14,8
  LD r2,r14,9
  LD r3,r14,10
  LD r4,r14,11
  LD r5,r14,12
  CALL @nb_mem_account_alloc
  MOVI r1,0
  JMP @nb_ma_out
nb_ma_oom:
  LD r1,r14,8
  LD r2,r14,9
  LD r3,r14,10
  LD r4,r14,11
  CALL @nb_mem_oom
  LA r1,0xFFFFFFFF
  JMP @nb_ma_out
nb_ma_bad:
  LA r1,0xFFFFFFFF
nb_ma_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nobs_mem_free r1=ctx r2=node r3=class r4=base_lo r5=base_hi
;                r6=pages_lo r7=pages_hi -> 0/-1.
nobs_mem_free:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  ST r5,r14,12
  ST r6,r14,13
  ST r7,r14,14
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_mf_bad
  LD r6,r14,8
  LD r7,r14,9
  LD r8,r6,#NB_NODES
  CMP r7,r8
  JMP[GE] @nb_mf_bad
  LD r7,r14,10
  LD r8,r6,#NB_CLASSES_F
  CMP r7,r8
  JMP[GE] @nb_mf_bad
  LD r6,r6,#NB_HEAP
  CMP r6,r0
  JMP[EQ] @nb_mf_bad
  ADD r1,r6,r0
  LD r2,r14,9
  LD r3,r14,10
  LD r4,r14,11
  LD r5,r14,12
  LD r6,r14,13
  LD r7,r14,14
  CALL @nheap_free
  CMP r1,r0
  JMP[NE] @nb_mf_bad
  LD r1,r14,8
  LD r2,r14,9
  LD r3,r14,10
  LD r4,r14,13
  LD r5,r14,14
  CALL @nb_mem_account_free
  MOVI r1,0
  JMP @nb_mf_out
nb_mf_bad:
  LA r1,0xFFFFFFFF
nb_mf_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nobs_mem_cold r1=ctx r2=node r3=class r4=spec -> 0/-1.
nobs_mem_cold:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_mc_bad
  LD r6,r14,8
  LD r7,r14,9
  LD r8,r6,#NB_NODES
  CMP r7,r8
  JMP[GE] @nb_mc_bad
  LD r7,r14,10
  LD r8,r6,#NB_CLASSES_F
  CMP r7,r8
  JMP[GE] @nb_mc_bad
  LD r7,r14,11
  CMP r7,r0
  JMP[EQ] @nb_mc_bad
  LD r8,r6,#NB_COLDCAP
  MOVI r9,0
nb_mc_scan:
  CMP r9,r8
  JMP[GE] @nb_mc_bad
  SHL r10,r9,3
  LD r11,r6,#NB_COLD
  ADD r11,r11,r10
  LD r10,r11,#NB_CO_STATE
  CMP r10,r0
  JMP[EQ] @nb_mc_set
  ADDI r9,r9,1
  JMP @nb_mc_scan
nb_mc_set:
  LD r10,r14,9
  ST r10,r11,#NB_CO_NODE
  LD r10,r14,10
  ST r10,r11,#NB_CO_CLASS
  LD r7,r14,11
  LD r10,r7,0
  ST r10,r11,#NB_CO_PAGES_LO
  LD r10,r7,1
  ST r10,r11,#NB_CO_PAGES_HI
  LD r10,r7,2
  ST r10,r11,#NB_CO_BASE_LO
  LD r10,r7,3
  ST r10,r11,#NB_CO_BASE_HI
  ST r13,r11,#NB_CO_STATE
  LD r6,r14,8
  LD r10,r6,#NB_COLDCOUNT
  ADDI r10,r10,1
  ST r10,r6,#NB_COLDCOUNT
  MOVI r1,0
  JMP @nb_mc_out
nb_mc_bad:
  LA r1,0xFFFFFFFF
nb_mc_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nobs_mem_pressure r1=ctx r2=node r3=class r4=pages_lo r5=pages_hi.
nobs_mem_pressure:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  ST r5,r14,12
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_mp_bad
  LD r6,r14,8
  LD r7,r14,9
  LD r8,r6,#NB_NODES
  CMP r7,r8
  JMP[GE] @nb_mp_bad
  LD r7,r14,10
  LD r8,r6,#NB_CLASSES_F
  CMP r7,r8
  JMP[GE] @nb_mp_bad
  LD r6,r6,#NB_HEAP
  CMP r6,r0
  JMP[EQ] @nb_mp_bad
nb_mp_attempt:
  LD r6,r14,8
  LD r1,r6,#NB_HEAP
  LD r2,r14,9
  LD r3,r14,10
  LD r4,r14,11
  LD r5,r14,12
  ADD r6,r14,r0
  ADDI r6,r6,40
  CALL @nheap_alloc
  CMP r1,r0
  JMP[EQ] @nb_mp_ok
  LD r1,r14,8
  LD r2,r14,9
  LD r3,r14,10
  CALL @nb_cold_find
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nb_mp_deny
  ST r1,r14,20
  LD r1,r14,8
  LD r2,r14,20
  CALL @nb_cold_addr
  ST r1,r14,21
  LD r6,r1,#NB_CO_PAGES_LO
  ST r6,r14,22
  LD r6,r1,#NB_CO_PAGES_HI
  ST r6,r14,23
  LD r6,r1,#NB_CO_BASE_LO
  ST r6,r14,24
  LD r6,r1,#NB_CO_BASE_HI
  ST r6,r14,25
  LD r6,r14,8
  LD r1,r6,#NB_HEAP
  LD r2,r14,9
  LD r3,r14,10
  LD r4,r14,24
  LD r5,r14,25
  LD r6,r14,22
  LD r7,r14,23
  CALL @nheap_free
  CMP r1,r0
  JMP[NE] @nb_mp_deny
  LD r1,r14,21
  ST r0,r1,#NB_CO_STATE
  LD r6,r14,8
  LD r7,r6,#NB_COLDCOUNT
  CMP r7,r0
  JMP[EQ] @nb_mp_nocnt
  SUB r7,r7,r13
  ST r7,r6,#NB_COLDCOUNT
nb_mp_nocnt:
  LD r7,r14,20
  ADDI r7,r7,1
  LD r6,r14,8
  ST r7,r6,#NB_COLDHEAD
  LD r1,r14,8
  LD r2,r14,9
  LD r3,r14,10
  LD r4,r14,22
  LD r5,r14,23
  CALL @nb_mem_account_evict
  LD r1,r14,8
  MOVI r2,#NB_K_EVICT
  LA r3,0xFFFFFFFF
  LD r4,r14,9
  LD r5,r14,10
  LD r6,r14,22
  CALL @nobs_trace
  JMP @nb_mp_attempt
nb_mp_ok:
  LD r1,r14,8
  LD r2,r14,9
  LD r3,r14,10
  LD r4,r14,11
  LD r5,r14,12
  CALL @nb_mem_account_alloc
  MOVI r1,0
  JMP @nb_mp_out
nb_mp_deny:
  LD r1,r14,8
  LD r2,r14,9
  LD r3,r14,10
  CALL @nb_mem_addr
  LD r6,r1,#NB_M_OOM
  ADDI r6,r6,1
  ST r6,r1,#NB_M_OOM
  LD r6,r1,#NB_M_DENY
  ADDI r6,r6,1
  ST r6,r1,#NB_M_DENY
  LD r1,r14,8
  LD r6,r1,#NB_OOMTOT
  ADDI r6,r6,1
  ST r6,r1,#NB_OOMTOT
  MOVI r2,#NB_K_OOM
  LA r3,0xFFFFFFFF
  LD r4,r14,9
  LD r5,r14,10
  LD r6,r14,11
  CALL @nobs_trace
  MOVI r1,1
  JMP @nb_mp_out
nb_mp_bad:
  MOVI r1,3
nb_mp_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nobs_mem_stats r1=ctx r2=node r3=class r4=out(16) -> 0/-1.
nobs_mem_stats:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_ms_bad
  LD r6,r14,8
  LD r7,r14,9
  LD r8,r6,#NB_NODES
  CMP r7,r8
  JMP[GE] @nb_ms_bad
  LD r7,r14,10
  LD r8,r6,#NB_CLASSES_F
  CMP r7,r8
  JMP[GE] @nb_ms_bad
  LD r8,r14,11
  CMP r8,r0
  JMP[EQ] @nb_ms_bad
  ADD r1,r6,r0
  LD r2,r14,9
  LD r3,r14,10
  CALL @nb_mem_addr
  ADD r1,r1,r0
  LD r2,r14,11
  MOVI r3,#NB_MEM_WORDS
  CALL @nb_copy
  MOVI r1,0
  JMP @nb_ms_out
nb_ms_bad:
  LA r1,0xFFFFFFFF
nb_ms_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nobs_quota_set r1=ctx r2=agent r3=spec(6) -> 0/-1.
nobs_quota_set:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_qs_bad
  LD r7,r14,9
  CMP r7,r0
  JMP[EQ] @nb_qs_bad
  MOVI r8,#NB_MAXAGENT
  CMP r7,r8
  JMP[GT] @nb_qs_bad
  LD r8,r14,10
  CMP r8,r0
  JMP[EQ] @nb_qs_bad
  LD r1,r14,8
  LD r2,r14,9
  CALL @nb_quota_addr
  ADD r9,r1,r0
  ST r13,r9,#NB_Q_ACTIVE
  LD r6,r14,9
  ST r6,r9,#NB_Q_ID
  LD r6,r14,10
  LD r7,r6,0
  ST r7,r9,#NB_Q_MAXSTEP
  LD r7,r6,1
  ST r7,r9,#NB_Q_MAXTICK
  LD r7,r6,2
  ST r7,r9,#NB_Q_MAXMEM_LO
  LD r7,r6,3
  ST r7,r9,#NB_Q_MAXMEM_HI
  LD r7,r6,4
  ST r7,r9,#NB_Q_MAXKV
  LD r7,r6,5
  ST r7,r9,#NB_Q_FLAGS
  ST r0,r9,#NB_Q_USEDSTEP
  ST r0,r9,#NB_Q_USEDTICK
  ST r0,r9,#NB_Q_USEDMEM_LO
  ST r0,r9,#NB_Q_USEDMEM_HI
  ST r0,r9,#NB_Q_USEDKV
  ST r0,r9,#NB_Q_DENIED
  ST r0,r9,#NB_Q_RES1
  ST r0,r9,#NB_Q_RES2
  MOVI r1,0
  JMP @nb_qs_out
nb_qs_bad:
  LA r1,0xFFFFFFFF
nb_qs_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nobs_quota_check r1=ctx r2=agent r3=kind r4=lo r5=hi -> 0/1/3.
nobs_quota_check:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  ST r5,r14,12
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_qc_bad
  LD r7,r14,9
  CMP r7,r0
  JMP[EQ] @nb_qc_bad
  MOVI r8,#NB_MAXAGENT
  CMP r7,r8
  JMP[GT] @nb_qc_bad
  LD r8,r14,10
  MOVI r9,#NB_QK_KV
  CMP r8,r9
  JMP[GT] @nb_qc_bad
  LD r1,r14,8
  LD r2,r14,9
  CALL @nb_quota_addr
  ADD r7,r1,r0
  LD r8,r7,#NB_Q_ACTIVE
  CMP r8,r0
  JMP[EQ] @nb_qc_bad
  LD r8,r14,10
  CMP r8,r0
  JMP[EQ] @nb_qc_steps
  CMP r8,r13
  JMP[EQ] @nb_qc_ticks
  MOVI r9,2
  CMP r8,r9
  JMP[EQ] @nb_qc_mem
  ; KV
  LD r6,r7,#NB_Q_MAXKV
  CMP r6,r0
  JMP[EQ] @nb_qc_fit
  LD r8,r7,#NB_Q_USEDKV
  CMP r8,r6
  JMP[GT] @nb_qc_exceed
  SUB r6,r6,r8
  LD r8,r14,11
  CMP r8,r6
  JMP[GT] @nb_qc_exceed
  JMP @nb_qc_fit
nb_qc_steps:
  LD r6,r7,#NB_Q_MAXSTEP
  CMP r6,r0
  JMP[EQ] @nb_qc_fit
  LD r8,r7,#NB_Q_USEDSTEP
  CMP r8,r6
  JMP[GT] @nb_qc_exceed
  SUB r6,r6,r8
  LD r8,r14,11
  CMP r8,r6
  JMP[GT] @nb_qc_exceed
  JMP @nb_qc_fit
nb_qc_ticks:
  LD r6,r7,#NB_Q_MAXTICK
  CMP r6,r0
  JMP[EQ] @nb_qc_fit
  LD r8,r7,#NB_Q_USEDTICK
  CMP r8,r6
  JMP[GT] @nb_qc_exceed
  SUB r6,r6,r8
  LD r8,r14,11
  CMP r8,r6
  JMP[GT] @nb_qc_exceed
  JMP @nb_qc_fit
nb_qc_mem:
  LD r6,r7,#NB_Q_MAXMEM_LO
  LD r8,r7,#NB_Q_MAXMEM_HI
  CMP r6,r0
  JMP[NE] @nb_qc_mem_lim
  CMP r8,r0
  JMP[EQ] @nb_qc_fit
nb_qc_mem_lim:
  LD r1,r7,#NB_Q_USEDMEM_LO
  LD r2,r7,#NB_Q_USEDMEM_HI
  LD r3,r14,11
  LD r4,r14,12
  CALL @n64_add
  ADD r8,r1,r0
  ADD r9,r2,r0
  ADD r1,r8,r0
  ADD r2,r9,r0
  LD r3,r7,#NB_Q_MAXMEM_LO
  LD r4,r7,#NB_Q_MAXMEM_HI
  CALL @n64_cmp
  CMP r1,r13
  JMP[EQ] @nb_qc_exceed
  JMP @nb_qc_fit
nb_qc_fit:
  MOVI r1,0
  JMP @nb_qc_out
nb_qc_exceed:
  MOVI r1,1
  JMP @nb_qc_out
nb_qc_bad:
  MOVI r1,3
nb_qc_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nobs_quota_account r1=ctx r2=agent r3=kind r4=lo r5=hi -> 0/1/3.
nobs_quota_account:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  ST r5,r14,12
  CALL @nobs_quota_check
  CMP r1,r0
  JMP[EQ] @nb_qa_admit
  CMP r1,r13
  JMP[NE] @nb_qa_out
  LD r1,r14,8
  LD r2,r14,9
  CALL @nb_quota_addr
  ADD r7,r1,r0
  LD r6,r7,#NB_Q_DENIED
  ADDI r6,r6,1
  ST r6,r7,#NB_Q_DENIED
  LD r1,r14,8
  LD r6,r1,#NB_QDENY
  ADDI r6,r6,1
  ST r6,r1,#NB_QDENY
  MOVI r2,#NB_K_QUOTA
  LA r3,0xFFFFFFFF
  LD r4,r14,9
  LD r5,r14,10
  LD r6,r14,11
  CALL @nobs_trace
  MOVI r1,1
  JMP @nb_qa_out
nb_qa_admit:
  LD r1,r14,8
  LD r2,r14,9
  CALL @nb_quota_addr
  ADD r7,r1,r0
  LD r8,r14,10
  CMP r8,r0
  JMP[EQ] @nb_qa_steps
  CMP r8,r13
  JMP[EQ] @nb_qa_ticks
  MOVI r9,2
  CMP r8,r9
  JMP[EQ] @nb_qa_mem
  LD r6,r7,#NB_Q_USEDKV
  LD r8,r14,11
  ADD r6,r6,r8
  ST r6,r7,#NB_Q_USEDKV
  JMP @nb_qa_ok
nb_qa_steps:
  LD r6,r7,#NB_Q_USEDSTEP
  LD r8,r14,11
  ADD r6,r6,r8
  ST r6,r7,#NB_Q_USEDSTEP
  JMP @nb_qa_ok
nb_qa_ticks:
  LD r6,r7,#NB_Q_USEDTICK
  LD r8,r14,11
  ADD r6,r6,r8
  ST r6,r7,#NB_Q_USEDTICK
  JMP @nb_qa_ok
nb_qa_mem:
  LD r1,r7,#NB_Q_USEDMEM_LO
  LD r2,r7,#NB_Q_USEDMEM_HI
  LD r3,r14,11
  LD r4,r14,12
  CALL @n64_add
  ST r1,r7,#NB_Q_USEDMEM_LO
  ST r2,r7,#NB_Q_USEDMEM_HI
nb_qa_ok:
  MOVI r1,0
nb_qa_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nobs_quota_get r1=ctx r2=agent r3=out(16) -> 0/-1.
nobs_quota_get:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_qg_bad
  LD r7,r14,9
  CMP r7,r0
  JMP[EQ] @nb_qg_bad
  MOVI r8,#NB_MAXAGENT
  CMP r7,r8
  JMP[GT] @nb_qg_bad
  LD r8,r14,10
  CMP r8,r0
  JMP[EQ] @nb_qg_bad
  LD r1,r14,8
  LD r2,r14,9
  CALL @nb_quota_addr
  ADD r1,r1,r0
  LD r2,r14,10
  MOVI r3,#NB_QUOTA_WORDS
  CALL @nb_copy
  MOVI r1,0
  JMP @nb_qg_out
nb_qg_bad:
  LA r1,0xFFFFFFFF
nb_qg_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nobs_trace r1=ctx r2=kind r3=cpu r4=id r5=a r6=b -> hash / 0.
nobs_trace:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  ST r4,r14,11
  ST r5,r14,12
  ST r6,r14,13
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_tr_bad
  LD r1,r14,8
  LD r7,r1,#NB_RINGTOTAL
  ST r7,r14,14
  LD r8,r1,#NB_RINGCAP
  ST r8,r14,15
  MOD r9,r7,r8
  SHL r9,r9,3
  LD r10,r1,#NB_RING
  ADD r10,r10,r9
  ST r10,r14,16
  LD r6,r1,#NB_TICK
  ST r6,r10,#NB_T_TICK
  LD r6,r14,10
  ST r6,r10,#NB_T_CPU
  LD r6,r14,9
  ST r6,r10,#NB_T_KIND
  LD r6,r14,11
  ST r6,r10,#NB_T_ID
  LD r6,r14,12
  ST r6,r10,#NB_T_A
  LD r6,r14,13
  ST r6,r10,#NB_T_B
  LD r6,r14,14
  ST r6,r10,#NB_T_SEQ
  LA r1,#NB_HASH_SEED
  ST r1,r14,20
  LD r1,r14,8
  LD r2,r1,#NB_TICK
  LD r1,r14,20
  CALL @nb_mix
  ST r1,r14,20
  LD r1,r14,10
  ADD r2,r1,r0
  LD r1,r14,20
  CALL @nb_mix
  ST r1,r14,20
  LD r2,r14,9
  LD r1,r14,20
  CALL @nb_mix
  ST r1,r14,20
  LD r2,r14,11
  LD r1,r14,20
  CALL @nb_mix
  ST r1,r14,20
  LD r2,r14,12
  LD r1,r14,20
  CALL @nb_mix
  ST r1,r14,20
  LD r2,r14,13
  LD r1,r14,20
  CALL @nb_mix
  ST r1,r14,20
  LD r2,r14,14
  LD r1,r14,20
  CALL @nb_mix
  ST r1,r14,20
  CMP r1,r0
  JMP[NE] @nb_tr_hash
  LA r1,#NB_HASH_SEED
nb_tr_hash:
  ST r1,r14,20
  LD r6,r14,16
  ST r1,r6,#NB_T_HASH
  LD r1,r14,8
  ST r1,r14,21
  LD r1,r14,14
  ADDI r1,r1,1
  ST r1,r14,22
  LD r7,r14,8
  ST r1,r7,#NB_RINGTOTAL
  LD r8,r14,15
  CMP r1,r8
  JMP[LE] @nb_tr_nofill
  ST r8,r7,#NB_RINGCOUNT
  SUB r9,r1,r8
  ST r9,r7,#NB_RINGWRAPS
  JMP @nb_tr_head
nb_tr_nofill:
  ST r1,r7,#NB_RINGCOUNT
  ST r0,r7,#NB_RINGWRAPS
nb_tr_head:
  MOD r9,r1,r8
  ST r9,r7,#NB_RINGHEAD
  LD r6,r14,20
  ST r6,r7,#NB_LASTHASH
  ADD r1,r6,r0
  JMP @nb_tr_out
nb_tr_bad:
  MOVI r1,0
nb_tr_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nobs_trace_at r1=ctx r2=index r3=out(8) -> 0/-1.
nobs_trace_at:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_ta_bad
  LD r3,r14,10
  CMP r3,r0
  JMP[EQ] @nb_ta_bad
  LD r6,r14,8
  LD r7,r14,9
  LD r8,r6,#NB_RINGTOTAL
  CMP r7,r8
  JMP[GE] @nb_ta_bad
  LD r9,r6,#NB_RINGCAP
  CMP r8,r9
  JMP[LE] @nb_ta_live
  SUB r10,r8,r9
  CMP r7,r10
  JMP[LT] @nb_ta_bad
nb_ta_live:
  MOD r10,r7,r9
  SHL r10,r10,3
  LD r11,r6,#NB_RING
  ADD r1,r11,r10
  LD r2,r14,10
  MOVI r3,#NB_TRACE_WORDS
  CALL @nb_copy
  MOVI r1,0
  JMP @nb_ta_out
nb_ta_bad:
  LA r1,0xFFFFFFFF
nb_ta_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nobs_trace_snapshot r1=ctx r2=out r3=max -> entries copied.
nobs_trace_snapshot:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  ST r3,r14,10
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_ts_zero
  LD r6,r14,9
  CMP r6,r0
  JMP[EQ] @nb_ts_zero
  LD r6,r14,8
  LD r7,r6,#NB_RINGTOTAL
  LD r8,r6,#NB_RINGCAP
  CMP r7,r8
  JMP[LE] @nb_ts_count_ok
  ADD r7,r8,r0
nb_ts_count_ok:
  LD r9,r14,10
  CMP r7,r9
  JMP[LE] @nb_ts_max_ok
  ADD r7,r9,r0
nb_ts_max_ok:
  ST r7,r14,11
  LD r10,r6,#NB_RINGTOTAL
  SUB r9,r10,r7
  ST r9,r14,12
  MOVI r8,0
  ST r8,r14,13
nb_ts_loop:
  LD r8,r14,13
  LD r7,r14,11
  CMP r8,r7
  JMP[GE] @nb_ts_done
  LD r9,r14,12
  ADD r9,r9,r8
  LD r10,r14,8
  LD r10,r10,#NB_RINGCAP
  MOD r9,r9,r10
  SHL r9,r9,3
  LD r10,r14,8
  LD r10,r10,#NB_RING
  ADD r1,r10,r9
  LD r2,r14,9
  SHL r8,r8,3
  ADD r2,r2,r8
  MOVI r3,#NB_TRACE_WORDS
  CALL @nb_copy
  LD r8,r14,13
  ADDI r8,r8,1
  ST r8,r14,13
  JMP @nb_ts_loop
nb_ts_done:
  LD r1,r14,11
  JMP @nb_ts_out
nb_ts_zero:
  MOVI r1,0
nb_ts_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; nobs_trace_last r1=ctx r2=out(8) -> 0/-1.
nobs_trace_last:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r1,r14,8
  ST r2,r14,9
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_tl_bad
  LD r1,r14,8
  LD r6,r1,#NB_RINGTOTAL
  CMP r6,r0
  JMP[EQ] @nb_tl_bad
  SUB r2,r6,r13
  LD r3,r14,9
  CALL @nobs_trace_at
  JMP @nb_tl_out
nb_tl_bad:
  LA r1,0xFFFFFFFF
nb_tl_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nobs_health r1=ctx r2=out(32) -> 0/-1.
nobs_health:
  ST r15,r14,0
  ADDI r14,r14,#NB_FRAME
  ST r6,r14,1
  ST r7,r14,2
  ST r8,r14,3
  ST r9,r14,4
  ST r10,r14,5
  ST r11,r14,6
  ST r12,r14,7
  ST r1,r14,8
  ST r2,r14,9
  CALL @nb_ok
  CMP r1,r0
  JMP[NE] @nb_h_bad
  LD r7,r14,9
  CMP r7,r0
  JMP[EQ] @nb_h_bad
  ADD r1,r7,r0
  MOVI r2,#NB_H_WORDS
  CALL @nb_zero
  LD r6,r14,8
  LD r7,r14,9
  LA r8,#NB_HMAGIC
  ST r8,r7,#NB_H_MAGIC
  MOVI r8,#NB_VERSION
  ST r8,r7,#NB_H_VERSION
  LD r8,r6,#NB_CPUS
  ST r8,r7,#NB_H_CPUS
  LD r8,r6,#NB_NODES
  ST r8,r7,#NB_H_NODES
  LD r8,r6,#NB_CLASSES_F
  ST r8,r7,#NB_H_CLASSES
  LD r8,r6,#NB_TICK
  ST r8,r7,#NB_H_TICK
  ADD r1,r6,r0
  ADD r2,r7,r0
  ADDI r2,r2,#NB_H_TICKS
  CALL @nb_core_sums
  LD r6,r14,8
  LD r7,r14,9
  ADD r1,r6,r0
  ADD r2,r7,r0
  ADDI r2,r2,#NB_H_ALLOCS
  CALL @nb_mem_sums
  LD r6,r14,8
  LD r7,r14,9
  LD r8,r6,#NB_QDENY
  ST r8,r7,#NB_H_QDENY
  LD r8,r6,#NB_RINGTOTAL
  ST r8,r7,#NB_H_RINGTOTAL
  LD r8,r6,#NB_RINGWRAPS
  ST r8,r7,#NB_H_RINGWRAPS
  LD r8,r6,#NB_SAMPLES
  ST r8,r7,#NB_H_SAMPLES
  LD r8,r6,#NB_RINGCOUNT
  ST r8,r7,#NB_H_RINGCOUNT
  MOVI r9,0
  LD r8,r7,#NB_H_BUDGET
  CMP r8,r0
  JMP[NE] @nb_h_degraded
  LD r8,r7,#NB_H_DEADLINE
  CMP r8,r0
  JMP[NE] @nb_h_degraded
  LD r8,r7,#NB_H_EVICTS
  CMP r8,r0
  JMP[NE] @nb_h_degraded
  LD r8,r7,#NB_H_QDENY
  CMP r8,r0
  JMP[NE] @nb_h_degraded
  JMP @nb_h_status
nb_h_degraded:
  MOVI r9,1
nb_h_status:
  LD r8,r7,#NB_H_OOM
  CMP r8,r0
  JMP[EQ] @nb_h_store
  MOVI r9,2
nb_h_store:
  ST r9,r7,#NB_H_STATUS
  MOVI r1,0
  JMP @nb_h_out
nb_h_bad:
  LA r1,0xFFFFFFFF
nb_h_out:
  LD r6,r14,1
  LD r7,r14,2
  LD r8,r14,3
  LD r9,r14,4
  LD r10,r14,5
  LD r11,r14,6
  LD r12,r14,7
  ADDI r14,r14,#NB_FN
  LD r15,r14,0
  RET
