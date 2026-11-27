; nkcas_test.nas - content-addressed store persistence and cold hydration
; (F13k).
;
; Scenario, run twice from a cold init with a word-for-word snapshot compare:
;   build P (10 tokens over P0/P1), Q (first page dedups P0, Q1 8 tokens) and
;   a multi-parent M{P1,Q1}; persist exactly the four public Merkle nodes.
;   Clear the volatile CAS directory and the nkvmerkle registry, keeping the
;   store bytes: nkcas_mount rebuilds the directory and validates every
;   record checksum.
;   Replay all four puts: each is an exact dedup hit (4 hits, 768 bytes
;   avoided) across the restart.
;   Hydrate P by root into 2 pages / 10 tokens and M by root into 4 pages /
;   20 tokens, without the original registry; verify page and token inclusion
;   proofs assembled from the store alone (8 valid, 11 mutated rejects).
;   Re-create the four public nkvmerkle nodes from the store, join P as a
;   fresh gen-5 agent, read all 10 tokens through nkvmerkle views, and close.
;   Collision, missing/delete/reinsert, payload corruption and mount failure
;   all fail closed with exact errors; the store is restored and re-mounted.
;   Generic nkcas_put/get/delete is exercised on a scratch record.
;   Final persistent counters are exact and a 2772-word snapshot (store,
;   CAS stats/trace, nkvmerkle stats, hydrated tokens) is identical across
;   the two scenarios.
;
; Success prints exactly O.  A failed check prints actual,expected,diag.

.org 0
JMP @main

.org 0x10000
.include "../lib/nkcas.nas"

main:
MOVI r13,1
LA r14,#STK

CALL @cold
CALL @setup
CALL @scenario
LA r1,@snapA
CALL @snapshot

CALL @cold
CALL @setup
CALL @scenario
LA r1,@snapB
CALL @snapshot

LA r1,@snapA
LA r2,@snapB
MOVI r3,2772
CALL @cmpbuf
MOVI r2,0
MOVI r3,990
CALL @chk

MOVI r1,79
PUTC r1
HALT

; ---------------------------------------------------------------------------
; cold - full cold init: agents, generations, CAS store, Merkle registry.
cold:
  ST r15,r14,0
  ADDI r14,r14,16
  CALL @nagent_init
  CALL @ngen_init
  LA r1,#STORE
  MOVI r2,32
  CALL @nkcas_init
  MOVI r2,0
  MOVI r3,991
  CALL @chk
  LA r1,@pdata
  MOVI r2,32
  CALL @nkm_init
  MOVI r2,0
  MOVI r3,992
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; setup - four nagent records and ngen agents 1/2/3 at gen 5/5/6.
setup:
  ST r15,r14,0
  ADDI r14,r14,32
  MOVI r1,0
  MOVI r2,0
  MOVI r3,0
  CALL @nagent_create
  MOVI r2,1
  MOVI r3,2
  CALL @chk
  MOVI r1,1
  MOVI r2,0
  MOVI r3,1
  CALL @nagent_create
  MOVI r2,2
  MOVI r3,3
  CALL @chk
  MOVI r1,2
  MOVI r2,0
  MOVI r3,2
  CALL @nagent_create
  MOVI r2,3
  MOVI r3,4
  CALL @chk
  MOVI r1,3
  MOVI r2,0
  MOVI r3,3
  CALL @nagent_create
  MOVI r2,4
  MOVI r3,5
  CALL @chk

  MOVI r1,1
  MOVI r2,0x1000
  MOVI r3,0x2000
  CALL @ngen_create
  MOVI r1,1
  MOVI r2,5
  CALL @gen_prep
  MOVI r2,1
  MOVI r3,6
  CALL @chk
  MOVI r1,1
  MOVI r2,3
  MOVI r3,5
  MOVI r4,7
  CALL @ngen_chk

  MOVI r1,2
  MOVI r2,0x1100
  MOVI r3,0x2100
  CALL @ngen_create
  MOVI r1,2
  MOVI r2,5
  CALL @gen_prep
  MOVI r2,1
  MOVI r3,8
  CALL @chk

  MOVI r1,3
  MOVI r2,0x1200
  MOVI r3,0x2200
  CALL @ngen_create
  MOVI r1,3
  MOVI r2,6
  CALL @gen_prep
  MOVI r2,1
  MOVI r3,9
  CALL @chk
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; gen_prep r1=agent r2=target: start 1, then drain/start up to target.
gen_prep:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  MOVI r2,1
  CALL @ngen_start
  MOVI r3,2
  ST r3,r14,3
gp_l:
  LD r3,r14,3
  LD r2,r14,2
  CMP r3,r2
  JMP[GT] @gp_ok
  LD r1,r14,1
  CALL @ngen_drain
  LD r1,r14,1
  LD r2,r14,3
  CALL @ngen_start
  LD r3,r14,3
  ADD r3,r3,r13
  ST r3,r14,3
  JMP @gp_l
