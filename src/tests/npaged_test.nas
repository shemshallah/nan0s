; npaged_test.nas - paged KV + incremental prefill/decode parity (F13a).
;
; Proves, with pure NaN and no C harness:
;  - a per-agent npaged block table over 2 MiB nheap pages and nkv class-20
;    storage caps (agent 1 and agent 2 use separate tables);
;  - logical token index -> stable (block, slot) mapping: tokens 0..2 are
;    stride apart in one page, token 3 starts a new 2 MiB page;
;  - prefill 4 tokens, then one-token-at-a-time decode with RoPE at the new
;    position; every step's logits and argmax equal a full nattn recompute
;    over the same token sequence (two prompts, lengths 7 and 4);
;  - remap block 1 to a fresh 2 MiB page: old generation fails, new
;    generation passes, logical tokens 3/4 stay stride apart, and the next
;    decoded token still equals the full recompute bit for bit;
;  - pressure accounting (33%/58%/100% for ctx1, 66% for ctx2), hard capacity
;    failure at 13 tokens, tail-block eviction to nheap and re-append;
;  - fail-closed checks: null x, wrong cfg dim, out-of-range token.
; Success prints exactly O.
;
; Data lives at 0x9000 (16-bit label addressing), code at 0x10000 above all
; library scratch (npaged 0x4800, nkv 0x5000, nattn 0x5600, nq4 0x6000).
.org 0
JMP @main

.org 0x9000
dat:
.word 0
hctx:
.word 0,0,0,0,0,0,0,0
hdescs:
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
hlists:
.word 0,0,0,0,0,0,0,0,0,0,0,0
ctx1:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tab1:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ctx2:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tab2:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
npcfg1:
.word 1,1,0,32,3,40,0,0
npcfg2:
.word 2,1,0,32,2,50,0,0
cfg:
.word 0x5454414E,1,8,32,1,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
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
nw:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
rtab:
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
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
seqx:
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
refbuf:
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
refviews:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
q4c:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
q8c:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
refcap:
.word 0
refshape:
.word 96
logp:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
logf:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
stats:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
vbuf:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
misc:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ts:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

.org 0x10000
.include "../lib/npaged.nas"

main:
MOVI r13,1
MOVI r14,0x7000
CALL @nobj_init

; ---------------------------------------------------------------------------
; nheap: node 0, 12 x 2 MiB at byte 0x200000 (word 0x80000)
LA r1,@hctx
LA r2,@hdescs
MOVI r3,32
LA r4,@hlists
MOVI r5,12
MOVI r6,1
CALL @nheap_init
LA r1,@hctx
MOVI r2,0
MOVI r3,1
LA r4,0x200000
MOVI r5,0
MOVI r6,12
MOVI r7,0
CALL @nheap_add
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; weights: Wq=I(Q4), Wk=I(Q8, value 1), Wv=I(Q4), Wo rows 0..3 -> cols 5,0,2,1
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
MOVI r2,160
CALL @zfill
LA r1,@wo
MOVI r2,0
MOVI r3,5
CALL @mk_row1
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
LA r1,@nw
MOVI r2,32
CALL @fill_ones
CALL @gen_rope
CALL @gen_x

; ---------------------------------------------------------------------------
; nattn cfg (shared by paged append and full recompute)
LA r1,@cfg
LA r2,0x5454414E
ST r2,r1,0
MOVI r2,1
ST r2,r1,1
MOVI r2,8
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
LA r2,@rtab
ST r2,r1,9
LA r2,0x3F000000
ST r2,r1,10
LA r2,@nw
ST r2,r1,11
MOVI r2,0
ST r2,r1,12
LA r2,@q4c
ST r2,r1,13
LA r2,@q8c
ST r2,r1,14
LA r2,0x3F000000
ST r2,r1,15
LA r2,0x3E800000
ST r2,r1,16
ST r0,r1,17

