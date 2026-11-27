; nkvdag_test.nas - content-hash prefix DAG, dedup and late joins (F13i).
;
; Scenario, repeated from a cold init for each close order and then twice for
; the deterministic snapshot:
;   four nagent records and four ngen agents.  Agent 1 reaches gen 5 and its
;   branch builds a 10-token prefix P over two pages.  Seal hashes both page
;   contents and inserts two immutable DAG nodes with one header each; the
;   partial 2-token boundary page is P's root.
;   Agent 3 joins P by root hash, then agent 4 joins later; P0/P1 now have
;   three references.  Agent 2 builds a second 16-token prefix Q whose first
;   page has byte-identical content to P0: seal finds P0 by content hash,
;   increments the dedup counter and reference count, creates no second
;   header, and links the new Q1 node behind P0.  P0 now has four references
;   from four agents, one dedup hit and one header.
;   Branch 1 publishes gen 6; a new ctx at the old gen 5 fails ESTALE with
;   ngen EDRAIN while the old ctx keeps reading as a DRAINING snapshot; a
;   fresh gen-6 ctx rejects the gen-5 view with EGEN.  A shared-page write is
;   ESHARED.  Unknown-root join is ENOENT.
;   Each branch appends a divergent suffix; branch 1 COW-copies the 2-token
;   boundary page, branches 3 and 4 do the same, and the final COW frees P1
;   at refcount zero.  Branch 2's extra page stays private.  Private writes
;   succeed only on the owning generation.
;   Close order A (4,3,2,1,1b) and B (1,2,3,4,1b) both free P0 only when the
;   last sharer leaves; Q1 and all private pages free at zero refs.  An
;   orphan ctx then joins the old P and Q roots and gets ENOENT.
;   All alloc/free/ref/dedup/join/COW/header counters, node headers, table
;   slots, nagent KV roots and ngen states are exact.  Four cold runs produce
;   two identical 5280-word snapshots.
;
; Success prints exactly O.  A failed check prints F=actual,expected,diag.

.org 0
JMP @main

.org 0x10000
.include "../lib/nkvdag.nas"

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
MOVI r3,5280
CALL @cmpbuf
MOVI r2,0
MOVI r3,900
CALL @chk
LA r1,@snapB1
LA r2,@snapB2
MOVI r3,5280
CALL @cmpbuf
MOVI r2,0
MOVI r3,901
CALL @chk

MOVI r1,79
PUTC r1
HALT

; ---------------------------------------------------------------------------
; cold - full cold init: agents, generations, DAG registry.
cold:
  ST r15,r14,0
  ADDI r14,r14,16
  CALL @nagent_init
  CALL @ngen_init
  LA r1,@pdata
  MOVI r2,32
  CALL @nkd_init
  MOVI r2,0
  MOVI r3,1
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; setup - four nagent records and ngen agents 1..4 at generations 5,2,3,4.
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
  MOVI r2,2
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
; scenario r1=close order (1 = 4,3,2,1,1b; 2 = 1,2,3,4,1b)
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
  CALL @close1
  MOVI r1,3
  MOVI r2,196
  CALL @p0_ref_chk
  CALL @close2
  MOVI r1,2
  MOVI r2,197
  CALL @p0_ref_chk
  CALL @close3
  MOVI r1,1
  MOVI r2,198
  CALL @p0_ref_chk
  CALL @close4
  MOVI r1,0
  MOVI r2,199
  CALL @p0_ref_chk
  JMP @sc_b5
sc_a:
  CALL @close4
  MOVI r1,3
  MOVI r2,200
  CALL @p0_ref_chk
  CALL @close3
  MOVI r1,2
  MOVI r2,201
  CALL @p0_ref_chk
  CALL @close2
  MOVI r1,1
  MOVI r2,202
  CALL @p0_ref_chk
  CALL @close1
  MOVI r1,0
  MOVI r2,203
  CALL @p0_ref_chk
sc_b5:
  CALL @close5
  CALL @after_close
  CALL @orphan
  CALL @final_checks
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; build - open b1, seal P, join b3/b4, build/dedup Q, views, publish, appends.
build:
  ST r15,r14,0
  ADDI r14,r14,64
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
  CALL @nkd_open
  MOVI r2,1
  MOVI r3,20
  CALL @chk
  LA r1,@ctx1
  MOVI r2,#NKD_C_USED
  MOVI r3,0
  MOVI r4,186
  CALL @ctx_chk
  LA r1,@ctx1
  MOVI r2,#NKD_C_ADMIT
  MOVI r3,1
  MOVI r4,21
  CALL @ctx_chk
  LA r1,@ctx1
  MOVI r2,#NKD_C_AGENT
  MOVI r3,1
  MOVI r4,22
  CALL @ctx_chk
  LA r1,@ctx1
  MOVI r2,#NKD_C_GEN
  MOVI r3,5
  MOVI r4,23
  CALL @ctx_chk
  LA r1,@ctx1
  MOVI r2,#NKD_C_NAGENT
  MOVI r3,1
  MOVI r4,24
  CALL @ctx_chk
  MOVI r1,#NKD_G_OPENS
  MOVI r2,1
  MOVI r3,25
  CALL @stats_chk

  ; ---- 10-token P over two pages
  LA r1,@ctx1
  MOVI r2,0
  MOVI r3,10
  MOVI r4,0x5000
  CALL @app_seq
  MOVI r2,1
  MOVI r3,26
  CALL @chk
  LA r1,@ctx1
  MOVI r2,#NKD_C_USED
  MOVI r3,10
  MOVI r4,27
  CALL @ctx_chk
  LA r1,@ctx1
  MOVI r2,#NKD_C_LIVE
  MOVI r3,2
  MOVI r4,28
  CALL @ctx_chk
  LA r1,@ctx1
  MOVI r2,#NKD_C_COPIES
  MOVI r3,0
  MOVI r4,29
  CALL @ctx_chk
  LA r2,@tab1
  LD r1,r2,0
  MOVI r2,#NKD_N_STATE
  MOVI r3,1
  MOVI r4,189
  CALL @node_chk
  LA r2,@tab1
  LD r1,r2,0
  MOVI r2,#NKD_N_USED
  MOVI r3,8
  MOVI r4,190
  CALL @node_chk
  LA r2,@tab1
  ADDI r2,r2,8
  LD r1,r2,0
  MOVI r2,#NKD_N_STATE
  MOVI r3,1
  MOVI r4,191
  CALL @node_chk

  ; ---- seal
  LA r1,@ctx1
  CALL @nkd_seal
  MOVI r2,1
  MOVI r3,30
  CALL @chk
  LA r1,@ctx1
  MOVI r2,#NKD_C_SEALED
  MOVI r3,1
  MOVI r4,31
  CALL @ctx_chk
  LA r1,@ctx1
  MOVI r2,#NKD_C_PREFIX
  MOVI r3,2
  MOVI r4,32
  CALL @ctx_chk
  LA r1,@ctx1
  MOVI r2,#NKD_C_DEPTH
  MOVI r3,2
  MOVI r4,33
  CALL @ctx_chk
  MOVI r1,#NKD_G_SEALS
  MOVI r2,1
  MOVI r3,34
  CALL @stats_chk
  MOVI r1,#NKD_G_DHEADERS
  MOVI r2,2
  MOVI r3,35
  CALL @stats_chk
  MOVI r1,#NKD_G_DAGLIVE
  MOVI r2,2
  MOVI r3,36
  CALL @stats_chk
  MOVI r1,#NKD_G_PALLOC
  MOVI r2,2
  MOVI r3,37
  CALL @stats_chk
  MOVI r1,#NKD_G_PFREE
  MOVI r2,2
  MOVI r3,38
  CALL @stats_chk
  MOVI r1,#NKD_G_REFS
  MOVI r2,4
  MOVI r3,39
  CALL @stats_chk

  ; ---- save P root and node indexes
  LA r1,@ci
  LA r2,@ctx1
  CALL @nkd_ctx_info
  LA r1,@ci
  MOVI r2,#NKD_C_ROOT
  CALL @fld
  LA r2,@proot
  ST r1,r2,0
  LA r1,@ci
  MOVI r2,#NKD_C_HLO
  CALL @fld
  LA r2,@phlo
  ST r1,r2,0
  LA r1,@ci
  MOVI r2,#NKD_C_HHI
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
  ADDI r1,r1,#NKD_E_HLO
  LD r1,r1,0
  LA r2,@p1hlo
  ST r1,r2,0
  LA r1,@tab1
  ADDI r1,r1,8
  ADDI r1,r1,#NKD_E_HHI
  LD r1,r1,0
  LA r2,@p1hhi
  ST r1,r2,0
  ; root node checks
  LA r2,@proot
  LD r1,r2,0
  MOVI r2,#NKD_N_KIND
  MOVI r3,1
  MOVI r4,40
  CALL @node_chk
  LA r2,@proot
  LD r1,r2,0
  MOVI r2,#NKD_N_REFS
  MOVI r3,1
  MOVI r4,41
  CALL @node_chk
  LA r2,@proot
  LD r1,r2,0
  MOVI r2,#NKD_N_USED
  MOVI r3,2
  MOVI r4,42
  CALL @node_chk
  LA r2,@proot
  LD r1,r2,0
  MOVI r2,#NKD_N_HEADERS
  MOVI r3,1
  MOVI r4,43
  CALL @node_chk
  LA r2,@proot
  LD r1,r2,0
  MOVI r2,#NKD_N_BGEN
  MOVI r3,5
  MOVI r4,44
  CALL @node_chk
  LA r2,@proot
  LD r1,r2,0
  MOVI r2,#NKD_N_PREV
  LA r3,@p0idx
  LD r3,r3,0
  MOVI r4,45
  CALL @node_chk
  ; P0 node checks
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKD_N_REFS
  MOVI r3,1
  MOVI r4,46
  CALL @node_chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKD_N_USED
  MOVI r3,8
  MOVI r4,47
  CALL @node_chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKD_N_PREV
  LA r3,#NKD_NONE
  MOVI r4,48
  CALL @node_chk

  ; ---- duplicate header / collision / refcount rejections
  LA r1,@ctx1
  CALL @nkd_seal
  MOVI r2,0
  MOVI r3,49
  CALL @chk
  CALL @nkd_errno
  MOVI r2,#NKD_EDUP
  MOVI r3,50
  CALL @chk
  MOVI r1,#NKD_G_ERRORS
  MOVI r2,1
  MOVI r3,51
  CALL @stats_chk
  MOVI r1,#NKD_G_XDUP
  MOVI r2,1
  MOVI r3,52
  CALL @stats_chk

  ; raw add duplicate: same key + same content
  LA r2,@p0idx
  LD r1,r2,0
  LA r2,@ni
  CALL @nkd_node_info
  LA r1,@ni
  MOVI r2,#NKD_N_HLO
  CALL @fld
  ST r1,r14,1
  LA r1,@ni
  MOVI r2,#NKD_N_HHI
  CALL @fld
  ST r1,r14,2
  LA r1,@ni
  MOVI r2,#NKD_N_PAY
  CALL @fld
  ST r1,r14,3
  LA r1,@ni
  MOVI r2,#NKD_N_USED
  CALL @fld
  ST r1,r14,4
  ; the content hash is reproducible from the payload and token count
  LD r1,r14,3
  LD r2,r14,4
  CALL @nkd_hash
  ST r2,r14,5
  LD r2,r14,1
  MOVI r3,192
  CALL @chk
  LD r1,r14,5
  LD r2,r14,2
  MOVI r3,193
  CALL @chk
  LD r1,r14,1
  LD r2,r14,2
  LD r3,r14,3
  LD r4,r14,4
  CALL @nkd_raw_add
  MOVI r2,0
  MOVI r3,53
  CALL @chk
  CALL @nkd_errno
  MOVI r2,#NKD_EDUP
  MOVI r3,54
  CALL @chk
  MOVI r1,#NKD_G_XDUP
  MOVI r2,2
  MOVI r3,55
  CALL @stats_chk

  ; raw add wrong key: collision
  LD r1,r14,1
  ADDI r1,r1,1
  LD r2,r14,2
  LD r3,r14,3
  LD r4,r14,4
  CALL @nkd_raw_add
  MOVI r2,0
  MOVI r3,56
  CALL @chk
  CALL @nkd_errno
  MOVI r2,#NKD_ECOLL
  MOVI r3,57
  CALL @chk
  MOVI r1,#NKD_G_XCOLL
  MOVI r2,1
  MOVI r3,58
  CALL @stats_chk

  ; freeing a referenced node is rejected
  LA r2,@p0idx
  LD r1,r2,0
  CALL @nkd_node_free
  MOVI r2,0
  MOVI r3,59
  CALL @chk
  CALL @nkd_errno
  MOVI r2,#NKD_EREF
  MOVI r3,60
  CALL @chk
  MOVI r1,#NKD_G_XREF
  MOVI r2,1
  MOVI r3,61
  CALL @stats_chk

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
  CALL @nkd_open
  MOVI r2,1
  MOVI r3,62
  CALL @chk
  LA r1,@ctx3
  LA r2,@phlo
  LD r2,r2,0
  LA r3,@phhi
  LD r3,r3,0
  CALL @nkd_join
  MOVI r2,1
  MOVI r3,63
  CALL @chk
  LA r1,@ctx3
  MOVI r2,#NKD_C_USED
  MOVI r3,10
  MOVI r4,64
  CALL @ctx_chk
  LA r1,@ctx3
  MOVI r2,#NKD_C_LIVE
  MOVI r3,2
  MOVI r4,65
  CALL @ctx_chk
  LA r1,@ctx3
  MOVI r2,#NKD_C_JOINS
  MOVI r3,1
  MOVI r4,66
  CALL @ctx_chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKD_N_REFS
  MOVI r3,2
  MOVI r4,67
  CALL @node_chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKD_N_JOINS
  MOVI r3,1
  MOVI r4,68
  CALL @node_chk
  MOVI r1,#NKD_G_JOINOPS
  MOVI r2,1
  MOVI r3,69
  CALL @stats_chk
  MOVI r1,#NKD_G_JOINREFS
  MOVI r2,2
  MOVI r3,70
  CALL @stats_chk

  ; ---- b4 late-joins the existing DAG
  LA r1,@ctx4
  MOVI r2,4
  MOVI r3,4
  MOVI r4,3
  MOVI r5,4
  MOVI r6,4
  LA r7,@tab4
  MOVI r8,16
  MOVI r9,8
  CALL @nkd_open
  MOVI r2,1
  MOVI r3,71
  CALL @chk
  LA r1,@ctx4
  LA r2,@phlo
  LD r2,r2,0
  LA r3,@phhi
  LD r3,r3,0
  CALL @nkd_join
  MOVI r2,1
  MOVI r3,72
  CALL @chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKD_N_REFS
  MOVI r3,3
  MOVI r4,73
  CALL @node_chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKD_N_REFS
  MOVI r3,3
  MOVI r4,74
  CALL @node_chk
  MOVI r1,#NKD_G_JOINOPS
  MOVI r2,2
  MOVI r3,75
  CALL @stats_chk
  MOVI r1,#NKD_G_JOINREFS
  MOVI r2,4
  MOVI r3,76
  CALL @stats_chk

  ; ---- b2 builds Q; page 0 is byte-identical to P0
  LA r1,@ctx2
  MOVI r2,2
  MOVI r3,2
  MOVI r4,1
  MOVI r5,2
  MOVI r6,2
  LA r7,@tab2
  MOVI r8,16
  MOVI r9,8
  CALL @nkd_open
  MOVI r2,1
  MOVI r3,77
  CALL @chk
  LA r1,@ctx2
  MOVI r2,#NKD_C_USED
  MOVI r3,0
  MOVI r4,185
  CALL @ctx_chk
  LA r1,@ctx2
  MOVI r2,0
  MOVI r3,8
  MOVI r4,0x5000
  CALL @app_seq
  MOVI r2,1
  MOVI r3,78
  CALL @chk
  LA r1,@ctx2
  MOVI r2,8
  MOVI r3,8
  MOVI r4,0x9000
  CALL @app_seq
  MOVI r2,1
  MOVI r3,79
  CALL @chk
  LA r1,@ctx2
  CALL @nkd_seal
  MOVI r2,1
  MOVI r3,80
  CALL @chk
  LA r1,@ctx2
  MOVI r2,#NKD_C_DEDUP
  MOVI r3,1
  MOVI r4,81
  CALL @ctx_chk
  LA r1,@ci
  LA r2,@ctx2
  CALL @nkd_ctx_info
  LA r1,@ci
  MOVI r2,#NKD_C_ROOT
  CALL @fld
  LA r2,@qroot
  ST r1,r2,0
  LA r1,@ci
  MOVI r2,#NKD_C_HLO
  CALL @fld
  LA r2,@qhlo
  ST r1,r2,0
  LA r1,@ci
  MOVI r2,#NKD_C_HHI
  CALL @fld
  LA r2,@qhhi
  ST r1,r2,0
  ; Q page0 must be the identical P0 header; Q1 is a new header behind it
  LA r1,@tab2
  LD r1,r1,0
  LA r2,@qi0
  ST r1,r2,0
  LA r1,@tab2
  ADDI r1,r1,8
  LD r1,r1,0
  LA r2,@qi1
  ST r1,r2,0
  LA r2,@qi0
  LD r1,r2,0
  LA r2,@p0idx
  LD r2,r2,0
  MOVI r3,82
  CALL @chk
  LA r2,@qi1
  LD r1,r2,0
  MOVI r2,#NKD_N_PREV
  LA r3,@p0idx
  LD r3,r3,0
  MOVI r4,83
  CALL @node_chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKD_N_REFS
  MOVI r3,4
  MOVI r4,84
  CALL @node_chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKD_N_DEDUP
  MOVI r3,1
  MOVI r4,85
  CALL @node_chk
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKD_N_HEADERS
  MOVI r3,1
  MOVI r4,86
  CALL @node_chk
  LA r2,@qi1
  LD r1,r2,0
  MOVI r2,#NKD_N_REFS
  MOVI r3,1
  MOVI r4,87
  CALL @node_chk
  MOVI r1,#NKD_G_DHEADERS
  MOVI r2,3
  MOVI r3,88
  CALL @stats_chk
  MOVI r1,#NKD_G_DEDUP
  MOVI r2,1
  MOVI r3,89
  CALL @stats_chk
  MOVI r1,#NKD_G_PALLOC
  MOVI r2,4
  MOVI r3,90
  CALL @stats_chk
  MOVI r1,#NKD_G_PFREE
  MOVI r2,4
  MOVI r3,91
  CALL @stats_chk

  ; ---- views: shared read, shared-write rejection
  LA r1,@ctx1
  MOVI r2,0
  MOVI r3,1
  LA r4,@vShared
  CALL @nkd_view_open
  MOVI r2,1
  MOVI r3,92
  CALL @chk
  LA r1,@ctx1
  MOVI r2,0
  MOVI r3,2
  LA r4,@vW
  CALL @nkd_view_open
  MOVI r2,1
  MOVI r3,93
  CALL @chk
  LA r1,@ctx1
  LA r2,@vW
  MOVI r3,0xBAD
  CALL @write_fail
  MOVI r2,#NKD_ESHARED
  MOVI r3,94
  CALL @chk
  MOVI r1,#NKD_G_XSHARED
  MOVI r2,1
  MOVI r3,95
  CALL @stats_chk

  ; ---- publish gen6; old-gen open fails, fresh gen6 rejects old view
  LA r1,@ctx1
  MOVI r2,6
  CALL @nkd_publish
  CMP r1,r0
  JMP[NE] @pub_ok
  MOVI r1,0
  MOVI r2,1
  MOVI r3,96
  CALL @chk
pub_ok:
  MOVI r1,1
  MOVI r2,1
  MOVI r3,97
  CALL @chk
  ; the old generation slot is draining while branch 1 is still in flight
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
  MOVI r1,1
  MOVI r2,3
  MOVI r3,6
  MOVI r4,188
  CALL @ngen_chk
  LA r1,@ctxOld
  MOVI r2,1
  MOVI r3,5
  MOVI r4,4
  MOVI r5,9
  MOVI r6,1
  LA r7,@tabOld
  MOVI r8,4
  MOVI r9,8
  CALL @nkd_open
  MOVI r2,0
  MOVI r3,98
  CALL @chk
  CALL @nkd_errno
  MOVI r2,#NKD_ESTALE
  MOVI r3,99
  CALL @chk
  LA r1,@ctxOld
  MOVI r2,#NKD_C_NGERR
  MOVI r3,#NG_EDRAIN
  MOVI r4,100
  CALL @ctx_chk
  MOVI r1,#NKD_G_XSTALE
  MOVI r2,1
  MOVI r3,101
  CALL @stats_chk
  ; fresh gen6 branch
  LA r1,@ctx5
  MOVI r2,1
  MOVI r3,6
  MOVI r4,4
  MOVI r5,5
  MOVI r6,1
  LA r7,@tab5
  MOVI r8,4
  MOVI r9,8
  CALL @nkd_open
  MOVI r2,1
  MOVI r3,102
  CALL @chk
  LA r1,@ctx5
  LA r2,@vShared
  LA r3,@vo
  CALL @read_fail
  MOVI r2,#NKD_EGEN
  MOVI r3,103
  CALL @chk
  MOVI r1,#NKD_G_XGEN
  MOVI r2,1
  MOVI r3,104
  CALL @stats_chk
  ; b1 (gen5, DRAINING) still reads its admitted snapshot
  LA r1,@ctx1
  LA r2,@vShared
  LA r3,@vo
  CALL @nkd_view_read
  MOVI r2,1
  MOVI r3,105
  CALL @chk
  ; diagnostics: view node and P0 payload
  LA r1,@vShared
  MOVI r2,#NKD_V_NODE
  CALL @fld
  LA r2,@p0idx
  LD r2,r2,0
  MOVI r3,180
  CALL @chk
  LA r2,@p0idx
  LD r1,r2,0
  LA r2,@ni
  CALL @nkd_node_info
  LA r1,@ni
  MOVI r2,#NKD_N_PAY
  CALL @fld
  LD r1,r1,0
  MOVI r2,0x5000
  MOVI r3,181
  CALL @chk
  LA r1,@vShared
  MOVI r2,#NKD_V_OFF
  CALL @fld
  MOVI r2,0
  MOVI r3,182
  CALL @chk
  LA r1,@vShared
  MOVI r2,#NKD_V_BGEN
  CALL @fld
  MOVI r2,5
  MOVI r3,183
  CALL @chk
  LA r1,@vo
  MOVI r2,1
  CALL @fld
  MOVI r2,5
  MOVI r3,184
  CALL @chk
  LA r1,@vo
  MOVI r2,0
  CALL @fld
  MOVI r2,0x5000
  MOVI r3,106
  CALL @chk
  LA r1,@vo
  MOVI r2,1
  CALL @fld
  MOVI r2,5
  MOVI r3,107
  CALL @chk
  ; unknown root
  LA r1,@ctx5
  MOVI r2,0xDEAD
  MOVI r3,0xBEEF
  CALL @nkd_join
  MOVI r2,0
  MOVI r3,108
  CALL @chk
  CALL @nkd_errno
  MOVI r2,#NKD_ENOENT
  MOVI r3,109
  CALL @chk

  ; ---- divergent suffixes
  LA r1,@ctx1
  MOVI r2,10
  MOVI r3,3
  MOVI r4,0x6000
  CALL @app_seq
  MOVI r2,1
  MOVI r3,110
  CALL @chk
  LA r1,@ctx1
  MOVI r2,#NKD_C_USED
  MOVI r3,13
  MOVI r4,111
  CALL @ctx_chk
  LA r1,@ctx1
  MOVI r2,#NKD_C_COPIES
  MOVI r3,1
  MOVI r4,112
  CALL @ctx_chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKD_N_REFS
  MOVI r3,2
  MOVI r4,113
  CALL @node_chk

  LA r1,@ctx3
  MOVI r2,10
  MOVI r3,7
  MOVI r4,0x7000
  CALL @app_seq
  MOVI r2,1
  MOVI r3,114
  CALL @chk
  LA r1,@ctx3
  MOVI r2,#NKD_C_USED
  MOVI r3,17
  MOVI r4,115
  CALL @ctx_chk
  LA r1,@ctx3
  MOVI r2,#NKD_C_LIVE
  MOVI r3,3
  MOVI r4,116
  CALL @ctx_chk
  LA r2,@p1idx
  LD r1,r2,0
  MOVI r2,#NKD_N_REFS
  MOVI r3,1
  MOVI r4,117
  CALL @node_chk

  LA r1,@ctx4
  MOVI r2,10
  MOVI r3,5
  MOVI r4,0x8000
  CALL @app_seq
  MOVI r2,1
  MOVI r3,118
  CALL @chk
  LA r1,@ctx4
  MOVI r2,#NKD_C_USED
  MOVI r3,15
  MOVI r4,119
  CALL @ctx_chk
  ; P1 reached zero refs during the final COW and was freed
  LA r1,@p1hlo
  LD r1,r1,0
  LA r2,@p1hhi
  LD r2,r2,0
  CALL @nkd_node_find
  LA r2,#NKD_NONE
  MOVI r3,120
  CALL @chk
  MOVI r1,#NKD_G_DAGLIVE
  MOVI r2,2
  MOVI r3,121
  CALL @stats_chk
  MOVI r1,#NKD_G_DFREE
  MOVI r2,1
  MOVI r3,122
  CALL @stats_chk

  LA r1,@ctx2
  MOVI r2,16
  MOVI r3,2
  MOVI r4,0x9008
  CALL @app_seq
  MOVI r2,1
  MOVI r3,123
  CALL @chk
  LA r1,@ctx2
  MOVI r2,#NKD_C_USED
  MOVI r3,18
  MOVI r4,124
  CALL @ctx_chk
  LA r1,@ctx2
  MOVI r2,#NKD_C_LIVE
  MOVI r3,3
  MOVI r4,125
  CALL @ctx_chk

  ; ---- private write succeeds only on the owning generation
  LA r1,@ctx1
  MOVI r2,10
  MOVI r3,2
  LA r4,@vPriv
  CALL @nkd_view_open
  MOVI r2,1
  MOVI r3,126
  CALL @chk
  LA r1,@ctx1
  LA r2,@vPriv
  MOVI r3,0x6AAA
  CALL @nkd_view_write
  MOVI r2,1
  MOVI r3,127
  CALL @chk
  LA r1,@ctx1
  MOVI r2,10
  MOVI r3,1
  LA r4,@vPrivRead
  CALL @nkd_view_open
  MOVI r2,1
  MOVI r3,128
  CALL @chk
  LA r1,@ctx1
  LA r2,@vPrivRead
  LA r3,@vo
  CALL @nkd_view_read
  MOVI r2,1
  MOVI r3,129
  CALL @chk
  LA r1,@vo
  MOVI r2,0
  CALL @fld
  MOVI r2,0x6AAA
  MOVI r3,130
  CALL @chk
  LA r1,@ctx1
  MOVI r2,#NKD_C_VWRITE
  MOVI r3,1
  MOVI r4,131
  CALL @ctx_chk

  ; ---- isolation ranges
  LA r1,@ctx1
  MOVI r2,0
  MOVI r3,10
  MOVI r4,0x5000
  MOVI r5,200
  CALL @rd_range
  MOVI r2,1
  MOVI r3,132
  CALL @chk
  LA r1,@ctx1
  MOVI r2,11
  MOVI r3,2
  MOVI r4,0x6001
  MOVI r5,210
  CALL @rd_range
  MOVI r2,1
  MOVI r3,133
  CALL @chk
  LA r1,@ctx3
  MOVI r2,0
  MOVI r3,10
  MOVI r4,0x5000
  MOVI r5,220
  CALL @rd_range
  MOVI r2,1
  MOVI r3,134
  CALL @chk
  LA r1,@ctx3
  MOVI r2,10
  MOVI r3,7
  MOVI r4,0x7000
  MOVI r5,230
  CALL @rd_range
  MOVI r2,1
  MOVI r3,135
  CALL @chk
  LA r1,@ctx4
  MOVI r2,0
  MOVI r3,10
  MOVI r4,0x5000
  MOVI r5,240
  CALL @rd_range
  MOVI r2,1
  MOVI r3,136
  CALL @chk
  LA r1,@ctx4
  MOVI r2,10
  MOVI r3,5
  MOVI r4,0x8000
  MOVI r5,250
  CALL @rd_range
  MOVI r2,1
  MOVI r3,137
  CALL @chk
  LA r1,@ctx2
  MOVI r2,0
  MOVI r3,8
  MOVI r4,0x5000
  MOVI r5,260
  CALL @rd_range
  MOVI r2,1
  MOVI r3,138
  CALL @chk
  LA r1,@ctx2
  MOVI r2,8
  MOVI r3,8
  MOVI r4,0x9000
  MOVI r5,270
  CALL @rd_range
  MOVI r2,1
  MOVI r3,139
  CALL @chk
  LA r1,@ctx2
  MOVI r2,16
  MOVI r3,2
  MOVI r4,0x9008
  MOVI r5,280
  CALL @rd_range
  MOVI r2,1
  MOVI r3,140
  CALL @chk

  ; ---- pre-close refs and nagent KV roots
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKD_N_REFS
  MOVI r3,4
  MOVI r4,141
  CALL @node_chk
  LA r2,@qi1
  LD r1,r2,0
  MOVI r2,#NKD_N_REFS
  MOVI r3,1
  MOVI r4,142
  CALL @node_chk
  MOVI r1,1
  MOVI r2,#NAG_KVROOT_F
  LA r3,@phlo
  LD r3,r3,0
  MOVI r4,143
  CALL @rec_chk
  MOVI r1,1
  MOVI r2,#NAG_KVGEN_F
  MOVI r3,1
  MOVI r4,144
  CALL @rec_chk
  MOVI r1,2
  MOVI r2,#NAG_KVROOT_F
  LA r3,@qhlo
  LD r3,r3,0
  MOVI r4,145
  CALL @rec_chk
  MOVI r1,3
  MOVI r2,#NAG_KVROOT_F
  LA r3,@phlo
  LD r3,r3,0
  MOVI r4,146
  CALL @rec_chk
  MOVI r1,4
  MOVI r2,#NAG_KVROOT_F
  LA r3,@phlo
  LD r3,r3,0
  MOVI r4,147
  CALL @rec_chk

  ; ---- pre-close totals
  MOVI r1,#NKD_G_LIVE
  MOVI r2,7
  MOVI r3,148
  CALL @stats_chk
  MOVI r1,#NKD_G_DAGLIVE
  MOVI r2,2
  MOVI r3,149
  CALL @stats_chk
  MOVI r1,#NKD_G_PALLOC
  MOVI r2,9
  MOVI r3,150
  CALL @stats_chk
  MOVI r1,#NKD_G_REFS
  MOVI r2,17
  MOVI r3,151
  CALL @stats_chk
  MOVI r1,#NKD_G_RELS
  MOVI r2,7
  MOVI r3,152
  CALL @stats_chk
  MOVI r1,#NKD_G_COWS
  MOVI r2,3
  MOVI r3,153
  CALL @stats_chk
  MOVI r1,#NKD_G_TCOPY
  MOVI r2,6
  MOVI r3,154
  CALL @stats_chk

  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; p0_ref_chk r1=expected refs r2=diag.  P0 must survive every close except the
; last sharer, which leaves refs 0 and the after_close find must miss it.
p0_ref_chk:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  ST r2,r14,2
  LA r2,@p0idx
  LD r1,r2,0
  MOVI r2,#NKD_N_REFS
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
  CALL @nkd_close
  MOVI r2,1
  MOVI r3,300
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
  CALL @nkd_close
  MOVI r2,1
  MOVI r3,301
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

close3:
  ST r15,r14,0
  ADDI r14,r14,16
  LA r1,@ctx3
  CALL @nkd_close
  MOVI r2,1
  MOVI r3,302
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

close4:
  ST r15,r14,0
  ADDI r14,r14,16
  LA r1,@ctx4
  CALL @nkd_close
  MOVI r2,1
  MOVI r3,303
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

close5:
  ST r15,r14,0
  ADDI r14,r14,16
  LA r1,@ctx5
  CALL @nkd_close
  MOVI r2,1
  MOVI r3,304
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; after_close - every DAG/private node has left at refcount zero.
after_close:
  ST r15,r14,0
  ADDI r14,r14,16
  MOVI r1,#NKD_G_LIVE
  MOVI r2,0
  MOVI r3,305
  CALL @stats_chk
  MOVI r1,#NKD_G_DAGLIVE
  MOVI r2,0
  MOVI r3,306
  CALL @stats_chk
  MOVI r1,#NKD_G_DHEADERS
  MOVI r2,3
  MOVI r3,307
  CALL @stats_chk
  MOVI r1,#NKD_G_DALLOC
  MOVI r2,3
  MOVI r3,308
  CALL @stats_chk
  MOVI r1,#NKD_G_DFREE
  MOVI r2,3
  MOVI r3,309
  CALL @stats_chk
  MOVI r1,#NKD_G_PALLOC
  MOVI r2,9
  MOVI r3,310
  CALL @stats_chk
  MOVI r1,#NKD_G_PFREE
  MOVI r2,9
  MOVI r3,311
  CALL @stats_chk
  MOVI r1,#NKD_G_REFS
  MOVI r2,17
  MOVI r3,312
  CALL @stats_chk
  MOVI r1,#NKD_G_RELS
  MOVI r2,17
  MOVI r3,313
  CALL @stats_chk
  MOVI r1,#NKD_G_LEAVES
  MOVI r2,17
  MOVI r3,314
  CALL @stats_chk
  MOVI r1,#NKD_G_CLOSES
  MOVI r2,5
  MOVI r3,315
  CALL @stats_chk
  MOVI r1,#NKD_G_OPENS
  MOVI r2,5
  MOVI r3,316
  CALL @stats_chk
  ; P0 and Q roots are unreachable while the orphan ctx is still closed
  LA r1,@phlo
  LD r1,r1,0
  LA r2,@phhi
  LD r2,r2,0
  CALL @nkd_node_find
  LA r2,#NKD_NONE
  MOVI r3,317
  CALL @chk
  LA r1,@qhlo
  LD r1,r1,0
  LA r2,@qhhi
  LD r2,r2,0
  CALL @nkd_node_find
  LA r2,#NKD_NONE
  MOVI r3,318
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; orphan - a fresh gen6 ctx may not join a root whose last ref went away.
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
  CALL @nkd_open
  MOVI r2,1
  MOVI r3,319
  CALL @chk
  LA r1,@ctx6
  LA r2,@phlo
  LD r2,r2,0
  LA r3,@phhi
  LD r3,r3,0
  CALL @nkd_join
  MOVI r2,0
  MOVI r3,320
  CALL @chk
  CALL @nkd_errno
  MOVI r2,#NKD_ENOENT
  MOVI r3,321
  CALL @chk
  LA r1,@ctx6
  LA r2,@qhlo
  LD r2,r2,0
  LA r3,@qhhi
  LD r3,r3,0
  CALL @nkd_join
  MOVI r2,0
  MOVI r3,322
  CALL @chk
  CALL @nkd_errno
  MOVI r2,#NKD_ENOENT
  MOVI r3,323
  CALL @chk
  LA r1,@ctx6
  CALL @nkd_close
  MOVI r2,1
  MOVI r3,324
  CALL @chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; final_checks - exact counters after the orphan rejection and close.
final_checks:
  ST r15,r14,0
  ADDI r14,r14,16
  MOVI r1,#NKD_G_LIVE
  MOVI r2,0
  MOVI r3,325
  CALL @stats_chk
  MOVI r1,#NKD_G_DAGLIVE
  MOVI r2,0
  MOVI r3,326
  CALL @stats_chk
  MOVI r1,#NKD_G_OPENS
  MOVI r2,6
  MOVI r3,327
  CALL @stats_chk
  MOVI r1,#NKD_G_CLOSES
  MOVI r2,6
  MOVI r3,328
  CALL @stats_chk
  MOVI r1,#NKD_G_ERRORS
  MOVI r2,10
  MOVI r3,329
  CALL @stats_chk
  MOVI r1,#NKD_G_XDUP
  MOVI r2,2
  MOVI r3,330
  CALL @stats_chk
  MOVI r1,#NKD_G_XCOLL
  MOVI r2,1
  MOVI r3,331
  CALL @stats_chk
  MOVI r1,#NKD_G_XREF
  MOVI r2,1
  MOVI r3,332
  CALL @stats_chk
  MOVI r1,#NKD_G_XSHARED
  MOVI r2,1
  MOVI r3,333
  CALL @stats_chk
  MOVI r1,#NKD_G_XSTALE
  MOVI r2,1
  MOVI r3,334
  CALL @stats_chk
  MOVI r1,#NKD_G_XGEN
  MOVI r2,1
  MOVI r3,335
  CALL @stats_chk
  MOVI r1,#NKD_G_ROOTS
  MOVI r2,4
  MOVI r3,336
  CALL @stats_chk
  ; root hashes stay as branch metadata even after the nodes are gone
  LA r1,@ctx1
  MOVI r2,#NKD_C_HLO
  LA r3,@phlo
  LD r3,r3,0
  MOVI r4,337
  CALL @ctx_chk
  LA r1,@ctx2
  MOVI r2,#NKD_C_HLO
  LA r3,@qhlo
  LD r3,r3,0
  MOVI r4,338
  CALL @ctx_chk
  ; ngen end states: agent1 current gen6, agents 2..4 their last generation
  MOVI r1,1
  MOVI r2,3
  MOVI r3,6
  MOVI r4,339
  CALL @ngen_chk
  MOVI r1,2
  MOVI r2,3
  MOVI r3,2
  MOVI r4,340
  CALL @ngen_chk
  MOVI r1,3
  MOVI r2,3
  MOVI r3,3
  MOVI r4,341
  CALL @ngen_chk
  MOVI r1,4
  MOVI r2,3
  MOVI r3,4
  MOVI r4,342
  CALL @ngen_chk
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; app_seq r1=ctx r2=first token r3=count r4=starting value -> 1/0.
; Token i gets r4+i at logical index r2+i.
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
  CALL @nkd_append
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
  MOVI r3,399
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
  CALL @nkd_view_open
  MOVI r2,1
  LD r3,r14,5
  CALL @chk
  LD r1,r14,1
  LA r2,@v
  LA r3,@vo
  CALL @nkd_view_read
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

; read_fail r1=ctx r2=view r3=out -> 0 and errno in r1? Returns errno.
read_fail:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r3,r14,1
  CALL @nkd_view_read
  CMP r1,r0
  JMP[NE] @rf_bad
  CALL @nkd_errno
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
  CALL @nkd_view_write
  CMP r1,r0
  JMP[NE] @wf_bad
  CALL @nkd_errno
  JMP @wf_out
wf_bad:
  LA r1,0xFFFFFFFF
wf_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; snapshot r1=out(5280): 7 contexts, node registry, stats, payload buffer,
; 4 nagent records, 4 ngen statuses, trace ring.
snapshot:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  LA r2,@ctx1
  LD r1,r14,1
  MOVI r3,224
  CALL @copyw
  LA r2,#NKD_NODES
  LD r1,r14,1
  ADDI r1,r1,224
  MOVI r3,2048
  CALL @copyw
  LA r2,#NKD_STATS
  LD r1,r14,1
  ADDI r1,r1,2272
  MOVI r3,64
  CALL @copyw
  LA r2,@pdata
  LD r1,r14,1
  ADDI r1,r1,2336
  MOVI r3,512
  CALL @copyw
  LA r2,#NAG_TAB
  LD r1,r14,1
  ADDI r1,r1,2848
  MOVI r3,1280
  CALL @copyw
  MOVI r1,1
  LD r2,r14,1
  ADDI r2,r2,4128
  CALL @ngen_status
  MOVI r1,2
  LD r2,r14,1
  ADDI r2,r2,4160
  CALL @ngen_status
  MOVI r1,3
  LD r2,r14,1
  ADDI r2,r2,4192
  CALL @ngen_status
  MOVI r1,4
  LD r2,r14,1
  ADDI r2,r2,4224
  CALL @ngen_status
  LA r2,#NKD_TRACE
  LD r1,r14,1
  ADDI r1,r1,4256
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
  LA r1,@ci
  LD r2,r14,1
  CALL @nkd_ctx_info
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
  CALL @nkd_stats
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
  CALL @nkd_node_info
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
  MOVI r3,398
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
  CALL @putdec3
  MOVI r1,44
  PUTC r1
  LD r1,r14,2
  CALL @putdec3
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
ctx6:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ctxOld:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tab1:
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
tab2:
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
tab3:
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
tab4:
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
ni:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
stats:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
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
p0idx:
.word 0
p1idx:
.word 0
qi0:
.word 0
qi1:
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
.org 0x414A0
snapA2:
.org 0x42940
snapB1:
.org 0x43DE0
snapB2:
.org 0x45280
