; nattn_test.nas - one-head causal attention over nkv token views (F7b).
;
; Proves:
;  - exact RoPE rotation with a precomputed cos/sin table (90 and 180 deg);
;  - exact f32 softmax: 4 equal -> 1/4, a -1000 gap -> exact one-hot,
;    3 equal -> 1/3, 2 equal -> 1/2, and a normalized generic 3-way;
;  - nattn_qk_fused (Q4_0 x Q8_0 packed integer dot) is bit-identical to the
;    nq4_dot32 oracle over two blocks, with power-of-two scales;
;  - Q4/Q8 quantize -> nq4 dequant round-trip on integer values;
;  - Q4/Q8 matvec over 32 and 64 columns;
;  - nattn_forward over a real nkv KV slab: projections, RoPE, quantized
;    Q/K cache, causal softmax and V mixing.  Uniform attention (Wq=0) on
;    tokens [e0,e1,e2,e2] gives exact contexts [1], [1/2,1/2],
;    [1/3,1/3,1/3], [1/4,1/4,1/2];
;  - a 1-layer attention token gate: embeddings x_t=e_t, Wq=I, Wk=127I,
;    Wv=I, scale 4 => score(t,t)=508, off-diagonal 0 or -508, so softmax is
;    exactly one-hot on the token itself.  Wo maps the last position to the
;    expected id: [0]->1, [0,1]->3, [0,2]->2.
; Success prints exactly O.
;
; Code lives at 0x10000, above every library scratch (nattn 0x5600,
; nq4 0x6000, nkv 0x5000, stack 0x7000).  Data stays at 0x9000 so the
; test's convenience ST r0,@label writes use 16-bit addresses.
.org 0
JMP @main
.org 0x9000
hctx:
.word 0,0,0,0,0,0,0,0
hdescs:
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
hlists:
.word 0,0,0,0,0,0,0,0,0,0,0,0
scfg:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
cfg:
.word 0x5454414E,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
blocktab:
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
views:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
rtab:
.word 0x3F800000,0,0x3F000000,0x3E800000
.word 0,0x3F800000,0xBF800000,0
rtabf:
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
.word 0x3F800000,0,0x3F800000,0,0x3F800000,0,0x3F800000,0
rvec:
.word 0x3F800000,0x40000000,0x40400000,0x40800000
rvec2:
.word 0x3F800000,0x40000000,0x40400000,0x40800000
q4log:
.word 0,0,0,0
hotlog:
.word 0,0xC47A0000,0xC47A0000
q3log:
.word 0x3F800000,0x3F800000,0x3F800000
q2log:
.word 0x3F800000,0x3F800000
genlog:
.word 0,0xBF800000,0xC0000000
smout:
.word 0,0,0,0,0,0,0,0
qvals:
.word 0x3F800000,0xBF800000,0x40000000,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0xBF800000,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0x40000000
qvals2:
.word 0x3F800000,0xBF800000,0x40000000,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
q4blk:
.word 0,0,0,0,0
q4blk2:
.word 0,0,0,0,0
q8blk:
.word 0,0,0,0,0,0,0,0,0
q8blk2:
.word 0,0,0,0,0,0,0,0,0
acts:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
oracle1:
.word 0
oracle2:
.word 0
sav:
.word 0
wq:
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
wk:
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
wv:
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
wo:
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
w64:
.word 0,0,0,0,0,0,0,0,0,0
xvec:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
one64:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
mout:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
nw:
.word 0x3F800000,0x3F800000,0x3F800000,0x3F800000
.word 0x3F800000,0x3F800000,0x3F800000,0x3F800000
.word 0x3F800000,0x3F800000,0x3F800000,0x3F800000
.word 0x3F800000,0x3F800000,0x3F800000,0x3F800000
.word 0x3F800000,0x3F800000,0x3F800000,0x3F800000
.word 0x3F800000,0x3F800000,0x3F800000,0x3F800000
.word 0x3F800000,0x3F800000,0x3F800000,0x3F800000
.word 0x3F800000,0x3F800000,0x3F800000,0x3F800000
q4c:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
q8c:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
t0ctx:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
t1ctx:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
t2ctx:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
t3ctx:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
logits:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
logits2:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
embpat:
.word 0,1,2,2
emb2a:
.word 0,1,0,1
emb2b:
.word 0,2,0,1
emb1:
.word 0,1,0,1
wvals:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
slab:
.word 0
stagev:
.word 0

.org 0x10000
.include "../lib/nattn.nas"

main:
MOVI r13,1
MOVI r14,0x7000

; ---------------------------------------------------------------------------
; RoPE: pos 0 table [1,0, 0.5,0.25] -> [1,2,0.5,2.75]
MOVI r1,0x31
CALL @stage
LA r1,@rvec
LA r2,@rtab
MOVI r3,0
MOVI r4,2
CALL @nattn_rope
CMP r1,r0
JMP[NE] @fail
LA r6,@rvec
LD r1,r6,0
LA r2,0x3F800000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
LA r2,0x40000000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,2
LA r2,0x3F000000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,3
LA r2,0x40300000
CMP r1,r2
JMP[NE] @fail

; RoPE pos 1 table [0,1, -1,0] -> [-2,1,-3,-4]
MOVI r1,0x32
CALL @stage
LA r1,@rvec2
LA r2,@rtab
MOVI r3,1
MOVI r4,2
CALL @nattn_rope
CMP r1,r0
JMP[NE] @fail
LA r6,@rvec2
LD r1,r6,0
LA r2,0xC0000000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
LA r2,0x3F800000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,2
LA r2,0xC0400000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,3
LA r2,0xC0800000
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; softmax: four equal -> 1/4 each
MOVI r1,0x33
CALL @stage
LA r1,@q4log
MOVI r2,4
LA r3,@smout
CALL @nattn_softmax
CMP r1,r0
JMP[NE] @fail
LA r6,@smout
LD r1,r6,0
LA r2,0x3E800000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,3
LA r2,0x3E800000
CMP r1,r2
JMP[NE] @fail

; one-hot gap: [0,-1000,-1000] -> [1,0,0]
MOVI r1,0x34
CALL @stage
LA r1,@hotlog
MOVI r2,3
LA r3,@smout
CALL @nattn_softmax
CMP r1,r0
JMP[NE] @fail
LA r6,@smout
LD r1,r6,0
LA r2,0x3F800000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
CMP r1,r0
JMP[NE] @fail
LD r1,r6,2
CMP r1,r0
JMP[NE] @fail

; 3-way [1,1,1] -> 1/3 exact bits
MOVI r1,0x35
CALL @stage
LA r1,@q3log
MOVI r2,3
LA r3,@smout
CALL @nattn_softmax
CMP r1,r0
JMP[NE] @fail
LA r6,@smout
LD r1,r6,0
LA r2,0x3EAAAAAB
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
CMP r1,r2
JMP[NE] @fail
LD r1,r6,2
CMP r1,r2
JMP[NE] @fail

; 2 equal -> 1/2
MOVI r1,0x36
CALL @stage
LA r1,@q2log
MOVI r2,2
LA r3,@smout
CALL @nattn_softmax
CMP r1,r0
JMP[NE] @fail
LA r6,@smout
LD r1,r6,0
LA r2,0x3F000000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
LA r2,0x3F000000
CMP r1,r2
JMP[NE] @fail

; generic 3-way: strictly ordered and normalized to 1e-6
MOVI r1,0x37
CALL @stage
LA r1,@genlog
MOVI r2,3
LA r3,@smout
CALL @nattn_softmax
CMP r1,r0
JMP[NE] @fail
LA r6,@smout
LD r1,r6,0
LD r2,r6,1
FCMP r1,r2
JMP[LE] @fail
LD r3,r6,2
FCMP r2,r3
JMP[LE] @fail
FADD r1,r1,r2
FADD r1,r1,r3
LA r2,0x3F800000
FSUB r1,r1,r2
LA r2,0x358637BD              ; 1e-6
FCMP r1,r2
JMP[GT] @fail
LA r2,0x358637BD
MOVI r3,0
FSUB r3,r3,r2
FCMP r1,r3
JMP[LT] @fail