gp_ok:
  MOVI r1,1
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; scenario - one complete cold hydration / dedup / proof / store test.
scenario:
  ST r15,r14,0
  ADDI r14,r14,16
  CALL @build
  CALL @cold_restart
  CALL @dedup_replay
  CALL @hydrate_checks
  CALL @proof_checks
  CALL @registry_checks
  CALL @collision_check
  CALL @delete_missing
  CALL @corruption_check
  CALL @generic_check
  CALL @final_checks
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; build - P, Q, multi-parent M, persist the four public nodes.
build:
  ST r15,r14,0
  ADDI r14,r14,112
  LA r1,@ctx1
  MOVI r2,1
  MOVI r3,5
  MOVI r4,0
  MOVI r5,1
  MOVI r6,1
  LA r7,@tab1
  MOVI r8,16
  MOVI r9,8
  CALL @nkm_open
  MOVI r2,1
  MOVI r3,20
  CALL @chk
  LA r1,@ctx1
  MOVI r2,0
  MOVI r3,10
  MOVI r4,0x5000
  CALL @app_seq
  LA r1,@ctx1
  CALL @nkm_seal
  MOVI r2,1
  MOVI r3,21
  CALL @chk
  LA r1,@ctx1
  LA r2,@ci
  CALL @nkm_ctx_info
  LA r1,@ci
  MOVI r2,#NKM_C_ROOT
  CALL @fld
  LA r2,@proot
  ST r1,r2,0
  LA r1,@ci
  MOVI r2,#NKM_C_HLO
  CALL @fld
  LA r2,@phlo
  ST r1,r2,0
  LA r1,@ci
  MOVI r2,#NKM_C_HHI
  CALL @fld
  LA r2,@phhi
  ST r1,r2,0
  LA r1,@tab1
  LD r1,r1,0
  LA r2,@p0idx
  ST r1,r2,0
  LA r1,@tab1
  ADDI r1,r1,8
  LD r1,r1,0
  LA r2,@p1idx
  ST r1,r2,0
  LA r1,@tab1
  ADDI r1,r1,#NKM_E_HLO
  LD r1,r1,0
  LA r2,@p0hlo
  ST r1,r2,0
  LA r1,@tab1
  ADDI r1,r1,#NKM_E_HHI
  LD r1,r1,0
  LA r2,@p0hhi
  ST r1,r2,0
  LA r1,@tab1
  ADDI r1,r1,8
  ADDI r1,r1,#NKM_E_HLO
  LD r1,r1,0
  LA r2,@p1hlo
  ST r1,r2,0
  LA r1,@tab1
  ADDI r1,r1,8
  ADDI r1,r1,#NKM_E_HHI
  LD r1,r1,0
  LA r2,@p1hhi
  ST r1,r2,0

  ; ---- Q: page 0 dedups P0, Q1 continues with 8 tokens.
  LA r1,@ctx2
  MOVI r2,2
  MOVI r3,5
  MOVI r4,1
  MOVI r5,2
  MOVI r6,2
  LA r7,@tab2
  MOVI r8,16
  MOVI r9,8
  CALL @nkm_open
  MOVI r2,1
  MOVI r3,22
  CALL @chk
  LA r1,@ctx2
  MOVI r2,0
  MOVI r3,8
  MOVI r4,0x5000
  CALL @app_seq
  LA r1,@ctx2
  MOVI r2,8
  MOVI r3,8
  MOVI r4,0x9000
  CALL @app_seq
  LA r1,@ctx2
  CALL @nkm_seal
  MOVI r2,1
  MOVI r3,23
  CALL @chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKM_N_DEDUP
  MOVI r3,1
  MOVI r4,24
  CALL @node_chk
  LA r1,@tab2
  ADDI r1,r1,8
  LD r1,r1,0
  LA r2,@q1idx
  ST r1,r2,0
  LA r1,@tab2
  ADDI r1,r1,8
  ADDI r1,r1,#NKM_E_HLO
  LD r1,r1,0
  LA r2,@q1hlo
  ST r1,r2,0
  LA r1,@tab2
  ADDI r1,r1,8
  ADDI r1,r1,#NKM_E_HHI
  LD r1,r1,0
  LA r2,@q1hhi
  ST r1,r2,0

  ; ---- M{P1,Q1} at gen 6.
  LA r1,@ctx3
  MOVI r2,3
  MOVI r3,6
  MOVI r4,2
  MOVI r5,3
  MOVI r6,3
  LA r7,@tab3
  MOVI r8,16
  MOVI r9,8
  CALL @nkm_open
  MOVI r2,1
  MOVI r3,25
  CALL @chk
  LA r1,@mpars
  LA r2,@p1idx
  LD r2,r2,0
  ST r2,r1,0
  LA r2,@q1idx
  LD r2,r2,0
  ST r2,r1,1
  LA r1,@ctx3
  LA r2,@mvals
  MOVI r3,2
  LA r4,@mpars
  MOVI r5,2
  CALL @nkm_merge_n
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[NE] @build_mok
  MOVI r2,1
  MOVI r3,26
  CALL @chk
build_mok:
  LA r2,@mroot
  ST r1,r2,0
  LA r2,@mi
  CALL @nkm_node_info
  LA r1,@mi
  MOVI r2,#NKM_N_HLO
  CALL @fld
  LA r2,@mhlo
  ST r1,r2,0
  LA r1,@mi
  MOVI r2,#NKM_N_HHI
  CALL @fld
  LA r2,@mhhi
  ST r1,r2,0

  ; ---- persist the four public nodes.
  LA r1,@p0idx
  LD r1,r1,0
  CALL @nkcas_capture
  LA r2,@p0slot
  ST r1,r2,0
  LA r2,#NKCS_NONE
  CMP r1,r2
  JMP[NE] @build_c1
  MOVI r2,1
  MOVI r3,27
  CALL @chk
build_c1:
  LA r1,@p1idx
  LD r1,r1,0
  CALL @nkcas_capture
  LA r2,@p1slot
  ST r1,r2,0
  LA r2,#NKCS_NONE
  CMP r1,r2
  JMP[NE] @build_c2
  MOVI r2,1
  MOVI r3,28
  CALL @chk
build_c2:
  LA r1,@q1idx
  LD r1,r1,0
  CALL @nkcas_capture
  LA r2,@q1slot
  ST r1,r2,0
  LA r2,#NKCS_NONE
  CMP r1,r2
  JMP[NE] @build_c3
  MOVI r2,1
  MOVI r3,29
  CALL @chk
build_c3:
  LA r1,@mroot
  LD r1,r1,0
  CALL @nkcas_capture
  LA r2,@mslot
  ST r1,r2,0
  LA r2,#NKCS_NONE
  CMP r1,r2
  JMP[NE] @build_c4
  MOVI r2,1
  MOVI r3,30
  CALL @chk
