; ntok.nas - deterministic byte-level tokenizer with a small BPE table (F7).
;
; Token ids:
;   0..255          the byte itself
;   256             BOS
;   257             EOS
;   258..281        merged tokens (24 merges, rank = id-258)
;   282             UNK
;   283             vocabulary size
;
; Encoding starts from one token per input byte and repeatedly merges the
; adjacent pair with the lowest table rank (leftmost on ties).  The table is
; a fixed ordered list, so the result is deterministic and independent of
; allocation or hash order.  All 256 byte values are in-vocabulary; UNK is
; only produced by an explicit out-of-vocabulary id path.
;
; API (r0=0, r13=1, r14 soft stack grows up):
;   ntok_bos / ntok_eos / ntok_unk -> id
;   ntok_vocab_size -> 283
;   ntok_merge_count -> 24
;   ntok_is_special r1=id -> 1 for BOS/EOS/UNK else 0
;   ntok_id_bytes r1=id -> byte length, 0 for BOS/EOS, -1 invalid
;   ntok_encode r1=input byte address r2=len r3=out word ptr r4=cap
;               -> token count or -1
;   ntok_decode_token r1=id r2=output byte address r3=cap -> bytes/-1
;   ntok_decode r1=id word ptr r2=count r3=output byte address r4=cap
;               -> bytes written or -1
;
; Scratch at 0x5200 (nkv 0x5000, nmodel 0x5400).

.equ NTK_BOS        256
.equ NTK_EOS        257
.equ NTK_MERGE_BASE 258
.equ NTK_MERGES     24
.equ NTK_UNK        282
.equ NTK_VOCAB      283

.equ NTK          0x5200
.equ NTK_IN       0x5200
.equ NTK_LEN      0x5201
.equ NTK_OUT      0x5202
.equ NTK_CAP      0x5203
.equ NTK_N        0x5204
.equ NTK_POS      0x5205
.equ NTK_BESTR    0x5206
.equ NTK_BESTP    0x5207
.equ NTK_BESTID   0x5208
.equ NTK_I        0x5209
.equ NTK_TMP      0x520A
.equ NTK_IDBUF    0x5230

; ---------------------------------------------------------------------------
ntok_bos:
  MOVI r1,#NTK_BOS
  RET
ntok_eos:
  MOVI r1,#NTK_EOS
  RET
ntok_unk:
  MOVI r1,#NTK_UNK
  RET
ntok_vocab_size:
  MOVI r1,#NTK_VOCAB
  RET
ntok_merge_count:
  MOVI r1,#NTK_MERGES
  RET

; ntok_is_special r1=id -> 1/0
ntok_is_special:
  MOVI r2,#NTK_BOS
  CMP r1,r2
  JMP[EQ] @ntok_sp_yes
  MOVI r2,#NTK_EOS
  CMP r1,r2
  JMP[EQ] @ntok_sp_yes
  MOVI r2,#NTK_UNK
  CMP r1,r2
  JMP[EQ] @ntok_sp_yes
  MOVI r1,0
  RET
ntok_sp_yes:
  MOVI r1,1
  RET

; nt_merge_lookup r1=left r2=right -> r1=new id r2=rank or r1=0 r2=-1
nt_merge_lookup:
  LA r3,@ntok_merges
  MOVI r4,0
nt_ml_l:
  MOVI r5,#NTK_MERGES
  CMP r4,r5
  JMP[GE] @nt_ml_no
  LD r5,r3,0
  CMP r5,r1
  JMP[NE] @nt_ml_next
  LD r5,r3,1
  CMP r5,r2
  JMP[NE] @nt_ml_next
  LD r1,r3,2
  ADD r2,r4,r0
  RET
nt_ml_next:
  ADDI r3,r3,3
  ADD r4,r4,r13
  JMP @nt_ml_l
nt_ml_no:
  MOVI r1,0
  LA r2,0xFFFFFFFF
  RET

; ---------------------------------------------------------------------------
; ntok_emit: r1=id r2=out byte address r3=cap -> bytes or -1 (recursive)
ntok_emit:
  ST r15,r14,0
  ST r12,r14,1
  ADD r12,r14,r0
  ADDI r12,r12,2
  ADDI r14,r14,8
  ST r1,r12,0
  ST r2,r12,1
  ST r3,r12,2

  ; literal byte
  MOVI r4,#NTK_MERGE_BASE
  CMP r1,r4
  JMP[GE] @ntk_e_special
  ; r1 < 258: byte, BOS or EOS
  MOVI r4,#NTK_BOS
  CMP r1,r4
  JMP[EQ] @ntk_e_empty
  MOVI r4,#NTK_EOS
  CMP r1,r4
  JMP[EQ] @ntk_e_empty
  ; byte only if r1 < 256
  MOVI r4,256
  CMP r1,r4
  JMP[GE] @ntk_e_bad
  MOVI r4,0xFF
  BOOL.8 r1,r1,r4
  JMP @ntk_e_put1

