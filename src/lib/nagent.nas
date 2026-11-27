; nagent.nas - AI-native agent ABI for NaN/0S (F5).
;
; An agent is a sealed record in a fixed table.  The record carries its own
; 24-word trap frame and its own generation-tagged capability table, so a
; checkpoint is a self-contained, deterministic image.  Handles are capability
; words in the existing NANIX form:
;
;   bits 31..24 0xCA
;   bits 23..16 capability index (1..32)
;   bits 15..8  generation (1..255)
;   bits 7..0   rights (1 read, 2 write, 4 execute, 8 grant, 16 replace)
;
; There are no raw pointers in a handle.  revoke bumps the entry generation and
; mints a new handle; every older handle fails the generation check.  A
; checkpoint seals the capability epoch as well, so restoring an older
; capability state after a grant/revoke is rejected (no generation rollback).
;
; Agent record (stride 320 words):
;   0  magic "NAGN"        1  version (1)
;   2  id (1..32)          3  agent generation
;   4  state (1 live)      5  cpu
;   6  node                7  scheduler slot
;   8  trap-frame base     9  cap table base
;   10 cap count           11 immutable weight root
;   12 KV root             13 KV root generation
;   14 trace head          15 trace event count
;   16 budget              17 deadline
;   18 last checkpoint hash 19 checkpoint epoch
;   20 parent id           21 migration epoch
;   22 capability epoch    23 record seal
;   24..47  24-word trap frame
;   48..    cap entries, 8 words each, up to 32
;
; Capability entry (8 words):
;   0 live 1 index 2 generation 3 rights 4 kind 5 root 6 handle 7 reserved
; Kinds: 1 immutable weights, 2 KV root, 3 tool/generic.
;
; Checkpoint record (caller supplied, 48 + 8*cap_count words):
;   0 magic "NAGC"  1 version  2 agent id  3 agent generation
;   4 state  5 cpu  6 node  7 slot  8 cap count  9 capability epoch
;   10 weight root  11 KV root  12 KV generation  13 trace head
;   14 trace count  15 budget  16 deadline  17 parent id
;   18 migration epoch  19 checkpoint epoch  20 hash
;   21 frame words (24) 22 cap words (8*n) 23 total words
;   24..47 frame
;   48..   caps with generations
;
; The hash is a deterministic 32-bit mix chain over every header word except
; the hash, then every frame word, then every capability word.  No host helper
; and no key: this is a corruption/integrity seal, not authentication.
;
; ABI: r0=0, r13=1, r14=SP (grows up), r15=link.
; Reserved low window: destination generations live at 0x6800..0x6840, so
; code/data in an image that links this library must end below 0x6800.  The
; agent table itself is at 0x348000 (32 * 320 words).
; Return codes:
;   0 success, 1 stale migration destination, 2 bad argument/record,
;   3 no such agent, 4 bad capability table, 5 immutable weight root,
;   6 no space.  nagent_restore returns a live id on success and 0 for a
;   malformed, tampered or stale checkpoint (no partial restore).
;
; API:
;   nagent_init
;   nagent_create      r1=cpu r2=node r3=slot -> id / 0
;   nagent_cap_grant   r1=id r2=kind r3=rights r4=root -> cap / 0
;   nagent_cap_revoke  r1=id r2=cap -> new cap / 0
;   nagent_cap_check   r1=id r2=cap r3=rights -> entry / 0
;   nagent_checkpoint  r1=id r2=storage r3=words -> epoch / 0
;   nagent_restore     r1=storage r2=words -> id / 0 (stale or invalid)
;   nagent_fork        r1=parent r2=cpu r3=node -> child id / 0
;   nagent_migrate     r1=id r2=cpu r3=node r4=cpu_gen r5=node_gen -> 0/1/2/3
;   nagent_trace_append r1=id r2=kind r3=a r4=b -> head / 0
;   nagent_verify      r1=id -> 0/2/3/4
;   nagent_record      r1=id -> record / 0
;   nagent_roots       r1=id r2=weight r3=kv -> 0/2/5   (0 keeps a field)
;   nagent_budget_set  r1=id r2=budget r3=deadline -> 0/2/3
;   nagent_dest_set    r1=cpu r2=cpu_gen r3=node r4=node_gen -> 0/2
;   nagent_ck_seal     r1=storage r2=words -> hash / 0

.equ NAG_TAB        0x348000
.equ NAG_MAX        32
.equ NAG_STRIDE     320
.equ NAG_CAP_MAX    32
.equ NAG_MAX_CPU    32
.equ NAG_MAX_NODE   8
.equ NAG_CPUGEN     0x6800
.equ NAG_NODEGEN    0x6820
.equ NAG_TOTAL      10240

.equ NAG_MAGIC      0x4E41474E       ; "NAGN"
.equ NAG_VERSION    1
.equ NAG_CK_MAGIC   0x4E414743       ; "NAGC"
.equ NAG_CK_VERSION 1

; Agent fields.
.equ NAG_MAGIC_F    0
.equ NAG_VERSION_F  1
.equ NAG_ID_F       2
.equ NAG_GEN_F      3
.equ NAG_STATE_F    4
.equ NAG_CPU_F      5
.equ NAG_NODE_F     6
.equ NAG_SLOT_F     7
.equ NAG_FRAME_F    8
.equ NAG_CAPBASE_F  9
.equ NAG_CAPCOUNT_F 10
.equ NAG_WROOT_F    11
.equ NAG_KVROOT_F   12
.equ NAG_KVGEN_F    13
.equ NAG_TRACE_F    14
.equ NAG_TRACEN_F   15
.equ NAG_BUDGET_F   16
.equ NAG_DEADLINE_F 17
.equ NAG_CKHASH_F   18
.equ NAG_CKEPOCH_F  19
.equ NAG_PARENT_F   20
.equ NAG_MIG_F      21
.equ NAG_CAPEPOCH_F 22
.equ NAG_SEAL_F     23
.equ NAG_FRAME_OFF  24
.equ NAG_CAP_OFF    48
.equ NAG_SEAL_FIELDS 23

; Capability entry fields.
.equ NAG_C_LIVE     0
.equ NAG_C_INDEX    1
.equ NAG_C_GEN      2
.equ NAG_C_RIGHTS   3
.equ NAG_C_KIND     4
.equ NAG_C_ROOT     5
.equ NAG_C_HANDLE   6
.equ NAG_C_RES      7

