(* R5: mirror-equivariant, order-independent signed memory updates. *)
From Coq Require Import Arith Lia.
Require Import NaN16Mirror NaN16Signed NaN16Memory.

Definition reflect {A : Type} (W : cell -> A) : cell -> A :=
  fun p => W (mirror p).

Theorem reflect_involutive_pointwise :
  forall (A : Type) (W : cell -> A) p,
    reflect (reflect W) p = W p.
Proof.
  intros A W p. unfold reflect.
  rewrite mirror_involutive. reflexivity.
Qed.

Theorem store_commutes_if_disjoint :
  forall (A : Type) (W : cell -> A) x y vx vy query,
    x <> y ->
    store (store W x vx) y vy query =
    store (store W y vy) x vx query.
Proof.
  intros A W x y vx vy query Hxy.
  unfold store. cbn beta.
  destruct (cell_eq_dec query y) as [Hqy | Hqy];
  destruct (cell_eq_dec query x) as [Hqx | Hqx];
  try reflexivity.
  exfalso. apply Hxy. congruence.
Qed.

Theorem signed_writes_commute_pointwise :
  forall (A : Type) (W : cell -> A) p vp vm query,
    fst p < snd p ->
    store (store W (oriented p Splus) vp)
          (oriented p Sminus) vm query =
    store (store W (oriented p Sminus) vm)
          (oriented p Splus) vp query.
Proof.
  intros A W p vp vm query Hp.
  apply store_commutes_if_disjoint.
  apply signed_orientations_disjoint. exact Hp.
Qed.

Theorem reflect_store_pointwise :
  forall (A : Type) (W : cell -> A) key value query,
    reflect (store W key value) query =
    store (reflect W) (mirror key) value query.
Proof.
  intros A W key value query.
  unfold reflect, store. cbn beta.
  destruct (cell_eq_dec (mirror query) key) as [Hleft | Hleft];
  destruct (cell_eq_dec query (mirror key)) as [Hright | Hright].
  - reflexivity.
  - exfalso. apply Hright.
    apply (f_equal mirror) in Hleft.
    rewrite mirror_involutive in Hleft. exact Hleft.
  - exfalso. apply Hleft.
    apply (f_equal mirror) in Hright.
    rewrite mirror_involutive in Hright. exact Hright.
  - reflexivity.
Qed.

(* The fixed diagonal is intentionally excluded from non-aliasing theorems. *)
Theorem diagonal_orientations_coincide : forall a,
  oriented (a, a) Splus = oriented (a, a) Sminus.
Proof. intro a. reflexivity. Qed.
