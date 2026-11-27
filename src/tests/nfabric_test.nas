; nfabric_test.nas - F11 two-node loopback RDMA, remote KV and checkpoint proof.
;
; Pure NaN image.  Proves, deterministically:
;   * two node records and queue pairs with posted receives, credits and FIFO
;     send/recv matching; no-credit sends fail closed;
;   * RDMA write/read through a remote key with rights, bounds and 64-bit
;     offsets, plus bidirectional traffic;
;   * rkey revoke: the old key fails ESTALE, the new key works;
;   * remote KV put/get over real nkv slabs, including stale slab generations
;     and exact token-byte equality;
;   * nagent-style "NAGC" checkpoint transport (push and pull), seal
;     verification, exact word equality and epoch rollback rejection;
;   * a corrupted checkpoint seal is rejected ECK.
;
; Success prints exactly O.  A failed check prints F <hex id> and HALT.
;
; Guest map (word addresses):
;   0x0000 boot JMP
;   0x0400.. nfabric/nkv/nheap/nanobj and this test (ends below 0x4000)
;   0x5000 nkv scratch, 0x7000 nfabric scratch, 0x7800 nheap scratch
;   0x6000 fabric nodes/QPs/MRs/CQs/configuration
;   0x8F00 test stack
; Byte buffers:
;   0x10000 source   0x12000 destination   0x16000 checkpoint blob
;   0x17000 receive blob   0x17400 stale blob
;   0x24000 node0 MR    0x26000 node1 MR    0x28000 read-only MR
;   0x40000/0x41000 nkv slab backing pages from nheap

.equ STK        0x8F00

.equ SRC        0x10000
.equ DST        0x12000
.equ BLOB       0x16000
.equ BLOB2      0x17000
.equ STALE      0x17400

.equ N0WIN      0x24000
.equ N1WIN      0x26000
.equ ROWIN      0x28000

.equ FAB        0x6000
.equ N0         0x6010
.equ N1         0x6050
.equ QP0T       0x6090
.equ QP1T       0x60D0
.equ MR0T       0x6110
.equ MR1T       0x6120
.equ CQ0        0x6130
.equ CQ1        0x6170
.equ RQ0        0x61B0
.equ RQ1        0x61D0
.equ MRINFO     0x61F0
.equ STAT       0x6200
.equ TMP        0x6220
.equ HCTX       0x6280
.equ HDESC      0x62A0
.equ HLIST      0x6320
.equ CFGKV      0x6340
.equ BT1        0x6360
.equ BT2        0x63A0

.equ KEY0       0x6200
.equ KEY1       0x6201
.equ KEYRO      0x6202
.equ KEY1B      0x6203
.equ CAP1       0x6204
.equ CAP2       0x6205
.equ HASH       0x6206

.org 0
JMP @main
.org 0x400
.include "../lib/nfabric.nas"

main:
MOVI r0,0
MOVI r13,1
LA r14,#STK
CALL @nobj_init

; ---------------------------------------------------------------------------
; Two 4 KiB pages for the KV slabs.
LA r1,#HCTX
LA r2,#HDESC
MOVI r3,16
LA r4,#HLIST
MOVI r5,12
MOVI r6,1
CALL @nheap_init
LA r1,#HCTX
MOVI r2,0
MOVI r3,0
LA r4,0x40000
MOVI r5,0
MOVI r6,2
MOVI r7,0
CALL @nheap_add
MOVI r5,0
MOVI r3,0x101
CALL @chk

; ---------------------------------------------------------------------------
; Nodes, fabric and memory regions.
LA r1,#N0
MOVI r2,0
LA r3,#QP0T
MOVI r4,2
LA r5,#MR0T
MOVI r6,2
CALL @nfab_node_init
MOVI r5,0
MOVI r3,0x110
CALL @chk

LA r1,#N1
MOVI r2,1
LA r3,#QP1T
MOVI r4,2
LA r5,#MR1T
MOVI r6,2
CALL @nfab_node_init
MOVI r5,0
MOVI r3,0x111
CALL @chk

LA r1,#FAB
LA r2,#N0
LA r3,#N1
CALL @nfab_init
MOVI r5,0
MOVI r3,0x112
CALL @chk

; node0 MR slot1: write window for reverse traffic
LA r1,#N0
MOVI r2,1
LA r3,#N0WIN
MOVI r4,0
LA r5,0x1000
MOVI r6,0
MOVI r7,3
CALL @nfab_mr_register
ST r1,r0,#KEY0
MOVI r5,0
MOVI r3,0x113
CALL @chkne

; node1 MR slot1: primary write window
LA r1,#N1
MOVI r2,1
LA r3,#N1WIN
MOVI r4,0
LA r5,0x2000
MOVI r6,0
MOVI r7,3
CALL @nfab_mr_register
ST r1,r0,#KEY1
MOVI r5,0
MOVI r3,0x114
CALL @chkne

; node1 MR slot2: read-only window
LA r1,#N1
MOVI r2,2
LA r3,#ROWIN
MOVI r4,0
LA r5,0x1000
MOVI r6,0
MOVI r7,1
CALL @nfab_mr_register
ST r1,r0,#KEYRO
MOVI r5,0
MOVI r3,0x115
CALL @chkne

; duplicate slot is rejected
LA r1,#N1
MOVI r2,1
LA r3,#N1WIN
MOVI r4,0
LA r5,0x1000
MOVI r6,0
MOVI r7,3
CALL @nfab_mr_register
MOVI r5,0
MOVI r3,0x116
CALL @chk
LA r1,#N1
CALL @nfab_errno
MOVI r5,#NFAB_EBAD
MOVI r3,0x117
CALL @chk

; key and MR info agree with the registered descriptor
LA r1,#N1
MOVI r2,1
CALL @nfab_mr_key
LD r5,r0,#KEY1
MOVI r3,0x118
CALL @chk
LA r1,#N1
MOVI r2,1
LA r3,#MRINFO
CALL @nfab_mr_info
MOVI r5,0
MOVI r3,0x119
CALL @chk
LD r1,r0,#MRINFO+1
LA r5,#N1WIN
MOVI r3,0x11A
CALL @chk
LD r1,r0,#MRINFO+7
LD r5,r0,#KEY1
MOVI r3,0x11B
CALL @chk

; ---------------------------------------------------------------------------
; Queue pairs and connections.
LA r1,#N0
MOVI r2,1
LA r3,#N1
MOVI r4,1
MOVI r5,4
LA r6,#RQ0
LA r7,#CQ0
CALL @nfab_qp_create
MOVI r5,0
MOVI r3,0x120
CALL @chk

LA r1,#N1
MOVI r2,1
LA r3,#N0
MOVI r4,1
MOVI r5,4
LA r6,#RQ1
LA r7,#CQ1
CALL @nfab_qp_create
MOVI r5,0
MOVI r3,0x121
CALL @chk

LA r1,#N0
MOVI r2,1
CALL @nfab_qp_connect
MOVI r5,0
MOVI r3,0x122
CALL @chk
LA r1,#N1
MOVI r2,1
CALL @nfab_qp_connect
MOVI r5,0
MOVI r3,0x123
CALL @chk

LA r1,#N0
MOVI r2,1
CALL @nfab_credits
MOVI r5,0
MOVI r3,0x124
CALL @chk

; no posted receive: send fails with ECREDIT
LA r1,#N0
MOVI r2,1
LA r3,#SRC
MOVI r4,0x100
MOVI r5,0x21
CALL @nfab_send
MOVI r5,0
MOVI r3,0x125
CALL @chk
LA r1,#N0
CALL @nfab_errno
MOVI r5,#NFAB_ECREDIT
MOVI r3,0x126
CALL @chk

; ---------------------------------------------------------------------------
; Send/recv with exact bytes, credits and ordering.
LA r1,#SRC
MOVI r2,0x100
MOVI r3,0x11
CALL @fill_bytes
LA r1,#N1
MOVI r2,1
LA r3,0x26100
MOVI r4,0x100
MOVI r5,0x11
CALL @nfab_recv_post
MOVI r5,0
MOVI r3,0x130
CALL @chk
LA r1,#N0
MOVI r2,1
CALL @nfab_credits
MOVI r5,1
MOVI r3,0x131
CALL @chk
LA r1,#N0
MOVI r2,1
LA r3,#SRC
MOVI r4,0x100
MOVI r5,0x21
CALL @nfab_send
MOVI r5,0
MOVI r3,0x132
CALL @chk
LA r1,#N0
MOVI r2,1
CALL @nfab_cq_count
MOVI r5,1
MOVI r3,0x12A
CALL @chk
LA r1,#N0
CALL @poll1
LD r1,r0,#TMP+0
MOVI r5,0
MOVI r3,0x133
CALL @chk
LD r1,r0,#TMP+1
MOVI r5,#NF_OP_SEND
MOVI r3,0x134
CALL @chk
LD r1,r0,#TMP+2
MOVI r5,0x100
MOVI r3,0x135
CALL @chk
LD r1,r0,#TMP+3
MOVI r5,0x21
MOVI r3,0x136
CALL @chk
LA r1,#N1
CALL @poll1
LD r1,r0,#TMP+0
MOVI r5,0
MOVI r3,0x137
CALL @chk
LD r1,r0,#TMP+1
MOVI r5,#NF_OP_RECV
MOVI r3,0x138
CALL @chk
LD r1,r0,#TMP+3
MOVI r5,0x11
MOVI r3,0x139
CALL @chk
LA r1,#N1WIN
ADDI r1,r1,0x100
LA r2,#SRC
MOVI r3,0x100
CALL @cmp_bytes

