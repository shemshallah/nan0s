; ngguf.nas - zero-copy GGUF v2/v3 import over a storage capability (F7).
;
; The parser reads a GGUF image through a class-20 byte-addressable storage
; capability (the same 8-word contract as nmem/nkv).  It validates the magic,
; version, counts, metadata values and tensor infos, then creates one nkv
; tensor view per tensor.  No tensor payload byte is copied and no host
; pointer is used: the image can sit at a 64-bit byte address and a tensor
; range may cross 4 GiB.
;
; Supported tensor types: F32 (0), F16 (1), Q4_0 (2), Q8_0 (8).
;   F32/F16 get a typed nkv view (dtype 2/1) with the GGUF shape.
;   Q4_0/Q8_0 get a zero-copy raw u8 nkv view over the packed block bytes
;   (32 weights/block, 18/34 bytes/block); the GGUF dtype/blocks are kept in
;   the tensor record so nq4 can consume the view directly.
;
; GGUF image layout (little endian):
;   0  magic "GGUF"          4  version u32 (2 or 3)
;   8  tensor_count u64      16 kv_count u64
;   24 metadata kv pairs: key = u64 len + bytes, value_type u32, value
;   then tensor infos: name = u64 len + bytes, n_dims u32, dims u64[n],
;                      type u32, offset u64 (relative to the data section)
;   then zero padding to `general.alignment` (default 32); tensor data.
;
; Header (NG_HDR_WORDS = 24 words, caller supplied):
;   +0 magic 0x47475546 ("GGUF" low-byte order)  +1 version
;   +2 tensor_count lo +3 hi   +4 kv_count lo +5 hi
;   +6 alignment               +7 data_off_lo +8 hi
;   +9 tensor table ptr        +10 tensor capacity +11 parsed tensors
;   +12 metadata_end lo +13 hi +14 tensor_info_end lo +15 hi
;   +16 storage cap            +17 storage base_lo +18 base_hi
;   +19 flags                  +20..23 reserved
;
; Tensor record (NG_TENSOR_WORDS = 64 words):
;   +0 magic 0x4554474E ("NGTE") +1 gguf dtype +2 n_dims
;   +3..18 dims[0..7] as (lo,hi) pairs
;   +19 name_len +20 name_off_lo +21 hi
;   +22 rel_off_lo +23 hi (in the data section)
;   +24 abs_off_lo +25 hi (storage byte offset)
;   +26 size_lo +27 hi        +28 count_lo +29 hi (elements)
;   +30 blocks_lo +31 hi      +32..55 nkv view (24 words)
;   +56 flags +57..63 reserved
;
; API:
;   ngguf_parse r1=storage cap r2=header r3=tensor table r4=max tensors
;               -> 0/-1
;   ngguf_blocks_to_nq4 r1=tensor record r2=dst blocks r3=dst capacity blocks
;               -> blocks converted, -1 bad record, -2 range not addressable
;                  below 4 GiB (first touch would need a 64-bit load)
;
; Q4_0/Q8_0 conversion: GGUF stores an f16 scale and 16/32 packed bytes per
; block.  ngguf_blocks_to_nq4 reads those bytes through the tensor's nkv view,
; converts the f16 scale to f32 exactly (nq_f16_to_f32), and repacks the block
; into nq4's word-aligned f32-scale layout.  The packed payload bytes are not
; altered.  This is the documented one-time conversion pass: a view cannot be
; consumed in place because the block stride changes 18->20 and 34->36 bytes.
;
; Limits: the GGUF header/metadata/tensor-info bytes must live below 4 GiB in
; the storage address window (guest LDB is 32-bit); tensor abs offsets/sizes
; and the image size are full 64-bit.  Element counts are limited to 32 bits
; because nkv shape words are 32-bit; byte sizes remain 64-bit.
;
; Scratch lives at 0x5800, above nkv (0x5000) and below nq4 (0x6000).

.include "nkv.nas"

.equ NG_MAGIC        0x46554747
.equ NG_ENTRY_MAGIC  0x4554474E
.equ NG_HDR_WORDS    24
.equ NG_TENSOR_WORDS 64
.equ NG_MAX_KV       4096
.equ NG_MAX_DIMS     4
.equ NG_MAX_NAME     65535
.equ NG_DEFAULT_ALIGN 32

.equ NG_H_MAGIC      0
.equ NG_H_VERSION    1
.equ NG_H_NTENSOR    2
.equ NG_H_NKV        4
.equ NG_H_ALIGN      6
.equ NG_H_DATAOFF    7
.equ NG_H_TENSORS    9
.equ NG_H_MAXT       10
.equ NG_H_PARSED     11
.equ NG_H_METAEND    12
.equ NG_H_INFOEND    14
.equ NG_H_CAP        16
.equ NG_H_BASELO     17
.equ NG_H_BASEHI     18
.equ NG_H_FLAGS      19

.equ NG_T_MAGIC      0
.equ NG_T_DTYPE      1
.equ NG_T_NDIMS      2
.equ NG_T_DIMS       3
.equ NG_T_NAMELEN    19
.equ NG_T_NAMEOFF    20
.equ NG_T_RELOFF     22
.equ NG_T_ABSOFF     24
.equ NG_T_SIZE       26
.equ NG_T_COUNT      28
.equ NG_T_BLOCKS     30
.equ NG_T_VIEW       32
.equ NG_T_FLAGS      56

.equ NG_DT_F32       0
.equ NG_DT_F16       1
.equ NG_DT_Q4_0      2
.equ NG_DT_Q8_0      8
.equ NG_Q_ELEMS      32
.equ NG_Q4_BYTES     18
.equ NG_Q8_BYTES     34

