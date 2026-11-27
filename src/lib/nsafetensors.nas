; nsafetensors.nas - safetensors header parser and zero-copy nkv views (F7b).
;
; Pure NaN.  safetensors is a u64 little-endian JSON-header length followed by
; that many JSON bytes, then the tensor data.  The data section starts at
; 8 + header_len; every tensor carries {dtype, shape, data_offsets:[b,e]} with
; b/e relative to the data section.
;
; This is a minimal, real JSON parser for that header, not a stub:
;   - strings with backslash escapes, nested objects/arrays, numbers and the
;     true/false/null literals are scanned; unknown keys are skipped;
;   - __metadata__ is skipped as an opaque value;
;   - dtype/shape/data_offsets are parsed and validated;
;   - rank 1..4, positive dims, begin <= end, count*elem == end-begin;
;   - the absolute range 8+header_len+begin .. +size is 64-bit and is bounds
;     checked against the storage capability;
;   - each tensor gets a zero-copy nkv view (F32/F16/U8/I8).
;
; Supported dtypes (documented subset): F32 -> nkv 2, F16 -> nkv 1,
; U8/I8 -> nkv 0 (raw byte view; the safetensors signedness is not encoded in
; the view).  Other safetensors dtypes are rejected with -1.
;
; Header descriptor (16 words, caller supplied):
;   +0 magic 0x4846534E ("NSFH") +1 version 1
;   +2 header_len lo +3 hi       +4 data_off lo +5 hi
;   +6 parsed tensors            +7 max tensors
;   +8 tensor table ptr          +9 json_begin lo +10 hi (8)
;   +11 storage cap              +12 base_lo +13 base_hi
;   +14 flags                    +15 reserved
;
; Tensor record (48 words):
;   +0 magic 0x5454534E ("NSTT") +1 dtype (0 u8,1 f16,2 f32)
;   +2 rank +3..6 shape[4]
;   +7 data_begin lo +8 hi       +9 data_end lo +10 hi
;   +11 abs_off lo +12 hi        +13 size lo +14 hi
;   +15 count lo +16 hi          +17 name_len
;   +18 name_off lo +19 hi (absolute byte address)
;   +20..43 nkv view (24 words)  +44 flags +45..47 reserved
;
; API:
;   nsafetensors_parse r1=storage cap r2=header(16) r3=tensor table
;                       r4=max tensors -> 0/-1
;
; Limits: the 8-byte length and JSON header must be addressable below 4 GiB
; (guest LDB is 32-bit); tensor data ranges may cross 4 GiB because views are
; 64-bit.  Header length <= 1 MiB, max tensors <= 256, JSON nesting <= 16.
; Scratch 0x5A00..0x5FFF (below nq4 0x6000, above ngguf 0x5800).

.include "nkv.nas"

.equ SF_MAGIC   0x4846534E
.equ SF_TMAGIC  0x5454534E
.equ SF_VERSION 1
.equ SF_REC_WORDS 48
.equ SF_MAX_HEADER 0x100000
.equ SF_MAX_TENSORS 256
.equ SF_MAX_DEPTH 16
.equ SF_MAX_DIMS 4

; descriptor fields
.equ SF_H_MAGIC   0
.equ SF_H_VERSION 1
.equ SF_H_LEN     2
.equ SF_H_DATAOFF 4
.equ SF_H_PARSED  6
.equ SF_H_MAXT    7
.equ SF_H_TENS    8
.equ SF_H_JSONB   9
.equ SF_H_CAP     11
.equ SF_H_BASELO  12
.equ SF_H_BASEHI  13
.equ SF_H_FLAGS   14

; record fields
.equ SF_T_MAGIC   0
.equ SF_T_DTYPE   1
.equ SF_T_RANK    2
.equ SF_T_SHAPE   3
.equ SF_T_BEGIN   7
.equ SF_T_END     9
.equ SF_T_ABS     11
.equ SF_T_SIZE    13
.equ SF_T_COUNT   15
.equ SF_T_NAMELEN 17
.equ SF_T_NAMEOFF 18
.equ SF_T_VIEW    20
.equ SF_T_FLAGS   44

.equ SF 0x5A00
.equ SF_BASE 0x5A00
.equ SF_JSON 0x5A01
.equ SF_END  0x5A02
.equ SF_CUR  0x5A03
.equ SF_ERR  0x5A04
.equ SF_DEPTH 0x5A05
.equ SF_TMP  0x5A60
.equ SF_DS   0x5A10
.equ SF_REC  0x5A30
.equ SF_TENS 0x5A2C
.equ SF_KEY  0x5A38
.equ SF_NAME 0x5A3A
.equ SF_HDR  0x5A40
.equ SF_CAP  0x5A41
.equ SF_MAXT 0x5A42
.equ SF_COUNT 0x5A43
.equ SF_DATALO 0x5A44
.equ SF_DATAHI 0x5A45
.equ SF_SIZELO 0x5A46
.equ SF_SIZEHI 0x5A47
.equ SF_INFO 0x5A48
.equ SF_BYTES 0x5A50

; shape/data_offsets accumulator fields (SF_DS)
.equ SF_D_DTYPE 0
.equ SF_D_RANK  1
.equ SF_D_SHAPE 2
.equ SF_D_BEGIN 6
.equ SF_D_END   8
.equ SF_D_FLAGS 10
.equ SF_D_COUNT 12

