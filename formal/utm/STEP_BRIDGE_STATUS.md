# Literal executor -> Coq VM step bridge

Verified one-step refinements in `MinskyNaN16LiteralStepBridge.v`:

| Opcode | Theorem | Main CI |
| --- | --- | --- |
| MOVI | `lp_exec_MOVI_refines` | PASS |
| LD | `lp_exec_LD_refines` | PASS |
| ST | `lp_exec_ST_refines` (requires `MemP_wf` and address `< 4366`) | PASS |
| HALT | `lp_exec_HALT_refines` | PASS |
| PUTC | `lp_exec_PUTC_refines` | PASS |
| RET | `lp_exec_RET_refines` | PASS |
| CALL | `lp_exec_CALL_refines` (explicit link invariant) | PASS |
| CMP | `lp_exec_CMP_refines` | PASS |
| JMP | `lp_exec_JMP_refines` (requires `k <> 3`) | PASS |
| RETP | `lp_exec_RETP_refines` (requires `k <> 3`) | PASS |
| SHR | `lp_exec_SHR_refines` | PASS |
| ADD | `lp_exec_ADD_refines` (no-carry) | PASS |
| SUB | `lp_exec_SUB_refines` (no-borrow) | PASS |
| SHL | `lp_exec_SHL_refines` (no-overflow) | PASS |
| BOOL.8/255 | `lp_exec_BOOL8_255_refines` | PASS |

All one-step theorems preserve the full `Rlp` relation, including the
opaque memory view, register bounds, flags, halt state and the link
register.  The ST case additionally uses the block invariant
`MemP_wf` and the fixture address bound to project the total memory
update through `mem_get_mem_set_eq` / `mem_get_mem_set_neq_all`.

## Remaining work

- A supported-instruction dispatcher (`decode_word_p` chooses the
  opcode-specific theorem, with its side conditions).
- An inductive run theorem from `lp_run` / `literal_step_p` to the
  Coq VM, including `MemP_wf` maintenance across the whole run.
- Lift that run theorem to the universality statement.

## Fast debug

`.github/workflows/nan0s-formal-utm-debug.yml` downloads the complete
`.vo` object graph from a successful main run and compiles only the
`Memory`, `Bridge` and `StepBridge` modules.
