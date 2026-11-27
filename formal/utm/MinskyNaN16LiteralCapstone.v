(** * Capstone: the fixture run refines the VM and reaches the published state

    This packages the concrete [Rlp] bridge with the already-certified
    literal postconditions.  The proof projects only the literal state;
    it never rewrites through the 21,025-step [vm_run_p] term. *)

From Coq Require Import List Arith Bool Lia NArith String.
Import ListNotations.
Open Scope nat_scope.

From NaNLM Require Import MinskyNaN16VM MinskyNaN16LiteralMachine
  MinskyNaN16LiteralDecode MinskyNaN16LiteralBridge
  MinskyNaN16LiteralStepBridge MinskyNaN16LiteralRun
  MinskyNaN16LiteralPuts MinskyNaN16Action.

Theorem fixture_bridge_and_final :
  Rlp (lp_run 21025 lp_reset)
      (vm_run_p 21025 fixture_prog_full (vm_of_lp lp_reset)) /\
  lp_halted (lp_run 21025 lp_reset) = true /\
  lp_pc (lp_run 21025 lp_reset) = 28 /\
  payload_word (mem_get (lp_mem (lp_run 21025 lp_reset)) action_state_addr) = 2 /\
  payload_word (mem_get (lp_mem (lp_run 21025 lp_reset)) action_head_addr) = 166 /\
  payload_word (mem_get (lp_mem (lp_run 21025 lp_reset)) action_halt_addr) = 0 /\
  lget_reg (lp_reg (lp_run 21025 lp_reset)) 1 = 4357.
Proof.
  destruct fixture_lp_run_refines as (HR & _ & _).
  destruct literal_full_run_pass as
    (Hhalt & Hpc & Hstate & Hhead & Hhhalt & _ & Hr1 & _).
  split.
  - exact HR.
  - split.
    + exact Hhalt.
    + split.
      * exact Hpc.
      * split.
        -- exact Hstate.
        -- split.
           ++ exact Hhead.
           ++ split.
              ** exact Hhhalt.
              ** exact Hr1.
Qed.

Print Assumptions fixture_bridge_and_final.
