; nsecure.nas - per-agent address spaces, W^X/NX, guards, capability
; revocation and a deny-by-default sandbox (F9 isolation/security).
;
; This is the product-side NaN policy layer.  It owns an address-space record
; per agent: a root capability, a fixed table of mapped ranges with 64-bit
; (lo,hi) base/size, rights R/W/X, flags, guard-page metadata, and a
; capability epoch.  The native substrate performs the actual page-table
; protection; this layer is the deterministic, checkpointable policy that the
; substrate is told to enforce.  Every range keeps the capability handle that
; authorized it and revalidates that handle on every access check, so a
; revoked capability or a newly downgraded grant fails closed.
;
; Address space (guest word addresses):
;   0x350000  16 x 256-word address-space records
;   0x6C00    this library's low scratch block (0x6C00..0x6C3F)
; The agent/scheduler capability tables are elsewhere: nanobj at 0x340000,
; nagent at 0x348000.  An image linking nsecure must keep code/data below
; 0x6800 (nagent destination generations), must not use 0x6C00..0x6C3F, and
; must keep its own stack clear of 0x7000 if the test image uses that address.
;
; Record (256 words, index = agent-1):
;   +0  magic 0x4E534543 "NSEC"   +1 version 1
;   +2  agent id 1..16            +3 state (1 live)
;   +4  root capability           +5 root kind (1 nanobj, 2 nagent)
;   +6  capability epoch          +7 live range count
;   +8  policy flags              +9 allowed-op mask lo
;   +10 allowed-op mask hi        +11 live sandbox window count
;   +12..15 reserved
;   +16..47  4 sandbox windows, 8 words each
;   +48..175 8 ranges, 16 words each
;
; Range (16 words):
;   +0 state: bits0..2 R/W/X (NANIX values), bit3 live,
;             bit4 guard, bit5 stack, bit6 heap
;   +1 authorizing capability     +2 capability kind
;   +3 base_lo +4 base_hi +5 size_lo +6 size_hi
;   +7 guard_lo +8 guard_hi       +9 capability epoch snapshot
;   +10 range id                  +11..15 reserved
;
; Window (8 words):
;   +0 live +1 base_lo +2 base_hi +3 size_lo +4 size_hi
;   +5 rights (R/W) +6..7 reserved
;
; Range rules
; -----------
; * Rights are 1 read, 2 write, 4 execute (the NANIX/nanobj/nagent values).
; * W|X is rejected everywhere: map rights and check rights.
; * Stack and heap ranges are always NX (execute is rejected even with R|X).
; * base and size are page aligned (4 KiB) and nonzero.
; * base+size is computed as a 64-bit (lo,hi) add.  A carry is EOVER; an end
;   above the 64 PiB user virtual ceiling (0x01000000_00000000) is ERANGE.
; * A guarded range reserves one 4 KiB page immediately below base and one
;   immediately above base+size.  Guards of different ranges may not overlap
;   other ranges or guards.  Access checks that touch a guard are EGUARD.
; * Access checks are exact-interval: a request must be wholly inside one
;   live range with the requested rights and a live authorizing capability.
;
; Capability integration
; ----------------------
; A handle is the existing 32-bit NANIX word (0xCA | index | generation |
; rights); it is never a pointer.  Kind 1 uses nobj_check, kind 2 uses
; nagent_cap_check(agent, handle, rights).  Both re-read the live table, so a
; revoked handle (generation bump) or a rights downgrade fails ECAP.  A range
; can be rebound to a new-generation handle with nsec_rebind; the address-
; space root can be rebound with nsec_root_set after a root revoke.
;
; Sandbox policy
; --------------
; Op ids 0..31 are SVCs, 32..47 are tool calls, 48..63 are memory operations
; (48..55 read-shaped, 56..63 write-shaped).  The allowed-op bitmap starts at
; zero and windows start empty: deny by default.  nsec_sandbox_check requires
; the op bit and a sandbox window that contains the whole buffer; the window
; must itself be mapped with a live capability.  Window rights are R/W and
; the write-shaped memory ops require W.
;
; Return codes
; ------------
;   0 OK, 1 EBAD, 2 ENOENT, 3 ESPACE, 4 ERANGE, 5 EOVER, 6 EWX, 7 EGUARD,
;   8 ECAP, 9 EPAGE, 10 EDENY, 11 EWIN, 12 ENX, 13 ERIGHT.
; nsec_map returns a 1-based range id on success and 0 on failure with the
; code in NSEC_G_ERR (read it with nsec_errno).  nsec_unmap, nsec_rebind,
; nsec_check and the sandbox calls return 0 or a code directly.
;
; API
; ---
;   nsec_init
;   nsec_agent_create r1=agent r2=root_cap r3=root_kind -> 0/code
;   nsec_root_set     r1=agent r2=root_cap r3=root_kind -> 0/code
;   nsec_map          r1=agent r2=cap r3=base_lo r4=base_hi
;                     r5=size_lo r6=size_hi r7=rights r8=flags
;                     r9=cap_kind -> range id / 0 (errno)
;   nsec_unmap        r1=agent r2=range -> 0/code
;   nsec_rebind       r1=agent r2=range r3=new_cap -> 0/code
;   nsec_check        r1=agent r2=base_lo r3=base_hi
;                     r4=len_lo r5=len_hi r6=rights -> 0/code
;   nsec_sandbox_init r1=agent -> 0/code
;   nsec_sandbox_allow_op   r1=agent r2=op -> 0/code
;   nsec_sandbox_allow_mask r1=agent r2=mask_lo r3=mask_hi -> 0/code
;   nsec_sandbox_window     r1=agent r2=slot r3=base_lo r4=base_hi
;                           r5=size_lo r6=size_hi r7=rights -> 0/code
;   nsec_sandbox_check      r1=agent r2=op r3=base_lo r4=base_hi
;                           r5=len_lo r6=len_hi -> 0/code
;   nsec_verify       r1=agent -> 0/code
;   nsec_errno        -> last map/policy error
;
; ABI: r0=0, r13=1, r14=SP (grows up), r15=link.  Public routines preserve
; r6..r12 and r13/r14; r1..r5 and flags are scratch.  Internal helpers use
; the 0x6C00 block only as call-scratch, never for state that outlives a
; public call.

.include "n64.nas"
.include "nanobj.nas"
.include "nagent.nas"

.equ NSEC_TAB       0x350000
.equ NSEC_MAX       16
.equ NSEC_STRIDE    256
.equ NSEC_TOTAL     4096

.equ NSEC_MAGIC     0x4E534543       ; "NSEC"
.equ NSEC_VERSION   1
.equ NSEC_LIMIT_HI  0x01000000       ; end <= 2^56 (64 PiB user half)
.equ NSEC_PAGE      0x1000

.equ NSEC_RANGES    8
.equ NSEC_RANGE_OFF 48
.equ NSEC_RANGE_W   16
.equ NSEC_WINDOWS   4
.equ NSEC_WIN_OFF   16
.equ NSEC_WIN_W     8

; Record fields.
.equ NS_MAGIC       0
.equ NS_VERSION     1
.equ NS_ID          2
.equ NS_STATE       3
.equ NS_ROOT        4
.equ NS_ROOTK       5
.equ NS_EPOCH       6
.equ NS_NRANGE      7
.equ NS_FLAGS       8
.equ NS_OPLO        9
.equ NS_OPHI        10
.equ NS_NWIN        11

; Range fields.
.equ NS_R_STATE     0
.equ NS_R_CAP       1
.equ NS_R_KIND      2
.equ NS_R_BLO       3
.equ NS_R_BHI       4
.equ NS_R_SLO       5
.equ NS_R_SHI       6
.equ NS_R_GLO       7
.equ NS_R_GHI       8
.equ NS_R_EPOCH     9
.equ NS_R_ID        10

; Window fields.
.equ NS_W_LIVE      0
.equ NS_W_BLO       1
.equ NS_W_BHI       2
.equ NS_W_SLO       3
.equ NS_W_SHI       4
.equ NS_W_RIGHTS    5

; State bits (range rights share NANIX values).
.equ NS_LIVE        8
.equ NS_R_READ      1
.equ NS_R_WRITE     2
.equ NS_R_EXEC      4
.equ NS_R_ALL       7
.equ NS_F_GUARD     16
.equ NS_F_STACK     32
.equ NS_F_HEAP      64

; Map flags.
.equ NSEC_M_GUARD   1
.equ NSEC_M_STACK   2
.equ NSEC_M_HEAP    4
.equ NSEC_M_ALL     7

; Capability kinds.
.equ NSEC_C_NOBJ    1
.equ NSEC_C_NAGENT  2

