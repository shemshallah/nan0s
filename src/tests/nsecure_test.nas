; nsecure_test.nas - F9 isolation/security proof (pure NaN, nan_cli).
;
; Proves, in one deterministic image:
;   * two independent agent address spaces with root capabilities, code RX and
;     data RW/NX, guarded stack/heap RW/NX;
;   * W|X rejection, stack/heap NX enforcement, 64-bit overflow/wrap, the
;     64 PiB limit, page alignment, overlap and guard placement;
;   * guard-page hits are distinct from plain unmapped accesses;
;   * nanobj and nagent capability revocation: the stored old handle fails,
;     nsec_rebind with the new generation succeeds; root revoke fails closed
;     until nsec_root_set;
;   * rights downgrade rejection and per-agent cap isolation;
;   * deny-by-default sandbox: op ids and windows must both be allowed,
;     write-shaped memory ops require W, per-agent policy does not leak;
;   * 1024 deterministic malformed requests (16 classes: wrap, huge length,
;     out-of-range, W+X, stale cap, guard hit, unaligned, zero length,
;     unmapped, NX violation, denied op/window, bad agent, sandbox wrap)
;     are all denied, and 160 well-formed requests pass.
;
; Success prints exactly O.  A failed check prints F <hex code> and HALT.
;
; Guest map (word addresses):
;   0x0000          boot JMP
;   0x0400..        nagent/nanobj/nsecure libraries and this test
;   0x6800..0x683F  nagent destination generations (library)
;   0x6C00..0x6C3F  nsecure low scratch (library)
;   0x7000..0x70FF  test stack
;   0x340000        nanobj table (library)
;   0x348000        nagent table (library)
;   0x350000        nsecure address-space table (library, 16 x 256)
;
; Bases intentionally span small and >4 GiB-friendly 64-bit values; the code
; itself lives in low guest words.

.equ STK        0x7000
.equ CODE_BASE  0x10000000
.equ DATA_BASE  0x20000000
.equ STACK_BASE 0x30000000
.equ HEAP_BASE  0x40000000
.equ BCODE_BASE 0x50000000
.equ BDATA_BASE 0x60000000
.equ FREE_BASE  0x71000000
.equ LIMIT_HI   0x01000000

.org 0
JMP @main
.org 0x400
.include "../lib/nsecure.nas"

main:
MOVI r0,0
MOVI r13,1
LA r14,#STK
CALL @nobj_init
CALL @nagent_init
CALL @nsec_init

; ---------------------------------------------------------------------------
; Roots: agent A uses a nanobj memory cap, agent B uses a nagent cap.
MOVI r1,22
MOVI r2,8
CALL @nobj_create
ST r1,r0,@rootA
MOVI r5,0
MOVI r3,0x101
CALL @chkne
MOVI r1,22
MOVI r2,8
CALL @nobj_create
ST r1,r0,@rootB
MOVI r5,0
MOVI r3,0x102
CALL @chkne

MOVI r1,0
MOVI r2,0
MOVI r3,7
CALL @nagent_create
MOVI r5,1
MOVI r3,0x103
CALL @chk
MOVI r1,1
MOVI r2,1
MOVI r3,8
CALL @nagent_create
MOVI r5,2
MOVI r3,0x104
CALL @chk

; B root is a nagent tool cap, rights all.
MOVI r1,2
MOVI r2,3
MOVI r3,31
LA r4,0xB001
CALL @nagent_cap_grant
ST r1,r0,@capBroot
MOVI r5,0
MOVI r3,0x105
CALL @chkne

MOVI r1,1
LD r2,r0,@rootA
MOVI r3,#NSEC_C_NOBJ
CALL @nsec_agent_create
MOVI r5,0
MOVI r3,0x106
CALL @chk
MOVI r1,2
LD r2,r0,@capBroot
MOVI r3,#NSEC_C_NAGENT
CALL @nsec_agent_create
MOVI r5,0
MOVI r3,0x107
CALL @chk
MOVI r1,1
CALL @nsec_verify
MOVI r5,0
MOVI r3,0x108
CALL @chk
MOVI r1,2
CALL @nsec_verify
MOVI r5,0
MOVI r3,0x109
CALL @chk

; ---------------------------------------------------------------------------
; Agent A capabilities: code RX, data RW (all-rights handle so it can be
; revoked), read-only handle for the rights test, and two nanobj RW caps.
MOVI r1,1
MOVI r2,3
MOVI r3,31
LA r4,0x1000
CALL @nagent_cap_grant
ST r1,r0,@capCode
MOVI r5,0
MOVI r3,0x110
CALL @chkne
MOVI r1,1
MOVI r2,3
MOVI r3,31
LA r4,0x2000
CALL @nagent_cap_grant
ST r1,r0,@capData
MOVI r5,0
MOVI r3,0x111
CALL @chkne
MOVI r1,1
MOVI r2,3
MOVI r3,1
LA r4,0x3000
CALL @nagent_cap_grant
ST r1,r0,@capRO
MOVI r5,0
MOVI r3,0x112
CALL @chkne
MOVI r1,22
MOVI r2,8
CALL @nobj_create
ST r1,r0,@capStack
MOVI r5,0
MOVI r3,0x113
CALL @chkne
MOVI r1,22
MOVI r2,8
CALL @nobj_create
ST r1,r0,@capHeap
MOVI r5,0
MOVI r3,0x114
CALL @chkne

; ---- map agent A: code RX, data RW+guard, stack RW+NX+guard, heap RW+NX+guard
MOVI r1,1
LD r2,r0,@capCode
LA r3,#CODE_BASE
MOVI r4,0
MOVI r5,0x2000
MOVI r6,0
MOVI r7,#NS_R_READ
ADDI r7,r7,#NS_R_EXEC
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,1
MOVI r3,0x120
CALL @chk
MOVI r1,1
LD r2,r0,@capData
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x4000
MOVI r6,0
MOVI r7,#NS_R_READ
ADDI r7,r7,#NS_R_WRITE
MOVI r8,#NSEC_M_GUARD
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,2
MOVI r3,0x121
CALL @chk
MOVI r1,1
LD r2,r0,@capStack
LA r3,#STACK_BASE
MOVI r4,0
MOVI r5,0x4000
MOVI r6,0
MOVI r7,#NS_R_READ
ADDI r7,r7,#NS_R_WRITE
MOVI r8,#NSEC_M_GUARD
ADDI r8,r8,#NSEC_M_STACK
MOVI r9,#NSEC_C_NOBJ
CALL @nsec_map
MOVI r5,3
MOVI r3,0x122
CALL @chk
MOVI r1,1
LD r2,r0,@capHeap
LA r3,#HEAP_BASE
MOVI r4,0
MOVI r5,0x4000
MOVI r6,0
MOVI r7,#NS_R_READ
ADDI r7,r7,#NS_R_WRITE
MOVI r8,#NSEC_M_GUARD
ADDI r8,r8,#NSEC_M_HEAP
MOVI r9,#NSEC_C_NOBJ
CALL @nsec_map
MOVI r5,4
MOVI r3,0x123
CALL @chk
MOVI r1,1
CALL @nsec_verify
MOVI r5,0
MOVI r3,0x124
CALL @chk

; ---------------------------------------------------------------------------
; Agent B: independent code/data ranges (isolation).
MOVI r1,2
MOVI r2,3
MOVI r3,31
LA r4,0xB100
CALL @nagent_cap_grant
ST r1,r0,@capBCode
MOVI r1,2
MOVI r2,3
MOVI r3,31
LA r4,0xB200
CALL @nagent_cap_grant
ST r1,r0,@capBData
MOVI r1,2
LD r2,r0,@capBCode
LA r3,#BCODE_BASE
MOVI r4,0
MOVI r5,0x2000
MOVI r6,0
MOVI r7,#NS_R_READ
ADDI r7,r7,#NS_R_EXEC
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,1
MOVI r3,0x130
CALL @chk
MOVI r1,2
LD r2,r0,@capBData
LA r3,#BDATA_BASE
MOVI r4,0
MOVI r5,0x4000
MOVI r6,0
MOVI r7,#NS_R_READ
ADDI r7,r7,#NS_R_WRITE
MOVI r8,#NSEC_M_GUARD
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,2
MOVI r3,0x131
CALL @chk
MOVI r1,2
CALL @nsec_verify
MOVI r5,0
MOVI r3,0x132
CALL @chk

; ---------------------------------------------------------------------------
; Allowed access checks.
MOVI r1,1
LA r2,#CODE_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
MOVI r5,0
MOVI r3,0x140
CALL @chk
MOVI r1,1
LA r2,#CODE_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_EXEC
CALL @nsec_check
MOVI r5,0
MOVI r3,0x141
CALL @chk
MOVI r1,1
LA r2,#DATA_BASE
MOVI r3,0
MOVI r4,0x2000
MOVI r5,0
MOVI r6,#NS_R_READ
ADDI r6,r6,#NS_R_WRITE
CALL @nsec_check
MOVI r5,0
MOVI r3,0x142
CALL @chk
MOVI r1,1
LA r2,#STACK_BASE
MOVI r3,0
MOVI r4,0x4000
MOVI r5,0
MOVI r6,#NS_R_WRITE
CALL @nsec_check
MOVI r5,0
MOVI r3,0x143
CALL @chk
MOVI r1,1
LA r2,#HEAP_BASE
MOVI r3,0
MOVI r4,0x4000
MOVI r5,0
MOVI r6,#NS_R_WRITE
CALL @nsec_check
MOVI r5,0
MOVI r3,0x144
CALL @chk

; NX and rights failures.
MOVI r1,1
LA r2,#DATA_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_EXEC
CALL @nsec_check
MOVI r5,#NSEC_ERIGHT
MOVI r3,0x145
CALL @chk
MOVI r1,1
LA r2,#CODE_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_WRITE
CALL @nsec_check
MOVI r5,#NSEC_ERIGHT
MOVI r3,0x146
CALL @chk
MOVI r1,1
LA r2,#STACK_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_EXEC
CALL @nsec_check
MOVI r5,#NSEC_ENX
MOVI r3,0x147
CALL @chk

; Per-agent isolation: A cannot touch B's space and vice versa.
MOVI r1,1
LA r2,#BCODE_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
MOVI r5,#NSEC_ERANGE
MOVI r3,0x148
CALL @chk
MOVI r1,2
LA r2,#DATA_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
MOVI r5,#NSEC_ERANGE
MOVI r3,0x149
CALL @chk

; ---------------------------------------------------------------------------
; Guard pages: inside usable memory, both guards, partial guard, then the
; page beyond the guard is plain unmapped.
MOVI r1,1
LA r2,#DATA_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
MOVI r5,0
MOVI r3,0x150
CALL @chk
; base - 0x1000
MOVI r1,1
LA r2,0x1FFFF000
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
MOVI r5,#NSEC_EGUARD
MOVI r3,0x151
CALL @chk
; end + 0x1000
MOVI r1,1
LA r2,0x20004000
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
MOVI r5,#NSEC_EGUARD
MOVI r3,0x152
CALL @chk
; crossing the upper guard
MOVI r1,1
LA r2,0x20003000
MOVI r3,0
MOVI r4,0x2000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
MOVI r5,#NSEC_EGUARD
MOVI r3,0x153
CALL @chk
; partial lower guard
MOVI r1,1
LA r2,0x1FFFF800
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
MOVI r5,#NSEC_EGUARD
MOVI r3,0x154
CALL @chk
; one page below the lower guard: unmapped, not a guard
MOVI r1,1
LA r2,0x1FFFE000
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
MOVI r5,#NSEC_ERANGE
MOVI r3,0x155
CALL @chk

; ---------------------------------------------------------------------------
; Map rejections with exact errno.
; W|X
MOVI r1,1
LD r2,r0,@capCode
LA r3,#FREE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_WRITE
ADDI r7,r7,#NS_R_EXEC
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_EWX
MOVI r3,0x160
CALL @chkmap
; stack execute (R|X with STACK flag)
MOVI r1,1
LD r2,r0,@capStack
LA r3,#STACK_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
ADDI r7,r7,#NS_R_EXEC
MOVI r8,#NSEC_M_STACK
MOVI r9,#NSEC_C_NOBJ
CALL @nsec_map
MOVI r5,#NSEC_ENX
MOVI r3,0x161
CALL @chkmap
; 64-bit wrap: low add carries, high add carries out.
MOVI r1,1
LD r2,r0,@capCode
LA r3,0xFFFFF000
LA r4,0xFFFFFFFF
MOVI r5,0x2000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_EOVER
MOVI r3,0x162
CALL @chkmap
; out of range at the 64 PiB ceiling
MOVI r1,1
LD r2,r0,@capCode
MOVI r3,0
LA r4,#LIMIT_HI
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_ERANGE
MOVI r3,0x163
CALL @chkmap
; huge length wraps both halves
MOVI r1,1
LD r2,r0,@capCode
LA r3,#DATA_BASE
MOVI r4,0
LA r5,0xFFFFF000
LA r6,0xFFFFFFFF
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_EOVER
MOVI r3,0x164
CALL @chkmap
; unaligned base
MOVI r1,1
LD r2,r0,@capCode
LA r3,0x71000800
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_EPAGE
MOVI r3,0x165
CALL @chkmap
; unaligned length
MOVI r1,1
LD r2,r0,@capCode
LA r3,#FREE_BASE
MOVI r4,0
MOVI r5,0x1001
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_EPAGE
MOVI r3,0x166
CALL @chkmap
; zero length
MOVI r1,1
LD r2,r0,@capCode
LA r3,#FREE_BASE
MOVI r4,0
MOVI r5,0
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_EBAD
MOVI r3,0x167
CALL @chkmap
; overlap with the code range
MOVI r1,1
LD r2,r0,@capCode
LA r3,#CODE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_ERANGE
MOVI r3,0x168
CALL @chkmap
; overlap with the data range's upper guard
MOVI r1,1
LD r2,r0,@capCode
LA r3,0x20004000
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_ERANGE
MOVI r3,0x169
CALL @chkmap
; guarded range with no room for the lower guard
MOVI r1,1
LD r2,r0,@capCode
MOVI r3,0
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,#NSEC_M_GUARD
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_ERANGE
MOVI r3,0x16A
CALL @chkmap
; unknown cap kind
MOVI r1,1
LD r2,r0,@capCode
LA r3,#FREE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,3
CALL @nsec_map
MOVI r5,#NSEC_EBAD
MOVI r3,0x16B
CALL @chkmap
; no such agent
MOVI r1,0
LD r2,r0,@capCode
LA r3,#FREE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_ENOENT
MOVI r3,0x16C
CALL @chkmap
MOVI r1,17
LD r2,r0,@capCode
LA r3,#FREE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_ENOENT
MOVI r3,0x16D
CALL @chkmap
; cross-agent capability: A's rights-1 index-3 handle does not match B's rights-31 entry at index 3
MOVI r1,2
LD r2,r0,@capRO
LA r3,#FREE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_ECAP
MOVI r3,0x16E
CALL @chkmap
; rights downgrade: read-only handle cannot authorize RW
MOVI r1,1
LD r2,r0,@capRO
LA r3,#FREE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
ADDI r7,r7,#NS_R_WRITE
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_ECAP
MOVI r3,0x16F
CALL @chkmap

; Read-only range is accepted, W fails, R passes, then free it.
MOVI r1,1
LD r2,r0,@capRO
LA r3,#FREE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,5
MOVI r3,0x170
CALL @chk
MOVI r1,1
LA r2,#FREE_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_WRITE
CALL @nsec_check
MOVI r5,#NSEC_ERIGHT
MOVI r3,0x171
CALL @chk
MOVI r1,1
LA r2,#FREE_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
MOVI r5,0
MOVI r3,0x172
CALL @chk
MOVI r1,1
MOVI r2,5
CALL @nsec_unmap
MOVI r5,0
MOVI r3,0x173
CALL @chk

; Bad unmap arguments.
MOVI r1,1
MOVI r2,0
CALL @nsec_unmap
MOVI r5,#NSEC_EBAD
MOVI r3,0x174
CALL @chk
MOVI r1,1
MOVI r2,9
CALL @nsec_unmap
MOVI r5,#NSEC_EBAD
MOVI r3,0x175
CALL @chk
MOVI r1,1
MOVI r2,5
CALL @nsec_unmap
MOVI r5,#NSEC_ENOENT
MOVI r3,0x176
CALL @chk

; ---------------------------------------------------------------------------
; Capability revocation integration.
; (a) nanobj address-space root: revoke, fail closed, rebind, recover.
LD r1,r0,@rootA
CALL @nobj_revoke
ST r1,r0,@rootA2
MOVI r5,0
MOVI r3,0x180
CALL @chkne
MOVI r1,1
LA r2,#CODE_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
MOVI r5,#NSEC_ECAP
MOVI r3,0x181
CALL @chk
MOVI r1,1
CALL @nsec_verify
MOVI r5,#NSEC_ECAP
MOVI r3,0x182
CALL @chk
MOVI r1,1
LD r2,r0,@rootA2
MOVI r3,#NSEC_C_NOBJ
CALL @nsec_root_set
MOVI r5,0
MOVI r3,0x183
CALL @chk
MOVI r1,1
LA r2,#CODE_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
MOVI r5,0
MOVI r3,0x184
CALL @chk

; (b) nagent data cap: old handle fails, rebind with new generation works.
MOVI r1,1
LD r2,r0,@capData
CALL @nagent_cap_revoke
ST r1,r0,@capData2
MOVI r5,0
MOVI r3,0x185
CALL @chkne
MOVI r1,1
LA r2,#DATA_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
ADDI r6,r6,#NS_R_WRITE
CALL @nsec_check
MOVI r5,#NSEC_ECAP
MOVI r3,0x186
CALL @chk
MOVI r1,1
MOVI r2,2
LD r3,r0,@capData2
CALL @nsec_rebind
MOVI r5,0
MOVI r3,0x187
CALL @chk
MOVI r1,1
LA r2,#DATA_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
ADDI r6,r6,#NS_R_WRITE
CALL @nsec_check
MOVI r5,0
MOVI r3,0x188
CALL @chk
; old handle cannot be used to map a new range either
MOVI r1,1
LD r2,r0,@capData
LA r3,#FREE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_ECAP
MOVI r3,0x189
CALL @chkmap

; (c) nanobj stack cap: same proof, and the heap cap is independent.
LD r1,r0,@capStack
CALL @nobj_revoke
ST r1,r0,@capStack2
MOVI r5,0
MOVI r3,0x18A
CALL @chkne
MOVI r1,1
LA r2,#STACK_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_WRITE
CALL @nsec_check
MOVI r5,#NSEC_ECAP
MOVI r3,0x18B
CALL @chk
MOVI r1,1
MOVI r2,3
LD r3,r0,@capStack2
CALL @nsec_rebind
MOVI r5,0
MOVI r3,0x18C
CALL @chk
MOVI r1,1
LA r2,#STACK_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_WRITE
CALL @nsec_check
MOVI r5,0
MOVI r3,0x18D
CALL @chk
MOVI r1,1
LA r2,#HEAP_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_WRITE
CALL @nsec_check
MOVI r5,0
MOVI r3,0x18E
CALL @chk

; ---------------------------------------------------------------------------
; No-space and reuse: fill the four remaining range slots, the ninth fails,
; then unmap all four and confirm the slots are reusable.
MOVI r1,1
LD r2,r0,@capCode
LA r3,0x71000000
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,5
MOVI r3,0x190
CALL @chk
MOVI r1,1
LD r2,r0,@capCode
LA r3,0x71002000
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,6
MOVI r3,0x191
CALL @chk
MOVI r1,1
LD r2,r0,@capCode
LA r3,0x71004000
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,7
MOVI r3,0x192
CALL @chk
MOVI r1,1
LD r2,r0,@capCode
LA r3,0x71006000
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,8
MOVI r3,0x193
CALL @chk
MOVI r1,1
LD r2,r0,@capCode
LA r3,0x71008000
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
MOVI r5,#NSEC_ESPACE
MOVI r3,0x194
CALL @chkmap
MOVI r1,1
MOVI r2,5
CALL @nsec_unmap
MOVI r5,0
MOVI r3,0x195
CALL @chk
MOVI r1,1
MOVI r2,6
CALL @nsec_unmap
MOVI r1,1
MOVI r2,7
CALL @nsec_unmap
MOVI r1,1
MOVI r2,8
CALL @nsec_unmap
MOVI r1,1
CALL @nsec_verify
MOVI r5,0
MOVI r3,0x196
CALL @chk

; ---------------------------------------------------------------------------
; Sandbox: deny by default, then an explicit op and window.
MOVI r1,1
CALL @nsec_sandbox_init
MOVI r5,0
MOVI r3,0x1A0
CALL @chk
MOVI r1,1
MOVI r2,42
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,#NSEC_EDENY
MOVI r3,0x1A1
CALL @chk

MOVI r1,1
MOVI r2,42
CALL @nsec_sandbox_allow_op
MOVI r5,0
MOVI r3,0x1A2
CALL @chk
MOVI r1,1
MOVI r2,42
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,#NSEC_EWIN
MOVI r3,0x1A3
CALL @chk

MOVI r1,1
MOVI r2,0
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x2000
MOVI r6,0
MOVI r7,#NS_R_READ
ADDI r7,r7,#NS_R_WRITE
CALL @nsec_sandbox_window
MOVI r5,0
MOVI r3,0x1A4
CALL @chk
MOVI r1,1
MOVI r2,42
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,0
MOVI r3,0x1A5
CALL @chk
; second page of the window
MOVI r1,1
MOVI r2,42
LA r3,0x20001000
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,0
MOVI r3,0x1A6
CALL @chk
; outside the window (still inside data)
MOVI r1,1
MOVI r2,42
LA r3,0x20003000
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,#NSEC_EWIN
MOVI r3,0x1A7
CALL @chk
; op not allowed
MOVI r1,1
MOVI r2,43
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,#NSEC_EDENY
MOVI r3,0x1A8
CALL @chk
; unaligned buffer
MOVI r1,1
MOVI r2,42
LA r3,0x20000010
MOVI r4,0
MOVI r5,0x100
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,#NSEC_EPAGE
MOVI r3,0x1A9
CALL @chk
; buffer spans past the window
MOVI r1,1
MOVI r2,42
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x3000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,#NSEC_EWIN
MOVI r3,0x1AA
CALL @chk
; memory write op requires W: allow 56, data window has W.
MOVI r1,1
MOVI r2,56
CALL @nsec_sandbox_allow_op
MOVI r5,0
MOVI r3,0x1AB
CALL @chk
MOVI r1,1
MOVI r2,56
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,0
MOVI r3,0x1AC
CALL @chk
; code window is read-only, so write-shaped op 56 is refused by the window
MOVI r1,1
MOVI r2,1
LA r3,#CODE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
CALL @nsec_sandbox_window
MOVI r5,0
MOVI r3,0x1AD
CALL @chk
MOVI r1,1
MOVI r2,48
CALL @nsec_sandbox_allow_op
MOVI r5,0
MOVI r3,0x1AE
CALL @chk
MOVI r1,1
MOVI r2,48
LA r3,#CODE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,0
MOVI r3,0x1AF
CALL @chk
MOVI r1,1
MOVI r2,56
LA r3,#CODE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,#NSEC_EWIN
MOVI r3,0x1B0
CALL @chk
; malformed window definitions
MOVI r1,1
MOVI r2,2
LA r3,#FREE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
ADDI r7,r7,#NS_R_EXEC
CALL @nsec_sandbox_window
MOVI r5,#NSEC_EWX
MOVI r3,0x1B1
CALL @chk
MOVI r1,1
MOVI r2,2
LA r3,#FREE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
CALL @nsec_sandbox_window
MOVI r5,#NSEC_ERANGE
MOVI r3,0x1B2
CALL @chk
MOVI r1,1
MOVI r2,2
LA r3,0x20000100
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
CALL @nsec_sandbox_window
MOVI r5,#NSEC_EPAGE
MOVI r3,0x1B3
CALL @chk
MOVI r1,1
MOVI r2,2
LA r3,0xFFFFF000
LA r4,0xFFFFFFFF
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
CALL @nsec_sandbox_window
MOVI r5,#NSEC_EOVER
MOVI r3,0x1B4
CALL @chk
MOVI r1,1
MOVI r2,2
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0
MOVI r6,0
MOVI r7,#NS_R_READ
CALL @nsec_sandbox_window
MOVI r5,#NSEC_EBAD
MOVI r3,0x1B5
CALL @chk
MOVI r1,1
MOVI r2,4
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
CALL @nsec_sandbox_window
MOVI r5,#NSEC_EBAD
MOVI r3,0x1B6
CALL @chk
MOVI r1,1
MOVI r2,63
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,#NSEC_EDENY
MOVI r3,0x1B7
CALL @chk
MOVI r1,1
MOVI r2,42
LA r3,0xFFFFF000
LA r4,0xFFFFFFFF
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,#NSEC_EOVER
MOVI r3,0x1B8
CALL @chk
MOVI r1,1
CALL @nsec_verify
MOVI r5,0
MOVI r3,0x1B9
CALL @chk

; Per-agent policy isolation.
MOVI r1,2
CALL @nsec_sandbox_init
MOVI r5,0
MOVI r3,0x1C0
CALL @chk
MOVI r1,2
MOVI r2,42
LA r3,#BDATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,#NSEC_EDENY
MOVI r3,0x1C1
CALL @chk
MOVI r1,2
MOVI r2,42
CALL @nsec_sandbox_allow_op
MOVI r5,0
MOVI r3,0x1C2
CALL @chk
MOVI r1,2
MOVI r2,42
LA r3,#BDATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,#NSEC_EWIN
MOVI r3,0x1C3
CALL @chk
MOVI r1,2
MOVI r2,0
LA r3,#BDATA_BASE
MOVI r4,0
MOVI r5,0x2000
MOVI r6,0
MOVI r7,#NS_R_READ
ADDI r7,r7,#NS_R_WRITE
CALL @nsec_sandbox_window
MOVI r5,0
MOVI r3,0x1C4
CALL @chk
MOVI r1,2
MOVI r2,42
LA r3,#BDATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,0
MOVI r3,0x1C5
CALL @chk
; A's window is not visible to B and vice versa
MOVI r1,2
MOVI r2,42
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,#NSEC_EWIN
MOVI r3,0x1C6
CALL @chk
MOVI r1,1
MOVI r2,42
LA r3,#BDATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,#NSEC_EWIN
MOVI r3,0x1C7
CALL @chk

; Root revoke after policy exists also fails closed, then recovers.
LD r1,r0,@rootA2
CALL @nobj_revoke
ST r1,r0,@rootA3
MOVI r5,0
MOVI r3,0x1C8
CALL @chkne
MOVI r1,1
MOVI r2,42
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,#NSEC_ECAP
MOVI r3,0x1C9
CALL @chk
MOVI r1,1
LD r2,r0,@rootA3
MOVI r3,#NSEC_C_NOBJ
CALL @nsec_root_set
MOVI r5,0
MOVI r3,0x1CA
CALL @chk
MOVI r1,1
MOVI r2,42
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
MOVI r5,0
MOVI r3,0x1CB
CALL @chk

; ---------------------------------------------------------------------------
; Deterministic malformed corpus: 1024 requests, 16 classes.  Every request
; must be denied.  Class dispatch is (i & 15); values vary with i.
MOVI r1,1
ST r1,r0,@mi
MOVI r1,0
ST r1,r0,@mdeny
mal_loop:
LD r6,r0,@mi
MOVI r7,1024
CMP r6,r7
JMP[GT] @mal_done
MOVI r7,15
BOOL.8 r8,r6,r7
JMP @mal_disp
mal_c0:
; 0: 64-bit wrap on a check
MOVI r6,0xF000
SHL r6,r6,16
LD r7,r0,@mi
MOVI r8,0xFF
BOOL.8 r7,r7,r8
ADD r6,r6,r7
MOVI r1,1
ADD r2,r6,r0
LA r3,0xFFFFFFFF
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
JMP @mal_count
mal_c1:
; 1: huge length wraps both halves
MOVI r1,1
LA r2,#DATA_BASE
MOVI r3,0
LA r4,0xFFFFF000
LA r5,0xFFFFFFFF
MOVI r6,#NS_R_READ
CALL @nsec_check
JMP @mal_count
mal_c2:
; 2: out of range above 64 PiB
MOVI r1,1
MOVI r2,0
LA r3,#LIMIT_HI
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
JMP @mal_count
mal_c3:
; 3: W|X rights on a check, varying offset
LA r2,#DATA_BASE
LD r6,r0,@mi
MOVI r7,0x3F
BOOL.8 r6,r6,r7
SHL r6,r6,6
ADD r2,r2,r6
MOVI r1,1
MOVI r3,0
MOVI r4,0x40
MOVI r5,0
MOVI r6,#NS_R_WRITE
ADDI r6,r6,#NS_R_EXEC
CALL @nsec_check
JMP @mal_count
mal_c4:
; 4: stale nagent cap on map (old generation)
MOVI r1,1
LD r2,r0,@capData
LA r3,#FREE_BASE
LD r6,r0,@mi
MOVI r7,0x0F
BOOL.8 r6,r6,r7
SHL r6,r6,12
ADD r3,r3,r6
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
CMP r1,r0
JMP[NE] @mal_success
CALL @nsec_errno
JMP @mal_count
mal_c5:
; 5: guard hit, varying byte offset inside the lower guard page
MOVI r6,0xF000
SHL r6,r6,16
MOVI r7,0x1
SHL r7,r7,28
ADD r6,r6,r7
LD r7,r0,@mi
MOVI r8,0xFF
BOOL.8 r7,r7,r8
SHL r7,r7,3
SUB r6,r6,r7
MOVI r1,1
ADD r2,r6,r0
MOVI r3,0
MOVI r4,8
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
JMP @mal_count
mal_c6:
; 6: unaligned map
MOVI r1,1
LD r2,r0,@capCode
LA r3,#FREE_BASE
LD r6,r0,@mi
MOVI r7,0x0F
BOOL.8 r6,r6,r7
SHL r6,r6,13
ADD r3,r3,r6
ADDI r3,r3,0x800
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
MOVI r7,#NS_R_READ
MOVI r8,0
MOVI r9,#NSEC_C_NAGENT
CALL @nsec_map
CMP r1,r0
JMP[NE] @mal_success
CALL @nsec_errno
JMP @mal_count
mal_c7:
; 7: zero-length check
MOVI r1,1
LA r2,#DATA_BASE
MOVI r3,0
MOVI r4,0
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
JMP @mal_count
mal_c8:
; 8: unmapped check, varying page
LA r6,0x50000000
LD r7,r0,@mi
MOVI r8,0x0F
BOOL.8 r7,r7,r8
SHL r7,r7,12
ADD r6,r6,r7
MOVI r1,1
ADD r2,r6,r0
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
JMP @mal_count
mal_c9:
; 9: execute request on NX data
MOVI r1,1
LA r2,#DATA_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_EXEC
CALL @nsec_check
JMP @mal_count
mal_c10:
; 10: sandbox op never allowed (32..39)
LD r6,r0,@mi
MOVI r7,7
BOOL.8 r6,r6,r7
ADDI r6,r6,32
MOVI r1,1
ADD r2,r6,r0
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
JMP @mal_count
mal_c11:
; 11: allowed op but outside every window
MOVI r1,1
MOVI r2,42
LA r3,0x20003000
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
JMP @mal_count
mal_c12:
; 12: check straddles the upper guard
LA r6,0x20003000
LD r7,r0,@mi
MOVI r8,0x3F
BOOL.8 r7,r7,r8
SHL r7,r7,2
ADD r6,r6,r7
MOVI r1,1
ADD r2,r6,r0
MOVI r3,0
MOVI r4,0x2000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
JMP @mal_count
mal_c13:
; 13: bad agent id
MOVI r1,0
LA r2,#DATA_BASE
MOVI r3,0
MOVI r4,0x1000
MOVI r5,0
MOVI r6,#NS_R_READ
CALL @nsec_check
JMP @mal_count
mal_c14:
; 14: check exactly at the 64 PiB limit
MOVI r1,1
MOVI r2,0
LA r3,#LIMIT_HI
MOVI r4,0
MOVI r5,0x1000
MOVI r6,#NS_R_READ
CALL @nsec_check
JMP @mal_count
mal_c15:
; 15: sandbox address wrap
MOVI r1,1
MOVI r2,42
LA r3,0xFFFFF000
LA r4,0xFFFFFFFF
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
JMP @mal_count

mal_disp:
CMP r8,r0
JMP[EQ] @mal_c0
MOVI r9,1
CMP r8,r9
JMP[EQ] @mal_c1
MOVI r9,2
CMP r8,r9
JMP[EQ] @mal_c2
MOVI r9,3
CMP r8,r9
JMP[EQ] @mal_c3
MOVI r9,4
CMP r8,r9
JMP[EQ] @mal_c4
MOVI r9,5
CMP r8,r9
JMP[EQ] @mal_c5
MOVI r9,6
CMP r8,r9
JMP[EQ] @mal_c6
MOVI r9,7
CMP r8,r9
JMP[EQ] @mal_c7
MOVI r9,8
CMP r8,r9
JMP[EQ] @mal_c8
MOVI r9,9
CMP r8,r9
JMP[EQ] @mal_c9
MOVI r9,10
CMP r8,r9
JMP[EQ] @mal_c10
MOVI r9,11
CMP r8,r9
JMP[EQ] @mal_c11
MOVI r9,12
CMP r8,r9
JMP[EQ] @mal_c12
MOVI r9,13
CMP r8,r9
JMP[EQ] @mal_c13
MOVI r9,14
CMP r8,r9
JMP[EQ] @mal_c14
JMP @mal_c15

mal_success:
; a malformed map must not return a range id
MOVI r1,0xE3
JMP @failcode
mal_count:
; map failures return 0 with errno loaded by the class; check and sandbox
; calls return the code directly.  A zero is an admitted request: failure.
CMP r1,r0
JMP[NE] @mal_denied
MOVI r1,0xE0
JMP @failcode
mal_denied:
LD r6,r0,@mdeny
ADDI r6,r6,1
ST r6,r0,@mdeny
LD r6,r0,@mi
ADDI r6,r6,1
ST r6,r0,@mi
JMP @mal_loop
mal_done:
LD r6,r0,@mdeny
MOVI r7,1024
CMP r6,r7
JMP[EQ] @mal_ok
MOVI r1,0xE1
JMP @failcode
mal_ok:

; ---------------------------------------------------------------------------
; Allowed corpus: 64 mixed R/W checks inside data, 32 sandbox reads in the
; data window, one read through the code window, one write through data.
MOVI r1,0
ST r1,r0,@ai
allow_l:
LD r6,r0,@ai
MOVI r7,64
CMP r6,r7
JMP[GE] @allow_d
MOVI r7,7
BOOL.8 r9,r6,r7
SHL r9,r9,9
LA r2,#DATA_BASE
ADD r2,r2,r9
MOVI r3,0
MOVI r4,0x100
MOVI r5,0
MOVI r7,1
BOOL.8 r8,r6,r7
MOVI r6,1
ADD r6,r6,r8
MOVI r1,1
CALL @nsec_check
CMP r1,r0
JMP[NE] @allow_bad
LD r6,r0,@ai
ADDI r6,r6,1
ST r6,r0,@ai
JMP @allow_l
allow_d:
MOVI r1,0
ST r1,r0,@ai
sallow_l:
LD r6,r0,@ai
MOVI r7,32
CMP r6,r7
JMP[GE] @sallow_d
MOVI r7,1
BOOL.8 r9,r6,r7
SHL r9,r9,12
LA r3,#DATA_BASE
ADD r3,r3,r9
MOVI r1,1
MOVI r2,42
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
CMP r1,r0
JMP[NE] @allow_bad
LD r6,r0,@ai
ADDI r6,r6,1
ST r6,r0,@ai
JMP @sallow_l
sallow_d:
MOVI r1,1
MOVI r2,48
LA r3,#CODE_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
CMP r1,r0
JMP[NE] @allow_bad
MOVI r1,1
MOVI r2,56
LA r3,#DATA_BASE
MOVI r4,0
MOVI r5,0x1000
MOVI r6,0
CALL @nsec_sandbox_check
CMP r1,r0
JMP[NE] @allow_bad
JMP @pass
allow_bad:
MOVI r1,0xE2
JMP @failcode

; ---------------------------------------------------------------------------
pass:
MOVI r1,79
PUTC r1
HALT

; chk r1=actual r5=expected r3=diagnostic -> HALT on mismatch.
chk:
CMP r1,r5
JMP[EQ] @chk_ok
ADD r1,r3,r0
JMP @failcode
chk_ok:
MOVI r1,0
RET

; chkne r1=a r5=b r3=diagnostic -> HALT when a == b.
chkne:
CMP r1,r5
JMP[NE] @chkne_ok
ADD r1,r3,r0
JMP @failcode
chkne_ok:
MOVI r1,0
RET

; chkmap r1=map result (0 expected) r5=errno r3=diagnostic.
chkmap:
ST r15,r14,0
ADDI r14,r14,24
ST r5,r14,1
ST r3,r14,2
CMP r1,r0
JMP[NE] @chkmap_bad
CALL @nsec_errno
LD r5,r14,1
CMP r1,r5
JMP[NE] @chkmap_bad
MOVI r1,0
ADDI r14,r14,-24
LD r15,r14,0
RET
chkmap_bad:
LD r1,r14,2
JMP @failcode

failcode:
ST r15,r14,0
ADDI r14,r14,24
ST r1,r14,1
MOVI r1,70
PUTC r1
MOVI r1,32
PUTC r1
LD r1,r14,1
CALL @t_puthex4
MOVI r1,10
PUTC r1
HALT

; t_puthex4 r1 -> four uppercase hex digits (low 16 bits, high first).
t_puthex4:
ST r15,r14,0
ADDI r14,r14,16
ST r1,r14,1
LD r1,r14,1
SHR r1,r1,12
MOVI r2,0xF
BOOL.8 r1,r1,r2
CALL @t_putnib
LD r1,r14,1
SHR r1,r1,8
MOVI r2,0xF
BOOL.8 r1,r1,r2
CALL @t_putnib
LD r1,r14,1
SHR r1,r1,4
MOVI r2,0xF
BOOL.8 r1,r1,r2
CALL @t_putnib
LD r1,r14,1
MOVI r2,0xF
BOOL.8 r1,r1,r2
CALL @t_putnib
ADDI r14,r14,-16
LD r15,r14,0
RET

t_putnib:
CMP r1,r0
JMP[LT] @t_pn_d
MOVI r2,10
CMP r1,r2
JMP[LT] @t_pn_l
ADDI r1,r1,55
JMP @t_pn_o
t_pn_l:
ADDI r1,r1,48
JMP @t_pn_o
t_pn_d:
MOVI r1,63
t_pn_o:
PUTC r1
RET

; ---------------------------------------------------------------------------
; Test state (low data words; labels resolve below the 0x6800 boundary).
rootA:
.word 0
rootA2:
.word 0
rootA3:
.word 0
rootB:
.word 0
capBroot:
.word 0
capCode:
.word 0
capData:
.word 0
capData2:
.word 0
capRO:
.word 0
capStack:
.word 0
capStack2:
.word 0
capHeap:
.word 0
capBCode:
.word 0
capBData:
.word 0
mi:
.word 0
mdeny:
.word 0
ai:
.word 0

.org 0x7000
stack:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
