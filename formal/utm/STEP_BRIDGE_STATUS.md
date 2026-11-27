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
      lp_run_safe fuel L vm prog ->
      Rlp (lp_run fuel L) (vm_run_p fuel prog vm) /\
      length (lp_reg (lp_run fuel L)) = 16 /\
      MemP_wf (lp_mem (lp_run fuel L))

is proved by induction on the fuel, so the literal executor and the VM
halt and step in lockstep.

## Link-register caveat

The CALL row of `LPInstrSide` includes the precondition of
`lp_exec_CALL_refines`:

    vm_reg vm 15 = S (lp_pc L).

The abstract VM's `pCALL` writes `vm_link` but leaves `vm_reg 15`
unchanged, while the literal `pCALL` writes the return address into
`r15`.  The run certificate therefore needs every CALL site to
establish this equation before the call.  The fixture's first CALL is
at pc 6, after a prelude that leaves `r15 = 0`, so the equation fails
there; this is recorded by `fixture_first_call_link_fails` (proved by
computation).  Consequently the 21,025-step concrete certificate is
not derivable from the current `R` without reconciling `r15` with
`vm_link` (or changing the VM CALL/RET equations).  The one-step and
run theorems above remain valid under the stated invariant; this is a
model-reconciliation task for the next layer, not a gap in the checked
proofs.

## Remaining work

- Reconcile the `r15` / `vm_link` calling convention.
- Then discharge `lp_run_safe 21025 lp_reset (vm_of_lp lp_reset)
  fixture_prog_full` by a reflected (boolean) certificate.  The current
  certificate is a `Prop`; the concrete fixture run needs a computable
  checker plus its soundness lemma.
- Lift the run theorem to the universality statement.

## Fast debug

`.github/workflows/nan0s-formal-utm-debug.yml` downloads the complete
`.vo` object graph from a successful main run and compiles only the
`Memory`, `Bridge` and `StepBridge` modules.