; Return codes.
.equ NSEC_OK        0
.equ NSEC_EBAD      1
.equ NSEC_ENOENT    2
.equ NSEC_ESPACE    3
.equ NSEC_ERANGE    4
.equ NSEC_EOVER     5
.equ NSEC_EWX       6
.equ NSEC_EGUARD    7
.equ NSEC_ECAP      8
.equ NSEC_EPAGE     9
.equ NSEC_EDENY     10
.equ NSEC_EWIN      11
.equ NSEC_ENX       12
.equ NSEC_ERIGHT    13

; Low scratch block.
.equ NSEC_G_ERR     0x6C00
.equ NSEC_G_T0      0x6C01
.equ NSEC_G_T1      0x6C02
.equ NSEC_G_T2      0x6C03
.equ NSEC_G_T3      0x6C04
.equ NSEC_G_T4      0x6C05
.equ NSEC_G_T5      0x6C06
.equ NSEC_G_T6      0x6C07
.equ NSEC_G_T7      0x6C08

; ---------------------------------------------------------------------------
; nsec_rec r1=agent -> record pointer or 0.
nsec_rec:
  CMP r1,r0
  JMP[EQ] @nsr_none
  MOVI r2,#NSEC_MAX
  CMP r1,r2
  JMP[GT] @nsr_none
  SUB r1,r1,r13
  MOVI r2,#NSEC_STRIDE
  MUL r1,r1,r2
  LA r2,#NSEC_TAB
  ADD r1,r1,r2
  RET
nsr_none:
  MOVI r1,0
  RET

; nsec_cap_check r1=agent r2=kind r3=handle r4=rights -> entry or 0.
; No nsecure scratch is touched, so it is safe from nested checks.
nsec_cap_check:
  CMP r2,r13
  JMP[EQ] @nsk_cap_nobj
  MOVI r5,#NSEC_C_NAGENT
  CMP r2,r5
  JMP[EQ] @nsk_cap_nagent
  MOVI r1,0
  RET
nsk_cap_nobj:
  ADD r1,r3,r0
  ADD r2,r4,r0
  JMP @nobj_check
nsk_cap_nagent:
  ADD r1,r1,r0
  ADD r2,r3,r0
  ADD r3,r4,r0
  JMP @nagent_cap_check

; nsec_bit r1=bit index 0..31 -> r1=1 << index.  The ISA shift count is an
; immediate, so a variable bit is built by doubling.
nsec_bit:
  MOVI r2,1
  MOVI r3,0
nsk_bit_l:
  CMP r3,r1
  JMP[GE] @nsk_bit_d
  SHL r2,r2,1
  ADDI r3,r3,1
  JMP @nsk_bit_l
nsk_bit_d:
  ADD r1,r2,r0
  RET

; nsec_lim r1=end_lo r2=end_hi -> 0 / ERANGE.
nsec_lim:
  LA r3,#NSEC_LIMIT_HI
  CMP r2,r3
  JMP[GT] @nsk_lim_bad
  JMP[LT] @nsk_lim_ok
  CMP r1,r0
  JMP[NE] @nsk_lim_bad
nsk_lim_ok:
  MOVI r1,0
  RET
nsk_lim_bad:
  MOVI r1,#NSEC_ERANGE
  RET

; nsec_lt64 r1=alo r2=ahi r3=blo r4=bhi -> 1 if a < b unsigned.
nsec_lt64:
  CMP r2,r4
  JMP[LT] @nsk_lt_yes
  JMP[GT] @nsk_lt_no
  CMP r1,r3
  JMP[LT] @nsk_lt_yes
nsk_lt_no:
  MOVI r1,0
  RET
nsk_lt_yes:
  MOVI r1,1
  RET

; nsec_overlap r1=alo r2=ahi r3=blo r4=bhi
;               r5=clo r6=chi r7=dlo r8=dhi -> 1 if [a,b) and [c,d) overlap.
nsec_overlap:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  ST r7,r14,7
  ST r8,r14,8
  LD r1,r14,1
  LD r2,r14,2
  LD r3,r14,7
  LD r4,r14,8
  CALL @nsec_lt64
  CMP r1,r0
  JMP[EQ] @nsk_ov_no
  LD r1,r14,5
  LD r2,r14,6
  LD r3,r14,3
  LD r4,r14,4
  CALL @nsec_lt64
  CMP r1,r0
  JMP[EQ] @nsk_ov_no
  MOVI r1,1
  JMP @nsk_ov_out
nsk_ov_no:
  MOVI r1,0
nsk_ov_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; nsec_inside r1=alo r2=ahi r3=blo r4=bhi r5=rlo r6=rhi r7=slo r8=shi
;              -> 1 if [a,b) is wholly inside [r,s).
nsec_inside:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  ST r7,r14,7
  ST r8,r14,8
  LD r1,r14,1
  LD r2,r14,2
  LD r3,r14,5
  LD r4,r14,6
  CALL @nsec_lt64
  CMP r1,r0
  JMP[NE] @nsk_in_no
  LD r1,r14,7
  LD r2,r14,8
  LD r3,r14,3
  LD r4,r14,4
  CALL @nsec_lt64
  CMP r1,r0
  JMP[NE] @nsk_in_no
  MOVI r1,1
  JMP @nsk_in_out
nsk_in_no:
  MOVI r1,0
nsk_in_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; nsec_hdr r1=agent -> record or 0 (structural validation, errno set).
; Does not require the root capability to be live.
nsec_hdr:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  CALL @nsec_rec
  CMP r1,r0
  JMP[EQ] @nsk_h_noent
  ST r1,r14,2
  LD r2,r1,#NS_MAGIC
  LA r3,#NSEC_MAGIC
  CMP r2,r3
  JMP[NE] @nsk_h_bad
  LD r2,r1,#NS_VERSION
  MOVI r3,#NSEC_VERSION
  CMP r2,r3
  JMP[NE] @nsk_h_bad
  LD r2,r1,#NS_ID
  LD r3,r14,1
  CMP r2,r3
  JMP[NE] @nsk_h_bad
  LD r2,r1,#NS_STATE
  CMP r2,r13
  JMP[NE] @nsk_h_bad
  ST r0,r0,#NSEC_G_ERR
  LD r1,r14,2
  JMP @nsk_h_out
nsk_h_noent:
  MOVI r2,#NSEC_ENOENT
  JMP @nsk_h_err
nsk_h_bad:
  MOVI r2,#NSEC_EBAD
nsk_h_err:
  ST r2,r0,#NSEC_G_ERR
  MOVI r1,0
nsk_h_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nsec_root_check r1=agent r2=record -> 0/ECAP.  Re-reads the live handle.
nsec_root_check:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r2,r14,2
  LD r3,r2,#NS_ROOT
  CMP r3,r0
  JMP[EQ] @nsk_r_bad
  LD r2,r2,#NS_ROOTK
  LD r1,r14,1
  MOVI r4,0
  CALL @nsec_cap_check
  CMP r1,r0
  JMP[EQ] @nsk_r_bad
  MOVI r1,0
  JMP @nsk_r_out
nsk_r_bad:
  MOVI r1,#NSEC_ECAP
nsk_r_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nsec_agent_ok r1=agent -> 0/code.  Header + live root capability.
nsec_agent_ok:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  CALL @nsec_hdr
  CMP r1,r0
  JMP[EQ] @nsk_a_fail
  ST r1,r14,2
  LD r1,r14,1
  LD r2,r14,2
  CALL @nsec_root_check
  CMP r1,r0
  JMP[NE] @nsk_a_ecap
  MOVI r1,0
  JMP @nsk_a_out
nsk_a_ecap:
  ST r1,r0,#NSEC_G_ERR
  JMP @nsk_a_out
nsk_a_fail:
  LD r1,r0,#NSEC_G_ERR
nsk_a_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsec_init - clear the address-space table.
nsec_init:
  LA r1,#NSEC_TAB
  MOVI r2,#NSEC_TOTAL
nsk_i_l:
  CMP r2,r0
  JMP[EQ] @nsk_i_d
  ST r0,r1,0
  ADD r1,r1,r13
  SUB r2,r2,r13
  JMP @nsk_i_l
nsk_i_d:
  ST r0,r0,#NSEC_G_ERR
  MOVI r1,0
  RET

; nsec_errno -> last map/policy error code.
nsec_errno:
  LD r1,r0,#NSEC_G_ERR
  RET

; nsec_agent_create r1=agent r2=root_cap r3=root_kind -> 0/code.
nsec_agent_create:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r0,r0,#NSEC_G_ERR
  LD r1,r14,1
  CMP r1,r0
  JMP[EQ] @nsq_ac_bad
  MOVI r2,#NSEC_MAX
  CMP r1,r2
  JMP[GT] @nsq_ac_bad
  LD r2,r14,3
  CMP r2,r13
  JMP[EQ] @nsq_ac_kind
  MOVI r3,#NSEC_C_NAGENT
  CMP r2,r3
  JMP[NE] @nsq_ac_bad