build_c4:
  MOVI r1,#NKCS_G_LIVE
  MOVI r2,4
  MOVI r3,31
  CALL @cas_chk
  MOVI r1,#NKCS_G_PUTS
  MOVI r2,4
  MOVI r3,32
  CALL @cas_chk
  MOVI r1,#NKCS_G_DEDUP
  MOVI r2,0
  MOVI r3,33
  CALL @cas_chk
  MOVI r1,#NKCS_G_WRITTEN
  MOVI r2,768
  MOVI r3,34
  CALL @cas_chk
  MOVI r1,#NKCS_G_AVOID
  MOVI r2,0
  MOVI r3,35
  CALL @cas_chk
  ; one record has length/checksum/payload and a persisted size.
  LA r1,@p0hlo
  LD r1,r1,0
  LA r2,@p0hhi
  LD r2,r2,0
  LA r3,@recbuf
  CALL @nkcas_get
  MOVI r2,0
  MOVI r3,36
  CALL @chk
  LA r1,@recbuf
  MOVI r2,#NKCS_R_USED
  MOVI r3,8
  MOVI r4,37
  CALL @rec_chk
  LA r1,@recbuf
  MOVI r2,#NKCS_R_SIZE
  MOVI r3,192
  MOVI r4,38
  CALL @rec_chk
  LA r1,@recbuf
  MOVI r2,#NKCS_R_DEDUP
  MOVI r3,0
  MOVI r4,39
  CALL @rec_chk
  LA r1,@recbuf
  MOVI r2,#NKCS_R_SUM
  CALL @fld
  LA r2,#NKCS_TMP
  ST r1,r2,0
  LA r1,@recbuf
  CALL @nkcas_checksum
  LA r2,#NKCS_TMP
  LD r2,r2,0
  MOVI r3,40
  CALL @chk
  LA r1,@recbuf
  MOVI r2,#NKCS_R_PAY+3
  MOVI r3,0x5003
  MOVI r4,41
  CALL @rec_chk
  ADDI r14,r14,-112
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; cold_restart - clear volatile directory/stats/trace and the node registry.
cold_restart:
  ST r15,r14,0
  ADDI r14,r14,16
  CALL @nkcas_cold
  LA r1,#STORE
  CALL @nkcas_mount
  MOVI r2,0
  MOVI r3,42
  CALL @chk
  MOVI r1,#NKCS_G_LIVE
  MOVI r2,4
  MOVI r3,43
  CALL @cas_chk
  MOVI r1,#NKCS_G_DEDUP
  MOVI r2,0
  MOVI r3,44
  CALL @cas_chk
  MOVI r1,#NKCS_G_WRITTEN
  MOVI r2,768
  MOVI r3,45
  CALL @cas_chk
  MOVI r1,#NKCS_G_AVOID
  MOVI r2,0
  MOVI r3,46
  CALL @cas_chk
  MOVI r1,#NKCS_G_MOUNTS
  MOVI r2,1
  MOVI r3,47
  CALL @cas_chk
  LA r1,@pdata
  MOVI r2,32
  CALL @nkm_init
  LA r1,@p0hlo
  LD r1,r1,0
  LA r2,@p0hhi
  LD r2,r2,0
  CALL @nkm_node_find
  LA r2,#NKM_NONE
  MOVI r3,48
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; dedup_replay - get and re-put each stored record; exact dedup/bytes.
dedup_replay:
  ST r15,r14,0
  ADDI r14,r14,32
  ; P0
  LA r1,@p0hlo
  LD r1,r1,0
  LA r2,@p0hhi
  LD r2,r2,0
  LA r3,@recbuf
  CALL @nkcas_get
  MOVI r2,0
  MOVI r3,50
  CALL @chk
  LA r1,@recbuf
  CALL @nkcas_put_record
  LA r2,@p0slot
  LD r2,r2,0
  MOVI r3,51
  CALL @chk
  ; P1
  LA r1,@p1hlo
  LD r1,r1,0
  LA r2,@p1hhi
  LD r2,r2,0
  LA r3,@recbuf
  CALL @nkcas_get
  MOVI r2,0
  MOVI r3,52
  CALL @chk
  LA r1,@recbuf
  CALL @nkcas_put_record
  LA r2,@p1slot
  LD r2,r2,0
  MOVI r3,53
  CALL @chk
  ; Q1
  LA r1,@q1hlo
  LD r1,r1,0
  LA r2,@q1hhi
  LD r2,r2,0
  LA r3,@recbuf
  CALL @nkcas_get
  MOVI r2,0
  MOVI r3,54
  CALL @chk
  LA r1,@recbuf
  CALL @nkcas_put_record
  LA r2,@q1slot
  LD r2,r2,0
  MOVI r3,55
  CALL @chk
  ; M
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@recbuf
  CALL @nkcas_get
  MOVI r2,0
  MOVI r3,56
  CALL @chk
  LA r1,@recbuf
  CALL @nkcas_put_record
  LA r2,@mslot
  LD r2,r2,0
  MOVI r3,57
  CALL @chk
  MOVI r1,#NKCS_G_LIVE
  MOVI r2,4
  MOVI r3,58
  CALL @cas_chk
  MOVI r1,#NKCS_G_DEDUP
  MOVI r2,4
  MOVI r3,59
  CALL @cas_chk
  MOVI r1,#NKCS_G_AVOID
  MOVI r2,768
  MOVI r3,60
  CALL @cas_chk
  MOVI r1,#NKCS_G_WRITTEN
  MOVI r2,768
  MOVI r3,61
  CALL @cas_chk
  ; per-record dedup hit counter persisted.
  LA r1,@p0hlo
  LD r1,r1,0
  LA r2,@p0hhi
  LD r2,r2,0
  LA r3,@recbuf
  CALL @nkcas_get
  LA r1,@recbuf
  MOVI r2,#NKCS_R_DEDUP
  MOVI r3,1
  MOVI r4,62
  CALL @rec_chk
  LA r1,@recbuf
  MOVI r2,#NKCS_R_PAY+3
  MOVI r3,0x5003
  MOVI r4,63
  CALL @rec_chk
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; hydrate_checks - reconstruct P and M by root, no registry.
hydrate_checks:
  ST r15,r14,0
  ADDI r14,r14,32
  LA r1,@phlo
  LD r1,r1,0
  LA r2,@phhi
  LD r2,r2,0
  LA r3,@pout
  LA r4,@tokout
  CALL @nkcas_hydrate
  MOVI r2,10
  MOVI r3,64
  CALL @chk
  LA r1,@pout
  MOVI r2,0
  MOVI r3,2
  MOVI r4,65
  CALL @word_chk
  LA r1,@pout
  MOVI r2,1
  MOVI r3,10
  MOVI r4,66
  CALL @word_chk
  LA r1,@pout
  MOVI r2,2
  MOVI r3,2
  MOVI r4,67
  CALL @word_chk
  LA r1,@tokout
  MOVI r2,0x5000
  MOVI r3,10
  MOVI r4,68
  CALL @tokens_chk
  ; page table entries: P0 then P1
  LA r1,@pout
  MOVI r2,0
  LA r3,@p0hlo
  LD r3,r3,0
  LA r4,@p0hhi
  LD r4,r4,0
  MOVI r5,8
  MOVI r6,69
  CALL @page_chk
  LA r1,@pout
  MOVI r2,1
  LA r3,@p1hlo
  LD r3,r3,0
  LA r4,@p1hhi
  LD r4,r4,0
  MOVI r5,2
  MOVI r6,70
  CALL @page_chk

  ; M root: 4 unique pages, 20 tokens, parents-first order.
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@mout
  LA r4,@mtok
  CALL @nkcas_hydrate
  MOVI r2,20
  MOVI r3,71
  CALL @chk
  LA r1,@mout
  MOVI r2,0
  MOVI r3,4
  MOVI r4,72
  CALL @word_chk
  LA r1,@mout
  MOVI r2,1
  MOVI r3,20
  MOVI r4,73
  CALL @word_chk
  LA r1,@mout
  MOVI r2,2
  MOVI r3,4
  MOVI r4,74
  CALL @word_chk
  LA r1,@mtok
  MOVI r2,0x5000
  MOVI r3,10
  MOVI r4,75
  CALL @tokens_chk
  LA r1,@mtok
  ADDI r1,r1,10
  MOVI r2,0x9000
  MOVI r3,8
  MOVI r4,76
  CALL @tokens_chk
  LA r1,@mtok
  ADDI r1,r1,18
  MOVI r2,0xA000
  MOVI r3,2
  MOVI r4,77
  CALL @tokens_chk
  LA r1,@mout
  MOVI r2,0
  LA r3,@p0hlo
  LD r3,r3,0
  LA r4,@p0hhi
  LD r4,r4,0
  MOVI r5,8
  MOVI r6,78
  CALL @page_chk
  LA r1,@mout
  MOVI r2,1
  LA r3,@p1hlo
  LD r3,r3,0
  LA r4,@p1hhi
  LD r4,r4,0
  MOVI r5,2
  MOVI r6,79
  CALL @page_chk
  LA r1,@mout
  MOVI r2,2
  LA r3,@q1hlo
  LD r3,r3,0
  LA r4,@q1hhi
  LD r4,r4,0
  MOVI r5,8
  MOVI r6,80
  CALL @page_chk
  LA r1,@mout
  MOVI r2,3
  LA r3,@mhlo
  LD r3,r3,0
  LA r4,@mhhi
  LD r4,r4,0
  MOVI r5,2
  MOVI r6,81
  CALL @page_chk
  MOVI r1,#NKCS_G_HYDRATES
  MOVI r2,2
  MOVI r3,82
  CALL @cas_chk
  MOVI r1,#NKCS_G_HNODES
  MOVI r2,6
  MOVI r3,83
  CALL @cas_chk
  MOVI r1,#NKCS_G_HTOKENS
  MOVI r2,30
  MOVI r3,84
  CALL @cas_chk
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; proof_checks - 8 valid proofs from the M root, 11 mutated rejects.
proof_checks:
  ST r15,r14,0
  ADDI r14,r14,32
  ; page P0 depth 3
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@p0hlo
  LD r3,r3,0
  LA r4,@p0hhi
  LD r4,r4,0
  LA r5,#NKCS_NONE
  LA r6,@pp0
  MOVI r7,3
  MOVI r8,100
  CALL @proof_one
  ; page P1 depth 2
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@p1hlo
  LD r3,r3,0
  LA r4,@p1hhi
  LD r4,r4,0
  LA r5,#NKCS_NONE
  LA r6,@pp1
  MOVI r7,2
  MOVI r8,101
  CALL @proof_one
  ; page Q1 depth 2
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@q1hlo
  LD r3,r3,0
  LA r4,@q1hhi
  LD r4,r4,0
  LA r5,#NKCS_NONE
  LA r6,@pq1
  MOVI r7,2
  MOVI r8,102
  CALL @proof_one
  ; page M depth 1
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@mhlo
  LD r3,r3,0
  LA r4,@mhhi
  LD r4,r4,0
  LA r5,#NKCS_NONE
  LA r6,@pm
  MOVI r7,1
  MOVI r8,103
  CALL @proof_one
  ; token P1[1]=0x5009
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@p1hlo
  LD r3,r3,0
  LA r4,@p1hhi
  LD r4,r4,0
  MOVI r5,1
  LA r6,@pt1
  MOVI r7,2
  MOVI r8,104
  CALL @proof_one
  ; token P0[3]=0x5003
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@p0hlo
  LD r3,r3,0
  LA r4,@p0hhi
  LD r4,r4,0
  MOVI r5,3
  LA r6,@pt0
  MOVI r7,3
  MOVI r8,105
  CALL @proof_one
  ; token Q1[7]=0x9007
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@q1hlo
  LD r3,r3,0
  LA r4,@q1hhi
  LD r4,r4,0
  MOVI r5,7
  LA r6,@ptq
  MOVI r7,2
  MOVI r8,106
  CALL @proof_one
  ; token M[1]=0xA001
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@mhlo
  LD r3,r3,0
  LA r4,@mhhi
  LD r4,r4,0
  MOVI r5,1
  LA r6,@ptm
  MOVI r7,1
  MOVI r8,107
  CALL @proof_one
  MOVI r1,#NKCS_G_PROOFS
  MOVI r2,8
  MOVI r3,108
  CALL @cas_chk
  MOVI r1,#NKCS_G_VERIFIES
  MOVI r2,8
  MOVI r3,109
  CALL @cas_chk
  ; token proof header values
  LA r1,@pt1
  MOVI r2,#NKM_P_MODE
  MOVI r3,2
  MOVI r4,110
  CALL @word_chk
  LA r1,@pt1
  MOVI r2,#NKM_P_TOKOFF
  MOVI r3,1
  MOVI r4,111
  CALL @word_chk
  LA r1,@pt1
  MOVI r2,#NKM_P_TOKVAL
  MOVI r3,0x5009
  MOVI r4,112
  CALL @word_chk
  ; 11 mutated rejects.
  LA r1,@pp1
  MOVI r2,27
  MOVI r3,120
  CALL @mut1
  LA r1,@pp1
  MOVI r2,19
  MOVI r3,121
  CALL @mut1
  LA r1,@pp1
  MOVI r2,17
  MOVI r3,122
  CALL @mut1
  LA r1,@pp1
  MOVI r2,16
  MOVI r3,123
  CALL @mut1
  LA r1,@pt1
  MOVI r2,#NKM_P_TOKVAL
  MOVI r3,124
  CALL @mut1
  LA r1,@pt0
  MOVI r2,30
  MOVI r3,125
  CALL @mut1
  LA r1,@pp1
  MOVI r2,#NKM_P_TARGLO
  MOVI r3,126
  CALL @mut1
  LA r1,@pp1
  MOVI r2,#NKM_P_ROOTLO
  MOVI r3,127
  CALL @mut1
  LA r1,@pp1
  MOVI r2,#NKM_P_DEPTH
  MOVI r3,128
  CALL @mut1
  LA r1,@pm
  MOVI r2,19
  MOVI r3,20
  MOVI r4,129
  CALL @swap2
  MOVI r1,130
  CALL @rootbad
  MOVI r1,#NKCS_G_XPROOF
  MOVI r2,11
  MOVI r3,131
  CALL @cas_chk
  MOVI r1,#NKCS_G_VERIFIES
  MOVI r2,8
  MOVI r3,132
  CALL @cas_chk
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; registry_checks - rehydrate the 4 public nodes, join P as a fresh agent.
registry_checks:
  ST r15,r14,0
  ADDI r14,r14,48
  CALL @nagent_init
  CALL @ngen_init
  MOVI r1,0
  MOVI r2,0
  MOVI r3,0
  CALL @nagent_create
  MOVI r2,1
  MOVI r3,140
  CALL @chk
  MOVI r1,1
  MOVI r2,0x1000
  MOVI r3,0x2000
  CALL @ngen_create
  MOVI r1,1
  MOVI r2,5
  CALL @gen_prep
  MOVI r2,1
  MOVI r3,141
  CALL @chk

  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  MOVI r3,0
  CALL @nkcas_registry_hydrate
  ST r1,r14,1
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[NE] @reg_have
  MOVI r2,1
  MOVI r3,142
  CALL @chk