; GGUF metadata value types
.equ NG_VT_U8        0
.equ NG_VT_I8        1
.equ NG_VT_U16       2
.equ NG_VT_I16       3
.equ NG_VT_U32       4
.equ NG_VT_I32       5
.equ NG_VT_F32       6
.equ NG_VT_BOOL      7
.equ NG_VT_STRING    8
.equ NG_VT_ARRAY     9
.equ NG_VT_U64       10
.equ NG_VT_I64       11
.equ NG_VT_F64       12

; scratch
.equ NGX             0x5800
.equ NGX_CAP         0x5800
.equ NGX_HDR         0x5801
.equ NGX_TENS        0x5802
.equ NGX_MAX         0x5803
.equ NGX_ERR         0x5804
.equ NGX_BASE        0x5805
.equ NGX_SIZE        0x5807
.equ NGX_OFF         0x5809
.equ NGX_NT          0x580B
.equ NGX_NKV         0x580D
.equ NGX_ALIGN       0x580F
.equ NGX_I           0x5810
.equ NGX_J           0x5811
.equ NGX_KL          0x5812
.equ NGX_KEYOFF      0x5814
.equ NGX_TY          0x5816
.equ NGX_ND          0x5817
.equ NGX_COUNT       0x5818
.equ NGX_TSIZE       0x581A
.equ NGX_REL         0x581C
.equ NGX_ENT         0x581E
.equ NGX_SINFO       0x5820
.equ NGX_SHAPE       0x5828
.equ NGX_TMP         0x5830

; ---------------------------------------------------------------------------
; ng_u8: r1=off_lo r2=off_hi -> r1=byte (0 and NGX_ERR=1 on failure)
ng_u8:
  ST r15,r14,0
  ADD r14,r14,r13
  LD r3,r0,#NGX_ERR
  CMP r3,r0
  JMP[NE] @ng_u8_bad
  ST r1,r0,#NGX_OFF
  ST r2,r0,#NGX_OFF+1
  LD r3,r0,#NGX_BASE+1
  CMP r3,r0
  JMP[NE] @ng_u8_bad
  LD r3,r0,#NGX_OFF+1
  CMP r3,r0
  JMP[NE] @ng_u8_bad
  ; off < size (64-bit compare; size may be 2 TiB)
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  LD r3,r0,#NGX_SIZE
  LD r4,r0,#NGX_SIZE+1
  CALL @n64_cmp
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[NE] @ng_u8_bad
  LD r4,r0,#NGX_BASE
  LD r2,r0,#NGX_OFF
  ADD r3,r4,r2
  CMP r3,r4
  JMP[LT] @ng_u8_bad
  LDB r1,r3,0
  JMP @ng_u8_out
ng_u8_bad:
  MOVI r1,1
  ST r1,r0,#NGX_ERR
  MOVI r1,0
ng_u8_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ng_inc8: advance NGX_OFF by one
ng_inc8:
  LD r1,r0,#NGX_OFF
  ADDI r1,r1,1
  ST r1,r0,#NGX_OFF
  CMP r1,r0
  JMP[NE] @ng_inc8_d
  LD r1,r0,#NGX_OFF+1
  ADDI r1,r1,1
  ST r1,r0,#NGX_OFF+1
ng_inc8_d:
  RET

; ng_u32: r1=off_lo r2=off_hi -> r1=32-bit value, advances off by 4
ng_u32:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NGX_OFF
  ST r2,r0,#NGX_OFF+1
  ST r0,r0,#NGX_TMP
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u8
  ST r1,r0,#NGX_TMP
  CALL @ng_inc8
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u8
  SHL r1,r1,8
  LD r2,r0,#NGX_TMP
  ADD r2,r2,r1
  ST r2,r0,#NGX_TMP
  CALL @ng_inc8
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u8
  SHL r1,r1,16
  LD r2,r0,#NGX_TMP
  ADD r2,r2,r1
  ST r2,r0,#NGX_TMP
  CALL @ng_inc8
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u8
  SHL r1,r1,24
  LD r2,r0,#NGX_TMP
  ADD r2,r2,r1
  ST r2,r0,#NGX_TMP
  CALL @ng_inc8
  LD r1,r0,#NGX_TMP
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ng_u64: r1=off_lo r2=off_hi -> r1=lo r2=hi, advances off by 8
ng_u64:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @ng_u32
  ST r1,r0,#NGX_TMP+4
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u32
  ST r1,r0,#NGX_TMP+5
  LD r1,r0,#NGX_TMP+4
  LD r2,r0,#NGX_TMP+5
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ng_skip: r1=len_lo r2=len_hi -> advance off, bounds checked
ng_skip:
  ST r15,r14,0
  ADD r14,r14,r13
  LD r3,r0,#NGX_ERR
  CMP r3,r0
  JMP[NE] @ng_skip_early
  LD r3,r0,#NGX_OFF
  LD r4,r0,#NGX_OFF+1
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @ng_skip_bad
  ST r1,r0,#NGX_TMP+6
  ST r2,r0,#NGX_TMP+7
  LD r3,r0,#NGX_SIZE
  LD r4,r0,#NGX_SIZE+1
  CALL @n64_cmp
  MOVI r3,1
  CMP r1,r3
  JMP[EQ] @ng_skip_bad
  LD r1,r0,#NGX_TMP+6
  LD r2,r0,#NGX_TMP+7
  ST r1,r0,#NGX_OFF
  ST r2,r0,#NGX_OFF+1
  JMP @ng_skip_out
ng_skip_early:
  JMP @ng_skip_out
ng_skip_bad:
  MOVI r1,1
  ST r1,r0,#NGX_ERR
ng_skip_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ng_key_eq: r1=off_lo r2=off_hi r3=key byte address r4=len -> r1=1/0
ng_key_eq:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NGX_KEYOFF
  ST r2,r0,#NGX_KEYOFF+1
  LD r5,r0,#NGX_OFF
  ST r5,r0,#NGX_TMP+26
  LD r5,r0,#NGX_OFF+1
  ST r5,r0,#NGX_TMP+27
  ST r1,r0,#NGX_OFF
  ST r2,r0,#NGX_OFF+1
  ST r3,r0,#NGX_TMP+20
  ST r4,r0,#NGX_TMP+21
  ST r0,r0,#NGX_TMP+8
ng_ke_l:
  LD r1,r0,#NGX_TMP+8
  LD r2,r0,#NGX_TMP+21
  CMP r1,r2
  JMP[GE] @ng_ke_yes
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u8
  ST r1,r0,#NGX_TMP+9
  LD r3,r0,#NGX_TMP+20
  LDB r4,r3,0
  LD r5,r0,#NGX_TMP+9
  CMP r5,r4
  JMP[NE] @ng_ke_no
  LD r1,r0,#NGX_TMP+20
  ADDI r1,r1,1
  ST r1,r0,#NGX_TMP+20
  LD r1,r0,#NGX_OFF
  ADDI r1,r1,1
  ST r1,r0,#NGX_OFF
  CMP r1,r0
  JMP[NE] @ng_ke_noinc
  LD r1,r0,#NGX_OFF+1
  ADDI r1,r1,1
  ST r1,r0,#NGX_OFF+1
ng_ke_noinc:
  LD r1,r0,#NGX_TMP+8
  ADD r1,r1,r13
  ST r1,r0,#NGX_TMP+8
  JMP @ng_ke_l
ng_ke_yes:
  MOVI r1,1
  JMP @ng_ke_restore
ng_ke_no:
  MOVI r1,0
ng_ke_restore:
  ST r1,r0,#NGX_TMP+10
  LD r1,r0,#NGX_TMP+26
  LD r2,r0,#NGX_TMP+27
  ST r1,r0,#NGX_OFF
  ST r2,r0,#NGX_OFF+1
  LD r1,r0,#NGX_TMP+10
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ng_type_size: r1=GGUF value type -> r1=bytes, 0=string/array, -1=bad
ng_type_size:
  CMP r1,r0
  JMP[EQ] @ng_ts_1
  MOVI r2,1
  CMP r1,r2
  JMP[EQ] @ng_ts_1
  MOVI r2,2
  CMP r1,r2
  JMP[EQ] @ng_ts_2
  MOVI r2,3
  CMP r1,r2
  JMP[EQ] @ng_ts_2
  MOVI r2,4
  CMP r1,r2
  JMP[EQ] @ng_ts_4
  MOVI r2,5
  CMP r1,r2
  JMP[EQ] @ng_ts_4
  MOVI r2,6
  CMP r1,r2
  JMP[EQ] @ng_ts_4
  MOVI r2,7
  CMP r1,r2
  JMP[EQ] @ng_ts_1
  MOVI r2,10
  CMP r1,r2
  JMP[EQ] @ng_ts_8
  MOVI r2,11
  CMP r1,r2
  JMP[EQ] @ng_ts_8
  MOVI r2,12
  CMP r1,r2
  JMP[EQ] @ng_ts_8
  MOVI r2,8
  CMP r1,r2
  JMP[EQ] @ng_ts_special
  MOVI r2,9
  CMP r1,r2
  JMP[EQ] @ng_ts_special
  LA r1,0xFFFFFFFF
  RET
ng_ts_1:
  MOVI r1,1
  RET
ng_ts_2:
  MOVI r1,2
  RET
ng_ts_4:
  MOVI r1,4
  RET
ng_ts_8:
  MOVI r1,8
  RET
ng_ts_special:
  MOVI r1,0
  RET

; ng_skip_value: r1=value type -> skip the value at NGX_OFF
ng_skip_value:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NGX_TMP+12
  MOVI r2,9
  CMP r1,r2
  JMP[EQ] @ng_sv_array
  MOVI r2,8
  CMP r1,r2
  JMP[EQ] @ng_sv_string
  LD r1,r0,#NGX_TMP+12
  CALL @ng_type_size
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ng_sv_bad
  MOVI r2,0
  MOVI r3,0
  CALL @ng_skip
  JMP @ng_sv_out
ng_sv_string:
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u64
  CALL @ng_skip
  JMP @ng_sv_out
ng_sv_array:
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u32
  ST r1,r0,#NGX_TMP+13
  MOVI r2,9
  CMP r1,r2
  JMP[EQ] @ng_sv_bad
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u64
  ; require count < 2^32 (practical metadata arrays)
  CMP r2,r0
  JMP[NE] @ng_sv_bad
  ST r1,r0,#NGX_TMP+14
  LD r1,r0,#NGX_TMP+13
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ng_sv_array_done
  MOVI r2,8
  CMP r1,r2
  JMP[EQ] @ng_sv_array_str
  ; fixed-size array: count * elem_size
  CALL @ng_type_size
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @ng_sv_bad
  LD r2,r0,#NGX_TMP+14
  MOVI r3,0
  CALL @n64_mul32
  CALL @ng_skip
  JMP @ng_sv_out
ng_sv_array_str:
  LD r1,r0,#NGX_TMP+14
  LA r2,0x10000
  CMP r1,r2
  JMP[GT] @ng_sv_bad
  MOVI r3,0
  ST r3,r0,#NGX_TMP+15
ng_sv_str_l:
  LD r1,r0,#NGX_TMP+15
  LD r2,r0,#NGX_TMP+14
  CMP r1,r2
  JMP[GE] @ng_sv_array_done
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u64
  CALL @ng_skip
  LD r1,r0,#NGX_TMP+15
  ADD r1,r1,r13
  ST r1,r0,#NGX_TMP+15
  JMP @ng_sv_str_l
ng_sv_array_done:
  JMP @ng_sv_out
ng_sv_bad:
  MOVI r1,1
  ST r1,r0,#NGX_ERR
ng_sv_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; ngguf_parse: r1=storage cap r2=header(24) r3=tensor table r4=max tensors
ngguf_parse:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NGX_CAP
  ST r2,r0,#NGX_HDR
  ST r3,r0,#NGX_TENS
  ST r4,r0,#NGX_MAX
  ST r0,r0,#NGX_ERR

  ; zero the header
  LD r1,r0,#NGX_HDR
  MOVI r2,#NG_HDR_WORDS
ng_zero:
  CMP r2,r0
  JMP[EQ] @ng_zero_d
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @ng_zero
ng_zero_d:

  ; storage metadata
  LD r1,r0,#NGX_CAP
  LA r2,#NGX_SINFO
  CALL @nkv_storage_info
  CMP r1,r0
  JMP[NE] @ng_fail
  LA r4,#NGX_SINFO
  LD r1,r4,4
  MOVI r2,1
  BOOL.8 r1,r1,r2
  CMP r1,r0
  JMP[EQ] @ng_fail
  LD r1,r4,0
  ST r1,r0,#NGX_BASE
  LD r1,r4,1
  ST r1,r0,#NGX_BASE+1
  LD r1,r4,2
  ST r1,r0,#NGX_SIZE
  LD r1,r4,3
  ST r1,r0,#NGX_SIZE+1
  LD r1,r4,7
  MOVI r2,#NKV_CLASS_STOR
  CMP r1,r2
  JMP[NE] @ng_fail

  ; magic
  MOVI r1,0
  MOVI r2,0
  CALL @ng_u32
  LA r2,#NG_MAGIC
  CMP r1,r2
  JMP[NE] @ng_fail
  ST r1,r0,#NGX_TMP+16

  ; version
  MOVI r1,4
  MOVI r2,0
  CALL @ng_u32
  MOVI r2,2
  CMP r1,r2
  JMP[EQ] @ng_ver_ok
  MOVI r2,3
  CMP r1,r2
  JMP[NE] @ng_fail
ng_ver_ok:
  ST r1,r0,#NGX_TMP+17

  ; counts
  MOVI r1,8
  MOVI r2,0
  CALL @ng_u64
  ST r1,r0,#NGX_NT
  ST r2,r0,#NGX_NT+1
  MOVI r1,16
  MOVI r2,0
  CALL @ng_u64
  ST r1,r0,#NGX_NKV
  ST r2,r0,#NGX_NKV+1

  LD r1,r0,#NGX_NT+1
  CMP r1,r0
  JMP[NE] @ng_fail
  LD r1,r0,#NGX_NT
  LD r2,r0,#NGX_MAX
  CMP r1,r2
  JMP[GT] @ng_fail
  CMP r1,r0
  JMP[EQ] @ng_fail
  LD r1,r0,#NGX_NKV+1
  CMP r1,r0
  JMP[NE] @ng_fail
  LD r1,r0,#NGX_NKV
  MOVI r2,#NG_MAX_KV
  CMP r1,r2
  JMP[GT] @ng_fail

  ; header base fields
  LD r4,r0,#NGX_HDR
  LA r1,#NG_MAGIC
  ST r1,r4,#NG_H_MAGIC
  LD r1,r0,#NGX_TMP+17
  ST r1,r4,#NG_H_VERSION
  LD r1,r0,#NGX_NT
  ST r1,r4,#NG_H_NTENSOR
  LD r1,r0,#NGX_NT+1
  ST r1,r4,#NG_H_NTENSOR+1
  LD r1,r0,#NGX_NKV
  ST r1,r4,#NG_H_NKV
  LD r1,r0,#NGX_NKV+1
  ST r1,r4,#NG_H_NKV+1
  LD r1,r0,#NGX_TENS
  ST r1,r4,#NG_H_TENSORS
  LD r1,r0,#NGX_MAX
  ST r1,r4,#NG_H_MAXT
  LD r1,r0,#NGX_CAP
  ST r1,r4,#NG_H_CAP
  LD r1,r0,#NGX_BASE
  ST r1,r4,#NG_H_BASELO
  LD r1,r0,#NGX_BASE+1
  ST r1,r4,#NG_H_BASEHI

  ; metadata scan
  MOVI r1,24
  MOVI r2,0
  ST r1,r0,#NGX_OFF
  ST r2,r0,#NGX_OFF+1
  ST r0,r0,#NGX_ALIGN
  ST r0,r0,#NGX_I
