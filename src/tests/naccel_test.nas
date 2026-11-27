; naccel_test.nas - F10 accelerator boundary proof (pure NaN, nan_cli).
;
; Proves, in one deterministic image:
;   * a per-device IOMMU domain with 64-bit IOVAs (>4 GiB), R/W/X rights,
;     map/unmap/rebind, a monotonic invalidation epoch and fault records;
;   * wrap, overlap, alignment, W|X and duplicate-device rejection;
;   * a caller-supplied DMA ring: submit, cancel, complete, exact status,
;     strict fence ordering (complete stops after a FENCE descriptor);
;   * a software device copy and GEMV placeholder through mapped IOVAs, with
;     exact source/destination bytes;
;   * invalid IOVA, permission and revoked-generation DMA faults;
;   * a 64-bit VRAM/BAR model with a bitmap allocator, weight and KV
;     placement, >4 GiB offsets, exhaustion and unmapped-BAR fallback with
;     exact placement/fallback accounting;
;   * unmap/rebind/revoke: old mappings fail, new mappings work.
;
; Success prints exactly O.  A failed check prints F <hex id> and HALT.
;
; Guest map (word addresses):
;   0x0000          boot JMP
;   0x0400..        niommu/naccel libraries and this test
;   0x360000        niommu domain table (512 words)
;   0x361000        niommu shadow map (3072 words)
;   0x4000..0x5800  byte-addressed DMA buffers (physical 0x10000..0x16000)
;   0x6000..0x6700  ring/VRAM contexts, descriptors, bitmaps, results
;   0x6E00          niommu last-error word
;   0x8F00..        test stack
;
; IOVAs intentionally live above 4 GiB.  Physical byte addresses are low
; guest bytes because this is an emulated boundary, not a real BAR.

.equ STK        0x8F00

; Byte-addressed guest buffers (word address = byte / 4).
.equ SRC_B      0x10000
.equ DST_B      0x11000
.equ DST2_B     0x12000
.equ DST3_B     0x13000
.equ GS_B       0x14000
.equ GD_B       0x15000
.equ WO_B       0x16000

.equ SRC_W      0x4000
.equ DST_W      0x4400
.equ DST2_W     0x4800
.equ DST3_W     0x4C00
.equ GS_W       0x5000
.equ GD_W       0x5400
.equ WO_W       0x5800

; Low data words.
.equ DOMV       0x6000
.equ DOM2V      0x6001
.equ DOM3V      0x6002
.equ MAP_SRC    0x6003
.equ MAP_DST    0x6004
.equ MAP_D2     0x6005
.equ MAP_D3     0x6006
.equ MAP_GS     0x6007
.equ MAP_GD     0x6008
.equ MAP_WO     0x6009
.equ MAP_BAR    0x600A
.equ MAP_BAR2   0x600B
.equ MAP_A      0x600C
.equ SEQ1       0x600D
.equ SEQ2       0x600E
.equ SEQ3       0x600F
.equ EPOCH1     0x6010
.equ GEN1       0x6011

.equ RING       0x6040
.equ DESC       0x6080

.equ TINYCTX    0x6120
.equ TINYBM     0x6140
.equ BIGCTX     0x6180
.equ BIGBM      0x6200

.equ OUT0       0x6600
.equ OUT1       0x6620
.equ STATS      0x6660
.equ RES        0x6680
.equ CNT        0x6690
.equ TMP2       0x66C0
.equ TBUF       0x66D0

.org 0
JMP @main
.org 0x400
.include "../lib/naccel.nas"

main:
MOVI r0,0
MOVI r13,1
LA r14,#STK
CALL @niom_init
MOVI r5,0
MOVI r3,0x101
CALL @chk

; ---------------------------------------------------------------------------
; Domains: one DMA device, one negative/BAR device, one VRAM BAR device.
MOVI r1,0x1234
CALL @niom_domain_create
ST r1,r0,#DOMV
MOVI r5,1
MOVI r3,0x102
CALL @chk
; duplicate live device is rejected
MOVI r1,0x1234
CALL @niom_domain_create
MOVI r5,0
MOVI r3,0x103
CALL @chk
MOVI r1,0x5678
CALL @niom_domain_create
ST r1,r0,#DOM2V
MOVI r5,2
MOVI r3,0x104
CALL @chk
MOVI r1,0x9ABC
CALL @niom_domain_create
ST r1,r0,#DOM3V
MOVI r5,3
MOVI r3,0x105
CALL @chk

; ---------------------------------------------------------------------------
; DMA domain maps.  IOVA 4 GiB / 8 GiB / 12 GiB + offsets.
LD r1,r0,#DOMV
MOVI r2,0
MOVI r3,1
MOVI r4,0x1000
MOVI r5,0
LA r6,#SRC_B
MOVI r7,0
MOVI r8,#NIOM_R_READ
CALL @niom_map
ST r1,r0,#MAP_SRC
MOVI r5,1
MOVI r3,0x110
CALL @chk

LD r1,r0,#DOMV
MOVI r2,0
MOVI r3,2
MOVI r4,0x1000
MOVI r5,0
LA r6,#DST_B
MOVI r7,0
MOVI r8,3
CALL @niom_map
ST r1,r0,#MAP_DST
MOVI r5,2
MOVI r3,0x111
CALL @chk