; ---------------------------------------------------------------------------
; sf_fail: set the sticky error flag
sf_fail:
  MOVI r1,1
  ST r1,r0,#SF_ERR
  RET

; sf_getc -> r1=byte, advances; 0 with error on end
sf_getc:
  LD r1,r0,#SF_ERR
  CMP r1,r0
  JMP[NE] @sf_getc_bad
  LD r1,r0,#SF_CUR
  LD r2,r0,#SF_END
  CMP r1,r2
  JMP[GE] @sf_getc_bad
  LD r2,r0,#SF_JSON
  ADD r2,r2,r1
  LDB r3,r2,0
  ADD r1,r1,r13
  ST r1,r0,#SF_CUR
  ADD r1,r3,r0
  RET
sf_getc_bad:
  MOVI r1,1
  ST r1,r0,#SF_ERR
  MOVI r1,0
  RET

; sf_peek -> r1=byte without advancing; 0 with error on end
sf_peek:
  LD r1,r0,#SF_ERR
  CMP r1,r0
  JMP[NE] @sf_peek_bad
  LD r1,r0,#SF_CUR
  LD r2,r0,#SF_END
  CMP r1,r2
  JMP[GE] @sf_peek_bad
  LD r2,r0,#SF_JSON
  ADD r2,r2,r1
  LDB r1,r2,0
  RET
sf_peek_bad:
  MOVI r1,0
  RET

; sf_skip_ws: spaces, tabs, CR, LF
sf_skip_ws:
  ST r15,r14,0
  ADD r14,r14,r13
sf_ws_l:
  CALL @sf_peek
  CMP r1,r0
  JMP[EQ] @sf_ws_d
  MOVI r2,32
  CMP r1,r2
  JMP[EQ] @sf_ws_adv
  MOVI r2,9
  CMP r1,r2
  JMP[EQ] @sf_ws_adv
  MOVI r2,10
  CMP r1,r2
  JMP[EQ] @sf_ws_adv
  MOVI r2,13
  CMP r1,r2
  JMP[NE] @sf_ws_d
sf_ws_adv:
  CALL @sf_getc
  JMP @sf_ws_l
sf_ws_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; sf_expect r1=char -> 0/-1 (no whitespace skip)
sf_expect:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#SF_TMP+0
  CALL @sf_getc
  LD r2,r0,#SF_TMP+0
  CMP r1,r2
  JMP[NE] @sf_ex_bad
  MOVI r1,0
  JMP @sf_ex_out
sf_ex_bad:
  CALL @sf_fail
  LA r1,0xFFFFFFFF
sf_ex_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; sf_skip_string: current byte must be '"'
sf_skip_string:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r1,34
  CALL @sf_expect
  CMP r1,r0
  JMP[NE] @sf_ss_bad
sf_ss_l:
  CALL @sf_getc
  CMP r1,r0
  JMP[EQ] @sf_ss_bad
  MOVI r2,34
  CMP r1,r2
  JMP[EQ] @sf_ss_ok
  MOVI r2,92
  CMP r1,r2
  JMP[NE] @sf_ss_l
  CALL @sf_getc
  CMP r1,r0
  JMP[EQ] @sf_ss_bad
  JMP @sf_ss_l
sf_ss_ok:
  MOVI r1,0
  JMP @sf_ss_out
sf_ss_bad:
  CALL @sf_fail
  LA r1,0xFFFFFFFF
sf_ss_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; sf_scan_string -> r1=start r2=len (raw bytes, no quotes), advances
sf_scan_string:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r1,34
  CALL @sf_expect
  CMP r1,r0
  JMP[NE] @sf_sc_bad
  LD r1,r0,#SF_CUR
  ST r1,r0,#SF_TMP+2          ; start
sf_sc_l:
  CALL @sf_getc
  CMP r1,r0
  JMP[EQ] @sf_sc_bad
  MOVI r2,34
  CMP r1,r2
  JMP[EQ] @sf_sc_ok
  MOVI r2,92
  CMP r1,r2
  JMP[NE] @sf_sc_l
  CALL @sf_getc
  CMP r1,r0
  JMP[EQ] @sf_sc_bad
  JMP @sf_sc_l
sf_sc_ok:
  LD r1,r0,#SF_CUR
  ADDI r1,r1,-1
  LD r2,r0,#SF_TMP+2
  SUB r1,r1,r2
  ADD r2,r2,r0
  JMP @sf_sc_out
sf_sc_bad:
  CALL @sf_fail
  MOVI r1,0
  MOVI r2,0
sf_sc_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; sf_key_eq r1=start r2=len r3=literal word ptr r4=litlen -> 1/0
sf_key_eq:
  CMP r2,r4
  JMP[NE] @sf_ke_no0
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#SF_TMP+4
  ST r3,r0,#SF_TMP+5
  SHL r3,r3,2                  ; literal byte address
  LD r5,r0,#SF_JSON
  MOVI r6,0
sf_ke_l:
  CMP r6,r2
  JMP[GE] @sf_ke_yes
  LD r7,r0,#SF_TMP+4
  ADD r7,r7,r6
  ADD r7,r5,r7
  LDB r7,r7,0
  ADD r8,r3,r6
  LDB r8,r8,0
  CMP r7,r8
  JMP[NE] @sf_ke_no
  ADD r6,r6,r13
  JMP @sf_ke_l
