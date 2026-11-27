; nsafetensors_test.nas - safetensors header parser and nkv views (F7b).
;
; Hand-built header (200 bytes, padded to 8):
;   {"__metadata__":{"format":"pt"},
;    "a":{"dtype":"F32","shape":[2,2],"data_offsets":[0,16]},
;    "b":{"dtype":"F16","shape":[4],"data_offsets":[16,24]},
;    "c":{"dtype":"U8","shape":[3],"data_offsets":[24,27]}}
; data at 8+200 = 208:
;   a: f32 1,2,3,4 (16B); b: f16 0.5,-1,2,0 (8B); c: AA BB CC (3B).
;
; Proves: u64 length, header length/data offset, three records with exact
; dtype/rank/shape/begin/end/size/count/name, zero-copy nkv views with 64-bit
; absolute offsets, element reads through nkv_view_addr, F16 raw bytes;
; rejection of bad JSON start, bad dtype, zero/non-numeric/unknown shape,
; missing shape field, begin>end, size mismatch, data past storage, too many
; tensors, zero/oversized header length and truncated storage.
; Success prints exactly O.
.org 0
JMP @main
; ---------------------------------------------------------------------------
.org 0x9000
sfimg:
.word 0x000000C8, 0x00000000, 0x5F5F227B, 0x6174656D, 0x61746164, 0x3A225F5F, 0x6F66227B, 0x74616D72
.word 0x70223A22, 0x2C7D2274, 0x3A226122, 0x7464227B, 0x22657079, 0x3346223A, 0x222C2232, 0x70616873
.word 0x5B3A2265, 0x5D322C32, 0x6164222C, 0x6F5F6174, 0x65736666, 0x3A227374, 0x312C305B, 0x2C7D5D36
.word 0x3A226222, 0x7464227B, 0x22657079, 0x3146223A, 0x222C2236, 0x70616873, 0x5B3A2265, 0x222C5D34
.word 0x61746164, 0x66666F5F, 0x73746573, 0x315B3A22, 0x34322C36, 0x222C7D5D, 0x7B3A2263, 0x79746422
.word 0x3A226570, 0x22385522, 0x6873222C, 0x22657061, 0x5D335B3A, 0x6164222C, 0x6F5F6174, 0x65736666
.word 0x3A227374, 0x2C34325B, 0x7D5D3732, 0x2020207D
.word 0x3F800000, 0x40000000, 0x40400000, 0x40800000
.word 0xBC003800, 0x00004000, 0x00CCBBAA
sfend:
.word 0
sfhdr:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
sftens:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
sccap:
.word 0
stagev:
.word 0
nm_a:
.str "a"
nm_b:
.str "b"
nm_c:
.str "c"
; ---------------------------------------------------------------------------
.org 0xA000
sfwork:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
; ---------------------------------------------------------------------------
.org 0x10000
.include "../lib/nsafetensors.nas"

main:
MOVI r13,1
MOVI r14,0x7000
CALL @nobj_init

; ---------------------------------------------------------------------------
; canonical parse
MOVI r1,0x31
CALL @stage
LA r1,@sfimg
MOVI r2,236
MOVI r3,0
CALL @mkcap
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@sccap
LA r1,@sccap
LD r1,r1,0
MOVI r2,8
CALL @parse_cap
CMP r1,r0
JMP[NE] @fail

