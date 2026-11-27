; ngguf_scale_test.nas - direct GGUF Q4_0/Q8_0 f16-scale consumption (F7b).
;
; Builds a minimal real GGUF v3 image at runtime address @gimg:
;   magic/version, 2 tensors, no metadata, alignment 32, data at 96.
;   tensor 0 "q8wt": Q8_0 [32], rel 0  -> abs 96, 34 bytes, f16 scale 0.5
;     payload q[0]=2, q[31]=-3.
;   tensor 1 "q4wt": Q4_0 [32], rel 64 -> abs 160, 18 bytes, f16 scale 0.5
;     payload q[0]=+1, q[16]=+1.
; Proves:
;  - ngguf_parse accepts the image and records exact dtype/blocks/abs offsets;
;  - nq_f16_to_f32 is exact for normals, subnormal, +-0, Inf and NaN;
;  - ngguf_blocks_to_nq4 converts both tensors to nq4 f32-scale blocks and the
;    payload bytes are unchanged;
;  - nq8_gemv over the converted Q8 block = -2.0 exactly (0xC0000000);
;  - nq4_gemv over the converted Q4 block = 2.0 exactly (0x40000000);
;  - a tensor view whose 34-byte block starts at 4 GiB-16 is rejected with -2
;    through nkv's 64-bit view address, as is a view whose base is >=4 GiB;
;  - bad magic/dtype/blocks/capacity return -1.
; Success prints exactly O.
.org 0
JMP @main
; ---------------------------------------------------------------------------
; GGUF image bytes (little endian words), 2 TiB storage cap base @gimg*4.
.org 0x9000
gimg:
.word 0x46554747, 0x00000003, 0x00000002, 0x00000000, 0x00000000, 0x00000000
.word 0x00000004, 0x00000000, 0x74773871, 0x00000001
.word 0x00000020, 0x00000000, 0x00000008, 0x00000000, 0x00000000
.word 0x00000004, 0x00000000, 0x74773471, 0x00000001
.word 0x00000020, 0x00000000, 0x00000002, 0x00000040, 0x00000000
.word 0x00023800, 0,0,0,0,0,0,0, 0x0000FD00, 0,0,0,0,0,0,0
.word 0x88993800, 0x88888888, 0x88888888, 0x88888888, 0x00008888
ghdr:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
gtens:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
q8conv:
.word 0,0,0,0,0,0,0,0,0
q4conv:
.word 0,0,0,0,0
acts:
.word 0x3F800000,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0x40400000,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0x40000000
gemvout:
.word 0
rrec:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
rshape:
.word 34
scap:
.word 0
caphi:
.word 0
stagev:
.word 0

; ---------------------------------------------------------------------------
.org 0x10000
.include "../lib/nq4.nas"
.include "../lib/ngguf.nas"

main:
MOVI r13,1
MOVI r14,0x7000
CALL @nobj_init