; reference full-recompute storage: 8 records of 3*dim*4 = 384 bytes
LA r1,@refbuf
SHL r1,r1,2
MOVI r2,0
MOVI r3,0xC00
MOVI r4,0
MOVI r5,3
MOVI r6,0
CALL @nkv_storage_create
CMP r1,r0
JMP[EQ] @fail
LA r7,@refcap
ST r1,r7,0
MOVI r4,0
ST r4,r0,@misc+0
refv_l:
LD r4,r0,@misc+0
MOVI r5,8
CMP r4,r5
JMP[GE] @refv_d
; off = i*384
MOVI r2,384
MUL r2,r4,r2
MOVI r3,0
MOVI r4,384
MOVI r5,0
MOVI r6,2
MOVI r7,1
LA r8,@refshape
; out = refviews + i*24
LD r9,r0,@misc+0
MOVI r10,24
MUL r9,r9,r10
LA r10,@refviews
ADD r9,r10,r9
LA r1,@refcap
LD r1,r1,0
CALL @nkv_view_create
CMP r1,r0
JMP[NE] @fail
LD r4,r0,@misc+0
ADD r4,r4,r13
ST r4,r0,@misc+0
JMP @refv_l
refv_d:

; ---------------------------------------------------------------------------
; ctx1: agent 1, 4 blocks x 3 tokens = 12 tokens, pressure 40%
LA r1,@ctx1
LA r2,@hctx
LA r3,@tab1
MOVI r4,4
LA r5,@npcfg1
CALL @npaged_init
CMP r1,r0
JMP[NE] @fail
; ctx2: agent 2, 3 blocks x 2 tokens = 6 tokens, pressure 50%
LA r1,@ctx2
LA r2,@hctx
LA r3,@tab2
MOVI r4,3
LA r5,@npcfg2
CALL @npaged_init
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; prompt 1 prefill: 4 tokens at positions 0..3
MOVI r1,0x60
CALL @stage
LA r1,@ctx1
LA r2,@seqx
MOVI r3,4
MOVI r4,0
LA r5,@cfg
LA r6,@logp
CALL @npaged_prefill
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @fail
MOVI r2,3
CMP r1,r2
JMP[NE] @fail
; parity at position 3
LA r1,@seqx
MOVI r2,4
LA r3,@logp
MOVI r4,0x61
CALL @parity
CMP r1,r0
JMP[NE] @fail
; 4/12 = 33% is below the 40% threshold: percent is live, flag stays clear
LA r1,@ctx1
LA r2,@stats
CALL @npaged_stats
CMP r1,r0
JMP[NE] @fail
LA r6,@stats
LD r1,r6,7
MOVI r2,33
CMP r1,r2
JMP[NE] @fail
LD r1,r6,13
CMP r1,r0
JMP[NE] @fail
LD r1,r6,15
MOVI r2,40
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; stable logical mapping inside block 0 and start of block 1
MOVI r1,0x62
CALL @stage
LA r1,@ctx1
MOVI r2,0
CALL @npaged_token_word
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+0
LA r1,@ctx1
MOVI r2,1
CALL @npaged_token_word
LD r2,r0,@misc+0
SUB r1,r1,r2
LA r2,@ctx1
LD r2,r2,10
CMP r1,r2
JMP[NE] @fail
LA r1,@ctx1
MOVI r2,2
CALL @npaged_token_word
LD r2,r0,@misc+0
SUB r1,r1,r2
LA r2,@ctx1
LD r2,r2,10
ADD r2,r2,r2
CMP r1,r2
JMP[NE] @fail
LA r1,@ctx1
MOVI r2,3
CALL @npaged_token_word
LD r2,r0,@misc+0
CMP r1,r2
JMP[EQ] @fail                ; token 3 is in a different 2 MiB page

; ---------------------------------------------------------------------------
; decode tokens 4 and 5 one at a time
LA r1,@ctx1
LA r2,@seqx
ADDI r2,r2,128
MOVI r3,4
LA r4,@cfg
LA r5,@logp
CALL @npaged_decode
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @fail
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LA r1,@seqx
MOVI r2,5
LA r3,@logp
MOVI r4,0x63
CALL @parity
CMP r1,r0
JMP[NE] @fail