reg_have:
  LD r1,r14,1
  LA r2,@mi
  CALL @nkm_node_info
  LA r1,@mi
  MOVI r2,#NKM_N_USED
  MOVI r3,2
  MOVI r4,143
  CALL @node_chk
  LA r1,@mi
  MOVI r2,#NKM_N_PCOUNT
  MOVI r3,2
  MOVI r4,144
  CALL @node_chk
  LA r1,@mi
  MOVI r2,#NKM_N_BGEN
  MOVI r3,6
  MOVI r4,145
  CALL @node_chk
  LA r1,@mi
  MOVI r2,#NKM_N_PIDX
  CALL @fld
  ST r1,r14,2
  LA r1,@p1hlo
  LD r1,r1,0
  LA r2,@p1hhi
  LD r2,r2,0
  CALL @nkm_find
  LD r2,r14,2
  MOVI r3,146
  CALL @chk
  LA r1,@mi
  MOVI r2,#NKM_N_PIDX
  ADD r1,r1,r2
  ADDI r1,r1,1
  LD r1,r1,0
  ST r1,r14,3
  LA r1,@q1hlo
  LD r1,r1,0
  LA r2,@q1hhi
  LD r2,r2,0
  CALL @nkm_find
  LD r2,r14,3
  MOVI r3,147
  CALL @chk
  MOVI r1,#NKM_G_LIVE
  MOVI r2,4
  MOVI r3,148
  CALL @nkm_chk
  MOVI r1,#NKM_G_PHEADERS
  MOVI r2,4
  MOVI r3,149
  CALL @nkm_chk
  MOVI r1,#NKM_G_REFS
  MOVI r2,8
  MOVI r3,150
  CALL @nkm_chk
  MOVI r1,#NKM_G_PFREE
  MOVI r2,0
  MOVI r3,151
  CALL @nkm_chk

  ; agent cfg -> ctx4, ngen agent 1 gen 5, nagent 0, P root.
  LA r1,@cfg
  LA r2,@ctx4
  ST r2,r1,0
  MOVI r2,1
  ST r2,r1,1
  MOVI r2,5
  ST r2,r1,2
  MOVI r2,0
  ST r2,r1,3
  MOVI r2,4
  ST r2,r1,4
  MOVI r2,0
  ST r2,r1,5
  LA r2,@tab4
  ST r2,r1,6
  MOVI r2,16
  ST r2,r1,7
  MOVI r2,8
  ST r2,r1,8
  LA r2,@phlo
  LD r2,r2,0
  ST r2,r1,9
  LA r2,@phhi
  LD r2,r2,0
  ST r2,r1,10
  MOVI r2,0
  ST r2,r1,11
  LA r1,@cfg
  CALL @nkcas_agent_hydrate
  CMP r1,r0
  JMP[NE] @ah_ok
