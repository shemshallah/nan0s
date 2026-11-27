(** * First literal-executor step refinement: MOVI

    This module starts the [LPState] -> Coq VM one-step simulation.  It
    proves the register-file update lemmas and the MOVI case, with no
    memory normalization: [lp_mem_at] is opaque and the MOVI memory
    preservation is a separate checked equality. *)

From Coq Require Import List Arith Bool Lia NArith String.
Import ListNotations.
Open Scope nat_scope.

From NaNLM Require Import MinskyNaN16VM MinskyNaN16LiteralMachine
  MinskyNaN16LiteralDecode MinskyNaN16LiteralPuts MinskyNaN16LiteralExec
  MinskyNaN16LiteralBridge MinskyNaN16LiteralMemory.

(** ** Register-file update lemmas *)

Lemma lset_word_length :
  forall r i v, List.length (lset_word r i v) = List.length r.
Proof.
  intros r. induction r as [|x xs IH]; intros i v.
  - reflexivity.
  - destruct i; simpl; [reflexivity|rewrite IH; reflexivity].
Qed.

Lemma lget_regN_lset_word_eq :
  forall r i v,
    i < List.length r ->
    lget_regN (lset_word r i v) i = v.
Proof.
  intros r. induction r as [|x xs IH]; intros i v Hi.
  - simpl in Hi. lia.
  - destruct i as [|i].
    + reflexivity.
    + simpl. apply IH. simpl in Hi. lia.
Qed.

Lemma lget_regN_lset_word_neq :
  forall r i v j,
    j <> i ->
    lget_regN (lset_word r i v) j = lget_regN r j.
Proof.
  intros r. induction r as [|x xs IH]; intros i v j Hneq.
  - destruct i, j; simpl; reflexivity.
  - destruct i as [|i], j as [|j].
    + exfalso. apply Hneq. reflexivity.
    + reflexivity.
    + reflexivity.
    + simpl. apply IH. intro H. apply Hneq. now f_equal.
Qed.

Lemma l_k_lp_to_LState :
  forall L, l_k (lp_to_LState L) = lp_k L.
Proof. intros L. reflexivity. Qed.

Ltac split_conj_step := repeat match goal with |- _ /\ _ => split end.

(** ** MOVI one-step refinement *)

Theorem lp_exec_MOVI_refines :
  forall L vm prog d imm,
    Rlp L vm ->
    List.length (lp_reg L) = 16 ->
    d < 16 ->
    d <> 15 ->
    imm < 2 ^ 32 ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some (pMOVI d imm) ->
    nth_error prog (vm_pc vm) = Some (pMOVI d imm) ->
    Rlp (lp_exec L (pMOVI d imm)) (exec_instr_p prog vm).
Proof.
  intros L vm prog d imm HR Hlen Hd Hd15 Himm Hdec Hnth.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  unfold lp_exec, exec_instr_p.
  rewrite Hnth.
  cbn.
  unfold R, lp_to_LState.
  split_conj_step.
  - change (S (vm_pc vm) = S (lp_pc L)).
    rewrite Hpc. reflexivity.
  - intros i Hi.
    change (set_reg (vm_reg vm) d imm i =
            N.to_nat (lget_regN (lset_word (lp_reg L) d (N.of_nat imm)) i)
              mod 2 ^ 32).
    destruct (Nat.eq_dec i d) as [-> | Hne].
    + rewrite set_reg_eq.
      rewrite (lget_regN_lset_word_eq (lp_reg L) d (N.of_nat imm))
        by (rewrite Hlen; lia).
      rewrite Nat2N.id.
      rewrite Nat.mod_small by exact Himm. reflexivity.
    + rewrite (set_reg_neq _ _ _ _ Hne).
      rewrite (lget_regN_lset_word_neq (lp_reg L) d (N.of_nat imm) i Hne).
      exact (Hregs i Hi).
  - change (set_reg (vm_reg vm) d imm 15 =
            N.to_nat (lget_regN (lset_word (lp_reg L) d (N.of_nat imm)) 15)
              mod 2 ^ 32).
    rewrite (set_reg_neq _ _ _ _ (not_eq_sym Hd15)).
    rewrite (lget_regN_lset_word_neq (lp_reg L) d (N.of_nat imm) 15
      (not_eq_sym Hd15)).
    exact Hreg15.
  - change (vm_link vm =
            N.to_nat (lget_regN (lset_word (lp_reg L) d (N.of_nat imm)) 15)).
    rewrite (lget_regN_lset_word_neq (lp_reg L) d (N.of_nat imm) 15
      (not_eq_sym Hd15)).
    exact Hlink.
  - intro a.
    change (vm_mem vm a =
            payload_word (lp_mem_at (lp_exec L (pMOVI d imm)) a)).
    rewrite lp_mem_at_lp_exec_MOVI.
    exact (Hmem a).
  - change (vm_zf vm = Nat.eqb ((lp_k L / 2) mod 2) 1).
    exact Hzf.
  - change (vm_lf vm = Nat.eqb (lp_k L mod 2) 1).
    exact Hlf.
  - change (lp_k L < 4). exact Hk.
  - change (vm_halted vm = lp_halted L). exact Hhalt.
  - intros i Hi.
    change (N.to_nat (lget_regN (lset_word (lp_reg L) d (N.of_nat imm)) i)
            < 2 ^ 32).
    destruct (Nat.eq_dec i d) as [-> | Hne].
    + rewrite (lget_regN_lset_word_eq (lp_reg L) d (N.of_nat imm))
        by (rewrite Hlen; lia).
      rewrite Nat2N.id. exact Himm.
    + rewrite (lget_regN_lset_word_neq (lp_reg L) d (N.of_nat imm) i Hne).
      exact (Hbound i Hi).
Qed.

Print Assumptions lp_exec_MOVI_refines.

(** ** HALT *)

Theorem lp_exec_HALT_refines :
  forall L vm prog,
    Rlp L vm ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some pHALT ->
    nth_error prog (vm_pc vm) = Some pHALT ->
    Rlp (lp_exec L pHALT) (exec_instr_p prog vm).
Proof.
  intros L vm prog HR Hdec Hnth.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  unfold lp_exec, exec_instr_p.
  rewrite Hnth. cbn.
  unfold R, lp_to_LState.
  split_conj_step.
  - change (vm_pc vm = lp_pc L). exact Hpc.
  - intros i Hi.
    change (vm_reg vm i = N.to_nat (lget_regN (lp_reg L) i) mod 2 ^ 32).
    exact (Hregs i Hi).
  - change (vm_reg vm 15 =
            N.to_nat (lget_regN (lp_reg L) 15) mod 2 ^ 32).
    exact Hreg15.
  - change (vm_link vm = N.to_nat (lget_regN (lp_reg L) 15)).
    exact Hlink.
  - intro a.
    change (vm_mem vm a = payload_word (lp_mem_at (lp_exec L pHALT) a)).
    rewrite lp_mem_at_lp_exec_HALT. exact (Hmem a).
  - change (vm_zf vm = Nat.eqb ((lp_k L / 2) mod 2) 1). exact Hzf.
  - change (vm_lf vm = Nat.eqb (lp_k L mod 2) 1). exact Hlf.
  - change (lp_k L < 4). exact Hk.
  - change (true = true). reflexivity.
  - intros i Hi.
    change (N.to_nat (lget_regN (lp_reg L) i) < 2 ^ 32).
    exact (Hbound i Hi).
Qed.

(** ** PUTC *)

Theorem lp_exec_PUTC_refines :
  forall L vm prog d,
    Rlp L vm ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some (pPUTC d) ->
    nth_error prog (vm_pc vm) = Some (pPUTC d) ->
    Rlp (lp_exec L (pPUTC d)) (exec_instr_p prog vm).
Proof.
  intros L vm prog d HR Hdec Hnth.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  unfold lp_exec, exec_instr_p.
  rewrite Hnth. cbn.
  unfold R, lp_to_LState.
  split_conj_step.
  - change (S (vm_pc vm) = S (lp_pc L)). rewrite Hpc. reflexivity.
  - intros i Hi.
    change (vm_reg vm i = N.to_nat (lget_regN (lp_reg L) i) mod 2 ^ 32).
    exact (Hregs i Hi).
  - change (vm_reg vm 15 =
            N.to_nat (lget_regN (lp_reg L) 15) mod 2 ^ 32).
    exact Hreg15.
  - change (vm_link vm = N.to_nat (lget_regN (lp_reg L) 15)).
    exact Hlink.
  - intro a.
    change (vm_mem vm a = payload_word (lp_mem_at (lp_exec L (pPUTC d)) a)).
    rewrite lp_mem_at_lp_exec_PUTC. exact (Hmem a).
  - change (vm_zf vm = Nat.eqb ((lp_k L / 2) mod 2) 1). exact Hzf.
  - change (vm_lf vm = Nat.eqb (lp_k L mod 2) 1). exact Hlf.
  - change (lp_k L < 4). exact Hk.
  - change (vm_halted vm = lp_halted L). exact Hhalt.
  - intros i Hi.
    change (N.to_nat (lget_regN (lp_reg L) i) < 2 ^ 32).
    exact (Hbound i Hi).
Qed.

(** ** RET *)

Theorem lp_exec_RET_refines :
  forall L vm prog,
    Rlp L vm ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some pRET ->
    nth_error prog (vm_pc vm) = Some pRET ->
    Rlp (lp_exec L pRET) (exec_instr_p prog vm).
