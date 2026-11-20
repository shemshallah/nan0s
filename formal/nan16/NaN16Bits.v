(* Bit-level semantics of the NaN16 palindromic mirror encoding. *)
From Coq Require Import List Lia.
Import ListNotations.

Definition byte_bits := list bool.
Definition byte_well_formed (b : byte_bits) : Prop := length b = 8.

(* High byte a; low byte the reversal of b, most-significant bit first. *)
Definition physical_bits (a b : byte_bits) : list bool := a ++ rev b.
Definition reverse16 (word : list bool) : list bool := rev word.

Lemma reverse16_involutive : forall word,
  reverse16 (reverse16 word) = word.
Proof. intro word. unfold reverse16. apply rev_involutive. Qed.

Lemma physical_width : forall a b,
  byte_well_formed a -> byte_well_formed b ->
  length (physical_bits a b) = 16.
Proof.
  intros a b Ha Hb. unfold byte_well_formed, physical_bits in *.
  rewrite app_length, rev_length. lia.
Qed.

Theorem physical_mirror_swap : forall a b,
  reverse16 (physical_bits a b) = physical_bits b a.
Proof.
  intros a b. unfold reverse16, physical_bits.
  rewrite rev_app_distr, rev_involutive. reflexivity.
Qed.

Lemma firstn_append_exact : forall (A : Type) (xs ys : list A),
  firstn (length xs) (xs ++ ys) = xs.
Proof.
  intros A xs. induction xs as [|x xs IH]; intro ys; simpl.
  - reflexivity.
  - rewrite IH. reflexivity.
Qed.

Lemma physical_first_byte : forall a b,
  byte_well_formed a -> firstn 8 (physical_bits a b) = a.
Proof.
  intros a b Ha. unfold physical_bits, byte_well_formed in *.
  rewrite <- Ha. apply firstn_append_exact.
Qed.

Theorem physical_encoding_injective : forall a b c d,
  byte_well_formed a -> byte_well_formed b ->
  byte_well_formed c -> byte_well_formed d ->
  physical_bits a b = physical_bits c d -> a = c /\ b = d.
Proof.
  intros a b c d Ha Hb Hc Hd Heq.
  assert (Hac : a = c).
  { pose proof Heq as Hfirst.
    apply (f_equal (firstn 8)) in Hfirst.
    rewrite (physical_first_byte a b Ha) in Hfirst.
    rewrite (physical_first_byte c d Hc) in Hfirst.
    exact Hfirst. }
  subst c.
  unfold physical_bits in Heq.
  apply app_inv_head in Heq.
  apply (f_equal (@rev bool)) in Heq.
  repeat rewrite rev_involutive in Heq.
  split; [reflexivity | exact Heq].
Qed.

Theorem physical_fixed_iff_diagonal : forall a b,
  byte_well_formed a -> byte_well_formed b ->
  reverse16 (physical_bits a b) = physical_bits a b <-> a = b.
Proof.
  intros a b Ha Hb.
  rewrite physical_mirror_swap.
  split.
  - intro H.
    destruct (physical_encoding_injective b a a b Hb Ha Ha Hb H)
      as [Hba _]. symmetry. exact Hba.
  - intro H. subst b. reflexivity.
Qed.
