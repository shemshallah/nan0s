(* Two signed orientations of each strict NaN16 mirror pair. *)
From Coq Require Import Arith Lia List.
Require Import NaN16Mirror.

Inductive polarity : Type := Splus | Sminus.

Definition flip_polarity (s : polarity) : polarity :=
  match s with Splus => Sminus | Sminus => Splus end.

Definition oriented (p : cell) (s : polarity) : cell :=
  match s with Splus => p | Sminus => mirror p end.

Definition signed_mirror (entry : cell * polarity) : cell * polarity :=
  (mirror (fst entry), flip_polarity (snd entry)).

Lemma flip_polarity_involutive : forall s,
  flip_polarity (flip_polarity s) = s.
Proof. intros []; reflexivity. Qed.

Lemma signed_mirror_involutive : forall entry,
  signed_mirror (signed_mirror entry) = entry.
Proof.
  intros [p s]. unfold signed_mirror. simpl.
  rewrite mirror_involutive, flip_polarity_involutive. reflexivity.
Qed.

Lemma oriented_flip : forall p s,
  mirror (oriented p s) = oriented p (flip_polarity s).
Proof.
  intros p [|]; simpl; [reflexivity | apply mirror_involutive].
Qed.

Lemma signed_mirror_preserves_orientation : forall p s,
  oriented (mirror p) (flip_polarity s) = oriented p s.
Proof.
  intros p [|]; simpl; [apply mirror_involutive | reflexivity].
Qed.

Lemma signed_orientation_injective : forall p q s t,
  fst p < snd p -> fst q < snd q ->
  oriented p s = oriented q t -> p = q /\ s = t.
Proof.
  intros [a b] [c d] s t Hab Hcd Heq.
  simpl in Hab, Hcd.
  destruct s; destruct t; unfold oriented, mirror in Heq; simpl in Heq.
  - inversion Heq; subst. split; reflexivity.
  - inversion Heq; subst. lia.
  - inversion Heq; subst. lia.
  - inversion Heq; subst. split; reflexivity.
Qed.

Theorem signed_representation_complete : forall p,
  valid byte_bound p -> fst p <> snd p ->
  exists q s,
    In q (upper_pairs byte_bound) /\ oriented q s = p.
Proof.
  intros [a b] Hvalid Hneq.
  unfold valid in Hvalid. simpl in Hvalid, Hneq.
  destruct Hvalid as [Ha Hb].
  destruct (lt_dec a b) as [Hab | Hnot].
  - exists (a, b), Splus. split.
    + apply upper_pairs_complete; assumption.
    + reflexivity.
  - assert (Hba : b < a) by lia.
    exists (b, a), Sminus. split.
    + apply upper_pairs_complete; assumption.
    + reflexivity.
Qed.

Theorem signed_representation_unique : forall q r s t,
  In q (upper_pairs byte_bound) ->
  In r (upper_pairs byte_bound) ->
  oriented q s = oriented r t -> q = r /\ s = t.
Proof.
  intros q r s t Hq Hr Heq.
  destruct (upper_pairs_sound _ q Hq) as [Hqs _].
  destruct (upper_pairs_sound _ r Hr) as [Hrs _].
  eapply signed_orientation_injective; eauto.
Qed.

(* Interpret S+/S- as W[a][b] and W[b][a] of the same source table. *)
Definition channel_value {A : Type} (W : cell -> A)
    (p : cell) (s : polarity) : A := W (oriented p s).

Lemma channel_mirror : forall (A : Type) (W : cell -> A) p s,
  channel_value W (mirror p) s =
  channel_value W p (flip_polarity s).
Proof.
  intros A W p [|]; unfold channel_value, oriented; simpl.
  - reflexivity.
  - rewrite mirror_involutive. reflexivity.
Qed.

Theorem signed_pair_count :
  2 * length (upper_pairs byte_bound) = 65280.
Proof.
  destruct nan16_mirror_counts as [H _]. rewrite H. reflexivity.
Qed.