ng_kv_l:
  LD r1,r0,#NGX_I
  LD r2,r0,#NGX_NKV
  CMP r1,r2
  JMP[GE] @ng_kv_d

  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u64
  ST r1,r0,#NGX_KL
  ST r2,r0,#NGX_KL+1
  CMP r2,r0
  JMP[NE] @ng_fail
  MOVI r3,#NG_MAX_NAME
  CMP r1,r3
  JMP[GT] @ng_fail
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  ST r1,r0,#NGX_KEYOFF
  ST r2,r0,#NGX_KEYOFF+1
  LD r1,r0,#NGX_KL
  MOVI r2,0
  CALL @ng_skip
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u32
  ST r1,r0,#NGX_TY

  ; general.alignment?
  LD r1,r0,#NGX_KL
  MOVI r2,17
  CMP r1,r2
  JMP[NE] @ng_kv_nomatch
  LD r1,r0,#NGX_KEYOFF
  LD r2,r0,#NGX_KEYOFF+1
  LA r3,@ng_key_align
  SHL r3,r3,2
  MOVI r4,17
  CALL @ng_key_eq
  CMP r1,r0
  JMP[EQ] @ng_kv_nomatch
  LD r1,r0,#NGX_TY
  MOVI r2,#NG_VT_U32
  CMP r1,r2
  JMP[NE] @ng_fail
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u32
  ST r1,r0,#NGX_ALIGN
  JMP @ng_kv_next
ng_kv_nomatch:
  LD r1,r0,#NGX_TY
  CALL @ng_skip_value
  LD r1,r0,#NGX_ERR
  CMP r1,r0
  JMP[NE] @ng_fail
ng_kv_next:
  LD r1,r0,#NGX_I
  ADD r1,r1,r13
  ST r1,r0,#NGX_I
  JMP @ng_kv_l
ng_kv_d:

  ; alignment default / validation (power of two, <= 1 MiB)
  LD r1,r0,#NGX_ALIGN
  CMP r1,r0
  JMP[NE] @ng_align_set
  MOVI r1,#NG_DEFAULT_ALIGN
  ST r1,r0,#NGX_ALIGN
ng_align_set:
  LD r1,r0,#NGX_ALIGN
  LA r2,0x100000
  CMP r1,r2
  JMP[GT] @ng_fail
  ADD r2,r1,r0
  ADDI r2,r2,-1
  BOOL.8 r2,r1,r2
  CMP r2,r0
  JMP[NE] @ng_fail
  LD r4,r0,#NGX_HDR
  ST r1,r4,#NG_H_ALIGN
  LD r1,r0,#NGX_OFF
  ST r1,r4,#NG_H_METAEND
  LD r1,r0,#NGX_OFF+1
  ST r1,r4,#NG_H_METAEND+1

  ; -------------------------------------------------------------------------
  ; tensor infos
  ST r0,r0,#NGX_I
ng_ti_l:
  LD r1,r0,#NGX_I
  LD r2,r0,#NGX_NT
  CMP r1,r2
  JMP[GE] @ng_ti_d
  ; entry = tens + i*64
  SHL r2,r1,6
  LD r3,r0,#NGX_TENS
  ADD r3,r3,r2
  ST r3,r0,#NGX_ENT

  ; name
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u64
  CMP r2,r0
  JMP[NE] @ng_fail
  MOVI r3,#NG_MAX_NAME
  CMP r1,r3
  JMP[GT] @ng_fail
  LD r3,r0,#NGX_ENT
  ST r1,r3,#NG_T_NAMELEN
  LD r2,r0,#NGX_OFF
  ST r2,r3,#NG_T_NAMEOFF
  LD r2,r0,#NGX_OFF+1
  ST r2,r3,#NG_T_NAMEOFF+1
  MOVI r2,0
  CALL @ng_skip

  ; n_dims
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u32
  CMP r1,r0
  JMP[EQ] @ng_fail
  MOVI r2,#NG_MAX_DIMS
  CMP r1,r2
  JMP[GT] @ng_fail
  ST r1,r0,#NGX_ND
  LD r3,r0,#NGX_ENT
  ST r1,r3,#NG_T_NDIMS

  ; dims
  ST r0,r0,#NGX_J
ng_dim_l:
  LD r1,r0,#NGX_J
  LD r2,r0,#NGX_ND
  CMP r1,r2
  JMP[GE] @ng_dim_d
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u64
  CMP r2,r0
  JMP[NE] @ng_fail
  CMP r1,r0
  JMP[EQ] @ng_fail
  LD r3,r0,#NGX_ENT
  LD r4,r0,#NGX_J
  SHL r4,r4,1
  ADD r3,r3,r4
  ST r1,r3,#NG_T_DIMS
  ST r2,r3,#NG_T_DIMS+1
  LD r3,r0,#NGX_J
  ADD r3,r3,r0
  LA r4,#NGX_SHAPE
  ADD r4,r4,r3
  ST r1,r4,0
  LD r1,r0,#NGX_J
  ADD r1,r1,r13
  ST r1,r0,#NGX_J
  JMP @ng_dim_l
ng_dim_d:

  ; dtype
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u32
  ST r1,r0,#NGX_TY
  LD r4,r0,#NGX_ENT
  ST r1,r4,#NG_T_DTYPE

  ; relative offset
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  CALL @ng_u64
  ST r1,r0,#NGX_REL
  ST r2,r0,#NGX_REL+1
  LD r4,r0,#NGX_ENT
  ST r1,r4,#NG_T_RELOFF
  ST r2,r4,#NG_T_RELOFF+1

  ; count = product(dims)
  MOVI r1,1
  ST r1,r0,#NGX_COUNT
  ST r0,r0,#NGX_COUNT+1
  ST r0,r0,#NGX_J
ng_cnt_l:
  LD r1,r0,#NGX_J
  LD r2,r0,#NGX_ND
  CMP r1,r2
  JMP[GE] @ng_cnt_d
  LA r3,#NGX_SHAPE
  ADD r3,r3,r1
  LD r1,r3,0
  LD r2,r0,#NGX_COUNT
  LD r3,r0,#NGX_COUNT+1
  CALL @n64_mul32
  ST r1,r0,#NGX_COUNT
  ST r2,r0,#NGX_COUNT+1
  LD r1,r0,#NGX_J
  ADD r1,r1,r13
  ST r1,r0,#NGX_J
  JMP @ng_cnt_l