; ---------------------------------------------------------------------------
; quantize Q4/Q8 and dequant integer values
MOVI r1,0x38
CALL @stage
LA r1,@qvals
LA r2,@q4blk
MOVI r3,32
LA r4,0x3F800000
CALL @nattn_quant_q4
CMP r1,r0
JMP[NE] @fail
LA r1,@q4blk
MOVI r2,0
CALL @nq4_dequant
LA r2,0x3F800000              ; qvals[0] = 1
CMP r1,r2
JMP[NE] @fail
LA r1,@q4blk
MOVI r2,16
CALL @nq4_dequant
LA r2,0xBF800000              ; qvals[16] = -1
CMP r1,r2
JMP[NE] @fail
LA r1,@q4blk
MOVI r2,31
CALL @nq4_dequant
LA r2,0x40000000              ; qvals[31] = 2
CMP r1,r2
JMP[NE] @fail
LA r1,@qvals
LA r2,@q8blk
MOVI r3,32
LA r4,0x3F800000
CALL @nattn_quant_q8
CMP r1,r0
JMP[NE] @fail
LA r1,@q8blk
MOVI r2,0
CALL @nq8_dequant
LA r2,0x3F800000
CMP r1,r2
JMP[NE] @fail
LA r1,@q8blk
MOVI r2,16
CALL @nq8_dequant
LA r2,0xBF800000
CMP r1,r2
JMP[NE] @fail
LA r1,@q8blk
MOVI r2,31
CALL @nq8_dequant
LA r2,0x40000000
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; fused Q4 x Q8 over two blocks == nq4_dot32 oracle, bit for bit
MOVI r1,0x39
CALL @stage
; block 0: qvals at scale 0.5; block 1: qvals2 at scale 2.0
LA r1,@qvals
LA r2,@q4blk
MOVI r3,32
LA r4,0x3F800000
CALL @nattn_quant_q4
CMP r1,r0
JMP[NE] @fail
LA r5,@q4blk
LA r2,0x3F000000
ST r2,r5,0
LA r1,@qvals2
LA r2,@q4blk2
MOVI r3,32
LA r4,0x3F800000
CALL @nattn_quant_q4
CMP r1,r0
JMP[NE] @fail
LA r5,@q4blk2
LA r2,0x40000000
ST r2,r5,0
; q8 block 0 scale 0.25, block 1 scale 4.0
LA r1,@qvals
LA r2,@q8blk
MOVI r3,32
LA r4,0x3F800000
CALL @nattn_quant_q8
CMP r1,r0
JMP[NE] @fail
LA r5,@q8blk
LA r2,0x3E800000
ST r2,r5,0
LA r1,@qvals2
LA r2,@q8blk2
MOVI r3,32
LA r4,0x3F800000
CALL @nattn_quant_q8
CMP r1,r0
JMP[NE] @fail
LA r5,@q8blk2
LA r2,0x40800000
ST r2,r5,0
; oracle over 2 blocks
LA r1,@q4blk
LA r2,@q8blk
MOVI r3,2
LA r4,@acts
CALL @qk_oracle
ST r1,r0,@oracle2
LA r1,@oracle2
LD r1,r1,0
ST r1,r0,@sav
LA r1,@q4blk
LA r2,@q8blk
MOVI r3,2
CALL @nattn_qk_fused
LA r2,@sav
LD r2,r2,0
CMP r1,r2
JMP[NE] @fail
; single block must also match
LA r1,@q4blk
LA r2,@q8blk
MOVI r3,1
LA r4,@acts
CALL @qk_oracle
ST r1,r0,@oracle1
LA r1,@q4blk
LA r2,@q8blk
MOVI r3,1
CALL @nattn_qk_fused
LA r2,@oracle1
LD r2,r2,0
CMP r1,r2
JMP[NE] @fail
; and the two-block dot must differ from block 0 alone
LA r1,@sav
LD r1,r1,0
LA r2,@oracle1
LD r2,r2,0
CMP r1,r2
JMP[EQ] @fail

; ---------------------------------------------------------------------------
; matvec: Q4/Q8 identity over 32 columns
MOVI r1,0x3A
CALL @stage
LA r1,@wq
MOVI r2,32
CALL @mk_id_q4
LA r1,@wk
MOVI r2,32
CALL @mk_id_q8
LA r1,@xvec
MOVI r2,32
CALL @fill_seq
LA r1,@wq
MOVI r2,32
MOVI r3,32
LA r4,@xvec
LA r5,@mout
CALL @nattn_matvec_q4
CMP r1,r0
JMP[NE] @fail
LA r6,@mout
MOVI r7,0
mvt_l:
  MOVI r2,32
  CMP r7,r2
  JMP[GE] @mvt_d
  ADD r1,r6,r7
  LD r1,r1,0
  LA r2,@xvec
  ADD r2,r2,r7
  LD r2,r2,0
  CMP r1,r2
  JMP[NE] @fail
  ADD r7,r7,r13
  JMP @mvt_l