LA r1,@ctx1
LA r2,@seqx
ADDI r2,r2,160
MOVI r3,5
LA r4,@cfg
LA r5,@logp
CALL @npaged_decode
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @fail
MOVI r2,5
CMP r1,r2
JMP[NE] @fail
LA r1,@seqx
MOVI r2,6
LA r3,@logp
MOVI r4,0x64
CALL @parity
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; remap block 1 (tokens 3,4,5) to a fresh 2 MiB page
MOVI r1,0x65
CALL @stage
LA r1,@ctx1
MOVI r2,4
CALL @npaged_token_gen
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+0          ; old generation
LA r1,@ctx1
MOVI r2,4
CALL @npaged_token_word
ST r1,r0,@misc+1          ; old record word
LA r1,@ctx1
MOVI r2,1
CALL @npaged_remap
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+2          ; new generation
LD r2,r0,@misc+0
CMP r1,r2
JMP[EQ] @fail
; stale generation fails, new generation passes
LA r1,@ctx1
MOVI r2,4
LD r3,r0,@misc+0
CALL @npaged_check
MOVI r2,0
CMP r1,r2
JMP[NE] @fail
LA r1,@ctx1
MOVI r2,4
LD r3,r0,@misc+2
CALL @npaged_check
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
; logical slots 3 and 4 stay stride apart in the new page
LA r1,@ctx1
MOVI r2,4
CALL @npaged_token_word
ST r1,r0,@misc+3
LD r2,r0,@misc+1
CMP r1,r2
JMP[EQ] @fail
LA r1,@ctx1
MOVI r2,3
CALL @npaged_token_word
LD r2,r0,@misc+3
SUB r2,r2,r1
LA r1,@ctx1
LD r1,r1,10
CMP r2,r1
JMP[NE] @fail

; decode token 6 after the remap; full recompute must still match
LA r1,@ctx1
LA r2,@seqx
ADDI r2,r2,192
MOVI r3,6
LA r4,@cfg
LA r5,@logp
CALL @npaged_decode
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @fail
MOVI r2,6
CMP r1,r2
JMP[NE] @fail
LA r1,@seqx
MOVI r2,7
LA r3,@logp
MOVI r4,0x66
CALL @parity
CMP r1,r0
JMP[NE] @fail
; the parity oracle is not vacuous: the decoded logits are nonzero
LA r1,@logp
MOVI r2,32
CALL @anynz
CMP r1,r0
JMP[EQ] @fail
; direct attention recompute is deterministic and matches the decode output
LA r1,@ctx1
MOVI r2,6
LA r3,@cfg
LA r4,@logf
CALL @npaged_attention
CMP r1,r0
JMP[NE] @fail
LA r1,@logp
LA r2,@logf
MOVI r3,32
CALL @cmpw
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; prompt 2 on a different agent: 3-token prefill + 2-token/block decode
MOVI r1,0x67
CALL @stage
LA r1,@ctx2
LA r2,@seqx
ADDI r2,r2,96
MOVI r3,3
MOVI r4,0
LA r5,@cfg
LA r6,@logp
CALL @npaged_prefill
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @fail
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LA r1,@seqx
ADDI r1,r1,96
MOVI r2,3
LA r3,@logp
MOVI r4,0x67
CALL @parity
CMP r1,r0
JMP[NE] @fail
LA r1,@ctx2
LA r2,@seqx
ADDI r2,r2,192
MOVI r3,3
LA r4,@cfg
LA r5,@logp
CALL @npaged_decode
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @fail
MOVI r2,3
CMP r1,r2
JMP[NE] @fail
LA r1,@seqx
ADDI r1,r1,96
MOVI r2,4
LA r3,@logp
MOVI r4,0x68
CALL @parity
CMP r1,r0
JMP[NE] @fail
; ctx2 pressure: 4/6 = 66%
LA r1,@ctx2
CALL @npaged_pressure
MOVI r2,66
CMP r1,r2
JMP[NE] @fail
LA r1,@ctx2
LA r2,@stats
CALL @npaged_stats
CMP r1,r0
JMP[NE] @fail
LA r6,@stats
LD r1,r6,0
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r6,1
MOVI r2,6
CMP r1,r2
JMP[NE] @fail
LD r1,r6,2
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r6,7
MOVI r2,66
CMP r1,r2
JMP[NE] @fail
LD r1,r6,13
MOVI r2,1
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; ctx1 pressure after 7 tokens: 7*100/12 = 58%
MOVI r1,0x69
CALL @stage
LA r1,@ctx1
CALL @npaged_pressure
MOVI r2,58
CMP r1,r2
JMP[NE] @fail
LA r1,@ctx1
LA r2,@stats
CALL @npaged_stats
CMP r1,r0
JMP[NE] @fail
LA r6,@stats
LD r1,r6,0
MOVI r2,7
CMP r1,r2
JMP[NE] @fail
LD r1,r6,2
MOVI r2,3
CMP r1,r2
JMP[NE] @fail
LD r1,r6,5
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r6,13
MOVI r2,1
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; fill ctx1 to 12 tokens with append-only steps
MOVI r7,0
ST r7,r0,@misc+4
fill_l:
LD r7,r0,@misc+4
MOVI r8,5
CMP r7,r8
JMP[GE] @fill_d
; x index = (7+i) % 8; xptr = seqx + index*32
LD r9,r0,@misc+4
MOVI r10,7
ADD r9,r9,r10
MOVI r10,7
BOOL.8 r9,r9,r10
SHL r9,r9,5
LA r2,@seqx
ADD r2,r2,r9
LD r10,r0,@misc+4
MOVI r1,7
ADD r3,r10,r1
LA r1,@ctx1
LA r4,@cfg
CALL @npaged_append
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @fail
LD r7,r0,@misc+4
ADD r7,r7,r13
ST r7,r0,@misc+4
JMP @fill_l
fill_d:
LA r1,@ctx2
CALL @npaged_pressure
LA r1,@ctx1
CALL @npaged_pressure
MOVI r2,100
CMP r1,r2
JMP[NE] @fail

