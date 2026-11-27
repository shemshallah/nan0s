; nansched_nansmp.nas - bind the F2 per-CPU scheduler ops table to nansmp.
;
; Include after src/lib/nansmp.nas and src/lib/nansched_mp.nas, then call
; nsched_bind_nansmp(ctx).  The caller-provided ops table must be at least
; NSD_OP_WORDS (6) words and must already be stored in ctx[NSD_C_OPS].
;
; Every primitive is the real nansmp ABI from spec/SMP.md:
;   nsp_cas        atomic compare-and-swap over a guest word
;   nsp_fetch_add  atomic payload fetch-add preserving the NaN heads
;   nsp_fence      sequentially consistent mfence
;   nsp_trylock    CAS spinlock acquisition
;   nsp_unlock     release + fence
;   nsp_ipi        reschedule IPI to a target logical CPU
;
; No scheduling policy lives here; the table is the only replacement point
; between the simulated gate and an AP boot.

; nsched_bind_nansmp ctx -> 0/3.
nsched_bind_nansmp:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r14,1
  CMP r1,r0
  JMP[EQ] @nsd_bind_bad
  LD r2,r1,#NSD_C_OPS
  CMP r2,r0
  JMP[EQ] @nsd_bind_bad
  LA r3,@nsp_cas
  ST r3,r2,#NSD_OP_CAS
  LA r3,@nsp_fetch_add
  ST r3,r2,#NSD_OP_FADD
  LA r3,@nsp_fence
  ST r3,r2,#NSD_OP_FENCE
  LA r3,@nsp_trylock
  ST r3,r2,#NSD_OP_LOCK
  LA r3,@nsp_unlock
  ST r3,r2,#NSD_OP_UNLOCK
  LA r3,@nsp_ipi
  ST r3,r2,#NSD_OP_IPI
  MOVI r1,0
  JMP @nsd_bind_out
nsd_bind_bad:
  MOVI r1,#NSD_BAD
nsd_bind_out:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET
