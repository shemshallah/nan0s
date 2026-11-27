; nkvmerkle_test.nas - Merkle multi-parent prefix DAG and root-only proofs
; (F13j).
;
; Scenario, repeated from a cold init for each close order and then twice for
; the deterministic snapshot:
;   four nagent records and four ngen agents.  Agent 1 reaches gen 5 and builds
;   a 10-token prefix P over two pages.  Seal hashes both pages with the
;   documented content+ordered-parent-hash+used+generation mix; P1 commits P0
;   as its parent and P1 is the prefix root.
;   Agent 3 joins P by root hash and agent 4 late-joins the same DAG.  Agent 2
;   at the same generation 5 builds a 16-token prefix Q whose first page is
;   identical to P0: seal finds the same node hash and identical committed
;   fields, increments dedup/refs, and creates no second header.  Q1 commits P0
;   as its parent.  P0 is now shared by four agents and two child nodes.
;   Branch 1 publishes gen 6.  A fresh gen-6 merge context publishes M with two
;   ordered parents {P1,Q1} and gen-6 content.  M is therefore a genuine
;   multi-parent prefix root; P0 has two distinct root paths, M->P1->P0 and
;   M->Q1->P0.
;   Inclusion page proofs for P0 and Q1 and token proofs for P1[1] and P0[3]
;   are generated from M and verified from the M root hash alone.  Mutating
;   content, parent hash, generation tag, used count, token value/offset,
;   target hash, root field, parent order or proof depth fails; verification
;   never reads the node registry.
;   Each branch appends a divergent suffix.  Branches 1/3/4 COW exactly the
;   shared 2-token P1 boundary page; branch 2 starts a private third page.
;   Close order A (4,3,2,1,5) and B (5,1,2,3,4) both free every node at zero
;   refs, including the parent-reference cascade through M.
;   An orphan gen-6 context then joins the old P and Q roots and gets ENOENT.
;   After every node is gone, the saved P0 page proof still verifies from the
;   saved root hash, proving root-only checkpoint verification.
;   All alloc/free/ref/dedup/join/COW/header counters, node headers, table
;   slots, nagent KV roots and ngen states are exact.  Four cold runs produce
;   two identical 6816-word snapshots.
;
; Success prints exactly O.  A failed check prints F=actual,expected,diag.

.org 0
JMP @main

.org 0x10000
.include "../lib/nkvmerkle.nas"

main:
MOVI r13,1
MOVI r14,0x7000

; ---- close order A, cold run 1
CALL @cold
CALL @setup
MOVI r1,1
CALL @scenario
LA r1,@snapA1
CALL @snapshot

; ---- close order B, cold run 1
CALL @cold
CALL @setup
MOVI r1,2
CALL @scenario
LA r1,@snapB1
CALL @snapshot

; ---- close order A, cold run 2
CALL @cold
CALL @setup
MOVI r1,1
CALL @scenario
LA r1,@snapA2
CALL @snapshot

; ---- close order B, cold run 2
CALL @cold
CALL @setup
MOVI r1,2
CALL @scenario
LA r1,@snapB2
CALL @snapshot

; ---- deterministic rerun, both close orders
LA r1,@snapA1
LA r2,@snapA2
MOVI r3,6816
CALL @cmpbuf
MOVI r2,0
MOVI r3,900
CALL @chk
LA r1,@snapB1
LA r2,@snapB2
MOVI r3,6816
CALL @cmpbuf
MOVI r2,0
MOVI r3,901
CALL @chk

MOVI r1,79
PUTC r1
HALT

; ---------------------------------------------------------------------------
; cold - full cold init: agents, generations, Merkle registry.
cold:
  ST r15,r14,0
  ADDI r14,r14,16
  CALL @nagent_init
  CALL @ngen_init
  LA r1,@pdata
  MOVI r2,32
  CALL @nkm_init
  MOVI r2,0
  MOVI r3,1
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; setup - four nagent records and ngen agents 1..4 at generations 5,5,3,4.
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
  MOVI r4,187
  CALL @ngen_chk

  MOVI r1,2
  MOVI r2,0x1100
  MOVI r3,0x2100
  CALL @ngen_create
  MOVI r1,2
  MOVI r2,5
  CALL @gen_prep
  MOVI r2,1
  MOVI r3,7
  CALL @chk

  MOVI r1,3
  MOVI r2,0x1200
  MOVI r3,0x2200
  CALL @ngen_create
  MOVI r1,3
  MOVI r2,3
  CALL @gen_prep
  MOVI r2,1
  MOVI r3,8
  CALL @chk

  MOVI r1,4
  MOVI r2,0x1300
  MOVI r3,0x2300
  CALL @ngen_create
  MOVI r1,4
  MOVI r2,4
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
  CMP r1,r0
  JMP[EQ] @gp_bad
  LD r3,r14,3
  ADD r3,r3,r13
  ST r3,r14,3
  JMP @gp_l
gp_ok:
  MOVI r1,1
  JMP @gp_out
gp_bad:
  MOVI r1,0
gp_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; scenario r1=close order (1 = 4,3,2,1,5; 2 = 5,1,2,3,4)
scenario:
  ST r15,r14,0
  ADDI r14,r14,16
  LA r2,@order
  ST r1,r2,0
  CALL @build
  LA r2,@order
  LD r1,r2,0
  MOVI r2,1
  CMP r1,r2
  JMP[EQ] @sc_a
  CALL @close5
  MOVI r1,5
  MOVI r2,200
  CALL @p0_ref_chk
  CALL @close1
  MOVI r1,4
  MOVI r2,201
  CALL @p0_ref_chk
  CALL @close2
  MOVI r1,2
  MOVI r2,202
  CALL @p0_ref_chk
  CALL @close3
  MOVI r1,1
  MOVI r2,203
  CALL @p0_ref_chk
  CALL @close4
  MOVI r1,0
  MOVI r2,204
  CALL @p0_ref_chk
  JMP @sc_b5
sc_a:
  CALL @close4
  MOVI r1,5
  MOVI r2,205
  CALL @p0_ref_chk
  CALL @close3
  MOVI r1,4
  MOVI r2,206
  CALL @p0_ref_chk
  CALL @close2
  MOVI r1,3
  MOVI r2,207
  CALL @p0_ref_chk
  CALL @close1
  MOVI r1,2
  MOVI r2,208
  CALL @p0_ref_chk
  CALL @close5
  MOVI r1,0
  MOVI r2,209
  CALL @p0_ref_chk