ng_cnt_d:
  LD r1,r0,#NGX_COUNT+1
  CMP r1,r0
  JMP[NE] @ng_fail
  LD r4,r0,#NGX_ENT
  LD r1,r0,#NGX_COUNT
  LD r2,r0,#NGX_COUNT+1
  ST r1,r4,#NG_T_COUNT
  ST r2,r4,#NG_T_COUNT+1

  ; size + blocks by type
  LD r1,r0,#NGX_TY
  CMP r1,r0
  JMP[EQ] @ng_sz_f32
  MOVI r2,#NG_DT_F16
  CMP r1,r2
  JMP[EQ] @ng_sz_f16
  MOVI r2,#NG_DT_Q4_0
  CMP r1,r2
  JMP[EQ] @ng_sz_q4
  MOVI r2,#NG_DT_Q8_0
  CMP r1,r2
  JMP[EQ] @ng_sz_q8
  JMP @ng_fail
ng_sz_f32:
  MOVI r1,4
  JMP @ng_sz_plain
ng_sz_f16:
  MOVI r1,2
ng_sz_plain:
  MOVI r3,0
  LD r2,r0,#NGX_COUNT
  LD r3,r0,#NGX_COUNT+1
  CALL @n64_mul32
  ST r1,r0,#NGX_TSIZE
  ST r2,r0,#NGX_TSIZE+1
  LD r4,r0,#NGX_ENT
  ST r0,r4,#NG_T_BLOCKS
  ST r0,r4,#NG_T_BLOCKS+1
  JMP @ng_sz_done
ng_sz_q4:
  MOVI r5,#NG_Q4_BYTES
  JMP @ng_sz_q
ng_sz_q8:
  MOVI r5,#NG_Q8_BYTES
ng_sz_q:
  LD r1,r0,#NGX_COUNT
  MOVI r2,#NG_Q_ELEMS
  MODU r3,r1,r2
  CMP r3,r0
  JMP[NE] @ng_fail
  DIVU r1,r1,r2
  ST r1,r0,#NGX_TMP+18
  ADD r1,r5,r0
  LD r2,r0,#NGX_TMP+18
  MOVI r3,0
  CALL @n64_mul32
  ST r1,r0,#NGX_TSIZE
  ST r2,r0,#NGX_TSIZE+1
  LD r4,r0,#NGX_ENT
  LD r1,r0,#NGX_TMP+18
  ST r1,r4,#NG_T_BLOCKS
  ST r0,r4,#NG_T_BLOCKS+1
ng_sz_done:
  LD r4,r0,#NGX_ENT
  LD r1,r0,#NGX_TSIZE
  ST r1,r4,#NG_T_SIZE
  LD r1,r0,#NGX_TSIZE+1
  ST r1,r4,#NG_T_SIZE+1
  LA r1,#NG_ENTRY_MAGIC
  ST r1,r4,#NG_T_MAGIC

  LD r1,r0,#NGX_I
  ADD r1,r1,r13
  ST r1,r0,#NGX_I
  JMP @ng_ti_l
ng_ti_d:
  LD r4,r0,#NGX_HDR
  LD r1,r0,#NGX_OFF
  ST r1,r4,#NG_H_INFOEND
  LD r1,r0,#NGX_OFF+1
  ST r1,r4,#NG_H_INFOEND+1

  ; data_off = align_up(info_end, alignment)
  LD r1,r0,#NGX_OFF
  LD r2,r0,#NGX_OFF+1
  LD r3,r0,#NGX_ALIGN
  CALL @n64_alignup
  ST r1,r0,#NGX_TMP+20
  ST r2,r0,#NGX_TMP+21
  LD r4,r0,#NGX_HDR
  ST r1,r4,#NG_H_DATAOFF
  ST r2,r4,#NG_H_DATAOFF+1

  ; -------------------------------------------------------------------------
  ; second pass: abs offsets, bounds, views
  ST r0,r0,#NGX_I
ng_vi_l:
  LD r1,r0,#NGX_I
  LD r2,r0,#NGX_NT
  CMP r1,r2
  JMP[GE] @ng_vi_d
  SHL r2,r1,6
  LD r3,r0,#NGX_TENS
  ADD r3,r3,r2
  ST r3,r0,#NGX_ENT
  ; reload this entry's dtype and size (scratch still holds the last tensor)
  LD r1,r3,#NG_T_DTYPE
  ST r1,r0,#NGX_TY
  LD r1,r3,#NG_T_SIZE
  ST r1,r0,#NGX_TSIZE
  LD r1,r3,#NG_T_SIZE+1
  ST r1,r0,#NGX_TSIZE+1

  ; rebuild the compact shape[0..ndims-1] from this entry's 64-bit dims
  ST r0,r0,#NGX_J
ng_vshape_l:
  LD r1,r0,#NGX_J
  LD r2,r0,#NGX_ENT
  LD r2,r2,#NG_T_NDIMS
  CMP r1,r2
  JMP[GE] @ng_vshape_d
  LD r3,r0,#NGX_ENT
  SHL r4,r1,1
  ADD r3,r3,r4
  LD r4,r3,#NG_T_DIMS
  LA r5,#NGX_SHAPE
  ADD r5,r5,r1
  ST r4,r5,0
  LD r1,r0,#NGX_J
  ADD r1,r1,r13
  ST r1,r0,#NGX_J
  JMP @ng_vshape_l
ng_vshape_d:

  ; rel must be aligned
  LD r3,r0,#NGX_ENT
  LD r1,r3,#NG_T_RELOFF
  LD r2,r0,#NGX_ALIGN
  ADDI r2,r2,-1
  BOOL.8 r1,r1,r2
  CMP r1,r0
  JMP[NE] @ng_fail

  ; abs = data_off + rel
  LD r1,r0,#NGX_TMP+20
  LD r2,r0,#NGX_TMP+21
  LD r3,r0,#NGX_ENT
  LD r3,r3,#NG_T_RELOFF
  LD r4,r0,#NGX_ENT
  LD r4,r4,#NG_T_RELOFF+1
  CALL @n64_add
  ST r1,r0,#NGX_TMP+22
  ST r2,r0,#NGX_TMP+23
  ; abs >= data_off (rejects 64-bit wraparound)
  LD r3,r0,#NGX_TMP+20
  LD r4,r0,#NGX_TMP+21
  CALL @n64_cmp
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @ng_fail

  ; end = abs + size; end >= abs; end <= storage size
  LD r1,r0,#NGX_TMP+22
  LD r2,r0,#NGX_TMP+23
  LD r3,r0,#NGX_ENT
  LD r3,r3,#NG_T_SIZE
  LD r4,r0,#NGX_ENT
  LD r4,r4,#NG_T_SIZE+1
  CALL @n64_add
  ST r1,r0,#NGX_TMP+24
  ST r2,r0,#NGX_TMP+25
  LD r3,r0,#NGX_TMP+22
  LD r4,r0,#NGX_TMP+23
  CALL @n64_cmp
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[EQ] @ng_fail
  LD r1,r0,#NGX_TMP+24
  LD r2,r0,#NGX_TMP+25
  LD r3,r0,#NGX_SIZE
  LD r4,r0,#NGX_SIZE+1
  CALL @n64_cmp
  MOVI r3,1
  CMP r1,r3
  JMP[EQ] @ng_fail

  ; store abs
  LD r3,r0,#NGX_ENT
  LD r1,r0,#NGX_TMP+22
  ST r1,r3,#NG_T_ABSOFF
  LD r1,r0,#NGX_TMP+23
  ST r1,r3,#NG_T_ABSOFF+1

  ; view
  LD r1,r0,#NGX_TY
  CMP r1,r0
  JMP[EQ] @ng_v_f32
  MOVI r2,#NG_DT_F16
  CMP r1,r2
  JMP[EQ] @ng_v_f16
  ; quantized: raw u8 view over the packed bytes
  LD r3,r0,#NGX_TSIZE+1
  CMP r3,r0
  JMP[NE] @ng_fail
  LD r1,r0,#NGX_TSIZE
  LA r2,#NGX_SHAPE
  ST r1,r2,0
  LD r1,r0,#NGX_CAP
  LD r2,r0,#NGX_TMP+22
  LD r3,r0,#NGX_TMP+23
  LD r4,r0,#NGX_TSIZE
  LD r5,r0,#NGX_TSIZE+1
  MOVI r6,0
  MOVI r7,1
  LA r8,#NGX_SHAPE
  LD r9,r0,#NGX_ENT
  ADDI r9,r9,#NG_T_VIEW
  CALL @nkv_view_create
  CMP r1,r0
  JMP[NE] @ng_fail
  JMP @ng_v_ok
ng_v_f32:
  MOVI r6,2
  JMP @ng_v_typed
ng_v_f16:
  MOVI r6,1
ng_v_typed:
  LD r1,r0,#NGX_CAP
  LD r2,r0,#NGX_TMP+22
  LD r3,r0,#NGX_TMP+23
  LD r4,r0,#NGX_TSIZE
  LD r5,r0,#NGX_TSIZE+1
  LD r7,r0,#NGX_ENT
  LD r7,r7,#NG_T_NDIMS
  LA r8,#NGX_SHAPE
  LD r9,r0,#NGX_ENT
  ADDI r9,r9,#NG_T_VIEW
  CALL @nkv_view_create
  CMP r1,r0
  JMP[NE] @ng_fail
ng_v_ok:
  LD r1,r0,#NGX_I
  ADD r1,r1,r13
  ST r1,r0,#NGX_I
  JMP @ng_vi_l
ng_vi_d:
  LD r4,r0,#NGX_HDR
  LD r1,r0,#NGX_NT
  ST r1,r4,#NG_H_PARSED
  MOVI r1,0
  JMP @ng_out
ng_fail:
  LA r1,0xFFFFFFFF
ng_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; ngguf_blocks_to_nq4: r1=record r2=dst r3=capacity(blocks)
;   -> blocks converted, -1 bad record, -2 not addressable below 4 GiB
.equ NGC 0x5840
ngguf_blocks_to_nq4:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NGC+0
  ST r2,r0,#NGC+1
  ST r3,r0,#NGC+2
  LD r2,r1,0
  LA r3,#NG_ENTRY_MAGIC
  CMP r2,r3
  JMP[NE] @ngc_bad
  LD r2,r1,#NG_T_DTYPE
  CMP r2,r0
  JMP[EQ] @ngc_fail
  MOVI r3,#NG_DT_Q4_0
  CMP r2,r3
  JMP[EQ] @ngc_q4
  MOVI r3,#NG_DT_Q8_0
  CMP r2,r3
  JMP[NE] @ngc_fail
  MOVI r3,#NG_Q8_BYTES
  MOVI r4,1
  JMP @ngc_type
