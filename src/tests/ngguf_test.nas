; ngguf_test.nas - GGUF v3 import through a 2 TiB storage cap (F7).
;
; Proves:
;  - header magic/version/counts, metadata key/type/value skipping (u32, bool,
;    f32, u64, string, array-of-strings), alignment capture and data offset;
;  - four tensor infos: F32 rank 2, Q4_0, F16, Q8_0, with exact names,
;    relative/absolute 64-bit offsets, byte sizes and block counts;
;  - zero-copy nkv views: typed F32/F16 views, raw u8 views for Q4_0/Q8_0;
;  - the last Q8_0 tensor starts at 4 GiB-32 and ends above 4 GiB (a 2 TiB
;    storage cap); its raw view element 32 is exactly 4 GiB (hi=1);
;  - rejection: bad magic, bad version, too many tensors, too many KV pairs,
;    non-power-of-two alignment, unsupported dtype, misaligned tensor offset,
;    truncated storage, tensor table too small.
; A single serial 'O' means all checks passed.
.org 0
JMP @main
.org 0x4000
.include "../lib/ngguf.nas"

main:
MOVI r13,1
MOVI r14,0x7000
CALL @nobj_init

; storage cap over the synthetic image: base 0x6000 words = 0x18000 bytes,
; size 2 TiB (lo=0, hi=512), read-only.
MOVI r1,1
CALL @stage
LA r1,0x18000
MOVI r2,0
MOVI r3,0
MOVI r4,512
MOVI r5,1
MOVI r6,0
CALL @nkv_storage_create
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@scap
; truncated cap over the same base, 300 bytes: metadata end is 357
LA r1,0x18000
MOVI r2,0
LA r3,300
MOVI r4,0
MOVI r5,1
MOVI r6,0
CALL @nkv_storage_create
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@scap_small

; ---------------------------------------------------------------------------
; parse the valid image
MOVI r1,2
CALL @stage
CALL @parse4
CMP r1,r0
JMP[NE] @fail