Proof.
  intros L vm prog HR Hdec Hnth.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  unfold lp_exec, exec_instr_p.
  rewrite Hnth. cbn.
  unfold R, lp_to_LState.
  split_conj_step.
  - change (vm_link vm = N.to_nat (lget_regN (lp_reg L) 15)). exact Hlink.
  - intros i Hi.
    change (vm_reg vm i = N.to_nat (lget_regN (lp_reg L) i) mod 2 ^ 32).
    exact (Hregs i Hi).
  - change (vm_reg vm 15 =
            N.to_nat (lget_regN (lp_reg L) 15) mod 2 ^ 32).
    exact Hreg15.
  - change (vm_link vm = N.to_nat (lget_regN (lp_reg L) 15)). exact Hlink.
  - intro a.
    change (vm_mem vm a = payload_word (lp_mem_at (lp_exec L pRET) a)).
    rewrite lp_mem_at_lp_exec_RET. exact (Hmem a).
  - change (vm_zf vm = Nat.eqb ((lp_k L / 2) mod 2) 1). exact Hzf.
  - change (vm_lf vm = Nat.eqb (lp_k L mod 2) 1). exact Hlf.
  - change (lp_k L < 4). exact Hk.
  - change (vm_halted vm = lp_halted L). exact Hhalt.
  - intros i Hi.
    change (N.to_nat (lget_regN (lp_reg L) i) < 2 ^ 32).
    exact (Hbound i Hi).
Qed.

Print Assumptions lp_exec_HALT_refines.
Print Assumptions lp_exec_PUTC_refines.
Print Assumptions lp_exec_RET_refines.

(** ** LD *)

Theorem lp_exec_LD_refines :
  forall L vm prog d a imm,
    Rlp L vm ->
    List.length (lp_reg L) = 16 ->
    d < 16 ->
    d <> 15 ->
    a < 16 ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some (pLD d a imm) ->
    nth_error prog (vm_pc vm) = Some (pLD d a imm) ->
    Rlp (lp_exec L (pLD d a imm)) (exec_instr_p prog vm).
Proof.
  intros L vm prog d a imm HR Hlen Hd Hd15 Ha Hdec Hnth.
  pose proof HR as HR_R.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  pose proof (R_reg_eq (lp_to_LState L) vm a HR_R Ha) as Hreg_a.
  assert (Haddr : vm_reg vm a = lget_reg (lp_reg L) a).
  { unfold lget_reg. exact Hreg_a. }
  unfold lp_exec, exec_instr_p.
  rewrite Hnth. cbn.
  unfold R, lp_to_LState.
  split_conj_step.
  - change (S (vm_pc vm) = S (lp_pc L)). rewrite Hpc. reflexivity.
  - intros i Hi.
    change (set_reg (vm_reg vm) d
              (vm_mem vm (vm_reg vm a + imm)) i =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (word_payload
                    (mem_get (lp_mem L) (lget_reg (lp_reg L) a + imm)))) i)
              mod 2 ^ 32).
    destruct (Nat.eq_dec i d) as [-> | Hne].
    + rewrite set_reg_eq.
      rewrite (lget_regN_lset_word_eq (lp_reg L) d
        (word_payload
          (mem_get (lp_mem L) (lget_reg (lp_reg L) a + imm))))
        by (rewrite Hlen; lia).
      rewrite Haddr.
      rewrite (Hmem (lget_reg (lp_reg L) a + imm)).
      rewrite <- (lp_mem_at_eq L (lget_reg (lp_reg L) a + imm)).
      rewrite Nat.mod_small by apply payload_word_lt_two32.
      reflexivity.
    + rewrite (set_reg_neq _ _ _ _ Hne).
      rewrite (lget_regN_lset_word_neq (lp_reg L) d
        (word_payload
          (mem_get (lp_mem L) (lget_reg (lp_reg L) a + imm))) i Hne).
      exact (Hregs i Hi).
  - change (set_reg (vm_reg vm) d
              (vm_mem vm (vm_reg vm a + imm)) 15 =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (word_payload
                    (mem_get (lp_mem L) (lget_reg (lp_reg L) a + imm)))) 15)
              mod 2 ^ 32).
    rewrite (set_reg_neq _ _ _ _ (not_eq_sym Hd15)).
    rewrite (lget_regN_lset_word_neq (lp_reg L) d
      (word_payload
        (mem_get (lp_mem L) (lget_reg (lp_reg L) a + imm))) 15
      (not_eq_sym Hd15)).
    exact Hreg15.
  - change (vm_link vm =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (word_payload
                    (mem_get (lp_mem L) (lget_reg (lp_reg L) a + imm)))) 15)).
    rewrite (lget_regN_lset_word_neq (lp_reg L) d
      (word_payload
        (mem_get (lp_mem L) (lget_reg (lp_reg L) a + imm))) 15
      (not_eq_sym Hd15)).
    exact Hlink.
  - intro x.
    change (vm_mem vm x =
            payload_word (lp_mem_at (lp_exec L (pLD d a imm)) x)).
    rewrite lp_mem_at_lp_exec_LD. exact (Hmem x).
  - change (vm_zf vm = Nat.eqb ((lp_k L / 2) mod 2) 1). exact Hzf.
  - change (vm_lf vm = Nat.eqb (lp_k L mod 2) 1). exact Hlf.
  - change (lp_k L < 4). exact Hk.
  - change (vm_halted vm = lp_halted L). exact Hhalt.
  - intros i Hi.
    change (N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (word_payload
                    (mem_get (lp_mem L) (lget_reg (lp_reg L) a + imm)))) i)
            < 2 ^ 32).
    destruct (Nat.eq_dec i d) as [-> | Hne].
    + rewrite (lget_regN_lset_word_eq (lp_reg L) d
        (word_payload
          (mem_get (lp_mem L) (lget_reg (lp_reg L) a + imm))))
        by (rewrite Hlen; lia).
      apply payload_word_lt_two32.
    + rewrite (lget_regN_lset_word_neq (lp_reg L) d
        (word_payload
          (mem_get (lp_mem L) (lget_reg (lp_reg L) a + imm))) i Hne).
      exact (Hbound i Hi).
Qed.

Print Assumptions lp_exec_LD_refines.

(** ** CALL (with the link-register invariant) *)

Theorem lp_exec_CALL_refines :
  forall L vm prog target,
    Rlp L vm ->
    List.length (lp_reg L) = 16 ->
    S (lp_pc L) < 2 ^ 32 ->
    vm_reg vm 15 = S (lp_pc L) ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some (pCALL target) ->
    nth_error prog (vm_pc vm) = Some (pCALL target) ->
    Rlp (lp_exec L (pCALL target)) (exec_instr_p prog vm).
Proof.
  intros L vm prog target HR Hlen Hpc32 Hreg15pre Hdec Hnth.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  unfold lp_exec, exec_instr_p.
  rewrite Hnth. cbn.
  unfold R, lp_to_LState.
  split_conj_step.
  - reflexivity.
  - intros i Hi.
    change (vm_reg vm i =
            N.to_nat
              (lget_regN (lset_word (lp_reg L) 15 (N.of_nat (S (lp_pc L)))) i)
              mod 2 ^ 32).
    rewrite (lget_regN_lset_word_neq (lp_reg L) 15
      (N.of_nat (S (lp_pc L))) i) by lia.
    exact (Hregs i Hi).
  - change (vm_reg vm 15 =
            N.to_nat
              (lget_regN (lset_word (lp_reg L) 15 (N.of_nat (S (lp_pc L)))) 15)
              mod 2 ^ 32).
    rewrite (lget_regN_lset_word_eq (lp_reg L) 15
      (N.of_nat (S (lp_pc L)))) by (rewrite Hlen; lia).
    rewrite Nat2N.id.
    rewrite Hreg15pre.
    rewrite Nat.mod_small by exact Hpc32.
    reflexivity.
  - change (instr_succ (vm_pc vm) =
            N.to_nat
              (lget_regN (lset_word (lp_reg L) 15 (N.of_nat (S (lp_pc L)))) 15)).
    unfold instr_succ. rewrite Hpc.
    rewrite (lget_regN_lset_word_eq (lp_reg L) 15
      (N.of_nat (S (lp_pc L)))) by (rewrite Hlen; lia).
    rewrite Nat2N.id. reflexivity.
  - intro a.
    change (vm_mem vm a =
            payload_word (lp_mem_at (lp_exec L (pCALL target)) a)).
    rewrite lp_mem_at_lp_exec_CALL. exact (Hmem a).
  - change (vm_zf vm = Nat.eqb ((lp_k L / 2) mod 2) 1). exact Hzf.
  - change (vm_lf vm = Nat.eqb (lp_k L mod 2) 1). exact Hlf.
  - change (lp_k L < 4). exact Hk.
  - change (vm_halted vm = lp_halted L). exact Hhalt.
  - intros i Hi.
    change (N.to_nat
              (lget_regN (lset_word (lp_reg L) 15 (N.of_nat (S (lp_pc L)))) i)
            < 2 ^ 32).
    destruct (Nat.eq_dec i 15) as [-> | Hne].
    + rewrite (lget_regN_lset_word_eq (lp_reg L) 15
        (N.of_nat (S (lp_pc L)))) by (rewrite Hlen; lia).
      rewrite Nat2N.id. exact Hpc32.
    + rewrite (lget_regN_lset_word_neq (lp_reg L) 15
        (N.of_nat (S (lp_pc L))) i) by lia.
      exact (Hbound i Hi).
Qed.

Print Assumptions lp_exec_CALL_refines.

(** ** N comparison agreement with the nat VM *)

Lemma N_eqb_to_nat :
  forall x y, N.eqb x y = Nat.eqb (N.to_nat x) (N.to_nat y).
Proof.
  intros x y.
  destruct (N.eqb x y) eqn:E.
  - apply N.eqb_eq in E. subst. rewrite Nat.eqb_refl. reflexivity.
  - symmetry. apply Nat.eqb_neq. intro H.
    apply N.eqb_neq in E. apply E. apply N2Nat.inj. exact H.
Qed.

Lemma N_lt_of_to_nat_lt :
  forall x y, N.to_nat x < N.to_nat y -> (x < y)%N.