mvt_d:
LA r1,@wk
MOVI r2,32
MOVI r3,32
LA r4,@xvec
LA r5,@mout
CALL @nattn_matvec_q8
CMP r1,r0
JMP[NE] @fail
LA r6,@mout
MOVI r7,0
mvt8_l:
  MOVI r2,32
  CMP r7,r2
  JMP[GE] @mvt8_d
  ADD r1,r6,r7
  LD r1,r1,0
  LA r2,@xvec
  ADD r2,r2,r7
  LD r2,r2,0
  LA r3,0x42FE0000              ; 127.0
  FMUL r2,r2,r3
  CMP r1,r2
  JMP[NE] @fail
  ADD r7,r7,r13
  JMP @mvt8_l
mvt8_d:

; 64-column matvec: two blocks, both +1, x all ones -> 64
MOVI r1,0x3B
CALL @stage
LA r1,@w64
MOVI r2,2
CALL @mk_one_q4
LA r1,@one64
MOVI r2,64
CALL @fill_ones
LA r1,@w64
MOVI r2,1
MOVI r3,64
LA r4,@one64
LA r5,@mout
CALL @nattn_matvec_q4
CMP r1,r0
JMP[NE] @fail
LA r6,@mout
LD r1,r6,0
LA r2,0x42800000              ; 64.0
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; forward on a real nkv slab: 4 tokens, dim 32, uniform attention (Wq=0)
MOVI r1,0x40
CALL @stage
CALL @setup_slab
CMP r1,r0
JMP[NE] @fail
; embeddings x0=e0, x1=e1, x2=e0+e1, x3=e2
LA r1,@embpat
CALL @write_embs
CMP r1,r0
JMP[NE] @fail
; zero Wq, identity Wv/Wo, identity Wk (irrelevant when Q=0)
LA r1,@wq
MOVI r2,160
CALL @zfill
LA r1,@wk
MOVI r2,32
CALL @mk_id_q8
LA r1,@wv
MOVI r2,32
CALL @mk_id_q4
LA r1,@wo
MOVI r2,32
CALL @mk_id_q4
; cfg uniform: n=4, dim=32, flags=1, scale=0.25
LA r1,@cfg
MOVI r2,4
ST r2,r1,2
MOVI r2,32
ST r2,r1,3
MOVI r2,1
ST r2,r1,4
LA r2,@wq
ST r2,r1,5
LA r2,@wk
ST r2,r1,6
LA r2,@wv
ST r2,r1,7
LA r2,@wo
ST r2,r1,8
LA r2,@rtabf
ST r2,r1,9
LA r2,0x3E800000
ST r2,r1,10
LA r2,@nw
ST r2,r1,11
MOVI r2,0
ST r2,r1,12
LA r2,@q4c
ST r2,r1,13
LA r2,@q8c
ST r2,r1,14
LA r2,0x3F800000
ST r2,r1,15
ST r2,r1,16
LA r1,@cfg
LA r2,@views
CALL @nattn_forward
CMP r1,r0
JMP[NE] @fail
; contexts
MOVI r1,0x41
CALL @stage
LA r1,@views
LA r2,@t0ctx
CALL @ctx_bits
; t0: [1,0,...]
LA r6,@t0ctx
LD r1,r6,0
LA r2,0x3F800000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
CMP r1,r0
JMP[NE] @fail
; t1: [0.5,0.5,0,...]
LA r1,@views
LA r2,@t1ctx
MOVI r3,1
CALL @tok_ctx
LA r6,@t1ctx
LD r1,r6,0
LA r2,0x3F000000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
LA r2,0x3F000000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,2
CMP r1,r0
JMP[NE] @fail
; t2: [1/3,1/3,1/3,0,...]
LA r1,@views
LA r2,@t2ctx
MOVI r3,2
CALL @tok_ctx
LA r6,@t2ctx
LD r1,r6,0
LA r2,0x3EAAAAAB
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
LA r2,0x3EAAAAAB
CMP r1,r2
JMP[NE] @fail
LD r1,r6,2
LA r2,0x3EAAAAAB
CMP r1,r2
JMP[NE] @fail
LD r1,r6,3
CMP r1,r0
JMP[NE] @fail
; t3: [0.25,0.25,0.5,0,...]
LA r1,@views
LA r2,@t3ctx
MOVI r3,3
CALL @tok_ctx
LA r6,@t3ctx
LD r1,r6,0
LA r2,0x3E800000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
LA r2,0x3E800000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,2
LA r2,0x3F000000
CMP r1,r2
JMP[NE] @fail
LD r1,r6,3
CMP r1,r0
JMP[NE] @fail