ntk_e_special:
  MOVI r4,#NTK_UNK
  CMP r1,r4
  JMP[NE] @ntk_e_merge
  MOVI r1,0x3F
  JMP @ntk_e_put1

ntk_e_merge:
  ; id must be a merge token
  MOVI r4,#NTK_MERGE_BASE
  SUB r4,r1,r4
  CMP r4,r0
  JMP[LT] @ntk_e_bad
  MOVI r5,#NTK_MERGES
  CMP r4,r5
  JMP[GE] @ntk_e_bad
  ; entry = merges + rank*3
  MOVI r5,3
  MUL r4,r4,r5
  LA r5,@ntok_merges
  ADD r5,r5,r4
  ST r5,r12,3
  ; left
  LD r1,r5,0
  LD r2,r12,1
  LD r3,r12,2
  CALL @ntok_emit
  CMP r1,r0
  JMP[LT] @ntk_e_bad
  ST r1,r12,4
  ; right = right child, out+l1, cap-l1
  LD r5,r12,3
  LD r1,r5,1
  LD r2,r12,1
  LD r4,r12,4
  ADD r2,r2,r4
  LD r3,r12,2
  SUB r3,r3,r4
  CALL @ntok_emit
  CMP r1,r0
  JMP[LT] @ntk_e_bad
  LD r4,r12,4
  ADD r1,r1,r4
  JMP @ntk_e_out

ntk_e_put1:
  LD r2,r12,1
  LD r3,r12,2
  CMP r3,r0
  JMP[EQ] @ntk_e_bad
  STB r1,r2,0
  MOVI r1,1
  JMP @ntk_e_out
ntk_e_empty:
  MOVI r1,0
  JMP @ntk_e_out
ntk_e_bad:
  LA r1,0xFFFFFFFF

ntk_e_out:
  ADDI r14,r14,-8
  LD r12,r14,1
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; ntok_id_bytes r1=id -> length, 0 special, -1 invalid
ntok_id_bytes:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,#NTK_VOCAB
  CMP r1,r2
  JMP[GE] @ntk_ib_bad
  MOVI r2,#NTK_BOS
  CMP r1,r2
  JMP[EQ] @ntk_ib_zero
  MOVI r2,#NTK_EOS
  CMP r1,r2
  JMP[EQ] @ntk_ib_zero
  LA r2,#NTK_IDBUF
  SHL r2,r2,2
  MOVI r3,8
  CALL @ntok_emit
  JMP @ntk_ib_out
ntk_ib_zero:
  MOVI r1,0
  JMP @ntk_ib_out
ntk_ib_bad:
  LA r1,0xFFFFFFFF
ntk_ib_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ntok_decode_token r1=id r2=out byte address r3=cap -> bytes/-1
ntok_decode_token:
  JMP @ntok_emit

; ---------------------------------------------------------------------------
; ntok_encode r1=in byte address r2=len r3=out word ptr r4=cap -> count/-1
ntok_encode:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NTK_IN
  ST r2,r0,#NTK_LEN
  ST r3,r0,#NTK_OUT
  ST r4,r0,#NTK_CAP
  CMP r2,r0
  JMP[EQ] @ntk_en_zero
  CMP r2,r4
  JMP[GT] @ntk_en_bad

  ; copy bytes to ids
  ST r0,r0,#NTK_I
ntk_en_cp:
  LD r1,r0,#NTK_I
  LD r2,r0,#NTK_LEN
  CMP r1,r2
  JMP[GE] @ntk_en_cpd
  LD r3,r0,#NTK_IN
  ADD r3,r3,r1
  LDB r4,r3,0
  LD r3,r0,#NTK_OUT
  ADD r3,r3,r1
  ST r4,r3,0
  LD r1,r0,#NTK_I
  ADD r1,r1,r13
  ST r1,r0,#NTK_I
  JMP @ntk_en_cp
ntk_en_cpd:
  LD r1,r0,#NTK_LEN
  ST r1,r0,#NTK_N

ntk_en_outer:
  ; best rank = 0x7FFFFFFF, best pos = -1
  LA r1,0x7FFFFFFF
  ST r1,r0,#NTK_BESTR
  LA r1,0xFFFFFFFF
  ST r1,r0,#NTK_BESTP
  ST r0,r0,#NTK_BESTID
  ST r0,r0,#NTK_POS