sc_b5:
  CALL @after_close
  CALL @orphan
  CALL @final_checks
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; build - P, joins, dedup Q, proofs/mutations, merge, suffixes, pre-close.
build:
  ST r15,r14,0
  ADDI r14,r14,112
  ; ---- b1 open at agent1 gen5
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
  MOVI r2,#NKM_C_USED
  MOVI r3,0
  MOVI r4,186
  CALL @ctx_chk
  LA r1,@ctx1
  MOVI r2,#NKM_C_ADMIT
  MOVI r3,1
  MOVI r4,21
  CALL @ctx_chk

  ; ---- 10-token P over two pages
  LA r1,@ctx1
  MOVI r2,0
  MOVI r3,10
  MOVI r4,0x5000
  CALL @app_seq
  MOVI r2,1
  MOVI r3,22
  CALL @chk
  LA r1,@ctx1
  MOVI r2,#NKM_C_USED
  MOVI r3,10
  MOVI r4,23
  CALL @ctx_chk
  LA r1,@ctx1
  MOVI r2,#NKM_C_LIVE
  MOVI r3,2
  MOVI r4,24
  CALL @ctx_chk

  ; ---- seal P
  LA r1,@ctx1
  CALL @nkm_seal
  MOVI r2,1
  MOVI r3,25
  CALL @chk
  LA r1,@ctx1
  MOVI r2,#NKM_C_SEALED
  MOVI r3,1
  MOVI r4,26
  CALL @ctx_chk
  LA r1,@ctx1
  MOVI r2,#NKM_C_PREFIX
  MOVI r3,2
  MOVI r4,27
  CALL @ctx_chk
  LA r1,@ctx1
  MOVI r2,#NKM_C_DEPTH
  MOVI r3,2
  MOVI r4,28
  CALL @ctx_chk
  MOVI r1,#NKM_G_SEALS
  MOVI r2,1
  MOVI r3,29
  CALL @stats_chk
  MOVI r1,#NKM_G_PHEADERS
  MOVI r2,2
  MOVI r3,30
  CALL @stats_chk
  MOVI r1,#NKM_G_PALLOC
  MOVI r2,2
  MOVI r3,31
  CALL @stats_chk
  MOVI r1,#NKM_G_PRIVALLOC
  MOVI r2,2
  MOVI r3,32
  CALL @stats_chk
  MOVI r1,#NKM_G_PRIVFREE
  MOVI r2,2
  MOVI r3,33
  CALL @stats_chk

  ; ---- save P root and node indexes
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

  ; ---- P node checks
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKM_N_KIND
  MOVI r3,#NKM_K_PUBLIC
  MOVI r4,34
  CALL @node_chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKM_N_USED
  MOVI r3,8
  MOVI r4,35
  CALL @node_chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,2
  MOVI r4,36
  CALL @node_chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKM_N_PCOUNT
  MOVI r3,0
  MOVI r4,37
  CALL @node_chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_USED
  MOVI r3,2
  MOVI r4,38
  CALL @node_chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,1
  MOVI r4,39
  CALL @node_chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_PCOUNT
  MOVI r3,1
  MOVI r4,40
  CALL @node_chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_PIDX
  LA r3,@p0idx
  LD r3,r3,0
  MOVI r4,41
  CALL @node_chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_BGEN
  MOVI r3,5
  MOVI r4,42
  CALL @node_chk

  ; ---- hash reproducibility for P0 and Q1 (after Q exists)
  ; (P0 checked here; Q1 checked below.)

  ; ---- b3 joins P
  LA r1,@ctx3
  MOVI r2,3
  MOVI r3,3
  MOVI r4,2
  MOVI r5,3
  MOVI r6,3
  LA r7,@tab3
  MOVI r8,16
  MOVI r9,8
  CALL @nkm_open
  MOVI r2,1
  MOVI r3,43
  CALL @chk
  LA r1,@ctx3
  LA r2,@phlo
  LD r2,r2,0
  LA r3,@phhi
  LD r3,r3,0
  CALL @nkm_join
  MOVI r2,1
  MOVI r3,44
  CALL @chk
  LA r1,@ctx3
  MOVI r2,#NKM_C_USED
  MOVI r3,10
  MOVI r4,45
  CALL @ctx_chk
  LA r1,@ctx3
  MOVI r2,#NKM_C_LIVE
  MOVI r3,2
  MOVI r4,46
  CALL @ctx_chk
  LA r1,@ctx3
  MOVI r2,#NKM_C_JOINS
  MOVI r3,1
  MOVI r4,47
  CALL @ctx_chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,3
  MOVI r4,48
  CALL @node_chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,2
  MOVI r4,49
  CALL @node_chk
  MOVI r1,#NKM_G_JOINOPS
  MOVI r2,1
  MOVI r3,50
  CALL @stats_chk
  MOVI r1,#NKM_G_JOINREFS
  MOVI r2,2
  MOVI r3,51
  CALL @stats_chk

  ; ---- b2 builds Q at the same gen 5; page 0 dedups P0
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
  MOVI r3,52
  CALL @chk
  LA r1,@ctx2
  MOVI r2,0
  MOVI r3,8
  MOVI r4,0x5000
  CALL @app_seq
  MOVI r2,1
  MOVI r3,53
  CALL @chk
  LA r1,@ctx2
  MOVI r2,8
  MOVI r3,8
  MOVI r4,0x9000
  CALL @app_seq
  MOVI r2,1
  MOVI r3,54
  CALL @chk
  LA r1,@ctx2
  CALL @nkm_seal
  MOVI r2,1
  MOVI r3,55
  CALL @chk
  LA r1,@ctx2
  MOVI r2,#NKM_C_DEDUP
  MOVI r3,1
  MOVI r4,56
  CALL @ctx_chk
  LA r1,@ctx2
  LA r2,@ci
  CALL @nkm_ctx_info
  LA r1,@ci
  MOVI r2,#NKM_C_ROOT
  CALL @fld
  LA r2,@qroot
  ST r1,r2,0
  LA r1,@ci
  MOVI r2,#NKM_C_HLO
  CALL @fld
  LA r2,@qhlo
  ST r1,r2,0
  LA r1,@ci
  MOVI r2,#NKM_C_HHI
  CALL @fld
  LA r2,@qhhi
  ST r1,r2,0
  LA r1,@tab2
  ADDI r1,r1,8
  LD r1,r1,0
  LA r2,@q1idx
  ST r1,r2,0
  ; Q page0 is the exact P0 header; Q1 is a new child of P0
  LA r2,@q1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_USED
  MOVI r3,8
  MOVI r4,57
  CALL @node_chk
  LA r2,@q1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_PIDX
  LA r3,@p0idx
  LD r3,r3,0
  MOVI r4,58
  CALL @node_chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKM_N_DEDUP
  MOVI r3,1
  MOVI r4,59
  CALL @node_chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKM_N_HEADERS
  MOVI r3,1
  MOVI r4,60
  CALL @node_chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,5
  MOVI r4,61
  CALL @node_chk
  LA r2,@q1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,1
  MOVI r4,62
  CALL @node_chk
  LA r2,@q1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_USED
  MOVI r3,8
  MOVI r4,63
  CALL @node_chk
  MOVI r1,#NKM_G_PHEADERS
  MOVI r2,3
  MOVI r3,64
  CALL @stats_chk
  MOVI r1,#NKM_G_DEDUP
  MOVI r2,1
  MOVI r3,65
  CALL @stats_chk

  ; ---- Q1 hash reproducibility from node fields and ordered parent P0
  LA r2,@q1idx
  LD r1,r2,0
  LA r2,@pi
  CALL @nkm_node_info
  LA r1,@pi
  MOVI r2,#NKM_N_PAY
  CALL @fld
  ST r1,r14,1
  LA r1,@pi
  MOVI r2,#NKM_N_USED
  CALL @fld
  ST r1,r14,2
  LA r1,@pi
  MOVI r2,#NKM_N_BGEN
  CALL @fld
  ST r1,r14,3
  LA r2,@p0idx
  LD r2,r2,0
  LA r1,@parr
  ST r2,r1,0
  LD r1,r14,1
  LD r2,r14,2
  LD r3,r14,3
  LA r4,@parr
  MOVI r5,1
  CALL @nkm_hash
  ST r1,r14,4
  ST r2,r14,5
  LA r1,@pi
  MOVI r2,#NKM_N_HLO
  CALL @fld
  LD r2,r14,4
  MOVI r3,505
  CALL @chk
  LA r1,@pi
  MOVI r2,#NKM_N_HHI
  CALL @fld
  LD r2,r14,5
  MOVI r3,506
  CALL @chk

  ; ---- b4 late-joins P
  LA r1,@ctx4
  MOVI r2,4
  MOVI r3,4
  MOVI r4,3
  MOVI r5,4
  MOVI r6,4
  LA r7,@tab4
  MOVI r8,16
  MOVI r9,8
  CALL @nkm_open
  MOVI r2,1
  MOVI r3,66
  CALL @chk
  LA r1,@ctx4
  LA r2,@phlo
  LD r2,r2,0
  LA r3,@phhi
  LD r3,r3,0
  CALL @nkm_join
  MOVI r2,1
  MOVI r3,67
  CALL @chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,6
  MOVI r4,68
  CALL @node_chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,3
  MOVI r4,69
  CALL @node_chk
  MOVI r1,#NKM_G_JOINOPS
  MOVI r2,2
  MOVI r3,70
  CALL @stats_chk
  MOVI r1,#NKM_G_JOINREFS
  MOVI r2,4
  MOVI r3,71
  CALL @stats_chk

  ; ---- hash reproducibility from node fields
  LA r2,@p0idx
  LD r1,r2,0
  LA r2,@pi
  CALL @nkm_node_info
  LA r1,@pi
  MOVI r2,#NKM_N_PAY
  CALL @fld
  ST r1,r14,1
  LA r1,@pi
  MOVI r2,#NKM_N_USED
  CALL @fld
  ST r1,r14,2
  LA r1,@pi
  MOVI r2,#NKM_N_BGEN
  CALL @fld
  ST r1,r14,3
  LD r1,r14,1
  LD r2,r14,2
  LD r3,r14,3
  MOVI r4,0
  MOVI r5,0
  CALL @nkm_hash
  ST r1,r14,4
  ST r2,r14,5
  LA r1,@pi
  MOVI r2,#NKM_N_HLO
  CALL @fld
  LD r2,r14,4
  MOVI r3,72
  CALL @chk
  LA r1,@pi
  MOVI r2,#NKM_N_HHI
  CALL @fld
  LD r2,r14,5
  MOVI r3,73
  CALL @chk

  ; ---- views: shared read, cross-generation setup, shared write
  LA r1,@ctx1
  MOVI r2,0
  MOVI r3,1
  LA r4,@vShared
  CALL @nkm_view_open
  MOVI r2,1
  MOVI r3,74
  CALL @chk
  LA r1,@ctx1
  LA r2,@vShared
  LA r3,@vo
  CALL @nkm_view_read
  MOVI r2,1
  MOVI r3,75
  CALL @chk
  LA r1,@vo
  MOVI r2,0
  CALL @fld
  MOVI r2,0x5000
  MOVI r3,76
  CALL @chk
  LA r1,@ctx1
  MOVI r2,0
  MOVI r3,2
  LA r4,@vW
  CALL @nkm_view_open
  MOVI r2,1
  MOVI r3,77
  CALL @chk
  LA r1,@ctx1
  LA r2,@vW
  MOVI r3,0xBAD
  CALL @write_fail
  MOVI r2,#NKM_ESHARED
  MOVI r3,78
  CALL @chk
  MOVI r1,#NKM_G_XSHARED
  MOVI r2,1
  MOVI r3,79
  CALL @stats_chk

  ; ---- publish gen6; old-gen open fails; fresh gen6 rejects old view
  LA r1,@ctx1
  MOVI r2,6
  CALL @nkm_publish
  CMP r1,r0
  JMP[NE] @pub_ok
  MOVI r1,0
  MOVI r2,1
  MOVI r3,80
  CALL @chk
pub_ok:
  MOVI r1,1
  MOVI r2,5
  LA r3,@slot
  CALL @ngen_slot
  LA r1,@slot
  MOVI r2,1
  CALL @fld
  MOVI r2,#NG_S_DRAINING
  MOVI r3,194
  CALL @chk
  LA r1,@ctxOld
  MOVI r2,1
  MOVI r3,5
  MOVI r4,4
  MOVI r5,9
  MOVI r6,1
  LA r7,@tabOld
  MOVI r8,4
  MOVI r9,8
  CALL @nkm_open
  MOVI r2,0
  MOVI r3,81
  CALL @chk
  CALL @nkm_errno
  MOVI r2,#NKM_ESTALE
  MOVI r3,82
  CALL @chk
  LA r1,@ctxOld
  MOVI r2,#NKM_C_NGERR
  MOVI r3,#NG_EDRAIN
  MOVI r4,83
  CALL @ctx_chk
  MOVI r1,#NKM_G_XSTALE
  MOVI r2,1
  MOVI r3,84
  CALL @stats_chk

  ; merge context at agent1 gen6
  LA r1,@ctx5
  MOVI r2,1
  MOVI r3,6
  MOVI r4,4
  MOVI r5,5
  MOVI r6,1
  LA r7,@tab5
  MOVI r8,4
  MOVI r9,8
  CALL @nkm_open
  MOVI r2,1
  MOVI r3,85
  CALL @chk
  LA r1,@ctx5
  LA r2,@vShared
  LA r3,@vo
  CALL @read_fail
  MOVI r2,#NKM_EGEN
  MOVI r3,86
  CALL @chk
  MOVI r1,#NKM_G_XGEN
  MOVI r2,1
  MOVI r3,87
  CALL @stats_chk

  ; b1 (gen5, DRAINING) still reads its admitted snapshot
  LA r1,@ctx1
  LA r2,@vShared
  LA r3,@vo
  CALL @nkm_view_read
  MOVI r2,1
  MOVI r3,88
  CALL @chk
  LA r1,@vo
  MOVI r2,0
  CALL @fld
  MOVI r2,0x5000
  MOVI r3,89
  CALL @chk

  ; unknown root
  LA r1,@ctx5
  MOVI r2,0xDEAD
  MOVI r3,0xBEEF
  CALL @nkm_join
  MOVI r2,0
  MOVI r3,90
  CALL @chk
  CALL @nkm_errno
  MOVI r2,#NKM_ENOENT
  MOVI r3,91
  CALL @chk

  ; duplicate seal and referenced free rejections
  LA r1,@ctx1
  CALL @nkm_seal
  MOVI r2,0
  MOVI r3,92
  CALL @chk
  CALL @nkm_errno
  MOVI r2,#NKM_EDUP
  MOVI r3,93
  CALL @chk
  MOVI r1,#NKM_G_XDUP
  MOVI r2,1
  MOVI r3,94
  CALL @stats_chk
  LA r2,@p0idx
  LD r1,r2,0
  CALL @nkm_node_free
  MOVI r2,0
  MOVI r3,95
  CALL @chk
  CALL @nkm_errno
  MOVI r2,#NKM_EREF
  MOVI r3,96
  CALL @chk
  MOVI r1,#NKM_G_XREF
  MOVI r2,1
  MOVI r3,97
  CALL @stats_chk

  ; ---- multi-parent merge M {P1,Q1} at gen6
  LA r1,@p1idx
  LD r1,r1,0
  LA r2,@mpars
  ST r1,r2,0
  LA r1,@q1idx
  LD r1,r1,0
  ST r1,r2,1
  LA r1,@ctx5
  LA r2,@mvals
  MOVI r3,2
  LA r4,@mpars
  MOVI r5,2
  CALL @nkm_merge_n
  LA r2,@mroot
  ST r1,r2,0
  LA r2,#NKM_NONE
  CMP r1,r2
  JMP[NE] @merge_ok
  MOVI r1,0
  MOVI r2,1
  MOVI r3,98
  CALL @chk
merge_ok:
  LA r1,@mroot
  LD r1,r1,0
  LA r2,@mi
  CALL @nkm_node_info
  LA r1,@mi
  MOVI r2,#NKM_N_USED
  CALL @fld
  MOVI r2,2
  MOVI r3,99
  CALL @chk
  LA r1,@mi
  MOVI r2,#NKM_N_PCOUNT
  CALL @fld
  MOVI r2,2
  MOVI r3,100
  CALL @chk
  LA r1,@mi
  MOVI r2,#NKM_N_BGEN
  CALL @fld
  MOVI r2,6
  MOVI r3,101
  CALL @chk
  LA r1,@mi
  MOVI r2,#NKM_N_PIDX
  CALL @fld
  LA r2,@p1idx
  LD r2,r2,0
  MOVI r3,102
  CALL @chk
  LA r1,@mi
  MOVI r2,#NKM_N_PIDX
  ADD r1,r1,r2
  ADDI r1,r1,1
  LD r1,r1,0
  LA r2,@q1idx
  LD r2,r2,0
  MOVI r3,103
  CALL @chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,4
  MOVI r4,104
  CALL @node_chk
  LA r2,@q1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,2
  MOVI r4,105
  CALL @node_chk
  LA r2,@mroot
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,1
  MOVI r4,106
  CALL @node_chk
  MOVI r1,#NKM_G_MERGES
  MOVI r2,1
  MOVI r3,107
  CALL @stats_chk
  MOVI r1,#NKM_G_PHEADERS
  MOVI r2,4
  MOVI r3,108
  CALL @stats_chk

  ; save M hashes for root-only verification
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

  ; root commitment metadata from the merge context
  LA r1,@ctx5
  LA r2,@ri
  CALL @nkm_root_info
  LA r1,@ri
  MOVI r2,0
  CALL @fld
  LA r2,@mhlo
  LD r2,r2,0
  MOVI r3,500
  CALL @chk
  LA r1,@ri
  MOVI r2,1
  CALL @fld
  LA r2,@mhhi
  LD r2,r2,0
  MOVI r3,501
  CALL @chk
  LA r1,@ri
  MOVI r2,2
  CALL @fld
  LA r2,@mroot
  LD r2,r2,0
  MOVI r3,502
  CALL @chk
  LA r1,@ri
  MOVI r2,3
  CALL @fld
  MOVI r2,2
  MOVI r3,503
  CALL @chk
  LA r1,@ri
  MOVI r2,7
  CALL @fld
  MOVI r2,1
  MOVI r3,504
  CALL @chk

  ; ---- page P0 proof from M, verify from M hash only
  LA r1,@mroot
  LD r1,r1,0
  LA r2,@p0idx
  LD r2,r2,0
  LA r3,#NKM_NONE
  LA r4,@pp0
  CALL @nkm_proof
  MOVI r2,1
  MOVI r3,109
  CALL @chk
  LA r1,@pp0
  MOVI r2,#NKM_P_DEPTH
  CALL @fld
  MOVI r2,3
  MOVI r3,110
  CALL @chk
  LA r1,@pp0
  MOVI r2,#NKM_P_MODE
  CALL @fld
  MOVI r2,1
  MOVI r3,111
  CALL @chk
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@pp0
  CALL @nkm_proof_verify
  MOVI r2,1
  MOVI r3,112
  CALL @chk

  ; ---- page Q1 proof from M
  LA r1,@mroot
  LD r1,r1,0
  LA r2,@q1idx
  LD r2,r2,0
  LA r3,#NKM_NONE
  LA r4,@pq1
  CALL @nkm_proof
  MOVI r2,1
  MOVI r3,113
  CALL @chk
  LA r1,@pq1
  MOVI r2,#NKM_P_DEPTH
  CALL @fld
  MOVI r2,2
  MOVI r3,114
  CALL @chk
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@pq1
  CALL @nkm_proof_verify
  MOVI r2,1
  MOVI r3,115
  CALL @chk

  ; ---- token P1[1] = 0x5009
  LA r1,@mroot
  LD r1,r1,0
  LA r2,@p1idx
  LD r2,r2,0
  MOVI r3,1
  LA r4,@pt1
  CALL @nkm_proof
  MOVI r2,1
  MOVI r3,116
  CALL @chk
  LA r1,@pt1
  MOVI r2,#NKM_P_MODE
  CALL @fld
  MOVI r2,2
  MOVI r3,117
  CALL @chk
  LA r1,@pt1
  MOVI r2,#NKM_P_TOKOFF
  CALL @fld
  MOVI r2,1
  MOVI r3,118
  CALL @chk
  LA r1,@pt1
  MOVI r2,#NKM_P_TOKVAL
  CALL @fld
  MOVI r2,0x5009
  MOVI r3,119
  CALL @chk
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@pt1
  CALL @nkm_proof_verify
  MOVI r2,1
  MOVI r3,120
  CALL @chk

  ; ---- token P0[3] = 0x5003
  LA r1,@mroot
  LD r1,r1,0
  LA r2,@p0idx
  LD r2,r2,0
  MOVI r3,3
  LA r4,@pt0
  CALL @nkm_proof
  MOVI r2,1
  MOVI r3,121
  CALL @chk
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@pt0
  CALL @nkm_proof_verify
  MOVI r2,1
  MOVI r3,122
  CALL @chk

  ; ---- mutation rejection at each committed field
  LA r1,@pp0
  MOVI r2,27
  MOVI r3,123
  CALL @mut1
  LA r1,@pp0
  MOVI r2,51
  MOVI r3,124
  CALL @mut1
  LA r1,@pp0
  MOVI r2,49
  MOVI r3,125
  CALL @mut1
  LA r1,@pp0
  MOVI r2,48
  MOVI r3,126
  CALL @mut1
  LA r1,@pt1
  MOVI r2,#NKM_P_TOKVAL
  MOVI r3,127
  CALL @mut1
  LA r1,@pt0
  MOVI r2,30
  MOVI r3,128
  CALL @mut1
  LA r1,@pp0
  MOVI r2,#NKM_P_TARGLO
  MOVI r3,129
  CALL @mut1
  LA r1,@pp0
  MOVI r2,#NKM_P_ROOTLO
  MOVI r3,130
  CALL @mut1
  LA r1,@pp0
  MOVI r2,#NKM_P_DEPTH
  MOVI r3,131
  CALL @mut1
  LA r1,@pp0
  MOVI r2,83
  MOVI r3,84
  MOVI r4,132
  CALL @swap2
  MOVI r1,133
  CALL @rootbad

  ; ---- divergent suffixes
  LA r1,@ctx1
  MOVI r2,10
  MOVI r3,3
  MOVI r4,0x6000
  CALL @app_seq
  MOVI r2,1
  MOVI r3,134
  CALL @chk
  LA r1,@ctx1
  MOVI r2,#NKM_C_USED
  MOVI r3,13
  MOVI r4,135
  CALL @ctx_chk
  LA r1,@ctx1
  MOVI r2,#NKM_C_COPIES
  MOVI r3,1
  MOVI r4,136
  CALL @ctx_chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,3
  MOVI r4,137
  CALL @node_chk

  LA r1,@ctx3
  MOVI r2,10
  MOVI r3,3
  MOVI r4,0x7000
  CALL @app_seq
  MOVI r2,1
  MOVI r3,138
  CALL @chk
  LA r1,@ctx3
  MOVI r2,#NKM_C_USED
  MOVI r3,13
  MOVI r4,139
  CALL @ctx_chk
  LA r1,@ctx3
  MOVI r2,#NKM_C_LIVE
  MOVI r3,2
  MOVI r4,140
  CALL @ctx_chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,2
  MOVI r4,141
  CALL @node_chk

  LA r1,@ctx4
  MOVI r2,10
  MOVI r3,2
  MOVI r4,0x8000
  CALL @app_seq
  MOVI r2,1
  MOVI r3,142
  CALL @chk
  LA r1,@ctx4
  MOVI r2,#NKM_C_USED
  MOVI r3,12
  MOVI r4,143
  CALL @ctx_chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,1
  MOVI r4,144
  CALL @node_chk

  LA r1,@ctx2
  MOVI r2,16
  MOVI r3,2
  MOVI r4,0x9100
  CALL @app_seq
  MOVI r2,1
  MOVI r3,145
  CALL @chk
  LA r1,@ctx2
  MOVI r2,#NKM_C_USED
  MOVI r3,18
  MOVI r4,146
  CALL @ctx_chk
  LA r1,@ctx2
  MOVI r2,#NKM_C_LIVE
  MOVI r3,3
  MOVI r4,147
  CALL @ctx_chk
  MOVI r1,#NKM_G_COWS
  MOVI r2,3
  MOVI r3,148
  CALL @stats_chk
  MOVI r1,#NKM_G_TCOPY
  MOVI r2,6
  MOVI r3,149
  CALL @stats_chk

  ; ---- private write succeeds only on the owning generation
  LA r1,@ctx1
  MOVI r2,10
  MOVI r3,2
  LA r4,@vPriv
  CALL @nkm_view_open
  MOVI r2,1
  MOVI r3,150
  CALL @chk
  LA r1,@ctx1
  LA r2,@vPriv
  MOVI r3,0x6AAA
  CALL @nkm_view_write
  MOVI r2,1
  MOVI r3,151
  CALL @chk
  LA r1,@ctx1
  MOVI r2,10
  MOVI r3,1
  LA r4,@vPrivRead
  CALL @nkm_view_open
  MOVI r2,1
  MOVI r3,152
  CALL @chk
  LA r1,@ctx1
  LA r2,@vPrivRead
  LA r3,@vo
  CALL @nkm_view_read
  MOVI r2,1
  MOVI r3,153
  CALL @chk
  LA r1,@vo
  MOVI r2,0
  CALL @fld
  MOVI r2,0x6AAA
  MOVI r3,154
  CALL @chk

  ; ---- isolation ranges
  LA r1,@ctx1
  MOVI r2,0
  MOVI r3,10
  MOVI r4,0x5000
  MOVI r5,300
  CALL @rd_range
  MOVI r2,1
  MOVI r3,155
  CALL @chk
  LA r1,@ctx1
  MOVI r2,11
  MOVI r3,2
  MOVI r4,0x6001
  MOVI r5,310
  CALL @rd_range
  MOVI r2,1
  MOVI r3,156
  CALL @chk
  LA r1,@ctx3
  MOVI r2,0
  MOVI r3,10
  MOVI r4,0x5000
  MOVI r5,320
  CALL @rd_range
  MOVI r2,1
  MOVI r3,157
  CALL @chk
  LA r1,@ctx3
  MOVI r2,10
  MOVI r3,3
  MOVI r4,0x7000
  MOVI r5,330
  CALL @rd_range
  MOVI r2,1
  MOVI r3,158
  CALL @chk
  LA r1,@ctx4
  MOVI r2,10
  MOVI r3,2
  MOVI r4,0x8000
  MOVI r5,340
  CALL @rd_range
  MOVI r2,1
  MOVI r3,159
  CALL @chk
  LA r1,@ctx2
  MOVI r2,0
  MOVI r3,8
  MOVI r4,0x5000
  MOVI r5,350
  CALL @rd_range
  MOVI r2,1
  MOVI r3,160
  CALL @chk
  LA r1,@ctx2
  MOVI r2,8
  MOVI r3,8
  MOVI r4,0x9000
  MOVI r5,360
  CALL @rd_range
  MOVI r2,1
  MOVI r3,161
  CALL @chk
  LA r1,@ctx2
  MOVI r2,16
  MOVI r3,2
  MOVI r4,0x9100
  MOVI r5,370
  CALL @rd_range
  MOVI r2,1
  MOVI r3,162
  CALL @chk

  ; ---- pre-close refs and totals
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,6
  MOVI r4,163
  CALL @node_chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,1
  MOVI r4,164
  CALL @node_chk
  LA r2,@q1idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,2
  MOVI r4,165
  CALL @node_chk
  LA r2,@mroot
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  MOVI r3,1
  MOVI r4,166
  CALL @node_chk

  MOVI r1,#NKM_G_LIVE
  MOVI r2,8
  MOVI r3,167
  CALL @stats_chk
  MOVI r1,#NKM_G_PUBLIVE
  MOVI r2,4
  MOVI r3,168
  CALL @stats_chk
  MOVI r1,#NKM_G_PALLOC
  MOVI r2,4
  MOVI r3,169
  CALL @stats_chk
  MOVI r1,#NKM_G_PRIVALLOC
  MOVI r2,8
  MOVI r3,170
  CALL @stats_chk
  MOVI r1,#NKM_G_PRIVFREE
  MOVI r2,4
  MOVI r3,171
  CALL @stats_chk
  MOVI r1,#NKM_G_REFS
  MOVI r2,21
  MOVI r3,172
  CALL @stats_chk
  MOVI r1,#NKM_G_RELS
  MOVI r2,7
  MOVI r3,173
  CALL @stats_chk
  MOVI r1,#NKM_G_DEDUP
  MOVI r2,1
  MOVI r3,174
  CALL @stats_chk
  MOVI r1,#NKM_G_SEALS
  MOVI r2,2
  MOVI r3,175
  CALL @stats_chk
  MOVI r1,#NKM_G_ROOTS
  MOVI r2,5
  MOVI r3,176
  CALL @stats_chk
  MOVI r1,#NKM_G_PROOFS
  MOVI r2,4
  MOVI r3,177
  CALL @stats_chk
  MOVI r1,#NKM_G_VERIFIES
  MOVI r2,4
  MOVI r3,178
  CALL @stats_chk
  MOVI r1,#NKM_G_XPROOF
  MOVI r2,11
  MOVI r3,179
  CALL @stats_chk

  ; ---- nagent KV roots (P/Q/M bindings)
  MOVI r1,1
  MOVI r2,#NAG_KVROOT_F
  LA r3,@mhlo
  LD r3,r3,0
  MOVI r4,180
  CALL @rec_chk
  MOVI r1,1
  MOVI r2,#NAG_KVGEN_F
  MOVI r3,2
  MOVI r4,181
  CALL @rec_chk
  MOVI r1,2
  MOVI r2,#NAG_KVROOT_F
  LA r3,@qhlo
  LD r3,r3,0
  MOVI r4,182
  CALL @rec_chk
  MOVI r1,3
  MOVI r2,#NAG_KVROOT_F
  LA r3,@phlo
  LD r3,r3,0
  MOVI r4,183
  CALL @rec_chk
  MOVI r1,4
  MOVI r2,#NAG_KVROOT_F
  LA r3,@phlo
  LD r3,r3,0
  MOVI r4,184
  CALL @rec_chk

  ADDI r14,r14,-112
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; p0_ref_chk r1=expected refs r2=diag.
p0_ref_chk:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  ST r2,r14,2
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKM_N_REFS
  LD r3,r14,1
  LD r4,r14,2
  CALL @node_chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; close helpers