LD r1,r0,#DOMV
MOVI r2,0x1000
MOVI r3,2
MOVI r4,0x1000
MOVI r5,0
LA r6,#DST2_B
MOVI r7,0
MOVI r8,3
CALL @niom_map
ST r1,r0,#MAP_D2
MOVI r5,3
MOVI r3,0x112
CALL @chk

LD r1,r0,#DOMV
MOVI r2,0x2000
MOVI r3,2
MOVI r4,0x1000
MOVI r5,0
LA r6,#DST3_B
MOVI r7,0
MOVI r8,#NIOM_R_WRITE
CALL @niom_map
ST r1,r0,#MAP_D3
MOVI r5,4
MOVI r3,0x113
CALL @chk

LD r1,r0,#DOMV
MOVI r2,0
MOVI r3,3
MOVI r4,0x1000
MOVI r5,0
LA r6,#GS_B
MOVI r7,0
MOVI r8,#NIOM_R_READ
CALL @niom_map
ST r1,r0,#MAP_GS
MOVI r5,5
MOVI r3,0x114
CALL @chk

LD r1,r0,#DOMV
MOVI r2,0x1000
MOVI r3,3
MOVI r4,0x1000
MOVI r5,0
LA r6,#GD_B
MOVI r7,0
MOVI r8,#NIOM_R_WRITE
CALL @niom_map
ST r1,r0,#MAP_GD
MOVI r5,6
MOVI r3,0x115
CALL @chk

; write-only source for the permission fault
LD r1,r0,#DOMV
MOVI r2,0x2000
MOVI r3,3
MOVI r4,0x1000
MOVI r5,0
LA r6,#WO_B
MOVI r7,0
MOVI r8,#NIOM_R_WRITE
CALL @niom_map
ST r1,r0,#MAP_WO
MOVI r5,7
MOVI r3,0x116
CALL @chk

; epoch after seven maps = 1 + 7
LD r1,r0,#DOMV
CALL @niom_epoch
ST r1,r0,#EPOCH1
MOVI r5,8
MOVI r3,0x117
CALL @chk

; ---------------------------------------------------------------------------
; Negative map cases on a second domain.
LD r1,r0,#DOM2V
MOVI r2,0
MOVI r3,9
MOVI r4,0x1000
MOVI r5,0
LA r6,0x20000
MOVI r7,0
MOVI r8,#NIOM_R_READ
CALL @niom_map
ST r1,r0,#MAP_A
MOVI r5,1
MOVI r3,0x120
CALL @chk

; overlap
LD r1,r0,#DOM2V
MOVI r2,0
MOVI r3,9
MOVI r4,0x1000
MOVI r5,0
LA r6,0x20000
MOVI r7,0
MOVI r8,#NIOM_R_READ
CALL @niom_map
MOVI r5,#NIOM_ESPACE
MOVI r3,0x121
CALL @chkmap
LD r1,r0,#DOM2V
CALL @niom_errno
MOVI r5,#NIOM_ESPACE
MOVI r3,0x122
CALL @chk

; adjacent is legal
LD r1,r0,#DOM2V
MOVI r2,0x1000
MOVI r3,9
MOVI r4,0x1000
MOVI r5,0
LA r6,0x21000
MOVI r7,0
MOVI r8,#NIOM_R_READ
CALL @niom_map
MOVI r5,2
MOVI r3,0x123
CALL @chk

; unaligned
LD r1,r0,#DOM2V
MOVI r2,0x800
MOVI r3,9
MOVI r4,0x1000
MOVI r5,0
LA r6,0x22000
MOVI r7,0
MOVI r8,#NIOM_R_READ
CALL @niom_map
MOVI r5,#NIOM_EALIGN
MOVI r3,0x124
CALL @chkmap

; wrap at the top of the 64-bit IOVA space
LD r1,r0,#DOM2V
LA r2,0xFFFFF000
LA r3,0xFFFFFFFF
MOVI r4,0x2000
MOVI r5,0
LA r6,0x23000
MOVI r7,0
MOVI r8,#NIOM_R_READ
CALL @niom_map
MOVI r5,#NIOM_EOVER
MOVI r3,0x125
CALL @chkmap

; W|X is rejected
LD r1,r0,#DOM2V
MOVI r2,0x2000
MOVI r3,9
MOVI r4,0x1000
MOVI r5,0
LA r6,0x24000
MOVI r7,0
MOVI r8,6
CALL @niom_map
MOVI r5,#NIOM_ERIGHT
MOVI r3,0x126
CALL @chkmap

; zero size is rejected
LD r1,r0,#DOM2V
MOVI r2,0x3000
MOVI r3,9
MOVI r4,0
MOVI r5,0
LA r6,0x25000
MOVI r7,0
MOVI r8,#NIOM_R_READ
CALL @niom_map
MOVI r5,#NIOM_EBAD
MOVI r3,0x127
CALL @chkmap

; ---------------------------------------------------------------------------
; VRAM BAR mappings.  Domain 3 owns only BARs; domain 2 owns the small BAR
; plus the negative-test ranges.
LD r1,r0,#DOM3V
MOVI r2,0
MOVI r3,4
MOVI r4,0
MOVI r5,512
MOVI r6,0
MOVI r7,1
MOVI r8,3
CALL @niom_map
ST r1,r0,#MAP_BAR
MOVI r5,1
MOVI r3,0x130
CALL @chk

LD r1,r0,#DOM3V
MOVI r2,0
LA r3,0x400
LA r4,0x10000000
MOVI r5,0
MOVI r6,0
MOVI r7,2
MOVI r8,3
CALL @niom_map
ST r1,r0,#MAP_BAR2
MOVI r5,2
MOVI r3,0x131
CALL @chk

; small BAR lives in domain 2 at 32 GiB, 256 MiB
LD r1,r0,#DOM2V
MOVI r2,0
MOVI r3,8
LA r4,0x10000000
MOVI r5,0
MOVI r6,0
MOVI r7,2
MOVI r8,3
CALL @niom_map
MOVI r5,3
MOVI r3,0x132
CALL @chk

; ---------------------------------------------------------------------------
; Fill byte buffers.
MOVI r6,0
fill_src:
MOVI r2,7
MUL r3,r6,r2
ADDI r3,r3,3
MOVI r4,0xFF
BOOL.8 r3,r3,r4
LA r4,#SRC_B
ADD r4,r4,r6
STB r3,r4,0
ADDI r6,r6,1
MOVI r2,64
CMP r6,r2
JMP[LT] @fill_src

LA r1,#DST_W
LA r2,0xAAAAAAAA
MOVI r3,16
BFILL r1,r2,r3
LA r1,#DST2_W
LA r2,0x55555555
MOVI r3,16
BFILL r1,r2,r3
LA r1,#DST3_W
LA r2,0x77777777
MOVI r3,16
BFILL r1,r2,r3
LA r1,#GD_W
LA r2,0xAAAAAAAA
MOVI r3,16
BFILL r1,r2,r3
LA r1,#WO_W
LA r2,0x11111111
MOVI r3,16
BFILL r1,r2,r3
LA r1,0x04030201
LA r2,#GS_W
ST r1,r2,0

; ---------------------------------------------------------------------------
; DMA ring: init, submit three copies, fence after the second.
LD r1,r0,#DOMV
MOVI r4,1
LA r1,#RING
LA r2,#DESC
MOVI r3,8
LD r4,r0,#DOMV
CALL @nacc_ring_init
MOVI r5,0
MOVI r3,0x140
CALL @chk

; copy src -> dst, 64 bytes, no fence
LA r1,#RING
MOVI r2,0
MOVI r3,1
MOVI r4,0
MOVI r5,2
MOVI r6,64
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
ST r1,r0,#SEQ1
MOVI r5,1
MOVI r3,0x141
CALL @chk

; copy dst -> dst2, fence
LA r1,#RING
MOVI r2,0
MOVI r3,2
MOVI r4,0x1000
MOVI r5,2
MOVI r6,64
MOVI r7,0
MOVI r8,#NACC_F_FENCE
CALL @nacc_submit
ST r1,r0,#SEQ2
MOVI r5,2
MOVI r3,0x142
CALL @chk

; copy dst2 -> dst3, no fence; must not pass the earlier fence
LA r1,#RING
MOVI r2,0x1000
MOVI r3,2
MOVI r4,0x2000
MOVI r5,2
MOVI r6,64
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
ST r1,r0,#SEQ3
MOVI r5,3
MOVI r3,0x143
CALL @chk

; the issued fence is not satisfied before it is reaped
LA r1,#RING
CALL @nacc_fence
MOVI r5,#NACC_EBUSY
MOVI r3,0x14B
CALL @chk

LA r1,#RING
CALL @nacc_complete
MOVI r5,2
MOVI r3,0x144
CALL @chk

; dst and dst2 contain the exact pattern; dst3 is still untouched
MOVI r6,0
chk_pat1:
MOVI r2,7
MUL r3,r6,r2
ADDI r3,r3,3
MOVI r4,0xFF
BOOL.8 r3,r3,r4
LA r4,#DST_B
ADD r4,r4,r6
LDB r1,r4,0
CMP r1,r3
JMP[NE] @bad_pattern1
MOVI r5,0x77
LA r4,#DST3_B
ADD r4,r4,r6
LDB r1,r4,0
CMP r1,r5
JMP[NE] @bad_dst3
ADDI r6,r6,1
MOVI r2,64
CMP r6,r2
JMP[LT] @chk_pat1

MOVI r6,0
chk_pat2:
MOVI r2,7
MUL r3,r6,r2
ADDI r3,r3,3
MOVI r4,0xFF
BOOL.8 r3,r3,r4
LA r4,#DST2_B
ADD r4,r4,r6
LDB r1,r4,0
CMP r1,r3
JMP[NE] @bad_pattern2
ADDI r6,r6,1
MOVI r2,64
CMP r6,r2
JMP[LT] @chk_pat2