; header fields are exact
LA r4,@ghdr
LD r1,r4,#NG_H_MAGIC
LA r2,#NG_MAGIC
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NG_H_VERSION
MOVI r2,3
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NG_H_NTENSOR
MOVI r2,5
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NG_H_NKV
MOVI r2,9
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NG_H_ALIGN
MOVI r2,32
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NG_H_METAEND
LA r2,357
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NG_H_INFOEND
LA r2,608
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NG_H_DATAOFF
LA r2,608
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NG_H_PARSED
MOVI r2,5
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NG_H_TENSORS
LA r2,@gtens
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; tensor 0: token_embd.weight, F32 [4,4], rel 0, abs 608, size 64
MOVI r1,3
CALL @stage
LA r6,@gtens
LD r1,r6,#NG_T_MAGIC
LA r2,#NG_ENTRY_MAGIC
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_DTYPE
CMP r1,r0
JMP[NE] @fail
LD r1,r6,#NG_T_NDIMS
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_DIMS
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_DIMS+2
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_NAMELEN
MOVI r2,17
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_NAMEOFF
LA r2,365
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_RELOFF
CMP r1,r0
JMP[NE] @fail
LD r1,r6,#NG_T_RELOFF+1
CMP r1,r0
JMP[NE] @fail
LD r1,r6,#NG_T_ABSOFF
LA r2,608
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_ABSOFF+1
CMP r1,r0
JMP[NE] @fail
LD r1,r6,#NG_T_SIZE
MOVI r2,64
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_SIZE+1
CMP r1,r0
JMP[NE] @fail
LD r1,r6,#NG_T_COUNT
MOVI r2,16
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_BLOCKS
CMP r1,r0
JMP[NE] @fail
; name bytes and typed view
ADDI r1,r6,#NG_T_NAMEOFF
LD r1,r1,0
MOVI r3,17
LA r2,@nm0
CALL @cmpname
CMP r1,r0
JMP[EQ] @fail
MOVI r1,0x61
CALL @stage
ADDI r4,r6,#NG_T_VIEW
LD r1,r4,#NKV_V_MAGIC
LA r2,#NKV_VIEW_MAGIC
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_DTYPE
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_RANK
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_OFF
LA r2,608
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_OFF+1
CMP r1,r0
JMP[NE] @fail
LD r1,r4,#NKV_V_SIZE
MOVI r2,64
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_COUNT
MOVI r2,16
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_SHAPE
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_SHAPE+1
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
MOVI r1,0x62
CALL @stage
LD r1,r4,#NKV_V_STRIDE
MOVI r2,16
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_STRIDE+2
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_STOR
LD r2,r0,@scap
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; tensor 1: output.weight, Q4_0 [4,32], rel 64, abs 672, 4 blocks, 72 bytes
MOVI r1,4
CALL @stage
LA r6,@gtens
ADDI r6,r6,64
LD r1,r6,#NG_T_DTYPE
MOVI r2,#NG_DT_Q4_0
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_DIMS
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_DIMS+2
MOVI r2,32
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_RELOFF
MOVI r2,64
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_ABSOFF
LA r2,672
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_SIZE
MOVI r2,72
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_COUNT
MOVI r2,128
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_BLOCKS
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
ADDI r1,r6,#NG_T_NAMEOFF
LD r1,r1,0
MOVI r3,13
LA r2,@nm1
CALL @cmpname
CMP r1,r0
JMP[EQ] @fail
ADDI r4,r6,#NG_T_VIEW
LD r1,r4,#NKV_V_DTYPE
CMP r1,r0
JMP[NE] @fail
LD r1,r4,#NKV_V_RANK
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_SIZE
MOVI r2,72
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_COUNT
MOVI r2,72
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_SHAPE
MOVI r2,72
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; tensor 2: f16.weight, F16 [8], rel 128, abs 736, 16 bytes
MOVI r1,5
CALL @stage
LA r6,@gtens
ADDI r6,r6,128
LD r1,r6,#NG_T_DTYPE
MOVI r2,#NG_DT_F16
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_NDIMS
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_DIMS
MOVI r2,8
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_RELOFF
MOVI r2,128
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_ABSOFF
LA r2,736
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_SIZE
MOVI r2,16
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_COUNT
MOVI r2,8
CMP r1,r2
JMP[NE] @fail
ADDI r1,r6,#NG_T_NAMEOFF
LD r1,r1,0
MOVI r3,9
LA r2,@nm2
CALL @cmpname
CMP r1,r0
JMP[EQ] @fail
ADDI r4,r6,#NG_T_VIEW
LD r1,r4,#NKV_V_DTYPE
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_COUNT
MOVI r2,8
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_SIZE
MOVI r2,16
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; tensor 3: q8.weight, Q8_0 [32,2], rel 0xFFFE7D80, abs 0xFFFE7FE0
; storage base 0x18000 -> view byte 0 is 0xFFFFFFE0; element 32 is 4 GiB.
MOVI r1,6
CALL @stage
LA r6,@gtens
ADDI r6,r6,192
LD r1,r6,#NG_T_DTYPE
MOVI r2,#NG_DT_Q8_0
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_NDIMS
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_DIMS
MOVI r2,32
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_DIMS+2
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_RELOFF
LA r2,0xFFFE7D80
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_RELOFF+1
CMP r1,r0
JMP[NE] @fail
LD r1,r6,#NG_T_ABSOFF
LA r2,0xFFFE7FE0
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_ABSOFF+1
CMP r1,r0
JMP[NE] @fail
LD r1,r6,#NG_T_SIZE
MOVI r2,68
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_BLOCKS
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_COUNT
MOVI r2,64
CMP r1,r2
JMP[NE] @fail
ADDI r1,r6,#NG_T_NAMEOFF
LD r1,r1,0
MOVI r3,9
LA r2,@nm3
CALL @cmpname
CMP r1,r0
JMP[EQ] @fail
ADDI r4,r6,#NG_T_VIEW
LD r1,r4,#NKV_V_DTYPE
CMP r1,r0
JMP[NE] @fail
LD r1,r4,#NKV_V_COUNT
MOVI r2,68
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NKV_V_SIZE
MOVI r2,68
CMP r1,r2
JMP[NE] @fail
; element 31 is the last byte below 4 GiB
LA r6,@gtens
ADDI r6,r6,192
ADDI r1,r6,#NG_T_VIEW
MOVI r2,31
MOVI r3,0
CALL @nkv_view_addr
CMP r3,r0
JMP[NE] @fail
MOVI r3,0
CMP r2,r3
JMP[NE] @fail
LA r3,0xFFFFFFFF
CMP r1,r3
JMP[NE] @fail
; element 32 is exactly 4 GiB: lo=0, hi=1
LA r6,@gtens
ADDI r6,r6,192
ADDI r1,r6,#NG_T_VIEW
MOVI r2,32
MOVI r3,0
CALL @nkv_view_addr
CMP r3,r0
JMP[NE] @fail
CMP r1,r0
JMP[NE] @fail
MOVI r3,1
CMP r2,r3
JMP[NE] @fail
; element 68 is out of the 68-byte view
LA r6,@gtens
ADDI r6,r6,192
ADDI r1,r6,#NG_T_VIEW
MOVI r2,68
MOVI r3,0
CALL @nkv_view_addr
LA r2,0xFFFFFFFF
CMP r3,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; tensor 4: big.weight, Q8_0 [32,2], rel 0xFFFFFD80, abs 0xFFFFFFE0
; abs+size = 0x100000024: the 64-bit tensor range crosses 4 GiB.
MOVI r1,8
CALL @stage
LA r6,@gtens
ADDI r6,r6,256
LD r1,r6,#NG_T_DTYPE
MOVI r2,#NG_DT_Q8_0
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_RELOFF
LA r2,0xFFFFFD80
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_ABSOFF
LA r2,0xFFFFFFE0
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_ABSOFF+1
CMP r1,r0
JMP[NE] @fail
LD r1,r6,#NG_T_SIZE
MOVI r2,68
CMP r1,r2
JMP[NE] @fail
ADDI r1,r6,#NG_T_NAMEOFF
LD r1,r1,0
MOVI r3,10
LA r2,@nm4
CALL @cmpname
CMP r1,r0
JMP[EQ] @fail
; abs + size = (0x24, 1)
LD r1,r6,#NG_T_ABSOFF
LD r2,r6,#NG_T_ABSOFF+1
LD r3,r6,#NG_T_SIZE
LD r4,r6,#NG_T_SIZE+1
CALL @n64_add
MOVI r3,0x24
CMP r1,r3
JMP[NE] @fail
MOVI r3,1
CMP r2,r3
JMP[NE] @fail
; view element 0 is at absolute 0x100017FE0 (hi=1)
LA r6,@gtens
ADDI r6,r6,256
ADDI r1,r6,#NG_T_VIEW
MOVI r2,0
MOVI r3,0
CALL @nkv_view_addr
CMP r3,r0
JMP[NE] @fail
MOVI r3,1
CMP r2,r3
JMP[NE] @fail
LA r3,0x00017FE0
CMP r1,r3
JMP[NE] @fail

; ---------------------------------------------------------------------------
; rejection cases: each mutation is restored before the next one
MOVI r1,7
CALL @stage

; bad magic
MOVI r1,0
MOVI r2,0x48
CALL @poke
CALL @parse4
CMP r1,r0
JMP[EQ] @fail
MOVI r1,0
MOVI r2,0x47
CALL @poke

; bad version 4
MOVI r1,4
MOVI r2,4
CALL @poke
CALL @parse4
CMP r1,r0
JMP[EQ] @fail
MOVI r1,4
MOVI r2,3
CALL @poke

; tensor_count 6 > max 5
MOVI r1,8
MOVI r2,6
CALL @poke
CALL @parse4
CMP r1,r0
JMP[EQ] @fail
MOVI r1,8
MOVI r2,5
CALL @poke

; kv_count 0x2009 > 4096
MOVI r1,17
MOVI r2,0x20
CALL @poke
CALL @parse4
CMP r1,r0
JMP[EQ] @fail
MOVI r1,17
MOVI r2,0
CALL @poke

; general.alignment = 3 (not a power of two), value at byte 96
MOVI r1,96
MOVI r2,3
CALL @poke
CALL @parse4
CMP r1,r0
JMP[EQ] @fail
MOVI r1,96
MOVI r2,32
CALL @poke

; output.weight dtype = 7 (unsupported), type field at byte 455
MOVI r1,455
MOVI r2,7
CALL @poke
CALL @parse4
CMP r1,r0
JMP[EQ] @fail
MOVI r1,455
MOVI r2,2
CALL @poke

; output.weight rel offset = 65 (misaligned), rel at byte 459
MOVI r1,459
MOVI r2,65
CALL @poke
CALL @parse4
CMP r1,r0
JMP[EQ] @fail
MOVI r1,459
MOVI r2,64
CALL @poke

; tensor table capacity 3 is too small
LA r1,@scap
LD r1,r1,0
LA r2,@ghdr
LA r3,@gtens
MOVI r4,3
CALL @ngguf_parse
CMP r1,r0
JMP[EQ] @fail

; 300-byte storage cap truncates the metadata (meta end 357)
LA r1,@scap_small
LD r1,r1,0
LA r2,@ghdr
LA r3,@gtens
MOVI r4,4
CALL @ngguf_parse
CMP r1,r0
JMP[EQ] @fail

; restore the valid parse and confirm it still works after mutations
CALL @parse4
CMP r1,r0
JMP[NE] @fail

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

; r1=stage char -> @stage
stage:
LA r2,@stagev
ST r1,r2,0
RET

; parse with max 5 -> r1=0/-1
parse4:
ST r15,r14,0
ADD r14,r14,r13
LA r1,@scap
LD r1,r1,0
LA r2,@ghdr
LA r3,@gtens
MOVI r4,5
CALL @ngguf_parse
SUB r14,r14,r13
LD r15,r14,0
RET

; poke byte at image-relative offset r1 with value r2
poke:
LA r3,0x18000
ADD r3,r3,r1
STB r2,r3,0
RET

