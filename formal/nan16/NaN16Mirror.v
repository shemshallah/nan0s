(* NaN16 palindromic mirror geometry: a finite, explicit foundation. *)
(* All statements use the standard Coq kernel; no axioms or Admitted. *)
From Coq Require Import Arith Lia List.
Import ListNotations.

Definition cell : Type := (nat * nat)%type.
Definition byte_bound : nat := 256.

Definition valid (n : nat) (p : cell) : Prop :=
  fst p < n /\ snd p < n.

Definition mirror (p : cell) : cell := (snd p, fst p).
Definition canonical (p : cell) : Prop := fst p <= snd p.

Definition project (p : cell) : cell :=
  if Nat.leb (fst p) (snd p) then p else mirror p.

Lemma mirror_involutive : forall p, mirror (mirror p) = p.
Proof. intros [a b]; reflexivity. Qed.

Lemma mirror_preserves_valid : forall n p,
  valid n p -> valid n (mirror p).
Proof.
  intros n [a b] [Ha Hb]. unfold valid, mirror in *.
  simpl in *. split; assumption.
Qed.

Lemma mirror_fixed_iff_diagonal : forall p,
  mirror p = p <-> fst p = snd p.
Proof.
  intros [a b]; simpl. split.
  - intro H. inversion H. reflexivity.
  - intro H. subst. reflexivity.
Qed.

Lemma project_canonical : forall p, canonical (project p).
Proof.
  intros [a b]. unfold canonical, project, mirror. simpl.
  destruct (Nat.leb a b) eqn:Hab; simpl.
  - apply Nat.leb_le in Hab. exact Hab.
  - apply Nat.leb_gt in Hab. lia.
Qed.

Lemma project_preserves_valid : forall n p,
  valid n p -> valid n (project p).
Proof.
  intros n [a b] [Ha Hb]. unfold project, valid, mirror in *.
  simpl in *. destruct (Nat.leb a b); simpl; tauto.
Qed.

Lemma project_on_canonical : forall p,
  canonical p -> project p = p.
Proof.
  intros [a b] H. unfold canonical, project in *.
  simpl in *. assert (Nat.leb a b = true) as E.
  { apply Nat.leb_le. exact H. }
  rewrite E. reflexivity.
Qed.

Lemma project_idempotent : forall p,
  project (project p) = project p.
Proof.
  intro p. apply project_on_canonical. apply project_canonical.
Qed.

Lemma project_mirror : forall p,
  project (mirror p) = project p.
Proof.
  intros [a b]. unfold project, mirror. simpl.
  destruct (Nat.leb a b) eqn:Hab;
    destruct (Nat.leb b a) eqn:Hba; simpl; try reflexivity.
  - apply Nat.leb_le in Hab. apply Nat.leb_le in Hba.
    assert (a = b) by lia. subst. reflexivity.
  - apply Nat.leb_gt in Hab. apply Nat.leb_gt in Hba. lia.
Qed.

Lemma every_cell_has_canonical_representative : forall n p,
  valid n p ->
  valid n (project p) /\
  canonical (project p) /\
  (project p = p \/ project p = mirror p).
Proof.
  intros n [a b] Hvalid.
  split.
  - apply project_preserves_valid. exact Hvalid.
  - split.
    + apply project_canonical.
    + unfold project, mirror. simpl.
      destruct (Nat.leb a b); [left | right]; reflexivity.
Qed.

Lemma canonical_and_mirror_canonical_force_diagonal : forall p,
  canonical p -> canonical (mirror p) -> mirror p = p.
Proof.
  intros [a b] H1 H2. unfold canonical, mirror in *.
  simpl in *. assert (a = b) by lia. subst. reflexivity.
Qed.

Lemma strict_pair_has_distinct_mirror : forall a b,
  a < b -> (a, b) <> mirror (a, b).
Proof.
  intros a b Hlt Heq. unfold mirror in Heq. simpl in Heq.
  inversion Heq. lia.
Qed.

(* List each unordered pair of distinct indices exactly once, with a < b. *)
Fixpoint upper_pairs (n : nat) : list cell :=
  match n with
  | O => []
  | S k => upper_pairs k ++ map (fun a => (a, k)) (seq 0 k)
  end.

Fixpoint choose2 (n : nat) : nat :=
  match n with
  | O => O
  | S k => k + choose2 k
  end.

Definition diagonal (n : nat) : list cell :=
  map (fun a => (a, a)) (seq 0 n).

Lemma upper_pairs_sound : forall n p,
  In p (upper_pairs n) -> fst p < snd p /\ snd p < n.
Proof.
  induction n as [|n IH]; intros [a b] Hin; simpl in Hin.
  - contradiction.
  - apply in_app_or in Hin. destruct Hin as [Hold | Hnew].
    + destruct (IH (a, b) Hold) as [Hlt Hbound].
      simpl in *. split; lia.
    + apply in_map_iff in Hnew.
      destruct Hnew as [i [Heq Hi]]. inversion Heq; subst.
      apply in_seq in Hi. simpl. split; lia.
