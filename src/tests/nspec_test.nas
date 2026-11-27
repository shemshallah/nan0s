; nspec_test.nas - speculative vs plain decode equality + paged KV rollback.
;
; Pure NaN, no C harness.  One immutable nattn weight root, two npaged
; contexts per run: a plain reference decode (npaged_decode) and a
; speculative decode (nspec draft table + exact verifier + npaged_trim
; rollback).  For prompt tokens 0..3, verifier seed 1 and draft seed
; 0x12345678, the test proves:
;
;  - a forced-rejection first step actually appends a deliberately wrong
;    draft, rejects it, trims the paged KV back to the accepted prefix and
;    bumps the block generation; the stale generation fails npaged_check and
;    the new generation passes;
;  - 16 generated token ids, 16*32 pre-sample logits and the final next-token
;    logits are bit-equal between the speculative path and plain decode;
;  - accepted + rejected == generated, rejected == rollbacks,
;    verifier passes == generated + rejected, drafts == generated;
;  - the hash-chained trace records prefill/draft/reject/rollback/emit events
;    and a full rerun with the same seed reproduces the same token ids,
;    logits, stats and trace head;
;  - npaged_trim itself: multi-block release to nheap, in-block generation
;    bump with retained-record rewrite, boundary trim without a bump,
;    trim-above-used failure, re-append and trim-to-zero.
;
; Success prints exactly O.

.org 0
JMP @main

; ---------------------------------------------------------------------------
; data at 0x9000 words, code at 0x10000 (above library scratch)
.org 0x9000
hctx:
.org 0x9010
hdescs:
.org 0x9110
hlists:
.org 0x9120
ctx_s:
.org 0x9140
ctx_p:
.org 0x9160
ctx_s2:
.org 0x9180
ctx_t:
.org 0x91A0
tab_s:
.org 0x9220
tab_p:
.org 0x92A0
tab_s2:
.org 0x9320
tab_t:
.org 0x9360
ns_s:
.org 0x9400
ns_p:
.org 0x94A0
ns_s2:
.org 0x9560
nscfg:
.org 0x9580
nscfg2:
.org 0x95A0
npcfg:
.org 0x95B0
npcfg_t:
.org 0x95C0
misc:
.org 0x95D0
ts:
.org 0x95F0
dat:
.org 0x9600
toks_p:
.org 0x9620
toks_s:
.org 0x9640
toks_s2:
.org 0x9660
st:
.org 0x9670
st2:
.org 0x9680
ev:
.org 0x9690
logs_p:
.org 0x9890
logs_s:
.org 0x9A90
logs_s2:
.org 0x9CA0
trace_s:
.org 0x9EA0
trace_s2:
.org 0xA0C0
cfg:
.org 0xA0E0
wq:
.org 0xA180
wk:
.org 0xA220
wv:
.org 0xA2C0
wo:
.org 0xA380
nw:
.org 0xA3A0
rtab:
.org 0xA7A0
toktab:
.org 0xA8A0
drafttab:
.org 0xA8E0
vbuf:
.org 0xA900
q4c:
.org 0xA940
q8c:

.org 0x10000
.include "../lib/nspec.nas"

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

; nspec cfg: vocab 8, K 4, temp 0.5, verifier seed 1, draft seed 0x12345678
LA r1,@nscfg
LA r2,0x4643534E
ST r2,r1,0
MOVI r2,1
ST r2,r1,1
MOVI r2,8
ST r2,r1,2
MOVI r2,4
ST r2,r1,3
LA r2,0x3F000000
ST r2,r1,4
ST r0,r1,5
MOVI r2,1
ST r2,r1,6
LA r2,0x12345678
ST r2,r1,7
LA r2,@drafttab
ST r2,r1,8
LA r2,@toktab
ST r2,r1,9
LA r2,@trace_s
ST r2,r1,10
MOVI r2,128
ST r2,r1,11
LA r2,@cfg
ST r2,r1,12
; cfg2 is identical except for the trace buffer
LA r1,@nscfg
LA r2,@nscfg2
MOVI r3,13
CALL @copyw
LA r2,@nscfg2
LA r1,@trace_s2
ST r1,r2,10

; npaged init configs
LA r1,@npcfg
MOVI r2,1
ST r2,r1,0
MOVI r2,1
ST r2,r1,1
ST r0,r1,2
MOVI r2,32
ST r2,r1,3
MOVI r2,8
ST r2,r1,4
MOVI r2,40
ST r2,r1,5
ST r0,r1,6
ST r0,r1,7
LA r1,@npcfg_t
MOVI r2,4
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
; paged contexts: spec, plain, spec-rerun (8 blocks x 8 tokens = 64 tokens)
MOVI r1,0x64
CALL @stage
LA r1,@ctx_s
LA r2,@hctx
LA r3,@tab_s
MOVI r4,8
LA r5,@npcfg
CALL @npaged_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ctx_p
LA r2,@hctx
LA r3,@tab_p
MOVI r4,8
LA r5,@npcfg
CALL @npaged_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ctx_s2
LA r2,@hctx
LA r3,@tab_s2
MOVI r4,8
LA r5,@npcfg
CALL @npaged_init
CMP r1,r0
JMP[NE] @fail
; trim context: 4 blocks x 4 tokens = 16 tokens
LA r1,@ctx_t
LA r2,@hctx
LA r3,@tab_t
MOVI r4,4
LA r5,@npcfg_t
CALL @npaged_init
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; nspec contexts
LA r1,@ns_s
LA r2,@ctx_s
LA r3,@nscfg
CALL @nspec_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ns_p
LA r2,@ctx_p
LA r3,@nscfg
CALL @nspec_init
CMP r1,r0
JMP[NE] @fail
LA r1,@ns_s2
LA r2,@ctx_s2
LA r3,@nscfg2
CALL @nspec_init
CMP r1,r0
JMP[NE] @fail

; xorshift recurrence pinned against nreplay nrng_next(1) = 0x00042021
MOVI r1,1
CALL @ns_xorshift
LA r2,0x00042021
CMP r1,r2
JMP[NE] @fail

; prefill prompt tokens 0,1,2,3 (x rows are contiguous in toktab)
MOVI r1,0x65
CALL @stage
LA r1,@ns_s
LA r2,@toktab
MOVI r3,4
MOVI r4,3
CALL @nspec_prefill
CMP r1,r0
JMP[NE] @fail
LA r1,@ns_p
LA r2,@toktab
MOVI r3,4
MOVI r4,3
CALL @nspec_prefill
CMP r1,r0
JMP[NE] @fail
LA r1,@ns_s2
LA r2,@toktab
MOVI r3,4
MOVI r4,3
CALL @nspec_prefill
CMP r1,r0
JMP[NE] @fail

; prefill logits must already be identical
LA r1,@ns_s
CALL @nspec_cur_logits
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+0
LA r1,@ns_p
CALL @nspec_cur_logits
LD r2,r0,@misc+0
MOVI r3,32
CALL @cmpw
CMP r1,r0
JMP[NE] @fail