ah_ok:
  MOVI r2,1
  MOVI r3,152
  CALL @chk
  LA r1,@ctx4
  MOVI r2,#NKM_C_USED
  MOVI r3,10
  MOVI r4,153
  CALL @ctx_chk
  LA r1,@ctx4
  MOVI r2,#NKM_C_LIVE
  MOVI r3,2
  MOVI r4,154
  CALL @ctx_chk
  LA r1,@ctx4
  MOVI r2,#NKM_C_JOINS
  MOVI r3,1
  MOVI r4,155
  CALL @ctx_chk
  LA r1,@ctx4
  MOVI r2,#NKM_C_HLO
  CALL @fld
  LA r2,@phlo
  LD r2,r2,0
  MOVI r3,156
  CALL @chk
  LA r1,@ctx4
  MOVI r2,0
  MOVI r3,10
  MOVI r4,0x5000
  MOVI r5,157
  CALL @rd_range
  MOVI r2,1
  MOVI r3,158
  CALL @chk
  LA r1,@ctx4
  CALL @nkm_close
  MOVI r2,1
  MOVI r3,159
  CALL @chk
  MOVI r1,#NKM_G_REFS
  MOVI r2,10
  MOVI r3,160
  CALL @nkm_chk
  MOVI r1,#NKM_G_RELS
  MOVI r2,2
  MOVI r3,161
  CALL @nkm_chk
  MOVI r1,#NKM_G_JOINREFS
  MOVI r2,2
  MOVI r3,162
  CALL @nkm_chk
  MOVI r1,#NKCS_G_HAGENTS
  MOVI r2,1
  MOVI r3,163
  CALL @cas_chk
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; collision_check - same key, different valid payload -> ECOLL, no alias.
collision_check:
  ST r15,r14,0
  ADDI r14,r14,24
  LA r1,@p0hlo
  LD r1,r1,0
  LA r2,@p0hhi
  LD r2,r2,0
  LA r3,@recbuf
  CALL @nkcas_get
  MOVI r2,0
  MOVI r3,170
  CALL @chk
  LA r1,@recbuf
  MOVI r2,#NKCS_R_PAY+3
  CALL @fld
  ADDI r1,r1,1
  LA r2,@recbuf
  MOVI r3,#NKCS_R_PAY+3
  ADD r2,r2,r3
  ST r1,r2,0
  LA r1,@recbuf
  CALL @nkcas_checksum
  LA r2,@recbuf
  ST r1,r2,#NKCS_R_SUM
  LA r1,@recbuf
  CALL @nkcas_put_record
  LA r2,#NKCS_NONE
  MOVI r3,171
  CALL @chk
  CALL @nkcas_errno
  MOVI r2,#NKCS_ECOLL
  MOVI r3,172
  CALL @chk
  MOVI r1,#NKCS_G_COLL
  MOVI r2,1
  MOVI r3,173
  CALL @cas_chk
  ; stored P0 unchanged
  LA r1,@p0hlo
  LD r1,r1,0
  LA r2,@p0hhi
  LD r2,r2,0
  LA r3,@recbuf
  CALL @nkcas_get
  LA r1,@recbuf
  MOVI r2,#NKCS_R_PAY+3
  MOVI r3,0x5003
  MOVI r4,174
  CALL @rec_chk
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; delete_missing - delete Q1, exact ENOENT paths, then reinsert.
delete_missing:
  ST r15,r14,0
  ADDI r14,r14,24
  LA r1,@q1hlo
  LD r1,r1,0
  LA r2,@q1hhi
  LD r2,r2,0
  LA r3,@recq1
  CALL @nkcas_get
  MOVI r2,0
  MOVI r3,180
  CALL @chk
  LA r1,@q1hlo
  LD r1,r1,0
  LA r2,@q1hhi
  LD r2,r2,0
  CALL @nkcas_delete
  MOVI r2,0
  MOVI r3,181
  CALL @chk
  MOVI r1,#NKCS_G_LIVE
  MOVI r2,3
  MOVI r3,182
  CALL @cas_chk
  MOVI r1,#NKCS_G_DELS
  MOVI r2,1
  MOVI r3,183
  CALL @cas_chk
  ; get missing
  LA r1,@q1hlo
  LD r1,r1,0
  LA r2,@q1hhi
  LD r2,r2,0
  LA r3,@recbuf
  CALL @nkcas_get
  MOVI r2,#NKCS_ENOENT
  MOVI r3,184
  CALL @chk
  ; hydrate missing
  LA r1,@q1hlo
  LD r1,r1,0
  LA r2,@q1hhi
  LD r2,r2,0
  LA r3,@pout
  LA r4,@tokout
  CALL @nkcas_hydrate
  LA r2,#NKCS_NONE
  MOVI r3,185
  CALL @chk
  CALL @nkcas_errno
  MOVI r2,#NKCS_ENOENT
  MOVI r3,186
  CALL @chk
  ; proof missing target
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@q1hlo
  LD r3,r3,0
  LA r4,@q1hhi
  LD r4,r4,0
  LA r5,#NKCS_NONE
  LA r6,@pmut
  CALL @nkcas_proof
  MOVI r2,0
  MOVI r3,187
  CALL @chk
  CALL @nkcas_errno
  MOVI r2,#NKCS_ENOENT
  MOVI r3,188
  CALL @chk
  ; delete missing
  LA r1,@q1hlo
  LD r1,r1,0
  LA r2,@q1hhi
  LD r2,r2,0
  CALL @nkcas_delete
  MOVI r2,#NKCS_ENOENT
  MOVI r3,189
  CALL @chk
  ; reinsert the saved Q1 record
  LA r1,@recq1
  CALL @nkcas_put_record
  LA r2,@q1slot
  ST r1,r2,0
  LD r2,r2,0
  MOVI r3,190
  CALL @chk
  MOVI r1,#NKCS_G_LIVE
  MOVI r2,4
  MOVI r3,191
  CALL @cas_chk
  MOVI r1,#NKCS_G_PUTS
  MOVI r2,5
  MOVI r3,192
  CALL @cas_chk
  MOVI r1,#NKCS_G_DELS
  MOVI r2,1
  MOVI r3,193
  CALL @cas_chk
  ; Q1 hydrates again
  LA r1,@q1hlo
  LD r1,r1,0
  LA r2,@q1hhi
  LD r2,r2,0
  LA r3,@pout
  LA r4,@tokout
  CALL @nkcas_hydrate
  MOVI r2,16
  MOVI r3,194
  CALL @chk
  LA r1,@tokout
  MOVI r2,0x5000
  MOVI r3,8
  MOVI r4,195
  CALL @tokens_chk
  LA r1,@tokout
  ADDI r1,r1,8
  MOVI r2,0x9000
  MOVI r3,8
  MOVI r4,195
  CALL @tokens_chk
  MOVI r1,#NKCS_G_MISS
  MOVI r2,4
  MOVI r3,196
  CALL @cas_chk
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; corruption_check - mutate one stored payload, then a failed mount; restore.
corruption_check:
  ST r15,r14,0
  ADDI r14,r14,32
  ; backup the whole store: 32 + 32*48 = 1568 words.
  LA r1,@stbackup
  LA r2,#STORE
  MOVI r3,1568
  BCOPY r1,r2,r3
  ; mutate P0 payload word 0 without updating the checksum.
  LA r1,@p0hlo
  LD r1,r1,0
  LA r2,@p0hhi
  LD r2,r2,0
  CALL @nkcas_find
  ST r1,r14,1
  CALL @nkcas_recptr
  ADDI r1,r1,#NKCS_R_PAY
  LD r2,r1,0
  ADDI r2,r2,1
  ST r2,r1,0
  ; get detects corruption
  LA r1,@p0hlo
  LD r1,r1,0
  LA r2,@p0hhi
  LD r2,r2,0
  LA r3,@recbuf
  CALL @nkcas_get
  MOVI r2,#NKCS_ECORRUPT
  MOVI r3,200
  CALL @chk
  MOVI r1,#NKCS_G_CORRUPT
  MOVI r2,1
  MOVI r3,201
  CALL @cas_chk
  ; mount rejects the store
  LA r1,#STORE
  CALL @nkcas_mount
  MOVI r2,#NKCS_ECORRUPT
  MOVI r3,202
  CALL @chk
  MOVI r1,#NKCS_G_MOUNTED
  MOVI r2,0
  MOVI r3,203
  CALL @cas_chk
  MOVI r1,#NKCS_G_CORRUPT
  MOVI r2,1
  MOVI r3,204
  CALL @cas_chk
  ; restore and mount
  LA r1,#STORE
  LA r2,@stbackup
  MOVI r3,1568
  BCOPY r1,r2,r3
  LA r1,#STORE
  CALL @nkcas_mount
  MOVI r2,0
  MOVI r3,205
  CALL @chk
  MOVI r1,#NKCS_G_LIVE
  MOVI r2,4
  MOVI r3,206
  CALL @cas_chk
  MOVI r1,#NKCS_G_DEDUP
  MOVI r2,4
  MOVI r3,207
  CALL @cas_chk
  MOVI r1,#NKCS_G_AVOID
  MOVI r2,768
  MOVI r3,208
  CALL @cas_chk
  MOVI r1,#NKCS_G_WRITTEN
  MOVI r2,960
  MOVI r3,209
  CALL @cas_chk
  MOVI r1,#NKCS_G_DELS
  MOVI r2,1
  MOVI r3,210
  CALL @cas_chk
  MOVI r1,#NKCS_G_MOUNTS
  MOVI r2,2
  MOVI r3,211
  CALL @cas_chk
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; generic_check - nkcas_put/get/delete on a scratch record; delete cleans it.
generic_check:
  ST r15,r14,0
  ADDI r14,r14,24
  MOVI r1,0xCA5C
  MOVI r2,0xA5C1
  LA r3,@gvals
  MOVI r4,3
  MOVI r5,5
  MOVI r6,0
  MOVI r7,0
  CALL @nkcas_put
  LA r2,#NKCS_NONE
  CMP r1,r2
  JMP[NE] @gen_have
  MOVI r2,1
  MOVI r3,220
  CALL @chk
