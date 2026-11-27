(** * ST memory bridge: block invariant and update lemmas

    [mem_set] updates one of the five [MemP] block lists.  The ST
    refinement needs the block lengths to survive every update so the
    updated index remains inside its list.  This module starts with the
    invariant and the list-level update facts; the projection lemmas
    [mem_get_mem_set_eq]/[_neq] are the next layer. *)

From Coq Require Import List Arith Bool Lia NArith String.
Import ListNotations.
From NaNLM Require Import MinskyNaN16LiteralMachine MinskyNaN16LiteralDecode.

Open Scope nat_scope.

Definition MemP_wf (m : MemP) : Prop :=
  List.length (mp_low m) = 99 /\
  List.length (mp_data m) = 1477 /\
  List.length (mp_pad m) = 2520 /\
  List.length (mp_tape m) = 256 /\
  List.length (mp_str m) = 14.

Lemma lset_word_length :
  forall (l : list N) i v,
    List.length (lset_word l i v) = List.length l.
Proof.
  intros l. induction l as [|x xs IH]; intros i v.
  - reflexivity.
  - destruct i; simpl; [reflexivity|rewrite IH; reflexivity].
Qed.

Lemma MemP_wf_reset : MemP_wf reset_mem.
Proof.
  unfold MemP_wf, reset_mem.
  repeat split;
    rewrite ?firstn_length, ?skipn_length;
    rewrite ?literal_image_4366; cbn; lia.
Qed.

Lemma MemP_wf_mem_set :
  forall m a v, MemP_wf m -> MemP_wf (mem_set m a v).
Proof.
  intros m a v (H1 & H2 & H3 & H4 & H5).
  unfold MemP_wf, mem_set.
  destruct (a <? tape_lo) eqn:E1;
    destruct (a <? data_hi) eqn:E2;
    destruct (a <? code_hi) eqn:E3;
    destruct (a <? tape_hi) eqn:E4;
    cbn;
    repeat split;
    try (rewrite lset_word_length);
    assumption.
Qed.

Print Assumptions MemP_wf_reset.
Print Assumptions MemP_wf_mem_set.

Lemma nth_lset_word_eq :
  forall (l : list N) i v,
    i < List.length l ->
    nth i (lset_word l i v) 0%N = v.
Proof.
  intros l. induction l as [|x xs IH]; intros i v Hi.
  - simpl in Hi. lia.
  - destruct i as [|i].
    + reflexivity.
    + simpl. apply IH. simpl in Hi. lia.
Qed.

Lemma mem_get_mem_set_low :
  forall m a v, MemP_wf m -> a < code_hi ->
    mem_get (mem_set m a v) a = v.
Proof.
  intros m a v (H1 & H2 & H3 & H4 & H5) Ha.
  unfold mem_set, mem_get.
  assert (E1 : (a <? tape_lo) = true)
    by (apply Nat.ltb_lt; unfold code_hi, tape_lo in *; lia).
  assert (E2 : (a <? data_hi) = true)
    by (apply Nat.ltb_lt; unfold code_hi, data_hi in *; lia).
  assert (E3 : (a <? code_hi) = true)
    by (apply Nat.ltb_lt; exact Ha).
  rewrite E1, E2, E3. cbn.
  apply nth_lset_word_eq. rewrite H1. unfold code_hi in Ha. exact Ha.
Qed.

Lemma mem_get_mem_set_data :
  forall m a v, MemP_wf m -> code_hi <= a -> a < data_hi ->
    mem_get (mem_set m a v) a = v.
Proof.
  intros m a v (H1 & H2 & H3 & H4 & H5) Hlo Hhi.
  unfold mem_set, mem_get.
  assert (E1 : (a <? tape_lo) = true)
    by (apply Nat.ltb_lt; unfold tape_lo, data_hi, code_hi in *; lia).
  assert (E2 : (a <? data_hi) = true)
    by (apply Nat.ltb_lt; exact Hhi).
  assert (E3 : (a <? code_hi) = false)
    by (apply Nat.ltb_ge; exact Hlo).
  rewrite E1, E2, E3. cbn.
  apply nth_lset_word_eq.
  rewrite H2. unfold data_lo, code_hi in *. lia.
Qed.

Lemma mem_get_mem_set_pad :
  forall m a v, MemP_wf m -> data_hi <= a -> a < tape_lo ->
    mem_get (mem_set m a v) a = v.
Proof.
  intros m a v (H1 & H2 & H3 & H4 & H5) Hlo Hhi.
  unfold mem_set, mem_get.
  assert (E1 : (a <? tape_lo) = true)
    by (apply Nat.ltb_lt; exact Hhi).
  assert (E2 : (a <? data_hi) = false)
    by (apply Nat.ltb_ge; exact Hlo).
  rewrite E1, E2. cbn.
  apply nth_lset_word_eq.
  rewrite H3. unfold pad_lo, data_hi in *. lia.
Qed.

Lemma mem_get_mem_set_tape :
  forall m a v, MemP_wf m -> tape_lo <= a -> a < tape_hi ->
    mem_get (mem_set m a v) a = v.
Proof.
  intros m a v (H1 & H2 & H3 & H4 & H5) Hlo Hhi.
  unfold mem_set, mem_get.
  assert (E1 : (a <? tape_lo) = false)
    by (apply Nat.ltb_ge; exact Hlo).
  assert (E4 : (a <? tape_hi) = true)
    by (apply Nat.ltb_lt; exact Hhi).
  rewrite E1, E4. cbn.
  apply nth_lset_word_eq.
  rewrite H4. unfold tape_lo, tape_hi in *. lia.
Qed.

Lemma mem_get_mem_set_str :
  forall m a v, MemP_wf m -> tape_hi <= a -> a < 4366 ->
    mem_get (mem_set m a v) a = v.
Proof.
  intros m a v (H1 & H2 & H3 & H4 & H5) Hlo Hhi.
  unfold mem_set, mem_get.
  assert (E1 : (a <? tape_lo) = false)
    by (apply Nat.ltb_ge; unfold tape_lo, tape_hi in *; lia).
  assert (E4 : (a <? tape_hi) = false)
    by (apply Nat.ltb_ge; exact Hlo).
  rewrite E1, E4. cbn.
  apply nth_lset_word_eq.
  rewrite H5. unfold str_lo, tape_hi in *. lia.
Qed.

Lemma mem_get_mem_set_eq :
  forall m a v, MemP_wf m -> a < 4366 ->
    mem_get (mem_set m a v) a = v.
Proof.
  intros m a v Hwf Ha.
  destruct (a <? code_hi) eqn:E3.
  - apply mem_get_mem_set_low; auto.
    apply Nat.ltb_lt in E3. exact E3.
  - apply Nat.ltb_ge in E3.
    destruct (a <? data_hi) eqn:E2.
    + apply mem_get_mem_set_data; auto.
      * exact E3.
      * apply Nat.ltb_lt in E2. exact E2.
    + apply Nat.ltb_ge in E2.
      destruct (a <? tape_lo) eqn:E1.
      * apply mem_get_mem_set_pad; auto.
        { exact E2. }
        { apply Nat.ltb_lt in E1. exact E1. }
      * apply Nat.ltb_ge in E1.
        destruct (a <? tape_hi) eqn:E4.
        -- apply mem_get_mem_set_tape; auto.
           + exact E1.
           + apply Nat.ltb_lt in E4. exact E4.
        -- apply mem_get_mem_set_str; auto.
           + apply Nat.ltb_ge in E4. exact E4.
           + exact Ha.
Qed.

Print Assumptions mem_get_mem_set_eq.