nsq_ac_kind:
  LD r3,r14,2
  CMP r3,r0
  JMP[EQ] @nsq_ac_cap
  LD r1,r14,1
  LD r2,r14,3
  MOVI r4,0
  CALL @nsec_cap_check
  CMP r1,r0
  JMP[EQ] @nsq_ac_cap
  LD r1,r14,1
  CALL @nsec_rec
  ST r1,r14,4
  LD r2,r1,#NS_MAGIC
  CMP r2,r0
  JMP[NE] @nsq_ac_bad
  ; zero the whole 256-word record
  ADD r3,r1,r0
  MOVI r4,#NSEC_STRIDE
nsq_ac_z:
  CMP r4,r0
  JMP[EQ] @nsq_ac_set
  ST r0,r3,0
  ADD r3,r3,r13
  SUB r4,r4,r13
  JMP @nsq_ac_z
nsq_ac_set:
  LD r2,r14,4
  LA r3,#NSEC_MAGIC
  ST r3,r2,#NS_MAGIC
  MOVI r3,#NSEC_VERSION
  ST r3,r2,#NS_VERSION
  LD r3,r14,1
  ST r3,r2,#NS_ID
  MOVI r3,1
  ST r3,r2,#NS_STATE
  LD r3,r14,2
  ST r3,r2,#NS_ROOT
  LD r3,r14,3
  ST r3,r2,#NS_ROOTK
  MOVI r3,1
  ST r3,r2,#NS_EPOCH
  MOVI r1,0
  JMP @nsq_ac_out
nsq_ac_bad:
  MOVI r1,#NSEC_EBAD
  ST r1,r0,#NSEC_G_ERR
  JMP @nsq_ac_out
nsq_ac_cap:
  MOVI r1,#NSEC_ECAP
  ST r1,r0,#NSEC_G_ERR
nsq_ac_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nsec_root_set r1=agent r2=root_cap r3=root_kind -> 0/code.
nsec_root_set:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r0,r0,#NSEC_G_ERR
  LD r1,r14,1
  CALL @nsec_hdr
  CMP r1,r0
  JMP[EQ] @nsq_rs_fail
  ST r1,r14,4
  LD r2,r14,3
  CMP r2,r13
  JMP[EQ] @nsq_rs_kind
  MOVI r3,#NSEC_C_NAGENT
  CMP r2,r3
  JMP[NE] @nsq_rs_bad
nsq_rs_kind:
  LD r3,r14,2
  CMP r3,r0
  JMP[EQ] @nsq_rs_cap
  LD r1,r14,1
  LD r2,r14,3
  MOVI r4,0
  CALL @nsec_cap_check
  CMP r1,r0
  JMP[EQ] @nsq_rs_cap
  LD r2,r14,4
  LD r3,r14,2
  ST r3,r2,#NS_ROOT
  LD r3,r14,3
  ST r3,r2,#NS_ROOTK
  LD r3,r2,#NS_EPOCH
  ADDI r3,r3,1
  ST r3,r2,#NS_EPOCH
  MOVI r1,0
  JMP @nsq_rs_out
nsq_rs_bad:
  MOVI r1,#NSEC_EBAD
  JMP @nsq_rs_err
nsq_rs_cap:
  MOVI r1,#NSEC_ECAP
nsq_rs_err:
  ST r1,r0,#NSEC_G_ERR
  JMP @nsq_rs_out
nsq_rs_fail:
  LD r1,r0,#NSEC_G_ERR
nsq_rs_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsec_map r1=agent r2=cap r3=base_lo r4=base_hi r5=size_lo r6=size_hi
;           r7=rights r8=flags r9=cap_kind -> range id / 0 (errno).
nsec_map:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  ST r7,r14,7
  ST r8,r14,8
  ST r9,r14,9
  ST r0,r0,#NSEC_G_ERR
  LD r1,r14,1
  CALL @nsec_agent_ok
  CMP r1,r0
  JMP[NE] @nsq_mp_failcode
  ; ---- rights
  LD r2,r14,7
  CMP r2,r0
  JMP[EQ] @nsq_mp_bad
  MOVI r3,#NS_R_ALL
  CMP r2,r3
  JMP[GT] @nsq_mp_bad
  MOVI r3,6
  BOOL.8 r4,r2,r3
  CMP r4,r3
  JMP[EQ] @nsq_mp_wx
  ; ---- flags and stack/heap NX
  LD r2,r14,8
  MOVI r3,#NSEC_M_ALL
  CMP r2,r3
  JMP[GT] @nsq_mp_bad
  MOVI r3,4
  LD r4,r14,7
  BOOL.8 r5,r4,r3
  CMP r5,r0
  JMP[EQ] @nsq_mp_noexec
  MOVI r3,6
  BOOL.8 r5,r2,r3
  CMP r5,r0
  JMP[NE] @nsq_mp_nx
nsq_mp_noexec:
  ; ---- alignment and nonzero size
  LD r2,r14,3
  MOVI r3,0xFFF
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @nsq_mp_page
  LD r2,r14,5
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @nsq_mp_page
  LD r3,r14,6
  CMP r2,r0
  JMP[NE] @nsq_mp_sz_ok
  CMP r3,r0
  JMP[EQ] @nsq_mp_bad
nsq_mp_sz_ok:
  ; ---- base + size
  LD r1,r14,3
  LD r2,r14,4
  LD r3,r14,5
  LD r4,r14,6
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @nsq_mp_over
  ST r1,r14,13
  ST r2,r14,14
  LD r1,r14,13
  LD r2,r14,14
  CALL @nsec_lim
  CMP r1,r0
  JMP[NE] @nsq_mp_failcode
  ; ---- effective interval, with optional 4 KiB guards at both ends
  LD r3,r14,3
  ST r3,r14,15
  LD r3,r14,4
  ST r3,r14,16
  LD r3,r14,13
  ST r3,r14,17
  LD r3,r14,14
  ST r3,r14,18
  ST r0,r14,19
  ST r0,r14,20
  LD r2,r14,8
  MOVI r3,#NSEC_M_GUARD
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[EQ] @nsq_mp_noguard
  ; base must leave room for the low guard page
  LD r2,r14,4
  CMP r2,r0
  JMP[NE] @nsq_mp_guard_room
  LD r2,r14,3
  MOVI r3,#NSEC_PAGE
  CMP r2,r3
  JMP[LT] @nsq_mp_range
nsq_mp_guard_room:
  LD r1,r14,3
  LD r2,r14,4
  MOVI r3,#NSEC_PAGE
  MOVI r4,0
  CALL @n64_sub
  ST r1,r14,15
  ST r2,r14,16
  LD r1,r14,13
  LD r2,r14,14
  MOVI r3,#NSEC_PAGE
  MOVI r4,0
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @nsq_mp_over
  ST r1,r14,17
  ST r2,r14,18
  LD r1,r14,17
  LD r2,r14,18
  CALL @nsec_lim
  CMP r1,r0
  JMP[NE] @nsq_mp_failcode
  MOVI r3,#NSEC_PAGE
  ST r3,r14,19
  ST r0,r14,20
nsq_mp_noguard:
  ; ---- authorizing capability: live and rights-covering
  LD r2,r14,9
  CMP r2,r13
  JMP[EQ] @nsq_mp_kind_ok
  MOVI r3,#NSEC_C_NAGENT
  CMP r2,r3
  JMP[NE] @nsq_mp_bad
nsq_mp_kind_ok:
  LD r1,r14,1
  LD r2,r14,9
  LD r3,r14,2
  LD r4,r14,7
  CALL @nsec_cap_check
  CMP r1,r0
  JMP[EQ] @nsq_mp_ecap
  ; ---- free range slot
  LD r1,r14,1
  CALL @nsec_rec
  ST r1,r14,10
  MOVI r5,1
  ST r5,r14,11
nsq_mp_find:
  LD r5,r14,11
  MOVI r6,#NSEC_RANGES
  CMP r5,r6
  JMP[GT] @nsq_mp_nospace
  SUB r6,r5,r13
  SHL r6,r6,4
  ADDI r6,r6,#NSEC_RANGE_OFF
  LD r7,r14,10
  ADD r6,r7,r6
  ST r6,r14,12
  LD r7,r6,#NS_R_STATE
  MOVI r8,#NS_LIVE
  BOOL.8 r7,r7,r8
  CMP r7,r0
  JMP[EQ] @nsq_mp_have
  LD r5,r14,11
  ADDI r5,r5,1
  ST r5,r14,11
  JMP @nsq_mp_find