Qed.

Lemma upper_pairs_complete : forall n a b,
  a < b -> b < n -> In (a, b) (upper_pairs n).
Proof.
  induction n as [|n IH]; intros a b Hab Hbn.
  - simpl. lia.
  - simpl. apply in_or_app.
    destruct (Nat.eq_dec b n) as [Heq | Hneq].
    + right. apply in_map_iff. exists a. split.
      * subst b. reflexivity.
      * apply in_seq. lia.
    + left. apply IH; lia.
Qed.

Lemma nodup_seq : forall start count,
  NoDup (seq start count).
Proof.
  intros start count. revert start.
  induction count as [|count IH]; intros start; simpl.
  - constructor.
  - constructor.
    + intro Hin. apply in_seq in Hin. lia.
    + apply IH.
Qed.

Lemma nodup_column : forall (l : list nat) (k : nat),
  NoDup l -> NoDup (map (fun a => (a, k)) l).
Proof.
  intros l k Hl. induction Hl as [|a xs Hnotin Hnodup IH]; simpl.
  - constructor.
  - constructor.
    + intro Hin. apply in_map_iff in Hin.
      destruct Hin as [b [Heq Hb]]. inversion Heq; subst.
      contradiction.
    + exact IH.
Qed.

Lemma nodup_append_disjoint : forall (l r : list cell),
  NoDup l -> NoDup r ->
  (forall x, In x l -> ~ In x r) -> NoDup (l ++ r).
Proof.
  intros l r Hl. revert r.
  induction Hl as [|x xs Hnotin Hnodup IH]; intros r Hr Hdis; simpl.
  - exact Hr.
  - constructor.
    + intro Hin. apply in_app_or in Hin. destruct Hin as [Hin | Hin].
      * contradiction.
      * apply (Hdis x); [left; reflexivity | exact Hin].
    + apply IH.
      * exact Hr.
      * intros y Hy. apply Hdis. right. exact Hy.
Qed.

Lemma upper_pairs_nodup : forall n, NoDup (upper_pairs n).
Proof.
  induction n as [|n IH]; simpl.
  - constructor.
  - apply nodup_append_disjoint.
    + exact IH.
    + apply nodup_column. apply nodup_seq.
    + intros [a b] Hold Hnew.
      destruct (upper_pairs_sound n (a, b) Hold) as [_ Hb].
      apply in_map_iff in Hnew.
      destruct Hnew as [i [Heq _]]. inversion Heq; subst.
      simpl in Hb. lia.
Qed.

Lemma upper_pairs_length : forall n,
  length (upper_pairs n) = choose2 n.
Proof.
  induction n as [|n IH]; simpl.
  - reflexivity.
  - rewrite app_length, map_length, seq_length, IH. lia.
Qed.

Lemma choose2_identity : forall n,
  2 * choose2 n + n = n * n.
Proof.
  induction n as [|n IH]; simpl; nia.
Qed.

Lemma diagonal_length : forall n,
  length (diagonal n) = n.
Proof.
  intros n. unfold diagonal. rewrite map_length, seq_length. reflexivity.
Qed.

Theorem nan16_mirror_counts :
  length (upper_pairs byte_bound) = 32640 /\
  length (diagonal byte_bound) = 256 /\
  2 * length (upper_pairs byte_bound) +
    length (diagonal byte_bound) = 65536 /\
  length (upper_pairs byte_bound) +
    length (diagonal byte_bound) = 32896.
Proof.
  unfold byte_bound.
  rewrite upper_pairs_length, diagonal_length.
  assert (H : choose2 256 = 32640) by (vm_compute; reflexivity).
  repeat split; lia.
Qed.

(* Injective flat addressing of the 256 x 256 cell lattice. *)
Definition flat_addr (a b : nat) : nat := a * byte_bound + b.

Lemma flat_addr_in_range : forall a b,
  a < byte_bound -> b < byte_bound -> flat_addr a b < 65536.
Proof.
  intros a b Ha Hb. unfold flat_addr, byte_bound in *.
  assert (Ha' : a <= 255) by lia.
  assert (Hb' : b <= 255) by lia.
  nia.
Qed.

Lemma flat_addr_injective : forall a b c d,
  a < byte_bound -> b < byte_bound ->
  c < byte_bound -> d < byte_bound ->
  flat_addr a b = flat_addr c d -> a = c /\ b = d.
Proof.
  intros a b c d Ha Hb Hc Hd Heq.
  unfold flat_addr, byte_bound in *.
  assert (Hac : a <= c) by nia.
  assert (Hca : c <= a) by nia.
  assert (Hequal : a = c) by lia.
  subst c. split; [reflexivity | nia].
Qed.