; compare r3 bytes at storage offset r1 to expected word address r2 -> r1=1/0
cmpname:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#NGX_TMP+40
SHL r2,r2,2
ST r2,r0,#NGX_TMP+41
ST r3,r0,#NGX_TMP+42
ST r0,r0,#NGX_TMP+43
cmp_l:
LD r1,r0,#NGX_TMP+43
LD r2,r0,#NGX_TMP+42
CMP r1,r2
JMP[GE] @cmp_yes
LD r1,r0,#NGX_TMP+40
LA r3,0x18000
ADD r3,r3,r1
LDB r4,r3,0
LD r3,r0,#NGX_TMP+41
LDB r5,r3,0
CMP r4,r5
JMP[NE] @cmp_no
LD r1,r0,#NGX_TMP+40
ADDI r1,r1,1
ST r1,r0,#NGX_TMP+40
LD r1,r0,#NGX_TMP+41
ADDI r1,r1,1
ST r1,r0,#NGX_TMP+41
LD r1,r0,#NGX_TMP+43
ADD r1,r1,r13
ST r1,r0,#NGX_TMP+43
JMP @cmp_l
cmp_yes:
MOVI r1,1
JMP @cmp_out
cmp_no:
MOVI r1,0
cmp_out:
SUB r14,r14,r13
LD r15,r14,0
RET

; ---------------------------------------------------------------------------
; synthetic GGUF v3 image: 4 tensors, 9 metadata keys, data_off 608
.org 0x6000
img:
.word 0x46554747, 0x00000003, 0x00000005, 0x00000000, 0x00000009, 0x00000000, 0x00000014, 0x00000000
.word 0x656E6567, 0x2E6C6172, 0x68637261, 0x63657469, 0x65727574, 0x00000008, 0x00000003, 0x00000000
.word 0x116E616E, 0x00000000, 0x67000000, 0x72656E65, 0x612E6C61, 0x6E67696C, 0x746E656D, 0x00000004
.word 0x00000020, 0x00000015, 0x00000000, 0x646F6D6E, 0x632E6C65, 0x65746E6F, 0x6C5F7478, 0x74676E65
.word 0x00000468, 0x00008000, 0x00001700, 0x00000000, 0x6F6D6E00, 0x2E6C6564, 0x65626D65, 0x6E696464
.word 0x656C5F67, 0x6874676E, 0x00000004, 0x00000004, 0x00000012, 0x00000000, 0x646F6D6E, 0x622E6C65
.word 0x6B636F6C, 0x756F635F, 0x0004746E, 0x00010000, 0x000B0000, 0x00000000, 0x6D6E0000, 0x6C65646F
.word 0x616C662E, 0x00000767, 0x000B0100, 0x00000000, 0x6D6E0000, 0x6C65646F, 0x6761742E, 0x00000973
.word 0x00000800, 0x00000300, 0x00000000, 0x00000100, 0x00000000, 0x00026100, 0x00000000, 0x62620000
.word 0x00000003, 0x00000000, 0x0A636363, 0x00000000, 0x6E000000, 0x65646F6D, 0x69622E6C, 0x00000A67
.word 0x66778800, 0x22334455, 0x00000C11, 0x00000000, 0x6F6D6E00, 0x2E6C6564, 0x69746172, 0x0000066F
.word 0x00000000, 0x0000113F, 0x00000000, 0x6B6F7400, 0x655F6E65, 0x2E64626D, 0x67696577, 0x00027468
.word 0x00040000, 0x00000000, 0x00040000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x000D0000
.word 0x00000000, 0x756F0000, 0x74757074, 0x6965772E, 0x02746867, 0x04000000, 0x00000000, 0x20000000
.word 0x00000000, 0x02000000, 0x40000000, 0x00000000, 0x0A000000, 0x00000000, 0x66000000, 0x772E3631
.word 0x68676965, 0x00000174, 0x00000800, 0x00000000, 0x00000100, 0x00008000, 0x00000000, 0x00000900
.word 0x00000000, 0x2E387100, 0x67696577, 0x00027468, 0x00200000, 0x00000000, 0x00020000, 0x00000000
.word 0x00080000, 0x7D800000, 0x0000FFFE, 0x000A0000, 0x00000000, 0x69620000, 0x65772E67, 0x74686769
.word 0x00000002, 0x00000020, 0x00000000, 0x00000002, 0x00000000, 0x00000008, 0xFFFFFD80, 0x00000000

; ---------------------------------------------------------------------------
.org 0x6200
scap:
.word 0
scap_small:
.word 0
stagev:
.word 0
ghdr:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
gtens:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
nm0:
.str "token_embd.weight"
nm1:
.str "output.weight"
nm2:
.str "f16.weight"
nm3:
.str "q8.weight"
nm4:
.str "big.weight"
