; nspectree_test.nas - tree speculation vs plain decode + branch promotion.
;
; Pure NaN, no C harness.  One immutable nattn weight root and one nheap.
; Four paged contexts: a tree-speculative context, a plain npaged_decode
; reference, a deterministic rerun, and a reusable scratch context for the
; alternate-branch / partial-accept / full-fallback cases.
;
; For prompt tokens 0,1,2,3 and verifier seed 1 the test proves:
;
;  - a depth-2 / two-root / two-children tree (6 candidates) is appended to
;    one paged context with per-candidate causal masks and branch tags;
;  - one batched verifier pass computes all six candidate logits, the primary
;    depth-2 branch is accepted, the other four candidates are rejected and
;    released by npaged_trim;
;  - the four accepted token ids, four 32-word pre-sample logits vectors and
;    the final 32 next-token logits are bit-equal to plain npaged_decode;
;  - the accepted record generation changes across the in-block trim (stale
;    generation fails npaged_check, the promoted generation passes) and a
;    boundary trim preserves the full block's generation;
;  - the alternate root B branch is promoted by record relocation from its
;    DFS slots to the prefix, then trimmed, and is still bit-equal to plain;
;  - the forced-partial step accepts depth 1 and appends the verifier's free
;    token, still bit-equal to plain;
;  - the forced-no-root step rejects all six candidates and falls back to two
;    sequential verifier appends, still bit-equal to plain;
;  - a full rerun reproduces ids, logits, final logits, counters, trace count
;    and trace head exactly.
;
; Success prints exactly O.

.org 0
JMP @main

; ---------------------------------------------------------------------------
; data at 0x9000 words, code at 0x10000
.org 0x9000
hctx:
.org 0x9010
hdescs:
.org 0x9110
hlists:
.org 0x9120
ntA:
.org 0x9500
ntB:
.org 0x9800
ntC:
.org 0x9B00
ntD:
.org 0x9E00
ctxTree:
.org 0x9E20
ctxPlain:
.org 0x9E40
ctxRerun:
.org 0x9E60
ctxScratch:
.org 0x9E80
tabTree:
.org 0x9F00
tabPlain:
.org 0x9F80
tabRerun:
.org 0xA000
tabScratch:
.org 0xA080
cfgNatt:
.org 0xA0A0
ntcfgA:
.org 0xA0B0
ntcfgPlain:
.org 0xA0C0
ntcfgC:
.org 0xA0D0
ntcfgAlt:
.org 0xA0E0
ntcfgPart:
.org 0xA0F0
ntcfgZero:
.org 0xA100
npcfg:
.org 0xA120
toksA:
.org 0xA140
toksB:
.org 0xA160
toksC:
.org 0xA180
toksD:
.org 0xA1A0
toksPlain2:
.org 0xA200
logsA:
.org 0xA300
logsB:
.org 0xA400
logsC:
.org 0xA500
logsD:
.org 0xA600
logsPlain2:
.org 0xA700
cur2save:
.org 0xA740
stA:
.org 0xA760
stB:
.org 0xA780
stC:
.org 0xA7A0
stD:
.org 0xA7C0
cand:
.org 0xA7E0
ev:
.org 0xA800
misc:
.org 0xA820
ts:
.org 0xA900
wq:
.org 0xAAA0
wk:
.org 0xABC0
wv:
.org 0xAC60
wo:
.org 0xAD00
nw:
.org 0xAD20
rtab:
.org 0xB120
toktab:
.org 0xB220
drafttab:
.org 0xB260
vbuf:
.org 0xB2A0
q4c:
.org 0xB3A0
q8c:
.org 0xB500
traceA:
.org 0xB800
traceC:

.org 0x10000
.include "../lib/nspectree.nas"

main:
MOVI r13,1
MOVI r14,0x7000
CALL @nobj_init

; ---------------------------------------------------------------------------
; nheap: node 0, 24 x 2 MiB pages at byte 0x200000
MOVI r1,0x61
CALL @stage
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
MOVI r6,24
MOVI r7,0
CALL @nheap_add
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; weights: Wq=I(Q4), Wk=I(Q8), Wv=I(Q4); Wo rows 0..7 -> cols
; 5,0,2,1,6,3,7,4 so all 8 vocab logits are meaningful.
MOVI r1,0x62
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
LA r1,@wo
MOVI r2,4
MOVI r3,6
CALL @mk_row1
LA r1,@wo
MOVI r2,5
MOVI r3,3
CALL @mk_row1
LA r1,@wo
MOVI r2,6
MOVI r3,7
CALL @mk_row1
LA r1,@wo
MOVI r2,7
MOVI r3,4
CALL @mk_row1
LA r1,@nw
MOVI r2,32
CALL @fill_ones
CALL @gen_rope
LA r1,@toktab
CALL @gen_toktab
LA r1,@drafttab
CALL @gen_drafttab

; ---------------------------------------------------------------------------
; nattn cfg (one immutable weight root shared by every stream)
MOVI r1,0x63
CALL @stage
LA r1,@cfgNatt
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
ST r0,r1,12
LA r2,@q4c
ST r2,r1,13
LA r2,@q8c
ST r2,r1,14
LA r2,0x3F000000
ST r2,r1,15
LA r2,0x3E800000
ST r2,r1,16
ST r0,r1,17

; nspectree init cfg: vocab 8, temp 0.5, flags 0, seed 1, draft 0x12345678
LA r1,@ntcfgA
LA r2,0x4346544E
ST r2,r1,0
MOVI r2,1
ST r2,r1,1
MOVI r2,8
ST r2,r1,2
LA r2,0x3F000000
ST r2,r1,3
ST r0,r1,4
MOVI r2,1
ST r2,r1,5
LA r2,0x12345678
ST r2,r1,6
LA r2,@toktab
ST r2,r1,7
LA r2,@drafttab
ST r2,r1,8
LA r2,@traceA
ST r2,r1,9
MOVI r2,160
ST r2,r1,10
ST r0,r1,11
; plain: no trace buffer
LA r1,@ntcfgA
LA r2,@ntcfgPlain
MOVI r3,12
CALL @copyw
LA r1,@ntcfgPlain
ST r0,r1,9
ST r0,r1,10
; rerun: traceC
LA r1,@ntcfgA
LA r2,@ntcfgC
MOVI r3,12
CALL @copyw
LA r2,@ntcfgC
LA r1,@traceC
ST r1,r2,9
; alt/part/zero: traceA
LA r1,@ntcfgA
LA r2,@ntcfgAlt
MOVI r3,12
CALL @copyw
LA r1,@ntcfgA
LA r2,@ntcfgPart
MOVI r3,12
CALL @copyw
LA r1,@ntcfgA
LA r2,@ntcfgZero
MOVI r3,12
CALL @copyw

; npaged init cfg: agent 1, gen 1, node 0, dim 32, 4 tokens/block, 50%
LA r1,@npcfg
MOVI r2,1
ST r2,r1,0
MOVI r2,1
ST r2,r1,1
ST r0,r1,2
MOVI r2,32
ST r2,r1,3
MOVI r2,4
ST r2,r1,4
MOVI r2,50
ST r2,r1,5
ST r0,r1,6
ST r0,r1,7

; ---------------------------------------------------------------------------
; paged + nspectree contexts (8 blocks x 4 tokens = 32 tokens)
MOVI r1,0x64
CALL @stage
LA r1,@ctxTree
LA r2,@hctx
LA r3,@tabTree
MOVI r4,8
LA r5,@npcfg
CALL @npaged_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ctxPlain
LA r2,@hctx
LA r3,@tabPlain
MOVI r4,8
LA r5,@npcfg
CALL @npaged_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ctxRerun
LA r2,@hctx
LA r3,@tabRerun
MOVI r4,8
LA r5,@npcfg
CALL @npaged_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ctxScratch
LA r2,@hctx
LA r3,@tabScratch
MOVI r4,8
LA r5,@npcfg
CALL @npaged_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ntA
LA r2,@ctxTree
LA r3,@cfgNatt
LA r4,@ntcfgA
CALL @nspectree_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ntB
LA r2,@ctxPlain
LA r3,@cfgNatt
LA r4,@ntcfgPlain
CALL @nspectree_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ntC
LA r2,@ctxRerun
LA r3,@cfgNatt
LA r4,@ntcfgC
CALL @nspectree_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
LA r2,@ctxScratch
LA r3,@cfgNatt
LA r4,@ntcfgPlain
CALL @nspectree_init
CMP r1,r0
JMP[NE] @fail

; xorshift recurrence pinned against nreplay nrng_next(1) = 0x00042021
MOVI r1,1
CALL @ns_xorshift
LA r2,0x00042021
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; prefill prompt tokens 0,1,2,3 (x rows are contiguous in toktab)
MOVI r1,0x65
CALL @stage
LA r1,@ntA
LA r2,@toktab
MOVI r3,4
MOVI r4,3
CALL @nspectree_prefill
CMP r1,r0
JMP[NE] @fail
LA r1,@ntB
LA r2,@toktab
MOVI r3,4
MOVI r4,3
CALL @nspectree_prefill
CMP r1,r0
JMP[NE] @fail
LA r1,@ntC
LA r2,@toktab
MOVI r3,4
MOVI r4,3
CALL @nspectree_prefill
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
LA r2,@toktab
MOVI r3,4
MOVI r4,3
CALL @nspectree_prefill
CMP r1,r0
JMP[NE] @fail
; prefill logits identical
LA r1,@ntA
CALL @nspectree_cur_logits
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+0
LA r1,@ntB
CALL @nspectree_cur_logits
LD r2,r0,@misc+0
MOVI r3,32
CALL @cmpw
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; plain reference: 4 tokens
MOVI r1,0x66
CALL @stage
LA r1,@ntB
LA r2,@toksB
LA r3,@logsB
MOVI r4,4
CALL @nspectree_generate_plain
MOVI r2,4
CMP r1,r2
JMP[NE] @fail

; plain reference: 2 tokens on the scratch context, final logits saved
MOVI r1,0x67
CALL @stage
LA r1,@ntD
LA r2,@toksPlain2
LA r3,@logsPlain2
MOVI r4,2
CALL @nspectree_generate_plain
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LA r1,@ntD
CALL @nspectree_cur_logits
CMP r1,r0
JMP[EQ] @fail
LA r2,@cur2save
MOVI r3,32
CALL @ns_copy
; release the scratch pages before reusing the context
LA r1,@ctxScratch
MOVI r2,0
CALL @npaged_trim
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; primary tree step 1: 2 tokens, guaranteed depth-2 accept
MOVI r1,0x68
CALL @stage
LA r1,@ntA
MOVI r2,1
CALL @nspectree_set_flags
CMP r1,r0
JMP[NE] @fail
LA r1,@ntA
LA r2,@toksA
LA r3,@logsA
MOVI r4,2
CALL @nspectree_generate
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
; ids/logits/cur equal to the 2-token plain reference
LA r1,@toksA
LA r2,@toksPlain2
MOVI r3,2
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@logsA
LA r2,@logsPlain2
MOVI r3,64
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@ntA
CALL @nspectree_cur_logits
CMP r1,r0
JMP[EQ] @fail
LA r2,@cur2save
MOVI r3,32
CALL @cmpw
CMP r1,r0
JMP[NE] @fail

; stats after step 1
LA r1,@ntA
LA r2,@stA
CALL @nspectree_stats
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@stA+0
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+1
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+2
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+3
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+4
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+5
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+6
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+7
MOVI r2,6
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+16
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+18
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+21
MOVI r2,6
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+17
CMP r1,r0
JMP[EQ] @fail
LD r1,r0,@stA+9
CMP r1,r0
JMP[EQ] @fail

; accepted branch tags and generations
LA r1,@ntA
MOVI r2,0
LA r3,@cand
CALL @nspectree_cand
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@cand+0
LD r2,r0,@toksA+0
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@cand+1
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@cand+4           ; c0 generation before trim
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+10
LA r1,@ntA
MOVI r2,0
CALL @nspectree_branch_gen
LD r2,r0,@misc+10
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@cand+5           ; c0 tag
ST r1,r0,@misc+11
LA r1,@ntA
MOVI r2,1
LA r3,@cand
CALL @nspectree_cand
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@cand+4
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+12
LA r1,@ntA
MOVI r2,1
CALL @nspectree_branch_gen
LD r2,r0,@misc+12
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@cand+5
ST r1,r0,@misc+13
; record flags carry the tags on the promoted slots
LA r1,@ctxTree
MOVI r2,4
CALL @npaged_token_word
CMP r1,r0
JMP[EQ] @fail
LD r1,r1,3
LD r2,r0,@misc+11
CMP r1,r2
JMP[NE] @fail
LA r1,@ctxTree
MOVI r2,5
CALL @npaged_token_word
CMP r1,r0
JMP[EQ] @fail
LD r1,r1,3
LD r2,r0,@misc+13
CMP r1,r2
JMP[NE] @fail
; generation bump on the accepted branch
LA r1,@ctxTree
MOVI r2,4
CALL @npaged_token_gen
CMP r1,r0
JMP[EQ] @fail
LD r2,r0,@misc+10
CMP r1,r2
JMP[EQ] @fail
ST r1,r0,@misc+14
LA r1,@ctxTree
MOVI r2,4
LD r3,r0,@misc+10
CALL @npaged_check
CMP r1,r0
JMP[NE] @fail
LA r1,@ctxTree
MOVI r2,4
LD r3,r0,@misc+14
CALL @npaged_check
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LA r1,@ctxTree
MOVI r2,5
CALL @npaged_token_gen
LD r2,r0,@misc+12
CMP r1,r2
JMP[EQ] @fail

; per-branch masks after step 1 (prefix 4)
LA r1,@ntA
MOVI r2,0
CALL @nspectree_mask_len
MOVI r2,5
CMP r1,r2
JMP[NE] @fail
LA r1,@ntA
MOVI r2,0
MOVI r3,4
CALL @nspectree_mask
MOVI r4,4
CMP r1,r4
JMP[NE] @fail
LA r1,@ntA
MOVI r2,1
CALL @nspectree_mask_len
MOVI r2,6
CMP r1,r2
JMP[NE] @fail
LA r1,@ntA
MOVI r2,1
MOVI r3,5
CALL @nspectree_mask
MOVI r4,5
CMP r1,r4
JMP[NE] @fail
LA r1,@ntA
MOVI r2,3
CALL @nspectree_mask_len
MOVI r2,5
CMP r1,r2
JMP[NE] @fail
LA r1,@ntA
MOVI r2,3
MOVI r3,4
CALL @nspectree_mask
MOVI r4,7
CMP r1,r4
JMP[NE] @fail
LA r1,@ntA
MOVI r2,2
MOVI r3,5
CALL @nspectree_mask
MOVI r4,6
CMP r1,r4
JMP[NE] @fail
LA r1,@ntA
MOVI r2,4
MOVI r3,5
CALL @nspectree_mask
MOVI r4,8
CMP r1,r4
JMP[NE] @fail
LA r1,@ntA
MOVI r2,5
MOVI r3,5
CALL @nspectree_mask
MOVI r4,9
CMP r1,r4
JMP[NE] @fail
; rejected candidates are gone
LA r1,@ctxTree
MOVI r2,6
CALL @npaged_token_gen
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; primary tree step 2: two more tokens, boundary trim
MOVI r1,0x69
CALL @stage
LA r1,@ntA
LA r2,@toksA
ADDI r2,r2,2
LA r3,@logsA
ADDI r3,r3,64
MOVI r4,2
CALL @nspectree_generate
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
; full 4-token equality
LA r1,@toksA
LA r2,@toksB
MOVI r3,4
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@logsA
LA r2,@logsB
MOVI r3,128
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@ntA
CALL @nspectree_cur_logits
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+1
LA r1,@ntB
CALL @nspectree_cur_logits
LD r2,r0,@misc+1
MOVI r3,32
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
; final stats
LA r1,@ntA
LA r2,@stA
CALL @nspectree_stats
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@stA+1
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+2
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+3
MOVI r2,8
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+4
MOVI r2,8
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+5
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+6
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+7
MOVI r2,12
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+16
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+18
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+21
MOVI r2,8
CMP r1,r2
JMP[NE] @fail
; boundary trim kept block 1's generation: step-2 candidate gens == tokens
LA r1,@ntA
MOVI r2,0
LA r3,@cand
CALL @nspectree_cand
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@cand+3
MOVI r2,6
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@cand+4
ST r1,r0,@misc+15
LA r1,@ctxTree
MOVI r2,6
CALL @npaged_token_gen
LD r2,r0,@misc+15
CMP r1,r2
JMP[NE] @fail
; step-2 mask lengths over prefix 6
LA r1,@ntA
MOVI r2,0
CALL @nspectree_mask_len
MOVI r2,7
CMP r1,r2
JMP[NE] @fail
LA r1,@ntA
MOVI r2,1
CALL @nspectree_mask_len
MOVI r2,8
CMP r1,r2
JMP[NE] @fail
LA r1,@ntA
MOVI r2,1
MOVI r3,7
CALL @nspectree_mask
MOVI r4,7
CMP r1,r4
JMP[NE] @fail

; trace: prefill first, verify/accept/reject/trim/promote/emit present
LA r1,@ntA
MOVI r2,0
LA r3,@ev
CALL @nspectree_trace
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@ev+0
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stA+8
MOVI r2,20
CMP r1,r2
JMP[LT] @fail
MOVI r7,0
ST r7,r0,@misc+20        ; seen-vk
ST r7,r0,@misc+21        ; seen-acc
ST r7,r0,@misc+22        ; seen-rej
ST r7,r0,@misc+23        ; seen-trim
ST r7,r0,@misc+24        ; seen-prom
ST r7,r0,@misc+25        ; seen-emit
MOVI r7,0
ST r7,r0,@misc+26
tr_l:
LD r7,r0,@misc+26
LD r8,r0,@stA+8
CMP r7,r8
JMP[GE] @tr_d
LA r1,@ntA
ADD r2,r7,r0
LA r3,@ev
CALL @nspectree_trace
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@ev+0
MOVI r2,4
CMP r1,r2
JMP[NE] @tr_5
MOVI r1,1
ST r1,r0,@misc+20
tr_5:
LD r1,r0,@ev+0
MOVI r2,5
CMP r1,r2
JMP[NE] @tr_6
MOVI r1,1
ST r1,r0,@misc+21
tr_6:
LD r1,r0,@ev+0
MOVI r2,6
CMP r1,r2
JMP[NE] @tr_7
MOVI r1,1
ST r1,r0,@misc+22
tr_7:
LD r1,r0,@ev+0
MOVI r2,7
CMP r1,r2
JMP[NE] @tr_8
MOVI r1,1
ST r1,r0,@misc+23
tr_8:
LD r1,r0,@ev+0
MOVI r2,8
CMP r1,r2
JMP[NE] @tr_9
MOVI r1,1
ST r1,r0,@misc+24
tr_9:
LD r1,r0,@ev+0
MOVI r2,9
CMP r1,r2
JMP[NE] @tr_n
MOVI r1,1
ST r1,r0,@misc+25
tr_n:
LD r7,r0,@misc+26
ADD r7,r7,r13
ST r7,r0,@misc+26
JMP @tr_l
tr_d:
LD r1,r0,@misc+20
CMP r1,r0
JMP[EQ] @fail
LD r1,r0,@misc+21
CMP r1,r0
JMP[EQ] @fail
LD r1,r0,@misc+22
CMP r1,r0
JMP[EQ] @fail
LD r1,r0,@misc+23
CMP r1,r0
JMP[EQ] @fail
LD r1,r0,@misc+24
CMP r1,r0
JMP[EQ] @fail
LD r1,r0,@misc+25
CMP r1,r0
JMP[EQ] @fail

; ---------------------------------------------------------------------------
; deterministic rerun on a fresh context
MOVI r1,0x6A
CALL @stage
LA r1,@ntC
MOVI r2,1
CALL @nspectree_set_flags
CMP r1,r0
JMP[NE] @fail
LA r1,@ntC
LA r2,@toksC
LA r3,@logsC
MOVI r4,2
CALL @nspectree_generate
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LA r1,@ntC
LA r2,@toksC
ADDI r2,r2,2
LA r3,@logsC
ADDI r3,r3,64
MOVI r4,2
CALL @nspectree_generate
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LA r1,@toksC
LA r2,@toksA
MOVI r3,4
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@logsC
LA r2,@logsA
MOVI r3,128
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@ntC
CALL @nspectree_cur_logits
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+2
LA r1,@ntA
CALL @nspectree_cur_logits
LD r2,r0,@misc+2
MOVI r3,32
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@ntC
LA r2,@stC
CALL @nspectree_stats
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@stC+9
LD r2,r0,@stA+9
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stC+8
LD r2,r0,@stA+8
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stC+2
LD r2,r0,@stA+2
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stC+3
LD r2,r0,@stA+3
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stC+4
LD r2,r0,@stA+4
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stC+5
LD r2,r0,@stA+5
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stC+16
LD r2,r0,@stA+16
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stC+17
LD r2,r0,@stA+17
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stC+18
LD r2,r0,@stA+18
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stC+7
LD r2,r0,@stA+7
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; alternate root B promotion: re-init the scratch context
MOVI r1,0x6B
CALL @stage
LA r1,@ctxScratch
MOVI r2,0
CALL @npaged_trim
CMP r1,r0
JMP[NE] @fail
LA r1,@ctxScratch
LA r2,@hctx
LA r3,@tabScratch
MOVI r4,8
LA r5,@npcfg
CALL @npaged_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
LA r2,@ctxScratch
LA r3,@cfgNatt
LA r4,@ntcfgAlt
CALL @nspectree_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
LA r2,@toktab
MOVI r3,4
MOVI r4,3
CALL @nspectree_prefill
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
MOVI r2,2
CALL @nspectree_set_flags
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
LA r2,@toksD
LA r3,@logsD
MOVI r4,2
CALL @nspectree_generate
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LA r1,@toksD
LA r2,@toksPlain2
MOVI r3,2
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@logsD
LA r2,@logsPlain2
MOVI r3,64
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
CALL @nspectree_cur_logits
CMP r1,r0
JMP[EQ] @fail
LA r2,@cur2save
MOVI r3,32
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
LA r2,@stD
CALL @nspectree_stats
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@stD+2
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stD+3
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stD+4
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stD+16
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stD+18
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
; the accepted root was candidate 3 and its child candidate 4, relocated
LA r1,@ntD
MOVI r2,3
LA r3,@cand
CALL @nspectree_cand
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@cand+4
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+30
LD r1,r0,@cand+5
ST r1,r0,@misc+31
LA r1,@ntD
MOVI r2,4
LA r3,@cand
CALL @nspectree_cand
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@cand+5
ST r1,r0,@misc+32
; relocated tags at slots 4 and 5
LA r1,@ctxScratch
MOVI r2,4
CALL @npaged_token_word
CMP r1,r0
JMP[EQ] @fail
LD r1,r1,3
LD r2,r0,@misc+31
CMP r1,r2
JMP[NE] @fail
LA r1,@ctxScratch
MOVI r2,5
CALL @npaged_token_word
CMP r1,r0
JMP[EQ] @fail
LD r1,r1,3
LD r2,r0,@misc+32
CMP r1,r2
JMP[NE] @fail
; promotion bumped the generation
LA r1,@ctxScratch
MOVI r2,4
CALL @npaged_token_gen
CMP r1,r0
JMP[EQ] @fail
LD r2,r0,@misc+30
CMP r1,r2
JMP[EQ] @fail
; rejected DFS slots are gone
LA r1,@ctxScratch
MOVI r2,6
CALL @npaged_token_gen
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; forced-partial: depth-1 accept + free verifier token
MOVI r1,0x6C
CALL @stage
LA r1,@ctxScratch
MOVI r2,0
CALL @npaged_trim
CMP r1,r0
JMP[NE] @fail
LA r1,@ctxScratch
LA r2,@hctx
LA r3,@tabScratch
MOVI r4,8
LA r5,@npcfg
CALL @npaged_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
LA r2,@ctxScratch
LA r3,@cfgNatt
LA r4,@ntcfgPart
CALL @nspectree_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
LA r2,@toktab
MOVI r3,4
MOVI r4,3
CALL @nspectree_prefill
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
MOVI r2,5
CALL @nspectree_set_flags
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
LA r2,@toksD
LA r3,@logsD
MOVI r4,2
CALL @nspectree_generate
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LA r1,@toksD
LA r2,@toksPlain2
MOVI r3,2
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@logsD
LA r2,@logsPlain2
MOVI r3,64
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
CALL @nspectree_cur_logits
CMP r1,r0
JMP[EQ] @fail
LA r2,@cur2save
MOVI r3,32
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
LA r2,@stD
CALL @nspectree_stats
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@stD+2
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stD+3
MOVI r2,5
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stD+4
MOVI r2,5
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stD+16
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stD+18
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
; accepted root keeps its branch tag; the free append has the default flag
LA r1,@ntD
MOVI r2,0
LA r3,@cand
CALL @nspectree_cand
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@cand+5
ST r1,r0,@misc+33
LA r1,@ctxScratch
MOVI r2,4
CALL @npaged_token_word
CMP r1,r0
JMP[EQ] @fail
LD r1,r1,3
LD r2,r0,@misc+33
CMP r1,r2
JMP[NE] @fail
LA r1,@ctxScratch
MOVI r2,5
CALL @npaged_token_word
CMP r1,r0
JMP[EQ] @fail
LD r1,r1,3
MOVI r2,1
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; forced-no-root: reject all six, two sequential verifier appends
MOVI r1,0x6D
CALL @stage
LA r1,@ctxScratch
MOVI r2,0
CALL @npaged_trim
CMP r1,r0
JMP[NE] @fail
LA r1,@ctxScratch
LA r2,@hctx
LA r3,@tabScratch
MOVI r4,8
LA r5,@npcfg
CALL @npaged_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
LA r2,@ctxScratch
LA r3,@cfgNatt
LA r4,@ntcfgZero
CALL @nspectree_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
LA r2,@toktab
MOVI r3,4
MOVI r4,3
CALL @nspectree_prefill
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
MOVI r2,8
CALL @nspectree_set_flags
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
LA r2,@toksD
LA r3,@logsD
MOVI r4,2
CALL @nspectree_generate
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LA r1,@toksD
LA r2,@toksPlain2
MOVI r3,2
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@logsD
LA r2,@logsPlain2
MOVI r3,64
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
CALL @nspectree_cur_logits
CMP r1,r0
JMP[EQ] @fail
LA r2,@cur2save
MOVI r3,32
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@ntD
LA r2,@stD
CALL @nspectree_stats
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@stD+2
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@stD+3
MOVI r2,6
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stD+4
MOVI r2,6
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@stD+16
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@stD+17
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@stD+18
CMP r1,r0
JMP[NE] @fail
; both emitted tokens are plain records with the default flag
LA r1,@ctxScratch
MOVI r2,4
CALL @npaged_token_word
CMP r1,r0
JMP[EQ] @fail
LD r1,r1,3
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LA r1,@ctxScratch
MOVI r2,5
CALL @npaged_token_word
CMP r1,r0
JMP[EQ] @fail
LD r1,r1,3
MOVI r2,1
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; fail-closed API checks
; odd count is rejected before any work
LA r1,@ntA
LA r2,@toksA
LA r3,@logsA
MOVI r4,3
CALL @nspectree_generate
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail
; prefill is only valid on a fresh paged context
LA r1,@ntA
LA r2,@toktab
MOVI r3,4
MOVI r4,3
CALL @nspectree_prefill
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail
; mask index beyond the length fails closed
LA r1,@ntA
MOVI r2,0
MOVI r3,9
CALL @nspectree_mask
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
MOVI r1,79
PUTC r1
HALT

