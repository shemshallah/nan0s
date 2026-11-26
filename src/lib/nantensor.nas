; nantensor.nas - NANIX typed tensors and capability namespace (M1b).
;
; Tensors are metadata objects over a storage BLOB capability.  A view copies
; metadata only; the storage capability and element range are shared.  The
; namespace maps a short name hash to a capability so AI tools/models can be
; looked up without a POSIX path.
;
; Include this file (it includes nanobj.nas).
;
; ABI:
;   ntensor_create r1=dtype r2=rank r3=shape word ptr r4=storage cap
;                  -> tensor cap or 0
;   ntensor_shape  r1=tensor cap r2=out ptr(24 words) -> 0/-1
;   ntensor_view   r1=tensor cap r2=element offset r3=new shape r4=new rank
;                  -> view cap or 0
;   ntensor_storage r1=tensor cap -> storage cap or 0
;   nns_create     -> namespace cap or 0
;   nns_set        r1=ns cap r2=name byte ptr r3=target cap -> 0/-1
;   nns_get        r1=ns cap r2=name byte ptr -> cap or 0
;
; Tensor payload layout (24 words):
;   0 dtype, 1 rank, 2 flags, 3 storage cap, 4 element offset,
;   5..12 shape[8], 13..20 strides[8], 21 element count, 22..23 reserved.
; Namespace payload layout: 12 entries of {name hash, cap}; cap 0 is empty.

.include "nanobj.nas"

; LD/ST have a 16-bit immediate.  Tensor/namespace cross-call words live in
; the reserved low block 0x3B0..0x3BB; high buffers use LA base registers.
.equ NT_CLASS_BLOB   2
.equ NT_CLASS_TENSOR 10
.equ NT_CLASS_NS     11
.equ NT_FLAG_CONTIG  1
.equ NT_FLAG_VIEW    2
.equ NT_HDR          0x360000
.equ NT_OLD          0x360020
.equ NT_NSBUF        0x360080
.equ NT_NSENT        0x3600E0
.equ NT_G_DTYPE    0x3B0
.equ NT_G_RANK    0x3B1
.equ NT_G_SHAPE    0x3B2
.equ NT_G_STOR    0x3B3
.equ NT_G_CAP    0x3B4
.equ NT_G_OFF    0x3B5
.equ NT_G_TMP    0x3B6
.equ NT_G_TMP2    0x3B7
.equ NT_G_NS    0x3B8
.equ NT_G_NAME    0x3B9
.equ NT_G_TARGET    0x3BA
.equ NT_G_HASH    0x3BB

; nt_fill: build NT_HDR.  r1=dtype r2=rank r3=shape r4=storage r5=offset r6=flags
nt_fill:
  LA r7,#NT_HDR
  ST r1,r7,0
  ST r2,r7,1
  ST r6,r7,2
  ST r4,r7,3
  ST r5,r7,4
  ; zero shape, strides, count, reserved
  MOVI r8,19
  ADDI r9,r7,5
nt_fill_z:
  CMP r8,r0
  JMP[EQ] @nt_fill_shape
  ST r0,r9,0
  ADD r9,r9,r13
  SUB r8,r8,r13
  JMP @nt_fill_z
nt_fill_shape:
  ; copy rank shape words
  MOVI r8,0
  ADDI r9,r7,5
nt_fill_cp:
  CMP r8,r2
  JMP[GE] @nt_fill_strides
  LD r10,r3,0
  ST r10,r9,0
  ADD r3,r3,r13
  ADD r9,r9,r13
  ADD r8,r8,r13
  JMP @nt_fill_cp
nt_fill_strides:
  CMP r2,r0
  JMP[EQ] @nt_fill_one
  ; stride[i] = accum; accum *= shape[i]; i = rank-1..0
  MOVI r8,1                    ; accum
  SUB r9,r2,r13                ; i
  ADDI r10,r7,5                ; shape base
  ADDI r11,r7,13               ; stride base
nt_fill_sl:
  ADD r12,r10,r9
  LD r12,r12,0                 ; shape[i]
  ADD r4,r11,r9
  ST r8,r4,0                   ; stride[i] = accum
  MUL r8,r8,r12                ; accum *= shape[i]
  CMP r9,r0
  JMP[EQ] @nt_fill_count
  SUB r9,r9,r13
  JMP @nt_fill_sl
nt_fill_count:
  ST r8,r7,21                  ; element count
  RET
nt_fill_one:
  MOVI r8,1
  ST r8,r7,21
  RET