ntk_en_scan:
  LD r1,r0,#NTK_POS
  LD r2,r0,#NTK_N
  ADDI r2,r2,-1
  CMP r1,r2
  JMP[GE] @ntk_en_scan_d
  LD r3,r0,#NTK_OUT
  ADD r3,r3,r1
  LD r1,r3,0
  LD r2,r3,1
  CALL @nt_merge_lookup
  LA r5,0xFFFFFFFF
  CMP r2,r5
  JMP[EQ] @ntk_en_next
  LD r3,r0,#NTK_BESTR
  CMP r2,r3
  JMP[GE] @ntk_en_next
  ST r2,r0,#NTK_BESTR
  LD r3,r0,#NTK_POS
  ST r3,r0,#NTK_BESTP
  ST r1,r0,#NTK_BESTID
ntk_en_next:
  LD r1,r0,#NTK_POS
  ADD r1,r1,r13
  ST r1,r0,#NTK_POS
  JMP @ntk_en_scan
ntk_en_scan_d:
  LD r1,r0,#NTK_BESTP
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ntk_en_done
  ; out[best] = bestid; shift left
  LD r3,r0,#NTK_OUT
  ADD r3,r3,r1
  LD r2,r0,#NTK_BESTID
  ST r2,r3,0
  ADD r1,r1,r13
  ST r1,r0,#NTK_POS
ntk_en_shift:
  LD r1,r0,#NTK_POS
  LD r2,r0,#NTK_N
  ADDI r2,r2,-1
  CMP r1,r2
  JMP[GE] @ntk_en_sh_d
  LD r3,r0,#NTK_OUT
  ADD r3,r3,r1
  LD r4,r3,1
  ST r4,r3,0
  LD r1,r0,#NTK_POS
  ADD r1,r1,r13
  ST r1,r0,#NTK_POS
  JMP @ntk_en_shift
ntk_en_sh_d:
  LD r1,r0,#NTK_N
  ADDI r1,r1,-1
  ST r1,r0,#NTK_N
  JMP @ntk_en_outer

ntk_en_done:
  LD r1,r0,#NTK_N
  JMP @ntk_en_out
ntk_en_zero:
  MOVI r1,0
  JMP @ntk_en_out
ntk_en_bad:
  LA r1,0xFFFFFFFF
ntk_en_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; ntok_decode r1=ids r2=count r3=out byte addr r4=cap -> bytes/-1
ntok_decode:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NTK_IN
  ST r2,r0,#NTK_LEN
  ST r3,r0,#NTK_OUT
  ST r4,r0,#NTK_CAP
  ST r0,r0,#NTK_I
  ST r0,r0,#NTK_POS          ; bytes written
ntk_de_l:
  LD r1,r0,#NTK_I
  LD r2,r0,#NTK_LEN
  CMP r1,r2
  JMP[GE] @ntk_de_done
  LD r3,r0,#NTK_IN
  ADD r3,r3,r1
  LD r1,r3,0
  LD r2,r0,#NTK_OUT
  LD r4,r0,#NTK_POS
  ADD r2,r2,r4
  LD r3,r0,#NTK_CAP
  SUB r3,r3,r4
  CALL @ntok_emit
  CMP r1,r0
  JMP[LT] @ntk_de_bad
  LD r2,r0,#NTK_POS
  ADD r2,r2,r1
  ST r2,r0,#NTK_POS
  LD r1,r0,#NTK_I
  ADD r1,r1,r13
  ST r1,r0,#NTK_I
  JMP @ntk_de_l
ntk_de_done:
  LD r1,r0,#NTK_POS
  JMP @ntk_de_out
ntk_de_bad:
  LA r1,0xFFFFFFFF
ntk_de_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; ordered merge table: left, right, new id (rank = row index)
ntok_merges:
.word 116,104,258      ; t h -> th
.word 101,114,259      ; e r -> er
.word 105,110,260      ; i n -> in
.word 258,101,261      ; th e -> the
.word 261,32,262       ; the SP -> the
.word 104,101,263      ; h e -> he
.word 263,108,264      ; he l -> hel
.word 264,108,265      ; hel l -> hell
.word 265,111,266      ; hell o -> hello
.word 97,110,267       ; a n -> an
.word 111,110,268      ; o n -> on
.word 97,116,269       ; a t -> at
.word 101,110,270      ; e n -> en
.word 110,100,271      ; n d -> nd
.word 111,102,272      ; o f -> of
.word 116,111,273      ; t o -> to
.word 105,115,274      ; i s -> is
.word 105,116,275      ; i t -> it
.word 267,100,276      ; an d -> and
.word 268,101,277      ; on e -> one
.word 273,32,278       ; to SP -> to
.word 274,32,279       ; is SP -> is
.word 267,32,280       ; an SP -> an
.word 258,105,281      ; th i -> thi