; last logits: residual x[t3]=e2 + ctx -> argmax 2
MOVI r1,0x42
CALL @stage
LA r1,@cfg
LA r2,@views
LA r3,@logits
CALL @nattn_last_logits
CMP r1,r0
JMP[NE] @fail
LA r1,@logits
MOVI r2,32
CALL @argmax
MOVI r2,2
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; 1-layer attention token gate: Wq=I, Wk=127I, Wv=I, scale 4,
; score(t,t)=508, so attention is exactly self (exp(-508)=0).
MOVI r1,0x50
CALL @stage
LA r1,@wq
MOVI r2,32
CALL @mk_id_q4
LA r1,@wk
MOVI r2,32
CALL @mk_id_q8
LA r1,@wv
MOVI r2,32
CALL @mk_id_q4
LA r1,@wo
MOVI r2,32
CALL @mk_id_q4
; Wo rows: row1 col0, row2 col2, row3 col1; row0 zero
LA r1,@wvals
MOVI r2,32
CALL @zfill
LA r1,@wo
MOVI r2,160
CALL @zfill
LA r1,@wo
MOVI r2,1
MOVI r3,0
CALL @mk_row1
LA r1,@wo
MOVI r2,2
MOVI r3,2
CALL @mk_row1
LA r1,@wo
MOVI r2,3
MOVI r3,1
CALL @mk_row1
; cfg: n=2, scale=4
LA r1,@cfg
MOVI r2,2
ST r2,r1,2
LA r2,0x40800000
ST r2,r1,10

; prompt [0,1]: x0=e0, x1=e1 -> id 3
LA r1,@emb2a
CALL @write_embs
CMP r1,r0
JMP[NE] @fail
LA r1,@cfg
LA r2,@views
CALL @nattn_forward
CMP r1,r0
JMP[NE] @fail
LA r1,@cfg
LA r2,@views
LA r3,@logits
CALL @nattn_last_logits
CMP r1,r0
JMP[NE] @fail
LA r1,@logits
MOVI r2,32
CALL @argmax
MOVI r2,3
CMP r1,r2
JMP[NE] @fail

; prompt [0,2]: x0=e0, x1=e2 -> id 2
MOVI r1,0x51
CALL @stage
LA r1,@emb2b
CALL @write_embs
CMP r1,r0
JMP[NE] @fail
LA r1,@cfg
LA r2,@views
CALL @nattn_forward
CMP r1,r0
JMP[NE] @fail
LA r1,@cfg
LA r2,@views
LA r3,@logits
CALL @nattn_last_logits
CMP r1,r0
JMP[NE] @fail
LA r1,@logits
MOVI r2,32
CALL @argmax
MOVI r2,2
CMP r1,r2
JMP[NE] @fail

; prompt [0]: x0=e0 -> id 1
MOVI r1,0x52
CALL @stage
LA r1,@emb1
CALL @write_embs
CMP r1,r0
JMP[NE] @fail
LA r1,@cfg
MOVI r2,1
ST r2,r1,2
LA r1,@cfg
LA r2,@views
CALL @nattn_forward
CMP r1,r0
JMP[NE] @fail
LA r1,@cfg
LA r2,@views
LA r3,@logits
CALL @nattn_last_logits
CMP r1,r0
JMP[NE] @fail
LA r1,@logits
MOVI r2,32
CALL @argmax
MOVI r2,1
CMP r1,r2
JMP[NE] @fail

