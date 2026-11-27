; ntok_test.nas - deterministic byte-level tokenizer + 24-merge BPE (F7).
;
; Proves:
;  - BOS=256, EOS=257, UNK=282, vocab=283, 24 ordered merges;
;  - exact encodings: "hello" -> [266], "the theory" -> [262,261,111,114,121],
;    "banana" -> [98,267,267,97], "is an and" -> [279,280,276];
;  - encode/decode round-trip for ASCII, NUL/high bytes and all 256 bytes;
;  - BOS/EOS are skipped by decode, UNK decodes to '?', invalid ids fail;
;  - ntok_id_bytes returns 5 for the merged "hello", 0 for BOS, -1 invalid.
; A single serial 'O' means all checks passed.
.org 0
JMP @main
.org 0x4000
.include "../lib/ntok.nas"

.equ TST 0x5300

main:
MOVI r13,1
MOVI r14,0x7000

; ---------------------------------------------------------------------------
MOVI r1,0x31
CALL @stage
CALL @ntok_bos
MOVI r2,256
CMP r1,r2
JMP[NE] @fail
CALL @ntok_eos
MOVI r2,257
CMP r1,r2
JMP[NE] @fail
CALL @ntok_unk
MOVI r2,282
CMP r1,r2
JMP[NE] @fail
CALL @ntok_vocab_size
MOVI r2,283
CMP r1,r2
JMP[NE] @fail
CALL @ntok_merge_count
MOVI r2,24
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; "hello" -> [266]
MOVI r1,0x32
CALL @stage
LA r1,@s_hello
MOVI r2,5
CALL @encstr
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LA r4,@ids
LD r1,r4,0
MOVI r2,266
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; "the theory" -> [262,261,111,114,121]
MOVI r1,0x33
CALL @stage
LA r1,@s_theory
MOVI r2,10
CALL @encstr
MOVI r2,5
CMP r1,r2
JMP[NE] @fail
LA r4,@ids
LD r1,r4,0
MOVI r2,262
CMP r1,r2
JMP[NE] @fail
LD r1,r4,1
MOVI r2,261
CMP r1,r2
JMP[NE] @fail
LD r1,r4,2
MOVI r2,111
CMP r1,r2
JMP[NE] @fail
LD r1,r4,3
MOVI r2,114
CMP r1,r2
JMP[NE] @fail
LD r1,r4,4
MOVI r2,121
CMP r1,r2
JMP[NE] @fail

; "banana" -> [98,267,267,97]
LA r1,@s_banana
MOVI r2,6
CALL @encstr
MOVI r2,4
CMP r1,r2
JMP[NE] @fail
LA r4,@ids
LD r1,r4,0
MOVI r2,98
CMP r1,r2
JMP[NE] @fail
LD r1,r4,1
MOVI r2,267
CMP r1,r2
JMP[NE] @fail
LD r1,r4,2
MOVI r2,267
CMP r1,r2
JMP[NE] @fail
LD r1,r4,3
MOVI r2,97
CMP r1,r2
JMP[NE] @fail

; "is an and" -> [279,280,276]
LA r1,@s_isand
MOVI r2,9
CALL @encstr
MOVI r2,3
CMP r1,r2
JMP[NE] @fail
LA r4,@ids
LD r1,r4,0
MOVI r2,279
CMP r1,r2
JMP[NE] @fail
LD r1,r4,1
MOVI r2,280
CMP r1,r2
JMP[NE] @fail
LD r1,r4,2
MOVI r2,276
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; round-trip strings, including NUL and high bytes
MOVI r1,0x34
CALL @stage
LA r1,@s_hello
MOVI r2,5
CALL @roundtrip
CMP r1,r0
JMP[EQ] @fail
LA r1,@s_theory
MOVI r2,10
CALL @roundtrip
CMP r1,r0
JMP[EQ] @fail
LA r1,@s_banana
MOVI r2,6
CALL @roundtrip
CMP r1,r0
JMP[EQ] @fail
LA r1,@s_isand
MOVI r2,9
CALL @roundtrip
CMP r1,r0
JMP[EQ] @fail
LA r1,@s_bin
MOVI r2,5
CALL @roundtrip
CMP r1,r0
JMP[EQ] @fail
LA r1,@s_hello_world
MOVI r2,11
CALL @roundtrip
CMP r1,r0
JMP[EQ] @fail