; descriptor
LA r4,@sfhdr
LD r1,r4,#SF_H_MAGIC
LA r2,#SF_MAGIC
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#SF_H_VERSION
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#SF_H_LEN
MOVI r2,200
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#SF_H_DATAOFF
MOVI r2,208
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#SF_H_DATAOFF+1
CMP r1,r0
JMP[NE] @fail
LD r1,r4,#SF_H_PARSED
MOVI r2,3
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#SF_H_TENS
LA r2,@sftens
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; record a: F32 [2,2], offsets 0..16, abs 208
MOVI r1,0x32
CALL @stage
LA r6,@sftens
LD r1,r6,#SF_T_MAGIC
LA r2,#SF_TMAGIC
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_DTYPE
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_RANK
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_SHAPE
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_SHAPE+1
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_BEGIN
CMP r1,r0
JMP[NE] @fail
LD r1,r6,#SF_T_END
MOVI r2,16
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_ABS
MOVI r2,208
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_SIZE
MOVI r2,16
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_COUNT
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_NAMELEN
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
; name "a"
LA r1,@sftens
LA r2,@nm_a
MOVI r3,1
CALL @name_eq
CMP r1,r0
JMP[EQ] @fail
; view type/count/offset
LA r6,@sftens
ADDI r4,r6,#SF_T_VIEW
LD r1,r4,#NKV_V_DTYPE
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_COUNT
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_OFF
MOVI r2,208
CMP r1,r2
JMP[NE] @fail
; element 0 = 1.0, element 3 = 4.0
LA r1,@sftens
ADDI r1,r1,#SF_T_VIEW
MOVI r2,0
MOVI r3,0
CALL @nkv_view_addr
CMP r3,r0
JMP[NE] @fail
SHR r1,r1,2
LD r1,r1,0
LA r2,0x3F800000
CMP r1,r2
JMP[NE] @fail
LA r1,@sftens
ADDI r1,r1,#SF_T_VIEW
MOVI r2,3
MOVI r3,0
CALL @nkv_view_addr
CMP r3,r0
JMP[NE] @fail
SHR r1,r1,2
LD r1,r1,0
LA r2,0x40800000
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; record b: F16 [4], offsets 16..24, abs 224, first half 0x3800
MOVI r1,0x33
CALL @stage
LA r6,@sftens
ADDI r6,r6,#SF_REC_WORDS
LD r1,r6,#SF_T_DTYPE
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_RANK
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_SHAPE
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_BEGIN
MOVI r2,16
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_END
MOVI r2,24
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_ABS
MOVI r2,224
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_SIZE
MOVI r2,8
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_COUNT
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LA r1,@sftens
ADDI r1,r1,#SF_REC_WORDS
LA r2,@nm_b
MOVI r3,1
CALL @name_eq
CMP r1,r0
JMP[EQ] @fail
; f16 bytes: 00 38 ...
LA r1,@sftens
ADDI r1,r1,#SF_REC_WORDS
ADDI r1,r1,#SF_T_VIEW
MOVI r2,0
MOVI r3,0
CALL @nkv_view_addr
CMP r3,r0
JMP[NE] @fail
ST r1,r0,@sccap          ; byte address reuse as scratch
LA r2,@sccap
LD r2,r2,0
LDB r1,r2,0
CMP r1,r0
JMP[NE] @fail
LDB r1,r2,1
MOVI r3,0x38
CMP r1,r3
JMP[NE] @fail
LA r6,@sftens
ADDI r6,r6,#SF_REC_WORDS
LD r1,r6,#SF_T_VIEW
LA r2,#NKV_VIEW_MAGIC
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; record c: U8 [3], offsets 24..27, abs 232, bytes AA BB CC
MOVI r1,0x34
CALL @stage
LA r6,@sftens
MOVI r2,2
MOVI r3,#SF_REC_WORDS
MUL r2,r2,r3
ADD r6,r6,r2
LD r1,r6,#SF_T_DTYPE
CMP r1,r0
JMP[NE] @fail
LD r1,r6,#SF_T_RANK
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_SHAPE
MOVI r2,3
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_ABS
MOVI r2,232
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_SIZE
MOVI r2,3
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#SF_T_COUNT
MOVI r2,3
CMP r1,r2
JMP[NE] @fail
LA r1,@sftens
MOVI r2,2
MOVI r3,#SF_REC_WORDS
MUL r2,r2,r3
ADD r1,r1,r2
ADDI r1,r1,#SF_T_VIEW
MOVI r2,0
MOVI r3,0
CALL @nkv_view_addr
CMP r3,r0
JMP[NE] @fail
ST r1,r0,@sccap
LA r2,@sccap
LD r2,r2,0
LDB r1,r2,0
MOVI r3,0xAA
CMP r1,r3
JMP[NE] @fail
LDB r1,r2,1
MOVI r3,0xBB
CMP r1,r3
JMP[NE] @fail
LDB r1,r2,2
MOVI r3,0xCC
CMP r1,r3
JMP[NE] @fail