close1:
  ST r15,r14,0
  ADDI r14,r14,16
  LA r1,@ctx1
  CALL @nkm_close
  MOVI r2,1
  MOVI r3,400
  CALL @chk
  MOVI r1,1
  MOVI r2,5
  LA r3,@slot
  CALL @ngen_slot
  LA r1,@slot
  MOVI r2,1
  CALL @fld
  MOVI r2,#NG_S_DRAINED
  MOVI r3,195
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

close2:
  ST r15,r14,0
  ADDI r14,r14,16
  LA r1,@ctx2
  CALL @nkm_close
  MOVI r2,1
  MOVI r3,401
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

close3:
  ST r15,r14,0
  ADDI r14,r14,16
  LA r1,@ctx3
  CALL @nkm_close
  MOVI r2,1
  MOVI r3,402
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

close4:
  ST r15,r14,0
  ADDI r14,r14,16
  LA r1,@ctx4
  CALL @nkm_close
  MOVI r2,1
  MOVI r3,403
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

close5:
  ST r15,r14,0
  ADDI r14,r14,16
  LA r1,@ctx5
  CALL @nkm_close
  MOVI r2,1
  MOVI r3,404
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; after_close - every public and private node left at refcount zero.
after_close:
  ST r15,r14,0
  ADDI r14,r14,16
  MOVI r1,#NKM_G_LIVE
  MOVI r2,0
  MOVI r3,405
  CALL @stats_chk
  MOVI r1,#NKM_G_PUBLIVE
  MOVI r2,0
  MOVI r3,406
  CALL @stats_chk
  MOVI r1,#NKM_G_PHEADERS
  MOVI r2,4
  MOVI r3,407
  CALL @stats_chk
  MOVI r1,#NKM_G_PALLOC
  MOVI r2,4
  MOVI r3,408
  CALL @stats_chk
  MOVI r1,#NKM_G_PFREE
  MOVI r2,4
  MOVI r3,409
  CALL @stats_chk
  MOVI r1,#NKM_G_PRIVALLOC
  MOVI r2,8
  MOVI r3,410
  CALL @stats_chk
  MOVI r1,#NKM_G_PRIVFREE
  MOVI r2,8
  MOVI r3,411
  CALL @stats_chk
  MOVI r1,#NKM_G_REFS
  MOVI r2,21
  MOVI r3,412
  CALL @stats_chk
  MOVI r1,#NKM_G_RELS
  MOVI r2,21
  MOVI r3,413
  CALL @stats_chk
  MOVI r1,#NKM_G_LEAVES
  MOVI r2,21
  MOVI r3,414
  CALL @stats_chk
  MOVI r1,#NKM_G_COWS
  MOVI r2,3
  MOVI r3,415
  CALL @stats_chk
  MOVI r1,#NKM_G_TCOPY
  MOVI r2,6
  MOVI r3,416
  CALL @stats_chk
  MOVI r1,#NKM_G_OPENS
  MOVI r2,5
  MOVI r3,417
  CALL @stats_chk
  MOVI r1,#NKM_G_CLOSES
  MOVI r2,5
  MOVI r3,418
  CALL @stats_chk
  ; P and Q roots are unreachable after the last close
  LA r1,@phlo
  LD r1,r1,0
  LA r2,@phhi
  LD r2,r2,0
  CALL @nkm_node_find
  LA r2,#NKM_NONE
  MOVI r3,419
  CALL @chk
  LA r1,@qhlo
  LD r1,r1,0
  LA r2,@qhhi
  LD r2,r2,0
  CALL @nkm_node_find
  LA r2,#NKM_NONE
  MOVI r3,420
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; orphan - a fresh gen6 ctx cannot join roots whose last ref went away.
orphan:
  ST r15,r14,0
  ADDI r14,r14,16
  LA r1,@ctx6
  MOVI r2,1
  MOVI r3,6
  MOVI r4,4
  MOVI r5,7
  MOVI r6,1
  LA r7,@tab6
  MOVI r8,4
  MOVI r9,8
  CALL @nkm_open
  MOVI r2,1
  MOVI r3,421
  CALL @chk
  LA r1,@ctx6
  LA r2,@phlo
  LD r2,r2,0
  LA r3,@phhi
  LD r3,r3,0
  CALL @nkm_join
  MOVI r2,0
  MOVI r3,422
  CALL @chk
  CALL @nkm_errno
  MOVI r2,#NKM_ENOENT
  MOVI r3,423
  CALL @chk
  LA r1,@ctx6
  LA r2,@qhlo
  LD r2,r2,0
  LA r3,@qhhi
  LD r3,r3,0
  CALL @nkm_join
  MOVI r2,0
  MOVI r3,424
  CALL @chk
  CALL @nkm_errno
  MOVI r2,#NKM_ENOENT
  MOVI r3,425
  CALL @chk
  LA r1,@ctx6
  CALL @nkm_close
  MOVI r2,1
  MOVI r3,426
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; final_checks - exact counters after the orphan rejection and close.
final_checks:
  ST r15,r14,0
  ADDI r14,r14,16
  MOVI r1,#NKM_G_LIVE
  MOVI r2,0
  MOVI r3,427
  CALL @stats_chk
  MOVI r1,#NKM_G_OPENS
  MOVI r2,6
  MOVI r3,428
  CALL @stats_chk
  MOVI r1,#NKM_G_CLOSES
  MOVI r2,6
  MOVI r3,429
  CALL @stats_chk
  MOVI r1,#NKM_G_ERRORS
  MOVI r2,19
  MOVI r3,430
  CALL @stats_chk
  MOVI r1,#NKM_G_XDUP
  MOVI r2,1
  MOVI r3,431
  CALL @stats_chk
  MOVI r1,#NKM_G_XREF
  MOVI r2,1
  MOVI r3,432
  CALL @stats_chk
  MOVI r1,#NKM_G_XSHARED
  MOVI r2,1
  MOVI r3,433
  CALL @stats_chk
  MOVI r1,#NKM_G_XSTALE
  MOVI r2,1
  MOVI r3,434
  CALL @stats_chk
  MOVI r1,#NKM_G_XGEN
  MOVI r2,1
  MOVI r3,435
  CALL @stats_chk
  MOVI r1,#NKM_G_XPROOF
  MOVI r2,11
  MOVI r3,436
  CALL @stats_chk
  ; ngen end states
  MOVI r1,1
  MOVI r2,3
  MOVI r3,6
  MOVI r4,437
  CALL @ngen_chk
  MOVI r1,2
  MOVI r2,3
  MOVI r3,5
  MOVI r4,438
  CALL @ngen_chk
  MOVI r1,3
  MOVI r2,3
  MOVI r3,3
  MOVI r4,439
  CALL @ngen_chk
  MOVI r1,4
  MOVI r2,3
  MOVI r3,4
  MOVI r4,440
  CALL @ngen_chk
  ; deterministic tree trace: all 46 events, no wrap, first event is OPEN
  MOVI r1,#NKM_G_TEVENTS
  MOVI r2,46
  MOVI r3,507
  CALL @stats_chk
  MOVI r1,#NKM_G_TWRAPS
  MOVI r2,0
  MOVI r3,508
  CALL @stats_chk
  MOVI r1,0
  LA r2,@tr
  CALL @nkm_trace
  LA r1,@tr
  MOVI r2,0
  CALL @fld
  MOVI r2,#NKM_T_OPEN
  MOVI r3,509
  CALL @chk
  ; root-only checkpoint: every node is gone, the saved proof still verifies
  LA r1,@mhlo
  LD r1,r1,0
  LA r2,@mhhi
  LD r2,r2,0
  LA r3,@pp0
  CALL @nkm_proof_verify
  MOVI r2,1
  MOVI r3,441
  CALL @chk
  ADDI r14,r14,-16
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
  ADD r2,r3,r0
  MOVI r3,499
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