fail:
LA r2,@misc+40
LD r1,r2,0
PUTC r1
MOVI r1,70
PUTC r1
HALT

; ---------------------------------------------------------------------------
; helpers
stage:
  LA r2,@misc+40
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

; anynz r1=vec r2=n -> 1 if any word nonzero
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

; mk_id_q4 r1=dst r2=rows (identity Q4_0 with scale 1.0)
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

; mk_id_q8 r1=dst r2=rows
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

; mk_row1 r1=w r2=row r3=col
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

; gen_rope: 32 positions x 16 pairs, exact binary fractions
gen_rope:
  MOVI r7,0
  ST r7,r0,@ts+0
gr_p:
  LD r7,r0,@ts+0
  MOVI r8,32
  CMP r7,r8
  JMP[GE] @gr_d
  MOVI r9,0
  ST r9,r0,@ts+1
gr_i:
  LD r9,r0,@ts+1
  MOVI r10,16
  CMP r9,r10
  JMP[GE] @gr_id
  MOVI r10,16
  MUL r10,r7,r10
  ADD r10,r10,r9
  SHL r10,r10,1
  LA r11,@rtab
  ADD r11,r11,r10
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
  RET

; gen_toktab: 8 token vectors, 32 words each
gen_toktab:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,@ts+0
  MOVI r7,0
  ST r7,r0,@ts+1