nsq_mp_have:
  ; ---- reject overlap with any live range's effective interval
  MOVI r5,1
  ST r5,r14,21
nsq_mp_ovl:
  LD r5,r14,21
  MOVI r6,#NSEC_RANGES
  CMP r5,r6
  JMP[GT] @nsq_mp_store
  SUB r6,r5,r13
  SHL r6,r6,4
  ADDI r6,r6,#NSEC_RANGE_OFF
  LD r7,r14,10
  ADD r6,r7,r6
  ST r6,r14,22
  LD r7,r6,#NS_R_STATE
  MOVI r8,#NS_LIVE
  BOOL.8 r7,r7,r8
  CMP r7,r0
  JMP[EQ] @nsq_mp_ovnext
  LD r8,r6,#NS_R_BLO
  ST r8,r14,23
  LD r8,r6,#NS_R_BHI
  ST r8,r14,24
  ; is it guarded?  Expand by its own guard for the overlap test.
  LD r7,r6,#NS_R_STATE
  MOVI r8,#NS_F_GUARD
  BOOL.8 r7,r7,r8
  CMP r7,r0
  JMP[EQ] @nsq_mp_ovplain
  LD r1,r6,#NS_R_BLO
  LD r2,r6,#NS_R_BHI
  LD r3,r6,#NS_R_GLO
  LD r4,r6,#NS_R_GHI
  CALL @n64_sub
  ST r1,r14,23
  ST r2,r14,24
  LD r1,r6,#NS_R_BLO
  LD r2,r6,#NS_R_BHI
  LD r3,r6,#NS_R_SLO
  LD r4,r6,#NS_R_SHI
  CALL @n64_add
  LD r3,r6,#NS_R_GLO
  LD r4,r6,#NS_R_GHI
  CALL @n64_add
  ST r1,r14,25
  ST r2,r14,26
  JMP @nsq_mp_ovcall
nsq_mp_ovplain:
  LD r1,r6,#NS_R_BLO
  LD r2,r6,#NS_R_BHI
  LD r3,r6,#NS_R_SLO
  LD r4,r6,#NS_R_SHI
  CALL @n64_add
  ST r1,r14,25
  ST r2,r14,26
nsq_mp_ovcall:
  LD r1,r14,15
  LD r2,r14,16
  LD r3,r14,17
  LD r4,r14,18
  LD r5,r14,23
  LD r6,r14,24
  LD r7,r14,25
  LD r8,r14,26
  CALL @nsec_overlap
  CMP r1,r0
  JMP[NE] @nsq_mp_range
nsq_mp_ovnext:
  LD r5,r14,21
  ADDI r5,r5,1
  ST r5,r14,21
  JMP @nsq_mp_ovl
nsq_mp_store:
  ; ---- state = live | rights | guard/stack/heap flag bits
  MOVI r3,#NS_LIVE
  LD r4,r14,7
  ADD r3,r3,r4
  LD r4,r14,8
  MOVI r5,#NSEC_M_GUARD
  BOOL.8 r6,r4,r5
  CMP r6,r0
  JMP[EQ] @nsq_mp_st1
  ADDI r3,r3,#NS_F_GUARD
nsq_mp_st1:
  MOVI r5,#NSEC_M_STACK
  BOOL.8 r6,r4,r5
  CMP r6,r0
  JMP[EQ] @nsq_mp_st2
  ADDI r3,r3,#NS_F_STACK
nsq_mp_st2:
  MOVI r5,#NSEC_M_HEAP
  BOOL.8 r6,r4,r5
  CMP r6,r0
  JMP[EQ] @nsq_mp_st3
  ADDI r3,r3,#NS_F_HEAP
nsq_mp_st3:
  ST r3,r14,27
  LD r2,r14,12
  LD r3,r14,27
  ST r3,r2,#NS_R_STATE
  LD r3,r14,2
  ST r3,r2,#NS_R_CAP
  LD r3,r14,9
  ST r3,r2,#NS_R_KIND
  LD r3,r14,3
  ST r3,r2,#NS_R_BLO
  LD r3,r14,4
  ST r3,r2,#NS_R_BHI
  LD r3,r14,5
  ST r3,r2,#NS_R_SLO
  LD r3,r14,6
  ST r3,r2,#NS_R_SHI
  LD r3,r14,19
  ST r3,r2,#NS_R_GLO
  LD r3,r14,20
  ST r3,r2,#NS_R_GHI
  LD r3,r14,10
  LD r3,r3,#NS_EPOCH
  ST r3,r2,#NS_R_EPOCH
  LD r3,r14,11
  ST r3,r2,#NS_R_ID
  LD r1,r14,10
  LD r3,r1,#NS_NRANGE
  ADDI r3,r3,1
  ST r3,r1,#NS_NRANGE
  LD r3,r1,#NS_EPOCH
  ADDI r3,r3,1
  ST r3,r1,#NS_EPOCH
  ST r0,r0,#NSEC_G_ERR
  LD r1,r14,11
  JMP @nsq_mp_out
nsq_mp_bad:
  MOVI r1,#NSEC_EBAD
  JMP @nsq_mp_fail
nsq_mp_wx:
  MOVI r1,#NSEC_EWX
  JMP @nsq_mp_fail
nsq_mp_nx:
  MOVI r1,#NSEC_ENX
  JMP @nsq_mp_fail
nsq_mp_page:
  MOVI r1,#NSEC_EPAGE
  JMP @nsq_mp_fail
nsq_mp_over:
  MOVI r1,#NSEC_EOVER
  JMP @nsq_mp_fail
nsq_mp_range:
  MOVI r1,#NSEC_ERANGE
  JMP @nsq_mp_fail
nsq_mp_ecap:
  MOVI r1,#NSEC_ECAP
  JMP @nsq_mp_fail
nsq_mp_nospace:
  MOVI r1,#NSEC_ESPACE
nsq_mp_fail:
  ST r1,r0,#NSEC_G_ERR
  MOVI r1,0
  JMP @nsq_mp_out
nsq_mp_failcode:
  ; agent_ok/lim return the code in r1; map's contract is 0 + errno
  ST r1,r0,#NSEC_G_ERR
  MOVI r1,0
nsq_mp_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; nsec_unmap r1=agent r2=range -> 0/code.
nsec_unmap:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  ST r0,r0,#NSEC_G_ERR
  LD r1,r14,1
  CALL @nsec_agent_ok
  CMP r1,r0
  JMP[NE] @nsq_um_out
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @nsq_um_bad
  MOVI r3,#NSEC_RANGES
  CMP r2,r3
  JMP[GT] @nsq_um_bad
  LD r1,r14,1
  CALL @nsec_rec
  ST r1,r14,3
  LD r2,r14,2
  SUB r2,r2,r13
  SHL r2,r2,4
  ADDI r2,r2,#NSEC_RANGE_OFF
  ADD r2,r1,r2
  ST r2,r14,4
  LD r3,r2,#NS_R_STATE
  MOVI r4,#NS_LIVE
  BOOL.8 r3,r3,r4
  CMP r3,r0
  JMP[EQ] @nsq_um_noent
  MOVI r3,16
nsq_um_z:
  CMP r3,r0
  JMP[EQ] @nsq_um_count
  ST r0,r2,0
  ADD r2,r2,r13
  SUB r3,r3,r13
  JMP @nsq_um_z
nsq_um_count:
  LD r1,r14,3
  LD r3,r1,#NS_NRANGE
  SUB r3,r3,r13
  ST r3,r1,#NS_NRANGE
  LD r3,r1,#NS_EPOCH
  ADDI r3,r3,1
  ST r3,r1,#NS_EPOCH
  MOVI r1,0
  JMP @nsq_um_out
nsq_um_bad:
  MOVI r1,#NSEC_EBAD
  JMP @nsq_um_err
nsq_um_noent:
  MOVI r1,#NSEC_ENOENT
nsq_um_err:
  ST r1,r0,#NSEC_G_ERR