; 13th token must fail on capacity
MOVI r1,0x6B
CALL @stage
LA r1,@ctx1
LA r2,@seqx
MOVI r3,12
LA r4,@cfg
CALL @npaged_append
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; tail-block eviction to nheap, then re-append and generation check
MOVI r1,0x6C
CALL @stage
LA r1,@ctx1
MOVI r2,10
CALL @npaged_token_gen
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+5          ; generation of old tail block
LA r1,@ctx1
CALL @npaged_evict_last
CMP r1,r0
JMP[NE] @fail
LA r1,@ctx1
LA r2,@stats
CALL @npaged_stats
CMP r1,r0
JMP[NE] @fail
LA r6,@stats
LD r1,r6,0
MOVI r2,9
CMP r1,r2
JMP[NE] @fail
LD r1,r6,2
MOVI r2,3
CMP r1,r2
JMP[NE] @fail
LD r1,r6,4
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
; evicted token is gone
LA r1,@ctx1
MOVI r2,9
CALL @npaged_token_gen
CMP r1,r0
JMP[NE] @fail
; re-append token 9: new block generation, capacity 2 free
LA r1,@ctx1
LA r2,@seqx
ADDI r2,r2,224
MOVI r3,9
LA r4,@cfg
CALL @npaged_append
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @fail
MOVI r2,9
CMP r1,r2
JMP[NE] @fail
LA r1,@ctx1
MOVI r2,9
CALL @npaged_token_gen
CMP r1,r0
JMP[EQ] @fail
LD r2,r0,@misc+5
CMP r1,r2
JMP[EQ] @fail
LA r1,@ctx1
CALL @npaged_remaining
MOVI r2,2
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; fail-closed negative checks
MOVI r1,0x6D
CALL @stage
; null x
LA r1,@ctx1
MOVI r2,0
MOVI r3,10
LA r4,@cfg
CALL @npaged_append
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail
; out-of-range token
LA r1,@ctx1
MOVI r2,11
CALL @npaged_token_word
CMP r1,r0
JMP[NE] @fail
; dim mismatch is rejected before any allocation
LA r1,@cfg
LD r2,r1,3
ST r2,r0,@misc+6
MOVI r2,64
ST r2,r1,3
LA r1,@ctx1
LA r2,@seqx
MOVI r3,10
LA r4,@cfg
CALL @npaged_append
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail
LA r1,@cfg
LD r2,r0,@misc+6
ST r2,r1,3
; old remap generation still fails, new one still passes
LA r1,@ctx1
MOVI r2,4
LD r3,r0,@misc+0
CALL @npaged_check
CMP r1,r0
JMP[NE] @fail
LA r1,@ctx1
MOVI r2,4
LD r3,r0,@misc+2
CALL @npaged_check
MOVI r2,1
CMP r1,r2
JMP[NE] @fail

MOVI r1,79
PUTC r1
HALT

fail:
LA r2,@dat
LD r1,r2,0
PUTC r1
MOVI r1,70
PUTC r1
HALT

; ---------------------------------------------------------------------------
; helpers
stage:
  LA r2,@dat
  ST r1,r2,0
  RET

; zfill r1=ptr r2=words
zfill:
  MOVI r3,0
zf_l:
  CMP r3,r2
  JMP[GE] @zf_d
  ADD r4,r1,r3
  ST r0,r4,0
  ADD r3,r3,r13
  JMP @zf_l
zf_d:
  RET

; copyw r1=src r2=dst r3=words
copyw:
  MOVI r4,0
cw_l:
  CMP r4,r3
  JMP[GE] @cw_d
  ADD r5,r1,r4
  LD r5,r5,0
  ADD r6,r2,r4
  ST r5,r6,0
  ADD r4,r4,r13
  JMP @cw_l
cw_d:
  RET

; cmpw r1=a r2=b r3=words -> 0/-1
cmpw:
  MOVI r4,0
cm_l:
  CMP r4,r3
  JMP[GE] @cm_ok
  ADD r5,r1,r4
  LD r5,r5,0
  ADD r6,r2,r4
  LD r6,r6,0
  CMP r5,r6
  JMP[NE] @cm_bad
  ADD r4,r4,r13
  JMP @cm_l
cm_ok:
  MOVI r1,0
  RET
cm_bad:
  LA r1,0xFFFFFFFF
  RET

; anynz r1=vec r2=n -> 1 if any word is nonzero
anynz:
  MOVI r3,0
anz_l:
  CMP r3,r2
  JMP[GE] @anz_no
  ADD r4,r1,r3
  LD r4,r4,0
  CMP r4,r0
  JMP[NE] @anz_yes
  ADD r3,r3,r13
  JMP @anz_l
anz_yes:
  MOVI r1,1
  RET
anz_no:
  MOVI r1,0
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

; fill_ones r1=ptr r2=words
fill_ones:
  LA r3,0x3F800000
  MOVI r4,0
fo_l:
  CMP r4,r2
  JMP[GE] @fo_d
  ADD r5,r1,r4
  ST r3,r5,0
  ADD r4,r4,r13
  JMP @fo_l
fo_d:
  RET

; mk_id_q4 r1=dst r2=rows
mk_id_q4:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,@ts+0
  ST r2,r0,@ts+1
  MOVI r7,0
  ST r7,r0,@ts+2
miq_l:
  LD r7,r0,@ts+2
  LD r8,r0,@ts+1
  CMP r7,r8
  JMP[GE] @miq_d
  LA r1,@vbuf
  MOVI r2,32
  CALL @zfill
  LD r7,r0,@ts+2
  LA r1,@vbuf
  ADD r1,r1,r7
  LA r2,0x3F800000
  ST r2,r1,0
  LD r7,r0,@ts+2
  MOVI r8,5
  MUL r7,r7,r8
  LD r8,r0,@ts+0
  ADD r2,r8,r7
  LA r1,@vbuf
  MOVI r3,32
  LA r4,0x3F800000
  CALL @nattn_quant_q4
  LD r7,r0,@ts+2
  ADD r7,r7,r13
  ST r7,r0,@ts+2
  JMP @miq_l