; ntensor_create: r1=dtype r2=rank r3=shape r4=storage cap -> cap or 0
ntensor_create:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_G_DTYPE
  ST r2,r0,#NT_G_RANK
  ST r3,r0,#NT_G_SHAPE
  ST r4,r0,#NT_G_STOR
  MOVI r5,8
  CMP r2,r5
  JMP[GT] @nt_cr_n
  ; storage must be a readable object
  ADD r1,r4,r0
  MOVI r2,#NOBJ_R_READ
  CALL @nobj_check
  CMP r1,r0
  JMP[EQ] @nt_cr_n
  LD r1,r0,#NT_G_DTYPE
  LD r2,r0,#NT_G_RANK
  LD r3,r0,#NT_G_SHAPE
  LD r4,r0,#NT_G_STOR
  MOVI r5,0
  MOVI r6,#NT_FLAG_CONTIG
  CALL @nt_fill
  MOVI r1,#NT_CLASS_TENSOR
  MOVI r2,24
  CALL @nobj_create
  CMP r1,r0
  JMP[EQ] @nt_cr_n
  ST r1,r0,#NT_G_CAP
  ADD r1,r1,r0
  LA r2,#NT_HDR
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_write
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @nt_cr_bad
  LD r1,r0,#NT_G_CAP
  JMP @nt_cr_d
nt_cr_bad:
  LD r1,r0,#NT_G_CAP
  CALL @nobj_release
nt_cr_n:
  MOVI r1,0
nt_cr_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ntensor_shape: r1=tensor r2=out(24 words) -> 0/-1
ntensor_shape:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_read
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @nt_sh_n
  MOVI r1,0
  JMP @nt_sh_d
nt_sh_n:
  LA r1,0xFFFFFFFF
nt_sh_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ntensor_storage: r1=tensor -> storage cap or 0
ntensor_storage:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r3,3
  MOVI r4,1
  LA r2,#NT_OLD
  CALL @nobj_read
  MOVI r5,1
  CMP r1,r5
  JMP[NE] @nt_st_n
  LA r2,#NT_OLD
  LD r1,r2,0
  JMP @nt_st_d
nt_st_n:
  MOVI r1,0
nt_st_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ntensor_view: r1=tensor r2=element offset r3=shape r4=rank -> cap or 0
ntensor_view:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_G_CAP
  ST r2,r0,#NT_G_OFF
  ST r3,r0,#NT_G_SHAPE
  ST r4,r0,#NT_G_RANK
  MOVI r5,8
  CMP r4,r5
  JMP[GT] @nt_vw_n
  ; read old header
  LD r1,r0,#NT_G_CAP
  LA r2,#NT_OLD
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_read
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @nt_vw_n
  LA r6,#NT_OLD
  LD r7,r6,21                  ; old count
  ST r7,r0,#NT_G_TMP2
  ; new offset = old offset + requested
  LD r7,r6,4
  LD r8,r0,#NT_G_OFF
  ADD r7,r7,r8
  ST r7,r0,#NT_G_OFF
  ; fill new header
  LD r1,r6,0                   ; dtype
  LD r2,r0,#NT_G_RANK
  LD r3,r0,#NT_G_SHAPE
  LD r4,r6,3                   ; storage cap
  LD r5,r0,#NT_G_OFF
  LD r6,r6,2                   ; old flags
  MOVI r7,#NT_FLAG_VIEW
  BOOL.14 r6,r6,r7
  CALL @nt_fill
  ; bounds: new count + offset <= old count
  LA r6,#NT_HDR
  LD r7,r6,21
  LD r8,r0,#NT_G_OFF
  ADD r7,r7,r8
  LD r9,r0,#NT_G_TMP2
  CMP r7,r9
  JMP[GT] @nt_vw_n
  ; create view object
  MOVI r1,#NT_CLASS_TENSOR
  MOVI r2,24
  CALL @nobj_create
  CMP r1,r0
  JMP[EQ] @nt_vw_n
  ST r1,r0,#NT_G_TARGET
  ADD r1,r1,r0
  LA r2,#NT_HDR
  MOVI r3,0
  MOVI r4,24
  CALL @nobj_write
  MOVI r5,24
  CMP r1,r5
  JMP[NE] @nt_vw_bad
  LD r1,r0,#NT_G_TARGET
  JMP @nt_vw_d
nt_vw_bad:
  LD r1,r0,#NT_G_TARGET
  CALL @nobj_release
nt_vw_n:
  MOVI r1,0