; ---------------------------------------------------------------------------
; rejection cases over a writable copy
MOVI r1,0x35
CALL @stage
; bad JSON start
CALL @reset_work
MOVI r1,8
MOVI r2,0x58
CALL @mut_byte
CALL @work_cap
MOVI r2,8
CALL @expect_reject
CMP r1,r0
JMP[EQ] @fail
; unsupported dtype F32 -> F92
CALL @reset_work
MOVI r1,55
MOVI r2,0x39
CALL @mut_byte
CALL @work_cap
MOVI r2,8
CALL @expect_reject
CMP r1,r0
JMP[EQ] @fail
; zero dim [2,2] -> [0,2]
CALL @reset_work
MOVI r1,68
MOVI r2,0x30
CALL @mut_byte
CALL @work_cap
MOVI r2,8
CALL @expect_reject
CMP r1,r0
JMP[EQ] @fail
; non-numeric dim [2,2] -> [2,x]
CALL @reset_work
MOVI r1,70
MOVI r2,0x78
CALL @mut_byte
CALL @work_cap
MOVI r2,8
CALL @expect_reject
CMP r1,r0
JMP[EQ] @fail
; missing shape key (shape -> xhape)
CALL @reset_work
MOVI r1,60
MOVI r2,0x78
CALL @mut_byte
CALL @work_cap
MOVI r2,8
CALL @expect_reject
CMP r1,r0
JMP[EQ] @fail
; begin > end: b 16..24 -> 99..24
CALL @reset_work
MOVI r1,143
MOVI r2,0x39
CALL @mut_byte
MOVI r1,144
MOVI r2,0x39
CALL @mut_byte
CALL @work_cap
MOVI r2,8
CALL @expect_reject
CMP r1,r0
JMP[EQ] @fail
; size mismatch: a end 16 -> 17
CALL @reset_work
MOVI r1,92
MOVI r2,0x37
CALL @mut_byte
CALL @work_cap
MOVI r2,8
CALL @expect_reject
CMP r1,r0
JMP[EQ] @fail
; data past storage: b 16..24 -> 32..40, cap 240
CALL @reset_work
MOVI r1,143
MOVI r2,0x33
CALL @mut_byte
MOVI r1,144
MOVI r2,0x32
CALL @mut_byte
MOVI r1,146
MOVI r2,0x34
CALL @mut_byte
MOVI r1,147
MOVI r2,0x30
CALL @mut_byte
LA r1,@sfwork
MOVI r2,240
MOVI r3,0
CALL @mkcap
MOVI r2,8
CALL @expect_reject
CMP r1,r0
JMP[EQ] @fail
; too many tensors: canonical with max 2
CALL @reset_work
CALL @work_cap
MOVI r2,2
CALL @expect_reject
CMP r1,r0
JMP[EQ] @fail
; header length zero
CALL @reset_work
MOVI r1,0
MOVI r2,0
CALL @mut_byte
CALL @work_cap
MOVI r2,8
CALL @expect_reject
CMP r1,r0
JMP[EQ] @fail
; header length over 1 MiB
CALL @reset_work
MOVI r1,3
MOVI r2,0x10
CALL @mut_byte
CALL @work_cap
MOVI r2,8
CALL @expect_reject
CMP r1,r0
JMP[EQ] @fail

; truncated storage: 236 -> 207 bytes
MOVI r1,0x36
CALL @stage
CALL @reset_work
LA r1,@sfwork
MOVI r2,207
MOVI r3,0
CALL @mkcap
MOVI r2,8
CALL @expect_reject
CMP r1,r0
JMP[EQ] @fail

MOVI r1,79
PUTC r1
HALT

fail:
LA r2,@stagev
LD r1,r2,0
PUTC r1
MOVI r1,70
PUTC r1
HALT

stage:
LA r2,@stagev
ST r1,r2,0
RET

; ---------------------------------------------------------------------------
; mkcap r1=base words r2=size lo r3=size hi -> cap or 0
mkcap:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r2,r0,0x5AE0
  ST r3,r0,0x5AE1
  SHL r1,r1,2
  MOVI r2,0
  LD r3,r0,0x5AE0
  LD r4,r0,0x5AE1
  MOVI r5,1
  MOVI r6,0
  CALL @nkv_storage_create
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; parse_cap r1=cap r2=max -> 0/-1
parse_cap:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r3,@sfhdr
  LA r4,@sftens
  ADD r5,r2,r0
  ADD r2,r3,r0
  ADD r3,r4,r0
  ADD r4,r5,r0
  CALL @nsafetensors_parse
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; expect_reject r1=cap r2=max -> 1 if rejected, 0 if accepted
expect_reject:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @parse_cap
  ADD r2,r1,r0
  MOVI r1,1
  LA r3,0xFFFFFFFF
  CMP r2,r3
  JMP[EQ] @er_ok
  MOVI r1,0
er_ok:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; reset_work: copy the canonical image words to sfwork
reset_work:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r1,@sfend
  LA r2,@sfimg
  SUB r3,r1,r2
  LA r1,@sfwork
  LA r2,@sfimg
  ADD r3,r3,r0
  BCOPY r1,r2,r3
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; mut_byte r1=byte offset r2=value
mut_byte:
  LA r3,@sfwork
  SHL r3,r3,2
  ADD r3,r3,r1
  STB r2,r3,0
  RET

; work_cap -> r1=cap over sfwork at size 236
work_cap:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r1,@sfwork
  MOVI r2,236
  MOVI r3,0
  CALL @mkcap
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; name_eq r1=rec r2=literal word ptr r3=len -> 1/0
name_eq:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r2,r0,0x5AE4
  ST r3,r0,0x5AE5
  LD r4,r1,#SF_T_NAMELEN
  LD r5,r0,0x5AE5
  CMP r4,r5
  JMP[NE] @ne_no
  LD r4,r1,#SF_T_NAMEOFF
  LD r2,r0,0x5AE4
  SHL r2,r2,2
  MOVI r5,0
ne_l:
  LD r6,r0,0x5AE5
  CMP r5,r6
  JMP[GE] @ne_yes
  ADD r7,r4,r5
  LDB r7,r7,0
  ADD r8,r2,r5
  LDB r8,r8,0
  CMP r7,r8
  JMP[NE] @ne_no
  ADD r5,r5,r13
  JMP @ne_l
ne_yes:
  MOVI r1,1
  JMP @ne_out
ne_no:
  MOVI r1,0
ne_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