; Checkpoint fields.
.equ CK_MAGIC       0
.equ CK_VERSION     1
.equ CK_AGENT       2
.equ CK_AGEN        3
.equ CK_STATE       4
.equ CK_CPU         5
.equ CK_NODE        6
.equ CK_SLOT        7
.equ CK_CAPS        8
.equ CK_CAPEPOCH    9
.equ CK_WROOT       10
.equ CK_KVROOT      11
.equ CK_KVGEN       12
.equ CK_TRACE       13
.equ CK_TRACEN      14
.equ CK_BUDGET      15
.equ CK_DEADLINE    16
.equ CK_PARENT      17
.equ CK_MIG         18
.equ CK_EPOCH       19
.equ CK_HASH        20
.equ CK_FRAMEW      21
.equ CK_CAPW        22
.equ CK_TOTAL       23
.equ CK_FRAME       24
.equ CK_CAPS_OFF    48

; Rights, kinds, states.
.equ NAG_R_READ     1
.equ NAG_R_WRITE    2
.equ NAG_R_EXEC     4
.equ NAG_R_GRANT    8
.equ NAG_R_REPL     16
.equ NAG_R_ALL      31
.equ NAG_CAP_WEIGHT 1
.equ NAG_CAP_KV     2
.equ NAG_CAP_TOOL   3
.equ NAG_FREE       0
.equ NAG_LIVE       1

; Return codes.
.equ NAG_OK         0
.equ NAG_ESTALE     1
.equ NAG_EBAD       2
.equ NAG_ENOENT     3
.equ NAG_ECAP       4
.equ NAG_EIMMUT     5
.equ NAG_ENOSPC     6

; Hash seeds and mix constants.
.equ NAG_SEAL_SEED  0x4E414753       ; "NAGS"
.equ NAG_CK_SEED    0x4E41474B       ; "NAGK"
.equ NAG_TRACE_SEED 0x811C9DC5
.equ NAG_KV_SALT    0x4B565341       ; "KVSA"
.equ NAG_MIX_C1     0x9E3779B9
.equ NAG_MIX_C2     0x85EBCA6B
.equ NAG_MIX_C3     0xC2B2AE35

; ---------------------------------------------------------------------------
; nag_rec r1=id -> record address or 0.
nag_rec:
  CMP r1,r0
  JMP[EQ] @nag_rec_none
  MOVI r2,#NAG_MAX
  CMP r1,r2
  JMP[GT] @nag_rec_none
  SUB r1,r1,r13
  MOVI r2,#NAG_STRIDE
  MUL r1,r1,r2
  LA r2,#NAG_TAB
  ADD r1,r1,r2
  RET
nag_rec_none:
  MOVI r1,0
  RET

; nag_handle r1=index r2=generation r3=rights -> capability word.
nag_handle:
  MOVI r4,0xCA
  SHL r4,r4,24
  SHL r5,r1,16
  ADD r4,r4,r5
  SHL r5,r2,8
  ADD r4,r4,r5
  ADD r1,r4,r3
  RET

; nag_mix r1=hash r2=word -> r1.  32-bit xor/multiply chain.
nag_mix:
  BOOL.6 r1,r1,r2
  LA r3,#NAG_MIX_C1
  ADD r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  LA r3,#NAG_MIX_C2
  MUL r1,r1,r3
  SHR r4,r1,15
  BOOL.6 r1,r1,r4
  LA r3,#NAG_MIX_C3
  MUL r1,r1,r3
  SHR r4,r1,16
  BOOL.6 r1,r1,r4
  RET

; nag_seal_calc r1=record -> seal hash (does not write the record).
nag_seal_calc:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  LA r1,#NAG_SEAL_SEED
  ST r1,r14,2
  MOVI r2,0
  ST r2,r14,3
nsc_f:
  LD r2,r14,3
  MOVI r3,#NAG_SEAL_FIELDS
  CMP r2,r3
  JMP[GE] @nsc_caps
  LD r4,r14,1
  ADD r4,r4,r2
  LD r2,r4,0
  LD r1,r14,2
  CALL @nag_mix
  ST r1,r14,2
  LD r2,r14,3
  ADDI r2,r2,1
  ST r2,r14,3
  JMP @nsc_f
nsc_caps:
  LD r1,r14,1
  LD r2,r1,#NAG_CAPCOUNT_F
  MOVI r3,#NAG_CAP_MAX
  CMP r2,r3
  JMP[LE] @nsc_count_ok
  ADD r2,r3,r0
nsc_count_ok:
  SHL r2,r2,3
  ST r2,r14,4
  MOVI r3,0
  ST r3,r14,3
nsc_c:
  LD r2,r14,3
  LD r3,r14,4
  CMP r2,r3
  JMP[GE] @nsc_done
  LD r4,r14,1
  ADDI r4,r4,#NAG_CAP_OFF
  ADD r4,r4,r2
  LD r2,r4,0
  LD r1,r14,2
  CALL @nag_mix
  ST r1,r14,2
  LD r2,r14,3
  ADDI r2,r2,1
  ST r2,r14,3
  JMP @nsc_c
nsc_done:
  LD r1,r14,2
  CMP r1,r0
  JMP[NE] @nsc_out
  LA r1,#NAG_SEAL_SEED
nsc_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nag_seal r1=record -> 0, writes the record seal.
nag_seal:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  CALL @nag_seal_calc
  LD r2,r14,1
  ST r1,r2,#NAG_SEAL_F
  MOVI r1,0
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nag_caps_scan r1=base r2=count -> 0 / NAG_ECAP.  Validates every entry.
nag_caps_scan:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  MOVI r3,#NAG_CAP_MAX
  CMP r2,r3
  JMP[GT] @ncs_bad
  MOVI r3,1
  ST r3,r14,3
ncs_l:
  LD r3,r14,3
  LD r2,r14,2
  CMP r3,r2
  JMP[GT] @ncs_ok
  SUB r4,r3,r13
  MOVI r5,8
  MUL r4,r4,r5
  LD r5,r14,1
  ADD r4,r5,r4
  ST r4,r14,4
  LD r5,r4,#NAG_C_LIVE
  CMP r5,r13
  JMP[NE] @ncs_bad
  LD r5,r4,#NAG_C_INDEX
  CMP r5,r3
  JMP[NE] @ncs_bad
  LD r5,r4,#NAG_C_GEN
  CMP r5,r0
  JMP[EQ] @ncs_bad
  MOVI r6,255
  CMP r5,r6
  JMP[GT] @ncs_bad
  LD r6,r4,#NAG_C_RIGHTS
  CMP r6,r0
  JMP[EQ] @ncs_bad
  MOVI r7,#NAG_R_ALL
  CMP r6,r7
  JMP[GT] @ncs_bad
  LD r7,r4,#NAG_C_KIND
  CMP r7,r0
  JMP[EQ] @ncs_bad
  MOVI r8,3
  CMP r7,r8
  JMP[GT] @ncs_bad
  LD r8,r4,#NAG_C_ROOT
  CMP r8,r0
  JMP[EQ] @ncs_bad
  ADD r1,r3,r0
  LD r2,r4,#NAG_C_GEN
  LD r3,r4,#NAG_C_RIGHTS
  CALL @nag_handle
  LD r4,r14,4
  LD r5,r4,#NAG_C_HANDLE
  CMP r5,r1
  JMP[NE] @ncs_bad
  LD r3,r14,3
  ADDI r3,r3,1
  ST r3,r14,3
  JMP @ncs_l
ncs_ok:
  MOVI r1,0
  JMP @ncs_out
ncs_bad:
  MOVI r1,#NAG_ECAP
ncs_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nag_check_caps r1=record -> 0 / NAG_ECAP.
nag_check_caps:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  LD r2,r1,#NAG_CAPCOUNT_F
  ST r2,r14,2
  LD r2,r1,#NAG_CAPBASE_F
  ADDI r3,r1,#NAG_CAP_OFF
  CMP r2,r3
  JMP[NE] @ncc_bad
  ADD r1,r2,r0
  LD r2,r14,2
  CALL @nag_caps_scan
  JMP @ncc_out
ncc_bad:
  MOVI r1,#NAG_ECAP
ncc_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nagent_init - clear the agent table and publish generation 1 destinations.
nagent_init:
  LA r1,#NAG_TAB
  MOVI r2,#NAG_TOTAL
nag_i_clr:
  CMP r2,r0
  JMP[EQ] @nag_i_g1
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nag_i_clr
nag_i_g1:
  LA r1,#NAG_CPUGEN
  MOVI r2,#NAG_MAX_CPU
nag_i_g1l:
  CMP r2,r0
  JMP[EQ] @nag_i_g2
  ST r13,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nag_i_g1l
nag_i_g2:
  LA r1,#NAG_NODEGEN
  MOVI r2,#NAG_MAX_NODE
nag_i_g2l:
  CMP r2,r0
  JMP[EQ] @nag_i_done
  ST r13,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nag_i_g2l
nag_i_done:
  MOVI r1,0
  RET

; nagent_record r1=id -> record or 0.
nagent_record:
  JMP @nag_rec

; nagent_create r1=cpu r2=node r3=slot -> id or 0.
nagent_create:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  MOVI r4,#NAG_MAX_CPU
  CMP r1,r4
  JMP[GE] @ncr_fail
  MOVI r4,#NAG_MAX_NODE
  CMP r2,r4
  JMP[GE] @ncr_fail
  MOVI r5,0
  ST r5,r14,4
ncr_scan:
  LD r5,r14,4
  MOVI r6,#NAG_MAX
  CMP r5,r6
  JMP[GE] @ncr_fail
  MOVI r6,#NAG_STRIDE
  MUL r6,r5,r6
  LA r7,#NAG_TAB
  ADD r6,r6,r7
  ST r6,r14,5
  LD r7,r6,#NAG_MAGIC_F
  CMP r7,r0
  JMP[EQ] @ncr_found
  LD r5,r14,4
  ADDI r5,r5,1
  ST r5,r14,4
  JMP @ncr_scan
ncr_found:
  ; clear the whole record, including caps
  LD r6,r14,5
  MOVI r7,#NAG_STRIDE
ncr_clr:
  CMP r7,r0
  JMP[EQ] @ncr_init
  ST r0,r6,0
  ADD r6,r6,r13
  SUB r7,r7,r13
  JMP @ncr_clr
ncr_init:
  LD r6,r14,5
  LA r7,#NAG_MAGIC
  ST r7,r6,#NAG_MAGIC_F
  MOVI r7,#NAG_VERSION
  ST r7,r6,#NAG_VERSION_F
  LD r7,r14,4
  ADDI r7,r7,1
  ST r7,r6,#NAG_ID_F
  MOVI r7,1
  ST r7,r6,#NAG_GEN_F
  ST r7,r6,#NAG_STATE_F
  LD r7,r14,1
  ST r7,r6,#NAG_CPU_F
  LD r7,r14,2
  ST r7,r6,#NAG_NODE_F
  LD r7,r14,3
  ST r7,r6,#NAG_SLOT_F
  ADDI r7,r6,#NAG_FRAME_OFF
  ST r7,r6,#NAG_FRAME_F
  ADDI r7,r6,#NAG_CAP_OFF
  ST r7,r6,#NAG_CAPBASE_F
  LA r7,#NAG_TRACE_SEED
  ST r7,r6,#NAG_TRACE_F
  MOVI r7,1
  ST r7,r6,#NAG_CAPEPOCH_F
  ADD r1,r6,r0
  CALL @nag_seal
  LD r1,r14,4
  ADDI r1,r1,1
  JMP @ncr_out
ncr_fail:
  MOVI r1,0
ncr_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nagent_verify r1=id -> 0 / NAG_EBAD / NAG_ENOENT / NAG_ECAP.
nagent_verify:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  CALL @nag_rec
  CMP r1,r0
  JMP[EQ] @nvy_noent
  ST r1,r14,2
  LD r2,r1,#NAG_MAGIC_F
  LA r3,#NAG_MAGIC
  CMP r2,r3
  JMP[NE] @nvy_bad
  LD r2,r1,#NAG_VERSION_F
  MOVI r3,#NAG_VERSION
  CMP r2,r3
  JMP[NE] @nvy_bad
  LD r2,r1,#NAG_ID_F
  LD r3,r14,1
  CMP r2,r3
  JMP[NE] @nvy_bad
  LD r2,r1,#NAG_STATE_F
  CMP r2,r13
  JMP[NE] @nvy_bad
  ADDI r3,r1,#NAG_FRAME_OFF
  LD r2,r1,#NAG_FRAME_F
  CMP r2,r3
  JMP[NE] @nvy_bad
  ADDI r3,r1,#NAG_CAP_OFF
  LD r2,r1,#NAG_CAPBASE_F
  CMP r2,r3
  JMP[NE] @nvy_bad
  LD r1,r14,2
  CALL @nag_check_caps
  CMP r1,r0
  JMP[NE] @nvy_caps
  LD r1,r14,2
  LD r2,r1,#NAG_SEAL_F
  ST r2,r14,3
  CALL @nag_seal_calc
  LD r2,r14,3
  CMP r1,r2
  JMP[NE] @nvy_bad
  MOVI r1,0
  JMP @nvy_out
nvy_noent:
  MOVI r1,#NAG_ENOENT
  JMP @nvy_out
nvy_caps:
  MOVI r1,#NAG_ECAP
  JMP @nvy_out
nvy_bad:
  MOVI r1,#NAG_EBAD
nvy_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nagent_cap_grant r1=id r2=kind r3=rights r4=root -> cap or 0.
nagent_cap_grant:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  LD r1,r14,1
  CALL @nagent_verify
  CMP r1,r0
  JMP[NE] @ncg_fail
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @ncg_fail
  MOVI r3,3
  CMP r2,r3
  JMP[GT] @ncg_fail
  LD r2,r14,3
  CMP r2,r0
  JMP[EQ] @ncg_fail
  MOVI r3,#NAG_R_ALL
  CMP r2,r3
  JMP[GT] @ncg_fail
  LD r2,r14,4
  CMP r2,r0
  JMP[EQ] @ncg_fail
  LD r1,r14,1
  CALL @nag_rec
  ST r1,r14,5
  LD r2,r1,#NAG_CAPCOUNT_F
  MOVI r3,#NAG_CAP_MAX
  CMP r2,r3
  JMP[GE] @ncg_fail
  ST r2,r14,6
  ; Kind-specific roots.  Weights are immutable; KV advances generation.
  LD r2,r14,2
  MOVI r3,#NAG_CAP_WEIGHT
  CMP r2,r3
  JMP[NE] @ncg_kv
  LD r1,r14,5
  LD r2,r1,#NAG_WROOT_F
  CMP r2,r0
  JMP[EQ] @ncg_w_set
  LD r3,r14,4
  CMP r2,r3
  JMP[NE] @ncg_immut
  JMP @ncg_entry
ncg_w_set:
  LD r3,r14,4
  ST r3,r1,#NAG_WROOT_F
  JMP @ncg_entry
ncg_kv:
  MOVI r3,#NAG_CAP_KV
  CMP r2,r3
  JMP[NE] @ncg_entry
  LD r1,r14,5
  LD r2,r1,#NAG_KVROOT_F
  CMP r2,r0
  JMP[EQ] @ncg_kv_first
  LD r2,r1,#NAG_KVGEN_F
  ADDI r2,r2,1
  ST r2,r1,#NAG_KVGEN_F
  LD r2,r14,4
  ST r2,r1,#NAG_KVROOT_F
  JMP @ncg_entry
ncg_kv_first:
  LD r3,r14,4
  ST r3,r1,#NAG_KVROOT_F
  MOVI r3,1
  ST r3,r1,#NAG_KVGEN_F
ncg_entry:
  LD r1,r14,5
  LD r2,r14,6
  MOVI r3,8
  MUL r2,r2,r3
  LD r3,r1,#NAG_CAPBASE_F
  ADD r3,r3,r2
  ST r3,r14,7
  MOVI r4,1
  ST r4,r3,#NAG_C_LIVE
  LD r2,r14,6
  ADDI r2,r2,1
  ST r2,r3,#NAG_C_INDEX
  MOVI r4,1
  ST r4,r3,#NAG_C_GEN
  LD r4,r14,3
  ST r4,r3,#NAG_C_RIGHTS
  LD r4,r14,2
  ST r4,r3,#NAG_C_KIND
  LD r4,r14,4
  ST r4,r3,#NAG_C_ROOT
  ADD r1,r2,r0
  MOVI r2,1
  LD r3,r14,3
  CALL @nag_handle
  LD r3,r14,7
  ST r1,r3,#NAG_C_HANDLE
  ST r0,r3,#NAG_C_RES
  LD r1,r14,5
  LD r3,r14,6
  ADDI r3,r3,1
  ST r3,r1,#NAG_CAPCOUNT_F
  LD r3,r1,#NAG_CAPEPOCH_F
  ADDI r3,r3,1
  ST r3,r1,#NAG_CAPEPOCH_F
  CALL @nag_seal
  LD r1,r14,7
  LD r1,r1,#NAG_C_HANDLE
  JMP @ncg_out
ncg_immut:
  MOVI r1,0
  JMP @ncg_out
ncg_fail:
  MOVI r1,0
ncg_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; nagent_cap_check r1=id r2=cap r3=rights -> entry or 0.
nagent_cap_check:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @nag_rec
  CMP r1,r0
  JMP[EQ] @nchk_fail
  ST r1,r14,4
  LD r2,r1,#NAG_MAGIC_F
  LA r3,#NAG_MAGIC
  CMP r2,r3
  JMP[NE] @nchk_fail
  LD r2,r1,#NAG_VERSION_F
  MOVI r3,#NAG_VERSION
  CMP r2,r3
  JMP[NE] @nchk_fail
  LD r2,r14,2
  SHR r3,r2,24
  MOVI r4,0xCA
  CMP r3,r4
  JMP[NE] @nchk_fail
  SHR r3,r2,16
  MOVI r4,0xFF
  BOOL.8 r3,r3,r4
  ST r3,r14,5
  SHR r4,r2,8
  MOVI r5,0xFF
  BOOL.8 r4,r4,r5
  ST r4,r14,6
  MOVI r5,0xFF
  BOOL.8 r5,r2,r5
  ST r5,r14,7
  LD r6,r14,3
  BOOL.8 r7,r5,r6
  CMP r7,r6
  JMP[NE] @nchk_fail
  LD r3,r14,5
  CMP r3,r0
  JMP[EQ] @nchk_fail
  LD r1,r14,4
  LD r4,r1,#NAG_CAPCOUNT_F
  CMP r3,r4
  JMP[GT] @nchk_fail
  ST r4,r14,8
  SUB r4,r3,r13
  MOVI r5,8
  MUL r4,r4,r5
  LD r5,r1,#NAG_CAPBASE_F
  ADD r4,r5,r4
  ST r4,r14,9
  LD r5,r4,#NAG_C_LIVE
  CMP r5,r13
  JMP[NE] @nchk_fail
  LD r5,r4,#NAG_C_INDEX
  CMP r5,r3
  JMP[NE] @nchk_fail
  LD r6,r14,6
  LD r5,r4,#NAG_C_GEN
  CMP r5,r6
  JMP[NE] @nchk_fail
  LD r6,r14,2
  LD r5,r4,#NAG_C_HANDLE
  CMP r5,r6
  JMP[NE] @nchk_fail
  LD r6,r14,3
  LD r5,r4,#NAG_C_RIGHTS
  BOOL.8 r7,r5,r6
  CMP r7,r6
  JMP[NE] @nchk_fail
  ADD r1,r4,r0
  JMP @nchk_out
nchk_fail:
  MOVI r1,0
nchk_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; nagent_cap_revoke r1=id r2=cap -> new cap or 0.
nagent_cap_revoke:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  LD r1,r14,1
  CALL @nagent_verify
  CMP r1,r0
  JMP[NE] @nrv_fail
  LD r1,r14,1
  LD r2,r14,2
  MOVI r3,#NAG_R_REPL
  CALL @nagent_cap_check
  CMP r1,r0
  JMP[EQ] @nrv_fail
  ST r1,r14,4
  LD r2,r1,#NAG_C_GEN
  MOVI r3,255
  CMP r2,r3
  JMP[GE] @nrv_fail
  ADDI r2,r2,1
  ST r2,r1,#NAG_C_GEN
  LD r3,r1,#NAG_C_RIGHTS
  LD r5,r1,#NAG_C_INDEX
  ADD r1,r5,r0
  CALL @nag_handle
  ST r1,r14,5
  LD r4,r14,4
  ST r1,r4,#NAG_C_HANDLE
  LD r1,r14,1
  CALL @nag_rec
  ST r1,r14,6
  LD r2,r1,#NAG_CAPEPOCH_F
  ADDI r2,r2,1
  ST r2,r1,#NAG_CAPEPOCH_F
  CALL @nag_seal
  LD r1,r14,5
  JMP @nrv_out
nrv_fail:
  MOVI r1,0
nrv_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nagent_trace_append r1=id r2=kind r3=a r4=b -> head or 0.
nagent_trace_append:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  LD r1,r14,1
  CALL @nagent_verify
  CMP r1,r0
  JMP[NE] @nta_fail
  LD r1,r14,1
  CALL @nag_rec
  ST r1,r14,5
  LD r1,r1,#NAG_TRACE_F
  LD r2,r14,2
  CALL @nag_mix
  LD r2,r14,3
  CALL @nag_mix
  LD r2,r14,4
  CALL @nag_mix
  CMP r1,r0
  JMP[NE] @nta_head
  LA r1,#NAG_TRACE_SEED
nta_head:
  ST r1,r14,6
  LD r2,r14,5
  ST r1,r2,#NAG_TRACE_F
  LD r3,r2,#NAG_TRACEN_F
  ADDI r3,r3,1
  ST r3,r2,#NAG_TRACEN_F
  ADD r1,r2,r0
  CALL @nag_seal
  LD r1,r14,6
  JMP @nta_out
nta_fail:
  MOVI r1,0
nta_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nagent_roots r1=id r2=weight(0 keep) r3=kv(0 keep) -> 0/2/3/5.
nagent_roots:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LD r1,r14,1
  CALL @nagent_verify
  CMP r1,r0
  JMP[NE] @nrt_bad
  LD r1,r14,1
  CALL @nag_rec
  ST r1,r14,4
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @nrt_kv
  LD r3,r1,#NAG_WROOT_F
  CMP r3,r0
  JMP[EQ] @nrt_w_set
  CMP r3,r2
  JMP[NE] @nrt_immut
  JMP @nrt_kv
nrt_w_set:
  ST r2,r1,#NAG_WROOT_F
nrt_kv:
  LD r1,r14,4
  LD r2,r14,3
  CMP r2,r0
  JMP[EQ] @nrt_done
  LD r3,r1,#NAG_KVROOT_F
  CMP r3,r0
  JMP[EQ] @nrt_kv_first
  CMP r3,r2
  JMP[EQ] @nrt_done
  LD r3,r1,#NAG_KVGEN_F
  ADDI r3,r3,1
  ST r3,r1,#NAG_KVGEN_F
  ST r2,r1,#NAG_KVROOT_F
  JMP @nrt_done
nrt_kv_first:
  ST r2,r1,#NAG_KVROOT_F
  MOVI r3,1
  ST r3,r1,#NAG_KVGEN_F
nrt_done:
  LD r1,r14,4
  CALL @nag_seal
  MOVI r1,0
  JMP @nrt_out
nrt_immut:
  MOVI r1,#NAG_EIMMUT
  JMP @nrt_out
nrt_bad:
  MOVI r1,#NAG_EBAD
nrt_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nagent_budget_set r1=id r2=budget r3=deadline -> 0/2/3.
nagent_budget_set:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  CALL @nagent_verify
  CMP r1,r0
  JMP[NE] @nbs_bad
  LD r1,r14,1
  CALL @nag_rec
  LD r2,r14,2
  ST r2,r1,#NAG_BUDGET_F
  LD r2,r14,3
  ST r2,r1,#NAG_DEADLINE_F
  CALL @nag_seal
  MOVI r1,0
  JMP @nbs_out
nbs_bad:
  MOVI r1,#NAG_EBAD
nbs_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nagent_migrate r1=id r2=cpu r3=node r4=cpu_gen r5=node_gen -> 0/1/2/3.
nagent_migrate:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  LD r1,r14,1
  CALL @nagent_verify
  CMP r1,r0
  JMP[NE] @nmg_bad
  LD r2,r14,2
  MOVI r3,#NAG_MAX_CPU
  CMP r2,r3
  JMP[GE] @nmg_bad
  LD r2,r14,3
  MOVI r3,#NAG_MAX_NODE
  CMP r2,r3
  JMP[GE] @nmg_bad
  LD r2,r14,2
  LA r3,#NAG_CPUGEN
  ADD r3,r3,r2
  LD r3,r3,0
  LD r4,r14,4
  CMP r3,r4
  JMP[NE] @nmg_stale
  LD r2,r14,3
  LA r3,#NAG_NODEGEN
  ADD r3,r3,r2
  LD r3,r3,0
  LD r4,r14,5
  CMP r3,r4
  JMP[NE] @nmg_stale
  LD r1,r14,1
  CALL @nag_rec
  ST r1,r14,6
  LD r2,r1,#NAG_CPU_F
  LD r3,r14,2
  CMP r2,r3
  JMP[NE] @nmg_move
  LD r2,r1,#NAG_NODE_F
  LD r3,r14,3
  CMP r2,r3
  JMP[NE] @nmg_move
  MOVI r1,0
  JMP @nmg_out
nmg_move:
  LD r3,r14,2
  ST r3,r1,#NAG_CPU_F
  LD r3,r14,3
  ST r3,r1,#NAG_NODE_F
  LD r2,r1,#NAG_MIG_F
  ADDI r2,r2,1
  ST r2,r1,#NAG_MIG_F
  CALL @nag_seal
  MOVI r1,0
  JMP @nmg_out
nmg_stale:
  MOVI r1,#NAG_ESTALE
  JMP @nmg_out
nmg_bad:
  MOVI r1,#NAG_EBAD
nmg_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; nagent_dest_set r1=cpu r2=cpu_gen r3=node r4=node_gen -> 0/2.
nagent_dest_set:
  MOVI r5,#NAG_MAX_CPU
  CMP r1,r5
  JMP[GE] @nds_bad
  MOVI r5,#NAG_MAX_NODE
  CMP r3,r5
  JMP[GE] @nds_bad
  LA r5,#NAG_CPUGEN
  ADD r5,r5,r1
  ST r2,r5,0
  LA r5,#NAG_NODEGEN
  ADD r5,r5,r3
  ST r4,r5,0
  MOVI r1,0
  RET
nds_bad:
  MOVI r1,#NAG_EBAD
  RET

; ---------------------------------------------------------------------------
; Checkpoint helpers.

; nag_ck_shape r1=storage r2=words -> total words or 0.
nag_ck_shape:
  CMP r1,r0
  JMP[EQ] @cks_bad
  LD r3,r1,#CK_MAGIC
  LA r4,#NAG_CK_MAGIC
  CMP r3,r4
  JMP[NE] @cks_bad
  LD r3,r1,#CK_VERSION
  MOVI r4,#NAG_CK_VERSION
  CMP r3,r4
  JMP[NE] @cks_bad
  LD r3,r1,#CK_FRAMEW
  MOVI r4,24
  CMP r3,r4
  JMP[NE] @cks_bad
  LD r3,r1,#CK_CAPS
  MOVI r4,#NAG_CAP_MAX
  CMP r3,r4
  JMP[GT] @cks_bad
  SHL r3,r3,3
  LD r4,r1,#CK_CAPW
  CMP r3,r4
  JMP[NE] @cks_bad
  ADDI r3,r4,#CK_CAPS_OFF
  LD r4,r1,#CK_TOTAL
  CMP r3,r4
  JMP[NE] @cks_bad
  CMP r2,r3
  JMP[LT] @cks_bad
  ADD r1,r3,r0
  RET
cks_bad:
  MOVI r1,0
  RET

; nag_ck_hash r1=storage r2=total -> hash.
nag_ck_hash:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  LA r1,#NAG_CK_SEED
  LD r2,r14,2
  CALL @nag_mix
  ST r1,r14,3
  MOVI r2,0
  ST r2,r14,4
nkh_l:
  LD r2,r14,4
  LD r3,r14,2
  CMP r2,r3
  JMP[GE] @nkh_done
  MOVI r3,#CK_HASH
  CMP r2,r3
  JMP[EQ] @nkh_skip
  LD r4,r14,1
  ADD r4,r4,r2
  LD r2,r4,0
  LD r1,r14,3
  CALL @nag_mix
  ST r1,r14,3
nkh_skip:
  LD r2,r14,4
  ADDI r2,r2,1
  ST r2,r14,4
  JMP @nkh_l
nkh_done:
  LD r1,r14,3
  CMP r1,r0
  JMP[NE] @nkh_out
  LA r1,#NAG_CK_SEED
nkh_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nag_ck_valid r1=storage r2=words -> 0 ok / 1 bad.
nag_ck_valid:
  ST r15,r14,0
  ADDI r14,r14,16
  ST r1,r14,1
  CALL @nag_ck_shape
  CMP r1,r0
  JMP[EQ] @ckv_bad
  ST r1,r14,2
  LD r1,r14,1
  LD r2,r14,2
  CALL @nag_ck_hash
  LD r2,r14,1
  LD r3,r2,#CK_HASH
  CMP r1,r3
  JMP[NE] @ckv_bad
  MOVI r1,0
  JMP @ckv_out
ckv_bad:
  MOVI r1,1
ckv_out:
  ADDI r14,r14,-16
  LD r15,r14,0
  RET

; nag_ck_caps r1=storage -> 0 / NAG_ECAP.
nag_ck_caps:
  ADD r2,r1,r0
  LD r3,r1,#CK_CAPS
  ADDI r2,r2,#CK_CAPS_OFF
  ADD r1,r2,r0
  ADD r2,r3,r0
  JMP @nag_caps_scan

; nagent_ck_seal r1=storage r2=words -> hash or 0.  Used by checkpoint and by
; an importer that has already validated the record's provenance.
nagent_ck_seal:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  CALL @nag_ck_shape
  CMP r1,r0
  JMP[EQ] @ckseal_fail
  ST r1,r14,3
  LD r1,r14,1
  LD r2,r14,3
  CALL @nag_ck_hash
  LD r2,r14,1
  ST r1,r2,#CK_HASH
  JMP @ckseal_out
ckseal_fail:
  MOVI r1,0
ckseal_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nagent_checkpoint r1=id r2=storage r3=words -> epoch or 0.
nagent_checkpoint:
  ST r15,r14,0
  ADDI r14,r14,56
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LD r1,r14,1
  CALL @nagent_verify
  CMP r1,r0
  JMP[NE] @ncp_fail
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @ncp_fail
  LD r1,r14,1
  CALL @nag_rec
  ST r1,r14,4
  LD r2,r1,#NAG_CAPCOUNT_F
  ST r2,r14,5
  SHL r2,r2,3
  ST r2,r14,6
  ADDI r3,r2,#CK_CAPS_OFF
  ST r3,r14,7
  LD r2,r14,3
  CMP r2,r3
  JMP[LT] @ncp_fail
  LD r6,r14,2
  LA r7,#NAG_CK_MAGIC
  ST r7,r6,#CK_MAGIC
  MOVI r7,#NAG_CK_VERSION
  ST r7,r6,#CK_VERSION
  LD r4,r14,4
  LD r7,r4,#NAG_ID_F
  ST r7,r6,#CK_AGENT
  LD r7,r4,#NAG_GEN_F
  ST r7,r6,#CK_AGEN
  LD r7,r4,#NAG_STATE_F
  ST r7,r6,#CK_STATE
  LD r7,r4,#NAG_CPU_F
  ST r7,r6,#CK_CPU
  LD r7,r4,#NAG_NODE_F
  ST r7,r6,#CK_NODE
  LD r7,r4,#NAG_SLOT_F
  ST r7,r6,#CK_SLOT
  LD r7,r14,5
  ST r7,r6,#CK_CAPS
  LD r7,r4,#NAG_CAPEPOCH_F
  ST r7,r6,#CK_CAPEPOCH
  LD r7,r4,#NAG_WROOT_F
  ST r7,r6,#CK_WROOT
  LD r7,r4,#NAG_KVROOT_F
  ST r7,r6,#CK_KVROOT
  LD r7,r4,#NAG_KVGEN_F
  ST r7,r6,#CK_KVGEN
  LD r7,r4,#NAG_TRACE_F
  ST r7,r6,#CK_TRACE
  LD r7,r4,#NAG_TRACEN_F
  ST r7,r6,#CK_TRACEN
  LD r7,r4,#NAG_BUDGET_F
  ST r7,r6,#CK_BUDGET
  LD r7,r4,#NAG_DEADLINE_F
  ST r7,r6,#CK_DEADLINE
  LD r7,r4,#NAG_PARENT_F
  ST r7,r6,#CK_PARENT
  LD r7,r4,#NAG_MIG_F
  ST r7,r6,#CK_MIG
  LD r7,r4,#NAG_CKEPOCH_F
  ADDI r7,r7,1
  ST r7,r6,#CK_EPOCH
  ST r0,r6,#CK_HASH
  MOVI r7,24
  ST r7,r6,#CK_FRAMEW
  LD r7,r14,6
  ST r7,r6,#CK_CAPW
  LD r7,r14,7
  ST r7,r6,#CK_TOTAL
  ; frame copy
  LD r4,r14,4
  LD r5,r4,#NAG_FRAME_F
  LD r6,r14,2
  ADDI r6,r6,#CK_FRAME
  MOVI r7,24
ncp_f:
  CMP r7,r0
  JMP[EQ] @ncp_caps
  LD r8,r5,0
  ST r8,r6,0
  ADD r5,r5,r13
  ADD r6,r6,r13
  SUB r7,r7,r13
  JMP @ncp_f
ncp_caps:
  ; cap copy
  LD r4,r14,4
  LD r5,r4,#NAG_CAPBASE_F
  LD r6,r14,2
  ADDI r6,r6,#CK_CAPS_OFF
  LD r7,r14,6
ncp_c:
  CMP r7,r0
  JMP[EQ] @ncp_seal
  LD r8,r5,0
  ST r8,r6,0
  ADD r5,r5,r13
  ADD r6,r6,r13
  SUB r7,r7,r13
  JMP @ncp_c
ncp_seal:
  LD r1,r14,2
  LD r2,r14,7
  CALL @nagent_ck_seal
  CMP r1,r0
  JMP[EQ] @ncp_fail
  ST r1,r14,8
  LD r1,r14,4
  LD r2,r14,8
  ST r2,r1,#NAG_CKHASH_F
  LD r2,r1,#NAG_CKEPOCH_F
  ADDI r2,r2,1
  ST r2,r1,#NAG_CKEPOCH_F
  ST r2,r14,9
  CALL @nag_seal
  LD r1,r14,9
  JMP @ncp_out
ncp_fail:
  MOVI r1,0
ncp_out:
  ADDI r14,r14,-56
  LD r15,r14,0
  RET

; nagent_restore r1=storage r2=words -> id / 0 (stale or invalid).
nagent_restore:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  LD r1,r14,1
  LD r2,r14,2
  CALL @nag_ck_valid
  CMP r1,r0
  JMP[NE] @nrs_bad
  LD r1,r14,1
  LD r2,r1,#CK_AGENT
  ST r2,r14,4
  ADD r1,r2,r0
  CALL @nag_rec
  CMP r1,r0
  JMP[EQ] @nrs_bad
  ST r1,r14,3
  LD r2,r1,#NAG_MAGIC_F
  LA r3,#NAG_MAGIC
  CMP r2,r3
  JMP[NE] @nrs_bad
  LD r2,r1,#NAG_VERSION_F
  MOVI r3,#NAG_VERSION
  CMP r2,r3
  JMP[NE] @nrs_bad
  LD r2,r1,#NAG_ID_F
  LD r3,r14,4
  CMP r2,r3
  JMP[NE] @nrs_bad
  LD r5,r14,1
  LD r2,r1,#NAG_GEN_F
  LD r3,r5,#CK_AGEN
  CMP r2,r3
  JMP[NE] @nrs_bad
  ; live seal: restore repairs state, not a corrupted live record
  LD r2,r1,#NAG_SEAL_F
  ST r2,r14,10
  CALL @nag_seal_calc
  LD r2,r14,10
  CMP r1,r2
  JMP[NE] @nrs_bad
  ; no capability-generation rollback
  LD r1,r14,3
  LD r2,r1,#NAG_CAPEPOCH_F
  LD r3,r14,1
  LD r3,r3,#CK_CAPEPOCH
  CMP r2,r3
  JMP[NE] @nrs_stale
  ; every cap generation in the checkpoint
  LD r1,r14,1
  CALL @nag_ck_caps
  CMP r1,r0
  JMP[NE] @nrs_bad
  ; ---- validated: write the agent ----
  LD r1,r14,3
  LD r5,r14,1
  LD r2,r5,#CK_AGEN
  ST r2,r1,#NAG_GEN_F
  LD r2,r5,#CK_STATE
  ST r2,r1,#NAG_STATE_F
  LD r2,r5,#CK_CPU
  ST r2,r1,#NAG_CPU_F
  LD r2,r5,#CK_NODE
  ST r2,r1,#NAG_NODE_F
  LD r2,r5,#CK_SLOT
  ST r2,r1,#NAG_SLOT_F
  LD r2,r5,#CK_CAPS
  ST r2,r1,#NAG_CAPCOUNT_F
  LD r2,r5,#CK_WROOT
  ST r2,r1,#NAG_WROOT_F
  LD r2,r5,#CK_KVROOT
  ST r2,r1,#NAG_KVROOT_F
  LD r2,r5,#CK_KVGEN
  ST r2,r1,#NAG_KVGEN_F
  LD r2,r5,#CK_TRACE
  ST r2,r1,#NAG_TRACE_F
  LD r2,r5,#CK_TRACEN
  ST r2,r1,#NAG_TRACEN_F
  LD r2,r5,#CK_BUDGET
  ST r2,r1,#NAG_BUDGET_F
  LD r2,r5,#CK_DEADLINE
  ST r2,r1,#NAG_DEADLINE_F
  LD r2,r5,#CK_PARENT
  ST r2,r1,#NAG_PARENT_F
  LD r2,r5,#CK_MIG
  ST r2,r1,#NAG_MIG_F
  LD r2,r5,#CK_CAPEPOCH
  ST r2,r1,#NAG_CAPEPOCH_F
  LD r2,r5,#CK_HASH
  ST r2,r1,#NAG_CKHASH_F
  LD r2,r5,#CK_EPOCH
  ST r2,r1,#NAG_CKEPOCH_F
  ADDI r2,r1,#NAG_FRAME_OFF
  ST r2,r1,#NAG_FRAME_F
  ADDI r2,r1,#NAG_CAP_OFF
  ST r2,r1,#NAG_CAPBASE_F
  ; frame copy
  ADD r6,r5,r0
  ADDI r6,r6,#CK_FRAME
  ADD r7,r1,r0
  ADDI r7,r7,#NAG_FRAME_OFF
  MOVI r8,24
nrs_f:
  CMP r8,r0
  JMP[EQ] @nrs_caps
  LD r9,r6,0
  ST r9,r7,0
  ADD r6,r6,r13
  ADD r7,r7,r13
  SUB r8,r8,r13
  JMP @nrs_f