gen_have:
  LA r2,@gslot
  ST r1,r2,0
  MOVI r1,0xCA5C
  MOVI r2,0xA5C1
  LA r3,@recbuf
  CALL @nkcas_get
  MOVI r2,0
  MOVI r3,221
  CALL @chk
  LA r1,@recbuf
  MOVI r2,#NKCS_R_USED
  MOVI r3,3
  MOVI r4,222
  CALL @rec_chk
  LA r1,@recbuf
  MOVI r2,#NKCS_R_PAY+2
  MOVI r3,0x333
  MOVI r4,223
  CALL @rec_chk
  MOVI r1,0xCA5C
  MOVI r2,0xA5C1
  CALL @nkcas_delete
  MOVI r2,0
  MOVI r3,224
  CALL @chk
  MOVI r1,0xCA5C
  MOVI r2,0xA5C1
  LA r3,@recbuf
  CALL @nkcas_get
  MOVI r2,#NKCS_ENOENT
  MOVI r3,225
  CALL @chk
  MOVI r1,#NKCS_G_LIVE
  MOVI r2,4
  MOVI r3,226
  CALL @cas_chk
  MOVI r1,#NKCS_G_PUTS
  MOVI r2,6
  MOVI r3,227
  CALL @cas_chk
  MOVI r1,#NKCS_G_WRITTEN
  MOVI r2,1152
  MOVI r3,228
  CALL @cas_chk
  MOVI r1,#NKCS_G_DELS
  MOVI r2,2
  MOVI r3,229
  CALL @cas_chk
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; final_checks - after restore: hydrate P and verify a stored proof.
final_checks:
  ST r15,r14,0
  ADDI r14,r14,24
  LA r1,@phlo
  LD r1,r1,0
  LA r2,@phhi
  LD r2,r2,0
  LA r3,@pout
  LA r4,@tokout
  CALL @nkcas_hydrate
  MOVI r2,10
  MOVI r3,240
  CALL @chk
  LA r1,@tokout
  MOVI r2,0x5000
  MOVI r3,10
  MOVI r4,241
  CALL @tokens_chk
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@pp0
  CALL @nkcas_verify
  MOVI r2,1
  MOVI r3,242
  CALL @chk
  MOVI r1,#NKCS_G_HYDRATES
  MOVI r2,1
  MOVI r3,243
  CALL @cas_chk
  MOVI r1,#NKCS_G_HNODES
  MOVI r2,2
  MOVI r3,244
  CALL @cas_chk
  MOVI r1,#NKCS_G_HTOKENS
  MOVI r2,10
  MOVI r3,245
  CALL @cas_chk
  MOVI r1,#NKCS_G_VERIFIES
  MOVI r2,1
  MOVI r3,246
  CALL @cas_chk
  MOVI r1,#NKCS_G_DEDUP
  MOVI r2,4
  MOVI r3,247
  CALL @cas_chk
  MOVI r1,#NKCS_G_AVOID
  MOVI r2,768
  MOVI r3,248
  CALL @cas_chk
  MOVI r1,#NKCS_G_WRITTEN
  MOVI r2,1152
  MOVI r3,249
  CALL @cas_chk
  MOVI r1,#NKCS_G_LIVE
  MOVI r2,4
  MOVI r3,250
  CALL @cas_chk
  MOVI r1,#NKCS_G_DELS
  MOVI r2,2
  MOVI r3,251
  CALL @cas_chk
  MOVI r1,#NKCS_G_MOUNTS
  MOVI r2,2
  MOVI r3,252
  CALL @cas_chk
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; proof_one r1=root lo r2=root hi r3=targ lo r4=targ hi r5=tokoff
;           r6=proof r7=expected depth r8=diag.  Generates and verifies.
proof_one:
  ST r15,r14,0
  ADDI r14,r14,80
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  ST r7,r14,7
  ST r8,r14,8
  CALL @nkcas_proof
  LD r2,r14,7
  LD r3,r14,8
  CALL @chk
  LD r1,r14,1
  LD r2,r14,2
  LD r3,r14,6
  CALL @nkcas_verify
  MOVI r2,1
  LD r3,r14,8
  CALL @chk
  ADDI r14,r14,-80
  LD r15,r14,0
  RET