miq_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; mk_id_q8 r1=dst r2=rows (identity, quantized value 1.0)
mk_id_q8:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,@ts+0
  ST r2,r0,@ts+1
  MOVI r7,0
  ST r7,r0,@ts+2
mi8_l:
  LD r7,r0,@ts+2
  LD r8,r0,@ts+1
  CMP r7,r8
  JMP[GE] @mi8_d
  LA r1,@vbuf
  MOVI r2,32
  CALL @zfill
  LD r7,r0,@ts+2
  LA r1,@vbuf
  ADD r1,r1,r7
  LA r2,0x3F800000
  ST r2,r1,0
  LD r7,r0,@ts+2
  MOVI r8,9
  MUL r7,r7,r8
  LD r8,r0,@ts+0
  ADD r2,r8,r7
  LA r1,@vbuf
  MOVI r3,32
  LA r4,0x3F800000
  CALL @nattn_quant_q8
  LD r7,r0,@ts+2
  ADD r7,r7,r13
  ST r7,r0,@ts+2
  JMP @mi8_l
mi8_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; mk_row1 r1=w r2=row r3=col (Q4 row with one 1.0)
mk_row1:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,@ts+0
  ST r2,r0,@ts+1
  ST r3,r0,@ts+2
  LA r1,@vbuf
  MOVI r2,32
  CALL @zfill
  LD r7,r0,@ts+2
  LA r1,@vbuf
  ADD r1,r1,r7
  LA r2,0x3F800000
  ST r2,r1,0
  LD r7,r0,@ts+1
  MOVI r8,5
  MUL r7,r7,r8
  LD r8,r0,@ts+0
  ADD r2,r8,r7
  LA r1,@vbuf
  MOVI r3,32
  LA r4,0x3F800000
  CALL @nattn_quant_q4
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; gen_rope: 16 positions x 16 pairs, all values exact binary fractions
gen_rope:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r7,0
  ST r7,r0,@ts+0
gr_p:
  LD r7,r0,@ts+0
  MOVI r8,16
  CMP r7,r8
  JMP[GE] @gr_d
  MOVI r9,0
  ST r9,r0,@ts+1
gr_i:
  LD r9,r0,@ts+1
  MOVI r10,16
  CMP r9,r10
  JMP[GE] @gr_id
  ; idx = (p*16+i)*2
  MOVI r10,16
  MUL r10,r7,r10
  ADD r10,r10,r9
  SHL r10,r10,1
  LA r11,@rtab
  ADD r11,r11,r10
  ; even position: c=0.5 s=0.25; odd: c=0.25 s=-0.5
  MOVI r12,1
  BOOL.8 r12,r7,r12
  CMP r12,r0
  JMP[NE] @gr_odd
  LA r12,0x3F000000
  LA r5,0x3E800000
  JMP @gr_st
gr_odd:
  LA r12,0x3E800000
  LA r5,0xBF000000
gr_st:
  ST r12,r11,0
  ST r5,r11,1
  LD r9,r0,@ts+1
  ADD r9,r9,r13
  ST r9,r0,@ts+1
  JMP @gr_i
gr_id:
  LD r7,r0,@ts+0
  ADD r7,r7,r13
  ST r7,r0,@ts+0
  JMP @gr_p
gr_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; gen_x: 8 sparse token vectors, 1..3 at two coordinates each
gen_x:
  ST r15,r14,0
  ADD r14,r14,r13
  LA r1,@seqx
  MOVI r2,256
  CALL @zfill
  MOVI r7,0
  ST r7,r0,@ts+0