Proof.
  intros x y H.
  destruct (N.lt_trichotomy x y) as [Hlt | [Heq | Hgt]].
  - exact Hlt.
  - subst. lia.
  - exfalso. pose proof (N_lt_to_nat_lt y x Hgt). lia.
Qed.

Lemma N_ltb_to_nat :
  forall x y, N.ltb x y = Nat.ltb (N.to_nat x) (N.to_nat y).
Proof.
  intros x y.
  destruct (N.ltb x y) eqn:E.
  - apply N.ltb_lt in E. symmetry. apply Nat.ltb_lt.
    apply N_lt_to_nat_lt. exact E.
  - symmetry. apply Nat.ltb_ge.
    assert (Hnot : ~ N.to_nat x < N.to_nat y).
    { intro H.
      assert (Hlt : (x < y)%N) by (apply N_lt_of_to_nat_lt; exact H).
      rewrite (proj2 (N.ltb_lt x y) Hlt) in E. discriminate. }
    lia.
Qed.

(** ** CMP *)

Theorem lp_exec_CMP_refines :
  forall L vm prog a b,
    Rlp L vm ->
    a < 16 ->
    b < 16 ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some (pCMP a b) ->
    nth_error prog (vm_pc vm) = Some (pCMP a b) ->
    Rlp (lp_exec L (pCMP a b)) (exec_instr_p prog vm).
Proof.
  intros L vm prog a b HR Ha Hb Hdec Hnth.
  pose proof HR as HR_R.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  pose proof (R_reg_eq (lp_to_LState L) vm a HR_R Ha) as HA.
  pose proof (R_reg_eq (lp_to_LState L) vm b HR_R Hb) as HB.
  assert (HA' : vm_reg vm a = N.to_nat (lget_regN (lp_reg L) a)).
  { unfold l_reg, lp_to_LState in HA. exact HA. }
  assert (HB' : vm_reg vm b = N.to_nat (lget_regN (lp_reg L) b)).
  { unfold l_reg, lp_to_LState in HB. exact HB. }
  unfold lp_exec, exec_instr_p.
  rewrite Hnth. cbn.
  unfold R, lp_to_LState.
  split_conj_step.
  - change (S (vm_pc vm) = S (lp_pc L)). rewrite Hpc. reflexivity.
  - intros i Hi.
    change (vm_reg vm i = N.to_nat (lget_regN (lp_reg L) i) mod 2 ^ 32).
    exact (Hregs i Hi).
  - change (vm_reg vm 15 =
            N.to_nat (lget_regN (lp_reg L) 15) mod 2 ^ 32).
    exact Hreg15.
  - change (vm_link vm = N.to_nat (lget_regN (lp_reg L) 15)).
    exact Hlink.
  - intro x.
    change (vm_mem vm x = payload_word (lp_mem_at (lp_exec L (pCMP a b)) x)).
    rewrite lp_mem_at_lp_exec_CMP. exact (Hmem x).
  - change (Nat.eqb (vm_reg vm a) (vm_reg vm b) =
            Nat.eqb
              ((pack_k
                 (N.eqb (lget_regN (lp_reg L) a) (lget_regN (lp_reg L) b))
                 (N.ltb (lget_regN (lp_reg L) a) (lget_regN (lp_reg L) b))
                / 2) mod 2) 1).
    rewrite pack_k_zf.
    rewrite HA', HB'.
    symmetry. apply N_eqb_to_nat.
  - change (Nat.ltb (vm_reg vm a) (vm_reg vm b) =
            Nat.eqb
              ((pack_k
                  (N.eqb (lget_regN (lp_reg L) a) (lget_regN (lp_reg L) b))
                  (N.ltb (lget_regN (lp_reg L) a) (lget_regN (lp_reg L) b)))
               mod 2) 1).
    rewrite pack_k_lf.
    rewrite HA', HB'.
    symmetry. apply N_ltb_to_nat.
  - apply pack_k_lt_4.
  - change (vm_halted vm = lp_halted L). exact Hhalt.
  - intros i Hi.
    change (N.to_nat (lget_regN (lp_reg L) i) < 2 ^ 32).
    exact (Hbound i Hi).
Qed.

Print Assumptions lp_exec_CMP_refines.

(** ** JMP *)

Theorem lp_exec_JMP_refines :
  forall L vm prog p target,
    Rlp L vm ->
    lp_k L <> 3 ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some (pJMP p target) ->
    nth_error prog (vm_pc vm) = Some (pJMP p target) ->
    Rlp (lp_exec L (pJMP p target)) (exec_instr_p prog vm).
Proof.
  intros L vm prog p target HR Hk3 Hdec Hnth.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  unfold lp_exec, exec_instr_p.
  rewrite Hnth. cbn.
  unfold R, lp_to_LState.
  split_conj_step.
  - change
      ((if pred_holds p (vm_zf vm) (vm_lf vm)
        then target else S (vm_pc vm)) =
       (if pred_passes (pred_nat p) (lp_k L)
        then target else S (lp_pc L))).
    rewrite Hpc, Hzf, Hlf.
    repeat rewrite l_k_lp_to_LState.
    assert (Hk' : lp_k L < 4)
      by (rewrite <- l_k_lp_to_LState; exact Hk).
    rewrite (pred_agrees p (lp_k L) Hk' Hk3).
    reflexivity.
  - intros i Hi.
    change (vm_reg vm i = N.to_nat (lget_regN (lp_reg L) i) mod 2 ^ 32).
    exact (Hregs i Hi).
  - change (vm_reg vm 15 =
            N.to_nat (lget_regN (lp_reg L) 15) mod 2 ^ 32).
    exact Hreg15.
  - change (vm_link vm = N.to_nat (lget_regN (lp_reg L) 15)). exact Hlink.
  - intro x.
    change (vm_mem vm x = payload_word (lp_mem_at (lp_exec L (pJMP p target)) x)).
    rewrite lp_mem_at_lp_exec_JMP. exact (Hmem x).
  - change (vm_zf vm = Nat.eqb ((lp_k L / 2) mod 2) 1). exact Hzf.
  - change (vm_lf vm = Nat.eqb (lp_k L mod 2) 1). exact Hlf.
  - change (lp_k L < 4). exact Hk.
  - change (vm_halted vm = lp_halted L). exact Hhalt.
  - intros i Hi.
    change (N.to_nat (lget_regN (lp_reg L) i) < 2 ^ 32).
    exact (Hbound i Hi).
Qed.

Print Assumptions lp_exec_JMP_refines.

(** ** RETP *)

Theorem lp_exec_RETP_refines :
  forall L vm prog p,
    Rlp L vm ->
    lp_k L <> 3 ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some (pRETP p) ->
    nth_error prog (vm_pc vm) = Some (pRETP p) ->
    Rlp (lp_exec L (pRETP p)) (exec_instr_p prog vm).
Proof.
  intros L vm prog p HR Hk3 Hdec Hnth.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  unfold lp_exec, exec_instr_p.
  rewrite Hnth. cbn.
  unfold R, lp_to_LState.
  split_conj_step.
  - change
      ((if pred_holds p (vm_zf vm) (vm_lf vm)
        then vm_link vm else S (vm_pc vm)) =
       (if pred_passes (pred_nat p) (lp_k L)
        then lget_reg (lp_reg L) 15 else S (lp_pc L))).
    rewrite Hpc, Hzf, Hlf.
    repeat rewrite l_k_lp_to_LState.
    assert (Hk' : lp_k L < 4)
      by (rewrite <- l_k_lp_to_LState; exact Hk).
    rewrite (pred_agrees p (lp_k L) Hk' Hk3).
    rewrite Hlink.
    unfold lget_reg, l_reg, lp_to_LState. reflexivity.
  - intros i Hi.
    change (vm_reg vm i = N.to_nat (lget_regN (lp_reg L) i) mod 2 ^ 32).
    exact (Hregs i Hi).
  - change (vm_reg vm 15 =
            N.to_nat (lget_regN (lp_reg L) 15) mod 2 ^ 32).
    exact Hreg15.
  - change (vm_link vm = N.to_nat (lget_regN (lp_reg L) 15)). exact Hlink.
  - intro x.
    change (vm_mem vm x = payload_word (lp_mem_at (lp_exec L (pRETP p)) x)).
    rewrite lp_mem_at_lp_exec_RETP. exact (Hmem x).
  - change (vm_zf vm = Nat.eqb ((lp_k L / 2) mod 2) 1). exact Hzf.
  - change (vm_lf vm = Nat.eqb (lp_k L mod 2) 1). exact Hlf.
  - change (lp_k L < 4). exact Hk.
  - change (vm_halted vm = lp_halted L). exact Hhalt.
  - intros i Hi.
    change (N.to_nat (lget_regN (lp_reg L) i) < 2 ^ 32).
    exact (Hbound i Hi).
Qed.

Print Assumptions lp_exec_RETP_refines.

(** ** SHR *)

Lemma N_land_mask_small :
  forall x, (x < 2 ^ 32)%N -> (N.land x word_mask32 = x)%N.
Proof.
  intros x Hx. unfold word_mask32.
  rewrite ones32.
  rewrite N.land_ones.
  apply N.mod_small. exact Hx.
Qed.

Lemma N_shiftr_lt_two32 :
  forall x n, (x < 2 ^ 32)%N ->
    (N.shiftr x (N.of_nat n) < 2 ^ 32)%N.
Proof.
  intros x n Hx.
  eapply N.le_lt_trans.
  - apply N.shiftr_upper_bound.
  - exact Hx.
Qed.

Lemma N_lt_two32_of_nat :
  forall x, N.to_nat x < 2 ^ 32 -> (x < 2 ^ 32)%N.
Proof.
  intros x H.
  apply N_lt_of_to_nat_lt.
  rewrite N_to_nat_two32. exact H.
Qed.

Lemma to_nat_shr32N :
  forall x n, (x < 2 ^ 32)%N ->
    N.to_nat (shr32N x n) = Nat.shiftr (N.to_nat x) n.
Proof.
  intros x n Hx.
  unfold shr32N.
  assert (Hsh : (N.shiftr x (N.of_nat n) < 2 ^ 32)%N)
    by (apply N_shiftr_lt_two32; exact Hx).
  rewrite (N_land_mask_small _ Hsh).
  rewrite N.shiftr_div_pow2.
  rewrite N2Nat.inj_div.
  rewrite N2Nat.inj_pow.
  rewrite Nat2N.id.
  rewrite Nat.shiftr_div_pow2.
  reflexivity.
Qed.

Theorem lp_exec_SHR_refines :
  forall L vm prog d a imm,
    Rlp L vm ->
    List.length (lp_reg L) = 16 ->
    d < 16 ->
    d <> 15 ->
    a < 16 ->
    imm < 32 ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some (pSHR d a imm) ->
    nth_error prog (vm_pc vm) = Some (pSHR d a imm) ->
    Rlp (lp_exec L (pSHR d a imm)) (exec_instr_p prog vm).
Proof.
  intros L vm prog d a imm HR Hlen Hd Hd15 Ha Himm Hdec Hnth.
  pose proof HR as HR_R.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  pose proof (R_reg_eq (lp_to_LState L) vm a HR_R Ha) as HA.
  assert (HA' : vm_reg vm a = N.to_nat (lget_regN (lp_reg L) a)).
  { unfold l_reg, lp_to_LState in HA. exact HA. }
  assert (Hx : (lget_regN (lp_reg L) a < 2 ^ 32)%N)
    by (apply N_lt_two32_of_nat; exact (Hbound a Ha)).
  assert (Himm32 : imm mod 32 = imm)
    by (apply Nat.mod_small; exact Himm).
  unfold lp_exec, exec_instr_p.
  rewrite Hnth. cbn.
  unfold R, lp_to_LState.
  split_conj_step.
  - change (S (vm_pc vm) = S (lp_pc L)). rewrite Hpc. reflexivity.
  - intros i Hi.
    change (set_reg (vm_reg vm) d (Nat.shiftr (vm_reg vm a) imm) i =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (shr32N (lget_regN (lp_reg L) a) (imm mod 32))) i)
              mod 2 ^ 32).
    destruct (Nat.eq_dec i d) as [-> | Hne].
    + rewrite set_reg_eq.
      rewrite (lget_regN_lset_word_eq (lp_reg L) d
        (shr32N (lget_regN (lp_reg L) a) (imm mod 32)))
        by (rewrite Hlen; lia).
      rewrite (to_nat_shr32N (lget_regN (lp_reg L) a) (imm mod 32) Hx).
      rewrite Himm32.
      rewrite HA'.
      rewrite Nat.mod_small.
      2:{ eapply Nat.le_lt_trans.
          - apply Nat.shiftr_upper_bound.
          - exact (Hbound a Ha). }
      reflexivity.
    + rewrite (set_reg_neq _ _ _ _ Hne).
      rewrite (lget_regN_lset_word_neq (lp_reg L) d
        (shr32N (lget_regN (lp_reg L) a) (imm mod 32)) i Hne).
      exact (Hregs i Hi).
  - change (set_reg (vm_reg vm) d (Nat.shiftr (vm_reg vm a) imm) 15 =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (shr32N (lget_regN (lp_reg L) a) (imm mod 32))) 15)
              mod 2 ^ 32).
    rewrite (set_reg_neq _ _ _ _ (not_eq_sym Hd15)).
    rewrite (lget_regN_lset_word_neq (lp_reg L) d
      (shr32N (lget_regN (lp_reg L) a) (imm mod 32)) 15
      (not_eq_sym Hd15)).
    exact Hreg15.
  - change (vm_link vm =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (shr32N (lget_regN (lp_reg L) a) (imm mod 32))) 15)).
    rewrite (lget_regN_lset_word_neq (lp_reg L) d
      (shr32N (lget_regN (lp_reg L) a) (imm mod 32)) 15
      (not_eq_sym Hd15)).
    exact Hlink.
  - intro x.
    change (vm_mem vm x =
            payload_word (lp_mem_at (lp_exec L (pSHR d a imm)) x)).
    rewrite lp_mem_at_lp_exec_SHR. exact (Hmem x).
  - change (Nat.eqb (Nat.shiftr (vm_reg vm a) imm) 0 =
            Nat.eqb
              ((pack_k
                 (N.eqb
                   (shr32N (lget_regN (lp_reg L) a) (imm mod 32)) 0)
                 false) / 2 mod 2) 1).
    rewrite pack_k_zf.
    rewrite HA'.
    rewrite N_eqb_to_nat.
    rewrite (to_nat_shr32N (lget_regN (lp_reg L) a) (imm mod 32) Hx).
    rewrite Himm32.
    reflexivity.
  - change (false =
            Nat.eqb
              (pack_k
                 (N.eqb
                   (shr32N (lget_regN (lp_reg L) a) (imm mod 32)) 0)
                 false mod 2) 1).
    rewrite pack_k_lf. reflexivity.
  - apply pack_k_lt_4.
  - change (vm_halted vm = lp_halted L). exact Hhalt.
  - intros i Hi.
    change (N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (shr32N (lget_regN (lp_reg L) a) (imm mod 32))) i)
            < 2 ^ 32).
    destruct (Nat.eq_dec i d) as [-> | Hne].
    + rewrite (lget_regN_lset_word_eq (lp_reg L) d
        (shr32N (lget_regN (lp_reg L) a) (imm mod 32)))
        by (rewrite Hlen; lia).
      rewrite (to_nat_shr32N (lget_regN (lp_reg L) a) (imm mod 32) Hx).
      rewrite Himm32.
      eapply Nat.le_lt_trans.
      * apply Nat.shiftr_upper_bound.
      * exact (Hbound a Ha).
    + rewrite (lget_regN_lset_word_neq (lp_reg L) d
        (shr32N (lget_regN (lp_reg L) a) (imm mod 32)) i Hne).
      exact (Hbound i Hi).