; mut1 r1=proof r2=word offset r3=diag.  Copy, add one, expect EPROOF.
mut1:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LA r1,@pmut
  LD r2,r14,1
  MOVI r3,528
  CALL @copyw
  LA r1,@pmut
  LD r2,r14,2
  ADD r1,r1,r2
  LD r2,r1,0
  ADDI r2,r2,1
  ST r2,r1,0
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@pmut
  CALL @nkcas_verify
  CMP r1,r0
  JMP[NE] @mut1_bad
  CALL @nkcas_errno
  MOVI r2,#NKCS_EPROOF
  LD r3,r14,3
  CALL @chk
  MOVI r1,1
  JMP @mut1_out
mut1_bad:
  MOVI r1,1
  MOVI r2,0
  LD r3,r14,3
  CALL @chk
mut1_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; swap2 r1=proof r2=off1 r3=off2 r4=diag.  Swap, expect EPROOF.
swap2:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  LA r1,@pmut
  LD r2,r14,1
  MOVI r3,528
  CALL @copyw
  LA r1,@pmut
  LD r2,r14,2
  ADD r2,r1,r2
  LD r3,r2,0
  LA r1,@pmut
  LD r2,r14,3
  ADD r2,r1,r2
  LD r4,r2,0
  ST r4,r3,0
  ST r3,r2,0
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@pmut
  CALL @nkcas_verify
  CMP r1,r0
  JMP[NE] @swap2_bad
  CALL @nkcas_errno
  MOVI r2,#NKCS_EPROOF
  LD r3,r14,4
  CALL @chk
  MOVI r1,1
  JMP @swap2_out
swap2_bad:
  MOVI r1,1
  MOVI r2,0
  LD r3,r14,4
  CALL @chk
swap2_out:
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; rootbad r1=diag: mutate the supplied root, keep the proof.
rootbad:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  LA r1,@mhlo
  LD r1,r1,0
  ADDI r1,r1,1
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@pp0
  CALL @nkcas_verify
  CMP r1,r0
  JMP[NE] @rootbad_bad
  CALL @nkcas_errno
  MOVI r2,#NKCS_EPROOF
  LD r3,r14,1
  CALL @chk
  MOVI r1,1
  JMP @rootbad_out
rootbad_bad:
  MOVI r1,1
  MOVI r2,0
  LD r3,r14,1
  CALL @chk
rootbad_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; snapshot r1=out(2772): store, CAS stats/trace, nkm stats, tokens.
snapshot:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  LA r2,#STORE
  LD r1,r14,1
  MOVI r3,1568
  CALL @copyw
  LA r2,#NKCS_STATS
  LD r1,r14,1
  ADDI r1,r1,1568
  MOVI r3,64
  CALL @copyw
  LA r2,#NKCS_TRACE
  LD r1,r14,1
  ADDI r1,r1,1632
  MOVI r3,1024
  CALL @copyw
  LA r2,#NKM_STATS
  LD r1,r14,1
  ADDI r1,r1,2656
  MOVI r3,64
  CALL @copyw
  LA r2,@tokout
  LD r1,r14,1
  ADDI r1,r1,2720
  MOVI r3,20
  CALL @copyw
  LA r2,@mtok
  LD r1,r14,1
  ADDI r1,r1,2740
  MOVI r3,32
  CALL @copyw
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; app_seq r1=ctx r2=first token r3=count r4=starting value -> 1/0.
app_seq:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
as_l:
  LD r2,r14,3
  CMP r2,r0
  JMP[EQ] @as_done
  LD r1,r14,1
  LD r2,r14,4
  CALL @nkm_append
  LD r3,r14,2
  CMP r1,r3
  JMP[NE] @as_bad
  LD r4,r14,4
  ADD r4,r4,r13
  ST r4,r14,4
  LD r3,r14,2
  ADD r3,r3,r13
  ST r3,r14,2
  LD r3,r14,3
  SUB r3,r3,r13
  ST r3,r14,3
  JMP @as_l
as_bad:
  MOVI r1,1
  MOVI r2,0
  MOVI r3,299
  CALL @chk
as_done:
  MOVI r1,1
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; rd_range r1=ctx r2=start r3=count r4=base r5=diagbase -> 1/0.
rd_range:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
rr_l:
  LD r3,r14,3
  CMP r3,r0
  JMP[EQ] @rr_done
  LD r1,r14,1
  LD r2,r14,2
  MOVI r3,1
  LA r4,@v
  CALL @nkm_view_open
  MOVI r2,1
  LD r3,r14,5
  CALL @chk
  LD r1,r14,1
  LA r2,@v
  LA r3,@vo
  CALL @nkm_view_read
  MOVI r2,1
  LD r3,r14,5
  CALL @chk
  LA r1,@vo
  MOVI r2,0
  CALL @fld
  LD r2,r14,4
  LD r3,r14,5
  CALL @chk
  LD r4,r14,4
  ADD r4,r4,r13
  ST r4,r14,4
  LD r2,r14,2
  ADD r2,r2,r13
  ST r2,r14,2
  LD r3,r14,3
  SUB r3,r3,r13
  ST r3,r14,3
  LD r5,r14,5
  ADD r5,r5,r13
  ST r5,r14,5
  JMP @rr_l
rr_done:
  MOVI r1,1
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; tokens_chk r1=ptr r2=expected base r3=count r4=diag.
tokens_chk:
  ST r15,r14,0
  ADDI r14,r14,48
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
tc_l:
  LD r3,r14,3
  CMP r3,r0
  JMP[EQ] @tc_done
  LD r1,r14,1
  LD r2,r1,0
  LD r3,r14,2
  LD r4,r14,4
  ADD r1,r2,r0
  ADD r2,r3,r0
  ADD r3,r4,r0
  CALL @chk
  LD r1,r14,1
  ADD r1,r1,r13
  ST r1,r14,1
  LD r2,r14,2
  ADD r2,r2,r13
  ST r2,r14,2
  LD r3,r14,3
  SUB r3,r3,r13
  ST r3,r14,3
  LD r4,r14,4
  ADD r4,r4,r13
  ST r4,r14,4
  JMP @tc_l
tc_done:
  MOVI r1,1
  ADDI r14,r14,-48
  LD r15,r14,0
  RET