nt_vw_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nns_hash: r1=name byte ptr -> r1=32-bit FNV-1a hash (never 0)
nns_hash:
  ADD r2,r1,r0
  MOVI r1,0x9DC5
  MOVI r5,0x811C
  SHL r5,r5,16
  ADD r1,r1,r5
  MOVI r3,0x0193
  MOVI r4,0x0100
  SHL r4,r4,16
  ADD r3,r3,r4
nns_h_l:
  LDB r4,r2,0
  CMP r4,r0
  JMP[EQ] @nns_h_d
  BOOL.6 r1,r1,r4
  MUL r1,r1,r3
  ADD r2,r2,r13
  JMP @nns_h_l
nns_h_d:
  CMP r1,r0
  JMP[NE] @nns_h_r
  MOVI r1,1
nns_h_r:
  RET

; nns_create -> namespace cap or 0
nns_create:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r1,#NT_CLASS_NS
  MOVI r2,24
  CALL @nobj_create
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nns_set: r1=ns r2=name r3=target -> 0/-1
nns_set:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_G_NS
  ST r2,r0,#NT_G_NAME
  ST r3,r0,#NT_G_TARGET
  ; namespace needs write
  ADD r1,r1,r0
  MOVI r2,#NOBJ_R_WRITE
  CALL @nobj_check
  CMP r1,r0
  JMP[EQ] @nns_s_n
  ; target must be a live capability
  LD r1,r0,#NT_G_TARGET
  MOVI r2,0
  CALL @nobj_check
  CMP r1,r0
  JMP[EQ] @nns_s_n
  LD r2,r0,#NT_G_NAME
  ADD r1,r2,r0
  CALL @nns_hash
  ST r1,r0,#NT_G_HASH
  MOVI r2,0
  ST r2,r0,#NT_G_TMP
nns_s_l:
  LD r2,r0,#NT_G_TMP
  MOVI r3,12
  CMP r2,r3
  JMP[GE] @nns_s_n
  ; read entry {hash,cap}
  LD r1,r0,#NT_G_NS
  LA r2,#NT_NSENT
  LD r3,r0,#NT_G_TMP
  SHL r3,r3,1
  MOVI r4,2
  CALL @nobj_read
  MOVI r5,2
  CMP r1,r5
  JMP[NE] @nns_s_n
  LA r3,#NT_NSENT
  LD r4,r3,0
  LD r5,r0,#NT_G_HASH
  CMP r4,r5
  JMP[EQ] @nns_s_put
  LD r4,r3,1
  CMP r4,r0
  JMP[EQ] @nns_s_put
  LD r2,r0,#NT_G_TMP
  ADD r2,r2,r13
  ST r2,r0,#NT_G_TMP
  JMP @nns_s_l
nns_s_put:
  LA r3,#NT_NSENT
  LD r4,r0,#NT_G_HASH
  ST r4,r3,0
  LD r4,r0,#NT_G_TARGET
  ST r4,r3,1
  LD r1,r0,#NT_G_NS
  ADD r2,r3,r0
  LD r3,r0,#NT_G_TMP
  SHL r3,r3,1
  MOVI r4,2
  CALL @nobj_write
  MOVI r5,2
  CMP r1,r5
  JMP[NE] @nns_s_n
  MOVI r1,0
  JMP @nns_s_d
nns_s_n:
  LA r1,0xFFFFFFFF
nns_s_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nns_get: r1=ns r2=name -> cap or 0
nns_get:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NT_G_NS
  ST r2,r0,#NT_G_NAME
  LD r2,r0,#NT_G_NAME
  ADD r1,r2,r0
  CALL @nns_hash
  ST r1,r0,#NT_G_HASH
  MOVI r2,0
  ST r2,r0,#NT_G_TMP
nns_g_l:
  LD r2,r0,#NT_G_TMP
  MOVI r3,12
  CMP r2,r3
  JMP[GE] @nns_g_n
  LD r1,r0,#NT_G_NS
  LA r2,#NT_NSENT
  LD r3,r0,#NT_G_TMP
  SHL r3,r3,1
  MOVI r4,2
  CALL @nobj_read
  MOVI r5,2
  CMP r1,r5
  JMP[NE] @nns_g_n
  LA r3,#NT_NSENT
  LD r4,r3,0
  LD r5,r0,#NT_G_HASH
  CMP r4,r5
  JMP[EQ] @nns_g_y
  LD r2,r0,#NT_G_TMP
  ADD r2,r2,r13
  ST r2,r0,#NT_G_TMP
  JMP @nns_g_l
nns_g_y:
  LD r1,r3,1
  JMP @nns_g_d
nns_g_n:
  MOVI r1,0
nns_g_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