; determinism: rerun [0] and compare four logits
MOVI r1,0x53
CALL @stage
LA r1,@cfg
LA r2,@views
CALL @nattn_forward
CMP r1,r0
JMP[NE] @fail
LA r1,@cfg
LA r2,@views
LA r3,@logits2
CALL @nattn_last_logits
CMP r1,r0
JMP[NE] @fail
LA r6,@logits
LA r7,@logits2
MOVI r8,0
det_l:
  MOVI r2,4
  CMP r8,r2
  JMP[GE] @det_d
  ADD r1,r6,r8
  LD r1,r1,0
  ADD r2,r7,r8
  LD r2,r2,0
  CMP r1,r2
  JMP[NE] @fail
  ADD r8,r8,r13
  JMP @det_l
det_d:

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
; qk_oracle r1=q4 blocks r2=q8 blocks r3=nblocks r4=acts -> f32 bits
; Dequantizes each Q8 block into acts and calls nq4_dot32, summing in order.
qk_oracle:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,0x6800
  ST r2,r0,0x6801
  ST r3,r0,0x6802
  ST r4,r0,0x6803
  MOVI r1,0
  ST r1,r0,0x6804
  ST r0,r0,0x6805
qko_b:
  LD r1,r0,0x6805
  LD r2,r0,0x6802
  CMP r1,r2
  JMP[GE] @qko_d
  MOVI r2,0
  ST r2,r0,0x6806
qko_j:
  LD r1,r0,0x6806
  MOVI r2,32
  CMP r1,r2
  JMP[GE] @qko_dot
  LD r2,r0,0x6805
  MOVI r3,9
  MUL r2,r2,r3
  LD r3,r0,0x6801
  ADD r2,r3,r2
  ADD r1,r2,r0
  LD r2,r0,0x6806
  CALL @nq8_dequant
  LD r2,r0,0x6806
  LD r3,r0,0x6803
  ADD r3,r3,r2
  ST r1,r3,0
  LD r1,r0,0x6806
  ADD r1,r1,r13
  ST r1,r0,0x6806
  JMP @qko_j
qko_dot:
  LD r2,r0,0x6805
  MOVI r3,5
  MUL r2,r2,r3
  LD r3,r0,0x6800
  ADD r2,r3,r2
  ADD r1,r2,r0
  LD r2,r0,0x6803
  CALL @nq4_dot32
  LD r2,r0,0x6804
  FADD r1,r1,r2
  ST r1,r0,0x6804
  LD r1,r0,0x6805
  ADD r1,r1,r13
  ST r1,r0,0x6805
  JMP @qko_b
qko_d:
  LD r1,r0,0x6804
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; zfill r1=ptr r2=words
zfill:
  CMP r2,r0
  JMP[LE] @zf_d
zf_l:
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  CMP r2,r0
  JMP[NE] @zf_l
zf_d:
  RET

; fill_seq r1=ptr r2=n -> ptr[i]=i+1 as f32
fill_seq:
  MOVI r3,0
fs_l:
  CMP r3,r2
  JMP[GE] @fs_d
  ADDI r4,r3,1
  CVTIF r4,r4
  ADD r5,r1,r3
  ST r4,r5,0
  ADD r3,r3,r13
  JMP @fs_l
fs_d:
  RET

; fill_ones r1=ptr r2=n
fill_ones:
  LA r3,0x3F800000
fo_l:
  CMP r2,r0
  JMP[LE] @fo_d
  ST r3,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @fo_l
fo_d:
  RET

; mk_id_q4 r1=w r2=rows: one block per row, scale 1, +1 at col=row
mk_id_q4:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,0x6810
  ST r2,r0,0x6811
  ST r0,r0,0x6812
miq4_l:
  LD r1,r0,0x6812
  LD r2,r0,0x6811
  CMP r1,r2
  JMP[GE] @miq4_d
  LA r1,0x6820
  MOVI r2,32
  CALL @zfill
  LD r2,r0,0x6812
  LA r1,0x6820
  ADD r1,r1,r2
  LA r3,0x3F800000
  ST r3,r1,0
  LD r2,r0,0x6812
  MOVI r3,5
  MUL r2,r2,r3
  LD r3,r0,0x6810
  ADD r2,r3,r2
  LA r1,0x6820
  ADD r1,r1,r0
  MOVI r3,32
  LA r4,0x3F800000
  CALL @nattn_quant_q4
  LD r1,r0,0x6812
  ADD r1,r1,r13
  ST r1,r0,0x6812
  JMP @miq4_l
