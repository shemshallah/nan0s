(** * Bounded-window loader for the literal interpreter

    The concrete fixture run starts from [lp_reset], whose tape block is
    the fixed literal image.  This module starts the universality lift by
    loading an arbitrary 256-cell source window into that block.

    The final universality theorem quantifies a window depth [K] and a
    signed source tape [a_tape].  A window fits the literal machine only
    when its 256 cells are the ones the run visits; that is the bounded
    representative of the still-open finite-memory/unbounded-tape bridge.

    Results:

      - [lp_load_tape] replaces the tape block of [reset_mem];
      - [MemP_wf_lp_load_tape] and [Rlp_lp_load_window] show the loaded
        state still satisfies the executor invariants;
      - [lp_load_window_tape] proves the loaded memory realizes
        [win_mem] at every one of the 256 tape addresses;
      - [bounded_window_bridge] applies [lp_run_refines] to any loaded
        window, leaving only the safety certificate as a hypothesis. *)

From Coq Require Import List Arith Bool Lia NArith String ZArith.
Import ListNotations.
From NaNLM Require Import MinskyNaN16VM MinskyNaN16LiteralMachine
  MinskyNaN16LiteralDecode MinskyNaN16LiteralBridge
  MinskyNaN16LiteralStepBridge MinskyNaN16LiteralMemory
  MinskyNaN16LiteralImage MinskyNaN16LiteralPuts
  MinskyNaN16RunConcrete MinskyNaN16Window MinskyAddressRefinement.

Open Scope nat_scope.

(** ** The literal tape-word constructor

    The payload projection ignores the head, so a window cell is stored
    as [nan_mkwordN (N.of_nat x) 0]. *)

Definition tape_word (x : nat) : N :=
  nan_mkwordN (N.of_nat x) 0.

Lemma payload_word_tape_word :
  forall (x : nat), payload_word (tape_word x) = (x mod 2 ^ 32)%nat.
Proof.
  intros x. unfold tape_word, payload_word.
  rewrite nan_mkwordN_payload.
  rewrite N2Nat.inj_mod.
  rewrite N2Nat.inj_pow.
  rewrite Nat2N.id.
  reflexivity.
Qed.

(** ** Loading an arbitrary tape block *)

Definition lp_load_tape (tape : list N) : LPState :=
  {| lp_pc := 0;
     lp_reg := regs0;
     lp_mem :=
       {| mp_low := mp_low reset_mem;
          mp_data := mp_data reset_mem;
          mp_pad := mp_pad reset_mem;
          mp_tape := firstn 256 (tape ++ repeat 0%N 256);
          mp_str := mp_str reset_mem |};
     lp_k := 0;
     lp_halted := false;
     lp_out := EmptyString |}.

Definition window_tape (c : AddressConfig) (K : nat) : list N :=
  map (fun i =>
         tape_word (win_mem c fixture_tape_base K
                      (fixture_tape_base + i)))
      (seq 0 256).

Definition lp_load_window (c : AddressConfig) (K : nat) : LPState :=
  lp_load_tape (window_tape c K).

Lemma MemP_wf_lp_load_tape :
  forall tape, MemP_wf (lp_mem (lp_load_tape tape)).
Proof.
  intro tape. unfold MemP_wf, lp_load_tape.
  cbn [lp_mem mp_low mp_data mp_pad mp_tape mp_str].
  destruct MemP_wf_reset as (H1 & H2 & H3 & H4 & H5).
  repeat split; try assumption.
  rewrite length_firstn, length_app.
  cbn [length repeat].
  rewrite Nat.min_l by (rewrite Nat.add_comm; apply Nat.le_add_r).
  reflexivity.
Qed.

Lemma Rlp_core_lp_load_tape :
  forall tape,
    Rlp_core (lp_load_tape tape) (vm_of_lp (lp_load_tape tape)).
