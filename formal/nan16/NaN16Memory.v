(* Independent signed-channel memory writes for the NaN16 mirror lattice. *)
(* No axioms, admitted proofs, or assumptions about equal channel values. *)
From Coq Require Import Arith Lia.
Require Import NaN16Mirror NaN16Signed.

Definition cell_eq_dec (p q : cell) : {p = q} + {p <> q}.
Proof.
  decide equality; apply Nat.eq_dec.
Defined.

Definition store {A : Type} (W : cell -> A)
    (key : cell) (value : A) : cell -> A :=
  fun query => if cell_eq_dec query key then value else W query.

Lemma store_hit : forall (A : Type) (W : cell -> A) key value,
  store W key value key = value.
Proof.
  intros A W key value. unfold store.
  destruct (cell_eq_dec key key) as [_ | Hneq].
  - reflexivity.
  - exfalso. apply Hneq. reflexivity.
Qed.

Lemma store_miss : forall (A : Type) (W : cell -> A) key query value,
  query <> key -> store W key value query = W query.
Proof.
  intros A W key query value Hneq. unfold store.
  destruct (cell_eq_dec query key) as [Heq | _].
  - contradiction.
  - reflexivity.
Qed.

Lemma store_two_distinct : forall (A : Type) (W : cell -> A)
    x y vx vy,
  x <> y ->
  store (store W x vx) y vy x = vx /\
  store (store W x vx) y vy y = vy.
Proof.
  intros A W x y vx vy Hxy. split.
  - rewrite (store_miss A (store W x vx) y x vy Hxy).
    apply store_hit.
  - apply store_hit.
Qed.

Lemma signed_orientations_disjoint : forall p,
  fst p < snd p ->
  oriented p Splus <> oriented p Sminus.
Proof.
  intros [a b] Hab Heq.
  simpl in Hab, Heq.
  inversion Heq. lia.
Qed.

Theorem canonical_signed_roundtrip : forall p s,
  fst p < snd p -> project (oriented p s) = p.
Proof.
  intros p s Hp. destruct s.
  - change (project p = p).
    apply project_on_canonical. unfold canonical. lia.
  - change (project (mirror p) = p).
    rewrite project_mirror.
    apply project_on_canonical. unfold canonical. lia.
Qed.

Theorem signed_writes_do_not_alias :
  forall (A : Type) (W : cell -> A) p vp vm,
    fst p < snd p ->
    let W' := store (store W (oriented p Splus) vp)
                     (oriented p Sminus) vm in
    W' (oriented p Splus) = vp /\
    W' (oriented p Sminus) = vm.
Proof.
  intros A W p vp vm Hp.
  cbv zeta.
  apply store_two_distinct.
  apply signed_orientations_disjoint. exact Hp.
Qed.

Theorem signed_writes_preserve_other :
  forall (A : Type) (W : cell -> A) p vp vm x,
    x <> oriented p Splus ->
    x <> oriented p Sminus ->
    store (store W (oriented p Splus) vp)
          (oriented p Sminus) vm x = W x.
Proof.
  intros A W p vp vm x Hplus Hminus.
  rewrite store_miss by exact Hminus.
  rewrite store_miss by exact Hplus.
  reflexivity.
Qed.
