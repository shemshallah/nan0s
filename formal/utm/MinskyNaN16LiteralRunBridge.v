(** * Final VM state of the fixture run

    [MinskyNaN16LiteralStepBridge.fixture_lp_run_refines] relates the
    full 21,025-instruction literal run to the Coq VM through [Rlp].
    [MinskyNaN16LiteralRun.literal_full_run_pass] gives the final literal
    cells.  This module projects the VM side: PC, halt flag, [r1], and
    the three published control cells. *)

From Coq Require Import List Arith Bool Lia NArith String.
Import ListNotations.
Open Scope nat_scope.

From NaNLM Require Import MinskyNaN16VM MinskyNaN16LiteralMachine
  MinskyNaN16LiteralBridge MinskyNaN16LiteralStepBridge
  MinskyNaN16LiteralRun MinskyNaN16LiteralPuts MinskyNaN16Action.

Theorem fixture_vm_final :
  vm_pc (vm_run_p 21025 fixture_prog_full (vm_of_lp lp_reset)) = 28 /\
  vm_halted (vm_run_p 21025 fixture_prog_full (vm_of_lp lp_reset)) = true /\
  vm_reg (vm_run_p 21025 fixture_prog_full (vm_of_lp lp_reset)) 1 = 4357 /\
  vm_mem (vm_run_p 21025 fixture_prog_full (vm_of_lp lp_reset))
    action_state_addr = 2 /\
  vm_mem (vm_run_p 21025 fixture_prog_full (vm_of_lp lp_reset))
    action_head_addr = 166 /\
  vm_mem (vm_run_p 21025 fixture_prog_full (vm_of_lp lp_reset))
    action_halt_addr = 0.
Proof.
  destruct fixture_lp_run_refines as (HR & _ & _).
  pose proof literal_full_run_pass as Hlit.
  destruct Hlit as
    (Hhalt & Hpc & Hstate & Hhead & Hhhalt & _ & Hr1 & _).
  unfold Rlp in HR.
  destruct HR as
    (HpcR & Hregs & _ & _ & Hmem & _ & _ & _ & HhaltR & _).
  split.
  - rewrite HpcR. exact Hpc.
  - split.
    + rewrite HhaltR. exact Hhalt.
    + split.
      * assert (H1 : 1 < 15) by lia.
        rewrite (Hregs 1 H1).
        change (lget_reg (lp_reg (lp_run 21025 lp_reset)) 1 mod 2 ^ 32 =
                4357).
        rewrite Hr1.
        apply Nat.mod_small.
        pose proof le_256_two32. lia.
      * split.
        -- rewrite (Hmem action_state_addr).
           rewrite lp_mem_at_eq. exact Hstate.
        -- split.
           ++ rewrite (Hmem action_head_addr).
              rewrite lp_mem_at_eq. exact Hhead.
           ++ rewrite (Hmem action_halt_addr).
              rewrite lp_mem_at_eq. exact Hhhalt.
Qed.

Print Assumptions fixture_vm_final.