ngc_q4:
  MOVI r3,#NG_Q4_BYTES
  MOVI r4,0
ngc_type:
  ST r3,r0,#NGC+3          ; bytes/block
  ST r4,r0,#NGC+4          ; q8 flag
  LD r2,r1,#NG_T_BLOCKS
  LD r3,r1,#NG_T_BLOCKS+1
  CMP r3,r0
  JMP[NE] @ngc_fail
  CMP r2,r0
  JMP[EQ] @ngc_fail
  ST r2,r0,#NGC+5          ; blocks
  LD r3,r0,#NGC+2
  CMP r2,r3
  JMP[GT] @ngc_fail

  ; first address of the tensor through its nkv view
  LD r2,r1,#NG_T_VIEW
  LA r3,#NKV_VIEW_MAGIC
  CMP r2,r3
  JMP[NE] @ngc_fail
  ADDI r1,r1,#NG_T_VIEW
  MOVI r2,0
  MOVI r3,0
  CALL @nkv_view_addr
  CMP r3,r0
  JMP[NE] @ngc_fail
  CMP r2,r0
  JMP[NE] @ngc_high
  ST r1,r0,#NGC+6          ; addr lo

  ; view size must cover blocks*bytes
  LD r1,r0,#NGC+5
  LD r2,r0,#NGC+3
  MOVI r3,0
  CALL @n64_mul32
  ST r1,r0,#NGC+7
  ST r2,r0,#NGC+8
  LD r4,r0,#NGC+0
  ADD r4,r4,r0
  LD r3,r4,#NG_T_VIEW+8   ; view size lo
  LD r4,r4,#NG_T_VIEW+9   ; view size hi
  LD r1,r0,#NGC+7
  LD r2,r0,#NGC+8
  CALL @n64_cmp
  CMP r1,r0
  JMP[EQ] @ngc_size_ok
  LA r5,0xFFFFFFFF
  CMP r1,r5
  JMP[NE] @ngc_fail
ngc_size_ok:
  ; end = addr + total must stay below 4 GiB
  LD r1,r0,#NGC+6
  MOVI r2,0
  LD r3,r0,#NGC+7
  LD r4,r0,#NGC+8
  CALL @n64_add
  CMP r2,r0
  JMP[NE] @ngc_high
  ST r1,r0,#NGC+9          ; end lo

  ST r0,r0,#NGC+10         ; b
  LD r1,r0,#NGC+1
  ST r1,r0,#NGC+11         ; dst cursor
ngc_loop:
  LD r1,r0,#NGC+10
  LD r2,r0,#NGC+5
  CMP r1,r2
  JMP[GE] @ngc_ok
  ; src = addr + b*bytes/block
  LD r1,r0,#NGC+10
  LD r2,r0,#NGC+3
  MOVI r3,0
  CALL @n64_mul32
  ADD r3,r1,r0
  ADD r4,r2,r0
  LD r1,r0,#NGC+6
  MOVI r2,0
  CALL @n64_add
  CMP r2,r0
  JMP[NE] @ngc_high
  ST r1,r0,#NGC+12         ; src byte address
  ; f16 scale (little endian)
  ADD r3,r1,r0
  LDB r1,r3,0
  LDB r2,r3,1
  SHL r2,r2,8
  BOOL.14 r1,r1,r2
  CALL @n64_f16_to_f32
  LD r2,r0,#NGC+11
  ST r1,r2,0
  ; payload words
  ST r0,r0,#NGC+13
  LD r1,r0,#NGC+4
  CMP r1,r0
  JMP[EQ] @ngc_q4w
  MOVI r1,8
  JMP @ngc_nw
ngc_q4w:
  MOVI r1,4
ngc_nw:
  ST r1,r0,#NGC+14
ngc_word:
  LD r1,r0,#NGC+13
  LD r2,r0,#NGC+14
  CMP r1,r2
  JMP[GE] @ngc_blkdone
  ; byte base = 2 + w*4
  SHL r2,r1,2
  ADDI r2,r2,2
  LD r3,r0,#NGC+12
  ADD r2,r3,r2
  LDB r1,r2,0
  LDB r3,r2,1
  SHL r3,r3,8
  BOOL.14 r1,r1,r3
  LDB r3,r2,2
  SHL r3,r3,16
  BOOL.14 r1,r1,r3
  LDB r3,r2,3
  SHL r3,r3,24
  BOOL.14 r1,r1,r3
  LD r2,r0,#NGC+11
  ADDI r2,r2,1
  LD r3,r0,#NGC+13
  ADD r2,r2,r3
  ST r1,r2,0
  LD r1,r0,#NGC+13
  ADD r1,r1,r13
  ST r1,r0,#NGC+13
  JMP @ngc_word
ngc_blkdone:
  LD r1,r0,#NGC+11
  LD r2,r0,#NGC+4
  CMP r2,r0
  JMP[EQ] @ngc_adv4
  ADDI r1,r1,9
  JMP @ngc_advd
ngc_adv4:
  ADDI r1,r1,5
ngc_advd:
  ST r1,r0,#NGC+11
  LD r1,r0,#NGC+10
  ADD r1,r1,r13
  ST r1,r0,#NGC+10
  JMP @ngc_loop
ngc_ok:
  LD r1,r0,#NGC+5
  JMP @ngc_out
ngc_high:
  LA r1,0xFFFFFFFE
  JMP @ngc_out
ngc_fail:
ngc_bad:
  LA r1,0xFFFFFFFF
ngc_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; product-form magic 0x46554747 is "GGUF" in LE byte order.
ng_key_align:
.str "general.alignment"