; "hello world" -> [266,32,119,111,114,108,100]
LA r1,@s_hello_world
MOVI r2,11
CALL @encstr
MOVI r2,7
CMP r1,r2
JMP[NE] @fail
LA r4,@ids
LD r1,r4,0
MOVI r2,266
CMP r1,r2
JMP[NE] @fail
LD r1,r4,1
MOVI r2,32
CMP r1,r2
JMP[NE] @fail
LD r1,r4,6
MOVI r2,100
CMP r1,r2
JMP[NE] @fail

; ---------------------------------------------------------------------------
; all 256 byte values round-trip (input has no matching merge pairs)
MOVI r1,0x35
CALL @stage
LA r1,@allbytes
SHL r1,r1,2
MOVI r2,256
LA r3,@ids
MOVI r4,256
CALL @ntok_encode
MOVI r2,256
CMP r1,r2
JMP[NE] @fail
LA r1,@ids
MOVI r2,256
LA r3,@decbuf
SHL r3,r3,2
MOVI r4,256
CALL @ntok_decode
MOVI r2,256
CMP r1,r2
JMP[NE] @fail
LA r1,@decbuf
SHL r1,r1,2
LA r2,@allbytes
SHL r2,r2,2
MOVI r3,256
CALL @cmpbytes
CMP r1,r0
JMP[EQ] @fail

; ---------------------------------------------------------------------------
; BOS/EOS are skipped: [BOS, "hello", EOS] decodes to "hello"
MOVI r1,0x36
CALL @stage
LA r4,@ids
MOVI r1,256
ST r1,r4,0
MOVI r1,266
ST r1,r4,1
MOVI r1,257
ST r1,r4,2
LA r1,@ids
MOVI r2,3
LA r3,@decbuf
SHL r3,r3,2
MOVI r4,256
CALL @ntok_decode
MOVI r2,5
CMP r1,r2
JMP[NE] @fail
LA r1,@decbuf
SHL r1,r1,2
LA r2,@s_hello
SHL r2,r2,2
MOVI r3,5
CALL @cmpbytes
CMP r1,r0
JMP[EQ] @fail

; ---------------------------------------------------------------------------
; UNK / invalid / id lengths
MOVI r1,0x37
CALL @stage
MOVI r1,#NTK_UNK
LA r2,@decbuf
SHL r2,r2,2
MOVI r3,8
CALL @ntok_decode_token
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
LA r4,@decbuf
SHL r4,r4,2
LDB r1,r4,0
MOVI r2,0x3F
CMP r1,r2
JMP[NE] @fail
MOVI r1,0x61
CALL @stage
MOVI r1,999
LA r2,@decbuf
SHL r2,r2,2
MOVI r3,8
CALL @ntok_decode_token
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail
MOVI r1,0x62
CALL @stage
MOVI r1,266
CALL @ntok_id_bytes
MOVI r2,5
CMP r1,r2
JMP[NE] @fail
CALL @ntok_bos
CALL @ntok_id_bytes
CMP r1,r0
JMP[NE] @fail
MOVI r1,999
CALL @ntok_id_bytes
LA r2,0xFFFFFFFF
CMP r1,r2
JMP[NE] @fail
MOVI r1,0x63
CALL @stage
CALL @ntok_bos
CALL @ntok_is_special
MOVI r2,1
CMP r1,r2
JMP[NE] @fail
MOVI r1,266
CALL @ntok_is_special
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

stage:
LA r2,@stagev
ST r1,r2,0
RET