sf_ke_yes:
  MOVI r1,1
  SUB r14,r14,r13
  LD r15,r14,0
  RET
sf_ke_no0:
  MOVI r1,0
  RET
sf_ke_no:
  MOVI r1,0
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; sf_parse_uint -> r1=value (>=0), advances digits
sf_parse_uint:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r4,0                    ; value
  MOVI r5,0                    ; digits
sf_pu_l:
  CALL @sf_peek
  MOVI r2,48
  CMP r1,r2
  JMP[LT] @sf_pu_d
  MOVI r2,57
  CMP r1,r2
  JMP[GT] @sf_pu_d
  CALL @sf_getc
  MOVI r2,48
  SUB r1,r1,r2
  MOVI r6,10
  MUL r4,r4,r6
  ADD r4,r4,r1
  LD r2,r0,#SF_TMP+6
  CMP r4,r2
  JMP[GT] @sf_pu_bad
  ADD r5,r5,r13
  JMP @sf_pu_l
sf_pu_d:
  CMP r5,r0
  JMP[EQ] @sf_pu_bad
  ADD r1,r4,r0
  JMP @sf_pu_out
sf_pu_bad:
  CALL @sf_fail
  LA r1,0xFFFFFFFF
sf_pu_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; sf_dtype r1=start r2=len -> r1 = 0 u8, 1 f16, 2 f32, -1 unsupported
sf_dtype:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#SF_TMP+8
  ST r2,r0,#SF_TMP+9
  LD r4,r0,#SF_TMP+9
  LA r3,@sf_d_f32
  MOVI r2,3
  LD r1,r0,#SF_TMP+8
  CALL @sf_key_eq
  CMP r1,r0
  JMP[NE] @sf_dt_f32
  LA r3,@sf_d_f16
  MOVI r2,3
  LD r1,r0,#SF_TMP+8
  LD r4,r0,#SF_TMP+9
  CALL @sf_key_eq
  CMP r1,r0
  JMP[NE] @sf_dt_f16
  LA r3,@sf_d_u8
  MOVI r2,2
  LD r1,r0,#SF_TMP+8
  LD r4,r0,#SF_TMP+9
  CALL @sf_key_eq
  CMP r1,r0
  JMP[NE] @sf_dt_u8
  LA r3,@sf_d_i8
  MOVI r2,2
  LD r1,r0,#SF_TMP+8
  LD r4,r0,#SF_TMP+9
  CALL @sf_key_eq
  CMP r1,r0
  JMP[NE] @sf_dt_i8
  LA r1,0xFFFFFFFF
  JMP @sf_dt_out
sf_dt_f32:
  MOVI r1,2
  JMP @sf_dt_out
sf_dt_f16:
  MOVI r1,1
  JMP @sf_dt_out
sf_dt_u8:
sf_dt_i8:
  MOVI r1,0
sf_dt_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; sf_skip_value: skip one JSON value, including nested containers.
sf_skip_value:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @sf_skip_ws
  CALL @sf_peek
  CMP r1,r0
  JMP[EQ] @sf_sv_bad
  MOVI r2,34
  CMP r1,r2
  JMP[EQ] @sf_sv_str
  MOVI r2,123
  CMP r1,r2
  JMP[EQ] @sf_sv_obj
  MOVI r2,91
  CMP r1,r2
  JMP[EQ] @sf_sv_arr
  MOVI r2,116
  CMP r1,r2
  JMP[EQ] @sf_sv_true
  MOVI r2,102
  CMP r1,r2
  JMP[EQ] @sf_sv_false
  MOVI r2,110
  CMP r1,r2
  JMP[EQ] @sf_sv_null
  MOVI r2,45
  CMP r1,r2
  JMP[EQ] @sf_sv_num
  MOVI r2,48
  CMP r1,r2
  JMP[LT] @sf_sv_bad
  MOVI r2,57
  CMP r1,r2
  JMP[GT] @sf_sv_bad
  JMP @sf_sv_num

sf_sv_str:
  CALL @sf_skip_string
  JMP @sf_sv_out
sf_sv_true:
  LA r1,@sf_t_true
  MOVI r2,4
  CALL @sf_seq
  JMP @sf_sv_out
sf_sv_false:
  LA r1,@sf_t_false
  MOVI r2,5
  CALL @sf_seq
  JMP @sf_sv_out
sf_sv_null:
  LA r1,@sf_t_null
  MOVI r2,4
  CALL @sf_seq
  JMP @sf_sv_out

sf_sv_num:
  ; permissive number scan: [0-9+-.eE] runs
  CALL @sf_getc
sf_sv_numl:
  CALL @sf_peek
  MOVI r2,48
  CMP r1,r2
  JMP[LT] @sf_sv_numd
  MOVI r2,57
  CMP r1,r2
  JMP[LE] @sf_sv_numc
  MOVI r2,43
  CMP r1,r2
  JMP[EQ] @sf_sv_numc
  MOVI r2,45
  CMP r1,r2
  JMP[EQ] @sf_sv_numc
  MOVI r2,46
  CMP r1,r2
  JMP[EQ] @sf_sv_numc
  MOVI r2,101
  CMP r1,r2
  JMP[EQ] @sf_sv_numc
  MOVI r2,69
  CMP r1,r2
  JMP[NE] @sf_sv_numd
sf_sv_numc:
  CALL @sf_getc
  JMP @sf_sv_numl
sf_sv_numd:
  JMP @sf_sv_out

sf_sv_obj:
  MOVI r1,123
  CALL @sf_expect
  CALL @sf_depth_inc
  CALL @sf_skip_ws
  CALL @sf_peek
  MOVI r2,125
  CMP r1,r2
  JMP[EQ] @sf_sv_objend
sf_sv_objl:
  CALL @sf_scan_string
  CALL @sf_skip_ws
  MOVI r1,58
  CALL @sf_expect
  CALL @sf_skip_value
  CALL @sf_skip_ws
  CALL @sf_peek
  MOVI r2,44
  CMP r1,r2
  JMP[EQ] @sf_sv_objnext
  MOVI r2,125
  CMP r1,r2
  JMP[NE] @sf_sv_bad
  JMP @sf_sv_objend
sf_sv_objnext:
  CALL @sf_getc
  JMP @sf_sv_objl
sf_sv_objend:
  MOVI r1,125
  CALL @sf_expect
  CALL @sf_depth_dec
  JMP @sf_sv_out

sf_sv_arr:
  MOVI r1,91
  CALL @sf_expect
  CALL @sf_depth_inc
  CALL @sf_skip_ws
  CALL @sf_peek
  MOVI r2,93
  CMP r1,r2
  JMP[EQ] @sf_sv_arrend
sf_sv_arrl:
  CALL @sf_skip_value
  CALL @sf_skip_ws
  CALL @sf_peek
  MOVI r2,44
  CMP r1,r2
  JMP[EQ] @sf_sv_arrnext
  MOVI r2,93
  CMP r1,r2
  JMP[NE] @sf_sv_bad
  JMP @sf_sv_arrend
sf_sv_arrnext:
  CALL @sf_getc
  JMP @sf_sv_arrl
sf_sv_arrend:
  MOVI r1,93
  CALL @sf_expect
  CALL @sf_depth_dec
  JMP @sf_sv_out
sf_sv_bad:
  CALL @sf_fail
sf_sv_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; sf_seq r1=literal word ptr r2=len -> 0/-1
sf_seq:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#SF_TMP+10
  ST r2,r0,#SF_TMP+11
  SHL r1,r1,2
  ST r1,r0,#SF_TMP+10
  MOVI r3,0
sf_seq_l:
  LD r2,r0,#SF_TMP+11
  CMP r3,r2
  JMP[GE] @sf_seq_ok
  ST r3,r0,#SF_TMP+12
  CALL @sf_getc
  LD r3,r0,#SF_TMP+12
  LD r4,r0,#SF_TMP+10
  ADD r4,r4,r3
  LDB r4,r4,0
  CMP r1,r4
  JMP[NE] @sf_seq_bad
  ADD r3,r3,r13
  JMP @sf_seq_l
sf_seq_ok:
  MOVI r1,0
  JMP @sf_seq_out
sf_seq_bad:
  CALL @sf_fail
  LA r1,0xFFFFFFFF
sf_seq_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; depth guard
sf_depth_inc:
  LD r1,r0,#SF_DEPTH
  ADD r1,r1,r13
  MOVI r2,#SF_MAX_DEPTH
  CMP r1,r2
  JMP[GT] @sf_di_bad
  ST r1,r0,#SF_DEPTH
  MOVI r1,0
  RET
sf_di_bad:
  CALL @sf_fail
  LA r1,0xFFFFFFFF
  RET

sf_depth_dec:
  LD r1,r0,#SF_DEPTH
  SUB r1,r1,r13
  ST r1,r0,#SF_DEPTH
  RET

; ---------------------------------------------------------------------------
; sf_tensor: parse one tensor object at the current byte and add a record.
; Requires SF_REC / SF_HDR / SF_DATA* / SF_COUNT set by the caller.
; -> 0/-1
sf_tensor:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @sf_skip_ws
  MOVI r1,123
  CALL @sf_expect
  CMP r1,r0
  JMP[NE] @sf_t_bad
  ; reset state
  LA r6,#SF_DS
  MOVI r1,0
  MOVI r2,12
sf_t_clear:
  CMP r2,r0
  JMP[EQ] @sf_t_cd
  ST r1,r6,0
  ADD r6,r6,r13
  SUB r2,r2,r13
  JMP @sf_t_clear
sf_t_cd:
  LA r6,#SF_DS
  LA r1,0xFFFFFFFF
  ST r1,r6,#SF_D_DTYPE
sf_t_loop:
  CALL @sf_skip_ws
  CALL @sf_peek
  MOVI r2,125
  CMP r1,r2
  JMP[EQ] @sf_t_end
  CALL @sf_scan_string
  ST r2,r0,#SF_KEY+0
  ST r1,r0,#SF_KEY+1
  CALL @sf_skip_ws
  MOVI r1,58
  CALL @sf_expect
  CMP r1,r0
  JMP[NE] @sf_t_bad
  ; dtype?
  LA r3,@sf_k_dtype
  MOVI r4,5
  LD r1,r0,#SF_KEY+0
  LD r2,r0,#SF_KEY+1
  CALL @sf_key_eq
  CMP r1,r0
  JMP[NE] @sf_t_isdtype
  ; shape?
  LA r3,@sf_k_shape
  MOVI r4,5
  LD r1,r0,#SF_KEY+0
  LD r2,r0,#SF_KEY+1
  CALL @sf_key_eq
  CMP r1,r0
  JMP[NE] @sf_t_isshape
  ; data_offsets?
  LA r3,@sf_k_offsets
  MOVI r4,12
  LD r1,r0,#SF_KEY+0
  LD r2,r0,#SF_KEY+1
  CALL @sf_key_eq
  CMP r1,r0
  JMP[NE] @sf_t_isoffsets
  CALL @sf_skip_value
  JMP @sf_t_after

sf_t_isdtype:
  CALL @sf_skip_ws
  CALL @sf_scan_string
  ADD r3,r1,r0
  ADD r1,r2,r0
  ADD r2,r3,r0
  CALL @sf_dtype
  CMP r1,r0
  JMP[LT] @sf_t_bad
  LA r6,#SF_DS
  ST r1,r6,#SF_D_DTYPE
  LD r2,r6,#SF_D_FLAGS
  MOVI r3,1
  BOOL.14 r2,r2,r3
  ST r2,r6,#SF_D_FLAGS
  JMP @sf_t_after

sf_t_isshape:
  CALL @sf_skip_ws
  MOVI r1,91
  CALL @sf_expect
  CMP r1,r0
  JMP[NE] @sf_t_bad
  LA r6,#SF_DS
  ST r0,r6,#SF_D_RANK
  CALL @sf_skip_ws
  CALL @sf_peek
  MOVI r2,93
  CMP r1,r2
  JMP[EQ] @sf_t_shaped
sf_t_shape_l:
  CALL @sf_parse_uint
  CMP r1,r0
  JMP[LT] @sf_t_bad
  LA r6,#SF_DS
  LD r2,r6,#SF_D_RANK
  MOVI r3,#SF_MAX_DIMS
  CMP r2,r3
  JMP[GE] @sf_t_bad
  ADD r3,r6,r2
  ST r1,r3,#SF_D_SHAPE
  ADD r2,r2,r13
  ST r2,r6,#SF_D_RANK
  CALL @sf_skip_ws
  CALL @sf_peek
  MOVI r2,44
  CMP r1,r2
  JMP[EQ] @sf_t_shape_more
  MOVI r2,93
  CMP r1,r2
  JMP[NE] @sf_t_bad
  JMP @sf_t_shaped
sf_t_shape_more:
  CALL @sf_getc
  CALL @sf_skip_ws
  JMP @sf_t_shape_l
sf_t_shaped:
  MOVI r1,93
  CALL @sf_expect
  CMP r1,r0
  JMP[NE] @sf_t_bad
  LA r6,#SF_DS
  LD r2,r6,#SF_D_FLAGS
  MOVI r3,2
  BOOL.14 r2,r2,r3
  ST r2,r6,#SF_D_FLAGS
  JMP @sf_t_after

sf_t_isoffsets:
  CALL @sf_skip_ws
  MOVI r1,91
  CALL @sf_expect
  CMP r1,r0
  JMP[NE] @sf_t_bad
  CALL @sf_skip_ws
  CALL @sf_parse_uint
  CMP r1,r0
  JMP[LT] @sf_t_bad
  LA r6,#SF_DS
  ST r1,r6,#SF_D_BEGIN
  ST r0,r6,#SF_D_BEGIN+1
  CALL @sf_skip_ws
  MOVI r1,44
  CALL @sf_expect
  CMP r1,r0
  JMP[NE] @sf_t_bad
  CALL @sf_skip_ws
  CALL @sf_parse_uint
  CMP r1,r0
  JMP[LT] @sf_t_bad
  LA r6,#SF_DS
  ST r1,r6,#SF_D_END
  ST r0,r6,#SF_D_END+1
  CALL @sf_skip_ws
  MOVI r1,93
  CALL @sf_expect
  CMP r1,r0
  JMP[NE] @sf_t_bad
  LA r6,#SF_DS
  LD r2,r6,#SF_D_FLAGS
  MOVI r3,4
  BOOL.14 r2,r2,r3
  ST r2,r6,#SF_D_FLAGS
  JMP @sf_t_after

sf_t_after:
  CALL @sf_skip_ws
  CALL @sf_peek
  MOVI r2,44
  CMP r1,r2
  JMP[EQ] @sf_t_next
  MOVI r2,125
  CMP r1,r2
  JMP[NE] @sf_t_bad
  JMP @sf_t_loop
sf_t_next:
  CALL @sf_getc
  JMP @sf_t_loop

sf_t_end:
  MOVI r1,125
  CALL @sf_expect
  CMP r1,r0
  JMP[NE] @sf_t_bad

  ; all three required fields
  LA r6,#SF_DS
  LD r1,r6,#SF_D_FLAGS
  MOVI r2,7
  BOOL.8 r1,r1,r2
  MOVI r2,7
  CMP r1,r2
  JMP[NE] @sf_t_bad
  LD r1,r6,#SF_D_RANK
  CMP r1,r0
  JMP[LE] @sf_t_bad
  MOVI r2,#SF_MAX_DIMS
  CMP r1,r2
  JMP[GT] @sf_t_bad
  ; dims positive and count = product
  MOVI r7,0
  ST r7,r0,#SF_TMP+20
  MOVI r1,1
  ST r1,r0,#SF_DS+#SF_D_COUNT
  ST r0,r0,#SF_DS+#SF_D_COUNT+1
sf_t_cnt:
  LD r7,r0,#SF_TMP+20
  LA r6,#SF_DS
  LD r1,r6,#SF_D_RANK
  CMP r7,r1
  JMP[GE] @sf_t_cntd
  ADD r1,r6,r7
  LD r1,r1,#SF_D_SHAPE
  CMP r1,r0
  JMP[EQ] @sf_t_bad
  LD r2,r0,#SF_DS+#SF_D_COUNT
  LD r3,r0,#SF_DS+#SF_D_COUNT+1
  CALL @n64_mul32
  ST r1,r0,#SF_DS+#SF_D_COUNT
  ST r2,r0,#SF_DS+#SF_D_COUNT+1
  LD r1,r0,#SF_TMP+20
  ADD r1,r1,r13
  ST r1,r0,#SF_TMP+20
  JMP @sf_t_cnt
sf_t_cntd:

  ; dtype element size
  LD r1,r6,#SF_D_DTYPE
  CMP r1,r0
  JMP[EQ] @sf_t_e1
  MOVI r2,1
  CMP r1,r2
  JMP[EQ] @sf_t_e2
  MOVI r2,2
  CMP r1,r2
  JMP[EQ] @sf_t_e4
  JMP @sf_t_bad
sf_t_e1:
  MOVI r7,1
  JMP @sf_t_elem
sf_t_e2:
  MOVI r7,2
  JMP @sf_t_elem
sf_t_e4:
  MOVI r7,4
sf_t_elem:
  ST r7,r0,#SF_TMP+21

  ; size = end - begin; begin <= end
  LD r1,r6,#SF_D_BEGIN
  LD r2,r6,#SF_D_BEGIN+1
  LD r3,r6,#SF_D_END
  LD r4,r6,#SF_D_END+1
  CALL @n64_cmp
  MOVI r5,1
  CMP r1,r5
  JMP[EQ] @sf_t_bad
  LD r1,r6,#SF_D_END
  LD r2,r6,#SF_D_END+1
  LD r3,r6,#SF_D_BEGIN
  LD r4,r6,#SF_D_BEGIN+1
  CALL @n64_sub
  ST r1,r0,#SF_TMP+22
  ST r2,r0,#SF_TMP+23

  ; count*elem must equal size
  LD r1,r0,#SF_TMP+21
  LD r2,r6,#SF_D_COUNT
  LD r3,r6,#SF_D_COUNT+1
  CALL @n64_mul32
  ST r1,r0,#SF_TMP+24
  ST r2,r0,#SF_TMP+25
  LA r6,#SF_DS
  LD r3,r0,#SF_TMP+22
  LD r4,r0,#SF_TMP+23
  CALL @n64_cmp
  CMP r1,r0
  JMP[NE] @sf_t_bad

  ; abs = data_off + begin; end_abs = abs + size <= storage size
  LD r1,r0,#SF_DATALO
  LD r2,r0,#SF_DATAHI
  LD r3,r6,#SF_D_BEGIN
  LD r4,r6,#SF_D_BEGIN+1
  CALL @n64_add
  ST r1,r0,#SF_TMP+26
  ST r2,r0,#SF_TMP+27
  LD r3,r0,#SF_TMP+22
  LD r4,r0,#SF_TMP+23
  CALL @n64_add
  ST r1,r0,#SF_TMP+28
  ST r2,r0,#SF_TMP+29
  LD r3,r0,#SF_SIZELO
  LD r4,r0,#SF_SIZEHI
  CALL @n64_cmp
  MOVI r5,1
  CMP r1,r5
  JMP[EQ] @sf_t_bad

  ; record
  LD r1,r0,#SF_REC
  LA r2,#SF_TMAGIC
  ST r2,r1,#SF_T_MAGIC
  LD r2,r6,#SF_D_DTYPE
  ST r2,r1,#SF_T_DTYPE
  LD r2,r6,#SF_D_RANK
  ST r2,r1,#SF_T_RANK
  MOVI r3,0
sf_t_shape_cp:
  CMP r3,r2
  JMP[GE] @sf_t_shape_cpd
  ADD r4,r6,r3
  LD r4,r4,#SF_D_SHAPE
  ADD r5,r1,r3
  ST r4,r5,#SF_T_SHAPE
  ADD r3,r3,r13
  JMP @sf_t_shape_cp
sf_t_shape_cpd:
  LD r2,r6,#SF_D_BEGIN
  ST r2,r1,#SF_T_BEGIN
  LD r2,r6,#SF_D_BEGIN+1
  ST r2,r1,#SF_T_BEGIN+1
  LD r2,r6,#SF_D_END
  ST r2,r1,#SF_T_END
  LD r2,r6,#SF_D_END+1
  ST r2,r1,#SF_T_END+1
  LD r2,r0,#SF_TMP+26
  ST r2,r1,#SF_T_ABS
  LD r2,r0,#SF_TMP+27
  ST r2,r1,#SF_T_ABS+1
  LD r2,r0,#SF_TMP+22
  ST r2,r1,#SF_T_SIZE
  LD r2,r0,#SF_TMP+23
  ST r2,r1,#SF_T_SIZE+1
  LD r2,r6,#SF_D_COUNT
  ST r2,r1,#SF_T_COUNT
  LD r2,r6,#SF_D_COUNT+1
  ST r2,r1,#SF_T_COUNT+1
  LD r2,r0,#SF_NAME+1
  ST r2,r1,#SF_T_NAMELEN
  LD r2,r0,#SF_NAME+0
  LD r3,r0,#SF_JSON
  ADD r2,r2,r3
  ST r2,r1,#SF_T_NAMEOFF
  ST r0,r1,#SF_T_NAMEOFF+1
  ST r0,r1,#SF_T_FLAGS

  ; nkv view
  LD r1,r0,#SF_CAP
  LD r2,r0,#SF_TMP+26
  LD r3,r0,#SF_TMP+27
  LD r4,r0,#SF_TMP+22
  LD r5,r0,#SF_TMP+23
  LD r6,r0,#SF_REC
  LD r7,r6,#SF_T_RANK
  LA r8,#SF_DS+#SF_D_SHAPE
  ADD r9,r6,r0
  ADDI r9,r9,#SF_T_VIEW
  LD r6,r0,#SF_REC
  LD r6,r6,#SF_T_DTYPE
  ; nkv dtype mapping is the same 0/1/2 code
  CALL @nkv_view_create
  CMP r1,r0
  JMP[NE] @sf_t_bad

  ; count++
  LD r1,r0,#SF_COUNT
  ADD r1,r1,r13
  ST r1,r0,#SF_COUNT
  MOVI r1,0
  JMP @sf_t_out
sf_t_bad:
  CALL @sf_fail
  LA r1,0xFFFFFFFF
sf_t_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsafetensors_parse r1=storage cap r2=header r3=tensor table r4=max -> 0/-1
nsafetensors_parse:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#SF_CAP
  ST r2,r0,#SF_HDR
  ST r3,r0,#SF_TENS
  ST r4,r0,#SF_MAXT
  CMP r3,r0
  JMP[EQ] @sf_p_bad
  CMP r4,r0
  JMP[LE] @sf_p_bad
  MOVI r5,#SF_MAX_TENSORS
  CMP r4,r5
  JMP[GT] @sf_p_bad

  ; storage metadata: base must be below 4 GiB
  LD r1,r0,#SF_CAP
  LA r2,#SF_INFO
  CALL @nkv_storage_info
  CMP r1,r0
  JMP[NE] @sf_p_bad
  LA r6,#SF_INFO
  LD r1,r6,1
  CMP r1,r0
  JMP[NE] @sf_p_bad
  LD r1,r6,0
  ST r1,r0,#SF_BASE
  LD r1,r6,2
  ST r1,r0,#SF_SIZELO
  LD r1,r6,3
  ST r1,r0,#SF_SIZEHI

  ; base must leave room for at least the 8-byte length below 4 GiB
  LD r1,r0,#SF_BASE
  LA r2,0xFFFFFFF7
  CMP r1,r2
  JMP[GT] @sf_p_bad

  ; 8-byte header length
  LD r1,r0,#SF_BASE
  MOVI r2,0
  ST r2,r0,#SF_H_JSONB
  ; read 8 bytes into lo/hi (u32 halves)
  LD r3,r0,#SF_BASE
  LDB r1,r3,0
  LDB r2,r3,1
  SHL r2,r2,8
  BOOL.14 r1,r1,r2
  LDB r2,r3,2
  SHL r2,r2,16
  BOOL.14 r1,r1,r2
  LDB r2,r3,3
  SHL r2,r2,24
  BOOL.14 r1,r1,r2
  ST r1,r0,#SF_TMP+30
  LDB r1,r3,4
  LDB r2,r3,5
  SHL r2,r2,8
  BOOL.14 r1,r1,r2
  LDB r2,r3,6
  SHL r2,r2,16
  BOOL.14 r1,r1,r2
  LDB r2,r3,7
  SHL r2,r2,24
  BOOL.14 r1,r1,r2
  ST r1,r0,#SF_TMP+31
  LD r1,r0,#SF_TMP+31
  CMP r1,r0
  JMP[NE] @sf_p_bad
  LD r1,r0,#SF_TMP+30
  CMP r1,r0
  JMP[EQ] @sf_p_bad
  LA r2,0x100000
  CMP r1,r2
  JMP[GT] @sf_p_bad
  ST r1,r0,#SF_END

  ; data_off = 8 + header_len (64-bit)
  LD r1,r0,#SF_TMP+30
  LD r2,r0,#SF_TMP+31
  MOVI r3,8
  MOVI r4,0
  CALL @n64_add
  ST r1,r0,#SF_DATALO
  ST r2,r0,#SF_DATAHI
  ; data_off + data size <= storage size
  LD r3,r0,#SF_SIZELO
  LD r4,r0,#SF_SIZEHI
  CALL @n64_cmp
  MOVI r5,1
  CMP r1,r5
  JMP[EQ] @sf_p_bad

  ; JSON base = base + 8, must not wrap 32 bits for LDB
  LD r1,r0,#SF_BASE
  ADDI r1,r1,8
  CMP r1,r0
  JMP[EQ] @sf_p_bad
  ST r1,r0,#SF_JSON
  ; base + 8 + header_len - 1 must stay below 4 GiB
  LD r2,r0,#SF_END
  ADD r2,r2,r1
  CMP r2,r1
  JMP[LT] @sf_p_bad

  ; header descriptor
  LD r1,r0,#SF_HDR
  LA r2,#SF_MAGIC
  ST r2,r1,#SF_H_MAGIC
  MOVI r2,#SF_VERSION
  ST r2,r1,#SF_H_VERSION
  LD r2,r0,#SF_TMP+30
  ST r2,r1,#SF_H_LEN
  LD r2,r0,#SF_TMP+31
  ST r2,r1,#SF_H_LEN+1
  LD r2,r0,#SF_DATALO
  ST r2,r1,#SF_H_DATAOFF
  LD r2,r0,#SF_DATAHI
  ST r2,r1,#SF_H_DATAOFF+1
  ST r0,r1,#SF_H_PARSED
  LD r2,r0,#SF_MAXT
  ST r2,r1,#SF_H_MAXT
  LD r2,r0,#SF_TENS
  ST r2,r1,#SF_H_TENS
  MOVI r2,8
  ST r2,r1,#SF_H_JSONB
  ST r0,r1,#SF_H_JSONB+1
  LD r2,r0,#SF_CAP
  ST r2,r1,#SF_H_CAP
  LD r2,r0,#SF_BASE
  ST r2,r1,#SF_H_BASELO
  ST r0,r1,#SF_H_BASEHI
  ST r0,r1,#SF_H_FLAGS

  ; JSON state
  MOVI r1,0
  ST r1,r0,#SF_CUR
  ST r1,r0,#SF_ERR
  ST r1,r0,#SF_DEPTH
  ST r1,r0,#SF_COUNT
  LA r2,0x7FFFFFFF
  ST r2,r0,#SF_TMP+6

  CALL @sf_skip_ws
  MOVI r1,123
  CALL @sf_expect
  CMP r1,r0
  JMP[NE] @sf_p_bad