; read_fail r1=ctx r2=view r3=out -> errno.
read_fail:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r3,r14,1
  CALL @nkm_view_read
  CMP r1,r0
  JMP[NE] @rf_bad
  CALL @nkm_errno
  JMP @rf_out
rf_bad:
  LA r1,0xFFFFFFFF
rf_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; write_fail r1=ctx r2=view r3=value -> errno.
write_fail:
  ST r15,r14,0
  ADDI r14,r14,24
  CALL @nkm_view_write
  CMP r1,r0
  JMP[NE] @wf_bad
  CALL @nkm_errno
  JMP @wf_out
wf_bad:
  LA r1,0xFFFFFFFF
wf_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; mut1 r1=src proof r2=word offset r3=diag.  Copies the proof, adds one to
; the chosen word, and requires verification to fail with EPROOF.
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
  CALL @nkm_proof_verify
  CMP r1,r0
  JMP[NE] @mut1_bad
  CALL @nkm_errno
  MOVI r2,#NKM_EPROOF
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

; swap2 r1=src r2=off1 r3=off2 r4=diag.  Swap two proof words and require
; verification to fail (ordered parent hashes are committed).
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
  CALL @nkm_proof_verify
  CMP r1,r0
  JMP[NE] @swap2_bad
  CALL @nkm_errno
  MOVI r2,#NKM_EPROOF
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

; rootbad r1=diag: mutate the supplied root hash, keep the proof intact.
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
  CALL @nkm_proof_verify
  CMP r1,r0
  JMP[NE] @rootbad_bad
  CALL @nkm_errno
  MOVI r2,#NKM_EPROOF
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
; snapshot r1=out(6816): 7 contexts, node registry, stats, payload buffer,
; 4 nagent records, 4 ngen statuses, trace ring.
snapshot:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  LA r2,@ctx1
  LD r1,r14,1
  MOVI r3,224
  CALL @copyw
  LA r2,#NKM_NODES
  LD r1,r14,1
  ADDI r1,r1,224
  MOVI r3,3584
  CALL @copyw
  LA r2,#NKM_STATS
  LD r1,r14,1
  ADDI r1,r1,3808
  MOVI r3,64
  CALL @copyw
  LA r2,@pdata
  LD r1,r14,1
  ADDI r1,r1,3872
  MOVI r3,512
  CALL @copyw
  LA r2,#NAG_TAB
  LD r1,r14,1
  ADDI r1,r1,4384
  MOVI r3,1280
  CALL @copyw
  MOVI r1,1
  LD r2,r14,1
  ADDI r2,r2,5664
  CALL @ngen_status
  MOVI r1,2
  LD r2,r14,1
  ADDI r2,r2,5696
  CALL @ngen_status
  MOVI r1,3
  LD r2,r14,1
  ADDI r2,r2,5728
  CALL @ngen_status
  MOVI r1,4
  LD r2,r14,1
  ADDI r2,r2,5760
  CALL @ngen_status
  LA r2,#NKM_TRACE
  LD r1,r14,1
  ADDI r1,r1,5792
  MOVI r3,1024
  CALL @copyw
  ADDI r14,r14,-24
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

; fld r1=base r2=offset -> r1=value
fld:
  ADD r3,r1,r2
  LD r1,r3,0
  RET

; ctx_chk r1=ctx r2=field r3=expected r4=diag
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

; stats_chk r1=field r2=expected r3=diag
stats_chk:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LA r1,@stats
  CALL @nkm_stats
  LA r1,@stats
  LD r2,r14,1
  ADD r1,r1,r2
  LD r1,r1,0
  LD r2,r14,2
  LD r3,r14,3
  CALL @chk
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; node_chk r1=index r2=field r3=expected r4=diag
node_chk:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r2,r14,1
  ST r3,r14,2
  ST r4,r14,3
  LA r2,@ni
  CALL @nkm_node_info
  LA r1,@ni
  LD r2,r14,1
  ADD r1,r1,r2
  LD r1,r1,0
  LD r2,r14,2
  LD r3,r14,3
  CALL @chk
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; rec_chk r1=id r2=field r3=expected r4=diag
rec_chk:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r2,r14,1
  ST r3,r14,2
  ST r4,r14,3
  CALL @nagent_record
  CMP r1,r0
  JMP[NE] @rc_have
  MOVI r1,0
  MOVI r2,1
  MOVI r3,498
  CALL @chk
rc_have:
  LD r2,r14,1
  ADD r1,r1,r2
  LD r1,r1,0
  LD r2,r14,2
  LD r3,r14,3
  CALL @chk
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ngen_chk r1=agent r2=field r3=expected r4=diag
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

; chk r1=actual r2=expected r3=diag.  Failure prints actual,expected,diag.
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

; puthex8 r1=value -> eight uppercase hex digits.
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

; ---------------------------------------------------------------------------
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
ctx5:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ctxOld:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ctx6:
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
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tab5:
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
tab6:
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
tabOld:
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0
ci:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
mi:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
pi:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ni:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
stats:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
st:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
slot:
.word 0,0,0,0,0,0,0,0
vo:
.word 0,0
v:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
vShared:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
vW:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
vPriv:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
vPrivRead:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
order:
.word 0
proot:
.word 0
qroot:
.word 0
mroot:
.word 0
p0idx:
.word 0
p1idx:
.word 0
q1idx:
.word 0
phlo:
.word 0
phhi:
.word 0
qhlo:
.word 0
qhhi:
.word 0
p1hlo:
.word 0
p1hhi:
.word 0
mhlo:
.word 0
mhhi:
.word 0
mvals:
.word 0xA000,0xA001
mpars:
.word 0,0,0,0
parr:
.word 0,0,0,0
ri:
.word 0,0,0,0,0,0,0,0
pi2:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tr:
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
snapA1:
.org 0x42000
snapA2:
.org 0x44000
snapB1:
.org 0x46000
snapB2:
