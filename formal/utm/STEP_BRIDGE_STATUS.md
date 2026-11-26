# Literal executor -> Coq VM step bridge

Verified one-step refinements in `MinskyNaN16LiteralStepBridge.v`:

| Opcode | Theorem | Main CI |
| --- | --- | --- |
| MOVI | `lp_exec_MOVI_refines` | PASS |
| LD | `lp_exec_LD_refines` | PASS |
| HALT | `lp_exec_HALT_refines` | PASS |
| PUTC | `lp_exec_PUTC_refines` | PASS |
| RET | `lp_exec_RET_refines` | PASS |
| CALL | `lp_exec_CALL_refines` (explicit link invariant) | PASS |

All six preserve the full `Rlp` relation, including the opaque memory
view, register bounds, flags, halt state and the link register.

## Remaining opcodes

- CMP / JMP: need `N.eqb`/`N.ltb` agreement with the `nat` VM flags and
  the `pred_agrees` side condition `k <> 3`.
- ST: needs the `nan_mkwordN` / `nan_mkword` payload bridge and memory
  update agreement.
- SHL / ADD / SUB: need explicit 32-bit no-overflow/no-borrow
  invariants.
- SHR, BOOL, RETP: shift/truth-table/predicate agreement.
- Then: a supported-instruction dispatcher and an inductive run
  theorem from `lp_run` to the VM.

## Fast debug

`.github/workflows/nan0s-formal-utm-debug.yml` downloads the complete
`.vo` object graph from a successful main run and compiles only the two
bridge modules.