; ---------------------------------------------------------------------------
; f16 conversion: exact normals, subnormals, signed zero, Inf, NaN
MOVI r1,0x31
CALL @stage
MOVI r1,0x3C00
CALL @nq_f16_to_f32
LA r2,0x3F800000
CMP r1,r2
JMP[NE] @fail
MOVI r1,0x3800
CALL @nq_f16_to_f32
LA r2,0x3F000000
CMP r1,r2
JMP[NE] @fail
MOVI r1,0xBC00
CALL @nq_f16_to_f32
LA r2,0xBF800000
CMP r1,r2
JMP[NE] @fail
MOVI r1,0x0001
CALL @nq_f16_to_f32
LA r2,0x33800000
CMP r1,r2
JMP[NE] @fail
MOVI r1,0x03FF
CALL @nq_f16_to_f32
LA r2,0x387FC000
CMP r1,r2
JMP[NE] @fail
MOVI r1,0x0000
CALL @nq_f16_to_f32
CMP r1,r0
JMP[NE] @fail
MOVI r1,0x8000
CALL @nq_f16_to_f32
LA r2,0x80000000
CMP r1,r2
JMP[NE] @fail
MOVI r1,0x7C00
CALL @nq_f16_to_f32
LA r2,0x7F800000
CMP r1,r2
JMP[NE] @fail
MOVI r1,0xFC00
CALL @nq_f16_to_f32
LA r2,0xFF800000
CMP r1,r2
JMP[NE] @fail
MOVI r1,0x7E00
CALL @nq_f16_to_f32
LA r2,0x7FC00000
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; 2 TiB storage cap over the image, parse
MOVI r1,0x32
CALL @stage
LA r1,@gimg
SHL r1,r1,2
MOVI r2,0
MOVI r3,0
MOVI r4,512
MOVI r5,1
MOVI r6,0
CALL @nkv_storage_create
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@scap
LA r1,@scap
LD r1,r1,0
LA r2,@ghdr
LA r3,@gtens
MOVI r4,2
CALL @ngguf_parse
CMP r1,r0
JMP[NE] @fail
LA r4,@ghdr
LD r1,r4,#NG_H_PARSED
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r4,#NG_H_DATAOFF
MOVI r2,96
CMP r1,r2
JMP[NE] @fail
; tensor 0: q8wt dtype 8, 1 block, abs 96, size 34
LA r6,@gtens
LD r1,r6,#NG_T_DTYPE
MOVI r2,8
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_BLOCKS
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_ABSOFF
MOVI r2,96
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_SIZE
MOVI r2,34
CMP r1,r2
JMP[NE] @fail
; tensor 1: q4wt dtype 2, 1 block, abs 160, size 18
ADDI r6,r6,#NG_TENSOR_WORDS
LD r1,r6,#NG_T_DTYPE
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_BLOCKS
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_ABSOFF
MOVI r2,160
CMP r1,r2
JMP[NE] @fail
LD r1,r6,#NG_T_SIZE
MOVI r2,18
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; convert Q8 and run nq8_gemv over the converted block
MOVI r1,0x33
CALL @stage
LA r1,@gtens
LA r2,@q8conv
MOVI r3,4
CALL @ngguf_blocks_to_nq4
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LA r6,@q8conv
LD r1,r6,0
LA r2,0x3F000000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
LA r2,0x00000002
CMP r1,r2
JMP[NE] @fail
LD r1,r6,8
LA r2,0xFD000000
CMP r1,r2
JMP[NE] @fail
LA r1,@q8conv
MOVI r2,1
LA r3,@acts
LA r4,@gemvout
CALL @nq8_gemv
CMP r1,r0
JMP[NE] @fail
LA r6,@gemvout
LD r1,r6,0
LA r2,0xC0000000
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; convert Q4 and run nq4_gemv
MOVI r1,0x34
CALL @stage
LA r1,@gtens
ADDI r1,r1,#NG_TENSOR_WORDS
LA r2,@q4conv
MOVI r3,4
CALL @ngguf_blocks_to_nq4
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LA r6,@q4conv
LD r1,r6,0
LA r2,0x3F000000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
LA r2,0x88888899
CMP r1,r2
JMP[NE] @fail
LA r1,@q4conv
MOVI r2,1
LA r3,@acts
LA r4,@gemvout
CALL @nq4_gemv
CMP r1,r0
JMP[NE] @fail
LA r6,@gemvout
LD r1,r6,0
LA r2,0x40000000
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; 4 GiB boundary through nkv: a 34-byte Q8 block at 0xFFFFFFF0
MOVI r1,0x35
CALL @stage
LA r1,0xFFFFFF00
MOVI r2,0
MOVI r3,0
MOVI r4,512
MOVI r5,1
MOVI r6,0
CALL @nkv_storage_create
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@caphi
LA r1,@rrec
LA r2,#NG_ENTRY_MAGIC
ST r2,r1,0
MOVI r2,8
ST r2,r1,1
MOVI r2,1
ST r2,r1,30
ST r0,r1,31
; view at rec+32 over the last 16 bytes below 4 GiB
LA r1,@caphi
LD r1,r1,0
MOVI r2,0xF0
MOVI r3,0
MOVI r4,34
MOVI r5,0
MOVI r6,0
MOVI r7,1
LA r8,@rshape
LA r9,@rrec
ADDI r9,r9,32
CALL @nkv_view_create
CMP r1,r0
JMP[NE] @fail
LA r1,@rrec
LA r2,@q8conv
MOVI r3,4
CALL @ngguf_blocks_to_nq4
LA r2,0xFFFFFFFE
CMP r1,r2
JMP[NE] @fail

; view whose base is exactly 4 GiB -> also -2
MOVI r1,0x36
CALL @stage
MOVI r1,0
MOVI r2,1
MOVI r3,0
MOVI r4,512
MOVI r5,1
MOVI r6,0
CALL @nkv_storage_create
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@caphi
LA r1,@caphi
LD r1,r1,0
MOVI r2,0
MOVI r3,0
MOVI r4,34
MOVI r5,0
MOVI r6,0
MOVI r7,1
LA r8,@rshape
LA r9,@rrec
ADDI r9,r9,32
CALL @nkv_view_create
CMP r1,r0
JMP[NE] @fail
LA r1,@rrec
LA r2,@q8conv
MOVI r3,4
CALL @ngguf_blocks_to_nq4
LA r2,0xFFFFFFFE
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; rejection cases
MOVI r1,0x37
CALL @stage
; bad record magic
LA r1,@rrec
MOVI r2,0
ST r2,r1,0
LA r2,@q8conv
MOVI r3,4
CALL @ngguf_blocks_to_nq4
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail
; unsupported dtype
LA r1,@rrec
LA r2,#NG_ENTRY_MAGIC
ST r2,r1,0
MOVI r2,3
ST r2,r1,1
LA r2,@q8conv
MOVI r3,4
CALL @ngguf_blocks_to_nq4
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail
; blocks over destination capacity
MOVI r2,8
ST r2,r1,1
MOVI r2,2
ST r2,r1,30
LA r2,@q8conv
MOVI r3,1
CALL @ngguf_blocks_to_nq4
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail
; zero destination capacity
MOVI r2,1
ST r2,r1,30
LA r2,@q8conv
MOVI r3,0
CALL @ngguf_blocks_to_nq4
LA r2,0xFFFFFFFF
CMP r1,r2
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

stage:
LA r2,@stagev
ST r1,r2,0
RET