; ---------------------------------------------------------------------------
; plain reference: 16 tokens
MOVI r1,0x66
CALL @stage
LA r1,@ns_p
LA r2,@toks_p
LA r3,@logs_p
MOVI r4,16
CALL @nspec_generate_plain
MOVI r2,16
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; speculative step 1 is forced to reject its first draft: the wrong token is
; appended, verified, trimmed and replaced with the verifier's token
MOVI r1,0x67
CALL @stage
LA r1,@ctx_s
MOVI r2,3
CALL @npaged_token_gen
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+1          ; old generation of accepted token 3
LA r1,@ns_s
MOVI r2,1
CALL @nspec_set_flags
CMP r1,r0
JMP[NE] @fail
LA r1,@ns_s
LA r2,@toks_s
LA r3,@logs_s
MOVI r4,1
CALL @nspec_generate
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LA r1,@ns_s
LA r2,@st
CALL @nspec_stats
CMP r1,r0
JMP[NE] @fail
; forced step: generated 1, accepted 0, rejected 1, rollback 1, pass 2,
; drafts 1, steps 1, forced 1, flags 0
LD r1,r0,@st+1
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+2
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@st+3
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+4
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+5
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+6
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+7
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+14
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@st+15
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
; trace has prefill + draft + reject + rollback + emit = 5 events
LD r1,r0,@st+8
MOVI r2,5
CMP r1,r2
JMP[NE] @fail
; generation bump on the accepted prefix
LA r1,@ctx_s
MOVI r2,3
CALL @npaged_token_gen
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+2          ; new generation
LD r2,r0,@misc+1
CMP r1,r2
JMP[EQ] @fail
LA r1,@ctx_s
MOVI r2,3
LD r3,r0,@misc+1
CALL @npaged_check
CMP r1,r0
JMP[NE] @fail
LA r1,@ctx_s
MOVI r2,3
LD r3,r0,@misc+2
CALL @npaged_check
MOVI r2,1
CMP r1,r2
JMP[NE] @fail

; 15 more speculative tokens
MOVI r1,0x68
CALL @stage
LA r1,@ns_s
LA r2,@toks_s
ADDI r2,r2,1
LA r3,@logs_s
ADDI r3,r3,32
MOVI r4,15
CALL @nspec_generate
MOVI r2,15
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; exact equality: tokens, all 16 pre-sample logits, final next-token logits
MOVI r1,0x69
CALL @stage
LA r1,@toks_p
LA r2,@toks_s
MOVI r3,16
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@logs_p
LA r2,@logs_s
MOVI r3,512
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@ns_s
CALL @nspec_cur_logits
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+0
LA r1,@ns_p
CALL @nspec_cur_logits
LD r2,r0,@misc+0
MOVI r3,32
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
; non-vacuous logits
LA r1,@logs_s
MOVI r2,512
CALL @anynz
CMP r1,r0
JMP[EQ] @fail
; every generated id is inside the 8-token vocabulary
MOVI r7,0
ST r7,r0,@misc+3
voc_l:
LD r7,r0,@misc+3
MOVI r8,16
CMP r7,r8
JMP[GE] @voc_d
LA r1,@toks_s
ADD r1,r1,r7
LD r1,r1,0
MOVI r2,8
CMP r1,r2
JMP[GE] @fail
LD r7,r0,@misc+3
ADD r7,r7,r13
ST r7,r0,@misc+3
JMP @voc_l
voc_d:

; npaged token counts are equal (20 = 4 prompt + 16 generated)
LA r1,@ctx_s
LA r2,@st
CALL @npaged_stats
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@st+0
MOVI r2,20
CMP r1,r2
JMP[NE] @fail
LA r1,@ctx_p
LA r2,@st2
CALL @npaged_stats
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@st2+0
MOVI r2,20
CMP r1,r2
JMP[NE] @fail

; speculative counters
LA r1,@ns_s
LA r2,@st
CALL @nspec_stats
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@st+0
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+1
MOVI r2,16
CMP r1,r2
JMP[NE] @fail
LD r4,r0,@st+2           ; accepted
LD r5,r0,@st+3           ; rejected
LD r6,r0,@st+4           ; rollbacks
LD r7,r0,@st+5           ; passes
LD r8,r0,@st+6           ; drafts
LD r9,r0,@st+7           ; steps
ADD r1,r4,r5
MOVI r2,16
CMP r1,r2
JMP[NE] @fail
CMP r5,r6
JMP[NE] @fail
CMP r5,r0
JMP[LE] @fail
MOVI r1,16
ADD r1,r1,r5
CMP r7,r1
JMP[NE] @fail
MOVI r2,16
CMP r8,r2
JMP[NE] @fail
CMP r9,r0
JMP[LE] @fail
CMP r4,r0
JMP[LE] @fail
LD r1,r0,@st+8
MOVI r2,5
CMP r1,r2
JMP[LT] @fail
LD r1,r0,@st+9
CMP r1,r0
JMP[EQ] @fail
LD r1,r0,@st+10
MOVI r2,8
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+11
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+14
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@st+15
MOVI r2,1
CMP r1,r2
JMP[NE] @fail

; first trace event is prefill; a rollback event (kind 6) is present
LA r1,@ns_s
MOVI r2,0
LA r3,@ev
CALL @nspec_trace
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@ev+0
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
MOVI r7,0
ST r7,r0,@misc+4
MOVI r7,0
ST r7,r0,@misc+5
tr_l:
LD r7,r0,@misc+4
LD r8,r0,@st+8
CMP r7,r8
JMP[GE] @tr_d
LA r1,@ns_s
ADD r2,r7,r0
LA r3,@ev
CALL @nspec_trace
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@ev+0
MOVI r2,6
CMP r1,r2
JMP[NE] @tr_n
MOVI r1,1
ST r1,r0,@misc+5
tr_n:
LD r7,r0,@misc+4
ADD r7,r7,r13
ST r7,r0,@misc+4
JMP @tr_l
tr_d:
LD r1,r0,@misc+5
CMP r1,r0
JMP[EQ] @fail

; ---------------------------------------------------------------------------
; deterministic rerun: same prompt/seed, same forced rejection, same output
MOVI r1,0x6A
CALL @stage
LA r1,@ns_s2
MOVI r2,1
CALL @nspec_set_flags
CMP r1,r0
JMP[NE] @fail
LA r1,@ns_s2
LA r2,@toks_s2
LA r3,@logs_s2
MOVI r4,1
CALL @nspec_generate
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LA r1,@ns_s2
LA r2,@toks_s2
ADDI r2,r2,1
LA r3,@logs_s2
ADDI r3,r3,32
MOVI r4,15
CALL @nspec_generate
MOVI r2,15
CMP r1,r2
JMP[NE] @fail
LA r1,@toks_s2
LA r2,@toks_s
MOVI r3,16
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@logs_s2
LA r2,@logs_s
MOVI r3,512
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@ns_s2
CALL @nspec_cur_logits
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+0
LA r1,@ns_s
CALL @nspec_cur_logits
LD r2,r0,@misc+0
MOVI r3,32
CALL @cmpw
CMP r1,r0
JMP[NE] @fail
LA r1,@ns_s2
LA r2,@st2
CALL @nspec_stats
CMP r1,r0
JMP[NE] @fail
; head, trace count and counters are identical
LD r1,r0,@st2+9
LD r2,r0,@st+9
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st2+8
LD r2,r0,@st+8
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st2+2
LD r2,r0,@st+2
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st2+3
LD r2,r0,@st+3
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st2+4
LD r2,r0,@st+4
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st2+5
LD r2,r0,@st+5
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st2+15
LD r2,r0,@st+15
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st2+7
LD r2,r0,@st+7
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st2+1
LD r2,r0,@st+1
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; npaged_trim: trim a 10-token context (4 tokens/block) to 6
MOVI r1,0x6B
CALL @stage
MOVI r7,0
ST r7,r0,@misc+6
trim_ap:
LD r7,r0,@misc+6
MOVI r8,10
CMP r7,r8
JMP[GE] @trim_apd
; x = toktab + toks_p[i]*32
LA r2,@toks_p
ADD r2,r2,r7
LD r2,r2,0
SHL r2,r2,5
LA r3,@toktab
ADD r2,r3,r2
ADD r3,r7,r0
LA r1,@ctx_t
LA r4,@cfg
CALL @npaged_append
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @fail
LD r7,r0,@misc+6
ADD r7,r7,r13
ST r7,r0,@misc+6
JMP @trim_ap
trim_apd:
; used 10, live 3, evicts 0
LA r1,@ctx_t
LA r2,@st
CALL @npaged_stats
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@st+0
MOVI r2,10
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+2
MOVI r2,3
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+4
CMP r1,r0
JMP[NE] @fail
; generation of token 5 before the trim
LA r1,@ctx_t
MOVI r2,5
CALL @npaged_token_gen
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+7
; trim to 6: block 2 freed, block 1 generation bumped
LA r1,@ctx_t
MOVI r2,6
CALL @npaged_trim
CMP r1,r0
JMP[NE] @fail
LA r1,@ctx_t
LA r2,@st
CALL @npaged_stats
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@st+0
MOVI r2,6
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+2
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+4
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
; token 5 survived with a new generation; token 8 is gone
LA r1,@ctx_t
MOVI r2,5
CALL @npaged_token_gen
CMP r1,r0
JMP[EQ] @fail
ST r1,r0,@misc+8
LD r2,r0,@misc+7
CMP r1,r2
JMP[EQ] @fail
LA r1,@ctx_t
MOVI r2,5
LD r3,r0,@misc+7
CALL @npaged_check
CMP r1,r0
JMP[NE] @fail
LA r1,@ctx_t
MOVI r2,5
LD r3,r0,@misc+8
CALL @npaged_check
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LA r1,@ctx_t
MOVI r2,8
CALL @npaged_token_gen
CMP r1,r0
JMP[NE] @fail
; trim above used fails; trim to used is a no-op
LA r1,@ctx_t
MOVI r2,7
CALL @npaged_trim
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail
LA r1,@ctx_t
MOVI r2,6
CALL @npaged_trim
CMP r1,r0
JMP[NE] @fail
; boundary trim to 4 frees block 1 without touching block 0's generation
LA r1,@ctx_t
MOVI r2,3
CALL @npaged_token_gen
ST r1,r0,@misc+9
LA r1,@ctx_t
MOVI r2,4
CALL @npaged_trim
CMP r1,r0
JMP[NE] @fail
LA r1,@ctx_t
LA r2,@st
CALL @npaged_stats
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@st+0
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+2
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LD r1,r0,@st+4
MOVI r2,2
CMP r1,r2
JMP[NE] @fail
LA r1,@ctx_t
MOVI r2,3
CALL @npaged_token_gen
LD r2,r0,@misc+9
CMP r1,r2
JMP[NE] @fail
; re-append at positions 4 and 5
LA r1,@toks_p
LD r2,r1,0
SHL r2,r2,5
LA r3,@toktab
ADD r2,r3,r2
LA r1,@ctx_t
MOVI r3,4
LA r4,@cfg
CALL @npaged_append
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @fail
LA r1,@toks_p
LD r2,r1,1
SHL r2,r2,5
LA r3,@toktab
ADD r2,r3,r2
LA r1,@ctx_t
MOVI r3,5
LA r4,@cfg
CALL @npaged_append
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[EQ] @fail
; trim to zero releases every page and restores the full capacity
LA r1,@ctx_t
MOVI r2,0
CALL @npaged_trim
CMP r1,r0
JMP[NE] @fail
LA r1,@ctx_t
CALL @npaged_remaining
MOVI r2,16
CMP r1,r2
JMP[NE] @fail
LA r1,@ctx_t
MOVI r2,0
CALL @npaged_token_gen
CMP r1,r0
JMP[NE] @fail
LA r1,@ctx_t
LA r2,@st
CALL @npaged_stats
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@st+0
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@st+2
CMP r1,r0
JMP[NE] @fail
LD r1,r0,@st+4
MOVI r2,4
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
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
  ; row = dst + t*32
  LD r9,r0,@ts+0
  SHL r10,r7,5
  ADD r9,r9,r10
  ST r9,r0,@ts+2
  ADD r1,r9,r0
  MOVI r2,32
  CALL @zfill
  LD r7,r0,@ts+1
  ; a = (t*3)&31, b = (t*5+7)&31, v = t%3
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
  ; row[a] = v+1
  LD r1,r0,@ts+2
  LD r2,r0,@ts+3
  ADD r1,r1,r2
  LD r3,r0,@ts+5
  ADD r3,r3,r13
  CVTIF r3,r3
  ST r3,r1,0
  ; row[b] = 3-v
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
