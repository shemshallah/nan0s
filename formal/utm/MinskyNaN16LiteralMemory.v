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

Lemma mem_get_mem_set_eq :
  forall m a v,
    MemP_wf m ->
    a < 4366 ->
    mem_get (mem_set m a v) a = v.
Proof.
  intros m a v Hwf Ha.
  destruct Hwf as (H1 & H2 & H3 & H4 & H5).
  unfold mem_set, mem_get.
  destruct (a <? tape_lo) eqn:E1;
    destruct (a <? data_hi) eqn:E2;
    destruct (a <? code_hi) eqn:E3;
    destruct (a <? tape_hi) eqn:E4;
    cbn.
  all: try (exfalso; lia).
  all: try (apply nth_lset_word_eq;
            rewrite ?H1, ?H2, ?H3, ?H4, ?H5; lia).
Qed.

Print Assumptions mem_get_mem_set_eq.