Proof.
  intro tape. constructor.
  - reflexivity.
  - intros i Hi.
    change (0%nat = Nat.modulo (N.to_nat (lget_regN regs0 i)) (2 ^ 32)%nat).
    rewrite lget_regN_regs0.
    symmetry. apply Nat.mod_0_l. exact two32_neq_0.
  - change (0%nat = Nat.modulo (N.to_nat (lget_regN regs0 15)) (2 ^ 32)%nat).
    rewrite lget_regN_regs0.
    symmetry. apply Nat.mod_0_l. exact two32_neq_0.
  - change (0%nat = N.to_nat (lget_regN regs0 15)).
    rewrite lget_regN_regs0. reflexivity.
  - reflexivity.
  - reflexivity.
  - change (Nat.lt 0 4). lia.
  - reflexivity.
  - intros i Hi.
    change (Nat.lt (N.to_nat (lget_regN regs0 i)) (2 ^ 32)%nat).
    rewrite lget_regN_regs0.
    pose proof one_lt_two32. lia.
Qed.

Lemma Rlp_lp_load_tape :
  forall tape, Rlp (lp_load_tape tape) (vm_of_lp (lp_load_tape tape)).
Proof.
  intro tape.
  apply R_of_core_mem.
  - apply Rlp_core_lp_load_tape.
  - apply vm_mem_of_lp.
Qed.

Lemma Rlp_lp_load_window :
  forall c K, Rlp (lp_load_window c K) (vm_of_lp (lp_load_window c K)).
Proof. intros c K. apply Rlp_lp_load_tape. Qed.

(** ** Tape-cell projection *)

Lemma mem_get_tape :
  forall (m : MemP) i,
    i < 256 ->
    mem_get m (fixture_tape_base + i) = nth i (mp_tape m) 0%N.
Proof.
  intros m i Hi.
  unfold mem_get, tape_lo, data_hi, code_hi, tape_hi, str_lo,
    fixture_tape_base.
  assert (E1 : (4096 + i <? 4096) = false)
    by (apply Nat.ltb_ge; lia).
  assert (E4 : (4096 + i <? 4352) = true)
    by (apply Nat.ltb_lt; lia).
  rewrite E1, E4.
  replace (4096 + i - 4096) with i by lia.
  reflexivity.
Qed.

Lemma nth_window_tape :
  forall c K i,
    i < 256 ->
    nth i (firstn 256 (window_tape c K ++ repeat 0%N 256)) 0%N =
    tape_word (win_mem c fixture_tape_base K (fixture_tape_base + i)).
Proof.
  intros c K i Hi.
  rewrite nth_firstn_lt by exact Hi.
  rewrite app_nth1.
  - unfold window_tape.
    rewrite nth_map_seq_lt by exact Hi.
    replace (0 + i) with i by lia.
    reflexivity.
  - unfold window_tape. rewrite length_map, length_seq. exact Hi.
Qed.

Lemma lp_load_window_tape :
  forall c K i,
    i < 256 ->
    win_mem c fixture_tape_base K (fixture_tape_base + i) < 2 ^ 32 ->
    payload_word (mem_get (lp_mem (lp_load_window c K))
                   (fixture_tape_base + i)) =
    win_mem c fixture_tape_base K (fixture_tape_base + i).
Proof.
  intros c K i Hi Hb.
  unfold lp_load_window, lp_load_tape.
  rewrite mem_get_tape by exact Hi.
  change (payload_word
    (nth i (firstn 256 (window_tape c K ++ repeat 0%N 256)) 0%N) =
    win_mem c fixture_tape_base K (fixture_tape_base + i)).
  rewrite nth_window_tape by exact Hi.
  rewrite payload_word_tape_word.
  apply Nat.mod_small. exact Hb.
Qed.

Lemma lp_load_window_vm_tape :
  forall c K i,
    i < 256 ->
    win_mem c fixture_tape_base K (fixture_tape_base + i) < 2 ^ 32 ->
    vm_mem (vm_of_lp (lp_load_window c K)) (fixture_tape_base + i) =
    win_mem c fixture_tape_base K (fixture_tape_base + i).