; fence is satisfied and counters are exact
LA r1,#RING
CALL @nacc_fence
MOVI r5,0
MOVI r3,0x145
CALL @chk
LA r1,#RING
LA r2,#CNT
CALL @nacc_counters
LD r1,r0,#CNT+0
MOVI r5,3
MOVI r3,0x146
CALL @chk
LD r1,r0,#CNT+1
MOVI r5,2
MOVI r3,0x147
CALL @chk
LD r1,r0,#CNT+4
MOVI r5,1
MOVI r3,0x148
CALL @chk
LD r1,r0,#CNT+3
MOVI r5,2
MOVI r3,0x149
CALL @chk

; second completion reaps the post-fence descriptor
LA r1,#RING
CALL @nacc_complete
MOVI r5,1
MOVI r3,0x14A
CALL @chk
MOVI r6,0
chk_pat3:
MOVI r2,7
MUL r3,r6,r2
ADDI r3,r3,3
MOVI r4,0xFF
BOOL.8 r3,r3,r4
LA r4,#DST3_B
ADD r4,r4,r6
LDB r1,r4,0
CMP r1,r3
JMP[NE] @bad_pattern3
ADDI r6,r6,1
MOVI r2,64
CMP r6,r2
JMP[LT] @chk_pat3

; ---------------------------------------------------------------------------
; Cancel: queued work is reaped as cancelled and does not touch the buffer.
LA r1,#RING
MOVI r2,0
MOVI r3,1
MOVI r4,0x2000
MOVI r5,2
MOVI r6,8
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
ST r1,r0,#SEQ1
MOVI r5,4
MOVI r3,0x150
CALL @chk
LA r1,#RING
LD r2,r0,#SEQ1
CALL @nacc_cancel
MOVI r5,0
MOVI r3,0x151
CALL @chk
LA r1,#RING
LD r2,r0,#SEQ1
LA r3,#RES
CALL @nacc_result
MOVI r5,0
MOVI r3,0x152
CALL @chk
LD r1,r0,#RES+0
MOVI r5,#NACC_CANCELLED
MOVI r3,0x153
CALL @chk
LD r1,r0,#RES+1
MOVI r5,#NACC_ECANCEL
MOVI r3,0x154
CALL @chk
LA r1,#RING
CALL @nacc_complete
MOVI r5,1
MOVI r3,0x155
CALL @chk
; destination first byte is still the previous copy's pattern byte 3
LA r1,#DST3_B
LDB r1,r1,0
MOVI r5,3
MOVI r3,0x156
CALL @chk

; a following valid copy still completes
LA r1,#RING
MOVI r2,0
MOVI r3,1
MOVI r4,0x2000
MOVI r5,2
MOVI r6,8
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
ST r1,r0,#SEQ1
LA r1,#RING
CALL @nacc_complete
MOVI r5,1
MOVI r3,0x157
CALL @chk
MOVI r6,0
chk_post_cancel:
MOVI r2,7
MUL r3,r6,r2
ADDI r3,r3,3
MOVI r4,0xFF
BOOL.8 r3,r3,r4
LA r4,#DST3_B
ADD r4,r4,r6
LDB r1,r4,0
CMP r1,r3
JMP[NE] @bad_post_cancel
ADDI r6,r6,1
MOVI r2,8
CMP r6,r2
JMP[LT] @chk_post_cancel

; ---------------------------------------------------------------------------
; Invalid IOVA: completion error ENOENT, ring continues.
LA r1,#RING
MOVI r2,0
MOVI r3,9
MOVI r4,0x2000
MOVI r5,2
MOVI r6,8
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
ST r1,r0,#SEQ1
LA r1,#RING
CALL @nacc_complete
MOVI r5,1
MOVI r3,0x160
CALL @chk
LA r1,#RING
LD r2,r0,#SEQ1
LA r3,#RES
CALL @nacc_result
LD r1,r0,#RES+0
MOVI r5,#NACC_ERROR
MOVI r3,0x161
CALL @chk
LD r1,r0,#RES+1
MOVI r5,#NIOM_ENOENT
MOVI r3,0x162
CALL @chk

; Permission: source mapping is write-only, so the read fails ERIGHT.
LA r1,#RING
MOVI r2,0x2000
MOVI r3,3
MOVI r4,0x2000
MOVI r5,2
MOVI r6,8
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
ST r1,r0,#SEQ1
LA r1,#RING
CALL @nacc_complete
MOVI r5,1
MOVI r3,0x163
CALL @chk
LA r1,#RING
LD r2,r0,#SEQ1
LA r3,#RES
CALL @nacc_result
LD r1,r0,#RES+1
MOVI r5,#NIOM_ERIGHT
MOVI r3,0x164
CALL @chk

; ---------------------------------------------------------------------------
; GEMV placeholder: four bytes 1,2,3,4 -> 3*(1+2+3+4)+4 = 34.
LA r1,#RING
MOVI r2,0
MOVI r3,3
MOVI r4,0x1000
MOVI r5,3
MOVI r6,4
MOVI r7,0
MOVI r8,#NACC_F_GEMV
CALL @nacc_submit
ST r1,r0,#SEQ1
LA r1,#RING
CALL @nacc_complete
MOVI r5,1
MOVI r3,0x165
CALL @chk
LD r1,r0,#GD_W+0
MOVI r5,34
MOVI r3,0x166
CALL @chk
LD r1,r0,#GD_W+1
MOVI r5,0
MOVI r3,0x167
CALL @chk