sf_p_top:
  CALL @sf_skip_ws
  CALL @sf_peek
  MOVI r2,125
  CMP r1,r2
  JMP[EQ] @sf_p_close
  ; count < max
  LD r1,r0,#SF_COUNT
  LD r2,r0,#SF_MAXT
  CMP r1,r2
  JMP[GE] @sf_p_bad
  CALL @sf_scan_string
  ST r2,r0,#SF_KEY+0
  ST r1,r0,#SF_KEY+1
  CALL @sf_skip_ws
  MOVI r1,58
  CALL @sf_expect
  CMP r1,r0
  JMP[NE] @sf_p_bad
  ; __metadata__?
  LA r3,@sf_k_meta
  MOVI r4,12
  LD r1,r0,#SF_KEY+0
  LD r2,r0,#SF_KEY+1
  CALL @sf_key_eq
  CMP r1,r0
  JMP[NE] @sf_p_meta
  ; tensor record address = table + count*48
  LD r1,r0,#SF_COUNT
  MOVI r2,#SF_REC_WORDS
  MUL r2,r1,r2
  LD r3,r0,#SF_TENS
  ADD r3,r3,r2
  ST r3,r0,#SF_REC
  LD r5,r0,#SF_KEY+0
  ST r5,r0,#SF_NAME
  LD r5,r0,#SF_KEY+1
  ST r5,r0,#SF_NAME+1
  CALL @sf_tensor
  CMP r1,r0
  JMP[NE] @sf_p_bad
  JMP @sf_p_after
sf_p_meta:
  CALL @sf_skip_value
sf_p_after:
  CALL @sf_skip_ws
  CALL @sf_peek
  MOVI r2,44
  CMP r1,r2
  JMP[EQ] @sf_p_next
  MOVI r2,125
  CMP r1,r2
  JMP[NE] @sf_p_bad
  JMP @sf_p_close
sf_p_next:
  CALL @sf_getc
  JMP @sf_p_top
sf_p_close:
  MOVI r1,125
  CALL @sf_expect
  CMP r1,r0
  JMP[NE] @sf_p_bad
  ; only whitespace padding remains
sf_p_pad:
  CALL @sf_peek
  CMP r1,r0
  JMP[EQ] @sf_p_done
  MOVI r2,32
  CMP r1,r2
  JMP[EQ] @sf_p_padv
  MOVI r2,9
  CMP r1,r2
  JMP[EQ] @sf_p_padv
  MOVI r2,10
  CMP r1,r2
  JMP[EQ] @sf_p_padv
  MOVI r2,13
  CMP r1,r2
  JMP[NE] @sf_p_bad
sf_p_padv:
  CALL @sf_getc
  JMP @sf_p_pad
sf_p_done:
  LD r1,r0,#SF_ERR
  CMP r1,r0
  JMP[NE] @sf_p_bad
  LD r1,r0,#SF_HDR
  LD r2,r0,#SF_COUNT
  ST r2,r1,#SF_H_PARSED
  MOVI r1,0
  JMP @sf_p_out
sf_p_bad:
  LA r1,0xFFFFFFFF
sf_p_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; literal keys
sf_k_meta:
.str "__metadata__"
sf_k_dtype:
.str "dtype"
sf_k_shape:
.str "shape"
sf_k_offsets:
.str "data_offsets"
sf_d_f32:
.str "F32"
sf_d_f16:
.str "F16"
sf_d_u8:
.str "U8"
sf_d_i8:
.str "I8"
sf_t_true:
.str "true"
sf_t_false:
.str "false"
sf_t_null:
.str "null"