miq4_d:
  MOVI r1,0
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; mk_id_q8 r1=w r2=rows: one block per row, scale 1, 127 at col=row
mk_id_q8:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,0x6810
  ST r2,r0,0x6811
  ST r0,r0,0x6812
miq8_l:
  LD r1,r0,0x6812
  LD r2,r0,0x6811
  CMP r1,r2
  JMP[GE] @miq8_d
  LA r1,0x6820
  MOVI r2,32
  CALL @zfill
  LD r2,r0,0x6812
  LA r1,0x6820
  ADD r1,r1,r2
  LA r3,0x42FE0000
  ST r3,r1,0
  LD r2,r0,0x6812
  MOVI r3,9
  MUL r2,r2,r3
  LD r3,r0,0x6810
  ADD r2,r3,r2
  LA r1,0x6820
  MOVI r3,32
  LA r4,0x3F800000
  CALL @nattn_quant_q8
  LD r1,r0,0x6812
  ADD r1,r1,r13
  ST r1,r0,0x6812
  JMP @miq8_l
miq8_d:
  MOVI r1,0
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; mk_one_q4 r1=w r2=nblocks: every nibble +1, scale 1
mk_one_q4:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,0x6810
  ST r2,r0,0x6811
  ST r0,r0,0x6812
  LA r1,0x6820
  MOVI r2,32
  CALL @fill_ones
moq_l:
  LD r1,r0,0x6812
  LD r2,r0,0x6811
  CMP r1,r2
  JMP[GE] @moq_d
  LD r2,r0,0x6812
  MOVI r3,5
  MUL r2,r2,r3
  LD r3,r0,0x6810
  ADD r2,r3,r2
  LA r1,0x6820
  MOVI r3,32
  LA r4,0x3F800000
  CALL @nattn_quant_q4
  LD r1,r0,0x6812
  ADD r1,r1,r13
  ST r1,r0,0x6812
  JMP @moq_l
moq_d:
  MOVI r1,0
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; mk_row1 r1=w r2=row r3=col: quantized Q4 row with +1 at col
mk_row1:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,0x6810
  ST r2,r0,0x6811
  ST r3,r0,0x6812
  LA r1,0x6820
  MOVI r2,32
  CALL @zfill
  LA r1,0x6820
  LD r2,r0,0x6812
  ADD r1,r1,r2
  LA r3,0x3F800000
  ST r3,r1,0
  LD r2,r0,0x6811
  MOVI r3,5
  MUL r2,r2,r3
  LD r3,r0,0x6810
  ADD r2,r3,r2
  LA r1,0x6820
  MOVI r3,32
  LA r4,0x3F800000
  CALL @nattn_quant_q4
  MOVI r1,0
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; argmax r1=vec r2=n -> index
argmax:
  LD r3,r1,0
  MOVI r4,0
  MOVI r5,1
am_l:
  CMP r5,r2
  JMP[GE] @am_d
  ADD r6,r1,r5
  LD r6,r6,0
  FCMP r6,r3
  JMP[GT] @am_up
  ADD r5,r5,r13
  JMP @am_l
am_up:
  ADD r3,r6,r0
  ADD r4,r5,r0
  ADD r5,r5,r13
  JMP @am_l
am_d:
  ADD r1,r4,r0
  RET