nrs_caps:
  LD r5,r14,1
  ADD r6,r5,r0
  ADDI r6,r6,#CK_CAPS_OFF
  LD r1,r14,3
  ADD r7,r1,r0
  ADDI r7,r7,#NAG_CAP_OFF
  LD r8,r5,#CK_CAPW
nrs_c:
  CMP r8,r0
  JMP[EQ] @nrs_seal
  LD r9,r6,0
  ST r9,r7,0
  ADD r6,r6,r13
  ADD r7,r7,r13
  SUB r8,r8,r13
  JMP @nrs_c
nrs_seal:
  LD r1,r14,3
  CALL @nag_seal
  LD r1,r14,4
  JMP @nrs_out
nrs_stale:
  MOVI r1,0
  JMP @nrs_out
nrs_bad:
  MOVI r1,0
nrs_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; nagent_fork r1=parent r2=cpu r3=node -> child id or 0.
nagent_fork:
  ST r15,r14,0
  ADDI r14,r14,64
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  LD r1,r14,1
  CALL @nagent_verify
  CMP r1,r0
  JMP[NE] @nfk_fail
  LD r1,r14,1
  CALL @nag_rec
  ST r1,r14,4
  ; reject generation exhaustion before allocating a child
  LD r2,r1,#NAG_CAPCOUNT_F
  ST r2,r14,7
  MOVI r3,1
  ST r3,r14,8
nfk_pre:
  LD r3,r14,8
  LD r2,r14,7
  CMP r3,r2
  JMP[GT] @nfk_create
  SUB r4,r3,r13
  MOVI r5,8
  MUL r4,r4,r5
  LD r5,r14,4
  LD r5,r5,#NAG_CAPBASE_F
  ADD r4,r5,r4
  LD r5,r4,#NAG_C_GEN
  MOVI r6,255
  CMP r5,r6
  JMP[GE] @nfk_fail
  LD r3,r14,8
  ADDI r3,r3,1
  ST r3,r14,8
  JMP @nfk_pre
nfk_create:
  LD r1,r14,2
  LD r2,r14,3
  MOVI r3,0
  CALL @nagent_create
  CMP r1,r0
  JMP[EQ] @nfk_fail
  ST r1,r14,5
  CALL @nag_rec
  ST r1,r14,6
  ; frame
  LD r4,r14,4
  LD r5,r4,#NAG_FRAME_F
  LD r4,r14,6
  LD r6,r4,#NAG_FRAME_F
  MOVI r7,24
nfk_f:
  CMP r7,r0
  JMP[EQ] @nfk_roots
  LD r8,r5,0
  ST r8,r6,0
  ADD r5,r5,r13
  ADD r6,r6,r13
  SUB r7,r7,r13
  JMP @nfk_f
nfk_roots:
  LD r1,r14,4
  LD r2,r14,6
  LD r3,r1,#NAG_WROOT_F
  ST r3,r2,#NAG_WROOT_F
  LD r3,r1,#NAG_KVROOT_F
  CMP r3,r0
  JMP[EQ] @nfk_trace
  LD r4,r1,#NAG_KVGEN_F
  ADDI r4,r4,1
  ST r4,r2,#NAG_KVGEN_F
  ADD r1,r3,r0
  ADD r2,r4,r0
  CALL @nag_mix
  LA r2,#NAG_KV_SALT
  CALL @nag_mix
  CMP r1,r0
  JMP[NE] @nfk_kv_store
  LA r1,#NAG_KV_SALT
nfk_kv_store:
  LD r2,r14,6
  ST r1,r2,#NAG_KVROOT_F
nfk_trace:
  LD r1,r14,4
  LD r2,r14,6
  LD r3,r1,#NAG_TRACE_F
  ST r3,r2,#NAG_TRACE_F
  LD r3,r1,#NAG_TRACEN_F
  ST r3,r2,#NAG_TRACEN_F
  LD r3,r1,#NAG_BUDGET_F
  ST r3,r2,#NAG_BUDGET_F
  LD r3,r1,#NAG_DEADLINE_F
  ST r3,r2,#NAG_DEADLINE_F
  LD r3,r1,#NAG_ID_F
  ST r3,r2,#NAG_PARENT_F
  ; caps: copy each entry, then bump generation and mint child handles
  MOVI r3,1
  ST r3,r14,8
nfk_caps:
  LD r3,r14,8
  LD r2,r14,7
  CMP r3,r2
  JMP[GT] @nfk_caps_done
  SUB r4,r3,r13
  MOVI r5,8
  MUL r4,r4,r5
  LD r5,r14,4
  LD r5,r5,#NAG_CAPBASE_F
  ADD r5,r5,r4
  ST r5,r14,9
  LD r6,r14,6
  LD r6,r6,#NAG_CAPBASE_F
  ADD r6,r6,r4
  ST r6,r14,10
  MOVI r7,8
nfk_cw:
  CMP r7,r0
  JMP[EQ] @nfk_cfix
  LD r8,r5,0
  ST r8,r6,0
  ADD r5,r5,r13
  ADD r6,r6,r13
  SUB r7,r7,r13
  JMP @nfk_cw
nfk_cfix:
  LD r5,r14,9
  LD r6,r14,10
  LD r3,r5,#NAG_C_GEN
  ADDI r3,r3,1
  ST r3,r6,#NAG_C_GEN
  LD r3,r14,8
  ST r3,r6,#NAG_C_INDEX
  MOVI r3,1
  ST r3,r6,#NAG_C_LIVE
  LD r3,r6,#NAG_C_KIND
  MOVI r4,#NAG_CAP_KV
  CMP r3,r4
  JMP[NE] @nfk_nokvroot
  LD r4,r14,6
  LD r4,r4,#NAG_KVROOT_F
  ST r4,r6,#NAG_C_ROOT
nfk_nokvroot:
  LD r1,r14,8
  LD r2,r6,#NAG_C_GEN
  LD r3,r6,#NAG_C_RIGHTS
  CALL @nag_handle
  LD r6,r14,10
  ST r1,r6,#NAG_C_HANDLE
  ST r0,r6,#NAG_C_RES
  LD r3,r14,8
  ADDI r3,r3,1
  ST r3,r14,8
  JMP @nfk_caps
nfk_caps_done:
  LD r1,r14,6
  LD r2,r14,7
  ST r2,r1,#NAG_CAPCOUNT_F
  LD r2,r14,4
  LD r2,r2,#NAG_CAPEPOCH_F
  ADDI r2,r2,1
  ST r2,r1,#NAG_CAPEPOCH_F
  ; child slot is unassigned; state/live and zero ck/mig came from create
  ST r0,r1,#NAG_SLOT_F
  CALL @nag_seal
  LD r1,r14,5
  JMP @nfk_out
nfk_fail:
  MOVI r1,0
nfk_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET
