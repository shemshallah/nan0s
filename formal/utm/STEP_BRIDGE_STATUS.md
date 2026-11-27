# Literal executor -> Coq VM step bridge

Verified one-step refinements in `MinskyNaN16LiteralStepBridge.v`:

| Opcode | Theorem | Main CI |
| --- | --- | --- |
| MOVI | `lp_exec_MOVI_refines` | PASS |
| LD | `lp_exec_LD_refines` (including `d = 15`) | PASS |
| ST | `lp_exec_ST_refines` (requires `MemP_wf` and address `< 4366`) | PASS |
| HALT | `lp_exec_HALT_refines` | PASS |
| PUTC | `lp_exec_PUTC_refines` | PASS |
| RET | `lp_exec_RET_refines` | PASS |
| CALL | `lp_exec_CALL_refines` | PASS |
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

## Link reconciliation

The native calling convention keeps the return address in `r15`.  The
extended Coq model in `MinskyNaN16LiteralExec.v` now mirrors that:

- `pCALL` writes both `vm_link` and `vm_reg 15`;
- `pLD` with `d = 15` restores both.

This is the D-16 reconciliation needed by the fixture's
save/restore sequences.  The universality development continues to use
`exec_instr` and is unchanged.  The earlier `d <> 15` restriction on
LD and the explicit CALL link precondition are gone.

## Dispatcher

`LPInstrSide` collects the opcode-specific side conditions, and

    lp_exec_instr_refines :
      Rlp L vm ->
      length (lp_reg L) = 16 ->
      MemP_wf (lp_mem L) ->
      LPInstrSide L vm ins ->
      decode_word_p (lp_mem_at L (lp_pc L)) = Some ins ->
      nth_error prog (vm_pc vm) = Some ins ->
      Rlp (lp_exec L ins) (exec_instr_p prog vm)

selects the matching row of the one-step table.  `lp_exec_reg_length`
and `lp_exec_mem_wf` show that the two run invariants survive every
instruction.

## Inductive run

`lp_run_safe` is the step-indexed safety certificate; `vm_run_p` is the
matching Coq-VM runner.  The run theorem

    lp_run_refines :
      Rlp L vm ->
      length (lp_reg L) = 16 ->
      MemP_wf (lp_mem L) ->
      lp_run_safe fuel L prog ->
      Rlp (lp_run fuel L) (vm_run_p fuel prog vm) /\
      length (lp_reg (lp_run fuel L)) = 16 /\
      MemP_wf (lp_mem (lp_run fuel L))

is proved by induction on the fuel, so the literal executor and the VM
halt and step in lockstep.  The safety certificate is LP-only: it never
steps the VM, which keeps the concrete fixture check within the
reducer's reach.

## Remaining work

- Reflect `lp_run_safe` into a boolean checker and evaluate
  `lp_run_check 21025 lp_reset fixture_prog_full`.  The certificate is
  already LP-only, so this is a pure computation; the reflection proof
  should be kept per-opcode to keep the kernel term small.
- Lift the run theorem to the universality statement.

## Fast debug

`.github/workflows/nan0s-formal-utm-debug.yml` downloads the complete
`.vo` object graph from a successful main run and compiles
`MinskyNaN16LiteralExec`, `MinskyNaN16LiteralMemory`,
`MinskyNaN16LiteralBridge` and `MinskyNaN16LiteralStepBridge`.