; ---------------------------------------------------------------------------
; Direct translation above 4 GiB: 4 GiB IOVA -> 0x10000, then unmap.
LD r1,r0,#DOMV
MOVI r2,1
MOVI r3,0
MOVI r4,1
MOVI r5,0x40
MOVI r6,0
MOVI r7,#NIOM_R_READ
LA r8,#TMP2
CALL @niom_translate
MOVI r5,0
MOVI r3,0x170
CALL @chk
LD r1,r0,#TMP2+0
LA r5,#SRC_B
MOVI r3,0x171
CALL @chk
LD r1,r0,#TMP2+1
MOVI r5,0
MOVI r3,0x172
CALL @chk

LD r1,r0,#DOMV
LD r2,r0,#MAP_SRC
CALL @niom_unmap
MOVI r5,0
MOVI r3,0x173
CALL @chk

; old IOVA fails, and a DMA submitted against it fails ENOENT
LD r1,r0,#DOMV
MOVI r2,1
MOVI r3,0
MOVI r4,1
MOVI r5,0x40
MOVI r6,0
MOVI r7,#NIOM_R_READ
LA r8,#TMP2
CALL @niom_translate
MOVI r5,#NIOM_ENOENT
MOVI r3,0x174
CALL @chk

LA r1,#RING
MOVI r2,0
MOVI r3,1
MOVI r4,0x2000
MOVI r5,2
MOVI r6,8
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
ST r1,r0,#SEQ1
LA r1,#RING
CALL @nacc_complete
MOVI r5,1
MOVI r3,0x175
CALL @chk
LA r1,#RING
LD r2,r0,#SEQ1
LA r3,#RES
CALL @nacc_result
LD r1,r0,#RES+1
MOVI r5,#NIOM_ENOENT
MOVI r3,0x176
CALL @chk

; remap the same IOVA, then rebind the entry to 28 GiB
LD r1,r0,#DOMV
MOVI r2,0
MOVI r3,1
MOVI r4,0x1000
MOVI r5,0
LA r6,#SRC_B
MOVI r7,0
MOVI r8,#NIOM_R_READ
CALL @niom_map
ST r1,r0,#MAP_SRC
MOVI r5,1
MOVI r3,0x177
CALL @chk

LD r1,r0,#DOMV
LD r2,r0,#MAP_SRC
MOVI r3,0
MOVI r4,7
MOVI r5,0x1000
MOVI r6,0
LA r7,#SRC_B
MOVI r8,0
MOVI r9,#NIOM_R_READ
CALL @niom_rebind
MOVI r5,0
MOVI r3,0x178
CALL @chk

; old IOVA 4 GiB now fails; new IOVA 28 GiB works
LD r1,r0,#DOMV
MOVI r2,1
MOVI r3,0
MOVI r4,1
MOVI r5,0x40
MOVI r6,0
MOVI r7,#NIOM_R_READ
LA r8,#TMP2
CALL @niom_translate
MOVI r5,#NIOM_ENOENT
MOVI r3,0x179
CALL @chk
LD r1,r0,#DOMV
MOVI r2,1
MOVI r3,0
MOVI r4,7
MOVI r5,0x40
MOVI r6,0
MOVI r7,#NIOM_R_READ
LA r8,#TMP2
CALL @niom_translate
MOVI r5,0
MOVI r3,0x17A
CALL @chk
LD r1,r0,#TMP2+0
LA r5,#SRC_B
MOVI r3,0x17B
CALL @chk

; epoch advanced by unmap + remap + rebind
LD r1,r0,#DOMV
CALL @niom_epoch
LD r2,r0,#EPOCH1
CMP r1,r2
JMP[LE] @bad_epoch
MOVI r5,11
MOVI r3,0x17C
CALL @chk

; a DMA from the rebound mapping still works
LA r1,#RING
MOVI r2,0
MOVI r3,7
MOVI r4,0x2000
MOVI r5,2
MOVI r6,8
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
ST r1,r0,#SEQ1
LA r1,#RING
CALL @nacc_complete
MOVI r5,1
MOVI r3,0x17D
CALL @chk

; ---------------------------------------------------------------------------
; Revoke: old generation is stale, maps are gone, queued work fails ESTALE.
LD r1,r0,#DOMV
CALL @niom_generation
ST r1,r0,#GEN1
; queue a descriptor under the live generation
LA r1,#RING
MOVI r2,0
MOVI r3,7
MOVI r4,0x2000
MOVI r5,2
MOVI r6,8
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
ST r1,r0,#SEQ1
MOVI r5,11
MOVI r3,0x180
CALL @chk

LD r1,r0,#DOMV
CALL @niom_revoke
MOVI r5,0
MOVI r3,0x181
CALL @chk
LD r1,r0,#DOMV
CALL @niom_generation
LD r2,r0,#GEN1
ADDI r2,r2,1
MOVI r5,0
CMP r1,r2
JMP[NE] @bad_gen
LD r1,r0,#DOMV
MOVI r2,1
MOVI r3,0
MOVI r4,1
MOVI r5,64
MOVI r6,0
MOVI r7,#NIOM_R_READ
LA r8,#TMP2
CALL @niom_translate
MOVI r5,#NIOM_ESTALE
MOVI r3,0x182
CALL @chk
LD r1,r0,#DOMV
LD r2,r0,#GEN1
ADDI r2,r2,1
MOVI r3,0
MOVI r4,7
MOVI r5,64
MOVI r6,0
MOVI r7,#NIOM_R_READ
LA r8,#TMP2
CALL @niom_translate
MOVI r5,#NIOM_ENOENT
MOVI r3,0x183
CALL @chk

; the descriptor queued before revoke completes with ESTALE
LA r1,#RING
CALL @nacc_complete
MOVI r5,1
MOVI r3,0x184
CALL @chk
LA r1,#RING
LD r2,r0,#SEQ1
LA r3,#RES
CALL @nacc_result
LD r1,r0,#RES+1
MOVI r5,#NACC_ESTALE
MOVI r3,0x185
CALL @chk
; new submissions fail closed
LA r1,#RING
MOVI r2,0
MOVI r3,7
MOVI r4,0x2000
MOVI r5,2
MOVI r6,8
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
MOVI r5,0
MOVI r3,0x186
CALL @chk
LA r1,#RING
LA r2,#CNT
CALL @nacc_counters
LD r1,r0,#CNT+5
MOVI r5,#NACC_ESTALE
MOVI r3,0x188
CALL @chk
LA r1,#RING
CALL @nacc_fence
MOVI r5,0
MOVI r3,0x187
CALL @chk

; fault records: eight faults; the ring retains 5..8.  Slot 0 is the
; post-rebind old-IOVA ENOENT, slot 1 the old-generation ESTALE, slot 2 the
; new-generation ENOENT and slot 3 the queued DMA's stale-generation fault.
LD r1,r0,#DOMV
CALL @niom_fault_count
MOVI r5,8
MOVI r3,0x190
CALL @chk
LD r1,r0,#DOMV
MOVI r2,0
LA r3,#TMP2
CALL @niom_fault
MOVI r5,0
MOVI r3,0x191
CALL @chk
LD r1,r0,#TMP2+0
MOVI r5,#NIOM_ENOENT
MOVI r3,0x192
CALL @chk
LD r1,r0,#TMP2+1
MOVI r5,0
MOVI r3,0x193
CALL @chk
LD r1,r0,#TMP2+2
MOVI r5,1
MOVI r3,0x194
CALL @chk
LD r1,r0,#DOMV
MOVI r2,1
LA r3,#TMP2
CALL @niom_fault
LD r1,r0,#TMP2+0
MOVI r5,#NIOM_ESTALE
MOVI r3,0x195
CALL @chk
LD r1,r0,#DOMV
MOVI r2,3
LA r3,#TMP2
CALL @niom_fault
LD r1,r0,#TMP2+0
MOVI r5,#NIOM_ESTALE
MOVI r3,0x196
CALL @chk
LD r1,r0,#TMP2+2
MOVI r5,7
MOVI r3,0x197
CALL @chk

; ---------------------------------------------------------------------------
; Large VRAM: 2 TiB at BAR IOVA 16 GiB, 64 MiB granule.
LA r1,#BIGCTX
MOVI r2,0
MOVI r3,4
MOVI r4,0
MOVI r5,512
LA r6,0x4000000
LA r7,#BIGBM
MOVI r8,1024
CALL @nacc_vram_init
MOVI r5,0
MOVI r3,0x200
CALL @chk

LA r1,#BIGCTX
LA r2,#STATS
CALL @nacc_vram_stats
MOVI r5,0
MOVI r3,0x201
CALL @chk
LD r1,r0,#STATS+20
LA r2,0x8000
MOVI r5,0
CMP r1,r2
JMP[NE] @bad_units
LD r1,r0,#STATS+19
MOVI r5,512
MOVI r3,0x202
CALL @chk
LD r1,r0,#STATS+7
MOVI r5,512
MOVI r3,0x203
CALL @chk
LD r1,r0,#STATS+17
MOVI r5,4
MOVI r3,0x204
CALL @chk

; weights 32 GiB -> VRAM at offset 0
LA r1,#BIGCTX
MOVI r2,1
MOVI r3,0
MOVI r4,8
LD r5,r0,#DOM3V
LA r6,#OUT0
CALL @nacc_vram_place
MOVI r5,1
MOVI r3,0x205
CALL @chk
LD r1,r0,#OUT0+0
MOVI r5,1
MOVI r3,0x206
CALL @chk
LD r1,r0,#OUT0+1
MOVI r5,0
MOVI r3,0x207
CALL @chk
LD r1,r0,#OUT0+2
MOVI r5,0
MOVI r3,0x208
CALL @chk
LD r1,r0,#OUT0+3
MOVI r5,512
MOVI r3,0x209
CALL @chk
LD r1,r0,#OUT0+6
MOVI r5,8
MOVI r3,0x20A
CALL @chk

; KV 2 GiB -> VRAM at 32 GiB
LA r1,#BIGCTX
MOVI r2,2
LA r3,0x80000000
MOVI r4,0
LD r5,r0,#DOM3V
LA r6,#OUT0
CALL @nacc_vram_place
MOVI r5,1
MOVI r3,0x20B
CALL @chk
LD r1,r0,#OUT0+0
MOVI r5,1
MOVI r3,0x20C
CALL @chk
LD r1,r0,#OUT0+1
MOVI r5,0
MOVI r3,0x20D
CALL @chk
LD r1,r0,#OUT0+2
MOVI r5,8
MOVI r3,0x20E
CALL @chk
LD r1,r0,#OUT0+3
MOVI r5,32
MOVI r3,0x20F
CALL @chk

; stats: 544 units, 34 GiB
LA r1,#BIGCTX
LA r2,#STATS
CALL @nacc_vram_stats
LD r1,r0,#STATS+0
MOVI r5,544
MOVI r3,0x210
CALL @chk
LD r1,r0,#STATS+1
MOVI r5,0
MOVI r3,0x211
CALL @chk
LD r1,r0,#STATS+4
LA r5,0x80000000
MOVI r3,0x212
CALL @chk
LD r1,r0,#STATS+5
MOVI r5,8
MOVI r3,0x213
CALL @chk
LD r1,r0,#STATS+10
MOVI r5,2
MOVI r3,0x214
CALL @chk
LD r1,r0,#STATS+11
MOVI r5,0
MOVI r3,0x215
CALL @chk

; activations are host-only by policy
LA r1,#BIGCTX
MOVI r2,3
LA r3,0x40000000
MOVI r4,0
LD r5,r0,#DOM3V
LA r6,#OUT0
CALL @nacc_vram_place
MOVI r5,2
MOVI r3,0x216
CALL @chk
LD r1,r0,#OUT0+0
MOVI r5,0
MOVI r3,0x217
CALL @chk

; free KV then weights
LA r1,#BIGCTX
MOVI r2,0
MOVI r3,8
MOVI r4,32
MOVI r5,0
CALL @nacc_vram_free
MOVI r5,0
MOVI r3,0x218
CALL @chk
LA r1,#BIGCTX
MOVI r2,0
MOVI r3,0
MOVI r4,512
MOVI r5,0
CALL @nacc_vram_free
MOVI r5,0
MOVI r3,0x219
CALL @chk
LA r1,#BIGCTX
LA r2,#STATS
CALL @nacc_vram_stats
LD r1,r0,#STATS+0
MOVI r5,0
MOVI r3,0x21A
CALL @chk
LD r1,r0,#STATS+9
MOVI r5,2
MOVI r3,0x21B
CALL @chk

; unmapped BAR (domain 0) -> allocate, fail translation, roll back, host
LA r1,#BIGCTX
MOVI r2,1
LA r3,0x40000000
MOVI r4,0
MOVI r5,0
LA r6,#OUT0
CALL @nacc_vram_place
MOVI r5,2
MOVI r3,0x21C
CALL @chk
LD r1,r0,#OUT0+0
MOVI r5,0
MOVI r3,0x21D
CALL @chk
LA r1,#BIGCTX
LA r2,#STATS
CALL @nacc_vram_stats
LD r1,r0,#STATS+0
MOVI r5,0
MOVI r3,0x21E
CALL @chk
LD r1,r0,#STATS+13
MOVI r5,1
MOVI r3,0x21F
CALL @chk
LD r1,r0,#STATS+11
MOVI r5,2
MOVI r3,0x220
CALL @chk

; ---------------------------------------------------------------------------
; Small VRAM: 256 MiB = 4 x 64 MiB units, at BAR IOVA 32 GiB in domain 2.
LA r1,#TINYCTX
MOVI r2,0
MOVI r3,8
LA r4,0x10000000
MOVI r5,0
LA r6,0x4000000
LA r7,#TINYBM
MOVI r8,8
CALL @nacc_vram_init
MOVI r5,0
MOVI r3,0x230
CALL @chk

; 3 units of weights -> VRAM at 0
LA r1,#TINYCTX
MOVI r2,1
LA r3,0xC000000
MOVI r4,0
LD r5,r0,#DOM2V
LA r6,#OUT0
CALL @nacc_vram_place
MOVI r5,1
MOVI r3,0x231
CALL @chk
LD r1,r0,#OUT0+3
MOVI r5,3
MOVI r3,0x232
CALL @chk

; 2 units of KV -> exhausted -> host fallback, no silent truncation
LA r1,#TINYCTX
MOVI r2,2
LA r3,0x8000000
MOVI r4,0
LD r5,r0,#DOM2V
LA r6,#OUT0
CALL @nacc_vram_place
MOVI r5,2
MOVI r3,0x233
CALL @chk
LD r1,r0,#OUT0+0
MOVI r5,0
MOVI r3,0x234
CALL @chk
LD r1,r0,#OUT0+3
MOVI r5,0
MOVI r3,0x235
CALL @chk

LA r1,#TINYCTX
LA r2,#STATS
CALL @nacc_vram_stats
LD r1,r0,#STATS+0
MOVI r5,3
MOVI r3,0x236
CALL @chk
LD r1,r0,#STATS+10
MOVI r5,1
MOVI r3,0x237
CALL @chk
LD r1,r0,#STATS+11
MOVI r5,1
MOVI r3,0x238
CALL @chk
LD r1,r0,#STATS+12
MOVI r5,1
MOVI r3,0x239
CALL @chk

; direct alloc gets the last unit at 192 MiB, then free it
LA r1,#TINYCTX
MOVI r2,1
MOVI r3,0
LA r4,#TMP2
CALL @nacc_vram_alloc
MOVI r5,0
MOVI r3,0x23A
CALL @chk
LD r1,r0,#TMP2+0
LA r2,0xC000000
MOVI r5,0
CMP r1,r2
JMP[NE] @bad_tiny_off
LD r1,r0,#TMP2+1
MOVI r5,0
MOVI r3,0x23B
CALL @chk
LA r1,#TINYCTX
LA r2,0xC000000
MOVI r3,0
MOVI r4,1
MOVI r5,0
CALL @nacc_vram_free
MOVI r5,0
MOVI r3,0x23C
CALL @chk

; full ring: a 2-unit request fails, an exact free fails after double free
LA r1,#TINYCTX
MOVI r2,2
MOVI r3,0
LA r4,#TMP2
CALL @nacc_vram_alloc
MOVI r5,#NACC_ENOSPC
MOVI r3,0x23D
CALL @chk
LA r1,#TINYCTX
LA r2,0xC000000
MOVI r3,0
MOVI r4,1
MOVI r5,0
CALL @nacc_vram_free
MOVI r5,#NACC_ENOENT
MOVI r3,0x23E
CALL @chk
LA r1,#TINYCTX
MOVI r2,0x1000
MOVI r3,0
MOVI r4,1
MOVI r5,0
CALL @nacc_vram_free
MOVI r5,#NACC_EALIGN
MOVI r3,0x23F
CALL @chk

; free the weight placement and prove all units return
LA r1,#TINYCTX
MOVI r2,0
MOVI r3,0
MOVI r4,3
MOVI r5,0
CALL @nacc_vram_free
MOVI r5,0
MOVI r3,0x240
CALL @chk
LA r1,#TINYCTX
LA r2,#STATS
CALL @nacc_vram_stats
LD r1,r0,#STATS+0
MOVI r5,0
MOVI r3,0x241
CALL @chk
LD r1,r0,#STATS+2
MOVI r5,4
MOVI r3,0x242
CALL @chk

; ---------------------------------------------------------------------------
; Ring capacity: a fresh 4-slot ring on the live domain 2 accepts four
; descriptors and rejects the fifth without overwriting the queued head.
LA r1,#RING
LA r2,#DESC
MOVI r3,4
LD r4,r0,#DOM2V
CALL @nacc_ring_init
MOVI r5,0
MOVI r3,0x250
CALL @chk

LA r1,#RING
MOVI r2,0
MOVI r3,3
MOVI r4,0x2000
MOVI r5,2
MOVI r6,8
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
MOVI r5,1
MOVI r3,0x251
CALL @chk
LA r1,#RING
MOVI r2,0
MOVI r3,3
MOVI r4,0x2000
MOVI r5,2
MOVI r6,8
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
MOVI r5,2
MOVI r3,0x252
CALL @chk
LA r1,#RING
MOVI r2,0
MOVI r3,3
MOVI r4,0x2000
MOVI r5,2
MOVI r6,8
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
MOVI r5,3
MOVI r3,0x253
CALL @chk
LA r1,#RING
MOVI r2,0
MOVI r3,3
MOVI r4,0x2000
MOVI r5,2
MOVI r6,8
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
MOVI r5,4
MOVI r3,0x254
CALL @chk
LA r1,#RING
MOVI r2,0
MOVI r3,3
MOVI r4,0x2000
MOVI r5,2
MOVI r6,8
MOVI r7,0
MOVI r8,0
CALL @nacc_submit
MOVI r5,0
MOVI r3,0x255
CALL @chk
LA r1,#RING
LA r2,#CNT
CALL @nacc_counters
LD r1,r0,#CNT+5
MOVI r5,#NACC_ENOSPC
MOVI r3,0x256
CALL @chk
LD r1,r0,#CNT+4
MOVI r5,4
MOVI r3,0x257
CALL @chk

; ---------------------------------------------------------------------------
MOVI r1,79
PUTC r1
HALT

; ---------------------------------------------------------------------------
; Failure paths print F <hex id>.
bad_pattern1:
MOVI r3,0x1A0
JMP @failcode
bad_pattern2:
MOVI r3,0x1A1
JMP @failcode
bad_dst3:
MOVI r3,0x1A2
JMP @failcode
bad_pattern3:
MOVI r3,0x1A3
JMP @failcode
bad_post_cancel:
MOVI r3,0x1A4
JMP @failcode
bad_epoch:
MOVI r3,0x1A5
JMP @failcode
bad_gen:
MOVI r3,0x1A6
JMP @failcode
bad_units:
MOVI r3,0x1A7
JMP @failcode
bad_tiny_off:
MOVI r3,0x1A8
JMP @failcode

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

; chkmap r1=result r5=expected errno r3=diagnostic.
; A rejected map returns 0 and publishes the exact code in niom_errno.
chkmap:
ST r15,r14,0
ADDI r14,r14,24
ST r5,r14,1
ST r3,r14,2
CMP r1,r0
JMP[NE] @chkmap_bad
CALL @niom_errno
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

; t_puthex4 r1 -> four uppercase hex digits.
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