; ---------------------------------------------------------------------------
; KV slab setup
setup_slab:
  ST r15,r14,0
  ADD r14,r14,r13
  CALL @nobj_init
  LA r1,@hctx
  LA r2,@hdescs
  MOVI r3,16
  LA r4,@hlists
  MOVI r5,12
  MOVI r6,1
  CALL @nheap_init
  LA r1,@hctx
  MOVI r2,0
  MOVI r3,0
  LA r4,0x100000
  MOVI r5,0
  MOVI r6,16
  MOVI r7,0
  CALL @nheap_add
  CMP r1,r0
  JMP[NE] @ss_bad
  ; cfg fields for the slab (bytes/token 3*dim*4 = 384)
  LA r6,@scfg
  MOVI r1,1
  ST r1,r6,0
  ST r1,r6,1
  ST r0,r6,2
  MOVI r1,2
  ST r1,r6,3
  MOVI r1,1
  ST r1,r6,4
  ST r1,r6,5
  MOVI r1,32
  ST r1,r6,6
  LA r1,384
  ST r1,r6,7
  ST r0,r6,8
  MOVI r1,8
  ST r1,r6,9
  MOVI r1,2
  ST r1,r6,10
  ST r0,r6,11
  MOVI r1,1
  ST r1,r6,12
  ST r0,r6,13
  ST r0,r6,14
  ST r0,r6,15
  LA r1,@scfg
  LA r2,@hctx
  LA r3,@blocktab
  MOVI r4,8
  CALL @nkv_slab_create
  CMP r1,r0
  JMP[EQ] @ss_bad
  ST r1,r0,@slab
  ; append four tokens
  LA r1,@slab
  LD r1,r1,0
  MOVI r2,4
  CALL @nkv_slab_append_n
  CMP r1,r0
  JMP[NE] @ss_bad
  ; token views
  MOVI r4,0
  ST r4,r0,0x6850
ss_tv:
  LD r4,r0,0x6850
  MOVI r5,4
  CMP r4,r5
  JMP[GE] @ss_ok
  LA r1,@slab
  LD r1,r1,0
  ADD r2,r4,r0
  MOVI r3,24
  MUL r3,r4,r3
  LA r5,@views
  ADD r3,r5,r3
  CALL @nkv_slab_token_view
  CMP r1,r0
  JMP[NE] @ss_bad
  LD r4,r0,0x6850
  ADD r4,r4,r13
  ST r4,r0,0x6850
  JMP @ss_tv
ss_ok:
  MOVI r1,0
  JMP @ss_out
ss_bad:
  LA r1,0xFFFFFFFF
ss_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; write_embs r1=pattern ptr: 4 token coords; x_t = e_{pat[t]}
; Zeroes all 3*dim words of views 0..3 and writes x slots.
write_embs:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,0x6830
  MOVI r4,0
  ST r4,r0,0x6854
we_t:
  LD r4,r0,0x6854
  MOVI r5,4
  CMP r4,r5
  JMP[GE] @we_ok
  MOVI r2,24
  MUL r3,r4,r2
  LA r5,@views
  ADD r3,r5,r3
  ADD r1,r3,r0
  CALL @nattn_view_ptr
  CMP r1,r0
  JMP[EQ] @we_bad
  ST r1,r0,0x6831
  MOVI r2,96
  CALL @zfill
  LD r4,r0,0x6854
  LD r1,r0,0x6830
  ADD r1,r1,r4
  LD r2,r1,0
  LD r1,r0,0x6831
  ADD r1,r1,r2
  LA r3,0x3F800000
  ST r3,r1,0
  LD r4,r0,0x6854
  ADD r4,r4,r13
  ST r4,r0,0x6854
  JMP @we_t
we_ok:
  MOVI r1,0
  JMP @we_out
we_bad:
  LA r1,0xFFFFFFFF
we_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; tok_ctx r1=views r2=out r3=token: copy 32 words from view+2*dim
tok_ctx:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r2,r0,0x6840
  MOVI r4,24
  MUL r4,r3,r4
  ADD r4,r1,r4
  ADD r1,r4,r0
  CALL @nattn_view_ptr
  CMP r1,r0
  JMP[EQ] @tc_bad
  MOVI r2,64
  ADD r1,r1,r2
  LD r5,r0,0x6840
  MOVI r4,0
tc_l:
  MOVI r2,32
  CMP r4,r2
  JMP[GE] @tc_ok
  ADD r2,r1,r4
  LD r2,r2,0
  ADD r3,r5,r4
  ST r2,r3,0
  ADD r4,r4,r13
  JMP @tc_l
tc_ok:
  MOVI r1,0
  JMP @tc_out
tc_bad:
  LA r1,0xFFFFFFFF
tc_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ctx_bits r1=views r2=out: same as tok_ctx for token 0
ctx_bits:
  MOVI r3,0
  JMP @tok_ctx