gt_l:
  LD r7,r0,@ts+1
  MOVI r8,8
  CMP r7,r8
  JMP[GE] @gt_d
  LD r9,r0,@ts+0
  SHL r10,r7,5
  ADD r9,r9,r10
  ST r9,r0,@ts+2
  ADD r1,r9,r0
  MOVI r2,32
  CALL @zfill
  LD r7,r0,@ts+1
  MOVI r8,3
  MUL r8,r7,r8
  MOVI r10,31
  BOOL.8 r8,r8,r10
  ST r8,r0,@ts+3
  MOVI r9,5
  MUL r9,r7,r9
  MOVI r10,7
  ADD r9,r9,r10
  MOVI r10,31
  BOOL.8 r9,r9,r10
  ST r9,r0,@ts+4
  MOVI r10,3
  MODU r10,r7,r10
  ST r10,r0,@ts+5
  LD r1,r0,@ts+2
  LD r2,r0,@ts+3
  ADD r1,r1,r2
  LD r3,r0,@ts+5
  ADD r3,r3,r13
  CVTIF r3,r3
  ST r3,r1,0
  LD r1,r0,@ts+2
  LD r2,r0,@ts+4
  ADD r1,r1,r2
  MOVI r3,3
  LD r4,r0,@ts+5
  SUB r3,r3,r4
  CVTIF r3,r3
  ST r3,r1,0
  LD r7,r0,@ts+1
  ADD r7,r7,r13
  ST r7,r0,@ts+1
  JMP @gt_l
gt_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; gen_drafttab: 8x8 f32 scores, score = ((p*3+j*5)%7)-3
gen_drafttab:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,@ts+0
  MOVI r7,0
  ST r7,r0,@ts+1
gd_p:
  LD r7,r0,@ts+1
  MOVI r8,8
  CMP r7,r8
  JMP[GE] @gd_d
  MOVI r9,0
  ST r9,r0,@ts+2
gd_j:
  LD r9,r0,@ts+2
  MOVI r10,8
  CMP r9,r10
  JMP[GE] @gd_jd
  MOVI r10,3
  MUL r10,r7,r10
  MOVI r11,5
  MUL r11,r9,r11
  ADD r10,r10,r11
  MOVI r11,7
  MODU r10,r10,r11
  ADDI r10,r10,-3
  CVTIF r10,r10
  MOVI r11,8
  MUL r11,r7,r11
  ADD r11,r11,r9
  LD r12,r0,@ts+0
  ADD r12,r12,r11
  ST r10,r12,0
  LD r9,r0,@ts+2
  ADD r9,r9,r13
  ST r9,r0,@ts+2
  JMP @gd_j
gd_jd:
  LD r7,r0,@ts+1
  ADD r7,r7,r13
  ST r7,r0,@ts+1
  JMP @gd_p
gd_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