; credits are gone; a second send fails until a receive is posted
LA r1,#N0
MOVI r2,1
CALL @nfab_credits
MOVI r5,0
MOVI r3,0x13A
CALL @chk
LA r1,#N0
MOVI r2,1
LA r3,#SRC
MOVI r4,0x80
MOVI r5,0x22
CALL @nfab_send
MOVI r5,0
MOVI r3,0x13B
CALL @chk
LA r1,#N0
CALL @nfab_errno
MOVI r5,#NFAB_ECREDIT
MOVI r3,0x13C
CALL @chk

; two posted receives and two sends, FIFO completion order
LA r1,#N1
MOVI r2,1
LA r3,0x26180
MOVI r4,0x80
MOVI r5,0x12
CALL @nfab_recv_post
LA r1,#N1
MOVI r2,1
LA r3,0x261C0
MOVI r4,0x80
MOVI r5,0x13
CALL @nfab_recv_post
LA r1,#N0
MOVI r2,1
LA r3,#SRC
MOVI r4,0x80
MOVI r5,0x22
CALL @nfab_send
MOVI r5,0
MOVI r3,0x140
CALL @chk
LA r1,#N0
MOVI r2,1
LA r3,#SRC
ADDI r3,r3,0x40
MOVI r4,0x80
MOVI r5,0x23
CALL @nfab_send
MOVI r5,0
MOVI r3,0x141
CALL @chk

LA r1,#N0
CALL @poll1
LD r1,r0,#TMP+3
MOVI r5,0x22
MOVI r3,0x142
CALL @chk
LA r1,#N0
CALL @poll1
LD r1,r0,#TMP+3
MOVI r5,0x23
MOVI r3,0x143
CALL @chk
LA r1,#N1
CALL @poll1
LD r1,r0,#TMP+3
MOVI r5,0x12
MOVI r3,0x144
CALL @chk
LA r1,#N1
CALL @poll1
LD r1,r0,#TMP+3
MOVI r5,0x13
MOVI r3,0x145
CALL @chk

; reverse direction: node1 sends to node0
LA r1,#N1WIN
ADDI r1,r1,0x500
MOVI r2,0x80
MOVI r3,0x71
CALL @fill_bytes
LA r1,#N0
MOVI r2,1
LA r3,0x24100
MOVI r4,0x80
MOVI r5,0x31
CALL @nfab_recv_post
MOVI r5,0
MOVI r3,0x146
CALL @chk
LA r1,#N1
MOVI r2,1
LA r3,0x26500
MOVI r4,0x80
MOVI r5,0x32
CALL @nfab_send
MOVI r5,0
MOVI r3,0x147
CALL @chk
LA r1,#N1
CALL @poll1
LD r1,r0,#TMP+3
MOVI r5,0x32
MOVI r3,0x148
CALL @chk
LA r1,#N0
CALL @poll1
LD r1,r0,#TMP+3
MOVI r5,0x31
MOVI r3,0x149
CALL @chk
LA r1,#N0WIN
ADDI r1,r1,0x100
LA r2,#N1WIN
ADDI r2,r2,0x500
MOVI r3,0x80
CALL @cmp_bytes

; ---------------------------------------------------------------------------
; RDMA write/read, rights, bounds and rkey revoke.
LA r1,#SRC
MOVI r2,0x80
MOVI r3,0x91
CALL @fill_bytes
LA r1,#N0
MOVI r2,1
LA r3,#SRC
MOVI r4,0x80
MOVI r5,0x200
MOVI r6,0
LD r7,r0,#KEY1
MOVI r8,0x41
CALL @nfab_write
MOVI r5,0
MOVI r3,0x150
CALL @chk
LA r1,#N0
CALL @poll1
LD r1,r0,#TMP+1
MOVI r5,#NF_OP_WRITE
MOVI r3,0x151
CALL @chk
LA r1,#N1WIN
ADDI r1,r1,0x200
LA r2,#SRC
MOVI r3,0x80
CALL @cmp_bytes

LA r1,#N0
MOVI r2,1
LA r3,#DST
MOVI r4,0x80
MOVI r5,0x200
MOVI r6,0
LD r7,r0,#KEY1
MOVI r8,0x42
CALL @nfab_read
MOVI r5,0
MOVI r3,0x152
CALL @chk
LA r1,#N0
CALL @poll1
LD r1,r0,#TMP+1
MOVI r5,#NF_OP_READ
MOVI r3,0x153
CALL @chk
LA r1,#DST
LA r2,#SRC
MOVI r3,0x80
CALL @cmp_bytes

; bounds
LA r1,#N0
MOVI r2,1
LA r3,#SRC
LA r4,0x2000
MOVI r5,0x1000
MOVI r6,0
LD r7,r0,#KEY1
MOVI r8,0x43
CALL @nfab_write
MOVI r5,0
MOVI r3,0x154
CALL @chk
LA r1,#N0
CALL @nfab_errno
MOVI r5,#NFAB_EBOUNDS
MOVI r3,0x155
CALL @chk

; read-only MR rejects write but permits read
LA r1,#N0
MOVI r2,1
LA r3,#SRC
MOVI r4,0x40
MOVI r5,0
MOVI r6,0
LD r7,r0,#KEYRO
MOVI r8,0x44
CALL @nfab_write
MOVI r5,0
MOVI r3,0x156
CALL @chk
LA r1,#N0
CALL @nfab_errno
MOVI r5,#NFAB_ERIGHT
MOVI r3,0x157
CALL @chk

LA r1,#ROWIN
MOVI r2,0x40
MOVI r3,0x33
CALL @fill_bytes
LA r1,#N0
MOVI r2,1
LA r3,#DST
MOVI r4,0x40
MOVI r5,0
MOVI r6,0
LD r7,r0,#KEYRO
MOVI r8,0x44
CALL @nfab_read
MOVI r5,0
MOVI r3,0x158
CALL @chk
LA r1,#N0
CALL @poll1
LD r1,r0,#TMP+1
MOVI r5,#NF_OP_READ
MOVI r3,0x159
CALL @chk
LA r1,#DST
LA r2,#ROWIN
MOVI r3,0x40
CALL @cmp_bytes

; revoke: old key is stale, new key works
LA r1,#N1
MOVI r2,1
CALL @nfab_mr_revoke
ST r1,r0,#KEY1B
MOVI r5,0
MOVI r3,0x15A
CALL @chkne
LD r2,r0,#KEY1
CMP r1,r2
JMP[EQ] @bad_revoke

LA r1,#N0
MOVI r2,1
LA r3,#SRC
MOVI r4,0x80
MOVI r5,0x200
MOVI r6,0
LD r7,r0,#KEY1
MOVI r8,0x45
CALL @nfab_write
MOVI r5,0
MOVI r3,0x15B
CALL @chk
LA r1,#N0
CALL @nfab_errno
MOVI r5,#NFAB_ESTALE
MOVI r3,0x15C
CALL @chk
LA r1,#N0
MOVI r2,1
LA r3,#SRC
MOVI r4,0x80
MOVI r5,0x200
MOVI r6,0
LD r7,r0,#KEY1B
MOVI r8,0x46
CALL @nfab_write
MOVI r5,0
MOVI r3,0x15D
CALL @chk
LA r1,#N0
CALL @poll1
LD r1,r0,#TMP+3
MOVI r5,0x46
MOVI r3,0x15E
CALL @chk
LA r1,#N1WIN
ADDI r1,r1,0x200
LA r2,#SRC
MOVI r3,0x80
CALL @cmp_bytes

; node1 writes into node0's MR
LA r1,#N1WIN
ADDI r1,r1,0x600
MOVI r2,0x40
MOVI r3,0xB1
CALL @fill_bytes
LA r1,#N1
MOVI r2,1
LA r3,0x26600
MOVI r4,0x40
MOVI r5,0x200
MOVI r6,0
LD r7,r0,#KEY0
MOVI r8,0x47
CALL @nfab_write
MOVI r5,0
MOVI r3,0x15F
CALL @chk
LA r1,#N1
CALL @poll1
LD r1,r0,#TMP+3
MOVI r5,0x47
MOVI r3,0x160
CALL @chk
LA r1,#N0WIN
ADDI r1,r1,0x200
LA r2,#N1WIN
ADDI r2,r2,0x600
MOVI r3,0x40
CALL @cmp_bytes

; ---------------------------------------------------------------------------
; Remote KV over nkv slabs.
LA r1,#CFGKV
MOVI r2,1
ST r2,r1,0
MOVI r2,1
ST r2,r1,1
MOVI r2,0
ST r2,r1,2
MOVI r2,0
ST r2,r1,3
MOVI r2,1
ST r2,r1,4
MOVI r2,1
ST r2,r1,5
MOVI r2,8
ST r2,r1,6
MOVI r2,8
ST r2,r1,7
MOVI r2,0
ST r2,r1,8
MOVI r2,8
ST r2,r1,9
MOVI r2,8
ST r2,r1,10
MOVI r2,0
ST r2,r1,11
MOVI r2,1
ST r2,r1,12
MOVI r2,0
ST r2,r1,13
MOVI r2,0
ST r2,r1,14
LA r1,#CFGKV
LA r2,#HCTX
LA r3,#BT1
MOVI r4,1
CALL @nkv_slab_create
ST r1,r0,#CAP1
MOVI r5,0
MOVI r3,0x170
CALL @chkne
LA r1,#CAP1
LD r1,r1,0
MOVI r2,8
CALL @nkv_slab_append_n
MOVI r5,0
MOVI r3,0x171
CALL @chk

MOVI r1,2
ST r1,r0,#CFGKV+0
LA r1,#CFGKV
LA r2,#HCTX
LA r3,#BT2
MOVI r4,1
CALL @nkv_slab_create
ST r1,r0,#CAP2
MOVI r5,0
MOVI r3,0x172
CALL @chkne
LA r1,#CAP2
LD r1,r1,0
MOVI r2,8
CALL @nkv_slab_append_n
MOVI r5,0
MOVI r3,0x173
CALL @chk

; fill slab1 token t with byte pattern 0x40+t*8+i
MOVI r6,0
kfill:
LD r1,r0,#CAP1
ADD r2,r6,r0
MOVI r3,0x40
MOVI r4,8
MUL r3,r6,r4
ADD r3,r3,r2
; seed = 0x40 + t*8
MOVI r3,8
MUL r3,r6,r3
ADDI r3,r3,0x40
CALL @fill_tok
ADDI r6,r6,1
MOVI r2,8
CMP r6,r2
JMP[LT] @kfill

; put token 3 to node1 window offset 0x300
LA r1,#N0
MOVI r2,1
LD r3,r0,#CAP1
MOVI r4,3
MOVI r5,0x300
MOVI r6,0
LD r7,r0,#KEY1B
MOVI r8,1
CALL @nfab_kv_put
MOVI r5,0
MOVI r3,0x174
CALL @chk
LA r1,#N0
CALL @poll1
LD r1,r0,#TMP+1
MOVI r5,#NF_OP_WRITE
MOVI r3,0x175
CALL @chk
LA r1,#CAP1
LD r1,r1,0
MOVI r2,3
LA r3,#N1WIN
ADDI r3,r3,0x300
CALL @cmp_tok_to_buf

; get it into slab2 token 3
LA r1,#N0
MOVI r2,1
LD r3,r0,#CAP2
MOVI r4,3
MOVI r5,0x300
MOVI r6,0
LD r7,r0,#KEY1B
MOVI r8,1
CALL @nfab_kv_get
MOVI r5,0
MOVI r3,0x176
CALL @chk
LA r1,#N0
CALL @poll1
LD r1,r0,#TMP+1
MOVI r5,#NF_OP_READ
MOVI r3,0x177
CALL @chk
LD r1,r0,#CAP1
MOVI r2,3
LD r3,r0,#CAP2
MOVI r4,3
CALL @cmp_tok_tok

; stale local generation on put
LA r1,#CAP1
LD r1,r1,0
CALL @nkv_slab_regen
MOVI r5,2
MOVI r3,0x178
CALL @chk
LA r1,#N0
MOVI r2,1
LD r3,r0,#CAP1
MOVI r4,3
MOVI r5,0x300
MOVI r6,0
LD r7,r0,#KEY1B
MOVI r8,1
CALL @nfab_kv_put
MOVI r5,0
MOVI r3,0x179
CALL @chk
LA r1,#N0
CALL @nfab_errno
MOVI r5,#NFAB_ESTALE
MOVI r3,0x17A
CALL @chk
LA r1,#N0
MOVI r2,1
LD r3,r0,#CAP1
MOVI r4,3
MOVI r5,0x300
MOVI r6,0
LD r7,r0,#KEY1B
MOVI r8,2
CALL @nfab_kv_put
MOVI r5,0
MOVI r3,0x17B
CALL @chk
LA r1,#N0
CALL @poll1
LD r1,r0,#TMP+1
MOVI r5,#NF_OP_WRITE
MOVI r3,0x17C
CALL @chk

; stale local generation on get
LA r1,#CAP2
LD r1,r1,0
CALL @nkv_slab_regen
MOVI r5,2
MOVI r3,0x17D
CALL @chk
LA r1,#N0
MOVI r2,1
LD r3,r0,#CAP2
MOVI r4,3
MOVI r5,0x300
MOVI r6,0
LD r7,r0,#KEY1B
MOVI r8,1
CALL @nfab_kv_get
MOVI r5,0
MOVI r3,0x17E
CALL @chk
LA r1,#N0
CALL @nfab_errno
MOVI r5,#NFAB_ESTALE
MOVI r3,0x17F
CALL @chk
LA r1,#N0
MOVI r2,1
LD r3,r0,#CAP2
MOVI r4,3
MOVI r5,0x300
MOVI r6,0
LD r7,r0,#KEY1B
MOVI r8,2
CALL @nfab_kv_get
MOVI r5,0
MOVI r3,0x180
CALL @chk
LA r1,#N0
CALL @poll1
LD r1,r0,#TMP+1
MOVI r5,#NF_OP_READ
MOVI r3,0x181
CALL @chk
LD r1,r0,#CAP1
MOVI r2,3
LD r3,r0,#CAP2
MOVI r4,3
CALL @cmp_tok_tok

; ---------------------------------------------------------------------------
; nagent-style checkpoint blob.
LA r1,#BLOB
LA r2,#NFCK_MAGIC
ST r2,r1,0
MOVI r2,#NFCK_VERSION
ST r2,r1,1
MOVI r2,1
ST r2,r1,2
MOVI r2,5
ST r2,r1,3
MOVI r2,1
ST r2,r1,4
MOVI r2,0
ST r2,r1,5
ST r2,r1,6
MOVI r2,1
ST r2,r1,7
MOVI r2,1
ST r2,r1,8
MOVI r2,3
ST r2,r1,9
LA r2,0x1111
ST r2,r1,10
LA r2,0x2222
ST r2,r1,11
MOVI r2,4
ST r2,r1,12
LA r2,0x3333
ST r2,r1,13
MOVI r2,7
ST r2,r1,14
LA r2,1000
ST r2,r1,15
LA r2,2000
ST r2,r1,16
ST r0,r1,17
MOVI r2,1
ST r2,r1,18
MOVI r2,5
ST r2,r1,19
ST r0,r1,20
MOVI r2,24
ST r2,r1,21
MOVI r2,8
ST r2,r1,22
MOVI r2,56
ST r2,r1,23
; frame 24..47
MOVI r6,0
ckframe:
MOVI r2,24
ADD r2,r2,r6
LA r3,#BLOB
ADD r3,r3,r2
LA r2,0x90000000
ADD r2,r2,r6
ST r2,r3,0
ADDI r6,r6,1
MOVI r2,24
CMP r6,r2
JMP[LT] @ckframe
; one cap entry 48..55
MOVI r6,0
ckcap:
MOVI r2,48
ADD r2,r2,r6
LA r3,#BLOB
ADD r3,r3,r2
LA r2,0xA0000000
ADD r2,r2,r6
ST r2,r3,0
ADDI r6,r6,1
MOVI r2,8
CMP r6,r2
JMP[LT] @ckcap

LA r1,#BLOB
MOVI r2,56
CALL @nfab_ck_seal
ST r1,r0,#HASH
LA r2,#BLOB
ST r1,r2,20
LA r1,#BLOB
MOVI r2,56
CALL @nfab_ck_verify
MOVI r5,0
MOVI r3,0x190
CALL @chk

; push epoch 5 to node1's window
LA r1,#N0
MOVI r2,1
LA r3,#BLOB
MOVI r4,56
MOVI r5,0x400
MOVI r6,0
LD r7,r0,#KEY1B
MOVI r8,5
CALL @nfab_ck_send
MOVI r5,0
MOVI r3,0x191
CALL @chk
LA r1,#N0
CALL @poll1
LD r1,r0,#TMP+1
MOVI r5,#NF_OP_WRITE
MOVI r3,0x192
CALL @chk
LA r1,#N1WIN
ADDI r1,r1,0x400
LA r2,#BLOB
SHL r2,r2,2
MOVI r3,224
CALL @cmp_bytes

; pull epoch 5 from node0's MR into node1's local blob
LA r1,#BLOB
SHL r1,r1,2
LA r2,#N0WIN
ADDI r2,r2,0x400
MOVI r3,224
CALL @nf_copy
LA r1,#N1
MOVI r2,1
MOVI r3,0x400
MOVI r4,0
LA r5,#BLOB2
MOVI r6,56
LD r7,r0,#KEY0
MOVI r8,5
CALL @nfab_ck_recv
MOVI r5,0
MOVI r3,0x193
CALL @chk
LA r1,#N1
CALL @poll1
LD r1,r0,#TMP+1
MOVI r5,#NF_OP_READ
MOVI r3,0x194
CALL @chk
LA r1,#BLOB2
MOVI r2,56
CALL @nfab_ck_verify
MOVI r5,0
MOVI r3,0x195
CALL @chk
LA r1,#BLOB2
LA r2,#BLOB
MOVI r3,56
CALL @cmp_words

; stale epoch on send: copy, set epoch 4, reseal
LA r1,#BLOB
LA r2,#STALE
MOVI r3,56
CALL @copy_words
LA r1,#STALE
MOVI r2,4
ST r2,r1,19
LA r1,#STALE
MOVI r2,56
CALL @nfab_ck_seal
LA r2,#STALE
ST r1,r2,20
LA r1,#N0
MOVI r2,1
LA r3,#STALE
MOVI r4,56
MOVI r5,0x400
MOVI r6,0
LD r7,r0,#KEY1B
MOVI r8,4
CALL @nfab_ck_send
MOVI r5,0
MOVI r3,0x196
CALL @chk
LA r1,#N0
CALL @nfab_errno
MOVI r5,#NFAB_ESTALE
MOVI r3,0x197
CALL @chk

; stale epoch on pull: put the epoch-4 blob in node0's MR and receive it
LA r1,#STALE
SHL r1,r1,2
LA r2,#N0WIN
ADDI r2,r2,0x400
MOVI r3,224
CALL @nf_copy
LA r1,#N1
MOVI r2,1
MOVI r3,0x400
MOVI r4,0
LA r5,#BLOB2
MOVI r6,56
LD r7,r0,#KEY0
MOVI r8,4
CALL @nfab_ck_recv
MOVI r5,0
MOVI r3,0x198
CALL @chk
LA r1,#N1
CALL @nfab_errno
MOVI r5,#NFAB_ESTALE
MOVI r3,0x199
CALL @chk
LA r1,#N1
CALL @poll1
LD r1,r0,#TMP+1
MOVI r5,#NF_OP_READ
MOVI r3,0x19A
CALL @chk

; corrupted seal is rejected
LA r1,#BLOB2
LD r2,r1,20
ADDI r2,r2,1
ST r2,r1,20
LA r1,#BLOB2
MOVI r2,56
CALL @nfab_ck_verify
MOVI r5,#NFAB_ECK
MOVI r3,0x19B
CALL @chk

; epoch 6 advances both sides and is accepted
LA r1,#BLOB
MOVI r2,6
ST r2,r1,19
LA r1,#BLOB
MOVI r2,56
CALL @nfab_ck_seal
LA r2,#BLOB
ST r1,r2,20
LA r1,#N0
MOVI r2,1
LA r3,#BLOB
MOVI r4,56
MOVI r5,0x400
MOVI r6,0
LD r7,r0,#KEY1B
MOVI r8,6
CALL @nfab_ck_send
MOVI r5,0
MOVI r3,0x19C
CALL @chk
LA r1,#N0
CALL @poll1
LD r1,r0,#TMP+1
MOVI r5,#NF_OP_WRITE
MOVI r3,0x19D
CALL @chk
LA r1,#BLOB
SHL r1,r1,2
LA r2,#N0WIN
ADDI r2,r2,0x400
MOVI r3,224
CALL @nf_copy
LA r1,#N1
MOVI r2,1
MOVI r3,0x400
MOVI r4,0
LA r5,#BLOB2
MOVI r6,56
LD r7,r0,#KEY0
MOVI r8,6
CALL @nfab_ck_recv
MOVI r5,0
MOVI r3,0x19E
CALL @chk
LA r1,#N1
CALL @poll1
LD r1,r0,#TMP+1
MOVI r5,#NF_OP_READ
MOVI r3,0x19F
CALL @chk
LA r1,#BLOB2
MOVI r2,56
CALL @nfab_ck_verify
MOVI r5,0
MOVI r3,0x1A0
CALL @chk
LA r1,#BLOB2
LA r2,#BLOB
MOVI r3,56
CALL @cmp_words

; ---------------------------------------------------------------------------
MOVI r1,79
PUTC r1
HALT

; ---------------------------------------------------------------------------
; poll1 r1=node -> r1=status r2=op r3=bytes r4=wr_id.  Fails on empty.
poll1:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#TMP+16
MOVI r2,1
LA r3,#TMP+24
CALL @nfab_poll
MOVI r5,1
CMP r1,r5
JMP[NE] @poll_fail
LD r1,r0,#TMP+24
LD r2,r0,#TMP+25
LD r3,r0,#TMP+27
LD r4,r0,#TMP+29
ST r1,r0,#TMP+0
ST r2,r0,#TMP+1
ST r3,r0,#TMP+2
ST r4,r0,#TMP+3
JMP @poll_out
poll_fail:
MOVI r1,0xFFFF
MOVI r2,0
MOVI r3,0
MOVI r4,0
poll_out:
SUB r14,r14,r13
LD r15,r14,0
RET

; fill_bytes r1=addr r2=count r3=seed.  Leaf.
fill_bytes:
CMP r2,r0
JMP[EQ] @fb_out
fb_l:
STB r3,r1,0
ADDI r3,r3,7
ADDI r1,r1,1
ADDI r2,r2,-1
CMP r2,r0
JMP[NE] @fb_l
fb_out:
RET

; cmp_bytes r1=a r2=b r3=count.  Mismatch -> bad_mem.
cmp_bytes:
CMP r3,r0
JMP[EQ] @cb_out
cb_l:
LDB r4,r1,0
LDB r5,r2,0
CMP r4,r5
JMP[NE] @bad_mem
ADDI r1,r1,1
ADDI r2,r2,1
ADDI r3,r3,-1
CMP r3,r0
JMP[NE] @cb_l
cb_out:
MOVI r1,0
RET

; cmp_words r1=a r2=b r3=count.  Mismatch -> bad_mem.
cmp_words:
CMP r3,r0
JMP[EQ] @cw_out
cw_l:
LD r4,r1,0
LD r5,r2,0
CMP r4,r5
JMP[NE] @bad_mem
ADDI r1,r1,1
ADDI r2,r2,1
ADDI r3,r3,-1
CMP r3,r0
JMP[NE] @cw_l
cw_out:
MOVI r1,0
RET

; copy_words r1=src r2=dst r3=count.  Leaf.
copy_words:
CMP r3,r0
JMP[EQ] @cwd_out
cwd_l:
LD r4,r1,0
ST r4,r2,0
ADDI r1,r1,1
ADDI r2,r2,1
ADDI r3,r3,-1
CMP r3,r0
JMP[NE] @cwd_l
cwd_out:
RET

; fill_tok r1=slab r2=token r3=seed.  Fill 8 token bytes.
fill_tok:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#TMP+4
ST r2,r0,#TMP+5
ST r3,r0,#TMP+6
LD r1,r0,#TMP+4
LD r2,r0,#TMP+5
CALL @nkv_slab_token_addr
CMP r5,r0
JMP[NE] @bad_tok
CMP r2,r0
JMP[NE] @bad_tok
MOVI r4,8
CMP r3,r4
JMP[NE] @bad_tok
ST r1,r0,#TMP+7
MOVI r5,0
ft_l:
LD r1,r0,#TMP+7
ADD r1,r1,r5
LD r3,r0,#TMP+6
ADD r3,r3,r5
STB r3,r1,0
ADDI r5,r5,1
MOVI r6,8
CMP r5,r6
JMP[LT] @ft_l
MOVI r1,0
JMP @ft_out
bad_tok:
MOVI r1,0x1B0
JMP @failcode
ft_out:
SUB r14,r14,r13
LD r15,r14,0
RET

; cmp_tok_to_buf r1=slab r2=token r3=buf.
cmp_tok_to_buf:
ST r15,r14,0
ADD r14,r14,r13
ST r3,r0,#TMP+8
CALL @nkv_slab_token_addr
CMP r5,r0
JMP[NE] @bad_tok
ST r1,r0,#TMP+9
MOVI r5,0
ctb_l:
LD r1,r0,#TMP+9
ADD r1,r1,r5
LD r2,r0,#TMP+8
ADD r2,r2,r5
LDB r3,r1,0
LDB r4,r2,0
CMP r3,r4
JMP[NE] @bad_tok
ADDI r5,r5,1
MOVI r6,8
CMP r5,r6
JMP[LT] @ctb_l
MOVI r1,0
JMP @ctb_out
ctb_out:
SUB r14,r14,r13
LD r15,r14,0
RET

; cmp_tok_tok r1=slabA r2=tokenA r3=slabB r4=tokenB.
cmp_tok_tok:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#TMP+4
ST r2,r0,#TMP+5
ST r3,r0,#TMP+6
ST r4,r0,#TMP+7
LD r1,r0,#TMP+4
LD r2,r0,#TMP+5
CALL @nkv_slab_token_addr
CMP r5,r0
JMP[NE] @bad_tok
ST r1,r0,#TMP+8
LD r1,r0,#TMP+6
LD r2,r0,#TMP+7
CALL @nkv_slab_token_addr
CMP r5,r0
JMP[NE] @bad_tok
ST r1,r0,#TMP+9
MOVI r5,0
ctt_l:
LD r1,r0,#TMP+8
ADD r1,r1,r5
LD r2,r0,#TMP+9
ADD r2,r2,r5
LDB r3,r1,0
LDB r4,r2,0
CMP r3,r4
JMP[NE] @bad_tok
ADDI r5,r5,1
MOVI r6,8
CMP r5,r6
JMP[LT] @ctt_l
MOVI r1,0
JMP @ctt_out
ctt_out:
SUB r14,r14,r13
LD r15,r14,0
RET

; chk r1 actual r5 expected r3 diagnostic.
chk:
CMP r1,r5
JMP[EQ] @chk_ok
ADD r1,r3,r0
JMP @failcode
chk_ok:
MOVI r1,0
RET

; chkne r1 actual r5 forbidden r3 diagnostic.
chkne:
CMP r1,r5
JMP[NE] @chkne_ok
ADD r1,r3,r0
JMP @failcode
chkne_ok:
MOVI r1,0
RET

bad_mem:
MOVI r1,0x1A1
JMP @failcode
bad_revoke:
MOVI r1,0x1A2
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
MOVI r2,10
CMP r1,r2
JMP[LT] @t_pn_l
ADDI r1,r1,55
JMP @t_pn_o
t_pn_l:
ADDI r1,r1,48
t_pn_o:
PUTC r1
RET