gx_t:
  LD r7,r0,@ts+0
  MOVI r8,8
  CMP r7,r8
  JMP[GE] @gx_d
  ; a = (t*3) & 31
  MOVI r8,3
  MUL r8,r7,r8
  MOVI r9,31
  BOOL.8 r8,r8,r9
  ST r8,r0,@ts+1
  ; b = (t*5+7) & 31
  MOVI r8,5
  MUL r8,r7,r8
  MOVI r9,7
  ADD r8,r8,r9
  MOVI r9,31
  BOOL.8 r8,r8,r9
  ST r8,r0,@ts+2
  ; v = t % 3
  MOVI r9,3
  MODU r9,r7,r9
  ST r9,r0,@ts+3
  ; base = seqx + t*32
  SHL r10,r7,5
  LA r11,@seqx
  ADD r11,r11,r10
  ; v1 = v+1
  ADD r12,r9,r13
  CVTIF r12,r12
  LD r8,r0,@ts+1
  ADD r5,r11,r8
  ST r12,r5,0
  ; v2 = 3-v
  MOVI r12,3
  SUB r12,r12,r9
  CVTIF r12,r12
  LD r8,r0,@ts+2
  ADD r5,r11,r8
  ST r12,r5,0
  LD r7,r0,@ts+0
  ADD r7,r7,r13
  ST r7,r0,@ts+0
  JMP @gx_t
gx_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ref_write_x r1=xsrc r2=count -> 0/-1
ref_write_x:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,@ts+0
  ST r2,r0,@ts+1
  MOVI r7,0
  ST r7,r0,@ts+2
rw_l:
  LD r7,r0,@ts+2
  LD r8,r0,@ts+1
  CMP r7,r8
  JMP[GE] @rw_ok
  MOVI r9,24
  MUL r9,r7,r9
  LA r10,@refviews
  ADD r10,r10,r9
  ADD r1,r10,r0
  CALL @nattn_view_ptr
  CMP r1,r0
  JMP[EQ] @rw_bad
  ST r1,r0,@ts+3
  MOVI r2,96
  CALL @zfill
  LD r7,r0,@ts+2
  SHL r7,r7,5
  LD r8,r0,@ts+0
  ADD r8,r8,r7
  ADD r1,r8,r0
  LD r2,r0,@ts+3
  MOVI r3,32
  CALL @copyw
  LD r7,r0,@ts+2
  ADD r7,r7,r13
  ST r7,r0,@ts+2
  JMP @rw_l
rw_ok:
  MOVI r1,0
  JMP @rw_out
rw_bad:
  LA r1,0xFFFFFFFF
rw_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; full_logits r1=xsrc r2=count r3=logits -> 0/-1
full_logits:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,@ts+8
  ST r2,r0,@ts+9
  ST r3,r0,@ts+10
  LA r1,@cfg
  LD r2,r0,@ts+9
  ST r2,r1,2
  LD r1,r0,@ts+8
  LD r2,r0,@ts+9
  CALL @ref_write_x
  CMP r1,r0
  JMP[NE] @fl_bad
  LA r1,@cfg
  LA r2,@refviews
  CALL @nattn_forward
  CMP r1,r0
  JMP[NE] @fl_bad
  LA r1,@cfg
  LA r2,@refviews
  LD r3,r0,@ts+10
  CALL @nattn_last_logits
  CMP r1,r0
  JMP[NE] @fl_bad
  MOVI r1,0
  JMP @fl_out
fl_bad:
  LA r1,0xFFFFFFFF
fl_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; parity r1=xsrc r2=count r3=paged logits r4=stage code -> 0/-1
parity:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,@ts+12
  ST r2,r0,@ts+13
  ST r3,r0,@ts+14
  ST r4,r0,@ts+15
  ADD r1,r4,r0
  CALL @stage
  LD r1,r0,@ts+12
  LD r2,r0,@ts+13
  LA r3,@logf
  CALL @full_logits
  CMP r1,r0
  JMP[NE] @pa_bad
  LD r1,r0,@ts+14
  LA r2,@logf
  MOVI r3,32
  CALL @cmpw
  CMP r1,r0
  JMP[NE] @pa_bad
  LD r1,r0,@ts+14
  MOVI r2,32
  CALL @argmax
  ST r1,r0,@ts+16
  LA r1,@logf
  MOVI r2,32
  CALL @argmax
  LD r2,r0,@ts+16
  CMP r1,r2
  JMP[NE] @pa_bad
  MOVI r1,0
  JMP @pa_out
pa_bad:
  LA r1,0xFFFFFFFF
pa_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