nsq_um_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nsec_rebind r1=agent r2=range r3=new_cap -> 0/code.
; Replaces the authorizing handle without remapping the range.  The new cap
; must be live and cover every right the range carries.
nsec_rebind:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r0,r0,#NSEC_G_ERR
  LD r1,r14,1
  CALL @nsec_agent_ok
  CMP r1,r0
  JMP[NE] @nsq_rb_out
  LD r2,r14,2
  CMP r2,r0
  JMP[EQ] @nsq_rb_bad
  MOVI r3,#NSEC_RANGES
  CMP r2,r3
  JMP[GT] @nsq_rb_bad
  LD r1,r14,1
  CALL @nsec_rec
  ST r1,r14,4
  LD r2,r14,2
  SUB r2,r2,r13
  SHL r2,r2,4
  ADDI r2,r2,#NSEC_RANGE_OFF
  ADD r2,r1,r2
  ST r2,r14,5
  LD r3,r2,#NS_R_STATE
  MOVI r4,#NS_LIVE
  BOOL.8 r3,r3,r4
  CMP r3,r0
  JMP[EQ] @nsq_rb_noent
  LD r4,r2,#NS_R_STATE
  MOVI r5,#NS_R_ALL
  BOOL.8 r4,r4,r5
  ST r4,r14,6
  LD r1,r14,1
  LD r2,r14,5
  LD r2,r2,#NS_R_KIND
  LD r3,r14,3
  LD r4,r14,6
  CALL @nsec_cap_check
  CMP r1,r0
  JMP[EQ] @nsq_rb_ecap
  LD r2,r14,5
  LD r3,r14,3
  ST r3,r2,#NS_R_CAP
  LD r1,r14,4
  LD r3,r1,#NS_EPOCH
  ST r3,r2,#NS_R_EPOCH
  ADDI r3,r3,1
  ST r3,r1,#NS_EPOCH
  MOVI r1,0
  JMP @nsq_rb_out
nsq_rb_bad:
  MOVI r1,#NSEC_EBAD
  JMP @nsq_rb_err
nsq_rb_noent:
  MOVI r1,#NSEC_ENOENT
  JMP @nsq_rb_err
nsq_rb_ecap:
  MOVI r1,#NSEC_ECAP
nsq_rb_err:
  ST r1,r0,#NSEC_G_ERR
nsq_rb_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsec_check r1=agent r2=base_lo r3=base_hi r4=len_lo r5=len_hi
;            r6=rights -> 0/code.
nsec_check:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  ST r0,r0,#NSEC_G_ERR
  LD r1,r14,1
  CALL @nsec_agent_ok
  CMP r1,r0
  JMP[NE] @nsq_ck_out
  ; ---- rights
  LD r2,r14,6
  CMP r2,r0
  JMP[EQ] @nsq_ck_bad
  MOVI r3,#NS_R_ALL
  CMP r2,r3
  JMP[GT] @nsq_ck_bad
  MOVI r3,6
  BOOL.8 r4,r2,r3
  CMP r4,r3
  JMP[EQ] @nsq_ck_wx
  ; ---- length nonzero, base+len 64-bit safe
  LD r2,r14,4
  LD r3,r14,5
  CMP r2,r0
  JMP[NE] @nsq_ck_len
  CMP r3,r0
  JMP[EQ] @nsq_ck_bad
nsq_ck_len:
  LD r1,r14,2
  LD r2,r14,3
  LD r3,r14,4
  LD r4,r14,5
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @nsq_ck_over
  ST r1,r14,7
  ST r2,r14,8
  LD r1,r14,7
  LD r2,r14,8
  CALL @nsec_lim
  CMP r1,r0
  JMP[NE] @nsq_ck_out
  ; ---- record and scan
  LD r1,r14,1
  CALL @nsec_rec
  ST r1,r14,9
  MOVI r3,0
  ST r3,r14,23
  MOVI r3,1
  ST r3,r14,10
nsq_ck_loop:
  LD r3,r14,10
  MOVI r4,#NSEC_RANGES
  CMP r3,r4
  JMP[GT] @nsq_ck_end
  SUB r4,r3,r13
  SHL r4,r4,4
  ADDI r4,r4,#NSEC_RANGE_OFF
  LD r5,r14,9
  ADD r4,r5,r4
  ST r4,r14,11
  LD r5,r4,#NS_R_STATE
  MOVI r6,#NS_LIVE
  BOOL.8 r5,r5,r6
  CMP r5,r0
  JMP[EQ] @nsq_ck_next
  LD r5,r4,#NS_R_BLO
  ST r5,r14,13
  LD r5,r4,#NS_R_BHI
  ST r5,r14,14
  LD r1,r14,13
  LD r2,r14,14
  LD r3,r4,#NS_R_SLO
  LD r4,r4,#NS_R_SHI
  CALL @n64_add
  ST r1,r14,15
  ST r2,r14,16
  ; inside?
  LD r1,r14,2
  LD r2,r14,3
  LD r3,r14,7
  LD r4,r14,8
  LD r5,r14,13
  LD r6,r14,14
  LD r7,r14,15
  LD r8,r14,16
  CALL @nsec_inside
  CMP r1,r0
  JMP[EQ] @nsq_ck_guard
  ; ---- rights of the range
  LD r2,r14,6
  LD r3,r14,11
  LD r3,r3,#NS_R_STATE
  ST r3,r14,12
  MOVI r5,#NS_R_EXEC
  BOOL.8 r4,r2,r5
  CMP r4,r0
  JMP[EQ] @nsq_ck_nox
  MOVI r5,#NS_F_STACK
  LD r6,r14,12
  BOOL.8 r7,r6,r5
  CMP r7,r0
  JMP[NE] @nsq_ck_nx
  MOVI r5,#NS_F_HEAP
  BOOL.8 r7,r6,r5
  CMP r7,r0
  JMP[NE] @nsq_ck_nx
  MOVI r5,#NS_R_EXEC
  BOOL.8 r7,r6,r5
  CMP r7,r5
  JMP[NE] @nsq_ck_right
nsq_ck_nox:
  MOVI r5,#NS_R_WRITE
  BOOL.8 r4,r2,r5
  CMP r4,r0
  JMP[EQ] @nsq_ck_now
  MOVI r5,#NS_R_WRITE
  LD r6,r14,12
  BOOL.8 r7,r6,r5
  CMP r7,r5
  JMP[NE] @nsq_ck_right
nsq_ck_now:
  MOVI r5,#NS_R_READ
  BOOL.8 r4,r2,r5
  CMP r4,r0
  JMP[EQ] @nsq_ck_cap
  MOVI r5,#NS_R_READ
  LD r6,r14,12
  BOOL.8 r7,r6,r5
  CMP r7,r5
  JMP[NE] @nsq_ck_right
nsq_ck_cap:
  ; ---- the authorizing capability must still be live and cover rights
  LD r1,r14,1
  LD r2,r14,11
  LD r2,r2,#NS_R_KIND
  LD r3,r14,11
  LD r3,r3,#NS_R_CAP
  LD r4,r14,6
  CALL @nsec_cap_check
  CMP r1,r0
  JMP[EQ] @nsq_ck_ecap
  MOVI r1,0
  JMP @nsq_ck_out
nsq_ck_guard:
  ; ---- touching either guard page is a distinct failure
  LD r3,r14,11
  LD r4,r3,#NS_R_STATE
  MOVI r5,#NS_F_GUARD
  BOOL.8 r4,r4,r5
  CMP r4,r0
  JMP[EQ] @nsq_ck_next
  ; before = base - guard
  LD r1,r14,13
  LD r2,r14,14
  LD r3,r14,11
  LD r3,r3,#NS_R_GLO
  LD r4,r14,11
  LD r4,r4,#NS_R_GHI
  CALL @n64_sub
  ST r1,r14,19
  ST r2,r14,20
  LD r1,r14,2
  LD r2,r14,3
  LD r3,r14,7
  LD r4,r14,8
  LD r5,r14,19
  LD r6,r14,20
  LD r7,r14,13
  LD r8,r14,14
  CALL @nsec_overlap
  CMP r1,r0
  JMP[NE] @nsq_ck_guardhit
  ; after = end + guard
  LD r1,r14,15
  LD r2,r14,16
  LD r3,r14,11
  LD r3,r3,#NS_R_GLO
  LD r4,r14,11
  LD r4,r4,#NS_R_GHI
  CALL @n64_add
  ST r1,r14,21
  ST r2,r14,22
  LD r1,r14,2
  LD r2,r14,3
  LD r3,r14,7
  LD r4,r14,8
  LD r5,r14,15
  LD r6,r14,16
  LD r7,r14,21
  LD r8,r14,22
  CALL @nsec_overlap
  CMP r1,r0
  JMP[NE] @nsq_ck_guardhit
nsq_ck_next:
  LD r3,r14,10
  ADDI r3,r3,1
  ST r3,r14,10
  JMP @nsq_ck_loop
nsq_ck_end:
  LD r3,r14,23
  CMP r3,r0
  JMP[NE] @nsq_ck_guardcode
  MOVI r1,#NSEC_ERANGE
  JMP @nsq_ck_out
nsq_ck_guardcode:
  MOVI r1,#NSEC_EGUARD
  JMP @nsq_ck_out
nsq_ck_guardhit:
  MOVI r3,1
  ST r3,r14,23
  JMP @nsq_ck_next
nsq_ck_bad:
  MOVI r1,#NSEC_EBAD
  JMP @nsq_ck_err
nsq_ck_wx:
  MOVI r1,#NSEC_EWX
  JMP @nsq_ck_err
nsq_ck_over:
  MOVI r1,#NSEC_EOVER
  JMP @nsq_ck_err
nsq_ck_nx:
  MOVI r1,#NSEC_ENX
  JMP @nsq_ck_err
nsq_ck_right:
  MOVI r1,#NSEC_ERIGHT
  JMP @nsq_ck_err
nsq_ck_ecap:
  MOVI r1,#NSEC_ECAP
nsq_ck_err:
  ST r1,r0,#NSEC_G_ERR
nsq_ck_out:
  CMP r1,r0
  JMP[EQ] @nsq_ck_done
  ST r1,r0,#NSEC_G_ERR
nsq_ck_done:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsec_sandbox_init r1=agent -> 0/code.  Clears the op mask and windows:
; policy starts deny-by-default.
nsec_sandbox_init:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1
  ST r0,r0,#NSEC_G_ERR
  LD r1,r14,1
  CALL @nsec_agent_ok
  CMP r1,r0
  JMP[NE] @nsq_si_out
  LD r1,r14,1
  CALL @nsec_rec
  ST r1,r14,2
  ST r0,r1,#NS_OPLO
  ST r0,r1,#NS_OPHI
  ST r0,r1,#NS_NWIN
  ADD r2,r1,r0
  ADDI r2,r2,#NSEC_WIN_OFF
  MOVI r3,#NSEC_WINDOWS
nsq_si_w:
  CMP r3,r0
  JMP[EQ] @nsq_si_done
  MOVI r4,#NSEC_WIN_W
nsq_si_ww:
  CMP r4,r0
  JMP[EQ] @nsq_si_wn
  ST r0,r2,0
  ADD r2,r2,r13
  SUB r4,r4,r13
  JMP @nsq_si_ww
nsq_si_wn:
  SUB r3,r3,r13
  JMP @nsq_si_w
nsq_si_done:
  LD r1,r14,2
  LD r2,r1,#NS_EPOCH
  ADDI r2,r2,1
  ST r2,r1,#NS_EPOCH
  MOVI r1,0
nsq_si_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; nsec_sandbox_allow_op r1=agent r2=op -> 0/code.
nsec_sandbox_allow_op:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  ST r0,r0,#NSEC_G_ERR
  LD r1,r14,1
  CALL @nsec_agent_ok
  CMP r1,r0
  JMP[NE] @nsq_ao_out
  LD r2,r14,2
  MOVI r3,63
  CMP r2,r3
  JMP[GT] @nsq_ao_bad
  LD r1,r14,1
  CALL @nsec_rec
  ST r1,r14,3
  MOVI r4,1
  ST r4,r14,4
  LD r2,r14,2
  MOVI r3,32
  CMP r2,r3
  JMP[LT] @nsq_ao_lo
  SUB r2,r2,r3
  LD r5,r1,#NS_OPHI
  ST r5,r14,5
  JMP @nsq_ao_bit
nsq_ao_lo:
  LD r5,r1,#NS_OPLO
  ST r5,r14,5
nsq_ao_bit:
  ; bit = 1 << (op & 31); the ISA shift count is an immediate
  MOVI r3,31
  BOOL.8 r1,r2,r3
  CALL @nsec_bit
  ST r1,r14,4
  LD r5,r14,5
  BOOL.8 r6,r5,r1
  CMP r6,r1
  JMP[EQ] @nsq_ao_ok
  ADD r5,r5,r1
  LD r2,r14,2
  MOVI r3,32
  CMP r2,r3
  JMP[LT] @nsq_ao_stlo
  LD r1,r14,3
  ST r5,r1,#NS_OPHI
  JMP @nsq_ao_bump
nsq_ao_stlo:
  LD r1,r14,3
  ST r5,r1,#NS_OPLO
nsq_ao_bump:
  LD r1,r14,3
  LD r2,r1,#NS_EPOCH
  ADDI r2,r2,1
  ST r2,r1,#NS_EPOCH
nsq_ao_ok:
  MOVI r1,0
  JMP @nsq_ao_out
nsq_ao_bad:
  MOVI r1,#NSEC_EBAD
  ST r1,r0,#NSEC_G_ERR
nsq_ao_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nsec_sandbox_allow_mask r1=agent r2=mask_lo r3=mask_hi -> 0/code.
nsec_sandbox_allow_mask:
  ST r15,r14,0
  ADDI r14,r14,32
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r0,r0,#NSEC_G_ERR
  LD r1,r14,1
  CALL @nsec_agent_ok
  CMP r1,r0
  JMP[NE] @nsq_am_out
  LD r1,r14,1
  CALL @nsec_rec
  LD r2,r14,2
  ST r2,r1,#NS_OPLO
  LD r2,r14,3
  ST r2,r1,#NS_OPHI
  LD r2,r1,#NS_EPOCH
  ADDI r2,r2,1
  ST r2,r1,#NS_EPOCH
  MOVI r1,0
nsq_am_out:
  ADDI r14,r14,-32
  LD r15,r14,0
  RET

; nsec_sandbox_window r1=agent r2=slot r3=base_lo r4=base_hi
;                      r5=size_lo r6=size_hi r7=rights -> 0/code.
nsec_sandbox_window:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  ST r7,r14,7
  ST r0,r0,#NSEC_G_ERR
  LD r1,r14,1
  CALL @nsec_agent_ok
  CMP r1,r0
  JMP[NE] @nsq_sw_out
  LD r2,r14,2
  MOVI r3,#NSEC_WINDOWS
  CMP r2,r3
  JMP[GE] @nsq_sw_bad
  LD r2,r14,7
  CMP r2,r0
  JMP[EQ] @nsq_sw_bad
  MOVI r3,#NS_R_ALL
  CMP r2,r3
  JMP[GT] @nsq_sw_bad
  MOVI r3,#NS_R_EXEC
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @nsq_sw_wx
  ; alignment and nonzero size
  LD r2,r14,3
  MOVI r3,0xFFF
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @nsq_sw_page
  LD r2,r14,5
  BOOL.8 r4,r2,r3
  CMP r4,r0
  JMP[NE] @nsq_sw_page
  LD r3,r14,6
  CMP r2,r0
  JMP[NE] @nsq_sw_sz
  CMP r3,r0
  JMP[EQ] @nsq_sw_bad
nsq_sw_sz:
  LD r1,r14,3
  LD r2,r14,4
  LD r3,r14,5
  LD r4,r14,6
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @nsq_sw_over
  ST r1,r14,8
  ST r2,r14,9
  LD r1,r14,8
  LD r2,r14,9
  CALL @nsec_lim
  CMP r1,r0
  JMP[NE] @nsq_sw_out
  ; the window must be mapped (and the capability live)
  LD r1,r14,1
  LD r2,r14,3
  LD r3,r14,4
  LD r4,r14,5
  LD r5,r14,6
  LD r6,r14,7
  CALL @nsec_check
  CMP r1,r0
  JMP[NE] @nsq_sw_out
  LD r1,r14,1
  CALL @nsec_rec
  ST r1,r14,10
  LD r2,r14,2
  SHL r2,r2,3
  ADDI r2,r2,#NSEC_WIN_OFF
  ADD r2,r1,r2
  ST r2,r14,11
  LD r3,r2,#NS_W_LIVE
  CMP r3,r0
  JMP[NE] @nsq_sw_nocount
  LD r1,r14,10
  LD r3,r1,#NS_NWIN
  ADDI r3,r3,1
  ST r3,r1,#NS_NWIN
nsq_sw_nocount:
  MOVI r3,1
  ST r3,r2,#NS_W_LIVE
  LD r3,r14,3
  ST r3,r2,#NS_W_BLO
  LD r3,r14,4
  ST r3,r2,#NS_W_BHI
  LD r3,r14,5
  ST r3,r2,#NS_W_SLO
  LD r3,r14,6
  ST r3,r2,#NS_W_SHI
  LD r3,r14,7
  ST r3,r2,#NS_W_RIGHTS
  LD r1,r14,10
  LD r3,r1,#NS_EPOCH
  ADDI r3,r3,1
  ST r3,r1,#NS_EPOCH
  MOVI r1,0
  JMP @nsq_sw_out
nsq_sw_bad:
  MOVI r1,#NSEC_EBAD
  JMP @nsq_sw_err
nsq_sw_wx:
  MOVI r1,#NSEC_EWX
  JMP @nsq_sw_err
nsq_sw_page:
  MOVI r1,#NSEC_EPAGE
  JMP @nsq_sw_err
nsq_sw_over:
  MOVI r1,#NSEC_EOVER
nsq_sw_err:
  ST r1,r0,#NSEC_G_ERR
nsq_sw_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; nsec_sandbox_check r1=agent r2=op r3=base_lo r4=base_hi
;                     r5=len_lo r6=len_hi -> 0/code.
; Deny-by-default: the op bit must be allowed and the whole buffer must be
; inside one allowed window that is itself mapped with a live capability.
nsec_sandbox_check:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r2,r14,2
  ST r3,r14,3
  ST r4,r14,4
  ST r5,r14,5
  ST r6,r14,6
  ST r0,r0,#NSEC_G_ERR
  LD r1,r14,1
  CALL @nsec_agent_ok
  CMP r1,r0
  JMP[NE] @nsq_sc_out
  LD r2,r14,2
  MOVI r3,63
  CMP r2,r3
  JMP[GT] @nsq_sc_bad
  ; op bit
  LD r1,r14,1
  CALL @nsec_rec
  ST r1,r14,7
  LD r2,r14,2
  MOVI r3,32
  CMP r2,r3
  JMP[LT] @nsq_sc_oplo
  SUB r2,r2,r3
  LD r4,r1,#NS_OPHI
  JMP @nsq_sc_opbit
nsq_sc_oplo:
  LD r4,r1,#NS_OPLO
nsq_sc_opbit:
  MOVI r3,31
  BOOL.8 r1,r2,r3
  CALL @nsec_bit
  ADD r5,r1,r0
  BOOL.8 r6,r4,r5
  CMP r6,r5
  JMP[NE] @nsq_sc_deny
  ; buffer validation
  LD r2,r14,5
  LD r3,r14,6
  CMP r2,r0
  JMP[NE] @nsq_sc_len
  CMP r3,r0
  JMP[EQ] @nsq_sc_bad
nsq_sc_len:
  LD r1,r14,3
  MOVI r3,0xFFF
  BOOL.8 r4,r1,r3
  CMP r4,r0
  JMP[NE] @nsq_sc_page
  LD r1,r14,5
  BOOL.8 r4,r1,r3
  CMP r4,r0
  JMP[NE] @nsq_sc_page
  LD r1,r14,3
  LD r2,r14,4
  LD r3,r14,5
  LD r4,r14,6
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @nsq_sc_over
  ST r1,r14,11
  ST r2,r14,12
  LD r1,r14,11
  LD r2,r14,12
  CALL @nsec_lim
  CMP r1,r0
  JMP[NE] @nsq_sc_out
  ; needed memory right: 48..55 read, 56..63 write, others read
  MOVI r3,#NS_R_READ
  ST r3,r14,10
  LD r2,r14,2
  MOVI r3,48
  CMP r2,r3
  JMP[LT] @nsq_sc_win
  MOVI r3,56
  CMP r2,r3
  JMP[LT] @nsq_sc_win
  MOVI r3,#NS_R_WRITE
  ST r3,r14,10
nsq_sc_win:
  MOVI r3,0
  ST r3,r14,8
nsq_sc_wl:
  LD r3,r14,8
  MOVI r4,#NSEC_WINDOWS
  CMP r3,r4
  JMP[GE] @nsq_sc_nowin
  SHL r4,r3,3
  ADDI r4,r4,#NSEC_WIN_OFF
  LD r5,r14,7
  ADD r4,r5,r4
  ST r4,r14,9
  LD r5,r4,#NS_W_LIVE
  CMP r5,r0
  JMP[EQ] @nsq_sc_wn
  LD r5,r4,#NS_W_BLO
  ST r5,r14,13
  LD r5,r4,#NS_W_BHI
  ST r5,r14,14
  LD r1,r14,13
  LD r2,r14,14
  LD r3,r4,#NS_W_SLO
  LD r4,r4,#NS_W_SHI
  CALL @n64_add
  ST r1,r14,15
  ST r2,r14,16
  LD r1,r14,3
  LD r2,r14,4
  LD r3,r14,11
  LD r4,r14,12
  LD r5,r14,13
  LD r6,r14,14
  LD r7,r14,15
  LD r8,r14,16
  CALL @nsec_inside
  CMP r1,r0
  JMP[EQ] @nsq_sc_wn
  ; window rights must cover the needed address-space right
  LD r4,r14,9
  LD r5,r4,#NS_W_RIGHTS
  LD r6,r14,10
  BOOL.8 r7,r5,r6
  CMP r7,r6
  JMP[NE] @nsq_sc_winright
  LD r1,r14,1
  LD r2,r14,3
  LD r3,r14,4
  LD r4,r14,5
  LD r5,r14,6
  LD r6,r14,10
  CALL @nsec_check
  JMP @nsq_sc_out
nsq_sc_wn:
  LD r3,r14,8
  ADDI r3,r3,1
  ST r3,r14,8
  JMP @nsq_sc_wl
nsq_sc_nowin:
  MOVI r1,#NSEC_EWIN
  JMP @nsq_sc_err
nsq_sc_winright:
  MOVI r1,#NSEC_EWIN
  JMP @nsq_sc_err
nsq_sc_bad:
  MOVI r1,#NSEC_EBAD
  JMP @nsq_sc_err
nsq_sc_deny:
  MOVI r1,#NSEC_EDENY
  JMP @nsq_sc_err
nsq_sc_page:
  MOVI r1,#NSEC_EPAGE
  JMP @nsq_sc_err
nsq_sc_over:
  MOVI r1,#NSEC_EOVER
nsq_sc_err:
  ST r1,r0,#NSEC_G_ERR
nsq_sc_out:
  CMP r1,r0
  JMP[EQ] @nsq_sc_done
  ST r1,r0,#NSEC_G_ERR
nsq_sc_done:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nsec_verify r1=agent -> 0/code.  Full structural revalidation: header,
; root capability, every live range (live cap, aligned, 64-bit safe, guard
; metadata) with pairwise non-overlap, and every live window (mapped, live).
nsec_verify:
  ST r15,r14,0
  ADDI r14,r14,96
  ST r1,r14,1
  ST r0,r0,#NSEC_G_ERR
  LD r1,r14,1
  CALL @nsec_hdr
  CMP r1,r0
  JMP[EQ] @nsq_v_fail
  ST r1,r14,2
  LD r1,r14,1
  LD r2,r14,2
  CALL @nsec_root_check
  CMP r1,r0
  JMP[NE] @nsq_v_ecap
  ; ---- ranges
  MOVI r3,1
  ST r3,r14,3
nsq_v_rl:
  LD r3,r14,3
  MOVI r4,#NSEC_RANGES
  CMP r3,r4
  JMP[GT] @nsq_v_win
  SUB r4,r3,r13
  SHL r4,r4,4
  ADDI r4,r4,#NSEC_RANGE_OFF
  LD r5,r14,2
  ADD r4,r5,r4
  ST r4,r14,4
  LD r5,r4,#NS_R_STATE
  MOVI r6,#NS_LIVE
  BOOL.8 r5,r5,r6
  CMP r5,r0
  JMP[EQ] @nsq_v_rn
  LD r5,r4,#NS_R_STATE
  MOVI r6,#NS_R_ALL
  BOOL.8 r5,r5,r6
  ST r5,r14,5
  CMP r5,r0
  JMP[EQ] @nsq_v_bad
  LD r5,r4,#NS_R_BLO
  MOVI r6,0xFFF
  BOOL.8 r5,r5,r6
  CMP r5,r0
  JMP[NE] @nsq_v_bad
  LD r5,r4,#NS_R_SLO
  BOOL.8 r5,r5,r6
  CMP r5,r0
  JMP[NE] @nsq_v_bad
  LD r1,r4,#NS_R_BLO
  LD r2,r4,#NS_R_BHI
  LD r3,r4,#NS_R_SLO
  LD r4,r4,#NS_R_SHI
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @nsq_v_bad
  LD r3,r14,4
  ST r1,r14,7
  ST r2,r14,8
  LD r1,r14,7
  LD r2,r14,8
  CALL @nsec_lim
  CMP r1,r0
  JMP[NE] @nsq_v_fail
  LD r1,r14,1
  LD r2,r14,4
  LD r2,r2,#NS_R_KIND
  LD r3,r14,4
  LD r3,r3,#NS_R_CAP
  LD r4,r14,5
  CALL @nsec_cap_check
  CMP r1,r0
  JMP[EQ] @nsq_v_ecap
  ; ---- guard metadata must be exactly one page and stay in range
  LD r5,r14,4
  LD r6,r5,#NS_R_STATE
  MOVI r7,#NS_F_GUARD
  BOOL.8 r6,r6,r7
  CMP r6,r0
  JMP[EQ] @nsq_v_unguard
  LD r6,r5,#NS_R_GLO
  MOVI r7,#NSEC_PAGE
  CMP r6,r7
  JMP[NE] @nsq_v_bad
  LD r6,r5,#NS_R_GHI
  CMP r6,r0
  JMP[NE] @nsq_v_bad
  LD r6,r5,#NS_R_BHI
  CMP r6,r0
  JMP[NE] @nsq_v_guard_room
  LD r6,r5,#NS_R_BLO
  MOVI r7,#NSEC_PAGE
  CMP r6,r7
  JMP[LT] @nsq_v_bad
nsq_v_guard_room:
  LD r1,r14,7
  LD r2,r14,8
  MOVI r3,#NSEC_PAGE
  MOVI r4,0
  CALL @n64_add
  CMP r5,r0
  JMP[NE] @nsq_v_bad
  ST r1,r14,15
  ST r2,r14,16
  LD r1,r14,15
  LD r2,r14,16
  CALL @nsec_lim
  CMP r1,r0
  JMP[NE] @nsq_v_fail
  JMP @nsq_v_eff
nsq_v_unguard:
  LD r6,r5,#NS_R_GLO
  CMP r6,r0
  JMP[NE] @nsq_v_bad
  LD r6,r5,#NS_R_GHI
  CMP r6,r0
  JMP[NE] @nsq_v_bad
nsq_v_eff:
  ; effective interval in 9..12
  LD r5,r14,4
  LD r1,r5,#NS_R_BLO
  LD r2,r5,#NS_R_BHI
  LD r3,r5,#NS_R_SLO
  LD r4,r5,#NS_R_SHI
  CALL @n64_add
  ST r1,r14,11
  ST r2,r14,12
  LD r5,r14,4
  LD r6,r5,#NS_R_STATE
  MOVI r7,#NS_F_GUARD
  BOOL.8 r6,r6,r7
  CMP r6,r0
  JMP[EQ] @nsq_v_rplain
  LD r1,r5,#NS_R_BLO
  LD r2,r5,#NS_R_BHI
  LD r3,r5,#NS_R_GLO
  LD r4,r5,#NS_R_GHI
  CALL @n64_sub
  ST r1,r14,9
  ST r2,r14,10
  LD r1,r14,11
  LD r2,r14,12
  LD r3,r5,#NS_R_GLO
  LD r4,r5,#NS_R_GHI
  CALL @n64_add
  ST r1,r14,11
  ST r2,r14,12
  JMP @nsq_v_rovl
nsq_v_rplain:
  LD r1,r5,#NS_R_BLO
  ST r1,r14,9
  LD r1,r5,#NS_R_BHI
  ST r1,r14,10
nsq_v_rovl:
  ; compare with all later live ranges
  LD r3,r14,3
  ADDI r3,r3,1
  ST r3,r14,6
nsq_v_ol:
  LD r3,r14,6
  MOVI r4,#NSEC_RANGES
  CMP r3,r4
  JMP[GT] @nsq_v_rn
  SUB r4,r3,r13
  SHL r4,r4,4
  ADDI r4,r4,#NSEC_RANGE_OFF
  LD r5,r14,2
  ADD r4,r5,r4
  ST r4,r14,14
  LD r5,r4,#NS_R_STATE
  MOVI r6,#NS_LIVE
  BOOL.8 r5,r5,r6
  CMP r5,r0
  JMP[EQ] @nsq_v_on
  LD r1,r4,#NS_R_BLO
  LD r2,r4,#NS_R_BHI
  LD r3,r4,#NS_R_SLO
  LD r4,r4,#NS_R_SHI
  CALL @n64_add
  ST r1,r14,15
  ST r2,r14,16
  LD r5,r14,14
  LD r5,r5,#NS_R_STATE
  MOVI r7,#NS_F_GUARD
  BOOL.8 r5,r5,r7
  CMP r5,r0
  JMP[EQ] @nsq_v_oplain
  LD r1,r14,14
  LD r1,r1,#NS_R_BLO
  LD r2,r14,14
  LD r2,r2,#NS_R_BHI
  LD r3,r14,14
  LD r3,r3,#NS_R_GLO
  LD r4,r14,14
  LD r4,r4,#NS_R_GHI
  CALL @n64_sub
  ST r1,r14,15
  ST r2,r14,16
  LD r1,r14,14
  LD r1,r1,#NS_R_BLO
  LD r2,r14,14
  LD r2,r2,#NS_R_BHI
  LD r3,r14,14
  LD r3,r3,#NS_R_SLO
  LD r4,r14,14
  LD r4,r4,#NS_R_SHI
  CALL @n64_add
  LD r3,r14,14
  LD r3,r3,#NS_R_GLO
  LD r4,r14,14
  LD r4,r4,#NS_R_GHI
  CALL @n64_add
  ST r1,r14,17
  ST r2,r14,18
  JMP @nsq_v_ocall
nsq_v_oplain:
  LD r1,r14,14
  LD r1,r1,#NS_R_BLO
  LD r2,r14,14
  LD r2,r2,#NS_R_BHI
  LD r3,r14,14
  LD r3,r3,#NS_R_SLO
  LD r4,r14,14
  LD r4,r4,#NS_R_SHI
  CALL @n64_add
  ST r1,r14,17
  ST r2,r14,18
nsq_v_ocall:
  LD r1,r14,9
  LD r2,r14,10
  LD r3,r14,11
  LD r4,r14,12
  LD r5,r14,15
  LD r6,r14,16
  LD r7,r14,17
  LD r8,r14,18
  CALL @nsec_overlap
  CMP r1,r0
  JMP[NE] @nsq_v_bad
nsq_v_on:
  LD r3,r14,6
  ADDI r3,r3,1
  ST r3,r14,6
  JMP @nsq_v_ol
nsq_v_rn:
  LD r3,r14,3
  ADDI r3,r3,1
  ST r3,r14,3
  JMP @nsq_v_rl
nsq_v_win:
  MOVI r3,0
  ST r3,r14,3
nsq_v_wl:
  LD r3,r14,3
  MOVI r4,#NSEC_WINDOWS
  CMP r3,r4
  JMP[GE] @nsq_v_ok
  SHL r4,r3,3
  ADDI r4,r4,#NSEC_WIN_OFF
  LD r5,r14,2
  ADD r4,r5,r4
  ST r4,r14,4
  LD r5,r4,#NS_W_LIVE
  CMP r5,r0
  JMP[EQ] @nsq_v_wn
  ; window shape: page aligned, nonzero size, R/W rights only
  LD r5,r14,4
  LD r2,r5,#NS_W_BLO
  MOVI r3,0xFFF
  BOOL.8 r2,r2,r3
  CMP r2,r0
  JMP[NE] @nsq_v_bad
  LD r2,r5,#NS_W_SLO
  BOOL.8 r2,r2,r3
  CMP r2,r0
  JMP[NE] @nsq_v_bad
  LD r2,r5,#NS_W_SLO
  LD r6,r5,#NS_W_SHI
  CMP r2,r0
  JMP[NE] @nsq_v_wsz
  CMP r6,r0
  JMP[EQ] @nsq_v_bad
nsq_v_wsz:
  LD r2,r5,#NS_W_RIGHTS
  CMP r2,r0
  JMP[EQ] @nsq_v_bad
  MOVI r3,3
  CMP r2,r3
  JMP[GT] @nsq_v_bad
  ; nsec_check(agent, base, size, rights) with the right argument order
  LD r1,r14,1
  LD r2,r14,4
  LD r2,r2,#NS_W_BLO
  LD r3,r14,4
  LD r3,r3,#NS_W_BHI
  LD r4,r14,4
  LD r4,r4,#NS_W_SLO
  LD r5,r14,4
  LD r5,r5,#NS_W_SHI
  LD r6,r14,4
  LD r6,r6,#NS_W_RIGHTS
  CALL @nsec_check
  CMP r1,r0
  JMP[NE] @nsq_v_fail
nsq_v_wn:
  LD r3,r14,3
  ADDI r3,r3,1
  ST r3,r14,3
  JMP @nsq_v_wl
nsq_v_ok:
  MOVI r1,0
  JMP @nsq_v_out
nsq_v_bad:
  MOVI r1,#NSEC_EBAD
  JMP @nsq_v_err
nsq_v_ecap:
  MOVI r1,#NSEC_ECAP
nsq_v_err:
  ST r1,r0,#NSEC_G_ERR
  JMP @nsq_v_out
nsq_v_fail:
  LD r1,r0,#NSEC_G_ERR
nsq_v_out:
  ADDI r14,r14,-96
  LD r15,r14,0
  RET