; r1=string word addr r2=len -> token count, ids at @ids
encstr:
  ST r15,r14,0
  ADD r14,r14,r13
  SHL r1,r1,2
  LA r3,@ids
  MOVI r4,256
  CALL @ntok_encode
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; r1=string word addr r2=len -> 1 if encode+decode reproduces the bytes
roundtrip:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#TST+0
  ST r2,r0,#TST+1
  SHL r1,r1,2
  LD r2,r0,#TST+1
  LA r3,@ids
  MOVI r4,256
  CALL @ntok_encode
  CMP r1,r0
  JMP[LT] @rt_bad
  ST r1,r0,#TST+2
  LA r1,@ids
  LD r2,r0,#TST+2
  LA r3,@decbuf
  SHL r3,r3,2
  MOVI r4,256
  CALL @ntok_decode
  CMP r1,r0
  JMP[LT] @rt_bad
  LD r2,r0,#TST+1
  CMP r1,r2
  JMP[NE] @rt_bad
  LA r1,@decbuf
  SHL r1,r1,2
  LD r2,r0,#TST+0
  SHL r2,r2,2
  LD r3,r0,#TST+1
  CALL @cmpbytes
  JMP @rt_out
rt_bad:
  MOVI r1,0
rt_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; compare r3 bytes at actual byte addr r1 vs expected byte addr r2 -> 1/0
cmpbytes:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#TST+8
  ST r2,r0,#TST+9
  ST r3,r0,#TST+10
  ST r0,r0,#TST+11
cb_l:
  LD r1,r0,#TST+11
  LD r2,r0,#TST+10
  CMP r1,r2
  JMP[GE] @cb_yes
  LD r1,r0,#TST+8
  LD r2,r0,#TST+11
  ADD r1,r1,r2
  LDB r3,r1,0
  LD r1,r0,#TST+9
  ADD r1,r1,r2
  LDB r4,r1,0
  CMP r3,r4
  JMP[NE] @cb_no
  LD r1,r0,#TST+11
  ADD r1,r1,r13
  ST r1,r0,#TST+11
  JMP @cb_l
cb_yes:
  MOVI r1,1
  JMP @cb_out
cb_no:
  MOVI r1,0
cb_out:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
.org 0x9000
s_hello:
.str "hello"
s_theory:
.str "the theory"
s_banana:
.str "banana"
s_isand:
.str "is an and"
s_bin:
.str "hi\x00\xff\x80"
s_hello_world:
.str "hello world"
allbytes:
.word 0x03020100, 0x07060504, 0x0B0A0908, 0x0F0E0D0C, 0x13121110, 0x17161514, 0x1B1A1918, 0x1F1E1D1C
.word 0x23222120, 0x27262524, 0x2B2A2928, 0x2F2E2D2C, 0x33323130, 0x37363534, 0x3B3A3938, 0x3F3E3D3C
.word 0x43424140, 0x47464544, 0x4B4A4948, 0x4F4E4D4C, 0x53525150, 0x57565554, 0x5B5A5958, 0x5F5E5D5C
.word 0x63626160, 0x67666564, 0x6B6A6968, 0x6F6E6D6C, 0x73727170, 0x77767574, 0x7B7A7978, 0x7F7E7D7C
.word 0x83828180, 0x87868584, 0x8B8A8988, 0x8F8E8D8C, 0x93929190, 0x97969594, 0x9B9A9998, 0x9F9E9D9C
.word 0xA3A2A1A0, 0xA7A6A5A4, 0xABAAA9A8, 0xAFAEADAC, 0xB3B2B1B0, 0xB7B6B5B4, 0xBBBAB9B8, 0xBFBEBDBC
.word 0xC3C2C1C0, 0xC7C6C5C4, 0xCBCAC9C8, 0xCFCECDCC, 0xD3D2D1D0, 0xD7D6D5D4, 0xDBDAD9D8, 0xDFDEDDDC
.word 0xE3E2E1E0, 0xE7E6E5E4, 0xEBEAE9E8, 0xEFEEEDEC, 0xF3F2F1F0, 0xF7F6F5F4, 0xFBFAF9F8, 0xFFFEFDFC
ids:
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
decbuf:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
stagev:
.word 0