Qed.

Print Assumptions lp_exec_SHR_refines.


(** ** ADD *)

Lemma to_nat_mod32N :
  forall x, N.to_nat (mod32N x) = N.to_nat x mod 2 ^ 32.
Proof.
  intros x. unfold mod32N, word_mask32.
  rewrite ones32.
  rewrite N.land_ones.
  rewrite N2Nat.inj_mod.
  rewrite N2Nat.inj_pow.
  reflexivity.
Qed.

Lemma to_nat_mod32N_add_small :
  forall x y,
    N.to_nat x + N.to_nat y < 2 ^ 32 ->
    N.to_nat (mod32N (N.add x y)) = N.to_nat x + N.to_nat y.
Proof.
  intros x y H.
  rewrite to_nat_mod32N.
  rewrite N2Nat.inj_add.
  apply Nat.mod_small. exact H.
Qed.

Theorem lp_exec_ADD_refines :
  forall L vm prog d a b,
    Rlp L vm ->
    List.length (lp_reg L) = 16 ->
    d < 16 ->
    d <> 15 ->
    a < 16 ->
    b < 16 ->
    N.to_nat (lget_regN (lp_reg L) a) +
      N.to_nat (lget_regN (lp_reg L) b) < 2 ^ 32 ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some (pADD d a b) ->
    nth_error prog (vm_pc vm) = Some (pADD d a b) ->
    Rlp (lp_exec L (pADD d a b)) (exec_instr_p prog vm).
Proof.
  intros L vm prog d a b HR Hlen Hd Hd15 Ha Hb Hnc Hdec Hnth.
  pose proof HR as HR_R.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  pose proof (R_reg_eq (lp_to_LState L) vm a HR_R Ha) as HA.
  pose proof (R_reg_eq (lp_to_LState L) vm b HR_R Hb) as HB.
  assert (HA' : vm_reg vm a = N.to_nat (lget_regN (lp_reg L) a)).
  { unfold l_reg, lp_to_LState in HA. exact HA. }
  assert (HB' : vm_reg vm b = N.to_nat (lget_regN (lp_reg L) b)).
  { unfold l_reg, lp_to_LState in HB. exact HB. }
  assert (HsumN : (N.add (lget_regN (lp_reg L) a)
                           (lget_regN (lp_reg L) b) < two32)%N).
  { apply N_lt_two32_of_nat.
    rewrite N2Nat.inj_add. exact Hnc. }
  unfold lp_exec, exec_instr_p.
  rewrite Hnth. cbn.
  unfold R, lp_to_LState.
  split_conj_step.
  - change (S (vm_pc vm) = S (lp_pc L)). rewrite Hpc. reflexivity.
  - intros i Hi.
    change (set_reg (vm_reg vm) d
              (vm_reg vm a + vm_reg vm b) i =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (mod32N (N.add (lget_regN (lp_reg L) a)
                                  (lget_regN (lp_reg L) b)))) i)
              mod 2 ^ 32).
    destruct (Nat.eq_dec i d) as [-> | Hne].
    + rewrite set_reg_eq.
      rewrite (lget_regN_lset_word_eq (lp_reg L) d
        (mod32N (N.add (lget_regN (lp_reg L) a)
                        (lget_regN (lp_reg L) b))))
        by (rewrite Hlen; lia).
      rewrite (to_nat_mod32N_add_small
        (lget_regN (lp_reg L) a) (lget_regN (lp_reg L) b) Hnc).
      rewrite HA', HB'.
      rewrite Nat.mod_small by exact Hnc.
      reflexivity.
    + rewrite (set_reg_neq _ _ _ _ Hne).
      rewrite (lget_regN_lset_word_neq (lp_reg L) d
        (mod32N (N.add (lget_regN (lp_reg L) a)
                        (lget_regN (lp_reg L) b))) i Hne).
      exact (Hregs i Hi).
  - change (set_reg (vm_reg vm) d
              (vm_reg vm a + vm_reg vm b) 15 =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (mod32N (N.add (lget_regN (lp_reg L) a)
                                  (lget_regN (lp_reg L) b)))) 15)
              mod 2 ^ 32).
    rewrite (set_reg_neq _ _ _ _ (not_eq_sym Hd15)).
    rewrite (lget_regN_lset_word_neq (lp_reg L) d
      (mod32N (N.add (lget_regN (lp_reg L) a)
                      (lget_regN (lp_reg L) b))) 15
      (not_eq_sym Hd15)).
    exact Hreg15.
  - change (vm_link vm =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (mod32N (N.add (lget_regN (lp_reg L) a)
                                  (lget_regN (lp_reg L) b)))) 15)).
    rewrite (lget_regN_lset_word_neq (lp_reg L) d
      (mod32N (N.add (lget_regN (lp_reg L) a)
                      (lget_regN (lp_reg L) b))) 15
      (not_eq_sym Hd15)).
    exact Hlink.
  - intro x.
    change (vm_mem vm x =
            payload_word (lp_mem_at (lp_exec L (pADD d a b)) x)).
    rewrite lp_mem_at_lp_exec_ADD. exact (Hmem x).
  - change (Nat.eqb (vm_reg vm a + vm_reg vm b) 0 =
            Nat.eqb
              (((pack_k
                  (N.eqb
                    (mod32N (N.add (lget_regN (lp_reg L) a)
                                    (lget_regN (lp_reg L) b))) 0)
                  (N.leb two32
                    (N.add (lget_regN (lp_reg L) a)
                           (lget_regN (lp_reg L) b)))
                 ) / 2) mod 2) 1).
    rewrite pack_k_zf.
    rewrite HA', HB'.
    rewrite N_eqb_to_nat.
    rewrite (to_nat_mod32N_add_small
      (lget_regN (lp_reg L) a) (lget_regN (lp_reg L) b) Hnc).
    reflexivity.
  - change (false =
            Nat.eqb
              (pack_k
                 (N.eqb
                   (mod32N (N.add (lget_regN (lp_reg L) a)
                                   (lget_regN (lp_reg L) b))) 0)
                 (N.leb two32
                   (N.add (lget_regN (lp_reg L) a)
                          (lget_regN (lp_reg L) b))) mod 2) 1).
    rewrite pack_k_lf.
    assert (Hle : (N.leb two32
                    (N.add (lget_regN (lp_reg L) a)
                           (lget_regN (lp_reg L) b)) = false)).
    { apply (proj2 (N.leb_gt two32
        (N.add (lget_regN (lp_reg L) a)
               (lget_regN (lp_reg L) b)))).
      exact HsumN. }
    rewrite Hle. reflexivity.
  - apply pack_k_lt_4.
  - change (vm_halted vm = lp_halted L). exact Hhalt.
  - intros i Hi.
    change (N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (mod32N (N.add (lget_regN (lp_reg L) a)
                                  (lget_regN (lp_reg L) b)))) i)
            < 2 ^ 32).
    destruct (Nat.eq_dec i d) as [-> | Hne].
    + rewrite (lget_regN_lset_word_eq (lp_reg L) d
        (mod32N (N.add (lget_regN (lp_reg L) a)
                        (lget_regN (lp_reg L) b))))
        by (rewrite Hlen; lia).
      rewrite to_nat_mod32N.
      apply Nat.mod_upper_bound. exact two32_neq_0.
    + rewrite (lget_regN_lset_word_neq (lp_reg L) d
        (mod32N (N.add (lget_regN (lp_reg L) a)
                        (lget_regN (lp_reg L) b))) i Hne).
      exact (Hbound i Hi).
Qed.

Print Assumptions lp_exec_ADD_refines.

(** ** SUB *)

Lemma to_nat_land_mask :
  forall x, N.to_nat (N.land x word_mask32) = N.to_nat x mod 2 ^ 32.
Proof.
  intros x. unfold word_mask32.
  rewrite ones32.
  rewrite N.land_ones.
  rewrite N2Nat.inj_mod.
  rewrite N2Nat.inj_pow.
  reflexivity.
Qed.

Lemma to_nat_two32 : N.to_nat two32 = 2 ^ 32.
Proof.
  unfold two32.
  change (N.to_nat (2 ^ 32)%N = 2 ^ 32).
  apply N_to_nat_two32.
Qed.

Lemma to_nat_sub32N :
  forall x y,
    (x < 2 ^ 32)%N ->
    N.to_nat y <= N.to_nat x ->
    N.to_nat (sub32N x y) = N.to_nat x - N.to_nat y.
Proof.
  intros x y Hx Hle.
  assert (Hxn : N.to_nat x < 2 ^ 32).
  { rewrite <- to_nat_two32. apply N_lt_to_nat_lt. exact Hx. }
  unfold sub32N.
  rewrite to_nat_land_mask.
  rewrite N2Nat.inj_add.
  rewrite N2Nat.inj_sub.
  rewrite to_nat_two32.
  remember (2 ^ 32) as M eqn:HM.
  assert (Hshape :
    N.to_nat x + (M - N.to_nat y)
    = M + (N.to_nat x - N.to_nat y)) by lia.
  rewrite Hshape.
  replace (M + (N.to_nat x - N.to_nat y))
    with ((N.to_nat x - N.to_nat y) + 1 * M) by lia.
  rewrite Nat.mod_add.
  apply Nat.mod_small. lia.
  all: lia.
Qed.

Theorem lp_exec_SUB_refines :
  forall L vm prog d a b,
    Rlp L vm ->
    List.length (lp_reg L) = 16 ->
    d < 16 ->
    d <> 15 ->
    a < 16 ->
    b < 16 ->
    N.to_nat (lget_regN (lp_reg L) b) <=
      N.to_nat (lget_regN (lp_reg L) a) ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some (pSUB d a b) ->
    nth_error prog (vm_pc vm) = Some (pSUB d a b) ->
    Rlp (lp_exec L (pSUB d a b)) (exec_instr_p prog vm).
Proof.
  intros L vm prog d a b HR Hlen Hd Hd15 Ha Hb Hle Hdec Hnth.
  pose proof HR as HR_R.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  pose proof (R_reg_eq (lp_to_LState L) vm a HR_R Ha) as HA.
  pose proof (R_reg_eq (lp_to_LState L) vm b HR_R Hb) as HB.
  assert (HA' : vm_reg vm a = N.to_nat (lget_regN (lp_reg L) a)).
  { unfold l_reg, lp_to_LState in HA. exact HA. }
  assert (HB' : vm_reg vm b = N.to_nat (lget_regN (lp_reg L) b)).
  { unfold l_reg, lp_to_LState in HB. exact HB. }
  assert (Hx : (lget_regN (lp_reg L) a < 2 ^ 32)%N)
    by (apply N_lt_two32_of_nat; exact (Hbound a Ha)).
  unfold lp_exec, exec_instr_p.
  rewrite Hnth. cbn.
  unfold R, lp_to_LState.
  split_conj_step.
  - change (S (vm_pc vm) = S (lp_pc L)). rewrite Hpc. reflexivity.
  - intros i Hi.
    change (set_reg (vm_reg vm) d
              (vm_reg vm a - vm_reg vm b) i =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (sub32N (lget_regN (lp_reg L) a)
                          (lget_regN (lp_reg L) b))) i)
              mod 2 ^ 32).
    destruct (Nat.eq_dec i d) as [-> | Hne].
    + rewrite set_reg_eq.
      rewrite (lget_regN_lset_word_eq (lp_reg L) d
        (sub32N (lget_regN (lp_reg L) a)
                (lget_regN (lp_reg L) b)))
        by (rewrite Hlen; lia).
      rewrite (to_nat_sub32N _ _ Hx Hle).
      rewrite HA', HB'.
      rewrite Nat.mod_small.
      2:{ apply Nat.le_lt_trans with (N.to_nat (lget_regN (lp_reg L) a)).
          - lia.
          - exact (Hbound a Ha). }
      reflexivity.
    + rewrite (set_reg_neq _ _ _ _ Hne).
      rewrite (lget_regN_lset_word_neq (lp_reg L) d
        (sub32N (lget_regN (lp_reg L) a)
                (lget_regN (lp_reg L) b)) i Hne).
      exact (Hregs i Hi).
  - change (set_reg (vm_reg vm) d
              (vm_reg vm a - vm_reg vm b) 15 =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (sub32N (lget_regN (lp_reg L) a)
                          (lget_regN (lp_reg L) b))) 15)
              mod 2 ^ 32).
    rewrite (set_reg_neq _ _ _ _ (not_eq_sym Hd15)).
    rewrite (lget_regN_lset_word_neq (lp_reg L) d
      (sub32N (lget_regN (lp_reg L) a)
              (lget_regN (lp_reg L) b)) 15
      (not_eq_sym Hd15)).
    exact Hreg15.
  - change (vm_link vm =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (sub32N (lget_regN (lp_reg L) a)
                          (lget_regN (lp_reg L) b))) 15)).
    rewrite (lget_regN_lset_word_neq (lp_reg L) d
      (sub32N (lget_regN (lp_reg L) a)
              (lget_regN (lp_reg L) b)) 15
      (not_eq_sym Hd15)).
    exact Hlink.
  - intro x.
    change (vm_mem vm x =
            payload_word (lp_mem_at (lp_exec L (pSUB d a b)) x)).
    rewrite lp_mem_at_lp_exec_SUB. exact (Hmem x).
  - change (Nat.eqb (vm_reg vm a - vm_reg vm b) 0 =
            Nat.eqb
              (((pack_k
                  (N.eqb
                    (sub32N (lget_regN (lp_reg L) a)
                            (lget_regN (lp_reg L) b)) 0)
                  (N.ltb (lget_regN (lp_reg L) a)
                         (lget_regN (lp_reg L) b)))
                / 2) mod 2) 1).
    rewrite pack_k_zf.
    rewrite HA', HB'.
    rewrite N_eqb_to_nat.
    rewrite (to_nat_sub32N _ _ Hx Hle).
    reflexivity.
  - change (Nat.ltb (vm_reg vm a) (vm_reg vm b) =
            Nat.eqb
              ((pack_k
                  (N.eqb
                    (sub32N (lget_regN (lp_reg L) a)
                            (lget_regN (lp_reg L) b)) 0)
                  (N.ltb (lget_regN (lp_reg L) a)
                         (lget_regN (lp_reg L) b)))
               mod 2) 1).
    rewrite pack_k_lf.
    rewrite HA', HB'.
    rewrite N_ltb_to_nat.
    reflexivity.
  - apply pack_k_lt_4.
  - change (vm_halted vm = lp_halted L). exact Hhalt.
  - intros i Hi.
    change (N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (sub32N (lget_regN (lp_reg L) a)
                          (lget_regN (lp_reg L) b))) i)
            < 2 ^ 32).
    destruct (Nat.eq_dec i d) as [-> | Hne].
    + rewrite (lget_regN_lset_word_eq (lp_reg L) d
        (sub32N (lget_regN (lp_reg L) a)
                (lget_regN (lp_reg L) b)))
        by (rewrite Hlen; lia).
      rewrite (to_nat_sub32N _ _ Hx Hle).
      apply Nat.le_lt_trans with (N.to_nat (lget_regN (lp_reg L) a)).
      * lia.
      * exact (Hbound a Ha).
    + rewrite (lget_regN_lset_word_neq (lp_reg L) d
        (sub32N (lget_regN (lp_reg L) a)
                (lget_regN (lp_reg L) b)) i Hne).
      exact (Hbound i Hi).
Qed.

Print Assumptions lp_exec_SUB_refines.

(** ** SHL *)

Lemma to_nat_shl32N :
  forall x n,
    (x < 2 ^ 32)%N ->
    N.to_nat x * 2 ^ n < 2 ^ 32 ->
    N.to_nat (shl32N x n) = Nat.shiftl (N.to_nat x) n.
Proof.
  intros x n Hx Hov.
  unfold shl32N.
  assert (Hsh : (N.shiftl x (N.of_nat n) < 2 ^ 32)%N).
  { rewrite N.shiftl_mul_pow2.
    apply N_lt_two32_of_nat.
    rewrite N2Nat.inj_mul.
    rewrite N2Nat.inj_pow.
    rewrite Nat2N.id.
    exact Hov. }
  rewrite (N_land_mask_small _ Hsh).
  rewrite N.shiftl_mul_pow2.
  rewrite N2Nat.inj_mul.
  rewrite N2Nat.inj_pow.
  rewrite Nat2N.id.
  rewrite Nat.shiftl_mul_pow2.
  reflexivity.
Qed.

Theorem lp_exec_SHL_refines :
  forall L vm prog d a imm,
    Rlp L vm ->
    List.length (lp_reg L) = 16 ->
    d < 16 ->
    d <> 15 ->
    a < 16 ->
    imm < 32 ->
    N.to_nat (lget_regN (lp_reg L) a) * 2 ^ imm < 2 ^ 32 ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some (pSHL d a imm) ->
    nth_error prog (vm_pc vm) = Some (pSHL d a imm) ->
    Rlp (lp_exec L (pSHL d a imm)) (exec_instr_p prog vm).
Proof.
  intros L vm prog d a imm HR Hlen Hd Hd15 Ha Himm Hov Hdec Hnth.
  pose proof HR as HR_R.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  pose proof (R_reg_eq (lp_to_LState L) vm a HR_R Ha) as HA.
  assert (HA' : vm_reg vm a = N.to_nat (lget_regN (lp_reg L) a)).
  { unfold l_reg, lp_to_LState in HA. exact HA. }
  assert (Hx : (lget_regN (lp_reg L) a < 2 ^ 32)%N)
    by (apply N_lt_two32_of_nat; exact (Hbound a Ha)).
  assert (Himm32 : imm mod 32 = imm)
    by (apply Nat.mod_small; exact Himm).
  unfold lp_exec, exec_instr_p.
  rewrite Hnth. cbn.
  unfold R, lp_to_LState.
  split_conj_step.
  - change (S (vm_pc vm) = S (lp_pc L)). rewrite Hpc. reflexivity.
  - intros i Hi.
    change (set_reg (vm_reg vm) d (Nat.shiftl (vm_reg vm a) imm) i =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (shl32N (lget_regN (lp_reg L) a) (imm mod 32))) i)
              mod 2 ^ 32).
    destruct (Nat.eq_dec i d) as [-> | Hne].
    + rewrite set_reg_eq.
      rewrite (lget_regN_lset_word_eq (lp_reg L) d
        (shl32N (lget_regN (lp_reg L) a) (imm mod 32)))
        by (rewrite Hlen; lia).
      rewrite (to_nat_shl32N _ _ Hx) by (rewrite Himm32; exact Hov).
      rewrite Himm32.
      rewrite HA'.
      rewrite Nat.mod_small.
      2:{ rewrite Nat.shiftl_mul_pow2. exact Hov. }
      reflexivity.
    + rewrite (set_reg_neq _ _ _ _ Hne).
      rewrite (lget_regN_lset_word_neq (lp_reg L) d
        (shl32N (lget_regN (lp_reg L) a) (imm mod 32)) i Hne).
      exact (Hregs i Hi).
  - change (set_reg (vm_reg vm) d (Nat.shiftl (vm_reg vm a) imm) 15 =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (shl32N (lget_regN (lp_reg L) a) (imm mod 32))) 15)
              mod 2 ^ 32).
    rewrite (set_reg_neq _ _ _ _ (not_eq_sym Hd15)).
    rewrite (lget_regN_lset_word_neq (lp_reg L) d
      (shl32N (lget_regN (lp_reg L) a) (imm mod 32)) 15
      (not_eq_sym Hd15)).
    exact Hreg15.
  - change (vm_link vm =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (shl32N (lget_regN (lp_reg L) a) (imm mod 32))) 15)).
    rewrite (lget_regN_lset_word_neq (lp_reg L) d
      (shl32N (lget_regN (lp_reg L) a) (imm mod 32)) 15
      (not_eq_sym Hd15)).
    exact Hlink.
  - intro x.
    change (vm_mem vm x =
            payload_word (lp_mem_at (lp_exec L (pSHL d a imm)) x)).
    rewrite lp_mem_at_lp_exec_SHL. exact (Hmem x).
  - change (Nat.eqb (Nat.shiftl (vm_reg vm a) imm) 0 =
            Nat.eqb
              (((pack_k
                  (N.eqb
                    (shl32N (lget_regN (lp_reg L) a) (imm mod 32)) 0)
                  false) / 2) mod 2) 1).
    rewrite pack_k_zf.
    rewrite HA'.
    rewrite N_eqb_to_nat.
    rewrite (to_nat_shl32N _ _ Hx) by (rewrite Himm32; exact Hov).
    rewrite Himm32.
    reflexivity.
  - change (false =
            Nat.eqb
              ((pack_k
                  (N.eqb
                    (shl32N (lget_regN (lp_reg L) a) (imm mod 32)) 0)
                  false) mod 2) 1).
    rewrite pack_k_lf. reflexivity.
  - apply pack_k_lt_4.
  - change (vm_halted vm = lp_halted L). exact Hhalt.
  - intros i Hi.
    change (N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (shl32N (lget_regN (lp_reg L) a) (imm mod 32))) i)
            < 2 ^ 32).
    destruct (Nat.eq_dec i d) as [-> | Hne].
    + rewrite (lget_regN_lset_word_eq (lp_reg L) d
        (shl32N (lget_regN (lp_reg L) a) (imm mod 32)))
        by (rewrite Hlen; lia).
      rewrite (to_nat_shl32N _ _ Hx) by (rewrite Himm32; exact Hov).
      rewrite Himm32.
      rewrite Nat.shiftl_mul_pow2. exact Hov.
    + rewrite (lget_regN_lset_word_neq (lp_reg L) d
        (shl32N (lget_regN (lp_reg L) a) (imm mod 32)) i Hne).
      exact (Hbound i Hi).
Qed.

Print Assumptions lp_exec_SHL_refines.

(** ** BOOL.8 with the fixture mask 255 *)

Lemma N_land_255_to_nat :
  forall x, N.to_nat (N.land x 255%N) = N.to_nat x mod 256.
Proof.
  intros x.
  change (N.to_nat (N.land x (N.ones 8)) = N.to_nat x mod 2 ^ 8).
  rewrite N.land_ones.
  rewrite N2Nat.inj_mod.
  rewrite N2Nat.inj_pow.
  reflexivity.
Qed.

Lemma le_256_two32 : 256 <= 2 ^ 32.
Proof.
  change (2 ^ 8 <= 2 ^ 32).
  apply Nat.pow_le_mono_r; lia.
Qed.

Lemma N_land_255_to_nat_lt :
  forall x, N.to_nat (N.land x 255%N) < 256.
Proof.
  intro x.
  rewrite N_land_255_to_nat.
  apply Nat.mod_upper_bound. lia.
Qed.

Theorem lp_exec_BOOL8_255_refines :
  forall L vm prog d a b,
    Rlp L vm ->
    List.length (lp_reg L) = 16 ->
    d < 16 ->
    d <> 15 ->
    a < 16 ->
    b < 16 ->
    lget_regN (lp_reg L) b = 255%N ->
    vm_reg vm b = 255 ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some (pBOOL 8 d a b) ->
    nth_error prog (vm_pc vm) = Some (pBOOL 8 d a b) ->
    Rlp (lp_exec L (pBOOL 8 d a b)) (exec_instr_p prog vm).