Proof.
  intros c K i Hi Hb.
  rewrite vm_mem_of_lp, lp_mem_at_eq.
  apply lp_load_window_tape; assumption.
Qed.

(** ** Code and table preservation

    The loader only replaces the tape block.  Every address below
    [fixture_tape_base] therefore still reads the reset image, and the
    fixture program decodes identically for every loaded window. *)

Lemma mem_get_lp_load_window_lt :
  forall c K a,
    a < fixture_tape_base ->
    mem_get (lp_mem (lp_load_window c K)) a = mem_get reset_mem a.
Proof.
  intros c K a Ha.
  unfold lp_load_window, lp_load_tape.
  unfold mem_get, tape_lo, data_hi, code_hi, pad_lo, tape_hi, str_lo,
    fixture_tape_base in *.
  assert (E1 : (a <? 4096) = true) by (apply Nat.ltb_lt; exact Ha).
  rewrite E1.
  destruct (a <? 1576) eqn:E2;
    destruct (a <? 99) eqn:E3;
    reflexivity.
Qed.

Lemma lp_load_window_decode :
  forall c K i,
    i < 99 ->
    decode_word_p (mem_get (lp_mem (lp_load_window c K)) i) =
    nth_error fixture_prog_full i.
Proof.
  intros c K i Hi.
  rewrite mem_get_lp_load_window_lt by (unfold fixture_tape_base; lia).
  rewrite mem_get_reset by lia.
  change (decode_word_p (literal_word_at i) = nth_error fixture_prog_full i).
  rewrite decode_full_pointwise by exact Hi.
  symmetry. apply nth_error_nth'.
  destruct literal_full_code_decodes as (_ & _ & Hlen).
  rewrite Hlen. exact Hi.
Qed.

(** ** The published reset tape is a loaded tape *)

Lemma lp_load_tape_reset :
  lp_load_tape (mp_tape reset_mem) = lp_reset.
Proof.
  unfold lp_load_tape, lp_reset.
  destruct MemP_wf_reset as (_ & _ & _ & Htape & _).
  assert (Hfirst :
    firstn 256 (mp_tape reset_mem ++ repeat 0%N 256) =
    mp_tape reset_mem).
  { rewrite firstn_app.
    assert (Hf : firstn 256 (mp_tape reset_mem) = mp_tape reset_mem).
    { rewrite <- Htape. apply firstn_all. }
    rewrite Hf.
    replace (256 - length (mp_tape reset_mem)) with 0 by lia.
    cbn. rewrite app_nil_r. reflexivity. }
  rewrite Hfirst.
  reflexivity.
Qed.

Theorem reset_loader_bridge :
  Rlp (lp_run 21025 lp_reset)
      (vm_run_p 21025 fixture_prog_full (vm_of_lp lp_reset)) /\
  List.length (lp_reg (lp_run 21025 lp_reset)) = 16 /\
  MemP_wf (lp_mem (lp_run 21025 lp_reset)).
Proof.
  rewrite <- lp_load_tape_reset.
  apply lp_run_refines.
  - apply Rlp_lp_load_tape.
  - reflexivity.
  - apply MemP_wf_lp_load_tape.
  - rewrite lp_load_tape_reset.
    apply lp_run_check_sound. exact fixture_run_check_true.
Qed.

(** ** Conditional bounded-window refinement *)

Theorem bounded_window_bridge :
  forall c K fuel,
    lp_run_safe fuel (lp_load_window c K) fixture_prog_full ->
    Rlp (lp_run fuel (lp_load_window c K))
        (vm_run_p fuel fixture_prog_full (vm_of_lp (lp_load_window c K))) /\
    List.length (lp_reg (lp_run fuel (lp_load_window c K))) = 16 /\
    MemP_wf (lp_mem (lp_run fuel (lp_load_window c K))).
Proof.
  intros c K fuel Hsafe.
  apply lp_run_refines.
  - apply Rlp_lp_load_window.
  - reflexivity.
  - apply MemP_wf_lp_load_tape.
  - exact Hsafe.
Qed.

Print Assumptions bounded_window_bridge.