; page_chk r1=out r2=index r3=hlo r4=hhi r5=used r6=diag.
page_chk:
  ST r15,r14,0
  ADDI r14,r14,56
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  LD r1,r14,1
  LD r2,r14,2
  SHL r2,r2,2
  ADDI r1,r1,#NKCS_PAGEHDR
  ADD r1,r1,r2
  LD r2,r1,1
  LD r3,r14,3
  LD r4,r14,6
  ADD r1,r2,r0
  ADD r2,r3,r0
  ADD r3,r4,r0
  CALL @chk
  LD r1,r14,1
  LD r2,r14,2
  SHL r2,r2,2
  ADDI r1,r1,#NKCS_PAGEHDR
  ADD r1,r1,r2
  LD r2,r1,2
  LD r3,r14,4
  LD r4,r14,6
  ADD r1,r2,r0
  ADD r2,r3,r0
  ADD r3,r4,r0
  CALL @chk
  LD r1,r14,1
  LD r2,r14,2
  SHL r2,r2,2
  ADDI r1,r1,#NKCS_PAGEHDR
  ADD r1,r1,r2
  LD r2,r1,3
  LD r3,r14,5
  LD r4,r14,6
  ADD r1,r2,r0
  ADD r2,r3,r0
  ADD r3,r4,r0
  CALL @chk
  ADDI r14,r14,-56
  LD r15,r14,0
  RET

; fld r1=base r2=offset -> r1=value.
fld:
  ADD r3,r1,r2
  LD r1,r3,0
  RET

; word_chk r1=base r2=offset r3=expected r4=diag.
word_chk:
  ST r15,r14,0
  ADDI r14,r14,16
  ADD r1,r1,r2
  LD r1,r1,0
  ADD r2,r3,r0
  ADD r3,r4,r0
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; rec_chk r1=record r2=offset r3=expected r4=diag.
rec_chk:
  ST r15,r14,0
  ADDI r14,r14,16
  ADD r1,r1,r2
  LD r1,r1,0
  ADD r2,r3,r0
  ADD r3,r4,r0
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ctx_chk r1=ctx r2=field r3=expected r4=diag.
ctx_chk:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  LD r1,r14,1
  LA r2,@ci
  CALL @nkm_ctx_info
  LA r1,@ci
  LD r2,r14,2
  ADD r1,r1,r2
  LD r1,r1,0
  LD r2,r14,3
  LD r3,r14,4
  CALL @chk
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; cas_chk r1=field r2=expected r3=diag.
cas_chk:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LA r1,@statsbuf
  CALL @nkcas_stats
  LA r1,@statsbuf
  LD r2,r14,1
  ADD r1,r1,r2
  LD r1,r1,0
  LD r2,r14,2
  LD r3,r14,3
  CALL @chk
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nkm_chk r1=field r2=expected r3=diag.
nkm_chk:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LA r1,@nkmstats
  CALL @nkm_stats
  LA r1,@nkmstats
  LD r2,r14,1
  ADD r1,r1,r2
  LD r1,r1,0
  LD r2,r14,2
  LD r3,r14,3
  CALL @chk
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; node_chk r1=index r2=field r3=expected r4=diag.
node_chk:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r2,r14,1
  ST r3,r14,2
  ST r4,r14,3
  LA r2,@mi
  CALL @nkm_node_info
  LA r1,@mi
  LD r2,r14,1
  ADD r1,r1,r2
  LD r1,r1,0
  LD r2,r14,2
  LD r3,r14,3
  CALL @chk
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ngen_chk r1=agent r2=field r3=expected r4=diag.
ngen_chk:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r2,r14,1
  ST r3,r14,2
  ST r4,r14,3
  LA r2,@st
  CALL @ngen_status
  LA r1,@st
  LD r2,r14,1
  ADD r1,r1,r2
  LD r1,r1,0
  LD r2,r14,2
  LD r3,r14,3
  CALL @chk
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; chk r1=actual r2=expected r3=diag.
chk:
  CMP r1,r2
  JMP[EQ] @chk_ok
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LD r1,r14,1
  CALL @puthex8
  MOVI r1,44
  PUTC r1
  LD r1,r14,2
  CALL @puthex8
  MOVI r1,44
  PUTC r1
  LD r1,r14,3
  CALL @putdec3
  MOVI r1,10
  PUTC r1
  HALT
chk_ok:
  MOVI r1,0
  RET

puthex8:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  MOVI r2,8
  ST r2,r14,2
ph_l:
  LD r1,r14,1
  SHR r3,r1,28
  MOVI r4,15
  BOOL.8 r3,r3,r4
  MOVI r4,10
  CMP r3,r4
  JMP[LT] @ph_dig
  ADDI r3,r3,55
  JMP @ph_out
ph_dig:
  ADDI r3,r3,48
ph_out:
  PUTC r3
  LD r1,r14,1
  SHL r1,r1,4
  ST r1,r14,1
  LD r2,r14,2
  SUB r2,r2,r13
  ST r2,r14,2
  CMP r2,r0
  JMP[GT] @ph_l
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

putdec3:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  MOVI r2,100
  DIVU r3,r1,r2
  MOVI r4,48
  ADD r3,r3,r4
  PUTC r3
  LD r1,r14,1
  MOVI r2,100
  MODU r1,r1,r2
  MOVI r2,10
  DIVU r3,r1,r2
  ADD r3,r3,r4
  PUTC r3
  MODU r1,r1,r2
  ADD r1,r1,r4
  PUTC r1
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

copyw:
  CMP r3,r0
  JMP[EQ] @cw_ok
  LD r4,r2,0
  ST r4,r1,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  SUB r3,r3,r13
  JMP @copyw
cw_ok:
  RET

cmpbuf:
  CMP r3,r0
  JMP[EQ] @cb_ok
  LD r4,r1,0
  LD r5,r2,0
  CMP r4,r5
  JMP[NE] @cb_bad
  ADD r1,r1,r13
  ADD r2,r2,r13
  SUB r3,r3,r13
  JMP @cmpbuf
cb_bad:
  MOVI r1,1
  RET
cb_ok:
  MOVI r1,0
  RET

.equ STK 0x23000
.equ STORE 0x364000

.org 0x24000
ctx1:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ctx2:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ctx3:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ctx4:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tab1:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tab2:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tab3:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tab4:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ci:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
mi:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
proot:
.word 0
phlo:
.word 0
phhi:
.word 0
p0idx:
.word 0
p1idx:
.word 0
q1idx:
.word 0
p0slot:
.word 0
p1slot:
.word 0
q1slot:
.word 0
mslot:
.word 0
mroot:
.word 0
p0hlo:
.word 0
p0hhi:
.word 0
p1hlo:
.word 0
p1hhi:
.word 0
q1hlo:
.word 0
q1hhi:
.word 0
mhlo:
.word 0
mhhi:
.word 0
gslot:
.word 0
mvals:
.word 0xA000,0xA001
mpars:
.word 0,0
gvals:
.word 0x111,0x222,0x333
cfg:
.word 0,0,0,0,0,0,0,0,0,0,0,0
recbuf:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
recq1:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
pout:
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
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0
mout:
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
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0
tokout:
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
mtok:
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
pp0:
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
pp1:
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
pq1:
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
pm:
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
pt1:
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
pt0:
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
ptq:
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
ptm:
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
pmut:
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
statsbuf:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
nkmstats:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
st:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
v:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
vo:
.word 0,0
stbackup:
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
pdata:
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
.org 0x40000
snapA:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.org 0x42000
snapB:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