Proof.
  intros L vm prog d a b HR Hlen Hd Hd15 Ha Hb Hval Hvalvm Hdec Hnth.
  pose proof HR as HR_R.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  pose proof (R_reg_eq (lp_to_LState L) vm a HR_R Ha) as HA.
  assert (HA' : vm_reg vm a = N.to_nat (lget_regN (lp_reg L) a)).
  { unfold l_reg, lp_to_LState in HA. exact HA. }
  assert (Hmod_lt : N.to_nat (lget_regN (lp_reg L) a) mod 256 < 2 ^ 32).
  { rewrite <- N_land_255_to_nat.
    apply Nat.lt_le_trans with 256.
    - apply N_land_255_to_nat_lt.
    - apply le_256_two32. }
  assert (Houter :
    (N.to_nat (lget_regN (lp_reg L) a) mod 256) mod 2 ^ 32 =
    N.to_nat (lget_regN (lp_reg L) a) mod 256)
    by (apply Nat.mod_small; exact Hmod_lt).
  unfold lp_exec, exec_instr_p.
  rewrite Hnth. cbn -[e_bool_res bool_resN].
  rewrite Hval.
  unfold R, lp_to_LState.
  split_conj_step.
  - change (S (vm_pc vm) = S (lp_pc L)). rewrite Hpc. reflexivity.
  - intros i Hi.
    change (set_reg (vm_reg vm) d
              (e_bool_res 8 (vm_reg vm a) (vm_reg vm b)) i =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (N.land (lget_regN (lp_reg L) a) 255%N)) i)
              mod 2 ^ 32).
    destruct (Nat.eq_dec i d) as [-> | Hne].
    + rewrite set_reg_eq.
      rewrite Hvalvm.
      rewrite (e_bool_res_8_255 (vm_reg vm a)) by (rewrite HA'; exact (Hbound a Ha)).
      rewrite (lget_regN_lset_word_eq (lp_reg L) d
        (N.land (lget_regN (lp_reg L) a) 255%N))
        by (rewrite Hlen; lia).
      rewrite N_land_255_to_nat.
      rewrite HA'.
      rewrite Houter.
      reflexivity.
    + rewrite (set_reg_neq _ _ _ _ Hne).
      rewrite (lget_regN_lset_word_neq (lp_reg L) d
        (N.land (lget_regN (lp_reg L) a) 255%N) i Hne).
      exact (Hregs i Hi).
  - change (set_reg (vm_reg vm) d
              (e_bool_res 8 (vm_reg vm a) (vm_reg vm b)) 15 =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (N.land (lget_regN (lp_reg L) a) 255%N)) 15)
              mod 2 ^ 32).
    rewrite (set_reg_neq _ _ _ _ (not_eq_sym Hd15)).
    rewrite (lget_regN_lset_word_neq (lp_reg L) d
      (N.land (lget_regN (lp_reg L) a) 255%N) 15
      (not_eq_sym Hd15)).
    exact Hreg15.
  - change (vm_link vm =
            N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (N.land (lget_regN (lp_reg L) a) 255%N)) 15)).
    rewrite (lget_regN_lset_word_neq (lp_reg L) d
      (N.land (lget_regN (lp_reg L) a) 255%N) 15
      (not_eq_sym Hd15)).
    exact Hlink.
  - intro x.
    change (vm_mem vm x =
            payload_word (lp_mem_at (lp_exec L (pBOOL 8 d a b)) x)).
    rewrite lp_mem_at_lp_exec_BOOL. exact (Hmem x).
  - change (Nat.eqb (e_bool_res 8 (vm_reg vm a) (vm_reg vm b)) 0 =
            Nat.eqb
              (((pack_k
                  (N.eqb (N.land (lget_regN (lp_reg L) a) 255%N) 0)
                  false) / 2) mod 2) 1).
    rewrite Hvalvm.
    rewrite (e_bool_res_8_255 (vm_reg vm a)) by (rewrite HA'; exact (Hbound a Ha)).
    rewrite pack_k_zf.
    rewrite N_eqb_to_nat.
    rewrite N_land_255_to_nat.
    rewrite HA'.
    reflexivity.
  - change (false =
            Nat.eqb
              ((pack_k
                  (N.eqb (N.land (lget_regN (lp_reg L) a) 255%N) 0)
                  false) mod 2) 1).
    rewrite pack_k_lf. reflexivity.
  - apply pack_k_lt_4.
  - change (vm_halted vm = lp_halted L). exact Hhalt.
  - intros i Hi.
    change (N.to_nat
              (lget_regN
                (lset_word (lp_reg L) d
                  (N.land (lget_regN (lp_reg L) a) 255%N)) i)
            < 2 ^ 32).
    destruct (Nat.eq_dec i d) as [-> | Hne].
    + rewrite (lget_regN_lset_word_eq (lp_reg L) d
        (N.land (lget_regN (lp_reg L) a) 255%N))
        by (rewrite Hlen; lia).
      rewrite N_land_255_to_nat.
      exact Hmod_lt.
    + rewrite (lget_regN_lset_word_neq (lp_reg L) d
        (N.land (lget_regN (lp_reg L) a) 255%N) i Hne).
      exact (Hbound i Hi).
Qed.

Print Assumptions lp_exec_BOOL8_255_refines.


(** ** ST *)

Lemma nan_mkwordN_payload :
  forall (v : N) (n : nat),
    word_payload (nan_mkwordN v n) = (v mod 2 ^ 32)%N.
Proof.
  intros v n.
  unfold nan_mkwordN.
  set (u := (N.land v word_mask32)%N).
  fold u.
  unfold word_payload.
  rewrite ones32.
  rewrite N.land_ones.
  rewrite N.shiftr_div_pow2.
  set (near := nan_head ((n / 4) mod 4)).
  set (far := swap16 (nan_head (n mod 4))).
  assert (Hshape :
    (N.shiftl near 48 + N.shiftl u 16 + far)%N
    = ((near * 2 ^ 32 + u) * 2 ^ 16 + far)%N).
  { rewrite !N.shiftl_mul_pow2. nia. }
  rewrite Hshape.
  rewrite N.div_add_l by (vm_compute; discriminate).
  assert (Hfar : (far / 2 ^ 16 = 0)%N).
  { apply N.div_small. unfold far. apply nan_head_swap16_lt. }
  rewrite Hfar. rewrite N.add_0_r.
  rewrite N.add_comm.
  rewrite N.Div0.mod_add.
  unfold u, word_mask32.
  rewrite ones32.
  rewrite N.land_ones.
  rewrite N.mod_mod by (vm_compute; discriminate).
  reflexivity.
Qed.

Lemma payload_word_nan_mkwordN :
  forall (v : N) (n : nat),
    payload_word (nan_mkwordN v n) = N.to_nat v mod 2 ^ 32.
Proof.
  intros v n.
  unfold payload_word.
  rewrite nan_mkwordN_payload.
  rewrite N2Nat.inj_mod.
  rewrite N2Nat.inj_pow.
  reflexivity.
Qed.

Theorem lp_exec_ST_refines :
  forall L vm prog d a imm,
    Rlp L vm ->
    MemP_wf (lp_mem L) ->
    d < 16 ->
    a < 16 ->
    lget_reg (lp_reg L) a + imm < 4366 ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some (pST d a imm) ->
    nth_error prog (vm_pc vm) = Some (pST d a imm) ->
    Rlp (lp_exec L (pST d a imm)) (exec_instr_p prog vm).
Proof.
  intros L vm prog d a imm HR Hwf Hd Ha Haddr_b Hdec Hnth.
  pose proof HR as HR_R.
  unfold Rlp in *.
  destruct HR as
    (Hpc & Hregs & Hreg15 & Hlink & Hmem & Hzf & Hlf & Hk & Hhalt & Hbound).
  pose proof (R_reg_eq (lp_to_LState L) vm a HR_R Ha) as Hreg_a.
  assert (Haddr : vm_reg vm a = lget_reg (lp_reg L) a).
  { unfold lget_reg. exact Hreg_a. }
  unfold lp_exec, exec_instr_p.
  rewrite Hnth. cbn.
  unfold R, lp_to_LState.
  split_conj_step.
  - change (S (vm_pc vm) = S (lp_pc L)). rewrite Hpc. reflexivity.
  - intros i Hi.
    change (vm_reg vm i = N.to_nat (lget_regN (lp_reg L) i) mod 2 ^ 32).
    exact (Hregs i Hi).
  - change (vm_reg vm 15 = N.to_nat (lget_regN (lp_reg L) 15) mod 2 ^ 32).
    exact Hreg15.
  - change (vm_link vm = N.to_nat (lget_regN (lp_reg L) 15)).
    exact Hlink.
  - intro x.
    change ((if Nat.eqb x (vm_reg vm a + imm) then vm_reg vm d
             else vm_mem vm x) =
            payload_word (lp_mem_at (lp_exec L (pST d a imm)) x)).
    rewrite lp_mem_at_lp_exec_ST.
    rewrite Haddr.
    destruct (Nat.eqb x (lget_reg (lp_reg L) a + imm)) eqn:Ex.
    + apply Nat.eqb_eq in Ex. subst x. cbn.
      rewrite (mem_get_mem_set_eq (lp_mem L)
        (lget_reg (lp_reg L) a + imm)
        (nan_mkwordN (lget_regN (lp_reg L) d) 10) Hwf Haddr_b).
      rewrite payload_word_nan_mkwordN.
      destruct (Nat.eq_dec d 15) as [-> | Hd15].
      * exact Hreg15.
      * apply (Hregs d). lia.
    + apply Nat.eqb_neq in Ex. cbn.
      rewrite (mem_get_mem_set_neq_all (lp_mem L)
        (lget_reg (lp_reg L) a + imm)
        (nan_mkwordN (lget_regN (lp_reg L) d) 10) x
        Hwf Haddr_b Ex).
      rewrite <- lp_mem_at_eq.
      exact (Hmem x).
  - change (vm_zf vm = Nat.eqb ((lp_k L / 2) mod 2) 1). exact Hzf.
  - change (vm_lf vm = Nat.eqb (lp_k L mod 2) 1). exact Hlf.
  - change (lp_k L < 4). exact Hk.
  - change (vm_halted vm = lp_halted L). exact Hhalt.
  - intros i Hi.
    change (N.to_nat (lget_regN (lp_reg L) i) < 2 ^ 32).
    exact (Hbound i Hi).
Qed.

Print Assumptions lp_exec_ST_refines.

(** ** Supported-instruction dispatcher

    [LPInstrSide] collects exactly the opcode-specific side conditions
    of the one-step table.  [lp_exec_instr_refines] then dispatches on
    the decoded constructor; block invariants and the register-file
    length are kept separate because they are preserved by every
    instruction and only need to be maintained once per run. *)

Definition LPInstrSide (L : LPState) (vm : VM) (ins : InstrP) : Prop :=
  match ins with
  | pCMP a b => a < 16 /\ b < 16
  | pJMP p target => lp_k L <> 3
  | pSHL d a imm =>
      d < 16 /\ d <> 15 /\ a < 16 /\ imm < 32 /\
      N.to_nat (lget_regN (lp_reg L) a) * 2 ^ imm < 2 ^ 32
  | pSHR d a imm => d < 16 /\ d <> 15 /\ a < 16 /\ imm < 32
  | pADD d a b =>
      d < 16 /\ d <> 15 /\ a < 16 /\ b < 16 /\
      N.to_nat (lget_regN (lp_reg L) a) +
        N.to_nat (lget_regN (lp_reg L) b) < 2 ^ 32
  | pSUB d a b =>
      d < 16 /\ d <> 15 /\ a < 16 /\ b < 16 /\
      N.to_nat (lget_regN (lp_reg L) b) <=
        N.to_nat (lget_regN (lp_reg L) a)
  | pLD d a imm => d < 16 /\ d <> 15 /\ a < 16
  | pST d a imm =>
      d < 16 /\ a < 16 /\ lget_reg (lp_reg L) a + imm < 4366
  | pMOVI d imm => d < 16 /\ d <> 15 /\ imm < 2 ^ 32
  | pBOOL tbl d a b =>
      tbl = 8 /\ d < 16 /\ d <> 15 /\ a < 16 /\ b < 16 /\
      lget_regN (lp_reg L) b = 255%N /\ vm_reg vm b = 255
  | pPUTC d => True
  | pCALL target => S (lp_pc L) < 2 ^ 32 /\ vm_reg vm 15 = S (lp_pc L)
  | pRET => True
  | pRETP p => lp_k L <> 3
  | pHALT => True
  end.

Theorem lp_exec_instr_refines :
  forall L vm prog ins,
    Rlp L vm ->
    List.length (lp_reg L) = 16 ->
    MemP_wf (lp_mem L) ->
    LPInstrSide L vm ins ->
    decode_word_p (lp_mem_at L (lp_pc L)) = Some ins ->
    nth_error prog (vm_pc vm) = Some ins ->
    Rlp (lp_exec L ins) (exec_instr_p prog vm).
Proof.
  intros L vm prog ins HR Hlen Hwf Hside Hdec Hnth.
  destruct ins as
    [a b | p target | d a imm | d a imm | d a b | d a b | d a imm
    | d a imm | d imm | tbl d a b | d | target | | p |].
  - red in Hside. destruct Hside as (Ha & Hb).
    apply lp_exec_CMP_refines; assumption.
  - red in Hside.
    exact (lp_exec_JMP_refines L vm prog p target HR Hside Hdec Hnth).
  - red in Hside. destruct Hside as (Hd & Hd15 & Ha & Himm & Hprod).
    apply lp_exec_SHL_refines; assumption.
  - red in Hside. destruct Hside as (Hd & Hd15 & Ha & Himm).
    apply lp_exec_SHR_refines; assumption.
  - red in Hside. destruct Hside as (Hd & Hd15 & Ha & Hb & Hsum).
    apply lp_exec_ADD_refines; assumption.
  - red in Hside. destruct Hside as (Hd & Hd15 & Ha & Hb & Hle).
    apply lp_exec_SUB_refines; assumption.
  - red in Hside. destruct Hside as (Hd & Hd15 & Ha).
    apply lp_exec_LD_refines; assumption.
  - red in Hside. destruct Hside as (Hd & Ha & Haddr).
    apply lp_exec_ST_refines; assumption.
  - red in Hside. destruct Hside as (Hd & Hd15 & Himm).
    apply lp_exec_MOVI_refines; assumption.
  - red in Hside.
    destruct Hside as (Htbl & Hd & Hd15 & Ha & Hb & Hbn & Hvb).
    subst tbl. apply lp_exec_BOOL8_255_refines; assumption.
  - red in Hside.
    apply lp_exec_PUTC_refines; assumption.
  - red in Hside. destruct Hside as (Hnext & Hlink).
    apply lp_exec_CALL_refines; assumption.
  - red in Hside.
    apply lp_exec_RET_refines; assumption.
  - red in Hside.
    apply lp_exec_RETP_refines; assumption.
  - red in Hside.
    apply lp_exec_HALT_refines; assumption.
Qed.

Print Assumptions lp_exec_instr_refines.

Lemma lp_exec_reg_length :
  forall L ins,
    List.length (lp_reg (lp_exec L ins)) = List.length (lp_reg L).
Proof.
  intros L ins. destruct ins; cbn; try reflexivity;
    apply lset_word_length.
Qed.

Lemma lp_exec_mem_wf :
  forall L ins,
    MemP_wf (lp_mem L) ->
    MemP_wf (lp_mem (lp_exec L ins)).
Proof.
  intros L ins Hwf. destruct ins; cbn; try exact Hwf;
    apply MemP_wf_mem_set; exact Hwf.
Qed.

Print Assumptions lp_exec_mem_wf.

(** ** Inductive run refinement

    [lp_run_safe] is the step-indexed safety certificate consumed by the
    run theorem.  It decodes the current word, checks that the Coq VM
    program has the same instruction at the same PC, checks the
    opcode-specific side conditions, and recurses on the two post-states.
    It is a [Prop] so the theorem stays independent of any reflection
    layer. *)

Fixpoint lp_run_safe
    (fuel : nat) (L : LPState) (vm : VM) (prog : list InstrP) : Prop :=
  match fuel with
  | 0 => True
  | S f =>
      if lp_halted L then True
      else
        match decode_word_p (lp_mem_at L (lp_pc L)) with
        | Some ins =>
            nth_error prog (vm_pc vm) = Some ins /\
            LPInstrSide L vm ins /\
            lp_run_safe f (lp_exec L ins) (exec_instr_p prog vm) prog
        | None => False
        end
  end.

Fixpoint vm_run_p
    (fuel : nat) (prog : list InstrP) (vm : VM) : VM :=
  match fuel with
  | 0 => vm
  | S f => if vm_halted vm then vm
           else vm_run_p f prog (exec_instr_p prog vm)
  end.

Theorem lp_run_refines :
  forall fuel L vm prog,
    Rlp L vm ->
    List.length (lp_reg L) = 16 ->
    MemP_wf (lp_mem L) ->
    lp_run_safe fuel L vm prog ->
    Rlp (lp_run fuel L) (vm_run_p fuel prog vm) /\
    List.length (lp_reg (lp_run fuel L)) = 16 /\
    MemP_wf (lp_mem (lp_run fuel L)).
Proof.
  intros fuel. induction fuel as [|fuel IH]; intros L vm prog HR Hlen Hwf Hsafe.
  - change (Rlp L vm /\ List.length (lp_reg L) = 16 /\
            MemP_wf (lp_mem L)).
    split; [exact HR | split; [exact Hlen | exact Hwf]].
  - cbn [lp_run vm_run_p].
    destruct (lp_halted L) eqn:Hhalt.
    + assert (Hvm : vm_halted vm = true).
      { pose proof HR as HR'.
        unfold Rlp in HR'.
        destruct HR' as
          (_ & _ & _ & _ & _ & _ & _ & _ & Hvm & _).
        rewrite Hvm. exact Hhalt. }
      rewrite Hvm.
      change (Rlp L vm /\ List.length (lp_reg L) = 16 /\
              MemP_wf (lp_mem L)).
      split; [exact HR | split; [exact Hlen | exact Hwf]].
    + assert (Hvm : vm_halted vm = false).
      { pose proof HR as HR'.
        unfold Rlp in HR'.
        destruct HR' as
          (_ & _ & _ & _ & _ & _ & _ & _ & Hvm & _).
        rewrite Hvm. exact Hhalt. }
      rewrite Hvm.
      change (Rlp (lp_run fuel (lp_step L))
                (vm_run_p fuel prog (exec_instr_p prog vm)) /\
              List.length (lp_reg (lp_run fuel (lp_step L))) = 16 /\
              MemP_wf (lp_mem (lp_run fuel (lp_step L)))).
      rewrite Hhalt in Hsafe.
      cbn [lp_run_safe] in Hsafe.
      destruct (decode_word_p (lp_mem_at L (lp_pc L))) as [ins|] eqn:Hdec.
      2: { rewrite Hdec in Hsafe. cbn in Hsafe. contradiction. }
      rewrite Hdec in Hsafe. cbn in Hsafe.
      destruct Hsafe as (Hnth & Hside & Hsafe').
      assert (Hstep : lp_step L = lp_exec L ins).
      { unfold lp_step. rewrite <- lp_mem_at_eq. rewrite Hdec. reflexivity. }
      rewrite Hstep.
      apply IH.
      * exact (lp_exec_instr_refines L vm prog ins HR Hlen Hwf Hside Hdec Hnth).
      * rewrite lp_exec_reg_length. exact Hlen.
      * apply lp_exec_mem_wf. exact Hwf.
      * exact Hsafe'.
Qed.

Print Assumptions lp_run_refines.
